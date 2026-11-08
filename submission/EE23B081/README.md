# QR Code Decoder (`mkQRDecoder`) - EE23B081

CS6230 CAD for VLSI, 2026 project. A Bluespec SystemVerilog QR code decoder, taken through
verification, four rounds of synthesis (Design Compiler) and placement (IC Compiler).

Team: EE23B056 Pozhilan Karthikeyan, EE23B081 P Tejasvin

## Results at a glance

| | |
|---|---|
| Function | 0 mismatches on 1,614 symbols (1,168 must decode, 446 must fail), run back to back with random `getByte` stalls |
| Latency | max 37,388 cycles, mean 11,278 (start to the `last` byte taken) |
| Verification | 8 unit test benches, whole-decoder test bench, 16 of 16 planted bugs caught |
| Synthesis | clock improved 2.7 ns to 1.0 ns over four designs, no timing violations |
| Best design | design 4: 1.00 ns, f2f slack 0.00, 38,074 leaf cells (9,508 sequential), 14.710 mW, cell area 19,724 um^2 |
| Placement | 170 x 170 um core, 71.90% utilization after `place_opt` (meets the 70% minimum) |

## What is in this folder

```
README.md          this file
report.pdf         architecture, spec compliance and verification report
pd_report.pdf      Table 5 (post-synthesis), Table 6 (post-placement), the four iterations
bsv/               the design
verification/      Python reference model, per-unit and whole-decoder test benches
pd/                Design Compiler runs and the ICC placement run
sdc_full_backup/   unfiltered SDC files written by each DC run (see note below)
```

### `bsv/`

| File | Role |
|---|---|
| `QRDecoder.bsv` | top level `mkQRDecoder`: one controller FSM that sequences the units |
| `QRReader.bsv` | reads the format and data modules (one request per cycle), unmasks, packs bytes |
| `QRWalker.bsv` | zigzag module order, skips function modules, mask conditions |
| `QRFormat.bsv` | format information decode: nearer valid word of the two copies, fail past 3 bit errors |
| `QRBlocks.bsv` | de-interleaves codewords into blocks in a buffer (default 1,024 bytes) |
| `QRRS.bsv` | per-block Reed-Solomon: syndromes, Berlekamp-Massey, Chien search, Forney, re-check |
| `QRGF.bsv` | GF(2^8) multiply, multiply by alpha, inverse (polynomial 0x11D) |
| `QRPayload.bsv` | numeric, alphanumeric and byte mode parser, one ASCII byte per character |
| `QRTypes.bsv`, `QRTables.bsv` | supplied files, unmodified |

Architecture in one line: small and serial. One module read per cycle, one byte-wide pipeline, one shared
GF(2^8) multiplier and one inverter in the Reed-Solomon stage. If a symbol has more blocks than the buffer holds,
it is read again for the next group of blocks (area traded for cycles). Details are in `report.pdf`, section 2.

## Build

```
bsc -u -verilog -p bsv:+ -bdir build -vdir build -g mkQRDecoder bsv/QRDecoder.bsv
```

The block buffer defaults to 1,024 bytes. `-D CAP=<bytes>` overrides it for experiments. `start` and `getByte`
use implicit conditions, with no `always_ready` or `always_enabled`.

## Verification

Needs `bsc` on the PATH and `python3` with `segno` (`pip install segno`).

```
cd verification
sh run_all.sh            # quick: every unit test, and the whole decoder on every 8th case (300-byte buffer)
FULL=1 sh run_all.sh     # all 1,614 symbols at the delivered 1,024-byte buffer, plus the planted-bug runs
```

The first build of the top level takes several minutes (bsc elaboration). See `verification/README.md` for
the layout, what each unit is checked against and the recorded results. All tests run in Bluesim. Verilator,
cocotb and code coverage were not used.

## Physical design

All runs use `saed14rvt_base_ss0p72v125c`, unchanged from the udcounter example, with 40% input and output
delay on every port except the clock.

| Folder | Contents |
|---|---|
| `pd/design_1` ... `pd/design_4` | `*_dc.tcl`, `*_dc.sdc`, `*_dc_qor.rpt`, `*_dc_timing.rpt`, `*_dc_power.rpt`, `dc_run.log` |
| `pd/best_design/` | the DC reports for design 4, plus the ICC placement run: `best_design_place.tcl`, `best_design_place.sdc`, `best_design_post_place_qor.rpt`, `best_design_post_place_power.rpt`, `best_icc_run.log` |

The four designs, each differing from the previous in one BSV file:

| Design | Change | Period |
|---|---|---|
| 1 | baseline | 2.7 ns |
| 2 | `QRFormat`: 32 independent "within 3 bits" tests instead of a compare-and-select chain | 2.1 ns |
| 3 | `QRGF`: GF inverse as a 256-entry table | 1.0 ns |
| 4 | `QRRS`: registered buffer address | 1.0 ns |

Design 4 is the best design. After `place_opt` it still meets 1.00 ns (f2f slack 0.00), with cell area
19,724 um^2 and 14.710 mW. `pd_report.pdf` has the full Table 5 and Table 6, the comparison of designs at equal
periods, and a map from each submitted design to its BSV source folder and run tag.

### Deviations from the handout layout

* **Placement only.** The flow is `place_opt` with no clock-tree synthesis and no routing, so the post-layout files are
  named `best_design_post_place_*` and `best_design_place.*` instead of `post_route` / `route`. Timing after placement
  uses an ideal clock and estimated parasitics.
* **No DRC/LVS.** These cannot be checked without routing. The placement legality check is clean (0 cells off row,
  0 overlaps, 0 power-strap or orientation violations).
* **Trimmed SDC files.** The SDC files in `pd/` have the expanded `group_path` register lists removed (they list every
  register and make the file about 1.5 MB). The clock and the 13 input and 32 output delays are unchanged, and the
  path groups are defined in each `design_N_dc.tcl`. The unfiltered SDC files are in `sdc_full_backup/`.
* **Large log.** `best_icc_run.log` (about 48 MiB) is unfiltered. Most of it is repeated power-routing warnings
  from the power straps; it contains no errors.

## Limits

* Power is from `report_power` with default switching activity, so it compares designs but is not an absolute figure.
* Synthesis uses a wire-load model, so DC's "design area" (which includes estimated net area) is not comparable with
  ICC's cell area.
* The reference model and the RTL share one reading of the points the specification leaves open
  (`verification/qr_model/README.md`, "Choices the spec leaves open").
