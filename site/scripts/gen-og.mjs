// Generate the 1200×630 Open Graph / link-preview card into public/og.png.
// Reuses the same system-Chrome + puppeteer-core setup as screenshot.mjs so
// the card renders in the real San Francisco system font and the exact brand
// palette. The keycap product mark is inlined as base64 so the render is
// self-contained (no server / file-access flags needed).
//
//   node scripts/gen-og.mjs
import { readFile, writeFile } from "node:fs/promises";
import puppeteer from "puppeteer-core";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const KEYCAP = new URL(
  "../../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
  import.meta.url,
).pathname;
const OUT = new URL("../public/og.png", import.meta.url).pathname;

const keycap = `data:image/png;base64,${(await readFile(KEYCAP)).toString("base64")}`;

const html = `<!doctype html><html lang="is"><head><meta charset="utf-8"><style>
  * { margin: 0; box-sizing: border-box; }
  html, body { width: 1200px; height: 630px; }
  body {
    font-family: -apple-system, system-ui, "SF Pro Text", sans-serif;
    background: linear-gradient(135deg, #faf9f6 0%, #f1efe9 100%);
    color: #1c1b1a;
    display: flex; align-items: center; gap: 64px;
    padding: 80px 88px;
  }
  .copy { flex: 1; }
  .kicker {
    font-size: 22px; font-weight: 600; letter-spacing: 0.14em;
    text-transform: uppercase; color: #8a857c; margin-bottom: 22px;
  }
  .wordmark {
    font-size: 116px; font-weight: 700; letter-spacing: -0.03em;
    line-height: 0.98; color: #1c1b1a;
  }
  .pitch {
    font-size: 37px; font-weight: 500; letter-spacing: -0.01em;
    color: #55524d; margin-top: 22px; max-width: 15ch;
  }
  .chips { display: flex; gap: 14px; margin-top: 40px; }
  .chip {
    font-size: 22px; font-weight: 600; color: #55524d;
    background: rgba(28,27,26,0.05); border: 1px solid #e3e0d8;
    padding: 12px 22px; border-radius: 999px;
  }
  .mark {
    width: 384px; height: 384px; flex: none; border-radius: 84px;
    box-shadow: 0 40px 80px -28px rgba(28,27,26,0.42);
  }
  .url {
    position: absolute; bottom: 68px; left: 88px;
    font-size: 24px; font-weight: 600; color: #8a857c;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
</style></head><body>
  <div class="copy">
    <div class="kicker">iOS · Íslenska + Enska</div>
    <div class="wordmark">Lyklaborð</div>
    <div class="pitch">Íslenskt lyklaborð sem skilur íslensku.</div>
    <div class="chips">
      <span class="chip">Ókeypis</span>
      <span class="chip">Opið (MIT)</span>
      <span class="chip">Engin gagnasöfnun</span>
    </div>
  </div>
  <img class="mark" src="${keycap}" alt="" />
  <div class="url">lyklabord.solberg.is</div>
</body></html>`;

const browser = await puppeteer.launch({
  executablePath: CHROME,
  args: ["--force-color-profile=srgb", "--hide-scrollbars"],
});
const page = await browser.newPage();
await page.setViewport({ width: 1200, height: 630, deviceScaleFactor: 2 });
await page.setContent(html, { waitUntil: "networkidle0" });
const buf = await page.screenshot({
  clip: { x: 0, y: 0, width: 1200, height: 630 },
  type: "png",
});
await writeFile(OUT, buf);
await browser.close();
console.log(`Wrote ${OUT} (1200×630 @2x)`);
