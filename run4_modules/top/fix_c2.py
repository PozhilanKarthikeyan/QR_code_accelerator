t = open("TbTop.bsv").read()
a = "      if (f && d) em = em + 1;                                    // never both\n"
assert t.count(a) == 1
t = t.replace(a, a + "      if (st == BRun && (f || d) && gcyc - startAt == 1) em = em + 1;   // C2: both low in the cycle after start\n")
open("TbTop.bsv", "w").write(t)
print("patched")
