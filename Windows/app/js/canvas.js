// The before/after view: the original under the result, the result shown right of a divider.
// Scroll (or pinch) zooms around the pointer, drag pans, drag the handle to compare,
// double-click switches between fit and actual pixels.

export class CompareView {
  constructor(canvas, knob) {
    this.c = canvas; this.knob = knob;
    this.ctx = canvas.getContext('2d');
    this.before = null; this.after = null;
    this.mode = 'split'; this.split = 0.5;
    this.s = 1; this.ox = 0; this.oy = 0; this.fitted = true;
    this.onSplit = () => {}; this.onZoom = () => {};
    this.drag = null;
    new ResizeObserver(() => this.resize()).observe(canvas.parentElement);
    canvas.addEventListener('wheel', (e) => this.wheel(e), { passive: false });
    canvas.addEventListener('pointerdown', (e) => this.down(e));
    canvas.addEventListener('pointermove', (e) => this.move(e));
    canvas.addEventListener('pointerup', (e) => this.up(e));
    canvas.addEventListener('pointercancel', (e) => this.up(e));
    canvas.addEventListener('dblclick', (e) => this.toggleZoom(e));
    knob.addEventListener('pointerdown', (e) => { e.stopPropagation(); knob.setPointerCapture(e.pointerId); this.drag = { kind: 'divider' }; });
    knob.addEventListener('pointermove', (e) => { if (this.drag?.kind === 'divider') this.dragSplit(e); });
    knob.addEventListener('pointerup', () => { this.drag = null; });
  }

  get dpr() { return window.devicePixelRatio || 1; }
  get size() {   // the image space: the result's size once there is one
    const im = this.after || this.before;
    return im ? [im.width, im.height] : [0, 0];
  }

  setImages(before, after) {
    const [ow, oh] = this.size;
    this.before = before; this.after = after;
    const [w, h] = this.size;
    if (w !== ow || h !== oh) this.fitted = true;
    if (this.fitted) this.fit(); else this.draw();
  }
  setMode(m) { this.mode = m; this.draw(); }
  setSplit(v) { this.split = v; this.draw(); }

  resize() {
    const r = this.c.parentElement.getBoundingClientRect();
    this.c.width = Math.max(1, Math.round(r.width * this.dpr));
    this.c.height = Math.max(1, Math.round(r.height * this.dpr));
    this.c.style.width = r.width + 'px'; this.c.style.height = r.height + 'px';
    if (this.fitted) this.fit(); else { this.clampPan(); this.draw(); }
  }

  fitScale() {
    const [w, h] = this.size;
    return w ? Math.min(this.c.width / w, this.c.height / h) * 0.94 : 1;
  }
  fit() {
    const [w, h] = this.size;
    if (!w) { this.draw(); return; }
    this.s = this.fitScale();
    this.ox = (this.c.width - w * this.s) / 2; this.oy = (this.c.height - h * this.s) / 2;
    this.fitted = true;
    this.draw();
  }
  zoomAt(factor, cx, cy) {
    const [w] = this.size;
    if (!w) return;
    const min = Math.min(this.fitScale(), 1) * 0.5, max = 32;
    const s = Math.min(max, Math.max(min, this.s * factor));
    this.ox = cx - (cx - this.ox) * (s / this.s);
    this.oy = cy - (cy - this.oy) * (s / this.s);
    this.s = s; this.fitted = false;
    this.clampPan(); this.draw();
  }
  zoomBy(f) { this.zoomAt(f, this.c.width / 2, this.c.height / 2); }
  actualPixels() { this.zoomAt(1 / this.s, this.c.width / 2, this.c.height / 2); }

  clampPan() {
    const [w, h] = this.size, W = w * this.s, H = h * this.s;
    this.ox = W <= this.c.width ? (this.c.width - W) / 2 : Math.min(0, Math.max(this.c.width - W, this.ox));
    this.oy = H <= this.c.height ? (this.c.height - H) / 2 : Math.min(0, Math.max(this.c.height - H, this.oy));
  }

  local(e) { const r = this.c.getBoundingClientRect(); return [(e.clientX - r.left) * this.dpr, (e.clientY - r.top) * this.dpr]; }

  wheel(e) {
    e.preventDefault();
    const [x, y] = this.local(e);
    if ((e.altKey || e.shiftKey) && !e.ctrlKey) {   // pan
      this.ox -= (e.shiftKey ? e.deltaY : e.deltaX) * this.dpr; this.oy -= (e.shiftKey ? 0 : e.deltaY) * this.dpr;
      this.fitted = false; this.clampPan(); this.draw();
      return;
    }
    const k = e.deltaMode === 1 ? 0.12 : e.ctrlKey ? 0.012 : 0.0025;   // lines, pinch, pixels
    this.zoomAt(Math.exp(-e.deltaY * k), x, y);
  }

  nearDivider(x) {
    if (this.mode !== 'split' || !this.after) return false;
    return Math.abs(x - (this.ox + this.size[0] * this.s * this.split)) < 8 * this.dpr;
  }
  down(e) {
    if (e.button !== 0) return;
    this.c.setPointerCapture(e.pointerId);
    const [x, y] = this.local(e);
    if (this.nearDivider(x)) this.drag = { kind: 'divider' };
    else { this.drag = { kind: 'pan', x, y, ox: this.ox, oy: this.oy }; this.c.style.cursor = 'grabbing'; }
  }
  move(e) {
    const [x, y] = this.local(e);
    if (!this.drag) { this.c.style.cursor = this.nearDivider(x) ? 'ew-resize' : 'grab'; return; }
    if (this.drag.kind === 'divider') return this.dragSplit(e);
    this.ox = this.drag.ox + (x - this.drag.x); this.oy = this.drag.oy + (y - this.drag.y);
    this.fitted = false; this.clampPan(); this.draw();
  }
  up() { this.drag = null; this.c.style.cursor = 'grab'; }
  dragSplit(e) {
    const [x] = this.local(e);
    this.split = Math.min(1, Math.max(0, (x - this.ox) / (this.size[0] * this.s)));
    this.onSplit(this.split); this.draw();
  }
  toggleZoom(e) {
    if (this.fitted || this.s < this.fitScale() * 1.05) {
      const [x, y] = this.local(e);
      this.zoomAt(Math.max(1, this.fitScale() * 3) / this.s, x, y);
    } else this.fit();
  }

  draw() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => { this.raf = 0; this.paint(); });
  }
  paint() {
    const { ctx, c } = this;
    ctx.clearRect(0, 0, c.width, c.height);
    const [w, h] = this.size;
    if (!w) { this.knob.hidden = true; return; }
    const dw = w * this.s, dh = h * this.s;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = this.s < 1 ? 'high' : 'low';
    const showBefore = !(this.after && this.mode === 'after');
    const showAfter = this.after && this.mode !== 'before';
    if (showBefore && this.before) ctx.drawImage(this.before, this.ox, this.oy, dw, dh);
    if (showAfter) {
      if (this.mode === 'split') {
        const x = Math.round(this.ox + dw * this.split);
        ctx.save(); ctx.beginPath(); ctx.rect(x, 0, c.width - x, c.height); ctx.clip();
        ctx.drawImage(this.after, this.ox, this.oy, dw, dh);
        ctx.restore();
        ctx.save();
        ctx.shadowColor = 'rgba(0,0,0,0.45)'; ctx.shadowBlur = 4 * this.dpr;
        ctx.fillStyle = 'rgba(255,255,255,0.95)';
        ctx.fillRect(x - this.dpr, Math.max(0, this.oy), 2 * this.dpr, Math.min(c.height, this.oy + dh) - Math.max(0, this.oy));
        ctx.restore();
      } else ctx.drawImage(this.after, this.ox, this.oy, dw, dh);
    }
    // The round handle sits on the divider, in the middle of the visible part of the image.
    const showKnob = this.after && this.mode === 'split';
    if (showKnob) {
      const x = (this.ox + dw * this.split) / this.dpr;
      const top = Math.max(0, this.oy), bot = Math.min(c.height, this.oy + dh);
      const y = (top + bot) / 2 / this.dpr;
      this.knob.style.transform = `translate(${x - 19}px, ${y - 19}px)`;
      this.knob.hidden = x < 2 || x > c.width / this.dpr - 2;
    } else this.knob.hidden = true;
    this.onZoom(this.s * 100);
  }
}
