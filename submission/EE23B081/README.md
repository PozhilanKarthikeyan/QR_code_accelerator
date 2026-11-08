# CS6230 QR Code Decoder - EE23B081

BSV implementation of `mkQRDecoder` (spec: CS6230 project, QR Code decoder).

## Contents

| Path | What it is |
|---|---|
| `bsv/` | The design. `QRDecoder.bsv` is the top level (`mkQRDecoder`); `QRReader`, `QRWalker`, `QRFormat`, `QRBlocks`, `QRRS`, `QRGF`, `QRPayload` are the units. `QRTypes.bsv` and `QRTables.bsv` are the supplied files, unmodified. |
| `verification/` | Python reference model, per-unit test benches and the whole-decoder test bench (Bluesim). See `verification/README.md`. |
| `pd/` | Design Compiler runs `design_1` to `design_4` and `best_design/` (DC reports plus the ICC place_opt reports, script, SDC and log). |
| `report.pdf` | Architecture, spec compliance and verification report. |
| `pd_report.pdf` | Table 5 (post-synthesis) and Table 6 (post-place) QoR data and the design iterations. |

## Build

The top level is a single synthesizable module with the supplied interface:

```
bsc -u -verilog -p bsv:+ -bdir build -vdir build -g mkQRDecoder bsv/QRDecoder.bsv
```

The block buffer defaults to 1024 bytes; `-D CAP=<bytes>` overrides it for experiments.

## Verification

```
cd verification
sh run_all.sh            # quick: every unit test + the whole decoder on every 8th case
FULL=1 sh run_all.sh     # all 1,614 symbols at the delivered 1024-byte buffer + planted-bug runs
```

Needs `bsc` and `python3` with `segno`.

## Physical design

Synthesis: Design Compiler (non-topographical), 40% external delay. Placement: IC Compiler `place_opt` only
(no CTS or routing), 170 x 170 um core, 71.90% utilization. Best design: `design_4` (tag `design_4_p10`) at 1.00 ns.
