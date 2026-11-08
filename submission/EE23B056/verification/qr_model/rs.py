"""Reed-Solomon over GF(256): encoder (for test generation) and decoder.

A block is a list of bytes, first byte = highest-degree coefficient.
Roots of the code are alpha^0 .. alpha^(e-1)  (Section 1.4).
"""
from gf256 import mul, div, inv, alpha_pow, poly_eval


def syndromes(block, e):
    """S_j = R(alpha^j), j = 0..e-1  (Horner)."""
    out = []
    for j in range(e):
        a = alpha_pow(j)
        s = 0
        for b in block:
            s = mul(s, a) ^ b
        out.append(s)
    return out


def generator(e):
    """g(x) = prod_{j<e} (x - alpha^j), ASCENDING coefficients."""
    g = [1]
    for j in range(e):
        a = alpha_pow(j)
        ng = [0] * (len(g) + 1)
        for k, c in enumerate(g):
            ng[k + 1] ^= c            # c * x
            ng[k] ^= mul(c, a)        # c * alpha^j
        g = ng
    return g


def encode(data, e):
    """Return the e check bytes for a list of data bytes."""
    g = generator(e)                  # ascending, g[e] == 1
    rem = [0] * e                     # rem[0] is the highest-degree term
    for b in data:
        fb = b ^ rem[0]
        rem = rem[1:] + [0]
        if fb:
            for k in range(e):
                rem[k] ^= mul(fb, g[e - 1 - k])
    return rem


def _padd(a, b):
    n = max(len(a), len(b))
    return [(a[i] if i < len(a) else 0) ^ (b[i] if i < len(b) else 0) for i in range(n)]


def berlekamp_massey(S):
    """Return (Lambda ascending, L)."""
    C, B = [1], [1]
    L, m, b = 0, 1, 1
    for n in range(len(S)):
        d = S[n]
        for i in range(1, L + 1):
            if i < len(C):
                d ^= mul(C[i], S[n - i])
        if d == 0:
            m += 1
            continue
        coef = div(d, b)
        T = C[:]
        C = _padd(C, [0] * m + [mul(coef, x) for x in B])
        if 2 * L <= n:
            L, B, b, m = n + 1 - L, T, d, 1
        else:
            m += 1
    while len(C) > 1 and C[-1] == 0:
        C.pop()
    return C, L


def decode_block(block, e):
    """Correct up to floor(e/2) byte errors.

    Returns (ok, corrected_block, info).  ok=False means 'cannot be corrected'.
    info has syndromes, locator, error positions (byte index in block) and values.
    """
    m = len(block)
    S = syndromes(block, e)
    info = dict(syndromes=S, errors=[])
    if not any(S):
        return True, list(block), info

    lam, L = berlekamp_massey(S)
    info["locator"] = lam
    if L > e // 2 or len(lam) - 1 != L:
        return False, list(block), info

    # Chien search: error at power i (byte index m-1-i) iff Lambda(alpha^-i) == 0
    powers = [i for i in range(m) if poly_eval(lam, alpha_pow(-i)) == 0]
    if len(powers) != L:
        return False, list(block), info

    # Forney (first consecutive root alpha^0):  e_i = X * Omega(X^-1) / Lambda'(X^-1)
    omega = [0] * e
    for i in range(e):
        for j in range(len(lam)):
            if i + j < e:
                omega[i + j] ^= mul(S[i], lam[j])
    dlam = [lam[k] if k % 2 == 1 else 0 for k in range(1, len(lam))]  # odd terms, shifted down
    out = list(block)
    for i in powers:
        X, Xi = alpha_pow(i), alpha_pow(-i)
        den = poly_eval(dlam, Xi)
        if den == 0:
            return False, list(block), info
        val = mul(X, div(poly_eval(omega, Xi), den))
        if val == 0:
            return False, list(block), info
        out[m - 1 - i] ^= val
        info["errors"].append((m - 1 - i, val))

    if any(syndromes(out, e)):        # belt and braces: result must be a codeword
        return False, list(block), info
    return True, out, info
