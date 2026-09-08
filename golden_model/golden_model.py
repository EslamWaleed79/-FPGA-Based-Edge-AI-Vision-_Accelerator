import argparse
import numpy as np


def saturate(val: int, width: int) -> int:
    """Saturate a signed Python int to a signed 'width'-bit range."""
    lo = -(1 << (width - 1))
    hi = (1 << (width - 1)) - 1
    if val > hi:
        return hi
    if val < lo:
        return lo
    return val


def conv2d_valid_int(img: np.ndarray, ker: np.ndarray) -> np.ndarray:
   
    H, W = img.shape
    N, _ = ker.shape
    outH, outW = H - N + 1, W - N + 1
    acc = np.zeros((outH, outW), dtype=np.int64)

    img64 = img.astype(np.int64)
    ker64 = ker.astype(np.int64)

    for oy in range(outH):
        for ox in range(outW):
            window = img64[oy:oy + N, ox:ox + N]
            acc[oy, ox] = int(np.sum(window * ker64))
    return acc


def conv2d_causal_same_int(img: np.ndarray, ker: np.ndarray) -> np.ndarray:
    
    H, W = img.shape
    N, _ = ker.shape
    img64 = img.astype(np.int64)
    ker64 = ker.astype(np.int64)

    padded = np.zeros((H + N - 1, W + N - 1), dtype=np.int64)
    padded[N - 1:, N - 1:] = img64  # zero-pad top and left only, not centered

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
            v = max(0, v)          # ReLU applied on the full-precision accumulator
        v = saturate(v, out_width)  # then saturate to hardware output width
        out[it.multi_index] = v
    return out


def max_abs_accumulator(n: int) -> int:
    """Worst-case |sum| for an NxN window: N*N taps, each |255 * -128| = 32640."""
    return n * n * 255 * 128


def required_bits_signed(max_abs_value: int) -> int:
    """Minimum signed bit-width to represent +-max_abs_value without saturation."""
    bits = 1  # sign bit
    while (1 << (bits - 1)) - 1 < max_abs_value:
        bits += 1
    return bits


def gen_image(h, w, rng):
    return rng.integers(0, 256, size=(h, w), dtype=np.int64)  # unsigned 8-bit: 0..255


def gen_kernel(n, rng):
    return rng.integers(-128, 128, size=(n, n), dtype=np.int64)  # signed 8-bit: -128..127


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--height', type=int, default=32)
    ap.add_argument('--width', type=int, default=32)
    ap.add_argument('--ksize', type=int, default=3)
    ap.add_argument('--out-width', type=int, default=16, help='hardware output bit width (signed)')
    ap.add_argument('--relu', type=int, default=0, choices=[0, 1])
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--outdir', type=str, default='.')
    ap.add_argument('--reuse-image', type=str, default=None,
                     help='Path to an existing input_image.txt to reuse (for multi-kernel-bank '
                          'tests: apply several different kernels to the SAME image).')
    ap.add_argument('--tag', type=str, default='',
                     help='Optional suffix inserted before .txt in output filenames, '
                          'e.g. --tag _bank1 -> kernel_bank1.txt, expected_output_bank1.txt')
    ap.add_argument('--mode', type=str, default='same', choices=['valid', 'same'],
                     help="'same' (default): causal top/left-zero-padded, output size = "
                          "input size, matches the CURRENT hardware. 'valid': legacy "
                          "no-padding mode, output shrinks to (H-N+1)x(W-N+1) -- only "
                          "use this if testing against an OLDER RTL build.")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)

    if args.reuse_image:
        flat = np.loadtxt(args.reuse_image, dtype=np.int64)
        img = flat.reshape(args.height, args.width)
    else:
        img = gen_image(args.height, args.width, rng)
    ker = gen_kernel(args.ksize, rng)

    if args.mode == 'same':
        raw_acc = conv2d_causal_same_int(img, ker)
    else:
        raw_acc = conv2d_valid_int(img, ker)

    out = apply_relu_and_saturate(raw_acc, args.out_width, bool(args.relu))

    # ---- bit-width justification (printed + used in report) ----
    worst_case = max_abs_accumulator(args.ksize)
    min_bits = required_bits_signed(worst_case)
    actual_max = int(np.max(np.abs(raw_acc)))
    saturations = int(np.sum((raw_acc > (2**(args.out_width-1) - 1)) |
                              (raw_acc < -(2**(args.out_width-1)))))

    print(f"[golden_model] N={args.ksize}  image={args.height}x{args.width}")
    print(f"[golden_model] Theoretical worst-case |accumulator| = {worst_case}")
    print(f"[golden_model] -> minimum bits needed to avoid ANY saturation = {min_bits} (signed)")
    print(f"[golden_model] Actual max |accumulator| for this random instance = {actual_max}")
    print(f"[golden_model] Output width used = {args.out_width}-bit signed "
          f"(range {-(2**(args.out_width-1))} .. {2**(args.out_width-1)-1})")
    print(f"[golden_model] Pixels that required saturation in this run = {saturations} "
          f"/ {raw_acc.size}")
    print(f"[golden_model] ReLU enabled = {bool(args.relu)}")

    # ---- write hardware-consumable files ----
    tag = args.tag
    np.savetxt(f"{args.outdir}/input_image.txt", img.flatten(), fmt='%d')
    np.savetxt(f"{args.outdir}/kernel{tag}.txt", ker.flatten(), fmt='%d')
    np.savetxt(f"{args.outdir}/expected_output{tag}.txt", out.flatten(), fmt='%d')
    with open(f"{args.outdir}/config{tag}.txt", 'w') as f:
        f.write(f"{args.height} {args.width} {args.ksize} {args.out_width} {int(bool(args.relu))}\n")

    print(f"[golden_model] Wrote input_image.txt, kernel{tag}.txt, expected_output{tag}.txt, "
          f"config{tag}.txt to '{args.outdir}'")


if __name__ == '__main__':
    main()
