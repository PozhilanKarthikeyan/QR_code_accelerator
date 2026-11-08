// Prints every data-module position for versions 1..40, plus cycle counts.
package TbWalker;
import QRTypes  :: *;
import QRWalker :: *;

(* synthesize *)
module mkTbWalker(Empty);
   QRWalker w <- mkQRWalker;
   Reg#(UInt#(6))  ver     <- mkReg(1);
   Reg#(Bool)      started <- mkReg(False);
   Reg#(UInt#(32)) cyc     <- mkReg(0);
   Reg#(UInt#(32)) nTaken  <- mkReg(0);

   rule count; cyc <= cyc + 1; endrule

   rule go (!started);
      Coord v8 = zeroExtend(ver);
      Coord n = 17 + 4 * v8;
      w.start(n, ver);
      started <= True;
      cyc <= 1;
      nTaken <= 0;
      $display("V %0d %0d", ver, n);
   endrule

   rule take (started && w.busy);
      match {.r, .c} <- w.next;
      nTaken <= nTaken + 1;
      $display("P %0d %0d", r, c);
   endrule

   rule fin (started && !w.busy);
      $display("E %0d %0d %0d", ver, nTaken, cyc);
      if (ver == 40) $finish;
      else begin ver <= ver + 1; started <= False; end
   endrule
endmodule
endpackage
