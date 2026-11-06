import sys
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else "../../qr_model")
import formatinfo
from tables import FORMAT_CODEWORDS

# ---- 0. the 32 valid words in QRTables.bsv, re-derived from the spec text itself
#      (BCH generator 10100110111, ten zeros appended, XOR constant 101010000010010)
def spec_word(d5):
    rem = d5 << 10
    for bit in range(14, 9, -1):
        if rem >> bit & 1:
            rem ^= 0b10100110111 << (bit - 10)
    return ((d5 << 10) | rem) ^ 0b101010000010010
assert all(spec_word(d) == FORMAT_CODEWORDS[d] for d in range(32)), "QRTables words differ from spec"
dmin = min(bin(a ^ b).count("1") for a in FORMAT_CODEWORDS for b in FORMAT_CODEWORDS if a != b)
print(f"tables: all 32 words re-derived from the spec; minimum distance {dmin}")

nbad = pbad = dbad = 0
nn = pn = dn = 0
dstat = {"ok": 0, "fail": 0, "used2": 0}
for line in open("format.out"):
    t = line.split()
    if not t: continue
    if t[0] == "N":
        w, d, dist = map(int, t[1:])
        nn += 1
        ed, edist = formatinfo.nearest(w)
        if (d, dist) != (ed, edist):
            nbad += 1
            if nbad <= 3: print("nearest mismatch", w, (d, dist), (ed, edist))
    elif t[0] == "P":
        n, s, i, r, c = map(int, t[1:])
        pn += 1
        c1, c2 = formatinfo.positions(n)
        if (r, c) != (c1, c2)[s][i]:
            pbad += 1
            if pbad <= 3: print("position mismatch", n, s, i, (r, c), (c1, c2)[s][i])
    elif t[0] == "D":
        c1, c2, ok, lvl, mask = map(int, t[1:])
        dn += 1
        eok, elvl, emask, info = formatinfo.decode(c1, c2)
        exp = (1, elvl, emask) if eok else (0, 0, 0)
        if (ok, lvl, mask) != exp:
            dbad += 1
            if dbad <= 3: print("decode mismatch", c1, c2, (ok, lvl, mask), exp, info)
        dstat["ok" if eok else "fail"] += 1
        if eok and info["used_copy"] == 2: dstat["used2"] += 1
        if info["dist1"] == info["dist2"] and info["dist1"] > 0 and eok: dstat.setdefault("tie_nonzero", 0); dstat["tie_nonzero"] += 1
print(f"nearestFormat : {nn - nbad}/{nn} words identical to model (all 2^15)")
print(f"formatPosition: {pn - pbad}/{pn} positions identical to model (40 versions x 2 copies x 15 bits)")
print(f"decodeFormat  : {dn - dbad}/{dn} random pairs identical to model "
      f"({dstat['ok']} decodable, {dstat['fail']} failing, {dstat['used2']} used copy 2, "
      f"{dstat.get('tie_nonzero', 0)} ties at distance>0)")
sys.exit(1 if (nbad or pbad or dbad or nn != 32768 or pn != 1200 or dn != 400000) else 0)
