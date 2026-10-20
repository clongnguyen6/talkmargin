"""Clean the chosen app icon: refit the generated tile to the macOS grid (824 px at 100, continuous corners).

Usage: python3 app-icon.py generated-source.png tile-mask.png out.png
The art is scaled to the grid, then only the outer rim band is warped radially so the art's own
tile edge lands on the mask edge. Interior (bubble, lines) is untouched. Stray specks are dropped.
"""
import sys
import numpy as np
from PIL import Image, ImageCms

src_path, mask_path, out_path = sys.argv[1:4]
src = np.asarray(Image.open(src_path).convert('RGBA')).astype(np.float64) / 255
alpha = src[..., 3]
H, W = alpha.shape
SS = 2           # supersampling of the output grid
T0 = 0.85        # warp only beyond this fraction of the tile radius


def crossing(profile):
    i = np.where(profile >= 0.5)[0]
    a, b = i[0], i[-1]
    lo = a - 1 + (0.5 - profile[a - 1]) / (profile[a] - profile[a - 1])
    hi = b + (profile[b] - 0.5) / (profile[b] - profile[b + 1])
    return lo + 0.5, hi + 0.5  # pixel centers -> edge coordinates


band = slice(int(H * 0.35), int(H * 0.65))
left, right = crossing(alpha[band].mean(axis=0))
top, bottom = crossing(alpha[:, band].mean(axis=1))
print(f'source tile x {left:.2f}-{right:.2f} y {top:.2f}-{bottom:.2f}')


def to_src(u, v):
    # Output (1024 space, edge coordinates) -> source pixel-center coordinates.
    return (left + (u - 100) * (right - left) / 824 - 0.5,
            top + (v - 100) * (bottom - top) / 824 - 0.5)


def sample(img, x, y):
    # Bilinear sampling with edge clamping.
    x = np.clip(x, 0, img.shape[1] - 1.001); y = np.clip(y, 0, img.shape[0] - 1.001)
    x0 = x.astype(int); y0 = y.astype(int); fx = x - x0; fy = y - y0
    if img.ndim == 3:
        fx = fx[..., None]; fy = fy[..., None]
    return ((img[y0, x0] * (1 - fx) + img[y0, x0 + 1] * fx) * (1 - fy)
            + (img[y0 + 1, x0] * (1 - fx) + img[y0 + 1, x0 + 1] * fx) * fy)


# Plate: extend opaque tile colour a few px outward so edge samples never mix in transparent black.
rgb = src[..., :3].copy()
known = alpha >= 0.98
for _ in range(24):
    acc = np.zeros_like(rgb); cnt = np.zeros(alpha.shape)
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        k = np.roll(known, (dy, dx), axis=(0, 1))
        acc += np.roll(rgb, (dy, dx), axis=(0, 1)) * k[..., None]; cnt += k
    grow = ~known & (cnt > 0)
    rgb[grow] = acc[grow] / cnt[grow][:, None]; known |= grow

# Tile radius per angle, old (art outline after linear fit) and new (mask), in output space.
mask = np.asarray(Image.open(mask_path).convert('L')).astype(np.float64) / 255
C = 512.0
angles = np.linspace(-np.pi, np.pi, 4096, endpoint=False)
radii = np.arange(380, 600, 0.25)


def radius(fn):
    xs = C + np.cos(angles)[:, None] * radii; ys = C + np.sin(angles)[:, None] * radii
    a = fn(xs, ys)
    out = np.empty(len(angles))
    for j, row in enumerate(a):
        i = np.argmax(row < 0.5)
        out[j] = radii[i - 1] + 0.25 * (row[i - 1] - 0.5) / (row[i - 1] - row[i])
    return out


r_old = radius(lambda x, y: sample(alpha, *to_src(x, y)))
r_new = radius(lambda x, y: sample(mask, x - 0.5, y - 0.5))
k = r_old / r_new
print(f'outline ratio old/new: min {k.min():.4f} max {k.max():.4f}')

n = 1024 * SS
u = (np.arange(n) + 0.5) / SS
U, V = np.meshgrid(u, u)
dx, dy = U - C, V - C
d = np.hypot(dx, dy); th = np.arctan2(dy, dx)
idx = (th + np.pi) / (2 * np.pi) * len(angles)
i0 = idx.astype(int) % len(angles); i1 = (i0 + 1) % len(angles); f = idx - np.floor(idx)
kk = k[i0] * (1 - f) + k[i1] * f
rn = r_new[i0] * (1 - f) + r_new[i1] * f
t = np.clip((d / rn - T0) / (1 - T0), 0, 1)
s = 1 + (kk - 1) * t * t * (3 - 2 * t)
sx, sy = to_src(C + dx * s, C + dy * s)
hi = sample(rgb, sx, sy)
hi = Image.fromarray(np.clip(hi * 255 + 0.5, 0, 255).astype(np.uint8), 'RGB')
tile = np.asarray(hi.resize((1024, 1024), Image.Resampling.LANCZOS))

m8 = (mask * 255 + 0.5).astype(np.uint8)
out = np.dstack([tile, m8])
out[m8 == 0, :3] = 0
srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
Image.fromarray(out, 'RGBA').save(out_path, icc_profile=srgb, optimize=True)
print('wrote', out_path)
