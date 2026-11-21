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
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;
extern int reboot(int howto);
#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT 0
#endif

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
        "CommCenter", "wifid", "bluetoothd", "camd",
        "sshd", "dropbear", "sharingd", NULL
    };
    for (int i = 0; kAllowed[i]; i++) {
        if (strcmp(name, kAllowed[i]) == 0) return 1;
    }
    return 0;
}

static void kill_by_name(const char *target) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0 || sz == 0) return;
    struct kinfo_proc *procs = malloc(sz);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &sz, NULL, 0) == 0) {
        size_t n = sz / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < n; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, target) == 0 ||
                strncmp(procs[i].kp_proc.p_comm, target, strlen(target)) == 0) {
                if (procs[i].kp_proc.p_pid > 1 && procs[i].kp_proc.p_pid != getpid()) {
                    kill(procs[i].kp_proc.p_pid, SIGKILL);
                }
            }
        }
    }
    free(procs);
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
            kill_by_name(tok);
        }
        write(fd, "OK\n", 3);
    } else if (strcmp(buf, "SSH_START") == 0) {
        const char *bins[] = { "/var/jb/usr/sbin/sshd", "/usr/sbin/sshd", "/usr/local/sbin/sshd", NULL };
        int started = 0;
        for (int i = 0; bins[i]; i++) {
            if (access(bins[i], X_OK) != 0) continue;
            pid_t pid = 0;
            char *argv[] = { (char *)bins[i], NULL };
            if (posix_spawn(&pid, bins[i], NULL, NULL, argv, environ) == 0) {
                int st = 0;
                waitpid(pid, &st, 0);
                started = 1;
                break;
            }
        }
        if (started) write(fd, "OK\n", 3);
        else write(fd, "ERR sshd not found\n", 19);
    } else if (strcmp(buf, "SSH_STOP") == 0) {
        kill_by_name("sshd");
        kill_by_name("dropbear");
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
