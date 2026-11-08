// QRWalker.bsv -- visits the data modules of a QR symbol in reading order.
//
// Written from Section 1.3 of the spec.  Two jobs, kept deliberately separate:
//
//   isFunctionModule : "is module (r,c) a function module?"  (pure, combinational)
//   maskInverts      : "does mask m invert module (r,c)?"    (pure, combinational)
//   mkQRWalker       : a small state machine that walks the zigzag and hands out
//                      the (row, col) of each data module, one per cycle.
//
// The walker knows nothing about memory or bytes.  The consumer asks for the next
// position, sends it to mem.req, and (one cycle later) unmasks the answer with
// maskInverts of the SAME position -- so the consumer must remember it.
package QRWalker;

import Vector  :: *;
import QRTypes  :: *;
import QRTables :: *;

// ---------------------------------------------------------------------------
// Which modules are function modules (Section 1.1)?
//   n   : side length          ver : version (1..40)
//   ap  : alignment-pattern coordinates for this version (from QRTables)
// ---------------------------------------------------------------------------
function Bool isFunctionModule(Coord n, UInt#(6) ver, AlignParams ap, Coord r, Coord c);
   // three finder patterns, each with its one-module light separator (8x8 boxes)
   Bool finder = ((r < 8) && (c < 8))
              || ((r < 8) && (c >= n - 8))
              || ((r >= n - 8) && (c < 8));

   // timing patterns
   Bool timing = (r == 6) || (c == 6);

   // format information: row 8 and column 8 next to the finders.  Column 8 at
   // the bottom starts at row n-8, which is the always-dark module.
   Bool fmtRow = (r == 8) && ((c <= 8) || (c >= n - 8));
   Bool fmtCol = (c == 8) && ((r <= 8) || (r >= n - 8));

   // version information (v >= 7): two 6x3 areas
   Bool verTR = (r < 6) && (c >= n - 11) && (c < n - 8);
   Bool verBL = (c < 6) && (r >= n - 11) && (r < n - 8);
   Bool verInfo = (ver >= 7) && (verTR || verBL);

   // alignment patterns: 5x5 squares centred on every (pos[i], pos[j]) pair,
   // except the three pairs that would land on a finder pattern.
   Bool align = False;
   for (Integer i = 0; i < 7; i = i + 1)
      for (Integer j = 0; j < 7; j = j + 1) begin
         Bool inRange = (fromInteger(i) < ap.count) && (fromInteger(j) < ap.count);
         Bool rowHit  = (r + 2 >= ap.pos[i]) && (ap.pos[i] + 2 >= r);   // |r - pos[i]| <= 2
         Bool colHit  = (c + 2 >= ap.pos[j]) && (ap.pos[j] + 2 >= c);   // |c - pos[j]| <= 2
         Bool lastI   = (fromInteger(i) + 1 == ap.count);
         Bool lastJ   = (fromInteger(j) + 1 == ap.count);
         Bool onFinder = ((i == 0) && (j == 0))        // centre near top-left finder
                      || ((i == 0) && lastJ)           // top-right
                      || (lastI && (j == 0));          // bottom-left
         if (inRange && rowHit && colHit && !onFinder) align = True;
      end

   return finder || timing || fmtRow || fmtCol || verInfo || align;
endfunction

// ---------------------------------------------------------------------------
// The eight mask patterns (Table 2).  True = this module was inverted.
// Only small mod-2 / mod-3 pieces are needed; r*c mod 3 uses (r mod 3)(c mod 3).
// ---------------------------------------------------------------------------
function Bool maskInverts(Bit#(3) m, Coord r, Coord c);
   UInt#(2) r3 = truncate(r % 3);
   UInt#(2) c3 = truncate(c % 3);
   UInt#(4) p3 = zeroExtend(r3) * zeroExtend(c3);        // 0..4
   UInt#(4) rc3  = p3 % 3;                                // (r*c) mod 3
   Bit#(1)  r0 = pack(r)[0];                              // r mod 2
   Bit#(1)  c0 = pack(c)[0];                              // c mod 2
   UInt#(4) rc2  = ((r0 & c0) == 1) ? 1 : 0;              // (r*c) mod 2
   UInt#(4) rpc2 = ((r0 ^ c0) == 1) ? 1 : 0;              // (r+c) mod 2
   UInt#(4) rpc3 = (zeroExtend(r3) + zeroExtend(c3)) % 3; // (r+c) mod 3
   UInt#(8) rdiv2 = r >> 1;                               // floor(r/2)
   UInt#(8) cdiv3 = c / 3;                                // floor(c/3)
   case (m)
      0: return rpc2 == 0;
      1: return r0 == 0;
      2: return c3 == 0;
      3: return rpc3 == 0;
      4: return ((rdiv2 + cdiv3) % 2) == 0;
      5: return (rc2 + rc3) == 0;
      6: return ((rc2 + rc3) % 2) == 0;
      7: return ((rpc2 + rc3) % 2) == 0;
   endcase
endfunction

// ---------------------------------------------------------------------------
// The walker
// ---------------------------------------------------------------------------
interface QRWalker;
   // Begin a new walk.  n must be 17+4*ver with 1 <= ver <= 40 (the caller has
   // already checked it).  Restarts from scratch even if a walk is in progress.
   method Action start(Coord n, UInt#(6) ver);
   // Next data module in reading order.  Ready only when one is available.
   method ActionValue#(Tuple2#(Coord, Coord)) next();
   // True from the cycle after start until the last module has been taken.
   method Bool busy();
endinterface

module mkQRWalker(QRWalker);
   Reg#(Bool)     active   <- mkReg(False);
   Reg#(Coord)    nReg     <- mkReg(0);
   Reg#(UInt#(6)) verReg   <- mkReg(1);

   // Position state.  A "strip" is a pair of columns (rightCol, rightCol-1).
   Reg#(Coord)    rightCol <- mkReg(0);
   Reg#(Coord)    row      <- mkReg(0);
   Reg#(Bool)     left     <- mkReg(False);   // False: at rightCol, True: at rightCol-1
   Reg#(Bool)     up       <- mkReg(True);    // direction of travel in this strip

   // Methods only raise these; one rule below owns every register update.
   RWire#(Tuple2#(Coord, UInt#(6))) startW <- mkRWire;
   PulseWire                        takeW  <- mkPulseWire;

   Coord col = left ? rightCol - 1 : rightCol;
   Bool  isFn = isFunctionModule(nReg, verReg, alignParams(verReg), row, col);

   (* fire_when_enabled, no_implicit_conditions *)
   rule update;
      if (startW.wget matches tagged Valid {.n, .v}) begin
         // first module visited: bottom-right corner, moving up
         nReg     <= n;
         verReg   <= v;
         rightCol <= n - 1;
         row      <= n - 1;
         left     <= False;
         up       <= True;
         active   <= True;
      end
      else if (active && (isFn || takeW)) begin
         // Step to the next candidate module.  A function module is stepped
         // over without being handed out; a data module is stepped over once
         // the consumer has taken it.
         if (!left)
            left <= True;                       // right column -> left column, same row
         else begin
            left <= False;
            Bool atEnd = up ? (row == 0) : (row == nReg - 1);
            if (!atEnd)
               row <= up ? row - 1 : row + 1;   // next row of this strip
            else begin
               up <= !up;                       // strip finished: turn around
               if (rightCol == 1)
                  active <= False;              // strip (1,0) was the last one
               else
                  rightCol <= (rightCol == 8) ? 5 : rightCol - 2;   // skip column 6
            end
         end
      end
   endrule

   method Action start(Coord n, UInt#(6) ver);
      startW.wset(tuple2(n, ver));
   endmethod

   method ActionValue#(Tuple2#(Coord, Coord)) next() if (active && !isFn);
      takeW.send;
      return tuple2(row, col);
   endmethod

   method Bool busy = active;
endmodule

endpackage
