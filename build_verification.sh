#!/bin/sh
# Builds submission/EE23B081/verification/ from run4_modules + qr_model + src.
# Run from ~/finalproj/QR_code_accelerator (the folder that holds run4_modules, qr_model, src, submission).
# Needs verification_extras/README.md and verification_extras/run_all.sh next to this script.
set -e
ROLL=${ROLL:-EE23B081}
V=submission/$ROLL/verification
rm -rf "$V"
mkdir -p "$V/modules" "$V/src" "$V/qr_model"

# unit tests + top-level test (sources, checkers, run scripts, recorded logs); generated files are rebuilt by run.sh
tar -C run4_modules \
    --exclude=build --exclude='build_*' --exclude=vectors --exclude=__pycache__ \
    --exclude='*.out' --exclude='*.hex' --exclude='*.pkl' --exclude=expect.json \
    --exclude='fix*.py' --exclude=PLAN.md --exclude=report.pdf \
    --exclude=test.txt --exclude=hello.txt \
    -cf - . | tar -C "$V/modules" -xf -

# reference model
tar -C qr_model --exclude=__pycache__ -cf - . | tar -C "$V/qr_model" -xf -

# supplied files the tests compile against (unmodified copies)
cp src/QRTypes.bsv src/QRTables.bsv "$V/src/"

cp verification_extras/README.md verification_extras/run_all.sh "$V/"
chmod +x "$V/run_all.sh"

echo "== $V =="
find "$V" -maxdepth 2 | sort
du -sh "$V"
