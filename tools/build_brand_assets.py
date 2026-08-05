"""Build crisp launcher + splash assets from the provided logo PNG."""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets" / "air_docs_logo_raw.png"
OUT_LAUNCHER = ROOT / "assets" / "air_docs_launcher.png"
OUT_SPLASH = ROOT / "assets" / "air_docs_logo_splash.png"
OUT_HOME = ROOT / "assets" / "air_docs_logo.png"
ICON_CANVAS = 1024
SPLASH_CANVAS = 2048
ICON_BG = (25, 79, 65)
SPLASH_BG = (13, 13, 13)


def _content_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    rgba = np.array(image.convert("RGBA"))
    r, g, b, a = rgba[:, :, 0], rgba[:, :, 1], rgba[:, :, 2], rgba[:, :, 3]
    visible = (a > 16) & ((r > 22) | (g > 22) | (b > 22))
    ys, xs = np.where(visible)
    if len(xs) == 0:
        return (0, 0, image.width, image.height)
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def _crop_logo(image: Image.Image) -> Image.Image:
    return image.crop(_content_bbox(image))


def _sharpen(image: Image.Image) -> Image.Image:
    return image.filter(ImageFilter.UnsharpMask(radius=1.2, percent=140, threshold=2))


def _upscale(source: Image.Image, max_dim: int) -> Image.Image:
    scale = max_dim / max(source.width, source.height)
    if scale <= 1:
        return _sharpen(source)
    upscaled = source.resize(
        (max(1, int(source.width * scale)), max(1, int(source.height * scale))),
        Image.Resampling.LANCZOS,
    )
    return _sharpen(upscaled)


def _fit_on_canvas(
    source: Image.Image,
    *,
    canvas: int,
    fill_ratio: float,
    background: tuple[int, int, int] | None,
    opaque: bool = False,
) -> Image.Image:
    bg = background if background is not None else (0, 0, 0)
    alpha = 255 if background is not None else 0
    sheet = Image.new("RGBA", (canvas, canvas), (*bg, alpha))
    max_w = int(canvas * fill_ratio)
    max_h = int(canvas * fill_ratio)
    scale = min(max_w / source.width, max_h / source.height)
    w = max(1, int(source.width * scale))
    h = max(1, int(source.height * scale))
    resized = source.resize((w, h), Image.Resampling.LANCZOS)
    x = (canvas - w) // 2
    y = (canvas - h) // 2
    sheet.alpha_composite(resized, (x, y))
    return sheet.convert("RGB") if opaque else sheet


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    logo = _upscale(_crop_logo(src), max_dim=1400)

    launcher = _fit_on_canvas(
        logo,
        canvas=ICON_CANVAS,
        fill_ratio=0.62,
        background=ICON_BG,
        opaque=True,
    )
    splash = _fit_on_canvas(
        logo,
        canvas=SPLASH_CANVAS,
        fill_ratio=0.68,
        background=SPLASH_BG,
    )
    home = _fit_on_canvas(
        logo,
        canvas=ICON_CANVAS,
        fill_ratio=0.92,
        background=None,
    )

    launcher.save(OUT_LAUNCHER)
    splash.save(OUT_SPLASH)
    home.save(OUT_HOME)

    print(f"source={SRC.name} {src.size} cropped={logo.size}")
    print(f"saved launcher={ICON_CANVAS}, splash={SPLASH_CANVAS}")


if __name__ == "__main__":
    main()
