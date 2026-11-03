// "Colour & light": automatic levels, exposure, colour balance and vibrance (the same kinds of fixes
// as Apple's auto-enhance on the Mac), plus a wide, gentle "clarity" boost for texture.

export function enhance(src, w, h, amount) {
  if (amount <= 0.001) return src;
  const n = w * h;
  // 1. Statistics from a sample of about 65k pixels.
  const step = Math.max(1, Math.floor(Math.sqrt(n / 65536)));
  const hist = new Float64Array(256);
  let count = 0, sR = 0, sG = 0, sB = 0, mids = 0;
  for (let y = 0; y < h; y += step) for (let x = 0; x < w; x += step) {
    const i = (y * w + x) * 4, R = src[i], G = src[i + 1], B = src[i + 2];
    const Y = (R * 77 + G * 150 + B * 29) >> 8;
    hist[Y]++; count++;
    if (Y > 50 && Y < 210) { sR += R; sG += G; sB += B; mids++; }
  }
  const pct = (p) => { let acc = 0; for (let v = 0; v < 256; v++) { acc += hist[v]; if (acc >= p * count) return v; } return 255; };
  const lo = pct(0.005), hi = pct(0.995);

  // Levels: lift the black point and pull down the white point towards the real range (partly).
  const black = Math.min(lo, 40) * 0.8, white = Math.max(hi, 200) + (255 - Math.max(hi, 200)) * 0.2;
  const levels = (v) => Math.max(0, Math.min(1, (v - black) / Math.max(1, white - black)));
  // Exposure: a gentle gamma towards a mid-grey average, only for clearly dark or bright images.
  let meanAfter = 0;
  for (let v = 0; v < 256; v++) meanAfter += hist[v] * levels(v);
  meanAfter /= count;
  let gamma = 1;
  if (meanAfter < 0.38 || meanAfter > 0.62) {
    gamma = Math.log(0.47) / Math.log(Math.max(0.02, Math.min(0.98, meanAfter)));
    gamma = 1 + (Math.max(0.7, Math.min(1.35, gamma)) - 1) * 0.65;
  }
  // Colour balance: move half-way towards neutral mid-tones (grey world), within ±10%.
  let gR = 1, gG = 1, gB = 1;
  if (mids > count / 10) {
    const m = (sR + sG + sB) / 3;
    const lim = (g) => 1 + (Math.max(0.9, Math.min(1.1, g)) - 1) * 0.5;
    gR = lim(m / sR); gG = lim(m / sG); gB = lim(m / sB);
  }
  const lut = [new Uint8Array(256), new Uint8Array(256), new Uint8Array(256)];
  const gains = [gR, gG, gB];
  for (let c = 0; c < 3; c++) for (let v = 0; v < 256; v++)
    lut[c][v] = Math.max(0, Math.min(255, Math.round(255 * Math.pow(levels(Math.min(255, v * gains[c])), 1 / gamma))));

  const out = new Uint8ClampedArray(src.length);
  const Yb = new Float32Array(n);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    let R = lut[0][src[i]], G = lut[1][src[i + 1]], B = lut[2][src[i + 2]];
    // Vibrance: boost muted colours more than already-strong ones.
    const mx = Math.max(R, G, B), mn = Math.min(R, G, B), sat = (mx - mn) / 255;
    const k = 0.22 * (1 - sat);
    const avg = (R + G + B) / 3;
    R += (R - avg) * k; G += (G - avg) * k; B += (B - avg) * k;
    out[i] = R; out[i + 1] = G; out[i + 2] = B; out[i + 3] = src[i + 3];
    Yb[p] = (out[i] * 77 + out[i + 1] * 150 + out[i + 2] * 29) / 256;
  }

  // 2. Clarity: wide unsharp mask on brightness (three box blurs ≈ a Gaussian).
  const radius = Math.max(4, Math.round(Math.max(w, h) * 0.006));
  const blurred = boxBlur3(Yb, w, h, radius);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    const d = (Yb[p] - blurred[p]) * 0.35;
    out[i] += d; out[i + 1] += d; out[i + 2] += d;
  }

  if (amount >= 0.999) return out;
  for (let i = 0; i < out.length; i += 4)
    for (let c = 0; c < 3; c++) out[i + c] = src[i + c] + amount * (out[i + c] - src[i + c]);
  return out;
}

function boxBlur3(src, w, h, r) {
  let a = src, b = new Float32Array(src.length);
  const line = new Float32Array(Math.max(w, h)), tmp = new Float32Array(Math.max(w, h));
  const pass = (len, get, set) => {
    for (let i = 0; i < len; i++) line[i] = get(i);
    let acc = 0;
    for (let i = -r; i <= r; i++) acc += line[Math.min(len - 1, Math.max(0, i))];
    const inv = 1 / (2 * r + 1);
    for (let i = 0; i < len; i++) {
      tmp[i] = acc * inv;
      acc += line[Math.min(len - 1, i + r + 1)] - line[Math.max(0, i - r)];
    }
    for (let i = 0; i < len; i++) set(i, tmp[i]);
  };
  for (let it = 0; it < 3; it++) {
    for (let y = 0; y < h; y++) pass(w, (x) => a[y * w + x], (x, v) => { b[y * w + x] = v; });
    for (let x = 0; x < w; x++) pass(h, (y) => b[y * w + x], (y, v) => { b[y * w + x] = v; });
    if (it === 0) { a = b; b = new Float32Array(src.length); } else { const t = a; a = b; b = t; }
  }
  return a;
}
