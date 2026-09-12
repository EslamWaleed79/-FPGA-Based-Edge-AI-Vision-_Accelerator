# Safely ignore the asynchronous CDC paths between the PS clock and your accelerator clock
set_false_path -from [get_clocks clk_fpga_0] -to [get_clocks clk]