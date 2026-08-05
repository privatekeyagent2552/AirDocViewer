"""Reform Air Docs Viewer icon: full emblem visible, no white clipping."""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets" / "fadocx_source.png"
OUT = ROOT / "assets" / "fadocx.png"
HEADER_OUT = ROOT / "assets" / "fadocx_header_landscape_png.png"
SPLASH_OUT = ROOT / "assets" / "fadocx_splash_square.png"
BETA_OUT = ROOT / "assets" / "fadocx_beta.png"
SIZE = 1024

CREAM = (245, 240, 228)
GREEN_BG = (26, 78, 66)


def load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for path in (
        "C:/Windows/Fonts/arialbd.ttf",
        "C:/Windows/Fonts/ARIALBD.TTF",
        "C:/Windows/Fonts/segoeuib.ttf",
    ):
        if Path(path).exists():
            return ImageFont.truetype(path, size=size)
    return ImageFont.load_default()


def extract_green_emblem(src: Image.Image) -> Image.Image:
    """Crop only the green rounded icon (no outer white padding or text bar)."""
    px = np.array(src.convert("RGB"))
    h, w = px.shape[:2]
    r, g, b = px[:, :, 0], px[:, :, 1], px[:, :, 2]

    green = (g > 55) & (g > r + 8) & (g > b + 4) & (r < 130)
    white = (r > 210) & (g > 210) & (b > 210)

    # Icon body = green pixels that are not part of outer white margin.
    icon = green & ~white
    ys, xs = np.where(icon)
    if len(xs) == 0:
        return src

    left, top, right, bottom = xs.min(), ys.min(), xs.max(), ys.max()

    # Trim only solid-white rows from the bottom (old text banner).
    for y in range(bottom, top, -1):
        row = px[y, left:right]
        white_ratio = np.mean(
            (row[:, 0] > 230) & (row[:, 1] > 230) & (row[:, 2] > 230)
        )
        if white_ratio > 0.12:
            bottom = y - 1
        else:
            break

    pad = 2
    crop = src.crop((
        max(0, left - pad),
        max(0, top - pad),
        min(w, right + pad + 1),
        min(h, bottom + pad + 1),
    ))

    # Drop the inner white title strip baked into the old rounded icon.
    trim_h = int(crop.height * 0.72)
    return crop.crop((0, 0, crop.width, trim_h))


def compose_square_icon(emblem: Image.Image) -> Image.Image:
    canvas = Image.new("RGB", (SIZE, SIZE), GREEN_BG)

    top_zone_h = int(SIZE * 0.78)
    scale = min(SIZE * 0.92 / emblem.width, top_zone_h / emblem.height)
    tw = int(emblem.width * scale)
    th = int(emblem.height * scale)
    emblem_scaled = emblem.resize((tw, th), Image.Resampling.LANCZOS)

    x = (SIZE - tw) // 2
    y = int(SIZE * 0.05)
    canvas.paste(emblem_scaled, (x, y))

    draw = ImageDraw.Draw(canvas)
    band_top = int(SIZE * 0.84)
    draw.rectangle((0, band_top, SIZE, SIZE), fill=(18, 52, 36))

    font = load_font(72)
    text = "AIR DOCS VIEWER"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw_text = bbox[2] - bbox[0]
    th_text = bbox[3] - bbox[1]
    tx = (SIZE - tw_text) // 2
    ty = band_top + ((SIZE - band_top) - th_text) // 2 - 2
    draw.text((tx, ty), text, fill=CREAM, font=font)

    return canvas


def compose_header(emblem: Image.Image) -> Image.Image:
    w, h = 1024, 512
    canvas = Image.new("RGB", (w, h), GREEN_BG)

    emblem_h = int(h * 0.86)
    scale = emblem_h / emblem.height
    emblem_w = int(emblem.width * scale)
    emblem_scaled = emblem.resize((emblem_w, emblem_h), Image.Resampling.LANCZOS)
    canvas.paste(emblem_scaled, (24, (h - emblem_h) // 2))

    draw = ImageDraw.Draw(canvas)
    font = load_font(58)
    text = "Air Docs Viewer"
    bbox = draw.textbbox((0, 0), text, font=font)
    tx = 24 + emblem_w + 36
    ty = (h - (bbox[3] - bbox[1])) // 2
    draw.text((tx, ty), text, fill=CREAM, font=font)
    return canvas


def main() -> None:
    src = Image.open(SRC)
    emblem = extract_green_emblem(src)
    icon = compose_square_icon(emblem)
    header = compose_header(emblem)
    splash = icon.resize((512, 512), Image.Resampling.LANCZOS)

    icon.save(OUT, optimize=True)
    header.save(HEADER_OUT, optimize=True)
    splash.save(SPLASH_OUT, optimize=True)
    icon.save(BETA_OUT, optimize=True)
    print(f"emblem crop={emblem.size}")
    print(f"Saved {OUT}, {HEADER_OUT}, {SPLASH_OUT}")


if __name__ == "__main__":
    main()
