// Test bench for QRBlocks.  For every version and level it plays the part of the reader
// (feeds the symbol's bytes from stream.hex, once per pass) and then reads every block of
// every group back out.  Prints, for the Python checker:
//   G v level g0 g1        one line per pass: the group of blocks kept
//   K v level b dataLen len <hex bytes>    block b, byte by byte, as read from the buffer
// Build with  -D CAP=<buffer bytes>.
package TbBlocks;

import RegFile  :: *;
import QRTypes  :: *;
import QRTables :: *;
import QRBlocks :: *;

typedef `CAP Cap;

typedef enum { Cfg, Plan, WaitPlan, Fill, WaitFull, Rewind, Blk, RdReq, RdGet, Adv, Done } TbSt
   deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbBlocks(Empty);
   RegFile#(UInt#(18), Bit#(8)) stream <- mkRegFileFullLoad("stream.hex");
   QRBlockBuf#(Cap) bb <- mkQRBlockBuf;

   Reg#(TbSt)      st    <- mkReg(Cfg);
   Reg#(UInt#(6))  ver   <- mkReg(1);
   Reg#(UInt#(2))  lvIx  <- mkReg(0);
   Reg#(UInt#(18)) off   <- mkReg(0);       // where this symbol's bytes start in stream.hex
   Reg#(UInt#(7))  g0    <- mkReg(0);
   Reg#(UInt#(12)) cnt   <- mkReg(0);
   Reg#(UInt#(12)) rIdx  <- mkReg(0);

   function Bit#(2) levelOf(UInt#(2) i) = (i == 0) ? 1 : (i == 1) ? 0 : (i == 2) ? 3 : 2;
   Bit#(2) lf = levelOf(lvIx);
   BlockParams p = blockParams(ver, lf);

   rule cfg (st == Cfg);
      bb.configure(p);
      g0 <= 0;
      st <= Plan;
   endrule

   rule plan (st == Plan);
      bb.planPass(g0);
      st <= WaitPlan;
   endrule

   rule waitPlan (st == WaitPlan && bb.groupValid);
      $display("G %0d %0d %0d %0d", ver, lf, bb.groupStart, bb.groupEnd);
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
         $write("K %0d %0d %0d %0d %0d ", ver, lf, d.idx, d.dataLen, d.len);
         rIdx <= 0;
         st   <= RdReq;
      end
      else begin
         if (bb.moreGroups) begin g0 <= bb.groupEnd; st <= Plan; end
         else begin
            // next level / version
            if (lvIx == 3) begin
               lvIx <= 0;
               if (ver == 40) st <= Done; else ver <= ver + 1;
            end
            else lvIx <= lvIx + 1;
            off <= off + zeroExtend(p.total);
            if (!(lvIx == 3 && ver == 40)) st <= Cfg;
         end
      end
   endrule

   rule rdReq (st == RdReq);
      bb.readReq(bb.curBlock.base + zeroExtend(rIdx));
      st <= RdGet;
   endrule

   rule rdGet (st == RdGet);
      $write("%h", bb.readData);
      if (rIdx == zeroExtend(bb.curBlock.len) - 1) begin $display(""); st <= Adv; end
      else begin rIdx <= rIdx + 1; st <= RdReq; end
   endrule

   rule adv (st == Adv);
      bb.advanceBlock;
      st <= Blk;
   endrule

   rule done (st == Done);
      $display("DONE");
      $finish;
   endrule
endmodule
endpackage
