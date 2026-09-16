import json, urllib.request, urllib.parse, sys
seen = {}
def q(url):
    return json.load(urllib.request.urlopen(url, timeout=30))
terms = ["keyboard","keyboard app","ai keyboard","custom keyboard","swipe keyboard","grammar keyboard","language keyboard","typing keyboard","emoji keyboard","bilingual keyboard","clipboard keyboard","fast typing"]
for country in ["us","gb"]:
    for t in terms:
        try:
            r = q(f"https://itunes.apple.com/search?term={urllib.parse.quote(t)}&entity=software&country={country}&limit=50")
        except Exception as e:
            print("ERR", t, e, file=sys.stderr); continue
        for a in r["results"]:
            if a["trackId"] in seen: continue
            genres = a.get("genres",[])
            if "Utilities" not in genres and "Productivity" not in genres: continue
            name = a["trackName"].lower()
            if "keyboard" not in name and "keyboard" not in (a.get("description","")[:300].lower()): continue
            seen[a["trackId"]] = dict(id=a["trackId"], name=a["trackName"], rating=a.get("averageUserRating"), n=a.get("userRatingCount",0), shots=len(a.get("screenshotUrls",[])), urls=a.get("screenshotUrls",[]), seller=a.get("sellerName"), sub=a.get("subtitle",""))
apps = sorted(seen.values(), key=lambda a: -a["n"])
json.dump(apps, open("apps.json","w"), indent=1)
for a in apps[:60]:
    print(f'{a["n"]:>8} {a["rating"] or 0:.1f} {a["shots"]:>2} {a["id"]} {a["name"][:50]}')
