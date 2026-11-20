/*
 * SapphireNoCamera -> SapphireAVCamera:
 *
 * 1. Prevents InCallService / Camera.app / third-party apps from deadlocking in
 *    FigCaptureSourceRemoteCopyCaptureSources waiting for mediaserverd's non-existent
 *    AppleH10CamIn capture server.
 * 2. Bridges AVCaptureSession, AVCaptureVideoPreviewLayer, AVCaptureVideoDataOutput,
 *    and AVCapturePhotoOutput directly to camd (/var/run/camd.sock + /var/tmp/camd-preview.bin).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
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
	uint32_t reserved[7];
	CamdSlot slot[CAMD_SHM_SLOTS];
} CamdShm;

static int g_shm_fd = -1;
static const CamdShm *g_shm = NULL;
static size_t g_shm_len = 0;
static int g_notify_tok = -1;
static uint64_t g_last_seq = 0;
static bool g_running = false;
static int g_mode = 1; /* 1 = back S5KHM6, 11 = front OV16A1Q */

#define MAX_LAYERS  8
#define MAX_OUTPUTS 8
static id g_preview_layers[MAX_LAYERS];
static id g_video_outputs[MAX_OUTPUTS];

static void
camd_cmd(const char *cmd, char *reply, size_t reply_cap, int timeout_ms)
{
	if (reply && reply_cap > 0) reply[0] = '\0';
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return;
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strlcpy(addr.sun_path, CAMD_SOCK_PATH, sizeof(addr.sun_path));
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
		size_t l = strlen(cmd);
		if (write(fd, cmd, l) == (ssize_t)l && reply && reply_cap > 1) {
			struct pollfd p = { fd, POLLIN, 0 };
			if (poll(&p, 1, timeout_ms) > 0) {
				ssize_t n = read(fd, reply, reply_cap - 1);
				if (n > 0) reply[n] = '\0';
			}
		}
	}
	close(fd);
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
	if (off + need > g_shm_len) return;
	g_last_seq = s.seq;

	const uint8_t *pixels = (const uint8_t *)g_shm + off;

	/* 1. Update any registered AVCaptureVideoPreviewLayer */
	bool any_layer = false;
	for (int i = 0; i < MAX_LAYERS; i++) {
		if (g_preview_layers[i] != nil) { any_layer = true; break; }
	}
	if (any_layer) {
		CFDataRef data = CFDataCreate(NULL, pixels, (CFIndex)need);
		if (data != NULL) {
			CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
			CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
			CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little;
			CGImageRef cg = CGImageCreate(s.width, s.height, 8, 32, s.stride, cs, bi, prov, NULL, false, kCGRenderingIntentDefault);
			if (cg != NULL) {
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

	/* 2. Deliver CMSampleBuffer to any registered AVCaptureVideoDataOutput delegate */
	for (int i = 0; i < MAX_OUTPUTS; i++) {
		id out = g_video_outputs[i];
		if (out == nil) continue;
		id del = ((id (*)(id, SEL))objc_msgSend)(out, sel_registerName("sampleBufferDelegate"));
		if (del == nil) continue;
		dispatch_queue_t q = ((dispatch_queue_t (*)(id, SEL))objc_msgSend)(out, sel_registerName("sampleBufferCallbackQueue"));
		if (q == NULL) q = dispatch_get_main_queue();

		CVPixelBufferRef pb = NULL;
		if (CVPixelBufferCreate(kCFAllocatorDefault, s.width, s.height, kCVPixelFormatType_32BGRA, NULL, &pb) == kCVReturnSuccess && pb != NULL) {
			CVPixelBufferLockBaseAddress(pb, 0);
			uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
			size_t dst_bpr = CVPixelBufferGetBytesPerRow(pb);
			for (uint32_t y = 0; y < s.height; y++) {
				memcpy(dst + y * dst_bpr, pixels + y * s.stride, s.width * 4);
			}
			CVPixelBufferUnlockBaseAddress(pb, 0);

			CMVideoFormatDescriptionRef fmt = NULL;
			if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) == noErr && fmt != NULL) {
				CMSampleTimingInfo timing = {
					.duration = CMTimeMake(1, 15),
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

static id
no_input_devices(id self, SEL selector)
{
	(void)self;
	(void)selector;
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

static BOOL (*orig_session_can_add_output)(id self, SEL sel, id output);
static BOOL
hook_session_can_add_output(id self, SEL sel, id output)
{
	(void)self;
	(void)sel;
	(void)output;
	return YES;
}

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

static void (*orig_session_start)(id self, SEL sel);
static void
hook_session_start(id self, SEL sel)
{
	(void)self;
	(void)sel;
	g_running = true;
	if (g_notify_tok == -1) {
		notify_register_dispatch(CAMD_NOTIFY_FRAME, &g_notify_tok, dispatch_get_main_queue(), ^(int t) {
			(void)t;
			deliver_latest_frame();
		});
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char cmd[32], rep[128];
		snprintf(cmd, sizeof(cmd), "START %d\n", g_mode);
		camd_cmd(cmd, rep, sizeof(rep), 3500);
		dispatch_async(dispatch_get_main_queue(), ^{
			deliver_latest_frame();
		});
	});
}

static void (*orig_session_stop)(id self, SEL sel);
static void
hook_session_stop(id self, SEL sel)
{
	(void)self;
	(void)sel;
	g_running = false;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		char rep[64];
		camd_cmd("STOP\n", rep, sizeof(rep), 1500);
	});
}

static BOOL
hook_session_is_running(id self, SEL sel)
{
	(void)self;
	(void)sel;
	return g_running ? YES : NO;
}

__attribute__((constructor)) static void
install(void)
{
	Class provider = objc_getClass("TUVideoDeviceControllerProvider");
	Method method = provider != Nil ? class_getInstanceMethod(provider, sel_registerName("inputDevices")) : NULL;
	if (method != NULL) {
		method_setImplementation(method, (IMP)no_input_devices);
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
		if (m1 != NULL) {
			orig_session_start = (void (*)(id, SEL))method_getImplementation(m1);
			method_setImplementation(m1, (IMP)hook_session_start);
		}
		Method m2 = class_getInstanceMethod(sess, sel_registerName("stopRunning"));
		if (m2 != NULL) {
			orig_session_stop = (void (*)(id, SEL))method_getImplementation(m2);
			method_setImplementation(m2, (IMP)hook_session_stop);
		}
		Method m3 = class_getInstanceMethod(sess, sel_registerName("isRunning"));
		if (m3 != NULL) {
			method_setImplementation(m3, (IMP)hook_session_is_running);
		}
		Method m4 = class_getInstanceMethod(sess, sel_registerName("canAddOutput:"));
		if (m4 != NULL) {
			orig_session_can_add_output = (BOOL (*)(id, SEL, id))method_getImplementation(m4);
			method_setImplementation(m4, (IMP)hook_session_can_add_output);
		}
		Method m5 = class_getInstanceMethod(sess, sel_registerName("addOutput:"));
		if (m5 != NULL) {
			orig_session_add_output = (void (*)(id, SEL, id))method_getImplementation(m5);
			method_setImplementation(m5, (IMP)hook_session_add_output);
		}
	}
}
