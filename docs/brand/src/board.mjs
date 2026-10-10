import { createRequire } from 'module'; import fs from 'fs'; import os from 'os'; import path from 'path'; import { fileURLToPath } from 'url';
import * as M from './mark.mjs'; import { iconSVG, PAL } from './icons.mjs';
const require = createRequire(path.join(os.homedir(), '.cache/distro-deck/node_modules/'));
const { chromium } = require('playwright');
// node board.mjs [out.png]: redraws ../octopus-directions.png unless another path is given.
const here = path.dirname(fileURLToPath(import.meta.url));
const outPNG = process.argv[2] ?? path.join(here, '../octopus-directions.png');
const b64 = f => 'data:image/png;base64,' + fs.readFileSync(path.join(here, f)).toString('base64');
const svgURL = s => 'data:image/svg+xml;base64,' + Buffer.from(s).toString('base64');
let n = 0; const u = () => 'u' + n++;

const glyphSVG = (eyes, color = '#fff') => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${M.glyphVB}" width="450" height="450">${M.glyph({ color, id: u(), eyes })}</svg>`;
const iconFor = k => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">${iconSVG(k, 1024, u()).replace(/^<svg[^>]*>|<\/svg>$/g, '')}</svg>`;

const DIR = [
  { k: 'sunset', title: 'Sunset', note: 'Warm bands, from your OpenSea Pro reference', chips: ['#EE4F4C', '#F99442', '#FCBC50'] },
  { k: 'coral', title: 'Coral', note: 'Flat octopus on sand, the friendliest', chips: ['#EE5F3B', '#FFF6EC', '#F9E7D3'] },
  { k: 'ink', title: 'Deep sea', note: 'Line octopus on navy, the calmest', chips: ['#16465A', '#0D2B3B', '#FFFFFF'] },
];
const data = {
  alert: b64('assets/alert-stopall.png'),
  bar: b64('assets/menubar.png'),
  icons: Object.fromEntries(DIR.map(d => [d.k, svgURL(iconFor(d.k))])),
  glyphOpen: svgURL(glyphSVG('open')), glyphClosed: svgURL(glyphSVG('closed')),
};

const col = d => `<section class="col">
  <h2>${d.title}</h2><p class="note">${d.note}</p>
  <div class="hero">${iconSVG(d.k, 216, u())}</div>
  <div class="sizes">${[64, 32, 16].map(s => iconSVG(d.k, s, u())).join('')}</div>
  <div class="lockup">${iconSVG(d.k, 44, u())}<span class="wm">Loco Loco</span></div>
  <img class="alert" data-k="${d.k}" width="288" height="230">
  <div class="chips">${d.chips.map(c => `<span class="chip"><i style="background:${c}"></i>${c}</span>`).join('')}</div>
</section>`;

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
@font-face { font-family: 'SF Pro Rounded'; src: url('file:///System/Library/Fonts/SFNSRounded.ttf'); font-weight: 100 900; }
* { box-sizing: border-box; }
body { margin: 0; background: #fff; color: #1d1d1f; font: 13px/1.4 system-ui, BlinkMacSystemFont, sans-serif; -webkit-font-smoothing: antialiased; }
main { width: 1200px; padding: 48px 56px 56px; }
h1 { font: 600 24px/1.2 'SF Pro Rounded'; margin: 0 0 32px; letter-spacing: -0.2px; }
.cols { display: grid; grid-template-columns: repeat(3, 1fr); gap: 40px; }
.col { min-width: 0; }
h2 { font: 600 17px/1.2 'SF Pro Rounded'; margin: 0; }
.note { margin: 4px 0 20px; color: #6e6e73; }
.hero { height: 216px; margin-left: -21px; }
.sizes { display: flex; align-items: center; gap: 20px; height: 64px; margin: 12px 0 24px -6px; }
.lockup { display: flex; align-items: center; gap: 8px; margin: 0 0 24px -4px; }
.wm { font: 600 26px/1 'SF Pro Rounded'; letter-spacing: -0.3px; }
.alert { display: block; margin: 0 0 28px; box-shadow: 0 0 0 0.5px rgba(0,0,0,.16), 0 10px 28px rgba(0,0,0,.12); }
.chips { display: flex; gap: 16px; }
.chip { display: inline-flex; align-items: center; gap: 6px; font: 12px ui-monospace, SFMono-Regular, monospace; color: #424245; }
.chip i { width: 14px; height: 14px; border-radius: 4px; box-shadow: inset 0 0 0 0.5px rgba(0,0,0,.18); }
.bar { margin-top: 48px; border-top: 0.5px solid #d2d2d7; padding-top: 28px; }
.bar .note { margin-bottom: 16px; }
.strip { display: grid; grid-template-columns: 140px auto; align-items: center; row-gap: 12px; }
.strip span { color: #6e6e73; }
.strip canvas { border-radius: 6px; }
</style></head><body><main>
<h1>Loco Loco, octopus identity</h1>
<div class="cols">${DIR.map(col).join('')}</div>
<div class="bar"><h2>Menu bar</h2><p class="note">Same glyph in all three. macOS tints it to match the bar. Shown at 2×.</p>
<div class="strip"><span>Now</span><canvas id="now"></canvas><span>Octopus</span><canvas id="run"></canvas><span>Nothing running</span><canvas id="idle"></canvas></div></div>
</main>
<script>
const D = ${JSON.stringify(data)};
const load = src => new Promise(r => { const i = new Image(); i.onload = () => r(i); i.src = src; });
const luma = (d, i) => 0.3 * d[i] + 0.59 * d[i + 1] + 0.11 * d[i + 2];
async function alerts() {
  const a = await load(D.alert);
  const c0 = document.createElement('canvas'); c0.width = a.width; c0.height = a.height; const x0 = c0.getContext('2d'); x0.drawImage(a, 0, 0);
  const px = x0.getImageData(0, 0, a.width, a.height).data;
  let minX = 1e9, minY = 1e9, maxX = 0, maxY = 0;
  for (let y = 60; y < 230; y++) for (let x = 200; x < 440; x++) { const i = (y * a.width + x) * 4; if (luma(px, i) < 110) { minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y); } }
  const bw = maxX - minX + 1, cx = (minX + maxX + 1) / 2, cy = (minY + maxY + 1) / 2, canvasS = bw / (824 / 1024);
  const bgi = (70 * a.width + 230) * 4, bg = 'rgb(' + px[bgi] + ',' + px[bgi + 1] + ',' + px[bgi + 2] + ')';
  window.__alert = { minX, minY, maxX, maxY, bg };
  const isBody = (x, y) => { const i = (y * a.width + x) * 4; return Math.abs(px[i] - px[bgi]) <= 2 && Math.abs(px[i + 1] - px[bgi + 1]) <= 2 && Math.abs(px[i + 2] - px[bgi + 2]) <= 2; };
  const my = 232; let l = 320; while (isBody(l - 1, my)) l--; let r = 320; while (isBody(r + 1, my)) r++; let t = 225; while (isBody(150, t - 1)) t--; let bt = 370; while (isBody(320, bt + 1)) bt++;
  let rc = l; while (!isBody(rc, t)) rc++; window.__inset = rc - l;
  window.__body = { l, t, w: r - l + 1, h: bt - t + 1, r: 48 };
  for (const img of document.querySelectorAll('img.alert')) {
    const c = document.createElement('canvas'); c.width = a.width; c.height = a.height; const x = c.getContext('2d'); x.drawImage(a, 0, 0);
    x.fillStyle = bg; x.fillRect(minX - 22, minY - 16, bw + 44, maxY - minY + 1 + 44);
    const ic = await load(D.icons[img.dataset.k]);
    x.drawImage(ic, cx - canvasS / 2, cy - canvasS / 2, canvasS, canvasS);
    const B = window.__body; const o = document.createElement('canvas'); o.width = B.w; o.height = B.h; o.getContext('2d').drawImage(c, B.l, B.t, B.w, B.h, 0, 0, B.w, B.h);
    img.src = o.toDataURL(); img.width = B.w / 2; img.height = B.h / 2; img.style.borderRadius = (B.r / 2) + 'px';
  }
}
async function bars() {
  const b = await load(D.bar), X0 = 180, W = 550;
  const base = document.createElement('canvas'); base.width = b.width; base.height = b.height; const bx = base.getContext('2d'); bx.drawImage(b, 0, 0);
  const px = bx.getImageData(0, 0, b.width, b.height).data;
  let H = 0; while (H < b.height && luma(px, (H * b.width + 20) * 4) < 200) H++; window.__H = H;
  const lit = []; for (let x = 200; x < 310; x++) { let on = false; for (let y = 4; y < H - 4; y++) if (luma(px, (y * b.width + x) * 4) > 205) on = true; lit.push(on); }
  const runs = []; let s = -1; lit.forEach((on, i) => { if (on && s < 0) s = i; if (!on && s >= 0) { runs.push([s + 200, i + 199]); s = -1; } });
  const [icon, digit] = runs; window.__bar = runs;
  let gTop = 99, gBot = 0; for (let y = 0; y < H; y++) for (let x = icon[0]; x <= icon[1]; x++) if (luma(px, (y * b.width + x) * 4) > 205) { gTop = Math.min(gTop, y); gBot = Math.max(gBot, y); }
  window.__glyphBox = [gTop, gBot];
  const L = icon[0] - 6 - X0, R = digit[1] + 6 - X0, gc = (gTop + gBot + 1) / 2;
  function paint(id, glyphSrc, withDigit) {
    return load(glyphSrc).then(g => {
      const c = document.getElementById(id); c.width = W; c.height = H; c.style.width = W + 'px'; c.style.height = H + 'px'; const x = c.getContext('2d');
      x.drawImage(base, X0, 0, W, H, 0, 0, W, H);
      if (!glyphSrc) return;
      const img = x.getImageData(0, 0, W, H), d = img.data;
      for (let y = 0; y < H; y++) for (let xx = L; xx <= R; xx++) { const t = (xx - L) / (R - L); for (let k = 0; k < 4; k++) d[(y * W + xx) * 4 + k] = d[(y * W + L - 1) * 4 + k] * (1 - t) + d[(y * W + R + 1) * 4 + k] * t; }
      x.putImageData(img, 0, 0);
      const gh = 32, gy = Math.round(gc - gh / 2); x.drawImage(g, icon[0] - X0, gy, gh, gh);
      if (withDigit) { const gw = Math.round(gh * (452 - 60) / 450); const nx = icon[0] - X0 + gw + (digit[0] - icon[1]); x.drawImage(base, digit[0] - 2, 0, digit[1] - digit[0] + 5, H, nx - 2, 0, digit[1] - digit[0] + 5, H); }
    });
  }
  const c = document.getElementById('now'); c.width = W; c.height = H; c.style.width = W + 'px'; c.style.height = H + 'px'; c.getContext('2d').drawImage(base, X0, 0, W, H, 0, 0, W, H);
  await paint('run', D.glyphOpen, true); await paint('idle', D.glyphClosed, false);
}
window.__done = Promise.all([document.fonts.ready, alerts(), bars()]).then(() => true);
</script></body></html>`;
const htmlPath = path.join(os.tmpdir(), 'loco-octopus-board.html');
fs.writeFileSync(htmlPath, html);
const br = await chromium.launch(); const p = await br.newPage({ viewport: { width: 1200, height: 900 }, deviceScaleFactor: 2 });
p.on('console', m => console.log('console:', m.text())); p.on('pageerror', e => console.log('pageerror:', e.message));
await p.goto('file://' + htmlPath); await p.evaluate(() => window.__done);
console.log(JSON.stringify(await p.evaluate(() => ({ body: window.__body, inset: window.__inset }))));
await p.screenshot({ path: outPNG, fullPage: true }); await br.close();
fs.rmSync(htmlPath);
