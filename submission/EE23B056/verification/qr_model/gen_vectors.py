#!/usr/bin/env python3
"""Generate test vectors for the RTL: symbols + expected outputs.

    python3 gen_vectors.py --out vectors --seed 1 [--scale 1]

Every case is checked against the model before it is written (the expected
bytes come from the *message that was encoded*, not from the decoder), so a
disagreement here is a bug in the generator or the model, not in your RTL.

Output files (all hex, one word per line, ready for $readmemh / mkRegFileLoad):
  symbols.hex      concatenated rows of all symbols.  Each row is 180 bits
                   (45 hex digits); module (r, c) is bit (179 - c) of the word,
                   i.e. column 0 is the most significant bit.
  cases.hex        one 128-bit word per case:
                     [127:120] side length N        [119:112] status (1 = ok, 0 = failed)
                     [111:96]  message length (bytes)
                     [95:64]   offset of first byte in expect_data.hex
                     [63:32]   index of first row in symbols.hex   [31:0] 0
  expect_data.hex  expected bytes of all successful cases, concatenated.
  cases.json       the same information for Python / cocotb, plus a name per case.
"""
import argparse
import json
import os
import random

import decoder
import encoder
import formatinfo
import layout
from payload import ALNUM, count_width
from tables import BLOCKS

ROW_BITS = 180
LEVELS = [1, 0, 3, 2]


# ---------------------------------------------------------------- helpers ---
def expected_bytes(segs):
    out = b""
    for kind, val in segs:
        if kind in ("numeric", "alnum"):
            out += val.encode()
        elif kind == "byte":
            out += bytes(val)
    return out


def rand_segment(rnd, kind, n):
    if kind == "numeric":
        return ("numeric", "".join(rnd.choice("0123456789") for _ in range(n)))
    if kind == "alnum":
        return ("alnum", "".join(rnd.choice(ALNUM) for _ in range(n)))
    return ("byte", bytes(rnd.randrange(256) for _ in range(n)))


def fit(v, lvl, segs):
    try:
        encoder.encode(v, lvl, 0, segs)
        return True
    except ValueError:
        return False


def fit_segment(rnd, v, lvl, kind, n):
    """Random segment of at most n characters that fits (version v, level lvl)."""
    while True:
        seg = rand_segment(rnd, kind, n)
        if n <= 1 or fit(v, lvl, [seg]):
            return seg
        n -= 1


def block_indices(p):
    """For each block, the list of symbol byte indices (data bytes then check bytes)."""
    ec, n1, d1, n2, nb, D, total = p
    res = []
    for b in range(nb):
        dl = d1 + (1 if b >= n1 else 0)
        idx = [i * nb + b if i < d1 else d1 * nb + (b - n1) for i in range(dl)]
        idx += [D + j * nb + b for j in range(ec)]
        res.append(idx)
    return res


def byte_modules(v, total):
    order = layout.data_order(v)
    return [order[8 * k:8 * k + 8] for k in range(total)]


def damage_bytes(mat, v, p, per_block, rnd):
    """Damage exactly per_block[b] distinct bytes in block b (data or check), flipping 1..8 modules each."""
    mods = byte_modules(v, p[6])
    for b, idx in enumerate(block_indices(p)):
        for k in rnd.sample(idx, per_block[b]):
            nflip = rnd.randrange(1, 9)
            for (r, c) in rnd.sample(mods[k], nflip):
                mat[r][c] ^= 1
            # make sure the byte really changed (it did: >= 1 module flipped)


def flip_format(mat, N, n1, n2, rnd):
    c1, c2 = formatinfo.positions(N)
    for rc in rnd.sample(c1, n1) + rnd.sample(c2, n2):
        mat[rc[0]][rc[1]] ^= 1


def copy(m):
    return [row[:] for row in m]


class Suite:
    def __init__(self, seed):
        self.rnd = random.Random(seed)
        self.cases = []

    def add(self, name, mat, N, ok, data=b""):
        r = decoder.decode(mat, N)
        assert r.ok == ok, f"{name}: model says ok={r.ok} ({r.reason}), expected {ok}"
        if ok:
            assert r.data == data, f"{name}: model decoded {r.data!r}, expected {data!r}"
        self.cases.append(dict(name=name, N=N, matrix=mat, ok=ok, data=data if ok else b""))

    # --------------------------------------------------------------------
    def clean(self, scale):
        rnd = self.rnd
        for v in range(1, 41):
            for lvl in LEVELS:
                for _ in range(scale):
                    kind = rnd.choice(["numeric", "alnum", "byte"])
                    n = rnd.choice([1, 2, 3, 5, 8, 20, 50, 200])
                    while n > 1 and not fit(v, lvl, [rand_segment(rnd, kind, n)]):
                        n //= 2
                    segs = [rand_segment(rnd, kind, n)]
                    mask = rnd.randrange(8)
                    mat = encoder.encode(v, lvl, mask, segs)
                    self.add(f"clean v{v} {formatinfo.LEVEL_NAME[lvl]} m{mask} {kind}{n}",
                             mat, len(mat), True, expected_bytes(segs))

    def corner_messages(self):
        rnd = self.rnd
        for v in (1, 9, 10, 26, 27, 40):               # both sides of the count-width changes
            for lvl in (1, 2):
                for kind, ns in (("numeric", [1, 2, 3, 4, 5]), ("alnum", [1, 2, 3]),
                                 ("byte", [1])):
                    for n in ns:
                        segs = [rand_segment(rnd, kind, n)]
                        mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                        self.add(f"short v{v} {kind}{n}", mat, len(mat), True, expected_bytes(segs))
                # multi-segment
                for sizes in ((4, 3, 5, 1), (2, 2, 1, 1), (1, 1, 0, 1)):
                    segs = [rand_segment(rnd, "numeric", sizes[0]), rand_segment(rnd, "alnum", sizes[1]),
                            rand_segment(rnd, "byte", sizes[2]), rand_segment(rnd, "numeric", sizes[3])]
                    if fit(v, lvl, segs):
                        mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                        self.add(f"multiseg v{v}", mat, len(mat), True, expected_bytes(segs))
                        break
                # empty message
                mat = encoder.encode(v, lvl, rnd.randrange(8), [])
                self.add(f"empty v{v}", mat, len(mat), True, b"")
                # numeric segment with count 0 (also an empty message)
                mat = encoder.encode(v, lvl, rnd.randrange(8), [("numeric", "")])
                self.add(f"empty-numeric v{v}", mat, len(mat), True, b"")
                # full capacity, byte mode
                n = BLOCKS[(v, lvl)][5]
                while not fit(v, lvl, [("byte", bytes(n))]):
                    n -= 1
                segs = [rand_segment(rnd, "byte", n)]
                mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                self.add(f"full v{v} {formatinfo.LEVEL_NAME[lvl]} byte{n}", mat, len(mat), True,
                         expected_bytes(segs))

    def max_damage(self, scale):
        rnd = self.rnd
        for v in range(1, 41):
            for lvl in LEVELS:
                p = BLOCKS[(v, lvl)]
                t = p[0] // 2
                for _ in range(scale):
                    segs = [fit_segment(rnd, v, lvl, "byte", rnd.randrange(1, 12))]
                    mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                    # (a) exactly t damaged bytes in every block
                    dm = copy(mat)
                    damage_bytes(dm, v, p, [t] * p[4], rnd)
                    self.add(f"damage t/blk v{v} {formatinfo.LEVEL_NAME[lvl]}", dm, len(dm), True,
                             expected_bytes(segs))
                    # (b) a random number (0..t) of damaged bytes per block
                    dm = copy(mat)
                    damage_bytes(dm, v, p, [rnd.randrange(t + 1) for _ in range(p[4])], rnd)
                    self.add(f"damage rnd v{v} {formatinfo.LEVEL_NAME[lvl]}", dm, len(dm), True,
                             expected_bytes(segs))

    def function_damage(self, scale):
        rnd = self.rnd
        for v in range(1, 41, 3):
            for lvl in LEVELS:
                segs = [fit_segment(rnd, v, lvl, "alnum", rnd.randrange(1, 10))]
                mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                N = len(mat)
                fm = layout.function_map(v)
                c1, c2 = formatinfo.positions(N)
                fmt = set(c1) | set(c2)
                cand = [(r, c) for r in range(N) for c in range(N) if fm[r][c] and (r, c) not in fmt]
                dm = copy(mat)
                for (r, c) in rnd.sample(cand, min(len(cand), rnd.randrange(10, 80))):
                    dm[r][c] ^= 1
                self.add(f"function damage v{v}", dm, N, True, expected_bytes(segs))
                # wipe all three finder patterns
                dm = copy(mat)
                for (r0, c0) in ((0, 0), (0, N - 7), (N - 7, 0)):
                    for dr in range(7):
                        for dc in range(7):
                            dm[r0 + dr][c0 + dc] = 0
                self.add(f"finders erased v{v}", dm, N, True, expected_bytes(segs))

    def format_damage(self):
        rnd = self.rnd
        for v in (1, 2, 7, 22, 40):
            for lvl in LEVELS:
                for mask in (0, 3, 7):
                    segs = [fit_segment(rnd, v, lvl, "byte", 5)]
                    mat = encoder.encode(v, lvl, mask, segs)
                    N = len(mat)
                    for n1, n2 in ((3, 0), (0, 3), (3, 3), (1, 2), (2, 3), (3, 1)):
                        dm = copy(mat)
                        flip_format(dm, N, n1, n2, rnd)
                        self.add(f"format {n1}+{n2} bad v{v}", dm, N, True, expected_bytes(segs))
                    # copy 1 destroyed (4..8 errors), copy 2 clean / with <=3 errors
                    # A badly damaged copy 1 can sit nearer to a *different* valid word than
                    # copy 2 is to the right one; the spec then picks copy 1, so retry until
                    # the pair really does decode to the original settings.
                    for attempt in range(100):
                        dm = copy(mat)
                        flip_format(dm, N, rnd.randrange(4, 9), rnd.randrange(0, 4), rnd)
                        r = decoder.decode(dm, N)
                        if r.ok and r.data == expected_bytes(segs):
                            self.add(f"format copy1 gone v{v}", dm, N, True, expected_bytes(segs))
                            break

    # ------------------------------------------------------- must fail ----
    def failures(self, scale):
        rnd = self.rnd
        # one damaged byte too many in one block
        for v in range(1, 41):
            for lvl in LEVELS:
                p = BLOCKS[(v, lvl)]
                t = p[0] // 2
                for _ in range(scale):
                    segs = [fit_segment(rnd, v, lvl, "byte", rnd.randrange(1, 8))]
                    mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                    for attempt in range(20):
                        dm = copy(mat)
                        per = [rnd.randrange(t + 1) for _ in range(p[4])]
                        per[rnd.randrange(p[4])] = t + 1
                        damage_bytes(dm, v, p, per, rnd)
                        if not decoder.decode(dm).ok:      # A5: a correct decoder must reject
                            self.add(f"too many errors v{v} {formatinfo.LEVEL_NAME[lvl]}", dm,
                                     len(dm), False)
                            break
        # format information past repair (both copies >3 away from every valid word)
        for v in (1, 5, 21, 40):
            for lvl in LEVELS:
                segs = [fit_segment(rnd, v, lvl, "byte", 4)]
                mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                N = len(mat)
                for k in range(8):
                    for attempt in range(200):
                        dm = copy(mat)
                        flip_format(dm, N, rnd.randrange(4, 9), rnd.randrange(4, 9), rnd)
                        if not decoder.decode(dm).ok:
                            self.add(f"format unreadable v{v}", dm, N, False)
                            break
        # bad side length
        for n in (0, 1, 17, 20, 22, 23, 24, 26, 100, 178, 181, 200, 255):
            self.add(f"bad size {n}", [[0] * 21 for _ in range(21)], n, False)
        self.add("bad size: v2 symbol, N=24 given", encoder.encode(2, 1, 0, [("byte", b"x")]), 24, False)
        # malformed payloads (valid Reed-Solomon, bad content)
        for v in (1, 9, 10, 26, 27, 40):
            w = lambda m: count_width(m, v)
            bad = {
                "unknown mode 1111": "1111" + "0" * 20,
                "ECI mode 0111": "0111" + "00000011" + "0" * 12,
                "kanji mode 1000": "1000" + "0" * 20,
                "structured append 0011": "0011" + "0" * 20,
                "numeric >999": "0001" + format(3, f"0{w(1)}b") + "1111111111",
                "numeric pair >99": "0001" + format(2, f"0{w(1)}b") + "1111111",
                "numeric single >9": "0001" + format(1, f"0{w(1)}b") + "1111",
                "alnum pair >2024": "0010" + format(2, f"0{w(2)}b") + format(2025, "011b"),
                "alnum single >44": "0010" + format(1, f"0{w(2)}b") + format(45, "06b"),
                "byte runs past end": "0100" + format(2 ** w(4) - 1, f"0{w(4)}b") + "0" * 16,
                "numeric runs past end": "0001" + format(2 ** w(1) - 1, f"0{w(1)}b") + "0" * 20,
                "alnum runs past end": "0010" + format(2 ** w(2) - 1, f"0{w(2)}b") + "0" * 20,
            }
            for lvl in (1, 2):
                for name, bits in bad.items():
                    # a valid segment first, so bytes would already have been emitted
                    segs = [("numeric", "42"), ("raw", bits)]
                    p = BLOCKS[(v, lvl)]
                    if len(encoder.segment_bits(segs[0], v)) + len(bits) > p[5] * 8:
                        continue
                    mat = encoder.encode(v, lvl, rnd.randrange(8), segs)
                    self.add(f"malformed '{name}' v{v}", mat, len(mat), False)

    # ------------------------------------------------------------- export --
    def write(self, out):
        os.makedirs(out, exist_ok=True)
        rows, data, meta, js = [], [], [], []
        for c in self.cases:
            N = c["N"]
            row0 = len(rows)
            for r in range(len(c["matrix"])):
                word = 0
                for col, bit in enumerate(c["matrix"][r]):
                    word |= (bit & 1) << (ROW_BITS - 1 - col)
                rows.append(f"{word:045x}")
            off = len(data)
            data += [f"{b:02x}" for b in c["data"]]
            word = (N << 120) | ((1 if c["ok"] else 0) << 112) | (len(c["data"]) << 96) \
                | (off << 64) | (row0 << 32)
            meta.append(f"{word:032x}")
            js.append(dict(name=c["name"], N=N, ok=c["ok"], data=c["data"].hex(),
                           rows=["".join(map(str, r)) for r in c["matrix"]]))
        open(os.path.join(out, "symbols.hex"), "w").write("\n".join(rows) + "\n")
        open(os.path.join(out, "cases.hex"), "w").write("\n".join(meta) + "\n")
        open(os.path.join(out, "expect_data.hex"), "w").write("\n".join(data) + "\n")
        json.dump(js, open(os.path.join(out, "cases.json"), "w"))
        n_ok = sum(c["ok"] for c in self.cases)
        print(f"wrote {len(self.cases)} cases ({n_ok} decodable, {len(self.cases) - n_ok} must fail) to {out}/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="vectors")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--scale", type=int, default=1, help="multiplies the number of random cases")
    a = ap.parse_args()
    s = Suite(a.seed)
    s.clean(a.scale)
    s.corner_messages()
    s.max_damage(a.scale)
    s.function_damage(a.scale)
    s.format_damage()
    s.failures(a.scale)
    s.write(a.out)


if __name__ == "__main__":
    main()
