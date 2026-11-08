"""Segment parser (Section 1.5, G4)."""

ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"

MODE_NUM, MODE_ALNUM, MODE_BYTE, MODE_END = 0b0001, 0b0010, 0b0100, 0b0000


def count_width(mode, v):
    col = 0 if v <= 9 else (1 if v <= 26 else 2)
    return {MODE_NUM: (10, 12, 14), MODE_ALNUM: (9, 11, 13), MODE_BYTE: (8, 16, 16)}[mode][col]


class _Bits:
    def __init__(self, data):
        self.bits = "".join(f"{b:08b}" for b in data)
        self.pos = 0

    def left(self):
        return len(self.bits) - self.pos

    def take(self, n):
        v = int(self.bits[self.pos:self.pos + n], 2)
        self.pos += n
        return v


def parse(data, v):
    """Return (ok, bytes, reason).  data = concatenated corrected data bytes."""
    s = _Bits(data)
    out = bytearray()
    while s.left() >= 4:
        mode = s.take(4)
        if mode == MODE_END:
            break
        if mode not in (MODE_NUM, MODE_ALNUM, MODE_BYTE):
            return False, b"", f"unknown mode {mode:04b}"
        w = count_width(mode, v)
        if s.left() < w:
            return False, b"", "segment header runs past end"
        n = s.take(w)
        if mode == MODE_NUM:
            while n > 0:
                k = min(n, 3)
                width = {3: 10, 2: 7, 1: 4}[k]
                if s.left() < width:
                    return False, b"", "numeric group runs past end"
                val = s.take(width)
                if val >= 10 ** k:
                    return False, b"", f"numeric group {val} out of range"
                out += f"{val:0{k}d}".encode()
                n -= k
        elif mode == MODE_ALNUM:
            while n > 0:
                if n >= 2:
                    if s.left() < 11:
                        return False, b"", "alnum pair runs past end"
                    val = s.take(11)
                    if val > 45 * 44 + 44:
                        return False, b"", f"alnum pair {val} out of range"
                    out.append(ord(ALNUM[val // 45]))
                    out.append(ord(ALNUM[val % 45]))
                    n -= 2
                else:
                    if s.left() < 6:
                        return False, b"", "alnum char runs past end"
                    val = s.take(6)
                    if val > 44:
                        return False, b"", f"alnum char {val} out of range"
                    out.append(ord(ALNUM[val]))
                    n -= 1
        else:
            for _ in range(n):
                if s.left() < 8:
                    return False, b"", "byte segment runs past end"
                out.append(s.take(8))
    return True, bytes(out), "ok"
