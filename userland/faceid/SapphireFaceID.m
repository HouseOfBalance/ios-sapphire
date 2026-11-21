/*
 * SapphireFaceID.dylib: SpringBoard Lock Screen client for 2D Face Unlock (faced + fpd op 28).
 *
 * - Strictly Lock Screen only (never wired into LAContext / appsEnabled).
 * - Triggers faced SCAN on screen wake while locked, enrolled, and proximity far.
 * - Shows a minimal frosted Face ID status pill at the top of the Lock Screen.
 * - On com.sapphire.face.unlocked (keybag already unlocked by fpd op 28), calls
 *   -[SBLockScreenManager _attemptUnlockWithPasscode:nil mesa:YES finishUIUnlock:...]
 *   defaulting to iPhone X style (stay on Lock Screen with padlock unlocked; swipe up to enter).
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

#define FACED_SOCK_PATH "/var/run/faced.sock"
#define PREFS_PATH      "/var/mobile/Library/Preferences/com.sapphire.faceid.plist"

static int g_tok_blank = -1;
static int g_tok_lock = -1;
static int g_tok_state = -1;
static int g_tok_prox = -1;
static BOOL g_enabled = YES;
static BOOL g_stay_on_lock = YES;
static BOOL g_scanning = NO;
static UIWindow *g_lock_win = nil;
static UIImageView *g_lock_icon = nil;
static UILabel *g_pill_lbl = nil;
static UIVisualEffectView *g_blur = nil;

static void
load_prefs(void)
{
	NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@PREFS_PATH];
	if (d[@"faceUnlockEnabled"] != nil) g_enabled = [d[@"faceUnlockEnabled"] boolValue];
	if (d[@"faceStayOnLock"] != nil) g_stay_on_lock = [d[@"faceStayOnLock"] boolValue];
}

static uint64_t
get_notify_state(int tok)
{
	if (tok < 0) return 0;
	uint64_t st = 0;
	notify_get_state(tok, &st);
	return st;
}

static void
faced_send_async(const char *cmd, void (^completion)(NSString *reply))
{
	NSString *cmdStr = [NSString stringWithUTF8String:cmd];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if (fd < 0) {
			if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@"ERR"); });
			return;
		}
		struct timeval tv = { .tv_sec = 4, .tv_usec = 0 };
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
		struct sockaddr_un sa = { .sun_family = AF_UNIX };
		snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", FACED_SOCK_PATH);
		NSString *reply = @"ERR";
		if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
			const char *c = cmdStr.UTF8String;
			if (write(fd, c, strlen(c)) == (ssize_t)strlen(c)) {
				char buf[256] = "";
				ssize_t n = read(fd, buf, sizeof(buf) - 1);
				if (n > 0) {
					buf[n] = '\0';
					reply = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
				}
			}
		}
		close(fd);
		if (completion) {
			dispatch_async(dispatch_get_main_queue(), ^{ completion(reply); });
		}
	});
}

static void
ensure_lock_ui(void)
{
	if (g_lock_win) return;
	CGRect sb = [UIScreen mainScreen].bounds;
	/* Native iPhone X Face ID padlock at top center: y=50, w=150, h=34 */
	g_lock_win = [[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width - 150) / 2.0, 50, 150, 34)];
	g_lock_win.windowLevel = UIWindowLevelAlert + 50;
	g_lock_win.backgroundColor = [UIColor clearColor];
	g_lock_win.userInteractionEnabled = NO;

	g_blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
	g_blur.frame = g_lock_win.bounds;
	g_blur.layer.cornerRadius = 17;
	g_blur.clipsToBounds = YES;
	[g_lock_win addSubview:g_blur];

	/* Center Lock Icon */
	g_lock_icon = [[UIImageView alloc] initWithFrame:CGRectMake((150 - 20) / 2.0, (34 - 24) / 2.0, 20, 24)];
	g_lock_icon.contentMode = UIViewContentModeScaleAspectFit;
	g_lock_icon.tintColor = [UIColor whiteColor];
	g_lock_icon.image = [UIImage systemImageNamed:@"lock.fill"];
	[g_blur.contentView addSubview:g_lock_icon];

	/* Pill Status Label (for Face Not Recognized or Face ID...) */
	g_pill_lbl = [[UILabel alloc] initWithFrame:g_blur.bounds];
	g_pill_lbl.textAlignment = NSTextAlignmentCenter;
	g_pill_lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
	g_pill_lbl.textColor = [UIColor whiteColor];
	g_pill_lbl.hidden = YES;
	[g_blur.contentView addSubview:g_pill_lbl];
}

static void
show_locked_icon(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		ensure_lock_ui();
		g_lock_icon.hidden = NO;
		g_lock_icon.image = [UIImage systemImageNamed:@"lock.fill"];
		g_lock_icon.tintColor = [UIColor whiteColor];
		g_lock_icon.transform = CGAffineTransformIdentity;
		g_pill_lbl.hidden = YES;
		g_lock_win.alpha = 1.0;
		g_lock_win.hidden = NO;
	});
}

static void
animate_unlocked_icon(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		ensure_lock_ui();
		g_lock_icon.hidden = NO;
		g_pill_lbl.hidden = YES;
		g_lock_icon.tintColor = [UIColor systemGreenColor];
		g_lock_icon.image = [UIImage systemImageNamed:@"lock.open.fill"];

		/* iPhone X style pop spring animation */
		g_lock_icon.transform = CGAffineTransformMakeScale(0.7, 0.7);
		[UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.45 initialSpringVelocity:6.0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
			g_lock_icon.transform = CGAffineTransformMakeScale(1.15, 1.15);
		} completion:^(BOOL finished) {
			[UIView animateWithDuration:0.2 animations:^{
				g_lock_icon.transform = CGAffineTransformIdentity;
			}];
		}];
	});
}

static void
show_pill(NSString *text, UIColor *tint, NSTimeInterval autoHide)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		ensure_lock_ui();
		g_lock_icon.hidden = YES;
		g_pill_lbl.hidden = NO;
		g_pill_lbl.text = text;
		g_pill_lbl.textColor = tint ?: [UIColor whiteColor];
		g_lock_win.alpha = 1.0;
		g_lock_win.hidden = NO;

		if (autoHide > 0) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(autoHide * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				[UIView animateWithDuration:0.25 animations:^{
					g_lock_win.alpha = 0.0;
				} completion:^(BOOL finished) {
					if (g_lock_win.alpha == 0.0) g_lock_win.hidden = YES;
				}];
			});
		}
	});
}

static void
hide_lock_ui(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (g_lock_win) {
			[UIView animateWithDuration:0.2 animations:^{
				g_lock_win.alpha = 0.0;
			} completion:^(BOOL finished) {
				g_lock_win.hidden = YES;
			}];
		}
	});
}

static void
unlock_lockscreen_ui(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		Class cls = objc_getClass("SBLockScreenManager");
		if (!cls) return;
		id mgr = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("sharedInstanceIfExists"));
		if (!mgr) mgr = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("sharedInstance"));
		if (!mgr) return;
		SEL sel = sel_registerName("_attemptUnlockWithPasscode:mesa:finishUIUnlock:");
		if ([mgr respondsToSelector:sel]) {
			((void (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(mgr, sel, nil, YES, !g_stay_on_lock);
		}
	});
}

static void
maybe_start_face_scan(void)
{
	load_prefs();
	if (get_notify_state(g_tok_blank) != 0) return;  /* screen off */
	if (get_notify_state(g_tok_lock) == 0) return;   /* already unlocked */
	if (get_notify_state(g_tok_state) == 0) return;  /* not enrolled */

	/* Always show locked padlock icon on Lock Screen */
	show_locked_icon();

	if (!g_enabled || g_scanning) return;
	if (get_notify_state(g_tok_prox) != 0) return;   /* pocket / near */

	g_scanning = YES;
	faced_send_async("SCAN\n", ^(NSString *reply) {
		g_scanning = NO;
		if ([reply hasPrefix:@"MATCH"]) {
			animate_unlocked_icon();
			notify_post("com.sapphire.vib.success");
			if (!g_stay_on_lock) {
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
					hide_lock_ui();
				});
			}
		} else if ([reply hasPrefix:@"NOMATCH"]) {
			show_pill(@"Face Not Recognized", [UIColor systemOrangeColor], 1.5);
			notify_post("com.sapphire.vib.error");
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
				if (get_notify_state(g_tok_lock) != 0) show_locked_icon();
			});
		}
	});
}

__attribute__((constructor)) static void
sapphire_faceid_init(void)
{
	NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
	if (![bid isEqualToString:@"com.apple.springboard"]) return;

	notify_register_check("com.apple.springboard.hasBlankedScreen", &g_tok_blank);
	notify_register_check("com.apple.springboard.lockstate", &g_tok_lock);
	notify_register_check("com.sapphire.face.state", &g_tok_state);
	notify_register_check("com.sapphire.sensor.prox", &g_tok_prox);

	int t1 = 0, t2 = 0, t3 = 0;
	notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &t1, dispatch_get_main_queue(), ^(int token) {
		uint64_t blanked = 0;
		notify_get_state(token, &blanked);
		if (blanked == 0) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
				maybe_start_face_scan();
			});
		} else {
			if (g_scanning) {
				faced_send_async("STOP\n", nil);
				g_scanning = NO;
			}
			hide_lock_ui();
		}
	});

	notify_register_dispatch("com.apple.springboard.lockstate", &t2, dispatch_get_main_queue(), ^(int token) {
		uint64_t locked = 0;
		notify_get_state(token, &locked);
		if (locked == 0) {
			if (g_scanning) {
				faced_send_async("STOP\n", nil);
				g_scanning = NO;
			}
			hide_lock_ui();
		} else {
			maybe_start_face_scan();
		}
	});

	notify_register_dispatch("com.sapphire.face.unlocked", &t3, dispatch_get_main_queue(), ^(int token) {
		(void)token;
		load_prefs();
		animate_unlocked_icon();
		unlock_lockscreen_ui();
	});
}
