import json, urllib.request, urllib.parse, sys, os, re, subprocess
from concurrent.futures import ThreadPoolExecutor
def q(url): return json.load(urllib.request.urlopen(url, timeout=30))
named = ["Typewise keyboard","Fleksy keyboard","Yandex Keyboard","Simeji","Wispr Flow","TypeAI keyboard","Grammarly keyboard","Microsoft SwiftKey","Gboard","CorrectMe grammar keyboard","Kal Keyboard Amharic","Georgian Keyboard","Persian keyboard","Bangla keyboard","Welsh keyboard","Faroese keyboard","Tamil keyboard","Ukrainian keyboard","Irish keyboard","Greek keyboard","Icelandic keyboard","Hindi keyboard","Sámi keyboard","Vietnamese keyboard Laban","Kurdish keyboard","Malayalam keyboard","Arabic keyboard","Estonian keyboard","Bobble keyboard","Desh keyboard","Ridmik keyboard","Anysoft keyboard","Unexpected keyboard","Thumbly keyboard","Wordtune keyboard","Paragraph AI keyboard","Rizz keyboard"]
picked = {}
for t in named:
    try: r = q(f"https://itunes.apple.com/search?term={urllib.parse.quote(t)}&entity=software&country=us&limit=6")
    except Exception as e: print("ERR",t,e,file=sys.stderr); continue
    for a in r["results"]:
        if not a.get("screenshotUrls"): continue
        d = (a.get("description","")[:400]+a["trackName"]).lower()
        if "keyboard" not in d and "typing" not in d: continue
        picked.setdefault(a["trackId"], dict(id=a["trackId"], name=a["trackName"], rating=a.get("averageUserRating"), n=a.get("userRatingCount",0), urls=a["screenshotUrls"], term=t, sub=a.get("subtitle","")))
        break
# also fold in earlier 'real keyboard' picks from apps.json
for a in json.load(open("apps.json")):
    if a["id"] in (1158877342,911813648,1091700242,6448661220,6497229487,1193750579,1125783830,900035450,1035199024,1103138272,6444097535,1502909594,6670622037):
        picked.setdefault(a["id"], dict(id=a["id"], name=a["name"], rating=a["rating"], n=a["n"], urls=a["urls"], term="sweep", sub=a["sub"]))
json.dump(list(picked.values()), open("picked.json","w"), indent=1)
out = "comp"; os.makedirs(out, exist_ok=True)
def slug(s): return re.sub(r"[^a-z0-9]+","-",s.lower()).strip("-")[:40]
jobs=[]
for a in picked.values():
    d = f"{out}/{slug(a['name'])}"; os.makedirs(d, exist_ok=True)
    json.dump(a, open(f"{d}/meta.json","w"), indent=1)
    for i,u in enumerate(a["urls"],1):
        ext = "png" if u.endswith(".png") else "jpg"
        jobs.append((u, f"{d}/{i:02d}.{ext}"))
def dl(j):
    u,p=j
    if os.path.exists(p): return
    try: urllib.request.urlretrieve(u,p)
    except Exception as e: print("DL ERR",p,e,file=sys.stderr)
with ThreadPoolExecutor(12) as ex: list(ex.map(dl,jobs))
for a in sorted(picked.values(), key=lambda a:-a["n"]):
    print(f'{a["n"]:>8} {a["rating"] or 0:.1f} {len(a["urls"]):>2} {a["name"][:45]:45} [{a["term"]}]')
