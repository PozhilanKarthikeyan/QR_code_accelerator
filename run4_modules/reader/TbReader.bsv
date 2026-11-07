// Plays the part of the course test bench for the reader:
//   * holds the bitmaps from symbols.hex and answers mem.req one cycle later
//     (the answer holds until the next one replaces it; reads outside the matrix give 0)
//   * for every case in cases.hex: reads the format info, and if it is valid, reads all
//     data modules and takes the codeword bytes with back-pressure
//       case index mod 3 == 0 : takes every byte at once
//                          1 : takes a byte in about half of the cycles
//                          2 : takes a byte in about 1 of 16 cycles
// Prints, for the Python checker:
//   F case ok level mask        (format result)
//   B case <hex bytes ...>      (codewords in the order received)
//   E case nBytes cycles        (cycles from startFormat until the last byte is taken)
//   X case                      (side length is not 17+4v: not given to the reader)
// Build with  -D NCASES=<number of lines in cases.hex>.
package TbReader;

import RegFile  :: *;
import QRTypes  :: *;
import QRFormat :: *;
import QRReader :: *;

typedef enum { Fetch, StartF, WaitF, StartD, Reading, Next } TbSt deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbReader(Empty);
   Integer numCases = `NCASES;

   RegFile#(UInt#(11), Bit#(128)) cases <- mkRegFileFullLoad("cases.hex");
   RegFile#(UInt#(18), Bit#(180)) syms  <- mkRegFileFullLoad("symbols.hex");

   QRReader rd <- mkQRReader;

   Reg#(TbSt)       st      <- mkReg(Fetch);
   Reg#(UInt#(11))  ci      <- mkReg(0);
   Reg#(Coord)      n       <- mkReg(0);
   Reg#(UInt#(6))   ver     <- mkReg(1);
   Reg#(UInt#(18))  base    <- mkReg(0);
   Reg#(Bit#(3))    maskR   <- mkReg(0);
   Reg#(Bit#(1))    respBit <- mkReg(0);
   Reg#(UInt#(32))  cyc     <- mkReg(0);
   Reg#(UInt#(32))  nBytes  <- mkReg(0);
   Reg#(Bit#(32))   lfsr    <- mkReg(32'hACE1_2468);

   (* fire_when_enabled, no_implicit_conditions *)
   rule tick;
      Bit#(32) a = lfsr ^ (lfsr << 13);
      Bit#(32) b = a ^ (a >> 17);
      lfsr <= b ^ (b << 5);
      cyc  <= cyc + 1;
   endrule

   // ---- the memory ---------------------------------------------------------
   (* fire_when_enabled, no_implicit_conditions *)
   rule feed;                      // resp is called in every cycle with the held answer
      rd.mem.resp(respBit);
   endrule

   rule serve;                     // takes every request in the cycle it is ready
      match {.r, .c} <- rd.mem.req;
      Bit#(180) row = syms.sub(base + zeroExtend(r));
      Bit#(8)   ix  = 179 - pack(c);
      respBit <= (r < n && c < n) ? row[ix] : 0;
   endrule

   // ---- the case sequencer -------------------------------------------------
   rule fetch (st == Fetch);
      if (ci == fromInteger(numCases)) $finish;
      else begin
         Bit#(128) w  = cases.sub(ci);
         Coord     nn = unpack(w[127:120]);
         Bit#(32)  fr = w[63:32];
         base <= unpack(fr[17:0]);
         n    <= nn;
         UInt#(8) t = nn - 17;
         Bool okSize = (nn >= 21) && (nn <= 177) && (pack(t)[1:0] == 0);
         ver  <= truncate(t >> 2);
         if (okSize) st <= StartF;
         else begin $display("X %0d", ci); st <= Next; end
      end
   endrule

   rule startF (st == StartF);
      rd.startFormat(n);
      cyc    <= 1;
      nBytes <= 0;
      st     <= WaitF;
   endrule

   rule waitF (st == WaitF &&& isValid(rd.formatInfo));
      FormatInfo fi = fromMaybe(?, rd.formatInfo);
      $display("F %0d %0d %0d %0d", ci, fi.ok ? 1 : 0, fi.level, fi.mask);
      maskR <= fi.mask;
      if (fi.ok) st <= StartD; else st <= Next;
   endrule

   rule startD (st == StartD);
      rd.startData(n, ver, maskR);
      $write("B %0d ", ci);
      st <= Reading;
   endrule

   UInt#(3) mode = truncate(ci % 3);
   Bool allow = (mode == 0) || (mode == 1 && lfsr[0] == 1) || (mode == 2 && lfsr[3:0] == 0);

   rule take (st == Reading && allow);
      let x <- rd.getCodeword;
      $write("%h", x);
      nBytes <= nBytes + 1;
   endrule

   rule finish (st == Reading && rd.dataFinished);
      $display("");
      $display("E %0d %0d %0d", ci, nBytes, cyc);
      st <= Next;
   endrule

   rule next (st == Next);
      ci <= ci + 1;
      st <= Fetch;
   endrule
endmodule
endpackage
