#!/usr/bin/env python3
"""Generate the complete VexSign V·Pen brand system from one mark.

The only hand-authored geometry is the V·Pen mark in
``VexSign/Resources/brand/Source/vpen-mark.svg``.  This script renders the
transparent PNG master and all public and in-app derivatives from the matching
geometry below:

* iOS standard, dark and tinted app-icon appearances;
* Xcode catalog, Icon Composer and Web Manager copies;
* logo marks, lockups, banners, favicon/PWA and social sets;
* the static and animated README hero.

The standard iOS icon stays at the established public path
``VexSign/Resources/Icons/AppIcon/icon.png``.  It is opaque and unrounded;
iOS owns the outer icon mask.  Web/logo surfaces use the same continuous-corner
mark with transparency around the tile.

Usage:
    python3 Tools/Release/generate-app-icons.py
    python3 Tools/Release/generate-app-icons.py --check

Only Pillow is required.  ``--check`` writes nothing and exits non-zero when a
committed generated asset has drifted.
"""
from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "VexSign/Resources"
BRAND = RESOURCES / "brand"
SOURCE = BRAND / "Source"
ICON_DIR = RESOURCES / "Icons/AppIcon"
XCASSETS = RESOURCES / "Assets.xcassets"
ICON_COMPOSER = RESOURCES / "AppIcon.icon"
DASHBOARD_ICON = ROOT / "Services/WebManager/Dashboard/icon.png"

# The V·Pen palette deliberately mirrors the related signing-family's calm,
# Apple-style indigo language while retaining VexSign's own letterform.
INDIGO_LIGHT = ((0x6D, 0x6A, 0xF0), (0x4B, 0x48, 0xC4))
INDIGO_DARK = ((0x7C, 0x79, 0xF5), (0x5A, 0x57, 0xD6))
ICON_DARK = ((0x1E, 0x1C, 0x34), (0x0C, 0x0C, 0x14))
TINTED_GROUND = (0x12, 0x12, 0x1A)
INK = "#1D1D1F"
PAPER = "#F5F5F7"
SURFACE_DARK = "#15151D"
MUTED_LIGHT = "#6E6E73"
MUTED_DARK = "#A1A1AA"
CORNER = 0.2237
MARK_FILL = 0.66

FONT_REGULAR = (
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
)
FONT_BOLD = (
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf",
)


def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    """Use a stable, widely available sans fallback for generated raster copy."""
    candidates = FONT_BOLD if weight == "bold" else FONT_REGULAR
    for candidate in candidates:
        if Path(candidate).is_file():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default()


def png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def text_bytes(text: str) -> bytes:
    return text.rstrip().encode("utf-8") + b"\n"


def hex_color(value: tuple[int, int, int]) -> str:
    return "#%02X%02X%02X" % value


# ---------------------------------------------------------------------------
# V·Pen master geometry
# ---------------------------------------------------------------------------
#
# The mark is a capital V that resolves into a fountain nib and a single signing
# flourish.  At favicon size it is an unmistakable V; at icon size the nib and
# hand-written finish make the signing purpose explicit.  Coordinates are in a
# 1024×1024 source canvas and are shared by the source SVG and raster renderer.


def _point(x: float, y: float, scale: int) -> tuple[int, int]:
    return round(x * scale), round(y * scale)


def _cubic(
    p0: tuple[float, float],
    p1: tuple[float, float],
    p2: tuple[float, float],
    p3: tuple[float, float],
    steps: int = 80,
) -> list[tuple[float, float]]:
    points = []
    for index in range(steps + 1):
        t = index / steps
        mt = 1 - t
        points.append((
            mt ** 3 * p0[0] + 3 * mt ** 2 * t * p1[0] + 3 * mt * t ** 2 * p2[0] + t ** 3 * p3[0],
            mt ** 3 * p0[1] + 3 * mt ** 2 * t * p1[1] + 3 * mt * t ** 2 * p2[1] + t ** 3 * p3[1],
        ))
    return points


def _round_line(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[float, float]],
    width: float,
    scale: int,
    fill: tuple[int, int, int, int],
) -> None:
    scaled = [_point(x, y, scale) for x, y in points]
    line_width = round(width * scale)
    draw.line(scaled, fill=fill, width=line_width, joint="curve")
    radius = line_width / 2
    for x, y in (scaled[0], scaled[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def render_mark(size: int = 1024) -> Image.Image:
    """Render the canonical white-on-transparent V·Pen source mark."""
    supersample = 4
    canvas = Image.new("RGBA", (size * supersample, size * supersample), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    white = (255, 255, 255, 255)
    clear = (0, 0, 0, 0)
    unit = size / 1024
    # Scale source-coordinates for callers other than the canonical 1024 master.
    scale = supersample * unit

    # Bold, rounded V arms.  The right arm is intentionally matched to the left;
    # the nib carries the signing expression instead of distorting the letter.
    _round_line(draw, [(242, 214), (480, 682)], 105, scale, white)
    _round_line(draw, [(782, 214), (544, 682)], 105, scale, white)

    # A tapered fountain nib turns the V point into the signing tool.
    draw.polygon([_point(x, y, scale) for x, y in ((454, 644), (570, 644), (512, 842))], fill=white)
    # Breather hole and slit are transparent, not a painted background colour,
    # so this source works on every surface.
    x0, y0 = _point(494, 720, scale)
    x1, y1 = _point(530, 756, scale)
    draw.ellipse((x0, y0, x1, y1), fill=clear)
    _round_line(draw, [(512, 756), (512, 812)], 8, scale, clear)

    # One continuous signing flourish, with no detached decorative elements.
    _round_line(draw, _cubic((500, 846), (560, 888), (636, 875), (688, 840)), 13, scale, white)
    _round_line(draw, _cubic((688, 840), (662, 882), (722, 890), (780, 868)), 13, scale, white)
    _round_line(draw, _cubic((780, 868), (838, 850), (837, 808), (800, 812)), 13, scale, white)

    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def mark_svg(uid: str = "vpen", fill: str = "#FFFFFF") -> str:
    """The actual vector form of the V·Pen, including nib cut-outs."""
    return f'''<defs>
  <mask id="{uid}-cuts">
    <rect width="1024" height="1024" fill="#FFFFFF"/>
    <circle cx="512" cy="738" r="18" fill="#000000"/>
    <path d="M508 756H516V812H508Z" fill="#000000"/>
  </mask>
</defs>
<g fill="{fill}" stroke="{fill}" stroke-linecap="round" stroke-linejoin="round" mask="url(#{uid}-cuts)">
  <path d="M242 214L480 682" fill="none" stroke-width="105"/>
  <path d="M782 214L544 682" fill="none" stroke-width="105"/>
  <path d="M454 644L570 644L512 842Z" stroke="none"/>
  <path d="M500 846C560 888 636 875 688 840C662 882 722 890 780 868C838 850 837 808 800 812" fill="none" stroke-width="13"/>
</g>'''


def source_svg() -> str:
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="VexSign V·Pen mark">
{mark_svg("source")}
</svg>'''


# ---------------------------------------------------------------------------
# Raster treatment
# ---------------------------------------------------------------------------

def diagonal_gradient(size: int, start: tuple[int, int, int], end: tuple[int, int, int]) -> Image.Image:
    """A corner-to-corner RGB gradient without external raster dependencies."""
    pixels: list[tuple[int, int, int]] = []
    denominator = max(1, 2 * (size - 1))
    for y in range(size):
        for x in range(size):
            t = (x + y) / denominator
            pixels.append(tuple(round(a * (1 - t) + b * t) for a, b in zip(start, end)))
    image = Image.new("RGB", (size, size))
    image.putdata(pixels)
    return image


def rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=round(size * CORNER), fill=255)
    return mask


def glass_overlays(size: int, strength: float = 1.0) -> Image.Image:
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    # Soft lens light across the upper half and a single top specular line.
    draw.ellipse(
        (-round(size * 0.35), -round(size * 0.78), round(size * 1.35), round(size * 0.52)),
        fill=(255, 255, 255, round(32 * strength)),
    )
    overlay = overlay.filter(ImageFilter.GaussianBlur(max(1, round(size * 0.045))))
    draw = ImageDraw.Draw(overlay)
    top = max(1, round(size * 0.052))
    for y in range(top):
        opacity = round(76 * strength * (1 - y / top))
        draw.line((0, y, size, y), fill=(255, 255, 255, opacity))
    return overlay


def make_tile(size: int, variant: str, rounded: bool, glass: float = 1.0) -> Image.Image:
    if variant == "light":
        background = diagonal_gradient(size, *INDIGO_LIGHT)
    elif variant == "logo-dark":
        background = diagonal_gradient(size, *INDIGO_DARK)
    elif variant == "icon-dark":
        background = diagonal_gradient(size, *ICON_DARK)
    else:  # pragma: no cover - internal callers only
        raise ValueError(f"unknown tile variant: {variant}")
    tile = background.convert("RGBA")
    tile.alpha_composite(glass_overlays(size, glass))
    if rounded:
        tile.putalpha(rounded_mask(size))
    return tile


def scaled_mark(mark: Image.Image, height: int, color: tuple[int, int, int] = (255, 255, 255)) -> Image.Image:
    alpha = mark.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:  # pragma: no cover - source geometry guarantees content
        raise ValueError("V·Pen source mark is empty")
    crop = alpha.crop(bbox)
    width = max(1, round(crop.width * height / crop.height))
    alpha = crop.resize((width, height), Image.Resampling.LANCZOS)
    glyph = Image.new("RGBA", (width, height), color + (0,))
    glyph.putalpha(alpha)
    return glyph


def place_mark(tile: Image.Image, mark: Image.Image, fill: float = MARK_FILL, dy: float = 0.0) -> Image.Image:
    glyph = scaled_mark(mark, round(tile.height * fill))
    x = (tile.width - glyph.width) // 2
    y = (tile.height - glyph.height) // 2 + round(tile.height * dy)
    output = tile.copy()
    output.alpha_composite(glyph, (x, y))
    return output


def render_mark_tile(mark: Image.Image, size: int, variant: str, rounded: bool, border: bool = False) -> Image.Image:
    # Render at 2× to keep rounded and fine nib edges smooth at favicon sizes.
    working = max(64, size * 2)
    tile = make_tile(working, variant, rounded)
    output = place_mark(tile, mark)
    if rounded and border:
        edge = Image.new("RGBA", (working, working), (0, 0, 0, 0))
        inset = max(1, round(working * 0.008))
        ImageDraw.Draw(edge).rounded_rectangle(
            (inset, inset, working - inset - 1, working - inset - 1),
            radius=round(working * CORNER) - inset,
            outline=(255, 255, 255, 40),
            width=max(1, inset),
        )
        output.alpha_composite(edge)
    return output.resize((size, size), Image.Resampling.LANCZOS)


def render_tinted(mark: Image.Image, size: int = 1024) -> Image.Image:
    """Opaque monochrome version required by this project's iOS asset policy."""
    ground = Image.new("RGBA", (size, size), TINTED_GROUND + (255,))
    glyph = scaled_mark(mark, round(size * MARK_FILL), (245, 245, 247))
    ground.alpha_composite(glyph, ((size - glyph.width) // 2, (size - glyph.height) // 2))
    return ground.convert("RGB")


# ---------------------------------------------------------------------------
# Vector delivery surfaces
# ---------------------------------------------------------------------------

def svg_defs(uid: str, variant: str) -> str:
    top, bottom = INDIGO_DARK if variant == "logo-dark" else INDIGO_LIGHT
    return f'''<defs>
  <linearGradient id="{uid}-tile" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{hex_color(top)}"/><stop offset="1" stop-color="{hex_color(bottom)}"/>
  </linearGradient>
  <linearGradient id="{uid}-spec" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.30"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>
  <radialGradient id="{uid}-lens" cx="0.5" cy="-0.1" r="0.9">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.12"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </radialGradient>
</defs>'''


def svg_tile(uid: str, variant: str = "light", rounded: bool = True) -> str:
    radius = "229.07" if rounded else "0"
    return f'''{svg_defs(uid, variant)}
<rect width="1024" height="1024" rx="{radius}" fill="url(#{uid}-tile)"/>
<rect width="1024" height="1024" rx="{radius}" fill="url(#{uid}-lens)"/>
<rect width="1024" height="53" rx="{radius}" fill="url(#{uid}-spec)"/>
{mark_svg(uid + '-mark')}'''


def svg_logo_mark(variant: str) -> str:
    uid = "vs-dark" if variant == "logo-dark" else "vs-light"
    label = "VexSign dark logo mark" if variant == "logo-dark" else "VexSign logo mark"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="512" height="512" role="img" aria-label="{label}">
{svg_tile(uid, variant, True)}
</svg>'''


def svg_app_icon() -> str:
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="VexSign app icon">
{svg_tile("vs-app", "light", False)}
</svg>'''


def svg_monochrome(color: str, label: str, outline: bool = False) -> str:
    if outline:
        # A true one-colour line treatment for embossing and engraving. It is
        # deliberately drawn from the V·Pen geometry instead of tracing a PNG.
        mark = f'''<g fill="none" stroke="{color}" stroke-linecap="round" stroke-linejoin="round">
  <path d="M242 214L480 682" stroke-width="66"/>
  <path d="M782 214L544 682" stroke-width="66"/>
  <path d="M454 644L570 644L512 842Z" stroke-width="34"/>
  <circle cx="512" cy="738" r="18" stroke-width="18"/>
  <path d="M512 756V812" stroke-width="11"/>
  <path d="M500 846C560 888 636 875 688 840C662 882 722 890 780 868C838 850 837 808 800 812" stroke-width="13"/>
</g>'''
    else:
        mark = mark_svg("mono", color)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="{label}">
{mark}
</svg>'''


def svg_wordmark(variant: str) -> str:
    color = PAPER if variant == "dark" else INK
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 88" width="360" height="88" role="img" aria-label="VexSign">
  <text x="0" y="66" font-family="-apple-system, 'SF Pro Display', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif" font-size="72" font-weight="700" letter-spacing="-2.5" fill="{color}">VexSign</text>
</svg>'''


def svg_lockup(variant: str) -> str:
    uid = "vs-lock-dark" if variant == "logo-dark" else "vs-lock"
    top, bottom = INDIGO_DARK if variant == "logo-dark" else INDIGO_LIGHT
    color = PAPER if variant == "logo-dark" else INK
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 556 128" width="556" height="128" role="img" aria-label="VexSign">
  <defs>
    <linearGradient id="{uid}-tile" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{hex_color(top)}"/><stop offset="1" stop-color="{hex_color(bottom)}"/></linearGradient>
    <radialGradient id="{uid}-lens" cx="0.5" cy="-0.1" r="0.9"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.12"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
  </defs>
  <rect x="8" y="8" width="112" height="112" rx="25.05" fill="url(#{uid}-tile)"/>
  <rect x="8" y="8" width="112" height="112" rx="25.05" fill="url(#{uid}-lens)"/>
  <g transform="translate(8 8) scale(.109375)">
{mark_svg(uid + '-mark')}
  </g>
  <text x="148" y="82" font-family="-apple-system, 'SF Pro Display', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif" font-size="72" font-weight="700" letter-spacing="-2.5" fill="{color}">VexSign</text>
</svg>'''


def svg_banner(variant: str) -> str:
    dark = variant == "dark"
    ground = SURFACE_DARK if dark else PAPER
    ink = PAPER if dark else INK
    muted = MUTED_DARK if dark else MUTED_LIGHT
    glow = "#7C79F5" if dark else "#6D6AF0"
    tile_variant = "logo-dark" if dark else "light"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1500 500" width="1500" height="500" role="img" aria-label="VexSign — Sign, install, and manage apps on your device">
  <defs>
    <radialGradient id="vs-banner-glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{glow}" stop-opacity="0.22"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/></radialGradient>
    <linearGradient id="vs-banner-tile" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{hex_color(INDIGO_DARK[0] if dark else INDIGO_LIGHT[0])}"/><stop offset="1" stop-color="{hex_color(INDIGO_DARK[1] if dark else INDIGO_LIGHT[1])}"/></linearGradient>
    <radialGradient id="vs-banner-lens" cx="0.5" cy="-0.1" r="0.9"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.12"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
  </defs>
  <rect width="1500" height="500" rx="28" fill="{ground}"/>
  <ellipse cx="250" cy="70" rx="440" ry="240" fill="url(#vs-banner-glow)"/>
  <ellipse cx="1380" cy="450" rx="440" ry="240" fill="url(#vs-banner-glow)"/>
  <rect x="118" y="132" width="236" height="236" rx="52.79" fill="url(#vs-banner-tile)"/>
  <rect x="118" y="132" width="236" height="236" rx="52.79" fill="url(#vs-banner-lens)"/>
  <g transform="translate(118 132) scale(.230469)">
{mark_svg('vs-banner-mark')}
  </g>
  <text x="414" y="236" font-family="-apple-system, 'SF Pro Display', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif" font-size="84" font-weight="700" letter-spacing="-3.5" fill="{ink}">VexSign</text>
  <text x="418" y="302" font-family="-apple-system, 'SF Pro Text', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif" font-size="32" fill="{muted}">Sign, install, and manage apps — entirely on your device.</text>
  <text x="418" y="350" font-family="-apple-system, 'SF Pro Text', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif" font-size="22" font-weight="600" letter-spacing=".6" fill="{muted}">iOS 16+   ·   ON-DEVICE   ·   GPL-3.0</text>
</svg>'''


def svg_favicon() -> str:
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="VexSign">
{svg_tile('vs-favicon', 'light', True)}
</svg>'''


def button_svg(label: str, icon: str, width: int, href_label: str) -> str:
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} 52" width="{width}" height="52" role="img" aria-label="{href_label}">
  <defs><linearGradient id="button" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6D6AF0"/><stop offset="1" stop-color="#4B48C4"/></linearGradient></defs>
  <rect width="{width}" height="52" rx="14" fill="url(#button)"/>
  <path d="{icon}" fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="42" y="33" font-family="-apple-system, 'SF Pro Text', 'Segoe UI', Roboto, Helvetica, Arial, sans-serif" font-size="16" font-weight="700" fill="#FFFFFF">{label}</text>
</svg>'''


# ---------------------------------------------------------------------------
# Marketing raster surfaces
# ---------------------------------------------------------------------------

def radial_glow(image: Image.Image, center: tuple[int, int], radius: int, color: tuple[int, int, int], opacity: int) -> None:
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    x, y = center
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color + (opacity,))
    layer = layer.filter(ImageFilter.GaussianBlur(radius // 2))
    image.alpha_composite(layer)


def social_preview(mark: Image.Image, light: bool) -> Image.Image:
    size = (1280, 640)
    base = Image.new("RGBA", size, (245, 245, 247, 255) if light else (21, 21, 29, 255))
    radial_glow(base, (190, 70), 410, (109, 106, 240), 38 if light else 56)
    radial_glow(base, (1110, 575), 460, (90, 87, 214), 26 if light else 45)
    logo = render_mark_tile(mark, 260, "light" if light else "logo-dark", True, border=light)
    base.alpha_composite(logo, (100, 190))
    draw = ImageDraw.Draw(base)
    ink = (29, 29, 31) if light else (245, 245, 247)
    muted = (110, 110, 115) if light else (190, 188, 205)
    draw.text((410, 202), "VexSign", font=font("bold", 88), fill=ink)
    draw.text((414, 330), "Sign, install, and manage apps", font=font("regular", 31), fill=muted)
    draw.text((414, 374), "entirely on your device.", font=font("regular", 31), fill=muted)
    draw.text((416, 465), "iOS 16+  ·  ON-DEVICE  ·  GPL-3.0", font=font("bold", 20), fill=muted)
    return base.convert("RGB")


def hero_background() -> Image.Image:
    image = Image.new("RGBA", (800, 300), (21, 21, 29, 255))
    radial_glow(image, (120, 30), 260, (109, 106, 240), 68)
    radial_glow(image, (740, 290), 250, (90, 87, 214), 44)
    return image


def hero_frames(mark: Image.Image) -> tuple[list[Image.Image], list[int]]:
    """A small, quiet reveal that is appropriate for GitHub's autoplay loop."""
    background = hero_background()
    tile = render_mark_tile(mark, 168, "logo-dark", True)
    tile_x, tile_y = 66, 66
    title_font = font("bold", 58)
    subtitle_font = font("regular", 17)
    meta_font = font("bold", 12)
    frames: list[Image.Image] = []
    durations: list[int] = []
    count = 33
    for index in range(count):
        t = index / (count - 1)
        ease = 1 - (1 - min(1, t / 0.55)) ** 3
        frame = background.copy()
        logo = tile.copy()
        # The mark settles up by 5 pixels while the card fades in.
        alpha = logo.getchannel("A").point(lambda value: round(value * ease))
        logo.putalpha(alpha)
        frame.alpha_composite(logo, (tile_x, tile_y + round((1 - ease) * 5)))
        text_progress = max(0, min(1, (t - 0.28) / 0.34))
        text_ease = 1 - (1 - text_progress) ** 3
        if text_ease:
            text_layer = Image.new("RGBA", frame.size, (0, 0, 0, 0))
            draw = ImageDraw.Draw(text_layer)
            title_alpha = round(255 * text_ease)
            muted_alpha = round(205 * text_ease)
            y_offset = round((1 - text_ease) * 7)
            draw.text((272, 91 + y_offset), "VexSign", font=title_font, fill=(245, 245, 247, title_alpha))
            draw.text((275, 171 + y_offset), "Sign, install, and manage apps —", font=subtitle_font, fill=(205, 203, 220, muted_alpha))
            draw.text((275, 197 + y_offset), "entirely on your device.", font=subtitle_font, fill=(205, 203, 220, muted_alpha))
            draw.text((276, 237 + y_offset), "iOS 16+  ·  ON-DEVICE  ·  GPL-3.0", font=meta_font, fill=(181, 179, 199, muted_alpha))
            frame.alpha_composite(text_layer)
        # One restrained specular pass once the identity is settled.
        if 0.58 <= t <= 0.83:
            phase = (t - 0.58) / 0.25
            shine = Image.new("RGBA", (168, 168), (0, 0, 0, 0))
            band_x = round(-80 + phase * 330)
            ImageDraw.Draw(shine).polygon(((band_x - 34, 0), (band_x + 5, 0), (band_x - 68, 168), (band_x - 107, 168)), fill=(255, 255, 255, 58))
            shine.putalpha(ImageChops.multiply(shine.getchannel("A"), tile.getchannel("A")))
            frame.alpha_composite(shine, (tile_x, tile_y))
        frames.append(frame.convert("RGB"))
        durations.append(65)
    durations[-1] = 1250
    return frames, durations


def gif_bytes(frames: list[Image.Image], durations: list[int]) -> bytes:
    palette = frames[-1].quantize(colors=160, method=Image.Quantize.MEDIANCUT)
    quantized = [frame.quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG) for frame in frames]
    buffer = io.BytesIO()
    quantized[0].save(buffer, format="GIF", save_all=True, append_images=quantized[1:], duration=durations, loop=0, optimize=True)
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# Output manifest
# ---------------------------------------------------------------------------

def brand_readme() -> str:
    return '''# VexSign Brand

## The V·Pen

VexSign’s mark is a capital **V** that ends in a fountain nib and one signing
flourish. It reads as a V from a favicon distance and as a signing instrument at
app-icon size. The mark is white on indigo, or a single ink in monochrome use.
It is not a generic checkmark and must never be stretched, rotated or recoloured.

The vector source is [`Source/vpen-mark.svg`](Source/vpen-mark.svg). Run:

```sh
python3 Tools/Release/generate-app-icons.py
python3 Tools/Release/generate-app-icons.py --check
```

The command owns every generated raster/vector delivery below. Do not edit a
PNG, favicon, catalog copy or README GIF by hand.

## Palette

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `indigoTop` → `indigoBottom` | `#6D6AF0` → `#4B48C4` | `#7C79F5` → `#5A57D6` | Tile, app icon, primary brand surface |
| Dark app-icon ground | — | `#1E1C34` → `#0C0C14` | System dark icon appearance |
| Ink / paper | `#1D1D1F` | `#F5F5F7` | Wordmark and copy |
| Surface / muted | `#15151D` / `#6E6E73` | `#15151D` / `#A1A1AA` | Banner, GIF and metadata |

## Asset map

| Surface | Location |
| --- | --- |
| Source mark | `Source/vpen-mark.svg`, `Source/vpen-mark-1024.png` |
| iOS icon source | `../Icons/AppIcon/` — standard, light, dark and tinted 1024px variants |
| AppIcon catalog | `../Assets.xcassets/AppIcon.appiconset/` |
| Logo marks, lockups, monochrome | `Logo/` |
| Banner | `Banner/` |
| Browser/PWA package | `Favicon/` |
| GitHub/social artwork | `Social/` |
| README animation / fallback | `Motion/hero.gif`, `Motion/hero-still.png` |

## Usage rules

* **iOS owns app-icon corners.** `Icons/AppIcon/icon.png` is opaque, square and
  full-bleed. Never bake a rounded alpha mask into it.
* Use `Logo/logo-mark.svg` on light surfaces and `logo-mark-dark.svg` on dark
  ones. Use a lockup rather than manually setting “VexSign” beside the tile.
* Clear space around the tile is one quarter of the tile side. The tile is at
  least 24 px on screen; below that use the monochrome V·Pen.
* The animated hero is for README/social only. Respect reduced-motion settings
  in the native app; no app behaviour depends on the animation.
'''


def icon_composer_json() -> str:
    return json.dumps({
        "fill": {
            "linear-gradient": ["srgb:0.42745,0.41569,0.94118,1.00000", "srgb:0.29412,0.28235,0.76863,1.00000"],
            "orientation": {"start": {"x": 0.0, "y": 0.0}, "stop": {"x": 1.0, "y": 1.0}},
        },
        "groups": [{
            "layers": [{
                "glass": False,
                "hidden": False,
                "image-name": "vexsign.png",
                "name": "VexSign V Pen",
                "position": {"scale": 1.0, "translation-in-points": [0, 0]},
            }],
            "shadow": {"kind": "neutral", "opacity": 0.35},
            "translucency": {"enabled": True, "value": 0.35},
        }],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }, indent=2) + "\n"


def output_manifest() -> dict[Path, bytes]:
    mark = render_mark()
    standard = render_mark_tile(mark, 1024, "light", False).convert("RGB")
    dark = render_mark_tile(mark, 1024, "icon-dark", False).convert("RGB")
    light = render_mark_tile(mark, 1024, "logo-dark", False).convert("RGB")
    tinted = render_tinted(mark)
    rounded = {size: render_mark_tile(mark, size, "light", True, border=True) for size in (512, 256, 128, 48, 32, 16)}
    rounded_dark = {size: render_mark_tile(mark, size, "logo-dark", True) for size in (512, 256, 128)}
    frames, durations = hero_frames(mark)
    web_manifest = {
        "name": "VexSign",
        "short_name": "VexSign",
        "description": "On-device signing and app management.",
        "icons": [
            {"src": "android-chrome-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "android-chrome-512.png", "sizes": "512x512", "type": "image/png"},
            {"src": "apple-touch-icon.png", "sizes": "180x180", "type": "image/png"},
        ],
        "theme_color": "#6D6AF0",
        "background_color": "#15151D",
        "display": "standalone",
    }
    outputs: dict[Path, bytes] = {
        # Source and canonical published app-icon set.
        SOURCE / "vpen-mark.svg": text_bytes(source_svg()),
        SOURCE / "vpen-mark-1024.png": png_bytes(mark),
        ICON_DIR / "icon.png": png_bytes(standard),
        ICON_DIR / "icon-light.png": png_bytes(light),
        ICON_DIR / "icon-dark.png": png_bytes(dark),
        ICON_DIR / "icon-tinted.png": png_bytes(tinted),
        ICON_DIR / "icon.svg": text_bytes(svg_app_icon()),
        ICON_DIR / "icon-512.png": png_bytes(rounded[512]),
        ICON_DIR / "icon-256.png": png_bytes(rounded[256]),
        ICON_DIR / "icon-192.png": png_bytes(rounded[256].resize((192, 192), Image.Resampling.LANCZOS)),
        ICON_DIR / "icon-180.png": png_bytes(rounded[256].resize((180, 180), Image.Resampling.LANCZOS)),
        ICON_DIR / "favicon-32.png": png_bytes(rounded[32]),
        ICON_DIR / "favicon-16.png": png_bytes(rounded[16]),
        # iOS app catalog and direct in-app references.
        XCASSETS / "AppIcon.appiconset/vexsign.png": png_bytes(standard),
        XCASSETS / "AppIcon.appiconset/vexsign_dark.png": png_bytes(dark),
        XCASSETS / "AppIcon.appiconset/vexsign_tint.png": png_bytes(tinted),
        XCASSETS / "AppLogo.imageset/AppLogo.png": png_bytes(standard),
        XCASSETS / "Glyph.imageset/vexsign.png": png_bytes(standard),
        XCASSETS / "LaunchLogo.imageset/LaunchLogo.png": png_bytes(rounded[512]),
        XCASSETS / "VexMark.imageset/VexMark.png": png_bytes(mark.resize((128, 128), Image.Resampling.LANCZOS)),
        XCASSETS / "VexMark.imageset/VexMark@2x.png": png_bytes(mark.resize((256, 256), Image.Resampling.LANCZOS)),
        XCASSETS / "VexMark.imageset/VexMark@3x.png": png_bytes(mark.resize((384, 384), Image.Resampling.LANCZOS)),
        XCASSETS / "VexMark.imageset/Contents.json": text_bytes(json.dumps({
            "images": [
                {"filename": "VexMark.png", "idiom": "universal", "scale": "1x"},
                {"filename": "VexMark@2x.png", "idiom": "universal", "scale": "2x"},
                {"filename": "VexMark@3x.png", "idiom": "universal", "scale": "3x"},
            ], "info": {"author": "xcode", "version": 1},
        }, indent=2)),
        # Icon Composer's original source layer now speaks the same V·Pen.
        ICON_COMPOSER / "Assets/vexsign.png": png_bytes(mark),
        ICON_COMPOSER / "icon.json": text_bytes(icon_composer_json()),
        # Existing deployed dashboard icon.
        DASHBOARD_ICON: png_bytes(rounded[512]),
        # Brand source outputs.
        BRAND / "README.md": text_bytes(brand_readme()),
        BRAND / "AppIcon/app-icon-1024.png": png_bytes(standard),
        BRAND / "AppIcon/app-icon-dark-1024.png": png_bytes(dark),
        BRAND / "AppIcon/app-icon-tinted-1024.png": png_bytes(tinted),
        BRAND / "AppIcon/app-icon.svg": text_bytes(svg_app_icon()),
        BRAND / "logo.svg": text_bytes(svg_logo_mark("light")),
        BRAND / "liquid-glass-logo.png": png_bytes(standard),
        BRAND / "hero.svg": text_bytes(svg_banner("dark")),
        BRAND / "Logo/logo-mark.svg": text_bytes(svg_logo_mark("light")),
        BRAND / "Logo/logo-mark-dark.svg": text_bytes(svg_logo_mark("logo-dark")),
        BRAND / "Logo/logo-mark-128.png": png_bytes(rounded[128]),
        BRAND / "Logo/logo-mark-256.png": png_bytes(rounded[256]),
        BRAND / "Logo/logo-mark-512.png": png_bytes(rounded[512]),
        BRAND / "Logo/logo-mark-dark-128.png": png_bytes(rounded_dark[128]),
        BRAND / "Logo/logo-mark-dark-256.png": png_bytes(rounded_dark[256]),
        BRAND / "Logo/logo-mark-dark-512.png": png_bytes(rounded_dark[512]),
        BRAND / "Logo/logo-lockup.svg": text_bytes(svg_lockup("light")),
        BRAND / "Logo/logo-lockup-dark.svg": text_bytes(svg_lockup("logo-dark")),
        BRAND / "Logo/logo-monochrome.svg": text_bytes(svg_monochrome(INK, "VexSign V Pen monochrome")),
        BRAND / "Logo/logo-monochrome-white.svg": text_bytes(svg_monochrome(PAPER, "VexSign V Pen white monochrome")),
        BRAND / "Logo/logo-outline.svg": text_bytes(svg_monochrome(INK, "VexSign V Pen outline", outline=True)),
        BRAND / "Logo/logo-outline-white.svg": text_bytes(svg_monochrome(PAPER, "VexSign V Pen white outline", outline=True)),
        BRAND / "Logo/wordmark.svg": text_bytes(svg_wordmark("light")),
        BRAND / "Logo/wordmark-dark.svg": text_bytes(svg_wordmark("dark")),
        BRAND / "Banner/banner-dark.svg": text_bytes(svg_banner("dark")),
        BRAND / "Banner/banner-light.svg": text_bytes(svg_banner("light")),
        BRAND / "Favicon/favicon.svg": text_bytes(svg_favicon()),
        BRAND / "Favicon/favicon-16.png": png_bytes(rounded[16]),
        BRAND / "Favicon/favicon-32.png": png_bytes(rounded[32]),
        BRAND / "Favicon/favicon-48.png": png_bytes(rounded[48]),
        BRAND / "Favicon/apple-touch-icon.png": png_bytes(render_mark_tile(mark, 180, "light", True, border=True)),
        BRAND / "Favicon/android-chrome-192.png": png_bytes(render_mark_tile(mark, 192, "light", True, border=True)),
        BRAND / "Favicon/android-chrome-512.png": png_bytes(rounded[512]),
        BRAND / "Favicon/site.webmanifest": text_bytes(json.dumps(web_manifest, indent=2)),
        BRAND / "Social/github-avatar.png": png_bytes(rounded_dark[512]),
        BRAND / "Social/social-preview.png": png_bytes(social_preview(mark, False)),
        BRAND / "Social/social-preview-light.png": png_bytes(social_preview(mark, True)),
        BRAND / "Motion/hero.gif": gif_bytes(frames, durations),
        BRAND / "Motion/hero-still.png": png_bytes(frames[-1]),
        BRAND / "Social/hero.gif": gif_bytes(frames, durations),
        # README calls to action with the same primary indigo surface.
        BRAND / "download-ipa.svg": text_bytes(button_svg("Download IPA", "M20 12v18m0 0 7-7m-7 7-7-7M11 39h18", 174, "Download VexSign IPA")),
        BRAND / "add-source.svg": text_bytes(button_svg("Add Source", "M20 12v18m-9-9h18M11 39h18", 170, "Add VexSign source")),
    }
    # ICO is intentionally assembled from the unrounded PNG app marks.  Browsers
    # pick the closest embedded resolution without needing a separate converter.
    ico = io.BytesIO()
    # Pillow generates the embedded sizes from the largest source image. Starting
    # at 48 px (rather than appending to a 16 px image) retains all three favicon
    # representations in the .ico payload.
    rounded[48].convert("RGBA").save(ico, format="ICO", sizes=[(16, 16), (32, 32), (48, 48)])
    outputs[BRAND / "Favicon/favicon.ico"] = ico.getvalue()
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when generated assets are stale")
    args = parser.parse_args()
    outputs = output_manifest()
    stale: list[Path] = []
    for path, content in outputs.items():
        if not path.is_file() or path.read_bytes() != content:
            stale.append(path)
            if not args.check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
                print(path.relative_to(ROOT))
    if args.check:
        if stale:
            print("VexSign brand assets are stale:", file=sys.stderr)
            for path in stale:
                print(f"  {path.relative_to(ROOT)}", file=sys.stderr)
            print("Run: python3 Tools/Release/generate-app-icons.py", file=sys.stderr)
            return 1
        print("VexSign V·Pen brand assets: up to date")
    else:
        print(f"Generated {len(outputs)} VexSign V·Pen brand assets from Source/vpen-mark.svg")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
