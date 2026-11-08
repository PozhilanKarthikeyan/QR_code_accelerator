# QR decoder reference model (CS6230)

Pure-Python model of the decoder in the project spec.  Needs `segno` and `pytest`
(`pip install segno pytest`).

| File | What it is | Matches RTL unit |
|---|---|---|
| `gen_tables.py` / `tables.py` | `tables.py` is *parsed from the supplied QRTables.bsv*, so model and graders use the same block/alignment/format tables | `QRTables.bsv` |
| `gf256.py` | GF(2^8): log-table `mul` and bit-serial `mul_shift`, `inv` | GF multiplier / inverse |
| `formatinfo.py` | Table 1 positions, BCH(15,5), nearest-codeword decode, copy selection | format decoder |
| `layout.py` | version from side, function-module map, zigzag order, 8 masks | reader + unmask |
| `rs.py` | syndromes, Berlekamp-Massey, Chien, Forney, RS encoder | RS stages |
| `payload.py` | segment parser with all G4 failure cases | payload parser |
| `decoder.py` | G1-G4 end to end; `Result.trace` holds every intermediate value | top level |
| `encoder.py` | independent encoder, only for building test symbols | (test only) |
| `gen_vectors.py` | builds ~1600 test cases and writes hex/JSON files for a BSV or cocotb test bench | test bench |
| `test_model.py` | 16 self-tests (see below) | - |
| `demo.py` | decodes the symbol in TbSample.bsv and prints the trace | - |

## Run
```
python3 gen_tables.py /path/to/QRTables.bsv > tables.py   # only if the tables change
python3 -m pytest -q test_model.py
python3 demo.py /path/to/TbSample.bsv
python3 gen_vectors.py --out vectors --seed 1 --scale 1
```

## How the model is checked
* all 65,536 GF multiplier input pairs (table vs shift-and-add); all 2^15 format words
* for all 40 versions x 4 levels, `data modules // 8 == total bytes` from the supplied tables
* the encoder reproduces segno's matrix bit for bit for all 160 version/level pairs
* the decoder decodes segno symbols, all 8 masks, all three modes, both sides of every count-width boundary
* exactly floor(e/2) byte errors corrected, floor(e/2)+1 never silently accepted as the original
* the course's own sample symbol decodes to `HELLO CAD FOR VLSI`

## Choices the spec leaves open (confirm on the course forum)
1. A stream with fewer than 4 bits left and no terminator ends the message successfully.
2. A segment with count 0 is legal; decoding continues with the next segment.
3. Numeric groups keep leading zeros (`007` gives three bytes).
4. Format copy choice: copy 1 if `dist1 <= dist2`, else copy 2; fail if the chosen distance > 3.
   (A copy that is badly damaged can land nearer another valid word; the model then follows the rule literally.)
5. Unknown mode means anything other than 0001, 0010, 0100 and 0000 (so ECI, Kanji, structured append all fail).
6. A failure found late (e.g. a malformed segment after good ones) fails the whole symbol.
