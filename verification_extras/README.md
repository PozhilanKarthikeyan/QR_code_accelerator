# Verification

Everything here is runnable with one command from this folder:

```
sh run_all.sh            # quick: every unit test + the whole decoder on every 8th case, 300-byte buffer
FULL=1 sh run_all.sh     # adds all 1,614 symbols at the delivered 1024-byte buffer, and the planted-bug runs
```

Needs `bsc` on the PATH, `python3` and `segno` (`pip install segno`). The first build of the top level takes
several minutes (bsc elaboration). Generated files (test vectors, simulator builds, `*.out`) are rebuilt by the
scripts and are not stored here.

## Layout

| Folder | Contents |
|---|---|
| `qr_model/` | Python reference decoder (written from the spec) and the vector generator. `gen_vectors.py` builds the 1,614 whole-symbol cases that the top-level test uses |
| `modules/<unit>/` | one folder per hardware unit: `Tb*.bsv` test bench, `check_*.py` checker, `run.sh` |
| `modules/top/` | whole-decoder test bench (`TbTop.bsv`), checker, `run.sh`, `mutants.sh`, and the recorded logs of our runs |
| `src/` | the supplied `QRTypes.bsv` and `QRTables.bsv`, unmodified, that the tests compile against |

The design under test is the delivered `bsv/` folder; `modules/<unit>/QR*.bsv` are the same sources in the
per-unit layout that the scripts expect.

## What is tested

| Unit | Checked against | Coverage |
|---|---|---|
| `walker` | model (`layout.py`) | module order and function-module skipping for all 40 versions, all 8 masks |
| `format` | model (`formatinfo.py`) | all 32,768 15-bit words, the 1,200 format positions (40 versions x 2 copies x 15 bits), 400,000 random copy pairs |
| `gf` | the spec's definition and model | all 65,536 GF(2^8) products, all 256 inverses, constants |
| `blocks` | the interleaving formula in the spec | all 160 version/level pairs at several buffer sizes |
| `reader` | model | whole symbols through the memory port, format failures, bad sizes |
| `rs` | an independent encoder and the model decoder | clean, 1..t errors, exactly t errors, too damaged, built to be within reach of another codeword |
| `payload` | an independent parser written from the spec and the model | numeric, alphanumeric and byte modes, count-width boundaries, all failure rules |
| `top` | model, end to end | 1,614 symbols run back to back without reset, with random stalls on `getByte`: 1,168 decode, 446 must fail |

Recorded results from our final runs (numbers copied from tool output):

* format decoder: 32768/32768 words, 1200/1200 positions, 400000/400000 random pairs identical to the model
* Reed-Solomon: 4099/4099 blocks match (1214 clean, 1727 fixed, 518 fixed with exactly t errors, 298 too damaged -> failed)
* payload parser: 2014 cases (895 decode, 1119 fail), 20021 characters, 0 mismatches (`modules/payload/run_log.txt`)
* whole decoder, 1024-byte buffer: 1614 cases (1168 decode, 446 must fail), 0 mismatches; slowest symbol 37,388 cycles (`modules/top/run_full1024.txt`)
* planted bugs: top level 9 of 9 caught, payload parser 7 of 7 caught (`modules/top/mutants_log.txt`, `modules/payload/mutants_log.txt`)

## Planted bugs ("mutation" runs)

`modules/top/mutants.sh` copies `QRDecoder.bsv`, plants one bug, and runs the whole-decoder test: wrong format level bits,
mask forgotten, next pass restarting at block 0, Reed-Solomon failure ignored, `endOfData` never sent, `getByte` still ready
after `failed`, wrong check-byte count, `done` raised without waiting for the parser, and side length never checked.
A bug counts as CAUGHT when the test fails. `modules/payload/mutants.sh` does the same for seven payload-parser rules.

## What the checks do not cover

* Verilator or cocotb flows and code coverage were not used; all tests run in Bluesim.
* The reference model and the RTL share one reading of the points the spec leaves open (see `qr_model/README.md`, section
  "Choices the spec leaves open").
