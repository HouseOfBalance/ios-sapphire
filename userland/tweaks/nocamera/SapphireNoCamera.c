/*
 * SapphireNoCamera -> SapphireAVCamera v3 (Zero-Copy IOSurface + Video Recording + Smooth Zoom):
 *
 * 1. Prevents InCallService / Camera.app / third-party apps from deadlocking in
 *    FigCaptureSourceRemoteCopyCaptureSources waiting for mediaserverd's H10ISP server.
 * 2. Bridges AVCaptureDevice, AVCaptureDeviceDiscoverySession, AVCaptureSession,
 *    AVCaptureVideoPreviewLayer, and AVCaptureVideoDataOutput to camd using a
 *    persistent Unix socket (/var/run/camd.sock) + Zero-Copy global IOSurface lookup.
 * 3. Inside Apple's stock Camera.app (com.apple.camera):
 *    - Zero-Copy GPU scanout: paints camd's global IOSurface directly onto a CALayer
 *      at index 0 inside Apple's real CAMPreviewView (behind all real Apple controls).
 *    - Photo capture: Apple's real shutter button -> camd CAPTURE -> Photos Library +
 *      live CAMImageWell thumbnail update.
 *    - Video recording: when Camera.app is in VIDEO mode, tapping Apple's real red shutter
 *      starts/stops AVAssetWriter (.mov H.264 / JPEG fallback) fed directly from camd's
 *      IOSurface-backed CVPixelBuffer and saves straight to Photos Library!
 *    - Real Flip Camera (Back/Front), Smooth Pinch + Wheel Zoom (0.6x UW / 1x / 2x / 5x),
 *      Tap-to-Focus (METER), and Drag-to-EV (EV).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceRef.h>
#include <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define CAMD_SOCK_PATH    "/var/run/camd.sock"
#define CAMD_SHM_PATH     "/var/tmp/camd-preview.bin"
#define CAMD_NOTIFY_FRAME "com.sapphire.cam.frame"
#define CAMD_SHM_MAGIC    0x444D4143u
#define CAMD_SHM_SLOTS    3

typedef struct {
	uint64_t seq;
	uint64_t ts_ns;
	uint32_t width, height, stride;
	uint32_t mode;
	float exposure_us, gain;
	float wb[3];
	float luma;
} CamdSlot;

typedef struct {
	uint32_t magic, version;
	uint32_t header_size, slot_size, nslots;
	uint32_t latest;
	uint64_t seq;
	uint32_t running;
	uint32_t reserved[7]; /* reserved[0..2] = global IOSurfaceID per slot */
	CamdSlot slot[CAMD_SHM_SLOTS];
} CamdShm;

static int g_shm_fd = -1;
static const CamdShm *g_shm = NULL;
static size_t g_shm_len = 0;
static int g_notify_tok = -1;
static uint64_t g_last_seq = 0;
static bool g_running = false;
static int g_mode = 1; /* 1=Back 1x S5KHM6, 12=UW 0.6x S5K4H7, 4=2x crop, 13=Macro, 11=Front OV16A1Q */
static bool g_capturing = false;

static int g_camd_fd = -1;
static pthread_mutex_t g_camd_mu = PTHREAD_MUTEX_INITIALIZER;

/* Cached zero-copy IOSurface handles per shm slot */
static IOSurfaceRef g_surf_cache[CAMD_SHM_SLOTS];
static uint32_t g_surf_id_cache[CAMD_SHM_SLOTS];

#define MAX_LAYERS  8
#define MAX_OUTPUTS 8
static id g_preview_layers[MAX_LAYERS];
static id g_video_outputs[MAX_OUTPUTS];

/* Native Apple Camera.app hosts (zero opaque overlay) */
static id g_cam_preview_host = nil; /* Apple's real CAMPreviewView */
static id g_cam_live_layer = nil;   /* Zero-copy CALayer inserted at index 0 of CAMPreviewView.layer */
static id g_cam_image_well = nil;   /* Apple's real CAMImageWell thumbnail button */
static double g_zoom_factor = 1.0;
static long g_capture_mode = 0;     /* 0 = Photo, 1 = Video, 2 = Square, 3 = Pano, etc. */

/* Video Recording state (AVAssetWriter) */
static bool g_recording = false;
static id g_asset_writer = nil;
static id g_writer_input = nil;
static id g_pixel_adaptor = nil;
static char g_video_path[256];
static uint64_t g_video_start_ns = 0;
static pthread_mutex_t g_rec_mu = PTHREAD_MUTEX_INITIALIZER;

static void
camd_cmd(const char *cmd, char *reply, size_t reply_cap, int timeout_ms)
{
	if (reply && reply_cap > 0) reply[0] = '\0';
	pthread_mutex_lock(&g_camd_mu);
	bool is_stop = (strncmp(cmd, "STOP", 4) == 0);
	if (g_camd_fd < 0) {
		if (is_stop) {
			pthread_mutex_unlock(&g_camd_mu);
			return;
		}
		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (fd < 0) {
			pthread_mutex_unlock(&g_camd_mu);
			return;
		}
		struct sockaddr_un addr;
		memset(&addr, 0, sizeof(addr));
		addr.sun_family = AF_UNIX;
		strlcpy(addr.sun_path, CAMD_SOCK_PATH, sizeof(addr.sun_path));
		if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
			close(fd);
			pthread_mutex_unlock(&g_camd_mu);
			return;
		}
		g_camd_fd = fd;
	}

	size_t l = strlen(cmd);
	if (write(g_camd_fd, cmd, l) != (ssize_t)l) {
		close(g_camd_fd);
		g_camd_fd = -1;
		pthread_mutex_unlock(&g_camd_mu);
		return;
	}

	if (reply && reply_cap > 1) {
		size_t total = 0;
		int elapsed = 0;
		while (elapsed < timeout_ms && total + 1 < reply_cap) {
			struct pollfd p = { g_camd_fd, POLLIN, 0 };
			int pr = poll(&p, 1, 100);
			if (pr > 0) {
				ssize_t n = read(g_camd_fd, reply + total, reply_cap - 1 - total);
				if (n <= 0) {
					close(g_camd_fd);
					g_camd_fd = -1;
					break;
				}
				total += (size_t)n;
				reply[total] = '\0';
				if (strncmp(cmd, "CAPTURE", 7) == 0) {
					if (strstr(reply, "DONE ") || strstr(reply, "ERR ")) break;
				} else if (strchr(reply, '\n')) {
					break;
				}
			} else if (pr < 0) {
				break;
			}
			elapsed += 100;
		}
	}

	if (is_stop && g_camd_fd >= 0) {
		close(g_camd_fd);
		g_camd_fd = -1;
	}
	pthread_mutex_unlock(&g_camd_mu);
}

static bool
shm_open_if_needed(void)
{
	if (g_shm != NULL && g_shm != MAP_FAILED) return true;
	int fd = open(CAMD_SHM_PATH, O_RDONLY);
	if (fd < 0) return false;
	struct stat st;
	if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(CamdShm)) {
		close(fd);
		return false;
	}
	void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		close(fd);
		return false;
	}
	g_shm_fd = fd;
	g_shm = (const CamdShm *)p;
	g_shm_len = (size_t)st.st_size;
	return true;
}

static IOSurfaceRef
lookup_slot_surface(uint32_t idx)
{
	if (idx >= CAMD_SHM_SLOTS || g_shm == NULL) return NULL;
	uint32_t sid = g_shm->reserved[idx];
	if (sid == 0) return NULL;
	if (g_surf_cache[idx] != NULL && g_surf_id_cache[idx] == sid) {
		return g_surf_cache[idx];
	}
	if (g_surf_cache[idx] != NULL) {
		CFRelease(g_surf_cache[idx]);
		g_surf_cache[idx] = NULL;
		g_surf_id_cache[idx] = 0;
	}
	IOSurfaceRef s = IOSurfaceLookup((IOSurfaceID)sid);
	if (s != NULL) {
		g_surf_cache[idx] = s;
		g_surf_id_cache[idx] = sid;
	}
	return s;
}

/* ================================================================== Video Recording (AVAssetWriter) */
static void
video_start_recording(uint32_t w, uint32_t h)
{
	pthread_mutex_lock(&g_rec_mu);
	if (g_recording) {
		pthread_mutex_unlock(&g_rec_mu);
		return;
	}
	if (w < 64 || h < 64) { w = 750; h = 1000; }
	snprintf(g_video_path, sizeof(g_video_path), "/var/tmp/sapphire_vid_%ld.mov", (long)time(NULL));
	unlink(g_video_path);

	Class urlCls = objc_getClass("NSURL");
	Class writerCls = objc_getClass("AVAssetWriter");
	Class inputCls = objc_getClass("AVAssetWriterInput");
	Class adaptCls = objc_getClass("AVAssetWriterInputPixelBufferAdaptor");
	Class dictCls = objc_getClass("NSDictionary");
	Class numCls = objc_getClass("NSNumber");
	if (!urlCls || !writerCls || !inputCls || !adaptCls) {
		pthread_mutex_unlock(&g_rec_mu);
		return;
	}

	CFStringRef pathStr = CFStringCreateWithCString(NULL, g_video_path, kCFStringEncodingUTF8);
	id url = ((id (*)(Class, SEL, id))objc_msgSend)(urlCls, sel_registerName("fileURLWithPath:"), (id)pathStr);
	CFRelease(pathStr);

	id err = nil;
	id writer = ((id (*)(id, SEL, id, id, id *))objc_msgSend)(
	    ((id (*)(Class, SEL))objc_msgSend)(writerCls, sel_registerName("alloc")),
	    sel_registerName("initWithURL:fileType:error:"), url, (id)CFSTR("com.apple.quicktime-movie"), &err);
	if (writer == nil) {
		pthread_mutex_unlock(&g_rec_mu);
		return;
	}

	/* Try H.264 first, fall back to JPEG if no hardware H.264 encoder */
	id nW = ((id (*)(Class, SEL, unsigned int))objc_msgSend)(numCls, sel_registerName("numberWithUnsignedInt:"), w);
	id nH = ((id (*)(Class, SEL, unsigned int))objc_msgSend)(numCls, sel_registerName("numberWithUnsignedInt:"), h);
	const char *codecs[2] = { "avc1", "jpeg" };
	id vinput = nil;
	for (int ci = 0; ci < 2 && vinput == nil; ci++) {
		CFStringRef cstr = CFStringCreateWithCString(NULL, codecs[ci], kCFStringEncodingUTF8);
		id keys[3] = { (id)CFSTR("AVVideoCodecKey"), (id)CFSTR("AVVideoWidthKey"), (id)CFSTR("AVVideoHeightKey") };
		id vals[3] = { (id)cstr, nW, nH };
		id settings = ((id (*)(Class, SEL, const id *, const id *, unsigned long))objc_msgSend)(
		    dictCls, sel_registerName("dictionaryWithObjects:forKeys:count:"), vals, keys, 3);
		CFRelease(cstr);
		id cand = ((id (*)(Class, SEL, id, id))objc_msgSend)(
		    inputCls, sel_registerName("assetWriterInputWithMediaType:outputSettings:"), (id)CFSTR("vide"), settings);
		if (cand && ((BOOL (*)(id, SEL, id))objc_msgSend)(writer, sel_registerName("canAddInput:"), cand)) {
			((void (*)(id, SEL, BOOL))objc_msgSend)(cand, sel_registerName("setExpectsMediaDataInRealTime:"), YES);
			((void (*)(id, SEL, id))objc_msgSend)(writer, sel_registerName("addInput:"), cand);
			vinput = cand;
		}
	}
	if (vinput == nil) {
		pthread_mutex_unlock(&g_rec_mu);
		return;
	}

	id nPF = ((id (*)(Class, SEL, unsigned int))objc_msgSend)(numCls, sel_registerName("numberWithUnsignedInt:"), kCVPixelFormatType_32BGRA);
	id pkeys[3] = { (id)kCVPixelBufferPixelFormatTypeKey, (id)kCVPixelBufferWidthKey, (id)kCVPixelBufferHeightKey };
	id pvals[3] = { nPF, nW, nH };
	id pattrs = ((id (*)(Class, SEL, const id *, const id *, unsigned long))objc_msgSend)(
	    dictCls, sel_registerName("dictionaryWithObjects:forKeys:count:"), pvals, pkeys, 3);
	id adaptor = ((id (*)(Class, SEL, id, id))objc_msgSend)(
	    adaptCls, sel_registerName("assetWriterInputPixelBufferAdaptorWithAssetWriterInput:sourcePixelBufferAttributes:"),
	    vinput, pattrs);

	if (((BOOL (*)(id, SEL))objc_msgSend)(writer, sel_registerName("startWriting"))) {
		((void (*)(id, SEL, CMTime))objc_msgSend)(writer, sel_registerName("startSessionAtSourceTime:"), kCMTimeZero);
		g_asset_writer = ((id (*)(id, SEL))objc_msgSend)(writer, sel_registerName("retain"));
		g_writer_input = ((id (*)(id, SEL))objc_msgSend)(vinput, sel_registerName("retain"));
		g_pixel_adaptor = ((id (*)(id, SEL))objc_msgSend)(adaptor, sel_registerName("retain"));
		g_video_start_ns = 0;
		g_recording = true;
	}
	pthread_mutex_unlock(&g_rec_mu);
}

static void
video_stop_recording(void)
{
	pthread_mutex_lock(&g_rec_mu);
	if (!g_recording || g_asset_writer == nil) {
		pthread_mutex_unlock(&g_rec_mu);
		return;
	}
	g_recording = false;
	id writer = g_asset_writer;
	id vinput = g_writer_input;
	id adaptor = g_pixel_adaptor;
	g_asset_writer = nil;
	g_writer_input = nil;
	g_pixel_adaptor = nil;
	char outPath[256];
	strlcpy(outPath, g_video_path, sizeof(outPath));
	pthread_mutex_unlock(&g_rec_mu);

	((void (*)(id, SEL))objc_msgSend)(vinput, sel_registerName("markAsFinished"));
	CFStringRef pathStr = CFStringCreateWithCString(NULL, outPath, kCFStringEncodingUTF8);
	((void (*)(id, SEL, void (^)(void)))objc_msgSend)(writer, sel_registerName("finishWritingWithCompletionHandler:"), ^{
		void (*saveVid)(id, id, SEL, void *) = (void (*)(id, id, SEL, void *))dlsym(
		    RTLD_DEFAULT, "UISaveVideoAtPathToSavedPhotosAlbum");
		if (saveVid && pathStr) {
			saveVid((id)pathStr, nil, NULL, NULL);
		}
		if (pathStr) CFRelease(pathStr);
		((void (*)(id, SEL))objc_msgSend)(adaptor, sel_registerName("release"));
		((void (*)(id, SEL))objc_msgSend)(vinput, sel_registerName("release"));
		((void (*)(id, SEL))objc_msgSend)(writer, sel_registerName("release"));
	});
}

static void
video_append_frame(IOSurfaceRef surf, const uint8_t *pixels, const CamdSlot *s)
{
	pthread_mutex_lock(&g_rec_mu);
	if (!g_recording || g_writer_input == nil || g_pixel_adaptor == nil) {
		pthread_mutex_unlock(&g_rec_mu);
		return;
	}
	if (!((BOOL (*)(id, SEL))objc_msgSend)(g_writer_input, sel_registerName("isReadyForMoreMediaData"))) {
		pthread_mutex_unlock(&g_rec_mu);
		return;
	}
	if (g_video_start_ns == 0) g_video_start_ns = s->ts_ns;
	int64_t rel_ns = (int64_t)(s->ts_ns > g_video_start_ns ? s->ts_ns - g_video_start_ns : 0);
	CMTime pts = CMTimeMake(rel_ns / 1000000, 1000);

	CVPixelBufferRef pb = NULL;
	if (surf != NULL) {
		CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surf, NULL, &pb);
	}
	if (pb == NULL && pixels != NULL) {
		if (CVPixelBufferCreate(kCFAllocatorDefault, s->width, s->height, kCVPixelFormatType_32BGRA, NULL, &pb) == kCVReturnSuccess && pb) {
			CVPixelBufferLockBaseAddress(pb, 0);
			uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
			size_t bpr = CVPixelBufferGetBytesPerRow(pb);
			for (uint32_t y = 0; y < s->height; y++) {
				memcpy(dst + y * bpr, pixels + y * s->stride, s->width * 4);
			}
			CVPixelBufferUnlockBaseAddress(pb, 0);
		}
	}
	if (pb != NULL) {
		((BOOL (*)(id, SEL, CVPixelBufferRef, CMTime))objc_msgSend)(
		    g_pixel_adaptor, sel_registerName("appendPixelBuffer:withPresentationTime:"), pb, pts);
		CVPixelBufferRelease(pb);
	}
	pthread_mutex_unlock(&g_rec_mu);
}

/* ================================================================== Zero-Copy Frame Delivery */
static void
deliver_latest_frame(void)
{
	if (!g_running || !shm_open_if_needed()) return;
	if (g_shm->magic != CAMD_SHM_MAGIC || g_shm->nslots == 0) return;
	uint32_t idx = g_shm->latest;
	if (idx >= g_shm->nslots || idx >= CAMD_SHM_SLOTS) return;
	CamdSlot s = g_shm->slot[idx];
	if (s.seq == 0 || s.seq == g_last_seq || s.width == 0 || s.height == 0) return;
	size_t off = (size_t)g_shm->header_size + (size_t)idx * (size_t)g_shm->slot_size;
	size_t need = (size_t)s.stride * (size_t)s.height;
	const uint8_t *pixels = (off + need <= g_shm_len) ? ((const uint8_t *)g_shm + off) : NULL;
	g_last_seq = s.seq;

	/* Zero-Copy global IOSurface lookup! */
	IOSurfaceRef surf = lookup_slot_surface(idx);

	/* 1. Paint directly onto CALayer.contents (Zero CPU copy when IOSurface is valid!) */
	bool any_layer = (g_cam_live_layer != nil);
	for (int i = 0; !any_layer && i < MAX_LAYERS; i++) {
		if (g_preview_layers[i] != nil) any_layer = true;
	}
	if (any_layer) {
		Class catCls = objc_getClass("CATransaction");
		if (catCls) {
			((void (*)(Class, SEL))objc_msgSend)(catCls, sel_registerName("begin"));
			((void (*)(Class, SEL, BOOL))objc_msgSend)(catCls, sel_registerName("setDisableActions:"), YES);
		}
		if (surf != NULL) {
			if (g_cam_live_layer != nil) {
				((void (*)(id, SEL, id))objc_msgSend)(g_cam_live_layer, sel_registerName("setContents:"), (id)surf);
			}
			for (int i = 0; i < MAX_LAYERS; i++) {
				id layer = g_preview_layers[i];
				if (layer != nil) {
					((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setContents:"), (id)surf);
				}
			}
		} else if (pixels != NULL) {
			CFDataRef data = CFDataCreate(NULL, pixels, (CFIndex)need);
			if (data != NULL) {
				CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
				CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
				CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little;
				CGImageRef cg = CGImageCreate(s.width, s.height, 8, 32, s.stride, cs, bi, prov, NULL, false, kCGRenderingIntentDefault);
				if (cg != NULL) {
					if (g_cam_live_layer != nil) {
						((void (*)(id, SEL, id))objc_msgSend)(g_cam_live_layer, sel_registerName("setContents:"), (id)cg);
					}
					for (int i = 0; i < MAX_LAYERS; i++) {
						id layer = g_preview_layers[i];
						if (layer != nil) {
							((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setContents:"), (id)cg);
						}
					}
					CGImageRelease(cg);
				}
				CGDataProviderRelease(prov);
				CGColorSpaceRelease(cs);
				CFRelease(data);
			}
		}
		if (catCls) {
			((void (*)(Class, SEL))objc_msgSend)(catCls, sel_registerName("commit"));
		}
	}

	/* 2. Feed active video recording if recording */
	if (g_recording) {
		video_append_frame(surf, pixels, &s);
	}

	/* 3. Deliver CMSampleBuffer to any registered AVCaptureVideoDataOutput delegate (QR / FaceTime / 3rd-party) */
	for (int i = 0; i < MAX_OUTPUTS; i++) {
		id out = g_video_outputs[i];
		if (out == nil) continue;
		id del = ((id (*)(id, SEL))objc_msgSend)(out, sel_registerName("sampleBufferDelegate"));
		if (del == nil) continue;
		dispatch_queue_t q = ((dispatch_queue_t (*)(id, SEL))objc_msgSend)(out, sel_registerName("sampleBufferCallbackQueue"));
		if (q == NULL) q = dispatch_get_main_queue();

		CVPixelBufferRef pb = NULL;
		if (surf != NULL) {
			CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surf, NULL, &pb);
		}
		if (pb == NULL && pixels != NULL) {
			if (CVPixelBufferCreate(kCFAllocatorDefault, s.width, s.height, kCVPixelFormatType_32BGRA, NULL, &pb) == kCVReturnSuccess && pb != NULL) {
				CVPixelBufferLockBaseAddress(pb, 0);
				uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
				size_t dst_bpr = CVPixelBufferGetBytesPerRow(pb);
				for (uint32_t y = 0; y < s.height; y++) {
					memcpy(dst + y * dst_bpr, pixels + y * s.stride, s.width * 4);
				}
				CVPixelBufferUnlockBaseAddress(pb, 0);
			}
		}
		if (pb != NULL) {
			CMVideoFormatDescriptionRef fmt = NULL;
			if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) == noErr && fmt != NULL) {
				CMSampleTimingInfo timing = {
					.duration = CMTimeMake(1, 30),
					.presentationTimeStamp = CMTimeMake((int64_t)s.ts_ns, 1000000000),
					.decodeTimeStamp = kCMTimeInvalid
				};
				CMSampleBufferRef sb = NULL;
				if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sb) == noErr && sb != NULL) {
					SEL cb = sel_registerName("captureOutput:didOutputSampleBuffer:fromConnection:");
					if (class_getInstanceMethod(object_getClass(del), cb) != NULL) {
						dispatch_async(q, ^{
							((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(del, cb, out, sb, nil);
							CFRelease(sb);
						});
					} else {
						CFRelease(sb);
					}
				}
				CFRelease(fmt);
			}
			CVPixelBufferRelease(pb);
		}
	}
}

static void
start_camd_mode(int mode)
{
	g_mode = mode;
	g_running = true;
	if (g_notify_tok == -1) {
		notify_register_dispatch(CAMD_NOTIFY_FRAME, &g_notify_tok, dispatch_get_main_queue(), ^(int t) {
			(void)t;
			deliver_latest_frame();
		});
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char cmd[32], rep[128];
		snprintf(cmd, sizeof(cmd), "START %d\n", mode);
		camd_cmd(cmd, rep, sizeof(rep), 4000);
		dispatch_async(dispatch_get_main_queue(), ^{
			deliver_latest_frame();
		});
	});
}

static void
stop_camd(void)
{
	if (g_recording) video_stop_recording();
	g_running = false;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		char rep[64];
		camd_cmd("STOP\n", rep, sizeof(rep), 1500);
	});
}

static void
apply_smooth_zoom(double factor)
{
	if (factor < 0.5) factor = 0.5;
	if (factor > 5.0) factor = 5.0;
	g_zoom_factor = factor;

	/* Hardware lens switching + smooth GPU sub-scale */
	double digital = 1.0;
	if (g_mode != 11) {
		int want = (factor < 0.85) ? 12 : (factor >= 1.95 ? 4 : 1);
		if (want != g_mode) {
			start_camd_mode(want);
		}
		if (want == 12) digital = factor / 0.6;
		else if (want == 4) digital = factor / 2.0;
		else digital = factor;
		if (digital < 1.0) digital = 1.0;
	}
	if (g_cam_live_layer != nil) {
		CATransform3D t = CATransform3DMakeScale((CGFloat)digital, (CGFloat)digital, 1.0);
		((void (*)(id, SEL, CATransform3D))objc_msgSend)(g_cam_live_layer, sel_registerName("setTransform:"), t);
	}
}

static void
trigger_shutter_action(void)
{
	/* In VIDEO mode (mode == 1): toggle real AVAssetWriter .mov recording */
	if (g_capture_mode == 1) {
		if (g_recording) {
			video_stop_recording();
		} else {
			uint32_t w = 750, h = 1000;
			if (g_shm != NULL && g_shm->latest < CAMD_SHM_SLOTS) {
				w = g_shm->slot[g_shm->latest].width;
				h = g_shm->slot[g_shm->latest].height;
			}
			video_start_recording(w, h);
		}
		return;
	}

	if (g_capturing) return;
	g_capturing = true;

	/* Native shutter blink feedback on Apple's CAMPreviewView */
	if (g_cam_live_layer != nil) {
		((void (*)(id, SEL, float))objc_msgSend)(g_cam_live_layer, sel_registerName("setOpacity:"), 0.15f);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (g_cam_live_layer != nil) {
				((void (*)(id, SEL, float))objc_msgSend)(g_cam_live_layer, sel_registerName("setOpacity:"), 1.0f);
			}
		});
	}

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char rep[512];
		camd_cmd("CAPTURE 12 nodng\n", rep, sizeof(rep), 25000);
		char jpg[256] = {0};
		const char *done = strstr(rep, "DONE ");
		if (done != NULL) {
			done += 5;
			const char *end = strstr(done, " DNG ");
			if (!end) end = strpbrk(done, "\r\n");
			size_t l = end ? (size_t)(end - done) : strlen(done);
			if (l < sizeof(jpg)) {
				memcpy(jpg, done, l);
				jpg[l] = '\0';
			}
		}
		id savedImg = nil;
		if (jpg[0] != '\0') {
			CFStringRef pathStr = CFStringCreateWithCString(NULL, jpg, kCFStringEncodingUTF8);
			if (pathStr) {
				savedImg = ((id (*)(Class, SEL, id))objc_msgSend)(
				    objc_getClass("UIImage"), sel_registerName("imageWithContentsOfFile:"), (id)pathStr);
				if (savedImg != nil) {
					((id (*)(id, SEL))objc_msgSend)(savedImg, sel_registerName("retain"));
					void (*saveFn)(id, id, SEL, void *) = (void (*)(id, id, SEL, void *))dlsym(
					    RTLD_DEFAULT, "UIImageWriteToSavedPhotosAlbum");
					if (saveFn) saveFn(savedImg, nil, NULL, NULL);
				}
				CFRelease(pathStr);
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (savedImg != nil) {
				if (g_cam_image_well != nil) {
					SEL s1 = sel_registerName("setThumbnailImage:animated:");
					SEL s2 = sel_registerName("setThumbnailImage:uuid:animated:");
					if (class_getInstanceMethod(object_getClass(g_cam_image_well), s1) != NULL) {
						((void (*)(id, SEL, id, BOOL))objc_msgSend)(g_cam_image_well, s1, savedImg, YES);
					} else if (class_getInstanceMethod(object_getClass(g_cam_image_well), s2) != NULL) {
						((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(g_cam_image_well, s2, savedImg, (id)CFSTR("sapphire"), YES);
					}
				}
				((void (*)(id, SEL))objc_msgSend)(savedImg, sel_registerName("release"));
			}
			g_capturing = false;
		});
	});
}

/* ================================================================== Fake AVCaptureDevice & Input */
static id g_back_dev = nil;
static id g_front_dev = nil;

static id dev_uid(id self, SEL sel) {
	(void)sel;
	return (id)(self == g_front_dev ? CFSTR("com.apple.avfoundation.avcapturedevice.built-in_video:1")
	                                : CFSTR("com.apple.avfoundation.avcapturedevice.built-in_video:0"));
}
static id dev_model(id self, SEL sel) { (void)self; (void)sel; return (id)CFSTR("AVCaptureDeviceTypeBuiltInWideAngleCamera"); }
static id dev_name(id self, SEL sel) { (void)sel; return (id)(self == g_front_dev ? CFSTR("Front Camera") : CFSTR("Back Camera")); }
static long dev_position(id self, SEL sel) { (void)sel; return self == g_front_dev ? 2 : 1; }
static id dev_type(id self, SEL sel) { (void)self; (void)sel; return (id)CFSTR("AVCaptureDeviceTypeBuiltInWideAngleCamera"); }
static BOOL dev_yes(id self, SEL sel) { (void)self; (void)sel; return YES; }
static BOOL dev_no(id self, SEL sel) { (void)self; (void)sel; return NO; }
static BOOL dev_has_media(id self, SEL sel, id mediaType) {
	(void)self; (void)sel;
	return mediaType != nil && CFEqual((CFTypeRef)mediaType, CFSTR("vide"));
}
static id dev_empty_array(id self, SEL sel) {
	(void)self; (void)sel;
	return ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSArray"), sel_registerName("array"));
}
static id dev_self_array(id self, SEL sel) {
	(void)sel;
	return ((id (*)(Class, SEL, id))objc_msgSend)(objc_getClass("NSArray"), sel_registerName("arrayWithObject:"), self);
}
static id dev_forward_target(id self, SEL sel, SEL aSelector) { (void)self; (void)sel; (void)aSelector; return nil; }

static void
ensure_fake_devices(void)
{
	if (g_back_dev != nil) return;
	Class base = objc_getClass("NSObject");
	Class cls = objc_allocateClassPair(base, "SapphireFakeAVCaptureDevice", 0);
	if (cls != Nil) {
		class_addMethod(cls, sel_registerName("uniqueID"), (IMP)dev_uid, "@@:");
		class_addMethod(cls, sel_registerName("modelID"), (IMP)dev_model, "@@:");
		class_addMethod(cls, sel_registerName("localizedName"), (IMP)dev_name, "@@:");
		class_addMethod(cls, sel_registerName("position"), (IMP)dev_position, "q@:");
		class_addMethod(cls, sel_registerName("deviceType"), (IMP)dev_type, "@@:");
		class_addMethod(cls, sel_registerName("isConnected"), (IMP)dev_yes, "B@:");
		class_addMethod(cls, sel_registerName("hasMediaType:"), (IMP)dev_has_media, "B@:@");
		class_addMethod(cls, sel_registerName("formats"), (IMP)dev_empty_array, "@@:");
		class_addMethod(cls, sel_registerName("constituentDevices"), (IMP)dev_self_array, "@@:");
		class_addMethod(cls, sel_registerName("virtualDeviceSwitchOverVideoZoomFactors"), (IMP)dev_empty_array, "@@:");
		class_addMethod(cls, sel_registerName("lockForConfiguration:"), (IMP)dev_yes, "B@:^@");
		class_addMethod(cls, sel_registerName("unlockForConfiguration"), (IMP)dev_no, "v@:");
		class_addMethod(cls, sel_registerName("hasFlash"), (IMP)dev_no, "B@:");
		class_addMethod(cls, sel_registerName("hasTorch"), (IMP)dev_no, "B@:");
		class_addMethod(cls, sel_registerName("isFocusModeSupported:"), (IMP)dev_yes, "B@:q");
		class_addMethod(cls, sel_registerName("isExposureModeSupported:"), (IMP)dev_yes, "B@:q");
		class_addMethod(cls, sel_registerName("isWhiteBalanceModeSupported:"), (IMP)dev_yes, "B@:q");
		class_addMethod(cls, sel_registerName("forwardingTargetForSelector:"), (IMP)dev_forward_target, "@@::");
		objc_registerClassPair(cls);
		g_back_dev = ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("new"));
		g_front_dev = ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("new"));
	}
}

static id fake_device_array(void) {
	ensure_fake_devices();
	id objs[2] = { g_back_dev, g_front_dev };
	if (objs[0] == nil) return ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSArray"), sel_registerName("array"));
	return ((id (*)(Class, SEL, const id *, unsigned long))objc_msgSend)(
	    objc_getClass("NSArray"), sel_registerName("arrayWithObjects:count:"), objs, 2);
}
static id hook_default_device_3(id self, SEL sel, id devType, id mediaType, long pos) {
	(void)self; (void)sel; (void)devType; (void)mediaType;
	ensure_fake_devices();
	return pos == 2 ? g_front_dev : g_back_dev;
}
static id hook_default_device_1(id self, SEL sel, id mediaType) {
	(void)self; (void)sel; (void)mediaType;
	ensure_fake_devices();
	return g_back_dev;
}
static id hook_devices(id self, SEL sel) { (void)self; (void)sel; return fake_device_array(); }
static long hook_auth_status(id self, SEL sel, id mediaType) { (void)self; (void)sel; (void)mediaType; return 3; }
static void hook_request_access(id self, SEL sel, id mediaType, void (^handler)(BOOL granted)) {
	(void)self; (void)sel; (void)mediaType;
	if (handler) handler(YES);
}
static id hook_discovery_devices(id self, SEL sel) { (void)self; (void)sel; return fake_device_array(); }

/* ================================================================== Native Apple Camera.app Viewfinder Integration */
static void
attach_live_layer_to_preview(id previewView)
{
	if (previewView == nil) return;
	CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(previewView, sel_registerName("bounds"));
	if (b.size.width < 50 || b.size.height < 50) return;

	id hostLayer = ((id (*)(id, SEL))objc_msgSend)(previewView, sel_registerName("layer"));
	if (hostLayer == nil) return;

	if (g_cam_live_layer == nil) {
		Class layerCls = objc_getClass("CALayer");
		g_cam_live_layer = ((id (*)(Class, SEL))objc_msgSend)(layerCls, sel_registerName("layer"));
		((id (*)(id, SEL))objc_msgSend)(g_cam_live_layer, sel_registerName("retain"));
		((void (*)(id, SEL, id))objc_msgSend)(g_cam_live_layer, sel_registerName("setContentsGravity:"), (id)kCAGravityResizeAspectFill);
		((void (*)(id, SEL, BOOL))objc_msgSend)(g_cam_live_layer, sel_registerName("setMasksToBounds:"), YES);
	}
	if (g_cam_preview_host != previewView) {
		g_cam_preview_host = previewView;
		((void (*)(id, SEL, BOOL))objc_msgSend)(hostLayer, sel_registerName("setMasksToBounds:"), YES);
		((void (*)(id, SEL, CGRect))objc_msgSend)(g_cam_live_layer, sel_registerName("setFrame:"), b);
		((void (*)(id, SEL, id, unsigned int))objc_msgSend)(hostLayer, sel_registerName("insertSublayer:atIndex:"), g_cam_live_layer, 0);
	} else {
		((void (*)(id, SEL, CGRect))objc_msgSend)(g_cam_live_layer, sel_registerName("setFrame:"), b);
	}

	if (!g_running) {
		start_camd_mode(g_mode);
	}
}

static void
scan_camera_views(id view)
{
	if (view == nil) return;
	const char *cname = object_getClassName(view);
	if (cname != NULL) {
		if (strcmp(cname, "CAMPreviewView") == 0) {
			attach_live_layer_to_preview(view);
		} else if (strcmp(cname, "CAMImageWell") == 0) {
			g_cam_image_well = view;
		}
	}
	if (class_getInstanceMethod(object_getClass(view), sel_registerName("subviews")) != NULL) {
		id subs = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews"));
		unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(subs, sel_registerName("count"));
		for (unsigned long i = 0; i < n; i++) {
			id sub = ((id (*)(id, SEL, unsigned long))objc_msgSend)(subs, sel_registerName("objectAtIndex:"), i);
			scan_camera_views(sub);
		}
	}
}

static void
attach_stock_camera_native(void)
{
	Class appCls = objc_getClass("UIApplication");
	if (appCls == Nil) return;
	id app = ((id (*)(Class, SEL))objc_msgSend)(appCls, sel_registerName("sharedApplication"));
	if (app == nil) return;

	id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
	id enumerator = ((id (*)(id, SEL))objc_msgSend)(scenes, sel_registerName("objectEnumerator"));
	id scene = nil;
	while ((scene = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel_registerName("nextObject"))) != nil) {
		if (class_getInstanceMethod(object_getClass(scene), sel_registerName("windows")) != NULL) {
			id wins = ((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("windows"));
			unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(wins, sel_registerName("count"));
			for (unsigned long i = 0; i < n; i++) {
				scan_camera_views(((id (*)(id, SEL, unsigned long))objc_msgSend)(wins, sel_registerName("objectAtIndex:"), i));
			}
		}
	}
}

/* Hooks into Apple's real CameraUI classes */
static void (*orig_cam_preview_layout)(id self, SEL sel);
static void
hook_cam_preview_layout(id self, SEL sel)
{
	if (orig_cam_preview_layout) orig_cam_preview_layout(self, sel);
	attach_live_layer_to_preview(self);
}

static void (*orig_dyn_shutter_touches_ended)(id self, SEL sel, id touches, id event);
static void
hook_dyn_shutter_touches_ended(id self, SEL sel, id touches, id event)
{
	if (orig_dyn_shutter_touches_ended) orig_dyn_shutter_touches_ended(self, sel, touches, event);
	trigger_shutter_action();
}

static void (*orig_cu_shutter_touches_ended)(id self, SEL sel, id touches, id event);
static void
hook_cu_shutter_touches_ended(id self, SEL sel, id touches, id event)
{
	if (orig_cu_shutter_touches_ended) orig_cu_shutter_touches_ended(self, sel, touches, event);
	trigger_shutter_action();
}

static void (*orig_flip_touches_ended)(id self, SEL sel, id touches, id event);
static void
hook_flip_touches_ended(id self, SEL sel, id touches, id event)
{
	if (orig_flip_touches_ended) orig_flip_touches_ended(self, sel, touches, event);
	int next_mode = (g_mode == 11) ? 1 : 11;
	start_camd_mode(next_mode);
}

static void (*orig_mode_changed)(id self, SEL sel, long mode, BOOL animated);
static void
hook_mode_changed(id self, SEL sel, long mode, BOOL animated)
{
	if (orig_mode_changed) orig_mode_changed(self, sel, mode, animated);
	g_capture_mode = mode;
}

static void (*orig_zoom_changed)(id self, SEL sel, id ctrl, double factor, long interaction);
static void
hook_zoom_changed(id self, SEL sel, id ctrl, double factor, long interaction)
{
	if (orig_zoom_changed) orig_zoom_changed(self, sel, ctrl, factor, interaction);
	apply_smooth_zoom(factor);
}

static void (*orig_pinch_zoom)(id self, SEL sel, id recognizer);
static void
hook_pinch_zoom(id self, SEL sel, id recognizer)
{
	if (orig_pinch_zoom) orig_pinch_zoom(self, sel, recognizer);
	if (recognizer != nil) {
		double scale = ((double (*)(id, SEL))objc_msgSend)(recognizer, sel_registerName("scale"));
		if (scale > 0.1 && scale < 10.0) {
			apply_smooth_zoom(g_zoom_factor * scale);
			((void (*)(id, SEL, double))objc_msgSend)(recognizer, sel_registerName("setScale:"), 1.0);
		}
	}
}

static void (*orig_ev_changed)(id self, SEL sel, float bias);
static void
hook_ev_changed(id self, SEL sel, float bias)
{
	if (orig_ev_changed) orig_ev_changed(self, sel, bias);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char cmd[32], rep[64];
		snprintf(cmd, sizeof(cmd), "EV %.2f\n", bias);
		camd_cmd(cmd, rep, sizeof(rep), 1500);
	});
}

static void (*orig_focus_tap)(id self, SEL sel, CGPoint pt);
static void
hook_focus_tap(id self, SEL sel, CGPoint pt)
{
	if (orig_focus_tap) orig_focus_tap(self, sel, pt);
	if (g_cam_preview_host == nil) return;
	CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(g_cam_preview_host, sel_registerName("bounds"));
	if (b.size.width < 1 || b.size.height < 1) return;
	float nx = (float)(pt.x / b.size.width);
	float ny = (float)(pt.y / b.size.height);
	if (nx < 0) nx = 0;
	if (nx > 1) nx = 1;
	if (ny < 0) ny = 0;
	if (ny > 1) ny = 1;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char cmd[64], rep[128];
		snprintf(cmd, sizeof(cmd), "METER %.3f,%.3f\n", nx, ny);
		camd_cmd(cmd, rep, sizeof(rep), 2000);
	});
}

static void app_did_enter_bg(id self, SEL sel, id note) { (void)self; (void)sel; (void)note; stop_camd(); }
static void app_will_enter_fg(id self, SEL sel, id note) {
	(void)self; (void)sel; (void)note;
	if (g_cam_preview_host != nil) start_camd_mode(g_mode);
}

static id no_input_devices(id self, SEL selector) {
	(void)self; (void)selector;
	return ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSArray"), sel_registerName("array"));
}

static void (*orig_preview_set_session)(id self, SEL sel, id session);
static void
hook_preview_set_session(id self, SEL sel, id session)
{
	bool present = false;
	for (int i = 0; i < MAX_LAYERS; i++) {
		if (g_preview_layers[i] == self) { present = true; break; }
	}
	if (!present && session != nil) {
		for (int i = 0; i < MAX_LAYERS; i++) {
			if (g_preview_layers[i] == nil) { g_preview_layers[i] = self; break; }
		}
	}
	if (orig_preview_set_session) orig_preview_set_session(self, sel, session);
}

static BOOL hook_session_can_add(id self, SEL sel, id obj) { (void)self; (void)sel; (void)obj; return YES; }

static void (*orig_session_add_output)(id self, SEL sel, id output);
static void
hook_session_add_output(id self, SEL sel, id output)
{
	if (output != nil) {
		const char *cls = object_getClassName(output);
		if (cls && strstr(cls, "VideoDataOutput") != NULL) {
			bool present = false;
			for (int i = 0; i < MAX_OUTPUTS; i++) {
				if (g_video_outputs[i] == output) { present = true; break; }
			}
			if (!present) {
				for (int i = 0; i < MAX_OUTPUTS; i++) {
					if (g_video_outputs[i] == nil) { g_video_outputs[i] = output; break; }
				}
			}
		}
	}
	if (orig_session_add_output) orig_session_add_output(self, sel, output);
}

static void hook_session_start(id self, SEL sel) { (void)self; (void)sel; start_camd_mode(g_mode); }
static void hook_session_stop(id self, SEL sel) { (void)self; (void)sel; stop_camd(); }
static BOOL hook_session_is_running(id self, SEL sel) { (void)self; (void)sel; return g_running ? YES : NO; }

static void
install_camera_ui_hooks(void)
{
	static bool hooked = false;
	if (hooked) return;
	Class pv = objc_getClass("CAMPreviewView");
	if (pv == Nil) return;
	hooked = true;

	Method m = class_getInstanceMethod(pv, sel_registerName("layoutSubviews"));
	if (m) {
		orig_cam_preview_layout = (void (*)(id, SEL))method_getImplementation(m);
		method_setImplementation(m, (IMP)hook_cam_preview_layout);
	}
	Class dynShutter = objc_getClass("CAMDynamicShutterControl");
	if (dynShutter != Nil) {
		Method ms = class_getInstanceMethod(dynShutter, sel_registerName("touchesEnded:withEvent:"));
		if (ms) {
			orig_dyn_shutter_touches_ended = (void (*)(id, SEL, id, id))method_getImplementation(ms);
			method_setImplementation(ms, (IMP)hook_dyn_shutter_touches_ended);
		}
	}
	Class cuShutter = objc_getClass("CUShutterButton");
	if (cuShutter != Nil) {
		Method mc = class_getInstanceMethod(cuShutter, sel_registerName("touchesEnded:withEvent:"));
		if (mc) {
			orig_cu_shutter_touches_ended = (void (*)(id, SEL, id, id))method_getImplementation(mc);
			method_setImplementation(mc, (IMP)hook_cu_shutter_touches_ended);
		}
	}
	Class flipBtn = objc_getClass("CAMFlipButton");
	if (flipBtn != Nil) {
		Method mf = class_getInstanceMethod(flipBtn, sel_registerName("touchesEnded:withEvent:"));
		if (mf) {
			orig_flip_touches_ended = (void (*)(id, SEL, id, id))method_getImplementation(mf);
			method_setImplementation(mf, (IMP)hook_flip_touches_ended);
		}
	}
	Class modeDial = objc_getClass("CAMModeDial");
	if (modeDial != Nil) {
		Method mm = class_getInstanceMethod(modeDial, sel_registerName("setSelectedMode:animated:"));
		if (mm) {
			orig_mode_changed = (void (*)(id, SEL, long, BOOL))method_getImplementation(mm);
			method_setImplementation(mm, (IMP)hook_mode_changed);
		}
	}
	Class vfVC = objc_getClass("CAMViewfinderViewController");
	if (vfVC != Nil) {
		Method mz = class_getInstanceMethod(vfVC, sel_registerName("zoomControl:didChangeZoomFactor:interactionType:"));
		if (mz) {
			orig_zoom_changed = (void (*)(id, SEL, id, double, long))method_getImplementation(mz);
			method_setImplementation(mz, (IMP)hook_zoom_changed);
		}
		Method mp = class_getInstanceMethod(vfVC, sel_registerName("_handleZoomPinchGestureRecognizer:"));
		if (mp) {
			orig_pinch_zoom = (void (*)(id, SEL, id))method_getImplementation(mp);
			method_setImplementation(mp, (IMP)hook_pinch_zoom);
		}
		Method me = class_getInstanceMethod(vfVC, sel_registerName("_updateExposureTargetBias:"));
		if (me) {
			orig_ev_changed = (void (*)(id, SEL, float))method_getImplementation(me);
			method_setImplementation(me, (IMP)hook_ev_changed);
		}
		Method mt = class_getInstanceMethod(vfVC, sel_registerName("_handleFocusAndExposureTapAtPoint:"));
		if (mt) {
			orig_focus_tap = (void (*)(id, SEL, CGPoint))method_getImplementation(mt);
			method_setImplementation(mt, (IMP)hook_focus_tap);
		}
	}

	Class obsCls = objc_getClass("SapphireCamLifecycleObserver");
	if (obsCls == Nil) {
		obsCls = objc_allocateClassPair(objc_getClass("NSObject"), "SapphireCamLifecycleObserver", 0);
		class_addMethod(obsCls, sel_registerName("didEnterBg:"), (IMP)app_did_enter_bg, "v@:@");
		class_addMethod(obsCls, sel_registerName("willEnterFg:"), (IMP)app_will_enter_fg, "v@:@");
		objc_registerClassPair(obsCls);
	}
	static id obs = nil;
	if (obs == nil && obsCls != Nil) {
		obs = ((id (*)(Class, SEL))objc_msgSend)(obsCls, sel_registerName("new"));
		id nc = ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSNotificationCenter"), sel_registerName("defaultCenter"));
		((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
		    nc, sel_registerName("addObserver:selector:name:object:"),
		    obs, sel_registerName("didEnterBg:"), (id)CFSTR("UIApplicationDidEnterBackgroundNotification"), nil);
		((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
		    nc, sel_registerName("addObserver:selector:name:object:"),
		    obs, sel_registerName("willEnterFg:"), (id)CFSTR("UIApplicationWillEnterForegroundNotification"), nil);
	}
}

__attribute__((constructor)) static void
install(void)
{
	Class provider = objc_getClass("TUVideoDeviceControllerProvider");
	Method method = provider != Nil ? class_getInstanceMethod(provider, sel_registerName("inputDevices")) : NULL;
	if (method != NULL) {
		method_setImplementation(method, (IMP)no_input_devices);
	}

	Class devCls = objc_getClass("AVCaptureDevice");
	if (devCls != Nil) {
		Method m1 = class_getClassMethod(devCls, sel_registerName("defaultDeviceWithDeviceType:mediaType:position:"));
		if (m1) method_setImplementation(m1, (IMP)hook_default_device_3);
		Method m2 = class_getClassMethod(devCls, sel_registerName("defaultDeviceWithMediaType:"));
		if (m2) method_setImplementation(m2, (IMP)hook_default_device_1);
		Method m3 = class_getClassMethod(devCls, sel_registerName("devices"));
		if (m3) method_setImplementation(m3, (IMP)hook_devices);
		Method m4 = class_getClassMethod(devCls, sel_registerName("devicesWithMediaType:"));
		if (m4) method_setImplementation(m4, (IMP)hook_devices);
		Method m5 = class_getClassMethod(devCls, sel_registerName("authorizationStatusForMediaType:"));
		if (m5) method_setImplementation(m5, (IMP)hook_auth_status);
		Method m6 = class_getClassMethod(devCls, sel_registerName("requestAccessForMediaType:completionHandler:"));
		if (m6) method_setImplementation(m6, (IMP)hook_request_access);
	}

	Class discCls = objc_getClass("AVCaptureDeviceDiscoverySession");
	if (discCls != Nil) {
		Method md = class_getInstanceMethod(discCls, sel_registerName("devices"));
		if (md) method_setImplementation(md, (IMP)hook_discovery_devices);
	}

	Class pvLayer = objc_getClass("AVCaptureVideoPreviewLayer");
	if (pvLayer != Nil) {
		Method m = class_getInstanceMethod(pvLayer, sel_registerName("setSession:"));
		if (m != NULL) {
			orig_preview_set_session = (void (*)(id, SEL, id))method_getImplementation(m);
			method_setImplementation(m, (IMP)hook_preview_set_session);
		}
	}

	Class sess = objc_getClass("AVCaptureSession");
	if (sess != Nil) {
		Method m1 = class_getInstanceMethod(sess, sel_registerName("startRunning"));
		if (m1) method_setImplementation(m1, (IMP)hook_session_start);
		Method m2 = class_getInstanceMethod(sess, sel_registerName("stopRunning"));
		if (m2) method_setImplementation(m2, (IMP)hook_session_stop);
		Method m3 = class_getInstanceMethod(sess, sel_registerName("isRunning"));
		if (m3) method_setImplementation(m3, (IMP)hook_session_is_running);
		Method m4 = class_getInstanceMethod(sess, sel_registerName("canAddOutput:"));
		if (m4) method_setImplementation(m4, (IMP)hook_session_can_add);
		Method m5 = class_getInstanceMethod(sess, sel_registerName("addOutput:"));
		if (m5) {
			orig_session_add_output = (void (*)(id, SEL, id))method_getImplementation(m5);
			method_setImplementation(m5, (IMP)hook_session_add_output);
		}
		Method m6 = class_getInstanceMethod(sess, sel_registerName("canAddInput:"));
		if (m6) method_setImplementation(m6, (IMP)hook_session_can_add);
	}

	CFBundleRef mainBundle = CFBundleGetMainBundle();
	CFStringRef bundleID = mainBundle ? CFBundleGetIdentifier(mainBundle) : NULL;
	if (bundleID != NULL && CFEqual(bundleID, CFSTR("com.apple.camera"))) {
		install_camera_ui_hooks();
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			install_camera_ui_hooks();
			attach_stock_camera_native();
		});
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			attach_stock_camera_native();
		});
	}
}
