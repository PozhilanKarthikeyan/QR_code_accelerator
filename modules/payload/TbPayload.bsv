// Test bench for QRPayload.  For every case in cfg.hex (version, length, offset into stream.hex) it plays the
// RS stage: start(ver), feed the stream bytes (with random gaps in 3 of 4 cases), endOfData, and meanwhile takes
// output characters (with random back-pressure in 3 of 4 cases).  It prints lines for check_payload.py:
//   B case data last       one character taken from getByte
//   R case S|F|T|X cycles  parser reached done (S), failed (F), timed out (T) or raised both (X)
// Build with  -D NCASES=<lines in cfg.hex>.
package TbPayload;

import RegFile  :: *;
import ConfigReg :: *;
import QRTypes  :: *;
import QRPayload :: *;

typedef enum { Cfg, Start, Run, Next, Fin } TbSt deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbPayload(Empty);
   Integer numCases = `NCASES;

   RegFile#(UInt#(18), Bit#(8))  stream <- mkRegFileFullLoad("stream.hex");
   RegFile#(UInt#(12), Bit#(56)) cfg    <- mkRegFileFullLoad("cfg.hex");

   QRPayload p <- mkQRPayload;

   Reg#(TbSt)      st      <- mkReg(Cfg);
   Reg#(UInt#(12)) ci      <- mkReg(0);
   Reg#(UInt#(6))  ver     <- mkReg(1);
   Reg#(UInt#(16)) len     <- mkReg(0);
   Reg#(UInt#(18)) off     <- mkReg(0);
   Reg#(UInt#(16)) cnt     <- mkConfigReg(0);      // ConfigReg: rFin may read it without an ordering conflict
   Reg#(Bool)      endSent <- mkConfigReg(False);
   Reg#(UInt#(32)) gcyc    <- mkReg(0);     // free-running cycle counter
   Reg#(UInt#(32)) t0      <- mkReg(0);     // gcyc when the current case started
   Reg#(Bit#(32))  lfsr    <- mkReg(32'hACE12345);

   UInt#(32) cyc = gcyc - t0;               // cycles since this case started
   Bool allFed  = (cnt == len && endSent);   // every byte of the stream was accepted by the parser
   Bool fast    = (pack(ci)[1:0] == 0);
   Bool gapFeed = fast || (lfsr[1:0] != 0);
   Bool gapGet  = fast || (lfsr[5:3] == 0);

   (* fire_when_enabled, no_implicit_conditions *)
   rule tick;
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      gcyc <= gcyc + 1;
   endrule

   rule rCfg (st == Cfg);
      if (ci == fromInteger(numCases)) st <= Fin;
      else begin
         Bit#(56) w = cfg.sub(ci);
         ver <= unpack(w[53:48]);
         len <= unpack(w[47:32]);
         off <= unpack(w[17:0]);
         st  <= Start;
      end
   endrule

   rule rStart (st == Start);
      p.start(ver);
      t0 <= gcyc;
      cnt <= 0;
      endSent <= False;
      st <= Run;
   endrule

   rule rFeed (st == Run && cnt < len && gapFeed);
      p.putByte(stream.sub(off + zeroExtend(cnt)));
      cnt <= cnt + 1;
   endrule

   rule rEnd (st == Run && cnt == len && !endSent);
      p.endOfData;
      endSent <= True;
   endrule

   rule rGet (st == Run && gapGet);
      let o <- p.getByte;
      $display("B %0d %0d %0d", ci, o.data, o.last ? 1 : 0);
   endrule

   rule rFin (st == Run && (p.failed || (p.done && allFed) || cyc > 200000));
      if (p.failed && p.done) $display("R %0d X %0d", ci, cyc);
      else if (p.failed)      $display("R %0d F %0d", ci, cyc);
      else if (p.done && allFed) $display("R %0d S %0d", ci, cyc);
      else                    $display("R %0d T %0d", ci, cyc);
      st <= Next;
   endrule

   rule rNext (st == Next);
      ci <= ci + 1;
      st <= Cfg;
   endrule

   rule rFinish (st == Fin);
      $display("END");
      $finish;
   endrule
endmodule

endpackage
