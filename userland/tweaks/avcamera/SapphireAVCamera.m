/*
 * SapphireAVCamera.dylib: AVFoundation client-side virtual camera bridge for third-party
 * iOS apps (Zalo, Messenger, Telegram, banking VietQR scanners, Safari WebKit.GPU, etc.).
 *
 * Connects directly to /var/run/camd.sock (mode 0666, no MAC sandbox block on sapphire)
 * and /var/tmp/camd-preview.bin, providing:
 *   - Virtual Back & Front AVCaptureDevice + AVCaptureDeviceDiscoverySession + permissions
 *   - Virtual AVCaptureDeviceInput & AVCaptureSession lifecycle (bypassing _figCaptureSource)
 *   - Zero-copy IOSurface AVCaptureVideoPreviewLayer (preserving app overlay sublayers/masks)
 *   - AVCaptureVideoDataOutput with BOTH 32BGRA (zero-copy IOSurface) AND NV12 (420f/420v)
 *     for WebRTC / MLKit / ZXing / VietQR scanners
 *   - AVCaptureMetadataOutput using Vision VNDetectBarcodesRequest (~6 Hz) + transformedMetadataObject
 *   - AVCapturePhotoOutput via camd CAPTURE 12 nodng
 *
 * Explicitly skips com.apple.camera (handled by SapphireNoCamera.dylib).
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

#include "../../camera/camd/camd_proto.h"

/* ============================================================================
 * Helpers: BGRA -> NV12 conversion (BT.601 full/video range)
 * ============================================================================ */
static void
bgra_to_nv12(const uint8_t *bgra, uint32_t srcStride, uint32_t w, uint32_t h,
             uint8_t *yPlane, size_t yStride, uint8_t *uvPlane, size_t uvStride)
{
	for (uint32_t y = 0; y < h; y++) {
		const uint8_t *src = bgra + (size_t)y * srcStride;
		uint8_t *yd = yPlane + (size_t)y * yStride;
		uint8_t *uvd = ((y & 1) == 0) ? (uvPlane + (size_t)(y >> 1) * uvStride) : NULL;
		for (uint32_t x = 0; x < w; x++) {
			int b = src[x * 4 + 0];
			int g = src[x * 4 + 1];
			int r = src[x * 4 + 2];
			int luma = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
			yd[x] = (uint8_t)(luma < 0 ? 0 : luma > 255 ? 255 : luma);
			if (uvd != NULL && (x & 1) == 0) {
				int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
				int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
				uvd[x + 0] = (uint8_t)(u < 0 ? 0 : u > 255 ? 255 : u);
				uvd[x + 1] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
			}
		}
	}
}

/* ============================================================================
 * Virtual AVCaptureDeviceFormat / FrameRateRange / CaptureDevice / Input / Connection
 * ============================================================================ */
@interface SapphireVirtualFrameRateRange : NSObject
@property (nonatomic, assign) Float64 minFrameRate;
@property (nonatomic, assign) Float64 maxFrameRate;
@property (nonatomic, assign) CMTime minFrameDuration;
@property (nonatomic, assign) CMTime maxFrameDuration;
@end

@implementation SapphireVirtualFrameRateRange
- (instancetype)init {
	if ((self = [super init])) {
		_minFrameRate = 15.0;
		_maxFrameRate = 30.0;
		_minFrameDuration = CMTimeMake(1, 30);
		_maxFrameDuration = CMTimeMake(1, 15);
	}
	return self;
}
@end

@interface SapphireVirtualCaptureFormat : NSObject {
	CMVideoFormatDescriptionRef _desc;
}
@property (nonatomic, readonly) CMFormatDescriptionRef formatDescription;
@property (nonatomic, readonly) NSArray *videoSupportedFrameRateRanges;
@property (nonatomic, readonly) NSString *mediaType;
@property (nonatomic, readonly) CGFloat videoMaxZoomFactor;
@end

@implementation SapphireVirtualCaptureFormat
- (instancetype)initWithWidth:(int32_t)w height:(int32_t)h {
	if ((self = [super init])) {
		CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_32BGRA, w, h, NULL, &_desc);
		_videoSupportedFrameRateRanges = @[ [[SapphireVirtualFrameRateRange alloc] init] ];
		_mediaType = AVMediaTypeVideo;
		_videoMaxZoomFactor = 4.0;
	}
	return self;
}
- (CMFormatDescriptionRef)formatDescription { return _desc; }
- (void)dealloc {
	if (_desc) CFRelease(_desc);
}
@end

@interface SapphireVirtualCaptureDevice : NSObject
@property (nonatomic, copy) NSString *uniqueID;
@property (nonatomic, copy) NSString *localizedName;
@property (nonatomic, copy) NSString *modelID;
@property (nonatomic, assign) AVCaptureDevicePosition position;
@property (nonatomic, copy) AVCaptureDeviceType deviceType;
@property (nonatomic, assign) int camIndex;
@property (nonatomic, strong) SapphireVirtualCaptureFormat *activeFormat;
@property (nonatomic, strong) NSArray *formats;
@property (nonatomic, assign) CMTime activeVideoMinFrameDuration;
@property (nonatomic, assign) CMTime activeVideoMaxFrameDuration;
@property (nonatomic, assign) CGFloat videoZoomFactor;
@property (nonatomic, assign) AVCaptureFocusMode focusMode;
@property (nonatomic, assign) AVCaptureExposureMode exposureMode;
@property (nonatomic, assign) AVCaptureWhiteBalanceMode whiteBalanceMode;
@property (nonatomic, assign) AVCaptureTorchMode torchMode;
@property (nonatomic, assign) AVCaptureFlashMode flashMode;
@end

@implementation SapphireVirtualCaptureDevice
- (instancetype)initWithPosition:(AVCaptureDevicePosition)pos {
	if ((self = [super init])) {
		_position = pos;
		_camIndex = (pos == AVCaptureDevicePositionFront) ? 1 : 0;
		_uniqueID = (pos == AVCaptureDevicePositionFront) ? @"com.sapphire.cam.front" : @"com.sapphire.cam.back";
		_localizedName = (pos == AVCaptureDevicePositionFront) ? @"Front Camera" : @"Back Camera";
		_modelID = @"SapphireCamera";
		_deviceType = AVCaptureDeviceTypeBuiltInWideAngleCamera;
		_activeFormat = [[SapphireVirtualCaptureFormat alloc] initWithWidth:900 height:1200];
		_formats = @[ _activeFormat ];
		_activeVideoMinFrameDuration = CMTimeMake(1, 30);
		_activeVideoMaxFrameDuration = CMTimeMake(1, 15);
		_videoZoomFactor = 1.0;
		_focusMode = AVCaptureFocusModeContinuousAutoFocus;
		_exposureMode = AVCaptureExposureModeContinuousAutoExposure;
		_whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
	}
	return self;
}
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)hasMediaType:(AVMediaType)mediaType { return [mediaType isEqualToString:AVMediaTypeVideo]; }
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { (void)preset; return YES; }
- (BOOL)lockForConfiguration:(NSError **)outError { if (outError) *outError = nil; return YES; }
- (void)unlockForConfiguration {}
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)m { (void)m; return YES; }
- (BOOL)isFocusPointOfInterestSupported { return YES; }
- (void)setFocusPointOfInterest:(CGPoint)p { (void)p; }
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)m { (void)m; return YES; }
- (BOOL)isExposurePointOfInterestSupported { return YES; }
- (void)setExposurePointOfInterest:(CGPoint)p { (void)p; }
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)m { (void)m; return YES; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isFlashAvailable { return NO; }
- (BOOL)hasTorch { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)m { return m == AVCaptureTorchModeOff; }
- (BOOL)isLowLightBoostSupported { return NO; }
- (BOOL)isSmoothAutoFocusSupported { return NO; }
- (BOOL)isAutoFocusRangeRestrictionSupported { return NO; }
- (void)setAutoFocusRangeRestriction:(AVCaptureAutoFocusRangeRestriction)r { (void)r; }
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)e { (void)e; }
- (BOOL)isSubjectAreaChangeMonitoringEnabled { return NO; }
- (BOOL)isKindOfClass:(Class)aClass {
	if (aClass == [AVCaptureDevice class]) return YES;
	return [super isKindOfClass:aClass];
}
@end

static SapphireVirtualCaptureDevice *
get_virtual_device(AVCaptureDevicePosition pos)
{
	static SapphireVirtualCaptureDevice *backDev, *frontDev;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		backDev = [[SapphireVirtualCaptureDevice alloc] initWithPosition:AVCaptureDevicePositionBack];
		frontDev = [[SapphireVirtualCaptureDevice alloc] initWithPosition:AVCaptureDevicePositionFront];
	});
	return (pos == AVCaptureDevicePositionFront) ? frontDev : backDev;
}

@interface SapphireVirtualCaptureInputPort : NSObject
@property (nonatomic, weak) id input;
@property (nonatomic, copy) AVMediaType mediaType;
@property (nonatomic, assign) BOOL enabled;
@end
@implementation SapphireVirtualCaptureInputPort
- (instancetype)initWithInput:(id)inp {
	if ((self = [super init])) {
		_input = inp;
		_mediaType = AVMediaTypeVideo;
		_enabled = YES;
	}
	return self;
}
@end

@interface SapphireVirtualCaptureInput : NSObject
@property (nonatomic, strong) SapphireVirtualCaptureDevice *device;
@property (nonatomic, strong) NSArray *ports;
@end
@implementation SapphireVirtualCaptureInput
- (instancetype)initWithDevice:(SapphireVirtualCaptureDevice *)dev {
	if ((self = [super init])) {
		_device = dev;
		_ports = @[ [[SapphireVirtualCaptureInputPort alloc] initWithInput:self] ];
	}
	return self;
}
- (BOOL)isKindOfClass:(Class)aClass {
	if (aClass == [AVCaptureDeviceInput class] || aClass == [AVCaptureInput class]) return YES;
	return [super isKindOfClass:aClass];
}
@end

@interface SapphireVirtualCaptureConnection : NSObject
@property (nonatomic, strong) NSArray *inputPorts;
@property (nonatomic, weak) AVCaptureOutput *output;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign, getter=isActive) BOOL active;
@property (nonatomic, assign) AVCaptureVideoOrientation videoOrientation;
@property (nonatomic, assign, getter=isVideoMirrored) BOOL videoMirrored;
@property (nonatomic, assign) BOOL automaticallyAdjustsVideoMirroring;
@property (nonatomic, assign) AVCaptureVideoStabilizationMode preferredVideoStabilizationMode;
@end
@implementation SapphireVirtualCaptureConnection
- (instancetype)initWithOutput:(AVCaptureOutput *)outp ports:(NSArray *)ports {
	if ((self = [super init])) {
		_output = outp;
		_inputPorts = ports ?: @[];
		_enabled = YES;
		_active = YES;
		_videoOrientation = AVCaptureVideoOrientationPortrait;
		_automaticallyAdjustsVideoMirroring = YES;
	}
	return self;
}
- (BOOL)isVideoOrientationSupported { return YES; }
- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoStabilizationSupported { return NO; }
- (BOOL)isKindOfClass:(Class)aClass {
	if (aClass == [AVCaptureConnection class]) return YES;
	return [super isKindOfClass:aClass];
}
@end

@interface SapphireVirtualMetadataCodeObject : NSObject
@property (nonatomic, copy) AVMetadataObjectType type;
@property (nonatomic, copy) NSString *stringValue;
@property (nonatomic, assign) CGRect bounds;
@property (nonatomic, strong) NSArray<NSDictionary *> *corners;
@property (nonatomic, assign) CMTime time;
@property (nonatomic, assign) CMTime duration;
@end
@implementation SapphireVirtualMetadataCodeObject
- (BOOL)isKindOfClass:(Class)aClass {
	if (aClass == [AVMetadataMachineReadableCodeObject class] || aClass == [AVMetadataObject class]) return YES;
	return [super isKindOfClass:aClass];
}
@end

@interface SapphireVirtualCapturePhoto : NSObject
@property (nonatomic, strong) NSData *jpegData;
@property (nonatomic, strong) NSDictionary *metadata;
@property (nonatomic, assign) CMTime timestamp;
@end
@implementation SapphireVirtualCapturePhoto
- (NSData *)fileDataRepresentation { return _jpegData; }
- (NSData *)fileDataRepresentationWithCustomizer:(id)c { (void)c; return _jpegData; }
- (BOOL)isRawPhoto { return NO; }
- (BOOL)isKindOfClass:(Class)aClass {
	if (aClass == [AVCapturePhoto class]) return YES;
	return [super isKindOfClass:aClass];
}
@end

@interface SapphireVirtualDiscoverySession : NSObject
@property (nonatomic, strong) NSArray *devices;
@end
@implementation SapphireVirtualDiscoverySession
- (BOOL)isKindOfClass:(Class)aClass {
	if (aClass == [AVCaptureDeviceDiscoverySession class]) return YES;
	return [super isKindOfClass:aClass];
}
@end

/* ============================================================================
 * Virtual Session Engine (talks to /var/run/camd.sock + /var/tmp/camd-preview.bin)
 * ============================================================================ */
@interface SapphireAVSessionState : NSObject
@property (nonatomic, weak) AVCaptureSession *session;
@property (nonatomic, strong) NSMutableArray *vInputs;
@property (nonatomic, strong) NSMutableArray *vOutputs;
@property (nonatomic, strong) NSHashTable *previewLayers;
@property (nonatomic, strong) NSMapTable *connections; /* output -> SapphireVirtualCaptureConnection */
@property (nonatomic, copy) AVCaptureSessionPreset vPreset;
@property (nonatomic, assign) BOOL vRunning;
@property (nonatomic, assign) int sockFd;
@property (nonatomic, assign) int shmFd;
@property (nonatomic, assign) const CamdShm *shm;
@property (nonatomic, assign) size_t shmSize;
@property (nonatomic, assign) uint64_t lastSeq;
@property (nonatomic, assign) uint32_t frameCounter;
@property (nonatomic, strong) dispatch_queue_t workQ;
@property (nonatomic, strong) dispatch_source_t timer;
@end

static const void *kSessionStateKey = &kSessionStateKey;
static const void *kPreviewLayerSessionKey = &kPreviewLayerSessionKey;
static const void *kPreviewLayerChildKey = &kPreviewLayerChildKey;

static SapphireAVSessionState *
session_state(AVCaptureSession *s, BOOL create)
{
	SapphireAVSessionState *st = objc_getAssociatedObject(s, kSessionStateKey);
	if (!st && create) {
		st = [[SapphireAVSessionState alloc] init];
		st.session = s;
		st.vInputs = [NSMutableArray array];
		st.vOutputs = [NSMutableArray array];
		st.previewLayers = [NSHashTable weakObjectsHashTable];
		st.connections = [NSMapTable weakToStrongObjectsMapTable];
		st.vPreset = AVCaptureSessionPresetHigh;
		st.sockFd = -1;
		st.shmFd = -1;
		st.workQ = dispatch_queue_create("com.sapphire.avcamera.work", DISPATCH_QUEUE_SERIAL);
		objc_setAssociatedObject(s, kSessionStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return st;
}

static int
camd_connect_and_cmd(const char *cmd, char *reply, size_t rsz)
{
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return -1;
	struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", CAMD_SOCK_PATH);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
		close(fd);
		return -1;
	}
	if (cmd != NULL) {
		size_t len = strlen(cmd);
		if (write(fd, cmd, len) != (ssize_t)len) {
			close(fd);
			return -1;
		}
		if (reply != NULL && rsz > 1) {
			ssize_t n = read(fd, reply, rsz - 1);
			if (n > 0) {
				reply[n] = '\0';
			} else {
				reply[0] = '\0';
			}
		}
	}
	return fd;
}

static NSString *
map_video_gravity(AVLayerVideoGravity g)
{
	if ([g isEqualToString:AVLayerVideoGravityResizeAspect]) return kCAGravityResizeAspect;
	if ([g isEqualToString:AVLayerVideoGravityResize]) return kCAGravityResize;
	return kCAGravityResizeAspectFill;
}

static AVMetadataObjectType
vision_symbology_to_av(VNBarcodeSymbology sym)
{
	if ([sym isEqualToString:VNBarcodeSymbologyQR]) return AVMetadataObjectTypeQRCode;
	if ([sym isEqualToString:VNBarcodeSymbologyEAN13]) return AVMetadataObjectTypeEAN13Code;
	if ([sym isEqualToString:VNBarcodeSymbologyEAN8]) return AVMetadataObjectTypeEAN8Code;
	if ([sym isEqualToString:VNBarcodeSymbologyCode128]) return AVMetadataObjectTypeCode128Code;
	if ([sym isEqualToString:VNBarcodeSymbologyCode39]) return AVMetadataObjectTypeCode39Code;
	if ([sym isEqualToString:VNBarcodeSymbologyPDF417]) return AVMetadataObjectTypePDF417Code;
	if ([sym isEqualToString:VNBarcodeSymbologyAztec]) return AVMetadataObjectTypeAztecCode;
	if ([sym isEqualToString:VNBarcodeSymbologyDataMatrix]) return AVMetadataObjectTypeDataMatrixCode;
	return AVMetadataObjectTypeQRCode;
}

@implementation SapphireAVSessionState

- (void)openShmIfNeeded {
	if (self.shm != NULL) return;
	int fd = open(CAMD_SHM_PATH, O_RDONLY);
	if (fd < 0) return;
	struct stat st;
	if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(CamdShm)) {
		close(fd);
		return;
	}
	void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		close(fd);
		return;
	}
	const CamdShm *hdr = (const CamdShm *)p;
	if (hdr->magic != CAMD_SHM_MAGIC) {
		munmap(p, (size_t)st.st_size);
		close(fd);
		return;
	}
	self.shmFd = fd;
	self.shm = hdr;
	self.shmSize = (size_t)st.st_size;
}

- (void)startEngine {
	if (self.vRunning) return;
	self.vRunning = YES;
	__weak typeof(self) weakSelf = self;
	dispatch_async(self.workQ, ^{
		__strong typeof(weakSelf) s = weakSelf;
		if (!s || !s.vRunning) return;
		char reply[256] = "";
		if (s.sockFd < 0) {
			s.sockFd = camd_connect_and_cmd("START\n", reply, sizeof(reply));
		}
		[s openShmIfNeeded];
		s.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, s.workQ);
		dispatch_source_set_timer(s.timer, dispatch_time(DISPATCH_TIME_NOW, 0), 33 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
		dispatch_source_set_event_handler(s.timer, ^{
			[weakSelf tickFrame];
		});
		dispatch_resume(s.timer);
	});
}

- (void)stopEngine {
	if (!self.vRunning) return;
	self.vRunning = NO;
	dispatch_async(self.workQ, ^{
		if (self.timer) {
			dispatch_source_cancel(self.timer);
			self.timer = nil;
		}
		if (self.sockFd >= 0) {
			close(self.sockFd);
			self.sockFd = -1;
		}
		if (self.shm != NULL) {
			munmap((void *)self.shm, self.shmSize);
			self.shm = NULL;
			self.shmSize = 0;
		}
		if (self.shmFd >= 0) {
			close(self.shmFd);
			self.shmFd = -1;
		}
	});
}

- (void)tickFrame {
	if (!self.vRunning) return;
	if (self.shm == NULL) {
		[self openShmIfNeeded];
		if (self.shm == NULL) return;
	}
	uint64_t seq = self.shm->seq;
	if (seq == 0 || seq == self.lastSeq) return;
	uint32_t slot = self.shm->latest;
	if (slot >= CAMD_SHM_SLOTS) return;
	self.lastSeq = seq;
	self.frameCounter++;

	const CamdSlot *cs = &self.shm->slot[slot];
	uint32_t w = cs->width, h = cs->height, stride = cs->stride;
	if (w == 0 || h == 0 || stride < w * 4) return;

	uint32_t surfId = self.shm->reserved[slot];
	IOSurfaceRef surf = (surfId != 0) ? IOSurfaceLookup(surfId) : NULL;
	const uint8_t *shmPixels = (const uint8_t *)self.shm + self.shm->header_size + (size_t)slot * self.shm->slot_size;

	/* 1. Update all attached AVCaptureVideoPreviewLayers on main thread */
	NSArray *layers = self.previewLayers.allObjects;
	if (layers.count > 0) {
		id layerContent = nil;
		CGImageRef cgImg = NULL;
		if (surf != NULL) {
			CFRetain(surf);
			layerContent = (__bridge id)surf;
		} else {
			NSData *copyData = [NSData dataWithBytes:shmPixels length:(size_t)stride * h];
			CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)copyData);
			CGColorSpaceRef csRef = CGColorSpaceCreateDeviceRGB();
			if (prov && csRef) {
				cgImg = CGImageCreate(w, h, 8, 32, stride, csRef,
				    kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, prov, NULL, false, kCGRenderingIntentDefault);
				layerContent = (__bridge id)cgImg;
			}
			if (prov) CGDataProviderRelease(prov);
			if (csRef) CGColorSpaceRelease(csRef);
		}
		if (layerContent != nil) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[CATransaction begin];
				[CATransaction setDisableActions:YES];
				for (AVCaptureVideoPreviewLayer *pl in layers) {
					CALayer *child = objc_getAssociatedObject(pl, kPreviewLayerChildKey);
					if (!child) {
						child = [CALayer layer];
						child.frame = pl.bounds;
						child.masksToBounds = YES;
						[pl insertSublayer:child atIndex:0];
						objc_setAssociatedObject(pl, kPreviewLayerChildKey, child, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
					}
					child.frame = pl.bounds;
					child.contentsGravity = map_video_gravity(pl.videoGravity);
					child.contents = layerContent;
				}
				[CATransaction commit];
				if (surf != NULL) CFRelease(surf);
				if (cgImg != NULL) CGImageRelease(cgImg);
			});
		}
	}

	/* 2. Deliver CMSampleBuffer to AVCaptureVideoDataOutput */
	NSArray *outputs = [self.vOutputs copy];
	BOOL needVision = NO;
	NSMutableArray<AVCaptureMetadataOutput *> *metaOutputs = nil;
	for (AVCaptureOutput *outp in outputs) {
		if ([outp isKindOfClass:[AVCaptureMetadataOutput class]]) {
			AVCaptureMetadataOutput *mo = (AVCaptureMetadataOutput *)outp;
			if (mo.metadataObjectsDelegate != nil && (self.frameCounter % 5) == 0) {
				needVision = YES;
				if (!metaOutputs) metaOutputs = [NSMutableArray array];
				[metaOutputs addObject:mo];
			}
			continue;
		}
		if (![outp isKindOfClass:[AVCaptureVideoDataOutput class]]) continue;
		AVCaptureVideoDataOutput *vdo = (AVCaptureVideoDataOutput *)outp;
		id<AVCaptureVideoDataOutputSampleBufferDelegate> del = vdo.sampleBufferDelegate;
		dispatch_queue_t q = vdo.sampleBufferCallbackQueue;
		if (!del || !q || ![del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) continue;

		OSType wantFmt = kCVPixelFormatType_32BGRA;
		NSNumber *fmtNum = vdo.videoSettings[(id)kCVPixelBufferPixelFormatTypeKey];
		if (fmtNum != nil) wantFmt = (OSType)[fmtNum unsignedIntValue];

		CVPixelBufferRef pb = NULL;
		if (wantFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
		    wantFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
			NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
			if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, wantFmt, (__bridge CFDictionaryRef)attrs, &pb) == kCVReturnSuccess) {
				CVPixelBufferLockBaseAddress(pb, 0);
				uint8_t *yP = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
				size_t yS = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
				uint8_t *uvP = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
				size_t uvS = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
				bgra_to_nv12(shmPixels, stride, w, h, yP, yS, uvP, uvS);
				CVPixelBufferUnlockBaseAddress(pb, 0);
			}
		} else {
			if (surf != NULL) {
				CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surf, NULL, &pb);
			} else {
				NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey : @{} };
				if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb) == kCVReturnSuccess) {
					CVPixelBufferLockBaseAddress(pb, 0);
					uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
					size_t dstS = CVPixelBufferGetBytesPerRow(pb);
					for (uint32_t r = 0; r < h; r++) {
						memcpy(dst + (size_t)r * dstS, shmPixels + (size_t)r * stride, (size_t)w * 4);
					}
					CVPixelBufferUnlockBaseAddress(pb, 0);
				}
			}
		}

		if (pb != NULL) {
			CMVideoFormatDescriptionRef fdesc = NULL;
			CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fdesc);
			CMSampleTimingInfo timing = {
				.duration = CMTimeMake(1, 30),
				.presentationTimeStamp = CMTimeMake((int64_t)(cs->ts_ns / 1000ULL), 1000000),
				.decodeTimeStamp = kCMTimeInvalid
			};
			CMSampleBufferRef sb = NULL;
			if (fdesc != NULL) {
				CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fdesc, &timing, &sb);
				CFRelease(fdesc);
			}
			CFRelease(pb);
			if (sb != NULL) {
				SapphireVirtualCaptureConnection *conn = [self.connections objectForKey:vdo];
				dispatch_async(q, ^{
					[del captureOutput:vdo didOutputSampleBuffer:sb fromConnection:(AVCaptureConnection *)conn];
					CFRelease(sb);
				});
			}
		}
	}

	/* 3. Vision Barcode/QR detection for AVCaptureMetadataOutput (~6 Hz) */
	if (needVision && metaOutputs.count > 0) {
		CVPixelBufferRef vpb = NULL;
		if (surf != NULL) {
			CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surf, NULL, &vpb);
		}
		if (vpb != NULL) {
			VNDetectBarcodesRequest *req = [[VNDetectBarcodesRequest alloc] init];
			VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:vpb options:@{}];
			NSError *err = nil;
			if ([handler performRequests:@[ req ] error:&err] && req.results.count > 0) {
				NSMutableArray *found = [NSMutableArray array];
				for (VNBarcodeObservation *obs in req.results) {
					if (!obs.payloadStringValue) continue;
					SapphireVirtualMetadataCodeObject *obj = [[SapphireVirtualMetadataCodeObject alloc] init];
					obj.type = vision_symbology_to_av(obs.symbology);
					obj.stringValue = obs.payloadStringValue;
					CGRect bb = obs.boundingBox;
					/* Vision origin is bottom-left; AVMetadata origin is top-left */
					obj.bounds = CGRectMake(bb.origin.x, 1.0 - bb.origin.y - bb.size.height, bb.size.width, bb.size.height);
					obj.time = CMTimeMake((int64_t)(cs->ts_ns / 1000ULL), 1000000);
					obj.duration = CMTimeMake(1, 6);
					[found addObject:obj];
				}
				if (found.count > 0) {
					for (AVCaptureMetadataOutput *mo in metaOutputs) {
						id<AVCaptureMetadataOutputObjectsDelegate> del = mo.metadataObjectsDelegate;
						dispatch_queue_t q = mo.metadataObjectsCallbackQueue ?: dispatch_get_main_queue();
						SapphireVirtualCaptureConnection *conn = [self.connections objectForKey:mo];
						if ([del respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) {
							dispatch_async(q, ^{
								[del captureOutput:mo didOutputMetadataObjects:found fromConnection:(AVCaptureConnection *)conn];
							});
						}
					}
				}
			}
			CFRelease(vpb);
		}
	}

	if (surf != NULL) {
		CFRelease(surf);
	}
}

- (void)dealloc {
	[self stopEngine];
}
@end

/* ============================================================================
 * Objective-C Method Swizzles
 * ============================================================================ */
static id (*orig_dev_devices)(id, SEL);
static id (*orig_dev_devicesWithMediaType)(id, SEL, AVMediaType);
static id (*orig_dev_defaultWithMediaType)(id, SEL, AVMediaType);
static id (*orig_dev_defaultWithType)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition);
static id (*orig_disc_session)(id, SEL, NSArray *, AVMediaType, AVCaptureDevicePosition);
static id (*orig_input_withDevice)(id, SEL, AVCaptureDevice *, NSError **);
static id (*orig_input_initWithDevice)(id, SEL, AVCaptureDevice *, NSError **);

static BOOL (*orig_sess_canAddInput)(id, SEL, AVCaptureInput *);
static void (*orig_sess_addInput)(id, SEL, AVCaptureInput *);
static void (*orig_sess_removeInput)(id, SEL, AVCaptureInput *);
static NSArray *(*orig_sess_inputs)(id, SEL);
static BOOL (*orig_sess_canAddOutput)(id, SEL, AVCaptureOutput *);
static void (*orig_sess_addOutput)(id, SEL, AVCaptureOutput *);
static void (*orig_sess_removeOutput)(id, SEL, AVCaptureOutput *);
static NSArray *(*orig_sess_outputs)(id, SEL);
static BOOL (*orig_sess_canSetPreset)(id, SEL, AVCaptureSessionPreset);
static void (*orig_sess_setPreset)(id, SEL, AVCaptureSessionPreset);
static void (*orig_sess_beginConfig)(id, SEL);
static void (*orig_sess_commitConfig)(id, SEL);
static void (*orig_sess_startRunning)(id, SEL);
static void (*orig_sess_stopRunning)(id, SEL);
static BOOL (*orig_sess_isRunning)(id, SEL);

static AVCaptureConnection *(*orig_out_connWithMediaType)(id, SEL, AVMediaType);
static void (*orig_photo_capture)(id, SEL, AVCapturePhotoSettings *, id<AVCapturePhotoCaptureDelegate>);
static void (*orig_pl_setSession)(id, SEL, AVCaptureSession *);
static AVCaptureSession *(*orig_pl_session)(id, SEL);
static void (*orig_pl_layout)(id, SEL);
static AVMetadataObject *(*orig_pl_transformMeta)(id, SEL, AVMetadataObject *);

static NSArray *hook_dev_devices(id self, SEL sel) {
	NSArray *r = orig_dev_devices ? orig_dev_devices(self, sel) : nil;
	if (r.count > 0) return r;
	return @[ get_virtual_device(AVCaptureDevicePositionBack), get_virtual_device(AVCaptureDevicePositionFront) ];
}

static NSArray *hook_dev_devicesWithMediaType(id self, SEL sel, AVMediaType mt) {
	if ([mt isEqualToString:AVMediaTypeVideo]) {
		return @[ get_virtual_device(AVCaptureDevicePositionBack), get_virtual_device(AVCaptureDevicePositionFront) ];
	}
	return orig_dev_devicesWithMediaType ? orig_dev_devicesWithMediaType(self, sel, mt) : @[];
}

static id hook_dev_defaultWithMediaType(id self, SEL sel, AVMediaType mt) {
	if ([mt isEqualToString:AVMediaTypeVideo]) {
		return get_virtual_device(AVCaptureDevicePositionBack);
	}
	return orig_dev_defaultWithMediaType ? orig_dev_defaultWithMediaType(self, sel, mt) : nil;
}

static id hook_dev_defaultWithType(id self, SEL sel, AVCaptureDeviceType dt, AVMediaType mt, AVCaptureDevicePosition pos) {
	if (!mt || [mt isEqualToString:AVMediaTypeVideo]) {
		return get_virtual_device(pos == AVCaptureDevicePositionFront ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack);
	}
	return orig_dev_defaultWithType ? orig_dev_defaultWithType(self, sel, dt, mt, pos) : nil;
}

static AVAuthorizationStatus hook_dev_authStatus(id self, SEL sel, AVMediaType mt) {
	(void)self; (void)sel; (void)mt;
	return AVAuthorizationStatusAuthorized;
}

static void hook_dev_requestAccess(id self, SEL sel, AVMediaType mt, void (^handler)(BOOL)) {
	(void)self; (void)sel; (void)mt;
	if (handler) {
		dispatch_async(dispatch_get_main_queue(), ^{ handler(YES); });
	}
}

static id hook_disc_session(id self, SEL sel, NSArray *types, AVMediaType mt, AVCaptureDevicePosition pos) {
	if (!mt || [mt isEqualToString:AVMediaTypeVideo]) {
		SapphireVirtualDiscoverySession *ds = [[SapphireVirtualDiscoverySession alloc] init];
		if (pos == AVCaptureDevicePositionFront) {
			ds.devices = @[ get_virtual_device(AVCaptureDevicePositionFront) ];
		} else if (pos == AVCaptureDevicePositionBack) {
			ds.devices = @[ get_virtual_device(AVCaptureDevicePositionBack) ];
		} else {
			ds.devices = @[ get_virtual_device(AVCaptureDevicePositionBack), get_virtual_device(AVCaptureDevicePositionFront) ];
		}
		return ds;
	}
	return orig_disc_session ? orig_disc_session(self, sel, types, mt, pos) : nil;
}

static id hook_input_withDevice(id self, SEL sel, AVCaptureDevice *dev, NSError **err) {
	if ([dev isKindOfClass:[SapphireVirtualCaptureDevice class]]) {
		if (err) *err = nil;
		return [[SapphireVirtualCaptureInput alloc] initWithDevice:(SapphireVirtualCaptureDevice *)dev];
	}
	return orig_input_withDevice ? orig_input_withDevice(self, sel, dev, err) : nil;
}

static id hook_input_initWithDevice(id self, SEL sel, AVCaptureDevice *dev, NSError **err) {
	if ([dev isKindOfClass:[SapphireVirtualCaptureDevice class]]) {
		if (err) *err = nil;
		return [[SapphireVirtualCaptureInput alloc] initWithDevice:(SapphireVirtualCaptureDevice *)dev];
	}
	return orig_input_initWithDevice ? orig_input_initWithDevice(self, sel, dev, err) : nil;
}

static BOOL is_virtual_session(AVCaptureSession *s) {
	SapphireAVSessionState *st = session_state(s, NO);
	return st != nil && st.vInputs.count > 0;
}

static BOOL hook_sess_canAddInput(AVCaptureSession *self, SEL sel, AVCaptureInput *inp) {
	if ([inp isKindOfClass:[SapphireVirtualCaptureInput class]]) return YES;
	return orig_sess_canAddInput ? orig_sess_canAddInput(self, sel, inp) : NO;
}

static void hook_sess_addInput(AVCaptureSession *self, SEL sel, AVCaptureInput *inp) {
	if ([inp isKindOfClass:[SapphireVirtualCaptureInput class]]) {
		SapphireAVSessionState *st = session_state(self, YES);
		if (![st.vInputs containsObject:inp]) [st.vInputs addObject:inp];
		return;
	}
	if (orig_sess_addInput) orig_sess_addInput(self, sel, inp);
}

static void hook_sess_removeInput(AVCaptureSession *self, SEL sel, AVCaptureInput *inp) {
	if ([inp isKindOfClass:[SapphireVirtualCaptureInput class]]) {
		SapphireAVSessionState *st = session_state(self, NO);
		[st.vInputs removeObject:inp];
		return;
	}
	if (orig_sess_removeInput) orig_sess_removeInput(self, sel, inp);
}

static NSArray *hook_sess_inputs(AVCaptureSession *self, SEL sel) {
	SapphireAVSessionState *st = session_state(self, NO);
	if (st && st.vInputs.count > 0) return [st.vInputs copy];
	return orig_sess_inputs ? orig_sess_inputs(self, sel) : @[];
}

static BOOL hook_sess_canAddOutput(AVCaptureSession *self, SEL sel, AVCaptureOutput *outp) {
	if (is_virtual_session(self)) return YES;
	return orig_sess_canAddOutput ? orig_sess_canAddOutput(self, sel, outp) : NO;
}

static void hook_sess_addOutput(AVCaptureSession *self, SEL sel, AVCaptureOutput *outp) {
	if (is_virtual_session(self)) {
		SapphireAVSessionState *st = session_state(self, YES);
		if (outp && ![st.vOutputs containsObject:outp]) {
			[st.vOutputs addObject:outp];
			SapphireVirtualCaptureInput *vin = st.vInputs.firstObject;
			SapphireVirtualCaptureConnection *conn = [[SapphireVirtualCaptureConnection alloc] initWithOutput:outp ports:vin.ports];
			[st.connections setObject:conn forKey:outp];
			objc_setAssociatedObject(outp, kSessionStateKey, st, OBJC_ASSOCIATION_ASSIGN);
		}
		return;
	}
	if (orig_sess_addOutput) orig_sess_addOutput(self, sel, outp);
}

static void hook_sess_removeOutput(AVCaptureSession *self, SEL sel, AVCaptureOutput *outp) {
	if (is_virtual_session(self)) {
		SapphireAVSessionState *st = session_state(self, NO);
		[st.vOutputs removeObject:outp];
		[st.connections removeObjectForKey:outp];
		return;
	}
	if (orig_sess_removeOutput) orig_sess_removeOutput(self, sel, outp);
}

static NSArray *hook_sess_outputs(AVCaptureSession *self, SEL sel) {
	SapphireAVSessionState *st = session_state(self, NO);
	if (st && st.vInputs.count > 0) return [st.vOutputs copy];
	return orig_sess_outputs ? orig_sess_outputs(self, sel) : @[];
}

static BOOL hook_sess_canSetPreset(AVCaptureSession *self, SEL sel, AVCaptureSessionPreset p) {
	if (is_virtual_session(self)) return YES;
	return orig_sess_canSetPreset ? orig_sess_canSetPreset(self, sel, p) : NO;
}

static void hook_sess_setPreset(AVCaptureSession *self, SEL sel, AVCaptureSessionPreset p) {
	if (is_virtual_session(self)) {
		session_state(self, YES).vPreset = p;
		return;
	}
	if (orig_sess_setPreset) orig_sess_setPreset(self, sel, p);
}

static void hook_sess_beginConfig(AVCaptureSession *self, SEL sel) {
	if (is_virtual_session(self)) return;
	if (orig_sess_beginConfig) orig_sess_beginConfig(self, sel);
}

static void hook_sess_commitConfig(AVCaptureSession *self, SEL sel) {
	if (is_virtual_session(self)) return;
	if (orig_sess_commitConfig) orig_sess_commitConfig(self, sel);
}

static void hook_sess_startRunning(AVCaptureSession *self, SEL sel) {
	if (is_virtual_session(self)) {
		[session_state(self, NO) startEngine];
		return;
	}
	if (orig_sess_startRunning) orig_sess_startRunning(self, sel);
}

static void hook_sess_stopRunning(AVCaptureSession *self, SEL sel) {
	if (is_virtual_session(self)) {
		[session_state(self, NO) stopEngine];
		return;
	}
	if (orig_sess_stopRunning) orig_sess_stopRunning(self, sel);
}

static BOOL hook_sess_isRunning(AVCaptureSession *self, SEL sel) {
	if (is_virtual_session(self)) return session_state(self, NO).vRunning;
	return orig_sess_isRunning ? orig_sess_isRunning(self, sel) : NO;
}

static AVCaptureConnection *hook_out_connWithMediaType(AVCaptureOutput *self, SEL sel, AVMediaType mt) {
	SapphireAVSessionState *st = objc_getAssociatedObject(self, kSessionStateKey);
	if (st != nil) {
		SapphireVirtualCaptureConnection *c = [st.connections objectForKey:self];
		if (c) return (AVCaptureConnection *)c;
	}
	return orig_out_connWithMediaType ? orig_out_connWithMediaType(self, sel, mt) : nil;
}

static void hook_photo_capture(AVCapturePhotoOutput *self, SEL sel, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> del) {
	SapphireAVSessionState *st = objc_getAssociatedObject(self, kSessionStateKey);
	if (st != nil && del != nil) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			int fd = camd_connect_and_cmd("CAPTURE 12 nodng\n", NULL, 0);
			NSData *jpeg = nil;
			if (fd >= 0) {
				FILE *fp = fdopen(fd, "r");
				char line[512];
				while (fp && fgets(line, sizeof(line), fp)) {
					if (strncmp(line, "DONE ", 5) == 0) {
						char *nl = strpbrk(line + 5, " \r\n");
						if (nl) *nl = '\0';
						jpeg = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:line + 5]];
						break;
					}
					if (strncmp(line, "ERR ", 4) == 0) break;
				}
				if (fp) fclose(fp);
				else close(fd);
			}
			SapphireVirtualCapturePhoto *photo = [[SapphireVirtualCapturePhoto alloc] init];
			photo.jpegData = jpeg;
			photo.timestamp = CMTimeMake(1, 1);
			NSError *err = jpeg ? nil : [NSError errorWithDomain:AVFoundationErrorDomain code:-11800 userInfo:nil];
			dispatch_async(dispatch_get_main_queue(), ^{
				if ([del respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
					[del captureOutput:self didFinishProcessingPhoto:(AVCapturePhoto *)photo error:err];
				}
			});
		});
		return;
	}
	if (orig_photo_capture) orig_photo_capture(self, sel, settings, del);
}

static void hook_pl_setSession(AVCaptureVideoPreviewLayer *self, SEL sel, AVCaptureSession *s) {
	if (s && is_virtual_session(s)) {
		objc_setAssociatedObject(self, kPreviewLayerSessionKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		SapphireAVSessionState *st = session_state(s, YES);
		[st.previewLayers addObject:self];
		return;
	}
	if (orig_pl_setSession) orig_pl_setSession(self, sel, s);
}

static AVCaptureSession *hook_pl_session(AVCaptureVideoPreviewLayer *self, SEL sel) {
	AVCaptureSession *vs = objc_getAssociatedObject(self, kPreviewLayerSessionKey);
	if (vs) return vs;
	return orig_pl_session ? orig_pl_session(self, sel) : nil;
}

static void hook_pl_layout(AVCaptureVideoPreviewLayer *self, SEL sel) {
	if (orig_pl_layout) orig_pl_layout(self, sel);
	CALayer *child = objc_getAssociatedObject(self, kPreviewLayerChildKey);
	if (child) {
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		child.frame = self.bounds;
		[CATransaction commit];
	}
}

static AVMetadataObject *hook_pl_transformMeta(AVCaptureVideoPreviewLayer *self, SEL sel, AVMetadataObject *obj) {
	if ([obj isKindOfClass:[SapphireVirtualMetadataCodeObject class]]) {
		SapphireVirtualMetadataCodeObject *src = (SapphireVirtualMetadataCodeObject *)obj;
		SapphireVirtualMetadataCodeObject *dst = [[SapphireVirtualMetadataCodeObject alloc] init];
		dst.type = src.type;
		dst.stringValue = src.stringValue;
		dst.time = src.time;
		dst.duration = src.duration;
		CGRect b = self.bounds;
		dst.bounds = CGRectMake(src.bounds.origin.x * b.size.width,
		                        src.bounds.origin.y * b.size.height,
		                        src.bounds.size.width * b.size.width,
		                        src.bounds.size.height * b.size.height);
		return (AVMetadataObject *)dst;
	}
	return orig_pl_transformMeta ? orig_pl_transformMeta(self, sel, obj) : obj;
}

static void
swizzle_class_method(Class cls, SEL sel, IMP imp, IMP *orig)
{
	Method m = class_getClassMethod(cls, sel);
	if (m) {
		IMP prev = method_setImplementation(m, imp);
		if (orig) *orig = prev;
	}
}

static void
swizzle_inst_method(Class cls, SEL sel, IMP imp, IMP *orig)
{
	Method m = class_getInstanceMethod(cls, sel);
	if (m) {
		IMP prev = method_setImplementation(m, imp);
		if (orig) *orig = prev;
	}
}

__attribute__((constructor)) static void
sapphire_avcamera_init(void)
{
	NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
	/* Camera.app is handled by SapphireNoCamera.dylib */
	if ([bid isEqualToString:@"com.apple.camera"]) {
		return;
	}
	Class devCls = objc_getClass("AVCaptureDevice");
	if (!devCls) return;

	swizzle_class_method(devCls, @selector(devices), (IMP)hook_dev_devices, (IMP *)&orig_dev_devices);
	swizzle_class_method(devCls, @selector(devicesWithMediaType:), (IMP)hook_dev_devicesWithMediaType, (IMP *)&orig_dev_devicesWithMediaType);
	swizzle_class_method(devCls, @selector(defaultDeviceWithMediaType:), (IMP)hook_dev_defaultWithMediaType, (IMP *)&orig_dev_defaultWithMediaType);
	swizzle_class_method(devCls, @selector(defaultDeviceWithDeviceType:mediaType:position:), (IMP)hook_dev_defaultWithType, (IMP *)&orig_dev_defaultWithType);
	swizzle_class_method(devCls, @selector(authorizationStatusForMediaType:), (IMP)hook_dev_authStatus, NULL);
	swizzle_class_method(devCls, @selector(requestAccessForMediaType:completionHandler:), (IMP)hook_dev_requestAccess, NULL);

	Class discCls = objc_getClass("AVCaptureDeviceDiscoverySession");
	if (discCls) {
		swizzle_class_method(discCls, @selector(discoverySessionWithDeviceTypes:mediaType:position:), (IMP)hook_disc_session, (IMP *)&orig_disc_session);
	}

	Class inpCls = objc_getClass("AVCaptureDeviceInput");
	if (inpCls) {
		swizzle_class_method(inpCls, @selector(deviceInputWithDevice:error:), (IMP)hook_input_withDevice, (IMP *)&orig_input_withDevice);
		swizzle_inst_method(inpCls, @selector(initWithDevice:error:), (IMP)hook_input_initWithDevice, (IMP *)&orig_input_initWithDevice);
	}

	Class sessCls = objc_getClass("AVCaptureSession");
	if (sessCls) {
		swizzle_inst_method(sessCls, @selector(canAddInput:), (IMP)hook_sess_canAddInput, (IMP *)&orig_sess_canAddInput);
		swizzle_inst_method(sessCls, @selector(addInput:), (IMP)hook_sess_addInput, (IMP *)&orig_sess_addInput);
		swizzle_inst_method(sessCls, @selector(removeInput:), (IMP)hook_sess_removeInput, (IMP *)&orig_sess_removeInput);
		swizzle_inst_method(sessCls, @selector(inputs), (IMP)hook_sess_inputs, (IMP *)&orig_sess_inputs);
		swizzle_inst_method(sessCls, @selector(canAddOutput:), (IMP)hook_sess_canAddOutput, (IMP *)&orig_sess_canAddOutput);
		swizzle_inst_method(sessCls, @selector(addOutput:), (IMP)hook_sess_addOutput, (IMP *)&orig_sess_addOutput);
		swizzle_inst_method(sessCls, @selector(removeOutput:), (IMP)hook_sess_removeOutput, (IMP *)&orig_sess_removeOutput);
		swizzle_inst_method(sessCls, @selector(outputs), (IMP)hook_sess_outputs, (IMP *)&orig_sess_outputs);
		swizzle_inst_method(sessCls, @selector(canSetSessionPreset:), (IMP)hook_sess_canSetPreset, (IMP *)&orig_sess_canSetPreset);
		swizzle_inst_method(sessCls, @selector(setSessionPreset:), (IMP)hook_sess_setPreset, (IMP *)&orig_sess_setPreset);
		swizzle_inst_method(sessCls, @selector(beginConfiguration), (IMP)hook_sess_beginConfig, (IMP *)&orig_sess_beginConfig);
		swizzle_inst_method(sessCls, @selector(commitConfiguration), (IMP)hook_sess_commitConfig, (IMP *)&orig_sess_commitConfig);
		swizzle_inst_method(sessCls, @selector(startRunning), (IMP)hook_sess_startRunning, (IMP *)&orig_sess_startRunning);
		swizzle_inst_method(sessCls, @selector(stopRunning), (IMP)hook_sess_stopRunning, (IMP *)&orig_sess_stopRunning);
		swizzle_inst_method(sessCls, @selector(isRunning), (IMP)hook_sess_isRunning, (IMP *)&orig_sess_isRunning);
	}

	Class outCls = objc_getClass("AVCaptureOutput");
	if (outCls) {
		swizzle_inst_method(outCls, @selector(connectionWithMediaType:), (IMP)hook_out_connWithMediaType, (IMP *)&orig_out_connWithMediaType);
	}

	Class photoCls = objc_getClass("AVCapturePhotoOutput");
	if (photoCls) {
		swizzle_inst_method(photoCls, @selector(capturePhotoWithSettings:delegate:), (IMP)hook_photo_capture, (IMP *)&orig_photo_capture);
	}

	Class plCls = objc_getClass("AVCaptureVideoPreviewLayer");
	if (plCls) {
		swizzle_inst_method(plCls, @selector(setSession:), (IMP)hook_pl_setSession, (IMP *)&orig_pl_setSession);
		swizzle_inst_method(plCls, @selector(session), (IMP)hook_pl_session, (IMP *)&orig_pl_session);
		swizzle_inst_method(plCls, @selector(layoutSublayers), (IMP)hook_pl_layout, (IMP *)&orig_pl_layout);
		swizzle_inst_method(plCls, @selector(transformedMetadataObjectForMetadataObject:), (IMP)hook_pl_transformMeta, (IMP *)&orig_pl_transformMeta);
	}
}
