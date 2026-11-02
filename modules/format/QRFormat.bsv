// QRFormat.bsv -- format information (Section 1.2 of the spec).
//
//   formatPosition : where bit f_i of copy 1 / copy 2 lives in the symbol (Table 1)
//   nearestFormat  : closest of the 32 valid 15-bit words to a read word, and how far away it is
//   decodeFormat   : G2 -- pick the nearer copy (copy 1 on a tie), fail if more than 3 bits away
//
// All three are pure combinational functions.  The reader unit reads the 30 module
// values using formatPosition, packs each copy into a Bit#(15) with bit i = f_i, and
// hands both words to decodeFormat.
package QRFormat;

import QRTypes  :: *;
import QRTables :: *;

// Result of G2.  When ok is False, level and mask are 0 and must not be used.
//   level is the raw 2-bit field of the symbol:  01 = L, 00 = M, 11 = Q, 10 = H
typedef struct {
   Bool    ok;
   Bit#(2) level;
   Bit#(3) mask;
} FormatInfo deriving (Bits, Eq, FShow);

// ---------------------------------------------------------------------------
// Table 1: module (row, col) holding format bit f_i.
//   n      : side length of the symbol
//   second : False = first copy (around the top-left finder),
//            True  = second copy (split between top-right and bottom-left finders)
//   i      : bit number 0..14
// ---------------------------------------------------------------------------
function Tuple2#(Coord, Coord) formatPosition(Coord n, Bool second, UInt#(4) i);
   Coord k = zeroExtend(i);
   Coord r = 0;
   Coord c = 0;
   if (!second) begin
      if      (i <= 5)  begin r = k;       c = 8;      end   // f0..f5 : (i, 8)
      else if (i == 6)  begin r = 7;       c = 8;      end
      else if (i == 7)  begin r = 8;       c = 8;      end
      else if (i == 8)  begin r = 8;       c = 7;      end
      else              begin r = 8;       c = 14 - k; end   // f9..f14: (8, 14-i)
   end
   else begin
      if      (i <= 5)  begin r = 8;       c = n - 1 - k;  end   // f0..f5 : (8, N-1-i)
      else if (i == 6)  begin r = 8;       c = n - 7;      end
      else if (i == 7)  begin r = 8;       c = n - 8;      end
      else if (i == 8)  begin r = n - 7;   c = 8;          end
      else              begin r = n - 15 + k;  c = 8;      end   // f9..f14: (N-15+i, 8)
   end
   return tuple2(r, c);
endfunction

// ---------------------------------------------------------------------------
// Nearest valid word.  Returns the 5 data bits {level, mask} of the closest of
// the 32 valid words, and the number of positions in which it differs from w.
// Ties go to the lower index (only possible when the distance is > 3, where the
// result is a failure anyway).
// ---------------------------------------------------------------------------
function Tuple2#(Bit#(5), UInt#(4)) nearestFormat(Bit#(15) w);
   Bit#(5)  bestD    = 0;
   UInt#(4) bestDst = 15;
   for (Integer d = 0; d < 32; d = d + 1) begin
      UInt#(4) dst = countOnes(w ^ formatCodeword(d));
      if (dst < bestDst) begin
         bestDst = dst;
         bestD    = fromInteger(d);
      end
   end
   return tuple2(bestD, bestDst);
endfunction

// ---------------------------------------------------------------------------
// G2: take the copy nearer to a valid word (first copy on a tie); fail if that
// copy is more than 3 positions away.
// ---------------------------------------------------------------------------
function FormatInfo decodeFormat(Bit#(15) copy1, Bit#(15) copy2);
   match {.d1, .dst1} = nearestFormat(copy1);
   match {.d2, .dst2} = nearestFormat(copy2);
   Bool     useFirst = dst1 <= dst2;
   Bit#(5)  d        = useFirst ? d1 : d2;
   UInt#(4) dst     = useFirst ? dst1 : dst2;
   Bool     good     = dst <= 3;
   return FormatInfo { ok:    good,
                       level: good ? d[4:3] : 0,
                       mask:  good ? d[2:0] : 0 };
endfunction

endpackage
