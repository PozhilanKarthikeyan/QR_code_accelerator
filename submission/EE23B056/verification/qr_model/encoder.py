"""Independent QR *encoder* used only to generate test symbols.

It exists so we can build things segno will not give us: several segments,
empty messages, malformed payloads, exact damage patterns.  It is validated
against segno in test_model.py (same data + mask => identical matrix), so it
does not share a misreading with decoder.py.
"""
import formatinfo
import layout
import payload
import rs
from payload import ALNUM, count_width
from tables import BLOCKS

VERSION_GEN = 0x1F25


def version_bits(v):
    rem = v << 12
    for i in range(17, 11, -1):
        if (rem >> i) & 1:
            rem ^= VERSION_GEN << (i - 12)
    return (v << 12) | (rem & 0xFFF)


# ---------------------------------------------------------------- payload ---
def segment_bits(seg, v):
    """seg = ('numeric', '0123') | ('alnum', 'AB C') | ('byte', b'..') | ('raw', '0101..')."""
    kind, val = seg
    if kind == "raw":
        return val
    if kind == "numeric":
        s = f"0001{len(val):0{count_width(1, v)}b}"
        for i in range(0, len(val), 3):
            g = val[i:i + 3]
            w = {3: 10, 2: 7, 1: 4}[len(g)]
            s += f"{int(g):0{w}b}"
        return s
    if kind == "alnum":
        s = f"0010{len(val):0{count_width(2, v)}b}"
        for i in range(0, len(val), 2):
            g = val[i:i + 2]
            if len(g) == 2:
                s += f"{45 * ALNUM.index(g[0]) + ALNUM.index(g[1]):011b}"
            else:
                s += f"{ALNUM.index(g):06b}"
        return s
    if kind == "byte":
        s = f"0100{len(val):0{count_width(4, v)}b}"
        return s + "".join(f"{b:08b}" for b in val)
    raise ValueError(kind)


def pad_to_capacity(bits, capacity_bytes):
    cap = capacity_bytes * 8
    if len(bits) > cap:
        raise ValueError("does not fit")
    bits += "0" * min(4, cap - len(bits))           # terminator
    bits += "0" * (-len(bits) % 8)
    pad = [0xEC, 0x11]
    i = 0
    while len(bits) < cap:
        bits += f"{pad[i % 2]:08b}"
        i += 1
    return [int(bits[k:k + 8], 2) for k in range(0, cap, 8)]


# ----------------------------------------------------------- codewords ------
def interleave(blocks, p):
    """blocks = list of (data, chk).  Inverse of decoder.deinterleave."""
    ec, n1, d1, n2, nb, D, total = p
    cw = [0] * total
    for b, (data, chk) in enumerate(blocks):
        for i, x in enumerate(data):
            k = i * nb + b if i < d1 else d1 * nb + (b - n1)
            cw[k] = x
        for j, x in enumerate(chk):
            cw[D + j * nb + b] = x
    return cw


def make_codewords(v, level, data_bytes):
    p = BLOCKS[(v, level)]
    ec, n1, d1, n2, nb, D, total = p
    assert len(data_bytes) == D
    blocks, pos = [], 0
    for b in range(nb):
        dl = d1 if b < n1 else d1 + 1
        d = list(data_bytes[pos:pos + dl])
        pos += dl
        blocks.append((d, rs.encode(d, ec)))
    return interleave(blocks, p)


# -------------------------------------------------------------- matrix ------
def build_matrix(v, level, mask, codewords):
    N = layout.side(v)
    m = [[0] * N for _ in range(N)]

    for (r0, c0) in ((0, 0), (0, N - 7), (N - 7, 0)):          # finders
        for dr in range(7):
            for dc in range(7):
                ring = max(abs(dr - 3), abs(dc - 3))
                m[r0 + dr][c0 + dc] = 0 if ring == 2 else 1
    for i in range(8, N - 8):                                  # timing
        m[6][i] = m[i][6] = 1 if i % 2 == 0 else 0
    for (r, c) in layout.align_centres(v):                     # alignment
        for dr in range(-2, 3):
            for dc in range(-2, 3):
                m[r + dr][c + dc] = 0 if max(abs(dr), abs(dc)) == 1 else 1
    m[N - 8][8] = 1                                            # dark module
    if v >= 7:                                                 # version info
        vb = version_bits(v)
        for i in range(18):
            bit = (vb >> i) & 1
            m[i // 3][N - 11 + i % 3] = bit
            m[N - 11 + i % 3][i // 3] = bit

    bits = [(x >> (7 - k)) & 1 for x in codewords for k in range(8)]
    for k, (r, c) in enumerate(layout.data_order(v)):
        b = bits[k] if k < len(bits) else 0
        if layout.mask_bit(mask, r, c):
            b ^= 1
        m[r][c] = b

    write_format(m, N, formatinfo.bch_encode((level << 3) | mask))
    return m


def write_format(m, N, word15):
    c1, c2 = formatinfo.positions(N)
    for i in range(15):
        bit = (word15 >> i) & 1
        m[c1[i][0]][c1[i][1]] = bit
        m[c2[i][0]][c2[i][1]] = bit


def encode(v, level, mask, segments):
    """Segments -> finished matrix.  level is the raw 2-bit field (1=L,0=M,3=Q,2=H)."""
    p = BLOCKS[(v, level)]
    bits = "".join(segment_bits(s, v) for s in segments)
    data = pad_to_capacity(bits, p[5])
    return build_matrix(v, level, mask, make_codewords(v, level, data))
