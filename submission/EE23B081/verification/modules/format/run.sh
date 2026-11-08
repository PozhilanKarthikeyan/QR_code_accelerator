#!/bin/sh
# Builds the format-decoder test bench in Bluesim and checks it against the Python model.
# Run from verification/format/.   Needs bsc on PATH.
set -e
BSV=${BSV_DIR:-../../bsv}          # folder holding QRFormat.bsv, QRTypes.bsv, QRTables.bsv
MODEL=${MODEL_DIR:-../../qr_model}
mkdir -p build
bsc -u -sim -p $BSV:+ -bdir build -simdir build -info-dir build -g mkTbFormat TbFormat.bsv >/dev/null
bsc -sim -e mkTbFormat -bdir build -simdir build -o build/TbFormat >/dev/null
./build/TbFormat > format.out
python3 check_format.py $MODEL
