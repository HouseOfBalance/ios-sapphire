// SapphireTools — main.m
// Cong cu cau hinh / chan doan cho ban port iOS 16.7 tren Redmi Note 13 4G
// (sapphire / SM6225 / Adreno 610).
//
// Objective-C + UIKit thuan, UI dung hoan toan bang code (khong Storyboard/XIB).
// Build: xem Makefile (clang + iOS SDK, ky bang ldid -Sentitlements.plist).

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

#ifndef CTL_SYSCTL
#define CTL_SYSCTL 0
#endif
#ifndef CTL_SYSCTL_OIDFMT
#define CTL_SYSCTL_OIDFMT 4
#endif
#ifndef CTL_MAXNAME
#define CTL_MAXNAME 12
#endif

#pragma mark - Constants

static NSString *const kSysMetal      = @"kern.sweet_metal";
static NSString *const kSysRScale     = @"kern.sweet_fb_rscale";
static NSString *const kSysFlipFlush  = @"kern.sweet_fb_flipflush";
static NSString *const kSysTapWake    = @"kern.sweet_tap_wake";
static NSString *const kSysQuietMs    = @"kern.sweet_touch_quiet_ms";
static NSString *const kSysStaleMs    = @"kern.sweet_touch_stale_ms";
static NSString *const kSysTouchRate  = @"kern.sweet_touch_rate";
static NSString *const kSysFrameStats = @"kern.sweet_fb_frame_stats";
static NSString *const kSysSurface    = @"kern.sweet_fb_surface";
static NSString *const kSysBootargs   = @"kern.bootargs";

static NSString *const kMetalArgsPath = @"/var/tmp/metal.args";
static NSString *const kSweetLogPath  = @"/var/log/sweetlog.txt";
static const NSUInteger kLogLines     = 80;

enum { kTagRScale = 100, kTagQuiet = 101, kTagStale = 102 };

static NSArray<NSString *> *SWMetalKeys(void) {
    return @[@"metal_gmem", @"metal_defer", @"metal_stats"];
}

#pragma mark - Small helpers

static NSString *SWErrText(int e) {
    return [NSString stringWithFormat:@"errno %d: %s", e, strerror(e)];
}

static NSString *SWNAText(int e) {
    if (e == 0 || e == ENOENT) return @"N/A";
    return [NSString stringWithFormat:@"N/A (%@)", SWErrText(e)];
}

static UILabel *SWMakeLabel(UIFont *font, UIColor *color, NSInteger lines) {
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = color;
    l.numberOfLines = lines;
    return l;
}

static UILabel *SWValueLabel(void) {
    UILabel *l = SWMakeLabel([UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular],
                             UIColor.secondaryLabelColor, 1);
    l.textAlignment = NSTextAlignmentRight;
    return l;
}

static UILabel *SWMonoLabel(NSInteger lines) {
    UILabel *l = SWMakeLabel([UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular],
                             UIColor.secondaryLabelColor, lines);
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

static void SWSetValue(UILabel *l, NSString *text) {
    l.text = text;
    l.hidden = (text.length == 0);
}

static UIViewController *SWTopViewController(UIViewController *vc) {
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void SWToast(UIView *anchor, NSString *msg) {
    UIWindow *w = anchor.window;
    if (!w) return;
    UILabel *l = SWMakeLabel([UIFont systemFontOfSize:14 weight:UIFontWeightMedium], UIColor.whiteColor, 0);
    l.text = msg;
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    l.layer.cornerRadius = 12;
    l.clipsToBounds = YES;
    CGFloat maxW = w.bounds.size.width - 40;
    CGSize s = [l sizeThatFits:CGSizeMake(maxW - 28, CGFLOAT_MAX)];
    CGFloat width = MIN(s.width + 28, maxW);
    CGFloat height = s.height + 20;
    l.frame = CGRectMake((w.bounds.size.width - width) / 2,
                         w.bounds.size.height - w.safeAreaInsets.bottom - height - 24,
                         width, height);
    l.alpha = 0;
    [w addSubview:l];
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:1.4 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL f2) { [l removeFromSuperview]; }];
    }];
}

#pragma mark - sysctl wrapper

typedef NS_ENUM(NSInteger, SWKind) {
    SWKindUnknown = 0,
    SWKindString,
    SWKindInt32,   // CTLTYPE_INT (kich thuoc thuc te lay tu do dai du lieu: 4 hoac 8)
    SWKindInt64,   // CTLTYPE_QUAD
    SWKindStruct   // CTLTYPE_OPAQUE
};

@interface SWSysctl : NSObject
+ (BOOL)exists:(NSString *)name;
+ (NSString *)stringForName:(NSString *)name errnoOut:(int *)err;
+ (BOOL)getInteger:(long long *)out name:(NSString *)name errnoOut:(int *)err;
+ (BOOL)setInteger:(long long)v name:(NSString *)name errnoOut:(int *)err;
+ (BOOL)setString:(NSString *)s name:(NSString *)name errnoOut:(int *)err;
@end

@implementation SWSysctl

// Lay kieu cua OID qua sysctl magic {0, 4, <oid...>} (CTL_SYSCTL_OIDFMT).
+ (SWKind)kindForName:(NSString *)name {
    int q[CTL_MAXNAME + 2];
    size_t n = CTL_MAXNAME;
    q[0] = CTL_SYSCTL;
    q[1] = CTL_SYSCTL_OIDFMT;
    if (sysctlnametomib(name.UTF8String, q + 2, &n) != 0) return SWKindUnknown;
    unsigned char buf[256];
    size_t len = sizeof(buf);
    if (sysctl(q, (u_int)(n + 2), buf, &len, NULL, 0) != 0 || len < sizeof(uint32_t)) return SWKindUnknown;
    uint32_t k = 0;
    memcpy(&k, buf, sizeof(k));
    switch (k & 0xf) {
        case 2: return SWKindInt32;
        case 3: return SWKindString;
        case 4: return SWKindInt64;
        case 5: return SWKindStruct;
        default: return SWKindUnknown;
    }
}

+ (NSData *)readRaw:(NSString *)name errnoOut:(int *)err {
    const char *n = name.UTF8String;
    for (int attempt = 0; attempt < 4; attempt++) {
        size_t len = 0;
        if (sysctlbyname(n, NULL, &len, NULL, 0) != 0) {
            if (err) *err = errno;
            return nil;
        }
        size_t cap = len + 256;
        NSMutableData *d = [NSMutableData dataWithLength:cap];
        size_t got = cap;
        if (sysctlbyname(n, d.mutableBytes, &got, NULL, 0) == 0) {
            d.length = got;
            return d;
        }
        if (errno != ENOMEM) {
            if (err) *err = errno;
            return nil;
        }
    }
    if (err) *err = ENOMEM;
    return nil;
}

+ (BOOL)exists:(NSString *)name {
    size_t len = 0;
    return sysctlbyname(name.UTF8String, NULL, &len, NULL, 0) == 0;
}

+ (BOOL)isStringData:(NSData *)d kind:(SWKind)k {
    if (k == SWKindString) return YES;
    if (k != SWKindUnknown) return NO;
    // Khong lay duoc OID format: doan theo noi dung.
    const unsigned char *b = d.bytes;
    NSUInteger n = d.length;
    if (n == 4 || n == 8) return NO;
    if (n == 0) return YES;
    for (NSUInteger i = 0; i < n; i++) {
        unsigned char c = b[i];
        if (c == 0) return i == n - 1;
        if (c >= 0x7f) return NO;
        if (c < 0x20 && c != '\n' && c != '\t' && c != '\r') return NO;
    }
    return YES;
}

+ (NSString *)stringFromData:(NSData *)d {
    if (d.length == 0) return @"";
    NSUInteger l = strnlen((const char *)d.bytes, d.length);
    NSString *s = [[NSString alloc] initWithBytes:d.bytes length:l encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithBytes:d.bytes length:l encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

+ (NSString *)stringForName:(NSString *)name errnoOut:(int *)err {
    NSData *d = [self readRaw:name errnoOut:err];
    if (!d) return nil;
    SWKind k = [self kindForName:name];
    if ([self isStringData:d kind:k]) return [self stringFromData:d];
    if (k != SWKindStruct && d.length == 4) {
        int32_t v = 0;
        memcpy(&v, d.bytes, 4);
        return [NSString stringWithFormat:@"%d", v];
    }
    if (k != SWKindStruct && d.length == 8) {
        int64_t v = 0;
        memcpy(&v, d.bytes, 8);
        return [NSString stringWithFormat:@"%lld", (long long)v];
    }
    NSMutableString *h = [NSMutableString stringWithString:@"0x"];
    const unsigned char *b = d.bytes;
    for (NSUInteger i = 0; i < d.length && i < 256; i++) [h appendFormat:@"%02x", b[i]];
    return h;
}

+ (BOOL)getInteger:(long long *)out name:(NSString *)name errnoOut:(int *)err {
    NSData *d = [self readRaw:name errnoOut:err];
    if (!d) return NO;
    SWKind k = [self kindForName:name];
    if ([self isStringData:d kind:k]) {
        const char *c = [self stringFromData:d].UTF8String;
        char *end = NULL;
        long long v = strtoll(c, &end, 0);
        if (end == c) {
            if (err) *err = EINVAL;
            return NO;
        }
        if (out) *out = v;
        return YES;
    }
    if (k != SWKindStruct && d.length == 4) {
        int32_t v = 0;
        memcpy(&v, d.bytes, 4);
        if (out) *out = v;
        return YES;
    }
    if (k != SWKindStruct && d.length == 8) {
        int64_t v = 0;
        memcpy(&v, d.bytes, 8);
        if (out) *out = v;
        return YES;
    }
    if (err) *err = EINVAL;
    return NO;
}

+ (BOOL)setString:(NSString *)s name:(NSString *)name errnoOut:(int *)err {
    const char *n = name.UTF8String;
    const char *c = s.UTF8String;
    size_t l = strlen(c);
    int rc = sysctlbyname(n, NULL, NULL, (void *)c, l);
    if (rc != 0 && errno == EINVAL) rc = sysctlbyname(n, NULL, NULL, (void *)c, l + 1);
    if (rc != 0) {
        if (err) *err = errno;
        return NO;
    }
    return YES;
}

+ (BOOL)setInteger:(long long)v name:(NSString *)name errnoOut:(int *)err {
    const char *n = name.UTF8String;
    size_t len = 0;
    if (sysctlbyname(n, NULL, &len, NULL, 0) != 0) {
        if (err) *err = errno;
        return NO;
    }
    SWKind k = [self kindForName:name];
    BOOL asString = (k == SWKindString) || (k == SWKindUnknown && len != 4 && len != 8);
    if (asString) {
        return [self setString:[NSString stringWithFormat:@"%lld", v] name:name errnoOut:err];
    }
    int rc;
    if (len == 8) {
        int64_t x = (int64_t)v;
        rc = sysctlbyname(n, NULL, NULL, &x, sizeof(x));
    } else {
        int32_t x = (int32_t)v;
        rc = sysctlbyname(n, NULL, NULL, &x, sizeof(x));
    }
    if (rc != 0) {
        if (err) *err = errno;
        return NO;
    }
    return YES;
}

@end

#pragma mark - Process helpers (posix_spawn / kill / reboot / log)

// Chay mot file thuc thi. Tra ve exit code, hoac -1 (kem *errOut != 0 neu spawn loi).
static int SWSpawnPath(const char *path, NSArray<NSString *> *args, NSString **output, int *errOut) {
    int fds[2] = {-1, -1};
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (output) {
        if (pipe(fds) != 0) {
            if (errOut) *errOut = errno;
            posix_spawn_file_actions_destroy(&fa);
            return -1;
        }
        posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&fa, fds[0]);
        posix_spawn_file_actions_addclose(&fa, fds[1]);
    } else {
        posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    }

    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = (char *)args[i].UTF8String;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, &fa, NULL, argv, environ);
    free(argv);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) {
        if (output) { close(fds[0]); close(fds[1]); }
        if (errOut) *errOut = rc;
        return -1;
    }

    NSMutableData *buf = nil;
    if (output) {
        close(fds[1]);
        buf = [NSMutableData data];
        char tmp[4096];
        ssize_t n;
        while ((n = read(fds[0], tmp, sizeof(tmp))) != 0) {
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (buf.length < 8u * 1024u * 1024u) [buf appendBytes:tmp length:(NSUInteger)n];
        }
        close(fds[0]);
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }

    if (output) {
        NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
        *output = s ?: @"";
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

// Thu lan luot cac duong dan, chay cai dau tien ton tai va thuc thi duoc.
static int SWRunFirst(NSArray<NSString *> *paths, NSArray<NSString *> *args, NSString **output, int *errOut) {
    int lastErr = ENOENT;
    for (NSString *p in paths) {
        if (access(p.fileSystemRepresentation, X_OK) != 0) continue;
        int e = 0;
        int rc = SWSpawnPath(p.fileSystemRepresentation, args, output, &e);
        if (rc == -1 && e != 0) {
            lastErr = e;
            continue;
        }
        return rc;
    }
    if (errOut) *errOut = lastErr;
    return -1;
}

// Du phong khi khong co killall: duyet KERN_PROC_ALL va kill theo ten.
static int SWKillByName(const char *name, int sig) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0) return -1;
    len += 16 * sizeof(struct kinfo_proc);
    struct kinfo_proc *procs = malloc(len);
    if (!procs) {
        errno = ENOMEM;
        return -1;
    }
    if (sysctl(mib, 3, procs, &len, NULL, 0) != 0) {
        int e = errno;
        free(procs);
        errno = e;
        return -1;
    }
    size_t count = len / sizeof(struct kinfo_proc);
    int killed = 0, lastErr = 0;
    for (size_t i = 0; i < count; i++) {
        if (procs[i].kp_proc.p_pid > 1 &&
            strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            if (kill(procs[i].kp_proc.p_pid, sig) == 0) killed++;
            else lastErr = errno;
        }
    }
    free(procs);
    if (killed == 0 && lastErr != 0) {
        errno = lastErr;
        return -1;
    }
    return killed;
}

static BOOL SWKillProcesses(NSArray<NSString *> *names, NSString **errMsg) {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"killall", @"-9", nil];
    [args addObjectsFromArray:names];
    int spawnErr = 0;
    int rc = SWRunFirst(@[@"/usr/bin/killall", @"/bin/killall", @"/usr/sbin/killall",
                          @"/var/jb/usr/bin/killall"], args, nil, &spawnErr);
    if (rc == 0) return YES;

    int total = 0, lastErr = 0;
    for (NSString *n in names) {
        int k = SWKillByName(n.UTF8String, SIGKILL);
        if (k > 0) total += k;
        else if (k < 0) lastErr = errno;
    }
    if (total > 0) return YES;

    if (errMsg) {
        NSString *a = (rc == -1) ? [NSString stringWithFormat:@"killall not runnable (%@)", SWErrText(spawnErr)]
                                 : [NSString stringWithFormat:@"killall exited with status %d", rc];
        NSString *b = lastErr ? [NSString stringWithFormat:@"direct kill failed (%@)", SWErrText(lastErr)]
                              : @"no matching process found";
        *errMsg = [NSString stringWithFormat:@"%@; %@.", a, b];
    }
    return NO;
}

static BOOL SWReboot(NSString **errMsg) {
    sync();
    int spawnErr = 0;
    int rc = SWRunFirst(@[@"/sbin/reboot", @"/usr/sbin/reboot", @"/usr/bin/reboot",
                          @"/var/jb/usr/sbin/reboot"], @[@"reboot"], nil, &spawnErr);
    if (rc == 0) return YES;

    int (*rebootFn)(int) = (int (*)(int))dlsym(RTLD_DEFAULT, "reboot");
    int e = 0;
    if (rebootFn) {
        if (rebootFn(0) == 0) return YES;
        e = errno;
    }
    if (errMsg) {
        *errMsg = [NSString stringWithFormat:@"reboot failed (%@). The app probably is not running as root.",
                   SWErrText(e ? e : spawnErr)];
    }
    return NO;
}

static NSString *SWReadTailOfFile(NSString *path, NSUInteger maxBytes) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!d) return nil;
    NSUInteger len = d.length, start = 0;
    BOOL cut = NO;
    if (len > maxBytes) {
        start = len - maxBytes;
        cut = YES;
    }
    NSData *sub = [d subdataWithRange:NSMakeRange(start, len - start)];
    if (cut && sub.length > 0) {
        const unsigned char *b = sub.bytes;
        const unsigned char *nl = memchr(b, '\n', sub.length);
        if (nl) {
            NSUInteger off = (NSUInteger)(nl - b) + 1;
            sub = [sub subdataWithRange:NSMakeRange(off, sub.length - off)];
        }
    }
    NSString *s = [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:sub encoding:NSISOLatin1StringEncoding];
    return s;
}

static NSArray<NSString *> *SWTailLines(NSString *text, BOOL filtered, NSUInteger count) {
    NSArray<NSString *> *keys = @[@"SWEET FB", @"SWEET TOUCH", @"SWEET MEM", @"hakios"];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if (line.length == 0) return;
        if (filtered) {
            BOOL hit = NO;
            for (NSString *k in keys) {
                if ([line rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    hit = YES;
                    break;
                }
            }
            if (!hit) return;
        }
        [out addObject:line];
    }];
    if (out.count > count) [out removeObjectsInRange:NSMakeRange(0, out.count - count)];
    return out;
}

// Doc 80 dong cuoi tu /var/log/sweetlog.txt, neu khong co thi tu dmesg.
static NSString *SWFetchKernelLog(BOOL filtered, NSString **sourceOut) {
    NSString *fileText = SWReadTailOfFile(kSweetLogPath, 1024 * 1024);
    if (fileText) {
        NSArray<NSString *> *lines = SWTailLines(fileText, filtered, kLogLines);
        if (lines.count > 0) {
            if (sourceOut) *sourceOut = kSweetLogPath;
            return [lines componentsJoinedByString:@"\n"];
        }
    }

    NSString *dmesg = nil;
    int err = 0;
    int rc = SWRunFirst(@[@"/sbin/dmesg", @"/usr/sbin/dmesg", @"/usr/bin/dmesg", @"/bin/dmesg"],
                        @[@"dmesg"], &dmesg, &err);
    if (rc >= 0 && dmesg) {
        NSArray<NSString *> *lines = SWTailLines(dmesg, filtered, kLogLines);
        if (sourceOut) *sourceOut = @"dmesg";
        if (lines.count > 0) return [lines componentsJoinedByString:@"\n"];
        return filtered ? @"(no matching SWEET FB / SWEET TOUCH / SWEET MEM / hakios lines in dmesg)"
                        : @"(dmesg is empty)";
    }

    if (fileText) {
        if (sourceOut) *sourceOut = kSweetLogPath;
        return filtered ? @"(no matching lines in /var/log/sweetlog.txt, and dmesg is not available)"
                        : @"(/var/log/sweetlog.txt is empty, and dmesg is not available)";
    }
    if (sourceOut) *sourceOut = @"N/A";
    return [NSString stringWithFormat:@"Cannot read %@ and cannot run dmesg (%@).",
            kSweetLogPath, SWErrText(err ? err : ENOENT)];
}

#pragma mark - Log viewer

@interface SWLogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UISegmentedControl *filterControl;
@end

@implementation SWLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"Filtered", @"All"]];
    self.filterControl.selectedSegmentIndex = 0;
    [self.filterControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.filterControl;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(closeTapped)];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"Copy"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self action:@selector(copyTapped)];
    UIBarButtonItem *refresh =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reload)];
    self.navigationItem.rightBarButtonItems = @[copy, refresh];

    self.sourceLabel = SWMakeLabel([UIFont systemFontOfSize:11], UIColor.secondaryLabelColor, 1);
    self.sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.sourceLabel];

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.textColor = UIColor.labelColor;
    self.textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.textView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    self.textView.layoutManager.allowsNonContiguousLayout = NO;
    [self.view addSubview:self.textView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.sourceLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:6],
        [self.sourceLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.sourceLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.textView.topAnchor constraintEqualToAnchor:self.sourceLabel.bottomAnchor constant:6],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self reload];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyTapped {
    UIPasteboard.generalPasteboard.string = self.textView.text ?: @"";
    SWToast(self.view, @"Log copied");
}

- (void)reload {
    BOOL filtered = (self.filterControl.selectedSegmentIndex == 0);
    self.sourceLabel.text = @"Loading…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *src = nil;
        NSString *text = SWFetchKernelLog(filtered, &src);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            s.textView.text = text;
            s.sourceLabel.text = [NSString stringWithFormat:@"Source: %@ • last %lu lines%@",
                                  src ?: @"N/A", (unsigned long)kLogLines, filtered ? @" (filtered)" : @""];
            [s.textView layoutIfNeeded];
            [s.textView scrollRangeToVisible:NSMakeRange(s.textView.text.length, 0)];
        });
    });
}

@end

#pragma mark - Main view controller

@interface SWMainViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UITableViewCell *> *> *sections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(void)> *actions;

// Graphics & Metal
@property (nonatomic, strong) UISegmentedControl *metalSeg;
@property (nonatomic, strong) UILabel *metalValue;
@property (nonatomic, strong) UISlider *rscaleSlider;
@property (nonatomic, strong) UILabel *rscaleValue;
@property (nonatomic, strong) UISwitch *flushSwitch;
@property (nonatomic, strong) UILabel *flushValue;
@property (nonatomic, strong) NSArray<UISwitch *> *metalSwitches;
@property (nonatomic, strong) UILabel *metalArgsLabel;

// Touch
@property (nonatomic, strong) UISegmentedControl *tapSeg;
@property (nonatomic, strong) UILabel *tapValue;
@property (nonatomic, strong) UISlider *quietSlider;
@property (nonatomic, strong) UILabel *quietValue;
@property (nonatomic, strong) UISlider *staleSlider;
@property (nonatomic, strong) UILabel *staleValue;
@property (nonatomic, strong) UILabel *touchRateLabel;

// Diagnostics
@property (nonatomic, strong) UILabel *frameStatsLabel;
@property (nonatomic, strong) UILabel *surfaceLabel;
@property (nonatomic, strong) UILabel *bootargsLabel;
@property (nonatomic, strong) UISwitch *autoSwitch;
@property (nonatomic, copy) NSString *frameStatsFull;
@property (nonatomic, copy) NSString *surfaceFull;
@property (nonatomic, copy) NSString *bootargsFull;

@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) BOOL appActive;
@end

@implementation SWMainViewController

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SapphireTools";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(refreshTapped)];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.appActive = YES;

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 64;
    self.table.cellLayoutMarginsFollowReadableWidth = NO;
    [self.view addSubview:self.table];

    [self buildSections];
    [self refreshControls];
    [self refreshLive];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(appBecameActive)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appResigned)
               name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.visible = YES;
    [self refreshControls];
    [self refreshLive];
    [self updateTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.visible = NO;
    [self updateTimer];
}

- (void)appBecameActive {
    self.appActive = YES;
    if (self.visible) {
        [self refreshControls];
        [self refreshLive];
    }
    [self updateTimer];
}

- (void)appResigned {
    self.appActive = NO;
    [self updateTimer];
}

- (void)updateTimer {
    BOOL want = self.visible && self.appActive && self.autoSwitch.isOn;
    if (want && !self.timer) {
        __weak typeof(self) ws = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            [ws refreshLive];
        }];
        self.timer.tolerance = 0.3;
    } else if (!want && self.timer) {
        [self.timer invalidate];
        self.timer = nil;
    }
}

#pragma mark Building the UI

- (UISlider *)makeSliderMin:(float)min max:(float)max tag:(NSInteger)tag {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = min;
    s.maximumValue = max;
    s.tag = tag;
    s.continuous = YES;
    [s addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [s addTarget:self action:@selector(sliderReleased:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return s;
}

// Hang chu: [title ........ value] va control (o ben phai hoac nam ben duoi).
- (UITableViewCell *)cellWithTitle:(NSString *)title
                             value:(UILabel *)value
                           control:(UIView *)control
                             below:(BOOL)below {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *t = SWMakeLabel([UIFont systemFontOfSize:16], UIColor.labelColor, 0);
    t.text = title;
    [t setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [t setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *top = [[UIStackView alloc] init];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 8;
    [top addArrangedSubview:t];
    if (value) {
        [value setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [value setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [top addArrangedSubview:value];
    }
    if (control && !below) {
        [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [top addArrangedSubview:control];
    }

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[top]];
    col.axis = UILayoutConstraintAxisVertical;
    col.alignment = UIStackViewAlignmentFill;
    col.spacing = 8;
    if (control && below) [col addArrangedSubview:control];

    col.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:col];
    UILayoutGuide *g = cell.contentView.layoutMarginsGuide;
    NSLayoutConstraint *bottom = [col.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10];
    bottom.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [col.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        bottom,
        [col.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
    ]];
    return cell;
}

- (UITableViewCell *)buttonCellWithTitle:(NSString *)title color:(UIColor *)color {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.textLabel.text = title;
    c.textLabel.textAlignment = NSTextAlignmentCenter;
    c.textLabel.textColor = color;
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    return c;
}

- (void)addCell:(UITableViewCell *)cell toSection:(NSUInteger)s action:(void (^)(void))action {
    NSMutableArray<UITableViewCell *> *rows = self.sections[s];
    if (action) {
        NSString *key = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)s, (unsigned long)rows.count];
        self.actions[key] = [action copy];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    [rows addObject:cell];
}

- (void)buildSections {
    __weak typeof(self) ws = self;
    self.sections = [NSMutableArray array];
    for (int i = 0; i < 4; i++) [self.sections addObject:[NSMutableArray array]];
    self.actions = [NSMutableDictionary dictionary];

    // ---------- Section 0: Graphics & Metal ----------
    self.metalSeg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"SapphireMetal", @"HakiosMetal"]];
    [self.metalSeg addTarget:self action:@selector(metalChanged:) forControlEvents:UIControlEventValueChanged];
    self.metalValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Metal mode (kern.sweet_metal)" value:self.metalValue
                              control:self.metalSeg below:YES] toSection:0 action:nil];

    self.rscaleSlider = [self makeSliderMin:400 max:1000 tag:kTagRScale];
    self.rscaleValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"FB render scale (kern.sweet_fb_rscale)" value:self.rscaleValue
                              control:self.rscaleSlider below:YES] toSection:0 action:nil];

    self.flushSwitch = [[UISwitch alloc] init];
    [self.flushSwitch addTarget:self action:@selector(flushChanged:) forControlEvents:UIControlEventValueChanged];
    self.flushValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"FB flip flush (kern.sweet_fb_flipflush)" value:self.flushValue
                              control:self.flushSwitch below:NO] toSection:0 action:nil];

    NSMutableArray<UISwitch *> *sw = [NSMutableArray array];
    NSArray<NSString *> *keys = SWMetalKeys();
    for (NSUInteger i = 0; i < keys.count; i++) {
        UISwitch *s = [[UISwitch alloc] init];
        s.tag = (NSInteger)i;
        [s addTarget:self action:@selector(metalFlagChanged:) forControlEvents:UIControlEventValueChanged];
        [sw addObject:s];
        [self addCell:[self cellWithTitle:[NSString stringWithFormat:@"%@=1 (metal.args)", keys[i]]
                                    value:nil control:s below:NO] toSection:0 action:nil];
    }
    self.metalSwitches = sw;

    self.metalArgsLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:kMetalArgsPath value:nil control:self.metalArgsLabel below:YES]
        toSection:0 action:nil];

    // ---------- Section 1: Touch ----------
    self.tapSeg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Single Tap", @"Double Tap"]];
    [self.tapSeg addTarget:self action:@selector(tapWakeChanged:) forControlEvents:UIControlEventValueChanged];
    self.tapValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Tap to wake (kern.sweet_tap_wake)" value:self.tapValue
                              control:self.tapSeg below:YES] toSection:1 action:nil];

    self.quietSlider = [self makeSliderMin:0 max:200 tag:kTagQuiet];
    self.quietValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Touch quiet (kern.sweet_touch_quiet_ms)" value:self.quietValue
                              control:self.quietSlider below:YES] toSection:1 action:nil];

    self.staleSlider = [self makeSliderMin:1000 max:10000 tag:kTagStale];
    self.staleValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Touch stale (kern.sweet_touch_stale_ms)" value:self.staleValue
                              control:self.staleSlider below:YES] toSection:1 action:nil];

    self.touchRateLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"Touch rate (kern.sweet_touch_rate)" value:nil
                              control:self.touchRateLabel below:YES] toSection:1 action:nil];

    [self addCell:[self buttonCellWithTitle:@"Reset Touch Rate" color:UIColor.systemBlueColor]
        toSection:1 action:^{ [ws resetTouchRate]; }];

    // ---------- Section 2: Live Diagnostics ----------
    self.frameStatsLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"Frame stats (kern.sweet_fb_frame_stats)" value:nil
                              control:self.frameStatsLabel below:YES]
        toSection:2 action:^{ [ws showValueTitle:kSysFrameStats text:ws.frameStatsFull]; }];

    self.surfaceLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"FB surface (kern.sweet_fb_surface)" value:nil
                              control:self.surfaceLabel below:YES]
        toSection:2 action:^{ [ws showValueTitle:kSysSurface text:ws.surfaceFull]; }];

    self.bootargsLabel = SWMonoLabel(3);
    [self addCell:[self cellWithTitle:@"Boot args (kern.bootargs)" value:nil
                              control:self.bootargsLabel below:YES]
        toSection:2 action:^{ [ws showValueTitle:kSysBootargs text:ws.bootargsFull]; }];

    self.autoSwitch = [[UISwitch alloc] init];
    self.autoSwitch.on = YES;
    [self.autoSwitch addTarget:self action:@selector(autoToggled:) forControlEvents:UIControlEventValueChanged];
    [self addCell:[self cellWithTitle:@"Auto refresh (every 2 s)" value:nil control:self.autoSwitch below:NO]
        toSection:2 action:nil];

    [self addCell:[self buttonCellWithTitle:@"Refresh now" color:UIColor.systemBlueColor]
        toSection:2 action:^{ [ws refreshTapped]; }];

    [self addCell:[self buttonCellWithTitle:@"View Recent Kernel Log" color:UIColor.systemBlueColor]
        toSection:2 action:^{ [ws showKernelLog]; }];

    // ---------- Section 3: Power & Actions ----------
    [self addCell:[self buttonCellWithTitle:@"Respring" color:UIColor.systemBlueColor]
        toSection:3 action:^{
            [ws runKill:@[@"backboardd", @"SpringBoard"] title:@"Respring failed"];
        }];
    [self addCell:[self buttonCellWithTitle:@"Restart SpringBoard only" color:UIColor.systemBlueColor]
        toSection:3 action:^{
            [ws runKill:@[@"SpringBoard"] title:@"Restart SpringBoard failed"];
        }];
    [self addCell:[self buttonCellWithTitle:@"Reboot" color:UIColor.systemRedColor]
        toSection:3 action:^{ [ws confirmReboot]; }];
}

#pragma mark Table data source / delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.sections[(NSUInteger)section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    return self.sections[(NSUInteger)ip.section][(NSUInteger)ip.row];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Graphics & Metal";
        case 1: return @"Touch";
        case 2: return @"Live Diagnostics";
        default: return @"Power & Actions";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return @"kern.sweet_* values are applied immediately. metal.args is read when a Metal client starts, "
                   @"so respring or relaunch the app to apply changes.";
        case 1:
            return @"Touch parameters are applied by the kernel immediately.";
        case 2:
            return @"Auto refresh runs while this screen is visible. Tap a value to view or copy it in full.";
        default:
            return [NSString stringWithFormat:@"Running as uid=%d euid=%d. Writing sysctl values and rebooting "
                                              @"need root (the binary must be setuid-root).",
                    (int)getuid(), (int)geteuid()];
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *key = [NSString stringWithFormat:@"%ld-%ld", (long)ip.section, (long)ip.row];
    void (^a)(void) = self.actions[key];
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (a) a();
}

#pragma mark Alerts

- (void)alertTitle:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [SWTopViewController(self) presentViewController:a animated:YES completion:nil];
}

- (void)alertWriteFailure:(NSString *)name errno:(int)e {
    [self alertTitle:[NSString stringWithFormat:@"Cannot write %@", name] message:SWErrText(e)];
}

- (void)showValueTitle:(NSString *)title text:(NSString *)text {
    NSString *value = text.length ? text : @"N/A";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:value
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        UIPasteboard.generalPasteboard.string = value;
        SWToast(ws.view, @"Copied");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [SWTopViewController(self) presentViewController:a animated:YES completion:nil];
}

#pragma mark Reading values

- (void)loadSegment:(UISegmentedControl *)seg label:(UILabel *)l name:(NSString *)name {
    long long v = 0;
    int e = 0;
    if ([SWSysctl getInteger:&v name:name errnoOut:&e]) {
        BOOL ok = (v >= 0 && v < (long long)seg.numberOfSegments);
        seg.enabled = YES;
        seg.selectedSegmentIndex = ok ? (NSInteger)v : UISegmentedControlNoSegment;
        SWSetValue(l, ok ? [NSString stringWithFormat:@"= %lld", v]
                         : [NSString stringWithFormat:@"%lld (unknown)", v]);
    } else {
        seg.enabled = NO;
        seg.selectedSegmentIndex = UISegmentedControlNoSegment;
        SWSetValue(l, SWNAText(e));
    }
}

- (void)loadSlider:(UISlider *)s label:(UILabel *)l name:(NSString *)name unit:(NSString *)unit {
    long long v = 0;
    int e = 0;
    if ([SWSysctl getInteger:&v name:name errnoOut:&e]) {
        s.enabled = YES;
        s.value = (float)v;
        SWSetValue(l, [NSString stringWithFormat:@"%lld%@", v, unit]);
    } else {
        s.enabled = NO;
        SWSetValue(l, SWNAText(e));
    }
}

- (void)loadSwitch:(UISwitch *)s label:(UILabel *)l name:(NSString *)name {
    long long v = 0;
    int e = 0;
    if ([SWSysctl getInteger:&v name:name errnoOut:&e]) {
        s.enabled = YES;
        [s setOn:(v != 0) animated:NO];
        SWSetValue(l, @"");
    } else {
        s.enabled = NO;
        [s setOn:NO animated:NO];
        SWSetValue(l, SWNAText(e));
    }
}

// Doc cac control co the chinh sua (khong goi tu timer de khong lam gian doan khi dang keo slider).
- (void)refreshControls {
    [self loadSegment:self.metalSeg label:self.metalValue name:kSysMetal];
    [self loadSlider:self.rscaleSlider label:self.rscaleValue name:kSysRScale unit:@""];
    [self loadSwitch:self.flushSwitch label:self.flushValue name:kSysFlipFlush];
    [self loadSegment:self.tapSeg label:self.tapValue name:kSysTapWake];
    [self loadSlider:self.quietSlider label:self.quietValue name:kSysQuietMs unit:@" ms"];
    [self loadSlider:self.staleSlider label:self.staleValue name:kSysStaleMs unit:@" ms"];
    [self loadMetalArgs];
    [self relayoutTable];
}

- (NSString *)readString:(NSString *)name into:(UILabel *)l changed:(BOOL *)changed {
    int e = 0;
    NSString *s = [SWSysctl stringForName:name errnoOut:&e];
    NSString *shown;
    if (!s) {
        shown = SWNAText(e);
        s = nil;
    } else if (s.length == 0) {
        shown = @"(empty)";
    } else {
        shown = s;
    }
    if (![l.text isEqualToString:shown]) {
        l.text = shown;
        if (changed) *changed = YES;
    }
    return s ?: shown;
}

// Cac gia tri "song": cap nhat moi 2 giay.
- (void)refreshLive {
    BOOL changed = NO;
    self.frameStatsFull = [self readString:kSysFrameStats into:self.frameStatsLabel changed:&changed];
    self.surfaceFull = [self readString:kSysSurface into:self.surfaceLabel changed:&changed];
    self.bootargsFull = [self readString:kSysBootargs into:self.bootargsLabel changed:&changed];
    [self readString:kSysTouchRate into:self.touchRateLabel changed:&changed];
    if (changed) [self relayoutTable];
}

- (void)relayoutTable {
    [UIView performWithoutAnimation:^{
        [self.table beginUpdates];
        [self.table endUpdates];
    }];
}

- (void)refreshTapped {
    [self refreshControls];
    [self refreshLive];
}

- (void)autoToggled:(UISwitch *)s {
    [self updateTimer];
    if (s.isOn) [self refreshLive];
}

#pragma mark Writing sysctl values

- (void)writeInt:(long long)v name:(NSString *)name {
    int e = 0;
    if (![SWSysctl setInteger:v name:name errnoOut:&e]) [self alertWriteFailure:name errno:e];
    [self refreshControls];
    [self refreshLive];
}

- (void)metalChanged:(UISegmentedControl *)s {
    if (s.selectedSegmentIndex == UISegmentedControlNoSegment) return;
    [self writeInt:s.selectedSegmentIndex name:kSysMetal];
}

- (void)tapWakeChanged:(UISegmentedControl *)s {
    if (s.selectedSegmentIndex == UISegmentedControlNoSegment) return;
    [self writeInt:s.selectedSegmentIndex name:kSysTapWake];
}

- (void)flushChanged:(UISwitch *)s {
    [self writeInt:s.isOn ? 1 : 0 name:kSysFlipFlush];
}

- (NSString *)nameForSlider:(UISlider *)s {
    switch (s.tag) {
        case kTagRScale: return kSysRScale;
        case kTagQuiet:  return kSysQuietMs;
        default:         return kSysStaleMs;
    }
}

- (float)stepForSlider:(UISlider *)s {
    switch (s.tag) {
        case kTagRScale: return 50;
        case kTagQuiet:  return 5;
        default:         return 100;
    }
}

- (NSString *)unitForSlider:(UISlider *)s {
    return s.tag == kTagRScale ? @"" : @" ms";
}

- (UILabel *)labelForSlider:(UISlider *)s {
    switch (s.tag) {
        case kTagRScale: return self.rscaleValue;
        case kTagQuiet:  return self.quietValue;
        default:         return self.staleValue;
    }
}

- (void)sliderMoved:(UISlider *)s {
    float step = [self stepForSlider:s];
    float v = roundf((s.value - s.minimumValue) / step) * step + s.minimumValue;
    if (v < s.minimumValue) v = s.minimumValue;
    if (v > s.maximumValue) v = s.maximumValue;
    s.value = v;
    SWSetValue([self labelForSlider:s], [NSString stringWithFormat:@"%d%@", (int)v, [self unitForSlider:s]]);
    if (!s.isTracking) [self commitSlider:s];   // vi du: dieu chinh bang VoiceOver
}

- (void)sliderReleased:(UISlider *)s {
    [self commitSlider:s];
}

- (void)commitSlider:(UISlider *)s {
    [self writeInt:(long long)llroundf(s.value) name:[self nameForSlider:s]];
}

- (void)resetTouchRate {
    int e = 0;
    if ([SWSysctl setInteger:0 name:kSysTouchRate errnoOut:&e]) {
        SWToast(self.view, @"Touch rate reset");
    } else {
        [self alertWriteFailure:kSysTouchRate errno:e];
    }
    [self refreshLive];
}

#pragma mark /var/tmp/metal.args

static NSString *SWTokenKey(NSString *t) {
    NSRange r = [t rangeOfString:@"="];
    return r.location == NSNotFound ? t : [t substringToIndex:r.location];
}

// Doc file hien tai. Tra ve YES neu file doc duoc hoac chua ton tai; *info la mo ta de hien thi.
- (NSMutableArray<NSString *> *)readMetalTokensInfo:(NSString **)info {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSError *err = nil;
    NSData *d = [NSData dataWithContentsOfFile:kMetalArgsPath options:0 error:&err];
    if (!d) {
        if (![NSFileManager.defaultManager fileExistsAtPath:kMetalArgsPath]) {
            if (info) *info = @"(file does not exist)";
        } else {
            if (info) *info = [NSString stringWithFormat:@"N/A (%@)", err.localizedDescription ?: @"read error"];
        }
        return tokens;
    }
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    for (NSString *t in [s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (t.length) [tokens addObject:t];
    }
    if (info) *info = tokens.count ? [tokens componentsJoinedByString:@" "] : @"(empty)";
    return tokens;
}

static BOOL SWFlagOn(NSArray<NSString *> *tokens, NSString *key) {
    BOOL on = NO;
    for (NSString *t in tokens) {
        if (![SWTokenKey(t) isEqualToString:key]) continue;
        NSRange r = [t rangeOfString:@"="];
        NSString *val = (r.location == NSNotFound) ? @"1" : [t substringFromIndex:r.location + 1];
        on = !(val.length == 0 || [val isEqualToString:@"0"]);   // lan xuat hien cuoi cung thang
    }
    return on;
}

- (void)loadMetalArgs {
    NSString *info = nil;
    NSArray<NSString *> *tokens = [self readMetalTokensInfo:&info];
    self.metalArgsLabel.text = info;
    NSArray<NSString *> *keys = SWMetalKeys();
    for (NSUInteger i = 0; i < keys.count && i < self.metalSwitches.count; i++) {
        [self.metalSwitches[i] setOn:SWFlagOn(tokens, keys[i]) animated:NO];
    }
}

- (BOOL)setMetalFlag:(NSString *)key on:(BOOL)on error:(NSString **)msg {
    // Doc lai file moi nhat de khong ghi de thay doi tu ben ngoai; giu nguyen cac token la.
    NSMutableArray<NSString *> *tokens = [self readMetalTokensInfo:NULL];
    NSIndexSet *idx = [tokens indexesOfObjectsPassingTest:^BOOL(NSString *t, NSUInteger i, BOOL *stop) {
        return [SWTokenKey(t) isEqualToString:key];
    }];
    [tokens removeObjectsAtIndexes:idx];
    if (on) [tokens addObject:[key stringByAppendingString:@"=1"]];

    NSString *content = tokens.count ? [[tokens componentsJoinedByString:@" "] stringByAppendingString:@"\n"] : @"";
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSError *e = nil;
    BOOL ok = [data writeToFile:kMetalArgsPath options:NSDataWritingAtomic error:&e];
    if (!ok) {
        e = nil;
        ok = [data writeToFile:kMetalArgsPath options:0 error:&e];   // /var/tmp co sticky bit: rename co the bi tu choi
    }
    if (ok) {
        chmod(kMetalArgsPath.fileSystemRepresentation, 0644);
        return YES;
    }
    if (msg) {
        *msg = [NSString stringWithFormat:@"%@ (%@ %ld)", e.localizedDescription ?: @"write error",
                e.domain ?: @"", (long)e.code];
    }
    return NO;
}

- (void)metalFlagChanged:(UISwitch *)sw {
    NSArray<NSString *> *keys = SWMetalKeys();
    if (sw.tag < 0 || (NSUInteger)sw.tag >= keys.count) return;
    NSString *msg = nil;
    if ([self setMetalFlag:keys[(NSUInteger)sw.tag] on:sw.isOn error:&msg]) {
        SWToast(self.view, @"metal.args saved");
    } else {
        [self alertTitle:@"Cannot write /var/tmp/metal.args" message:msg ?: @"Unknown error"];
    }
    [self loadMetalArgs];
    [self relayoutTable];
}

#pragma mark Power & log actions

- (void)runKill:(NSArray<NSString *> *)names title:(NSString *)title {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        if (!SWKillProcesses(names, &err)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws alertTitle:title message:err ?: @"Unknown error"];
            });
        }
    });
}

- (void)confirmReboot {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reboot device?"
                                                               message:@"The device will restart immediately."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reboot" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *err = nil;
            if (!SWReboot(&err)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [ws alertTitle:@"Reboot failed" message:err ?: @"Unknown error"];
                });
            }
        });
    }]];
    [SWTopViewController(self) presentViewController:a animated:YES completion:nil];
}

- (void)showKernelLog {
    SWLogViewController *vc = [[SWLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

@end

#pragma mark - App delegate / main

@interface SWAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SWAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    SWMainViewController *root = [[SWMainViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Neu binary duoc cai setuid-root thi nang quyen de ghi sysctl / reboot. Neu khong, bo qua.
        if (geteuid() != 0) {
            (void)setuid(0);
            (void)setgid(0);
        }
        signal(SIGPIPE, SIG_IGN);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SWAppDelegate class]));
    }
}
