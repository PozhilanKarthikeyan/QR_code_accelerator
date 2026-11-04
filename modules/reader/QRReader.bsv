// QRReader.bsv -- unit 3: reads the bitmap through the memory port.
//
// Two jobs, one after the other:
//   startFormat(n)             : read both copies of the format information (30 reads),
//                                then formatInfo() holds the decoded result (QRFormat).
//   startData(n, ver, mask)    : walk every data module (QRWalker), read it, undo the
//                                mask, pack 8 bits (first bit = MSB) into a codeword
//                                byte and hand the bytes out, in reading order, through
//                                getCodeword().  The 3-7 left-over remainder bits of
//                                some versions never complete a byte and are dropped.
//
// Rules of the memory port (spec C4) that shape this file:
//   * the answer to a request taken in cycle k arrives in cycle k+1, and then HOLDS
//     (the same value keeps showing until the next answer replaces it), so the
//     reader remembers that it asked and trusts resp() only in the cycle after;
//   * the test bench always takes a request in the cycle it is ready, so "ready"
//     can be treated as "will be taken".
//
// The reader may be restarted as often as the top level likes, but only while it is
// idle, i.e. nothing is in flight: after formatInfo() is valid, or dataFinished().
package QRReader;

import QRTypes  :: *;
import QRTables :: *;
import QRFormat :: *;
import QRWalker :: *;

typedef enum { Idle, Fmt, Data } ReaderPhase deriving (Bits, Eq, FShow);

interface QRReader;
   // Read both format copies.  n = side length (already known to be 17+4*ver).
   method Action startFormat(Coord n);
   // Invalid until all 30 format bits have arrived; stays valid until the next start.
   method Maybe#(FormatInfo) formatInfo();

   // Read the data modules.  mask = FormatInfo.mask.  Restarts from the first module.
   method Action startData(Coord n, UInt#(6) ver, Bit#(3) mask);
   // Next unmasked codeword byte, in the order they sit in the symbol.
   method ActionValue#(Bit#(8)) getCodeword();
   // True once every data module has been read and every byte has been taken.
   method Bool dataFinished();

   interface MemPort mem;
endinterface

module mkQRReader(QRReader);
   Reg#(ReaderPhase) phase   <- mkReg(Idle);
   Reg#(Coord)       nReg    <- mkReg(0);
   Reg#(Bit#(3))     maskReg <- mkReg(0);

   QRWalker walker <- mkQRWalker;

   // ---- format phase ------------------------------------------------------
   Reg#(UInt#(5)) fmtIssued <- mkReg(0);      // requests issued so far, 0..30
   Reg#(Bit#(15)) fmtW1     <- mkReg(0);      // copy 1, bit i = f_i
   Reg#(Bit#(15)) fmtW2     <- mkReg(0);      // copy 2
   Reg#(Bool)     fmtFin    <- mkReg(False);

   // ---- data phase: one-position buffer between walker and memory port ----
   Reg#(Bool)  stagedValid <- mkReg(False);
   Reg#(Coord) stR         <- mkReg(0);
   Reg#(Coord) stC         <- mkReg(0);

   // ---- the request that was taken last cycle (its answer arrives now) ----
   Reg#(Bool)     pendValid <- mkReg(False);
   Reg#(Bool)     pendFmt   <- mkReg(False);
   Reg#(UInt#(5)) pendIdx   <- mkReg(0);
   Reg#(Coord)    pendR     <- mkReg(0);
   Reg#(Coord)    pendC     <- mkReg(0);

   // ---- byte assembly and the one-byte output slot ------------------------
   Reg#(Bit#(7))  shiftReg <- mkReg(0);       // bits 0..6 of the byte being built
   Reg#(UInt#(3)) bitCnt   <- mkReg(0);       // how many are in shiftReg
   Reg#(Bool)     outValid <- mkReg(False);
   Reg#(Bit#(8))  outByte  <- mkReg(0);
   Reg#(Bool)     dataFin  <- mkReg(False);

   // ---- signals between methods and rules (each register has ONE writer: step)
   Wire#(Bit#(1))                    respW      <- mkBypassWire;
   RWire#(Tuple2#(Coord, Coord))     pulledW    <- mkRWire;
   PulseWire                         reqTakenW  <- mkPulseWire;
   PulseWire                         getW       <- mkPulseWire;
   RWire#(Coord)                     startFmtW  <- mkRWire;
   RWire#(Tuple3#(Coord, UInt#(6), Bit#(3))) startDataW <- mkRWire;

   // ---- when do we want to issue a request? (registers only) ---------------
   Bool fmtWant = (phase == Fmt) && (fmtIssued < 30);

   // A new request is the 8th bit of a byte iff 7 bits are already read or in flight.
   // That request's answer would complete a byte, so the output slot must be free.
   UInt#(4) bitsSoFar = zeroExtend(bitCnt) + ((pendValid && !pendFmt) ? 1 : 0);
   Bool     is8th     = (bitsSoFar == 7);
   Bool     dataWant  = (phase == Data) && stagedValid && (!is8th || !outValid);

   // format bit position for request number fmtIssued (0..14 copy 1, 15..29 copy 2)
   Bool     second = (fmtIssued >= 15);
   UInt#(5) i5     = second ? fmtIssued - 15 : fmtIssued;
   UInt#(4) i4     = truncate(i5);
   Tuple2#(Coord, Coord) fmtPos = formatPosition(nReg, second, i4);

   // Fetch the next data position from the walker whenever the buffer is empty or is
   // being emptied this cycle.
   rule pull (phase == Data && (!stagedValid || dataWant));
      match {.r, .c} <- walker.next;
      pulledW.wset(tuple2(r, c));
   endrule

   (* fire_when_enabled, no_implicit_conditions *)
   rule step;
      if (startFmtW.wget matches tagged Valid .n) begin
         phase     <= Fmt;
         nReg      <= n;
         fmtIssued <= 0;
         fmtW1     <= 0;
         fmtW2     <= 0;
         fmtFin    <= False;
         pendValid <= False;
      end
      else if (startDataW.wget matches tagged Valid {.n, .v, .m}) begin
         phase       <= Data;
         maskReg     <= m;
         bitCnt      <= 0;
         shiftReg    <= 0;
         outValid    <= False;
         dataFin     <= False;
         stagedValid <= False;
         pendValid   <= False;
      end
      else begin
         // --- remember the request taken this cycle; its answer comes next cycle
         pendValid <= reqTakenW;
         pendFmt   <= (phase == Fmt);
         pendIdx   <= fmtIssued;
         pendR     <= stR;
         pendC     <= stC;
         if (reqTakenW && phase == Fmt) fmtIssued <= fmtIssued + 1;

         // --- use the answer to last cycle's request
         ReaderPhase nextPhase = phase;
         Bool fill = False;                       // a byte completes this cycle
         if (pendValid) begin
            if (pendFmt) begin
               Bool     sec = (pendIdx >= 15);
               UInt#(5) k5  = sec ? pendIdx - 15 : pendIdx;
               UInt#(4) k4  = truncate(k5);
               Bit#(15) bitv = zeroExtend(respW) << k4;
               if (sec) fmtW2 <= fmtW2 | bitv; else fmtW1 <= fmtW1 | bitv;
               if (pendIdx == 29) begin
                  fmtFin    <= True;
                  nextPhase = Idle;
               end
            end
            else begin
               Bit#(1) b   = respW ^ (maskInverts(maskReg, pendR, pendC) ? 1 : 0);
               if (bitCnt == 7) begin
                  outByte  <= {shiftReg, b};       // first bit read ends up as the MSB
                  fill      = True;
                  bitCnt   <= 0;
               end
               else begin
                  shiftReg <= {shiftReg[5:0], b};
                  bitCnt   <= bitCnt + 1;
               end
            end
         end

         // --- one-position buffer
         if (pulledW.wget matches tagged Valid {.r, .c}) begin
            stR <= r;  stC <= c;  stagedValid <= True;
         end
         else if (dataWant)
            stagedValid <= False;                  // handed to the memory port

         // --- output slot
         if (fill)      outValid <= True;
         else if (getW) outValid <= False;

         // --- all positions handed out, answered and unmasked?
         if (phase == Data && !walker.busy && !stagedValid && !pendValid
             && !isValid(pulledW.wget)) begin
            nextPhase = Idle;
            dataFin  <= True;
         end
         phase <= nextPhase;
      end
   endrule

   // ------------------------------------------------------------------------
   method Action startFormat(Coord n);
      startFmtW.wset(n);
   endmethod

   method Maybe#(FormatInfo) formatInfo();
      return fmtFin ? tagged Valid decodeFormat(fmtW1, fmtW2) : tagged Invalid;
   endmethod

   method Action startData(Coord n, UInt#(6) ver, Bit#(3) mask);
      startDataW.wset(tuple3(n, ver, mask));
      walker.start(n, ver);
   endmethod

   method ActionValue#(Bit#(8)) getCodeword() if (outValid);
      getW.send;
      return outByte;
   endmethod

   method Bool dataFinished = dataFin && !outValid;

   interface MemPort mem;
      method ActionValue#(Tuple2#(Coord, Coord)) req() if (fmtWant || dataWant);
         reqTakenW.send;
         return fmtWant ? fmtPos : tuple2(stR, stC);
      endmethod
      method Action resp(Bit#(1) b);
         respW <= b;
      endmethod
   endinterface
endmodule

endpackage
