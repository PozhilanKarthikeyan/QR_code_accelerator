"""Top-level reference decoder: matrix in, bytes (or failure) out.

decode() follows G1..G4 of the spec and records every intermediate result in
Result.trace, so when the RTL disagrees you can see where the two first part.
"""
from dataclasses import dataclass, field

import formatinfo
import layout
import payload
import rs
from tables import BLOCKS


@dataclass
class Result:
    ok: bool
    data: bytes = b""
    reason: str = "ok"
    trace: dict = field(default_factory=dict)

    @property
    def done_empty(self):
        return self.ok and len(self.data) == 0


def _get(matrix, r, c):
    """Reads outside the matrix return 0, as the test bench does."""
    if 0 <= r < len(matrix) and 0 <= c < len(matrix[r]):
        return matrix[r][c] & 1
    return 0


def read_format_copies(matrix, N):
    c1, c2 = formatinfo.positions(N)
    w1 = sum(_get(matrix, r, c) << i for i, (r, c) in enumerate(c1))
    w2 = sum(_get(matrix, r, c) << i for i, (r, c) in enumerate(c2))
    return w1, w2


def read_codewords(matrix, v, mask):
    """Zigzag read + unmask + pack into bytes (ignoring leftover bits)."""
    order = layout.data_order(v)
    bits = []
    for (r, c) in order:
        b = _get(matrix, r, c)
        if layout.mask_bit(mask, r, c):
            b ^= 1
        bits.append(b)
    nbytes = len(bits) // 8
    return [int("".join(map(str, bits[8 * i:8 * i + 8])), 2) for i in range(nbytes)]


def deinterleave(cw, p):
    """Split the symbol's bytes into blocks of (data, check).  p = BLOCKS entry."""
    ec, n1, d1, n2, nb, D, total = p
    blocks = []
    for b in range(nb):
        dlen = d1 if b < n1 else d1 + 1
        data = []
        for i in range(dlen):
            k = i * nb + b if i < d1 else d1 * nb + (b - n1)
            data.append(cw[k])
        chk = [cw[D + j * nb + b] for j in range(ec)]
        blocks.append((data, chk))
    return blocks


def decode(matrix, N=None):
    """matrix: list of rows (each a list/bytearray of 0/1).  N: side length given to start()."""
    if N is None:
        N = len(matrix)
    tr = {"N": N}

    v = layout.version_of_side(N)                                   # G1
    if v is None:
        return Result(False, reason="bad side length", trace=tr)
    tr["version"] = v

    w1, w2 = read_format_copies(matrix, N)                          # G2
    ok, level, mask, finfo = formatinfo.decode(w1, w2)
    tr["format"] = finfo
    if not ok:
        return Result(False, reason="format information unreadable", trace=tr)
    tr["level"] = formatinfo.LEVEL_NAME[level]
    tr["mask"] = mask

    p = BLOCKS[(v, level)]                                          # G3
    tr["block_params"] = p
    cw = read_codewords(matrix, v, mask)
    tr["raw_codewords"] = cw
    assert len(cw) >= p[6]
    cw = cw[:p[6]]
    blocks = deinterleave(cw, p)
    ec = p[0]
    data = []
    tr["blocks"] = []
    for b, (d, chk) in enumerate(blocks):
        okb, fixed, info = rs.decode_block(d + chk, ec)
        info["before"] = d + chk
        info["after"] = fixed
        tr["blocks"].append(info)
        if not okb:
            return Result(False, reason=f"block {b} uncorrectable", trace=tr)
        data += fixed[:len(d)]
    tr["data_bytes"] = data

    okp, msg, why = payload.parse(data, v)                          # G4
    if not okp:
        return Result(False, reason="payload: " + why, trace=tr)
    return Result(True, msg, "ok", tr)
