#!/usr/bin/env python3
"""v3 style options — four directions for shot 2 (accents), all from the real
simulator capture, all 1260x2736. Output: v3/options/A..D.png + options.png sheet."""
import pathlib
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = pathlib.Path(__file__).parent; OUT = HERE / "options"; OUT.mkdir(exist_ok=True)
W, H = 1260, 2736
PAPER=(0xFA,0xF9,0xF6); RAISED=(0xF1,0xEF,0xE9); INK=(0x1C,0x1B,0x1A); INK2=(0x2A,0x29,0x26)
SOFT=(0x55,0x52,0x4D); FAINT=(0xA5,0xA1,0x9A); CREAM=(0xE8,0xE5,0xE0); BLUE=(0x0A,0x7A,0xFF)
SF="/System/Library/Fonts/SFNS.ttf"
CAP = Image.open(HERE.parent/"v2/captures/02-raw.png").convert("RGB")   # 1320x2868

def font(size, weight=400):
    f=ImageFont.truetype(SF,size)
    try: f.set_variation_by_axes([100,max(17,min(96,size*0.55)),400,weight])
    except Exception: pass
    return f
def tw(d,s,f): b=d.textbbox((0,0),s,font=f); return b[2]-b[0]
def center(d,s,f,y,fill): d.text(((W-tw(d,s,f))//2,y),s,font=f,fill=fill)
def rounded_top(im, r):
    m=Image.new("L",im.size,0); ImageDraw.Draw(m).rounded_rectangle([0,0,im.width-1,im.height+r],r,fill=255); return m
def shadow_band(img, y, alpha=70, h=260, blur=40):
    s=Image.new("RGBA",(W,h),(0,0,0,0)); ImageDraw.Draw(s).rectangle([0,h-60,W,h],fill=(0,0,0,alpha))
    s=s.filter(ImageFilter.GaussianBlur(blur)); img.paste(s,(0,y-h+60),s)
def kb(top=1620, width=W):
    c=CAP.crop((0,top,CAP.width,CAP.height)); sc=width/c.width
    return c.resize((width,int(c.height*sc)),Image.LANCZOS)
def callout(d, img, text, xy, big=True):
    """SwiftKey-style lifted chip with the corrected word."""
    f=font(120 if big else 88, 600); pad=44
    w=tw(d,text,f)+2*pad; h=(150 if big else 120)+pad
    x,y=xy; x-=w//2
    sh=Image.new("RGBA",(w+120,h+120),(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([60,70,w+60,h+60],40,fill=(0,0,0,90))
    sh=sh.filter(ImageFilter.GaussianBlur(30)); img.paste(sh,(x-60,y-60),sh)
    d.rounded_rectangle([x,y,x+w,y+h],40,fill="white",outline=(0xD8,0xD5,0xCF),width=3)
    d.text((x+pad,y+pad//2+8),text,font=f,fill=INK)
    return x,y,w,h

# ---------------- A · Paper editorial (proof frame) ----------------------
def A():
    img=Image.new("RGB",(W,H),PAPER); d=ImageDraw.Draw(img); y=190
    for l in ["Type","accent-naked"]: center(d,l,font(126,760),y,INK); y+=138
    y+=40
    for l in ["Dropping accents is an input method,","not a typo."]: center(d,l,font(46,450),y,SOFT); y+=58
    y+=110; big=font(150,520)
    bw=tw(d,"ut i bud",big); x=(W-bw)//2; d.text((x,y),"ut i bud",font=big,fill=FAINT)
    d.line([(x-10,y+100),(x+bw+10,y+100)],fill=FAINT,width=9); y+=205
    center(d,"↓",font(110,300),y-30,FAINT); y+=140
    aw=tw(d,"út í búð",big); x=(W-aw)//2; d.text((x,y),"út í búð",font=big,fill=INK); d.line([(x,y+195),(x+aw,y+195)],fill=INK,width=6)
    k=kb(); ky=H-k.height; shadow_band(img,ky); img.paste(k,(0,ky)); return img

# ---------------- B · Bleed + callout (SwiftKey #3 / Kurdish #3) ---------
def B():
    img=Image.new("RGB",(W,H),PAPER); d=ImageDraw.Draw(img)
    # keyboard scaled to 1.28x and bled off both sides, sits mid-frame
    k=kb(top=1540,width=int(W*1.10)); kx=-(k.width-W)//2; ky=H-k.height+40
    slab=Image.new("RGB",(W,k.height),PAPER); slab.paste(k,(kx,0))
    shadow_band(img,ky,alpha=90); img.paste(slab,(0,ky))
    # lifted correction chip over the suggestion row, with arrow from the typed word
    cx,cy,cw,ch=callout(d,img,"út í búð",(W//2, ky-330))
    d.line([(W//2, cy+ch+10),(W//2, ky+120)],fill=BLUE,width=10)
    d.polygon([(W//2-28,ky+110),(W//2+28,ky+110),(W//2,ky+160)],fill=BLUE)
    y=210
    for l in ["Broddarnir","koma sjálfir."]: center(d,l,font(140,780),y,INK); y+=150
    y+=40
    for l in ["Type ut i bud. Get út í búð.","No accent hunting, no layout switching."]: center(d,l,font(48,450),y,SOFT); y+=60
    return img

# ---------------- C · Ink stage (dark, cream type, keyboard slab) --------
def C():
    img=Image.new("RGB",(W,H),INK); d=ImageDraw.Draw(img)
    # subtle radial lift
    g=Image.new("L",(W,H),0); gd=ImageDraw.Draw(g); gd.ellipse([-400,-300,W+400,1400],fill=60); g=g.filter(ImageFilter.GaussianBlur(300))
    img.paste(Image.new("RGB",(W,H),INK2),(0,0),g); d=ImageDraw.Draw(img)
    y=200
    for l in ["Type","accent-naked"]: center(d,l,font(126,760),y,CREAM); y+=138
    y+=40
    for l in ["Dropping accents is an input method,","not a typo."]: center(d,l,font(46,450),y,(0xB5,0xB1,0xAA)); y+=58
    y+=120; big=font(160,560)
    center(d,"ut i bud",big,y,(0x6E,0x6A,0x64)); y+=210
    center(d,"út í búð",big,y,CREAM)
    # keyboard in a rounded device slab, no tilt, 92% width
    k=kb(top=1560,width=int(W*0.92)); kx=(W-k.width)//2; ky=H-k.height+60
    m=rounded_top(k,90); img.paste(k,(kx,ky),m)
    d=ImageDraw.Draw(img); d.rounded_rectangle([kx-14,ky-14,kx+k.width+14,H+200],104,outline=(0x3A,0x38,0x34),width=14)
    return img

# ---------------- D · Keys as brand mark (hero-style, type-led) ----------
def D():
    img=Image.new("RGB",(W,H),PAPER); d=ImageDraw.Draw(img)
    # giant ð æ ö þ keycaps as the graphic
    keys=["ð","æ","ö","þ"]; kw=250; gap=36; x0=(W-(kw*4+gap*3))//2; y0=1010
    for i,ch in enumerate(keys):
        x=x0+i*(kw+gap)
        sh=Image.new("RGBA",(kw+80,kw+100),(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([40,60,kw+40,kw+60],36,fill=(0,0,0,60))
        sh=sh.filter(ImageFilter.GaussianBlur(24)); img.paste(sh,(x-40,y0-40),sh)
        d.rounded_rectangle([x,y0,x+kw,y0+kw],36,fill="white",outline=(0xD8,0xD5,0xCF),width=3)
        f=font(150,420); d.text((x+(kw-tw(d,ch,f))//2,y0+30),ch,font=f,fill=INK)
    y=210
    for l in ["The keyboard that","knows Icelandic"]: center(d,l,font(126,760),y,INK); y+=138
    y+=40
    for l in ["Free. Open source. Nothing leaves your phone."]: center(d,l,font(46,450),y,SOFT); y+=58
    k=kb(top=1560); ky=H-k.height+120; shadow_band(img,ky); img.paste(k,(0,ky))
    return img

imgs={}
for name,fn in [("A",A),("B",B),("C",C),("D",D)]:
    im=fn(); assert im.size==(W,H); im.save(OUT/f"{name}.png"); imgs[name]=im
sheet=Image.new("RGB",(4*W+5*40, H+80),(0x22,0x22,0x22)); x=40
for n,im in imgs.items(): sheet.paste(im,(x,40)); x+=W+40
sheet.resize((sheet.width//3,sheet.height//3),Image.LANCZOS).save(OUT/"options.png")
# thumbnail row: how the listing reads at store scale
th=Image.new("RGB",(4*272+40,567),(0x22,0x22,0x22)); x=20
for im in imgs.values(): th.paste(im.resize((252,547),Image.LANCZOS),(x,10)); x+=272
th.save(OUT/"options-thumbs.png"); print("ok")
