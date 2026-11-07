def patch(fn, pairs):
    t = open(fn).read()
    for a, b in pairs:
        assert t.count(a) == 1, (fn, a)
        t = t.replace(a, b)
    open(fn, "w").write(t)

patch("TbPayload.bsv", [
 ("import RegFile  :: *;\n", "import RegFile  :: *;\nimport ConfigReg :: *;\n"),
 ("   Reg#(UInt#(16)) cnt     <- mkReg(0);\n   Reg#(Bool)      endSent <- mkReg(False);\n",
  "   Reg#(UInt#(16)) cnt     <- mkConfigReg(0);      // ConfigReg: rFin may read it without an ordering conflict\n   Reg#(Bool)      endSent <- mkConfigReg(False);\n"),
 ("   Bool fast    =", "   Bool allFed  = (cnt == len && endSent);   // every byte of the stream was accepted by the parser\n   Bool fast    ="),
 ("   rule rFin (st == Run && (p.failed || p.done || cyc > 500000));\n",
  "   rule rFin (st == Run && (p.failed || (p.done && allFed) || cyc > 200000));\n"),
 ("      else if (p.done)        $display(\"R %0d S %0d\", ci, cyc);\n",
  "      else if (p.done && allFed) $display(\"R %0d S %0d\", ci, cyc);\n"),
])
patch("check_payload.py", [
 ("    # no terminator: the data simply ends",
  "    # short messages followed by a tail: the producer must never stall after the terminator\n"
  "    for i in range(80):\n"
  "        v = rnd.choice(EDGE_VERS)\n"
  "        k = rnd.choice(\"NAB\")\n"
  "        n = rnd.randrange(0, 5)\n"
  "        val = rs(\"0123456789\", n) if k == \"N\" else rs(ALN, n) if k == \"A\" else rb(n)\n"
  "        add_segs(f\"short msg + tail {i} v{v}\", v, [(k, val)], tail=rb(rnd.randrange(4, 12)))\n"
  "    # no terminator: the data simply ends"),
])
print("patched")
