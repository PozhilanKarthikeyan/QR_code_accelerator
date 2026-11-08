#!/bin/sh
# Builds the block-buffer test bench in Bluesim for several buffer sizes and checks each
# against the spec's interleaving formula.  Run from modules/blocks/.  Needs bsc on PATH.
#   CAPS="153 1024" ./run.sh      (default)    each value is the buffer size in bytes
# Big sizes take a while to compile (about 2 minutes for 1024) -- that is bsc, not the test.
set -e
SRC=${BSV_DIR:-../../src}              # folder holding QRTypes.bsv and QRTables.bsv
MODEL=${MODEL_DIR:-../../qr_model}
CAPS=${CAPS:-"153 1024"}
python3 check_blocks.py gen $MODEL
for CAP in $CAPS; do
  mkdir -p build_$CAP
  bsc -u -sim -D CAP=$CAP -p $SRC:+ -bdir build_$CAP -simdir build_$CAP -info-dir build_$CAP -g mkTbBlocks TbBlocks.bsv >/dev/null
  bsc -sim -e mkTbBlocks -bdir build_$CAP -simdir build_$CAP -o build_$CAP/TbBlocks >/dev/null
  ./build_$CAP/TbBlocks > blocks.out
  python3 check_blocks.py $CAP $MODEL
done
