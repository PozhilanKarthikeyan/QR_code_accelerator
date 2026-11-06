// Unit 6: payload parser (spec Section 1.5 and G4).
//
// Corrected data bytes come in through putByte (block 0 first); characters come out through getByte.
//   start(ver)   select the count widths (Table 4) and clear all state
//   putByte(b)   next data byte.  Ready while fewer than 17 bits are buffered.  After the message has
//                ended (terminator, or failure) bytes are accepted and thrown away, so the producer never stalls.
//   endOfData()  all data bytes of all blocks have been fed (after the last putByte)
//   getByte()    next character; `last` only on the final one (needs a one-character holdback)
//   failed()     malformed payload
//   done()       every character was taken (an empty message gives done at once)
//
// Structure: a bit accumulator (right-aligned, nbits valid bits, oldest bit highest), a state machine that
// takes 4 / count-width / group-width bits at a time, a staging vector for the (up to 3) characters of one
// group, the one-character holdback `held`, and the output slot `outD/outL/outV`.
// Methods only raise wires; the single rule `step` owns every register.
package QRPayload;

import Vector :: *;
import QRTypes :: *;

interface QRPayload;
   method Action start(UInt#(6) ver);
   method Action putByte(Bit#(8) b);
   method Action endOfData();
   method ActionValue#(OutByte) getByte();
   method Bool failed();
   method Bool done();
endinterface

typedef enum { SIdle, SMode, SCount, SNum, SAln, SByt, SEmit, SFlush, SDone, SFail } PSt
   deriving (Bits, Eq, FShow);
typedef enum { KNum, KAln, KByt } Kind deriving (Bits, Eq, FShow);

// Count field width (Table 4); cls 0 = versions 1-9, 1 = 10-26, 2 = 27-40.
function UInt#(5) countWidth(Kind k, UInt#(2) cls);
   UInt#(5) w = 8;
   case (k)
      KNum: w = (cls == 0) ? 10 : ((cls == 1) ? 12 : 14);
      KAln: w = (cls == 0) ? 9  : ((cls == 1) ? 11 : 13);
      default: w = (cls == 0) ? 8 : 16;
   endcase
   return w;
endfunction

// ASCII code of alphanumeric value 0..44: 0-9, A-Z, space, $ % * + - . / :
function Bit#(8) alnumAscii(UInt#(6) v);
   Bit#(8) r = 0;
   Bit#(8) x = zeroExtend(pack(v));
   if (v < 10) r = 48 + x;
   else if (v < 36) r = 55 + x;
   else begin
      case (v)
         36: r = 32;
         37: r = 36;
         38: r = 37;
         39: r = 42;
         40: r = 43;
         41: r = 45;
         42: r = 46;
         43: r = 47;
         44: r = 58;
         default: r = 0;
      endcase
   end
   return r;
endfunction

function Bit#(8) digitAscii(UInt#(10) d);
   return 48 + zeroExtend(pack(d)[3:0]);
endfunction

// The w bits that end n bits into the accumulator's valid part, i.e. the next w bits of the stream.
function Bit#(16) takeBits(Bit#(24) a, UInt#(5) n, UInt#(5) w);
   Bit#(24) s = a >> (n - w);
   Bit#(16) m = ~(16'hFFFF << w);
   Bit#(16) t = truncate(s);
   return t & m;
endfunction

// State that follows a finished group (or a count field): next group, or next segment when none are left.
function PSt afterGroup(Kind k, UInt#(16) r);
   PSt s = SMode;
   if (r != 0) s = (k == KNum) ? SNum : ((k == KAln) ? SAln : SByt);
   return s;
endfunction

module mkQRPayload(QRPayload);
   Reg#(PSt)                st     <- mkReg(SIdle);
   Reg#(Kind)               kind   <- mkReg(KNum);
   Reg#(UInt#(2))           cls    <- mkReg(0);
   Reg#(Bit#(24))           acc    <- mkReg(0);
   Reg#(UInt#(5))           nbits  <- mkReg(0);
   Reg#(Bool)               ended  <- mkReg(False);
   Reg#(UInt#(16))          remCnt <- mkReg(0);    // characters of the current segment still to decode
   Reg#(Vector#(3, Bit#(8))) grp   <- mkReg(replicate(0));
   Reg#(UInt#(2))           gcnt   <- mkReg(0);
   Reg#(UInt#(2))           gidx   <- mkReg(0);
   Reg#(Bit#(8))            held   <- mkReg(0);    // holdback: decoded but not yet released
   Reg#(Bool)               heldV  <- mkReg(False);
   Reg#(Bit#(8))            outD   <- mkReg(0);    // output slot
   Reg#(Bool)               outL   <- mkReg(False);
   Reg#(Bool)               outV   <- mkReg(False);

   RWire#(UInt#(6)) startW <- mkRWire;
   RWire#(Bit#(8))  byteW  <- mkRWire;
   PulseWire        endW   <- mkPulseWire;
   PulseWire        takenW <- mkPulseWire;

   Bool discard = (st == SFlush || st == SDone || st == SFail || st == SIdle);

   (* fire_when_enabled, no_implicit_conditions *)
   rule step;
      PSt      nst   = st;
      Kind     nkind = kind;
      UInt#(2) ncls  = cls;
      Bit#(24) a     = acc;
      UInt#(5) n     = nbits;
      Bool     nended = ended;
      UInt#(16) nrem = remCnt;
      Vector#(3, Bit#(8)) ngrp = grp;
      UInt#(2) ngcnt = gcnt;
      UInt#(2) ngidx = gidx;
      Bit#(8)  nheld = held;
      Bool     nheldV = heldV;
      Bit#(8)  noutD = outD;
      Bool     noutL = outL;
      Bool     noutV = outV;

      if (takenW) noutV = False;

      case (st)
         SMode: begin
            if (nbits >= 4) begin
               Bit#(16) f = takeBits(acc, nbits, 4);
               n = nbits - 4;
               case (f[3:0])
                  4'b0000: nst = SFlush;                       // terminator
                  4'b0001: begin nkind = KNum; nst = SCount; end
                  4'b0010: begin nkind = KAln; nst = SCount; end
                  4'b0100: begin nkind = KByt; nst = SCount; end
                  default: nst = SFail;                        // unknown mode indicator
               endcase
            end
            else if (ended) nst = SFlush;                      // fewer than 4 bits left: message over
         end

         SCount: begin
            UInt#(5) w = countWidth(kind, cls);
            if (nbits >= w) begin
               Bit#(16) f = takeBits(acc, nbits, w);
               n = nbits - w;
               nrem = unpack(f);
               nst = afterGroup(kind, unpack(f));
            end
            else if (ended) nst = SFail;                       // header runs past the end
         end

         SNum: begin
            UInt#(2) k = (remCnt >= 3) ? 3 : truncate(remCnt);
            UInt#(5) w = (k == 3) ? 10 : ((k == 2) ? 7 : 4);
            if (nbits >= w) begin
               Bit#(16) f = takeBits(acc, nbits, w);
               UInt#(10) v = unpack(truncate(f));
               UInt#(10) lim = (k == 3) ? 999 : ((k == 2) ? 99 : 9);
               n = nbits - w;
               if (v > lim) nst = SFail;                       // group out of range
               else begin
                  UInt#(10) hq = v / 100;
                  UInt#(10) tq = (v % 100) / 10;
                  UInt#(10) uq = v % 10;
                  Vector#(3, Bit#(8)) gv = replicate(0);
                  if (k == 3) begin gv[0] = digitAscii(hq); gv[1] = digitAscii(tq); gv[2] = digitAscii(uq); end
                  else if (k == 2) begin gv[0] = digitAscii(tq); gv[1] = digitAscii(uq); end
                  else gv[0] = digitAscii(uq);
                  ngrp = gv; ngcnt = k; ngidx = 0;
                  nrem = remCnt - zeroExtend(k);
                  nst = SEmit;
               end
            end
            else if (ended) nst = SFail;                       // group runs past the end
         end

         SAln: begin
            Bool two = (remCnt >= 2);
            UInt#(5) w = two ? 11 : 6;
            if (nbits >= w) begin
               Bit#(16) f = takeBits(acc, nbits, w);
               UInt#(11) v = unpack(truncate(f));
               Bool bad = two ? (v > 2024) : (v > 44);
               n = nbits - w;
               if (bad) nst = SFail;                           // pair / single out of range
               else begin
                  UInt#(11) q = v / 45;
                  UInt#(11) r = v % 45;
                  Vector#(3, Bit#(8)) gv = replicate(0);
                  if (two) begin
                     gv[0] = alnumAscii(truncate(q)); gv[1] = alnumAscii(truncate(r));
                     ngcnt = 2; nrem = remCnt - 2;
                  end
                  else begin
                     gv[0] = alnumAscii(truncate(v));
                     ngcnt = 1; nrem = remCnt - 1;
                  end
                  ngrp = gv; ngidx = 0;
                  nst = SEmit;
               end
            end
            else if (ended) nst = SFail;
         end

         SByt: begin
            if (nbits >= 8) begin
               Bit#(16) f = takeBits(acc, nbits, 8);
               Vector#(3, Bit#(8)) gv = replicate(0);
               gv[0] = f[7:0];
               n = nbits - 8;
               ngrp = gv; ngcnt = 1; ngidx = 0;
               nrem = remCnt - 1;
               nst = SEmit;
            end
            else if (ended) nst = SFail;
         end

         SEmit: begin
            if (gidx < gcnt) begin
               if (!heldV || !outV) begin
                  if (heldV) begin noutD = held; noutL = False; noutV = True; end
                  nheld = grp[gidx]; nheldV = True;
                  ngidx = gidx + 1;
                  if (gidx + 1 == gcnt) nst = afterGroup(kind, remCnt);
               end
            end
            else nst = afterGroup(kind, remCnt);
         end

         SFlush: begin
            if (heldV) begin
               if (!outV) begin
                  noutD = held; noutL = True; noutV = True;
                  nheldV = False; nst = SDone;
               end
            end
            else nst = SDone;
         end

         default: begin end
      endcase

      // append the byte offered by the producer (after this cycle's consumption)
      if (byteW.wget matches tagged Valid .b &&& !discard) begin
         a = (a << 8) | zeroExtend(b);
         n = n + 8;
      end

      if (startW.wget matches tagged Valid .v) begin
         nst = SMode;
         ncls = (v <= 9) ? 0 : ((v <= 26) ? 1 : 2);
         a = 0; n = 0; nended = False; nrem = 0;
         ngcnt = 0; ngidx = 0; nheldV = False; noutV = False;
      end
      else if (endW) nended = True;

      st <= nst; kind <= nkind; cls <= ncls; acc <= a; nbits <= n; ended <= nended;
      remCnt <= nrem; grp <= ngrp; gcnt <= ngcnt; gidx <= ngidx;
      held <= nheld; heldV <= nheldV; outD <= noutD; outL <= noutL; outV <= noutV;
   endrule

   method Action start(UInt#(6) ver);
      startW.wset(ver);
   endmethod

   method Action putByte(Bit#(8) b) if (discard || nbits <= 16);
      byteW.wset(b);
   endmethod

   method Action endOfData();
      endW.send;
   endmethod

   method ActionValue#(OutByte) getByte() if (outV && st != SFail);
      takenW.send;
      return OutByte { data: outD, last: outL };
   endmethod

   method Bool failed() = (st == SFail);
   method Bool done()   = (st == SDone && !outV && !heldV);
endmodule

endpackage
