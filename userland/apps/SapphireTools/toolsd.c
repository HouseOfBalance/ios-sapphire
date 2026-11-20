/*
 * toolsd: root helper daemon for SapphireTools.app (launched by launchd as root).
 * Listens on /var/run/sapphire-toolsd.sock (0666) and executes allowlisted
 * privileged operations on behalf of the unprivileged GUI app:
 *   SYSCTL_SET <name> <value>   (only kern.sweet_* and kern.hakios.*)
 *   WRITE_METAL_ARGS <content>  (writes /var/tmp/metal.args atomically)
 *   KILL <proc1> [proc2 ...]    (only allowlisted daemons)
 *   REBOOT
 *   DMESG                       (returns dmesg / sweetlog tail)
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <sys/reboot.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SOCK_PATH "/var/run/sapphire-toolsd.sock"
#define METAL_ARGS_PATH "/var/tmp/metal.args"

static int allowed_sysctl(const char *name) {
    return strncmp(name, "kern.sweet_", 11) == 0 ||
           strncmp(name, "kern.hakios.", 12) == 0;
}

static int allowed_proc(const char *name) {
    static const char *const kAllowed[] = {
        "backboardd", "SpringBoard", "fpd", "btmonitor",
        "vibd", "thermald", "sensord", "mediaserverd",
        "sshd", "dropbear", "sharingd", NULL
    };
    for (int i = 0; kAllowed[i]; i++) {
        if (strcmp(name, kAllowed[i]) == 0) return 1;
    }
    return 0;
}

static void handle_client(int fd) {
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = '\0';

    char resp[512];
    if (strncmp(buf, "PING", 4) == 0) {
        snprintf(resp, sizeof(resp), "OK uid=%d euid=%d\n", (int)getuid(), (int)geteuid());
        write(fd, resp, strlen(resp));
    } else if (strncmp(buf, "SYSCTL_SET ", 11) == 0) {
        char *sp = strchr(buf + 11, ' ');
        if (!sp) {
            write(fd, "ERR EINVAL\n", 11);
            return;
        }
        *sp = '\0';
        const char *name = buf + 11;
        const char *val = sp + 1;
        if (!allowed_sysctl(name)) {
            write(fd, "ERR EPERM\n", 10);
            return;
        }
        long long iv = strtoll(val, NULL, 10);
        int iv32 = (int)iv;
        if (sysctlbyname(name, NULL, NULL, &iv32, sizeof(iv32)) == 0 ||
            sysctlbyname(name, NULL, NULL, &iv, sizeof(iv)) == 0 ||
            sysctlbyname(name, NULL, NULL, (void *)val, strlen(val) + 1) == 0) {
            write(fd, "OK\n", 3);
        } else {
            snprintf(resp, sizeof(resp), "ERR %d %s\n", errno, strerror(errno));
            write(fd, resp, strlen(resp));
        }
    } else if (strncmp(buf, "WRITE_METAL_ARGS\n", 17) == 0) {
        const char *body = buf + 17;
        int tfd = open(METAL_ARGS_PATH ".tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (tfd < 0) {
            snprintf(resp, sizeof(resp), "ERR %d %s\n", errno, strerror(errno));
            write(fd, resp, strlen(resp));
            return;
        }
        size_t blen = strlen(body);
        if (blen > 0) write(tfd, body, blen);
        close(tfd);
        if (rename(METAL_ARGS_PATH ".tmp", METAL_ARGS_PATH) == 0) {
            chmod(METAL_ARGS_PATH, 0644);
            write(fd, "OK\n", 3);
        } else {
            snprintf(resp, sizeof(resp), "ERR %d %s\n", errno, strerror(errno));
            write(fd, resp, strlen(resp));
        }
    } else if (strncmp(buf, "KILL ", 5) == 0) {
        char *p = buf + 5;
        char *tok;
        while ((tok = strsep(&p, " ")) != NULL) {
            if (*tok == '\0') continue;
            if (!allowed_proc(tok)) continue;
            char cmd[128];
            snprintf(cmd, sizeof(cmd), "/usr/bin/killall -9 %s 2>/dev/null || /var/jb/usr/bin/killall -9 %s 2>/dev/null", tok, tok);
            system(cmd);
        }
        write(fd, "OK\n", 3);
    } else if (strcmp(buf, "REBOOT") == 0) {
        write(fd, "OK\n", 3);
        sync();
        reboot(RB_AUTOBOOT);
    } else {
        write(fd, "ERR UNKNOWN\n", 12);
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    unlink(SOCK_PATH);
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv < 0) return 1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path));

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0) return 1;
    chmod(SOCK_PATH, 0666);
    if (listen(srv, 8) != 0) return 1;

    for (;;) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        handle_client(c);
        close(c);
    }
    return 0;
}
