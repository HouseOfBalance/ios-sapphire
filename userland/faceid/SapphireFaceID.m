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
static UIWindow *g_pill_win = nil;
static UILabel *g_pill_lbl = nil;

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
show_pill(NSString *text, UIColor *tint, NSTimeInterval autoHide)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!g_pill_win) {
			CGRect sb = [UIScreen mainScreen].bounds;
			g_pill_win = [[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width - 170) / 2.0, 52, 170, 32)];
			g_pill_win.windowLevel = UIWindowLevelAlert + 50;
			g_pill_win.backgroundColor = [UIColor clearColor];
			g_pill_win.userInteractionEnabled = NO;

			UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
			blur.frame = g_pill_win.bounds;
			blur.layer.cornerRadius = 16;
			blur.clipsToBounds = YES;
			[g_pill_win addSubview:blur];

			g_pill_lbl = [[UILabel alloc] initWithFrame:blur.bounds];
			g_pill_lbl.textAlignment = NSTextAlignmentCenter;
			g_pill_lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
			[blur.contentView addSubview:g_pill_lbl];
		}
		g_pill_lbl.text = text;
		g_pill_lbl.textColor = tint ?: [UIColor whiteColor];
		g_pill_win.alpha = 1.0;
		g_pill_win.hidden = NO;

		if (autoHide > 0) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(autoHide * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				[UIView animateWithDuration:0.25 animations:^{
					g_pill_win.alpha = 0.0;
				} completion:^(BOOL finished) {
					(void)finished;
					if (g_pill_win.alpha == 0.0) g_pill_win.hidden = YES;
				}];
			});
		}
	});
}

static void
hide_pill(void)
{
	dispatch_async(dispatch_get_main_queue(), ^{
		if (g_pill_win) g_pill_win.hidden = YES;
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
	if (!g_enabled || g_scanning) return;
	if (get_notify_state(g_tok_blank) != 0) return;  /* screen off */
	if (get_notify_state(g_tok_lock) == 0) return;   /* already unlocked */
	if (get_notify_state(g_tok_state) == 0) return;  /* not enrolled */
	if (get_notify_state(g_tok_prox) != 0) return;   /* pocket / near */

	g_scanning = YES;
	show_pill(@"Face ID...", [UIColor whiteColor], 0);
	faced_send_async("SCAN\n", ^(NSString *reply) {
		g_scanning = NO;
		if ([reply hasPrefix:@"MATCH"]) {
			show_pill(@"Unlocked", [UIColor systemGreenColor], 1.2);
		} else if ([reply hasPrefix:@"NOMATCH"]) {
			show_pill(@"Face Not Recognized", [UIColor systemOrangeColor], 1.2);
		} else {
			hide_pill();
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
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
				maybe_start_face_scan();
			});
		} else {
			if (g_scanning) {
				faced_send_async("STOP\n", nil);
				g_scanning = NO;
			}
			hide_pill();
		}
	});

	notify_register_dispatch("com.apple.springboard.lockstate", &t2, dispatch_get_main_queue(), ^(int token) {
		uint64_t locked = 0;
		notify_get_state(token, &locked);
		if (locked == 0 && g_scanning) {
			faced_send_async("STOP\n", nil);
			g_scanning = NO;
			hide_pill();
		}
	});

	notify_register_dispatch("com.sapphire.face.unlocked", &t3, dispatch_get_main_queue(), ^(int token) {
		(void)token;
		load_prefs();
		unlock_lockscreen_ui();
	});
}
