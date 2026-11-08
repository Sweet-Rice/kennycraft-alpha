// From Bennett's bench/kc-bench branch (sw/arena.h), unchanged. API per issue #2.
#pragma once
#include <stdint.h>
#ifndef ARENA_SIZE               /* Kenny: overridable (make ARENA_SIZE=n), still one value per build */
#define ARENA_SIZE (8 * 1024)   /* bytes, same on laptop and chip */
#endif
void     arena_reset(void);             /* top of every frame */
void    *arena_alloc(uint32_t bytes);   /* 4-byte aligned, halts when full */
uint32_t arena_high_water(void);        /* peak bytes used since boot */
