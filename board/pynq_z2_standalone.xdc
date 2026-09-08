## =============================================================================
## pynq_z2_standalone.xdc
## -----------------------------------------------------------------------------
## Constraints for a MINIMAL standalone bring-up of top_conv_accelerator on the
## PYNQ-Z2 board (Zynq-7020, part xc7z020clg400-1), using onboard switches/
## buttons/LEDs for a smoke test BEFORE wiring into the full PS+DMA AXI-Stream
## design (axi_stream_wrapper.sv). This is intentionally a simple bring-up
## target: verify the core's clock closes timing and basic control signals
## toggle correctly on real silicon, decoupled from the DMA/PS integration.
##
## For the real board demo (streaming a full image via the ARM/PS side),
## don't use this constraints file -- instead instantiate axi_stream_wrapper
## inside a Vivado IP Integrator block design alongside the Zynq PS7 IP and
## an AXI-DMA IP; the PS7 IP's own auto-generated constraints handle the
## PS-side pins, and this accelerator only needs its clock/reset sourced
## from the PS7's FCLK_CLK0 and peripheral reset outputs (no separate XDC
## pin constraints needed for the PL side in that flow, since AXI-Stream
## connects entirely on-chip between PS and PL).
##
## PYNQ-Z2 reference: Digilent/TUL PYNQ-Z2 board, XC7Z020-1CLG400C.
## Pin assignments below match the standard PYNQ-Z2 board schematic.
## =============================================================================

## ---- 125 MHz system clock (from the Zynq PS if using PS7, OR the board's
## onboard 125 MHz oscillator if driving PL fabric standalone without PS7) ----
## NOTE: if instantiated under the Zynq PS7 (normal PYNQ flow), clk should
## come from FCLK_CLK0 (a PS-generated clock, NOT this external pin) and
## this constraint should be REMOVED. Keep it only for a pure-PL, no-PS7,
## standalone bring-up test using the board's external oscillator directly.
# set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk]
# create_clock -period 8.000 -name sys_clk [get_ports clk]
## (8.000 ns = 125 MHz; PYNQ-Z2's onboard oscillator is 125 MHz)

## ---- Recommended target clock for THIS accelerator (see report Table 1):
## start at 100 MHz for first-pass timing closure (10.000 ns period), only
## push toward 125+ MHz once you've confirmed the 3-stage MAC pipeline +
## line-buffer LUTRAM closes comfortably at 100 MHz with margin. ----
create_clock -period 10.000 -name accel_clk [get_ports clk]

## ---- Reset: active-low, tie to a pushbutton for standalone bring-up.
## PYNQ-Z2 BTN0 = pin D19 ----
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports rst_n_btn]
## NOTE: BTN0 is active-HIGH on PYNQ-Z2; invert in a top-level wrapper
## (rst_n <= ~rst_n_btn) since this core's rst_n port is active-low.

## ---- 'start' pulse: BTN1 (pin D20) ----
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} [get_ports start_btn]

## ---- Status LEDs (PYNQ-Z2: LD0=R14, LD1=P14, LD2=N16, LD3=M14) ----
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports led_busy]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports led_done]
## LD2/LD3 (N16/M14) available for future use, e.g. saturate/relu indicators.

## ---- Slide switches (SW0=M20, SW1=M19) -- e.g. cfg_relu_en, demo mode select ----
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports sw_relu_en]
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports sw_demo_mode]

## ---- Timing: false paths for slow, debounced switch/button inputs (not
## timing-critical, avoid unnecessarily constraining async board I/O) ----
set_false_path -from [get_ports {rst_n_btn start_btn sw_relu_en sw_demo_mode}]

## ---- Input pixel stream / output pixel stream: NOT exposed as raw pins in
## either bring-up flow (32x32 image can't reasonably be hand-fed via
## switches). For a true standalone demo without a PS/DMA, add a small
## on-chip ROM (or BRAM preloaded via .mem file / Vivado's "Initialize BRAM
## Content from a file") holding one test image + kernel, driven by a
## simple free-running sequencer FSM feeding in_pixel/in_valid -- left as
## a documented next step (see checklist) since it's board-demo-specific
## glue logic, not part of the reusable accelerator core itself.
