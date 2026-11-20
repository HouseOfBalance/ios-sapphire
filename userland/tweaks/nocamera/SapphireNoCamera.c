/*
 * SapphireNoCamera -> SapphireAVCamera:
 *
 * 1. Prevents InCallService / Camera.app / third-party apps from deadlocking in
 *    FigCaptureSourceRemoteCopyCaptureSources waiting for mediaserverd's non-existent
 *    AppleH10CamIn capture server.
 * 2. Bridges AVCaptureDevice, AVCaptureDeviceDiscoverySession, AVCaptureDeviceInput,
 *    AVCaptureSession, AVCaptureVideoPreviewLayer, AVCaptureVideoDataOutput, and
 *    AVCapturePhotoOutput directly to camd (/var/run/camd.sock + /var/tmp/camd-preview.bin).
 * 3. For Apple's stock Camera.app (com.apple.camera), whose CAMViewfinderViewController
 *    relies on private CAMCaptureEngine / FigCaptureSession pipes inside mediaserverd,
 *    automatically attaches a native full-screen camd viewfinder + lens bar (1x, 0.6x UW,
 *    2x Crop, Macro, Front) + tap-to-focus + 12MP/108MP shutter directly inside Camera.app's
 *    main UIWindow so stock Camera.app works out-of-the-box!
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
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
static int g_mode = 1; /* 1 = back S5KHM6, 12 = UW, 4 = 2x, 13 = Macro, 11 = front OV16A1Q */

#define MAX_LAYERS  8
#define MAX_OUTPUTS 8
static id g_preview_layers[MAX_LAYERS];
static id g_video_outputs[MAX_OUTPUTS];

/* Stock Camera.app overlay views */
static id g_cam_img_view = nil;
static id g_cam_hud_label = nil;
static id g_cam_shutter_btn = nil;
static int g_cam_res_mode = 0; /* 0 = 12MP, 1 = 108MP, 2 = 12MP+DNG */

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
			size_t total = 0;
			int elapsed = 0;
			while (elapsed < timeout_ms && total + 1 < reply_cap) {
				struct pollfd p = { fd, POLLIN, 0 };
				int pr = poll(&p, 1, 200);
				if (pr > 0) {
					ssize_t n = read(fd, reply + total, reply_cap - 1 - total);
					if (n <= 0) break;
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
				elapsed += 200;
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

	/* 1. Update stock Camera.app overlay or any registered AVCaptureVideoPreviewLayer */
	bool any_layer = (g_cam_img_view != nil);
	for (int i = 0; !any_layer && i < MAX_LAYERS; i++) {
		if (g_preview_layers[i] != nil) any_layer = true;
	}
	if (any_layer) {
		CFDataRef data = CFDataCreate(NULL, pixels, (CFIndex)need);
		if (data != NULL) {
			CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
			CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
			CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little;
			CGImageRef cg = CGImageCreate(s.width, s.height, 8, 32, s.stride, cs, bi, prov, NULL, false, kCGRenderingIntentDefault);
			if (cg != NULL) {
				if (g_cam_img_view != nil) {
					id uiimg = ((id (*)(Class, SEL, CGImageRef))objc_msgSend)(
					    objc_getClass("UIImage"), sel_registerName("imageWithCGImage:"), cg);
					((void (*)(id, SEL, id))objc_msgSend)(
					    g_cam_img_view, sel_registerName("setImage:"), uiimg);
				}
				if (g_cam_hud_label != nil) {
					char hbuf[128];
					snprintf(hbuf, sizeof(hbuf), "#%llu  %ux%u  %.1f ms  %.1fx  luma %.2f",
					    (unsigned long long)s.seq, s.width, s.height,
					    s.exposure_us / 1000.0f, s.gain, s.luma);
					CFStringRef cfs = CFStringCreateWithCString(NULL, hbuf, kCFStringEncodingUTF8);
					if (cfs) {
						((void (*)(id, SEL, id))objc_msgSend)(
						    g_cam_hud_label, sel_registerName("setText:"), (id)cfs);
						CFRelease(cfs);
					}
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

/* ================================================================== Fake AVCaptureDevice & Input */
static id g_back_dev = nil;
static id g_front_dev = nil;

static id
dev_uid(id self, SEL sel)
{
	(void)sel;
	return (id)(self == g_front_dev ? CFSTR("com.apple.avfoundation.avcapturedevice.built-in_video:1")
	                                : CFSTR("com.apple.avfoundation.avcapturedevice.built-in_video:0"));
}
static id
dev_model(id self, SEL sel)
{
	(void)self; (void)sel;
	return (id)CFSTR("AVCaptureDeviceTypeBuiltInWideAngleCamera");
}
static id
dev_name(id self, SEL sel)
{
	(void)sel;
	return (id)(self == g_front_dev ? CFSTR("Front Camera") : CFSTR("Back Camera"));
}
static long
dev_position(id self, SEL sel)
{
	(void)sel;
	return self == g_front_dev ? 2 : 1; /* AVCaptureDevicePositionFront=2, Back=1 */
}
static id
dev_type(id self, SEL sel)
{
	(void)self; (void)sel;
	return (id)CFSTR("AVCaptureDeviceTypeBuiltInWideAngleCamera");
}
static BOOL
dev_yes(id self, SEL sel)
{
	(void)self; (void)sel;
	return YES;
}
static BOOL
dev_no(id self, SEL sel)
{
	(void)self; (void)sel;
	return NO;
}
static BOOL
dev_has_media(id self, SEL sel, id mediaType)
{
	(void)self; (void)sel;
	return mediaType != nil && CFEqual((CFTypeRef)mediaType, CFSTR("vide"));
}
static id
dev_empty_array(id self, SEL sel)
{
	(void)self; (void)sel;
	return ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSArray"), sel_registerName("array"));
}
static id
dev_self_array(id self, SEL sel)
{
	(void)sel;
	return ((id (*)(Class, SEL, id))objc_msgSend)(objc_getClass("NSArray"), sel_registerName("arrayWithObject:"), self);
}
static id
dev_forward_target(id self, SEL sel, SEL aSelector)
{
	(void)self; (void)sel; (void)aSelector;
	return nil;
}

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

static id
 fake_device_array(void)
{
	ensure_fake_devices();
	id objs[2] = { g_back_dev, g_front_dev };
	if (objs[0] == nil) {
		return ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSArray"), sel_registerName("array"));
	}
	return ((id (*)(Class, SEL, const id *, unsigned long))objc_msgSend)(
	    objc_getClass("NSArray"), sel_registerName("arrayWithObjects:count:"), objs, 2);
}

static id
hook_default_device_3(id self, SEL sel, id devType, id mediaType, long pos)
{
	(void)self; (void)sel; (void)devType; (void)mediaType;
	ensure_fake_devices();
	return pos == 2 ? g_front_dev : g_back_dev;
}

static id
hook_default_device_1(id self, SEL sel, id mediaType)
{
	(void)self; (void)sel; (void)mediaType;
	ensure_fake_devices();
	return g_back_dev;
}

static id
hook_devices(id self, SEL sel)
{
	(void)self; (void)sel;
	return fake_device_array();
}

static long
hook_auth_status(id self, SEL sel, id mediaType)
{
	(void)self; (void)sel; (void)mediaType;
	return 3; /* AVAuthorizationStatusAuthorized */
}

static void
hook_request_access(id self, SEL sel, id mediaType, void (^handler)(BOOL granted))
{
	(void)self; (void)sel; (void)mediaType;
	if (handler) handler(YES);
}

static id
hook_discovery_devices(id self, SEL sel)
{
	(void)self; (void)sel;
	return fake_device_array();
}

/* ================================================================== Stock Camera.app Native Overlay */
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
cam_overlay_lens_changed(id self, SEL sel, id sender)
{
	(void)self; (void)sel;
	static const int modes[] = { 1, 12, 4, 13, 11 };
	long idx = ((long (*)(id, SEL))objc_msgSend)(sender, sel_registerName("selectedSegmentIndex"));
	if (idx >= 0 && idx < 5) {
		start_camd_mode(modes[idx]);
	}
}

static void
cam_overlay_res_changed(id self, SEL sel, id sender)
{
	(void)self; (void)sel;
	long idx = ((long (*)(id, SEL))objc_msgSend)(sender, sel_registerName("selectedSegmentIndex"));
	if (idx >= 0 && idx <= 2) {
		g_cam_res_mode = (int)idx;
	}
}

static void
cam_overlay_tap_focus(id self, SEL sel, id recognizer)
{
	(void)self; (void)sel;
	if (g_cam_img_view == nil) return;
	CGPoint pt = ((CGPoint (*)(id, SEL, id))objc_msgSend)(recognizer, sel_registerName("locationInView:"), g_cam_img_view);
	CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(g_cam_img_view, sel_registerName("bounds"));
	if (b.size.width < 1 || b.size.height < 1) return;
	float nx = (float)(pt.x / b.size.width);
	float ny = (float)(pt.y / b.size.height);
	nx = nx < 0 ? 0 : (nx > 1 ? 1 : nx);
	ny = ny < 0 ? 0 : (ny > 1 ? 1 : ny);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char cmd[64], rep[128];
		snprintf(cmd, sizeof(cmd), "METER %.3f,%.3f\n", nx, ny);
		camd_cmd(cmd, rep, sizeof(rep), 2000);
	});
}

static void
cam_overlay_shutter(id self, SEL sel, id sender)
{
	(void)self; (void)sel; (void)sender;
	if (g_cam_shutter_btn != nil) {
		((void (*)(id, SEL, BOOL))objc_msgSend)(g_cam_shutter_btn, sel_registerName("setEnabled:"), NO);
		((void (*)(id, SEL, CGFloat))objc_msgSend)(g_cam_shutter_btn, sel_registerName("setAlpha:"), 0.4);
	}
	if (g_cam_hud_label != nil) {
		((void (*)(id, SEL, id))objc_msgSend)(g_cam_hud_label, sel_registerName("setText:"), (id)CFSTR("Capturing still…"));
	}
	const char *cmd = (g_cam_res_mode == 1) ? "CAPTURE 108 nodng\n" :
	                  (g_cam_res_mode == 2) ? "CAPTURE 12 dng\n" : "CAPTURE 12 nodng\n";
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char rep[512];
		camd_cmd(cmd, rep, sizeof(rep), 25000);
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
		if (jpg[0] != '\0') {
			CFStringRef pathStr = CFStringCreateWithCString(NULL, jpg, kCFStringEncodingUTF8);
			if (pathStr) {
				id img = ((id (*)(Class, SEL, id))objc_msgSend)(
				    objc_getClass("UIImage"), sel_registerName("imageWithContentsOfFile:"), (id)pathStr);
				if (img != nil) {
					void (*saveFn)(id, id, SEL, void *) = (void (*)(id, id, SEL, void *))dlsym(
					    RTLD_DEFAULT, "UIImageWriteToSavedPhotosAlbum");
					if (saveFn) saveFn(img, nil, NULL, NULL);
				}
				CFRelease(pathStr);
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (g_cam_shutter_btn != nil) {
				((void (*)(id, SEL, BOOL))objc_msgSend)(g_cam_shutter_btn, sel_registerName("setEnabled:"), YES);
				((void (*)(id, SEL, CGFloat))objc_msgSend)(g_cam_shutter_btn, sel_registerName("setAlpha:"), 1.0);
			}
			if (g_cam_hud_label != nil) {
				char msg[300];
				snprintf(msg, sizeof(msg), "%s", jpg[0] ? jpg : (rep[0] ? rep : "Capture timeout"));
				CFStringRef cfs = CFStringCreateWithCString(NULL, msg, kCFStringEncodingUTF8);
				if (cfs) {
					((void (*)(id, SEL, id))objc_msgSend)(g_cam_hud_label, sel_registerName("setText:"), (id)cfs);
					CFRelease(cfs);
				}
			}
		});
	});
}

static void
attach_stock_camera_ui_if_needed(void)
{
	if (g_cam_img_view != nil) return;
	Class appCls = objc_getClass("UIApplication");
	if (appCls == Nil) return;
	id app = ((id (*)(Class, SEL))objc_msgSend)(appCls, sel_registerName("sharedApplication"));
	if (app == nil) return;

	/* Find key/first window */
	id win = nil;
	id scenes = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("connectedScenes"));
	id enumerator = ((id (*)(id, SEL))objc_msgSend)(scenes, sel_registerName("objectEnumerator"));
	id scene = nil;
	while ((scene = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel_registerName("nextObject"))) != nil) {
		if (class_getInstanceMethod(object_getClass(scene), sel_registerName("windows")) != NULL) {
			id wins = ((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("windows"));
			if (((unsigned long (*)(id, SEL))objc_msgSend)(wins, sel_registerName("count")) > 0) {
				win = ((id (*)(id, SEL, unsigned long))objc_msgSend)(wins, sel_registerName("objectAtIndex:"), 0);
				break;
			}
		}
	}
	if (win == nil && class_getInstanceMethod(object_getClass(app), sel_registerName("windows")) != NULL) {
		id wins = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
		if (((unsigned long (*)(id, SEL))objc_msgSend)(wins, sel_registerName("count")) > 0) {
			win = ((id (*)(id, SEL, unsigned long))objc_msgSend)(wins, sel_registerName("objectAtIndex:"), 0);
		}
	}
	if (win == nil) return;

	CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(win, sel_registerName("bounds"));
	if (bounds.size.width < 100 || bounds.size.height < 100) return;

	/* Register target helper class */
	Class targetCls = objc_getClass("SapphireCamOverlayTarget");
	if (targetCls == Nil) {
		targetCls = objc_allocateClassPair(objc_getClass("NSObject"), "SapphireCamOverlayTarget", 0);
		class_addMethod(targetCls, sel_registerName("lensChanged:"), (IMP)cam_overlay_lens_changed, "v@:@");
		class_addMethod(targetCls, sel_registerName("resChanged:"), (IMP)cam_overlay_res_changed, "v@:@");
		class_addMethod(targetCls, sel_registerName("tapFocus:"), (IMP)cam_overlay_tap_focus, "v@:@");
		class_addMethod(targetCls, sel_registerName("shutterTapped:"), (IMP)cam_overlay_shutter, "v@:@");
		objc_registerClassPair(targetCls);
	}
	static id targetObj = nil;
	if (targetObj == nil) targetObj = ((id (*)(Class, SEL))objc_msgSend)(targetCls, sel_registerName("new"));

	Class viewCls = objc_getClass("UIView");
	Class ivCls = objc_getClass("UIImageView");
	Class lblCls = objc_getClass("UILabel");
	Class segCls = objc_getClass("UISegmentedControl");
	Class btnCls = objc_getClass("UIButton");
	Class colCls = objc_getClass("UIColor");
	Class tapCls = objc_getClass("UITapGestureRecognizer");

	id root = ((id (*)(id, SEL, CGRect))objc_msgSend)(
	    ((id (*)(Class, SEL))objc_msgSend)(viewCls, sel_registerName("alloc")),
	    sel_registerName("initWithFrame:"), bounds);
	id black = ((id (*)(Class, SEL))objc_msgSend)(colCls, sel_registerName("blackColor"));
	id white = ((id (*)(Class, SEL))objc_msgSend)(colCls, sel_registerName("whiteColor"));
	((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("setBackgroundColor:"), black);

	/* Preview ImageView */
	CGRect pvRect = CGRectMake(0, 84, bounds.size.width, bounds.size.height - 260);
	g_cam_img_view = ((id (*)(id, SEL, CGRect))objc_msgSend)(
	    ((id (*)(Class, SEL))objc_msgSend)(ivCls, sel_registerName("alloc")),
	    sel_registerName("initWithFrame:"), pvRect);
	((void (*)(id, SEL, long))objc_msgSend)(g_cam_img_view, sel_registerName("setContentMode:"), 1); /* ScaleAspectFit */
	((void (*)(id, SEL, BOOL))objc_msgSend)(g_cam_img_view, sel_registerName("setUserInteractionEnabled:"), YES);
	id tap = ((id (*)(id, SEL, id, SEL))objc_msgSend)(
	    ((id (*)(Class, SEL))objc_msgSend)(tapCls, sel_registerName("alloc")),
	    sel_registerName("initWithTarget:action:"), targetObj, sel_registerName("tapFocus:"));
	((void (*)(id, SEL, id))objc_msgSend)(g_cam_img_view, sel_registerName("addGestureRecognizer:"), tap);
	((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSubview:"), g_cam_img_view);

	/* HUD Label */
	g_cam_hud_label = ((id (*)(id, SEL, CGRect))objc_msgSend)(
	    ((id (*)(Class, SEL))objc_msgSend)(lblCls, sel_registerName("alloc")),
	    sel_registerName("initWithFrame:"), CGRectMake(12, 48, bounds.size.width - 24, 30));
	((void (*)(id, SEL, id))objc_msgSend)(g_cam_hud_label, sel_registerName("setTextColor:"), white);
	((void (*)(id, SEL, long))objc_msgSend)(g_cam_hud_label, sel_registerName("setTextAlignment:"), 1);
	((void (*)(id, SEL, id))objc_msgSend)(g_cam_hud_label, sel_registerName("setText:"), (id)CFSTR("Sapphire Camera (camd)"));
	((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSubview:"), g_cam_hud_label);

	/* Lens SegmentedControl */
	id lensItems[5] = { (id)CFSTR("1x"), (id)CFSTR("0.6x UW"), (id)CFSTR("2x"), (id)CFSTR("Macro"), (id)CFSTR("Front") };
	id lensArr = ((id (*)(Class, SEL, const id *, unsigned long))objc_msgSend)(
	    objc_getClass("NSArray"), sel_registerName("arrayWithObjects:count:"), lensItems, 5);
	id lensSeg = ((id (*)(id, SEL, id))objc_msgSend)(
	    ((id (*)(Class, SEL))objc_msgSend)(segCls, sel_registerName("alloc")),
	    sel_registerName("initWithItems:"), lensArr);
	((void (*)(id, SEL, CGRect))objc_msgSend)(lensSeg, sel_registerName("setFrame:"),
	    CGRectMake(16, bounds.size.height - 168, bounds.size.width - 32, 34));
	((void (*)(id, SEL, long))objc_msgSend)(lensSeg, sel_registerName("setSelectedSegmentIndex:"), 0);
	((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(
	    lensSeg, sel_registerName("addTarget:action:forControlEvents:"),
	    targetObj, sel_registerName("lensChanged:"), 1UL << 12);
	((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSubview:"), lensSeg);

	/* Resolution SegmentedControl */
	id resItems[3] = { (id)CFSTR("12 MP"), (id)CFSTR("108 MP"), (id)CFSTR("12MP+DNG") };
	id resArr = ((id (*)(Class, SEL, const id *, unsigned long))objc_msgSend)(
	    objc_getClass("NSArray"), sel_registerName("arrayWithObjects:count:"), resItems, 3);
	id resSeg = ((id (*)(id, SEL, id))objc_msgSend)(
	    ((id (*)(Class, SEL))objc_msgSend)(segCls, sel_registerName("alloc")),
	    sel_registerName("initWithItems:"), resArr);
	((void (*)(id, SEL, CGRect))objc_msgSend)(resSeg, sel_registerName("setFrame:"),
	    CGRectMake(40, bounds.size.height - 126, bounds.size.width - 80, 30));
	((void (*)(id, SEL, long))objc_msgSend)(resSeg, sel_registerName("setSelectedSegmentIndex:"), 0);
	((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(
	    resSeg, sel_registerName("addTarget:action:forControlEvents:"),
	    targetObj, sel_registerName("resChanged:"), 1UL << 12);
	((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSubview:"), resSeg);

	/* Shutter Button */
	g_cam_shutter_btn = ((id (*)(Class, SEL, long))objc_msgSend)(btnCls, sel_registerName("buttonWithType:"), 0);
	((void (*)(id, SEL, CGRect))objc_msgSend)(g_cam_shutter_btn, sel_registerName("setFrame:"),
	    CGRectMake((bounds.size.width - 70) / 2.0, bounds.size.height - 86, 70, 70));
	((void (*)(id, SEL, id))objc_msgSend)(g_cam_shutter_btn, sel_registerName("setBackgroundColor:"), white);
	id layer = ((id (*)(id, SEL))objc_msgSend)(g_cam_shutter_btn, sel_registerName("layer"));
	((void (*)(id, SEL, CGFloat))objc_msgSend)(layer, sel_registerName("setCornerRadius:"), 35.0);
	((void (*)(id, SEL, id, SEL, unsigned long))objc_msgSend)(
	    g_cam_shutter_btn, sel_registerName("addTarget:action:forControlEvents:"),
	    targetObj, sel_registerName("shutterTapped:"), 1UL << 6);
	((void (*)(id, SEL, id))objc_msgSend)(root, sel_registerName("addSubview:"), g_cam_shutter_btn);

	((void (*)(id, SEL, id))objc_msgSend)(win, sel_registerName("addSubview:"), root);
	((void (*)(id, SEL, id))objc_msgSend)(win, sel_registerName("bringSubviewToFront:"), root);

	start_camd_mode(1);
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

static BOOL
hook_session_can_add(id self, SEL sel, id obj)
{
	(void)self; (void)sel; (void)obj;
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

static void
hook_session_start(id self, SEL sel)
{
	(void)self; (void)sel;
	start_camd_mode(g_mode);
}

static void
hook_session_stop(id self, SEL sel)
{
	(void)self; (void)sel;
	g_running = false;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		char rep[64];
		camd_cmd("STOP\n", rep, sizeof(rep), 1500);
	});
}

static BOOL
hook_session_is_running(id self, SEL sel)
{
	(void)self; (void)sel;
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

	/* Hook AVCaptureDevice class methods so apps never hang on FigCaptureSourceRemoteCopyCaptureSources */
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

	/* If loaded inside Apple's stock Camera.app (com.apple.camera), attach native camd UI overlay */
	CFBundleRef mainBundle = CFBundleGetMainBundle();
	CFStringRef bundleID = mainBundle ? CFBundleGetIdentifier(mainBundle) : NULL;
	if (bundleID != NULL && CFEqual(bundleID, CFSTR("com.apple.camera"))) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			attach_stock_camera_ui_if_needed();
		});
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			attach_stock_camera_ui_if_needed();
		});
	}
}
