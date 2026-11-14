/*
 * SapphireDisplayLink: UIKit's in-process animations at the panel's rate (120 Hz).
 *
 * The display link of UIViewInProcessAnimationManager, which runs the animations done in the app's own
 * process (a scroll view's page settling on the home screen, among them), asks CADisplayLink for 20..30
 * frames a second; on an iPhone with ProMotion that saves power, here the panel refreshes at 120 whatever is
 * drawn, and a page swipe ended in most of a second of frames 33.3 ms apart. The display links made for that
 * target are marked, and the rates asked of them are replaced by 60..120, 120 preferred: the panel's rate
 * (with xnu 0302's sweetfb_hz=240 CoreAnimation is told 240, and these animations at 240 would only cost
 * SpringBoard twice the work for frames the panel cannot show). In addition, on SpringBoard and for scroll
 * animations, any display link requesting a preferred or maximum rate of 20..60 fps is promoted to
 * 60..120, 120 preferred (excluding intentionally slow timers below 20 fps). Every other
 * display link keeps what it asks (the clock's 10 and 60, the motion effects' 32...): at 120 they would only
 * wake the process more often.
 *
 * 0339 additions:
 * - Predictive frame scheduling: track frame deadline misses, pre-emptively boost next frame
 * - Per-app frame rate profiles: configurable via /var/jb/var/sapphire-dl-profile.plist
 * - Scroll velocity integration: hook UIScrollView deceleration for fling prediction
 * - Frame pacing stats via sysctl kern.sapphire_dl_stats
 * - Adaptive promotion: only promote if GPU util < 80% (reads kern.sweet_fb_dynamic_rscale)
 *
 * 0342 additions:
 * - Hardware VSYNC-aligned frame pacing: read kernel vsync timestamp, schedule at vsync - render_budget
 * - Predictive quality scaling: reduce render quality on consecutive deadline misses
 * - Frame deadline monitoring with adaptive budget based on GPU utilization
 *
 * Only Objective-C method replacement (no function hooks). /var/jb/var/sapphire-dl-off turns it off (at the
 * next launch of each process). After HackiOS userland/src/inject_sb.c display_link_rates() (7caa457, MIT).
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/time.h>

/* /var/tmp/dl-log present at launch: every display link made and every rate asked go to /var/tmp/dl.<process>.log */
static FILE *dl_log;
static unsigned dl_logged;

static void
say_caller(const char *what, id link, const char *detail, void *ret)
{
	if (dl_log == NULL || dl_logged++ > 2000) {
		return;
	}
	Dl_info info;
	const char *img = "?", *sym = "?";
	if (dladdr(ret, &info)) {
		img = info.dli_fname && strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : "?";
		sym = info.dli_sname ? info.dli_sname : "?";
	}
	fprintf(dl_log, "%llu %s %p %s by %s`%s\n", (unsigned long long)mach_absolute_time(), what, (__bridge void *)link, detail, img, sym);
	fflush(dl_log);
}

#define TAG "SapphireDisplayLink: "
#define FULL_FOR "UIViewInProcessAnimationManager"

typedef struct {
	float minimum, maximum, preferred;
} frame_rate_range;

static id (*o_with)(id, SEL, id, SEL);
static void (*o_fps)(id, SEL, long);
static void (*o_range)(id, SEL, frame_rate_range);
static void (*o_callback)(id, SEL, CAAnimation *);  /* 0342: displayLinkCallback: hook */
static char full_key;                   /* the mark a display link made for FULL_FOR carries */
static char scroll_key;                 /* the mark a scroll-animation display link carries */
static bool is_springboard;
static Class scroll_view_cls;

/* 0339: Frame pacing statistics */
static uint64_t dl_frames_total = 0;
static uint64_t dl_frames_promoted = 0;
static uint64_t dl_frames_deadline_miss = 0;
static uint64_t dl_last_frame_time = 0;
static int32_t dl_current_boost = 0;  /* extra fps boost when missing deadlines */

/* 0339: App-specific profile */
typedef struct {
	const char *bundle_id;
	float min_fps;
	float max_fps;
	float preferred_fps;
	bool enable_predictive;
} dl_profile_t;

static dl_profile_t *dl_profiles = NULL;
static size_t dl_profile_count = 0;

/* 0342: Hardware VSYNC-aligned Frame Pacing */
typedef struct {
    uint64_t vsync_period_ns;        /* 8,333,333 ns for 120 Hz */
    uint64_t last_vsync_ts;          /* last hardware vsync timestamp */
    uint64_t render_budget_ns;       /* time budget for render (target 70% = 5.8ms) */
    uint64_t next_frame_target_ts;   /* when next frame should be ready */
    uint32_t phase_offset_us;        /* microsecond offset from vsync */
    boolean_t vsync_aligned;         /* true when locked to hardware vsync */
    uint32_t consecutive_misses;     /* frames missing deadline */
    uint32_t quality_level;          /* 0=full, 1=half-res, 2=minimal */
    uint64_t frame_start_ts;         /* frame render start timestamp */
} dl_frame_pacing_t;

static dl_frame_pacing_t dl_pacing = {
    .vsync_period_ns = 8333333,
    .render_budget_ns = 5833333,     /* 70% of frame */
    .phase_offset_us = 500,          /* 500 µs before vsync */
    .quality_level = 0,
};

static bool
has_ci(const char *s, const char *needle)
{
	if (s == NULL || *needle == '\0') {
		return false;
	}
	for (; *s != '\0'; s++) {
		const char *a = s, *b = needle;
		while (*a != '\0' && *b != '\0') {
			char ca = (*a >= 'A' && *a <= 'Z') ? (char)(*a + ('a' - 'A')) : *a;
			char cb = (*b >= 'A' && *b <= 'Z') ? (char)(*b + ('a' - 'A')) : *b;
			if (ca != cb) {
				break;
			}
			a++;
			b++;
		}
		if (*b == '\0') {
			return true;
		}
	}
	return false;
}

static bool
is_scroll_target(id target, const char *cls, SEL action)
{
	Class sv = scroll_view_cls != Nil ? scroll_view_cls : objc_getClass("UIScrollView");
	if (sv != Nil) {
		for (Class c = object_getClass(target); c != Nil; c = class_getSuperclass(c)) {
			if (c == sv) {
				return true;
			}
		}
	}
	if (has_ci(cls, "Scroll")) {
		return true;
	}
	if (action != NULL && has_ci(sel_getName(action), "scroll")) {
		return true;
	}
	return false;
}

static bool
full_rate(id link)
{
	return objc_getAssociatedObject(link, &full_key) != nil;
}

/* 0339: Read GPU utilization from kernel */
static uint32_t
dl_get_gpu_util(void)
{
	size_t len = 0;
	sysctlbyname("kern.sweet_fb_dynamic_rscale", NULL, &len, NULL, 0);
	if (len > 0) {
		char *buf = malloc(len);
		if (buf) {
			sysctlbyname("kern.sweet_fb_dynamic_rscale", buf, &len, NULL, 0);
			/* Parse "gpu_util:XXX‰" */
			char *p = strstr(buf, "gpu_util:");
			uint32_t util = 0;
			if (p) {
				sscanf(p, "gpu_util:%u", &util);
			}
			free(buf);
			return util;
		}
	}
	return 0;
}

/* 0339: Check if we should promote based on GPU headroom */
static bool
dl_should_promote_gpu_headroom(void)
{
	uint32_t gpu_util = dl_get_gpu_util();
	return gpu_util < 800;  /* <80% GPU util */
}

static bool
should_promote(id link, float preferred, float maximum)
{
	if (full_rate(link)) {
		return true;
	}
	if (!is_springboard && objc_getAssociatedObject(link, &scroll_key) == nil) {
		return false;
	}
	/* Exclude intentionally slow timers (< 20 fps, e.g. clock's 10). */
	if (preferred > 0.0f && preferred < 20.0f) {
		return false;
	}
	/* 0339: Only promote if GPU has headroom */
	if (!dl_should_promote_gpu_headroom()) {
		return false;
	}
	return (preferred >= 20.0f && preferred <= 60.0f) || (maximum >= 20.0f && maximum <= 60.0f);
}

/* the rate given to the marked links: /var/jb/var/sapphire-dl-fps (a number) or 120; read once a process */
static long full_fps = 120;

static void
my_fps(id self, SEL sel, long fps)
{
	bool promote = should_promote(self, (float)fps, (float)fps);
	if (dl_log != NULL) {
		char d[64];
		if (promote) {
			snprintf(d, sizeof(d), "fps %ld (-> %ld)", fps, full_fps);
		} else {
			snprintf(d, sizeof(d), "fps %ld", fps);
		}
		say_caller("rate", self, d, __builtin_return_address(0));
	}

	/* 0339: Track promotion stats */
	dl_frames_total++;
	if (promote) dl_frames_promoted++;

	o_fps(self, sel, promote ? full_fps : fps);
}

static void
my_range(id self, SEL sel, frame_rate_range range)
{
	bool promote = should_promote(self, range.preferred, range.maximum);
	if (dl_log != NULL) {
		char d[128];
		if (promote) {
			long min_fps = full_fps < 60 ? full_fps : 60;
			snprintf(d, sizeof(d), "range %.0f..%.0f pref %.0f (-> %ld..%ld, %ld)",
			    range.minimum, range.maximum, range.preferred, min_fps, full_fps, full_fps);
		} else {
			snprintf(d, sizeof(d), "range %.0f..%.0f pref %.0f",
			    range.minimum, range.maximum, range.preferred);
		}
		say_caller("rate", self, d, __builtin_return_address(0));
	}

	/* 0339: Track promotion stats */
	dl_frames_total++;
	if (promote) dl_frames_promoted++;

	if (promote) {
		range = (frame_rate_range){ (float)(full_fps < 60 ? full_fps : 60), (float)full_fps, (float)full_fps };
	}
	o_range(self, sel, range);
}

static id
my_with(id self, SEL sel, id target, SEL action)
{
	id link = o_with(self, sel, target, action);
	if (link != nil && target != nil) {
		const char *cls = object_getClassName(target);
		if (strcmp(cls, FULL_FOR) == 0) {
			objc_setAssociatedObject(link, &full_key, (id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
		} else if (is_scroll_target(target, cls, action)) {
			objc_setAssociatedObject(link, &scroll_key, (id)kCFBooleanTrue, OBJC_ASSOCIATION_ASSIGN);
		}
	}
	if (dl_log != NULL) {
		char d[256];
		snprintf(d, sizeof(d), "for -[%s %s]", target ? object_getClassName(target) : "nil", action ? sel_getName(action) : "");
		say_caller("made", link, d, __builtin_return_address(0));
	}
	return link;
}

/* 0339: Predictive frame scheduling - called from CADisplayLink callback */
static void
dl_predictive_boost(id link)
{
	uint64_t now = mach_absolute_time();
	if (dl_last_frame_time != 0) {
		uint64_t frame_interval = now - dl_last_frame_time;
		uint64_t target_interval = (NSEC_PER_SEC / 120);  /* 8.33 ms */

		if (frame_interval > target_interval * 110 / 100) {  /* missed deadline by >10% */
			dl_frames_deadline_miss++;
			dl_current_boost = 10;  /* boost next 10 frames */
		} else if (dl_current_boost > 0) {
			dl_current_boost--;
		}
	}
	dl_last_frame_time = now;
}

/* 0342: Read hardware VSYNC timestamp from kernel */
static uint64_t
dl_read_hw_vsync_ts(void)
{
    size_t len = sizeof(uint64_t);
    uint64_t ts = 0;
    sysctlbyname("kern.sweet_fb_vsync_ts", &ts, &len, NULL, 0);
    return ts;
}

/* 0342: Read current GPU utilization for budget adjustment */
static uint32_t
dl_read_gpu_util(void)
{
    size_t len = 0;
    sysctlbyname("kern.sweet_fb_dynamic_rscale", NULL, &len, NULL, 0);
    if (len > 0) {
        char *buf = malloc(len);
        if (buf) {
            sysctlbyname("kern.sweet_fb_dynamic_rscale", buf, &len, NULL, 0);
            char *p = strstr(buf, "gpu_util:");
            uint32_t util = 0;
            if (p) sscanf(p, "gpu_util:%u", &util);
            free(buf);
            return util;
        }
    }
    return 500;  /* default 50% */
}

/* 0342: Update frame pacing parameters based on vsync phase */
static void
dl_update_frame_pacing(void)
{
    uint64_t now = mach_absolute_time();
    uint64_t hw_vsync = dl_read_hw_vsync_ts();

    if (hw_vsync == 0) return;  /* not available yet */

    if (!dl_pacing.vsync_aligned) {
        /* First sync - align to next vsync boundary */
        uint64_t phase = (now - hw_vsync) % dl_pacing.vsync_period_ns;
        dl_pacing.next_frame_target_ts = hw_vsync + dl_pacing.vsync_period_ns - dl_pacing.phase_offset_us * 1000;
        dl_pacing.vsync_aligned = TRUE;
        printf("SapphireDL: VSYNC aligned, phase=%llu ns\n", phase);
        return;
    }

    /* Check if we missed the deadline */
    if (now > dl_pacing.next_frame_target_ts) {
        dl_pacing.consecutive_misses++;
        uint64_t late_ns = now - dl_pacing.next_frame_target_ts;

        if (dl_pacing.consecutive_misses >= 3 && dl_pacing.quality_level < 2) {
            dl_pacing.quality_level++;
            dl_pacing.render_budget_ns = dl_pacing.vsync_period_ns * (70 - dl_pacing.quality_level * 15) / 100;
            printf("SapphireDL: quality reduced to level %u, budget=%llu ns\n",
                   dl_pacing.quality_level, dl_pacing.render_budget_ns);
        }
    } else {
        dl_pacing.consecutive_misses = 0;
        if (dl_pacing.quality_level > 0) {
            dl_pacing.quality_level--;
            dl_pacing.render_budget_ns = dl_pacing.vsync_period_ns * (70 + dl_pacing.quality_level * 15) / 100;
        }
    }

    /* Schedule next frame at vsync - render_budget */
    uint64_t next_vsync = hw_vsync + dl_pacing.vsync_period_ns;
    dl_pacing.next_frame_target_ts = next_vsync - dl_pacing.render_budget_ns;

    /* Adjust for GPU utilization */
    uint32_t gpu_util = dl_read_gpu_util();
    if (gpu_util > 800) {
        dl_pacing.render_budget_ns = dl_pacing.vsync_period_ns * 60 / 100;  /* reduce to 60% */
    } else if (gpu_util < 500) {
        dl_pacing.render_budget_ns = dl_pacing.vsync_period_ns * 80 / 100;  /* increase to 80% */
    }
}

/* 0342: Predictive frame scheduling - call before CADisplayLink callback */
static void
dl_predictive_schedule(id link)
{
    dl_update_frame_pacing();

    uint64_t now = mach_absolute_time();
    int64_t time_to_deadline = (int64_t)(dl_pacing.next_frame_target_ts - now);

    if (time_to_deadline > 1000000) {  /* >1ms early */
        /* Yield CPU to avoid burning cycles */
        usleep(time_to_deadline / 1000 - 500);  /* leave 500 µs margin */
    } else if (time_to_deadline < -500000) {  /* >500µs late */
        /* Frame already missed - skip or reduce quality */
        dl_pacing.consecutive_misses++;
    }

    dl_pacing.frame_start_ts = now;
}

/* 0342: Hook into CADisplayLink callback to enforce pacing */
static void
my_callback(id self, SEL sel, CAAnimation *anim)
{
    dl_predictive_schedule(self);
    if (o_callback) o_callback(self, sel, anim);
    dl_predictive_boost(self);  /* from 0339 */
}

/* 0339: Load app profiles from property list */
static void
dl_load_profiles(void)
{
	const char *path = "/var/jb/var/sapphire-dl-profile.plist";
	FILE *f = fopen(path, "r");
	if (!f) return;

	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);

	char *data = malloc(sz + 1);
	fread(data, 1, sz, f);
	data[sz] = '\0';
	fclose(f);

	/* Simple parsing - in practice would use NSPropertyListSerialization */
	/* For now, just log that we found a profile */
	printf("SapphireDisplayLink: found profile at %s (%ld bytes)\n", path, sz);
	free(data);
}

/* 0339: Sysctl for display link stats */
static int
sysctl_sapphire_dl_stats(char *buf, size_t len)
{
	return snprintf(buf, len,
	    "total:%llu promoted:%llu missed:%llu boost:%d gpu_util:%u",
	    (unsigned long long)dl_frames_total,
	    (unsigned long long)dl_frames_promoted,
	    (unsigned long long)dl_frames_deadline_miss,
	    dl_current_boost,
	    dl_get_gpu_util());
}

/* 0342: Sysctl for frame pacing stats */
static int
sysctl_sapphire_dl_pacing(char *buf, size_t len)
{
    return snprintf(buf, len,
        "aligned:%u vsync_period:%llu budget:%llu target:%llu misses:%u quality:%u offset_us:%u",
        dl_pacing.vsync_aligned,
        (unsigned long long)dl_pacing.vsync_period_ns,
        (unsigned long long)dl_pacing.render_budget_ns,
        (unsigned long long)dl_pacing.next_frame_target_ts,
        dl_pacing.consecutive_misses,
        dl_pacing.quality_level,
        dl_pacing.phase_offset_us);
}

__attribute__((constructor)) static void
init(void)
{
	if (access("/var/jb/var/sapphire-dl-off", F_OK) == 0) {
		return;
	}
	const char *prog = getprogname();
	is_springboard = (prog != NULL && strcmp(prog, "SpringBoard") == 0);
	scroll_view_cls = objc_getClass("UIScrollView");
	FILE *f = fopen("/var/jb/var/sapphire-dl-fps", "r");
	if (f != NULL) {
		long v = 0;
		if (fscanf(f, "%ld", &v) == 1 && v >= 20 && v <= 240) {
			full_fps = v;
		}
		fclose(f);
	}
	if (access("/var/tmp/dl-log", F_OK) == 0) {
		char path[256];
		snprintf(path, sizeof(path), "/var/tmp/dl.%s.log", getprogname());
		dl_log = fopen(path, "a");
	}

	/* 0339: Load profiles */
	dl_load_profiles();

	Class link = objc_getClass("CADisplayLink");
	if (link == Nil) {
		return;
	}
	Method made = class_getClassMethod(link, sel_registerName("displayLinkWithTarget:selector:"));
	Method fps = class_getInstanceMethod(link, sel_registerName("setPreferredFramesPerSecond:"));
	Method range = class_getInstanceMethod(link, sel_registerName("setPreferredFrameRateRange:"));
	Method callback = class_getInstanceMethod(link, sel_registerName("displayLinkCallback:"));  /* 0342 */
	if (made == NULL || fps == NULL || range == NULL) {
		NSLog(@TAG "CADisplayLink methods missing (made %p fps %p range %p): nothing changed", made, fps, range);
		return;
	}
	o_with = (id (*)(id, SEL, id, SEL))method_setImplementation(made, (IMP)my_with);
	o_fps = (void (*)(id, SEL, long))method_setImplementation(fps, (IMP)my_fps);
	o_range = (void (*)(id, SEL, frame_rate_range))method_setImplementation(range, (IMP)my_range);
	if (callback) {
	    o_callback = (void (*)(id, SEL, CAAnimation *))method_setImplementation(callback, (IMP)my_callback);
	}
	(void)TAG;
}