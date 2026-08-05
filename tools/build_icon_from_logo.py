"""Build square launcher + splash assets from the provided logo PNG."""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets" / "air_docs_logo.png"
OUT_ICON = ROOT / "assets" / "fadocx.png"
OUT_SPLASH = ROOT / "assets" / "fadocx_splash_square.png"
OUT_BETA = ROOT / "assets" / "fadocx_beta.png"
SIZE = 1024
BG = (26, 78, 66, 255)


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    canvas = Image.new("RGBA", (SIZE, SIZE), BG)

    # Fit the full logo (with title) inside the square with safe padding.
    pad = int(SIZE * 0.06)
    max_w = SIZE - pad * 2
    max_h = SIZE - pad * 2
    scale = min(max_w / src.width, max_h / src.height)
    w = int(src.width * scale)
    h = int(src.height * scale)
    logo = src.resize((w, h), Image.Resampling.LANCZOS)

    x = (SIZE - w) // 2
    y = (SIZE - h) // 2
    canvas.alpha_composite(logo, (x, y))

    rgb = canvas.convert("RGB")
    rgb.save(OUT_ICON, optimize=True)
    rgb.save(OUT_BETA, optimize=True)
    rgb.resize((512, 512), Image.Resampling.LANCZOS).save(OUT_SPLASH, optimize=True)
    print(f"Saved {OUT_ICON} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
