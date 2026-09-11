import numpy as np
import time
import cv2

from pynq import Overlay, allocate

# ============================================================
# 1. LOAD FPGA BITSTREAM & HANDLERS
# ============================================================
print("Loading bitstream...")
overlay = Overlay("design_1_wrapper.bit")
dma = overlay.axi_dma_0
gpio = overlay.axi_gpio_0.channel1
print("FPGA bitstream loaded.")

def configure_accelerator(start=0, relu_en=0, kernel_sel=0, img_w=0, img_h=0,
                          wr_en=0, wr_bank=0, wr_row=0, wr_col=0, wr_data=0):
    config_val = 0
    config_val |= (start & 0x1)      << 0
    config_val |= (relu_en & 0x1)    << 1
    config_val |= (kernel_sel & 0x3) << 2
    config_val |= (img_w & 0x3F)     << 4
    config_val |= (img_h & 0x3F)     << 10
    config_val |= (wr_en & 0x1)      << 16
    config_val |= (wr_bank & 0x3)    << 17
    config_val |= (wr_row & 0x3)     << 19
    config_val |= (wr_col & 0x3)     << 21
    config_val |= (wr_data & 0xFF)   << 23
    gpio.write(config_val, 0xFFFFFFFF)

def load_kernel_to_hw(bank_id, kernel_matrix):
    for row in range(3):
        for col in range(3):
            weight_8bit = int(kernel_matrix[row][col]) & 0xFF
            configure_accelerator(wr_en=0, wr_bank=bank_id, wr_row=row, wr_col=col, wr_data=weight_8bit)
            configure_accelerator(wr_en=1, wr_bank=bank_id, wr_row=row, wr_col=col, wr_data=weight_8bit)
            configure_accelerator(wr_en=0, wr_bank=bank_id, wr_row=row, wr_col=col, wr_data=weight_8bit)

edge_kernel = np.array([[0, -1, 0], [-1, 5, -1], [0, -1, 0]], dtype=np.int32)
print("Loading kernel into FPGA...")
load_kernel_to_hw(0, edge_kernel)

# ============================================================
# 2. PREPARE IMAGE DATA
# ============================================================
IMAGE_WIDTH, IMAGE_HEIGHT = 32, 32
NUM_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT

img = cv2.imread("test.jpg", cv2.IMREAD_GRAYSCALE)
img_32 = cv2.resize(img, (IMAGE_WIDTH, IMAGE_HEIGHT), interpolation=cv2.INTER_AREA)
image_flat = img_32.astype(np.uint32).reshape(-1)

# ============================================================
# 3. ALLOCATE BUFFERS & TRIGGER HARDWARE
# ============================================================
in_buffer = allocate(shape=(NUM_PIXELS,), dtype=np.uint32)
out_buffer = allocate(shape=(NUM_PIXELS,), dtype=np.uint32)

in_buffer[:] = image_flat
out_buffer[:] = 0xFFFFFFFF # Magic Marker

# Configure hardware dimensions (Using N-1 logic)
configure_accelerator(start=0, relu_en=1, kernel_sel=0, img_w=IMAGE_WIDTH-1, img_h=IMAGE_HEIGHT-1)

dma.recvchannel.transfer(out_buffer)
dma.sendchannel.transfer(in_buffer)

print("Starting hardware processing...")
configure_accelerator(start=1, relu_en=1, kernel_sel=0, img_w=IMAGE_WIDTH-1, img_h=IMAGE_HEIGHT-1)

# Wait with a short 2-second timeout, ignoring the missing TLAST error
wait_start = time.time()
while not dma.recvchannel.idle:
    if (time.time() - wait_start) > 2.0:
        break

configure_accelerator(start=0)

# ============================================================
# 4. RENDER AND SAVE THE PHOTO
# ============================================================
# Count how many markers were overwritten
raw_words = np.array(out_buffer)
num_overwritten = NUM_PIXELS - int(np.sum(raw_words == 0xFFFFFFFF))

if num_overwritten == NUM_PIXELS:
    print("\n[+] 1024 Pixels processed successfully. Generating image...")
    
    # Read the output buffer as signed 32-bit integers
    fpga_output = out_buffer.view(np.int32).copy()
    
    # Reshape it into a 32x32 2D array
    fpga_image = fpga_output.reshape(IMAGE_HEIGHT, IMAGE_WIDTH).astype(np.float32)
    
    # Convolution outputs can be out of standard pixel ranges. 
    # Normalize the output so it maps perfectly from 0 to 255.
    max_value = fpga_image.max()
    if max_value > 0:
        fpga_image = (fpga_image / max_value) * 255.0
        
    # Clip any weird values and convert to standard 8-bit image format
    final_image = np.clip(fpga_image, 0, 255).astype(np.uint8)
    
    # Save the resulting image to the PYNQ SD card
    filename = "fpga_output_photo.jpg"
    cv2.imwrite(filename, final_image)
    print(f"[SUCCESS] Image saved as '{filename}' in your current directory!")

else:
    print(f"\n[!] Error: Only {num_overwritten} pixels were generated. Image not saved.")

in_buffer.close()
out_buffer.close()