#!/usr/bin/env python3
"""v3 renderer — flat compose of real simulator captures on the paper stage.
Style A ("crop, don't frame"). Reads copy from ../copy.md via the v2 parser.
Usage: render.py  → v3/out/en-US/0N_*.png + v3/out/sheet.png"""
import pathlib, sys, importlib.util
from PIL import Image, ImageDraw, ImageFont, ImageFilter
HERE=pathlib.Path(__file__).parent; CAPS=HERE.parent/"v2/captures"; OUT=HERE/"out"
import re
COPY=HERE.parent/"copy.md"; SLUGS={1:"hero",2:"accents",3:"blend",4:"bin",5:"dictionary",6:"privacy"}
LOCALES={"is":"is-IS","en":"en-US"}; SF="/System/Library/Fonts/SFNS.ttf"
def font(size,weight=400):
    f=ImageFont.truetype(SF,size)
    try: f.set_variation_by_axes([100,max(17,min(96,size*0.55)),400,weight])
    except Exception: pass
    return f
def parse_copy():
    shots={}; cur=None
    for line in COPY.read_text(encoding="utf-8").splitlines():
        m=re.match(r"^##\s+(\d+)\s",line)
        if m: cur=int(m.group(1)); shots[cur]={"is-IS":{},"en-US":{}}; continue
        if cur is None: continue
        m=re.match(r"^-\s+(Title|Sub|Meta|Pitch)\s+\((is|en)\):\s+(.*)$",line)
        if m:
            kind,loc,val=m.group(1).lower(),LOCALES[m.group(2)],m.group(3)
            shots[cur][loc][kind]=[t.strip() for t in val.split(" / ")] if kind=="title" else val
    return shots
W,H=1260,2736
PAPER=(0xFA,0xF9,0xF6); INK=(0x1C,0x1B,0x1A); SOFT=(0x55,0x52,0x4D); FAINT=(0xA5,0xA1,0x9A)
def tw(d,s,f): b=d.textbbox((0,0),s,font=f); return b[2]-b[0]
def center(d,s,f,y,fill): d.text(((W-tw(d,s,f))//2,y),s,font=f,fill=fill)
def shadow_band(img,y):
    s=Image.new("RGBA",(W,260),(0,0,0,0)); ImageDraw.Draw(s).rectangle([0,200,W,260],fill=(0,0,0,70))
    s=s.filter(ImageFilter.GaussianBlur(40)); img.paste(s,(0,y-200),s)
def find_field_top(cap):
    """Top of the host text field. Scan the LEFT edge column (x=6, inside
    the field's side margin, so the white host background runs down to the
    keyboard's grey top edge), find the keyboard top, then back off by the
    field height plus margin (screenshot-mode host layout)."""
    px=cap.load(); x=6
    for y in range(cap.height//2, cap.height):
        r,g,b=px[x,y][:3]
        if r<235 and g<235: return max(0, y-270)
    return int(cap.height*0.56)
def scrub_host_squiggle(c):
    """The ReplayHost TextField draws UIKit's red spell-check underline under
    slettur ("deploya"). That is the HOST's, not the keyboard's, and reads as
    the keyboard flagging the word — paint those red dots back to white."""
    px=c.load()
    for y in range(c.height):
        for x in range(c.width):
            r,g,b=px[x,y][:3]
            if r-g>28 and r-b>28 and r>140: px[x,y]=(255,255,255)
    return c
def keyboard(cap):
    top=find_field_top(cap); c=scrub_host_squiggle(cap.crop((0,top,cap.width,cap.height))); sc=W/c.width
    return c.resize((W,int(c.height*sc)),Image.LANCZOS)
def caption(d,title,sub,y=190,tsize=126,ssize=46):
    sub=sub.replace("`","")
    for l in title: center(d,l,font(tsize,760),y,INK); y+=int(tsize*1.1)
    y+=40
    for l in compose_wrap(d,sub,font(ssize,450),W-240): center(d,l,font(ssize,450),y,SOFT); y+=int(ssize*1.28)
    return y
def compose_wrap(d,text,f,maxw):
    words=text.split(); lines=[]; cur=""
    for w in words:
        t=(cur+" "+w).strip()
        if tw(d,t,f)<=maxw: cur=t
        else: lines.append(cur); cur=w
    if cur: lines.append(cur)
    return lines
def transformation(d,y,before,after):
    big=font(150,520); bw=tw(d,before,big); x=(W-bw)//2
    d.text((x,y),before,font=big,fill=FAINT); d.line([(x-10,y+100),(x+bw+10,y+100)],fill=FAINT,width=9); y+=205
    center(d,"↓",font(110,300),y-30,FAINT); y+=140
    aw=tw(d,after,big); x=(W-aw)//2; d.text((x,y),after,font=big,fill=INK); d.line([(x,y+195),(x+aw,y+195)],fill=INK,width=6)

BRAND_FONT=pathlib.Path.home()/"Library/Fonts/UniversLTStd-CnObl.otf"   # licensed; not vendored
def keycap(ch, size):
    """Blank keycap asset + glyph drawn in the brand face (Univers Condensed
    Oblique, the same font as the app icon and site keycap, commits 39ec938 /
    95f3099), UPPERCASE like the brand Ð. The GPT-drawn Icelandic glyphs were
    wrong; the blank is generated, the letter is ours. Legend sits low-left on
    the face like the reference Ð asset."""
    KC=HERE.parent.parent/"assets/keycaps"
    cap=Image.open(KC/"blank.png").convert("RGBA"); cap=cap.crop(cap.getbbox()).resize((1024,1024),Image.LANCZOS)
    if not BRAND_FONT.exists(): raise SystemExit(f"brand font missing: {BRAND_FONT}")
    d=ImageDraw.Draw(cap); f=ImageFont.truetype(str(BRAND_FONT),560)
    ch=ch.upper()
    bb=d.textbbox((0,0),ch,font=f); w,h=bb[2]-bb[0],bb[3]-bb[1]
    # reference Ð: legend centre ≈ (0.37, 0.55) of the face
    x=int(1024*0.36)-w//2-bb[0]; y=int(1024*0.56)-h//2-bb[1]
    d.text((x,y),ch,font=f,fill=(0x33,0x32,0x30,255))
    return cap.resize((size,size),Image.LANCZOS)

def shot(n,loc,title,sub,cap_name,transform=None,keys=False,popkeys=None):
    img=Image.new("RGB",(W,H),PAPER); d=ImageDraw.Draw(img)
    y=caption(d,title,sub)
    if transform: transformation(d,y+110,*transform)
    if keys:
        kw=250; gap=30; x0=(W-(kw*4+gap*3))//2; y0=y+130
        for i,ch in enumerate("ðæöþ"):
            cap=keycap(ch,kw)
            sh=Image.new("RGBA",(kw+80,kw+100),(0,0,0,0)); ImageDraw.Draw(sh).rounded_rectangle([40,60,kw+40,kw+60],36,fill=(0,0,0,55))
            sh=sh.filter(ImageFilter.GaussianBlur(26)); x=x0+i*(kw+gap)
            img.paste(sh,(x-40,y0-30),sh); img.paste(cap,(x,y0),cap)
    k=keyboard(Image.open(CAPS/cap_name).convert("RGB")); ky=H-k.height
    shadow_band(img,ky); img.paste(k,(0,ky))
    if popkeys:
        # Physical keycaps "popping" out of the keyboard: drawn AFTER the
        # slab so they straddle its top edge (about 60% above, 40% over it).
        kw=240; gap=28
        total=len(popkeys)*kw+(len(popkeys)-1)*gap; x0=(W-total)//2
        for i,(name,rot,dy) in enumerate(popkeys):
            cap=keycap(name,kw).rotate(rot,expand=True,resample=Image.BICUBIC)
            x=x0+i*(kw+gap)-(cap.width-kw)//2; yy=ky-int(kw*0.6)-dy
            sh=Image.new("RGBA",(cap.width+80,cap.height+80),(0,0,0,0))
            ImageDraw.Draw(sh).rounded_rectangle([50,70,cap.width+30,cap.height+50],40,fill=(0,0,0,70))
            sh=sh.filter(ImageFilter.GaussianBlur(30)); img.paste(sh,(x-40,yy-20),sh); img.paste(cap,(x,yy),cap)
    return img
copy=parse_copy()
plan={1:dict(cap="01-raw.png",keys=True),2:dict(cap="02-raw.png",transform=("ut i bud","út í búð"),popkeys=[("ú",8,40),("í",-5,0),("ð",6,30)]),
      3:dict(cap="03-raw.png"),4:dict(cap="04-raw.png",transform=("fra Akureyr","frá Akureyri"))}
for loc in ["en-US","is-IS"]:
    (OUT/loc).mkdir(parents=True,exist_ok=True)
    for n,p in plan.items():
        if not (CAPS/p["cap"]).exists(): continue
        c=copy[n][loc]; im=shot(n,loc,c["title"],c["sub"],p["cap"],p.get("transform"),p.get("keys",False),p.get("popkeys"))
        im.save(OUT/loc/f"{n:02d}_{SLUGS[n]}.png")
ims=[Image.open(p) for p in sorted((OUT/"en-US").glob("*.png"))]
s=Image.new("RGB",(len(ims)*(W//3+20)+20,H//3+40),(0x22,0x22,0x22)); x=20
for im in ims: s.paste(im.resize((W//3,H//3),Image.LANCZOS),(x,20)); x+=W//3+20
s.save(OUT/"sheet.png"); print("rendered",len(ims))
