// QRRS.bsv -- unit 5: Reed-Solomon correction of one block (spec Section 1.4).
//
// Baseline design: small and simple.  ONE general GF multiplier and ONE inverter are
// shared by every step (the operands are chosen by the state), everything else is
// one-byte-per-cycle constant multipliers.  Cycles are traded for area on purpose;
// a parallel version is a later synthesis experiment.
//
// For the block the buffer holds (data bytes then check bytes, first byte = highest power):
//   1. SYNDROMES   S_j = R(alpha^j), j < e.  Read the block once; every byte updates all
//                  syndromes at the same time (Horner: S_j = S_j*alpha^j + byte).
//                  All zero -> the block is clean, go to the output.
//   2. LOCATOR     Berlekamp-Massey turns S into the error locator Lambda(x), of degree L.
//                  L > e/2 means too many errors -> fail.
//   3. EVALUATOR   Omega(x) = S(x)*Lambda(x) mod x^e   (only L coefficients are needed).
//   4. CHIEN+FORNEY  For p = 0..m-1 test Lambda(alpha^-p) = 0.  Every root is an error in
//                  byte m-1-p of the block; its value is Omega(x)/Lambda_odd(x) at x = alpha^-p
//                  (Forney with first root alpha^0).  The fix is written back into the buffer.
//                  Not exactly L roots -> fail.
//   5. VERIFY      If anything was fixed, recompute the syndromes: they must now be all zero.
//   6. OUTPUT      Hand out the d data bytes of the block, in order, through getData().
//
// On failure nothing is output for this block.
package QRRS;

import Vector   :: *;
import QRTypes  :: *;
import QRGF     :: *;
import QRBlocks :: *;

typedef enum {
   Idle,
   Syn, SynChk,
   BmInit, BmDisc0, BmDiscLoop, BmDecide, BmCoef, BmUpd, BmInv, BmNext,
   OmInit, OmLoop,
   ChInit, ChEval, ChInv, ChVal, ChRd, ChWait, ChWr, ChStep, ChEnd,
   OutPrep, OutReq, OutGet,
   Done, Fail
} RSState deriving (Bits, Eq, FShow);

interface QRRS;
   // Correct the block `d` (from QRBlockBuf.curBlock) of a symbol with `ec` check bytes per block.
   method Action decodeBlock(UInt#(5) ec, BlockDesc d);
   // The corrected data bytes of the block, in order (implicit condition: one is ready).
   method ActionValue#(Bit#(8)) getData();
   method Bool done();     // all data bytes of the block have been taken
   method Bool failed();   // the block could not be corrected; no bytes were (or will be) output
endinterface

module mkQRRS#(QRBlockBuf#(cap) bb)(QRRS);
   Reg#(RSState)   st    <- mkReg(Idle);

   // the block
   Reg#(UInt#(5))  ecR   <- mkReg(0);
   Reg#(UInt#(12)) baseR <- mkReg(0);
   Reg#(UInt#(8))  mR    <- mkReg(0);        // block length: data + check
   Reg#(UInt#(7))  dR    <- mkReg(0);        // data bytes

   // working storage
   Vector#(32, Reg#(Bit#(8))) syn   <- replicateM(mkReg(0));   // syndromes S_0..S_29 (30, 31 unused)
   Vector#(16, Reg#(Bit#(8))) lam   <- replicateM(mkReg(0));   // Lambda; becomes the Chien registers
   Vector#(16, Reg#(Bit#(8))) bpoly <- replicateM(mkReg(0));   // Berlekamp-Massey's B(x)
   Vector#(16, Reg#(Bit#(8))) tpoly <- replicateM(mkReg(0));   // old Lambda while it is being updated
   Vector#(15, Reg#(Bit#(8))) om    <- replicateM(mkReg(0));   // Omega; becomes the Chien registers

   // Berlekamp-Massey, Omega and Chien state
   Reg#(UInt#(6))  cn     <- mkReg(0);        // n
   Reg#(UInt#(5))  cL     <- mkReg(0);        // L
   Reg#(UInt#(6))  cm     <- mkReg(1);        // m (shift of B)
   Reg#(UInt#(6))  ci     <- mkReg(0);        // inner loop index
   Reg#(UInt#(6))  ck     <- mkReg(0);        // Omega coefficient index
   Reg#(UInt#(8))  cp     <- mkReg(0);        // Chien position p
   Reg#(UInt#(5))  roots  <- mkReg(0);
   Reg#(UInt#(8))  reqIdx <- mkReg(0);        // read index (syndrome pass and output)
   Reg#(UInt#(12)) rdAddr <- mkReg(0);        // buffer address of the next read/write, kept in a register
                                              //   (= baseR + reqIdx in the syndrome and output passes, the
                                              //   byte under test in the Chien pass): no adder before the read decode
   Reg#(Bool)      pendRd <- mkReg(False);    // a read was issued last cycle
   Reg#(Bool)      verify <- mkReg(False);    // second syndrome pass, after the corrections
   Reg#(Bool)      swap   <- mkReg(False);
   Reg#(Bit#(8))   acc    <- mkReg(0);
   Reg#(Bit#(8))   dReg   <- mkReg(0);        // discrepancy
   Reg#(Bit#(8))   coef   <- mkReg(0);
   Reg#(Bit#(8))   binv   <- mkReg(1);        // 1/b
   Reg#(Bit#(8))   oddR   <- mkReg(0);
   Reg#(Bit#(8))   omR    <- mkReg(0);
   Reg#(Bit#(8))   invv   <- mkReg(0);
   Reg#(Bit#(8))   valR   <- mkReg(0);        // error value

   // output slot
   Reg#(Bool)      outValid <- mkReg(False);
   Reg#(Bit#(8))   outByte  <- mkReg(0);

   RWire#(Tuple2#(UInt#(5), BlockDesc)) startW <- mkRWire;
   PulseWire                            getW   <- mkPulseWire;

   // ---- the same values as plain vectors, for dynamic indexing -------------
   Vector#(32, Bit#(8)) synV = readVReg(syn);
   Vector#(16, Bit#(8)) lamV = readVReg(lam);
   Vector#(16, Bit#(8)) bV   = readVReg(bpoly);
   Vector#(16, Bit#(8)) tV   = readVReg(tpoly);
   Vector#(15, Bit#(8)) omV  = readVReg(om);

   UInt#(5) tLim = ecR >> 1;                  // errors that can be corrected
   UInt#(6) t6   = zeroExtend(tLim);

   // ---- the one shared multiplier ------------------------------------------
   UInt#(4) ci4 = truncate(ci);
   UInt#(5) syn_n_ci  = truncate(cn - ci);    // S[n-i]
   UInt#(5) syn_k_ci  = truncate(ck - ci);    // S[k-j]
   Bit#(8) opA = 0;
   Bit#(8) opB = 0;
   case (st)
      BmDiscLoop: begin opA = lamV[ci4];  opB = synV[syn_n_ci]; end   // Lambda_i * S_(n-i)
      BmCoef:     begin opA = dReg;       opB = binv;           end   // d / b
      BmUpd:      begin opA = coef;       opB = bV[ci4];        end   // (d/b) * B_j
      OmLoop:     begin opA = lamV[ci4];  opB = synV[syn_k_ci]; end   // Lambda_j * S_(k-j)
      ChVal:      begin opA = omR;        opB = invv;           end   // Omega / Lambda_odd
      default:    begin opA = 0;          opB = 0;              end
   endcase
   Bit#(8) prod = gfMul(opA, opB);

   // ---- the one shared inverter --------------------------------------------
   Bit#(8) invOut = gfInv((st == BmInv) ? dReg : oddR);

   // ---- Chien-search sums ---------------------------------------------------
   function Bit#(8) oddTerm(Integer k) = (k % 2 == 1) ? lamV[k] : 0;
   Vector#(16, Bit#(8)) oddTerms = genWith(oddTerm);
   Bit#(8) sumL = fold(\^ , lamV);            // Lambda(x)
   Bit#(8) oddL = fold(\^ , oddTerms);        // Lambda_odd(x) = x * Lambda'(x)
   Bit#(8) sumO = fold(\^ , omV);             // Omega(x)

   Bool allZero = (pack(readVReg(syn)) == 0);

   (* fire_when_enabled, no_implicit_conditions *)
   rule step;
      Bool fillOut = False;
      Bool clearOut = False;

      if (startW.wget matches tagged Valid {.ec, .d}) begin
         ecR <= ec;  baseR <= d.base;  mR <= d.len;  dR <= d.dataLen;
         for (Integer j = 0; j < 32; j = j + 1) syn[j] <= 0;
         reqIdx <= 0;  pendRd <= False;  verify <= False;  rdAddr <= d.base;
         clearOut = True;
         st <= Syn;
      end
      else begin
         case (st)
            // ------------------------------------------------------------ 1. syndromes
            Syn: begin
               Bool issue = (reqIdx < mR);
               if (issue) begin
                  bb.readReq(rdAddr);
                  reqIdx <= reqIdx + 1;
                  rdAddr <= rdAddr + 1;
               end
               pendRd <= issue;
               if (pendRd)                                  // the byte asked for last cycle
                  for (Integer j = 0; j < 30; j = j + 1)
                     syn[j] <= (fromInteger(j) < ecR) ? (gfMul(synV[j], alphaPow(j)) ^ bb.readData) : 0;
               if (!issue && !pendRd) st <= SynChk;
            end
            SynChk: begin
               if (verify) st <= allZero ? OutPrep : Fail;
               else        st <= allZero ? OutPrep : BmInit;
            end

            // ------------------------------------------------------------ 2. Berlekamp-Massey
            BmInit: begin
               for (Integer k = 0; k < 16; k = k + 1) begin
                  lam[k]   <= (k == 0) ? 1 : 0;
                  bpoly[k] <= (k == 0) ? 1 : 0;
               end
               for (Integer k = 0; k < 15; k = k + 1) om[k] <= 0;
               cL <= 0;  cm <= 1;  binv <= 1;  cn <= 0;
               st <= BmDisc0;
            end
            BmDisc0: begin                                   // d = S_n + sum_{i=1..L} Lambda_i S_(n-i)
               UInt#(5) cn5 = truncate(cn);
               acc <= synV[cn5];
               ci  <= 1;
               st  <= BmDiscLoop;
            end
            BmDiscLoop: begin
               UInt#(6) l6c = zeroExtend(cL);
               if (ci <= l6c) begin
                  acc <= acc ^ prod;
                  ci  <= ci + 1;
               end
               else begin
                  dReg <= acc;
                  st   <= BmDecide;
               end
            end
            BmDecide: begin
               UInt#(6) l6   = zeroExtend(cL);
               Bool doSwap   = (l6 + l6 <= cn);                              // 2L <= n
               UInt#(6) newL = cn + 1 - l6;
               if (dReg == 0) begin
                  cm <= cm + 1;
                  st <= BmNext;
               end
               else if (doSwap && newL > t6)                  // too many errors
                  st <= Fail;
               else begin
                  if (doSwap) for (Integer k = 0; k < 16; k = k + 1) tpoly[k] <= lamV[k];
                  swap <= doSwap;
                  st   <= BmCoef;
               end
            end
            BmCoef: begin
               coef <= prod;
               ci   <= 0;
               st   <= BmUpd;
            end
            BmUpd: begin                                     // Lambda_(j+m) += (d/b) * B_j
               UInt#(6) idx = ci + cm;
               if (idx <= 15) begin
                  UInt#(4) idx4 = truncate(idx);
                  lam[idx4] <= lamV[idx4] ^ prod;
                  ci <= ci + 1;
               end
               else if (swap) st <= BmInv;
               else begin
                  cm <= cm + 1;
                  st <= BmNext;
               end
            end
            BmInv: begin                                     // B = old Lambda, b = d, L = n+1-L, m = 1
               binv <= invOut;
               for (Integer k = 0; k < 16; k = k + 1) bpoly[k] <= tV[k];
               UInt#(6) l6b = zeroExtend(cL);
               cL <= truncate(cn + 1 - l6b);
               cm <= 1;
               st <= BmNext;
            end
            BmNext: begin
               UInt#(6) ec6 = zeroExtend(ecR);
               if (cn + 1 >= ec6) st <= OmInit;
               else begin
                  cn <= cn + 1;
                  st <= BmDisc0;
               end
            end

            // ------------------------------------------------------------ 3. Omega
            OmInit: begin
               ck <= 0;  ci <= 0;  acc <= 0;
               st <= (cL == 0) ? Fail : OmLoop;
            end
            OmLoop: begin                                    // Omega_k = sum_{j<=k} Lambda_j S_(k-j)
               if (ci <= ck) begin
                  acc <= acc ^ prod;
                  ci  <= ci + 1;
               end
               else begin
                  UInt#(4) ck4 = truncate(ck);
                  om[ck4] <= acc;
                  acc <= 0;  ci <= 0;  ck <= ck + 1;
                  UInt#(6) l6d = zeroExtend(cL);
                  if (ck + 1 == l6d) st <= ChInit;
               end
            end

            // ------------------------------------------------------------ 4. Chien + Forney
            ChInit: begin
               cp <= 0;  roots <= 0;
               st <= ChEval;
            end
            ChEval: begin
               if (sumL == 0) begin                          // alpha^-p is a root: byte m-1-p is wrong
                  roots <= roots + 1;
                  oddR  <= oddL;
                  omR   <= sumO;
                  st    <= (oddL == 0) ? Fail : ChInv;
               end
               else st <= ChStep;
            end
            ChInv: begin
               invv <= invOut;
               st   <= ChVal;
            end
            ChVal: begin
               valR <= prod;
               rdAddr <= baseR + zeroExtend(mR - 1 - cp);     // byte m-1-p; cp is stable until ChStep
               st   <= ChRd;
            end
            ChRd: begin
               if (valR == 0) st <= Fail;
               else begin
                  bb.readReq(rdAddr);
                  st <= ChWait;
               end
            end
            ChWait: st <= ChWr;
            ChWr: begin
               bb.writeByte(rdAddr, bb.readData ^ valR);
               st <= ChStep;
            end
            ChStep: begin                                    // x = alpha^-p  ->  alpha^-(p+1)
               for (Integer k = 0; k < 16; k = k + 1) lam[k] <= gfMul(lamV[k], alphaPowNeg(k));
               for (Integer k = 0; k < 15; k = k + 1) om[k]  <= gfMul(omV[k],  alphaPowNeg(k));
               if (cp + 1 == mR) st <= ChEnd;
               else begin
                  cp <= cp + 1;
                  st <= ChEval;
               end
            end
            ChEnd: begin
               if (roots != cL) st <= Fail;
               else begin                                    // 5. verify: syndromes of the fixed block
                  for (Integer j = 0; j < 32; j = j + 1) syn[j] <= 0;
                  reqIdx <= 0;  pendRd <= False;  verify <= True;  rdAddr <= baseR;
                  st <= Syn;
               end
            end

            // ------------------------------------------------------------ 6. output
            OutPrep: begin
               reqIdx <= 0;  rdAddr <= baseR;
               st <= OutReq;
            end
            OutReq: begin
               if (reqIdx == zeroExtend(dR)) begin
                  if (!outValid) st <= Done;
               end
               else if (!outValid) begin
                  bb.readReq(rdAddr);
                  reqIdx <= reqIdx + 1;
                  rdAddr <= rdAddr + 1;
                  st <= OutGet;
               end
            end
            OutGet: begin
               outByte <= bb.readData;
               fillOut = True;
               st <= OutReq;
            end
            default: noAction;                               // Idle, Done, Fail
         endcase
      end

      if (fillOut)   outValid <= True;
      else if (getW || clearOut) outValid <= False;
   endrule

   method Action decodeBlock(UInt#(5) ec, BlockDesc d) = startW.wset(tuple2(ec, d));

   method ActionValue#(Bit#(8)) getData() if (outValid);
      getW.send;
      return outByte;
   endmethod

   method Bool done   = (st == Done);
   method Bool failed = (st == Fail);
endmodule

endpackage
