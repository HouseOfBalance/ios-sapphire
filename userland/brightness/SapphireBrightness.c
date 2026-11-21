/*
 * SapphireBrightness.dylib: standalone BrightnessSystem + BKDisplayBrightnessController
 * + CBCAManager bridge + Auto-Brightness (ALS via sensord) for backboardd on sweetmetal=2.
 *
 * - Bridges Control Center and Settings brightness sliders directly to AppleCLCD's
 *   IOMFBBrightnessLevel property (5..500 nits in 16.16 fixed-point -> kernel DCS 0x51
 *   via xnu patch 0361 kern.sweet_bl_dcs=1).
 * - Disables CoreBrightness digital dimming (CBCAManager scaler forced to 1.0).
 * - Auto-Brightness: listens to Darwin notification "com.sapphire.sensor.lux" (state = lux*100)
 *   posted by sensord (zero polling when screen is off), applies log lux->nits curve with
 *   asymmetric EMA smoothing, +-15% lux hysteresis, and preserves user manual bias in slider space.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <notify.h>
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
#define N_LUX               "com.sapphire.sensor.lux"
#define PREF_DOMAIN         CFSTR("com.sapphire.brightness")

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

/* Auto-brightness state */
static int auto_enabled = 0;
static float auto_bias = 0.0f;
static float last_lux = -1.0f;
static float last_auto_base = -1.0f;
static int lux_notify_token = -1;

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

static float
clampf(float v, float lo, float hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

static float
lux_to_base_level(float lux)
{
	/* Log curve: 0..5 lux -> ~5..15 nits, 300 lux -> ~100 nits, 10000+ lux -> 500 nits */
	if (lux < 0.0f) lux = 0.0f;
	double norm = log10((double)lux + 1.0) / 4.0;
	if (norm < 0.0) norm = 0.0;
	if (norm > 1.0) norm = 1.0;
	double nits = BRIGHTNESS_MIN_NITS + (BRIGHTNESS_MAX_NITS - BRIGHTNESS_MIN_NITS) * pow(norm, 1.85);
	double frac = (nits - BRIGHTNESS_MIN_NITS) / (BRIGHTNESS_MAX_NITS - BRIGHTNESS_MIN_NITS);
	return clampf((float)sqrt(frac < 0.0 ? 0.0 : frac), 0.04f, 1.0f);
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

static void
save_pref_float(CFStringRef key, float val)
{
	CFNumberRef num = CFNumberCreate(NULL, kCFNumberFloatType, &val);
	if (num != NULL) {
		CFPreferencesSetAppValue(key, num, PREF_DOMAIN);
		CFPreferencesAppSynchronize(PREF_DOMAIN);
		CFRelease(num);
	}
}

static void
save_pref_int(CFStringRef key, int val)
{
	CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &val);
	if (num != NULL) {
		CFPreferencesSetAppValue(key, num, PREF_DOMAIN);
		CFPreferencesAppSynchronize(PREF_DOMAIN);
		CFRelease(num);
	}
}

static void
on_lux_update(uint64_t state)
{
	if (!auto_enabled) {
		return;
	}
	float lux = (float)state / 100.0f;
	/* +-15% hysteresis to avoid flicker */
	if (last_lux >= 0.0f && fabsf(lux - last_lux) < 0.15f * (last_lux + 1.0f)) {
		return;
	}
	last_lux = lux;
	float base = lux_to_base_level(lux);
	last_auto_base = base;
	float target = clampf(base + auto_bias, 0.02f, 1.0f);
	if (current_level < 0.0f) {
		current_level = target;
	} else {
		/* Asymmetric EMA: brighten faster than dimming */
		float alpha = (target > current_level) ? 0.35f : 0.15f;
		current_level = clampf(current_level + alpha * (target - current_level), 0.02f, 1.0f);
	}
	brightness_to_panel(current_level, false);
}

static bool
key_equals(id key, CFStringRef target)
{
	return key != NULL && CFGetTypeID((CFTypeRef)key) == CFStringGetTypeID() &&
	    CFStringCompare((CFStringRef)key, target, 0) == kCFCompareEqualTo;
}

static bool
is_brightness_key(id key)
{
	return key_equals(key, CFSTR("DisplayBrightness"));
}

static bool
is_auto_key(id key)
{
	return key_equals(key, CFSTR("DisplayBrightnessAuto")) ||
	    key_equals(key, CFSTR("AutoBrightnessEnable"));
}

static bool
hook_set_property(id self, SEL sel, id value, id key)
{
	if (is_auto_key(key) && value != NULL) {
		int en = 0;
		if (CFGetTypeID((CFTypeRef)value) == CFBooleanGetTypeID()) {
			en = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
		} else if (CFGetTypeID((CFTypeRef)value) == CFNumberGetTypeID()) {
			CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &en);
			en = en != 0 ? 1 : 0;
		}
		if (en != auto_enabled) {
			auto_enabled = en;
			auto_bias = 0.0f;
			last_lux = -1.0f;
			save_pref_int(CFSTR("autoEnabled"), auto_enabled);
			save_pref_float(CFSTR("autoBias"), auto_bias);
			sb_log("SapphireBrightness: auto-brightness %s\n", auto_enabled ? "ON" : "OFF");
			if (auto_enabled && lux_notify_token >= 0) {
				uint64_t st = 0;
				if (notify_get_state(lux_notify_token, &st) == NOTIFY_STATUS_OK && st > 0) {
					on_lux_update(st);
				}
			}
		}
	} else if (is_brightness_key(key) && value != NULL) {
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
			level = clampf(level, 0.0f, 1.0f);
			current_level = level;
			brightness_to_panel(level, committed);
			if (committed) {
				save_pref_float(CFSTR("level"), level);
				if (auto_enabled && last_auto_base >= 0.0f) {
					auto_bias = clampf(level - last_auto_base, -0.35f, 0.35f);
					save_pref_float(CFSTR("autoBias"), auto_bias);
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
	if (is_auto_key(key)) {
		return (id)(auto_enabled ? kCFBooleanTrue : kCFBooleanFalse);
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
load_saved_prefs(void)
{
	CFPropertyListRef kept = CFPreferencesCopyAppValue(CFSTR("level"), PREF_DOMAIN);
	if (kept != NULL && CFGetTypeID(kept) == CFNumberGetTypeID()) {
		float level = 0.5f;
		CFNumberGetValue((CFNumberRef)kept, kCFNumberFloatType, &level);
		current_level = clampf(level, 0.0f, 1.0f);
		brightness_to_panel(current_level, true);
	}
	if (kept != NULL) CFRelease(kept);

	CFPropertyListRef aen = CFPreferencesCopyAppValue(CFSTR("autoEnabled"), PREF_DOMAIN);
	if (aen != NULL && CFGetTypeID(aen) == CFNumberGetTypeID()) {
		CFNumberGetValue((CFNumberRef)aen, kCFNumberIntType, &auto_enabled);
		auto_enabled = auto_enabled != 0 ? 1 : 0;
	}
	if (aen != NULL) CFRelease(aen);

	CFPropertyListRef abias = CFPreferencesCopyAppValue(CFSTR("autoBias"), PREF_DOMAIN);
	if (abias != NULL && CFGetTypeID(abias) == CFNumberGetTypeID()) {
		CFNumberGetValue((CFNumberRef)abias, kCFNumberFloatType, &auto_bias);
		auto_bias = clampf(auto_bias, -0.35f, 0.35f);
	}
	if (abias != NULL) CFRelease(abias);
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
				load_saved_prefs();
				sb_log("SapphireBrightness: hooked BrightnessSystem (%s, level=%g, auto=%d, bias=%g)\n",
				    reason, (double)current_level, auto_enabled, (double)auto_bias);
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
	notify_register_dispatch(N_LUX, &lux_notify_token, dispatch_get_main_queue(), ^(int token) {
		uint64_t state = 0;
		if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) {
			on_lux_update(state);
		}
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		try_install("timer-1s");
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		try_install("timer-3s");
	});
}
