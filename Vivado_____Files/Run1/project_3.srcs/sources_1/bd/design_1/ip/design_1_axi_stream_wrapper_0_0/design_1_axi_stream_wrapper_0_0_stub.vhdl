-- Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2018.2 (win64) Build 2258646 Thu Jun 14 20:03:12 MDT 2018
-- Date        : Thu Sep 10 00:18:07 2026
-- Host        : DESKTOP-1IDCUPR running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               C:/Users/compumarts/Desktop/project_3/project_3.srcs/sources_1/bd/design_1/ip/design_1_axi_stream_wrapper_0_0/design_1_axi_stream_wrapper_0_0_stub.vhdl
-- Design      : design_1_axi_stream_wrapper_0_0
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7z020clg400-1
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity design_1_axi_stream_wrapper_0_0 is
  Port ( 
    clk : in STD_LOGIC;
    rst_n : in STD_LOGIC;
    cfg_img_width : in STD_LOGIC_VECTOR ( 5 downto 0 );
    cfg_img_height : in STD_LOGIC_VECTOR ( 5 downto 0 );
    cfg_relu_en : in STD_LOGIC;
    cfg_kernel_wr_en : in STD_LOGIC;
    cfg_kernel_wr_bank : in STD_LOGIC_VECTOR ( 1 downto 0 );
    cfg_kernel_wr_row : in STD_LOGIC_VECTOR ( 1 downto 0 );
    cfg_kernel_wr_col : in STD_LOGIC_VECTOR ( 1 downto 0 );
    cfg_kernel_wr_data : in STD_LOGIC_VECTOR ( 7 downto 0 );
    cfg_kernel_sel : in STD_LOGIC_VECTOR ( 1 downto 0 );
    start : in STD_LOGIC;
    busy : out STD_LOGIC;
    done : out STD_LOGIC;
    s_axis_tvalid : in STD_LOGIC;
    s_axis_tready : out STD_LOGIC;
    s_axis_tdata : in STD_LOGIC_VECTOR ( 7 downto 0 );
    s_axis_tlast : in STD_LOGIC;
    m_axis_tvalid : out STD_LOGIC;
    m_axis_tready : in STD_LOGIC;
    m_axis_tdata : out STD_LOGIC_VECTOR ( 31 downto 0 );
    m_axis_tlast : out STD_LOGIC
  );

end design_1_axi_stream_wrapper_0_0;

architecture stub of design_1_axi_stream_wrapper_0_0 is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "clk,rst_n,cfg_img_width[5:0],cfg_img_height[5:0],cfg_relu_en,cfg_kernel_wr_en,cfg_kernel_wr_bank[1:0],cfg_kernel_wr_row[1:0],cfg_kernel_wr_col[1:0],cfg_kernel_wr_data[7:0],cfg_kernel_sel[1:0],start,busy,done,s_axis_tvalid,s_axis_tready,s_axis_tdata[7:0],s_axis_tlast,m_axis_tvalid,m_axis_tready,m_axis_tdata[31:0],m_axis_tlast";
attribute X_CORE_INFO : string;
attribute X_CORE_INFO of stub : architecture is "axi_stream_wrapper,Vivado 2018.2";
begin
end;
