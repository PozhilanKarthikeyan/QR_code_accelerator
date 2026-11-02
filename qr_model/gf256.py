"""GF(2^8) arithmetic, polynomial x^8+x^4+x^3+x^2+1 (0x11D), alpha = 2.

Two multipliers are provided on purpose:
  * mul()       - log/antilog tables, fast, used by the rest of the model
  * mul_shift() - bit-serial shift-and-add; this is the structure you would
                  put in hardware, so test_model.py checks the two agree on
                  all 65536 input pairs.
"""
POLY = 0x11D

EXP = [0] * 512
LOG = [0] * 256
_x = 1
for _i in range(255):
    EXP[_i] = _x
    LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= POLY
for _i in range(255, 512):
    EXP[_i] = EXP[_i - 255]


def mul(a, b):
    if a == 0 or b == 0:
        return 0
    return EXP[LOG[a] + LOG[b]]


def mul_shift(a, b):
    """Shift-and-add multiply (hardware-style reference)."""
    r = 0
    for i in range(8):
        if (b >> i) & 1:
            r ^= a
        a <<= 1
        if a & 0x100:
            a ^= POLY
    return r


def inv(a):
    """Multiplicative inverse; inv(0) = 0 (same convention as gfInv in QRTables.bsv)."""
    if a == 0:
        return 0
    return EXP[255 - LOG[a]]


def div(a, b):
    if b == 0:
        raise ZeroDivisionError
    if a == 0:
        return 0
    return EXP[(LOG[a] - LOG[b]) % 255]


def alpha_pow(j):
    """alpha^j for any integer j (negative allowed)."""
    return EXP[j % 255]


def poly_eval(p, x):
    """Evaluate polynomial given in ASCENDING order (p[k] = coeff of x^k)."""
    r = 0
    for c in reversed(p):
        r = mul(r, x) ^ c
    return r
