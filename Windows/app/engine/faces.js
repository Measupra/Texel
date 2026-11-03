// Faces: YuNet finds faces and five landmarks; each face is lined up the way GFPGAN expects, redrawn
// at 512×512, and later blended back with soft edges. Port of FaceRestorer.swift.
import { sample, bitmapPixels, clamp } from './imageops.js';

const N = 512;
const TEMPLATE = [[192.98138, 239.94708], [318.90277, 240.1936], [256.63416, 314.01935],
                  [201.26117, 371.41043], [313.08905, 371.15118]];

/** Faces in an image: [{score, box:[x,y,w,h], pts:[[x,y]×5]}], biggest first. detector(Float32Array 1×3×640×640 BGR 0–255) → outputs. */
export async function findFaces(rgba, W, H, detector, threshold = 0.6) {
  const k = 640 / Math.max(W, H);
  const sw = Math.max(1, Math.round(W * k)), sh = Math.max(1, Math.round(H * k));
  const bmp = await createImageBitmap(new ImageData(new Uint8ClampedArray(rgba.buffer, rgba.byteOffset, W * H * 4), W, H),
    { resizeWidth: sw, resizeHeight: sh, resizeQuality: 'high' });
  const small = bitmapPixels(bmp, sw, sh);
  const x = new Float32Array(3 * 640 * 640), P = 640 * 640;
  for (let y = 0; y < sh; y++) for (let xx = 0; xx < sw; xx++) {
    const i = (y * sw + xx) * 4, o = y * 640 + xx;
    x[o] = small[i + 2]; x[P + o] = small[i + 1]; x[2 * P + o] = small[i];
  }
  const out = await detector(x);
  let faces = [];
  for (const s of [8, 16, 32]) {
    const cols = 640 / s;
    const cls = out[`cls_${s}`], obj = out[`obj_${s}`], box = out[`bbox_${s}`], kps = out[`kps_${s}`];
    for (let i = 0; i < cls.length; i++) {
      const score = Math.sqrt(clamp(cls[i], 0, 1) * clamp(obj[i], 0, 1));
      if (score < threshold) continue;
      const r = Math.floor(i / cols), c = i % cols;
      const cx = (c + box[i * 4]) * s, cy = (r + box[i * 4 + 1]) * s;
      const bw = Math.exp(box[i * 4 + 2]) * s, bh = Math.exp(box[i * 4 + 3]) * s;
      const pts = [];
      for (let p = 0; p < 5; p++) pts.push([(kps[i * 10 + 2 * p] + c) * s / k, (kps[i * 10 + 2 * p + 1] + r) * s / k]);
      faces.push({ score, box: [(cx - bw / 2) / k, (cy - bh / 2) / k, bw / k, bh / k], pts });
    }
  }
  faces.sort((a, b) => b.score - a.score);
  const keep = [];
  for (const f of faces) if (keep.every((g) => iou(f.box, g.box) < 0.3)) keep.push(f);
  return keep.sort((a, b) => b.box[2] * b.box[3] - a.box[2] * a.box[3]);
}

function iou(a, b) {
  const ix = Math.max(0, Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]));
  const iy = Math.max(0, Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]));
  const inter = ix * iy;
  return inter / (a[2] * a[3] + b[2] * b[3] - inter);
}

/** Five landmarks in a fixed order: eyes (image-left first), nose, mouth corners. */
function orderLandmarks(pts) {
  let [e1, e2, nose, m1, m2] = pts;
  if (e1[0] > e2[0]) [e1, e2] = [e2, e1];
  const ax = e2[0] - e1[0], ay = e2[1] - e1[1];
  if (m1[0] * ax + m1[1] * ay > m2[0] * ax + m2[1] * ay) [m1, m2] = [m2, m1];
  return { pts: [e1, e2, nose, m1, m2], eyeDistance: Math.hypot(ax, ay) };
}

/** Least-squares rotation + uniform scale + shift taking src points onto dst: [a, b, tx, ty] with x' = a·x − b·y + tx, y' = b·x + a·y + ty. */
function similarity(src, dst) {
  const n = src.length;
  const ms = [0, 0], md = [0, 0];
  for (let i = 0; i < n; i++) { ms[0] += src[i][0] / n; ms[1] += src[i][1] / n; md[0] += dst[i][0] / n; md[1] += dst[i][1] / n; }
  let a = 0, b = 0, norm = 0;
  for (let i = 0; i < n; i++) {
    const sx = src[i][0] - ms[0], sy = src[i][1] - ms[1], tx = dst[i][0] - md[0], ty = dst[i][1] - md[1];
    a += sx * tx + sy * ty; b += sx * ty - sy * tx; norm += sx * sx + sy * sy;
  }
  const c = a / Math.max(norm, 1e-9), s = b / Math.max(norm, 1e-9);
  return [c, s, md[0] - (c * ms[0] - s * ms[1]), md[1] - (s * ms[0] + c * ms[1])];
}
const apply = (t, x, y) => [t[0] * x - t[1] * y + t[2], t[1] * x + t[0] * y + t[3]];
function invert(t) {
  const [c, s, tx, ty] = t, d = c * c + s * s;
  const ic = c / d, is = -s / d;
  return [ic, is, -(ic * tx - is * ty), -(is * tx + ic * ty)];
}

/** Restores every face (up to 12). restorer(Float32Array 1×3×512×512 RGB 0–1) → same. */
export async function restoreFaces(rgba, W, H, detector, restorer, progress, cancelled) {
  progress('Looking for faces…');
  const found = (await findFaces(rgba, W, H, detector)).slice(0, 12);
  const faces = [];
  const input = new Float32Array(3 * N * N), px = [0, 0, 0];
  const usable = found.map((f) => orderLandmarks(f.pts)).filter((f) => f.eyeDistance >= 6);
  for (let n = 0; n < usable.length; n++) {
    if (cancelled()) throw new Error('cancelled');
    progress(usable.length === 1 ? 'Restoring the face…' : `Restoring faces · ${n + 1} of ${usable.length}`);
    const toFace = similarity(usable[n].pts, TEMPLATE), fromFace = invert(toFace);
    for (let v = 0; v < N; v++) for (let u = 0; u < N; u++) {
      const [sx, sy] = apply(fromFace, u, v);
      sample(rgba, W, H, sx, sy, px);
      const o = v * N + u;
      input[o] = px[0] / 255; input[N * N + o] = px[1] / 255; input[2 * N * N + o] = px[2] / 255;
    }
    const out = await restorer(input);
    const pixels = new Uint8ClampedArray(N * N * 4);
    for (let i = 0; i < N * N; i++) {
      pixels[i * 4] = out[i] * 255 + 0.5; pixels[i * 4 + 1] = out[N * N + i] * 255 + 0.5;
      pixels[i * 4 + 2] = out[2 * N * N + i] * 255 + 0.5; pixels[i * 4 + 3] = 255;
    }
    faces.push({ pixels, toFace, sourceW: W, sourceH: H });
  }
  return faces;
}

const smoothstep = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };

/** Blends restored faces into an image that may be a larger version of the one they came from. */
export function pasteFaces(faces, rgba, w, h, strength) {
  if (!faces.length || strength <= 0.001) return rgba;
  const a = new Uint8ClampedArray(rgba);
  const amount = Math.min(1, strength), px = [0, 0, 0];
  for (const face of faces) {
    const kx = w / face.sourceW, ky = h / face.sourceH;
    // Output pixel → source position (centres aligned) → face position.
    const toFace = (X, Y) => apply(face.toFace, (X + 0.5) / kx - 0.5, (Y + 0.5) / ky - 0.5);
    const back = invert(face.toFace);
    const corners = [[0, 0], [N, 0], [0, N], [N, N]].map(([u, v]) => {
      const [sx, sy] = apply(back, u, v);
      return [(sx + 0.5) * kx - 0.5, (sy + 0.5) * ky - 0.5];
    });
    const x0 = Math.max(0, Math.floor(Math.min(...corners.map((c) => c[0]))) - 1);
    const x1 = Math.min(w, Math.ceil(Math.max(...corners.map((c) => c[0]))) + 1);
    const y0 = Math.max(0, Math.floor(Math.min(...corners.map((c) => c[1]))) - 1);
    const y1 = Math.min(h, Math.ceil(Math.max(...corners.map((c) => c[1]))) + 1);
    for (let Y = y0; Y < y1; Y++) for (let X = x0; X < x1; X++) {
      const [u, v] = toFace(X, Y);
      const edge = Math.min(u, N - 1 - u, v, N - 1 - v);
      if (edge <= 16) continue;
      const m = smoothstep(16, 80, edge) * amount;
      sample(face.pixels, N, N, u, v, px);
      const i = (Y * w + X) * 4;
      a[i] += m * (px[0] - a[i]); a[i + 1] += m * (px[1] - a[i + 1]); a[i + 2] += m * (px[2] - a[i + 2]);
    }
  }
  return a;
}
