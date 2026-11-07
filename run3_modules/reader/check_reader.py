import sys, collections
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else "../../qr_model")
import formatinfo, layout

# ---- load vectors
cases = [int(x, 16) for x in open("vectors/cases.hex").read().split()]
rows  = [int(x, 16) for x in open("vectors/symbols.hex").read().split()]
def parse(w):
    return dict(N=w >> 120 & 0xFF, first=w >> 32 & 0xFFFFFFFF)

# ---- parse the simulator output
F, B, E, X = {}, {}, {}, set()
for line in open("reader.out"):
    t = line.split()
    if not t: continue
    if   t[0] == "F": F[int(t[1])] = tuple(map(int, t[2:5]))
    elif t[0] == "B": B[int(t[1])] = t[2] if len(t) > 2 else ""
    elif t[0] == "E": E[int(t[1])] = (int(t[2]), int(t[3]))
    elif t[0] == "X": X.add(int(t[1]))

bad = 0
def fail(msg):
    global bad
    bad += 1
    if bad <= 8: print("MISMATCH", msg)

stats = collections.Counter()
worst_overhead = 0
for ci, w in enumerate(cases):
    c = parse(w); N = c["N"]
    sizeok = N >= 21 and N <= 177 and (N - 17) % 4 == 0
    if not sizeok:
        if ci not in X: fail(f"case {ci}: N={N} should have been skipped")
        stats["bad size"] += 1
        continue
    v = (N - 17) // 4
    m = [[(rows[c["first"] + r] >> (179 - cc)) & 1 for cc in range(N)] for r in range(N)]
    pos1, pos2 = formatinfo.positions(N)
    w1 = sum(m[r][cc] << i for i, (r, cc) in enumerate(pos1))
    w2 = sum(m[r][cc] << i for i, (r, cc) in enumerate(pos2))
    ok, lvl, mask, _ = formatinfo.decode(w1, w2)
    exp_f = (1, lvl, mask) if ok else (0, 0, 0)
    if F.get(ci) != exp_f:
        fail(f"case {ci}: format got {F.get(ci)} expected {exp_f}")
        continue
    if not ok:
        stats["format fails"] += 1
        if ci in B: fail(f"case {ci}: data was read although format failed")
        continue
    order = layout.data_order(v)
    bits = [m[r][cc] ^ (1 if layout.mask_bit(mask, r, cc) else 0) for r, cc in order]
    nb = len(bits) // 8
    exp = bytes(int("".join(map(str, bits[8*i:8*i+8])), 2) for i in range(nb)).hex()
    if B.get(ci) != exp:
        got = B.get(ci, "")
        k = next((i for i in range(0, min(len(got), len(exp)), 2) if got[i:i+2] != exp[i:i+2]), min(len(got), len(exp)))
        fail(f"case {ci} (v{v}): bytes differ, got {len(got)//2} expected {nb}, first difference at byte {k//2}")
        continue
    stats["bytes ok"] += 1
    stats["total bytes"] += nb
    nbytes, cyc = E[ci]
    if ci % 3 == 0:                      # no back-pressure: should run at the walker's speed
        overhead = cyc - (N * (N - 1) + 1)
        worst_overhead = max(worst_overhead, overhead)
        if overhead > 60: fail(f"case {ci}: {cyc} cycles, walker alone needs {N*(N-1)+1}")

print(f"reader: {stats['bytes ok']} cases with identical codeword bytes ({stats['total bytes']} bytes), "
      f"{stats['format fails']} format failures as expected, {stats['bad size']} bad sizes skipped")
print(f"speed : without back-pressure at most {worst_overhead} cycles above the walker's own N*(N-1)+1")
print("PASS" if bad == 0 else f"FAIL ({bad} mismatches)")
sys.exit(1 if bad else 0)
