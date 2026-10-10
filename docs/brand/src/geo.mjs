// Bezier-based octopus geometry (512 grid). Paths use only M, C, L.
const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
export function parse(d) {
  const t = d.match(/[MCL]|-?\d*\.?\d+(?:e-?\d+)?/g); let i = 0, cmd, cur; const segs = [];
  while (i < t.length) {
    if (/[MCL]/.test(t[i])) cmd = t[i++];
    if (cmd === 'M') cur = [+t[i++], +t[i++]];
    else if (cmd === 'L') { const p = [+t[i++], +t[i++]]; segs.push([cur, lerp(cur, p, 1 / 3), lerp(cur, p, 2 / 3), p]); cur = p; }
    else { const a = [+t[i++], +t[i++]], b = [+t[i++], +t[i++]], p = [+t[i++], +t[i++]]; segs.push([cur, a, b, p]); cur = p; }
  }
  return segs;
}
const bz = ([p0, p1, p2, p3], s) => { const u = 1 - s; return [0, 1].map(k => u*u*u*p0[k] + 3*u*u*s*p1[k] + 3*u*s*s*p2[k] + s*s*s*p3[k]); };
export function sample(d, n = 80) { const out = []; for (const sg of parse(d)) for (let k = out.length ? 1 : 0; k <= n; k++) out.push(bz(sg, k / n)); return out; }
const f2 = v => Math.round(v * 100) / 100;
export const poly = (pts, close) => 'M' + pts.map(p => f2(p[0]) + ' ' + f2(p[1])).join('L') + (close ? 'Z' : '');
export function taper(d, r0, r1, ease = 1) {
  const c = sample(d); const len = [0];
  for (let i = 1; i < c.length; i++) len.push(len[i - 1] + Math.hypot(c[i][0] - c[i - 1][0], c[i][1] - c[i - 1][1]));
  const L = len.at(-1), A = [], B = [];
  for (let i = 0; i < c.length; i++) {
    const a = c[Math.max(0, i - 1)], b = c[Math.min(c.length - 1, i + 1)];
    let tx = b[0] - a[0], ty = b[1] - a[1]; const m = Math.hypot(tx, ty) || 1; tx /= m; ty /= m;
    const r = r0 + (r1 - r0) * Math.pow(len[i] / L, ease);
    A.push([c[i][0] - ty * r, c[i][1] + tx * r]); B.push([c[i][0] + ty * r, c[i][1] - tx * r]);
  }
  const e = c.at(-1), q = c.at(-3), ang = Math.atan2(e[1] - q[1], e[0] - q[0]), cap = [];
  for (let k = 1; k < 24; k++) { const th = ang + Math.PI / 2 - Math.PI * k / 24; cap.push([e[0] + Math.cos(th) * r1, e[1] + Math.sin(th) * r1]); }
  const s = c[0], s2 = c[2], ang0 = Math.atan2(s[1] - s2[1], s[0] - s2[0]), cap0 = [];
  for (let k = 1; k < 24; k++) { const th = ang0 + Math.PI / 2 - Math.PI * k / 24; cap0.push([s[0] + Math.cos(th) * r0, s[1] + Math.sin(th) * r0]); }
  return poly([...A, ...cap, ...B.reverse(), ...cap0], true);
}
export const mirror = d => d.replace(/(-?\d*\.?\d+)\s+(-?\d*\.?\d+)/g, (m, x, y) => `${f2(512 - +x)} ${y}`);
export const mirrorW = (d, w) => d.replace(/(-?\d*\.?\d+)\s+(-?\d*\.?\d+)/g, (m, x, y) => `${f2(w - +x)} ${y}`);
