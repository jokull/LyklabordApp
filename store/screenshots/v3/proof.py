#!/usr/bin/env python3
"""v3 proof frame — shot 2 (accents) in the "crop, don't frame" concept.
Reads the real simulator capture, crops from the text field down, scales it to
full width on the paper stage, and puts the before→after transformation in
display type. Pure Pillow. Writes v3/proof-02.png (1260x2736) and a two-up
against the v2 render for comparison."""
import pathlib
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = pathlib.Path(__file__).parent
W, H = 1260, 2736
PAPER = (0xFA, 0xF9, 0xF6); RAISED = (0xF1, 0xEF, 0xE9)
INK = (0x1C, 0x1B, 0x1A); SOFT = (0x55, 0x52, 0x4D); FAINT = (0xA5, 0xA1, 0x9A)
SF = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight=400):
    f = ImageFont.truetype(SF, size)
    try: f.set_variation_by_axes([100, max(17, min(96, size*0.55)), 400, weight])
    except Exception: pass
    return f

def tw(d, s, f): 
    b = d.textbbox((0,0), s, font=f); return b[2]-b[0]

img = Image.new("RGB", (W, H), PAPER)
d = ImageDraw.Draw(img)

# ---- caption zone -------------------------------------------------------
y = 190
t = font(126, 760)
for line in ["Type", "accent-naked"]:
    d.text(((W - tw(d, line, t))//2, y), line, font=t, fill=INK); y += 138
y += 40
s = font(46, 450)
for line in ["Dropping accents is an input method,", "not a typo."]:
    d.text(((W - tw(d, line, s))//2, y), line, font=s, fill=SOFT); y += 58

# ---- the transformation, in display type --------------------------------
y += 110
big = font(150, 520)
before, after = "ut i bud", "út í búð"
# before: faint, struck through
bw = tw(d, before, big); x = (W - bw)//2
d.text((x, y), before, font=big, fill=FAINT)
d.line([(x-10, y+100), (x+bw+10, y+100)], fill=FAINT, width=9)
y += 205
# arrow
d.text(((W - tw(d, "↓", font(110,300)))//2, y-30), "↓", font=font(110,300), fill=FAINT)
y += 140
aw = tw(d, after, big); x = (W - aw)//2
d.text((x, y), after, font=big, fill=INK)
# accent marks highlighted: underline just the word
d.line([(x, y+195), (x+aw, y+195)], fill=INK, width=6)

# ---- the real keyboard, cropped, full width -----------------------------
cap = Image.open(HERE.parent / "v2/captures/02-raw.png").convert("RGB")
# capture is 1320x2868; text field top ≈ y=1640 in that space
crop = cap.crop((0, 1620, cap.width, cap.height))
scale = W / crop.width
crop = crop.resize((W, int(crop.height*scale)), Image.LANCZOS)
ky = H - crop.height
# soft shadow above the device slab so it reads as a surface, not a paste
shadow = Image.new("RGBA", (W, 260), (0,0,0,0))
sd = ImageDraw.Draw(shadow); sd.rectangle([0, 200, W, 260], fill=(0,0,0,70))
shadow = shadow.filter(ImageFilter.GaussianBlur(40))
img.paste(shadow, (0, ky-200), shadow)
img.paste(crop, (0, ky))
out = HERE / "proof-02.png"; img.save(out)
assert img.size == (W, H)

# ---- two-up vs v2 --------------------------------------------------------
v2 = Image.open(HERE.parent / "v2/export/en-US/02_accents.png").convert("RGB")
two = Image.new("RGB", (W*2+60, H+40), (0x22,0x22,0x22))
two.paste(v2, (20, 20)); two.paste(img, (W+40, 20))
two.resize((two.width//2, two.height//2), Image.LANCZOS).save(HERE / "proof-02-vs-v2.png")
# thumbnail check: what the listing looks like at App Store scale
img.resize((252, 547), Image.LANCZOS).save(HERE / "proof-02-thumb.png")
print("ok")
