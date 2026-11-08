// Doom's use of the on-chip RAMs (doom/README.md, Memory). The bootloader's
// data and stack in dmem are dead once Doom runs, so all of dmem is Doom's.
#ifndef KC_MEM_H
#define KC_MEM_H

// dmem 0x1000_0000..0x1000_5FFF (BRAM, one bus access per word; lanes on the
// same word share it)
#define KC_DMEM_COLORMAPS       0x10000000u   // COLORMAP lump, 34 x 256 bytes
#define KC_DMEM_COLORMAPS_SIZE  0x2200

#endif
