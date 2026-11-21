/*
 * SapphireBrightness.dylib: standalone BrightnessSystem + BKDisplayBrightnessController
 * + CBCAManager bridge for backboardd when running with sweetmetal=2 (HakiosMetal.bundle),
 * where libredwood-gl.dylib is no longer loaded into backboardd.
 *
 * Bridges iOS Control Center and Settings brightness sliders directly to AppleCLCD's
 * IOMFBBrightnessLevel property (5..500 nits in 16.16 fixed-point -> kernel DCS 0x51
 * enabled by xnu patch 0361 kern.sweet_bl_dcs=1), and disables CoreBrightness digital
 * dimming so the panel is driven cleanly in hardware.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BRIGHTNESS_MAX_NITS 500.0
#define BRIGHTNESS_MIN_NITS 5.0

extern kern_return_t sb_set_property(io_registry_entry_t, CFStringRef, CFTypeRef)
    __asm__("_IORegistryEntrySetCFProperty");

static bool (*orig_set_property)(id, SEL, id, id);
static id (*orig_copy_property)(id, SEL, id);
static void (*orig_digital_dimming)(id, SEL, float);

static float current_level = -1.0f;
static uint64_t last_panel_ns = 0;
static int installed_brightness = 0;
static int installed_cbca = 0;
static int installed_bk = 0;

static void
sb_log(const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n <= 0) {
		return;
	}
	FILE *f = fopen("/var/tmp/sapphire-brightness.log", "a");
	if (f != NULL) {
		fwrite(buf, 1, (size_t)n, f);
		fclose(f);
	}
}

static uint64_t
now_ns(void)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return mach_absolute_time() * tb.numer / tb.denom;
}

static void
brightness_to_panel(float level, bool force)
{
	uint64_t t = now_ns();
	if (!force && last_panel_ns != 0 && (t - last_panel_ns) < 25000000ULL) {
		return;
	}
	last_panel_ns = t;

	io_service_t fb = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLCD"));
	if (fb == 0) {
		return;
	}
	double nits = BRIGHTNESS_MIN_NITS + (BRIGHTNESS_MAX_NITS - BRIGHTNESS_MIN_NITS) * (double)level * (double)level;
	long long fixed = (long long)(nits * 65536.0);
	CFNumberRef value = CFNumberCreate(NULL, kCFNumberLongLongType, &fixed);
	if (value != NULL) {
		sb_set_property(fb, CFSTR("IOMFBBrightnessLevel"), value);
		CFRelease(value);
	}
	IOObjectRelease(fb);
}

static bool
is_brightness_key(id key)
{
	return key != NULL && CFGetTypeID((CFTypeRef)key) == CFStringGetTypeID() &&
	    CFStringCompare((CFStringRef)key, CFSTR("DisplayBrightness"), 0) == kCFCompareEqualTo;
}

static bool
hook_set_property(id self, SEL sel, id value, id key)
{
	if (is_brightness_key(key) && value != NULL) {
		CFTypeRef number = (CFTypeRef)value;
		bool committed = true;
		int flag = 1;
		float level = 0.0f;

		if (CFGetTypeID((CFTypeRef)value) == CFDictionaryGetTypeID()) {
			number = CFDictionaryGetValue((CFDictionaryRef)value, CFSTR("Brightness"));
			CFTypeRef commit = CFDictionaryGetValue((CFDictionaryRef)value, CFSTR("Commit"));
			if (commit != NULL && CFGetTypeID(commit) == CFNumberGetTypeID() &&
			    CFNumberGetValue((CFNumberRef)commit, kCFNumberIntType, &flag)) {
				committed = (flag != 0);
			}
		}
		if (number != NULL && CFGetTypeID(number) == CFNumberGetTypeID() &&
		    CFNumberGetValue((CFNumberRef)number, kCFNumberFloatType, &level)) {
			if (level < 0.0f) level = 0.0f;
			if (level > 1.0f) level = 1.0f;
			current_level = level;
			brightness_to_panel(level, committed);
			if (committed) {
				CFNumberRef kept = CFNumberCreate(NULL, kCFNumberFloatType, &level);
				if (kept != NULL) {
					CFPreferencesSetAppValue(CFSTR("level"), kept, CFSTR("com.sapphire.brightness"));
					CFPreferencesAppSynchronize(CFSTR("com.sapphire.brightness"));
					CFRelease(kept);
				}
			}
		}
	}
	return orig_set_property ? orig_set_property(self, sel, value, key) : true;
}

static id
hook_copy_property(id self, SEL sel, id key)
{
	if (is_brightness_key(key) && current_level >= 0.0f) {
		float level = current_level;
		return (id)CFNumberCreate(NULL, kCFNumberFloatType, &level);
	}
	return orig_copy_property ? orig_copy_property(self, sel, key) : nil;
}

static bool
hook_brightness_available(id self, SEL sel)
{
	(void)self;
	(void)sel;
	return true;
}

static void
hook_digital_dimming(id self, SEL sel, float scaler)
{
	(void)scaler;
	if (orig_digital_dimming != NULL) {
		orig_digital_dimming(self, sel, 1.0f);
	}
}

static void
try_install(const char *reason)
{
	if (!installed_bk) {
		Class controller = objc_getClass("BKDisplayBrightnessController");
		if (controller != Nil) {
			Method avail = class_getInstanceMethod(controller, sel_registerName("isBrightnessLevelControlAvailable"));
			if (avail != NULL) {
				method_setImplementation(avail, (IMP)hook_brightness_available);
				installed_bk = 1;
				sb_log("SapphireBrightness: hooked BKDisplayBrightnessController (%s)\n", reason);
			}
		}
	}

	if (!installed_brightness) {
		Class system = objc_getClass("BrightnessSystem");
		if (system != Nil) {
			Method set = class_getInstanceMethod(system, sel_registerName("setProperty:forKey:"));
			Method copy = class_getInstanceMethod(system, sel_registerName("copyPropertyForKey:"));
			if (set != NULL && copy != NULL) {
				orig_set_property = (bool (*)(id, SEL, id, id))method_setImplementation(set, (IMP)hook_set_property);
				orig_copy_property = (id (*)(id, SEL, id))method_setImplementation(copy, (IMP)hook_copy_property);
				installed_brightness = 1;

				CFPropertyListRef kept = CFPreferencesCopyAppValue(CFSTR("level"), CFSTR("com.sapphire.brightness"));
				if (kept != NULL && CFGetTypeID(kept) == CFNumberGetTypeID()) {
					float level = 0.5f;
					CFNumberGetValue((CFNumberRef)kept, kCFNumberFloatType, &level);
					if (level < 0.0f) level = 0.0f;
					if (level > 1.0f) level = 1.0f;
					current_level = level;
					brightness_to_panel(current_level, true);
				}
				if (kept != NULL) {
					CFRelease(kept);
				}
				sb_log("SapphireBrightness: hooked BrightnessSystem (%s, level=%g)\n", reason, (double)current_level);
			}
		}
	}

	if (!installed_cbca) {
		Class manager = objc_getClass("CBCAManager");
		if (manager != Nil) {
			Method m = class_getInstanceMethod(manager, sel_registerName("updateDigitalDimmingBrightnessScaler:"));
			if (m != NULL) {
				orig_digital_dimming = (void (*)(id, SEL, float))method_setImplementation(m, (IMP)hook_digital_dimming);
				installed_cbca = 1;
				sb_log("SapphireBrightness: disabled CBCAManager digital dimming (%s)\n", reason);
			}
		}
	}
}

static void
on_image_added(const struct mach_header *header, intptr_t slide)
{
	(void)slide;
	if (installed_brightness && installed_cbca && installed_bk) {
		return;
	}
	Dl_info info;
	if (dladdr(header, &info) != 0 && info.dli_fname != NULL &&
	    (strstr(info.dli_fname, "CoreBrightness") != NULL || strstr(info.dli_fname, "BackBoard") != NULL)) {
		dispatch_async(dispatch_get_main_queue(), ^{
			try_install("add_image");
		});
	}
}

__attribute__((constructor)) static void
sapphire_brightness_init(void)
{
	unsetenv("DYLD_INSERT_LIBRARIES");
	if (strcmp(getprogname(), "backboardd") != 0) {
		return;
	}
	sb_log("SapphireBrightness: loaded in backboardd (pid %d)\n", (int)getpid());
	try_install("ctor");
	_dyld_register_func_for_add_image(on_image_added);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		try_install("timer-1s");
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		try_install("timer-3s");
	});
}
