// cr6.c — CR6 UART command link (wiki Shared.md, CR6 / D8). Lane 0 game code only.
//
// Frames, both ways: A5 | len | seq | op | payload (0..7, replies up to 40) | crc8, where
// len counts seq + op + payload and the CRC-8 (poly 0x07, init 0) covers len..payload.
// After each drain the chip sends one STATUS: the result of the last command (the ack),
// the frame number, its credit (RX_DEPTH - RX_RESERVE) and a running count of drained bytes.
// The chip checks everything, so a bad laptop can't corrupt the world: edits only inside the
// 16^3 zone the player set (by talking to a villager), y 1..28, block types 1..9, never into
// the player, a ready slot, one edit command and 256 cells per frame, and a cell bucket.
#include "cr6.h"
#include "game.h"
#include "blocks.h"
#include "chunks.h"
#include "entity.h"
#include "render.h"
#include "kc_hal.h"

enum { HELLO = 0x01, BYE = 0x02, PLACE = 0x10, BREAK = 0x11, FILL = 0x12, SPAWN = 0x20, MOVE = 0x21,
       Q_PLAYER = 0x30, Q_BLOCKS = 0x31, Q_ENTITY = 0x33, SET_BALANCE = 0x40, SET_QUOTE = 0x41, SET_CONTRACT = 0x42,
       STATUS = 0x81, HELLO_ACK = 0x82, R_PLAYER = 0x83, R_BLOCKS = 0x84, R_ENTITY = 0x86, EVENT = 0x8F };
enum { R_OK, R_CRC, R_BAD_OP, R_ZONE, R_BAD_BLOCK, R_PROTECTED, R_RATE, R_BUSY, R_NOT_LINKED, R_BAD_ENTITY };
enum { EV_INTERACT = 3, EV_CONFIRM = 4 };

#define SYNC        0xA5
#define CR6_VER     1
#define RX_DEPTH    16
#define RX_RESERVE  4                  // keys already in flight (Tai, CR6 answer 1)
#define ZONE        16
#define MAX_CELLS   256
#define BUCKET_MAX  512
#define BUCKET_FILL 16                 // ponytail: per frame (~256/s at 16 fps); use dt if fps varies a lot
#define TALK_RANGE  Q16(3.0)
#define MOB_RANGE   32

static uint8_t linked, dropping, got, last_seq, last_res, drained, frame_no, edited;
static uint8_t rx[12];
static uint16_t bucket = BUCKET_MAX;
static int16_t zone[3];                // x0, y0, z0 of the player's contract zone
static uint8_t zone_set;
static uint16_t hud_kcn, quote_kcn;
static uint8_t quote_id, contract[3];  // state << 6 | progress, per contractor type

static uint32_t u16(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }

static uint8_t crc8(const uint8_t *p, int32_t n) {
    uint32_t c = 0;
    for (int32_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int32_t k = 0; k < 8; k++) c = (c & 0x80) ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
    }
    return (uint8_t)c;
}

static void tx(uint8_t b) {
    while (hal_mmio_r(MMIO_UART_STATUS) & 2) {}
    hal_mmio_w(MMIO_UART_TX, b);
}

static void send(uint8_t seq, uint8_t op, const uint8_t *p, int32_t n) {
    uint8_t f[44];
    f[0] = SYNC; f[1] = (uint8_t)(n + 2); f[2] = seq; f[3] = op;
    for (int32_t i = 0; i < n; i++) f[4 + i] = p[i];
    f[n + 4] = crc8(f + 1, n + 3);
    for (int32_t i = 0; i < n + 5; i++) tx(f[i]);
}

static void event(uint8_t code, uint32_t arg) {
    uint8_t p[3] = { code, (uint8_t)arg, (uint8_t)(arg >> 8) };
    send(0, EVENT, p, 3);
}

// ---------------------------------------------------------------- commands ---------------
static int32_t edit_box(uint32_t x, uint32_t y, uint32_t z, uint32_t sx, uint32_t sy, uint32_t sz, uint32_t t, int32_t place) {
    uint32_t cells = sx * sy * sz;
    if (t > 9) return R_BAD_BLOCK;                                  // bedrock and 11..15 never
    if (edited || cells > bucket) return R_RATE;
    if (cells > MAX_CELLS) return R_BAD_OP;
    if (!zone_set || x < (uint32_t)zone[0] || z < (uint32_t)zone[2] || y < (uint32_t)zone[1]
        || x + sx > (uint32_t)zone[0] + ZONE || z + sz > (uint32_t)zone[2] + ZONE
        || y + sy > (uint32_t)zone[1] + ZONE || y < 1 || y + sy - 1 > BUILD_MAX_Y) return R_ZONE;
    if (!world_loaded((int)x, (int)z) || !world_loaded((int)(x + sx - 1), (int)z)
        || !world_loaded((int)x, (int)(z + sz - 1)) || !world_loaded((int)(x + sx - 1), (int)(z + sz - 1)))
        return R_BUSY;
    if (t && player_overlaps((int32_t)x, (int32_t)y, (int32_t)z, (int32_t)(x + sx - 1), (int32_t)(y + sy - 1), (int32_t)(z + sz - 1)))
        return R_PROTECTED;
    if (place && world_get((int)x, (int)y, (int)z) != B_AIR) return R_PROTECTED;   // PLACE only into air
    if (!t && sx * sy * sz == 1 && world_get((int)x, (int)y, (int)z) == B_BEDROCK) return R_PROTECTED;
    for (uint32_t j = 0; j < sy; j++)
        for (uint32_t k = 0; k < sz; k++)
            for (uint32_t i = 0; i < sx; i++) {
                uint8_t old = world_get((int)(x + i), (int)(y + j), (int)(z + k));
                if (old == B_BEDROCK || (t && old != B_AIR)) continue;   // FILL never overwrites
                world_set((int)(x + i), (int)(y + j), (int)(z + k), (uint8_t)t);
            }
    edited = 1;
    bucket = (uint16_t)(bucket - cells);
    return R_OK;
}

// Entity positions: x, z in 1/16 block, y in 1/8 block. Within 32 blocks of the player.
static int32_t near_player(uint32_t x16, uint32_t z16) {
    int32_t dx = (int32_t)(x16 >> 4) - qfloor(kc_me.pos[0]), dz = (int32_t)(z16 >> 4) - qfloor(kc_me.pos[2]);
    return iabs(dx) <= MOB_RANGE && iabs(dz) <= MOB_RANGE;
}

static int32_t run(uint8_t seq, uint8_t op, const uint8_t *p, int32_t n) {
    switch (op) {
    case BYE:
        linked = 0;
        return R_OK;
    case PLACE: if (n != 6) break;
        if (p[5] == 0) return R_BAD_BLOCK;
        return edit_box(u16(p), p[4], u16(p + 2), 1, 1, 1, p[5], 1);
    case BREAK: if (n != 5) break;
        return edit_box(u16(p), p[4], u16(p + 2), 1, 1, 1, 0, 0);
    case FILL: if (n != 7) break;
        return edit_box(u16(p), p[4], u16(p + 2), (p[5] & 15u) + 1, (p[6] & 15u) + 1, (p[5] >> 4) + 1u, p[6] >> 4, 0);
    case SPAWN: {
        if (n != 6) break;
        uint32_t id = p[0] & 15u, kind = p[0] >> 4, x = u16(p + 1), z = u16(p + 3);
        if (id != (uint32_t)entity_count() || kind >= ENT_KINDS || !near_player(x, z)) return R_BAD_ENTITY;
        return entity_add((int32_t)kind, (q16)(x << 12), (q16)((uint32_t)p[5] << 13), (q16)(z << 12), 0) < 0 ? R_BAD_ENTITY : R_OK;
    }
    case MOVE: {
        if (n != 5) break;
        // id byte: bit 7 set = teleport there at once instead of walking
        uint32_t x = u16(p + 1), z = u16(p + 3), id = p[0] & 0x7Fu;
        if (id >= (uint32_t)entity_count() || !near_player(x, z)) return R_BAD_ENTITY;
        if (p[0] & 0x80u) entity_teleport((int32_t)id, (q16)(x << 12), (q16)(z << 12));
        else entity_move((int32_t)id, (q16)(x << 12), (q16)(z << 12));
        return R_OK;
    }
    case Q_PLAYER: {
        if (n != 0) break;
        uint32_t x = (uint32_t)kc_me.pos[0] >> 12, z = (uint32_t)kc_me.pos[2] >> 12, y = (uint32_t)kc_me.pos[1] >> 13;
        uint8_t r[5] = { (uint8_t)x, (uint8_t)(x >> 8), (uint8_t)z, (uint8_t)(z >> 8), (uint8_t)y };
        send(seq, R_PLAYER, r, 5);
        return R_OK;
    }
    case Q_BLOCKS: {
        // x, z, y, (sx-1) | (sy-1) << 2 | (sz-1) << 4 (at most 4 x 4 x 4). Reply: one nibble per
        // cell, low nibble first, x fastest, then z, then y (the layout kc_agents/cr6.py sends).
        if (n != 6 || (p[5] & 0xC0)) break;
        uint32_t x = u16(p), z = u16(p + 2), y = p[4], sx = (p[5] & 3u) + 1, sy = ((p[5] >> 2) & 3u) + 1, sz = (p[5] >> 4) + 1u;
        uint8_t r[32] = { 0 };
        uint32_t c = 0;
        for (uint32_t j = 0; j < sy; j++)
            for (uint32_t k = 0; k < sz; k++)
                for (uint32_t i = 0; i < sx; i++, c++)
                    r[c >> 1] |= (uint8_t)(world_get((int)(x + i), (int)(y + j), (int)(z + k)) << ((c & 1) << 2));
        send(seq, R_BLOCKS, r, (int32_t)((c + 1) >> 1));
        return R_OK;
    }
    case Q_ENTITY: {                                            // id -> id, x, z (1/16), y (1/8), state
        if (n != 1) break;
        if (p[0] >= entity_count()) return R_BAD_ENTITY;
        q16 e[3];
        int32_t facing;
        entity_get(p[0], e, &facing);
        uint32_t x = (uint32_t)e[0] >> 12, z = (uint32_t)e[2] >> 12, y = (uint32_t)e[1] >> 13;
        uint8_t r[7] = { p[0], (uint8_t)x, (uint8_t)(x >> 8), (uint8_t)z, (uint8_t)(z >> 8), (uint8_t)y, 0 };
        send(seq, R_ENTITY, r, 7);                              // state byte: 0 until STATE exists
        return R_OK;
    }
    case SET_BALANCE: if (n != 2) break;
        hud_kcn = (uint16_t)u16(p);
        return R_OK;
    case SET_QUOTE: if (n != 3) break;
        quote_id = p[0]; quote_kcn = (uint16_t)u16(p + 1);
        return R_OK;
    case SET_CONTRACT: if (n != 2 || p[0] > 2) break;
        contract[p[0]] = p[1];
        return R_OK;
    }
    return R_BAD_OP;
}

static void frame_done(void) {
    uint8_t seq = rx[2], op = rx[3];
    int32_t n = rx[1] - 2;
    if (op == HELLO) {
        if (n != 3 || rx[4] != 'K' || rx[5] != 'C') { last_res = R_BAD_OP; return; }
        uint32_t boot = world_boot_count();
        uint8_t a[7] = { CR6_VER, RX_DEPTH, 1, ENT_MAX, 0, (uint8_t)boot, (uint8_t)(boot >> 8) };
        linked = 1;
        send(seq, HELLO_ACK, a, 7);
        last_seq = seq; last_res = R_OK;
        return;
    }
    if (!linked) { last_seq = seq; last_res = R_NOT_LINKED; return; }
    if (seq == last_seq && op >= PLACE && op <= MOVE) return;     // a retransmit: ack again, don't redo
    last_seq = seq;
    last_res = (uint8_t)run(seq, op, rx + 4, n);
}

// ---------------------------------------------------------------- public -----------------
int32_t cr6_byte(uint8_t b) {
    drained++;
    if (dropping) return 1;
    if (!got) {
        if (b != SYNC) return 0;
        rx[got++] = b;
        return 1;
    }
    rx[got++] = b;
    int32_t bad_len = got == 2 && (b < 2 || b > 9);
    if (!bad_len) {
        if (got < rx[1] + 3) return 1;
        if (crc8(rx + 1, rx[1] + 1) == rx[rx[1] + 2]) { got = 0; frame_done(); return 1; }
    }
    // Bad frame: drop the rest of this drain and let go of every key (a lost key-up must
    // not leave W stuck). The laptop resends the keys it still holds and the command.
    got = 0;
    dropping = 1;
    kc_me.held = 0;
    last_res = R_CRC;
    return 1;
}

void cr6_end_drain(void) {
    dropping = 0;
    edited = 0;
    bucket = (uint16_t)imin(BUCKET_MAX, bucket + BUCKET_FILL);
    if (!linked) return;
    uint8_t s[4] = { last_res, frame_no++, RX_DEPTH - RX_RESERVE, drained };
    send(last_seq, STATUS, s, 4);
}

void cr6_key(uint8_t code) {
    if (!linked) return;
    if (code == KEY_Y || code == KEY_N) {
        if (quote_id) event(EV_CONFIRM, quote_id | (code == KEY_Y ? 0x100u : 0));
        return;
    }
    // KEY_E: talk to the nearest entity within reach, and mark the contract zone around
    // the player (the laptop can't set or widen it).
    int32_t best = -1;
    q16 best_d = TALK_RANGE;
    for (int32_t i = 0; i < entity_count(); i++) {
        q16 e[3];
        int32_t facing;
        entity_get(i, e, &facing);
        q16 d = imax(iabs(e[0] - kc_me.pos[0]), iabs(e[2] - kc_me.pos[2]));
        if (d <= best_d && iabs(e[1] - kc_me.pos[1]) < Q16(2.0)) { best = i; best_d = d; }
    }
    if (best < 0) return;
    zone[0] = (int16_t)(qfloor(kc_me.pos[0]) - ZONE / 2);
    zone[1] = (int16_t)imax(1, qfloor(kc_me.pos[1]) - 4);
    zone[2] = (int16_t)(qfloor(kc_me.pos[2]) - ZONE / 2);
    zone_set = 1;
    event(EV_INTERACT, (uint32_t)best);
}

// ---------------------------------------------------------------- HUD --------------------
// 3x5 glyphs, rows top to bottom, 3 bits each (bit 2 = left column).
static const uint16_t font[] = {
    0x7B6F, 0x2C97, 0x73E7, 0x73CF, 0x5BC9, 0x79CF, 0x79EF, 0x7249, 0x7BEF, 0x7BCF,   // 0-9
    0x5BAD, 0x7927, 0x6B6D, 0x5BD2, 0x12A4, 0x72C2,                                  // K C N Y / ?
};
static int32_t glyph(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    return c == 'K' ? 10 : c == 'C' ? 11 : c == 'N' ? 12 : c == 'Y' ? 13 : c == '/' ? 14 : c == '?' ? 15 : -1;
}

static void put(int32_t x, int32_t y, uint8_t v) { hal_fb_put((uint32_t)(y * FB_STRIDE + x), v); }

static void rect(int32_t x, int32_t y, int32_t w, int32_t h, uint8_t c) {
    for (int32_t j = 0; j < h; j++)
        for (int32_t i = 0; i < w; i++) put(x + i, y + j, c);
}

// Text on a black plate, s = pixel scale. Returns the width drawn.
static int32_t text(int32_t x, int32_t y, int32_t s, const char *str, uint8_t c) {
    int32_t n = 0;
    while (str[n]) n++;
    rect(x - s, y - s, n * 4 * s + s, 7 * s, PIX(COLOR_BLACK, 0, 0));
    for (int32_t i = 0; i < n; i++) {
        int32_t g = glyph(str[i]);
        if (g < 0) continue;
        for (int32_t r = 0; r < 5; r++)
            for (int32_t col = 0; col < 3; col++)
                if ((font[g] >> (14 - r * 3 - col)) & 1) rect(x + (i * 4 + col) * s, y + r * s, s, s, c);
    }
    return n * 4 * s;
}

// Decimal without a divide (the chip has no DIV): subtract powers of ten.
static char *num(char *o, uint32_t v) {
    static const uint16_t p10[] = { 10000, 1000, 100, 10, 1 };
    int32_t any = 0;
    for (int32_t i = 0; i < 5; i++) {
        char d = '0';
        while (v >= p10[i]) { v -= p10[i]; d++; }
        if (d != '0' || any || i == 4) { *o++ = d; any = 1; }
    }
    return o;
}

void cr6_draw_hud(int32_t W) {
    if (!linked) return;
    int32_t s = W == 320 ? 2 : 1, y = 3 * s;
    uint8_t white = PIX(COLOR_WHITE, 0, 0), gold = PIX(kc_face_color[B_SAND * 3], 0, 0);
    char b[16], *o = num(b, hud_kcn);
    *o++ = ' '; *o++ = 'K'; *o++ = 'C'; *o++ = 'N'; *o = 0;
    text(3 * s, y, s, b, gold);
    y += 8 * s;
    if (quote_id) {
        o = num(b, quote_kcn);
        const char *q = "? Y/N";
        while (*q) *o++ = *q++;
        *o = 0;
        text(3 * s, y, s, b, white);
        y += 8 * s;
    }
    for (int32_t t = 0; t < 3; t++) {                          // builder, miner, farmer
        uint32_t st = contract[t] >> 6, prog = contract[t] & 63;
        if (!st) continue;
        uint8_t fill = st == 3 ? PIX(kc_face_color[B_GRASS * 3], 0, 0) : white;
        rect(2 * s, y, 34 * s, 4 * s, PIX(COLOR_BLACK, 0, 0));
        rect(3 * s, y + s, (int32_t)(st == 3 ? 32 : (prog * 32) >> 6) * s, 2 * s, fill);
        y += 6 * s;
    }
}
