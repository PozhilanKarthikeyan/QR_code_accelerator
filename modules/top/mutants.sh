#!/bin/sh
# Plants bugs in a scratch copy of QRDecoder.bsv and checks that run.sh notices each one.
# Run from modules/top/ AFTER run.sh passes (it reuses vectors/).  Each bug is a full build + simulation,
# so it runs a sample of the cases: MSTEP=9 (every 9th case) by default; SURVIVED may only mean the sample
# missed the case that shows the bug, so rerun a survivor with MSTEP=1.
#   CAP=300 MSTEP=9 ./mutants.sh
MODEL=${MODEL_DIR:-../../qr_model}
SRC=${BSV_DIR:-../../src}
MSTEP=${MSTEP:-9}
HERE=$(pwd)
try() {   # name  sed-expression
   rm -rf /tmp/mutt && mkdir -p /tmp/mutt && cp QRDecoder.bsv TbTop.bsv check_top.py run.sh /tmp/mutt/
   ln -s $HERE/vectors /tmp/mutt/vectors
   sed -i "$2" /tmp/mutt/QRDecoder.bsv
   if cmp -s QRDecoder.bsv /tmp/mutt/QRDecoder.bsv; then echo "$1: PATTERN NOT FOUND (fix mutants.sh)"; return; fi
   if (cd /tmp/mutt && MODS=$HERE/.. BSV_DIR=$HERE/$SRC MODEL_DIR=$HERE/$MODEL STEP=$MSTEP ./run.sh >/tmp/mutt/log 2>&1); then
      echo "$1: SURVIVED"; else echo "$1: CAUGHT"; fi
}
try "format level bits inverted"            's/lvlR  <= f.level;/lvlR  <= ~f.level;/'
try "mask forgotten (always 0)"             's/maskR <= f.mask;/maskR <= 0;/'
try "next pass restarts at block 0"         's/g0  <= bb.groupEnd;/g0  <= 0;/'
try "Reed-Solomon failure ignored"          's/if (rs.failed) begin nfail = True; nst = TIdle; end/if (False) begin nfail = True; nst = TIdle; end/'
try "endOfData never sent"                  's/pl.endOfData;//'
try "getByte still ready after failed"      's/getByte() if (!failedR);/getByte() if (True);/'
try "wrong check-byte count"                's/rs.decodeBlock(p.ecLen, d)/rs.decodeBlock(p.ecLen - 1, d)/'
try "done without waiting for the parser"   's/if (pl.done) begin ndone/if (True) begin ndone/'
try "side length never checked"             's/Bool okSize = (sz >= 21) \&\& (sz <= 177) \&\& (pack(t)\[1:0\] == 0);/Bool okSize = True;/'
