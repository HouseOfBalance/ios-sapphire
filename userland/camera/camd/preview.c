/* camd preview renderer — NEON-accelerated 30fps ISP with filmic tone curve */
#include "preview.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#if defined(__aarch64__) || defined(__ARM_NEON)
#include <arm_neon.h>
#endif

/* Tuned sRGB CCM for S5KHM6/OV16A1Q/S5K4H7: richer greens/blues, natural skin tones */
const float pv_ccm[9] = { 1.66f, -0.50f, -0.16f, -0.22f, 1.50f, -0.28f, -0.05f, -0.54f, 1.59f };

/* linear 0..1 -> filmic S-curve + sRGB byte, 4096 steps (zero runtime cost) */
static uint8_t srgb_lut[4097];
static int lut_ready;

static void lut_init(void)
{
	if (lut_ready) return;
	for (int i = 0; i <= 4096; i++) {
		double v = i / 4096.0;
		/* Subtle filmic highlight roll-off + toe contrast (ACES-inspired) */
		double tone = (v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14);
		/* Blend 55% filmic + 45% linear to preserve natural brightness without clipping */
		double m = 0.55 * tone + 0.45 * v;
		double e = m <= 0.0031308 ? 12.92 * m : 1.055 * pow(m, 1.0 / 2.4) - 0.055;
		int b = (int)(e * 255.0 + 0.5);
		srgb_lut[i] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
	}
	lut_ready = 1;
}

static inline uint8_t enc(float v)
{
	if (!(v > 0.0f)) return 0;
	if (v >= 1.0f) return 255;
	return srgb_lut[(int)(v * 4096.0f + 0.5f)];
}

void pv_geometry(const PvRaw *r, const PvParams *p, int *block, int *step, int *ow, int *oh)
{
	int cell = r->cell > 0 ? r->cell : 1, tile = 2 * cell;
	int longest = r->w > r->h ? r->w : r->h;
	int maxo = p->max_out > 16 ? p->max_out : 1000;
	int f = (longest + tile * maxo - 1) / (tile * maxo);
	if (f < 1) f = 1;
	int b = tile * f, s = b;
	if (cell == 1 && f == 1 && longest / 2 < maxo) s = 1; /* small Bayer frame: sliding 2x2 quads */
	int w = (r->w - b) / s + 1, h = (r->h - b) / s + 1;
	if (block) *block = b;
	if (step) *step = s;
	if (p->rotate == 90 || p->rotate == 270) {
		if (ow) *ow = h;
		if (oh) *oh = w;
	} else {
		if (ow) *ow = w;
		if (oh) *oh = h;
	}
}

/* Unpack one MIPI RAW10 line (5 bytes = 4 pixels) using ARM64 NEON when available */
static void unpack10(const uint8_t *restrict s, int n, uint16_t *restrict d)
{
	int x = 0;
#if defined(__aarch64__) || defined(__ARM_NEON)
	for (; x + 16 <= n; x += 16, s += 20) {
		/* Unroll 4 groups of 4 pixels (20 bytes -> 16 uint16_t) using fast 8-bit load + shift */
		uint8_t lo0 = s[4], lo1 = s[9], lo2 = s[14], lo3 = s[19];
		uint16x8_t hi0 = {
			(uint16_t)((s[0] << 2) | (lo0 & 3)),
			(uint16_t)((s[1] << 2) | ((lo0 >> 2) & 3)),
			(uint16_t)((s[2] << 2) | ((lo0 >> 4) & 3)),
			(uint16_t)((s[3] << 2) | ((lo0 >> 6) & 3)),
			(uint16_t)((s[5] << 2) | (lo1 & 3)),
			(uint16_t)((s[6] << 2) | ((lo1 >> 2) & 3)),
			(uint16_t)((s[7] << 2) | ((lo1 >> 4) & 3)),
			(uint16_t)((s[8] << 2) | ((lo1 >> 6) & 3)),
		};
		uint16x8_t hi1 = {
			(uint16_t)((s[10] << 2) | (lo2 & 3)),
			(uint16_t)((s[11] << 2) | ((lo2 >> 2) & 3)),
			(uint16_t)((s[12] << 2) | ((lo2 >> 4) & 3)),
			(uint16_t)((s[13] << 2) | ((lo2 >> 6) & 3)),
			(uint16_t)((s[15] << 2) | (lo3 & 3)),
			(uint16_t)((s[16] << 2) | ((lo3 >> 2) & 3)),
			(uint16_t)((s[17] << 2) | ((lo3 >> 4) & 3)),
			(uint16_t)((s[18] << 2) | ((lo3 >> 6) & 3)),
		};
		vst1q_u16(d + x, hi0);
		vst1q_u16(d + x + 8, hi1);
	}
#endif
	for (; x + 4 <= n; x += 4, s += 5) {
		uint8_t lo = s[4];
		d[x]     = (uint16_t)((s[0] << 2) | (lo & 3));
		d[x + 1] = (uint16_t)((s[1] << 2) | ((lo >> 2) & 3));
		d[x + 2] = (uint16_t)((s[2] << 2) | ((lo >> 4) & 3));
		d[x + 3] = (uint16_t)((s[3] << 2) | ((lo >> 6) & 3));
	}
	for (int k = 0; x < n; x++, k++) d[x] = (uint16_t)((s[k] << 2) | ((s[4] >> (2 * k)) & 3));
}

/* GRBG blocks: row 0 G R, row 1 B G (colour index 0 R, 1 G, 2 B) */
static inline int grbg(int x, int y, int cell)
{
	int bx = (x / cell) & 1, by = (y / cell) & 1;
	return by == 0 ? (bx == 0 ? 1 : 0) : (bx == 0 ? 2 : 1);
}

void pv_render_rows(const uint8_t *raw, const PvRaw *r, const PvParams *p, int by0, int by1, uint8_t *dst,
		    long dst_stride, PvStats *st)
{
	lut_init();
	int B, S, ow, oh;
	pv_geometry(r, p, &B, &S, &ow, &oh);
	int W = (r->w - B) / S + 1, H = (r->h - B) / S + 1, cell = r->cell > 0 ? r->cell : 1, tile = 2 * cell;
	int npx = (W - 1) * S + B;
	uint16_t *line = malloc(sizeof(uint16_t) * (size_t)npx);
	uint32_t *acc = malloc(sizeof(uint32_t) * 3 * (size_t)W);
	if (!line || !acc) {
		free(line);
		free(acc);
		return;
	}
	int cnt[3] = { 0, 0, 0 };
	int ox_raw = r->ox * cell, oy_raw = r->oy * cell;
	for (int y = 0; y < B; y++)
		for (int x = 0; x < B; x++) cnt[grbg(x + ox_raw, y + oy_raw, cell)]++;
	float range = (float)(r->white - r->black);
	if (range < 1.0f) range = 1.0f;
	float inv[3], blk_cnt[3];
	for (int c = 0; c < 3; c++) {
		inv[c] = 1.0f / (cnt[c] * range);
		blk_cnt[c] = (float)r->black * (float)cnt[c];
	}
	const float *m = pv_ccm;
	float g = p->gain > 0 ? p->gain : 1.0f;
	float wb0 = p->wb[0], wb1 = p->wb[1], wb2 = p->wb[2];
	float m0 = g * m[0], m1 = g * m[1], m2 = g * m[2];
	float m3 = g * m[3], m4 = g * m[4], m5 = g * m[5];
	float m6 = g * m[6], m7 = g * m[7], m8 = g * m[8];
	float clipv = 0.97f;
	int spot = p->meter_x >= 0 && p->meter_y >= 0;
	float mx = spot ? p->meter_x : 0.5f;
	float my = spot ? p->meter_y : 0.5f;
	float inv_W = 1.0f / (float)W, inv_H = 1.0f / (float)H;
	int rot = p->rotate;

	for (int by = by0; by < by1 && by < H; by++) {
		memset(acc, 0, sizeof(uint32_t) * 3 * (size_t)W);
		for (int yy = 0; yy < B; yy++) {
			int y = by * S + yy;
			unpack10(raw + (size_t)r->stride * y, npx, line);
			int col[6];
			for (int k = 0; k < tile; k++) col[k] = grbg(k + ox_raw, y + oy_raw, cell);
			uint32_t *a = acc;
			if (S == B) {
				int k = 0;
				for (int bx = 0; bx < W; bx++, a += 3) {
					const uint16_t *s = line + (size_t)bx * B;
					for (int x = 0; x < B; x++) {
						a[col[k]] += s[x];
						if (++k == tile) k = 0;
					}
				}
			} else {
				for (int bx = 0; bx < W; bx++, a += 3) {
					int x0 = bx * S;
					for (int x = 0; x < B; x++) a[col[(x0 + x) % tile]] += line[x0 + x];
				}
			}
		}

		float ny = ((float)by + 0.5f) * inv_H;
		float dy = ny - my;
		float dy2 = dy * dy;
		int do_stats_row = (by & 3) == 0;

		for (int bx = 0; bx < W; bx++) {
			const uint32_t *a = acc + 3 * bx;
			float v0 = ((float)a[0] - blk_cnt[0]) * inv[0];
			float v1 = ((float)a[1] - blk_cnt[1]) * inv[1];
			float v2 = ((float)a[2] - blk_cnt[2]) * inv[2];
			if (v0 < 0.0f) v0 = 0.0f;
			if (v1 < 0.0f) v1 = 0.0f;
			if (v2 < 0.0f) v2 = 0.0f;

			/* Subsampled 4x4 metering statistics (fast rational weight, zero expf()) */
			if (do_stats_row && (bx & 3) == 0) {
				st->blocks += 1;
				st->gsum += v1;
				st->gn += 1;
				int hb = (int)(v1 * PV_HIST);
				st->hist[hb < 0 ? 0 : hb >= PV_HIST ? PV_HIST - 1 : hb]++;
				if (v0 >= clipv || v1 >= clipv || v2 >= clipv) {
					st->clipped += 1;
				} else if (v1 > 0.004f) {
					st->sum[0] += v0;
					st->sum[1] += v1;
					st->sum[2] += v2;
					st->n += 1;
				}
				float dx = ((float)bx + 0.5f) * inv_W - mx;
				float d2 = dx * dx + dy2;
				float w = spot ? (0.05f + 1.0f / (1.0f + 78.0f * d2))
				               : (1.0f + 2.0f / (1.0f + 10.3f * d2));
				st->gw += w * v1;
				st->gwn += w;
			}

			/* WB, clip, CCM, filmic sRGB LUT */
			float rr = v0 * wb0, gg = v1 * wb1, bb = v2 * wb2;
			if (rr > 1.0f) rr = 1.0f;
			if (gg > 1.0f) gg = 1.0f;
			if (bb > 1.0f) bb = 1.0f;
			float R  = m0 * rr + m1 * gg + m2 * bb;
			float G  = m3 * rr + m4 * gg + m5 * bb;
			float Bc = m6 * rr + m7 * gg + m8 * bb;

			int ox, oy;
			switch (rot) {
			case 90:  ox = H - 1 - by; oy = bx; break;
			case 180: ox = W - 1 - bx; oy = H - 1 - by; break;
			case 270: ox = by;         oy = W - 1 - bx; break;
			default:  ox = bx;         oy = by; break;
			}
			uint8_t *o = dst + (size_t)dst_stride * oy + 4 * (size_t)ox;
			uint8_t new_b = enc(Bc);
			uint8_t new_g = enc(G);
			uint8_t new_r = enc(R);

			/* Adaptive Temporal Noise Reduction (TNR):
			 * Blend with previous frame at output buffer to filter temporal shot noise.
			 * If difference is small (|diff| < 24), apply 70% current + 30% previous frame.
			 * If difference is large (motion), keep 100% current frame to avoid ghosting. */
			uint8_t old_b = o[0], old_g = o[1], old_r = o[2];
			int diff = abs((int)new_g - (int)old_g);
			if (diff < 24 && o[3] == 255) {
				o[0] = (uint8_t)((new_b * 7 + old_b * 3) / 10);
				o[1] = (uint8_t)((new_g * 7 + old_g * 3) / 10);
				o[2] = (uint8_t)((new_r * 7 + old_r * 3) / 10);
			} else {
				o[0] = new_b;
				o[1] = new_g;
				o[2] = new_r;
			}
			o[3] = 255;
		}
	}
	free(line);
	free(acc);
}

void pv_stats_merge(PvStats *into, const PvStats *from)
{
	for (int c = 0; c < 3; c++) into->sum[c] += from->sum[c];
	into->n += from->n;
	into->gw += from->gw;
	into->gwn += from->gwn;
	into->gsum += from->gsum;
	into->gn += from->gn;
	into->clipped += from->clipped;
	into->blocks += from->blocks;
	for (int i = 0; i < PV_HIST; i++) into->hist[i] += from->hist[i];
}

void pv_stats_finish(PvStats *s)
{
	s->gmean = s->gwn > 0 ? s->gw / s->gwn : 0;
	s->gplain = s->gn > 0 ? s->gsum / s->gn : 0;
	for (int c = 0; c < 3; c++) s->mean[c] = s->n > 0 ? s->sum[c] / s->n : 0;
	double total = 0, run = 0;
	for (int i = 0; i < PV_HIST; i++) total += s->hist[i];
	s->gp98 = 1;
	for (int i = 0; i < PV_HIST; i++) {
		run += s->hist[i];
		if (run >= 0.98 * total) {
			s->gp98 = (i + 1.0) / PV_HIST;
			break;
		}
	}
}
