import sys, random, pickle
modeldir = sys.argv[2] if len(sys.argv) > 2 else "../../qr_model"
sys.path.insert(0, modeldir)
import rs as modelrs                       # the team's model: a second opinion
from tables import BLOCKS

LEVELS = [1, 0, 3, 2]

# ---- an independent GF(2^8) and RS encoder, straight from the spec ------------------
def gmul(a, b):
    r = 0
    while b:
        if b & 1: r ^= a
        a <<= 1
        if a & 0x100: a ^= 0x11D
        b >>= 1
    return r
def gpow(a, n):
    r = 1
    for _ in range(n): r = gmul(r, a)
    return r
def generator(e):                          # prod_{j<e} (x - alpha^j), highest power first
    g = [1]
    for j in range(e):
        r = gpow(2, j)
        ng = g + [0]
        for i in range(len(g)): ng[i + 1] ^= gmul(g[i], r)
        g = ng
    return g
def encode(data, e):                       # data followed by e check bytes
    g = generator(e)
    rem = list(data) + [0] * e
    for i in range(len(data)):
        c = rem[i]
        if c:
            for j in range(1, len(g)): rem[i + j] ^= gmul(g[j], c)
    return list(data) + rem[len(data):]

# =====================================================================================
if sys.argv[1] == "gen":
    rnd = random.Random(7)
    cases, stream, cfg = [], [], []
    plan = [(v, lf) for v in range(1, 41) for lf in LEVELS]
    for rnd_i in range(8):                             # extra rounds for the small versions
        plan += [(v, lf) for v in range(1, 9) for lf in LEVELS]
    for (v, lf) in plan:
        ec, n1, d1, n2, nb, D, total = BLOCKS[(v, lf)]
        t = ec // 2
        blocks, sent_blocks = [], []
        for b in range(nb):
            d = d1 + (1 if b >= n1 else 0)
            data = [rnd.randrange(256) for _ in range(d)]
            cw = encode(data, ec)
            assert cw[d:] == modelrs.encode(data, ec), "own encoder disagrees with the model's check bytes"
            m = len(cw)
            r = rnd.random()
            adv = False
            if r > 0.92:
                # ADVERSARIAL: g(x) is a codeword of weight e+1.  Corrupting k >= e+1-t of its terms moves the
                # block to distance e+1-k <= t of the OTHER codeword c + g*x^s, so a correct decoder must
                # "succeed" with that codeword's data, although more than t bytes are wrong.
                g = generator(ec)
                s_ = rnd.randint(0, d - 1)                     # shift: keeps every term inside the block
                idx = list(range(ec + 1)); rnd.shuffle(idx)
                k = rnd.randint(ec + 1 - t, ec + 1)
                sent = list(cw); other = list(cw)
                for i_ in range(ec + 1):
                    byte = m - 1 - (s_ + ec - i_)
                    other[byte] ^= g[i_]
                    if i_ in idx[:k]: sent[byte] ^= g[i_]
                ok_m, corr, info = modelrs.decode_block(list(sent), ec)
                assert ok_m and corr[:d] == other[:d], "model does not follow the adversarial codeword"
                exp = ("S", other[:d]); adv = True
            else:
                k = 0 if r < 0.30 else rnd.randint(1, t) if r < 0.75 else t if r < 0.85 else min(m, t + rnd.randint(1, 3))
                cand = [0, m - 1, d - 1, d, m - 2, 1]          # boundary positions get extra attention
                pos = set()
                if k and rnd.random() < 0.3:
                    rnd.shuffle(cand)
                    for c_ in cand[:rnd.randint(1, 3)]:
                        if len(pos) < k: pos.add(c_)
                while len(pos) < k: pos.add(rnd.randrange(m))
                sent = list(cw)
                for p_ in pos: sent[p_] ^= rnd.randint(1, 255)
                ok_m, corr, info = modelrs.decode_block(list(sent), ec)
                if k <= t:
                    assert ok_m and corr[:d] == data, f"model failed on a correctable block (v{v} lf{lf} b{b} k{k})"
                    exp = ("S", data)
                else:
                    exp = ("S", corr[:d]) if ok_m else ("F", None)
            blocks.append(dict(d=d, ec=ec, m=m, k=k, exp=exp, orig=data, adv=adv))
            sent_blocks.append(sent)
        # interleave as the symbol does (spec 1.4)
        out = [0] * total
        for b, sent in enumerate(sent_blocks):
            d = blocks[b]["d"]
            for i in range(d1): out[i * nb + b] = sent[i]
            if b >= n1: out[d1 * nb + (b - n1)] = sent[d1]
            for j in range(ec): out[D + j * nb + b] = sent[d + j]
        cfg.append((v << 26) | (lf << 24) | len(stream))
        stream += out
        cases.append(dict(v=v, lf=lf, blocks=blocks))
    assert len(stream) < 2**18 and len(cfg) < 1024
    open("stream.hex", "w").write("\n".join("%02x" % b for b in stream) + "\n")
    open("cfg.hex", "w").write("\n".join("%08x" % c for c in cfg) + "\n")
    pickle.dump(cases, open("cases.pkl", "wb"))
    nbk = sum(len(c["blocks"]) for c in cases)
    print(f"{len(cases)} cases, {nbk} blocks, {len(stream)} stream bytes")
    sys.exit(0)

# =====================================================================================
cases = pickle.load(open("cases.pkl", "rb"))
got = {}
for line in open("rs.out"):
    t = line.split()
    if not t or t[0] != "R": continue
    ci, b = int(t[1]), int(t[2])
    got[(ci, b)] = (t[3] if len(t) == 6 else "", t[-2], int(t[-1]))

bad = 0
def fail(msg):
    global bad
    bad += 1
    if bad <= 8: print("MISMATCH", msg)

stat = {"clean": 0, "fixed": 0, "fixed_t": 0, "beyond_fail": 0, "beyond_fix": 0, "adv": 0}
cyc = {"clean": 0, "fixed": 0, "fixed_t": 0, "beyond_fail": 0}
nblk = 0
for ci, c in enumerate(cases):
    for b, blk in enumerate(c["blocks"]):
        nblk += 1
        g = got.get((ci, b))
        if g is None: fail(f"case {ci} block {b}: no output"); continue
        hx, status, cy = g
        status_exp, data = blk["exp"]
        if status != status_exp:
            fail(f"case {ci} (v{c['v']} lf{c['lf']}) block {b}: {blk['k']} errors, e={blk['ec']}: got {status}, expected {status_exp}")
            continue
        if status == "S" and bytes.fromhex(hx) != bytes(data):
            fail(f"case {ci} (v{c['v']} lf{c['lf']}) block {b}: {blk['k']} errors: data bytes differ")
            continue
        t = blk["ec"] // 2
        key = ("adv" if blk.get("adv") else "clean" if blk["k"] == 0 else "fixed_t" if blk["k"] == t else "fixed" if blk["k"] < t
               else "beyond_fail" if status == "F" else "beyond_fix")
        stat[key] += 1
        if key in cyc: cyc[key] = max(cyc[key], cy)

print(f"rs: {nblk - bad}/{nblk} blocks match: "
      f"{stat['clean']} clean, {stat['fixed']} fixed (1..t-1 errors), {stat['fixed_t']} fixed with exactly t errors, "
      f"{stat['beyond_fail']} too damaged -> failed, {stat['beyond_fix']} random ones within reach of another codeword (model agrees), "
      f"{stat['adv']} built to be within reach of another codeword (decoded to it, as a correct decoder must)")
print(f"speed: slowest block (cycles) clean {cyc['clean']}, fixed {cyc['fixed']}, fixed with t errors {cyc['fixed_t']}, failed {cyc['beyond_fail']}")
done = "DONE" in open("rs.out").read()
print("PASS" if bad == 0 and done else f"FAIL ({bad} mismatches, finished={done})")
sys.exit(0 if bad == 0 and done else 1)
