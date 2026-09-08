import argparse
import numpy as np


def saturate(val: int, width: int) -> int:
    """Saturate a signed Python int to a signed 'width'-bit range."""
    lo = -(1 << (width - 1))
    hi = (1 << (width - 1)) - 1
    return max(lo, min(hi, val))


def to_hex_unsigned(val: int, width_bits: int) -> str:
    """Format an unsigned value as zero-padded hex, width_bits wide."""
    nhex = width_bits // 4
    return f"{val & ((1 << width_bits) - 1):0{nhex}X}"


def to_hex_twos_complement(val: int, width_bits: int) -> str:
    """Format a signed value in two's-complement hex, width_bits wide."""
    mask = (1 << width_bits) - 1
    return f"{val & mask:0{width_bits // 4}X}"


def conv2d_causal_same_int(img: np.ndarray, ker: np.ndarray) -> np.ndarray:
   
    H, W = img.shape
    N, _ = ker.shape
    img64 = img.astype(np.int64)
    ker64 = ker.astype(np.int64)
    padded = np.zeros((H + N - 1, W + N - 1), dtype=np.int64)
    padded[N - 1:, N - 1:] = img64
    acc = np.zeros((H, W), dtype=np.int64)
    for oy in range(H):
        for ox in range(W):
            window = padded[oy:oy + N, ox:ox + N]
            acc[oy, ox] = int(np.sum(window * ker64))
    return acc


def apply_relu_and_saturate(acc: np.ndarray, out_width: int, relu_en: bool) -> np.ndarray:
    out = np.zeros_like(acc)
    it = np.nditer(acc, flags=['multi_index'])
    for x in it:
        v = int(x)
        if relu_en:
            v = max(0, v)
        v = saturate(v, out_width)
        out[it.multi_index] = v
    return out


def gen_edge_test_image(h: int, w: int, bg: int = 20, fg: int = 200,
                         sq_frac: float = 0.5) -> np.ndarray:
   
    img = np.full((h, w), bg, dtype=np.int64)
    sq_h = int(h * sq_frac)
    sq_w = int(w * sq_frac)
    r0 = (h - sq_h) // 2
    c0 = (w - sq_w) // 2
    img[r0:r0 + sq_h, c0:c0 + sq_w] = fg
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--height', type=int, default=32)
    ap.add_argument('--width', type=int, default=32)
    ap.add_argument('--out-width', type=int, default=16)
    ap.add_argument('--relu', type=int, default=1, choices=[0, 1],
                     help='ReLU as post-processing bonus feature (spec item #7); '
                          'default ON for the edge-detection demo')
    ap.add_argument('--outdir', type=str, default='.')
    args = ap.parse_args()

    H, W, OUT_W = args.height, args.width, args.out_width
    N = 3
    relu_en = bool(args.relu)

    # ---- synthetic test image ----
    img = gen_edge_test_image(H, W)

    # ---- the two Sobel kernels (signed 8-bit, well within -128..127) ----
    sobel_x = np.array([[-1, 0, 1],
                         [-2, 0, 2],
                         [-1, 0, 1]], dtype=np.int64)
    sobel_y = np.array([[-1, -2, -1],
                         [0,  0,  0],
                         [1,  2,  1]], dtype=np.int64)

    # ---- run the RTL-equivalent pipeline for each kernel independently ----
    raw_x = conv2d_causal_same_int(img, sobel_x)
    raw_y = conv2d_causal_same_int(img, sobel_y)
    out_x = apply_relu_and_saturate(raw_x, OUT_W, relu_en)
    out_y = apply_relu_and_saturate(raw_y, OUT_W, relu_en)

    # ---- qualitative edge magnitude for the report (NOT an RTL check target) ----
    magnitude = np.sqrt(out_x.astype(np.float64) ** 2 + out_y.astype(np.float64) ** 2)
    magnitude_u16 = np.clip(np.round(magnitude), 0, 65535).astype(np.int64)

    print(f"[golden_model_sobel] image {H}x{W}, N={N}, OUT_W={OUT_W}, ReLU={relu_en}")
    print(f"[golden_model_sobel] output map {H}x{W} per kernel pass (SAME-padding: 1:1 with input)")
    print(f"[golden_model_sobel] Sobel X: min={out_x.min()} max={out_x.max()}")
    print(f"[golden_model_sobel] Sobel Y: min={out_y.min()} max={out_y.max()}")
    print(f"[golden_model_sobel] magnitude: min={magnitude_u16.min()} max={magnitude_u16.max()}")

    # ---- write hex vector files (2 hex digits = 8-bit, 4 hex digits = 16-bit) ----
    with open(f"{args.outdir}/image_sobel.txt", 'w') as f:
        for v in img.flatten():
            f.write(to_hex_unsigned(int(v), 8) + "\n")

    with open(f"{args.outdir}/kernel_sobel_x.txt", 'w') as f:
        for v in sobel_x.flatten():
            f.write(to_hex_twos_complement(int(v), 8) + "\n")

    with open(f"{args.outdir}/kernel_sobel_y.txt", 'w') as f:
        for v in sobel_y.flatten():
            f.write(to_hex_twos_complement(int(v), 8) + "\n")

    with open(f"{args.outdir}/expected_sobel_x_out.txt", 'w') as f:
        for v in out_x.flatten():
            f.write(to_hex_twos_complement(int(v), OUT_W) + "\n")

    with open(f"{args.outdir}/expected_sobel_y_out.txt", 'w') as f:
        for v in out_y.flatten():
            f.write(to_hex_twos_complement(int(v), OUT_W) + "\n")

    # decimal, report/visualization only -- never read by the testbench
    with open(f"{args.outdir}/edge_magnitude.txt", 'w') as f:
        for v in magnitude_u16.flatten():
            f.write(f"{int(v)}\n")

    with open(f"{args.outdir}/config_sobel.txt", 'w') as f:
        f.write(f"{H} {W} {N} {OUT_W} {int(relu_en)}\n")

    print(f"[golden_model_sobel] Wrote image_sobel.txt, kernel_sobel_x.txt, kernel_sobel_y.txt, "
          f"expected_sobel_x_out.txt, expected_sobel_y_out.txt, edge_magnitude.txt, "
          f"config_sobel.txt to '{args.outdir}'")


if __name__ == '__main__':
    main()
