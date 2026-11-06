#!/bin/sh
# Builds the real top level (mkQRDecoder) plus the whole-decoder test bench in Bluesim and checks it.
# Run from modules/top/.  Needs bsc on PATH and python3.
#   CAP=300  ./run.sh        buffer size in bytes (default 300: builds and runs faster; the delivered
#                            default in QRDecoder.bsv is 1024)
#   STEP=8   ./run.sh        run only every 8th case (default 1 = all 1614); good for quick iterations
#   BSCX="-steps-warn-interval 1000000 -steps-max-intervals 50"  extra bsc flags (raise the elaboration step limit)
#   MODS=..                  folder holding walker/ format/ reader/ blocks/ gf/ rs/ payload/
# Steps: (1) elaborate mkQRDecoder to Verilog on its own: proves that the top level is one synthesizable
# module and that start/getByte keep their ready signals (C5); (2) simulate with TbTop; (3) check.
set -e
SRC=${BSV_DIR:-../../src}                # folder holding QRTypes.bsv and QRTables.bsv
MODEL=${MODEL_DIR:-../../qr_model}
MODS=${MODS:-..}
CAP=${CAP:-300}
STEP=${STEP:-1}
BSCX=${BSCX:-}
B=build/cap$CAP
P=.:$MODS/walker:$MODS/format:$MODS/reader:$MODS/blocks:$MODS/gf:$MODS/rs:$MODS/payload:$SRC:+
mkdir -p $B/v $B/sim vectors
[ -f vectors/cases.hex ] || python3 $MODEL/gen_vectors.py --out vectors --seed 1 --scale 1
NC=$(wc -l < vectors/cases.hex)
bsc -u -verilog $BSCX -D CAP=$CAP -p $P -bdir $B/v -vdir $B/v -info-dir $B/v -g mkQRDecoder QRDecoder.bsv >/dev/null
grep -q RDY_start $B/v/mkQRDecoder.v && grep -q RDY_getByte $B/v/mkQRDecoder.v
touch TbTop.bsv
bsc -u -sim $BSCX -D CAP=$CAP -D NCASES=$NC -D STEP=$STEP -p $P -bdir $B/sim -simdir $B/sim -info-dir $B/sim -g mkTbTop TbTop.bsv >/dev/null
bsc -sim -e mkTbTop -bdir $B/sim -simdir $B/sim -o $B/sim/TbTop >/dev/null
(cd vectors && ../$B/sim/TbTop > ../top.out)
STEP=$STEP python3 check_top.py $MODEL
