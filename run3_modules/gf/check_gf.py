import sys
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else "../../qr_model")
import gf256                     # the team's model, used as a second opinion

# ---- an independent reference, straight from the spec's definition
POLY = 0x11D
def ref_mul(a, b):
    r = 0
    while b:
        if b & 1: r ^= a
        a <<= 1
        if a & 0x100: a ^= POLY
        b >>= 1
    return r
def ref_pow(a, n):
    r = 1
    for _ in range(n): r = ref_mul(r, a)
    return r

bad = 0
def fail(msg):
    global bad
    bad += 1
    if bad <= 8: print("MISMATCH", msg)

n = {"M": 0, "I": 0, "X": 0, "A": 0, "N": 0}
for line in open("gf.out"):
    t = line.split()
    if not t or t[0] not in n: continue
    k = t[0]; n[k] += 1
    if k == "M":
        a, b, p = map(int, t[1:])
        if p != ref_mul(a, b) or p != gf256.mul(a, b): fail(f"mul {a}*{b} = {p}, expected {ref_mul(a, b)}")
    elif k == "I":
        a, r = map(int, t[1:])
        if a == 0:
            if r != 0: fail("inv(0) must be 0")
        elif ref_mul(a, r) != 1 or r != gf256.inv(a): fail(f"inv({a}) = {r}")
    elif k == "X":
        a, r = map(int, t[1:])
        if r != ref_mul(a, 2): fail(f"xtime({a}) = {r}")
    elif k == "A":
        e, r = map(int, t[1:])
        if r != ref_pow(2, e) or r != gf256.alpha_pow(e): fail(f"alphaPow({e}) = {r}")
    elif k == "N":
        e, r = map(int, t[1:])
        if ref_mul(r, ref_pow(2, e)) != 1: fail(f"alphaPowNeg({e}) = {r} is not the inverse of alpha^{e}")

ok = (n == {"M": 65536, "I": 256, "X": 256, "A": 255, "N": 41})
print(f"gf: multiply {n['M']}/65536 pairs, inverse {n['I']}/256, times-alpha {n['X']}/256, "
      f"alpha^k {n['A']}/255, alpha^-k {n['N']}/41 checked against the spec definition and the model")
print("PASS" if bad == 0 and ok else f"FAIL ({bad} mismatches)")
sys.exit(0 if bad == 0 and ok else 1)
