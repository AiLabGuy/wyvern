#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Wyvern Contributors
# SPDX-License-Identifier: MIT

"""Derive the Graphite, Hermes, and Neon Dock icons from the existing master.

The master ``assets/icon/wyvern-icon-1024.png`` is not modified and stays the
default app icon (``scripts/make-icns.sh`` still builds ``AppIcon.icns`` from
``assets/icon``). This script only writes three 512 px alternates:

- ``Resources/IconVariants/wyvern-icon-graphite.png``
- ``Resources/IconVariants/wyvern-icon-hermes.png``
- ``Resources/IconVariants/wyvern-icon-neon.png``

No new mark is drawn. Every output pixel comes from the master's alpha and
luminance (and, for the eyes, its green). There is no clock and no randomness.

Run from the repo root:

    python3 scripts/make-icon-variants.py

Work is done at the master's 1024 px, then Pillow's Lanczos resizes to 512.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "assets" / "icon" / "wyvern-icon-1024.png"
OUT_DIR = ROOT / "Resources" / "IconVariants"
EDGE = 512

# Rec. 709 luma. The master separates cleanly: the rounded-square plate sits
# under luma 48, the wyvern mark sits at 48 and above, and the eyes are the
# only saturated green.
PLATE_LUMA = 48.0
MARK_LUMA_HI = 210.0

# Hermes stays in the deep-blue #0B2A6F family and the gold #E8B923 family.
HERMES_PLATE_DARK = np.array([6.0, 20.0, 51.0])  # #061433
HERMES_PLATE_LIGHT = np.array([20.0, 53.0, 122.0])  # #14357A
HERMES_GOLD_DARK = np.array([92.0, 67.0, 8.0])  # #5C4308
HERMES_GOLD = np.array([232.0, 185.0, 35.0])  # #E8B923
HERMES_GOLD_LIGHT = np.array([255.0, 236.0, 176.0])  # #FFECB0
HERMES_EYE = np.array([255.0, 214.0, 90.0])  # #FFD65A

# Neon: the same plate, darkened, with a cyan edge glow.
NEON_PLATE = np.array([8.0, 10.0, 16.0])
NEON_FILL = np.array([10.0, 26.0, 34.0])
NEON_GLOW = np.array([57.0, 243.0, 255.0])  # #39F3FF
NEON_CORE = np.array([226.0, 255.0, 255.0])
NEON_EYE = np.array([140.0, 255.0, 176.0])


def luma(rgb: np.ndarray) -> np.ndarray:
    channels = rgb.astype(np.float64)
    return 0.2126 * channels[..., 0] + 0.7152 * channels[..., 1] + 0.0722 * channels[..., 2]


def eye_mask(rgb: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    red = rgb[..., 0].astype(np.float64)
    green = rgb[..., 1].astype(np.float64)
    blue = rgb[..., 2].astype(np.float64)
    return (alpha > 200) & (green > red + 25.0) & (green > blue + 15.0) & (green > 50.0)


def box_blur(src: np.ndarray, radius: int) -> np.ndarray:
    """Separable-free box blur via a summed-area table. ``radius`` is in pixels."""
    if radius <= 0:
        return src
    padded = np.pad(src, radius, mode="edge")
    integral = np.zeros((padded.shape[0] + 1, padded.shape[1] + 1), dtype=np.float64)
    integral[1:, 1:] = np.cumsum(np.cumsum(padded, axis=0), axis=1)
    height, width = src.shape
    window = 2 * radius + 1
    rows = np.arange(height)[:, None]
    cols = np.arange(width)[None, :]
    total = (
        integral[rows + window, cols + window]
        - integral[rows, cols + window]
        - integral[rows + window, cols]
        + integral[rows, cols]
    )
    return total / float(window * window)


def gradient(values: np.ndarray) -> np.ndarray:
    horizontal = np.zeros_like(values)
    vertical = np.zeros_like(values)
    horizontal[:, 1:-1] = values[:, 2:] - values[:, :-2]
    vertical[1:-1, :] = values[2:, :] - values[:-2, :]
    return np.sqrt(horizontal * horizontal + vertical * vertical)


def compose(color: np.ndarray, alpha: np.ndarray) -> Image.Image:
    clipped = np.clip(np.rint(color), 0, 255).astype(np.uint8)
    out = np.dstack([clipped, alpha.astype(np.uint8)])
    return Image.fromarray(out, mode="RGBA")


def graphite(rgb: np.ndarray, alpha: np.ndarray, values: np.ndarray) -> Image.Image:
    """Monochrome graphite. Luma is cooled slightly so it is not pure silver."""
    color = np.stack([values * 0.90, values * 0.93, values * 0.98], axis=-1)
    return compose(color, alpha)


def hermes(rgb: np.ndarray, alpha: np.ndarray, values: np.ndarray, eyes: np.ndarray) -> Image.Image:
    """Deep-blue plate, gold mark. The midpoint of the mark ramp is #E8B923."""
    plate_t = np.clip(values / PLATE_LUMA, 0.0, 1.0)[..., None]
    plate = HERMES_PLATE_DARK + (HERMES_PLATE_LIGHT - HERMES_PLATE_DARK) * plate_t
    mark_t = np.clip((values - PLATE_LUMA) / (MARK_LUMA_HI - PLATE_LUMA), 0.0, 1.0)
    low = mark_t <= 0.55
    toward_mid = np.clip(mark_t / 0.55, 0.0, 1.0)[..., None]
    toward_light = np.clip((mark_t - 0.55) / 0.45, 0.0, 1.0)[..., None]
    dark_to_mid = HERMES_GOLD_DARK + (HERMES_GOLD - HERMES_GOLD_DARK) * toward_mid
    mid_to_light = HERMES_GOLD + (HERMES_GOLD_LIGHT - HERMES_GOLD) * toward_light
    mark = np.where(low[..., None], dark_to_mid, mid_to_light)
    color = np.where((values < PLATE_LUMA)[..., None], plate, mark)
    color = np.where(eyes[..., None], HERMES_EYE, color)
    return compose(color, alpha)


def neon(alpha: np.ndarray, values: np.ndarray, eyes: np.ndarray) -> Image.Image:
    """Dark plate and a glowing outline of the same mark. Edges are a fixed-scale gradient."""
    opaque = alpha > 16
    magnitude = gradient(values)
    edge = np.clip(magnitude / 180.0, 0.0, 1.0)
    glow = np.clip(box_blur(edge, 5) * 2.2, 0.0, 1.0)
    core = np.clip(edge * 1.35, 0.0, 1.0)
    color = np.zeros(values.shape + (3,), dtype=np.float64)
    color[opaque] = NEON_PLATE
    interior = opaque & (values >= PLATE_LUMA) & ~eyes
    color[interior] = NEON_FILL
    color += glow[..., None] * NEON_GLOW * 0.90
    color += core[..., None] * NEON_CORE * 0.65
    color = np.where(eyes[..., None], NEON_EYE, color)
    # Keep the master's silhouette. Glow stays inside the existing alpha.
    return compose(color, alpha)


def to_512(image: Image.Image) -> Image.Image:
    return image.resize((EDGE, EDGE), Image.Resampling.LANCZOS)


def write(image: Image.Image, name: str) -> None:
    path = OUT_DIR / name
    image.save(path, format="PNG", optimize=False, compress_level=9)
    print(f"wrote {path.relative_to(ROOT)} {image.size[0]}x{image.size[1]}")


def main() -> int:
    if not MASTER.is_file():
        print(f"missing master icon: {MASTER}", file=sys.stderr)
        return 1
    master = Image.open(MASTER).convert("RGBA")
    if master.size != (1024, 1024):
        print(f"expected a 1024 px master, got {master.size}", file=sys.stderr)
        return 1
    pixels = np.asarray(master)
    rgb = pixels[..., :3]
    alpha = pixels[..., 3]
    values = luma(rgb)
    # Transparent corners must not contribute a fake edge against the plate.
    values = np.where(alpha > 16, values, 0.0)
    eyes = eye_mask(rgb, alpha)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    write(to_512(graphite(rgb, alpha, values)), "wyvern-icon-graphite.png")
    write(to_512(hermes(rgb, alpha, values, eyes)), "wyvern-icon-hermes.png")
    write(to_512(neon(alpha, values, eyes)), "wyvern-icon-neon.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
