#!/bin/sh
# Plants bugs in a scratch copy of QRPayload.bsv and checks that run.sh notices every one.
# Run from modules/payload/.  Prints CAUGHT or SURVIVED per bug.
MODEL=${MODEL_DIR:-../../qr_model}
SRC=${BSV_DIR:-../../src}
HERE=$(pwd)
try() {   # name  sed-expression
   rm -rf /tmp/mut && mkdir -p /tmp/mut && cp QRPayload.bsv TbPayload.bsv check_payload.py run.sh /tmp/mut/
   sed -i "$2" /tmp/mut/QRPayload.bsv
   if cmp -s QRPayload.bsv /tmp/mut/QRPayload.bsv; then echo "$1: PATTERN NOT FOUND (fix mutants.sh)"; return; fi
   if (cd /tmp/mut && BSV_DIR=$HERE/$SRC MODEL_DIR=$HERE/$MODEL ./run.sh >/tmp/mut/log 2>&1); then
      echo "$1: SURVIVED"; else echo "$1: CAUGHT"; fi
}
try "count-width class boundary 26 -> 27"      's/(v <= 26)/(v <= 27)/'
try "numeric limit 999 -> 1023"                 's/(k == 3) ? 999/(k == 3) ? 1023/'
try "alphanumeric pair limit 2024 -> 2025"      's/v > 2024/v > 2025/'
try "last flag never set"                       's/noutL = True;/noutL = False;/'
try "fewer than 4 bits left fails"              's/else if (ended) nst = SFlush;  /else if (ended) nst = SFail;   /'
try "bytes after the end are not discarded"     's/if (discard || nbits <= 16)/if (nbits <= 16)/'
try "byte-mode count width 16 -> 8"             's/default: w = (cls == 0) ? 8 : 16;/default: w = 8;/'
