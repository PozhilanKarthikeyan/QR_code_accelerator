package QRDecoder;

import QRTypes  :: *;
import QRTables :: *;

(* synthesize *)
module mkQRDecoder (QRDecoder);

   // Read the symbol through mem, decode it, and return the message
   // through getByte.
   //
   // This placeholder compiles and runs, but gives up on every symbol at
   // once (the example test bench reports that failed rose).  Replace it
   // with your design.
   // bsc warns that getByte and mem_req are never ready; for the
   // placeholder that is expected.

   Reg#(Bool) gaveUp <- mkReg(False);

   method Action start(Coord size);
      gaveUp <= True;
   endmethod

   method ActionValue#(OutByte) getByte() if (False);
      return OutByte { data: 0, last: True };
   endmethod

   method Bool failed = gaveUp;
   method Bool done   = False;

   interface MemPort mem;
      method ActionValue#(Tuple2#(Coord, Coord)) req() if (False);
         return tuple2(0, 0);
      endmethod
      method Action resp(Bit#(1) b);
      endmethod
   endinterface

endmodule

endpackage
