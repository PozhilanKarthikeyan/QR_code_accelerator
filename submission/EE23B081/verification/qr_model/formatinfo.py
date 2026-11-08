"""Format information: positions, BCH(15,5), nearest-codeword decoding."""
from tables import FORMAT_CODEWORDS

FORMAT_XOR = 0b101010000010010   # 0x5412
FORMAT_GEN = 0b10100110111       # 0x537
LEVEL_NAME = {1: "L", 0: "M", 3: "Q", 2: "H"}   # raw 2-bit field -> name
LEVEL_FIELD = {v: k for k, v in LEVEL_NAME.items()}


def bch_encode(d5):
    """5 data bits {level(2), mask(3)} -> 15-bit stored word (Section 1.2)."""
    rem = d5 << 10
    for i in range(14, 9, -1):
        if (rem >> i) & 1:
            rem ^= FORMAT_GEN << (i - 10)
    return ((d5 << 10) | (rem & 0x3FF)) ^ FORMAT_XOR


def positions(N):
    """Table 1.  Returns (copy1, copy2), each a list of 15 (row, col), index = bit i."""
    c1 = [None] * 15
    c2 = [None] * 15
    for i in range(6):
        c1[i] = (i, 8)
        c2[i] = (8, N - 1 - i)
    c1[6], c2[6] = (7, 8), (8, N - 7)
    c1[7], c2[7] = (8, 8), (8, N - 8)
    c1[8], c2[8] = (8, 7), (N - 7, 8)
    for i in range(9, 15):
        c1[i] = (8, 14 - i)
        c2[i] = (N - 15 + i, 8)
    return c1, c2


def popcount(x):
    return bin(x).count("1")


def nearest(word15):
    """Return (index_d5, distance) of the valid word nearest to word15."""
    best = min(range(32), key=lambda d: popcount(word15 ^ FORMAT_CODEWORDS[d]))
    return best, popcount(word15 ^ FORMAT_CODEWORDS[best])


def decode(copy1, copy2):
    """G2: pick the copy nearer to a valid word (first on a tie); fail if > 3 away.

    Returns (ok, level_field, mask, info_dict)."""
    d1, dist1 = nearest(copy1)
    d2, dist2 = nearest(copy2)
    if dist1 <= dist2:
        d, dist, which = d1, dist1, 1
    else:
        d, dist, which = d2, dist2, 2
    info = dict(copy1=copy1, copy2=copy2, dist1=dist1, dist2=dist2,
                used_copy=which, d5=d)
    if dist > 3:
        return False, None, None, info
    return True, d >> 3, d & 7, info
