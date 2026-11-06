// Unit 7: the top level.  Wires the reader (unit 3), the block buffer (unit 4), Reed-Solomon (unit 5)
// and the payload parser (unit 6) together and runs the sequence below.  Spec rules C1-C5 apply.
//
//   start(size)       size ok? (21..177, 17+4v)  else failed at once
//   startFormat(n)    read both format copies             -> TFmt   (unreadable -> failed)
//   configure(p)      blockParams(version, level)         -> TCfg
//   per PASS (a group of blocks that fits in the buffer; one pass when the whole symbol fits):
//      planPass(g0)   choose the group                    -> TPlan, TWaitPlan
//      startData      read the symbol again, forward every codeword byte to putByte  -> TFill
//      per BLOCK of the group: decodeBlock, forward the corrected data bytes to the payload parser -> TBlk, TRun, TAdv
//   endOfData         after the last block of the last pass                          -> TFinal
//   done              when the parser has handed out every character
//
// Reading and Reed-Solomon never overlap, so the reader is idle whenever a failure can be noticed.
// Every sub-unit restarts from any state, so a failure just returns to TIdle: the next start()
// reconfigures everything.  The parser may fail in the middle of the stream (malformed payload),
// Reed-Solomon of a later block may fail after characters were already handed out; both just
// raise failed (the test bench discards bytes delivered before failed, spec C2).
//
// Buffer size: -D CAP=<bytes> overrides the default (1024) for experiments.
package QRDecoder;

import QRTypes   :: *;
import QRTables  :: *;
import QRFormat  :: *;
import QRReader  :: *;
import QRBlocks  :: *;
import QRRS      :: *;
import QRPayload :: *;

`ifdef CAP
typedef `CAP QRCap;
`else
typedef 1024 QRCap;
`endif

typedef enum { TIdle, TFmt, TCfg, TPlan, TWaitPlan, TFill, TRewind, TBlk, TRun, TAdv, TFinal }
   TopSt deriving (Bits, Eq, FShow);

(* synthesize *)
module mkQRDecoder (QRDecoder);

   QRReader            rd <- mkQRReader;
   QRBlockBuf#(QRCap)  bb <- mkQRBlockBuf;
   QRRS                rs <- mkQRRS(bb);
   QRPayload           pl <- mkQRPayload;

   Reg#(TopSt)     st      <- mkReg(TIdle);
   Reg#(Bool)      failedR <- mkReg(False);
   Reg#(Bool)      doneR   <- mkReg(False);
   Reg#(Coord)     nR      <- mkReg(0);
   Reg#(UInt#(6))  verR    <- mkReg(1);
   Reg#(Bit#(2))   lvlR    <- mkReg(0);
   Reg#(Bit#(3))   maskR   <- mkReg(0);
   Reg#(UInt#(7))  g0      <- mkReg(0);        // first block of the current pass

   RWire#(Coord)   startW  <- mkRWire;

   BlockParams p = blockParams(verR, lvlR);

   // Move every codeword byte of the symbol, in symbol order, into the block buffer.
   rule fwdRd (st == TFill);
      let b <- rd.getCodeword;
      bb.putByte(b);
   endrule

   // Move the corrected data bytes of the current block into the payload parser.
   rule fwdRs (st == TRun);
      let b <- rs.getData;
      pl.putByte(b);
   endrule

   (* fire_when_enabled, no_implicit_conditions *)
   rule ctl;
      TopSt nst   = st;
      Bool  nfail = failedR;
      Bool  ndone = doneR;

      if (startW.wget matches tagged Valid .sz) begin
         UInt#(8) t = sz - 17;
         Bool okSize = (sz >= 21) && (sz <= 177) && (pack(t)[1:0] == 0);
         ndone = False;
         if (okSize) begin
            UInt#(6) v = truncate(t >> 2);
            nfail = False;
            nR    <= sz;
            verR  <= v;
            rd.startFormat(sz);
            pl.start(v);
            nst = TFmt;
         end
         else nfail = True;                                    // bad side length
      end
      else if (st != TIdle && pl.failed) begin                 // malformed payload
         nfail = True;
         nst   = TIdle;
      end
      else begin
         case (st)
            TFmt: begin
               if (rd.formatInfo matches tagged Valid .f) begin
                  if (f.ok) begin
                     lvlR  <= f.level;
                     maskR <= f.mask;
                     nst = TCfg;
                  end
                  else begin nfail = True; nst = TIdle; end    // unreadable format information
               end
            end

            TCfg: begin
               bb.configure(p);
               g0  <= 0;
               nst = TPlan;
            end

            TPlan: begin
               bb.planPass(g0);
               nst = TWaitPlan;
            end

            TWaitPlan: begin
               if (bb.groupValid) begin
                  rd.startData(nR, verR, maskR);
                  nst = TFill;
               end
            end

            TFill: begin
               if (bb.filled && rd.dataFinished) nst = TRewind;
            end

            TRewind: begin
               bb.rewindBlocks;
               nst = TBlk;
            end

            TBlk: begin
               BlockDesc d = bb.curBlock;
               if (d.valid) begin
                  rs.decodeBlock(p.ecLen, d);
                  nst = TRun;
               end
               else if (bb.moreGroups) begin
                  g0  <= bb.groupEnd;
                  nst = TPlan;
               end
               else begin
                  pl.endOfData;
                  nst = TFinal;
               end
            end

            TRun: begin
               if (rs.failed) begin nfail = True; nst = TIdle; end   // too many errors in a block
               else if (rs.done) nst = TAdv;
            end

            TAdv: begin
               bb.advanceBlock;
               nst = TBlk;
            end

            TFinal: begin
               if (pl.done) begin ndone = True; nst = TIdle; end
            end

            default: begin end
         endcase
      end

      st      <= nst;
      failedR <= nfail;
      doneR   <= ndone;
   endrule

   method Action start(Coord size) if (st == TIdle);
      startW.wset(size);
   endmethod

   method ActionValue#(OutByte) getByte() if (!failedR);
      let x <- pl.getByte;
      return x;
   endmethod

   method Bool failed = failedR;
   method Bool done   = doneR;

   interface mem = rd.mem;

endmodule

endpackage
