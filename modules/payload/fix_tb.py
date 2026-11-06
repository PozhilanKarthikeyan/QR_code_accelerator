t = open("TbPayload.bsv").read()
def rep(a, b):
    global t
    assert t.count(a) == 1, a
    t = t.replace(a, b)
rep("   Reg#(UInt#(20)) cyc     <- mkReg(0);\n",
    "   Reg#(UInt#(32)) gcyc    <- mkReg(0);     // free-running cycle counter\n   Reg#(UInt#(32)) t0      <- mkReg(0);     // gcyc when the current case started\n")
rep("   Bool fast    =", "   UInt#(32) cyc = gcyc - t0;               // cycles since this case started\n   Bool fast    =")
rep("      cyc  <= (st == Start) ? 0 : cyc + 1;\n", "      gcyc <= gcyc + 1;\n")
rep("      p.start(ver);\n", "      p.start(ver);\n      t0 <= gcyc;\n")
open("TbPayload.bsv", "w").write(t)
r = open("run.sh").read()
open("run.sh", "w").write(r.replace("-p .:$SRC:+", "-p $SRC:+"))
print("patched")
