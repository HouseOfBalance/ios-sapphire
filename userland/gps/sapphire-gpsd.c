/*
 * sapphire-gpsd: Qualcomm QMI LOC (service 0x10) GNSS client over /dev/redwood-qmiN.
 *
 * Usage:
 *   sapphire-gpsd --test [seconds]   Run interactively, print GNSS fixes & stop cleanly
 *   sapphire-gpsd                    Run continuously, write fixes to /var/tmp/sapphire-gps.fix
 *                                    and post Darwin notification com.sapphire.gps.fix
 *
 * Message/TLV IDs follow Qualcomm location_service_v02.h:
 *   0x0021 QMI_LOC_REG_EVENTS_REQ       (TLV 0x01: uint64 eventRegMask, bit 0 = POSITION_REPORT)
 *   0x0022 QMI_LOC_START_REQ            (TLV 0x01: u8 sessionId, 0x10: u32 recurrence, 0x12: u32 minInterval)
 *   0x0023 QMI_LOC_STOP_REQ             (TLV 0x01: u8 sessionId)
 *   0x0024 QMI_LOC_EVENT_POSITION_REPORT_IND
 *   0x0038 QMI_LOC_INJECT_UTC_TIME_REQ  (TLV 0x01: u64 timeUtc ms, TLV 0x02: u32 timeUnc ms)
 */
#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <unistd.h>

#define SVC_LOC                 0x10
#define QMI_LOC_REG_EVENTS_REQ  0x0021
#define QMI_LOC_START_REQ       0x0022
#define QMI_LOC_STOP_REQ        0x0023
#define QMI_LOC_POS_REPORT_IND  0x0024
#define QMI_LOC_INJECT_UTC_REQ  0x0038

#define FIX_PATH                "/var/tmp/sapphire-gps.fix"
#define FIX_TMP_PATH            "/var/tmp/sapphire-gps.fix.tmp"
#define N_GPS_FIX               "com.sapphire.gps.fix"

struct sweet_qmi_hdr { uint32_t node, port; };
struct sweet_qmi_lookup { uint32_t svc, inst, index, node, port, found_inst; };
#define SWEET_QMI_LOOKUP        _IOWR('q', 1, struct sweet_qmi_lookup)

struct qmi_cli { int fd; uint32_t node, port; uint16_t txn; };
struct qmi_msg { uint8_t b[4096]; uint32_t n; };

static volatile sig_atomic_t g_stop = 0;

static void
on_sig(int s)
{
	(void)s;
	g_stop = 1;
}

static int
qmi_open_loc(struct qmi_cli *c)
{
	char path[32];
	c->fd = -1;
	for (int i = 0; i < 16; i++) {
		snprintf(path, sizeof(path), "/dev/redwood-qmi%d", i);
		c->fd = open(path, O_RDWR);
		if (c->fd >= 0) break;
		if (errno != EBUSY) return -1;
	}
	if (c->fd < 0) return -1;
	struct sweet_qmi_lookup l = { SVC_LOC, ~0u, 0, 0, 0, 0 };
	if (ioctl(c->fd, SWEET_QMI_LOOKUP, &l) != 0) {
		close(c->fd);
		c->fd = -1;
		return -1;
	}
	c->node = l.node;
	c->port = l.port;
	c->txn = (uint16_t)((getpid() & 0xff) << 8) | 1;
	return 0;
}

static void
m_init(struct qmi_msg *m, uint16_t txn, uint16_t id)
{
	m->b[0] = 0x00; /* request */
	memcpy(m->b + 1, &txn, 2);
	memcpy(m->b + 3, &id, 2);
	m->n = 7;
	uint16_t z = 0;
	memcpy(m->b + 5, &z, 2);
}

static void
m_tlv(struct qmi_msg *m, uint8_t type, const void *val, uint16_t len)
{
	if (m->n + 3 + len > sizeof(m->b)) return;
	m->b[m->n] = type;
	memcpy(m->b + m->n + 1, &len, 2);
	memcpy(m->b + m->n + 3, val, len);
	m->n += 3 + len;
	uint16_t total = (uint16_t)(m->n - 7);
	memcpy(m->b + 5, &total, 2);
}

static int
qmi_send(struct qmi_cli *c, const struct qmi_msg *m)
{
	uint8_t pkt[sizeof(struct sweet_qmi_hdr) + sizeof(m->b)];
	struct sweet_qmi_hdr h = { c->node, c->port };
	memcpy(pkt, &h, sizeof(h));
	memcpy(pkt + sizeof(h), m->b, m->n);
	ssize_t r = write(c->fd, pkt, sizeof(h) + m->n);
	return (r == (ssize_t)(sizeof(h) + m->n)) ? 0 : -1;
}

static const uint8_t *
tlv_find(const uint8_t *qmi, uint32_t qlen, uint8_t want, uint16_t *out_len)
{
	if (qlen < 7) return NULL;
	uint32_t off = 7;
	while (off + 3 <= qlen) {
		uint8_t t = qmi[off];
		uint16_t l;
		memcpy(&l, qmi + off + 1, 2);
		if (off + 3 + l > qlen) break;
		if (t == want) {
			if (out_len) *out_len = l;
			return qmi + off + 3;
		}
		off += 3 + l;
	}
	return NULL;
}

static void
write_fix(double lat, double lon, float acc, float alt, float spd, float hdg, uint64_t ts_ms)
{
	FILE *f = fopen(FIX_TMP_PATH, "w");
	if (!f) return;
	fprintf(f, "lat=%.7f\nlon=%.7f\nacc=%.2f\nalt=%.2f\nspd=%.2f\nhdg=%.2f\nts=%llu\n",
	    lat, lon, acc, alt, spd, hdg, (unsigned long long)ts_ms);
	fclose(f);
	rename(FIX_TMP_PATH, FIX_PATH);
	notify_post(N_GPS_FIX);
}

int
main(int argc, char **argv)
{
	bool test_mode = false;
	int max_secs = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--test") == 0) {
			test_mode = true;
			if (i + 1 < argc) max_secs = atoi(argv[++i]);
		}
	}

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	struct qmi_cli cli;
	if (qmi_open_loc(&cli) != 0) {
		fprintf(stderr, "sapphire-gpsd: QMI LOC (0x10) not available\n");
		return 1;
	}
	fprintf(stderr, "sapphire-gpsd: connected to QMI LOC at %u:0x%x\n", cli.node, cli.port);

	/* 1. Inject current UTC time to speed up cold TTFF */
	struct timeval tv;
	gettimeofday(&tv, NULL);
	uint64_t utc_ms = (uint64_t)tv.tv_sec * 1000ULL + (uint64_t)(tv.tv_usec / 1000ULL);
	uint32_t unc_ms = 5000;
	struct qmi_msg m;
	m_init(&m, cli.txn++, QMI_LOC_INJECT_UTC_REQ);
	m_tlv(&m, 0x01, &utc_ms, sizeof(utc_ms));
	m_tlv(&m, 0x02, &unc_ms, sizeof(unc_ms));
	qmi_send(&cli, &m);

	/* 2. Register for POSITION_REPORT indications */
	uint64_t mask = 0x00000001ULL;
	m_init(&m, cli.txn++, QMI_LOC_REG_EVENTS_REQ);
	m_tlv(&m, 0x01, &mask, sizeof(mask));
	qmi_send(&cli, &m);

	/* 3. Start periodic 1s GNSS session (sessionId = 1) */
	uint8_t sid = 1;
	uint32_t recurrence = 1; /* periodic */
	uint32_t min_interval = 1000;
	m_init(&m, cli.txn++, QMI_LOC_START_REQ);
	m_tlv(&m, 0x01, &sid, 1);
	m_tlv(&m, 0x10, &recurrence, 4);
	m_tlv(&m, 0x12, &min_interval, 4);
	qmi_send(&cli, &m);

	struct timeval t0;
	gettimeofday(&t0, NULL);
	uint8_t buf[4096];

	while (!g_stop) {
		if (max_secs > 0) {
			struct timeval now;
			gettimeofday(&now, NULL);
			if (now.tv_sec - t0.tv_sec >= max_secs) break;
		}
		fd_set rfds;
		FD_ZERO(&rfds);
		FD_SET(cli.fd, &rfds);
		struct timeval to = { .tv_sec = 1, .tv_usec = 0 };
		int sel = select(cli.fd + 1, &rfds, NULL, NULL, &to);
		if (sel <= 0) continue;

		ssize_t n = read(cli.fd, buf, sizeof(buf));
		if (n <= (ssize_t)(sizeof(struct sweet_qmi_hdr) + 7)) continue;
		const uint8_t *q = buf + sizeof(struct sweet_qmi_hdr);
		uint32_t qlen = (uint32_t)(n - (ssize_t)sizeof(struct sweet_qmi_hdr));
		uint8_t flags = q[0];
		uint16_t msgid;
		memcpy(&msgid, q + 3, 2);

		if (flags == 0x04 && msgid == QMI_LOC_POS_REPORT_IND) {
			uint16_t l = 0;
			const uint8_t *p;
			uint32_t status = 99;
			double lat = 0, lon = 0;
			float acc = 999.0f, alt = 0.0f, spd = 0.0f, hdg = 0.0f;
			uint64_t ts = 0;
			bool have_ll = false;

			if ((p = tlv_find(q, qlen, 0x01, &l)) && l >= 4) memcpy(&status, p, 4);
			if ((p = tlv_find(q, qlen, 0x10, &l)) && l >= 8) { memcpy(&lat, p, 8); have_ll = true; }
			if ((p = tlv_find(q, qlen, 0x11, &l)) && l >= 8) { memcpy(&lon, p, 8); } else have_ll = false;
			if ((p = tlv_find(q, qlen, 0x12, &l)) && l >= 4) memcpy(&acc, p, 4);
			if ((p = tlv_find(q, qlen, 0x16, &l)) && l >= 4) memcpy(&alt, p, 4);
			if ((p = tlv_find(q, qlen, 0x19, &l)) && l >= 4) memcpy(&spd, p, 4);
			if ((p = tlv_find(q, qlen, 0x1A, &l)) && l >= 4) memcpy(&hdg, p, 4);
			if ((p = tlv_find(q, qlen, 0x22, &l)) && l >= 8) memcpy(&ts, p, 8);

			if (have_ll) {
				write_fix(lat, lon, acc, alt, spd, hdg, ts);
				if (test_mode) {
					printf("GPS FIX (status=%u): lat=%.7f lon=%.7f acc=%.1fm alt=%.1fm spd=%.1fm/s hdg=%.1f\n",
					    status, lat, lon, acc, alt, spd, hdg);
					fflush(stdout);
				}
			} else if (test_mode) {
				printf("GPS IND (status=%u, searching satellites...)\n", status);
				fflush(stdout);
			}
		}
	}

	/* Stop GNSS session cleanly on exit */
	m_init(&m, cli.txn++, QMI_LOC_STOP_REQ);
	m_tlv(&m, 0x01, &sid, 1);
	qmi_send(&cli, &m);
	close(cli.fd);
	return 0;
}
