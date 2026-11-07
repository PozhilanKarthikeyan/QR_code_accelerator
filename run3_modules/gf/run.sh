#!/bin/sh
# Builds the GF(2^8) test bench in Bluesim and checks it against the spec's definition and the model.
# Run from modules/gf/.  Needs bsc on PATH.
set -e
MODEL=${MODEL_DIR:-../../qr_model}
mkdir -p build
bsc -u -sim -steps-warn-interval 1000000 -bdir build -simdir build -info-dir build -g mkTbGF TbGF.bsv >/dev/null
bsc -sim -e mkTbGF -bdir build -simdir build -o build/TbGF >/dev/null
./build/TbGF > gf.out
python3 check_gf.py $MODEL
