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
src/                    (the zip must call this bsv/, see "Submission")
  QRTypes.bsv           supplied, do not edit
  QRTables.bsv          supplied, do not edit
  QRDecoder.bsv         top level (still the placeholder)
  QRWalker.bsv          unit 1, done
  QRFormat.bsv          unit 2, done
  TbSample.bsv          supplied example testbench
qr_model/               Python reference model (gen_vectors.py makes ~1600 test cases)
verification/walker/    tests for unit 1; run.sh runs them
verification/format/    tests for unit 2; run.sh runs them
```

Submission (spec 6.3): `<Roll_Number>/{README.md, report.pdf, pd_report.pdf, bsv/, verification/, pd/}`. Build the zip from this repo at the end, then check it in a fresh copy of the handout (see README).

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

**Design knob P = blocks handled per pass.** Each pass walks the whole symbol but stores only the bytes of the current group of P blocks, then corrects and emits those blocks in order.

| P | Buffer | Passes (v40, 81 blocks) | Cycles |
|---|---|---|---|
| all | 3,706 bytes (~30k flops) | 1 | ~30k |
| 8 | 1,224 bytes | 11 | ~330k |
| 1 | 153 bytes | 81 | ~2.4M |

Plan: write it parametric from the start, get P = all working first, then shrink P as a synthesis iteration. **Open question for the forum: what is the cycle limit?** It decides how small P can go.

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
| 3 | Reader | walker + mem port + unmask -> bytes | | not started |
| 4 | De-interleaver + buffer | bytes -> blocks (counters, no division) | | not started |
| 5 | Reed-Solomon | syndromes, Berlekamp-Massey, Chien, Forney | | not started |
| 6 | Payload parser | corrected bytes -> characters, `last` flag | | not started |
| 7 | Top level (`mkQRDecoder`) | `start` / `getByte` / `failed` / `done`, controller | | not started |

Suggested build order: GF multiplier, 2, 3, 4, 5, 6, 7. Test each unit against the model before connecting it.

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

## Verification plan

- Per unit: exhaustive where the input space allows (GF multiplier, format decoder), random plus hand-picked hard cases otherwise.
- Whole decoder: a testbench that plays the course testbench: answers `mem.req` one cycle later, stalls `getByte` randomly, decodes many symbols without reset, checks C1 to C5.
- Test set must include (spec 5.3): every version, level and mask; every mode and multi-segment messages; empty message; short final groups; exactly floor(e/2) damaged bytes per block (data and check bytes); damaged function modules; up to 3 wrong format bits in one or both copies; symbols that must fail.
- Vectors come from `qr_model/gen_vectors.py` (~1,600 cases).
- Put everything under `verification/` with a README and a one-command `make test`.

## Design-space exploration (10 marks)

Run Design Compiler (normal synthesis, not topographical) with 40% external delay; reuse the udcounter scripts and do not change the timing libraries. Record Table 5 for every iteration, then ICC place and route (not ICC2) for the best one (Table 6). Candidate levers, one or two per iteration:

1. Baseline (P = all): get it correct first.
2. Shrink P (area against cycles).
3. Format decoder: all 32 comparisons at once vs one per cycle.
4. RS: one shared GF multiplier vs several.
5. Merge counters, share (r, c) logic, look ahead in the walker so it skips function modules faster.
6. Retime or tighten the clock period.

Tackle P first: while the buffer is huge it hides the effect of every other change.

## Decisions and open questions

Confirm on the course forum (questions that would reveal part of a solution go to the TAs by email instead):

1. What is the cycle limit per decode?
2. The model README lists choices the spec leaves open: fewer than 4 bits left with no terminator ends the message successfully; a segment with count 0 is legal; numeric groups keep leading zeros; unknown mode means anything other than 0001, 0010, 0100, 0000; a late failure fails the whole symbol. Confirm or correct these.
3. Is `failed` rising after the byte with `last` has been taken acceptable? (C2 says failed may rise at any point; this is the case where all bytes were already delivered.)

## BSV gotchas found so far

- `dist` is a reserved word (SystemVerilog keyword); the compiler's error message about it is confusing. Use another name.
- `Coord` is a `UInt#(8)`: use `pack(r)[0]` to pick a bit.

## Environment

`bsc` 2024.07 and Bluesim were used to verify unit 1. The course Docker image has `bsc`, Verilator and cocotb.

## Status log

- Unit 1 (walker + mask) done. 40/40 versions and 8/8 masks match the model.
- Unit 2 (format decoder) done. Exhaustive nearest-word test, 1200 positions and 400k random pairs match the model.
- Model (`qr_model/`) passes its 16 self-tests and generates 1,614 vectors.
- `QRDecoder.bsv` is still the placeholder; units 3 to 7 not started. Next: unit 3, the reader (walker + format decoder + memory port).
