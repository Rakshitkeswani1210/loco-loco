import { taper, mirror } from './geo.mjs';
// Final octopus (P4), 512 grid.
export const head = 'M256 60C336 60 392 116 392 196C392 248 368 284 332 302L180 302C144 284 120 248 120 196C120 116 176 60 256 60Z';
export const eyes = [[212, 218], [300, 218]];
const outerL = 'M194 270C160 296 104 290 76 324C54 352 60 392 92 398C114 402 126 386 116 372';
const innerL = 'M234 292C236 338 230 376 222 406C214 434 196 448 174 440';
export const armsD = [outerL, innerL, mirror(innerL), mirror(outerL)];
export function solid({ fill = '#fff', id = 'm', r0 = 30, r1 = 11, eyeRx = 16, eyeRy = 21, eyes: eyeMode = 'open' } = {}) {
  const arms = armsD.map(d => `<path d="${taper(d, r0, r1, 0.9)}"/>`).join('');
  const holes = eyeMode === 'open'
    ? eyes.map(([x, y]) => `<ellipse cx="${x}" cy="${y}" rx="${eyeRx}" ry="${eyeRy}" fill="#000"/>`).join('')
    : eyes.map(([x, y]) => `<path d="M${x - eyeRx * 1.5} ${y - 4}Q${x} ${y + eyeRy * 1.4} ${x + eyeRx * 1.5} ${y - 4}" fill="none" stroke="#000" stroke-width="${eyeRx * 0.85}" stroke-linecap="round"/>`).join('');
  return `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-512" y="-512" width="1536" height="1536"><rect x="-512" y="-512" width="1536" height="1536" fill="#fff"/>${holes}</mask></defs><g mask="url(#${id})" fill="${fill}"><path d="${head}"/>${arms}</g>`;
}
// Line octopus: one stroke from the left arm tip, over the head, to the right arm tip; inner arms hang free.
const lineOuterL = 'M116 372C126 386 114 402 92 398C60 392 54 352 76 324C96 298 128 300 142 290C154 281 124 246 122 200';
const lineTop = 'C122 116 178 60 256 60C334 60 390 116 390 200';
const lineInnerL = 'M228 302C230 342 226 378 218 406C210 432 192 446 172 438';
const rev = d => { // reverse a mirrored M..C.. path so it continues from the top
  const n = d.match(/-?\d*\.?\d+/g).map(Number); const pts = []; for (let i = 0; i < n.length; i += 2) pts.push([n[i], n[i + 1]]);
  const out = []; for (let i = pts.length - 1; i > 0; i -= 3) out.push(`C${pts[i - 1][0]} ${pts[i - 1][1]} ${pts[i - 2][0]} ${pts[i - 2][1]} ${pts[i - 3][0]} ${pts[i - 3][1]}`);
  return out.join('');
};
export const lineOuter = lineOuterL + lineTop + rev(mirror(lineOuterL));
export const lineInner = [lineInnerL, mirror(lineInnerL)];
export function line({ stroke = '#fff', w = 22, eyeR = 15, eyesFill } = {}) {
  return `<g fill="none" stroke="${stroke}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"><path d="${lineOuter}"/>${lineInner.map(d => `<path d="${d}"/>`).join('')}</g><g fill="${eyesFill || stroke}">${eyes.map(([x, y]) => `<circle cx="${x}" cy="${y + 4}" r="${eyeR}"/>`).join('')}</g>`;
}
// Menu bar glyph: the solid mark, heavier, cropped to its bounds.
export const glyphVB = '31 30 450 450';
export const glyph = ({ color = '#000', id = 'g', eyes: e = 'open' } = {}) => solid({ fill: color, id, r0: 36, r1: 20, eyeRx: 24, eyeRy: 30, eyes: e });

// Squircle body for macOS icons: 1024 canvas, 824 body at 100 inset, superellipse n = 5.
export function squircle(x = 100, y = 100, s = 824, n = 5, steps = 360) {
  const pts = []; const a = s / 2, cx = x + a, cy = y + a;
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * Math.PI * 2, c = Math.cos(t), sn = Math.sin(t);
    pts.push([cx + a * Math.sign(c) * Math.pow(Math.abs(c), 2 / n), cy + a * Math.sign(sn) * Math.pow(Math.abs(sn), 2 / n)]);
  }
  return 'M' + pts.map(p => p[0].toFixed(2) + ' ' + p[1].toFixed(2)).join('L') + 'Z';
}
