#!/usr/bin/env python3
"""Decode the symbol from TbSample.bsv and print every intermediate result.

    python3 demo.py path/to/TbSample.bsv
"""
import re
import sys

import decoder

rows = re.findall(r"symbol\[\s*\d+\]\s*=\s*'b([01]+);", open(sys.argv[1]).read())
mat = [[int(ch) for ch in row] for row in rows]
r = decoder.decode(mat)
t = r.trace
print("ok:", r.ok, "| message:", r.data, "| reason:", r.reason)
print("version", t["version"], "level", t["level"], "mask", t["mask"])
f = t["format"]
print(f"format copies: {f['copy1']:015b} {f['copy2']:015b}  "
      f"(distances {f['dist1']}, {f['dist2']}, used copy {f['used_copy']})")
print("block params (ecLen,n1,d1,n2,nb,totalData,total):", t["block_params"])
print("raw codewords :", " ".join(f"{b:02x}" for b in t["raw_codewords"]))
for i, b in enumerate(t["blocks"]):
    print(f"block {i}: syndromes={b['syndromes']} errors(pos,val)={b['errors']}")
print("data bytes    :", " ".join(f"{b:02x}" for b in t["data_bytes"]))
