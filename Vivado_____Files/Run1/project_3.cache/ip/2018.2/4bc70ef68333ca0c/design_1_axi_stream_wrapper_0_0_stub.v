// Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2018.2 (win64) Build 2258646 Thu Jun 14 20:03:12 MDT 2018
// Date        : Thu Sep 10 00:18:06 2026
// Host        : DESKTOP-1IDCUPR running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub -rename_top decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix -prefix
//               decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix_ design_1_axi_stream_wrapper_0_0_stub.v
// Design      : design_1_axi_stream_wrapper_0_0
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7z020clg400-1
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* X_CORE_INFO = "axi_stream_wrapper,Vivado 2018.2" *)
module decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix(clk, rst_n, cfg_img_width, cfg_img_height, 
  cfg_relu_en, cfg_kernel_wr_en, cfg_kernel_wr_bank, cfg_kernel_wr_row, cfg_kernel_wr_col, 
  cfg_kernel_wr_data, cfg_kernel_sel, start, busy, done, s_axis_tvalid, s_axis_tready, 
  s_axis_tdata, s_axis_tlast, m_axis_tvalid, m_axis_tready, m_axis_tdata, m_axis_tlast)
/* synthesis syn_black_box black_box_pad_pin="clk,rst_n,cfg_img_width[5:0],cfg_img_height[5:0],cfg_relu_en,cfg_kernel_wr_en,cfg_kernel_wr_bank[1:0],cfg_kernel_wr_row[1:0],cfg_kernel_wr_col[1:0],cfg_kernel_wr_data[7:0],cfg_kernel_sel[1:0],start,busy,done,s_axis_tvalid,s_axis_tready,s_axis_tdata[7:0],s_axis_tlast,m_axis_tvalid,m_axis_tready,m_axis_tdata[31:0],m_axis_tlast" */;
  input clk;
  input rst_n;
  input [5:0]cfg_img_width;
  input [5:0]cfg_img_height;
  input cfg_relu_en;
  input cfg_kernel_wr_en;
  input [1:0]cfg_kernel_wr_bank;
  input [1:0]cfg_kernel_wr_row;
  input [1:0]cfg_kernel_wr_col;
  input [7:0]cfg_kernel_wr_data;
  input [1:0]cfg_kernel_sel;
  input start;
  output busy;
  output done;
  input s_axis_tvalid;
  output s_axis_tready;
  input [7:0]s_axis_tdata;
  input s_axis_tlast;
  output m_axis_tvalid;
  input m_axis_tready;
  output [31:0]m_axis_tdata;
  output m_axis_tlast;
endmodule
