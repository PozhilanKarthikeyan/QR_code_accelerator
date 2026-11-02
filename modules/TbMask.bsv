// For each mask, prints one line per row: 177 bits, bit for column 0 first.
package TbMask;
import QRTypes  :: *;
import QRWalker :: *;

(* synthesize *)
module mkTbMask(Empty);
   Reg#(Bit#(3))    m   <- mkReg(0);
   Reg#(Coord)      r   <- mkReg(0);
   Reg#(Coord)      c   <- mkReg(0);
   Reg#(Bit#(177))  acc <- mkReg(0);

   rule go;
      Bit#(1) b = maskInverts(m, r, c) ? 1 : 0;
      Bit#(177) nacc = {acc[175:0], b};
      if (c == 176) begin
         $display("M %0d %0d %b", m, r, nacc);
         acc <= 0; c <= 0;
         if (r == 176) begin
            r <= 0;
            if (m == 7) $finish; else m <= m + 1;
         end
         else r <= r + 1;
      end
      else begin acc <= nacc; c <= c + 1; end
   endrule
endmodule
endpackage
