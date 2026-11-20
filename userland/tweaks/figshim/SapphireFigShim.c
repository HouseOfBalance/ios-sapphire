/*
 * SapphireFigShim.dylib — injected into /usr/sbin/mediaserverd (CMCapture.framework).
 * Phase 1: probes and logs exact CMCapture / BWFigVideoCaptureDevice / BWFigVideoCaptureStream
 * runtime classes & methods into /var/tmp/figshim.log and hooks BWFigVideoCaptureStream start/stop
 * safely to bridge camd's zero-copy IOSurface frames into Apple's mediaserverd pipeline.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
fig_log(const char *msg)
{
	FILE *f = fopen("/var/tmp/figshim.log", "a");
	if (f) {
		fprintf(f, "%s\n", msg);
		fclose(f);
	}
}

static void
dump_class_methods(const char *clsName)
{
	Class c = objc_getClass(clsName);
	char buf[256];
	if (c == Nil) {
		snprintf(buf, sizeof(buf), "[figshim] class %s: NOT FOUND", clsName);
		fig_log(buf);
		return;
	}
	unsigned int cnt = 0;
	Method *ms = class_copyMethodList(c, &cnt);
	snprintf(buf, sizeof(buf), "[figshim] class %s: FOUND (%u methods)", clsName, cnt);
	fig_log(buf);
	for (unsigned int i = 0; i < cnt && i < 40; i++) {
		const char *sname = sel_getName(method_getName(ms[i]));
		if (sname && (strstr(sname, "start") || strstr(sname, "stop") || strstr(sname, "Property") ||
		    strstr(sname, "Sample") || strstr(sname, "Buffer") || strstr(sname, "Stream") ||
		    strstr(sname, "Source") || strstr(sname, "init") || strstr(sname, "Device"))) {
			snprintf(buf, sizeof(buf), "  - %s", sname);
			fig_log(buf);
		}
	}
	if (ms) free(ms);
}

__attribute__((constructor)) static void
figshim_init(void)
{
	fig_log("[figshim] loaded in mediaserverd");
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
	    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		dump_class_methods("BWFigVideoCaptureDevice");
		dump_class_methods("BWFigVideoCaptureStream");
		dump_class_methods("BWFigCaptureDevice");
		dump_class_methods("BWFigCaptureStream");
		dump_class_methods("BWFigCaptureDeviceClient");
		dump_class_methods("FigCaptureSourceCompanionFormat");
		dump_class_methods("BWStillImageCoordinatorNode");
		dump_class_methods("BWMovieFileSinkNode");

		void *sym1 = dlsym(RTLD_DEFAULT, "FigCaptureSourceRemoteCopyCaptureSources");
		void *sym2 = dlsym(RTLD_DEFAULT, "FigCaptureSourceCreate");
		void *sym3 = dlsym(RTLD_DEFAULT, "FigCaptureServerStart");
		char buf[256];
		snprintf(buf, sizeof(buf), "[figshim] syms: RemoteCopy=%p SourceCreate=%p ServerStart=%p",
		    sym1, sym2, sym3);
		fig_log(buf);
	});
}
