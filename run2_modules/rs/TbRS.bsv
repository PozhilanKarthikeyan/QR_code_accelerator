// Test bench for QRRS.  For every case in cfg.hex (a version and level) it plays the reader
// (feeds the interleaved bytes of stream.hex into QRBlockBuf, once per pass), then runs the
// RS stage over every block of every group and prints what comes out:
//   R case block <hex of the data bytes> S <cycles>     the block was corrected
//   R case block <nothing>               F <cycles>     the block could not be corrected
// Build with  -D CAP=<buffer bytes> -D NCASES=<number of lines in cfg.hex>.
package TbRS;

import RegFile  :: *;
import QRTypes  :: *;
import QRTables :: *;
import QRBlocks :: *;
import QRRS     :: *;

typedef `CAP Cap;

typedef enum { Cfg, Cfg2, Plan, WaitPlan, Fill, WaitFull, Rewind, Blk, Wait, Adv, Next, Fin } TbSt
   deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbRS(Empty);
   Integer numCases = `NCASES;

   RegFile#(UInt#(18), Bit#(8))  stream <- mkRegFileFullLoad("stream.hex");
   RegFile#(UInt#(10), Bit#(32)) cfg    <- mkRegFileFullLoad("cfg.hex");

   QRBlockBuf#(Cap) bb <- mkQRBlockBuf;
   QRRS             rs <- mkQRRS(bb);

   Reg#(TbSt)      st   <- mkReg(Cfg);
   Reg#(UInt#(10)) ci   <- mkReg(0);          // case number
   Reg#(UInt#(6))  ver  <- mkReg(1);
   Reg#(Bit#(2))   lf   <- mkReg(0);
   Reg#(UInt#(18)) off  <- mkReg(0);
   Reg#(UInt#(7))  g0   <- mkReg(0);
   Reg#(UInt#(12)) cnt  <- mkReg(0);
   Reg#(UInt#(16)) bcyc <- mkReg(0);

   BlockParams p = blockParams(ver, lf);

   rule cfg1 (st == Cfg);
      if (ci == fromInteger(numCases)) st <= Fin;
      else begin
         Bit#(32) w = cfg.sub(ci);
         ver <= unpack(w[31:26]);
         lf  <= w[25:24];
         off <= unpack(w[17:0]);
         st  <= Cfg2;
      end
   endrule

   rule cfg2 (st == Cfg2);
      bb.configure(p);
      g0 <= 0;
      st <= Plan;
   endrule

   rule plan (st == Plan);
      bb.planPass(g0);
      st <= WaitPlan;
   endrule

   rule waitPlan (st == WaitPlan && bb.groupValid);
      cnt <= 0;
      st  <= Fill;
   endrule

   rule fill (st == Fill);
      bb.putByte(stream.sub(off + zeroExtend(cnt)));
      if (cnt == p.total - 1) st <= WaitFull; else cnt <= cnt + 1;
   endrule

   rule waitFull (st == WaitFull && bb.filled);
      st <= Rewind;
   endrule

   rule rewind (st == Rewind);
      bb.rewindBlocks;
      st <= Blk;
   endrule

   rule blk (st == Blk);
      BlockDesc d = bb.curBlock;
      if (d.valid) begin
         $write("R %0d %0d ", ci, d.idx);
         rs.decodeBlock(p.ecLen, d);
         bcyc <= 0;
         st   <= Wait;
      end
      else if (bb.moreGroups) begin g0 <= bb.groupEnd; st <= Plan; end
      else st <= Next;
   endrule

   rule take;                                  // the corrected data bytes
      let x <- rs.getData;
      $write("%h", x);
   endrule

   rule watch (st == Wait);                   // count cycles; report when the block is finished
      if (rs.done) begin
         $display(" S %0d", bcyc);
         st <= Adv;
      end
      else if (rs.failed) begin
         $display(" F %0d", bcyc);
         st <= Adv;
      end
      else bcyc <= bcyc + 1;
   endrule

   rule adv (st == Adv);
      bb.advanceBlock;
      st <= Blk;
   endrule

   rule next (st == Next);
      ci <= ci + 1;
      st <= Cfg;
   endrule

   rule fin (st == Fin);
      $display("DONE");
      $finish;
   endrule
endmodule
endpackage
