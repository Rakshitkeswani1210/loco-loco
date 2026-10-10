import * as M from './mark.mjs';
const SQ = M.squircle();
const shadow = id => `<filter id="${id}" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.28"/></filter>`;
// Mark placement inside the 1024 canvas: 512 grid scaled to ~560, centred on the body.
const place = (inner, scale = 1.06, dy = 6) => `<g transform="translate(${512 - 256 * scale} ${512 - 254 * scale + dy}) scale(${scale})">${inner}</g>`;

export const PAL = {
  sunset: { name: 'Sunset', bands: ['#EE4F4C', '#F46E45', '#F99442', '#FCBC50'], ink: '#FFFFFF' },
  coral: { name: 'Coral', bg: ['#FFF6EC', '#F9E7D3'], ink: '#EE5F3B' },
  ink: { name: 'Deep sea', bg: ['#16465A', '#0D2B3B'], ink: '#FFFFFF' },
};
export function icon(kind, uid = kind, { small = false } = {}) {
  const p = PAL[kind];
  let defs = shadow(uid + 's') + `<clipPath id="${uid}c"><path d="${SQ}"/></clipPath>`;
  let body = '';
  if (kind === 'sunset') {
    // Soft diagonal ribbons like the reference: one gradient across the bands, each band lighter at its leading edge.
    const n = [0.892, 0.452], a = 194, b = 1302, k = p.bands.length;
    const mix = (h, t) => { const c = [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)); return '#' + c.map(v => Math.round(v + (255 - v) * t).toString(16).padStart(2, '0')).join(''); };
    const stops = p.bands.map((c, i) => { const s0 = i / k, s1 = (i + 1) / k, w = s1 - s0;
      return `<stop offset="${(s0 + w * 0.04).toFixed(3)}" stop-color="${i ? mix(c, 0.08) : c}"/><stop offset="${(s0 + w * 0.45).toFixed(3)}" stop-color="${c}"/><stop offset="${(s1 - w * 0.04).toFixed(3)}" stop-color="${c}"/>`; }).join('');
    defs += `<linearGradient id="${uid}g" gradientUnits="userSpaceOnUse" x1="${n[0] * a}" y1="${n[1] * a}" x2="${n[0] * b}" y2="${n[1] * b}">${stops}</linearGradient>`;
    body = `<path d="${SQ}" fill="url(#${uid}g)"/>` + place(M.solid({ fill: p.ink, id: uid + 'm' }));
  } else if (kind === 'coral') {
    defs += `<linearGradient id="${uid}g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${p.bg[0]}"/><stop offset="1" stop-color="${p.bg[1]}"/></linearGradient>`;
    body = `<path d="${SQ}" fill="url(#${uid}g)"/>` + place(M.solid({ fill: p.ink, id: uid + 'm' }));
  } else {
    defs += `<linearGradient id="${uid}g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${p.bg[0]}"/><stop offset="1" stop-color="${p.bg[1]}"/></linearGradient>`;
    body = `<path d="${SQ}" fill="url(#${uid}g)"/>` + place(M.line({ stroke: p.ink, w: small ? 34 : 22, eyeR: small ? 20 : 15 }));
  }
  return `<defs>${defs}</defs><g filter="url(#${uid}s)">${body.startsWith('<path') ? body.replace(/^<path d="[^"]+" fill="url\(#\w+g\)"\/>/, m => m) : body}</g>`;
}
export const iconSVG = (kind, size, uid) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="${size}" height="${size}">${icon(kind, uid, { small: size <= 32 })}</svg>`;
