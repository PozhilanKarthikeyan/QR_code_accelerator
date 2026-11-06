// Whole-decoder test bench.  Plays the part of the course test bench, for many symbols in a row
// WITHOUT reset, and checks the rules of the interface (spec C1-C4) while it runs:
//   * holds the bitmaps from symbols.hex, answers mem.req one cycle later (the answer holds; reads
//     outside the matrix give 0), takes every request in the cycle it is ready;
//   * for every case of cases.hex: start(N), then takes getByte with back-pressure
//       k = (number of the case run so far) mod 4:   0: takes a byte whenever one is ready
//                                                     1: about 1 cycle in 4
//                                                     2: about 1 cycle in 32
//                                                     3: about 1 cycle in 64
//     and compares every byte and its `last` flag with expect_data.hex (C1);
//   * C2: failed and done are never high together, the first of them to rise stays high until the next
//     start, done never rises before the byte with last was taken, a valid symbol never raises failed,
//     a symbol that must fail never raises done;
//   * C3: a getByte that fires while failed is high is an error.
//   * start() is called as soon as the previous case ended; its implicit condition decides when it fires.
// Prints for check_top.py (all numbers decimal):
//   R case k code latency total errors bytes
//        code 0 = done rose, 1 = failed rose, 2 = no result within 3,000,000 cycles
//        latency = cycles from start until the byte with last was taken (0 if none), total = until done/failed
//   E case ...   one line per case with a data or flag mismatch (first one only)
//   END          after the last case
// Build with  -D NCASES=<lines in cases.hex>  -D STEP=<run every STEP-th case; 1 = all>  [-D CAP=<bytes>].
package TbTop;

import RegFile   :: *;
import ConfigReg :: *;
import QRTypes   :: *;
import QRDecoder :: *;

typedef enum { BFetch, BStart, BRun, BGap } BSt deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbTop(Empty);
   Integer numCases = `NCASES;
   Integer stepV    = `STEP;

   RegFile#(UInt#(11), Bit#(128)) cases <- mkRegFileFullLoad("cases.hex");
   RegFile#(UInt#(18), Bit#(180)) syms  <- mkRegFileFullLoad("symbols.hex");
   RegFile#(UInt#(15), Bit#(8))   expd  <- mkRegFileFullLoad("expect_data.hex");

   QRDecoder dut <- mkQRDecoder;

   Reg#(BSt)       st      <- mkReg(BFetch);
   Reg#(UInt#(12)) ci      <- mkReg(0);
   Reg#(UInt#(12)) ctr     <- mkReg(0);        // cases run so far
   Reg#(Coord)     n       <- mkReg(0);
   Reg#(Bool)      expOk   <- mkReg(False);
   Reg#(UInt#(16)) len     <- mkReg(0);
   Reg#(UInt#(15)) off     <- mkReg(0);
   Reg#(UInt#(18)) base    <- mkReg(0);
   Reg#(UInt#(2))  mode    <- mkReg(0);
   Reg#(Bit#(1))   respBit <- mkReg(0);
   Reg#(Bit#(32))  lfsr    <- mkReg(32'hACE12468);
   Reg#(UInt#(32)) gcyc    <- mkReg(0);
   Reg#(UInt#(32)) startAt <- mkReg(0);
   Reg#(UInt#(2))  ended   <- mkReg(0);        // 0 running, 1 failed rose, 2 done rose
   Reg#(UInt#(8))  errM    <- mkReg(0);
   Reg#(UInt#(3))  gapCnt  <- mkReg(0);
   Reg#(UInt#(32)) totalR  <- mkReg(0);

   // written by rGet, read by rMon: ConfigReg so that the two rules need no ordering
   Reg#(UInt#(16)) idx      <- mkConfigReg(0);
   Reg#(UInt#(8))  errG     <- mkConfigReg(0);
   Reg#(Bool)      lastSeen <- mkConfigReg(False);
   Reg#(UInt#(32)) lastCyc  <- mkConfigReg(0);

   Bool allow = (mode == 0)
             || (mode == 1 && lfsr[1:0] == 0)
             || (mode == 2 && lfsr[6:2] == 0)
             || (mode == 3 && lfsr[12:7] == 0);

   (* fire_when_enabled, no_implicit_conditions *)
   rule tick;
      Bit#(32) a = lfsr ^ (lfsr << 13);
      Bit#(32) b = a ^ (a >> 17);
      lfsr <= b ^ (b << 5);
      gcyc <= gcyc + 1;
   endrule

   // ---- the memory ---------------------------------------------------------
   (* fire_when_enabled, no_implicit_conditions *)
   rule feed;
      dut.mem.resp(respBit);
   endrule

   rule serve;
      match {.r, .c} <- dut.mem.req;
      Bit#(180) row = syms.sub(base + zeroExtend(r));
      Bit#(8)   ix  = 179 - pack(c);
      respBit <= (r < n && c < n) ? row[ix] : 0;
   endrule

   // ---- the case sequencer -------------------------------------------------
   rule rFetch (st == BFetch);
      if (ci >= fromInteger(numCases)) begin
         $display("END");
         $finish;
      end
      else begin
         Bit#(128) w = cases.sub(truncate(ci));
         n     <= unpack(w[127:120]);
         expOk <= (w[112] == 1);
         len   <= unpack(w[111:96]);
         off   <= unpack(w[78:64]);
         base  <= unpack(w[49:32]);
         mode  <= truncate(ctr);
         st    <= BStart;
      end
   endrule

   rule rStart (st == BStart);
      dut.start(n);                       // waits here until the decoder is ready for a new symbol
      startAt  <= gcyc;
      idx      <= 0;
      errG     <= 0;
      lastSeen <= False;
      ended    <= 0;
      errM     <= 0;
      st       <= BRun;
   endrule

   // ---- take the message (C1, C3) -------------------------------------------
   rule rGet (st == BRun && allow);
      let o <- dut.getByte;
      UInt#(8) e = errG;
      if (dut.failed) e = e + 1;                                  // C3: byte taken while failed is high
      if (expOk) begin
         if (idx >= len) e = e + 1;                               // more bytes than the message has
         else begin
            Bit#(8) want = expd.sub(off + truncate(idx));
            Bool    wl   = (idx + 1 == len);
            if (o.data != want || o.last != wl) begin
               if (errG == 0)
                  $display("E %0d byte %0d got %0h last %0d, want %0h last %0d",
                           ci, idx, o.data, o.last ? 1 : 0, want, wl ? 1 : 0);
               e = e + 1;
            end
         end
      end
      if (o.last) begin lastSeen <= True; lastCyc <= gcyc; end
      idx  <= idx + 1;
      errG <= e;
   endrule

   // ---- watch failed / done (C2), end the case ------------------------------
   // The result is noted when failed or done first rises; the R line is printed after a short gap in
   // which the result must stay unchanged (so that a result that drops again is still reported).
   rule rMon (st == BRun || st == BGap);
      Bool f = dut.failed;
      Bool d = dut.done;
      UInt#(8) em = errM;
      if (f && d) em = em + 1;                                    // never both
      if (st == BRun && (f || d) && gcyc - startAt == 1) em = em + 1;   // C2: both low in the cycle after start
      if (st == BRun) begin
         if (f || d) begin
            if (f && expOk)  em = em + 1;                         // a valid symbol must not fail
            if (d && !expOk) em = em + 1;                         // a symbol that must fail must not finish
            if (d && expOk && (idx != len || (len != 0 && !lastSeen))) em = em + 1;   // done before the last byte was taken
            ended  <= f ? 1 : 2;
            totalR <= gcyc - startAt;
            errM   <= em;
            UInt#(2) gr = unpack(lfsr[9:8]);
            gapCnt <= 2 + zeroExtend(gr);
            st     <= BGap;
         end
         else if (gcyc - startAt > 3000000) begin
            $display("R %0d %0d 2 0 %0d %0d %0d", ci, mode, gcyc - startAt, errG + em, idx);
            $finish;
         end
         else errM <= em;
      end
      else begin                                                  // BGap: the result must stay as it was
         if (ended == 1 && !(f && !d)) em = em + 1;
         if (ended == 2 && !(d && !f)) em = em + 1;
         errM <= em;
         if (gapCnt == 0) begin
            UInt#(32) lat = lastSeen ? (lastCyc - startAt) : 0;
            $display("R %0d %0d %0d %0d %0d %0d %0d", ci, mode, (ended == 1) ? 1 : 0, lat, totalR,
                     errG + em, idx);
            ci  <= ci + fromInteger(stepV);
            ctr <= ctr + 1;
            st  <= BFetch;
         end
         else gapCnt <= gapCnt - 1;
      end
   endrule
endmodule

endpackage
