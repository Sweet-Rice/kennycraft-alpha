#pragma once
#include <stdint.h>
/* ---- lane control: custom-0 (0x0B) ---- */
static inline uint32_t lane_id(void) {
    uint32_t r;
    asm volatile(".insn r 0x0B, 0, 0, %0, x0, x0" : "=r"(r));
    return r;
}
static inline void lmask(uint32_t keep) {
    asm volatile(".insn r 0x0B, 1, 0, x0, %0, x0" :: "r"(keep) : "memory");
}
static inline uint32_t ballot(uint32_t pred) {
    uint32_t r;
    asm volatile(".insn r 0x0B, 3, 0, %0, %1, x0" : "=r"(r) : "r"(pred) : "memory");
    return r;
}
static inline uint32_t mask_get(void) {
    uint32_t r;
    asm volatile(".insn r 0x0B, 5, 0, %0, x0, x0" : "=r"(r) :: "memory");
    return r;
}
static inline void mask_set(uint32_t m) {
    asm volatile(".insn r 0x0B, 6, 0, x0, %0, x0" :: "r"(m) : "memory");
}
static inline void mask_all(void) {
    asm volatile(".insn r 0x0B, 7, 0, x0, x0, x0" ::: "memory");
}
/* ---- divergence: custom-2 (0x5B) ---- */
#define GPU_IF(cond, else_lbl) \
    asm goto(".insn b 0x5B, 0, %0, x0, %l1" :: "r"(cond) : "memory" : else_lbl)
#define GPU_ELSE(end_lbl) \
    asm goto(".insn b 0x5B, 1, x0, x0, %l0" ::: "memory" : end_lbl)
#define GPU_ENDIF() \
    asm volatile(".insn r 0x5B, 2, 0, x0, x0, x0" ::: "memory")
/* usage:
 *   GPU_IF(hit, L_else);
 *       color = shade(...);
 *   L_else:
 *   GPU_ELSE(L_end);
 *       color = sky(row);
 *   L_end:
 *   GPU_ENDIF();
 * The label goes BEFORE GPU_ELSE so a skipped then-body still runs DELSE.
 */
/* ---- ray unit: custom-1 (0x2B) ---- */
#define VSET(field, v) \
    asm volatile(".insn r 0x2B, 0, " #field ", x0, %0, x0" :: "r"(v) : "memory")
#define VGET(field) ({ uint32_t _r; \
    asm volatile(".insn r 0x2B, 2, " #field ", %0, x0, x0" : "=r"(_r) :: "memory"); _r; })
static inline uint32_t vtrace(uint32_t max_steps) {
    uint32_t r;
    asm volatile(".insn r 0x2B, 1, 0, %0, %1, x0" : "=r"(r) : "r"(max_steps) : "memory");
    return r;
}
/* ---- helpers ---- */
static inline int32_t sel(uint32_t c, int32_t a, int32_t b) {   /* branchless c ? a : b */
    int32_t m = -(int32_t)(c != 0);
    asm("" : "+r"(m));
    return b ^ ((a ^ b) & m);
}
#define gpu_keep(x) asm volatile("" : "+r"(x))   /* pin a value before a mask change */
