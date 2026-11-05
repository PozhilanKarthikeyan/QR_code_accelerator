#!/usr/bin/env python3
"""Payload parser (unit 6): test-vector generator and checker.

  python3 check_payload.py gen   [model_dir]   writes cfg.hex, stream.hex, expect.json
  python3 check_payload.py check [model_dir]   reads payload.out (from the Bluesim test bench), compares, prints a summary

Expected results come from ref_parse() below, written from spec Section 1.5 / G4, and are cross-checked against
the model's payload.parse (a disagreement is reported at `gen` time and stops the run).  Constructed cases also carry
the message that was encoded, which must match ref_parse (so the reference itself is tested).
"""
import json
import random
import sys

MODEL = sys.argv[2] if len(sys.argv) > 2 else "../../qr_model"
sys.path.insert(0, MODEL)
import payload as model            # the team's model, used as a second opinion

ALN = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
CW = {"N": (10, 12, 14), "A": (9, 11, 13), "B": (8, 16, 16)}
MODE = {"N": "0001", "A": "0010", "B": "0100"}
TERM = "0000"
EDGE_VERS = [1, 9, 10, 26, 27, 40]


def cls(v):
    return 0 if v <= 9 else (1 if v <= 26 else 2)


# --------------------------------------------------- reference parser (spec 1.5, G4)
def ref_parse(data, ver):
    """-> ('ok', bytes) or ('fail', None)."""
    bits = "".join(format(x, "08b") for x in data)
    i = 0
    out = bytearray()

    def left():
        return len(bits) - i

    while left() >= 4:
        m = bits[i:i + 4]
        i += 4
        if m == "0000":
            return "ok", bytes(out)
        kind = {"0001": "N", "0010": "A", "0100": "B"}.get(m)
        if kind is None:
            return "fail", None
        w = CW[kind][cls(ver)]
        if left() < w:
            return "fail", None
        cnt = int(bits[i:i + w], 2)
        i += w
        if kind == "N":
            while cnt:
                k = min(cnt, 3)
                nb = {3: 10, 2: 7, 1: 4}[k]
                if left() < nb:
                    return "fail", None
                v = int(bits[i:i + nb], 2)
                i += nb
                if v > 10 ** k - 1:
                    return "fail", None
                out += str(v).zfill(k).encode()
                cnt -= k
        elif kind == "A":
            while cnt:
                if cnt >= 2:
                    if left() < 11:
                        return "fail", None
                    v = int(bits[i:i + 11], 2)
                    i += 11
                    if v > 2024:
                        return "fail", None
                    out += (ALN[v // 45] + ALN[v % 45]).encode()
                    cnt -= 2
                else:
                    if left() < 6:
                        return "fail", None
                    v = int(bits[i:i + 6], 2)
                    i += 6
                    if v > 44:
                        return "fail", None
                    out += ALN[v].encode()
                    cnt -= 1
        else:
            for _ in range(cnt):
                if left() < 8:
                    return "fail", None
                out.append(int(bits[i:i + 8], 2))
                i += 8
    return "ok", bytes(out)          # fewer than 4 bits left: the message is over


# --------------------------------------------------- stream builders
def b(v, n):
    return format(v, "0%db" % n)


def seg_bits(kind, val, ver):
    r = MODE[kind] + b(len(val), CW[kind][cls(ver)])
    if kind == "N":
        for i in range(0, len(val), 3):
            g = val[i:i + 3]
            r += b(int(g), {3: 10, 2: 7, 1: 4}[len(g)])
    elif kind == "A":
        for i in range(0, len(val), 2):
            g = val[i:i + 2]
            r += b(45 * ALN.index(g[0]) + ALN.index(g[1]), 11) if len(g) == 2 else b(ALN.index(g), 6)
    else:
        r += "".join(b(x, 8) for x in val)
    return r


def to_bytes(bits, pad="0"):
    while len(bits) % 8:
        bits += pad
    return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))


def msg_of(segs):
    out = b""
    for kind, val in segs:
        out += bytes(val) if kind == "B" else val.encode()
    return out


# --------------------------------------------------- case list
CASES = []        # (name, ver, data bytes, expect) ; expect = bytes (must decode to it), "fail" (must fail), None (reference decides)


def add(name, ver, data, expect=None):
    CASES.append((name, ver, bytes(data), expect))


def add_segs(name, ver, segs, term=True, tail=b"", pad="0", expect="msg"):
    bits = "".join(seg_bits(k, v, ver) for k, v in segs) + (TERM if term else "")
    add(name, ver, to_bytes(bits, pad) + tail, msg_of(segs) if expect == "msg" else expect)


def build(rnd):
    rs = lambda alpha, n: "".join(rnd.choice(alpha) for _ in range(n))
    rb = lambda n: bytes(rnd.randrange(256) for _ in range(n))

    # empty messages and the terminator
    for v in EDGE_VERS:
        add_segs(f"empty-term v{v}", v, [], expect=b"")
    add("empty-no-bytes", 1, b"", b"")
    add("empty-one-zero-byte", 1, b"\x00", b"")
    add("empty-term-then-garbage", 5, bytes([0x00, 0xFF, 0xAB, 0xCD]), b"")
    add("empty-term-then-malformed", 5, bytes([0x0F, 0xFF, 0xFF]), b"")
    # numeric: every length, all width classes, leading zeros
    for v in EDGE_VERS:
        for n in range(0, 14):
            add_segs(f"num n={n} v{v}", v, [("N", rs("0123456789", n))])
    for s in ["0", "00", "000", "007", "0123", "999", "99", "9", "000000", "100", "010", "001"]:
        add_segs(f"num '{s}'", 1, [("N", s)])
    # alphanumeric: every character, every length, all width classes
    for ch in ALN:
        add_segs(f"aln single '{ch}'", 1, [("A", ch)])
    add_segs("aln all chars", 1, [("A", ALN)])
    add_segs("aln all chars rev", 10, [("A", ALN[::-1])])
    add_segs("aln pair max ':'x2", 1, [("A", "::")])
    for v in EDGE_VERS:
        for n in range(0, 14):
            add_segs(f"aln n={n} v{v}", v, [("A", rs(ALN, n))])
    # byte mode
    for v in EDGE_VERS:
        for n in range(0, 12):
            add_segs(f"byte n={n} v{v}", v, [("B", rb(n))])
    add_segs("byte all values", 40, [("B", bytes(range(256)))])
    add_segs("byte 255 v1 count", 1, [("B", rb(255))])
    add_segs("byte 300 v10 (16-bit count)", 10, [("B", rb(300))])
    add_segs("byte 1000 v27", 27, [("B", rb(1000))])
    add_segs("byte 2900 v40", 40, [("B", rb(2900))])
    add_segs("num 5000 v40", 40, [("N", rs("0123456789", 5000))])
    add_segs("aln 3000 v40", 40, [("A", rs(ALN, 3000))])
    # several segments
    for i in range(300):
        v = rnd.randrange(1, 41)
        segs = []
        for _ in range(rnd.randrange(1, 6)):
            k = rnd.choice("NAB")
            n = rnd.randrange(0, 13)
            segs.append((k, rs("0123456789", n) if k == "N" else rs(ALN, n) if k == "A" else rb(n)))
        add_segs(f"multi {i} v{v}", v, segs)
    # padding after the terminator is ignored, however long or odd
    add_segs("pad EC11 short", 1, [("A", "HELLO")], tail=bytes([0xEC, 0x11] * 5))
    add_segs("pad garbage after term", 3, [("N", "12345")], tail=rb(40))
    add_segs("pad 0xFF after term", 3, [("B", b"hi")], tail=b"\xff" * 30)
    add_segs("pad long v40", 40, [("A", "HI")], tail=rb(2900))
    add_segs("pad EC11 long v40", 40, [("N", "1")], tail=bytes([0xEC, 0x11] * 1400))
    # no terminator: the data simply ends (fewer than 4 bits left means done)
    for pad in "01":
        for v in (1, 10, 27):
            for segs in ([("N", "12")], [("N", "1")], [("N", "123")], [("A", "A")], [("A", "ABC")],
                         [("B", b"x")], [("B", b"xy")], [("N", "12"), ("A", "B")]):
                bits = "".join(seg_bits(k, x, v) for k, x in segs)
                # pad '0': leftover zero bits read as terminator or too few bits; pad '1' may make a bad mode
                add(f"noterm pad{pad} v{v} {segs[0][0]}{len(segs)}", v, to_bytes(bits, pad),
                    msg_of(segs) if pad == "0" else None)
    # explicit leftover-bit cases: 1..3 bits left must succeed whatever they are, 4+ non-zero bits are a mode
    add("left3 ones v1", 1, to_bytes(seg_bits("N", "12", 1), "1"), b"12")           # 21 bits + 111
    add("left1 one v10", 10, to_bytes(seg_bits("N", "12", 10), "1"), b"12")         # 23 bits + 1
    add("left2 ones", 1, to_bytes(seg_bits("A", "ABC", 1), "1"), b"ABC")            # 30 bits + 11
    add("left4 ones (bad mode)", 10, to_bytes(seg_bits("B", b"x", 10), "1"), "fail")  # 28 bits + 1111
    # failures
    for m in [0b0011, 0b0101, 0b0110, 0b0111, 0b1000, 0b1001, 0b1010, 0b1011, 0b1100, 0b1101, 0b1110, 0b1111]:
        add(f"badmode {m:04b} first", 1, to_bytes(format(m, "04b") + "0" * 20), "fail")
        v = rnd.choice(EDGE_VERS)
        add(f"badmode {m:04b} after segment v{v}", v,
            to_bytes(seg_bits("N", "123", v) + format(m, "04b") + "0" * 20), "fail")
    for v in EDGE_VERS:
        # header cut off: mode, then fewer count bits than the width needs
        for kind in "NAB":
            w = CW[kind][cls(v)]
            add(f"header cut {kind} v{v}", v, to_bytes(MODE[kind] + "1" * (w - 1))[:max(1, (4 + w - 1) // 8)], "fail")
    for val in (1000, 1023):
        add(f"num3 {val}", 1, to_bytes(MODE["N"] + b(3, 10) + b(val, 10) + TERM), "fail")
    for val in (100, 127):
        add(f"num2 {val}", 1, to_bytes(MODE["N"] + b(2, 10) + b(val, 7) + TERM), "fail")
    for val in (10, 15):
        add(f"num1 {val}", 1, to_bytes(MODE["N"] + b(1, 10) + b(val, 4) + TERM), "fail")
    for val in (2025, 2047):
        add(f"aln pair {val}", 1, to_bytes(MODE["A"] + b(2, 9) + b(val, 11) + TERM), "fail")
    for val in (45, 63):
        add(f"aln single {val}", 1, to_bytes(MODE["A"] + b(1, 9) + b(val, 6) + TERM), "fail")
    add("num bad after good", 1, to_bytes(seg_bits("N", "123", 1) + MODE["N"] + b(3, 10) + b(1000, 10)), "fail")
    add("aln bad after good chars", 1, to_bytes(MODE["A"] + b(4, 9) + b(45 * 10 + 11, 11) + b(2025, 11) + TERM), "fail")
    add("byte count past end", 1, to_bytes(MODE["B"] + b(200, 8) + "".join(b(x, 8) for x in b"abc")), "fail")
    add("byte count past end v10", 10, to_bytes(MODE["B"] + b(30000, 16) + "".join(b(x, 8) for x in b"abc")), "fail")
    add("num count past end", 1, to_bytes(MODE["N"] + b(900, 10) + b(123, 10)), "fail")
    add("aln count past end", 1, to_bytes(MODE["A"] + b(300, 9) + b(5, 11)), "fail")
    add("num group cut", 1, to_bytes(MODE["N"] + b(3, 10) + "10"), "fail")
    add("aln pair cut", 1, to_bytes(MODE["A"] + b(2, 9) + "10"), "fail")
    # random streams: the reference decides (about half decode, half fail)
    for i in range(1200):
        v = rnd.randrange(1, 41)
        n = rnd.randrange(0, 31)
        d = bytearray(rb(n))
        if d and rnd.random() < 0.7:                       # start with a valid mode so the parser gets deeper
            d[0] = (rnd.choice([1, 2, 4, 4, 2, 1, 0]) << 4) | (d[0] & 15)
        if len(d) > 2 and rnd.random() < 0.5:              # keep counts small so the segment can finish
            d[1] = d[1] & 0x0F
        add(f"fuzz {i} v{v}", v, d)


# --------------------------------------------------- gen
def gen():
    rnd = random.Random(20261106)
    build(rnd)
    stream = bytearray()
    cfg = []
    expect = []
    n_ok = n_fail = disagree = 0
    for name, ver, data, want in CASES:
        status, msg = ref_parse(data, ver)
        mok, mmsg, _ = model.parse(data, ver)
        if (status == "ok") != mok or (mok and bytes(mmsg) != msg):
            disagree += 1
            if disagree <= 10:
                print(f"REF/MODEL DISAGREE on '{name}': ref {status} {msg!r}, model {mok} {mmsg!r}")
        if isinstance(want, bytes) and (status != "ok" or msg != want):
            print(f"REF WRONG on constructed case '{name}': wanted {want!r}, ref {status} {msg!r}")
            disagree += 1
        if want == "fail" and status != "fail":
            print(f"CASE '{name}' was meant to fail but the reference decodes it to {msg!r}")
            disagree += 1
        n_ok += status == "ok"
        n_fail += status == "fail"
        cfg.append(f"{ver:02x}{len(data):04x}{len(stream):08x}")
        stream += data
        expect.append({"name": name, "ver": ver, "status": status, "data": (msg or b"").hex()})
    if disagree:
        print(f"gen: {disagree} disagreement(s); fix the reference, the model or the case list first")
        sys.exit(1)
    assert len(CASES) <= 4096 and len(stream) < (1 << 18), "cases do not fit the test bench memories"
    open("cfg.hex", "w").write("\n".join(cfg) + "\n")
    open("stream.hex", "w").write("\n".join(f"{x:02x}" for x in stream or b"\0") + "\n")
    json.dump(expect, open("expect.json", "w"))
    print(f"gen: {len(CASES)} cases ({n_ok} decode, {n_fail} must fail), {len(stream)} stream bytes; "
          f"reference and model agree on all")


# --------------------------------------------------- check
def check():
    expect = json.load(open("expect.json"))
    got = {}
    res = {}
    ended = False
    for line in open("payload.out"):
        t = line.split()
        if not t:
            continue
        if t[0] == "B":
            got.setdefault(int(t[1]), []).append((int(t[2]), int(t[3])))
        elif t[0] == "R":
            res[int(t[1])] = (t[2], int(t[3]))
        elif t[0] == "END":
            ended = True
    bad = 0
    nbytes = 0

    def fail(msg):
        nonlocal bad
        bad += 1
        if bad <= 12:
            print("MISMATCH", msg)

    if not ended:
        fail("test bench did not reach END")
    for i, e in enumerate(expect):
        r = res.get(i)
        if r is None:
            fail(f"case {i} '{e['name']}': no result line")
            continue
        if r[0] in "TX":
            fail(f"case {i} '{e['name']}': {'timed out' if r[0] == 'T' else 'raised failed and done together'}")
            continue
        if e["status"] == "fail":
            if r[0] != "F":
                fail(f"case {i} '{e['name']}': must fail, parser says {r[0]}")
            continue
        if r[0] != "S":
            fail(f"case {i} '{e['name']}': must decode, parser says {r[0]}")
            continue
        out = got.get(i, [])
        want = bytes.fromhex(e["data"])
        if bytes(d for d, _ in out) != want:
            fail(f"case {i} '{e['name']}': bytes {bytes(d for d, _ in out)[:24]!r}.. expected {want[:24]!r}..")
        elif [l for _, l in out] != [0] * (len(want) - 1) + ([1] if want else []):
            fail(f"case {i} '{e['name']}': `last` flags wrong")
        nbytes += len(want)
    nok = sum(1 for e in expect if e["status"] == "ok")
    print(f"payload: {len(expect)} cases ({nok} decode, {len(expect) - nok} fail), {nbytes} characters, "
          f"{bad} mismatches -> {'PASS' if bad == 0 else 'FAIL'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    {"gen": gen, "check": check}[sys.argv[1]]()
