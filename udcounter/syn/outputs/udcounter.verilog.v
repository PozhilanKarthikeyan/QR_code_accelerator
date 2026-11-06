/////////////////////////////////////////////////////////////
// Created by: Synopsys DC Ultra(TM) in wire load mode
// Version   : U-2022.12
// Date      : Tue Sep  8 14:31:39 2026
/////////////////////////////////////////////////////////////


module udcounter ( Clk, reset, UpOrDown, Count );
  output [3:0] Count;
  input Clk, reset, UpOrDown;
  wire   N20, N22, N23, n1, n10, n11, n12, n13, n14, n15, n16, n17, n18, n19,
         n20;

  SAEDRVT14_FDPRBQ_V2LP_1 Count_reg_3_ ( .D(N23), .CK(Clk), .RD(n1), .Q(
        Count[3]) );
  SAEDRVT14_FDPRBQ_V2_1 Count_reg_1_ ( .D(n20), .CK(Clk), .RD(n1), .Q(Count[1]) );
  SAEDRVT14_FDPRBQ_V2LP_1 Count_reg_2_ ( .D(N22), .CK(Clk), .RD(n1), .Q(
        Count[2]) );
  SAEDRVT14_FDPRBQ_V2_1 Count_reg_0_ ( .D(N20), .CK(Clk), .RD(n1), .Q(Count[0]) );
  SAEDRVT14_INV_6 U15 ( .A(n13), .X(n17) );
  SAEDRVT14_MUXI2_U_0P5 U16 ( .D0(n20), .D1(n13), .S(n12), .X(N22) );
  SAEDRVT14_INV_S_1 U17 ( .A(n16), .X(n11) );
  SAEDRVT14_INV_S_1 U18 ( .A(Count[0]), .X(N20) );
  SAEDRVT14_ND2_MM_2 U19 ( .A1(n19), .A2(Count[3]), .X(n18) );
  SAEDRVT14_INV_0P75 U20 ( .A(n17), .X(n10) );
  SAEDRVT14_OAI22_1P5 U21 ( .A1(Count[2]), .A2(n16), .B1(n14), .B2(n17), .X(
        n15) );
  SAEDRVT14_INV_S_1 U22 ( .A(Count[2]), .X(n14) );
  SAEDRVT14_INV_S_2 U23 ( .A(n10), .X(n20) );
  SAEDRVT14_ADDF_V1_2 U24 ( .A(UpOrDown), .B(Count[1]), .CI(Count[0]), .CO(n16), .S(n13) );
  SAEDRVT14_OAI22_1 U25 ( .A1(n16), .A2(Count[2]), .B1(n11), .B2(n14), .X(n12)
         );
  SAEDRVT14_INV_S_0P5 U26 ( .A(reset), .X(n1) );
  SAEDRVT14_OAI21_3 U27 ( .A1(n17), .A2(n16), .B(n15), .X(n19) );
  SAEDRVT14_OAI21_0P5 U28 ( .A1(Count[3]), .A2(n19), .B(n18), .X(N23) );
endmodule

