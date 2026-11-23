/*
 * VexZstd.c — zstd frame decoder for archive payloads.
 *
 * Derived from SayoSign's from-scratch decoder (`core/src/zstd.c`), which is the reason this
 * works without linking libzstd: iOS ships no zstd decoder, and `.deb` payloads have moved to
 * `data.tar.zst`. SayoSign is GPL-3.0, the same licence as this repository — see
 * THIRD_PARTY_NOTICES.md for the attribution and the commit the code was taken from.
 *
 * Changes from the upstream file, all on the boundary rather than in the algorithm:
 *
 *   - a caller-supplied output ceiling, checked while the buffer grows and against the frame's
 *     declared content size, so a decompression bomb becomes an error instead of a jetsam kill;
 *   - the 4-byte XXH64 frame checksum is verified instead of skipped, so a truncated or
 *     corrupted `.deb` payload is refused rather than half-parsed;
 *   - `malloc` results are checked, and the error string is thread-local;
 *   - the buffer/error helpers are private to this file (`vex_` prefix), so nothing collides
 *     with the app's other C sources.
 *
 * The decoder itself (FSE, Huffman, sequences, repeat offsets, block types) is upstream code.
 */

#include "VexZstd.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Errors */

static _Thread_local char vex_error[256];

const char *vex_zstd_last_error(void) { return vex_error; }

static void vex_set_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(vex_error, sizeof vex_error, fmt, ap);
    va_end(ap);
}

/* Bounded output buffer */

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    size_t max;      /* ceiling on `len`; exceeding it sets `over` */
    int over;
} vex_buf;

static void vex_buf_init(vex_buf *b, size_t max) {
    memset(b, 0, sizeof *b);
    b->max = max;
}

static void vex_buf_free(vex_buf *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

static int vex_buf_reserve(vex_buf *b, size_t extra) {
    if (b->len > b->max || extra > b->max - b->len) {
        b->over = 1;
        vex_set_error("zstd output exceeds the %zu byte limit", b->max);
        return -1;
    }
    if (b->len + extra <= b->cap) return 0;
    size_t next = b->cap ? b->cap : 4096;
    while (next < b->len + extra) next *= 2;
    uint8_t *grown = realloc(b->data, next);
    if (!grown) {
        vex_set_error("zstd: out of memory");
        return -1;
    }
    b->data = grown;
    b->cap = next;
    return 0;
}

static int vex_buf_append(vex_buf *b, const void *p, size_t n) {
    if (!n) return 0;
    if (vex_buf_reserve(b, n)) return -1;
    memcpy(b->data + b->len, p, n);
    b->len += n;
    return 0;
}

static int vex_buf_fill(vex_buf *b, uint8_t v, size_t n) {
    if (vex_buf_reserve(b, n)) return -1;
    memset(b->data + b->len, v, n);
    b->len += n;
    return 0;
}

/* XXH64: the frame checksum */

#define VEX_P1 11400714785074694791ULL
#define VEX_P2 14029467366897019727ULL
#define VEX_P3 1609587929392839161ULL
#define VEX_P4 9650029242287828579ULL
#define VEX_P5 2870177450012600261ULL

static uint64_t vex_rotl(uint64_t v, int r) { return (v << r) | (v >> (64 - r)); }

static uint64_t vex_read64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | (uint64_t)p[i];
    return v;
}

static uint32_t vex_read32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t vex_xxh_round(uint64_t acc, uint64_t input) {
    acc += input * VEX_P2;
    acc = vex_rotl(acc, 31);
    acc *= VEX_P1;
    return acc;
}

static uint64_t vex_xxh_merge(uint64_t acc, uint64_t lane) {
    acc ^= vex_xxh_round(0, lane);
    acc = acc * VEX_P1 + VEX_P4;
    return acc;
}

/* XXH64 with seed 0 over `n` bytes: the low 32 bits are the zstd frame checksum. */
static uint64_t vex_xxh64(const uint8_t *p, size_t n) {
    uint64_t h;
    size_t i = 0;
    if (n >= 32) {
        uint64_t v1 = VEX_P1 + VEX_P2, v2 = VEX_P2, v3 = 0, v4 = (uint64_t)0 - VEX_P1;
        for (; i + 32 <= n; i += 32) {
            v1 = vex_xxh_round(v1, vex_read64(p + i));
            v2 = vex_xxh_round(v2, vex_read64(p + i + 8));
            v3 = vex_xxh_round(v3, vex_read64(p + i + 16));
            v4 = vex_xxh_round(v4, vex_read64(p + i + 24));
        }
        h = vex_rotl(v1, 1) + vex_rotl(v2, 7) + vex_rotl(v3, 12) + vex_rotl(v4, 18);
        h = vex_xxh_merge(h, v1);
        h = vex_xxh_merge(h, v2);
        h = vex_xxh_merge(h, v3);
        h = vex_xxh_merge(h, v4);
    } else {
        h = VEX_P5;
    }
    h += (uint64_t)n;
    for (; i + 8 <= n; i += 8) {
        h ^= vex_xxh_round(0, vex_read64(p + i));
        h = vex_rotl(h, 27) * VEX_P1 + VEX_P4;
    }
    if (i + 4 <= n) {
        h ^= (uint64_t)vex_read32(p + i) * VEX_P1;
        h = vex_rotl(h, 23) * VEX_P2 + VEX_P3;
        i += 4;
    }
    for (; i < n; i++) {
        h ^= (uint64_t)p[i] * VEX_P5;
        h = vex_rotl(h, 11) * VEX_P1;
    }
    h ^= h >> 33;
    h *= VEX_P2;
    h ^= h >> 29;
    h *= VEX_P3;
    h ^= h >> 32;
    return h;
}

/* Decoder (upstream SayoSign algorithm) */
#include "VexZstd.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    const uint8_t *p;
    size_t n;
    size_t pos;
} fwd;

typedef struct {
    const uint8_t *p;
    int64_t bit;
} bwd;

static int bwd_init(bwd *b, const uint8_t *p, size_t n) {
    if (!n) return -1;
    uint8_t last = p[n - 1];
    if (!last) return -1;
    int hb = 7;
    while (!(last & (1 << hb))) hb--;
    b->p = p;
    b->bit = (int64_t)(n - 1) * 8 + hb;
    return 0;
}

static uint64_t bwd_read(bwd *b, int nb) {
    if (nb == 0) return 0;
    uint64_t v = 0;
    for (int i = 0; i < nb; i++) {
        b->bit--;
        int bitv = 0;
        if (b->bit >= 0) bitv = (b->p[b->bit >> 3] >> (b->bit & 7)) & 1;
        v = (v << 1) | (uint64_t)bitv;
    }
    return v;
}

typedef struct {
    uint8_t *sym;
    uint8_t *nb;
    uint16_t *base;
    int log;
    int size;
} fse_t;

static void fse_free(fse_t *t) { free(t->sym); free(t->nb); free(t->base); memset(t, 0, sizeof *t); }

static int fse_build(fse_t *t, const int16_t *norm, int nsym, int log) {
    int size = 1 << log;
    fse_free(t);
    t->sym = calloc(size, 1);
    t->nb = calloc(size, 1);
    t->base = calloc(size, sizeof(uint16_t));
    t->log = log;
    t->size = size;
    uint16_t *next = calloc(nsym, sizeof(uint16_t));
    int high = size - 1;
    for (int s = 0; s < nsym; s++) {
        if (norm[s] == -1) { t->sym[high--] = (uint8_t)s; next[s] = 1; }
        else next[s] = (uint16_t)norm[s];
    }
    int step = (size >> 1) + (size >> 3) + 3, mask = size - 1, pos = 0;
    for (int s = 0; s < nsym; s++) {
        for (int i = 0; i < norm[s]; i++) {
            t->sym[pos] = (uint8_t)s;
            do pos = (pos + step) & mask; while (pos > high);
        }
    }
    if (pos != 0) { free(next); return -1; }
    for (int i = 0; i < size; i++) {
        int s = t->sym[i];
        uint16_t ns = next[s]++;
        int hb = 31 - __builtin_clz(ns);
        t->nb[i] = (uint8_t)(log - hb);
        t->base[i] = (uint16_t)((ns << t->nb[i]) - size);
    }
    free(next);
    return 0;
}

static int fse_read_desc(const uint8_t *p, size_t n, int maxsym, int maxlog, fse_t *t, size_t *used) {
    if (n < 1) return -1;
    int log = (p[0] & 0xf) + 5;
    if (log > maxlog) return -1;
    int16_t norm[256] = { 0 };
    int remaining = (1 << log) + 1;
    int threshold = 1 << log;
    int nbits = log + 1;
    size_t bitpos = 4;
    int s = 0;
    while (remaining > 1 && s <= maxsym) {
        uint32_t v = 0;
        for (int k = 0; k < 32; k++) {
            size_t bp = bitpos + k;
            if ((bp >> 3) < n) v |= (uint32_t)((p[bp >> 3] >> (bp & 7)) & 1) << k;
        }
        int max = (2 * threshold - 1) - remaining;
        int count;
        if ((int)(v & (threshold - 1)) < max) {
            count = (int)(v & (threshold - 1));
            bitpos += nbits - 1;
        } else {
            count = (int)(v & (2 * threshold - 1));
            if (count >= threshold) count -= max;
            bitpos += nbits;
        }
        count--;
        remaining -= count < 0 ? -count : count;
        norm[s++] = (int16_t)count;
        if (count == 0) {
            for (;;) {
                uint32_t r = 0;
                for (int k = 0; k < 2; k++) {
                    size_t bp = bitpos + k;
                    if ((bp >> 3) < n) r |= (uint32_t)((p[bp >> 3] >> (bp & 7)) & 1) << k;
                }
                bitpos += 2;
                for (uint32_t z = 0; z < r && s <= maxsym; z++) norm[s++] = 0;
                if (r != 3) break;
            }
        }
        while (remaining < threshold) { nbits--; threshold >>= 1; }
    }
    if (remaining != 1) return -1;
    *used = (bitpos + 7) >> 3;
    if (*used > n) return -1;
    return fse_build(t, norm, s, log);
}

typedef struct {
    uint8_t sym[1 << 11];
    uint8_t nb[1 << 11];
    int log;
} huf_t;

static int huf_from_weights(huf_t *h, const uint8_t *w, int nw) {
    uint32_t sum = 0;
    for (int i = 0; i < nw; i++) if (w[i]) sum += 1u << (w[i] - 1);
    if (!sum) return -1;
    int log = 32 - __builtin_clz(sum);
    uint32_t total = 1u << log;
    uint32_t rest = total - sum;
    if (rest & (rest - 1)) return -1;
    int lastw = 31 - __builtin_clz(rest) + 1;
    uint8_t weights[256] = { 0 };
    memcpy(weights, w, nw);
    weights[nw] = (uint8_t)lastw;
    int ns = nw + 1;
    if (log > 11) return -1;
    h->log = log;
    uint32_t rank[16] = { 0 };
    for (int i = 0; i < ns; i++) rank[weights[i]]++;
    uint32_t start[16] = { 0 };
    uint32_t acc = 0;
    for (int wt = 1; wt <= log; wt++) {
        start[wt] = acc;
        acc += rank[wt] << (wt - 1);
    }
    for (int i = 0; i < ns; i++) {
        int wt = weights[i];
        if (!wt) continue;
        uint32_t len = 1u << (wt - 1);
        uint32_t s0 = start[wt];
        for (uint32_t k = 0; k < len; k++) {
            h->sym[s0 + k] = (uint8_t)i;
            h->nb[s0 + k] = (uint8_t)(log + 1 - wt);
        }
        start[wt] += len;
    }
    return 0;
}

static int huf_read_table(huf_t *h, const uint8_t *p, size_t n, size_t *used) {
    if (n < 1) return -1;
    uint8_t hb = p[0];
    uint8_t w[256];
    int nw = 0;
    if (hb >= 128) {
        nw = hb - 127;
        size_t bytes = (nw + 1) / 2;
        if (1 + bytes > n) return -1;
        for (int i = 0; i < nw; i++) {
            uint8_t b = p[1 + i / 2];
            w[i] = i & 1 ? b & 0xf : b >> 4;
        }
        *used = 1 + bytes;
    } else {
        if (1 + (size_t)hb > n) return -1;
        fse_t t = { 0 };
        size_t du;
        if (fse_read_desc(p + 1, hb, 255, 6, &t, &du)) { fse_free(&t); return -1; }
        bwd b;
        if (bwd_init(&b, p + 1 + du, hb - du)) { fse_free(&t); return -1; }
        uint32_t s1 = (uint32_t)bwd_read(&b, t.log), s2 = (uint32_t)bwd_read(&b, t.log);
        for (;;) {
            if (nw >= 255) break;
            w[nw++] = t.sym[s1];
            s1 = t.base[s1] + (uint32_t)bwd_read(&b, t.nb[s1]);
            if (b.bit < 0) { w[nw++] = t.sym[s2]; break; }
            if (nw >= 255) break;
            w[nw++] = t.sym[s2];
            s2 = t.base[s2] + (uint32_t)bwd_read(&b, t.nb[s2]);
            if (b.bit < 0) { w[nw++] = t.sym[s1]; break; }
        }
        fse_free(&t);
        *used = 1 + hb;
    }
    return huf_from_weights(h, w, nw);
}

static int huf_stream(const huf_t *h, const uint8_t *p, size_t n, uint8_t *out, size_t cnt) {
    bwd b;
    if (bwd_init(&b, p, n)) return -1;
    uint32_t state = (uint32_t)bwd_read(&b, h->log);
    uint32_t mask = (1u << h->log) - 1;
    for (size_t i = 0; i < cnt; i++) {
        out[i] = h->sym[state];
        int nb = h->nb[state];
        state = ((state << nb) | (uint32_t)bwd_read(&b, nb)) & mask;
    }
    return 0;
}

typedef struct {
    huf_t huf;
    int huf_ok;
    fse_t ll, ml, of;
    int rep[3];
    int ll_ok, ml_ok, of_ok;
} zctx;

static const int16_t LL_DEF[36] = { 4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1 };
static const int16_t ML_DEF[53] = { 1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1 };
static const int16_t OF_DEF[29] = { 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1 };
static const uint32_t LL_BASE[36] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
static const uint8_t LL_BITS[36] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
static const uint32_t ML_BASE[53] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539 };
static const uint8_t ML_BITS[53] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

static int seq_table(fse_t *t, int *ok, int mode, const uint8_t *p, size_t n, size_t *used,
                     const int16_t *def, int defn, int deflog, int maxsym, int maxlog) {
    *used = 0;
    if (mode == 0) { *ok = 1; return fse_build(t, def, defn, deflog); }
    if (mode == 1) {
        if (n < 1) return -1;
        fse_free(t);
        t->log = 0;
        t->size = 1;
        t->sym = calloc(1, 1);
        t->nb = calloc(1, 1);
        t->base = calloc(1, sizeof(uint16_t));
        t->sym[0] = p[0];
        *used = 1;
        *ok = 1;
        return 0;
    }
    if (mode == 2) { *ok = 1; return fse_read_desc(p, n, maxsym, maxlog, t, used); }
    return *ok ? 0 : -1;
}

static int decode_block(zctx *z, const uint8_t *p, size_t n, vex_buf *out, size_t frame_start) {
    if (n < 1) return -1;
    int ltype = p[0] & 3, sf = (p[0] >> 2) & 3;
    size_t rsize, csize = 0, hl;
    int streams = 1;
    if (ltype <= 1) {
        if ((sf & 1) == 0) { rsize = p[0] >> 3; hl = 1; }
        else if (sf == 1) { if (n < 2) return -1; rsize = (p[0] >> 4) | ((size_t)p[1] << 4); hl = 2; }
        else { if (n < 3) return -1; rsize = (p[0] >> 4) | ((size_t)p[1] << 4) | ((size_t)p[2] << 12); hl = 3; }
    } else {
        if (n < 3) return -1;
        if (sf <= 1) {
            streams = sf == 0 ? 1 : 4;
            uint32_t v = p[0] | (p[1] << 8) | ((uint32_t)p[2] << 16);
            rsize = (v >> 4) & 0x3ff;
            csize = (v >> 14) & 0x3ff;
            hl = 3;
        } else if (sf == 2) {
            if (n < 4) return -1;
            streams = 4;
            uint32_t v = p[0] | (p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
            rsize = (v >> 4) & 0x3fff;
            csize = (v >> 18) & 0x3fff;
            hl = 4;
        } else {
            if (n < 5) return -1;
            streams = 4;
            uint64_t v = p[0] | (p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint64_t)p[3] << 24) | ((uint64_t)p[4] << 32);
            rsize = (v >> 4) & 0x3ffff;
            csize = (v >> 22) & 0x3ffff;
            hl = 5;
        }
    }
    uint8_t *lit = malloc(rsize + 32);
    size_t pos = hl;
    if (ltype == 0) {
        if (pos + rsize > n) { free(lit); return -1; }
        memcpy(lit, p + pos, rsize);
        pos += rsize;
    } else if (ltype == 1) {
        if (pos + 1 > n) { free(lit); return -1; }
        memset(lit, p[pos], rsize);
        pos += 1;
    } else {
        if (pos + csize > n) { free(lit); return -1; }
        const uint8_t *q = p + pos;
        size_t qn = csize;
        if (ltype == 2) {
            size_t u;
            if (huf_read_table(&z->huf, q, qn, &u)) { free(lit); return -1; }
            z->huf_ok = 1;
            q += u;
            qn -= u;
        } else if (!z->huf_ok) { free(lit); return -1; }
        if (streams == 1) {
            if (huf_stream(&z->huf, q, qn, lit, rsize)) { free(lit); return -1; }
        } else {
            if (qn < 6) { free(lit); return -1; }
            size_t s1 = q[0] | (q[1] << 8), s2 = q[2] | (q[3] << 8), s3 = q[4] | (q[5] << 8);
            if (6 + s1 + s2 + s3 > qn) { free(lit); return -1; }
            size_t s4 = qn - 6 - s1 - s2 - s3;
            size_t seg = (rsize + 3) / 4;
            const uint8_t *b = q + 6;
            if (huf_stream(&z->huf, b, s1, lit, seg) ||
                huf_stream(&z->huf, b + s1, s2, lit + seg, seg) ||
                huf_stream(&z->huf, b + s1 + s2, s3, lit + 2 * seg, seg) ||
                huf_stream(&z->huf, b + s1 + s2 + s3, s4, lit + 3 * seg, rsize - 3 * seg)) { free(lit); return -1; }
        }
        pos += csize;
    }
    if (pos >= n) {
        int rc = vex_buf_append(out, lit, rsize);
        free(lit);
        return pos == n ? rc : -1;
    }
    size_t nseq;
    uint8_t b0 = p[pos];
    if (b0 == 0) { nseq = 0; pos++; }
    else if (b0 < 128) { nseq = b0; pos++; }
    else if (b0 < 255) { if (pos + 2 > n) { free(lit); return -1; } nseq = ((size_t)(b0 - 128) << 8) + p[pos + 1]; pos += 2; }
    else { if (pos + 3 > n) { free(lit); return -1; } nseq = p[pos + 1] + ((size_t)p[pos + 2] << 8) + 0x7f00; pos += 3; }
    if (nseq == 0) {
        int rc = vex_buf_append(out, lit, rsize);
        free(lit);
        return rc;
    }
    if (pos >= n) { free(lit); return -1; }
    uint8_t modes = p[pos++];
    size_t u;
    if (seq_table(&z->ll, &z->ll_ok, modes >> 6, p + pos, n - pos, &u, LL_DEF, 36, 6, 35, 9)) { free(lit); return -1; }
    pos += u;
    if (seq_table(&z->of, &z->of_ok, (modes >> 4) & 3, p + pos, n - pos, &u, OF_DEF, 29, 5, 31, 8)) { free(lit); return -1; }
    pos += u;
    if (seq_table(&z->ml, &z->ml_ok, (modes >> 2) & 3, p + pos, n - pos, &u, ML_DEF, 53, 6, 52, 9)) { free(lit); return -1; }
    pos += u;
    bwd b;
    if (bwd_init(&b, p + pos, n - pos)) { free(lit); return -1; }
    uint32_t sll = (uint32_t)bwd_read(&b, z->ll.log);
    uint32_t sof = (uint32_t)bwd_read(&b, z->of.log);
    uint32_t sml = (uint32_t)bwd_read(&b, z->ml.log);
    size_t lp = 0;
    for (size_t i = 0; i < nseq; i++) {
        uint8_t ofc = z->of.sym[sof], llc = z->ll.sym[sll], mlc = z->ml.sym[sml];
        if (llc > 35 || mlc > 52 || ofc > 31) { free(lit); return -1; }
        uint64_t ofv = (1ull << ofc) + bwd_read(&b, ofc);
        uint64_t mlv = ML_BASE[mlc] + bwd_read(&b, ML_BITS[mlc]);
        uint64_t llv = LL_BASE[llc] + bwd_read(&b, LL_BITS[llc]);
        uint64_t offset;
        if (ofv > 3) {
            offset = ofv - 3;
            z->rep[2] = z->rep[1]; z->rep[1] = z->rep[0]; z->rep[0] = (int)offset;
        } else {
            int idx = (int)ofv - 1;
            if (llv == 0) idx++;
            if (idx == 0) offset = (uint64_t)z->rep[0];
            else {
                if (idx == 3) offset = (uint64_t)z->rep[0] - 1;
                else offset = (uint64_t)z->rep[idx];
                if (idx > 1) z->rep[2] = z->rep[1];
                z->rep[1] = z->rep[0];
                z->rep[0] = (int)offset;
            }
        }
        if (lp + llv > rsize) { free(lit); return -1; }
        vex_buf_append(out, lit + lp, (size_t)llv);
        lp += (size_t)llv;
        if (offset == 0 || offset > out->len - frame_start) { free(lit); return -1; }
        if (vex_buf_reserve(out, (size_t)mlv)) { free(lit); return -1; }
        uint8_t *dst = out->data + out->len;
        const uint8_t *src = dst - offset;
        for (uint64_t k = 0; k < mlv; k++) dst[k] = src[k];
        out->len += (size_t)mlv;
        if (i + 1 < nseq) {
            sll = z->ll.base[sll] + (uint32_t)bwd_read(&b, z->ll.nb[sll]);
            sml = z->ml.base[sml] + (uint32_t)bwd_read(&b, z->ml.nb[sml]);
            sof = z->of.base[sof] + (uint32_t)bwd_read(&b, z->of.nb[sof]);
        }
    }
    vex_buf_append(out, lit + lp, rsize - lp);
    free(lit);
    return 0;
}

static int zstd_decode_into(const uint8_t *p, size_t n, vex_buf *out) {
    size_t pos = 0;
    while (pos + 4 <= n) {
        uint32_t magic = p[pos] | (p[pos + 1] << 8) | ((uint32_t)p[pos + 2] << 16) | ((uint32_t)p[pos + 3] << 24);
        if ((magic & 0xfffffff0) == 0x184d2a50) {
            if (pos + 8 > n) break;
            uint32_t sz = p[pos + 4] | (p[pos + 5] << 8) | ((uint32_t)p[pos + 6] << 16) | ((uint32_t)p[pos + 7] << 24);
            pos += 8 + sz;
            continue;
        }
        if (magic != 0xfd2fb528) { vex_set_error("bad zstd magic"); return -1; }
        pos += 4;
        if (pos >= n) return -1;
        uint8_t fhd = p[pos++];
        int fcs_flag = fhd >> 6, single = (fhd >> 5) & 1, checksum = (fhd >> 2) & 1, did = fhd & 3;
        if (!single) pos++;
        static const int didsz[4] = { 0, 1, 2, 4 };
        pos += didsz[did];
        int fcs = fcs_flag == 0 ? (single ? 1 : 0) : fcs_flag == 1 ? 2 : fcs_flag == 2 ? 4 : 8;
        if (pos + (size_t)fcs > n) return -1;
        if (fcs) {
            /* A declared size over the caller's ceiling is refused before a page is allocated. */
            uint64_t declared = 0;
            for (int i = 0; i < fcs; i++) declared |= (uint64_t)p[pos + i] << (8 * i);
            if (fcs == 2) declared += 256;
            if (declared > (uint64_t)out->max) {
                out->over = 1;
                vex_set_error("zstd: frame declares %llu bytes, over the %zu byte limit",
                              (unsigned long long)declared, out->max);
                return -1;
            }
            pos += (size_t)fcs;
        }
        zctx z;
        memset(&z, 0, sizeof z);
        z.rep[0] = 1; z.rep[1] = 4; z.rep[2] = 8;
        size_t frame_start = out->len;
        for (;;) {
            if (pos + 3 > n) { vex_set_error("truncated zstd"); goto fail; }
            uint32_t bh = p[pos] | (p[pos + 1] << 8) | ((uint32_t)p[pos + 2] << 16);
            pos += 3;
            int last = bh & 1, type = (bh >> 1) & 3;
            size_t bs = bh >> 3;
            if (type == 0) {
                if (pos + bs > n) goto fail;
                vex_buf_append(out, p + pos, bs);
                pos += bs;
            } else if (type == 1) {
                if (pos + 1 > n) goto fail;
                vex_buf_fill(out, p[pos], bs);
                pos += 1;
            } else if (type == 2) {
                if (pos + bs > n) goto fail;
                if (decode_block(&z, p + pos, bs, out, frame_start)) { vex_set_error("zstd block error"); goto fail; }
                pos += bs;
            } else goto fail;
            if (last) break;
        }
        if (checksum) {
            if (pos + 4 > n) { vex_set_error("zstd: truncated frame checksum"); goto fail; }
            uint32_t stored = (uint32_t)p[pos] | ((uint32_t)p[pos + 1] << 8) |
                              ((uint32_t)p[pos + 2] << 16) | ((uint32_t)p[pos + 3] << 24);
            const uint8_t *frame = out->len > frame_start ? out->data + frame_start : NULL;
            uint32_t actual = (uint32_t)(vex_xxh64(frame, out->len - frame_start) & 0xffffffffu);
            if (stored != actual) {
                vex_set_error("zstd: frame checksum mismatch (%08x != %08x)", stored, actual);
                goto fail;
            }
            pos += 4;
        }
        fse_free(&z.ll); fse_free(&z.ml); fse_free(&z.of);
        continue;
    fail:
        fse_free(&z.ll); fse_free(&z.ml); fse_free(&z.of);
        if (!*vex_zstd_last_error()) vex_set_error("zstd decode error");
        return -1;
    }
    return 0;
}

/* Public entry */

int vex_zstd_decode(const uint8_t *in, size_t len, size_t max_out, uint8_t **out, size_t *out_len) {
    if (!out || !out_len) { vex_set_error("zstd: missing output arguments"); return -1; }
    *out = NULL;
    *out_len = 0;
    if (!in || !len) { vex_set_error("zstd: empty input"); return -1; }

    vex_buf decoded;
    vex_buf_init(&decoded, max_out ? max_out : (size_t)-1);
    if (zstd_decode_into(in, len, &decoded)) {
        int over = decoded.over;
        vex_buf_free(&decoded);
        if (!*vex_error) vex_set_error("zstd: malformed frame");
        return over ? -2 : -1;
    }
    if (!decoded.data) {
        /* Empty frame: hand back memory the caller can still free uniformly. */
        decoded.data = malloc(1);
        if (!decoded.data) { vex_set_error("zstd: out of memory"); return -1; }
    }
    *out = decoded.data;
    *out_len = decoded.len;
    return 0;
}

void vex_zstd_free(void *p) { free(p); }
