/*
 * btmonitor.c: Monitor btshim control socket for HCI events and post Darwin notifications
 *
 * This replaces the bash script that used socat (not available on iOS).
 * Uses kqueue/kevent for efficient event-driven monitoring of the Unix control socket.
 *
 * Build: clang -target arm64-apple-ios15.0 -isysroot $SDK -o btmonitor btmonitor.c
 *        ldid -S btmonitor
 *
 * The btshim daemon (btshim.c) creates a control socket at /var/run/btshim/ctl
 * and sends newline-terminated events like:
 *   ACL_CONNECTED <addr>
 *   ACL_DISCONNECTED <addr>
 *   A2DP_CONNECTED
 *   A2DP_DISCONNECTED
 *
 * We monitor this socket and post com.sapphire.audio.route-change notification
 * which the RedwoodAudio.driver uses to trigger route changes.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/event.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <notify.h>
#include <signal.h>

#define BT_CTL_PATH "/var/run/btshim/ctl"
#define AUDIO_NOTIFY "com.sapphire.audio.route-change"
#define BUF_SIZE 4096

static volatile sig_atomic_t running = 1;

static void
handle_signal(int sig)
{
    (void)sig;
    running = 0;
}

static int
connect_btshim(void)
{
    struct sockaddr_un addr;
    int fd;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, BT_CTL_PATH, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(fd);
        return -1;
    }

    /* Set non-blocking */
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    /* Send "stream" command to enter streaming mode */
    const char *stream_cmd = "stream\n";
    if (write(fd, stream_cmd, strlen(stream_cmd)) < 0) {
        perror("write stream command");
        close(fd);
        return -1;
    }

    /* Read the confirmation response */
    char response[32];
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ssize_t n = read(fd, response, sizeof(response) - 1);
    if (n <= 0 || response[0] != '0') {
        fprintf(stderr, "btmonitor: Failed to enter streaming mode\n");
        close(fd);
        return -1;
    }

    return fd;
}

static void
post_notification(void)
{
    int err = notify_post(AUDIO_NOTIFY);
    if (err != 0) {
        fprintf(stderr, "btmonitor: notify_post failed: %d\n", err);
    }
}

static void
process_line(const char *line)
{
    if (strncmp(line, "ACL_CONNECTED ", 14) == 0) {
        fprintf(stderr, "btmonitor: ACL connected %s\n", line + 14);
        post_notification();
    } else if (strncmp(line, "ACL_DISCONNECTED ", 17) == 0) {
        fprintf(stderr, "btmonitor: ACL disconnected %s\n", line + 17);
        post_notification();
    } else if (strcmp(line, "A2DP_CONNECTED") == 0) {
        fprintf(stderr, "btmonitor: A2DP connected\n");
        post_notification();
    } else if (strcmp(line, "A2DP_DISCONNECTED") == 0) {
        fprintf(stderr, "btmonitor: A2DP disconnected\n");
        post_notification();
    }
}

static void
monitor_loop(int sock)
{
    int kq = kqueue();
    if (kq < 0) {
        perror("kqueue");
        return;
    }

    struct kevent kev;
    EV_SET(&kev, sock, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        perror("kevent register");
        close(kq);
        return;
    }

    char buf[BUF_SIZE];
    size_t buf_len = 0;

    while (running) {
        struct kevent events[1];
        struct timespec timeout = { .tv_sec = 1, .tv_nsec = 0 };
        int nev = kevent(kq, NULL, 0, events, 1, &timeout);

        if (nev < 0) {
            if (errno == EINTR) continue;
            perror("kevent");
            break;
        }

        if (nev == 0) {
            /* Timeout - check if socket still exists */
            continue;
        }

        if (events[0].filter == EVFILT_READ) {
            ssize_t n = read(sock, buf + buf_len, BUF_SIZE - buf_len - 1);
            if (n <= 0) {
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    continue;
                }
                /* Connection closed or error */
                fprintf(stderr, "btmonitor: socket closed, attempting reconnect\n");
                break;
            }

            buf_len += n;
            buf[buf_len] = '\0';

            /* Process complete lines */
            char *line_start = buf;
            char *newline;
            while ((newline = strchr(line_start, '\n')) != NULL) {
                *newline = '\0';
                if (newline > line_start && *(newline - 1) == '\r') {
                    *(newline - 1) = '\0';
                }
                process_line(line_start);
                line_start = newline + 1;
            }

            /* Move remaining partial line to start of buffer */
            if (line_start != buf) {
                buf_len = strlen(line_start);
                memmove(buf, line_start, buf_len + 1);
            }
        }
    }

    close(kq);
}

static int
wait_for_socket(void)
{
    struct kevent kev;
    int kq = kqueue();
    if (kq < 0) return -1;

    int dir_fd = open("/var/run/btshim", O_RDONLY | O_DIRECTORY);
    if (dir_fd < 0) {
        close(kq);
        return -1;
    }

    EV_SET(&kev, dir_fd, EVFILT_VNODE, EV_ADD | EV_ENABLE, NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB, 0, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        close(dir_fd);
        close(kq);
        return -1;
    }

    /* Wait up to 30 seconds for socket to appear */
    struct timespec timeout = { .tv_sec = 30, .tv_nsec = 0 };
    int nev = kevent(kq, NULL, 0, &kev, 1, &timeout);

    close(dir_fd);
    close(kq);

    return (nev > 0) ? 0 : -1;
}

int
main(void)
{
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);

    fprintf(stderr, "btmonitor: Starting Bluetooth HCI event monitor\n");

    /* Wait for btshim control socket to appear */
    if (access(BT_CTL_PATH, F_OK) != 0) {
        fprintf(stderr, "btmonitor: Waiting for %s to appear...\n", BT_CTL_PATH);
        if (wait_for_socket() != 0) {
            fprintf(stderr, "btmonitor: Timeout waiting for btshim socket\n");
            return 1;
        }
    }

    fprintf(stderr, "btmonitor: Found btshim socket, connecting...\n");

    while (running) {
        int sock = connect_btshim();
        if (sock < 0) {
            sleep(5);
            continue;
        }

        fprintf(stderr, "btmonitor: Connected to btshim control socket\n");
        monitor_loop(sock);
        close(sock);

        if (!running) break;
        fprintf(stderr, "btmonitor: Disconnected, reconnecting in 5s...\n");
        sleep(5);
    }

    fprintf(stderr, "btmonitor: Shutting down\n");
    return 0;
}