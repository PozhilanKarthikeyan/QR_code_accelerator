#!/bin/sh
# Builds the reader test bench in Bluesim and checks it against the Python model.
# Run from modules/reader/.  Needs bsc on PATH and Python 3 with segno (for gen_vectors.py).
set -e
SRC=${BSV_DIR:-../../src}              # folder holding QRTypes.bsv and QRTables.bsv
MODEL=${MODEL_DIR:-../../qr_model}
mkdir -p build vectors
[ -f vectors/cases.hex ] || python3 $MODEL/gen_vectors.py --out vectors --seed 1 --scale 1
NC=$(wc -l < vectors/cases.hex)
bsc -u -sim -D NCASES=$NC -p ../walker:../format:$SRC:+ -bdir build -simdir build -info-dir build -g mkTbReader TbReader.bsv >/dev/null
bsc -sim -e mkTbReader -bdir build -simdir build -o build/TbReader >/dev/null
(cd vectors && ../build/TbReader > ../reader.out)
python3 check_reader.py $MODEL
