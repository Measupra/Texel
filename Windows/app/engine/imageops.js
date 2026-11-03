// Pixel helpers shared by the engine. Images are straight RGBA, 8 bits per channel, top row first.

export const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

/** Tent (triangle) blur of size k (odd), colour channels only; alpha is copied. */
export function tent(src, w, h, k) {
  const r = (k - 1) >> 1;
  const out = new Uint8ClampedArray(src.length);
  if (r < 1) { out.set(src); return out; }
  const mid = new Uint8ClampedArray(src.length);
  const inv = 1 / (r + 1);
  const n = Math.max(w, h);
  const a = new Float32Array(n), line = new Float32Array(n);

  // One line: causal box of r+1 then anti-causal box of r+1 = a centred triangle of 2r+1.
  const blurLine = (len) => {
    let acc = 0;
    for (let i = -r; i <= 0; i++) acc += line[i < 0 ? 0 : i];
    for (let x = 0; x < len; x++) {
      a[x] = acc * inv;
      acc += line[x + 1 < len ? x + 1 : len - 1] - line[x - r > 0 ? x - r : 0];
    }
    acc = 0;
    for (let i = 0; i <= r; i++) acc += a[i < len ? i : len - 1];
    for (let x = 0; x < len; x++) {
      line[x] = acc * inv;
      acc += a[x + r + 1 < len ? x + r + 1 : len - 1] - a[x];
    }
  };

  for (let y = 0; y < h; y++) {
    const row = y * w * 4;
    for (let c = 0; c < 3; c++) {
      for (let x = 0; x < w; x++) line[x] = src[row + x * 4 + c];
      blurLine(w);
      for (let x = 0; x < w; x++) mid[row + x * 4 + c] = line[x] + 0.5;
    }
  }
  for (let x = 0; x < w; x++) {
    for (let c = 0; c < 3; c++) {
      for (let y = 0; y < h; y++) line[y] = mid[(y * w + x) * 4 + c];
      blurLine(h);
      for (let y = 0; y < h; y++) out[(y * w + x) * 4 + c] = line[y] + 0.5;
    }
  }
  for (let i = 3; i < src.length; i += 4) out[i] = src[i];
  return out;
}

/** High-quality resize using the browser's own resampler. */
export async function resizeHQ(rgba, w, h, ow, oh) {
  if (w === ow && h === oh) return new Uint8ClampedArray(rgba);
  const bmp = await createImageBitmap(new ImageData(new Uint8ClampedArray(rgba.buffer, rgba.byteOffset, w * h * 4), w, h),
    { resizeWidth: ow, resizeHeight: oh, resizeQuality: 'high', premultiplyAlpha: 'none' });
  return bitmapPixels(bmp, ow, oh);
}

/** Pixels of an ImageBitmap (or anything drawable) at w×h. */
export function bitmapPixels(bmp, w, h) {
  const c = new OffscreenCanvas(w, h);
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(bmp, 0, 0, w, h);
  if (bmp.close) bmp.close();
  return ctx.getImageData(0, 0, w, h).data;
}

/** Bilinear sample (x, y in pixel coordinates, edges repeated) → [r, g, b]. */
export function sample(s, W, H, x, y, out) {
  const fx0 = Math.floor(x), fy0 = Math.floor(y);
  const fx = x - fx0, fy = y - fy0;
  const xa = clamp(fx0, 0, W - 1), xb = clamp(fx0 + 1, 0, W - 1);
  const ya = clamp(fy0, 0, H - 1), yb = clamp(fy0 + 1, 0, H - 1);
  const i00 = (ya * W + xa) * 4, i01 = (ya * W + xb) * 4, i10 = (yb * W + xa) * 4, i11 = (yb * W + xb) * 4;
  for (let c = 0; c < 3; c++) {
    const top = s[i00 + c] * (1 - fx) + s[i01 + c] * fx;
    const bot = s[i10 + c] * (1 - fx) + s[i11 + c] * fx;
    out[c] = top * (1 - fy) + bot * fy;
  }
  return out;
}

export function luma(rgba, n) {
  const Y = new Float32Array(n);
  for (let i = 0; i < n; i++) Y[i] = (rgba[i * 4] * 77 + rgba[i * 4 + 1] * 150 + rgba[i * 4 + 2] * 29) / 256;
  return Y;
}
