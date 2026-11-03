// Texel for Windows: the interface. Same state, defaults, texts and flow as the Mac/iPhone app
// (AppState.swift + ContentView.swift); the heavy work runs in engine/worker.js.
import { icon } from './icons.js';
import { CompareView } from './canvas.js';
import { MODELS, MAX_SIDE, MAX_OUTPUT_PIXELS } from '../engine/upscaler.js';
import { PRESETS, CLASSIC_MAX_PIXELS } from '../engine/classic.js';

const $ = (id) => document.getElementById(id);
const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
const scaleText = (s) => `${s}×`;

// ---------------------------------------------------------------- state

const S = {
  source: null,          // { name, w, h, bitmap }
  result: null,          // { w, h, bitmap }
  scale: 2, useAI: true, aiModel: 'photo', preset: 'best',
  isRunning: false, isLoading: false, isExporting: false, isAnalyzing: false, isBlending: false,
  progress: 0, stage: '', startedAt: 0, lastDuration: null, resultLabel: '',
  viewMode: 'split', split: 0.5, zoom: 0,
  aiStrength: 1, detail: 0.35, sharpen: 0.25, smooth: 0.35,
  restoreFaces: true, faceStrength: 0.7, autoEnhance: true, enhanceAmount: 0.6,
  isSaved: false, autoSummary: null, tab: 'finish', hasBase: false,
};

const look = () => ({ strength: S.aiStrength, detail: S.detail, sharpen: S.sharpen, smooth: S.smooth,
                      faces: S.restoreFaces ? S.faceStrength : 0, enhance: S.autoEnhance ? S.enhanceAmount : 0 });
const sameLook = (a, b) => Object.keys(a).every((k) => Math.abs(a[k] - b[k]) < 0.001);
const outputSize = () => S.source ? [Math.max(1, Math.round(S.source.w * S.scale)), Math.max(1, Math.round(S.source.h * S.scale))] : null;

function blocker() {
  const size = outputSize();
  if (!size) return null;
  const [w, h] = size;
  if (S.useAI) {
    if (w > MAX_SIDE || h > MAX_SIDE || w * h > MAX_OUTPUT_PIXELS) return `${w} × ${h} is too large for this PC. Pick a smaller scale.`;
  } else {
    if (S.scale === 1) return '1× (enhance without enlarging) needs AI mode.';
    if (w * h > CLASSIC_MAX_PIXELS || w > MAX_SIDE || h > MAX_SIDE) return `${w} × ${h} is too large for Classic on this PC. Use AI or a smaller scale.`;
  }
  return null;
}

// ---------------------------------------------------------------- engine

const worker = new Worker(new URL('../engine/worker.js', import.meta.url), { type: 'module' });
let runLook = null, blendLook = null, pendingBlend = false;
let backend = '';

worker.onmessage = async (e) => {
  const m = e.data;
  switch (m.type) {
    case 'progress':
      if (!S.isRunning) return;
      S.stage = m.stage; if (m.fraction != null) S.progress = Math.max(S.progress, m.fraction);
      syncRun();
      break;
    case 'result': {
      backend = m.backend || backend;
      const bitmap = await createImageBitmap(new ImageData(m.rgba, m.w, m.h));
      finishRun();
      const old = S.result?.bitmap;
      S.result = { w: m.w, h: m.h, bitmap };
      S.hasBase = true; S.isSaved = false; S.lastDuration = m.took; S.viewMode = 'split';
      view.setImages(S.source.bitmap, bitmap);
      old?.close?.();
      revealResult();
      if (m.rebuiltFrom > 1) toast(`Pixelated image detected. Rebuilt from ${Math.floor(S.source.w / m.rebuiltFrom)}×${Math.floor(S.source.h / m.rebuiltFrom)}`, 'wand', true);
      else if (m.faceCount > 0 && runLook.faces > 0) toast(m.faceCount === 1 ? 'Restored 1 face' : `Restored ${m.faceCount} faces`, 'smile', true);
      sync();
      if (!sameLook(look(), runLook)) applyDetail();
      break;
    }
    case 'composed': {
      const bitmap = await createImageBitmap(new ImageData(m.rgba, m.w, m.h));
      S.isBlending = false;
      if (S.result) { S.result.bitmap.close?.(); S.result = { w: m.w, h: m.h, bitmap }; S.isSaved = false; view.setImages(S.source.bitmap, bitmap); }
      if (m.newFaces > 0) toast(m.newFaces === 1 ? 'Restored 1 face' : `Restored ${m.newFaces} faces`, 'smile', true);
      sync();
      if (pendingBlend || !sameLook(look(), blendLook)) { pendingBlend = false; applyDetail(); }
      break;
    }
    case 'plan': {
      S.isAnalyzing = false;
      const p = m.plan;
      Object.assign(S, { useAI: true, aiModel: p.model, scale: p.scale, aiStrength: p.aiStrength, detail: p.detail,
                         smooth: p.smooth, sharpen: p.sharpen, restoreFaces: p.restoreFaces, faceStrength: p.faceStrength,
                         autoEnhance: p.autoEnhance, enhanceAmount: p.enhanceAmount, autoSummary: p.summary, tab: 'finish' });
      sync();
      const b = blocker();
      if (b) alertBox('Something went wrong', b); else run();
      break;
    }
    case 'cancelled': finishRun(); sync(); break;
    case 'error':
      if (m.job === 'run') finishRun();
      if (m.job === 'compose') S.isBlending = false;
      if (m.job === 'autoPlan') S.isAnalyzing = false;
      sync();
      alertBox('Something went wrong', friendlyError(m.message));
      break;
  }
};

function friendlyError(msg) {
  if (/memory|allocation|OOM/i.test(msg)) return 'Your PC ran out of memory for an image this size. Try a smaller scale.';
  return msg;
}

function run() {
  const size = outputSize();
  if (!S.source || S.isRunning || blocker() || !size) return;
  const [outW, outH] = size;
  const sizeLabel = S.scale === 1 ? 'Enhanced' : scaleText(S.scale);
  S.resultLabel = S.useAI ? `AI ${MODELS[S.aiModel].title} ${sizeLabel}` : `${PRESETS[S.preset].title} ${sizeLabel}`;
  runLook = look();
  Object.assign(S, { isRunning: true, progress: 0, stage: 'Starting…', startedAt: performance.now() });
  sync();
  worker.postMessage({ type: 'run', outW, outH, useAI: S.useAI, model: S.aiModel, preset: S.preset, look: runLook });
}
function finishRun() { S.isRunning = false; S.stage = ''; }
function cancel() { worker.postMessage({ type: 'cancel' }); S.stage = 'Cancelling…'; syncRun(); }

/** Re-composes the finishing sliders and Enhance on the last upscale, without running it again. */
function applyDetail() {
  if (!S.hasBase || S.isRunning) return;
  if (S.isBlending) { pendingBlend = true; return; }
  S.isBlending = true; blendLook = look();
  syncBusy();
  worker.postMessage({ type: 'compose', look: blendLook });
}

function autoFix() {
  if (!S.source || S.isRunning || S.isAnalyzing) return;
  S.isAnalyzing = true; sync();
  worker.postMessage({ type: 'autoPlan' });
}

/** Wipes the result in from the right, settling the divider in the middle. */
function revealResult() {
  const start = performance.now(), id = ++revealId;
  const step = () => {
    if (id !== revealId) return;
    const t = Math.min(1, (performance.now() - start) / 900);
    S.split = 1 - 0.5 * (1 - Math.pow(1 - t, 3));
    view.setSplit(S.split);
    if (t < 1) requestAnimationFrame(step);
  };
  step();
}
let revealId = 0;

// ---------------------------------------------------------------- opening images

async function openData(name, data) {
  if (S.isRunning) return;
  S.isLoading = true; syncOverlays();
  try {
    const blob = new Blob([data]);
    let bitmap;
    try {
      bitmap = await createImageBitmap(blob, { imageOrientation: 'from-image', premultiplyAlpha: 'none' });
    } catch {
      throw new Error('That image couldn’t be read. Texel on Windows opens PNG, JPEG, WebP, AVIF, BMP and GIF files.');
    }
    const w = bitmap.width, h = bitmap.height;
    if (w * h > 120_000_000) throw new Error(`${w} × ${h} is too large to open.`);
    const c = new OffscreenCanvas(w, h);
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(bitmap, 0, 0);
    const rgba = ctx.getImageData(0, 0, w, h).data;
    let hasAlpha = false;
    for (let i = 3; i < rgba.length; i += 4) if (rgba[i] < 255) { hasAlpha = true; break; }
    worker.postMessage({ type: 'setSource', src: { rgba, w, h, hasAlpha } }, [rgba.buffer]);
    S.source?.bitmap.close?.(); S.result?.bitmap.close?.();
    Object.assign(S, { source: { name, w, h, bitmap }, result: null, hasBase: false, lastDuration: null, resultLabel: '',
                       viewMode: 'split', split: 0.5, isSaved: false, autoSummary: null });
    view.split = 0.5; view.mode = 'split';
    showEditor();
    view.fitted = true;
    view.setImages(bitmap, null);
  } catch (err) {
    alertBox('Something went wrong', err.message);
  } finally {
    S.isLoading = false; sync();
  }
}

async function openDialog() {
  if (S.isRunning) return;
  const f = await window.texel.openImage();
  if (f) openData(f.name, f.data);
}

async function pasteImage(items) {
  for (const it of items) {
    if (it.kind === 'file' && it.type.startsWith('image/')) { const f = it.getAsFile(); return openData('Pasted image.png', await f.arrayBuffer()); }
  }
  try {
    const clip = await navigator.clipboard.read();
    for (const c of clip) {
      const t = c.types.find((x) => x.startsWith('image/'));
      if (t) return openData('Pasted image.png', await (await c.getType(t)).arrayBuffer());
    }
  } catch { /* fall through */ }
  toast('There’s no image on the clipboard', 'info', true);
}

function goHome() {
  if (S.isRunning) { worker.postMessage({ type: 'cancel' }); finishRun(); }
  revealId++;
  S.source?.bitmap.close?.(); S.result?.bitmap.close?.();
  Object.assign(S, { source: null, result: null, hasBase: false, isSaved: false, lastDuration: null, resultLabel: '',
                     viewMode: 'split', split: 0.5, progress: 0, stage: '', autoSummary: null });
  view.setImages(null, null);
  showHome();
  sync();
}

/** Asks before leaving when that would stop a run or discard an unsaved result. */
function requestExit(then = goHome) {
  if (S.isRunning) {
    confirmBox('Stop and exit?', 'The upscale in progress will be stopped and you’ll go back to the start.',
      [{ label: 'Stop and Exit', cls: 'danger', act: then }, { label: 'Cancel' }]);
  } else if (S.result && !S.isSaved) {
    confirmBox('Exit without saving?', 'Your upscaled image hasn’t been saved. If you exit now, it’s gone.',
      [{ label: 'Save & Exit', cls: 'primary', act: () => save('png', then) },
       { label: 'Exit Without Saving', cls: 'danger', act: then }, { label: 'Cancel' }]);
  } else then();
}

// ---------------------------------------------------------------- saving

const FORMATS = { png: ['image/png', 'png'], jpg: ['image/jpeg', 'jpg'], webp: ['image/webp', 'webp'] };

async function save(fmt = 'png', then) {
  if (!S.result || S.isRunning || S.isExporting) return;
  S.isExporting = true; syncToolbar();
  try {
    const { w, h, bitmap } = S.result;
    const c = new OffscreenCanvas(w, h);
    const ctx = c.getContext('2d');
    if (fmt === 'jpg') { ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, w, h); }
    ctx.drawImage(bitmap, 0, 0);
    const blob = await c.convertToBlob({ type: FORMATS[fmt][0], quality: fmt === 'png' ? undefined : 0.92 });
    const base = S.source.name.replace(/\.[^.]+$/, '');
    const suffix = S.scale === 1 ? 'enhanced' : `${S.scale}x`;
    const saved = await window.texel.saveImage(`${base}-texel-${suffix}.${FORMATS[fmt][1]}`, FORMATS[fmt][1], await blob.arrayBuffer());
    if (saved) { S.isSaved = true; toast(`Saved ${saved}`); then?.(); }
  } catch (err) {
    alertBox('Something went wrong', err.message);
  } finally {
    S.isExporting = false; sync();
  }
}

// ---------------------------------------------------------------- building the interface

const view = new CompareView($('view'), $('knob'));
view.onSplit = (v) => { S.split = v; };
view.onZoom = (z) => { if (Math.abs(z - S.zoom) > 0.4) { S.zoom = z; syncInfo(); } };
$('knob').innerHTML = icon('leftRight');

$('btnClose').innerHTML = icon('x');
$('btnAdd').innerHTML = icon('plus');
$('btnSaveMenu').innerHTML = icon('chevron');
$('tbSpark').innerHTML = icon('sparkles');
$('btnAbout').innerHTML = icon('info');
$('dropIcon').innerHTML = icon('image');
$('btnOpen').innerHTML = `${icon('folder')}<span>Open an Image…</span>`;
$('btnOpen').classList.add('shine');
$('btnPaste').innerHTML = `${icon('paste')}<span>Paste from Clipboard</span>`;
$('features').innerHTML = [['cpu', 'On-device AI'], ['expand', 'Up to 8×'], ['lock', 'Private']]
  .map(([i, t], n) => `<span class="feature st" style="--i:${3 + n}">${icon(i)}${t}</span>`).join('');

$('btnOpen').onclick = openDialog;
$('btnPaste').onclick = () => pasteImage([]);
$('btnAbout').onclick = showAbout;
$('btnClose').onclick = () => requestExit();
$('btnAdd').onclick = (e) => showMenu($('addMenu'), e.currentTarget, [
  { label: 'Open an Image…', icon: 'folder', kbd: 'Ctrl+O', act: () => requestExit(openDialog) },
  { label: 'Paste from Clipboard', icon: 'paste', kbd: 'Ctrl+V', act: () => requestExit(() => pasteImage([])) },
]);
$('btnSave').onclick = () => save('png');
$('btnSaveMenu').onclick = (e) => showMenu($('saveMenu'), e.currentTarget, [
  { section: 'Save as' },
  { label: 'PNG · lossless', act: () => save('png') },
  { label: 'JPEG', act: () => save('jpg') },
  { label: 'WebP · small', act: () => save('webp') },
]);

/** Segmented control with a sliding highlight. */
function pills(options, get, set, compact = false) {
  const root = el('div', 'pills' + (compact ? ' compact' : ''));
  const hl = el('div', 'hlt'); root.appendChild(hl);
  const buttons = options.map((o) => {
    const b = el('button', '', `${o.icon ? icon(o.icon) : ''}<span>${o.title}</span>`);
    b.onclick = () => { if (get() !== o.value) { set(o.value); sync(); } };
    root.appendChild(b);
    return b;
  });
  root.update = () => {
    const i = options.findIndex((o) => o.value === get());
    buttons.forEach((b, n) => b.classList.toggle('on', n === i));
    const b = buttons[i];
    if (b && b.offsetWidth) { hl.style.width = b.offsetWidth + 'px'; hl.style.transform = `translateX(${b.offsetLeft}px)`; hl.hidden = false; }
    else hl.hidden = i < 0;
  };
  root.setTitles = (titles) => buttons.forEach((b, n) => { b.querySelector('span').textContent = titles[n]; });
  return root;
}
function row(label, child) { const r = el('div', 'row'); r.appendChild(el('label', '', label)); r.appendChild(child); return r; }

function slider(label, key, tint) {
  const r = el('div', 'slider');
  r.appendChild(el('label', '', label));
  const input = el('input'); input.type = 'range'; input.min = 0; input.max = 1; input.step = 0.01;
  input.style.setProperty('--tint', tint);
  const out = el('output');
  r.append(input, out);
  input.oninput = () => { S[key] = +input.value; paint(); };
  input.onchange = () => applyDetail();   // when the mouse is released
  const paint = () => { input.style.setProperty('--fill', `${S[key] * 100}%`); out.textContent = `${Math.round(S[key] * 100)}%`; };
  r.update = () => { if (document.activeElement !== input || !input.matches(':active')) input.value = S[key]; paint(); out.classList.toggle('busy', S.isBlending); };
  return r;
}

/** An on/off pill plus a strength slider (Enhance). */
function toggleRow(label, iconName, onKey, valueKey, tint) {
  const r = el('div', 'slider');
  const t = el('button', 'toggle', `${icon(iconName)}<span>${label}</span>`);
  t.style.setProperty('--tint', tint);
  t.onclick = () => { S[onKey] = !S[onKey]; sync(); applyDetail(); };
  const input = el('input'); input.type = 'range'; input.min = 0; input.max = 1; input.step = 0.01;
  input.style.setProperty('--tint', tint);
  const out = el('output');
  r.append(t, input, out);
  input.oninput = () => { S[valueKey] = +input.value; paint(); };
  input.onchange = () => applyDetail();
  const paint = () => {
    input.style.setProperty('--fill', `${S[valueKey] * 100}%`);
    out.textContent = S[onKey] ? `${Math.round(S[valueKey] * 100)}%` : 'Off';
  };
  r.update = () => { t.classList.toggle('on', S[onKey]); input.disabled = !S[onKey]; input.value = S[valueKey]; paint(); out.classList.toggle('busy', S.isBlending); };
  return r;
}

const P = {};
function buildPanel() {
  const panel = $('panel');
  P.view = pills([{ value: 'split', title: 'Split', icon: 'split' }, { value: 'before', title: 'Before' }, { value: 'after', title: 'After' }],
    () => S.viewMode, (v) => { S.viewMode = v; view.setMode(v); }, true);

  P.auto = el('button', 'autofix');
  P.auto.onclick = autoFix;

  P.size = pills([1, 2, 3, 4, 6, 8].map((v) => ({ value: v, title: `${v}×` })), () => S.scale, (v) => { S.scale = v; });
  P.mode = pills([{ value: true, title: 'AI', icon: 'sparkles' }, { value: false, title: 'Classic', icon: 'cpu' }], () => S.useAI, (v) => { S.useAI = v; });

  P.chips = el('div', 'chips');
  for (const [m, ic, tag] of [['photo', 'aperture', 'BEST'], ['general', 'bolt', 'FAST'], ['anime', 'palette', 'ART']]) {
    const b = el('button', 'chip', `${icon(ic)}<b>${MODELS[m].title}</b><small>${tag}</small>`);
    b.dataset.model = m;
    b.onclick = () => { S.aiModel = m; sync(); };
    P.chips.appendChild(b);
  }

  P.tab = pills([{ value: 'finish', title: 'Finish', icon: 'sliders' }, { value: 'enhance', title: 'Enhance', icon: 'wand' }],
    () => S.tab, (v) => { S.tab = v; }, true);
  P.sliders = el('div', 'sliders'); P.sliders.style.cssText = 'display:flex;flex-direction:column;gap:12px';
  P.sl = [slider('AI', 'aiStrength', '#2dd4bf'), slider('Detail', 'detail', 'var(--violet)'),
          slider('Smooth', 'smooth', 'var(--indigo)'), slider('Sharp', 'sharpen', 'var(--gold)')];
  P.sliders.append(...P.sl);
  P.preset = pills(Object.entries(PRESETS).map(([k, v]) => ({ value: k, title: v.title })), () => S.preset, (v) => { S.preset = v; }, true);
  P.enh = el('div'); P.enh.style.cssText = 'display:flex;flex-direction:column;gap:12px';
  P.tg = [toggleRow('Faces', 'smile', 'restoreFaces', 'faceStrength', '#9e6bfa'), toggleRow('Colour', 'sun', 'autoEnhance', 'enhanceAmount', '#ffcc73')];
  P.enh.append(...P.tg);

  P.status = el('div', 'status');
  P.go = el('button', 'go shine');
  P.go.onclick = run;

  panel.append(P.view, P.auto, row('Size', P.size), row('Mode', P.mode), P.chips, P.tab, P.sliders, P.preset, P.enh, P.status, P.go);
}

function buildRunCard() {
  const c = $('runcard');
  c.innerHTML = `
    <div class="run-top">
      <div class="ring">
        <svg viewBox="0 0 64 64"><defs><linearGradient id="rg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5c70ff"/><stop offset=".55" stop-color="#9e6bfa"/><stop offset="1" stop-color="#ffcc73"/></linearGradient></defs>
          <circle cx="32" cy="32" r="28.5" fill="none" stroke="rgba(255,255,255,.1)" stroke-width="7"/>
          <circle id="ringArc" cx="32" cy="32" r="28.5" fill="none" stroke="url(#rg)" stroke-width="7" stroke-linecap="round" stroke-dasharray="179.07" stroke-dashoffset="175" style="transition:stroke-dashoffset .4s ease-out"/></svg>
        <svg class="orbit" viewBox="0 0 78 78"><circle cx="39" cy="39" r="37" fill="none" stroke="rgba(255,255,255,.25)" stroke-width="2" stroke-linecap="round" stroke-dasharray="27.9 232.5"/></svg>
        <div class="pct" id="runPct">0%</div>
      </div>
      <div class="run-text"><b id="runTitle">Upscaling with AI</b><div class="stage-t" id="runStage"></div><div class="time" id="runTime">0.0 s</div></div>
    </div>
    <div class="run-buttons"><button id="runCancel">${icon('stop')}Cancel</button><button id="runHome">${icon('home')}Start Over</button></div>
    <div class="note">Keep Texel open until it finishes.</div>`;
  $('runCancel').onclick = cancel;
  $('runHome').onclick = () => requestExit();
}

// ---------------------------------------------------------------- syncing the interface with the state

function sync() {
  syncToolbar(); syncOverlays(); syncInfo();
  $('aurora').classList.toggle('dim', !!S.source);
  if (!S.source) return;
  $('panel').hidden = S.isRunning;
  $('runcard').hidden = !S.isRunning;
  $('scan').hidden = !S.isRunning;
  if (S.isRunning) { syncRun(); return; }

  P.view.hidden = !S.result;
  const b = blocker();
  P.auto.disabled = S.isAnalyzing || S.isRunning;
  P.auto.innerHTML = `${icon('wand')}<span class="t"><b>Auto Fix</b><small>${S.isAnalyzing ? 'Looking for blur, noise, faces and lighting…' : 'Finds what’s wrong and fixes it, keeping the look'}</small></span>${S.isAnalyzing ? '<span class="spinner"></span>' : icon('arrowRight')}`;
  P.chips.hidden = !S.useAI;
  for (const c of P.chips.children) c.classList.toggle('on', c.dataset.model === S.aiModel);
  P.tab.setTitles([S.useAI ? 'Finish' : 'Quality', 'Enhance']);
  P.sliders.hidden = !(S.tab === 'finish' && S.useAI);
  P.preset.hidden = !(S.tab === 'finish' && !S.useAI);
  P.enh.hidden = S.tab !== 'enhance';
  for (const p of [P.view, P.size, P.mode, P.tab, P.preset]) p.update();
  for (const s of [...P.sl, ...P.tg]) s.update();

  let status;
  if (b) status = `<div class="status warn">${icon('warning')}<span>${b}</span></div>`;
  else if (S.autoSummary && S.tab === 'finish') status = `<div class="status auto">${icon('wand')}<span>${S.autoSummary}</span></div>`;
  else if (S.scale === 1 && S.tab === 'finish') status = '<div class="status">1× keeps the size and rebuilds the image: the AI redraws it at 4× detail, then shrinks it back, removing blur, noise and compression.</div>';
  else if (S.tab === 'enhance') status = '<div class="status">Faces redraws blurry faces with a face AI. Colour fixes light and colour and adds clarity to texture like trees and fabric.</div>';
  else status = `<div class="status">${S.useAI ? MODELS[S.aiModel].summary : PRESETS[S.preset].summary}</div>`;
  P.status.outerHTML = status;
  P.status = $('panel').querySelector('.status');

  const size = outputSize();
  P.go.disabled = S.isRunning || !!b;
  P.go.classList.toggle('off', P.go.disabled);
  P.go.innerHTML = `${icon('sparkles')}<span class="t"><b>${S.scale === 1 ? 'Enhance with AI' : S.useAI ? 'Upscale with AI' : 'Upscale'}</b>
    <small>${size ? (S.scale === 1 ? `Same size · ${size[0].toLocaleString()} × ${size[1].toLocaleString()} px` : `→ ${size[0].toLocaleString()} × ${size[1].toLocaleString()} px`) : ''}</small></span>${icon('arrowRight')}`;
  P.go.title = 'Ctrl+Enter';
}

function syncBusy() { if (S.source && !S.isRunning) for (const s of [...P.sl, ...P.tg]) s.update(); }

function syncRun() {
  const p = Math.max(0.02, S.progress);
  $('ringArc').style.strokeDashoffset = 179.07 * (1 - p);
  $('runPct').textContent = `${Math.round(S.progress * 100)}%`;
  $('runTitle').textContent = S.useAI ? (S.scale === 1 ? 'Enhancing with AI' : 'Upscaling with AI') : 'Upscaling';
  $('runStage').textContent = S.stage;
}
setInterval(() => { if (S.isRunning) $('runTime').textContent = `${((performance.now() - S.startedAt) / 1000).toFixed(1)} s`; }, 100);

function syncToolbar() {
  const has = !!S.source;
  $('btnClose').hidden = !has; $('tbGroup').hidden = !has; $('tbTitle').hidden = !has;
  $('btnAdd').disabled = S.isRunning;
  const canSave = !!S.result && !S.isRunning && !S.isExporting;
  $('btnSave').disabled = !canSave; $('btnSaveMenu').disabled = !canSave;
  $('btnSave').classList.toggle('saved', S.isSaved);
  $('btnSave').innerHTML = S.isExporting ? '<span class="spinner"></span>' : icon(S.isSaved ? 'check' : 'save');
  $('btnSave').title = S.isSaved ? 'Saved' : 'Save as PNG (Ctrl+S)';
}

function syncOverlays() { $('loading').hidden = !S.isLoading; }

function syncInfo() {
  const s = S.source;
  const info = $('info'), tb = $('tagBefore'), ta = $('tagAfter');
  if (!s) return;
  const show = !!S.result && !S.isRunning;
  tb.hidden = ta.hidden = !show;
  tb.classList.toggle('gone-l', S.viewMode === 'after');
  ta.classList.toggle('gone-r', S.viewMode === 'before');
  ta.textContent = `AFTER · ${S.resultLabel.toUpperCase()}`;
  info.hidden = S.isRunning;
  const parts = [];
  if (S.result) {
    parts.push(`${s.w}×${s.h} → ${S.result.w}×${S.result.h}`);
    if (S.lastDuration != null) parts.push(`${S.lastDuration.toFixed(1)} s`);
  } else parts.push(`${s.w} × ${s.h}`);
  if (S.zoom > 0) parts.push(`${Math.round(S.zoom)}%`);
  info.textContent = parts.join('  ·  ');
}

function showEditor() { $('home').hidden = true; $('editor').hidden = false; requestAnimationFrame(() => { view.resize(); sync(); }); }
function showHome() { $('editor').hidden = true; $('home').hidden = false; }

// ---------------------------------------------------------------- toasts, menus, dialogs

let toastTimer;
function toast(text, iconName = 'check', gold = false) {
  const t = $('toast');
  t.innerHTML = `${icon(iconName, gold ? 'gold' : '')}<span>${text}</span>`;
  t.hidden = false; t.style.animation = 'none'; void t.offsetWidth; t.style.animation = '';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 3000);
}

function showMenu(menu, anchor, items) {
  menu.innerHTML = '';
  for (const it of items) {
    if (it.section) { menu.appendChild(el('div', 'sec', it.section)); continue; }
    const b = el('button', '', `${it.icon ? icon(it.icon) : ''}<span>${it.label}</span>${it.kbd ? `<kbd>${it.kbd}</kbd>` : ''}`);
    b.onclick = () => { menu.hidden = true; it.act(); };
    menu.appendChild(b);
  }
  const r = anchor.getBoundingClientRect();
  menu.hidden = false;
  menu.style.top = `${r.bottom + 6}px`;
  menu.style.left = `${Math.min(window.innerWidth - menu.offsetWidth - 10, r.right - menu.offsetWidth + 20)}px`;
}
document.addEventListener('pointerdown', (e) => {
  for (const m of [$('saveMenu'), $('addMenu')]) if (!m.hidden && !m.contains(e.target)) m.hidden = true;
}, true);

function confirmBox(title, text, actions) {
  const d = $('dialog');
  d.className = 'dialog glass';
  d.innerHTML = `<h2>${title}</h2><p>${text}</p><div class="actions"></div>`;
  for (const a of actions) {
    const b = el('button', a.cls || '', a.label);
    b.onclick = () => { $('modal').hidden = true; a.act?.(); };
    d.querySelector('.actions').appendChild(b);
  }
  $('modal').hidden = false;
  d.querySelector('.actions button').focus();
}
function alertBox(title, text) { confirmBox(title, text, [{ label: 'OK', cls: 'primary' }]); }

async function showAbout() {
  const info = await window.texel.appInfo();
  const esrgan = await window.texel.readText('licenses/LICENSE-Real-ESRGAN.txt');
  const d = $('dialog');
  d.className = 'dialog glass about';
  d.innerHTML = `
    <div class="about-head"><img src="img/logo.png" alt=""><div class="t"><b>Texel</b><small>Version ${info.version} · Windows</small></div><button id="aboutDone">Done</button></div>
    <h3>Privacy</h3><p>Texel upscales your images entirely on this PC. It doesn’t collect, upload or share any data, and has no accounts, ads or tracking.</p>
    <h3>How it works</h3><p>AI mode uses Real-ESRGAN neural networks running on your graphics card through WebGPU (or the processor if the graphics card can’t). Enhance redraws faces with GFPGAN and fixes colour and light automatically. Classic mode uses GPU shaders: edge-directed upscaling (AMD FidelityFX Super Resolution 1), detail refinement and contrast-adaptive sharpening.${backend ? ` This PC is using the ${backend === 'GPU' ? 'graphics card' : 'processor'}.` : ''}</p>
    <h3>Acknowledgements</h3>
    <p>The upscaling models are converted from Real-ESRGAN (<a data-href="https://github.com/xinntao/Real-ESRGAN">github.com/xinntao/Real-ESRGAN</a>) and are used under the BSD 3-Clause License:</p>
    <pre>${esrgan.replace(/</g, '&lt;')}</pre>
    <p style="margin-top:12px">Face restoration uses GFPGAN v1.4 by Xintao Wang et al. (Apache License 2.0). Faces are found with YuNet by Shiqi Yu (MIT License). Built with ONNX Runtime (MIT), Electron (MIT) and the Nunito typeface (SIL Open Font License). The full licences are in the app’s <i>licenses</i> folder.</p>`;
  $('modal').hidden = false;
  $('aboutDone').onclick = () => { $('modal').hidden = true; };
  d.querySelectorAll('a[data-href]').forEach((a) => { a.onclick = () => window.texel.openLink(a.dataset.href); });
}
$('modal').addEventListener('pointerdown', (e) => { if (e.target === $('modal') && $('dialog').classList.contains('about')) $('modal').hidden = true; });

// ---------------------------------------------------------------- keyboard, drag and drop, closing

document.addEventListener('keydown', (e) => {
  if (!$('modal').hidden) {
    if (e.key === 'Escape') $('modal').hidden = true;
    return;
  }
  const k = e.key.toLowerCase();
  if (e.ctrlKey && k === 'o') { e.preventDefault(); S.source ? requestExit(openDialog) : openDialog(); }
  else if (e.ctrlKey && k === 's') { e.preventDefault(); save('png'); }
  else if (e.ctrlKey && e.key === 'Enter') { e.preventDefault(); run(); }
  else if (e.ctrlKey && e.shiftKey && k === 'a') { e.preventDefault(); autoFix(); }
  else if (e.ctrlKey && (k === '=' || k === '+')) { e.preventDefault(); view.zoomBy(1.25); }
  else if (e.ctrlKey && k === '-') { e.preventDefault(); view.zoomBy(0.8); }
  else if (e.ctrlKey && k === '0') { e.preventDefault(); view.fit(); }
  else if (e.ctrlKey && k === '1') { e.preventDefault(); view.actualPixels(); }
  else if (e.key === 'Escape' && S.source) requestExit();
});
document.addEventListener('paste', (e) => {
  if (S.isRunning) return;
  const items = [...(e.clipboardData?.items || [])];
  if (items.some((i) => i.type.startsWith('image/'))) { e.preventDefault(); S.source ? requestExit(() => pasteImage(items)) : pasteImage(items); }
});

let dragDepth = 0;
window.addEventListener('dragenter', (e) => { e.preventDefault(); if (!S.isRunning && ++dragDepth === 1) $('drop').hidden = false; });
window.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; $('drop').hidden = true; } });
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', async (e) => {
  e.preventDefault(); dragDepth = 0; $('drop').hidden = true;
  const f = [...(e.dataTransfer?.files || [])][0];
  if (!f || S.isRunning) return;
  const data = await f.arrayBuffer();
  S.source ? requestExit(() => openData(f.name, data)) : openData(f.name, data);
});

window.texel.onCloseRequested(() => requestExit(() => window.texel.confirmClose()));
window.addEventListener('resize', () => { if (S.source && !S.isRunning) for (const p of [P.view, P.size, P.mode, P.tab, P.preset]) p.update(); });

buildPanel();
buildRunCard();
sync();
document.fonts.ready.then(() => sync());
