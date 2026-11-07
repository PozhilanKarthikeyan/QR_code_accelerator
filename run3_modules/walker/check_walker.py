import sys
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else "../../qr_model")
import layout

# ---- walker: compare against layout.data_order for every version
seq, cur, ok, cyc = {}, None, True, {}
for line in open("walker.out"):
    t = line.split()
    if not t: continue
    if t[0] == "V": cur = int(t[1]); seq[cur] = []
    elif t[0] == "P": seq[cur].append((int(t[1]), int(t[2])))
    elif t[0] == "E": cyc[int(t[1])] = (int(t[2]), int(t[3]))
bad = 0
for v in range(1, 41):
    exp = list(layout.data_order(v))
    got = seq.get(v, [])
    if got != exp:
        bad += 1
        i = next((k for k,(a,b) in enumerate(zip(got,exp)) if a!=b), min(len(got),len(exp)))
        print(f"v{v}: MISMATCH got {len(got)} exp {len(exp)}; first diff at #{i}: got {got[i:i+2]} exp {exp[i:i+2]}")
print(f"walker: {40-bad}/40 versions identical to model's data_order")
for v in (1, 2, 7, 40):
    n, c = cyc[v]; N = 17+4*v
    print(f"  v{v}: {n} data modules, {c} cycles ({c-n} cycles lost skipping function modules; N*N={N*N})")

# ---- masks
got = {}
for line in open("mask.out"):
    t = line.split()
    if t and t[0] == "M": got[(int(t[1]), int(t[2]))] = t[3]
bad = 0
for m in range(8):
    for r in range(177):
        exp = "".join("1" if layout.mask_bit(m, r, c) else "0" for c in range(177))
        if got.get((m, r)) != exp:
            bad += 1
            if bad <= 3: print(f"mask {m} row {r} differs")
print(f"masks: {8*177-bad}/{8*177} rows identical to model's mask_bit (all 8 masks x 177x177 modules)")
