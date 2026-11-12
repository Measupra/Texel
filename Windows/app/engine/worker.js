// The engine runs here, off the interface thread: AI models (ONNX Runtime, GPU via WebGPU with a CPU
// fallback), Classic (WebGL2), finishing, faces, colour and Auto Fix. It keeps the plain upscale and
// restored faces so slider changes are re-composed quickly without running the AI again.
import * as ort from '../vendor/ort/ort.webgpu.min.mjs';
import { upscale, MODELS, resizeAlphaInto } from './upscaler.js';
import { finish } from './finisher.js';
import { restoreFaces, pasteFaces, findFaces } from './faces.js';
import { enhance } from './enhancer.js';
import { analyze, plan } from './analyzer.js';
import { classicUpscale } from './classic.js';

ort.env.wasm.wasmPaths = new URL('../vendor/ort/', import.meta.url).href;
ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(8, navigator.hardwareConcurrency || 4) : 1;
ort.env.logLevel = 'error';

const MODEL_DIR = new URL('../models/', import.meta.url).href;
const sessions = {};
let backend = null;        // 'GPU' or 'CPU'
let src = null;            // { rgba, w, h, hasAlpha }
let base = null;           // { rgba, w, h, detail: {rgba,w,h}, useFinisher }
let faces = null;          // restored faces for `base` (null = not worked out yet)
// Jobs run one at a time, in the order they arrive. Each run carries an id; Cancel stops every run
// asked for so far (the one in progress and any still queued), but not ones that arrive later.
let currentRun = 0, lastRunSeen = 0, cancelUpTo = 0;
const isCancelled = () => currentRun <= cancelUpTo;

async function gpuAvailable() {
  try {
    const a = navigator.gpu && await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
    // A software-emulated "GPU" (no real graphics driver) is far slower than the processor.
    return !!a && !(a.info?.isFallbackAdapter || a.isFallbackAdapter);
  } catch { return false; }
}

async function session(name, status) {
  if (sessions[name]) return sessions[name];
  status?.('Loading the AI model…');
  if (backend === null) backend = (await gpuAvailable()) ? 'GPU' : 'CPU';
  const eps = backend === 'GPU' ? ['webgpu', 'wasm'] : ['wasm'];
  let s;
  try {
    s = await ort.InferenceSession.create(MODEL_DIR + name, { executionProviders: eps, graphOptimizationLevel: 'all' });
  } catch (e) {
    if (backend !== 'GPU') throw e;
    backend = 'CPU';   // the GPU couldn't run it: use the processor instead
    s = await ort.InferenceSession.create(MODEL_DIR + name, { executionProviders: ['wasm'], graphOptimizationLevel: 'all' });
  }
  return (sessions[name] = s);
}

const runner = (s, inName, outName, shape) => async (data) => {
  const r = await s.run({ [inName]: new ort.Tensor('float32', data, shape) });
  return r[outName].data;
};
async function detector() {
  const s = await session('yunet.onnx');
  return async (x) => {
    const r = await s.run({ input: new ort.Tensor('float32', x, [1, 3, 640, 640]) });
    const out = {};
    for (const k of Object.keys(r)) out[k] = r[k].data;
    return out;
  };
}
async function restorer(status) {
  return runner(await session('faces.onnx', status), 'face', 'restored', [1, 3, 512, 512]);
}

async function compose(look) {
  let img = base.useFinisher ? await finish(base.rgba, base.w, base.h, base.detail, look) : base.rgba;
  if (look.faces > 0.001 && faces?.length) img = pasteFaces(faces, img, base.w, base.h, look.faces);
  if (look.enhance > 0.001) img = enhance(img, base.w, base.h, look.enhance);
  return img === base.rgba ? new Uint8ClampedArray(img) : img;
}

async function workOutFaces(progress, cancelled) {
  try {
    faces = await restoreFaces(base.detail.rgba, base.detail.w, base.detail.h, await detector(),
                               await restorer(progress), progress, cancelled);
  } catch (e) {
    if (e.message === 'cancelled') throw e;
    console.warn('Faces skipped:', e);
    faces = [];   // faces are a bonus: never fail the whole upscale over them
  }
}

const handlers = {
  setSource(m) { src = m.src; base = null; faces = null; },

  // A run that's cancelled or fails leaves the last finished result in place for the sliders.
  async run(m) {
    const kept = { base, faces };
    try { await handlers.upscale(m); } catch (e) { ({ base, faces } = kept); throw e; }
  },

  async upscale(m) {
    currentRun = m.id;
    const started = performance.now();
    const progress = (stage, fraction) => postMessage({ type: 'progress', id: m.id, stage, fraction });
    const stopIfCancelled = () => { if (isCancelled()) throw new Error('cancelled'); };
    stopIfCancelled();
    let rebuiltFrom = 1;
    if (m.useAI) {
      const s = await session(MODELS[m.model].file, (t) => progress(t, 0));
      const r = await upscale(src, m.outW, m.outH, runner(s, 'image', 'upscaled', [1, 3, 256, 256]), progress, isCancelled);
      rebuiltFrom = r.rebuiltFrom;
      base = { rgba: r.rgba, w: r.w, h: r.h, detail: r.detail, useFinisher: true };
    } else {
      const rgba = await classicUpscale(src, m.outW, m.outH, m.preset, progress, isCancelled);
      if (src.hasAlpha) resizeAlphaInto(src.rgba, src.w, src.h, rgba, m.outW, m.outH);
      base = { rgba, w: m.outW, h: m.outH, detail: { rgba: src.rgba, w: src.w, h: src.h }, useFinisher: false };
    }
    faces = null;
    // Cancel pressed late (after the last tile) still stops the run rather than showing a result.
    stopIfCancelled();
    if (m.look.faces > 0.001) await workOutFaces((t) => progress(t, 0.985), isCancelled);
    stopIfCancelled();
    progress('Finishing touches', 0.99);
    const rgba = await compose(m.look);
    stopIfCancelled();
    postMessage({ type: 'result', id: m.id, rgba, w: base.w, h: base.h, rebuiltFrom, faceCount: faces?.length ?? 0,
                  took: (performance.now() - started) / 1000, backend }, [rgba.buffer]);
  },

  async compose(m) {
    if (!base) return;
    const needFaces = m.look.faces > 0.001 && faces === null;
    if (needFaces) await workOutFaces(() => {}, () => false);
    const rgba = await compose(m.look);
    postMessage({ type: 'composed', rgba, w: base.w, h: base.h, newFaces: needFaces ? faces.length : -1 }, [rgba.buffer]);
  },

  async autoPlan(m) {
    const found = await findFaces(src.rgba, src.w, src.h, await detector());
    const report = await analyze(src.rgba, src.w, src.h, found);
    postMessage({ type: 'plan', id: m.id, plan: plan(report, src.w, src.h) });
  },

};

let queue = Promise.resolve();
self.onmessage = (e) => {
  const m = e.data;
  if (m.type === 'cancel') { cancelUpTo = lastRunSeen; return; }   // acts at once, not in turn
  if (m.type === 'run') lastRunSeen = m.id;
  queue = queue.then(async () => {
    try {
      await handlers[m.type](m);
    } catch (err) {
      const msg = String(err?.message || err);
      postMessage({ type: msg === 'cancelled' ? 'cancelled' : 'error', id: m.id, job: m.type, message: msg });
    }
  });
};
postMessage({ type: 'ready' });
