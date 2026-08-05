"""Logo assets — home uses original; icon uses circle-safe crop; splash matches home layout."""

from __future__ import annotations



import math

import subprocess

import sys

from pathlib import Path



import numpy as np

from PIL import Image, ImageDraw



ROOT = Path(r"C:/Users/hashi/AndroidStudioProjects/AirDocsViewer")

ASSETS = ROOT / "assets"

RES = ROOT / "android/app/src/main/res"

SRC = ASSETS / "_logo_raw.png"

SIZE = 1024

# Portrait canvas — home logo ~70% width, top-aligned (matches home_screen.dart).

SPLASH_W = 1080

SPLASH_H = 2400





def sample_edge_green(rgb: np.ndarray) -> tuple[int, int, int]:

    h, w = rgb.shape[:2]

    pts = [rgb[0, 0], rgb[0, w - 1], rgb[h - 1, 0], rgb[h - 1, w - 1]]

    return tuple(int(v) for v in np.mean(pts, axis=0))





def logo_content_crop(img: Image.Image, pad: int = 12) -> Image.Image:

    """Crop to silver emblem + AirDoc Viewer text — drop outer green only."""

    rgb = np.array(img.convert("RGB"))

    h, w = rgb.shape[:2]

    r = rgb[:, :, 0].astype(np.int16)

    g = rgb[:, :, 1].astype(np.int16)

    b = rgb[:, :, 2].astype(np.int16)

    lum = rgb.mean(axis=2)

    sat = np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b)

    silver = (lum > 82) & (sat < 72)

    rows = np.any(silver, axis=1)

    cols = np.any(silver, axis=0)

    r0, r1 = int(np.where(rows)[0][0]), int(np.where(rows)[0][-1])

    c0, c1 = int(np.where(cols)[0][0]), int(np.where(cols)[0][-1])

    r0, c0 = max(0, r0 - pad), max(0, c0 - pad)

    r1, c1 = min(h - 1, r1 + pad), min(w - 1, c1 + pad)

    return Image.fromarray(rgb[r0 : r1 + 1, c0 : c1 + 1])





def flatten_green(img: Image.Image, bg: tuple[int, int, int]) -> Image.Image:

    arr = np.array(img.convert("RGB"))

    r = arr[:, :, 0].astype(np.int16)

    g = arr[:, :, 1].astype(np.int16)

    b = arr[:, :, 2].astype(np.int16)

    lum = arr.mean(axis=2)

    sat = np.maximum(np.maximum(r, g), b) - np.minimum(np.minimum(r, g), b)

    silver = (lum > 82) & (sat < 72)

    green_bg = (g > r + 2) & (lum < 140) & ~silver

    arr[green_bg] = bg

    return Image.fromarray(arr)





def fit_square(img: Image.Image, side: int, content_frac: float, bg: tuple[int, int, int]) -> Image.Image:

    canvas = Image.new("RGB", (side, side), bg)

    w, h = img.size

    max_side = int(side * content_frac)

    scale = min(max_side / w, max_side / h)

    nw, nh = max(1, int(w * scale)), max(1, int(h * scale))

    resized = img.resize((nw, nh), Image.Resampling.LANCZOS)

    ox, oy = (side - nw) // 2, (side - nh) // 2

    canvas.paste(resized, (ox, oy))

    return canvas





def round_corners(img: Image.Image, radius: int, bg: tuple[int, int, int]) -> Image.Image:

    """Match home ClipRRect(borderRadius: 16)."""

    img = img.convert("RGBA")

    w, h = img.size

    mask = Image.new("L", (w, h), 0)

    draw = ImageDraw.Draw(mask)

    draw.rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=255)

    out = Image.new("RGBA", (w, h), bg + (255,))

    out.paste(img, (0, 0), mask)

    return out.convert("RGB")





def make_home_style_splash(

    original: Image.Image,

    bg: tuple[int, int, int],

    *,

    screen_w: int = SPLASH_W,

    screen_h: int = SPLASH_H,

) -> Image.Image:

    """Same as home_screen _buildHomeLogoHero: 70% width, top padding, radius 16dp."""

    canvas = Image.new("RGB", (screen_w, screen_h), bg)

    density = screen_w / 360.0  # logical width ~360dp on typical phone

    logo_w = int(min(max(screen_w * 0.70, 240.0 * density), 360.0 * density))

    aspect = original.height / original.width

    logo_h = int(logo_w * aspect)

    logo = original.resize((logo_w, logo_h), Image.Resampling.LANCZOS)

    radius = max(1, int(16 * density))

    # top: 4dp + status bar ~28dp ≈ 32dp (home uses top: 4 below app bar; splash ≈ below status bar)

    top_px = int(32 * density)

    logo = round_corners(logo, radius, bg)

    ox = (screen_w - logo_w) // 2

    canvas.paste(logo, (ox, top_px))

    return canvas





LAUNCH_BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>

<layer-list xmlns:android="http://schemas.android.com/apk/res/android">

    <item>

        <bitmap android:gravity="fill" android:src="@drawable/splash"/>

    </item>

</layer-list>

"""



LAUNCH_THEME_V31 = """<?xml version="1.0" encoding="utf-8"?>

<resources>

    <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">

        <item name="android:forceDarkAllowed">false</item>

        <item name="android:windowFullscreen">true</item>

        <item name="android:windowDrawsSystemBarBackgrounds">true</item>

        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>

        <item name="android:windowBackground">@drawable/launch_background</item>

    </style>

    <style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar">

        <item name="android:windowBackground">?android:colorBackground</item>

    </style>

</resources>

"""



LAUNCH_THEME_NIGHT_V31 = """<?xml version="1.0" encoding="utf-8"?>

<resources>

    <style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">

        <item name="android:forceDarkAllowed">false</item>

        <item name="android:windowFullscreen">true</item>

        <item name="android:windowDrawsSystemBarBackgrounds">true</item>

        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>

        <item name="android:windowBackground">@drawable/launch_background</item>

    </style>

    <style name="NormalTheme" parent="@android:style/Theme.Black.NoTitleBar">

        <item name="android:windowBackground">?android:colorBackground</item>

    </style>

</resources>

"""





def patch_splash_xml() -> None:

    """Use full-screen home-style splash on ALL Android versions (no A12 circle crop)."""

    for rel in ("drawable/launch_background.xml", "drawable-v21/launch_background.xml"):

        path = RES / rel

        path.parent.mkdir(parents=True, exist_ok=True)

        path.write_text(LAUNCH_BACKGROUND_XML, encoding="utf-8")

    (RES / "values-v31/styles.xml").write_text(LAUNCH_THEME_V31, encoding="utf-8")

    (RES / "values-night-v31/styles.xml").write_text(LAUNCH_THEME_NIGHT_V31, encoding="utf-8")

    print("patched launch_background + values-v31 (home-style splash, all APIs)")





def generate_assets() -> None:

    if not SRC.exists():

        raise FileNotFoundError(SRC)



    original = Image.open(SRC).convert("RGB")

    bg = sample_edge_green(np.array(original))

    hex_bg = f"#{bg[0]:02X}{bg[1]:02X}{bg[2]:02X}"

    content = flatten_green(logo_content_crop(original), bg)

    print(f"source={original.size} content={content.size} bg={hex_bg}")



    # Home — exact original (perfect).

    original.save(ASSETS / "air_docs_logo.png")

    original.save(ASSETS / "air_docs_logo_source.png")



    # App icon — circle-safe crop for launcher only.

    icon = fit_square(content, SIZE, 0.58, bg)

    icon.save(ASSETS / "air_docs_launcher.png")

    icon.save(ASSETS / "air_docs_adaptive_fg.png")

    icon.resize((512, 512), Image.Resampling.LANCZOS).save(ASSETS / "air_docs_emblem.png")



    # Splash — same image + layout as home_screen (70% width, top, rounded corners).

    splash = make_home_style_splash(original, bg)

    splash.save(ASSETS / "air_docs_logo_splash.png")

    splash.save(ASSETS / "air_docs_splash_icon.png")

    splash.save(ASSETS / "air_docs_splash_android12.png")



    Path(ASSETS / "_logo_bg.txt").write_text(hex_bg, encoding="utf-8")

    print(f"splash={splash.size} (home-style portrait)")





def main() -> None:

    if "--patch-only" in sys.argv:

        patch_splash_xml()

        return



    generate_assets()

    subprocess.run(

        ["dart", "run", "flutter_native_splash:create"],

        cwd=ROOT,

        check=True,

    )

    patch_splash_xml()

    print("done — splash matches home screen on all Android devices")





if __name__ == "__main__":

    main()

