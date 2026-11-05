#!/bin/sh
# Builds the payload-parser test bench in Bluesim and checks it against an independent parser written from
# the spec and the model's payload.py.  Run from modules/payload/.  Needs bsc on PATH.
set -e
SRC=${BSV_DIR:-../../src}              # folder holding QRTypes.bsv
MODEL=${MODEL_DIR:-../../qr_model}
mkdir -p build
python3 check_payload.py gen $MODEL
NC=$(wc -l < cfg.hex)
bsc -u -sim -D NCASES=$NC -p .:$SRC:+ -bdir build -simdir build -info-dir build -g mkTbPayload TbPayload.bsv >/dev/null
bsc -sim -e mkTbPayload -bdir build -simdir build -o build/TbPayload >/dev/null
./build/TbPayload > payload.out
python3 check_payload.py check $MODEL
