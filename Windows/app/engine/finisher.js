// Runs after the AI: AI strength (blend with a plain enlargement), Detail (the original's fine
// texture), Smooth (edge-aware evening-out) and Sharp. Port of Finisher in AppState.swift.
import { tent, resizeHQ } from './imageops.js';

const clampOdd = (k) => Math.max(3, Math.min(k, 15));

export async function finish(ai, w, h, detailSrc, { strength = 1, detail = 0, sharpen = 0, smooth = 0 }) {
  if (detail <= 0.001 && sharpen <= 0.001 && smooth <= 0.001 && strength >= 0.999) return ai;
  const a = new Uint8ClampedArray(ai);
  const ratio = w / Math.max(1, detailSrc.w);

  if (detail > 0.001 || strength < 0.999) {
    const l = await resizeHQ(detailSrc.rgba, detailSrc.w, detailSrc.h, w, h);
    if (strength < 0.999) {
      const t = 1 - Math.max(0, strength);
      for (let i = 0; i < a.length; i += 4) {
        a[i] += t * (l[i] - a[i]); a[i + 1] += t * (l[i + 1] - a[i + 1]); a[i + 2] += t * (l[i + 2] - a[i + 2]);
      }
    }
    if (detail > 0.001) {
      const lb = tent(l, w, h, clampOdd(Math.round(ratio) * 2 + 1));
      // Big enlargements: the original's "texture" is mostly its pixel grid, so add less.
      // At 1× (Enhance) it includes the noise the AI just removed, so add back only half.
      const gain = detail * 1.5 * Math.min(1, Math.pow(2 / Math.max(ratio, 1), 1.5)) * Math.min(1, Math.max(ratio, 1) / 2);
      for (let i = 0; i < a.length; i += 4)
        for (let c = 0; c < 3; c++) a[i + c] = a[i + c] + gain * (l[i + c] - lb[i + c]);
    }
  }

  if (smooth > 0.001) {
    let k = Math.round(ratio * 1.5); if (k % 2 === 0) k += 1;
    const b = tent(a, w, h, clampOdd(k));
    const amount = Math.min(1, smooth), edge = 80;
    for (let i = 0; i < a.length; i += 4) {
      const d0 = b[i] - a[i], d1 = b[i + 1] - a[i + 1], d2 = b[i + 2] - a[i + 2];
      const d = Math.max(Math.abs(d0), Math.abs(d1), Math.abs(d2));
      const wgt = amount * Math.max(0, 1 - d / edge);
      if (wgt > 0) { a[i] += wgt * d0; a[i + 1] += wgt * d1; a[i + 2] += wgt * d2; }
    }
  }

  if (sharpen > 0.001) {
    // The radius grows with the enlargement, so it works on detail you can actually see.
    const b = tent(a, w, h, clampOdd(Math.round(ratio) * 2 + 1));
    const gain = sharpen * 1.6;
    for (let i = 0; i < a.length; i += 4)
      for (let c = 0; c < 3; c++) a[i + c] = a[i + c] + gain * (a[i + c] - b[i + c]);
  }
  return a;
}
