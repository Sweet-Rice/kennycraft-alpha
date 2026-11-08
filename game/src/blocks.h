// blocks.h — block types (frozen list from the plan).
#ifndef KC_BLOCKS_H
#define KC_BLOCKS_H

enum {
    B_AIR = 0, B_GRASS, B_DIRT, B_STONE, B_COBBLE, B_LOG, B_LEAVES, B_PLANKS,
    B_SAND, B_BRICK, B_BEDROCK,
    B_NETHERRACK, B_LAVA, B_GLOWSTONE, B_OBSIDIAN, B_PORTAL,
    B_COUNT
};

#define WORLD_CHUNKS   256     // 256 x 256 chunks
#define CHUNK_W        16
#define BUILD_MAX_Y    28      // highest y the player may place into; keeps the eye inside the window
#define WORLD_SEED     0x4B43u // "KC"
// The Nether is the east strip of the same world: chunks from here on get Nether terrain, so
// storage, tags and the window need nothing new. A bedrock wall at x = NETHER_X0 keeps the two
// apart: portals (or P) are the only way across.
// Limit: shared coordinate space; a real dimension id in the chunk id if the strip ever matters
#define NETHER_X0      3072

#endif
