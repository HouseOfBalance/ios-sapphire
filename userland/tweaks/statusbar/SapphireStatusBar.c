/*
 * SapphireStatusBar: the iPhone X's status bar for iOS drawn at 2x (xnu 0239/0240, sweetfb_scale=2).
 *
 * UIKit picks a status bar layout by the screen -- +[_UIStatusBarVisualProvider_iOS
 * visualProviderSubclassForScreen:visualProviderInfo:] -- and has one only for real iPhone screens
 * (pixel width, scale, corner radius: _UIStatusBarVisualProvider_Split1125 for the X's 375 points at
 * 3x). The X's 375 x 812 points at 2x is none of them: it logged "No status bar visual provider for
 * screen ... (width: 375.00, scale: 2.00, idiom: 0, cornerRadius: 39.00)" and showed the red
 * "rdar://45025538" placeholder bar. This tweak (ElleKit's TweakLoader brings it into every UIKit
 * process) gives such a screen the X's layout, which is in points.
 */
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef Class (*subclass_fn)(id, SEL, id, id);
static subclass_fn original;
static Class status_bar_split;

static Class
subclass_for_screen(id self, SEL selector, id screen, id info)
{
	Class chosen = original(self, selector, screen, info);
	const char *name = chosen != Nil ? class_getName(chosen) : NULL;

	if (chosen == Nil || (name != NULL && strstr(name, "Fallback") != NULL)) {
		Class x = status_bar_split != Nil ? status_bar_split : objc_getClass("_UIStatusBarVisualProvider_Split1125");
		if (x != Nil) {
			return x;
		}
	}
	return chosen;
}

static id
status_bar_fallback_alloc(id self __attribute__((unused)), SEL selector)
{
	return ((id (*)(Class, SEL))objc_msgSend)(status_bar_split, selector);
}

static id
status_bar_fallback_alloc_zone(id self __attribute__((unused)), SEL selector, void *zone)
{
	return ((id (*)(Class, SEL, void *))objc_msgSend)(status_bar_split, selector, zone);
}

/*
 * HakiOS 2.3.4: hooking +visualProviderSubclassForScreen:visualProviderInfo: alone still left the
 * fallback provider in some UIKit paths (white band / red rdar://45025538 bar). Replace
 * _UIStatusBarVisualProvider_Fallback's class methods and alloc/allocWithZone: with Split1125.
 */
static void
status_bar_fallback_is_split(void)
{
	Class fallback = objc_getClass("_UIStatusBarVisualProvider_Fallback");
	status_bar_split = objc_getClass("_UIStatusBarVisualProvider_Split1125");
	if (fallback == Nil || status_bar_split == Nil) {
		return;
	}
	Class chain[8];
	unsigned depth = 0;

	for (Class c = status_bar_split; c != Nil && depth < 8; c = class_getSuperclass(c)) {
		bool common = false;
		for (Class f = fallback; f != Nil; f = class_getSuperclass(f)) {
			common = common || f == c;
		}
		if (common) {
			break;
		}
		chain[depth++] = c;
	}
	while (depth-- > 0) {
		unsigned count = 0;
		Method *methods = class_copyMethodList(object_getClass(chain[depth]), &count);
		for (unsigned i = 0; i < count; i++) {
			const char *name = sel_getName(method_getName(methods[i]));
			if (strcmp(name, "load") != 0 && strcmp(name, "initialize") != 0 &&
			    strcmp(name, "alloc") != 0 && strcmp(name, "allocWithZone:") != 0) {
				class_replaceMethod(object_getClass(fallback), method_getName(methods[i]),
				    method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
			}
		}
		free(methods);
	}
	class_replaceMethod(object_getClass(fallback), sel_registerName("alloc"), (IMP)status_bar_fallback_alloc, "@16@0:8");
	class_replaceMethod(object_getClass(fallback), sel_registerName("allocWithZone:"), (IMP)status_bar_fallback_alloc_zone, "@24@0:8^v16");
}

__attribute__((constructor)) static void
install(void)
{
	status_bar_fallback_is_split();
	Class provider = objc_getClass("_UIStatusBarVisualProvider_iOS");
	SEL selector = sel_registerName("visualProviderSubclassForScreen:visualProviderInfo:");
	Method method = provider != Nil ? class_getClassMethod(provider, selector) : NULL;

	if (method != NULL) {
		original = (subclass_fn)method_setImplementation(method, (IMP)subclass_for_screen);
	}
}
