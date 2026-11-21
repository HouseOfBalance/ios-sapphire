/*
 * bkstart: com.apple.backboardd launchd wrapper on sapphire.
 * launchd strips DYLD_* environment variables for system daemons, so bkstart sets
 * DYLD_INSERT_LIBRARIES=/redwood/lib/SapphireBrightness.dylib (unless disabled by
 * /var/tmp/no-brightness-bridge) and execv()s the real /usr/libexec/backboardd
 * with the same PID and Mach services.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define BACKBOARDD "/usr/libexec/backboardd"
#define BL_DYLIB   "/redwood/lib/SapphireBrightness.dylib"
#define BL_DISABLE "/var/tmp/no-brightness-bridge"

int
main(int argc, char **argv)
{
	(void)argc;
	if (access(BL_DISABLE, F_OK) != 0 && access(BL_DYLIB, R_OK) == 0) {
		setenv("DYLD_INSERT_LIBRARIES", BL_DYLIB, 1);
	}
	argv[0] = BACKBOARDD;
	execv(BACKBOARDD, argv);
	perror("bkstart: exec backboardd");
	return 1;
}
