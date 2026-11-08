// kc_lanes.h — lane control used by the kernel. Same names and encodings as Bennett's
// sw/gpu.h (lane_id, lmask, ballot, mask_get, mask_set, mask_all); sel() stays in fixed.h
// because gpu.h's sel compiles to a branch under clang.
// KC_LANES == 1 (laptop, and the Stage 0 chip that has no custom instructions yet):
//   a software mask emulates LMASK / BALLOT / MASKGET / MASKSET for a single lane.
// KC_LANES == 8 (Stage 1+): the real custom-0 instructions (Interfaces, Lane control).
//   If Bennett's gpu.h lands with the same names, include it instead and delete the
//   KC_LANES == 8 block below.
#ifndef KC_LANES_H
#define KC_LANES_H
#include <stdint.h>

#ifndef KC_LANES
#define KC_LANES 1
#endif

#if KC_LANES == 1
extern uint32_t kc_soft_mask;   // defined in trace.c
static inline uint32_t lane_id(void)       { return 0; }
static inline void     lmask(uint32_t c)  { if (!c) kc_soft_mask = 0; }
static inline uint32_t ballot(uint32_t c) { return (kc_soft_mask && c) ? 1u : 0u; }
static inline uint32_t mask_get(void)      { return kc_soft_mask; }
static inline void     mask_set(uint32_t m){ kc_soft_mask = m & 1u; }
static inline void     mask_all(void)      { kc_soft_mask = 1u; }

#elif KC_LANES == 8
// custom-0 = 0x0B, R-type, funct7 = 0. funct3: 000 LANEID, 001 LMASK, 011 BALLOT,
// 101 MASKGET, 110 MASKSET, 111 MASKALL.
static inline uint32_t lane_id(void) {
    uint32_t r; __asm__ volatile(".insn r 0x0B, 0, 0, %0, x0, x0" : "=r"(r)); return r;
}
static inline void lmask(uint32_t c) {
    __asm__ volatile(".insn r 0x0B, 1, 0, x0, %0, x0" :: "r"(c) : "memory");
}
static inline uint32_t ballot(uint32_t c) {
    uint32_t r; __asm__ volatile(".insn r 0x0B, 3, 0, %0, %1, x0" : "=r"(r) : "r"(c) : "memory"); return r;
}
static inline uint32_t mask_get(void) {
    uint32_t r; __asm__ volatile(".insn r 0x0B, 5, 0, %0, x0, x0" : "=r"(r) :: "memory"); return r;
}
static inline void mask_set(uint32_t m) {
    __asm__ volatile(".insn r 0x0B, 6, 0, x0, %0, x0" :: "r"(m) : "memory");
}
static inline void mask_all(void) {
    __asm__ volatile(".insn r 0x0B, 7, 0, x0, x0, x0" ::: "memory");
}
// QRCP rd, rs1 (custom-0 funct3 010, D22): rd = qrcp(rs1) in each active lane, bit-exact
// with fixed.c. Needs a core built with HAS_QRCP = 1 (the Stage 2 top); fixed.h uses it
// for qrcp() when built with KC_QRCP=1.
static inline int32_t qrcp_hw(int32_t x) {
    int32_t r; __asm__ volatile(".insn r 0x0B, 2, 0, %0, %1, x0" : "=r"(r) : "r"(x)); return r;
}
#else
#error "KC_LANES must be 1 or 8"
#endif

#endif
