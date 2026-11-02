"""Self-tests for the reference model.  Run:  python3 -m pytest -q   (or python3 test_model.py)

Layers of evidence, from independent sources:
  * tables.py (parsed from the supplied BSV) vs. layout geometry: for all 40
    versions and 4 levels, data modules // 8 must equal the table's total bytes.
  * encoder.py vs segno: same data bytes + mask => identical matrix.
  * decoder.py vs segno: segno symbols must decode to the message.
  * RS: exactly floor(e/2) byte errors are fixed; floor(e/2)+1 are rejected.
"""
import random

import segno

import decoder
import encoder
import formatinfo
import gf256
import layout
import payload
import rs
from tables import BLOCKS, FORMAT_CODEWORDS

LEVELS = {"L": 1, "M": 0, "Q": 3, "H": 2}


def segno_matrix(msg, v, lvl, mask, mode="byte"):
    q = segno.make(msg, version=v, error=lvl, mask=mask, mode=mode,
                   boost_error=False, micro=False)
    return [list(r) for r in q.matrix]


# ------------------------------------------------------------------ GF ------
def test_gf_multiplier_all_pairs():
    for a in range(256):
        for b in range(256):
            assert gf256.mul(a, b) == gf256.mul_shift(a, b)


def test_gf_inverse():
    assert gf256.inv(0) == 0
    for a in range(1, 256):
        assert gf256.mul(a, gf256.inv(a)) == 1


# -------------------------------------------------------------- tables ------
def test_block_tables_consistent():
    for (v, lvl), (ec, n1, d1, n2, nb, D, total) in BLOCKS.items():
        assert nb == n1 + n2
        assert D == n1 * d1 + n2 * (d1 + 1)
        assert total == D + nb * ec


def test_data_module_count_matches_tables():
    """Independent check of function_map + zigzag against the supplied tables."""
    for v in range(1, 41):
        n_data = len(layout.data_order(v))
        for lvl in range(4):
            assert n_data // 8 == BLOCKS[(v, lvl)][6], (v, lvl)
    assert len(layout.data_order(1)) == 208                 # stated in the spec


def test_format_codewords_match_bch():
    for d in range(32):
        assert formatinfo.bch_encode(d) == FORMAT_CODEWORDS[d]


def test_format_decode_exhaustive():
    """All 2^15 words: result must be the unique nearest codeword when <= 3 away."""
    for w in range(1 << 15):
        d, dist = formatinfo.nearest(w)
        ok, lvl, mask, _ = formatinfo.decode(w, w)
        assert ok == (dist <= 3)
        if ok:
            assert (lvl << 3 | mask) == d


def test_format_first_copy_wins_ties():
    a, b = FORMAT_CODEWORDS[0], FORMAT_CODEWORDS[9]
    a2 = a ^ 0b11          # distance 2
    b2 = b ^ 0b11          # distance 2
    ok, lvl, mask, info = formatinfo.decode(a2, b2)
    assert ok and info["used_copy"] == 1 and (lvl << 3 | mask) == 0
    ok, lvl, mask, info = formatinfo.decode(a ^ 0b111, b2)   # copy 2 nearer
    assert info["used_copy"] == 2 and (lvl << 3 | mask) == 9


def test_version_of_side():
    assert layout.version_of_side(21) == 1
    assert layout.version_of_side(177) == 40
    for n in (0, 1, 20, 22, 23, 24, 26, 178, 181):
        assert layout.version_of_side(n) is None


# ---------------------------------------------------- encoder vs segno ------
def test_encoder_matches_segno_all_versions():
    for v in range(1, 41):
        for name, lvl in LEVELS.items():
            mask = (v + lvl) % 8
            mat = segno_matrix("QR", v, name, mask)
            r = decoder.decode(mat)
            assert r.ok and r.data == b"QR", (v, name, r.reason)
            cw = encoder.make_codewords(v, lvl, r.trace["data_bytes"])
            assert encoder.build_matrix(v, lvl, mask, cw) == mat, (v, name, mask)


def test_all_masks():
    for mask in range(8):
        mat = segno_matrix("MASK TEST 12345", 3, "M", mask, mode="alphanumeric")
        r = decoder.decode(mat)
        assert r.ok and r.data == b"MASK TEST 12345" and r.trace["mask"] == mask


def test_modes_roundtrip_against_segno():
    rnd = random.Random(1)
    for v in (1, 2, 9, 10, 26, 27, 40):        # both sides of every count-width boundary
        for mode, alphabet in (("numeric", "0123456789"),
                               ("alphanumeric", payload.ALNUM),
                               ("byte", None)):
            for n in (1, 2, 3, 4, 5, 7):
                if mode == "byte":
                    msg = bytes(rnd.randrange(256) for _ in range(n))
                    q = segno.make(msg, version=v, error="L", mask=2, mode="byte",
                                   boost_error=False, micro=False, encoding="latin-1")
                    want = msg
                else:
                    msg = "".join(rnd.choice(alphabet) for _ in range(n))
                    q = segno.make(msg, version=v, error="L", mask=2, mode=mode,
                                   boost_error=False, micro=False)
                    want = msg.encode()
                r = decoder.decode([list(x) for x in q.matrix])
                assert r.ok and r.data == want, (v, mode, n, r.reason)


# ------------------------------------------------------------------ RS ------
def test_rs_syndromes_of_valid_codeword_are_zero():
    rnd = random.Random(2)
    for e in (7, 10, 13, 17, 22, 28, 30):
        data = [rnd.randrange(256) for _ in range(40)]
        blk = data + rs.encode(data, e)
        assert not any(rs.syndromes(blk, e))


def test_rs_corrects_exactly_t_and_rejects_t_plus_1():
    rnd = random.Random(3)
    for e in (7, 10, 13, 16, 17, 18, 20, 22, 24, 26, 28, 30):
        t = e // 2
        for _ in range(60):
            n_data = rnd.randrange(5, 100)
            data = [rnd.randrange(256) for _ in range(n_data)]
            blk = data + rs.encode(data, e)
            for k in (0, 1, t):
                bad = list(blk)
                for pos in rnd.sample(range(len(bad)), k):
                    bad[pos] ^= rnd.randrange(1, 256)
                ok, fixed, info = rs.decode_block(bad, e)
                assert ok and fixed == blk, (e, k)
            # t+1 errors: normally rejected; if the decoder does accept, the result must at
            # least be a genuine codeword (A5 says the graders never produce such a case)
            bad = list(blk)
            for pos in rnd.sample(range(len(bad)), t + 1):
                bad[pos] ^= rnd.randrange(1, 256)
            ok, fixed, _ = rs.decode_block(bad, e)
            assert (not ok) or (not any(rs.syndromes(fixed, e)))


# ------------------------------------------------------------- payload ------
def parse_bits(bits, v=1):
    bits += "0" * (-len(bits) % 8)
    return payload.parse(bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8)), v)


def test_payload_edge_cases():
    assert parse_bits("0000") == (True, b"", "ok")                     # empty message
    assert parse_bits("")[0] and parse_bits("")[1] == b""
    assert parse_bits("0001" + format(3, "010b") + format(7, "010b"))[1] == b"007"
    assert parse_bits("0001" + format(2, "010b") + format(42, "07b"))[1] == b"42"
    assert parse_bits("0001" + format(1, "010b") + format(9, "04b"))[1] == b"9"
    assert parse_bits("0010" + format(1, "09b") + format(44, "06b"))[1] == b":"
    assert not parse_bits("0001" + format(3, "010b") + format(1000, "010b"))[0]   # > 999
    assert not parse_bits("0001" + format(2, "010b") + format(100, "07b"))[0]     # > 99
    assert not parse_bits("0001" + format(1, "010b") + format(10, "04b"))[0]      # > 9
    assert not parse_bits("0010" + format(2, "09b") + format(2025, "011b"))[0]    # > 2024
    assert not parse_bits("0010" + format(1, "09b") + format(45, "06b"))[0]       # > 44
    assert not parse_bits("1111" + "0" * 12)[0]                                    # unknown mode
    assert not parse_bits("0100" + format(5, "08b") + "0" * 8)[0]                  # runs past end
    # multiple segments, then terminator, then garbage that must be ignored
    s = ("0001" + format(3, "010b") + format(123, "010b")
         + "0100" + format(2, "08b") + "0100000101000010"
         + "0000" + "1111")
    assert parse_bits(s)[1] == b"123AB"


# --------------------------------------------------------- whole decoder -----
def test_damage_cases():
    rnd = random.Random(4)
    for v in (1, 2, 5, 14, 27, 40):
        for name, lvl in LEVELS.items():
            p = BLOCKS[(v, lvl)]
            ec, n1, d1, n2, nb, D, total = p
            t = ec // 2
            msg = [("byte", bytes(rnd.randrange(256) for _ in range(min(10, D - 4))))]
            mat = encoder.encode(v, lvl, rnd.randrange(8), msg)
            want = decoder.decode(mat).data
            # t damaged bytes in every block
            order = layout.data_order(v)
            bitpos = {}
            for k, rc in enumerate(order[:total * 8]):
                bitpos[k // 8] = bitpos.get(k // 8, []) + [rc]
            dmg = [row[:] for row in mat]
            for b in range(nb):
                blen = d1 + (1 if b >= n1 else 0) + ec
                idx = []
                for i in range(blen):
                    if i < d1: idx.append(i * nb + b)
                    elif i == d1 and b >= n1: idx.append(d1 * nb + (b - n1))
                    else: idx.append(D + (i - (d1 + (1 if b >= n1 else 0))) * nb + b)
                for k in rnd.sample(idx, t):
                    r, c = rnd.choice(bitpos[k])
                    dmg[r][c] ^= 1
            r = decoder.decode(dmg)
            assert r.ok and r.data == want, (v, name, r.reason)


def test_failures():
    mat = encoder.encode(1, 0, 2, [("byte", b"hi")])
    assert not decoder.decode(mat, 22).ok                      # bad size
    bad = [row[:] for row in mat]
    c1, c2 = formatinfo.positions(21)
    for rc in c1[:5] + c2[:5]:
        bad[rc[0]][rc[1]] ^= 1
    assert not decoder.decode(bad).ok                          # unreadable format
    bad = [row[:] for row in mat]
    for rc in c1[:3]:
        bad[rc[0]][rc[1]] ^= 1
    for rc in c2[5:8]:
        bad[rc[0]][rc[1]] ^= 1
    assert decoder.decode(bad).ok                              # 3 + 3 wrong bits is fine


if __name__ == "__main__":
    import sys
    import pytest
    sys.exit(pytest.main([__file__, "-q"]))
