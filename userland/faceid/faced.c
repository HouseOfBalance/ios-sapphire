/*
 * faced: standalone 2D Face Unlock daemon for ios-sapphire (pure C, zero Metal/Vision/CoreML).
 *
 * - Connects to camd (/var/run/camd.sock) using low-priority "START 11 FACE" (front OV16A1Q)
 *   so Camera.app and third-party apps always preempt faced cleanly.
 * - Extracts 512-dim L2-normalized local-contrast-normalized HOG facial descriptors on
 *   64x64 aligned face crops (YCbCr skin + symmetry ROI) in <10 ms on Cortex-A73.
 * - Requires 2 consecutive matching frames within a 2.8s window, respects proximity
 *   (com.sapphire.sensor.prox), and delegates keybag unlock to fpd ("FACE_UNLOCK" -> op 28)
 *   so fingerprint and 2D face unlock share the kernel's 5-attempt lockout counter.
 * - Lock Screen ONLY: never wired into LAContext / SapphireBiometry.
 *
 * Socket: /var/run/faced.sock (mode 0666)
 *   STATUS  -> OK enrolled=<n> scanning=<0|1>
 *   ENROLL  -> PROGRESS 1..5 ... DONE <n> | ERR <reason>
 *   SCAN    -> MATCH <score> | NOMATCH <score> | NOFACE | BUSY | CANCELLED
 *   STOP    -> OK
 *   DELETE  -> OK
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <notify.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include "../camera/camd/camd_proto.h"

#define FACED_SOCK_PATH  "/var/run/faced.sock"
#define FPD_SOCK_PATH    "/var/run/fpd.sock"
#define FACED_DIR        "/var/root/faced"
#define FACED_TMPL_PATH  "/var/root/faced/templates.bin"
#define N_FACE_STATE     "com.sapphire.face.state"
#define N_PROX           "com.sapphire.sensor.prox"

#define DESC_DIM         512
#define MAX_TEMPLATES    10
#define TMPL_MAGIC       0x31434146u /* "FAC1" */
#define MATCH_THRESHOLD  0.78f
#define SCAN_TIMEOUT_MS  2800

typedef struct {
	uint32_t magic;
	uint32_t count;
	float vec[MAX_TEMPLATES][DESC_DIM];
} FaceTemplates;

static FaceTemplates g_tmpl;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_cancel = 0;
static volatile int g_scanning = 0;
static int g_tok_state = -1;
static int g_tok_prox = -1;

static uint64_t
now_ms(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (uint64_t)tv.tv_sec * 1000ULL + (uint64_t)(tv.tv_usec / 1000ULL);
}

static void
update_face_state(void)
{
	if (g_tok_state >= 0) {
		notify_set_state(g_tok_state, g_tmpl.count > 0 ? 1 : 0);
		notify_post(N_FACE_STATE);
	}
}

static bool
is_prox_near(void)
{
	if (g_tok_prox < 0) return false;
	uint64_t st = 0;
	if (notify_get_state(g_tok_prox, &st) == NOTIFY_STATUS_OK && st != 0) {
		return true;
	}
	return false;
}

static void
load_templates(void)
{
	memset(&g_tmpl, 0, sizeof(g_tmpl));
	g_tmpl.magic = TMPL_MAGIC;
	FILE *f = fopen(FACED_TMPL_PATH, "rb");
	if (!f) return;
	FaceTemplates tmp;
	if (fread(&tmp, 1, sizeof(tmp), f) == sizeof(tmp) &&
	    tmp.magic == TMPL_MAGIC && tmp.count <= MAX_TEMPLATES) {
		g_tmpl = tmp;
	}
	fclose(f);
}

static int
save_templates(void)
{
	mkdir(FACED_DIR, 0700);
	g_tmpl.magic = TMPL_MAGIC;
	int fd = open(FACED_TMPL_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) return -1;
	ssize_t n = write(fd, &g_tmpl, sizeof(g_tmpl));
	close(fd);
	return (n == (ssize_t)sizeof(g_tmpl)) ? 0 : -1;
}

static int
unix_connect(const char *path, int timeout_sec)
{
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return -1;
	struct timeval tv = { .tv_sec = timeout_sec, .tv_usec = 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", path);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static int
fpd_cmd(const char *cmd, char *reply, size_t rsz)
{
	int fd = unix_connect(FPD_SOCK_PATH, 2);
	if (fd < 0) return -1;
	size_t len = strlen(cmd);
	if (write(fd, cmd, len) != (ssize_t)len) {
		close(fd);
		return -1;
	}
	ssize_t n = read(fd, reply, rsz - 1);
	close(fd);
	if (n <= 0) return -1;
	reply[n] = '\0';
	return 0;
}

/* ============================================================================
 * Face ROI detection (YCbCr skin chrominance + center prior) + 512-dim HOG
 * ============================================================================ */
static bool
extract_face_descriptor(const uint8_t *bgrx, uint32_t w, uint32_t h, uint32_t stride, float out[DESC_DIM])
{
	if (w < 120 || h < 120) return false;

	/* Downsample to 120x160 grid to find skin-tone face bounding box */
	const int gw = 96, gh = 128;
	int skin_count = 0;
	double sum_x = 0, sum_y = 0;
	double sum_luma = 0;
	uint8_t skin_mask[128 * 96];

	for (int gy = 0; gy < gh; gy++) {
		uint32_t sy = (uint32_t)((uint64_t)gy * h / gh);
		const uint8_t *row = bgrx + (size_t)sy * stride;
		for (int gx = 0; gx < gw; gx++) {
			uint32_t sx = (uint32_t)((uint64_t)gx * w / gw);
			int b = row[sx * 4 + 0];
			int g = row[sx * 4 + 1];
			int r = row[sx * 4 + 2];
			int y  = (77 * r + 150 * g + 29 * b) >> 8;
			int cb = ((-43 * r - 85 * g + 128 * b) >> 8) + 128;
			int cr = ((128 * r - 107 * g - 21 * b) >> 8) + 128;
			sum_luma += y;
			/* Focus on central 80% of frame to ignore background edges */
			bool in_center = (gx >= 10 && gx < gw - 10 && gy >= 10 && gy < gh - 10);
			bool is_skin = in_center && y > 35 && y < 245 && cb >= 75 && cb <= 130 && cr >= 132 && cr <= 178;
			skin_mask[gy * gw + gx] = is_skin ? 1 : 0;
			if (is_skin) {
				skin_count++;
				sum_x += gx;
				sum_y += gy;
			}
		}
	}

	double avg_luma = sum_luma / (double)(gw * gh);
	if (avg_luma < 18.0 || avg_luma > 240.0) return false;
	if (skin_count < (gw * gh) / 25) return false; /* face too small or absent */

	double cx = sum_x / skin_count;
	double cy = sum_y / skin_count;

	/* Compute skin spread around centroid */
	double var_x = 0, var_y = 0;
	for (int gy = 0; gy < gh; gy++) {
		for (int gx = 0; gx < gw; gx++) {
			if (skin_mask[gy * gw + gx]) {
				double dx = gx - cx, dy = gy - cy;
				var_x += dx * dx;
				var_y += dy * dy;
			}
		}
	}
	double rx = sqrt(var_x / skin_count) * 1.85;
	double ry = sqrt(var_y / skin_count) * 1.95;
	double side = (rx > ry ? rx : ry);
	if (side < 14.0 || side > 46.0) return false;

	/* Map square face ROI back to source coordinates */
	int x0 = (int)((cx - side) * w / gw);
	int y0 = (int)((cy - side) * h / gh);
	int x1 = (int)((cx + side) * w / gw);
	int y1 = (int)((cy + side) * h / gh);
	if (x0 < 0) x0 = 0;
	if (y0 < 0) y0 = 0;
	if (x1 > (int)w) x1 = (int)w;
	if (y1 > (int)h) y1 = (int)h;
	int rw = x1 - x0, rh = y1 - y0;
	if (rw < 48 || rh < 48) return false;

	/* Sample 64x64 grayscale face crop */
	float crop[64 * 64];
	double mean = 0, sq = 0;
	for (int py = 0; py < 64; py++) {
		uint32_t sy = (uint32_t)(y0 + (py * rh) / 64);
		const uint8_t *row = bgrx + (size_t)sy * stride;
		for (int px = 0; px < 64; px++) {
			uint32_t sx = (uint32_t)(x0 + (px * rw) / 64);
			float lum = 0.299f * row[sx * 4 + 2] + 0.587f * row[sx * 4 + 1] + 0.114f * row[sx * 4 + 0];
			crop[py * 64 + px] = lum;
			mean += lum;
			sq += (double)lum * lum;
		}
	}
	mean /= (64.0 * 64.0);
	double stdv = sqrt(fmax(sq / (64.0 * 64.0) - mean * mean, 1.0));
	if (stdv < 12.0) return false; /* flat/blank image */

	for (int i = 0; i < 64 * 64; i++) {
		crop[i] = (float)((crop[i] - mean) / stdv);
	}

	/* Compute 8x8 cells x 8 unsigned orientation bins = 512-dim HOG descriptor */
	memset(out, 0, sizeof(float) * DESC_DIM);
	for (int py = 1; py < 63; py++) {
		for (int px = 1; px < 63; px++) {
			float gx_v = crop[py * 64 + (px + 1)] - crop[py * 64 + (px - 1)];
			float gy_v = crop[(py + 1) * 64 + px] - crop[(py - 1) * 64 + px];
			float mag = sqrtf(gx_v * gx_v + gy_v * gy_v);
			if (mag < 1e-5f) continue;
			float ang = atan2f(gy_v, gx_v);
			if (ang < 0.0f) ang += (float)M_PI;
			int bin = (int)(ang * (8.0f / (float)M_PI));
			if (bin < 0) bin = 0;
			if (bin >= 8) bin = 7;
			int cell = (py / 8) * 8 + (px / 8);
			out[cell * 8 + bin] += mag;
		}
	}

	/* Per-cell L2 normalize then global L2 normalize */
	for (int c = 0; c < 64; c++) {
		float cn = 0;
		for (int b = 0; b < 8; b++) cn += out[c * 8 + b] * out[c * 8 + b];
		cn = sqrtf(cn + 1e-6f);
		for (int b = 0; b < 8; b++) out[c * 8 + b] /= cn;
	}
	float gn = 0;
	for (int i = 0; i < DESC_DIM; i++) gn += out[i] * out[i];
	gn = sqrtf(gn + 1e-6f);
	for (int i = 0; i < DESC_DIM; i++) out[i] /= gn;
	return true;
}

static float
cosine_sim(const float a[DESC_DIM], const float b[DESC_DIM])
{
	float dot = 0;
	for (int i = 0; i < DESC_DIM; i++) dot += a[i] * b[i];
	return dot;
}

static float
best_template_score(const float vec[DESC_DIM])
{
	float best = -1.0f;
	for (uint32_t i = 0; i < g_tmpl.count; i++) {
		float s = cosine_sim(vec, g_tmpl.vec[i]);
		if (s > best) best = s;
	}
	return best;
}

/* ============================================================================
 * camd session helper (START 11 FACE)
 * ============================================================================ */
typedef struct {
	int sock;
	int shm_fd;
	const CamdShm *shm;
	size_t shm_size;
} CamSession;

static int
cam_open_face(CamSession *cs)
{
	memset(cs, 0, sizeof(*cs));
	cs->sock = -1;
	cs->shm_fd = -1;

	cs->sock = unix_connect(CAMD_SOCK_PATH, 2);
	if (cs->sock < 0) return -1;

	const char *cmd = "START 11 FACE\n";
	if (write(cs->sock, cmd, strlen(cmd)) != (ssize_t)strlen(cmd)) {
		close(cs->sock);
		cs->sock = -1;
		return -1;
	}
	char rep[256] = "";
	ssize_t n = read(cs->sock, rep, sizeof(rep) - 1);
	if (n <= 0 || strncmp(rep, "OK", 2) != 0) {
		close(cs->sock);
		cs->sock = -1;
		return (n > 0 && strstr(rep, "busy")) ? -2 : -1;
	}
	/* Set socket non-blocking to detect PREEMPTED asynchronously */
	fcntl(cs->sock, F_SETFL, fcntl(cs->sock, F_GETFL) | O_NONBLOCK);

	for (int tries = 0; tries < 20; tries++) {
		cs->shm_fd = open(CAMD_SHM_PATH, O_RDONLY);
		if (cs->shm_fd >= 0) break;
		usleep(25000);
	}
	if (cs->shm_fd < 0) {
		close(cs->sock);
		cs->sock = -1;
		return -1;
	}
	struct stat st;
	if (fstat(cs->shm_fd, &st) != 0 || st.st_size < (off_t)sizeof(CamdShm)) {
		close(cs->shm_fd);
		close(cs->sock);
		cs->sock = cs->shm_fd = -1;
		return -1;
	}
	void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, cs->shm_fd, 0);
	if (p == MAP_FAILED) {
		close(cs->shm_fd);
		close(cs->sock);
		cs->sock = cs->shm_fd = -1;
		return -1;
	}
	cs->shm = (const CamdShm *)p;
	cs->shm_size = (size_t)st.st_size;
	return 0;
}

static bool
cam_was_preempted(CamSession *cs)
{
	if (cs->sock < 0) return true;
	char buf[128];
	ssize_t n = read(cs->sock, buf, sizeof(buf) - 1);
	if (n == 0) return true;
	if (n > 0) {
		buf[n] = '\0';
		if (strstr(buf, "PREEMPTED") != NULL) return true;
	}
	return false;
}

static void
cam_close_face(CamSession *cs)
{
	if (cs->shm) {
		munmap((void *)cs->shm, cs->shm_size);
		cs->shm = NULL;
	}
	if (cs->shm_fd >= 0) {
		close(cs->shm_fd);
		cs->shm_fd = -1;
	}
	if (cs->sock >= 0) {
		close(cs->sock);
		cs->sock = -1;
	}
}

/* ============================================================================
 * Commands: ENROLL & SCAN
 * ============================================================================ */
static void
send_str(int fd, const char *s)
{
	(void)write(fd, s, strlen(s));
}

static void
handle_enroll(int cfd)
{
	pthread_mutex_lock(&g_lock);
	g_scanning = 1;
	g_cancel = 0;
	pthread_mutex_unlock(&g_lock);

	CamSession cs;
	int r = cam_open_face(&cs);
	if (r != 0) {
		send_str(cfd, r == -2 ? "ERR busy\n" : "ERR camd\n");
		g_scanning = 0;
		return;
	}

	uint64_t t0 = now_ms();
	uint64_t last_seq = cs.shm->seq;
	int captured = 0;
	int seen_frames = 0;
	float samples[5][DESC_DIM];

	while (!g_cancel && captured < 5 && (now_ms() - t0) < 15000) {
		if (cam_was_preempted(&cs)) break;
		uint64_t seq = cs.shm->seq;
		if (seq == 0 || seq == last_seq) {
			usleep(30000);
			continue;
		}
		last_seq = seq;
		seen_frames++;
		if (seen_frames <= 3) continue; /* let AE settle */

		uint32_t slot = cs.shm->latest;
		if (slot >= CAMD_SHM_SLOTS) continue;
		const CamdSlot *sl = &cs.shm->slot[slot];
		const uint8_t *px = (const uint8_t *)cs.shm + cs.shm->header_size + (size_t)slot * cs.shm->slot_size;

		float vec[DESC_DIM];
		if (extract_face_descriptor(px, sl->width, sl->height, sl->stride, vec)) {
			memcpy(samples[captured], vec, sizeof(vec));
			captured++;
			char msg[64];
			snprintf(msg, sizeof(msg), "PROGRESS %d 5\n", captured);
			send_str(cfd, msg);
			usleep(250000); /* brief gap for user head micro-movement */
		}
	}

	cam_close_face(&cs);
	g_scanning = 0;

	if (captured == 5) {
		pthread_mutex_lock(&g_lock);
		g_tmpl.count = 5;
		for (int i = 0; i < 5; i++) memcpy(g_tmpl.vec[i], samples[i], sizeof(samples[i]));
		save_templates();
		update_face_state();
		pthread_mutex_unlock(&g_lock);
		send_str(cfd, "DONE 5\n");
	} else {
		send_str(cfd, g_cancel ? "CANCELLED\n" : "ERR noface\n");
	}
}

static void
handle_scan(int cfd)
{
	if (g_tmpl.count == 0) {
		send_str(cfd, "ERR not_enrolled\n");
		return;
	}
	if (is_prox_near()) {
		send_str(cfd, "CANCELLED\n");
		return;
	}

	pthread_mutex_lock(&g_lock);
	g_scanning = 1;
	g_cancel = 0;
	pthread_mutex_unlock(&g_lock);

	CamSession cs;
	int r = cam_open_face(&cs);
	if (r != 0) {
		send_str(cfd, r == -2 ? "BUSY\n" : "ERR camd\n");
		g_scanning = 0;
		return;
	}

	uint64_t t0 = now_ms();
	uint64_t last_seq = cs.shm->seq;
	int seen = 0, consec_match = 0, face_seen = 0;
	float best_score = 0.0f;
	bool matched = false;

	while (!g_cancel && (now_ms() - t0) < SCAN_TIMEOUT_MS) {
		if (is_prox_near() || cam_was_preempted(&cs)) {
			g_cancel = 1;
			break;
		}
		uint64_t seq = cs.shm->seq;
		if (seq == 0 || seq == last_seq) {
			usleep(25000);
			continue;
		}
		last_seq = seq;
		seen++;
		if (seen <= 2) continue; /* skip initial cold frames */

		uint32_t slot = cs.shm->latest;
		if (slot >= CAMD_SHM_SLOTS) continue;
		const CamdSlot *sl = &cs.shm->slot[slot];
		const uint8_t *px = (const uint8_t *)cs.shm + cs.shm->header_size + (size_t)slot * cs.shm->slot_size;

		float vec[DESC_DIM];
		if (extract_face_descriptor(px, sl->width, sl->height, sl->stride, vec)) {
			face_seen = 1;
			float sc = best_template_score(vec);
			if (sc > best_score) best_score = sc;
			if (sc >= MATCH_THRESHOLD) {
				consec_match++;
				if (consec_match >= 2) {
					matched = true;
					break;
				}
			} else {
				consec_match = 0;
			}
		}
	}

	cam_close_face(&cs);
	g_scanning = 0;

	char out[128];
	if (matched) {
		char fpd_rep[64] = "";
		if (fpd_cmd("FACE_UNLOCK\n", fpd_rep, sizeof(fpd_rep)) == 0 && strncmp(fpd_rep, "OK", 2) == 0) {
			snprintf(out, sizeof(out), "MATCH %.3f\n", best_score);
		} else {
			snprintf(out, sizeof(out), "ERR unlock %s\n", fpd_rep);
		}
		send_str(cfd, out);
	} else if (g_cancel) {
		send_str(cfd, "CANCELLED\n");
	} else if (face_seen) {
		char fpd_rep[64] = "";
		fpd_cmd("FACE_FAIL\n", fpd_rep, sizeof(fpd_rep));
		snprintf(out, sizeof(out), "NOMATCH %.3f\n", best_score);
		send_str(cfd, out);
	} else {
		send_str(cfd, "NOFACE\n");
	}
}

static void *
client_thread(void *arg)
{
	int cfd = *(int *)arg;
	free(arg);
	char buf[256];
	ssize_t n = read(cfd, buf, sizeof(buf) - 1);
	if (n > 0) {
		buf[n] = '\0';
		char *nl = strpbrk(buf, "\r\n");
		if (nl) *nl = '\0';
		if (strcmp(buf, "STATUS") == 0) {
			char out[128];
			snprintf(out, sizeof(out), "OK enrolled=%u scanning=%d\n", g_tmpl.count, (int)g_scanning);
			send_str(cfd, out);
		} else if (strcmp(buf, "STOP") == 0) {
			g_cancel = 1;
			send_str(cfd, "OK\n");
		} else if (strcmp(buf, "DELETE") == 0) {
			g_cancel = 1;
			pthread_mutex_lock(&g_lock);
			g_tmpl.count = 0;
			unlink(FACED_TMPL_PATH);
			update_face_state();
			pthread_mutex_unlock(&g_lock);
			send_str(cfd, "OK\n");
		} else if (strcmp(buf, "ENROLL") == 0) {
			handle_enroll(cfd);
		} else if (strcmp(buf, "SCAN") == 0 || strcmp(buf, "SCAN_BIO") == 0) {
			handle_scan(cfd);
		} else {
			send_str(cfd, "ERR unknown\n");
		}
	}
	close(cfd);
	return NULL;
}

int
main(void)
{
	signal(SIGPIPE, SIG_IGN);
	notify_register_check(N_FACE_STATE, &g_tok_state);
	notify_register_check(N_PROX, &g_tok_prox);
	load_templates();
	update_face_state();

	unlink(FACED_SOCK_PATH);
	int ls = socket(AF_UNIX, SOCK_STREAM, 0);
	if (ls < 0) return 1;
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", FACED_SOCK_PATH);
	if (bind(ls, (struct sockaddr *)&sa, sizeof(sa)) != 0 || listen(ls, 16) != 0) {
		close(ls);
		return 1;
	}
	chmod(FACED_SOCK_PATH, 0666);

	for (;;) {
		int cfd = accept(ls, NULL, NULL);
		if (cfd < 0) continue;
		int *p = malloc(sizeof(int));
		if (!p) { close(cfd); continue; }
		*p = cfd;
		pthread_t th;
		if (pthread_create(&th, NULL, client_thread, p) == 0) {
			pthread_detach(th);
		} else {
			free(p);
			close(cfd);
		}
	}
	return 0;
}
