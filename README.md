# FPGA-Based Edge-AI Vision Accelerator

**Ultra-Low Power, Zero-DSP, Zero-BRAM Spatial Convolution Engine**  
**Authors:** Eslam Waleed | Ain Shams University  
**Target Hardware:** Xilinx Zynq-7000 SoC (PYNQ-Z2)

![Project Board Demo](link-to-your-gif-or-image-here.gif) *(Add a 15-second GIF of the board working here!)*

## 📌 Project Overview
This repository contains the RTL, verification models, and implementation scripts for a high-performance, ultra-low-power Edge-AI hardware accelerator. Designed specifically for spatial filtering (e.g., multi-kernel Sobel edge detection) in resource-constrained environments, this architecture deliberately avoids the use of dedicated DSP slices and Block RAM to maximize resource efficiency and minimize dynamic power.

## 🚀 Key Performance Metrics
Post-route implementation results confirm the following metrics:

* **Maximum Frequency ($F_{max}$):** 101.46 MHz *(Tested with +5.144 ns WNS at 15.0 ns constraint)*
* **Dynamic Power:** 125 mW *(at 66.67 MHz operating frequency)*
* **Throughput:** 1.0 pixels/cycle *(Continuous streaming after pipeline fill)*
* **Initial Latency:** 4 clock cycles *(Same-padding architecture eliminates standard row-fill delays)*
* **Resource Utilization:** 1,231 LUTs | 0 DSPs | 0 BRAMs
* **Verification Mismatches:** 0 *(100% bit-accurate against Python NumPy golden model)*

## 🧠 Architectural Highlights

### 1. Zero-DSP MAC Array
To avoid the high power consumption and resource penalties associated with dedicated DSP48 slices, the entire Multiply-Accumulate (MAC) array is synthesized entirely from standard logic fabric (LUTs).

### 2. Same-Padding Line Buffers
Unlike standard valid convolutions that require waiting for $N-1$ rows to buffer before outputting valid data, our custom line buffer logic uses edge-aware same-padding. This drops our initial latency down to just **4 clock cycles** (1 cycle input register + 3 cycles MAC pipeline), allowing the accelerator to immediately stream valid feature maps.

### 3. Software-Hardware Co-Design
Verification was automated using a Python-based testing pipeline. Python generates random input images, computes the golden expected outputs using NumPy, and passes the test vectors to the SystemVerilog testbench. The RTL is cross-checked cycle-by-cycle against the software model.

## 📂 Repository Structure
* `/rtl` - SystemVerilog source files (Line Buffers, MAC Array, Control FSM)
* `/tb` - SystemVerilog testbenches and simulation vectors
* `/models` - Python golden models and test vector generators
* `/docs` - Final PDF technical report and block diagrams
* `build.tcl` - Automated Vivado build script

## 🛠️ How to Build and Reproduce
To recreate the project locally and verify our implementation metrics, run the provided Tcl script in Vivado:
1. Open the Vivado Tcl Console.
2. Navigate to this repository's root directory.
3. Run the following command:
   `source build.tcl`
*(This script will automatically create the project, import the RTL, apply constraints, and run Synthesis and Implementation).*
