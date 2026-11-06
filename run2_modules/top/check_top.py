#!/usr/bin/env python3
"""Whole-decoder check: reads top.out written by the Bluesim test bench and the vectors it ran.

  python3 check_top.py [model_dir]        (run from modules/top/; env STEP = the STEP the test bench ran with)

All the byte-by-byte and handshake checking (C1-C3) is done inside TbTop.bsv, which counts errors per case.
This script checks that every case that was meant to run produced a result, that the result is the expected
one (done for a decodable symbol with the right number of bytes, failed for one that must fail), that no
case saw an error, and reports the latency of the cases the test bench ran without back-pressure.
"""
import json
import os
import sys

STEP = int(os.environ.get("STEP", "1"))
cases = [int(x, 16) for x in open("vectors/cases.hex").read().split()]
names = [c["name"] for c in json.load(open("vectors/cases.json"))]


def parse(w):
    return dict(N=w >> 120 & 0xFF, ok=(w >> 112 & 0xFF) == 1, len=w >> 96 & 0xFFFF)


R, E, ended = {}, {}, False
for line in open("top.out"):
    t = line.split()
    if not t:
        continue
    if t[0] == "R":
        R[int(t[1])] = tuple(map(int, t[2:8]))        # mode code latency total errors bytes
    elif t[0] == "E":
        E.setdefault(int(t[1]), line.strip())
    elif t[0] == "END":
        ended = True

bad = 0


def fail(msg):
    global bad
    bad += 1
    if bad <= 12:
        print("MISMATCH", msg)


if not ended:
    fail("test bench did not reach END (it stopped early: timeout or crash)")
want = list(range(0, len(cases), STEP))
n_ok = n_fail = 0
lat = []                                              # (latency, name) of fast, successful, non-empty cases
for ci in want:
    c = parse(cases[ci])
    n_ok += c["ok"]
    n_fail += not c["ok"]
    r = R.get(ci)
    if r is None:
        fail(f"case {ci} '{names[ci]}': no result line")
        continue
    mode, code, latency, total, errs, nbytes = r
    if code == 2:
        fail(f"case {ci} '{names[ci]}': no result within the cycle limit")
        continue
    if errs:
        fail(f"case {ci} '{names[ci]}': {errs} protocol/data errors  {E.get(ci, '')}")
    if c["ok"] and code != 0:
        fail(f"case {ci} '{names[ci]}': must decode, decoder raised failed")
    elif not c["ok"] and code != 1:
        fail(f"case {ci} '{names[ci]}': must fail, decoder raised done")
    elif c["ok"] and nbytes != c["len"]:
        fail(f"case {ci} '{names[ci]}': {nbytes} bytes taken, message has {c['len']}")
    if c["ok"] and mode == 0 and c["len"] > 0 and code == 0:
        lat.append((latency, names[ci]))
extra = set(R) - set(want)
if extra:
    fail(f"results for cases that should not have run: {sorted(extra)[:5]}")
lat.sort(reverse=True)
if lat:
    mean = sum(l for l, _ in lat) / len(lat)
    print(f"latency (cases run without back-pressure): {len(lat)} cases, max {lat[0][0]} cycles, "
          f"mean {mean:.0f}; slowest: " + "; ".join(f"{l} '{n}'" for l, n in lat[:3]))
print(f"top: {len(want)} cases ({n_ok} decode, {n_fail} must fail), {bad} mismatches -> "
      f"{'PASS' if bad == 0 else 'FAIL'}")
sys.exit(1 if bad else 0)
