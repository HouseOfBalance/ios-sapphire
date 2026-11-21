// SapphireTools v2 — main.m
// Cong cu cau hinh / chan doan cho ban port iOS 16.7 tren Redmi Note 13 4G
// (sapphire / SM6225 / Adreno 610), repo HouseOfBalance/ios-sapphire.
//
// Objective-C + UIKit thuan, UI dung hoan toan bang code (khong Storyboard/XIB).
// Build: xem Makefile (clang + iOS SDK, ky bang ldid -Sentitlements.plist).
//
// v2: sua loi pipe/timeout/doc sysctl, them Display+FPS meter, Services, SSH,
//     Accessibility toggles, Sysctl Explorer, Debug Snapshot (copy/share), metal.args editor.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#ifndef CTL_SYSCTL
#define CTL_SYSCTL 0
#endif
#ifndef CTL_SYSCTL_NAME
#define CTL_SYSCTL_NAME 1
#endif
#ifndef CTL_SYSCTL_NEXT
#define CTL_SYSCTL_NEXT 2
#endif
#ifndef CTL_SYSCTL_OIDFMT
#define CTL_SYSCTL_OIDFMT 4
#endif
#ifndef CTL_MAXNAME
#define CTL_MAXNAME 12
#endif
#ifndef SZOMB
#define SZOMB 5
#endif

#define SW_CTLFLAG_RD 0x80000000u
#define SW_CTLFLAG_WR 0x40000000u

#pragma mark - Constants

static NSString *const kSysMetal      = @"kern.sweet_metal";
static NSString *const kSysRScale     = @"kern.sweet_fb_rscale";
static NSString *const kSysFlipFlush  = @"kern.sweet_fb_flipflush";
static NSString *const kSysTapWake    = @"kern.sweet_tap_wake";
static NSString *const kSysQuietMs    = @"kern.sweet_touch_quiet_ms";
static NSString *const kSysStaleMs    = @"kern.sweet_touch_stale_ms";
static NSString *const kSysTouchRate  = @"kern.sweet_touch_rate";
static NSString *const kSysTapWakes   = @"kern.sweet_tap_wakes";
static NSString *const kSysFodPress   = @"kern.sweet_fod_press";
static NSString *const kSysFodSeq     = @"kern.sweet_fod_seq";
static NSString *const kSysFrameStats = @"kern.sweet_fb_frame_stats";
static NSString *const kSysSurface    = @"kern.sweet_fb_surface";
static NSString *const kSysBootargs   = @"kern.bootargs";
static NSString *const kSweetPrefix   = @"kern.sweet_";

static NSString *const kMetalArgsPath = @"/var/tmp/metal.args";
static NSString *const kSweetLogPath  = @"/var/log/sweetlog.txt";
static NSString *const kSnapshotDir   = @"/var/tmp";
static NSString *const kSnapshotPrefix = @"sapphire-snapshot-";
static const NSUInteger kLogLines     = 80;
static const NSUInteger kSnapshotLogLines = 300;

enum { kTagRScale = 100, kTagQuiet = 101, kTagStale = 102 };

// Thu tu cac section trong man hinh chinh.
enum {
    SecGraphics = 0, SecDisplay, SecTouch, SecDiag, SecServices,
    SecSSH, SecAccess, SecTools, SecPower, SecCount
};

static NSArray<NSString *> *SWMetalKeys(void) {
    return @[@"metal_gmem", @"metal_defer", @"metal_stats"];
}

// Daemon can theo doi: {ten tien trinh (p_comm), mo ta}.
static NSArray<NSArray<NSString *> *> *SWServiceList(void) {
    return @[
        @[@"SpringBoard",   @"UI shell"],
        @[@"backboardd",    @"display / touch events"],
        @[@"camd",          @"camera daemon"],
        @[@"fpd",           @"fingerprint"],
        @[@"btmonitor",     @"bluetooth monitor"],
        @[@"vibd",          @"haptics"],
        @[@"thermald",      @"thermal"],
        @[@"sensord",       @"sensors"],
        @[@"CommCenter",    @"modem / cellular"],
        @[@"mediaserverd",  @"audio / media"],
        @[@"wifid",         @"Wi-Fi"],
        @[@"bluetoothd",    @"bluetooth"],
    ];
}

// Muc Accessibility: {tieu de, ham doc, ham ghi} trong libAccessibility.dylib.
static NSArray<NSDictionary<NSString *, NSString *> *> *SWAXItems(void) {
    return @[
        @{ @"title": @"Reduce Transparency",
           @"get": @"_AXSEnhanceBackgroundContrastEnabled",
           @"set": @"_AXSSetEnhanceBackgroundContrastEnabled" },
        @{ @"title": @"Reduce Motion",
           @"get": @"_AXSReduceMotionEnabled",
           @"set": @"_AXSSetReduceMotionEnabled" },
    ];
}

#pragma mark - Small helpers

static NSString *SWErrText(int e) {
    return [NSString stringWithFormat:@"errno %d: %s", e, strerror(e)];
}

static NSString *SWNAText(int e) {
    if (e == 0 || e == ENOENT) return @"N/A";
    return [NSString stringWithFormat:@"N/A (%@)", SWErrText(e)];
}

static int64_t SWNowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static NSString *SWFormatDuration(double s) {
    long long t = (long long)(s > 0 ? s : 0);
    if (t < 60)    return [NSString stringWithFormat:@"%llds", t];
    if (t < 3600)  return [NSString stringWithFormat:@"%lldm %llds", t / 60, t % 60];
    if (t < 86400) return [NSString stringWithFormat:@"%lldh %lldm", t / 3600, (t % 3600) / 60];
    return [NSString stringWithFormat:@"%lldd %lldh", t / 86400, (t % 86400) / 3600];
}

// "123", "-5", "0x1f" -> YES. Khong chap nhan phan thua.
static BOOL SWParseInt(NSString *s, long long *out) {
    NSString *t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (t.length == 0) return NO;
    NSScanner *sc = [NSScanner scannerWithString:t];
    long long v = 0;
    if ([t hasPrefix:@"0x"] || [t hasPrefix:@"0X"]) {
        unsigned long long u = 0;
        if (![sc scanHexLongLong:&u]) return NO;
        v = (long long)u;
    } else if (![sc scanLongLong:&v]) {
        return NO;
    }
    if (!sc.isAtEnd) return NO;
    if (out) *out = v;
    return YES;
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

// Gan text neu khac; bao *changed de biet co can relayout bang hay khong.
static void SWSetText(UILabel *l, NSString *text, BOOL *changed) {
    NSString *t = text ?: @"";
    if (![l.text isEqualToString:t]) {
        l.text = t;
        if (changed) *changed = YES;
    }
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
        [UIView animateWithDuration:0.3 delay:1.8 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL f2) { [l removeFromSuperview]; }];
    }];
}


#pragma mark - Chu thich de hieu (tieng Viet doi thuong)

// Tra ve dong chu nho giai thich tac dung cua muc co tieu de `title` (nil neu khong co).
static NSString *SWHintForTitle(NSString *title) {
    static NSArray<NSArray<NSString *> *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            @[@"Metal mode", @"Chọn cách vẽ hình: Off = tắt, hai mức còn lại = vẽ trực tiếp bằng chip đồ họa Adreno 610. Đổi thử xem cách nào mượt hơn."],
            @[@"FB render scale", @"Độ nét của khung hình nội bộ. Thường số thấp = nhẹ máy, mượt hơn nhưng hơi mờ; số cao = nét hơn nhưng nặng hơn."],
            @[@"FB flip flush", @"Ép đẩy hình xuống màn hình ngay mỗi lần đổi khung. Thử bật nếu thấy hình bị rách hoặc nhấp nháy."],
            @[@"metal_gmem=1", @"Cờ thử nghiệm của HakiosMetal (bộ nhớ nhanh trên GPU). Chỉ có hiệu lực khi app Metal khởi động lại."],
            @[@"metal_defer=1", @"Cờ thử nghiệm của HakiosMetal (trì hoãn việc vẽ). Chỉ có hiệu lực khi app Metal khởi động lại."],
            @[@"metal_stats=1", @"Bật ghi thống kê của HakiosMetal vào nhật ký, để xem máy vẽ nhanh hay chậm."],
            @[@"/var/tmp/metal.args", @"File chứa các cờ ở trên. Chạm vào đây để tự sửa bằng tay."],
            @[@"Screen (UIScreen)", @"Thông tin màn hình mà hệ điều hành đang thấy: độ phân giải và số lần làm mới tối đa mỗi giây (Hz)."],
            @[@"Thermal state", @"Máy đang nóng cỡ nào. Nominal = bình thường; Serious/Critical = quá nóng, máy có thể bị giảm tốc."],
            @[@"FPS meter", @"Đo số khung hình mỗi giây thực tế. Bật lên rồi thử các thay đổi khác để xem có mượt hơn không."],
            @[@"Measured", @"Kết quả đo: fps càng gần số Hz tối đa càng mượt. “drops” = số khung bị rớt (giật). Chạm để đo lại từ đầu."],
            @[@"Motion test", @"Thanh xanh chạy qua lại để bạn nhìn bằng mắt xem có bị giật không."],
            @[@"Tap to wake", @"Chạm màn hình để bật sáng máy: tắt / chạm 1 lần / chạm 2 lần."],
            @[@"Touch quiet", @"Thời gian chờ (mili giây) sau khi ngừng chạm thì cảm ứng được coi là “yên”. Chỉnh khi cảm ứng bị lỗi vặt."],
            @[@"Touch stale", @"Sau bao lâu (mili giây) không có tín hiệu thì dữ liệu chạm cũ bị bỏ đi."],
            @[@"Touch rate", @"Tốc độ đọc cảm ứng hiện tại do hệ thống báo cáo. Chỉ để xem."],
            @[@"FOD / tap-wake", @"Bộ đếm vân tay dưới màn hình và số lần đánh thức bằng chạm. Số nhảy lên khi bạn thao tác = tính năng đang hoạt động."],
            @[@"Frame stats", @"Thống kê khung hình do hệ thống ghi lại. Chạm để xem đầy đủ hoặc sao chép."],
            @[@"FB surface", @"Thông tin vùng nhớ chứa hình đang hiển thị. Chạm để xem đầy đủ."],
            @[@"Boot args", @"Các tham số máy nhận lúc khởi động. Chỉ để xem."],
            @[@"Auto refresh", @"Tự cập nhật các số liệu mỗi 2 giây. Tắt đi nếu thấy máy bị chậm khi mở app."],
            @[@"SSH daemon", @"Cho phép máy tính điều khiển điện thoại và gửi file qua Wi-Fi. Bật lên khi bạn muốn chép file từ PC sang."],
            @[@"Device IP", @"Địa chỉ mạng của điện thoại, nhập vào máy tính để kết nối. Chạm để sao chép lệnh ssh."],
            @[@"Reduce Transparency", @"Tắt hiệu ứng mờ trong suốt của giao diện. Nhẹ cho chip đồ họa hơn nên thường mượt hơn."],
            @[@"Reduce Motion", @"Giảm hiệu ứng chuyển động, phóng to, trượt của giao diện. Cũng giúp mượt hơn."],
            @[@"Apply as user", @"Chỉ bật nếu bạn gạt công tắc ở trên mà giao diện không thay đổi gì."],
            @[@"Reset Touch Rate", @"Đặt bộ đo tốc độ cảm ứng về 0 để đo lại."],
            @[@"Refresh now", @"Cập nhật mọi số liệu ngay lập tức."],
            @[@"View Recent Kernel Log", @"Xem nhật ký mới nhất của hệ thống để tìm nguyên nhân khi có lỗi."],
            @[@"Copy scp command", @"Sao chép lệnh để gửi file từ máy tính sang điện thoại."],
            @[@"Refresh SSH", @"Kiểm tra lại SSH đang bật hay tắt và địa chỉ IP."],
            @[@"Sysctl Explorer", @"Danh sách mọi thông số tinh chỉnh của hệ thống (kể cả cái mới thêm sau này). Xem và sửa được."],
            @[@"Open Sapphire Camera", @"Mở máy ảnh trực tiếp (camd): hỗ trợ đủ 4 ống kính (108MP/12MP, góc siêu rộng, macro, cam trước), chạm lấy nét AF và lưu vào Photos/Files."],
            @[@"Edit metal.args", @"Tự gõ sửa các cờ cấu hình Metal."],
            @[@"Copy debug snapshot", @"Gom toàn bộ thông tin máy thành một đoạn chữ để dán gửi cho người phân tích lỗi."],
            @[@"Share debug snapshot", @"Giống nút trên nhưng gửi qua menu Chia sẻ dưới dạng file."],
            @[@"Share sweetlog", @"Gửi file nhật ký sweetlog.txt cho người khác."],
            @[@"Respring", @"Khởi động lại giao diện (màn hình đen vài giây), KHÔNG tắt máy."],
            @[@"Restart SpringBoard only", @"Chỉ khởi động lại màn hình chính, nhẹ hơn Respring."],
            @[@"Reboot", @"Khởi động lại cả máy."],
        ];
    });
    for (NSArray<NSString *> *row in table) {
        if ([title hasPrefix:row[0]]) return row[1];
    }
    for (NSArray<NSString *> *svc in SWServiceList()) {
        if ([title hasPrefix:[svc[0] stringByAppendingString:@" ("]]) {
            return @"Chương trình nền của hệ thống. Xanh = đang chạy, đỏ = không chạy. Chạm để khởi động lại nếu nó bị lỗi.";
        }
    }
    return nil;
}

static UILabel *SWHintLabel(NSString *text) {
    UILabel *h = SWMakeLabel([UIFont systemFontOfSize:12], UIColor.secondaryLabelColor, 0);
    h.text = text;
    return h;
}

#pragma mark - sysctl wrapper

typedef NS_ENUM(NSInteger, SWKind) {
    SWKindUnknown = 0,
    SWKindString,
    SWKindInt32,   // CTLTYPE_INT (kich thuoc thuc te lay tu do dai du lieu: 4 hoac 8)
    SWKindInt64,   // CTLTYPE_QUAD
    SWKindStruct   // CTLTYPE_OPAQUE
};

static SWKind SWKindFromRaw(uint32_t raw) {
    switch (raw & 0xf) {
        case 2: return SWKindInt32;
        case 3: return SWKindString;
        case 4: return SWKindInt64;
        case 5: return SWKindStruct;
        default: return SWKindUnknown;
    }
}

@interface SWSysctl : NSObject
+ (BOOL)exists:(NSString *)name;
+ (uint32_t)rawKindForMib:(const int *)mib length:(size_t)n;
+ (NSString *)stringForName:(NSString *)name errorCode:(int *)err;
+ (BOOL)getInteger:(long long *)out name:(NSString *)name errorCode:(int *)err;
+ (BOOL)setInteger:(long long)v name:(NSString *)name errorCode:(int *)err;
+ (BOOL)setString:(NSString *)s name:(NSString *)name errorCode:(int *)err;
@end

@implementation SWSysctl

// Lay "kind" (flags | type) cua OID qua sysctl magic {0, 4, <oid...>} (CTL_SYSCTL_OIDFMT).
+ (uint32_t)rawKindForMib:(const int *)mib length:(size_t)n {
    if (n == 0 || n > CTL_MAXNAME) return 0;
    int q[CTL_MAXNAME + 2];
    q[0] = CTL_SYSCTL;
    q[1] = CTL_SYSCTL_OIDFMT;
    memcpy(q + 2, mib, n * sizeof(int));
    unsigned char buf[256];
    size_t len = sizeof(buf);
    if (sysctl(q, (u_int)(n + 2), buf, &len, NULL, 0) != 0 || len < sizeof(uint32_t)) return 0;
    uint32_t k = 0;
    memcpy(&k, buf, sizeof(k));
    return k;
}

+ (uint32_t)rawKindForName:(NSString *)name {
    int mib[CTL_MAXNAME];
    size_t n = CTL_MAXNAME;
    if (sysctlnametomib(name.UTF8String, mib, &n) != 0) return 0;
    return [self rawKindForMib:mib length:n];
}

+ (SWKind)kindForName:(NSString *)name {
    return SWKindFromRaw([self rawKindForName:name]);
}

// Doc dung MOT lan goi handler (khong "do kich thuoc" truoc): mot so sysctl tu kernel
// tinh gia tri theo khoang thoi gian tu lan doc truoc (rate, stats), goi hai lan se lam lech so lieu.
// Chi khi buffer 4 KB khong du (ENOMEM) moi hoi kich thuoc that.
+ (NSData *)readRaw:(NSString *)name errorCode:(int *)err {
    const char *n = name.UTF8String;
    size_t cap = 4096;
    for (int attempt = 0; attempt < 4; attempt++) {
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
        size_t need = 0;
        if (sysctlbyname(n, NULL, &need, NULL, 0) != 0) {
            if (err) *err = errno;
            return nil;
        }
        cap = MAX(need + 256, cap * 2);
        if (cap > 4u * 1024u * 1024u) break;
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

+ (NSString *)stringForName:(NSString *)name errorCode:(int *)err {
    NSData *d = [self readRaw:name errorCode:err];
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

+ (BOOL)getInteger:(long long *)out name:(NSString *)name errorCode:(int *)err {
    NSData *d = [self readRaw:name errorCode:err];
    if (!d) return NO;
    SWKind k = [self kindForName:name];
    if ([self isStringData:d kind:k]) {
        // Sao chep sang buffer C: con tro UTF8String cua object tam co the bi ARC giai phong som.
        char cbuf[64];
        NSString *str = [self stringFromData:d];
        if (![str getCString:cbuf maxLength:sizeof(cbuf) encoding:NSUTF8StringEncoding]) {
            if (err) *err = EINVAL;
            return NO;
        }
        char *end = NULL;
        long long v = strtoll(cbuf, &end, 0);
        if (end == cbuf) {
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

#include <sys/socket.h>
#include <sys/un.h>

static BOOL SWToolsdCall(NSString *cmd, int *errOut) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (errOut) *errOut = errno;
        return NO;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, "/var/run/sapphire-toolsd.sock", sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        if (errOut) *errOut = errno;
        close(fd);
        return NO;
    }
    const char *c = cmd.UTF8String;
    size_t len = strlen(c);
    ssize_t w = write(fd, c, len);
    char resp[128] = {0};
    ssize_t r = (w == (ssize_t)len) ? read(fd, resp, sizeof(resp) - 1) : -1;
    close(fd);
    if (r > 0 && strncmp(resp, "OK", 2) == 0) return YES;
    if (errOut) *errOut = EPERM;
    return NO;
}

+ (BOOL)setString:(NSString *)s name:(NSString *)name errorCode:(int *)err {
    const char *n = name.UTF8String;
    const char *c = s.UTF8String;
    size_t l = strlen(c);
    int rc = sysctlbyname(n, NULL, NULL, (void *)c, l);
    if (rc != 0 && errno == EINVAL) rc = sysctlbyname(n, NULL, NULL, (void *)c, l + 1);
    if (rc != 0) {
        if ((errno == EPERM || errno == EACCES) &&
            SWToolsdCall([NSString stringWithFormat:@"SYSCTL_SET %@ %@\n", name, s], err)) {
            return YES;
        }
        if (err) *err = errno;
        return NO;
    }
    return YES;
}

+ (BOOL)setInteger:(long long)v name:(NSString *)name errorCode:(int *)err {
    const char *n = name.UTF8String;
    size_t len = 0;
    if (sysctlbyname(n, NULL, &len, NULL, 0) != 0) {
        if (err) *err = errno;
        return NO;
    }
    SWKind k = [self kindForName:name];
    BOOL asString = (k == SWKindString) || (k == SWKindUnknown && len != 4 && len != 8);
    if (asString) {
        return [self setString:[NSString stringWithFormat:@"%lld", v] name:name errorCode:err];
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
        if ((errno == EPERM || errno == EACCES) &&
            SWToolsdCall([NSString stringWithFormat:@"SYSCTL_SET %@ %lld\n", name, v], err)) {
            return YES;
        }
        if (err) *err = errno;
        return NO;
    }
    return YES;
}

@end

#pragma mark - Guarded sysctl read (timeout + blocking denylist)

// Cac sysctl kieu "_await" co the CHAN den khi co frame/su kien: khong bao gio doc tu app.
static BOOL SWSysctlLooksBlocking(NSString *name) {
    return [name rangeOfString:@"await" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSMutableSet<NSString *> *SWHungSet(void) {
    static NSMutableSet<NSString *> *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}

// Doc sysctl o thread nen voi timeout 1.5 s. Tra ve nil (kem *errorCode) neu doc loi.
// Sysctl da timeout se bi danh dau "hung" va khong doc lai (tranh ro ri thread).
static NSString *SWReadSysctlGuarded(NSString *name, int *errorCode) {
    if (errorCode) *errorCode = 0;
    if (SWSysctlLooksBlocking(name)) return @"(blocking sysctl - not read)";
    @synchronized (SWHungSet()) {
        if ([SWHungSet() containsObject:name]) return @"(timed out earlier - skipped)";
    }
    __block NSString *result = nil;
    __block int e = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int err = 0;
        NSString *s = [SWSysctl stringForName:name errorCode:&err];
        result = s;
        e = err;
        dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC)) != 0) {
        @synchronized (SWHungSet()) { [SWHungSet() addObject:name]; }
        return @"(timeout)";
    }
    if (errorCode) *errorCode = e;
    return result;
}

// Chuoi hien thi: gia tri / "(empty)" / "N/A (...)".
static NSString *SWSysctlDisplay(NSString *name) {
    int e = 0;
    NSString *s = SWReadSysctlGuarded(name, &e);
    if (!s) return SWNAText(e);
    return s.length ? s : @"(empty)";
}

// Duyet cay kern.* bang sysctl magic NEXT/NAME, tra ve cac OID la co ten bat dau bang prefix.
static NSArray<NSDictionary *> *SWEnumerateSysctls(NSString *prefix) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    int cur[CTL_MAXNAME];
    size_t curLen = 1;
    cur[0] = CTL_KERN;
    for (int iter = 0; iter < 8000; iter++) {
        int q[CTL_MAXNAME + 2];
        q[0] = CTL_SYSCTL;
        q[1] = CTL_SYSCTL_NEXT;
        memcpy(q + 2, cur, curLen * sizeof(int));
        int nxt[CTL_MAXNAME];
        size_t nbytes = sizeof(nxt);
        if (sysctl(q, (u_int)(curLen + 2), nxt, &nbytes, NULL, 0) != 0) break;
        size_t nlen = nbytes / sizeof(int);
        if (nlen == 0 || nlen > CTL_MAXNAME || nxt[0] != CTL_KERN) break;
        memcpy(cur, nxt, nlen * sizeof(int));
        curLen = nlen;

        int nq[CTL_MAXNAME + 2];
        nq[0] = CTL_SYSCTL;
        nq[1] = CTL_SYSCTL_NAME;
        memcpy(nq + 2, cur, curLen * sizeof(int));
        char nm[256];
        size_t nl = sizeof(nm);
        if (sysctl(nq, (u_int)(curLen + 2), nm, &nl, NULL, 0) != 0 || nl == 0) continue;
        nm[sizeof(nm) - 1] = 0;
        NSString *name = [NSString stringWithUTF8String:nm];
        if (!name || ![name hasPrefix:prefix]) continue;

        uint32_t raw = [SWSysctl rawKindForMib:cur length:curLen];
        if ((raw & 0xf) == 1) continue;   // CTLTYPE_NODE
        NSString *type;
        switch (SWKindFromRaw(raw)) {
            case SWKindString: type = @"string"; break;
            case SWKindInt32:  type = @"int";    break;
            case SWKindInt64:  type = @"quad";   break;
            case SWKindStruct: type = @"opaque"; break;
            default:           type = @"?";      break;
        }
        BOOL wr = (raw & SW_CTLFLAG_WR) != 0;
        BOOL rd = (raw & SW_CTLFLAG_RD) != 0;
        [out addObject:@{ @"name": name, @"type": type, @"writable": @(wr),
                          @"access": wr ? (rd ? @"RW" : @"WO") : @"RO" }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return out;
}

#pragma mark - Process helpers (posix_spawn / kill / reboot)

// Chay mot file thuc thi (timeout 8 s). Tra ve exit code, hoac -1 (kem *errOut != 0 neu loi:
// loi spawn, hoac ETIMEDOUT khi tien trinh bi kill do chay qua lau).
static int SWSpawnPath(const char *path, NSArray<NSString *> *args, NSString **output, int *errOut) {
    const int64_t kTimeoutMs = 8000;
    int fds[2] = {-1, -1};
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (output) {
        if (pipe(fds) != 0) {
            if (errOut) *errOut = errno;
            posix_spawn_file_actions_destroy(&fa);
            return -1;
        }
        // FD_CLOEXEC tren ca hai dau pipe: neu khong, mot spawn chay song song o thread khac
        // se ke thua dau ghi va lam read() o day khong bao gio gap EOF.
        // dup2 xuong 1/2 tu dong bo co CLOEXEC nen child van nhan duoc stdout/stderr.
        fcntl(fds[0], F_SETFD, FD_CLOEXEC);
        fcntl(fds[1], F_SETFD, FD_CLOEXEC);
        posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
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

    const int64_t deadline = SWNowMs() + kTimeoutMs;
    NSMutableData *buf = nil;
    if (output) {
        close(fds[1]);
        buf = [NSMutableData data];
        char tmp[4096];
        for (;;) {
            int64_t left = deadline - SWNowMs();
            if (left <= 0) break;
            struct pollfd p = { fds[0], POLLIN, 0 };
            int pr = poll(&p, 1, (int)left);
            if (pr < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (pr == 0) break;   // het gio: de vong waitpid ben duoi quyet dinh
            ssize_t n = read(fds[0], tmp, sizeof(tmp));
            if (n == 0) break;
            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN) continue;
                break;
            }
            if (buf.length < 8u * 1024u * 1024u) [buf appendBytes:tmp length:(NSUInteger)n];
        }
        close(fds[0]);
    }

    int status = 0;
    BOOL timedOut = NO;
    for (;;) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) break;
        if (w < 0 && errno != EINTR) { status = 0; break; }   // ECHILD...
        if (SWNowMs() >= deadline) {
            timedOut = YES;
            kill(pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
            break;
        }
        usleep(10 * 1000);
    }

    if (output) {
        NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
        *output = s ?: @"";
    }
    if (timedOut) {
        if (errOut) *errOut = ETIMEDOUT;
        return -1;
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
            if (e == ETIMEDOUT) break;
            continue;
        }
        return rc;
    }
    if (errOut) *errOut = lastErr;
    return -1;
}

// Liet ke tien trinh (KERN_PROC_ALL). Tra ve mang malloc (caller free) hoac NULL.
static struct kinfo_proc *SWCopyProcs(size_t *countOut) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    struct kinfo_proc *procs = NULL;
    for (int attempt = 0; attempt < 5; attempt++) {
        size_t len = 0;
        if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0) break;
        len += 32 * sizeof(struct kinfo_proc);
        struct kinfo_proc *p2 = realloc(procs, len);
        if (!p2) break;
        procs = p2;
        if (sysctl(mib, 3, procs, &len, NULL, 0) == 0) {
            if (countOut) *countOut = len / sizeof(struct kinfo_proc);
            return procs;
        }
        if (errno != ENOMEM) break;
    }
    free(procs);
    if (countOut) *countOut = 0;
    return NULL;
}

// ten tien trinh (p_comm, toi da 16 ky tu) -> [{pid, start(epoch giay)}]
static NSDictionary<NSString *, NSArray<NSDictionary *> *> *SWProcessMap(void) {
    size_t n = 0;
    struct kinfo_proc *procs = SWCopyProcs(&n);
    if (!procs) return @{};
    NSMutableDictionary<NSString *, NSMutableArray *> *map = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < n; i++) {
        if (procs[i].kp_proc.p_stat == SZOMB) continue;
        char comm[MAXCOMLEN + 1];
        strlcpy(comm, procs[i].kp_proc.p_comm, sizeof(comm));
        NSString *name = [NSString stringWithUTF8String:comm];
        if (name.length == 0) continue;
        NSMutableArray *arr = map[name];
        if (!arr) {
            arr = [NSMutableArray array];
            map[name] = arr;
        }
        [arr addObject:@{ @"pid": @(procs[i].kp_proc.p_pid),
                          @"start": @((double)procs[i].kp_proc.p_un.__p_starttime.tv_sec) }];
    }
    free(procs);
    return map;
}

// Mo ta ngan "PID 123 · 4m 12s" (hoac "PID 12, 15 (2)") cho mot muc trong SWProcessMap.
static NSString *SWDescribeProcs(NSArray<NSDictionary *> *list) {
    if (list.count == 0) return @"not running";
    NSDictionary *first = list.firstObject;
    double up = [NSDate date].timeIntervalSince1970 - [first[@"start"] doubleValue];
    if (list.count == 1) {
        return [NSString stringWithFormat:@"PID %d · %@", [first[@"pid"] intValue], SWFormatDuration(up)];
    }
    return [NSString stringWithFormat:@"PID %d +%lu · %@", [first[@"pid"] intValue],
            (unsigned long)(list.count - 1), SWFormatDuration(up)];
}

// Gui tin hieu theo ten tien trinh (khop chinh xac p_comm). Tra ve so tien trinh da gui,
// hoac -1 (kem *errorCode) khi tat ca deu loi.
static int SWKillByName(NSString *name, int sig, int *errorCode) {
    size_t n = 0;
    struct kinfo_proc *procs = SWCopyProcs(&n);
    if (!procs) {
        if (errorCode) *errorCode = ENOMEM;
        return -1;
    }
    const char *target = name.UTF8String;
    int killed = 0, lastErr = 0;
    pid_t self = getpid();
    for (size_t i = 0; i < n; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 1 || pid == self) continue;
        if (procs[i].kp_proc.p_stat == SZOMB) continue;
        if (strncmp(procs[i].kp_proc.p_comm, target, MAXCOMLEN) != 0) continue;
        if (kill(pid, sig) == 0) killed++;
        else lastErr = errno;
    }
    free(procs);
    if (killed == 0 && (lastErr == EPERM || lastErr == EACCES)) {
        if (SWToolsdCall([NSString stringWithFormat:@"KILL %@\n", name], errorCode)) {
            return 1;
        }
    }
    if (killed == 0 && lastErr != 0) {
        if (errorCode) *errorCode = lastErr;
        return -1;
    }
    return killed;
}

// Kill truc tiep truoc (khong can killall), killall chi la du phong.
static BOOL SWKillProcesses(NSArray<NSString *> *names, NSString **errMsg) {
    int total = 0, lastErr = 0;
    for (NSString *n in names) {
        int e = 0;
        int k = SWKillByName(n, SIGKILL, &e);
        if (k > 0) total += k;
        else if (k < 0) lastErr = e;
    }
    if (total > 0) return YES;

    if (SWToolsdCall([NSString stringWithFormat:@"KILL %@\n", [names componentsJoinedByString:@" "]], NULL)) {
        return YES;
    }

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"killall", @"-9", nil];
    [args addObjectsFromArray:names];
    int spawnErr = 0;
    int rc = SWRunFirst(@[@"/usr/bin/killall", @"/bin/killall", @"/usr/sbin/killall",
                          @"/var/jb/usr/bin/killall"], args, nil, &spawnErr);
    if (rc == 0) return YES;

    if (errMsg) {
        NSString *a = lastErr ? [NSString stringWithFormat:@"direct kill failed (%@)", SWErrText(lastErr)]
                              : @"no matching process found";
        NSString *b = (rc == -1) ? [NSString stringWithFormat:@"killall not runnable (%@)", SWErrText(spawnErr)]
                                 : [NSString stringWithFormat:@"killall exited with status %d", rc];
        *errMsg = [NSString stringWithFormat:@"%@; %@.", a, b];
    }
    return NO;
}

static BOOL SWReboot(NSString **errMsg) {
    sync();
    if (SWToolsdCall(@"REBOOT\n", NULL)) return YES;
    int spawnErr = 0;
    int rc = SWRunFirst(@[@"/sbin/reboot", @"/usr/sbin/reboot", @"/usr/bin/reboot",
                          @"/var/jb/usr/sbin/reboot", @"/var/jb/sbin/reboot"], @[@"reboot"], nil, &spawnErr);
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

#pragma mark - Network / SSH helpers

// Danh sach IPv4 cua cac interface dang up (tru loopback, link-local). *primary: uu tien en0 (Wi-Fi).
static NSArray<NSString *> *SWInterfaceAddresses(NSString **primary) {
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return @[];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *best = nil;
    BOOL hasEn0 = NO;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN];
        const struct sockaddr_in *sin = (const struct sockaddr_in *)p->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        NSString *nm = [NSString stringWithUTF8String:p->ifa_name];
        if (!ip || !nm || [ip hasPrefix:@"169.254."]) continue;
        [lines addObject:[NSString stringWithFormat:@"%@  %@", nm, ip]];
        if ([nm isEqualToString:@"en0"]) {
            best = ip;
            hasEn0 = YES;
        } else if (!hasEn0 && !best) {
            best = ip;
        }
    }
    freeifaddrs(ifa);
    if (primary) *primary = best;
    return lines;
}

// Co the connect() toi 127.0.0.1:port khong? (neu sshd chay kieu launchd socket-activation,
// moi lan probe co the lam launchd bat 1 tien trinh sshd -i roi thoat ngay: vo hai nhung dung probe qua day.)
static BOOL SWTCPPortOpen(uint16_t port, int timeoutMs) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_len = sizeof(a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = NO;
    int rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    if (rc == 0) {
        ok = YES;
    } else if (errno == EINPROGRESS) {
        struct pollfd p = { fd, POLLOUT, 0 };
        if (poll(&p, 1, timeoutMs) > 0) {
            int soerr = 0;
            socklen_t sl = sizeof(soerr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) == 0) ok = (soerr == 0);
        }
    }
    close(fd);
    return ok;
}

// Cong SSH dang lang nghe: 22, roi 2222 (dropbear thuong dung). 0 neu khong co.
static uint16_t SWDetectSSHPort(void) {
    if (SWTCPPortOpen(22, 300)) return 22;
    if (SWTCPPortOpen(2222, 300)) return 2222;
    return 0;
}

static NSArray<NSString *> *SWLaunchctlPaths(void) {
    return @[@"/var/jb/usr/bin/launchctl", @"/bin/launchctl", @"/usr/bin/launchctl", @"/sbin/launchctl"];
}

// Tim plist LaunchDaemon cua sshd/dropbear (Procursus: com.openssh.sshd.plist trong /var/jb/Library/LaunchDaemons).
static NSString *SWFindSSHPlist(void) {
    NSArray<NSString *> *dirs = @[@"/var/jb/Library/LaunchDaemons", @"/Library/LaunchDaemons",
                                  @"/System/Library/LaunchDaemons"];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:d error:NULL]) {
            NSString *l = f.lowercaseString;
            if (![l hasSuffix:@".plist"] || [l containsString:@"keygen"]) continue;
            if ([l containsString:@"sshd"] || [l containsString:@"dropbear"]) {
                return [d stringByAppendingPathComponent:f];
            }
        }
    }
    return nil;
}

// Bat/tat SSH. Co plist -> launchctl load -w / unload. Khong co plist -> chay thang daemon (best-effort).
// Tra ve YES neu lenh chay khong loi (trang thai thuc te phai kiem tra lai bang SWDetectSSHPort).
static BOOL SWSSHSetEnabled(BOOL on, NSString **msg) {
    int derr = 0;
    if (SWToolsdCall(on ? @"SSH_START\n" : @"SSH_STOP\n", &derr)) {
        return YES;
    }
    NSString *plist = SWFindSSHPlist();
    NSString *out = nil;
    int e = 0, rc = -1;
    if (plist) {
        NSArray<NSString *> *args = on ? @[@"launchctl", @"load", @"-w", plist]
                                       : @[@"launchctl", @"unload", plist];
        rc = SWRunFirst(SWLaunchctlPaths(), args, &out, &e);
        if (rc == -1) {
            if (msg) *msg = [NSString stringWithFormat:@"launchctl not runnable (%@)", SWErrText(e)];
            return NO;
        }
        if (rc != 0 && msg) {
            NSString *t = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            *msg = [NSString stringWithFormat:@"launchctl %@ exited %d%@%@", on ? @"load" : @"unload", rc,
                    t.length ? @": " : @"", t];
        }
        if (!on) {
            usleep(500 * 1000);
            if (SWDetectSSHPort() != 0) {   // van con listener (khong do launchd quan ly): kill
                SWKillByName(@"sshd", SIGKILL, NULL);
                SWKillByName(@"dropbear", SIGKILL, NULL);
            }
        }
        return rc == 0;
    }
    if (!on) {
        int e1 = 0;
        int a = SWKillByName(@"sshd", SIGKILL, &e1);
        int b = SWKillByName(@"dropbear", SIGKILL, &e1);
        if (a <= 0 && b <= 0 && msg) *msg = @"No SSH launchd plist found and no sshd/dropbear process to kill.";
        return (a > 0 || b > 0);
    }
    NSArray<NSString *> *sshdPaths = @[@"/var/jb/usr/sbin/sshd", @"/usr/sbin/sshd"];
    rc = SWRunFirst(sshdPaths, @[@"sshd"], &out, &e);
    if (rc == 0) return YES;
    rc = SWRunFirst(@[@"/var/jb/usr/sbin/dropbear", @"/var/jb/usr/local/sbin/dropbear", @"/usr/sbin/dropbear"],
                    @[@"dropbear", @"-R", @"-p", @"22"], &out, &e);
    if (rc == 0) return YES;
    if (msg) *msg = @"No SSH launchd plist (com.openssh.sshd.plist) and no sshd/dropbear binary could be started. "
                    @"Is OpenSSH installed (Sileo -> openssh)?";
    return NO;
}

#pragma mark - Accessibility (libAccessibility.dylib)

static void *SWAXHandle(void) {
    static void *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        if (!h) h = RTLD_DEFAULT;
    });
    return h;
}

static BOOL SWAXGet(NSDictionary<NSString *, NSString *> *item, BOOL *out) {
    NSString *nm = item[@"get"];
    void *f = dlsym(SWAXHandle(), nm.UTF8String);
    if (!f) return NO;
    if (out) *out = ((unsigned char (*)(void))f)() != 0;
    return YES;
}

static BOOL SWAXSet(NSDictionary<NSString *, NSString *> *item, BOOL on) {
    NSString *nm = item[@"set"];
    void *f = dlsym(SWAXHandle(), nm.UTF8String);
    if (!f) return NO;
    ((void (*)(unsigned char))f)(on ? 1 : 0);
    return YES;
}

// Chay block voi euid = user "mobile" (neu dang la root nhung ruid/suid cho phep quay lai).
// Dung khi cai dat accessibility ghi nham vao domain preferences cua root thay vi cua mobile.
static BOOL SWRunAsMobile(void (^blk)(void)) {
    struct passwd *pw = getpwnam("mobile");
    uid_t mu = pw ? pw->pw_uid : 501;
    uid_t saved = geteuid();
    if (saved == mu) {
        blk();
        return YES;
    }
    if (seteuid(mu) != 0) return NO;
    blk();
    (void)seteuid(saved);
    return geteuid() == saved;
}

#pragma mark - /var/tmp/metal.args

static NSString *SWTokenKey(NSString *t) {
    NSRange r = [t rangeOfString:@"="];
    return r.location == NSNotFound ? t : [t substringToIndex:r.location];
}

// Doc file hien tai. *info la mo ta de hien thi. File chua ton tai -> mang rong.
static NSMutableArray<NSString *> *SWReadMetalTokens(NSString **info) {
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

static BOOL SWWriteMetalTokens(NSArray<NSString *> *tokens, NSString **msg) {
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
    if (SWToolsdCall([NSString stringWithFormat:@"WRITE_METAL_ARGS\n%@", content], NULL)) {
        return YES;
    }
    if (msg) {
        *msg = [NSString stringWithFormat:@"%@ (%@ %ld)", e.localizedDescription ?: @"write error",
                e.domain ?: @"", (long)e.code];
    }
    return NO;
}

// Doi mot co key=1 / bo key; giu nguyen cac token la va doc lai file moi nhat truoc khi ghi.
static BOOL SWSetMetalFlag(NSString *key, BOOL on, NSString **msg) {
    NSMutableArray<NSString *> *tokens = SWReadMetalTokens(NULL);
    NSIndexSet *idx = [tokens indexesOfObjectsPassingTest:^BOOL(NSString *t, NSUInteger i, BOOL *stop) {
        return [SWTokenKey(t) isEqualToString:key];
    }];
    [tokens removeObjectsAtIndexes:idx];
    if (on) [tokens addObject:[key stringByAppendingString:@"=1"]];
    return SWWriteMetalTokens(tokens, msg);
}

#pragma mark - Log / snapshot helpers

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

// Doc `count` dong cuoi tu /var/log/sweetlog.txt, neu khong co thi tu dmesg.
static NSString *SWFetchKernelLog(BOOL filtered, NSUInteger count, NSString **sourceOut) {
    NSString *fileText = SWReadTailOfFile(kSweetLogPath, 1024 * 1024);
    if (fileText) {
        NSArray<NSString *> *lines = SWTailLines(fileText, filtered, count);
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
        NSArray<NSString *> *lines = SWTailLines(dmesg, filtered, count);
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

static NSString *SWUptimeString(void) {
    struct timeval bt;
    size_t l = sizeof(bt);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &bt, &l, NULL, 0) != 0 || bt.tv_sec == 0) return @"N/A";
    return SWFormatDuration([NSDate date].timeIntervalSince1970 - (double)bt.tv_sec);
}

static NSDateFormatter *SWPosixFormatter(NSString *fmt) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = fmt;
    return f;
}

// Anh chup toan bo thong tin debug thanh mot chuoi van ban (chay o thread nen).
// uiInfo: phan thong tin chi lay duoc tu UI (man hinh, thermal, SSH, accessibility) do thread chinh chuan bi.
static NSString *SWBuildSnapshot(NSString *uiInfo) {
    NSMutableString *s = [NSMutableString string];
    NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    [s appendFormat:@"SapphireTools v%@ debug snapshot\n", ver];
    [s appendFormat:@"date: %@\n", [SWPosixFormatter(@"yyyy-MM-dd HH:mm:ss Z") stringFromDate:[NSDate date]]];
    [s appendFormat:@"uid=%d euid=%d gid=%d egid=%d\n\n", (int)getuid(), (int)geteuid(), (int)getgid(), (int)getegid()];

    [s appendString:@"== Device ==\n"];
    for (NSString *k in @[@"hw.machine", @"hw.model", @"kern.osversion", @"kern.osrelease", @"kern.bootargs"]) {
        [s appendFormat:@"%@ = %@\n", k, SWSysctlDisplay(k)];
    }
    NSString *kv = SWSysctlDisplay(@"kern.version");
    NSRange nl = [kv rangeOfString:@"\n"];
    if (nl.location != NSNotFound) kv = [kv substringToIndex:nl.location];
    [s appendFormat:@"kern.version = %@\n", kv];
    [s appendFormat:@"uptime = %@\n\n", SWUptimeString()];

    [s appendString:@"== UI / display / thermal / ssh ==\n"];
    [s appendString:uiInfo.length ? uiInfo : @"(n/a)"];
    [s appendString:@"\n\n== kern.sweet_* sysctls ==\n"];
    NSArray<NSDictionary *> *entries = SWEnumerateSysctls(kSweetPrefix);
    if (entries.count == 0) [s appendString:@"(none found - is this the sapphire kernel?)\n"];
    for (NSDictionary *e in entries) {
        NSString *name = e[@"name"];
        [s appendFormat:@"%@ = %@   [%@ %@]\n", name, SWSysctlDisplay(name), e[@"access"], e[@"type"]];
    }

    [s appendFormat:@"\n== %@ ==\n", kMetalArgsPath];
    NSString *info = nil;
    SWReadMetalTokens(&info);
    [s appendFormat:@"%@\n", info ?: @"(n/a)"];

    [s appendString:@"\n== Services ==\n"];
    NSDictionary *procs = SWProcessMap();
    for (NSArray<NSString *> *svc in SWServiceList()) {
        [s appendFormat:@"%-14s %@\n", svc[0].UTF8String, SWDescribeProcs(procs[svc[0]])];
    }
    for (NSString *extra in @[@"sshd", @"dropbear"]) {
        if (procs[extra]) [s appendFormat:@"%-14s %@\n", extra.UTF8String, SWDescribeProcs(procs[extra])];
    }

    [s appendString:@"\n== Network ==\n"];
    NSArray<NSString *> *ips = SWInterfaceAddresses(NULL);
    [s appendString:ips.count ? [ips componentsJoinedByString:@"\n"] : @"(no IPv4 address)"];

    NSString *src = nil;
    NSString *log = SWFetchKernelLog(NO, kSnapshotLogLines, &src);
    [s appendFormat:@"\n\n== log: last %lu lines of %@ ==\n%@\n", (unsigned long)kSnapshotLogLines, src ?: @"N/A", log];
    return s;
}

// Luu snapshot vao /var/tmp (de scp ve PC), chi giu 5 file moi nhat. Tra ve duong dan hoac nil.
static NSString *SWSaveSnapshot(NSString *text) {
    NSString *stamp = [SWPosixFormatter(@"yyyyMMdd-HHmmss") stringFromDate:[NSDate date]];
    NSString *path = [kSnapshotDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@%@.txt", kSnapshotPrefix, stamp]];
    NSError *e = nil;
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e]) return nil;
    chmod(path.fileSystemRepresentation, 0644);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *old = [NSMutableArray array];
    for (NSString *f in [fm contentsOfDirectoryAtPath:kSnapshotDir error:NULL]) {
        if ([f hasPrefix:kSnapshotPrefix] && [f hasSuffix:@".txt"]) [old addObject:f];
    }
    [old sortUsingSelector:@selector(compare:)];   // ten co timestamp nen sap xep chu cai = theo thoi gian
    while (old.count > 5) {
        [fm removeItemAtPath:[kSnapshotDir stringByAppendingPathComponent:old.firstObject] error:NULL];
        [old removeObjectAtIndex:0];
    }
    return path;
}

#include <notify.h>
#include <sys/mman.h>
#include <sys/un.h>

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
} SWCamdSlot;

typedef struct {
    uint32_t magic, version;
    uint32_t header_size, slot_size, nslots;
    uint32_t latest;
    uint64_t seq;
    uint32_t running;
    uint32_t reserved[7];
    SWCamdSlot slot[CAMD_SHM_SLOTS];
} SWCamdShm;

#include <pthread.h>
static int gCamdSockFd = -1;
static pthread_mutex_t gCamdSockMu = PTHREAD_MUTEX_INITIALIZER;

static NSString *SWCamdCommand(NSString *cmd, double timeoutSec) {
    pthread_mutex_lock(&gCamdSockMu);
    BOOL isStop = [cmd hasPrefix:@"STOP"];
    if (gCamdSockFd < 0) {
        if (isStop) {
            pthread_mutex_unlock(&gCamdSockMu);
            return @"OK";
        }
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            pthread_mutex_unlock(&gCamdSockMu);
            return nil;
        }
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strlcpy(addr.sun_path, CAMD_SOCK_PATH, sizeof(addr.sun_path));
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            close(fd);
            pthread_mutex_unlock(&gCamdSockMu);
            return nil;
        }
        gCamdSockFd = fd;
    }
    NSString *line = [cmd hasSuffix:@"\n"] ? cmd : [cmd stringByAppendingString:@"\n"];
    const char *c = line.UTF8String;
    size_t len = strlen(c);
    if (write(gCamdSockFd, c, len) != (ssize_t)len) {
        close(gCamdSockFd);
        gCamdSockFd = -1;
        pthread_mutex_unlock(&gCamdSockMu);
        return nil;
    }
    NSMutableString *out = [NSMutableString string];
    char buf[512];
    int64_t deadline = SWNowMs() + (int64_t)(timeoutSec * 1000.0);
    for (;;) {
        int64_t left = deadline - SWNowMs();
        if (left <= 0) break;
        struct pollfd p = { gCamdSockFd, POLLIN, 0 };
        if (poll(&p, 1, (int)left) <= 0) break;
        ssize_t n = read(gCamdSockFd, buf, sizeof(buf) - 1);
        if (n <= 0) {
            close(gCamdSockFd);
            gCamdSockFd = -1;
            break;
        }
        buf[n] = '\0';
        [out appendFormat:@"%s", buf];
        if ([cmd hasPrefix:@"CAPTURE"]) {
            if ([out containsString:@"DONE "] || [out containsString:@"ERR "]) break;
        } else if ([out containsString:@"\n"]) {
            break;
        }
    }
    if (isStop && gCamdSockFd >= 0) {
        close(gCamdSockFd);
        gCamdSockFd = -1;
    }
    pthread_mutex_unlock(&gCamdSockMu);
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@interface SWCameraViewController : UIViewController
@property (nonatomic, strong) UIImageView *previewView;
@property (nonatomic, strong) UILabel *hudLabel;
@property (nonatomic, strong) UISegmentedControl *lensSeg;
@property (nonatomic, strong) UISegmentedControl *resSeg;
@property (nonatomic, strong) UISlider *evSlider;
@property (nonatomic, strong) UIButton *shutterBtn;
@property (nonatomic, assign) int shmFd;
@property (nonatomic, assign) void *shmPtr;
@property (nonatomic, assign) size_t shmLen;
@property (nonatomic, assign) int notifyToken;
@property (nonatomic, assign) uint64_t lastSeq;
@property (nonatomic, assign) int currentMode;
@property (nonatomic, strong) dispatch_queue_t camQueue;
@end

@implementation SWCameraViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sapphire Camera";
    self.view.backgroundColor = UIColor.blackColor;
    self.shmFd = -1;
    self.notifyToken = -1;
    self.currentMode = 1; // 1 = Main 12MP 4:3, 12 = UltraWide, 11 = Front, 13 = Macro
    self.camQueue = dispatch_queue_create("com.sapphire.tools.cam", DISPATCH_QUEUE_SERIAL);

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(closeTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"AF" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(afTapped)];

    self.previewView = [[UIImageView alloc] init];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView.contentMode = UIViewContentModeScaleAspectFit;
    self.previewView.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(previewTapped:)];
    [self.previewView addGestureRecognizer:tap];
    [self.view addSubview:self.previewView];

    self.hudLabel = SWMakeLabel([UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium], UIColor.whiteColor, 2);
    self.hudLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    self.hudLabel.textAlignment = NSTextAlignmentCenter;
    self.hudLabel.layer.cornerRadius = 6;
    self.hudLabel.clipsToBounds = YES;
    self.hudLabel.text = @"Connecting to camd…";
    [self.view addSubview:self.hudLabel];

    self.lensSeg = [[UISegmentedControl alloc] initWithItems:@[@"1x Main", @"0.6x UW", @"2x Crop", @"Macro", @"Front"]];
    self.lensSeg.translatesAutoresizingMaskIntoConstraints = NO;
    self.lensSeg.selectedSegmentIndex = 0;
    self.lensSeg.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
    [self.lensSeg addTarget:self action:@selector(lensChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.lensSeg];

    self.resSeg = [[UISegmentedControl alloc] initWithItems:@[@"12 MP", @"108 MP", @"12MP+DNG"]];
    self.resSeg.translatesAutoresizingMaskIntoConstraints = NO;
    self.resSeg.selectedSegmentIndex = 0;
    self.resSeg.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
    [self.view addSubview:self.resSeg];

    self.evSlider = [[UISlider alloc] init];
    self.evSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.evSlider.minimumValue = -2.0f;
    self.evSlider.maximumValue = 2.0f;
    self.evSlider.value = 0.0f;
    [self.evSlider addTarget:self action:@selector(evChanged:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.view addSubview:self.evSlider];

    self.shutterBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.shutterBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.shutterBtn.backgroundColor = UIColor.whiteColor;
    self.shutterBtn.layer.cornerRadius = 34;
    self.shutterBtn.layer.borderWidth = 4;
    self.shutterBtn.layer.borderColor = UIColor.systemGray2Color.CGColor;
    [self.shutterBtn addTarget:self action:@selector(shutterTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.shutterBtn];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.hudLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:6],
        [self.hudLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.hudLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.hudLabel.heightAnchor constraintEqualToConstant:34],

        [self.previewView.topAnchor constraintEqualToAnchor:self.hudLabel.bottomAnchor constant:6],
        [self.previewView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.previewView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.previewView.bottomAnchor constraintEqualToAnchor:self.lensSeg.topAnchor constant:-10],

        [self.lensSeg.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.lensSeg.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.lensSeg.bottomAnchor constraintEqualToAnchor:self.resSeg.topAnchor constant:-8],

        [self.resSeg.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.resSeg.widthAnchor constraintEqualToConstant:190],
        [self.resSeg.bottomAnchor constraintEqualToAnchor:self.shutterBtn.topAnchor constant:-12],

        [self.evSlider.leadingAnchor constraintEqualToAnchor:self.resSeg.trailingAnchor constant:12],
        [self.evSlider.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.evSlider.centerYAnchor constraintEqualToAnchor:self.resSeg.centerYAnchor],

        [self.shutterBtn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.shutterBtn.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-14],
        [self.shutterBtn.widthAnchor constraintEqualToConstant:68],
        [self.shutterBtn.heightAnchor constraintEqualToConstant:68],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    __weak typeof(self) ws = self;
    notify_register_dispatch(CAMD_NOTIFY_FRAME, &_notifyToken, dispatch_get_main_queue(), ^(int tok) {
        [ws renderLatestFrame];
    });
    [self startPreviewMode:self.currentMode];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.notifyToken != -1) {
        notify_cancel(self.notifyToken);
        self.notifyToken = -1;
    }
    dispatch_async(self.camQueue, ^{
        SWCamdCommand(@"STOP", 2.0);
    });
    if (self.shmPtr && self.shmPtr != MAP_FAILED) {
        munmap(self.shmPtr, self.shmLen);
        self.shmPtr = NULL;
    }
    if (self.shmFd >= 0) {
        close(self.shmFd);
        self.shmFd = -1;
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)startPreviewMode:(int)mode {
    self.currentMode = mode;
    self.hudLabel.text = [NSString stringWithFormat:@"Starting mode %d…", mode];
    __weak typeof(self) ws = self;
    dispatch_async(self.camQueue, ^{
        NSString *r = SWCamdCommand([NSString stringWithFormat:@"START %d", mode], 4.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            if (!r || ![r hasPrefix:@"OK"]) {
                s.hudLabel.text = [NSString stringWithFormat:@"camd error: %@", r ?: @"socket /var/run/camd.sock not reachable"];
                return;
            }
            s.hudLabel.text = r;
            [s openShmIfNeeded];
            [s renderLatestFrame];
        });
    });
}

- (void)openShmIfNeeded {
    if (self.shmPtr && self.shmPtr != MAP_FAILED) return;
    int fd = open(CAMD_SHM_PATH, O_RDONLY);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(SWCamdShm)) {
        close(fd);
        return;
    }
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        close(fd);
        return;
    }
    self.shmFd = fd;
    self.shmPtr = p;
    self.shmLen = (size_t)st.st_size;
}

- (void)renderLatestFrame {
    [self openShmIfNeeded];
    if (!self.shmPtr || self.shmPtr == MAP_FAILED) return;
    const SWCamdShm *shm = (const SWCamdShm *)self.shmPtr;
    if (shm->magic != CAMD_SHM_MAGIC || shm->nslots == 0) return;
    uint32_t idx = shm->latest;
    if (idx >= shm->nslots || idx >= CAMD_SHM_SLOTS) return;
    SWCamdSlot slot = shm->slot[idx];
    if (slot.seq == 0 || slot.seq == self.lastSeq || slot.width == 0 || slot.height == 0) return;
    size_t off = (size_t)shm->header_size + (size_t)idx * (size_t)shm->slot_size;
    size_t need = (size_t)slot.stride * (size_t)slot.height;
    if (off + need > self.shmLen) return;
    self.lastSeq = slot.seq;

    const uint8_t *pixels = (const uint8_t *)self.shmPtr + off;
    CFDataRef data = CFDataCreate(NULL, pixels, (CFIndex)need);
    if (!data) return;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
    CGBitmapInfo bi = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little;
    CGImageRef cg = CGImageCreate(slot.width, slot.height, 8, 32, slot.stride, cs, bi, prov, NULL, false, kCGRenderingIntentDefault);
    if (cg) {
        self.previewView.image = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
    }
    CGDataProviderRelease(prov);
    CGColorSpaceRelease(cs);
    CFRelease(data);

    self.hudLabel.text = [NSString stringWithFormat:@"#%llu  %ux%u  %.1f ms  %.1fx  luma %.2f",
                          (unsigned long long)slot.seq, slot.width, slot.height,
                          slot.exposure_us / 1000.0f, slot.gain, slot.luma];
}

- (void)lensChanged:(UISegmentedControl *)seg {
    static const int modes[] = { 1, 12, 4, 13, 11 };
    NSInteger idx = seg.selectedSegmentIndex;
    if (idx >= 0 && idx < 5) {
        [self startPreviewMode:modes[idx]];
    }
}

- (void)evChanged:(UISlider *)s {
    float v = s.value;
    dispatch_async(self.camQueue, ^{
        SWCamdCommand([NSString stringWithFormat:@"EV %.2f", v], 1.5);
    });
}

- (void)afTapped {
    dispatch_async(self.camQueue, ^{
        SWCamdCommand(@"AF", 2.0);
    });
    SWToast(self.view, @"Autofocus triggered");
}

- (void)previewTapped:(UITapGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.previewView];
    CGSize sz = self.previewView.bounds.size;
    if (sz.width < 1 || sz.height < 1) return;
    float nx = (float)(pt.x / sz.width);
    float ny = (float)(pt.y / sz.height);
    nx = nx < 0 ? 0 : (nx > 1 ? 1 : nx);
    ny = ny < 0 ? 0 : (ny > 1 ? 1 : ny);
    dispatch_async(self.camQueue, ^{
        SWCamdCommand([NSString stringWithFormat:@"METER %.3f,%.3f", nx, ny], 2.0);
    });
    SWToast(self.view, [NSString stringWithFormat:@"Spot meter & AF (%.2f, %.2f)", nx, ny]);
}

- (void)shutterTapped {
    self.shutterBtn.enabled = NO;
    self.shutterBtn.alpha = 0.4;
    NSInteger rIdx = self.resSeg.selectedSegmentIndex;
    NSString *cmd = (rIdx == 1) ? @"CAPTURE 108 nodng" : (rIdx == 2 ? @"CAPTURE 12 dng" : @"CAPTURE 12 nodng");
    self.hudLabel.text = [NSString stringWithFormat:@"Capturing (%@)…", cmd];
    __weak typeof(self) ws = self;
    dispatch_async(self.camQueue, ^{
        NSString *resp = SWCamdCommand(cmd, 25.0);
        NSString *jpgPath = nil;
        for (NSString *line in [resp componentsSeparatedByString:@"\n"]) {
            NSRange r = [line rangeOfString:@"DONE "];
            if (r.location != NSNotFound) {
                NSString *rest = [[line substringFromIndex:r.location + 5]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSRange dngR = [rest rangeOfString:@" DNG "];
                jpgPath = (dngR.location != NSNotFound) ? [rest substringToIndex:dngR.location] : rest;
            }
        }
        if (jpgPath.length) {
            UIImage *img = [UIImage imageWithContentsOfFile:jpgPath];
            if (img) {
                UIImageWriteToSavedPhotosAlbum(img, nil, NULL, NULL);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            s.shutterBtn.enabled = YES;
            s.shutterBtn.alpha = 1.0;
            if (jpgPath.length) {
                SWToast(s.view, [NSString stringWithFormat:@"Saved %@", jpgPath.lastPathComponent]);
            } else {
                SWToast(s.view, [NSString stringWithFormat:@"Capture: %@", resp ?: @"timeout"]);
            }
        });
    });
}

@end

#pragma mark - Log viewer

@interface SWLogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, assign) NSUInteger generation;
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
    NSUInteger gen = ++self.generation;   // bo qua ket qua cu neu nguoi dung doi bo loc lien tuc
    self.sourceLabel.text = @"Loading…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *src = nil;
        NSString *text = SWFetchKernelLog(filtered, kLogLines, &src);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s || s.generation != gen) return;
            s.textView.text = text;
            s.sourceLabel.text = [NSString stringWithFormat:@"Source: %@ • last %lu lines%@",
                                  src ?: @"N/A", (unsigned long)kLogLines, filtered ? @" (filtered)" : @""];
            [s.textView layoutIfNeeded];
            [s.textView scrollRangeToVisible:NSMakeRange(s.textView.text.length, 0)];
        });
    });
}

@end

#pragma mark - Sysctl Explorer

// Liet ke + sua moi kern.sweet_* (ke ca sysctl moi them sau nay, khong can sua app).
@interface SWSysctlExplorerViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *values;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *deltas;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *prevNums;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL loading;
@end

@implementation SWSysctlExplorerViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _entries = @[];
        _values = @{};
        _deltas = @{};
        _prevNums = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"kern.sweet_*";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"Copy all"
                                                             style:UIBarButtonItemStylePlain
                                                            target:self action:@selector(copyAll)];
    UIBarButtonItem *refresh =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(fullReload)];
    self.navigationItem.rightBarButtonItems = @[refresh, copy];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    [self reloadFull:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.timer) {
        __weak typeof(self) ws = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            [ws reloadFull:NO];
        }];
        self.timer.tolerance = 0.3;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)fullReload { [self reloadFull:YES]; }

- (void)reloadFull:(BOOL)full {
    if (self.loading) return;
    self.loading = YES;
    NSArray<NSDictionary *> *known = self.entries;
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *entries = (full || known.count == 0) ? SWEnumerateSysctls(kSweetPrefix) : known;
        NSMutableDictionary<NSString *, NSString *> *vals = [NSMutableDictionary dictionary];
        for (NSDictionary *e in entries) {
            NSString *name = e[@"name"];
            int err = 0;
            NSString *v = SWReadSysctlGuarded(name, &err);
            vals[name] = v ? (v.length ? v : @"(empty)") : SWNAText(err);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            NSMutableDictionary<NSString *, NSNumber *> *deltas = [NSMutableDictionary dictionary];
            for (NSDictionary *e in entries) {
                NSString *name = e[@"name"];
                long long n = 0;
                if (![e[@"type"] isEqualToString:@"string"] && SWParseInt(vals[name], &n)) {
                    NSNumber *prev = s.prevNums[name];
                    if (prev && prev.longLongValue != n) deltas[name] = @(n - prev.longLongValue);
                    s.prevNums[name] = @(n);
                }
            }
            s.entries = entries;
            s.values = vals;
            s.deltas = deltas;
            s.loading = NO;
            [s.tableView reloadData];
        });
    });
}

- (NSString *)plainText {
    NSMutableString *t = [NSMutableString string];
    for (NSDictionary *e in self.entries) {
        [t appendFormat:@"%@ = %@   [%@ %@]\n", e[@"name"], self.values[e[@"name"]] ?: @"?", e[@"access"], e[@"type"]];
    }
    return t;
}

- (void)copyAll {
    UIPasteboard.generalPasteboard.string = [self plainText];
    SWToast(self.view, @"All sysctls copied");
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.entries.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (self.entries.count == 0) {
        return @"No kern.sweet_* sysctls found. Is the sapphire kernel running?";
    }
    return @"Tap a row to copy or (if RW) edit. *_await sysctls block in the kernel and are never read. "
           @"(+n) = change since the previous refresh.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"x"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"x"];
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
        c.textLabel.numberOfLines = 0;
        c.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
        c.detailTextLabel.numberOfLines = 0;
    }
    NSDictionary *e = self.entries[(NSUInteger)ip.row];
    NSString *name = e[@"name"];
    c.textLabel.text = [NSString stringWithFormat:@"%@  [%@ %@]", name, e[@"access"], e[@"type"]];
    NSNumber *d = self.deltas[name];
    NSString *v = self.values[name] ?: @"…";
    c.detailTextLabel.text = d ? [NSString stringWithFormat:@"%@   (%+lld)", v, d.longLongValue] : v;
    c.detailTextLabel.textColor = d ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *e = self.entries[(NSUInteger)ip.row];
    NSString *name = e[@"name"];
    NSString *cur = self.values[name] ?: @"";
    BOOL writable = [e[@"writable"] boolValue] && !SWSysctlLooksBlocking(name);
    BOOL isString = [e[@"type"] isEqualToString:@"string"];
    BOOL isInt = [e[@"type"] isEqualToString:@"int"] || [e[@"type"] isEqualToString:@"quad"];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:name message:cur
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (writable && (isString || isInt)) {
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = cur;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            if (isInt) tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        }];
    }
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@ = %@", name, cur];
        SWToast(ws.view, @"Copied");
    }]];
    if (writable && (isString || isInt)) {
        __weak UIAlertController *wa = a;
        [a addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) {
            NSString *txt = wa.textFields.firstObject.text ?: @"";
            [ws applyValue:txt toName:name asString:isString];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)applyValue:(NSString *)txt toName:(NSString *)name asString:(BOOL)isString {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int err = 0;
        BOOL ok;
        long long v = 0;
        if (isString) {
            ok = [SWSysctl setString:txt name:name errorCode:&err];
        } else if (SWParseInt(txt, &v)) {
            ok = [SWSysctl setInteger:v name:name errorCode:&err];
        } else {
            ok = NO;
            err = EINVAL;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            if (!ok) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:
                                        [NSString stringWithFormat:@"Cannot write %@", name]
                                                                           message:SWErrText(err)
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [s presentViewController:a animated:YES completion:nil];
            }
            [s reloadFull:NO];
        });
    });
}

@end

#pragma mark - Main view controller

@interface SWMainViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UITableViewCell *> *> *sections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(void)> *actions;
@property (nonatomic, strong) dispatch_queue_t ioQueue;   // serial: doc/ghi sysctl theo thu tu, khong chan main thread

// Graphics & Metal
@property (nonatomic, strong) UISegmentedControl *metalSeg;
@property (nonatomic, strong) UILabel *metalValue;
@property (nonatomic, strong) UISlider *rscaleSlider;
@property (nonatomic, strong) UILabel *rscaleValue;
@property (nonatomic, strong) UISwitch *flushSwitch;
@property (nonatomic, strong) UILabel *flushValue;
@property (nonatomic, strong) NSArray<UISwitch *> *metalSwitches;
@property (nonatomic, strong) UILabel *metalArgsLabel;

// Display
@property (nonatomic, strong) UILabel *screenLabel;
@property (nonatomic, strong) UILabel *thermalLabel;
@property (nonatomic, strong) UISwitch *fpsSwitch;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) UIView *fpsBar;
@property (nonatomic, strong) CALayer *fpsDot;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) CFTimeInterval fpsLast;
@property (nonatomic, assign) CFTimeInterval fpsWinStart;
@property (nonatomic, assign) double fpsWorst;
@property (nonatomic, assign) NSUInteger fpsFrames;
@property (nonatomic, assign) NSUInteger fpsDrops;

// Touch
@property (nonatomic, strong) UISegmentedControl *tapSeg;
@property (nonatomic, strong) UILabel *tapValue;
@property (nonatomic, strong) UISlider *quietSlider;
@property (nonatomic, strong) UILabel *quietValue;
@property (nonatomic, strong) UISlider *staleSlider;
@property (nonatomic, strong) UILabel *staleValue;
@property (nonatomic, strong) UILabel *touchRateLabel;
@property (nonatomic, strong) UILabel *touchCountersLabel;

// Diagnostics
@property (nonatomic, strong) UILabel *frameStatsLabel;
@property (nonatomic, strong) UILabel *surfaceLabel;
@property (nonatomic, strong) UILabel *bootargsLabel;
@property (nonatomic, strong) UISwitch *autoSwitch;
@property (nonatomic, copy) NSString *frameStatsFull;
@property (nonatomic, copy) NSString *surfaceFull;
@property (nonatomic, copy) NSString *bootargsFull;

// Services
@property (nonatomic, strong) NSMutableArray<UILabel *> *svcLabels;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSDictionary *> *> *procMap;

// SSH
@property (nonatomic, strong) UISwitch *sshSwitch;
@property (nonatomic, strong) UILabel *sshStatusLabel;
@property (nonatomic, strong) UILabel *ipLabel;
@property (nonatomic, copy) NSString *primaryIP;
@property (nonatomic, assign) uint16_t sshPort;
@property (nonatomic, assign) BOOL sshBusy;

// Accessibility
@property (nonatomic, strong) NSArray<UISwitch *> *axSwitches;
@property (nonatomic, strong) NSArray<UILabel *> *axLabels;
@property (nonatomic, strong) UISwitch *axMobileSwitch;

@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) BOOL appActive;
@property (nonatomic, assign) BOOL liveBusy;
@property (nonatomic, assign) BOOL shownRootWarning;
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
    self.ioQueue = dispatch_queue_create("com.sapphire.tools.io", DISPATCH_QUEUE_SERIAL);

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 64;
    self.table.cellLayoutMarginsFollowReadableWidth = NO;
    [self.view addSubview:self.table];

    [self buildSections];
    [self refreshDisplayInfo];
    [self refreshAX];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(appBecameActive)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appResigned)
               name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(refreshAX)
               name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshAX)
               name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.visible = YES;
    [self refreshAll];
    [self updateTimer];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.shownRootWarning && geteuid() != 0) {
        self.shownRootWarning = YES;
        int e = 0;
        if (!SWToolsdCall(@"PING\n", &e)) {
            [self alertTitle:@"Not running as root & toolsd offline"
                     message:[NSString stringWithFormat:
                              @"uid=%d euid=%d and /var/run/sapphire-toolsd.sock is not responding (%@).\n\n"
                              @"Fix: install SapphireTools.deb (starts com.sapphire.toolsd as root).",
                              (int)getuid(), (int)geteuid(), SWErrText(e)]];
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.visible = NO;
    [self updateTimer];
}

- (void)appBecameActive {
    self.appActive = YES;
    if (self.visible) [self refreshAll];
    [self updateTimer];
}

- (void)appResigned {
    self.appActive = NO;
    [self updateTimer];
}

// Timer 2 s + CADisplayLink chi chay khi man hinh dang hien va app active.
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
    [self updateFPSLink];
}

- (void)refreshAll {
    [self refreshControls];
    [self refreshLive];
    [self refreshSSH];
    [self refreshAX];
    [self refreshDisplayInfo];
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
    UIView *titleView = t;
    NSString *hint = SWHintForTitle(title);
    if (hint) {
        UIStackView *ts = [[UIStackView alloc] initWithArrangedSubviews:@[t, SWHintLabel(hint)]];
        ts.axis = UILayoutConstraintAxisVertical;
        ts.spacing = 2;
        titleView = ts;
    }
    [titleView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [titleView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *top = [[UIStackView alloc] init];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 8;
    [top addArrangedSubview:titleView];
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
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSString *hint = SWHintForTitle(title);
    if (hint) {
        c.detailTextLabel.text = hint;
        c.detailTextLabel.font = [UIFont systemFontOfSize:12];
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.detailTextLabel.textAlignment = NSTextAlignmentCenter;
        c.detailTextLabel.numberOfLines = 0;
    }
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

- (UISwitch *)makeSwitch:(SEL)sel tag:(NSInteger)tag {
    UISwitch *s = [[UISwitch alloc] init];
    s.tag = tag;
    [s addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return s;
}

- (void)buildSections {
    __weak typeof(self) ws = self;
    self.sections = [NSMutableArray array];
    for (int i = 0; i < SecCount; i++) [self.sections addObject:[NSMutableArray array]];
    self.actions = [NSMutableDictionary dictionary];
    UIColor *blue = UIColor.systemBlueColor;

    // ---------- Graphics & Metal ----------
    [self addCell:[self buttonCellWithTitle:@"Preset A: 60Hz Locked (0% Cà giật, Nét 100%)" color:UIColor.systemGreenColor]
        toSection:SecGraphics action:^{
            [SWSysctl setInteger:60 name:@"kern.sweet_fb_hz" errorCode:NULL];
            [SWSysctl setInteger:1000 name:kSysRScale errorCode:NULL];
            [SWSysctl setInteger:5 name:@"kern.sweet_sched" errorCode:NULL];
            [SWSysctl setInteger:0 name:kSysFlipFlush errorCode:NULL];
            SWWriteMetalTokens(@[], nil);
            SWToast(ws.view, @"Đã đặt 60Hz Locked + Nét 100% (đang Respring…)");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SWKillProcesses(@[@"backboardd", @"SpringBoard"], nil);
            });
        }];

    [self addCell:[self buttonCellWithTitle:@"Preset B: 120Hz Smooth (Scale 75%, Siêu mượt)" color:blue]
        toSection:SecGraphics action:^{
            [SWSysctl setInteger:120 name:@"kern.sweet_fb_hz" errorCode:NULL];
            [SWSysctl setInteger:750 name:kSysRScale errorCode:NULL];
            [SWSysctl setInteger:5 name:@"kern.sweet_sched" errorCode:NULL];
            [SWSysctl setInteger:0 name:kSysFlipFlush errorCode:NULL];
            SWWriteMetalTokens(@[], nil);
            SWToast(ws.view, @"Đã đặt 120Hz + Scale 75% (đang Respring…)");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SWKillProcesses(@[@"backboardd", @"SpringBoard"], nil);
            });
        }];

    self.metalSeg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"SapphireMetal", @"HakiosMetal"]];
    [self.metalSeg addTarget:self action:@selector(metalChanged:) forControlEvents:UIControlEventValueChanged];
    self.metalValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Metal mode (kern.sweet_metal)" value:self.metalValue
                              control:self.metalSeg below:YES] toSection:SecGraphics action:nil];

    self.rscaleSlider = [self makeSliderMin:400 max:1000 tag:kTagRScale];
    self.rscaleValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"FB render scale (kern.sweet_fb_rscale)" value:self.rscaleValue
                              control:self.rscaleSlider below:YES] toSection:SecGraphics action:nil];

    self.flushSwitch = [self makeSwitch:@selector(flushChanged:) tag:0];
    self.flushValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"FB flip flush (kern.sweet_fb_flipflush)" value:self.flushValue
                              control:self.flushSwitch below:NO] toSection:SecGraphics action:nil];

    NSMutableArray<UISwitch *> *sw = [NSMutableArray array];
    NSArray<NSString *> *keys = SWMetalKeys();
    for (NSUInteger i = 0; i < keys.count; i++) {
        UISwitch *s = [self makeSwitch:@selector(metalFlagChanged:) tag:(NSInteger)i];
        [sw addObject:s];
        [self addCell:[self cellWithTitle:[NSString stringWithFormat:@"%@=1 (metal.args)", keys[i]]
                                    value:nil control:s below:NO] toSection:SecGraphics action:nil];
    }
    self.metalSwitches = sw;

    self.metalArgsLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:[kMetalArgsPath stringByAppendingString:@"  (tap to edit)"]
                                value:nil control:self.metalArgsLabel below:YES]
        toSection:SecGraphics action:^{ [ws editMetalArgs]; }];

    // ---------- Display ----------
    self.screenLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"Screen (UIScreen)" value:nil control:self.screenLabel below:YES]
        toSection:SecDisplay action:^{
            UIPasteboard.generalPasteboard.string = ws.screenLabel.text ?: @"";
            SWToast(ws.view, @"Copied");
        }];

    self.thermalLabel = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Thermal state" value:self.thermalLabel control:nil below:NO]
        toSection:SecDisplay action:nil];

    self.fpsSwitch = [self makeSwitch:@selector(fpsToggled:) tag:0];
    [self addCell:[self cellWithTitle:@"FPS meter (CADisplayLink)" value:nil control:self.fpsSwitch below:NO]
        toSection:SecDisplay action:nil];

    self.fpsLabel = SWMonoLabel(0);
    self.fpsLabel.text = @"off";
    [self addCell:[self cellWithTitle:@"Measured (tap to reset)" value:nil control:self.fpsLabel below:YES]
        toSection:SecDisplay action:^{ [ws resetFPS]; }];

    self.fpsBar = [[UIView alloc] init];
    self.fpsBar.backgroundColor = UIColor.tertiarySystemFillColor;
    self.fpsBar.layer.cornerRadius = 7;
    [self.fpsBar.heightAnchor constraintEqualToConstant:14].active = YES;
    [self addCell:[self cellWithTitle:@"Motion test" value:nil control:self.fpsBar below:YES]
        toSection:SecDisplay action:nil];

    // ---------- Touch ----------
    self.tapSeg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Single Tap", @"Double Tap"]];
    [self.tapSeg addTarget:self action:@selector(tapWakeChanged:) forControlEvents:UIControlEventValueChanged];
    self.tapValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Tap to wake (kern.sweet_tap_wake)" value:self.tapValue
                              control:self.tapSeg below:YES] toSection:SecTouch action:nil];

    self.quietSlider = [self makeSliderMin:0 max:200 tag:kTagQuiet];
    self.quietValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Touch quiet (kern.sweet_touch_quiet_ms)" value:self.quietValue
                              control:self.quietSlider below:YES] toSection:SecTouch action:nil];

    self.staleSlider = [self makeSliderMin:1000 max:10000 tag:kTagStale];
    self.staleValue = SWValueLabel();
    [self addCell:[self cellWithTitle:@"Touch stale (kern.sweet_touch_stale_ms)" value:self.staleValue
                              control:self.staleSlider below:YES] toSection:SecTouch action:nil];

    self.touchRateLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"Touch rate (kern.sweet_touch_rate)" value:nil
                              control:self.touchRateLabel below:YES] toSection:SecTouch action:nil];

    self.touchCountersLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"FOD / tap-wake counters" value:nil
                              control:self.touchCountersLabel below:YES] toSection:SecTouch action:nil];

    [self addCell:[self buttonCellWithTitle:@"Reset Touch Rate" color:blue]
        toSection:SecTouch action:^{ [ws resetTouchRate]; }];

    // ---------- Live Diagnostics ----------
    self.frameStatsLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"Frame stats (kern.sweet_fb_frame_stats)" value:nil
                              control:self.frameStatsLabel below:YES]
        toSection:SecDiag action:^{ [ws showValueTitle:kSysFrameStats text:ws.frameStatsFull]; }];

    self.surfaceLabel = SWMonoLabel(0);
    [self addCell:[self cellWithTitle:@"FB surface (kern.sweet_fb_surface)" value:nil
                              control:self.surfaceLabel below:YES]
        toSection:SecDiag action:^{ [ws showValueTitle:kSysSurface text:ws.surfaceFull]; }];

    self.bootargsLabel = SWMonoLabel(3);
    [self addCell:[self cellWithTitle:@"Boot args (kern.bootargs)" value:nil
                              control:self.bootargsLabel below:YES]
        toSection:SecDiag action:^{ [ws showValueTitle:kSysBootargs text:ws.bootargsFull]; }];

    self.autoSwitch = [self makeSwitch:@selector(autoToggled:) tag:0];
    self.autoSwitch.on = YES;
    [self addCell:[self cellWithTitle:@"Auto refresh (every 2 s)" value:nil control:self.autoSwitch below:NO]
        toSection:SecDiag action:nil];

    [self addCell:[self buttonCellWithTitle:@"Refresh now" color:blue]
        toSection:SecDiag action:^{ [ws refreshTapped]; }];

    [self addCell:[self buttonCellWithTitle:@"View Recent Kernel Log" color:blue]
        toSection:SecDiag action:^{ [ws showKernelLog]; }];

    // ---------- Services ----------
    self.svcLabels = [NSMutableArray array];
    for (NSArray<NSString *> *svc in SWServiceList()) {
        UILabel *v = SWValueLabel();
        [self.svcLabels addObject:v];
        NSString *name = svc[0];
        [self addCell:[self cellWithTitle:[NSString stringWithFormat:@"%@ (%@)", name, svc[1]]
                                    value:v control:nil below:NO]
            toSection:SecServices action:^{ [ws confirmRestartService:name]; }];
    }

    // ---------- SSH ----------
    self.sshSwitch = [self makeSwitch:@selector(sshToggled:) tag:0];
    self.sshStatusLabel = SWValueLabel();
    self.sshStatusLabel.text = @"…";
    [self addCell:[self cellWithTitle:@"SSH daemon" value:self.sshStatusLabel control:self.sshSwitch below:NO]
        toSection:SecSSH action:nil];

    self.ipLabel = SWMonoLabel(0);
    self.ipLabel.text = @"…";
    [self addCell:[self cellWithTitle:@"Device IP (tap: copy ssh command)" value:nil
                              control:self.ipLabel below:YES]
        toSection:SecSSH action:^{ [ws copySSHCommandScp:NO]; }];

    [self addCell:[self buttonCellWithTitle:@"Copy scp command" color:blue]
        toSection:SecSSH action:^{ [ws copySSHCommandScp:YES]; }];

    [self addCell:[self buttonCellWithTitle:@"Refresh SSH / IP" color:blue]
        toSection:SecSSH action:^{ [ws refreshSSH]; }];

    // ---------- Accessibility ----------
    NSMutableArray<UISwitch *> *axs = [NSMutableArray array];
    NSMutableArray<UILabel *> *axl = [NSMutableArray array];
    NSArray<NSDictionary<NSString *, NSString *> *> *items = SWAXItems();
    for (NSUInteger i = 0; i < items.count; i++) {
        UISwitch *s = [self makeSwitch:@selector(axToggled:) tag:(NSInteger)i];
        UILabel *l = SWValueLabel();
        [axs addObject:s];
        [axl addObject:l];
        [self addCell:[self cellWithTitle:items[i][@"title"] value:l control:s below:NO]
            toSection:SecAccess action:nil];
    }
    self.axSwitches = axs;
    self.axLabels = axl;
    self.axMobileSwitch = [[UISwitch alloc] init];
    [self addCell:[self cellWithTitle:@"Apply as user “mobile”" value:nil control:self.axMobileSwitch below:NO]
        toSection:SecAccess action:nil];

    // ---------- Tools ----------
    UITableViewCell *camCell = [self buttonCellWithTitle:@"Open Sapphire Camera (camd)" color:UIColor.systemGreenColor];
    camCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    [self addCell:camCell toSection:SecTools action:^{
        SWCameraViewController *cvc = [[SWCameraViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cvc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [ws presentViewController:nav animated:YES completion:nil];
    }];
    UITableViewCell *explorer = [self buttonCellWithTitle:@"Sysctl Explorer (kern.sweet_*)" color:blue];
    explorer.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    [self addCell:explorer toSection:SecTools action:^{
        [ws.navigationController pushViewController:[[SWSysctlExplorerViewController alloc] init] animated:YES];
    }];
    [self addCell:[self buttonCellWithTitle:@"Edit metal.args…" color:blue]
        toSection:SecTools action:^{ [ws editMetalArgs]; }];
    [self addCell:[self buttonCellWithTitle:@"Copy debug snapshot" color:blue]
        toSection:SecTools action:^{ [ws copySnapshot]; }];
    [self addCell:[self buttonCellWithTitle:@"Share debug snapshot…" color:blue]
        toSection:SecTools action:^{ [ws shareSnapshot]; }];
    [self addCell:[self buttonCellWithTitle:@"Share sweetlog.txt…" color:blue]
        toSection:SecTools action:^{ [ws shareSweetlog]; }];

    // ---------- Power & Actions ----------
    [self addCell:[self buttonCellWithTitle:@"Respring" color:blue]
        toSection:SecPower action:^{
            [ws runKill:@[@"backboardd", @"SpringBoard"] title:@"Respring failed"];
        }];
    [self addCell:[self buttonCellWithTitle:@"Restart SpringBoard only" color:blue]
        toSection:SecPower action:^{
            [ws runKill:@[@"SpringBoard"] title:@"Restart SpringBoard failed"];
        }];
    [self addCell:[self buttonCellWithTitle:@"Reboot" color:UIColor.systemRedColor]
        toSection:SecPower action:^{ [ws confirmReboot]; }];
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
        case SecGraphics: return @"Graphics & Metal";
        case SecDisplay:  return @"Display";
        case SecTouch:    return @"Touch";
        case SecDiag:     return @"Live Diagnostics";
        case SecServices: return @"Services";
        case SecSSH:      return @"SSH";
        case SecAccess:   return @"Accessibility";
        case SecTools:    return @"Tools & Export";
        default:          return @"Power & Actions";
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case SecGraphics:
            return @"kern.sweet_* values are applied immediately. metal.args is read when a Metal client starts, "
                   @"so respring or relaunch the app to apply changes.";
        case SecDisplay:
            return @"Screen is UIKit's view of the display: compare native px and max Hz with FB surface below. "
                   @"The FPS meter only runs while this screen is visible and draws a moving bar so the GPU path is exercised.";
        case SecTouch:
            return @"Touch parameters are applied by the kernel immediately.";
        case SecDiag:
            return @"Auto refresh runs while this screen is visible. Tap a value to view or copy it in full.";
        case SecServices:
            return @"Tap to restart (SIGKILL; launchd should respawn it). The new PID is reported after about 1.5 s. "
                   @"A daemon that is not part of this build simply shows “not running”.";
        case SecSSH:
            return @"Start = launchctl load -w on the OpenSSH plist (survives reboot). Stop = unload until next boot. "
                   @"If you still use the default password (usually “alpine”), change it with passwd. "
                   @"Probing the port may briefly spawn sshd -i when launchd owns the socket.";
        case SecAccess:
            return @"Resolved at runtime from libAccessibility.dylib. If SpringBoard does not react, enable "
                   @"“Apply as user mobile” (the preference may have been written to root's domain).";
        case SecTools:
            return @"Snapshots are also saved to /var/tmp/sapphire-snapshot-*.txt (last 5 kept): "
                   @"scp root@<ip>:/var/tmp/sapphire-snapshot-*.txt . from your PC.";
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

- (void)alertWriteFailure:(NSString *)name errorCode:(int)e {
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

#pragma mark Reading values (background -> main)

static NSDictionary *SWReadIntResult(NSString *name) {
    long long v = 0;
    int e = 0;
    if ([SWSysctl getInteger:&v name:name errorCode:&e]) return @{ @"ok": @YES, @"v": @(v) };
    return @{ @"ok": @NO, @"e": @(e) };
}

- (void)loadSegment:(UISegmentedControl *)seg label:(UILabel *)l result:(NSDictionary *)r {
    if ([r[@"ok"] boolValue]) {
        long long v = [r[@"v"] longLongValue];
        BOOL ok = (v >= 0 && v < (long long)seg.numberOfSegments);
        seg.enabled = YES;
        seg.selectedSegmentIndex = ok ? (NSInteger)v : UISegmentedControlNoSegment;
        SWSetValue(l, ok ? [NSString stringWithFormat:@"= %lld", v]
                         : [NSString stringWithFormat:@"%lld (unknown)", v]);
    } else {
        seg.enabled = NO;
        seg.selectedSegmentIndex = UISegmentedControlNoSegment;
        SWSetValue(l, SWNAText([r[@"e"] intValue]));
    }
}

- (void)loadSlider:(UISlider *)s label:(UILabel *)l result:(NSDictionary *)r unit:(NSString *)unit {
    if (s.isTracking) return;   // khong ghi de gia tri khi nguoi dung dang keo
    if ([r[@"ok"] boolValue]) {
        long long v = [r[@"v"] longLongValue];
        s.enabled = YES;
        s.value = (float)v;
        SWSetValue(l, [NSString stringWithFormat:@"%lld%@", v, unit]);
    } else {
        s.enabled = NO;
        SWSetValue(l, SWNAText([r[@"e"] intValue]));
    }
}

- (void)loadSwitch:(UISwitch *)s label:(UILabel *)l result:(NSDictionary *)r {
    if ([r[@"ok"] boolValue]) {
        s.enabled = YES;
        [s setOn:([r[@"v"] longLongValue] != 0) animated:NO];
        SWSetValue(l, @"");
    } else {
        s.enabled = NO;
        [s setOn:NO animated:NO];
        SWSetValue(l, SWNAText([r[@"e"] intValue]));
    }
}

// Cac control co the chinh sua: doc o thread nen, ap dung o main (khong goi tu timer de khong
// lam gian doan khi dang keo slider).
- (void)refreshControls {
    __weak typeof(self) ws = self;
    dispatch_async(self.ioQueue, ^{
        NSMutableDictionary<NSString *, NSDictionary *> *res = [NSMutableDictionary dictionary];
        for (NSString *n in @[kSysMetal, kSysRScale, kSysFlipFlush, kSysTapWake, kSysQuietMs, kSysStaleMs]) {
            res[n] = SWReadIntResult(n);
        }
        NSString *info = nil;
        NSArray<NSString *> *tokens = SWReadMetalTokens(&info);
        NSString *boot = SWSysctlDisplay(kSysBootargs);
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws applyControls:res metalInfo:info tokens:tokens bootargs:boot];
        });
    });
}

- (void)applyControls:(NSDictionary<NSString *, NSDictionary *> *)res
            metalInfo:(NSString *)info
               tokens:(NSArray<NSString *> *)tokens
             bootargs:(NSString *)boot {
    [self loadSegment:self.metalSeg label:self.metalValue result:res[kSysMetal]];
    [self loadSlider:self.rscaleSlider label:self.rscaleValue result:res[kSysRScale] unit:@""];
    [self loadSwitch:self.flushSwitch label:self.flushValue result:res[kSysFlipFlush]];
    [self loadSegment:self.tapSeg label:self.tapValue result:res[kSysTapWake]];
    [self loadSlider:self.quietSlider label:self.quietValue result:res[kSysQuietMs] unit:@" ms"];
    [self loadSlider:self.staleSlider label:self.staleValue result:res[kSysStaleMs] unit:@" ms"];

    self.metalArgsLabel.text = info;
    NSArray<NSString *> *keys = SWMetalKeys();
    for (NSUInteger i = 0; i < keys.count && i < self.metalSwitches.count; i++) {
        [self.metalSwitches[i] setOn:SWFlagOn(tokens, keys[i]) animated:NO];
    }
    self.bootargsFull = boot;
    self.bootargsLabel.text = boot;
    [self relayoutTable];
}

// Cac gia tri "song": cap nhat moi 2 giay (doc o thread nen, bo qua neu lan truoc chua xong).
- (void)refreshLive {
    if (self.liveBusy) return;
    self.liveBusy = YES;
    __weak typeof(self) ws = self;
    dispatch_async(self.ioQueue, ^{
        NSString *frame = SWSysctlDisplay(kSysFrameStats);
        NSString *surface = SWSysctlDisplay(kSysSurface);
        NSString *rate = SWSysctlDisplay(kSysTouchRate);
        NSString *counters = [NSString stringWithFormat:@"fod_press=%@  fod_seq=%@  tap_wakes=%@",
                              SWSysctlDisplay(kSysFodPress), SWSysctlDisplay(kSysFodSeq),
                              SWSysctlDisplay(kSysTapWakes)];
        NSDictionary *procs = SWProcessMap();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            s.liveBusy = NO;
            [s applyLiveFrame:frame surface:surface rate:rate counters:counters procs:procs];
        });
    });
}

- (void)applyLiveFrame:(NSString *)frame surface:(NSString *)surface rate:(NSString *)rate
              counters:(NSString *)counters procs:(NSDictionary *)procs {
    BOOL changed = NO;
    self.frameStatsFull = frame;
    self.surfaceFull = surface;
    SWSetText(self.frameStatsLabel, frame, &changed);
    SWSetText(self.surfaceLabel, surface, &changed);
    SWSetText(self.touchRateLabel, rate, &changed);
    SWSetText(self.touchCountersLabel, counters, &changed);

    self.procMap = procs;
    NSArray<NSArray<NSString *> *> *svcs = SWServiceList();
    for (NSUInteger i = 0; i < svcs.count && i < self.svcLabels.count; i++) {
        NSArray<NSDictionary *> *list = procs[svcs[i][0]];
        UILabel *l = self.svcLabels[i];
        SWSetText(l, SWDescribeProcs(list), &changed);
        l.textColor = list.count ? UIColor.systemGreenColor : UIColor.systemRedColor;
    }

    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"Nominal", @"Fair", @"Serious", @"Critical"]; });
    NSProcessInfo *pi = NSProcessInfo.processInfo;
    NSInteger ts = (NSInteger)pi.thermalState;
    NSString *thermal = (ts >= 0 && ts < (NSInteger)names.count) ? names[(NSUInteger)ts] : @"?";
    if (pi.isLowPowerModeEnabled) thermal = [thermal stringByAppendingString:@" · LPM"];
    SWSetText(self.thermalLabel, thermal, &changed);
    switch (ts) {
        case 0:  self.thermalLabel.textColor = UIColor.systemGreenColor; break;
        case 1:  self.thermalLabel.textColor = UIColor.systemYellowColor; break;
        default: self.thermalLabel.textColor = UIColor.systemRedColor; break;
    }
    if (changed) [self relayoutTable];
}

- (void)refreshDisplayInfo {
    UIScreen *sc = UIScreen.mainScreen;
    CGSize pt = sc.bounds.size, px = sc.nativeBounds.size;
    NSString *t = [NSString stringWithFormat:@"%.0f×%.0f pt @%.1fx · native %.0f×%.0f px (scale %.2f)\nmax %ld Hz",
                   pt.width, pt.height, sc.scale, px.width, px.height, sc.nativeScale,
                   (long)sc.maximumFramesPerSecond];
    BOOL changed = NO;
    SWSetText(self.screenLabel, t, &changed);
    if (changed) [self relayoutTable];
}

- (void)relayoutTable {
    [UIView performWithoutAnimation:^{
        [self.table beginUpdates];
        [self.table endUpdates];
    }];
}

- (void)refreshTapped {
    [self refreshAll];
}

- (void)autoToggled:(UISwitch *)s {
    [self updateTimer];
    if (s.isOn) [self refreshLive];
}

#pragma mark FPS meter

- (void)fpsToggled:(UISwitch *)s {
    [self resetFPS];
    [self updateFPSLink];
}

- (void)resetFPS {
    self.fpsLast = 0;
    self.fpsWinStart = 0;
    self.fpsFrames = 0;
    self.fpsWorst = 0;
    self.fpsDrops = 0;
    if (!self.fpsSwitch.isOn) self.fpsLabel.text = @"off";
}

- (void)updateFPSLink {
    BOOL want = self.visible && self.appActive && self.fpsSwitch.isOn;
    if (want && !self.link) {
        CADisplayLink *l = [CADisplayLink displayLinkWithTarget:self selector:@selector(fpsTick:)];
        float mx = (float)UIScreen.mainScreen.maximumFramesPerSecond;
        if (mx < 30) mx = 60;
        l.preferredFrameRateRange = CAFrameRateRangeMake(30, mx, mx);
        [l addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        self.link = l;
        self.fpsLast = 0;
        self.fpsWinStart = 0;
        self.fpsFrames = 0;
        [self startBarAnimation];
    } else if (!want && self.link) {
        [self.link invalidate];   // CADisplayLink giu target manh: bat buoc invalidate de khong ro ri
        self.link = nil;
        [self stopBarAnimation];
        if (!self.fpsSwitch.isOn) self.fpsLabel.text = @"off";
    }
}

- (void)fpsTick:(CADisplayLink *)l {
    CFTimeInterval now = l.timestamp;
    if (self.fpsLast > 0) {
        double dt = now - self.fpsLast;
        double expected = l.targetTimestamp - l.timestamp;
        if (expected < 1.0 / 240.0) expected = 1.0 / 240.0;
        if (dt > self.fpsWorst) self.fpsWorst = dt;
        if (dt > expected * 1.5) {
            double missed = round(dt / expected) - 1.0;
            self.fpsDrops += (NSUInteger)(missed < 1.0 ? 1.0 : missed);
        }
    }
    self.fpsLast = now;
    self.fpsFrames++;
    if (self.fpsWinStart == 0) self.fpsWinStart = now;
    if (now - self.fpsWinStart >= 0.5) {
        double fps = (double)self.fpsFrames / (now - self.fpsWinStart);
        self.fpsLabel.text = [NSString stringWithFormat:@"%.1f fps · worst %.1f ms · drops %lu",
                              fps, self.fpsWorst * 1000.0, (unsigned long)self.fpsDrops];
        self.fpsFrames = 0;
        self.fpsWinStart = now;
    }
}

- (void)startBarAnimation {
    if (!self.fpsDot) {
        CALayer *d = [CALayer layer];
        d.bounds = CGRectMake(0, 0, 28, 14);
        d.cornerRadius = 7;
        d.backgroundColor = UIColor.systemBlueColor.CGColor;
        [self.fpsBar.layer addSublayer:d];
        self.fpsDot = d;
    }
    CGFloat w = self.fpsBar.bounds.size.width;
    if (w < 60) w = 300;
    self.fpsDot.position = CGPointMake(14, 7);
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.x"];
    a.fromValue = @14;
    a.toValue = @(w - 14);
    a.duration = 0.8;
    a.autoreverses = YES;
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [self.fpsDot addAnimation:a forKey:@"slide"];
}

- (void)stopBarAnimation {
    [self.fpsDot removeAllAnimations];
}

#pragma mark Writing sysctl values

- (void)writeInt:(long long)v name:(NSString *)name {
    __weak typeof(self) ws = self;
    dispatch_async(self.ioQueue, ^{
        int e = 0;
        BOOL ok = [SWSysctl setInteger:v name:name errorCode:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            if (!ok) [s alertWriteFailure:name errorCode:e];
            [s refreshControls];
            [s refreshLive];
        });
    });
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
    __weak typeof(self) ws = self;
    dispatch_async(self.ioQueue, ^{
        int e = 0;
        BOOL ok = [SWSysctl setInteger:0 name:kSysTouchRate errorCode:&e];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            if (ok) SWToast(s.view, @"Touch rate reset");
            else [s alertWriteFailure:kSysTouchRate errorCode:e];
            [s refreshLive];
        });
    });
}

#pragma mark /var/tmp/metal.args

- (void)metalFlagChanged:(UISwitch *)sw {
    NSArray<NSString *> *keys = SWMetalKeys();
    if (sw.tag < 0 || (NSUInteger)sw.tag >= keys.count) return;
    NSString *msg = nil;
    if (SWSetMetalFlag(keys[(NSUInteger)sw.tag], sw.isOn, &msg)) {
        SWToast(self.view, @"metal.args saved");
    } else {
        [self alertTitle:@"Cannot write /var/tmp/metal.args" message:msg ?: @"Unknown error"];
    }
    [self refreshControls];
}

// Sua tu do: metal_gmem_draws=…, metal_defer=… va moi key khac ma Hakios doc.
- (void)editMetalArgs {
    NSString *info = nil;
    NSArray<NSString *> *tokens = SWReadMetalTokens(&info);
    NSString *cur = [tokens componentsJoinedByString:@" "];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Edit metal.args"
        message:@"Space-separated key=value tokens, e.g.\nmetal_gmem=1 metal_defer=1 metal_gmem_draws=64\nEmpty text clears the file."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) ws = self;
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSMutableArray<NSString *> *toks = [NSMutableArray array];
        NSString *text = wa.textFields.firstObject.text ?: @"";
        for (NSString *t in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
            if (t.length) [toks addObject:t];
        }
        NSString *msg = nil;
        if (SWWriteMetalTokens(toks, &msg)) SWToast(ws.view, @"metal.args saved");
        else [ws alertTitle:@"Cannot write /var/tmp/metal.args" message:msg ?: @"Unknown error"];
        [ws refreshControls];
    }]];
    [SWTopViewController(self) presentViewController:a animated:YES completion:nil];
}

#pragma mark Services

- (void)confirmRestartService:(NSString *)name {
    BOOL critical = [name isEqualToString:@"SpringBoard"] || [name isEqualToString:@"backboardd"];
    NSString *msg = critical
        ? @"The screen will go black for a few seconds and this app will be closed."
        : @"The process is killed (SIGKILL); launchd should start it again.";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Restart %@?", name]
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) { [ws restartService:name]; }]];
    [SWTopViewController(self) presentViewController:a animated:YES completion:nil];
}

- (void)restartService:(NSString *)name {
    NSArray<NSDictionary *> *before = self.procMap[name];
    int oldPid = before.count ? [before.firstObject[@"pid"] intValue] : 0;
    __weak typeof(self) ws = self;
    dispatch_async(self.ioQueue, ^{
        int e = 0;
        int k = SWKillByName(name, SIGKILL, &e);
        NSDictionary *after = nil;
        if (k > 0) {
            usleep(1500 * 1000);
            after = SWProcessMap();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            if (k < 0) {
                [s alertTitle:[NSString stringWithFormat:@"Cannot restart %@", name] message:SWErrText(e)];
            } else if (k == 0) {
                [s alertTitle:[NSString stringWithFormat:@"%@ is not running", name]
                      message:@"Nothing to kill. If it should be running, check launchd."];
            } else {
                NSArray<NSDictionary *> *now = after[name];
                if (now.count) {
                    SWToast(s.view, [NSString stringWithFormat:@"%@ restarted: PID %d → %d", name, oldPid,
                                     [now.firstObject[@"pid"] intValue]]);
                } else {
                    [s alertTitle:[NSString stringWithFormat:@"%@ did not come back", name]
                          message:@"Not running 1.5 s after the kill. It may need more time, or launchd may not manage it."];
                }
            }
            [s refreshLive];
        });
    });
}

#pragma mark SSH

- (void)refreshSSH {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *ip = nil;
        NSArray<NSString *> *lines = SWInterfaceAddresses(&ip);
        uint16_t port = SWDetectSSHPort();
        NSDictionary *procs = SWProcessMap();
        NSString *daemon = procs[@"sshd"] ? @"sshd" : (procs[@"dropbear"] ? @"dropbear" : nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s || s.sshBusy) return;
            s.primaryIP = ip;
            s.sshPort = port;
            [s.sshSwitch setOn:(port != 0) animated:NO];
            NSString *st = port ? [NSString stringWithFormat:@"listening :%u", (unsigned)port]
                                : (daemon ? [NSString stringWithFormat:@"stopped (%@ sessions only)", daemon] : @"stopped");
            BOOL changed = NO;
            SWSetText(s.sshStatusLabel, st, &changed);
            s.sshStatusLabel.textColor = port ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
            SWSetText(s.ipLabel, lines.count ? [lines componentsJoinedByString:@"\n"]
                                             : @"No IPv4 address (Wi-Fi off?)", &changed);
            if (changed) [s relayoutTable];
        });
    });
}

- (void)sshToggled:(UISwitch *)sw {
    if (sw.isOn) {
        [self setSSH:YES];
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Stop SSH?"
        message:@"Active SSH sessions (including scp transfers) will be closed."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { [ws refreshSSH]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) { [ws setSSH:NO]; }]];
    [SWTopViewController(self) presentViewController:a animated:YES completion:nil];
}

- (void)setSSH:(BOOL)on {
    self.sshBusy = YES;
    self.sshSwitch.enabled = NO;
    self.sshStatusLabel.text = on ? @"starting…" : @"stopping…";
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *msg = nil;
        (void)SWSSHSetEnabled(on, &msg);
        BOOL reached = NO;
        for (int i = 0; i < 14; i++) {   // cho toi da ~4 s cho trang thai doi
            usleep(300 * 1000);
            if ((SWDetectSSHPort() != 0) == on) {
                reached = YES;
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            s.sshBusy = NO;
            s.sshSwitch.enabled = YES;
            [s refreshSSH];
            if (reached) {
                SWToast(s.view, on ? @"SSH started" : @"SSH stopped");
            } else {
                [s alertTitle:on ? @"SSH did not start" : @"SSH is still listening"
                      message:msg ?: @"The daemon state did not change within 4 s."];
            }
        });
    });
}

- (void)copySSHCommandScp:(BOOL)scp {
    if (!self.primaryIP) {
        SWToast(self.view, @"No IP address (Wi-Fi off?)");
        return;
    }
    unsigned port = self.sshPort ? self.sshPort : 22;
    NSString *cmd;
    if (scp) {
        cmd = [NSString stringWithFormat:@"scp%@ ./file root@%@:/var/tmp/",
               port != 22 ? [NSString stringWithFormat:@" -P %u", port] : @"", self.primaryIP];
    } else {
        cmd = [NSString stringWithFormat:@"ssh%@ root@%@",
               port != 22 ? [NSString stringWithFormat:@" -p %u", port] : @"", self.primaryIP];
    }
    UIPasteboard.generalPasteboard.string = cmd;
    SWToast(self.view, [NSString stringWithFormat:@"Copied: %@", cmd]);
}

#pragma mark Accessibility

- (void)refreshAX {
    NSArray<NSDictionary<NSString *, NSString *> *> *items = SWAXItems();
    for (NSUInteger i = 0; i < items.count && i < self.axSwitches.count; i++) {
        BOOL on = NO;
        UISwitch *sw = self.axSwitches[i];
        UILabel *l = self.axLabels[i];
        if (SWAXGet(items[i], &on)) {
            sw.enabled = YES;
            [sw setOn:on animated:NO];
            SWSetValue(l, @"");
        } else {
            sw.enabled = NO;
            [sw setOn:NO animated:NO];
            SWSetValue(l, @"N/A (symbol missing)");
        }
    }
}

- (void)axToggled:(UISwitch *)sw {
    NSArray<NSDictionary<NSString *, NSString *> *> *items = SWAXItems();
    if (sw.tag < 0 || (NSUInteger)sw.tag >= items.count) return;
    NSDictionary<NSString *, NSString *> *it = items[(NSUInteger)sw.tag];
    BOOL on = sw.isOn;
    __block BOOL ok = NO;
    if (self.axMobileSwitch.isOn) {
        BOOL ran = SWRunAsMobile(^{ ok = SWAXSet(it, on); });
        if (!ran) {
            [self alertTitle:@"Cannot switch to user mobile"
                     message:@"seteuid() failed or the original euid could not be restored. "
                             @"The binary must be setuid-root."];
        }
    } else {
        ok = SWAXSet(it, on);
    }
    if (ok) {
        SWToast(self.view, [NSString stringWithFormat:@"%@ %@", it[@"title"], on ? @"ON" : @"OFF"]);
    } else {
        [self alertTitle:@"Accessibility setter not found"
                 message:[NSString stringWithFormat:@"%@ is not exported by libAccessibility.dylib on this build.",
                          it[@"set"]]];
    }
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [ws refreshAX];
    });
}

#pragma mark Snapshot / export

// Phan thong tin chi lay duoc tu UI, ghep vao snapshot.
- (NSString *)uiInfoString {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"screen : %@\n", [self.screenLabel.text stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] ?: @"?"];
    [s appendFormat:@"thermal: %@\n", self.thermalLabel.text ?: @"?"];
    [s appendFormat:@"fps    : %@\n", self.fpsLabel.text ?: @"?"];
    for (NSDictionary<NSString *, NSString *> *it in SWAXItems()) {
        BOOL on = NO;
        [s appendFormat:@"ax     : %@ = %@\n", it[@"title"], SWAXGet(it, &on) ? (on ? @"ON" : @"OFF") : @"N/A"];
    }
    [s appendFormat:@"ssh    : %@ (port %u)\n", self.sshStatusLabel.text ?: @"?", (unsigned)self.sshPort];
    [s appendFormat:@"ip     : %@", [self.ipLabel.text stringByReplacingOccurrencesOfString:@"\n" withString:@", "] ?: @"?"];
    return s;
}

- (void)collectSnapshot:(void (^)(NSString *text, NSString *path))done {
    NSString *ui = [self uiInfoString];
    SWToast(self.view, @"Collecting snapshot…");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *text = SWBuildSnapshot(ui);
        NSString *path = SWSaveSnapshot(text);
        dispatch_async(dispatch_get_main_queue(), ^{ done(text, path); });
    });
}

- (void)copySnapshot {
    __weak typeof(self) ws = self;
    [self collectSnapshot:^(NSString *text, NSString *path) {
        UIPasteboard.generalPasteboard.string = text;
        SWToast(ws.view, path ? [NSString stringWithFormat:@"Copied. Saved %@", path.lastPathComponent]
                              : @"Copied (could not save the file to /var/tmp)");
    }];
}

- (void)presentShareItems:(NSArray *)items {
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:items
                                                                     applicationActivities:nil];
    vc.popoverPresentationController.sourceView = self.view;
    vc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                             CGRectGetMidY(self.view.bounds), 1, 1);
    [SWTopViewController(self) presentViewController:vc animated:YES completion:nil];
}

- (void)shareSnapshot {
    __weak typeof(self) ws = self;
    [self collectSnapshot:^(NSString *text, NSString *path) {
        // Neu share sheet khong chay duoc tren ban port nay: dung "Copy debug snapshot" hoac scp file trong /var/tmp.
        [ws presentShareItems:path ? @[[NSURL fileURLWithPath:path]] : @[text]];
    }];
}

- (void)shareSweetlog {
    if (access(kSweetLogPath.fileSystemRepresentation, R_OK) != 0) {
        [self alertTitle:@"Cannot read sweetlog.txt" message:SWErrText(errno)];
        return;
    }
    [self presentShareItems:@[[NSURL fileURLWithPath:kSweetLogPath]]];
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
        signal(SIGPIPE, SIG_IGN);
#ifdef SW_FULL_ROOT
        // Tuy chon (make FULL_ROOT=1): bien ruid/rgid thanh root luon, de cac tool duoc spawn (launchctl...)
        // thay uid=0 that su. Doi lai HOME/prefs cua app chuyen sang /var/root.
        if (geteuid() == 0 && getuid() != 0) {
            (void)setgid(0);
            (void)setuid(0);
        }
#endif
        // Mac dinh KHONG goi setuid(0): neu binary la setuid-root thi euid da la 0 (du de ghi sysctl/reboot);
        // neu khong phai thi setuid(0) luon that bai (EPERM) nen khong co tac dung.
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SWAppDelegate class]));
    }
}
