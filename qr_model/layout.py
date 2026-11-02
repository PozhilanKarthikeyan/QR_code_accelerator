"""Symbol geometry: function-module map, masks, zigzag reading order."""
from functools import lru_cache
from tables import ALIGN


def side(v):
    return 17 + 4 * v


def version_of_side(N):
    """G1: version for a side length, or None."""
    if N >= 21 and (N - 17) % 4 == 0 and (N - 17) // 4 <= 40:
        return (N - 17) // 4
    return None


def align_centres(v):
    """All alignment-pattern centres, minus the three that collide with finders."""
    lst = ALIGN[v]
    out = []
    for i, r in enumerate(lst):
        for j, c in enumerate(lst):
            last = len(lst) - 1
            if (i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0):
                continue
            out.append((r, c))
    return out


@lru_cache(maxsize=None)
def function_map(v):
    """N x N tuple-of-tuples of bool: True = function module."""
    N = side(v)
    f = [[False] * N for _ in range(N)]

    def box(r0, c0, h, w):
        for r in range(r0, r0 + h):
            for c in range(c0, c0 + w):
                f[r][c] = True

    box(0, 0, 8, 8)                 # finder + separator, top-left
    box(0, N - 8, 8, 8)             # top-right
    box(N - 8, 0, 8, 8)             # bottom-left
    for i in range(N):              # timing patterns
        f[6][i] = True
        f[i][6] = True
    box(8, 0, 1, 9)                 # format information, row 8 (left)
    box(8, N - 8, 1, 8)             # row 8 (right)
    box(0, 8, 9, 1)                 # column 8 (top)
    box(N - 8, 8, 8, 1)             # column 8 (bottom) - includes the dark module
    for (r, c) in align_centres(v):
        box(r - 2, c - 2, 5, 5)
    if v >= 7:                      # version information
        box(0, N - 11, 6, 3)
        box(N - 11, 0, 3, 6)
    return tuple(tuple(row) for row in f)


@lru_cache(maxsize=None)
def data_order(v):
    """List of (row, col) of the data modules in reading order (Section 1.3)."""
    N = side(v)
    f = function_map(v)
    out = []
    right = N - 1
    upward = True
    while right >= 1:
        if right == 6:
            right = 5
        rows = range(N - 1, -1, -1) if upward else range(N)
        for r in rows:
            for c in (right, right - 1):
                if not f[r][c]:
                    out.append((r, c))
        upward = not upward
        right -= 2
    return tuple(out)


def mask_bit(m, r, c):
    """True where mask m inverts the module (Table 2)."""
    if m == 0: return (r + c) % 2 == 0
    if m == 1: return r % 2 == 0
    if m == 2: return c % 3 == 0
    if m == 3: return (r + c) % 3 == 0
    if m == 4: return (r // 2 + c // 3) % 2 == 0
    if m == 5: return (r * c) % 2 + (r * c) % 3 == 0
    if m == 6: return ((r * c) % 2 + (r * c) % 3) % 2 == 0
    if m == 7: return (((r + c) % 2) + (r * c) % 3) % 2 == 0
    raise ValueError(m)
