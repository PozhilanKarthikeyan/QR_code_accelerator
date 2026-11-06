#!/bin/sh
# Builds the Reed-Solomon test bench in Bluesim and checks it against an independent encoder
# and the model's decoder.  Run from modules/rs/.  Needs bsc on PATH.
#   CAP=300 ./run.sh      buffer size in bytes (default 300: builds fast)
set -e
SRC=${BSV_DIR:-../../src}              # folder holding QRTypes.bsv and QRTables.bsv
MODEL=${MODEL_DIR:-../../qr_model}
CAP=${CAP:-300}
mkdir -p build
python3 check_rs.py gen $MODEL
NC=$(wc -l < cfg.hex)
bsc -u -sim -D CAP=$CAP -D NCASES=$NC -p ../blocks:../gf:$SRC:+ -bdir build -simdir build -info-dir build -g mkTbRS TbRS.bsv >/dev/null
bsc -sim -e mkTbRS -bdir build -simdir build -o build/TbRS >/dev/null
./build/TbRS > rs.out
python3 check_rs.py check $MODEL
