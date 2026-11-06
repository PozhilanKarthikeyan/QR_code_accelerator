// Prints the results of the GF(2^8) functions for the Python checker.
//   M a b p    gfMul for ALL 65,536 pairs
//   I a r      gfInv for all 256 values
//   X a r      gfXtime for all 256 values
//   A k r      alphaPow(k) for k = 0..254;  N k r  alphaPowNeg(k) for k = 0..40
package TbGF;
import QRGF :: *;

(* synthesize *)
module mkTbGF(Empty);
   Reg#(UInt#(2))  phase <- mkReg(0);
   Reg#(UInt#(16)) cnt   <- mkReg(0);

   rule pMul (phase == 0);
      Bit#(16) c = pack(cnt);
      Bit#(8) a = c[15:8];
      Bit#(8) b = c[7:0];
      $display("M %0d %0d %0d", a, b, gfMul(a, b));
      if (cnt == 65535) begin phase <= 1; cnt <= 0; end else cnt <= cnt + 1;
   endrule

   rule pOne (phase == 1);
      Bit#(8) a = truncate(pack(cnt));
      $display("I %0d %0d", a, gfInv(a));
      $display("X %0d %0d", a, gfXtime(a));
      if (cnt == 255) begin phase <= 2; cnt <= 0; end else cnt <= cnt + 1;
   endrule

   rule pConst (phase == 2);
      for (Integer k = 0; k < 255; k = k + 1)
         $display("A %0d %0d", k, alphaPow(k));
      for (Integer k = 0; k < 41; k = k + 1)           // the RS stage needs alpha^-k only for small k
         $display("N %0d %0d", k, alphaPowNeg(k));
      $finish;
   endrule
endmodule
endpackage
