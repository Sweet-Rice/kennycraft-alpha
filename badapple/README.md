# Bad Apple

Bad Apple!! (6,572 frames, 30 fps) played in black and white at 160 × 120 on
the existing `top_s2p100` bitstream (pipelined 8-lane core at 100 MHz, three
framebuffers, DDR3 chunk store). **No RTL was changed and nothing was
rebuilt in Vivado.** Everything here is software, memory images patched into
that bitstream with `fpga/patch_bit.sh`, and two bench-only additions to the
Verilator harness.

Base bitstream: `build_20261108_115553_1f9ddd` (`top_s2p100`, `top.bit`
sha256 `f6675032…c67cae4`). Its RTL sources are identical to this branch's
`rtl/`.

## How it works

There's no UART or JTAG data path on this bitstream, and the CPU can't address
DDR3. The only way to get data onto the chip is the memories `updatemem` can
patch. So the video goes to the board through several bitstreams, and the
DDR3 chunk store holds it in between.

1. **Codec** (`ba_codec.h`, shared by the host and the chip). Each frame is
   thresholded to 1 bit per pixel. Every pixel is coded with an adaptive binary
   range coder (the LZMA bit coder: 11-bit probabilities, adaptation shift 3).
   Its context is 2,048 states built from 11 known pixels: 6 in this frame
   (W, WW, NW, N, NE, NN) and 5 in the previous one (PW, P, PE, PN, PS).
   The whole video is 15.8 MB raw at 1 bpp and codes to **498,253 bytes**
   (75.8 B per frame).
2. **DDR3 image** (`ba_chip.h`). A header chunk (magic, frame count, a
   checksum per chunk) plus the stream, in 4 KB chunks: 123 chunks, 503,808
   bytes. Chunk n uses world-window slot n mod 16, at chunk coordinates
   cz ≥ 128 (DDR3 ≥ 128 MB).
3. **Loader passes** (`loader.c`, 16 images). Each image carries a 32,388-byte
   slice of the DDR3 image: 24,196 B in data memory (0x0100–0x5FFF) and
   8,192 B in texture memory (two 4-bit cells per byte). The loader writes the
   slice into world-window slots, stores each slot to DDR3 with `CHUNK_CMD`,
   then reloads every chunk and compares it. Screen: one bar per pass (this
   pass white), one box per chunk, and a green border (all intact) or a red one.
4. **Player** (`player.c`). Loads the header and checksums every chunk
   (green or red box per chunk), and refuses to play if any chunk is damaged.
   Otherwise it streams the chunks through the 16 world slots as a ring,
   reloading a slot as soon as its chunk is used up. It decodes each frame
   into the back framebuffer with `FB_MODE` = 1 (160 × 120, scaled to the
   VGA output), one frame every two vsyncs (30 fps), and loops forever.

The voxel game isn't running, so the world window, texture memory and data
memory are all free for this.

| Memory | Use |
| --- | --- |
| imem (32 KB) | Loader 2.5 KB, player 3.4 KB |
| dmem 0x0100–0x5FFF | Loader: slice payload. Player: probabilities 4 KB, two frame planes 6.9 KB, header copy 4 KB |
| dmem 0x6000–0x7FFF | Stack only (distributed RAM, not patchable; left empty like the bitstream's) |
| tex (16 K × 4 bit) | Loader: rest of the slice |
| world window (16 × 4 KB slots) | Staging for DDR3 chunk stores and loads |
| DDR3 | The whole image |
| palette | Written at runtime (0 black, 1 white, plus status colours) |

## Files

| File | What |
| --- | --- |
| `ba_codec.h` | Context model, range decoder, plane layout |
| `ba_tool.c` | Host encoder, plus `check`: decodes the whole stream with the chip's decoder and compares every frame |
| `ba_chip.h` | MMIO, chunk to slot and DDR3 mapping, nibble access, chunk checksum, status drawing |
| `loader.c` | One loader pass |
| `player.c` | Chunk check and playback |
| `build.py` | Video → codec → DDR3 image → 16 pass images + player image (`kc_imem.hex`, `kc_dmem.hex`, `textures.hex`) |
| `sim.py` | Runs every pass and then the player in kcvl, and compares frames with the reference |
| `board.sh` | Patches every image into the base bitstream, then programs the passes and the player back to back |

## Build

```sh
python3 badapple/build.py <bad_apple.mp4> /tmp/ba/img      # ffmpeg, zig cc, the pinned RISC-V GCC
```

The source used is the 480 × 360, 30 fps upload at
<https://archive.org/details/bad-apple-pv-360p>. The video itself isn't in the
repo.

## Board

```sh
FPGA_STATE=<fpga-mcp state dir> sh badapple/board.sh \
    <.fpga-state/builds/build_20261108_115553_1f9ddd> /tmp/ba/img /tmp/ba/bits
```

Prebuilt: the **Bad Apple** release has `bad_apple.zip`, which holds the 17
patched bitstreams (`SHA256SUMS`) and their memory images. Program
`bad_apple_pass_01.bit` through `bad_apple_pass_16.bit` in order, a couple of
seconds apart, then `bad_apple_player.bit`.

Post `taking-board` on #1 first. This hasn't been run on the board yet. It
assumes **DDR3 keeps its contents while the FPGA is reprogrammed**: nothing
refreshes it during configuration, and the MIG recalibrates afterwards. The
player's chunk-check screen answers that directly. All green means the data
survived. Red boxes show which chunks didn't, by pass (each pass covers about
8 chunks).

## Verilator

Bench-only additions in `tb/harness` (not part of any bitstream):

- `stubs/mig_ddr3.sv`: `+ddr_load=FILE` and `+ddr_save=FILE` fill and dump
  the DDR3 model (`$readmemh` / `$writememh` of its sparse array), so DDR3
  carries from one kcvl run to the next the way it has to across reprogramming.
- `main.cpp`: kcvl passes `+` plusargs through to the RTL instead of
  rejecting them.

```sh
make vl-build STAGE=2 PIPELINED=1 TEX_HEX=/tmp/ba/run/textures.hex VL_MDIR=out/vl-ba
python3 badapple/sim.py /tmp/ba/img /tmp/ba/run 60
```

### Results

- Host: the chip's decoder reproduces all 6,572 frames bit for bit
  (`ba_tool check`).
- Verilator, same RTL as the base bitstream (`STAGE=2 PIPELINED=1`):
  - All 16 loader passes reported `ok`, about 3.2 M cycles each.
  - The player found all 122 data chunks intact.
  - The first 60 video frames match the reference pixel for pixel.
  - Frames come exactly 1,680,000 cycles apart, which is two vsyncs at the
    bench's clock ratio, so decoding never fell behind. On the board two
    vsyncs at 100 MHz are 3.36 M cycles.
- Not run in Verilator: frames after 60, including the first reload of a ring
  slot (around frame 1,098).
- `updatemem` patched all 16 passes and the player into the base bitstream.
