// AI upscaling with the Real-ESRGAN models: overlapping 256-px tiles, each 4× tile resampled straight
// into the requested size, plus detection of pixelated (blown-up) images. Port of AIUpscaler.swift.
import { clamp } from './imageops.js';

export const TILE = 256, PAD = 16, FACTOR = 4;
export const MAX_SIDE = 16384, MAX_OUTPUT_PIXELS = 64_000_000;

export const MODELS = {
  photo: { file: 'photo.onnx', title: 'Photo', summary: 'Real-ESRGAN x4plus. The largest model: rebuilds fine texture and removes JPEG noise. Slowest.' },
  general: { file: 'general.onnx', title: 'General', summary: 'Real-ESRGAN general v3 with medium denoise. Several times faster than Photo and keeps natural texture.' },
  anime: { file: 'anime.onnx', title: 'Anime', summary: 'Real-ESRGAN anime 6B. Keeps flat colours and clean line art.' },
};

function positions(n) {
  if (n <= TILE) return [0];
  const p = [];
  let x = 0;
  while (x + TILE < n) { p.push(x); x += TILE - 2 * PAD; }
  p.push(n - TILE);
  return p;
}

/** Sample positions and weights in 4×-space for each output pixel along one axis. */
function taps(n, hr) {
  const r = hr / n;
  const maxT = r >= 1 ? Math.ceil(r) + 2 : 2;
  const idx = new Int32Array(n * maxT), wt = new Float32Array(n * maxT), cnt = new Uint8Array(n);
  for (let x = 0; x < n; x++) {
    let k = 0;
    const o = x * maxT;
    if (r >= 1) {
      const a = x * r, b = a + r;
      let i = Math.floor(a), sum = 0;
      while (i < b) {
        const w = Math.min(b, i + 1) - Math.max(a, i);
        if (w > 1e-6) { idx[o + k] = clamp(i, 0, hr - 1); wt[o + k] = w; sum += w; k++; }
        i++;
      }
      for (let j = 0; j < k; j++) wt[o + j] /= sum;
    } else {
      const p = (x + 0.5) * r - 0.5;
      const i0 = Math.floor(p), f = p - i0;
      idx[o] = clamp(i0, 0, hr - 1); wt[o] = 1 - f;
      idx[o + 1] = clamp(i0 + 1, 0, hr - 1); wt[o + 1] = f;
      k = 2;
    }
    cnt[x] = k;
  }
  return { idx, wt, cnt, maxT };
}

// ---------------------------------------------------------------- pixelation detection

/** How many times a pixelated image was blown up (1 = normal). Only blocky enlargements count. */
export function effectiveDownscale(rgba, W, H) {
  const align = 48;
  const cw = Math.floor(Math.min(W, 1536) / align) * align, ch = Math.floor(Math.min(H, 1536) / align) * align;
  if (cw < 192 || ch < 192) return 1;
  const x0 = Math.floor((W - cw) / 2 / align) * align, y0 = Math.floor((H - ch) / 2 / align) * align;
  const Y = new Float32Array(cw * ch);
  for (let y = 0; y < ch; y++) for (let x = 0; x < cw; x++) {
    const i = ((y0 + y) * W + (x0 + x)) * 4;
    Y[y * cw + x] = (rgba[i] * 77 + rgba[i + 1] * 150 + rgba[i + 2] * 29) / 256;
  }
  const colDiff = new Float32Array(cw - 1), rowDiff = new Float32Array(ch - 1);
  for (let y = 0; y < ch; y++) {
    const r = y * cw;
    for (let x = 0; x < cw - 1; x++) colDiff[x] += Math.abs(Y[r + x + 1] - Y[r + x]);
    if (y < ch - 1) { let acc = 0; for (let x = 0; x < cw; x++) acc += Math.abs(Y[r + cw + x] - Y[r + x]); rowDiff[y] = acc; }
  }
  let best = 1;
  for (const f of [2, 3, 4, 6, 8, 12, 16]) {
    if (cw / f < 24 || ch / f < 24) continue;
    if (gridRatio(colDiff, f) < 0.5 && gridRatio(rowDiff, f) < 0.5 && reconstructionError(Y, cw, ch, f) < 3.0) best = f;
  }
  return best;
}

function gridRatio(d, f) {
  const n = Math.floor(d.length / f) * f;
  if (n < f) return 1;
  const phase = new Float64Array(f);
  for (let i = 0; i < n; i++) phase[i % f] += d[i];
  let k = 0;
  for (let i = 1; i < f; i++) if (phase[i] > phase[k]) k = i;
  if (phase[k] <= 1e-6) return 1;
  let other = 0;
  for (let i = 0; i < f; i++) if (i !== k) other = Math.max(other, phase[i]);
  return other / phase[k];
}

function reconstructionError(Y, w, h, f) {
  const sw = Math.floor(w / f), sh = Math.floor(h / f);
  const small = new Float32Array(sw * sh), inv = 1 / (f * f);
  for (let sy = 0; sy < sh; sy++) for (let sx = 0; sx < sw; sx++) {
    let acc = 0;
    for (let dy = 0; dy < f; dy++) { const row = (sy * f + dy) * w + sx * f; for (let dx = 0; dx < f; dx++) acc += Y[row + dx]; }
    small[sy * sw + sx] = acc * inv;
  }
  let errNear = 0, errBil = 0;
  for (let y = 0; y < sh * f; y++) {
    const py = (y + 0.5) / f - 0.5;
    const ya = clamp(Math.floor(py), 0, sh - 1), yb = Math.min(ya + 1, sh - 1), fy = clamp(py - ya, 0, 1), yn = Math.floor(y / f);
    for (let x = 0; x < sw * f; x++) {
      const v = Y[y * w + x];
      errNear += Math.abs(v - small[yn * sw + Math.floor(x / f)]);
      const px = (x + 0.5) / f - 0.5;
      const xa = clamp(Math.floor(px), 0, sw - 1), xb = Math.min(xa + 1, sw - 1), fx = clamp(px - xa, 0, 1);
      const top = small[ya * sw + xa] * (1 - fx) + small[ya * sw + xb] * fx;
      const bot = small[yb * sw + xa] * (1 - fx) + small[yb * sw + xb] * fx;
      errBil += Math.abs(v - (top * (1 - fy) + bot * fy));
    }
  }
  return Math.min(errNear, errBil) / (sw * f * sh * f);
}

export function boxShrink(rgba, W, H, f) {
  const w = Math.floor(W / f), h = Math.floor(H / f), n = f * f;
  const out = new Uint8ClampedArray(w * h * 4).fill(255);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let r = 0, g = 0, b = 0;
    for (let dy = 0; dy < f; dy++) {
      let i = ((y * f + dy) * W + x * f) * 4;
      for (let dx = 0; dx < f; dx++) { r += rgba[i]; g += rgba[i + 1]; b += rgba[i + 2]; i += 4; }
    }
    const o = (y * w + x) * 4;
    out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n;
  }
  return out;
}

// ---------------------------------------------------------------- upscaling

/**
 * src: {rgba, w, h, hasAlpha}. Returns {rgba, w, h, detail: {rgba, w, h}, rebuiltFrom}.
 * run(input Float32Array 1×3×256×256) → Float32Array 1×3×1024×1024 (0…1).
 */
export async function upscale(src, outW, outH, run, progress, cancelled) {
  if (outW > MAX_SIDE || outH > MAX_SIDE || outW * outH > MAX_OUTPUT_PIXELS)
    throw new Error(`${outW} × ${outH} is larger than AI mode allows on this PC (${MAX_OUTPUT_PIXELS / 1e6} MP). Pick a smaller scale.`);
  const W0 = src.w, H0 = src.h;
  let rgba = src.rgba;

  progress('Checking the photo’s real resolution…', 0.005);
  const rebuilt = effectiveDownscale(rgba, W0, H0);
  let cur = rgba, W = W0, H = H0;
  if (rebuilt > 1) { cur = boxShrink(rgba, W0, H0, rebuilt); W = Math.floor(W0 / rebuilt); H = Math.floor(H0 / rebuilt); }
  const detail = rebuilt > 1 ? { rgba: cur, w: W, h: H } : { rgba: src.rgba, w: W0, h: H0 };

  // One pass reaches 4×; beyond that a first pass makes a quarter-size image and a second AI pass
  // enlarges it by exactly 4×, so every step is real AI detail.
  let sizes;
  if (W * FACTOR >= outW && H * FACTOR >= outH) sizes = [[outW, outH]];
  else {
    const mw = Math.min(W * FACTOR, Math.ceil(outW / FACTOR)), mh = Math.min(H * FACTOR, Math.ceil(outH / FACTOR));
    sizes = [[Math.max(W, mw), Math.max(H, mh)], [outW, outH]];
  }
  const inputs = [[W, H], ...sizes.slice(0, -1)];
  const tileCounts = inputs.map(([w, h]) => positions(Math.max(w, TILE)).length * positions(Math.max(h, TILE)).length);
  const total = tileCounts.reduce((a, b) => a + b, 0);
  let doneTiles = 0, out;
  for (let i = 0; i < sizes.length; i++) {
    const [pw, ph] = sizes[i], [iw, ih] = inputs[i];
    const label = rebuilt > 1
      ? (sizes.length > 1 ? `Rebuilding from ${W}×${H} · pass ${i + 1} of ${sizes.length}` : `Rebuilding from ${W}×${H}`)
      : (sizes.length > 1 ? `AI upscaling · pass ${i + 1} of ${sizes.length}` : 'AI upscaling');
    const base = doneTiles;
    out = await runTiles(cur, iw, ih, pw, ph, run, cancelled, (done, tot) =>
      progress(`${label} · tile ${done} of ${tot}`, 0.01 + 0.96 * (base + done) / total));
    doneTiles += tileCounts[i];
    if (i < sizes.length - 1) cur = out;
  }

  if (src.hasAlpha) resizeAlphaInto(rgba, W0, H0, out, outW, outH);
  progress('Finishing', 0.98);
  return { rgba: out, w: outW, h: outH, detail, rebuiltFrom: rebuilt };
}

async function runTiles(rgba, W, H, outW, outH, run, cancelled, tileDone) {
  const f = FACTOR, T = TILE, P = PAD, HR = T * f;
  const out = new Uint8ClampedArray(outW * outH * 4).fill(255);
  const col = taps(outW, W * f), row = taps(outH, H * f);
  const kx = outW / W, ky = outH / H;
  const Wp = Math.max(W, T), Hp = Math.max(H, T);
  const xs = positions(Wp), ys = positions(Hp);
  const total = xs.length * ys.length;
  const input = new Float32Array(3 * T * T);
  let done = 0;
  for (const ty of ys) for (const tx of xs) {
    if (cancelled()) throw new Error('cancelled');
    for (let y = 0; y < T; y++) {
      const sy = Math.min(ty + y, H - 1);
      for (let x = 0; x < T; x++) {
        const i = (sy * W + Math.min(tx + x, W - 1)) * 4, o = y * T + x;
        input[o] = rgba[i] / 255; input[T * T + o] = rgba[i + 1] / 255; input[2 * T * T + o] = rgba[i + 2] / 255;
      }
    }
    const o = await run(input);
    // This tile owns the output pixels whose centres fall in its core (overlap discarded).
    const cx0 = tx === 0 ? 0 : tx + P, cx1 = Math.min(tx + T >= Wp ? Wp : tx + T - P, W);
    const cy0 = ty === 0 ? 0 : ty + P, cy1 = Math.min(ty + T >= Hp ? Hp : ty + T - P, H);
    const X0 = Math.max(0, Math.ceil(cx0 * kx - 0.5)), X1 = Math.min(outW, Math.ceil(cx1 * kx - 0.5));
    const Y0 = Math.max(0, Math.ceil(cy0 * ky - 0.5)), Y1 = Math.min(outH, Math.ceil(cy1 * ky - 0.5));
    const ox = tx * f, oy = ty * f, plane = HR * HR;
    for (let Y = Y0; Y < Y1; Y++) {
      const ro = Y * row.maxT, rn = row.cnt[Y];
      for (let X = X0; X < X1; X++) {
        const co = X * col.maxT, cn = col.cnt[X];
        let r = 0, g = 0, b = 0;
        for (let j = 0; j < rn; j++) {
          const ly = clamp(row.idx[ro + j] - oy, 0, HR - 1), wy = row.wt[ro + j];
          for (let k = 0; k < cn; k++) {
            const lx = clamp(col.idx[co + k] - ox, 0, HR - 1), w = col.wt[co + k] * wy, si = ly * HR + lx;
            r += o[si] * w; g += o[plane + si] * w; b += o[2 * plane + si] * w;
          }
        }
        const di = (Y * outW + X) * 4;
        out[di] = r * 255 + 0.5; out[di + 1] = g * 255 + 0.5; out[di + 2] = b * 255 + 0.5;
      }
    }
    done++;
    tileDone(done, total);
  }
  return out;
}

/** Alpha is resized smoothly on its own from the original, into an RGBA result. */
export function resizeAlphaInto(rgba, W0, H0, out, outW, outH) {
  const kx = outW / W0, ky = outH / H0;
  for (let Y = 0; Y < outH; Y++) {
    const sy = (Y + 0.5) / ky - 0.5, y0 = clamp(Math.floor(sy), 0, H0 - 1), y1 = Math.min(H0 - 1, y0 + 1), fy = clamp(sy - y0, 0, 1);
    for (let X = 0; X < outW; X++) {
      const sx = (X + 0.5) / kx - 0.5, x0 = clamp(Math.floor(sx), 0, W0 - 1), x1 = Math.min(W0 - 1, x0 + 1), fx = clamp(sx - x0, 0, 1);
      out[(Y * outW + X) * 4 + 3] = rgba[(y0 * W0 + x0) * 4 + 3] * (1 - fx) * (1 - fy) + rgba[(y0 * W0 + x1) * 4 + 3] * fx * (1 - fy)
        + rgba[(y1 * W0 + x0) * 4 + 3] * (1 - fx) * fy + rgba[(y1 * W0 + x1) * 4 + 3] * fx * fy;
    }
  }
}
