#!/bin/sh
# One command for the whole verification:   sh run_all.sh        quick run (a few minutes)
#                                           FULL=1 sh run_all.sh  adds the 1024-byte, all-1614-case run and the planted-bug runs
# Needs bsc on PATH, python3 with segno (pip install segno), nothing else.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/modules"

echo "### unit tests"
for u in walker format; do
  echo "--- $u";  (cd $u && BSV_DIR=.:../../src sh run.sh)   # these two look for QRTypes/QRTables in BSV_DIR
done
for u in gf blocks reader rs payload; do
  echo "--- $u";  (cd $u && sh run.sh)
done

echo "### whole decoder"
cd top
if [ "$FULL" = 1 ]; then
  echo "--- all 1614 cases, 1024-byte buffer (the delivered size)"
  CAP=1024 STEP=1 sh run.sh
  echo "--- planted bugs in the top level (every 9th case each)"
  CAP=300 MSTEP=9 sh mutants.sh
  echo "--- planted bugs in the payload parser"
  (cd ../payload && sh mutants.sh)
else
  CAP=300 STEP=8 sh run.sh
fi
echo "ALL DONE"
