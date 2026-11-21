/*
 * SapphireBiometry.dylib — "Use Fingerprint for Apps and Purchases" (Huella / fpd)
 *
 * Hooks LocalAuthentication's LAContext across UIKit apps & App Store:
 * - Reads /var/mobile/Library/Preferences/com.sapphire.fingerprint.plist ("appsEnabled").
 * - Reports LABiometryTypeTouchID (1) and canEvaluatePolicy:YES when enabled & fpd is alive.
 * - On evaluatePolicy:localizedReason:reply:, displays a native iOS bottom auth sheet +
 *   optical FOD target ring at the exact hardware sensor position (540/1080, 2109/2400),
 *   authenticates via /var/run/fpd.sock ("TEST"), triggers haptics, and returns reply(YES, nil)
 *   on "TEST MATCH".
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <notify.h>

#define FPD_SOCK_PATH   "/var/run/fpd.sock"
#define FACED_SOCK_PATH "/var/run/faced.sock"
#define FP_PREFS_PATH   @"/var/mobile/Library/Preferences/com.sapphire.fingerprint.plist"
#define FACE_PREFS_PATH @"/var/mobile/Library/Preferences/com.sapphire.faceid.plist"
#define SENSOR_X        (540.0 / 1080.0)
#define SENSOR_Y        (2109.0 / 2400.0)
#define SENSOR_R        (105.0 / 1080.0)

static BOOL
bio_apps_enabled(void)
{
	NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FP_PREFS_PATH];
	if (d == nil) return YES; /* default ON once installed */
	id v = d[@"appsEnabled"];
	return v ? [v boolValue] : YES;
}

static BOOL
face_apps_enabled(void)
{
	NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FACE_PREFS_PATH];
	if (d == nil) return YES;
	id v = d[@"faceAppsEnabled"];
	return v ? [v boolValue] : YES;
}

static BOOL
faced_has_enrolled_face(void)
{
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return NO;
	struct timeval tv = { 1, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	struct sockaddr_un a;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	strlcpy(a.sun_path, FACED_SOCK_PATH, sizeof(a.sun_path));
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
		close(fd);
		return NO;
	}
	const char *cmd = "STATUS\n";
	BOOL ok = NO;
	if (write(fd, cmd, strlen(cmd)) == (ssize_t)strlen(cmd)) {
		char buf[512];
		ssize_t n = read(fd, buf, sizeof(buf) - 1);
		if (n > 0) {
			buf[n] = '\0';
			const char *f = strstr(buf, "enrolled=");
			if (f && atoi(f + 9) > 0) ok = YES;
		}
	}
	close(fd);
	return ok;
}

static BOOL
fpd_has_enrolled_fingers(void)
{
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return NO;
	struct timeval tv = { 1, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	struct sockaddr_un a;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	strlcpy(a.sun_path, FPD_SOCK_PATH, sizeof(a.sun_path));
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
		close(fd);
		return NO;
	}
	const char *cmd = "STATUS\n";
	BOOL ok = NO;
	if (write(fd, cmd, strlen(cmd)) == (ssize_t)strlen(cmd)) {
		char buf[512];
		ssize_t n = read(fd, buf, sizeof(buf) - 1);
		if (n > 0) {
			buf[n] = '\0';
			const char *f = strstr(buf, "fingers=");
			if (f && atoi(f + 8) > 0) ok = YES;
		}
	}
	close(fd);
	return ok;
}

static BOOL
bio_any_enrolled_and_enabled(void)
{
	if (bio_apps_enabled() && fpd_has_enrolled_fingers()) return YES;
	if (face_apps_enabled() && faced_has_enrolled_face()) return YES;
	return NO;
}

static UIWindow *
bio_key_window(void)
{
	UIApplication *app = [UIApplication sharedApplication];
	for (UIScene *s in app.connectedScenes) {
		if (![s isKindOfClass:[UIWindowScene class]]) continue;
		UIWindowScene *ws = (UIWindowScene *)s;
		for (UIWindow *w in ws.windows) {
			if (w.isKeyWindow) return w;
		}
		if (ws.windows.firstObject) return ws.windows.firstObject;
	}
	return nil;
}

@interface SapphireBioPrompt : UIView
@property (nonatomic, copy) void (^replyBlock)(BOOL success, NSError *error);
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *sensorSpot;
@property (nonatomic, assign) int sockFd;
@property (nonatomic, assign) int faceSockFd;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) int attempts;
@end

@implementation SapphireBioPrompt

- (instancetype)initWithFrame:(CGRect)frame reason:(NSString *)reason reply:(void (^)(BOOL, NSError *))reply
{
	self = [super initWithFrame:frame];
	if (!self) return nil;
	_replyBlock = [reply copy];
	_sockFd = -1;
	_faceSockFd = -1;
	_finished = NO;
	_attempts = 0;
	self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];

	CGFloat w = frame.size.width;
	CGFloat h = frame.size.height;

	/* Centered iOS-style frosted card */
	UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
	UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
	card.frame = CGRectMake(28, h * 0.30, w - 56, 210);
	card.layer.cornerRadius = 22;
	card.clipsToBounds = YES;
	[self addSubview:card];

	BOOL hasFace = (face_apps_enabled() && faced_has_enrolled_face());
	BOOL hasFP = (bio_apps_enabled() && fpd_has_enrolled_fingers());
	NSString *glyphName = (hasFace && !hasFP) ? @"faceid" : (hasFace ? @"person.badge.shield.checkmark" : @"touchid");

	UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:glyphName]];
	icon.tintColor = [UIColor systemBlueColor];
	icon.contentMode = UIViewContentModeScaleAspectFit;
	icon.frame = CGRectMake((card.bounds.size.width - 44) / 2.0, 18, 44, 44);
	[card.contentView addSubview:icon];

	_titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 68, card.bounds.size.width - 32, 24)];
	_titleLabel.text = (hasFace && !hasFP) ? @"Face ID (Huella)" : (hasFace ? @"Face ID / Touch ID" : @"Touch ID (Huella)");
	_titleLabel.textColor = [UIColor whiteColor];
	_titleLabel.font = [UIFont boldSystemFontOfSize:17];
	_titleLabel.textAlignment = NSTextAlignmentCenter;
	[card.contentView addSubview:_titleLabel];

	_reasonLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 94, card.bounds.size.width - 32, 38)];
	_reasonLabel.text = reason.length ? reason : (hasFace ? @"Look at front camera or use fingerprint" : @"Authenticate with your fingerprint");
	_reasonLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
	_reasonLabel.font = [UIFont systemFontOfSize:13];
	_reasonLabel.textAlignment = NSTextAlignmentCenter;
	_reasonLabel.numberOfLines = 2;
	[card.contentView addSubview:_reasonLabel];

	_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 134, card.bounds.size.width - 32, 20)];
	_statusLabel.text = hasFace ? @"Scanning face / Touch sensor" : @"Place finger on sensor";
	_statusLabel.textColor = [UIColor systemTealColor];
	_statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
	_statusLabel.textAlignment = NSTextAlignmentCenter;
	[card.contentView addSubview:_statusLabel];

	UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
	cancel.frame = CGRectMake(0, 162, card.bounds.size.width, 46);
	[cancel setTitle:@"Cancel" forState:UIControlStateNormal];
	[cancel setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
	cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
	[cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
	[card.contentView addSubview:cancel];

	/* Optical FOD sensor target ring at exact hardware position */
	if (hasFP) {
		CGFloat sx = w * SENSOR_X;
		CGFloat sy = h * SENSOR_Y;
		CGFloat sr = w * SENSOR_R;
		_sensorSpot = [[UIView alloc] initWithFrame:CGRectMake(sx - sr, sy - sr, sr * 2.0, sr * 2.0)];
		_sensorSpot.layer.cornerRadius = sr;
		_sensorSpot.layer.borderWidth = 3.0;
		_sensorSpot.layer.borderColor = [UIColor systemGreenColor].CGColor;
		_sensorSpot.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
		UIImageView *fp = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"touchid"]];
		fp.tintColor = [UIColor whiteColor];
		fp.contentMode = UIViewContentModeScaleAspectFit;
		fp.frame = CGRectInset(_sensorSpot.bounds, 14, 14);
		[_sensorSpot addSubview:fp];
		[self addSubview:_sensorSpot];
	}

	[self startTest];
	return self;
}

- (void)closeSock:(BOOL)sendCancel
{
	if (_sockFd >= 0) {
		if (sendCancel) {
			const char *c = "TEST_CANCEL\n";
			(void)write(_sockFd, c, strlen(c));
		}
		close(_sockFd);
		_sockFd = -1;
	}
	if (_faceSockFd >= 0) {
		if (sendCancel) {
			const char *c = "STOP\n";
			(void)write(_faceSockFd, c, strlen(c));
		}
		close(_faceSockFd);
		_faceSockFd = -1;
	}
}

- (void)finishWithSuccess:(BOOL)ok code:(NSInteger)errCode
{
	if (_finished) return;
	_finished = YES;
	[self closeSock:!ok];
	void (^cb)(BOOL, NSError *) = _replyBlock;
	_replyBlock = nil;
	dispatch_async(dispatch_get_main_queue(), ^{
		[UIView animateWithDuration:0.18 animations:^{
			self.alpha = 0.0;
		} completion:^(BOOL d) {
			(void)d;
			[self removeFromSuperview];
			if (cb) {
				NSError *err = ok ? nil : [NSError errorWithDomain:@"com.apple.LocalAuthentication" code:errCode userInfo:nil];
				cb(ok, err);
			}
		}];
	});
}

- (void)cancelTapped
{
	[self finishWithSuccess:NO code:-2]; /* LAErrorUserCancel */
}

- (void)startFaceScan
{
	if (_finished || !face_apps_enabled() || !faced_has_enrolled_face()) return;
	__weak typeof(self) ws = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (fd < 0) return;
		struct sockaddr_un sa;
		memset(&sa, 0, sizeof(sa));
		sa.sun_family = AF_UNIX;
		strlcpy(sa.sun_path, FACED_SOCK_PATH, sizeof(sa.sun_path));
		if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
			close(fd);
			return;
		}
		ws.faceSockFd = fd;
		const char *cmd = "SCAN_BIO\n";
		if (write(fd, cmd, strlen(cmd)) != (ssize_t)strlen(cmd)) {
			close(fd);
			ws.faceSockFd = -1;
			return;
		}
		char buf[256];
		ssize_t n = read(fd, buf, sizeof(buf) - 1);
		if (n > 0) {
			buf[n] = '\0';
			if (strstr(buf, "MATCH") != NULL && strstr(buf, "NOMATCH") == NULL) {
				notify_post("com.sapphire.vib.success");
				dispatch_async(dispatch_get_main_queue(), ^{
					ws.statusLabel.text = @"Face Verified";
					ws.statusLabel.textColor = [UIColor systemGreenColor];
				});
				[ws finishWithSuccess:YES code:0];
			}
		}
		if (ws.faceSockFd == fd) {
			close(fd);
			ws.faceSockFd = -1;
		}
	});
}

- (void)startTest
{
	if (_finished) return;
	[self closeSock:NO];

	[self startFaceScan];

	if (!bio_apps_enabled() || !fpd_has_enrolled_fingers()) return;

	__weak typeof(self) ws = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (fd < 0) {
			[ws finishWithSuccess:NO code:-1];
			return;
		}
		struct sockaddr_un a;
		memset(&a, 0, sizeof(a));
		a.sun_family = AF_UNIX;
		strlcpy(a.sun_path, FPD_SOCK_PATH, sizeof(a.sun_path));
		if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
			close(fd);
			[ws finishWithSuccess:NO code:-7]; /* LAErrorBiometryNotEnrolled / unavailable */
			return;
		}
		ws.sockFd = fd;
		const char *cmd = "TEST\n";
		if (write(fd, cmd, strlen(cmd)) != (ssize_t)strlen(cmd)) {
			[ws finishWithSuccess:NO code:-1];
			return;
		}
		NSMutableData *buf = [NSMutableData data];
		char tmp[512];
		while (!ws.finished && fd == ws.sockFd) {
			ssize_t n = read(fd, tmp, sizeof(tmp));
			if (n <= 0) break;
			[buf appendBytes:tmp length:(NSUInteger)n];
			for (;;) {
				const char *s = buf.bytes;
				const char *nl = memchr(s, '\n', buf.length);
				if (!nl) break;
				NSString *line = [[NSString alloc] initWithBytes:s length:(NSUInteger)(nl - s) encoding:NSUTF8StringEncoding];
				[buf replaceBytesInRange:NSMakeRange(0, (NSUInteger)(nl - s) + 1) withBytes:NULL length:0];
				if (!line) continue;
				if ([line isEqualToString:@"PRESS"]) {
					dispatch_async(dispatch_get_main_queue(), ^{
						ws.statusLabel.text = @"Verifying Fingerprint…";
						ws.sensorSpot.backgroundColor = [UIColor whiteColor];
					});
				} else if ([line hasPrefix:@"TEST MATCH"]) {
					notify_post("com.sapphire.vib.success");
					dispatch_async(dispatch_get_main_queue(), ^{
						ws.statusLabel.text = @"Recognized";
						ws.statusLabel.textColor = [UIColor systemGreenColor];
					});
					[ws finishWithSuccess:YES code:0];
					return;
				} else if ([line hasPrefix:@"TEST NOMATCH"] || [line hasPrefix:@"TEST LIFTED"]) {
					notify_post("com.sapphire.vib.error");
					ws.attempts++;
					dispatch_async(dispatch_get_main_queue(), ^{
						ws.sensorSpot.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
						ws.statusLabel.text = [line hasPrefix:@"TEST LIFTED"] ? @"Hold finger slightly longer" : @"Try again";
						ws.statusLabel.textColor = [UIColor systemOrangeColor];
					});
					if (ws.attempts >= 5) {
						[ws finishWithSuccess:NO code:-1]; /* LAErrorAuthenticationFailed */
						return;
					}
					[ws startTest];
					return;
				} else if ([line hasPrefix:@"TEST TIMEOUT"] || [line hasPrefix:@"ERR"]) {
					[ws finishWithSuccess:NO code:-1];
					return;
				}
			}
		}
	});
}
@end

/* ================================================================== LAContext hooks */
static BOOL (*orig_can_eval)(id self, SEL sel, NSInteger policy, NSError **error);
static BOOL
hook_can_eval(id self, SEL sel, NSInteger policy, NSError **error)
{
	if ((policy == 1 || policy == 2) && bio_any_enrolled_and_enabled()) {
		if (error) *error = nil;
		return YES;
	}
	return orig_can_eval ? orig_can_eval(self, sel, policy, error) : NO;
}

static NSInteger (*orig_bio_type)(id self, SEL sel);
static NSInteger
hook_bio_type(id self, SEL sel)
{
	if (bio_any_enrolled_and_enabled()) {
		if (face_apps_enabled() && faced_has_enrolled_face() && (!bio_apps_enabled() || !fpd_has_enrolled_fingers())) {
			return 2; /* LABiometryTypeFaceID */
		}
		return 1; /* LABiometryTypeTouchID */
	}
	return orig_bio_type ? orig_bio_type(self, sel) : 0;
}

static NSData *(*orig_domain_state)(id self, SEL sel);
static NSData *
hook_domain_state(id self, SEL sel)
{
	if (bio_any_enrolled_and_enabled()) {
		static NSData *tok = nil;
		if (!tok) tok = [@"sapphire-bio-v3" dataUsingEncoding:NSUTF8StringEncoding];
		return tok;
	}
	return orig_domain_state ? orig_domain_state(self, sel) : nil;
}

static void (*orig_eval_policy)(id self, SEL sel, NSInteger policy, NSString *reason, void (^reply)(BOOL, NSError *));
static void
hook_eval_policy(id self, SEL sel, NSInteger policy, NSString *reason, void (^reply)(BOOL, NSError *))
{
	if ((policy == 1 || policy == 2) && bio_any_enrolled_and_enabled()) {
		dispatch_async(dispatch_get_main_queue(), ^{
			UIWindow *w = bio_key_window();
			if (!w) {
				if (orig_eval_policy) orig_eval_policy(self, sel, policy, reason, reply);
				else if (reply) reply(NO, [NSError errorWithDomain:@"com.apple.LocalAuthentication" code:-1 userInfo:nil]);
				return;
			}
			SapphireBioPrompt *p = [[SapphireBioPrompt alloc] initWithFrame:w.bounds reason:reason reply:reply];
			p.alpha = 0.0;
			[w addSubview:p];
			[UIView animateWithDuration:0.18 animations:^{ p.alpha = 1.0; }];
		});
		return;
	}
	if (orig_eval_policy) orig_eval_policy(self, sel, policy, reason, reply);
}

__attribute__((constructor)) static void
sapphire_biometry_init(void)
{
	Class la = objc_getClass("LAContext");
	if (la == Nil) return;

	Method m1 = class_getInstanceMethod(la, sel_registerName("canEvaluatePolicy:error:"));
	if (m1) {
		orig_can_eval = (BOOL (*)(id, SEL, NSInteger, NSError **))method_getImplementation(m1);
		method_setImplementation(m1, (IMP)hook_can_eval);
	}
	Method m2 = class_getInstanceMethod(la, sel_registerName("biometryType"));
	if (m2) {
		orig_bio_type = (NSInteger (*)(id, SEL))method_getImplementation(m2);
		method_setImplementation(m2, (IMP)hook_bio_type);
	}
	Method m3 = class_getInstanceMethod(la, sel_registerName("evaluatedPolicyDomainState"));
	if (m3) {
		orig_domain_state = (NSData *(*)(id, SEL))method_getImplementation(m3);
		method_setImplementation(m3, (IMP)hook_domain_state);
	}
	Method m4 = class_getInstanceMethod(la, sel_registerName("evaluatePolicy:localizedReason:reply:"));
	if (m4) {
		orig_eval_policy = (void (*)(id, SEL, NSInteger, NSString *, void (^)(BOOL, NSError *)))method_getImplementation(m4);
		method_setImplementation(m4, (IMP)hook_eval_policy);
	}
}
