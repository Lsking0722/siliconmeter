# SiliconMeter app icon: a square die in slate line art on black, a soft white halo behind it
# and a few cores lit white, on a dark macOS squircle. Our own floorplan; the name plate
# reads "SoC" (Inter Display SemiBold, or the font in $SM_ICON_FONT). No Apple logo.
#   python3 scripts/make_icon.py Resources/AppIcon-1024.png          (full detail)
#   python3 scripts/make_icon.py Resources/AppIcon-small.png small   (16–32 px sizes: bolder
#   strokes, no inner detail, so the die still reads as a die)
# Needs Pillow. scripts/pack_icns.py packs both into Resources/AppIcon.icns.
import os, sys
SMALL = len(sys.argv) > 2 and sys.argv[2] == "small"
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageFont

S = 4096                       # supersampled canvas (4× of 1024)
U = S / 1024                   # px per icon point
DIE = 636                      # die edge in icon points
D0 = (1024 - DIE) / 2          # die origin (points)
def P(v): return v * U
def die(x, y): return (P(D0 + x * DIE / 1000), P(D0 + y * DIE / 1000))   # die units 0…1000
def lw(units): return max(1, int(round(units * (2.6 if SMALL else 1) * DIE / 1000 * U)))

LINE = (138, 150, 159, 255)    # slate grey lines
DIM = (96, 107, 116, 255)      # inner detail
LIT = (246, 248, 250, 255)

icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))

# Squircle (macOS grid: 824 pt, radius ≈ 185) with a faint vertical sheen.
sq = Image.new('L', (S, S), 0)
ImageDraw.Draw(sq).rounded_rectangle([P(100), P(100), P(924), P(924)], radius=int(P(185)), fill=255)
shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
shadow.putalpha(sq.filter(ImageFilter.GaussianBlur(P(24))).point(lambda v: int(v * 0.5)))
icon = Image.alpha_composite(icon, ImageChops.offset(shadow, 0, int(P(10))))
bg = Image.new('RGBA', (S, S), (5, 6, 7, 255))
sheen = Image.linear_gradient('L').resize((S, S)).point(lambda v: int(14 * (1 - v / 255)))
bg = Image.composite(Image.new('RGBA', (S, S), (60, 66, 72, 255)), bg, sheen)
body = Image.new('RGBA', (S, S), (0, 0, 0, 0)); body.paste(bg, (0, 0), sq)
icon = Image.alpha_composite(icon, body)

# Halo: a soft white glow around the die, as in Apple's chip keynote shots.
halo_mask = Image.new('L', (S, S), 0)
x0, y0 = die(0, 0); x1, y1 = die(1000, 1000)
ImageDraw.Draw(halo_mask).rectangle([x0, y0, x1, y1], fill=255)
halo = halo_mask.filter(ImageFilter.GaussianBlur(P(30))).point(lambda v: int(v * 0.5))
halo = ImageChops.multiply(halo, sq)
layer = Image.new('RGBA', (S, S), (225, 232, 238, 0)); layer.putalpha(halo)
icon = Image.alpha_composite(icon, layer)

# Die artwork on its own layer.
art = Image.new('RGBA', (S, S), (0, 0, 0, 0))
lit = Image.new('L', (S, S), 0)          # mask of lit strokes (for their glow)
A = ImageDraw.Draw(art); L = ImageDraw.Draw(lit)

def rect(x, y, w, h, color=LINE, width=4, fill=None, glow=False):
    if SMALL and color == DIM: return
    a, b = die(x, y); c, d = die(x + w, y + h)
    A.rectangle([a, b, c, d], outline=color, width=lw(width), fill=fill)
    if glow: L.rectangle([a, b, c, d], outline=255, width=lw(width))
def line(x, y, x2, y2, color=DIM, width=2.5, glow=False):
    if SMALL and color == DIM: return
    A.line([die(x, y), die(x2, y2)], fill=color, width=lw(width))
    if glow: L.line([die(x, y), die(x2, y2)], fill=255, width=lw(width))

# Silicon and frame.
rect(0, 0, 1000, 1000, fill=(6, 7, 8, 255), width=0, color=None)
F = 22
A.rectangle([*die(0, 0), *die(1000, 1000)], outline=(150, 162, 171, 255), width=lw(F))
G = 18                                    # street between blocks

def nested(x, y, w, h, color=LINE, glow=False, depth=3):
    """A core: frame, inset ring, a centre cell split in three."""
    rect(x, y, w, h, color, 7 if glow else 6, glow=glow)
    ix, iy, iw, ih = x + w * 0.12, y + h * 0.12, w * 0.76, h * 0.76
    rect(ix, iy, iw, ih, color if glow else DIM, 3.5, glow=glow)
    if depth > 2:
        cx, cy, cw, ch = x + w * 0.3, y + h * 0.3, w * 0.4, h * 0.4
        rect(cx, cy, cw, ch, color if glow else DIM, 3, glow=glow)
        for t in (1 / 3, 2 / 3):
            line(cx, cy + ch * t, cx + cw, cy + ch * t, color if glow else DIM, 2.5, glow=glow)
        line(x + w * 0.5, iy, x + w * 0.5, cy, color if glow else DIM, 2.5, glow=glow)
        line(x + w * 0.5, cy + ch, x + w * 0.5, iy + ih, color if glow else DIM, 2.5, glow=glow)

L0, L1 = 40, 480          # left half
R0, R1 = 500, 960         # right half

# Top-left: the name plate, "SoC" centred in a light metallic grey.
rect(L0, 40, L1 - L0, 210, LINE, 6)
if not SMALL:
    font = None
    for path in [os.environ.get("SM_ICON_FONT", ""),
                 "/usr/share/fonts/opentype/inter/InterDisplay-SemiBold.otf",
                 "/Library/Fonts/InterDisplay-SemiBold.otf",
                 "/System/Library/Fonts/SFNS.ttf"]:
        if path and os.path.exists(path):
            font = ImageFont.truetype(path, size=int(lw(1) * 128)); break
    if font is None: sys.exit("no font: set SM_ICON_FONT to an Inter Display SemiBold / SF Pro file")
    text = "SoC"
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    # Slight positive tracking, drawn glyph by glyph.
    track = lw(1) * 3
    x, _ = die(L0 + 44, 0)
    asc = font.getbbox("S")             # cap box of S
    cap = asc[3] - asc[1]
    _, top = die(0, 40 + 105)           # plate centre
    y = top - cap / 2 - asc[1]
    for ch in text:
        md.text((x, y), ch, font=font, fill=255)
        x += font.getlength(ch) + track
    # Centre the ink (not the advance box) in the plate, so both side margins are equal.
    bx0, by0, bx1, by1 = mask.getbbox()
    (px0, py0), (px1, py1) = die(L0, 40), die(L1, 250)
    mask = ImageChops.offset(mask, int(round((px0 + px1) / 2 - (bx0 + bx1) / 2)),
                             int(round((py0 + py1) / 2 - (by0 + by1) / 2)))
    metal = Image.linear_gradient("L").resize((S, S))
    tx0, ty0 = die(0, 40 + 105 - 55); tx1, ty1 = die(0, 40 + 105 + 55)
    # Light at the top of the letters, a touch darker below: brushed metal.
    shade = Image.new("RGBA", (S, S))
    top_c, bot_c = (226, 232, 236), (150, 161, 170)
    grad = Image.linear_gradient("L").resize((1, 256)).resize((S, int(ty1 - ty0)))
    col = Image.new("RGBA", (S, S), bot_c + (255,))
    band = Image.composite(Image.new("RGBA", grad.size, bot_c + (255,)),
                           Image.new("RGBA", grad.size, top_c + (255,)), grad)
    col.paste(Image.new("RGBA", (S, int(ty0)), top_c + (255,)), (0, 0))
    col.paste(band, (0, int(ty0)))
    col.putalpha(mask)
    art.alpha_composite(col)

# Top-right: SLC / IO — columns with ladder hatching.
cols = 9
for i in range(cols):
    x = R0 + i * (R1 - R0) / cols
    w = (R1 - R0) / cols
    rect(x, 40, w, 210, LINE, 4)
    if i % 3 != 1:
        for j in range(1, 9):
            line(x + 6, 40 + j * 210 / 9, x + w - 6, 40 + j * 210 / 9, DIM, 2)
    else:
        rect(x + w * 0.25, 95, w * 0.5, 100, DIM, 2.5)

# Left middle: two performance cores.
pw = (L1 - L0 - G) / 2
for i in range(2):
    nested(L0 + i * (pw + G), 270, pw, 290)
# Left: four efficiency cores — lit.
ew = (L1 - L0 - 3 * 12) / 4
for i in range(4):
    nested(L0 + i * (ew + 12), 580, ew, 160, LIT, glow=True)
# Bottom left: two rows of eight neural-engine / cache lanes.
nw = (L1 - L0) / 8
for r, y in enumerate((760, 865)):
    for i in range(8):
        x = L0 + i * nw
        rect(x + 3, y, nw - 6, 95, LINE, 4)
        rect(x + nw * 0.28, y + 22, nw * 0.44, 50, DIM, 2)
        line(x + nw * 0.28, y + 47, x + nw * 0.72, y + 47, DIM, 2)

# Right: six GPU cores (tall columns), each with one execution cell lit.
gw = (R1 - R0) / 6
for i in range(6):
    x = R0 + i * gw
    rect(x + 4, 270, gw - 8, 470, LINE, 6)
    rect(x + gw * 0.22, 300, gw * 0.56, 150, DIM, 2.5)
    for j in range(1, 5):
        line(x + gw * 0.3, 300 + j * 30, x + gw * 0.7, 300 + j * 30, DIM, 2)
    line(x + gw * 0.5, 450, x + gw * 0.5, 600, DIM, 2.5)
    rect(x + gw * 0.25, 600, gw * 0.5, 90, LIT, 4, glow=True)
    rect(x + gw * 0.37, 620, gw * 0.26, 50, LIT, 2.5, glow=True)
# Bottom right: media / display / fabric blocks.
rect(R0, 760, 270, 80, LINE, 4); rect(R0 + 280, 760, 180, 80, LINE, 4)
for j in range(1, 4): line(R0 + 10, 760 + j * 20, R0 + 260, 760 + j * 20, DIM, 2)
for i in range(1, 6): line(R0 + 280 + i * 30, 768, R0 + 280 + i * 30, 832, DIM, 2)
rect(R0, 852, 150, 108, LINE, 4); rect(R0 + 160, 852, 140, 108, LINE, 4); rect(R0 + 310, 852, 150, 108, LINE, 4)
rect(R0 + 25, 875, 100, 60, DIM, 2); rect(R0 + 185, 880, 90, 50, DIM, 2)
for j in range(1, 6): line(R0 + 320, 852 + j * 18, R0 + 450, 852 + j * 18, DIM, 2)

# Lit strokes: a tight, faint bloom only.
bloom = lit.filter(ImageFilter.GaussianBlur(P(4))).point(lambda v: int(min(255, v * 1.1)))
glow_layer = Image.new('RGBA', (S, S), (235, 242, 248, 0)); glow_layer.putalpha(bloom)
icon = Image.alpha_composite(icon, glow_layer)
icon = Image.alpha_composite(icon, art)

out = icon.resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1] if len(sys.argv) > 1 else 'AppIcon-1024.png')
