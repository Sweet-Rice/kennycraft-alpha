#pragma once
#include <stdint.h>
#define ARENA_SIZE (8 * 1024)   /* bytes, same on laptop and chip */
void     arena_reset(void);             /* top of every frame */
void    *arena_alloc(uint32_t bytes);   /* 4-byte aligned, halts when full */
uint32_t arena_high_water(void);        /* peak bytes used since boot */
