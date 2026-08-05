"""Extract emblem + title text without the green rounded-square frame."""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets" / "air_docs_logo.png"
OUT_EMBLEM = ROOT / "assets" / "air_docs_emblem.png"
OUT_ICON = ROOT / "assets" / "fadocx.png"
OUT_SPLASH = ROOT / "assets" / "fadocx_splash_square.png"
OUT_BETA = ROOT / "assets" / "fadocx_beta.png"
SIZE = 1024
APP_BG = (13, 13, 13, 255)  # matches splash #0D0D0D
ICON_BG = (26, 78, 66, 255)


def is_green_bg(r: np.ndarray, g: np.ndarray, b: np.ndarray) -> np.ndarray:
    return (g > 42) & (g > r + 14) & (g > b + 10) & (r < 150)


def extract_emblem(src: Image.Image) -> Image.Image:
    rgba = np.array(src.convert("RGBA"))
    r, g, b, a = rgba[:, :, 0], rgba[:, :, 1], rgba[:, :, 2], rgba[:, :, 3]

    green = is_green_bg(r, g, b)
    rgba[green, 3] = 0

    # Drop fringe pixels with low alpha after green removal.
    img = Image.fromarray(rgba)
    img = img.filter(ImageFilter.MaxFilter(3))
    rgba = np.array(img)
    rgba[rgba[:, :, 3] < 20] = [0, 0, 0, 0]
    img = Image.fromarray(rgba)

    bbox = img.getbbox()
    if not bbox:
        return src
    return img.crop(bbox)


def compose_launcher(emblem: Image.Image, bg: tuple[int, int, int, int]) -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), bg)
    pad = int(SIZE * 0.04)
    max_w = SIZE - pad * 2
    max_h = SIZE - pad * 2
    scale = min(max_w / emblem.width, max_h / emblem.height)
    w = max(1, int(emblem.width * scale))
    h = max(1, int(emblem.height * scale))
    scaled = emblem.resize((w, h), Image.Resampling.LANCZOS)
    x = (SIZE - w) // 2
    y = (SIZE - h) // 2
    canvas.alpha_composite(scaled, (x, y))
    return canvas.convert("RGB")


def main() -> None:
    src = Image.open(SRC)
    emblem = extract_emblem(src)
    emblem.save(OUT_EMBLEM, optimize=True)

    compose_launcher(emblem, ICON_BG).save(OUT_ICON, optimize=True)
    compose_launcher(emblem, ICON_BG).save(OUT_BETA, optimize=True)
    compose_launcher(emblem, APP_BG).resize((512, 512), Image.Resampling.LANCZOS).save(
        OUT_SPLASH, optimize=True
    )
    print(f"emblem={emblem.size}")
    print(f"saved {OUT_EMBLEM}, {OUT_ICON}, {OUT_SPLASH}")


if __name__ == "__main__":
    main()
