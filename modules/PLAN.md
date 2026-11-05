# PLAN.md: QR decoder project (CS6230)

Living document. Read this first, then the spec PDF. Update the **Status log** and **Decisions** whenever something changes.

- **Due:** Nov 9, 2026, 23:59 IST. **Weight:** 30% of the course.
- **Marks (30):** functional tests 10, verification 5, design-space exploration 10 (>= 4 synthesis iterations with real, quantified improvement), place and route 5.
- **Team:** <name A> / <name B>. Unit owners are listed in the table below.

## Rules for anyone (human or AI) working on this repo

1. **The spec PDF is the source of truth** (`CADForVLSI_2026_Project_Spec.pdf`). If this file and the spec disagree, the spec wins.
2. **Write RTL from the spec, not from `qr_model/`.** The model exists to check the RTL (spec Section 5.2). If RTL is copied from the model, a misreading gets into both and the comparison passes anyway. The person who wrote a unit's model should not also write that unit's RTL.
3. **Do not edit `QRTypes.bsv` or `QRTables.bsv`.** The graders replace them with their own copies.
4. Keep the module name `mkQRDecoder`, its interface and its `(* synthesize *)` attribute. Do not put `always_ready` or `always_enabled` on `start` or `getByte` (C5).
5. All numbers in the reports must be real tool output. No fabricated results.
6. Everyone must understand every line they submit (spec Section 7).
7. Keep the repo **private** until grading is over; submissions are compared against public repositories.

## Repo layout

```
src/                    supplied files: QRTypes.bsv, QRTables.bsv, QRDecoder.bsv (placeholder), TbSample.bsv
modules/                one folder per unit, so two people never overwrite each other
  walker/  format/  reader/   each holds its .bsv, its test bench, check_*.py and run.sh
  PLAN.md               this file (keep ONE copy)
qr_model/               Python reference model (gen_vectors.py makes ~1600 test cases)
```

Run a unit's tests from inside its folder, e.g. `cd modules/reader && ./run.sh` (defaults assume `../../src` and `../../qr_model`).
`reader/run.sh` also needs `../walker` and `../format` and generates test vectors into `vectors/` (needs `segno`).
Build output (`build/`, `vectors/`, `*.out`) must not be committed; keep it in `.gitignore`.

**Submission (spec 6.3):** `<Roll_Number>/{README.md, report.pdf, pd_report.pdf, bsv/, verification/, pd/}`. At the end, copy every design `.bsv` (including `QRTypes`/`QRTables` as supplied) into `bsv/`, the test benches and scripts into `verification/`, and build the zip. Check it in a fresh copy of the handout.

## Key numbers (computed from the supplied tables)

- Version 40: 177x177, **29,648 data modules = 3,706 bytes**. The memory port gives one module per cycle, so a decode takes at least ~29.7k cycles. The design is memory-bound; the RS maths adds comparatively little.
- Worst cases over all versions and levels: up to 30 check bytes per block, 81 blocks, 153 bytes per block, 2,956 data bytes, 2,430 check bytes in total.
- One byte = 8 module reads, so there are 8 cycles of slack per byte while reading.

## Architecture

```
start(size) -> [1 version] -> [2 format] -> [3 walker + unmask] -> byte buffer
                                                                       |
      getByte <- [6 payload parser] <- [5 RS correct] <- [4 de-interleave]
```

**Central decision: where the codeword bytes are kept.** The symbol stores blocks interleaved, but output must be block 0 first. Re-reading memory is legal but there is no cheap jump to the k-th module, so re-reading means re-walking the whole symbol.

**Design knob = buffer size `cap` in bytes** (a type parameter of `QRBlockBuf#(cap)`; legal range 153 to 4095). Each pass keeps as many whole blocks as fit (the group), the top level re-reads the symbol for the next group. Larger buffer = more area, fewer passes. Measured by the unit-4 test (worst case over all 160 version/level pairs; a read pass costs about N*(N-1)+40 cycles):

| cap (bytes) | flop bits | max passes per symbol | worst-case read cycles |
|---|---|---|---|
| 153 (minimum) | 1,224 | 34 | 1,060,528 |
| 300 | 2,400 | 22 | 625,504 |
| 512 | 4,096 | 9 | 280,728 |
| 1024 | 8,192 | 5 | 155,960 |
| 2048 | 16,384 | 2 | 62,384 |
| 3706 (whole symbol) | 29,648 | 1 | 31,192 |

Working default: **1024** (builds in about 95 s in Bluesim). Revisit once the forum gives the cycle limit and once synthesis numbers exist. It is one line to change.

**Behaviours to keep in mind (spec Section 4):**
- Memory answers one cycle after the request, so the reader must save the requested (r, c) and unmask with that saved position.
- `mem.req` is ready only when a module is wanted. `getByte` and `start` use implicit conditions. Output must be held under back-pressure.
- All blocks must pass RS before `done` rises. `failed` may rise at any point, even after bytes were returned (C2).
- The parser needs a one-character holdback, because `last` can only be set once the terminator (or end of data) has been seen.
- Fail on: bad side length, format distance > 3, uncorrectable block, malformed payload.

## Units

| # | Unit | Job | Owner | Status |
|---|---|---|---|---|
| 1 | Walker + mask (`QRWalker.bsv`) | which modules to read, in order; mask test | | **done, verified** |
| 2 | Format decoder (`QRFormat.bsv`) | 15+15 bits to ok / level / mask; Table 1 positions | | **done, verified** |
| 3 | Reader (`QRReader.bsv`) | walker + format reads + mem port + unmask -> codeword bytes | | **done, verified** |
| 4 | Block buffer (`QRBlocks.bsv`) | bytes -> blocks (counters, no division), group planner, block walker, read port | | **done, verified** |
| 5a | GF(2^8) arithmetic (`QRGF.bsv`) | add/multiply/inverse/constants | | **done, verified** |
| 5 | Reed-Solomon (`QRRS.bsv`) | syndromes, Berlekamp-Massey, Chien, Forney, verify | | **done, verified** |
| 6 | Payload parser | corrected bytes -> characters, `last` flag | | not started |
| 7 | Top level (`mkQRDecoder`) | `start` / `getByte` / `failed` / `done`, controller | | not started |

Suggested build order: 1, 2, 3, 4, 5a, 5, 6, 7 (6 and 7 remain). Test each unit against the model before connecting it.

### Unit 1 contract (done)

```
isFunctionModule(n, ver, alignParams(ver), r, c) -> Bool     // pure
maskInverts(mask3, r, c)                         -> Bool     // pure, True = module was inverted
interface QRWalker:
  start(Coord n, UInt#(6) ver)                   // n = 17+4*ver, already validated; restarts any walk
  next() -> (row, col)                           // implicit condition: ready only on a data module
  busy()                                         // True from the cycle after start until last module taken
```
- Visits data modules in the spec's zigzag order; function modules are stepped over without being offered.
- Costs about 1 cycle per skipped function module (v40: 31,153 cycles for 29,648 modules; v1: 421 for 208).
- Reader obligation: call `next()`, send the position to `mem.req`, **register that same (r, c)**, and unmask the response one cycle later with `maskInverts` of the registered position.
- Verified: positions identical to `layout.data_order` for all 40 versions; all 8 masks identical to `mask_bit` over 177x177. Run `verification/walker/run.sh` (needs `bsc`; use `BSV_DIR=../../src ./run.sh` while the folder is still called `src`). Expected output: `40/40` and `1416/1416`.

### Unit 2 contract (done)

```
formatPosition(Coord n, Bool second, UInt#(4) i) -> (row, col)   // Table 1: where bit f_i of a copy lives
nearestFormat(Bit#(15) w) -> (Bit#(5) d, UInt#(4) dst)           // closest valid word: d = {level, mask}, dst = distance
decodeFormat(Bit#(15) copy1, Bit#(15) copy2) -> FormatInfo { Bool ok; Bit#(2) level; Bit#(3) mask; }
```
- All three are pure combinational functions. Level is the raw 2-bit field (01=L, 00=M, 11=Q, 10=H), which is what `blockParams(version, levelField)` expects. When `ok` is False, level and mask are 0 and must not be used.
- Copy 1 wins ties; the chosen copy must be within 3 bits, else not ok.
- Reader obligation: read the 15 modules of each copy with `formatPosition`, pack each copy into a `Bit#(15)` with **bit i = f_i**, then call `decodeFormat`. That is 30 reads, and the mask is needed before any data module can be unmasked.
- Baseline is the "all 32 at once" version; the one-candidate-per-cycle version is a later synthesis experiment.
- Verified (`verification/format/run.sh`, expect these three lines): `nearestFormat` 32768/32768 words (all 2^15) identical to the model; `formatPosition` 1200/1200; `decodeFormat` 400000/400000 random pairs (including copy-2 wins and ties at non-zero distance). The 32 words in `QRTables.bsv` were also re-derived from the spec's BCH description, minimum distance 7. A deliberately broken tie rule makes the checker report ~75k mismatches, so the test does catch that bug.

### Unit 3 contract (done)

```
interface QRReader:
  startFormat(Coord n)                       // read both format copies (30 reads)
  formatInfo() -> Maybe#(FormatInfo)         // Invalid until all 30 bits arrived; valid until next start
  startData(Coord n, UInt#(6) ver, Bit#(3) mask)   // walk + read + unmask; restarts from the first module
  getCodeword() -> Bit#(8)                   // next unmasked codeword byte, in symbol order (implicit condition)
  dataFinished() -> Bool                     // all modules read and every byte taken
  interface MemPort mem                      // the top level passes this straight through
```
- Bytes come out in the order they sit in the symbol (k = 0, 1, 2 ... in the spec's interleaving formula), first bit read = MSB. The few remainder bits of some versions never make a byte and are dropped.
- Restart (`startFormat` / `startData`) only while idle: after `formatInfo` is valid, or after `dataFinished`. The top level can call `startData` again for each pass of the group-per-pass design.
- Speed: about 1 module per cycle; a full decode read costs `N*(N-1)+1` cycles plus about 34 (30 format reads and the pipeline). A slow consumer stalls the reader safely: it never loses or repeats a bit.
- How it handles the memory port: it remembers each request and trusts `resp` only in the cycle after (the answer *holds* afterwards); it relies on C4 (a ready request is always taken in the same cycle); a one-position buffer sits between the walker and the port.
- Verified (`modules/reader/run.sh`, expect `PASS`): all 1,614 model cases; 1,563 give identical codeword bytes (about 1.98M bytes), 37 format failures behave as expected, 14 bad sizes skipped; every third case takes bytes at once, the others with random back-pressure. Planted bugs (unmask with the wrong position; ignore a full output slot) are both caught.

### Unit 4 contract (done)

```
interface QRBlockBuf#(cap):
  configure(BlockParams p)            // once per symbol (from blockParams(ver, level))
  planPass(UInt#(7) g0)               // choose the group of blocks g0 .. groupEnd-1 (0 for the first pass)
  groupValid() / groupStart() / groupEnd() / moreGroups()
  putByte(Bit#(8))                    // feed the symbol's bytes in symbol order, ALL p.total of them, every pass
  filled()                            // every byte of this pass has been seen
  rewindBlocks() / advanceBlock() / curBlock() -> BlockDesc{valid, idx, base, dataLen, len}
  readReq(UInt#(12) addr) / readData() // data appears the cycle after readReq and holds; addr = base + position in block
```
- Per pass the top level does: `planPass(g0)`, wait `groupValid`, `rd.startData(...)`, move every reader byte into `putByte`, wait `filled`, then run RS over the group's blocks (`rewindBlocks`, then `curBlock` / `advanceBlock` until `!valid`), then `planPass(groupEnd)` if `moreGroups`. The reader's format step is done once, not per pass.
- Inside a block the bytes are the data bytes followed by the check bytes, which is exactly the order RS wants. Blocks in a group sit back to back; `curBlock.base` gives each one's start address.
- The de-interleaver uses counters only (phase, block, index); the offset of the first long block is remembered from the first data round. The group planner adds blocks greedily until the next one would not fit (at most 81 cycles per pass).
- Storage is plain registers without reset (`mkRegU`) inside `mkByteMem`, with a decoded row/column address. No library memory, so the Verilog needs nothing from bsc's library. Reading is a balanced AND-OR tree.
- Verified (`modules/blocks/run.sh`, expect `PASS` for each size): for all 160 (version, level) pairs, every block's bytes match the spec's formula for k (random data), the groups are contiguous, within the capacity and greedy-maximal. Sizes tested: 153 (34 passes worst), 300, 1024 (5 passes worst). Three planted bugs (wrong offset for the extra byte of long blocks, wrong position for check bytes, planner off by one) are all caught.
- Limits found: bsc elaboration works up to the full 3706 bytes but warns about step counts (limit 1M); the Bluesim C++ for 3706 bytes (3.8 MB) did not compile in 4 GB of RAM, while 1024 compiles in about 95 s. Bigger buffers also make every later test build slower.

### Unit 5a contract (done): GF(2^8)

```
gfXtime(a)          // a * alpha
gfMul(a, b)         // a * b  (8 AND-XOR rows; with a constant argument it shrinks to a few XORs)
gfInv(a)            // 1/a as a^254, gfInv(0) = 0; fully parallel (13 multipliers), a later area optimisation target
alphaPow(Integer k) // alpha^k as a compile-time constant (square-and-multiply)
alphaPowNeg(Integer k) // alpha^-k as a compile-time constant
```
- Field: polynomial 0x11D, alpha = 2, addition is XOR (spec 1.4).
- Verified (`modules/gf/run.sh`, expect `PASS`): all 65,536 products, all 256 inverses (and a*inv(a)=1), times-alpha for all 256 values, alpha^k for k = 0..254 and alpha^-k for k = 0..40, each against an independent re-implementation of the spec's definition AND the model. Changing one bit of the reduction constant is caught (63,901 mismatches).
- Use `alphaPow` only with small compile-time constants: each call costs elaboration steps (bsc stops at 1,000,000 steps in total).

### Unit 5 contract (done): Reed-Solomon

```
mkQRRS(QRBlockBuf#(cap) bb) -> QRRS          // takes the block buffer as an argument and uses its read and write ports
interface QRRS:
  decodeBlock(UInt#(5) ec, BlockDesc d)      // correct block d (from bb.curBlock); ec = check bytes per block (BlockParams.ecLen)
  getData() -> Bit#(8)                       // the corrected DATA bytes of the block, in order (implicit condition)
  done()   // all data bytes of the block have been taken
  failed() // block could not be corrected; no bytes are output for it
```
- Per block the top level does: `rs.decodeBlock(p.ecLen, bb.curBlock)`, move every `getData` byte on to the payload parser, wait for `done` or `failed`, then `bb.advanceBlock`. On `failed` the whole symbol fails (earlier blocks' bytes may already have gone out, which spec C2 allows).
- Steps: syndromes (one read pass, all syndromes updated per byte) -> all zero means clean -> output; else Berlekamp-Massey (L > e/2 fails) -> Omega -> Chien search with Forney (fixes are written back into the buffer, exactly L roots required) -> verify pass (syndromes must now be zero) -> output.
- Baseline cost choices: one shared GF multiplier and one shared inverter (`gfInv`, 13 multipliers' worth of logic), 30 constant multipliers for the syndromes and 31 for the Chien search. Storage: 95 bytes (S 32, Lambda 16, B 16, T 16, Omega 15) = 760 flops, plus about 100 bits of control.
- Speed (measured, slowest blocks over 4,099 test blocks): clean 527 cycles (mostly the output copy), fixed 2,003, fixed with the maximum number of errors 2,059, failed 1,459. Worst case per symbol is about 81 blocks x 2k = 160k cycles; a lightly damaged symbol is far cheaper.
- Verified (`modules/rs/run.sh`, expect `PASS`): 4,099 blocks over 416 cases covering all 160 version/level pairs (small versions repeated). Mix: 1,214 clean, 1,727 with 1..t-1 errors, 518 with exactly t errors, 298 too damaged (must fail), 342 built so the block lies within reach of a DIFFERENT valid block (the decoder must succeed with that block's data), errors also in check bytes and at block boundaries. Compared against an independent RS encoder written from the spec and the model's decoder.
- Planted bugs caught: Chien search direction, Berlekamp-Massey length test off by one, correction written one byte off, and removing both safety checks. Removing only the "exactly L roots" check is NOT caught because the verify pass catches the same blocks; the roots check only fails earlier, so keep both.
- Design-space levers: parallelise the Berlekamp-Massey update, replace `gfInv` by a serial inverse on the shared multiplier, drop the T array, use fewer syndrome multipliers by processing syndromes serially.
- Changed unit 4: `QRBlockBuf` gained `writeByte(addr, x)` (used for the corrections). Use the new `QRBlocks.bsv`; its tests still pass.

## Verification plan

- Per unit: exhaustive where the input space allows (GF multiplier, format decoder), random plus hand-picked hard cases otherwise.
- Whole decoder: a testbench that plays the course testbench: answers `mem.req` one cycle later, stalls `getByte` randomly, decodes many symbols without reset, checks C1 to C5.
- Test set must include (spec 5.3): every version, level and mask; every mode and multi-segment messages; empty message; short final groups; exactly floor(e/2) damaged bytes per block (data and check bytes); damaged function modules; up to 3 wrong format bits in one or both copies; symbols that must fail.
- Vectors come from `qr_model/gen_vectors.py` (~1,600 cases).
- Put everything under `verification/` with a README and a one-command `make test`.

## Design-space exploration (10 marks)

Run Design Compiler (normal synthesis, not topographical) with 40% external delay; reuse the udcounter scripts and do not change the timing libraries. Record Table 5 for every iteration, then ICC place and route (not ICC2) for the best one (Table 6). Candidate levers, one or two per iteration:

1. Baseline (a working `cap`, e.g. 1024): get it correct first.
2. Shrink the buffer `cap` (area against cycles).
3. Format decoder: all 32 comparisons at once vs one per cycle.
4. RS: one shared GF multiplier vs several.
5. Merge counters, share (r, c) logic, look ahead in the walker so it skips function modules faster.
6. Retime or tighten the clock period.

Tackle `cap` first: while the buffer is large it hides the effect of every other change.

## Decisions and open questions

Confirm on the course forum (questions that would reveal part of a solution go to the TAs by email instead):

1. What is the cycle limit per decode?
2. The model README lists choices the spec leaves open: fewer than 4 bits left with no terminator ends the message successfully; a segment with count 0 is legal; numeric groups keep leading zeros; unknown mode means anything other than 0001, 0010, 0100, 0000; a late failure fails the whole symbol. Confirm or correct these.
3. Is `failed` rising after the byte with `last` has been taken acceptable? (C2 says failed may rise at any point; this is the case where all bytes were already delivered.)

## BSV gotchas found so far

- `dist` is a reserved word (SystemVerilog keyword); the compiler's error message about it is confusing. Use another name.
- `Coord` is a `UInt#(8)`: use `pack(r)[0]` to pick a bit.

- Bluesim builds slow down badly with thousands of registers (see unit 4). Develop and test with a small `cap` (153 or 300).
- In `bsc` output, `\|` (the OR operator passed to `fold`) is easy to mangle when pasting; keep a single backslash.

## Environment

`bsc` 2024.07 and Bluesim were used to verify unit 1. The course Docker image has `bsc`, Verilator and cocotb.

## Status log

- Unit 1 (walker + mask) done. 40/40 versions and 8/8 masks match the model.
- Unit 5 (Reed-Solomon) done. 4,099 blocks match, including blocks built to land near a different valid block; planted bugs caught.
- Unit 5a (GF arithmetic) done: all 65,536 products and the rest match the spec definition and the model.
- Unit 4 (block buffer) done. All 160 version/level pairs match the spec's interleaving at cap 153, 300 and 1024; three planted bugs caught.
- Unit 3 (reader) done. 1,563 cases / 1.98M codeword bytes identical to the model, with back-pressure; two planted bugs caught.
- Unit 2 (format decoder) done. Exhaustive nearest-word test, 1200 positions and 400k random pairs match the model.
- Model (`qr_model/`) passes its 16 self-tests and generates 1,614 vectors.
- `QRDecoder.bsv` is still the placeholder; units 6 and 7 not started. Next: unit 6, the payload parser.
