import numpy as np
import matplotlib.pyplot as plt

# Load the flat text file and reshape it back to the 32x32 image grid
data = np.loadtxt('edge_magnitude.txt')
img = data.reshape((32, 32))

# Plot and save the corrected image for the report
plt.imshow(img, cmap='gray')
plt.title("Sobel Edge Magnitude (ReLU Disabled)")
plt.axis('off')
plt.savefig('sobel_corrected.png', bbox_inches='tight')
plt.show()