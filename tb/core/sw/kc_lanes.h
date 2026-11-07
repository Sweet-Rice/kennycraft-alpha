/* Custom instructions for the tb/core Stage 1 test programs, as Tai_2
   section 1 writes them (.insn forms). */
#define LANEID(rd)      .insn r 0x0B, 0, 0, rd, x0, x0
#define LMASK(rs)       .insn r 0x0B, 1, 0, x0, rs, x0
#define BALLOT(rd, rs)  .insn r 0x0B, 3, 0, rd, rs, x0
#define MASKGET(rd)     .insn r 0x0B, 5, 0, rd, x0, x0
#define MASKSET(rs)     .insn r 0x0B, 6, 0, x0, rs, x0
#define MASKALL         .insn r 0x0B, 7, 0, x0, x0, x0
#define DIF(rs, label)  .insn b 0x5B, 0, rs, x0, label
#define DELSE(label)    .insn b 0x5B, 1, x0, x0, label
#define DENDIF          .insn r 0x5B, 2, 0, x0, x0, x0
