// QRBlocks.bsv -- unit 4: de-interleaver and block buffer.
//
// The reader delivers the symbol's bytes in symbol order (k = 0,1,2,...).  The
// Reed-Solomon stage wants them one block at a time (data bytes, then check bytes).
// This unit sorts them out:
//
//   * Each PASS keeps only a GROUP of blocks g0 .. g1-1, packed back to back in a
//     buffer of `cap` bytes.  g1 is chosen greedily: as many blocks as fit.  If the
//     whole symbol fits, one pass does everything; otherwise the top level reads the
//     symbol again for the next group (g0 = groupEnd).  So `cap` is the knob that
//     trades area (buffer size) against cycles (number of passes).
//   * The byte with number k is stored with counters only, no division (spec 1.4):
//         data byte i < d of block b   (k = i*n + b)       goes to block b, position i
//         extra data byte of a longer block                 goes to position d
//         check byte j of block b      (k = D + j*n + b)    goes to position d_b + j
//     where d_b = d for the first n1 blocks and d+1 for the n2 longer ones.
//
// Use, per symbol:   configure(p)
//   per pass:        planPass(g0); wait groupValid; start the reader; putByte() for all
//                    p.total bytes; wait filled; then walk the group with rewindBlocks /
//                    curBlock / advanceBlock and fetch bytes with readReq / readData.
package QRBlocks;

import Vector  :: *;
import QRTypes  :: *;
import QRTables :: *;

typedef struct {
   Bool      valid;     // False after the last block of the group
   UInt#(7)  idx;       // block number b (symbol order)
   UInt#(12) base;      // buffer address of the block's first byte
   UInt#(7)  dataLen;   // data bytes in this block
   UInt#(8)  len;       // data bytes + check bytes
} BlockDesc deriving (Bits, Eq, FShow);

interface QRBlockBuf#(numeric type cap);
   // Describe the symbol (from blockParams).  Call once per symbol.
   method Action configure(BlockParams p);

   // Choose the next group of blocks, starting at block g0 (0 for the first pass).
   method Action     planPass(UInt#(7) g0);
   method Bool       groupValid();     // the group below is known and putByte may start
   method UInt#(7)   groupStart();
   method UInt#(7)   groupEnd();       // exclusive
   method Bool       moreGroups();     // blocks remain after this group

   // Feed the symbol's bytes in symbol order; all of them, every pass.
   method Action     putByte(Bit#(8) x);
   method Bool       filled();         // every byte of this pass has been seen

   // Walk the blocks of the group, in order.
   method Action     rewindBlocks();
   method Action     advanceBlock();
   method BlockDesc  curBlock();

   // Read a byte: readReq(addr) in cycle t, readData is the byte in cycle t+1
   // (and stays until the next readReq).  addr = base + position in the block.
   method Action     readReq(UInt#(12) addr);
   method Bit#(8)    readData();
   // Overwrite one byte of the buffer (used by Reed-Solomon to write a correction back).
   // Never in the same cycle as putByte.
   method Action     writeByte(UInt#(12) addr, Bit#(8) x);
endinterface

// ---------------------------------------------------------------------------
// The byte store: cap registers without reset, one write port, one read port that
// answers one cycle after readReq.  The address is decoded ONCE into a one-hot row
// and a one-hot column (64 columns), and every byte sits where its row and column
// meet.  Written this way bsc and the C++ compiler stay fast even for thousands of bytes.
// ---------------------------------------------------------------------------
interface ByteMem#(numeric type cap);
   method Action  write(UInt#(12) addr, Bit#(8) x);
   method Action  readReq(UInt#(12) addr);
   method Bit#(8) readData();
endinterface

module mkByteMem(ByteMem#(cap)) provisos (Add#(1, _c, cap));
   Integer capI = valueOf(cap);
   Integer rows = (capI + 63) / 64;
   if (capI > 4096) error("ByteMem: cap must be at most 4096");

   Vector#(cap, Reg#(Bit#(8))) store <- replicateM(mkRegU);
   Reg#(Bit#(8))               rdReg <- mkRegU;
   RWire#(Tuple2#(UInt#(12), Bit#(8))) wrW <- mkRWire;
   RWire#(UInt#(12))                   rdW <- mkRWire;

   function Vector#(64, Bool) onehot6(UInt#(6) v);
      function Bool hit(Integer i) = (v == fromInteger(i));
      return genWith(hit);
   endfunction

   // write decode
   match {.wA, .wX} = fromMaybe(?, wrW.wget);
   UInt#(6) wCol = truncate(wA);
   UInt#(6) wRow = truncate(wA >> 6);
   Vector#(64, Bool) wColSel = onehot6(wCol);
   Vector#(64, Bool) wRowSel = onehot6(wRow);

   for (Integer r = 0; r < rows; r = r + 1)
      rule writeRow (isValid(wrW.wget) && wRowSel[r]);     // one rule per row of 64 bytes
         for (Integer c = 0; c < 64; c = c + 1)
            if (r * 64 + c < capI && wColSel[c])
               store[r * 64 + c] <= wX;
      endrule

   // read decode: balanced AND-OR tree over all bytes
   UInt#(12) rA = fromMaybe(?, rdW.wget);
   UInt#(6) rCol = truncate(rA);
   UInt#(6) rRow = truncate(rA >> 6);
   Vector#(64, Bool) rColSel = onehot6(rCol);
   Vector#(64, Bool) rRowSel = onehot6(rRow);
   function Bit#(8) term(Integer i) = (rRowSel[i / 64] && rColSel[i % 64]) ? store[i] : 0;
   Vector#(cap, Bit#(8)) terms = genWith(term);

   rule readRule (isValid(rdW.wget));
      rdReg <= fold(\| , terms);
   endrule

   method Action  write(UInt#(12) addr, Bit#(8) x) = wrW.wset(tuple2(addr, x));
   method Action  readReq(UInt#(12) addr)          = rdW.wset(addr);
   method Bit#(8) readData                         = rdReg;
endmodule

module mkQRBlockBuf(QRBlockBuf#(cap))
   provisos (Add#(TLog#(cap), _a, 12), Add#(153, _b, cap), Add#(1, _c, cap));   // largest block is 153 bytes

   Integer capI = valueOf(cap);
   if (capI > 4095) error("QRBlockBuf: cap must be below 4096");
   UInt#(12) capV = fromInteger(capI);

   // The buffer.  No reset inside: it is never read before it is written, and a
   // register without reset is smaller.
   ByteMem#(cap) mem <- mkByteMem;

   // symbol description
   Reg#(UInt#(5))  ecR <- mkReg(0);
   Reg#(UInt#(7))  n1R <- mkReg(0);
   Reg#(UInt#(7))  d1R <- mkReg(0);
   Reg#(UInt#(7))  nbR <- mkReg(0);

   // current group and the planner
   Reg#(UInt#(7))  g0R      <- mkReg(0);
   Reg#(UInt#(7))  g1R      <- mkReg(0);
   Reg#(Bool)      gValid   <- mkReg(False);
   Reg#(Bool)      planning <- mkReg(False);
   Reg#(UInt#(7))  pb       <- mkReg(0);
   Reg#(UInt#(12)) pacc     <- mkReg(0);

   // the de-interleaver: where the next incoming byte belongs
   Reg#(Bool)      filling <- mkReg(False);
   Reg#(Bool)      fullR   <- mkReg(False);
   Reg#(UInt#(2))  wph     <- mkReg(0);       // 0 data, 1 extra data of long blocks, 2 check
   Reg#(UInt#(7))  wb      <- mkReg(0);       // block number
   Reg#(UInt#(7))  widx    <- mkReg(0);       // byte index i (data) or j (check)
   Reg#(UInt#(12)) wbase   <- mkReg(0);       // buffer address of block wb (valid for wb >= g0)
   Reg#(UInt#(12)) baseN1  <- mkReg(0);       // wbase of block n1, remembered for the extra-byte phase

   // the block walker for the RS stage
   Reg#(UInt#(7))  ib    <- mkReg(0);
   Reg#(UInt#(12)) ibase <- mkReg(0);

   // method -> rule signals; the rule `step` owns every register
   RWire#(BlockParams) cfgW    <- mkRWire;
   RWire#(UInt#(7))    planW   <- mkRWire;
   RWire#(Bit#(8))     putW    <- mkRWire;
   PulseWire           rewW    <- mkPulseWire;
   PulseWire           advW    <- mkPulseWire;
   RWire#(UInt#(12))   rdW     <- mkRWire;
   RWire#(Tuple2#(UInt#(12), Bit#(8))) fixW <- mkRWire;

   // data bytes of block b: the first n1 blocks have d1, the rest d1+1
   function UInt#(7) dlen(UInt#(7) b) = (b >= n1R) ? d1R + 1 : d1R;
   function UInt#(12) blen(UInt#(7) b) = zeroExtend(dlen(b)) + zeroExtend(ecR);

   (* fire_when_enabled, no_implicit_conditions *)
   rule step;
      Maybe#(Tuple2#(UInt#(12), Bit#(8))) wr = tagged Invalid;   // the one write to the buffer this cycle
      // ----------------------------------------------------------- set-up / planning / filling
      if (cfgW.wget matches tagged Valid .p) begin
         ecR <= p.ecLen;  n1R <= p.n1;  d1R <= p.d1;  nbR <= p.nb;
      end
      else if (planW.wget matches tagged Valid .g0) begin
         g0R      <= g0;
         pb       <= g0;
         pacc     <= 0;
         planning <= True;
         gValid   <= False;
         filling  <= False;
         fullR    <= False;
      end
      else if (planning) begin
         // add blocks while they fit
         Bool stop = (pb == nbR) || (pacc + blen(pb) > capV);
         if (stop) begin
            g1R      <= pb;
            planning <= False;
            gValid   <= True;
            filling  <= True;                 // start of the de-interleaver
            wph <= 0;  wb <= 0;  widx <= 0;  wbase <= 0;
         end
         else begin
            pacc <= pacc + blen(pb);
            pb   <= pb + 1;
         end
      end
      else if (putW.wget matches tagged Valid .x &&& filling) begin
         // where does this byte go?
         UInt#(7) dl  = dlen(wb);
         UInt#(8) pos = (wph == 0) ? zeroExtend(widx)
                      : (wph == 1) ? zeroExtend(d1R)
                      :              zeroExtend(dl) + zeroExtend(widx);
         UInt#(12) addr = wbase + zeroExtend(pos);
         Bool inGroup = (wb >= g0R) && (wb < g1R);
         if (inGroup) wr = tagged Valid tuple2(addr, x);

         // where does the next byte go?
         Bool      lastB    = (wb == nbR - 1);
         UInt#(7)  nextWb   = lastB ? 0 : wb + 1;
         UInt#(12) nextBase = (nextWb <= g0R) ? 0 : wbase + blen(wb);
         if (wph == 0 && wb == n1R) baseN1 <= wbase;      // remembered for phase 1
         UInt#(12) baseOfN1 = (wb == n1R) ? wbase : baseN1;

         // next state of the counters (variables, so each register is written once)
         UInt#(7)  nWb   = nextWb;
         UInt#(12) nBase = nextBase;
         UInt#(2)  nPh   = wph;
         UInt#(7)  nIdx  = widx;
         Bool      allIn = False;
         if (lastB) begin                                 // wrapped past the last block
            nWb = 0;  nBase = 0;
            case (wph)
               0: begin                                   // data bytes
                     if (widx == d1R - 1) begin           // last data round
                        if (n1R != nbR) begin             // some blocks are longer: their extra byte comes next
                           nPh = 1;  nWb = n1R;  nBase = baseOfN1;  nIdx = d1R;
                        end
                        else begin nPh = 2;  nIdx = 0; end
                     end
                     else nIdx = widx + 1;
                  end
               1: begin nPh = 2;  nIdx = 0; end           // extra data bytes done
               default: begin                              // check bytes
                     if (widx == zeroExtend(ecR) - 1) allIn = True;
                     else nIdx = widx + 1;
                  end
            endcase
         end
         wb <= nWb;  wbase <= nBase;  wph <= nPh;  widx <= nIdx;
         if (allIn) begin filling <= False;  fullR <= True; end
      end

      // a correction written back by the RS stage (never in the same cycle as a fill)
      if (fixW.wget matches tagged Valid {.fa, .fx}) wr = tagged Valid tuple2(fa, fx);
      if (wr matches tagged Valid {.wa, .wx}) mem.write(wa, wx);

      // ----------------------------------------------------------- block walker
      if (rewW)      begin ib <= g0R;  ibase <= 0; end
      else if (advW) begin ib <= ib + 1;  ibase <= ibase + blen(ib); end

      // ----------------------------------------------------------- read port
      if (rdW.wget matches tagged Valid .a) mem.readReq(a);
   endrule

   method Action configure(BlockParams p) = cfgW.wset(p);
   method Action planPass(UInt#(7) g0)     = planW.wset(g0);
   method Bool     groupValid  = gValid;
   method UInt#(7) groupStart  = g0R;
   method UInt#(7) groupEnd    = g1R;
   method Bool     moreGroups  = gValid && (g1R < nbR);

   method Action putByte(Bit#(8) x) if (filling);
      putW.wset(x);
   endmethod
   method Bool filled = fullR;

   method Action rewindBlocks = rewW.send;
   method Action advanceBlock = advW.send;
   method BlockDesc curBlock;
      return BlockDesc { valid: ib < g1R, idx: ib, base: ibase,
                         dataLen: dlen(ib), len: truncate(blen(ib)) };
   endmethod

   method Action readReq(UInt#(12) addr) = rdW.wset(addr);
   method Bit#(8) readData = mem.readData;
   method Action writeByte(UInt#(12) addr, Bit#(8) x) = fixW.wset(tuple2(addr, x));
endmodule

endpackage
