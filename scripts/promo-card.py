"""Compose a CurseForge promo card in the house style: 2000x1280, dark
ground with a faint diagonal weave, the wordmark and a tagline on the
left, a real in-game panel on the right, one caption along the bottom.

    python scripts/promo-card.py <panel.png> <out.png> --tagline "..." --caption "..." [--crop L,T,R,B] [--scale 1.6]

The panel is a screenshot (or a crop of one, via --crop, in source
pixels). It is scaled by --scale with nearest-neighbour so the game's
pixel text stays crisp, then centred on the right half. A panel with an
alpha channel (a mock rendered on a transparent page, see the Notes
cards) is instead fitted into a --fit W,H box with Lanczos, keeps its own
borders, and casts its shadow from its alpha. --wide moves the wordmark
and tagline up and lets the panel span the width below them, for a
scene of two panels side by side. Fonts are the Windows Arial family,
matching the earlier cards in promo/.
"""
import argparse
from PIL import Image, ImageDraw, ImageFont

W, H = 2000, 1280
BG = (23, 25, 33)
WEAVE = (31, 33, 42)
INK = (232, 230, 222)
GOLD = (255, 211, 110)
DIM = (150, 155, 170)
WHITE = (250, 250, 246)


def font(name, size):
    for path in (f"C:/Windows/Fonts/{name}",):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def weave(img):
    d = ImageDraw.Draw(img)
    for x in range(-H, W, 14):
        d.line([(x, 0), (x + H, H)], fill=WEAVE, width=1)


def rich(d, x, y, parts, f, spacing=8, maxw=640):
    """Word-wrapped text where parts is [(text, colour, bold)]; returns y after."""
    # a bold run that touches punctuation ("*yours*:") keeps the mark glued
    # to the previous word; a run at a chunk edge yields an empty token,
    # which is skipped so it does not become a stray space
    words = []
    for text, colour, bold in parts:
        for w in text.split(" "):
            if w == "":
                continue
            if words and w[0] in ",.:;!?" :
                pw, pc, pb = words[-1]
                words[-1] = (pw + w, pc, pb)
            else:
                words.append((w, colour, bold))
    line, lw = [], 0
    fb = font("arialbd.ttf", f.size)
    space = d.textlength(" ", font=f)
    lines = []
    for w, colour, bold in words:
        ff = fb if bold else f
        ww = d.textlength(w, font=ff)
        if line and lw + space + ww > maxw:
            lines.append(line)
            line, lw = [], 0
        line.append((w, colour, ff, ww))
        lw += (space if lw else 0) + ww
    if line:
        lines.append(line)
    for ln in lines:
        cx = x
        for w, colour, ff, ww in ln:
            d.text((cx, y), w, font=ff, fill=colour)
            cx += ww + space
        y += f.size + spacing
    return y


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("panel")
    ap.add_argument("out")
    ap.add_argument("--tagline", required=True, help="use *bold* around emphasised runs")
    ap.add_argument("--caption", required=True, help="'Title -- rest' puts the title in bold")
    ap.add_argument("--crop", default=None, help="L,T,R,B in source pixels")
    ap.add_argument("--scale", type=float, default=1.6)
    ap.add_argument("--fit", default=None, help="W,H box for an alpha panel (default 780,1040)")
    ap.add_argument("--wide", action="store_true", help="wordmark top-left, panel across the full width")
    a = ap.parse_args()

    card = Image.new("RGB", (W, H), BG)
    weave(card)
    d = ImageDraw.Draw(card)

    # wordmark: "True" in white, "Parse" in gold
    fm = font("arialbd.ttf", 84)
    x0, y0 = (120, 110) if a.wide else (370, 500)
    d.text((x0, y0), "True", font=fm, fill=WHITE)
    d.text((x0 + d.textlength("True", font=fm), y0), "Parse", font=fm, fill=GOLD)

    # tagline with *bold* runs
    parts, bold = [], False
    for i, chunk in enumerate(a.tagline.split("*")):
        if chunk:
            parts.append((chunk, INK if (i % 2 == 1) else DIM, i % 2 == 1))
    rich(d, x0, y0 + 120, parts, font("arial.ttf", 34), spacing=14, maxw=1400 if a.wide else 640)

    # panel
    panel = Image.open(a.panel)
    alpha = panel.mode == "RGBA"
    panel = panel.convert("RGBA" if alpha else "RGB")
    if a.crop:
        l, t, r, b = [int(v) for v in a.crop.split(",")]
        panel = panel.crop((l, t, r, b))
    pw, ph = panel.size
    if alpha:
        fw, fh = [int(v) for v in (a.fit or ("1760,820" if a.wide else "780,1040")).split(",")]
        k = min(fw / pw, fh / ph, 1.5)
        panel = panel.resize((round(pw * k), round(ph * k)), Image.LANCZOS)
    else:
        panel = panel.resize((int(pw * a.scale), int(ph * a.scale)), Image.NEAREST)
    pw, ph = panel.size
    if a.wide:
        px = (W - pw) // 2
        py = 330 + (H - 62 - 40 - 330 - ph) // 2
    else:
        px = 1120 + (760 - pw) // 2
        py = (H - ph) // 2
    # a soft drop shadow: a dark rectangle blurred into the ground, offset
    # down a little, then a 1px hairline in the panel's own border colour
    from PIL import ImageFilter
    pad = 90
    shade = Image.new("L", (pw + pad * 2, ph + pad * 2), 0)
    if alpha:
        shade.paste(panel.split()[3].point(lambda v: v * 170 // 255), (pad, pad + 14))
    else:
        ImageDraw.Draw(shade).rectangle((pad, pad + 14, pad + pw, pad + ph + 14), fill=170)
    shade = shade.filter(ImageFilter.GaussianBlur(28))
    dark = Image.new("RGB", shade.size, (6, 6, 10))
    card.paste(dark, (px - pad, py - pad), shade)
    if alpha:
        card.paste(panel, (px, py), panel)
    else:
        card.paste(panel, (px, py))
        d.rectangle((px - 1, py - 1, px + pw, py + ph), outline=(56, 49, 76))

    # caption: "Title -- rest"
    fc, fcb = font("arial.ttf", 30), font("arialbd.ttf", 30)
    title, _, rest = a.caption.partition(" -- ")
    cx, cy = 50, H - 62
    d.text((cx, cy), title, font=fcb, fill=INK)
    cx += d.textlength(title, font=fcb)
    if rest:
        d.text((cx, cy), " \u2014 " + rest, font=fc, fill=DIM)

    card.save(a.out, "PNG", optimize=True)
    print("wrote", a.out, card.size)


if __name__ == "__main__":
    main()
