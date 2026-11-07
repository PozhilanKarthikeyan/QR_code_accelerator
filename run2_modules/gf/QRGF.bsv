// QRGF.bsv -- arithmetic in GF(2^8) for the Reed-Solomon stage (spec Section 1.4).
//
// The field: bytes, polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D), primitive element alpha = 2.
//   * addition is XOR
//   * "times alpha" is a left shift, and if a 1 fell off the top, XOR in 0x1D (= 0x11D without bit 8)
//   * a general product is a sum of shifted copies: b = b7 b6 ... b0 means a*b = sum of (a * alpha^i) for each bit i set in b
//
// Everything here is a pure combinational function.
package QRGF;

import Vector :: *;

// a * alpha
function Bit#(8) gfXtime(Bit#(8) a);
   Bit#(8) s = a << 1;
   return (a[7] == 1) ? (s ^ 8'h1D) : s;
endfunction

// a * b.   8 AND-XOR rows; if one argument is a constant, synthesis folds it
// down to a few XORs (this is how the constant multipliers for syndromes are made).
function Bit#(8) gfMul(Bit#(8) a, Bit#(8) b);
   Bit#(8) acc = 0;
   Bit#(8) x   = a;                       // a * alpha^i
   for (Integer i = 0; i < 8; i = i + 1) begin
      if (b[i] == 1) acc = acc ^ x;
      x = gfXtime(x);
   end
   return acc;
endfunction

// 1/a, computed as a^254 (every nonzero a has a^255 = 1).  gfInv(0) = 0 by convention.
//   a^254 = a^2 * a^4 * a^8 * ... * a^128
// This is the big, fully parallel version (13 multipliers).  Fine as a first design;
// a table or a serial version is a later area optimisation.
function Bit#(8) gfInvChain(Bit#(8) a);
   Bit#(8) s = gfMul(a, a);               // a^2
   Bit#(8) r = s;
   for (Integer i = 2; i <= 7; i = i + 1) begin
      s = gfMul(s, s);                    // a^(2^i)
      r = gfMul(r, s);
   end
   return r;
endfunction

// 1/a as a 256-entry table, built at compile time from gfInvChain above (so it is the same
// function by construction, gfInv(0) = 0 included).  Synthesis turns it into a shallow ROM
// instead of six multipliers in series.  This is the name the Reed-Solomon stage uses.
function Bit#(8) gfInv(Bit#(8) a);
   function Bit#(8) f(Integer i) = gfInvChain(fromInteger(i));
   Vector#(256, Bit#(8)) tbl = genWith(f);
   return tbl[a];
endfunction

// alpha^k as a compile-time constant, for k >= 0.  Used to build the constant
// multipliers of the syndrome and Chien-search stages.  Square-and-multiply, so the
// compiler needs only about 2*log2(k) steps per constant.
function Bit#(8) alphaPow(Integer k);
   if (k == 0)           return 1;
   else if (k % 2 == 1)  return gfXtime(alphaPow(k - 1));
   else begin
      Bit#(8) h = alphaPow(k / 2);
      return gfMul(h, h);
   end
endfunction

// alpha^(-k) as a compile-time constant (alpha has order 255, so this is alpha^(255-k mod 255)).
function Bit#(8) alphaPowNeg(Integer k) = alphaPow((255 - (k % 255)) % 255);

endpackage
