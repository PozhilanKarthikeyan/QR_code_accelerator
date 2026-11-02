#!/bin/sh
# Builds the walker test benches in Bluesim and checks them against the Python model.
# Run from verification/walker/.   Needs bsc on PATH and segno-free Python 3.
set -e
BSV=${BSV_DIR:-../../bsv}          # folder holding QRWalker.bsv, QRTypes.bsv, QRTables.bsv
MODEL=${MODEL_DIR:-../../qr_model}
mkdir -p build
for t in TbWalker TbMask; do
  bsc -u -sim -p .:$BSV:+ -bdir build -simdir build -info-dir build -g mk$t $t.bsv >/dev/null
  bsc -sim -e mk$t -bdir build -simdir build -o build/$t >/dev/null
done
./build/TbWalker > walker.out
./build/TbMask   > mask.out
python3 check_walker.py $MODEL
