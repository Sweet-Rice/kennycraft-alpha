// chunks.h — world memory API for game code (issue #2). Called only from game code (lane 0),
// never from the render kernel.
//
// World: 4,096 x 32 x 4,096 blocks = 256 x 256 chunks of 16 x 32 x 16 (4 KB each in DDR3).
// BRAM holds a 4 x 4-chunk window; chunk (cx, cz) always lives in slot (cx & 3, cz & 3).
// All coordinates here are absolute block coordinates.
#ifndef KC_CHUNKS_H
#define KC_CHUNKS_H
#include <stdint.h>

#ifndef KC_GEN_BITMAP
#define KC_GEN_BITMAP 0     // 1: issue #2's 8 KB "generated" bitmap; 0: tags inside the DDR3 chunks
#endif
#ifndef KC_TAG_PERSIST
#define KC_TAG_PERSIST 0    // 1: tags without the boot nonce, so stored chunks survive a reset
#endif

// ---- high level ------------------------------------------------------------------------
// Once per frame. Keeps the player 24-40 blocks from every window edge: evicts (storing
// dirty chunks), loads chunks stored this boot, generates new ones (at most one per frame
// after startup), and moves WIN_ORIGIN once the whole new edge is in.
void    world_update(int px, int pz);
uint8_t world_get(int x, int y, int z);        // air if not loaded, bedrock below y = 0
void    world_set(int x, int y, int z, uint8_t t);  // ignored if not loaded; marks dirty
int     world_corner_x(void);                  // absolute corner of the committed window
int     world_corner_z(void);                  // (matches WIN_ORIGIN; multiples of 16)

// ---- low level (MMIO 0x30-0x3C) ----------------------------------------------------------
uint32_t chunk_load(int cx, int cz);           // CHUNK_CMD bit 31 = 0; returns a ticket
uint32_t chunk_store(int cx, int cz);          // CHUNK_CMD bit 31 = 1; returns a ticket
int      chunk_done(uint32_t ticket);          // CHUNK_DONE has passed the ticket
void     chunk_wait(uint32_t ticket);
void     slot_valid(int cx, int cz, int on);   // read-modify-write SLOT_VALID
void     window_origin(int corner_x, int corner_z);   // WIN_ORIGIN

// ---- Kenny extras (not in issue #2) --------------------------------------------------------
int     world_ready(void);                     // window complete and committed
int     world_storage_ok(void);                // DDR3 calibrated (else every chunk is generated)
int     world_slot_chunk(int slot);            // chunk id (cz * 256 + cx) + 1 if loaded, else 0
int     world_loaded(int x, int z);            // block column's chunk is loaded and valid
uint32_t world_stats_generated(void);          // chunks generated since boot
uint32_t world_stats_tag_hits(void);           // loads whose tag matched (0 with KC_GEN_BITMAP)
uint32_t world_stats_tag_misses(void);         // loads with no matching tag, then generated
#ifdef KC_HOST
uint32_t world_boot_count(void);              // laptop: this boot's DDR3 boot counter
uint32_t world_boot_nonce(void);              // laptop: this boot's chunk tag nonce
void    world_reboot(void);                    // laptop: forget all state, as a reset would
#endif

#endif
