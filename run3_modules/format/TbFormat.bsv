// Prints results of the format functions for the Python checker.
//   N lines : nearestFormat for ALL 2^15 words
//   P lines : formatPosition for every version, both copies, all 15 bits
//   D lines : decodeFormat on 400,000 pseudo-random pairs of words
package TbFormat;
import Vector   :: *;
import QRTypes  :: *;
import QRTables :: *;
import QRFormat :: *;

// one step of xorshift32
function Bit#(32) xs(Bit#(32) x);
   Bit#(32) a = x ^ (x << 13);
   Bit#(32) b = a ^ (a >> 17);
   return b ^ (b << 5);
endfunction

// flip between 0 and 5 bits of a word (positions drawn from x; position 15 = no flip)
function Bit#(15) noise(Bit#(32) x);
   UInt#(3) f = unpack(x[2:0]);
   Bit#(15) m = 0;
   for (Integer i = 0; i < 5; i = i + 1) begin
      Bit#(4)  p   = x[6 + 4*i : 3 + 4*i];
      Bit#(16) one = 16'h1 << p;
      if (fromInteger(i) < f && f <= 5) m = m ^ one[14:0];
   end
   return m;
endfunction

function Bit#(15) validWord(Bit#(5) d);
   Bit#(15) w = 0;
   for (Integer k = 0; k < 32; k = k + 1)
      if (d == fromInteger(k)) w = formatCodeword(k);
   return w;
endfunction

(* synthesize *)
module mkTbFormat(Empty);
   Reg#(UInt#(3))  phase <- mkReg(0);
   Reg#(UInt#(32)) cnt   <- mkReg(0);
   Reg#(UInt#(6))  ver   <- mkReg(1);
   Reg#(Bit#(32))  ga <- mkReg(32'h1234567);
   Reg#(Bit#(32))  gb <- mkReg(32'h9abcdef1);
   Reg#(Bit#(32))  gc <- mkReg(32'h0f1e2d3c);
   Reg#(Bit#(32))  gd <- mkReg(32'h77777771);

   // phase 0: exhaustive nearestFormat
   rule p0 (phase == 0);
      Bit#(15) w = truncate(pack(cnt));
      match {.d, .dst} = nearestFormat(w);
      $display("N %0d %0d %0d", w, d, dst);
      if (cnt == 32767) begin phase <= 1; cnt <= 0; end else cnt <= cnt + 1;
   endrule

   // phase 1: positions
   rule p1 (phase == 1);
      Coord v8 = zeroExtend(ver);
      Coord n = 17 + 4 * v8;
      for (Integer s = 0; s < 2; s = s + 1)
         for (Integer i = 0; i < 15; i = i + 1) begin
            match {.r, .c} = formatPosition(n, s == 1, fromInteger(i));
            $display("P %0d %0d %0d %0d %0d", n, s, i, r, c);
         end
      if (ver == 40) begin phase <= 2; cnt <= 0; end else ver <= ver + 1;
   endrule

   // phase 2: random pairs through decodeFormat
   rule p2 (phase == 2);
      Bit#(15) rnd1 = gb[31:17];
      Bit#(15) rnd2 = gc[31:17];
      Bit#(15) c1 = (ga[1:0] == 0) ? rnd1 : (validWord(ga[6:2])  ^ noise(gb));
      Bit#(15) c2 = (ga[3:2] == 0) ? rnd2 : (validWord(ga[11:7]) ^ noise(gc));
      FormatInfo fi = decodeFormat(c1, c2);
      $display("D %0d %0d %0d %0d %0d", c1, c2, fi.ok ? 1 : 0, fi.level, fi.mask);
      ga <= xs(ga); gb <= xs(gb); gc <= xs(gc); gd <= xs(gd);
      if (cnt == 399999) $finish; else cnt <= cnt + 1;
   endrule
endmodule
endpackage
