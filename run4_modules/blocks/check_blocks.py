import sys, random
sys.path.insert(0, sys.argv[2] if len(sys.argv) > 2 else "../../qr_model")
from tables import BLOCKS            # parsed from the supplied QRTables.bsv

LEVELS = [1, 0, 3, 2]                # the raw 2-bit level fields, in the order the test bench uses

def block_layout(v, lf):
    ec, n1, d1, n2, nb, D, total = BLOCKS[(v, lf)]
    return ec, n1, d1, n2, nb, D, total

if sys.argv[1] == "gen":             # write stream.hex: random bytes for every (version, level)
    rnd = random.Random(2026)
    out = []
    for v in range(1, 41):
        for lf in LEVELS:
            total = block_layout(v, lf)[6]
            out += [rnd.randrange(256) for _ in range(total)]
    assert len(out) < 2**18
    open("stream.hex", "w").write("\n".join("%02x" % b for b in out) + "\n")
    print(f"stream.hex: {len(out)} bytes for 160 (version, level) pairs")
    sys.exit(0)

cap = int(sys.argv[1])
stream = [int(x, 16) for x in open("stream.hex").read().split()]

# ---- what the spec says block b must contain (Section 1.4's formula for k)
def expected_blocks(v, lf, data):
    ec, n1, d1, n2, nb, D, total = block_layout(v, lf)
    blocks = []
    for b in range(nb):
        d = d1 + (1 if b >= n1 else 0)
        ks = [i * nb + b for i in range(d1)]
        if b >= n1: ks.append(d1 * nb + (b - n1))
        ks += [D + j * nb + b for j in range(ec)]
        blocks.append((d, bytes(data[k] for k in ks)))
    return blocks

# ---- parse the simulator output
groups, blks = {}, {}
for line in open("blocks.out"):
    t = line.split()
    if not t: continue
    if t[0] == "G":
        v, lf, g0, g1 = map(int, t[1:5]); groups.setdefault((v, lf), []).append((g0, g1))
    elif t[0] == "K":
        v, lf, b, d, ln = map(int, t[1:6]); blks.setdefault((v, lf), []).append((b, d, ln, t[6]))

bad = 0
def fail(msg):
    global bad
    bad += 1
    if bad <= 8: print("MISMATCH", msg)

off = 0
npass = 0; maxpass = 0; nblocks = 0
for v in range(1, 41):
    for lf in LEVELS:
        ec, n1, d1, n2, nb, D, total = block_layout(v, lf)
        data = stream[off:off + total]; off += total
        exp = expected_blocks(v, lf, data)
        lens = [d + ec for d, _ in exp]
        # the groups: contiguous, cover all blocks, greedy and within capacity
        g = groups.get((v, lf), [])
        pos = 0
        for (g0, g1) in g:
            if g0 != pos: fail(f"v{v} lf{lf}: group starts at {g0}, expected {pos}")
            s = sum(lens[g0:g1])
            if s > cap: fail(f"v{v} lf{lf}: group {g0}-{g1} needs {s} bytes > cap {cap}")
            if g1 < nb and s + lens[g1] <= cap: fail(f"v{v} lf{lf}: group {g0}-{g1} not maximal")
            if g1 <= g0: fail(f"v{v} lf{lf}: empty group")
            pos = g1
        if pos != nb: fail(f"v{v} lf{lf}: groups end at {pos}, expected {nb}")
        npass += len(g); maxpass = max(maxpass, len(g))
        # the blocks: all of them, once, in order, with the right bytes
        got = blks.get((v, lf), [])
        if [x[0] for x in got] != list(range(nb)): fail(f"v{v} lf{lf}: blocks read {[x[0] for x in got][:6]}..."); continue
        for (b, d, ln, hx), (ed, ebytes) in zip(got, exp):
            nblocks += 1
            if (d, ln) != (ed, len(ebytes)): fail(f"v{v} lf{lf} block {b}: length {d}/{ln}, expected {ed}/{len(ebytes)}")
            elif bytes.fromhex(hx) != ebytes: fail(f"v{v} lf{lf} block {b}: bytes differ")

print(f"blocks (cap {cap}): checked {nblocks} blocks of 160 (version, level) pairs against the spec's interleaving formula; "
      f"{npass} passes in total, at most {maxpass} for one symbol")
print("PASS" if bad == 0 and "DONE" in open("blocks.out").read() else f"FAIL ({bad} mismatches)")
sys.exit(1 if bad else 0)
