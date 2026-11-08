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
// Demo village (make KC_DEMO=1, src/terrain.c): flat grass with its top at DEMO_H, laid out
// around spawn (DEMO_X0, DEMO_Z0) toward +z, the way the spawn camera faces. The build plot is
// DEMO_PLOT_W square with its cobble border's corner at (DEMO_PLOT_X0, DEMO_PLOT_Z0) from spawn;
// talking to any villager makes the plot the contract zone (src/cr6.c). host/orchestrator.py
// has the same numbers.
#define DEMO_X0        2048
#define DEMO_Z0        2048
#define DEMO_H         14
#define DEMO_PLOT_X0   (-7)
#define DEMO_PLOT_Z0   20
#define DEMO_PLOT_W    14

#endif
