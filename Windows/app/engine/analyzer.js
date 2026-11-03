// Auto Fix: measures blur, noise, JPEG blocks, pixelation, faces and lighting, then picks settings.
// Port of ImageAnalyzer.swift (same calibrated thresholds).
import { effectiveDownscale } from './upscaler.js';
import { resizeHQ, luma } from './imageops.js';

export async function analyze(rgba, W, H, faces) {
  const r = { pixelated: 1, noise: 0, sharpness: 0.5, jpeg: 0, faces: faces.length,
              largestFace: faces.reduce((m, f) => Math.max(m, f.box[2]), 0),
              dark: false, bright: false, lowContrast: false, colourCast: false };
  const align = 48;
  const cw = Math.floor(Math.min(W, 1056) / align) * align, ch = Math.floor(Math.min(H, 1056) / align) * align;
  if (cw >= 192 && ch >= 192) {
    const x0 = Math.floor((W - cw) / 2 / align) * align, y0 = Math.floor((H - ch) / 2 / align) * align;
    const crop = new Uint8ClampedArray(cw * ch * 4);
    for (let y = 0; y < ch; y++) crop.set(rgba.subarray(((y0 + y) * W + x0) * 4, ((y0 + y) * W + x0 + cw) * 4), y * cw * 4);
    r.pixelated = effectiveDownscale(crop, cw, ch);
    if (r.pixelated === 1) {
      const Y = luma(crop, cw * ch);
      r.noise = noise(Y, cw, ch); r.sharpness = sharpness(Y, cw, ch); r.jpeg = jpegBlocks(Y, cw, ch);
    }
  }
  const k = Math.min(1, 256 / Math.max(W, H));
  const sw = Math.max(1, Math.round(W * k)), sh = Math.max(1, Math.round(H * k));
  const small = await resizeHQ(rgba, W, H, sw, sh);
  const hist = new Float64Array(256);
  let sRG = 0, sBG = 0, mids = 0;
  for (let i = 0; i < sw * sh; i++) {
    const R = small[i * 4], G = small[i * 4 + 1], B = small[i * 4 + 2];
    const y = (R * 77 + G * 150 + B * 29) >> 8;
    hist[y]++;
    if (y > 60 && y < 200) { sRG += R - G; sBG += B - G; mids++; }
  }
  const n = sw * sh;
  const pct = (p) => { let acc = 0; for (let v = 0; v < 256; v++) { acc += hist[v]; if (acc >= p * n) return v; } return 255; };
  let mean = 0; for (let v = 0; v < 256; v++) mean += v * hist[v]; mean /= n;
  const lo = pct(0.02), hi = pct(0.98);
  r.dark = mean < 70 || hi < 150;
  r.bright = mean > 195 && lo > 80;
  r.lowContrast = hi - lo < 140;
  if (mids > n / 10) r.colourCast = Math.hypot(sRG / mids, sBG / mids) > 22;
  return r;
}

const blurOf = (r) => Math.max(0, Math.min(1, (0.5 - r.sharpness) / 0.15));
const noisinessOf = (r) => Math.max(0, Math.min(1, (r.noise - 1.8) / 5));
const blockinessOf = (r) => Math.max(0, Math.min(1, (r.jpeg - 0.15) / 0.5));

export function plan(r, W, H) {
  const blur = blurOf(r), noisy = noisinessOf(r), blocky = blockinessOf(r);
  const dirt = Math.max(noisy, blocky);
  const issues = Math.max(blur, dirt, r.pixelated > 1 ? 1 : 0);
  const scale = r.pixelated === 1 && Math.max(W, H) < 1000 ? 2 : 1;
  let faceStrength = r.largestFace < 96 ? 0.8 : r.largestFace < 256 ? 0.65 : 0.45;
  faceStrength = Math.min(0.9, faceStrength + 0.2 * blur);
  const lightIssues = [r.dark, r.bright, r.lowContrast, r.colourCast].filter(Boolean).length;

  const found = [];
  if (r.pixelated > 1) found.push('pixelated');
  if (blur > 0.25) found.push(blur > 0.65 ? 'very blurry' : 'a little blurry');
  if (noisy > 0.15) found.push('grainy');
  if (blocky > 0.15) found.push('JPEG blocks');
  if (r.dark) found.push('dark');
  if (r.bright) found.push('washed out');
  if (r.lowContrast && !r.bright) found.push('flat contrast');
  if (r.colourCast) found.push('colour cast');
  if (r.faces > 0) found.push(r.faces === 1 ? '1 face' : `${r.faces} faces`);
  let what = found.length ? found.join(' · ') : 'Looks clean: light touch';
  what = what[0].toUpperCase() + what.slice(1);
  return {
    model: 'photo', scale,
    aiStrength: 0.6 + 0.4 * issues,
    detail: 0.3 * (1 - dirt),
    smooth: 0.1 + 0.5 * dirt,
    sharpen: Math.max(0.1, 0.15 + 0.45 * blur - 0.2 * noisy),
    restoreFaces: r.faces > 0, faceStrength,
    autoEnhance: true, enhanceAmount: Math.min(0.75, 0.3 + 0.15 * lightIssues),
    summary: `${what} → ${scale === 1 ? 'same size' : '2× (small image)'}`,
  };
}

// ---------------------------------------------------------------- measurements

function gradient(Y, w, h) {
  const g = new Float32Array(w * h);
  for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
    const i = y * w + x;
    const gx = (Y[i - w + 1] + 2 * Y[i + 1] + Y[i + w + 1]) - (Y[i - w - 1] + 2 * Y[i - 1] + Y[i + w - 1]);
    const gy = (Y[i + w - 1] + 2 * Y[i + w] + Y[i + w + 1]) - (Y[i - w - 1] + 2 * Y[i - w] + Y[i - w + 1]);
    g[i] = Math.abs(gx) + Math.abs(gy);
  }
  return g;
}

function percentile(v, w, h, p) {
  const hist = new Int32Array(2048); let n = 0;
  for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) { hist[Math.min(2047, v[y * w + x] | 0)]++; n++; }
  let acc = 0;
  for (let b = 0; b < 2048; b++) { acc += hist[b]; if (acc >= p * n) return b; }
  return 2047;
}

function noise(Y, w, h) {
  const g = gradient(Y, w, h), limit = percentile(g, w, h, 0.5);
  let sum = 0, n = 0;
  for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
    const i = y * w + x;
    if (g[i] > limit) continue;
    const l = (Y[i - w - 1] - 2 * Y[i - w] + Y[i - w + 1]) - 2 * (Y[i - 1] - 2 * Y[i] + Y[i + 1]) + (Y[i + w - 1] - 2 * Y[i + w] + Y[i + w + 1]);
    sum += Math.abs(l); n++;
  }
  return n ? Math.sqrt(Math.PI / 2) / 6 * sum / n : 0;
}

function sharpness(Y, w, h) {
  const g = gradient(Y, w, h), limit = percentile(g, w, h, 0.97);
  let sum = 0, n = 0;
  for (let y = 1; y < h - 1; y++) for (let x = 0; x < w - 3; x++) {
    if (g[y * w + x + 1] < limit) continue;
    const d3 = Math.abs(Y[y * w + x + 3] - Y[y * w + x]);
    if (d3 <= 20) continue;
    sum += Math.abs(Y[y * w + x + 1] - Y[y * w + x]) / d3; n++;
  }
  return n < 50 ? 0.5 : sum / n;
}

function jpegBlocks(Y, w, h) {
  const col = new Float64Array(8), row = new Float64Array(8);
  for (let y = 0; y < h; y++) for (let x = 0; x < w - 1; x++) col[x % 8] += Math.abs(Y[y * w + x + 1] - Y[y * w + x]);
  for (let y = 0; y < h - 1; y++) { let acc = 0; for (let x = 0; x < w; x++) acc += Math.abs(Y[(y + 1) * w + x] - Y[y * w + x]); row[y % 8] += acc; }
  const ratio = (ph) => { const others = (ph.reduce((a, b) => a + b, 0) - ph[7]) / 7; return others > 0 ? ph[7] / others - 1 : 0; };
  return Math.max(0, Math.min(ratio(col), ratio(row)));
}
