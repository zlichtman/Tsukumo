#!/usr/bin/env python3
"""Draws the Tsukumo DMG window background in Tsukumo's dark theme: a 900x560 pt layout (KemoSabe at its
desk, the name, and the install row with its pathway) on a 1920x1200 pt canvas so an enlarged window
stays dark. Writes background.png, background@2x.png; combine them into the committed background.tiff
(which release-mac.sh uses) with tiffutil -cathidpicheck. Run: python3 scripts/dmg/make_background.py"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math, os
HERE = os.path.dirname(os.path.abspath(__file__))
BG, INK, CORAL = (26, 21, 40), (244, 236, 226), (240, 122, 98)
LAYOUT_W, LAYOUT_H = 900, 560
APP, APPS, ICON_Y = 260, 640, 352   # icon centers, kept in step with settings.py

def font(size, weight=None):
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
        if weight:
            try: f.set_variation_by_name(weight)
            except Exception: pass
        return f
    except OSError:
        return ImageFont.load_default()

def centered(d, text, y, f, fill, scale):
    w = d.textlength(text, font=f); d.text((LAYOUT_W * scale / 2 - w / 2, y * scale), text, font=f, fill=fill)

def dotted_curve(d, points, scale, color, alpha, r=1.6, step=9):
    # A quadratic Bezier through three points, drawn as dots.
    (x0, y0), (cx, cy), (x1, y1) = points
    length = math.dist((x0, y0), (cx, cy)) + math.dist((cx, cy), (x1, y1))
    n = max(2, int(length / step))
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * cx + t ** 2 * x1
        y = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * cy + t ** 2 * y1
        a = int(alpha * (0.35 + 0.65 * math.sin(math.pi * t)))
        d.ellipse([(x - r) * scale, (y - r) * scale, (x + r) * scale, (y + r) * scale], fill=color + (a,))

def draw(scale):
    im = Image.new("RGBA", (1920 * scale, 1200 * scale), BG + (255,))
    glow = Image.new("RGBA", im.size, (0, 0, 0, 0)); g = ImageDraw.Draw(glow)
    g.ellipse([(LAYOUT_W / 2 - 210) * scale, 10 * scale, (LAYOUT_W / 2 + 210) * scale, 250 * scale], fill=CORAL + (40,))
    g.ellipse([(LAYOUT_W / 2 - 330) * scale, 280 * scale, (LAYOUT_W / 2 + 330) * scale, 440 * scale], fill=(120, 96, 200, 22))
    im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(48 * scale)))
    d = ImageDraw.Draw(im)
    # Pathways: faint dotted curves from Kemo's screen down to each end of the install row.
    dotted_curve(d, [(540, 150), (720, 150), (APPS, ICON_Y - 72)], scale, CORAL, 95)
    dotted_curve(d, [(372, 120), (185, 140), (APP, ICON_Y - 72)], scale, INK, 60)
    # Kemo at its desk. The crop is from the app's dark background at 2x; fade that color out.
    kemo = Image.open(os.path.join(HERE, "kemo-at-work.png")).convert("RGBA")
    px = kemo.load()
    for yy in range(kemo.height):
        for xx in range(kemo.width):
            r, gg, b, a = px[xx, yy]
            px[xx, yy] = (r, gg, b, min(a, min(255, (abs(r - BG[0]) + abs(gg - BG[1]) + abs(b - BG[2])) * 9)))
    kh = int(170 * scale); kw = int(kemo.width * kh / kemo.height)
    kemo = kemo.resize((kw, kh), Image.LANCZOS)
    im.alpha_composite(kemo, (int(LAYOUT_W * scale / 2 - kw / 2), int(26 * scale)))
    centered(d, "Tsukumo", 204, font(28 * scale, "Bold"), INK + (250,), scale)
    centered(d, "All your AI bots in one dock, with KemoSabe on your Mac.", 242, font(13 * scale), INK + (150,), scale)
    # The pathway between the icons: dashes that grow toward Applications.
    y = ICON_Y * scale; x0, x1 = (APP + 82) * scale, (APPS - 82) * scale
    x, i = x0, 0
    while x < x1 - 18 * scale:
        dash = (6 + i * 1.4) * scale
        a = int(110 + min(145, i * 14))
        d.rounded_rectangle([x, y - 2 * scale, min(x + dash, x1 - 18 * scale), y + 2 * scale], radius=2 * scale, fill=CORAL + (a,))
        x += dash + 7 * scale; i += 1
    d.polygon([(x1, y), (x1 - 18 * scale, y - 11 * scale), (x1 - 18 * scale, y + 11 * scale)], fill=CORAL)
    # Finder draws icon names in dark text over a picture, so each name sits on a soft ivory plate.
    for cx in (APP, APPS):
        d.rounded_rectangle([(cx - 64) * scale, (ICON_Y + 70) * scale, (cx + 64) * scale, (ICON_Y + 92) * scale], radius=11 * scale, fill=INK + (228,))
    centered(d, "Drag Tsukumo into Applications", 468, font(17 * scale, "Semibold"), INK + (240,), scale)
    centered(d, "Then open it from Applications. It lives in the menu bar.", 496, font(12 * scale), INK + (140,), scale)
    return im.convert("RGB")

draw(1).save(os.path.join(HERE, "background.png"))
draw(2).save(os.path.join(HERE, "background@2x.png"))
print("wrote background.png and background@2x.png")
