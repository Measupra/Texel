// Classic (non-AI) upscaling on the GPU with WebGL2: AMD FidelityFX Super Resolution 1 (EASU) in
// 2× steps, iterative back-projection to stay faithful to the original pixels, then RCAS sharpening.

export const PRESETS = {
  fast: { title: 'Fast', summary: 'One edge-directed pass. Instant.', progressive: false, refine: 0, sharp: 0 },
  balanced: { title: 'Balanced', summary: 'Edge-directed 2× steps, 4 detail-refinement passes and light sharpening.', progressive: true, refine: 4, sharp: 0.3 },
  best: { title: 'Best', summary: 'Edge-directed 2× steps, then 10 detail-refinement passes. Takes longest, sharpest result.', progressive: true, refine: 10, sharp: 0.25 },
};
export const CLASSIC_MAX_PIXELS = 64_000_000;

const VS = `#version 300 es
void main(){ vec2 p = vec2(float((gl_VertexID<<1)&2), float(gl_VertexID&2)); gl_Position = vec4(p*2.0-1.0, 0.0, 1.0); }`;
const HEAD = `#version 300 es
precision highp float; precision highp int;
uniform highp sampler2D uTex; uniform highp sampler2D uTex2; uniform vec2 uIn; uniform vec2 uOut; uniform float uSharp;
out vec4 frag;
vec4 T(ivec2 p){ return texelFetch(uTex, clamp(p, ivec2(0), ivec2(uIn)-1), 0); }
float Lu(vec3 c){ return c.b*0.5 + (c.r*0.5 + c.g); }
`;
const FS = {
  easu: `
void setW(inout vec2 dir, inout float len, float w, float lA, float lB, float lC, float lD, float lE){
  float lenX = max(abs(lD-lC), abs(lC-lB)); lenX = 1.0/max(lenX, 1e-5);
  float dirX = lD-lB; dir.x += dirX*w;
  lenX = clamp(abs(dirX)*lenX, 0.0, 1.0); lenX *= lenX; len += lenX*w;
  float lenY = max(abs(lE-lC), abs(lC-lA)); lenY = 1.0/max(lenY, 1e-5);
  float dirY = lE-lA; dir.y += dirY*w;
  lenY = clamp(abs(dirY)*lenY, 0.0, 1.0); lenY *= lenY; len += lenY*w;
}
void tap(inout vec3 aC, inout float aW, vec2 off, vec2 dir, vec2 len, float lob, float clp, vec3 c){
  vec2 v = vec2(off.x*dir.x + off.y*dir.y, off.x*(-dir.y) + off.y*dir.x) * len;
  float d2 = min(dot(v,v), clp);
  float wB = 0.4*d2 - 1.0, wA = lob*d2 - 1.0; wB *= wB; wA *= wA;
  wB = 1.5625*wB - 0.5625;
  float w = wB*wA; aC += c*w; aW += w;
}
void main(){
  vec2 pp = gl_FragCoord.xy*uIn/uOut - 0.5; vec2 fp = floor(pp); pp -= fp; ivec2 ip = ivec2(fp);
  vec3 b=T(ip+ivec2(0,-1)).rgb, c=T(ip+ivec2(1,-1)).rgb;
  vec3 e=T(ip+ivec2(-1,0)).rgb, f=T(ip).rgb, g=T(ip+ivec2(1,0)).rgb, h=T(ip+ivec2(2,0)).rgb;
  vec3 i=T(ip+ivec2(-1,1)).rgb, j=T(ip+ivec2(0,1)).rgb, k=T(ip+ivec2(1,1)).rgb, l=T(ip+ivec2(2,1)).rgb;
  vec3 n=T(ip+ivec2(0,2)).rgb, o=T(ip+ivec2(1,2)).rgb;
  float bL=Lu(b), cL=Lu(c), eL=Lu(e), fL=Lu(f), gL=Lu(g), hL=Lu(h), iL=Lu(i), jL=Lu(j), kL=Lu(k), lL=Lu(l), nL=Lu(n), oL=Lu(o);
  vec2 dir = vec2(0.0); float len = 0.0;
  setW(dir, len, (1.0-pp.x)*(1.0-pp.y), bL,eL,fL,gL,jL);
  setW(dir, len, pp.x*(1.0-pp.y),       cL,fL,gL,hL,kL);
  setW(dir, len, (1.0-pp.x)*pp.y,       fL,iL,jL,kL,nL);
  setW(dir, len, pp.x*pp.y,             gL,jL,kL,lL,oL);
  vec2 dir2 = dir*dir; float dirR = dir2.x + dir2.y; bool zro = dirR < 1.0/32768.0;
  dirR = inversesqrt(max(dirR, 1e-12)); dirR = zro ? 1.0 : dirR; dir.x = zro ? 1.0 : dir.x; dir *= dirR;
  len = len*0.5; len *= len;
  float stretch = dot(dir,dir) / max(abs(dir.x), abs(dir.y));
  vec2 len2 = vec2(1.0 + (stretch-1.0)*len, 1.0 - 0.5*len);
  float lob = 0.5 + ((1.0/4.0-0.04)-0.5)*len; float clp = 1.0/lob;
  vec3 aC = vec3(0.0); float aW = 0.0;
  tap(aC,aW,vec2( 0.0,-1.0)-pp,dir,len2,lob,clp,b); tap(aC,aW,vec2( 1.0,-1.0)-pp,dir,len2,lob,clp,c);
  tap(aC,aW,vec2(-1.0, 1.0)-pp,dir,len2,lob,clp,i); tap(aC,aW,vec2( 0.0, 1.0)-pp,dir,len2,lob,clp,j);
  tap(aC,aW,vec2( 0.0, 0.0)-pp,dir,len2,lob,clp,f); tap(aC,aW,vec2(-1.0, 0.0)-pp,dir,len2,lob,clp,e);
  tap(aC,aW,vec2( 1.0, 1.0)-pp,dir,len2,lob,clp,k); tap(aC,aW,vec2( 2.0, 1.0)-pp,dir,len2,lob,clp,l);
  tap(aC,aW,vec2( 2.0, 0.0)-pp,dir,len2,lob,clp,h); tap(aC,aW,vec2( 1.0, 0.0)-pp,dir,len2,lob,clp,g);
  tap(aC,aW,vec2( 1.0, 2.0)-pp,dir,len2,lob,clp,o); tap(aC,aW,vec2( 0.0, 2.0)-pp,dir,len2,lob,clp,n);
  vec3 mn4 = min(min(f,g),min(j,k)), mx4 = max(max(f,g),max(j,k));
  vec3 col = abs(aW) > 1e-6 ? aC/aW : f;
  frag = vec4(min(mx4, max(mn4, col)), 1.0);
}`,
  // Average of the high-res pixels each low-res pixel covers (4×4 bilinear taps).
  down: `
void main(){
  vec2 r = uIn/uOut; vec2 base = (gl_FragCoord.xy - 0.5)*r; vec4 acc = vec4(0.0);
  for(int j=0;j<4;j++) for(int i=0;i<4;i++){
    vec2 p = base + (vec2(float(i), float(j)) + 0.5)*r/4.0;
    acc += texture(uTex, p/uIn);
  }
  frag = acc/16.0;
}`,
  // Error between the original (uTex2, low-res) and the shrunk result (uTex), signed.
  diff: `void main(){ ivec2 p = ivec2(gl_FragCoord.xy); frag = texelFetch(uTex2, p, 0) - texelFetch(uTex, p, 0); }`,
  // Current result (uTex) + bicubic enlargement of the error (uTex2, uIn sized), kept inside the
  // range of the four nearest original pixels so it can't create halos. uSharp carries the
  // original texture size here.
  backproject: `
uniform highp sampler2D uOrig;
vec4 cr(float t){ float t2=t*t, t3=t2*t; return vec4(-0.5*t3+t2-0.5*t, 1.5*t3-2.5*t2+1.0, -1.5*t3+2.0*t2+0.5*t, 0.5*t3-0.5*t2); }
vec4 E(ivec2 p){ return texelFetch(uTex2, clamp(p, ivec2(0), ivec2(uIn)-1), 0); }
vec4 O(ivec2 p){ return texelFetch(uOrig, clamp(p, ivec2(0), ivec2(uIn)-1), 0); }
void main(){
  vec2 s = gl_FragCoord.xy*uIn/uOut - 0.5; vec2 b = floor(s); vec2 f = s - b; ivec2 ib = ivec2(b);
  vec4 wx = cr(f.x), wy = cr(f.y); vec4 up = vec4(0.0);
  for(int j=0;j<4;j++){ vec4 row = vec4(0.0); for(int i=0;i<4;i++) row += E(ib+ivec2(i-1,j-1))*wx[i]; up += row*wy[j]; }
  vec4 cur = texelFetch(uTex, ivec2(gl_FragCoord.xy), 0) + up;
  vec4 a=O(ib), c=O(ib+ivec2(1,0)), d=O(ib+ivec2(0,1)), e=O(ib+ivec2(1,1));
  frag = vec4(clamp(cur.rgb, min(min(a,c),min(d,e)).rgb, max(max(a,c),max(d,e)).rgb), 1.0);
}`,
  rcas: `
void main(){
  ivec2 p = ivec2(gl_FragCoord.xy);
  vec3 e = T(p).rgb;
  vec3 b=T(p+ivec2(0,-1)).rgb, d=T(p+ivec2(-1,0)).rgb, f=T(p+ivec2(1,0)).rgb, h=T(p+ivec2(0,1)).rgb;
  float bL=Lu(b), dL=Lu(d), eL=Lu(e), fL=Lu(f), hL=Lu(h);
  float nz = 0.25*(bL+dL+fL+hL) - eL;
  float rng = max(max(max(bL,dL),max(eL,fL)),hL) - min(min(min(bL,dL),min(eL,fL)),hL);
  nz = clamp(abs(nz)/max(rng,1e-5), 0.0, 1.0); nz = -0.5*nz + 1.0;
  vec3 mn4 = min(min(b,d),min(f,h)), mx4 = max(max(b,d),max(f,h));
  vec3 hitMin = min(mn4,e) / max(4.0*mx4, vec3(1e-5));
  vec3 hitMax = (1.0 - max(mx4,e)) / min(4.0*mn4 - 4.0, vec3(-1e-5));
  vec3 lr = max(-hitMin, hitMax);
  float lobe = max(-0.1875, min(max(lr.r, max(lr.g, lr.b)), 0.0)) * uSharp;
  lobe *= nz;
  frag = vec4(clamp((lobe*(b+d+f+h) + e) / (4.0*lobe + 1.0), 0.0, 1.0), 1.0);
}`,
  copy: `void main(){ frag = clamp(texelFetch(uTex, ivec2(gl_FragCoord.xy), 0), 0.0, 1.0); }`,
};

let gl, P, maxSide = 0;

function setup() {
  if (gl) return;
  const canvas = new OffscreenCanvas(1, 1);
  gl = canvas.getContext('webgl2', { premultipliedAlpha: false, antialias: false });
  if (!gl) throw new Error('Classic mode needs WebGL 2, which isn’t available on this PC.');
  if (!gl.getExtension('EXT_color_buffer_float')) throw new Error('Classic mode needs floating-point GPU textures.');
  maxSide = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  const compile = (type, src) => {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const vs = compile(gl.VERTEX_SHADER, VS);
  P = {};
  for (const k in FS) {
    const p = gl.createProgram();
    gl.attachShader(p, vs); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, HEAD + FS[k])); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    const u = {}; for (const n of ['uTex', 'uTex2', 'uOrig', 'uIn', 'uOut', 'uSharp']) u[n] = gl.getUniformLocation(p, n);
    P[k] = { p, u };
  }
  gl.bindVertexArray(gl.createVertexArray());
}

function target(w, h, float) {
  const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texStorage2D(gl.TEXTURE_2D, 1, float ? gl.RGBA16F : gl.RGBA8, w, h);
  for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
                        [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);
  const f = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, f);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
  return { t, f, w, h };
}
const drop = (x) => { if (x) { gl.deleteTexture(x.t); gl.deleteFramebuffer(x.f); } };

function pass(prog, dst, inW, inH, tex, tex2, orig, sharp) {
  gl.useProgram(prog.p);
  gl.bindFramebuffer(gl.FRAMEBUFFER, dst.f);
  gl.viewport(0, 0, dst.w, dst.h);
  const bind = (unit, t, name) => { if (!t || !prog.u[name]) return; gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, t); gl.uniform1i(prog.u[name], unit); };
  bind(0, tex, 'uTex'); bind(1, tex2, 'uTex2'); bind(2, orig, 'uOrig');
  gl.uniform2f(prog.u.uIn, inW, inH); gl.uniform2f(prog.u.uOut, dst.w, dst.h);
  if (prog.u.uSharp) gl.uniform1f(prog.u.uSharp, sharp || 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
}

/** Upscales straight RGBA (alpha is resized by the caller if needed). */
export async function classicUpscale(src, outW, outH, preset, progress, cancelled) {
  try { setup(); } catch (e) {
    // No WebGL 2 (very old or missing graphics driver): a high-quality resize plus sharpening.
    progress('High-quality resize (no GPU available)', 0.3);
    const { resizeHQ, tent } = await import('./imageops.js');
    const out = await resizeHQ(src.rgba, src.w, src.h, outW, outH);
    const amount = { fast: 0, balanced: 0.5, best: 0.7 }[preset];
    if (amount > 0) {
      progress('Sharpening', 0.8);
      const k = Math.max(3, Math.min(15, Math.round(outW / src.w) * 2 + 1));
      const b = tent(out, outW, outH, k);
      for (let i = 0; i < out.length; i += 4)
        for (let c = 0; c < 3; c++) out[i + c] = out[i + c] + amount * (out[i + c] - b[i + c]);
    }
    return out;
  }
  if (outW > maxSide || outH > maxSide) throw new Error(`${outW} × ${outH} is larger than this GPU allows (${maxSide} px per side). Try a smaller scale.`);
  const p = PRESETS[preset];
  const W = src.w, H = src.h;
  const orig = target(W, H, false);
  gl.bindTexture(gl.TEXTURE_2D, orig.t);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, src.rgba);

  // 1. Edge-directed upscale, in 2× steps for big enlargements.
  const steps = [];
  let w = W, h = H;
  if (p.progressive) while (w * 2 < outW && h * 2 < outH) { w *= 2; h *= 2; steps.push([w, h]); }
  steps.push([outW, outH]);
  let cur = orig, curW = W, curH = H;
  for (let i = 0; i < steps.length; i++) {
    progress(`Edge-directed upscale ${i + 1} of ${steps.length} · ${steps[i][0]} × ${steps[i][1]}`, 0.05 + 0.3 * i / steps.length);
    const next = target(steps[i][0], steps[i][1], true);
    pass(P.easu, next, curW, curH, cur.t);
    if (cur !== orig) drop(cur);
    cur = next; curW = steps[i][0]; curH = steps[i][1];
    await new Promise((r) => setTimeout(r, 0));
  }

  // 2. Detail refinement: shrink, compare with the original, add the difference back.
  if (p.refine > 0) {
    const small = target(W, H, true), err = target(W, H, true);
    for (let it = 0; it < p.refine; it++) {
      if (cancelled()) { drop(small); drop(err); drop(cur); drop(orig); throw new Error('cancelled'); }
      progress(`Detail refinement ${it + 1} of ${p.refine}`, 0.35 + 0.55 * it / p.refine);
      pass(P.down, small, outW, outH, cur.t);
      pass(P.diff, err, W, H, small.t, orig.t);
      const next = target(outW, outH, true);
      pass(P.backproject, next, W, H, cur.t, err.t, orig.t);
      drop(cur); cur = next;
      gl.finish();
      await new Promise((r) => setTimeout(r, 0));
    }
    drop(small); drop(err);
  }

  // 3. Sharpen, and convert to 8-bit.
  progress('Sharpening', 0.92);
  const fin = target(outW, outH, false);
  if (p.sharp > 0) pass(P.rcas, fin, outW, outH, cur.t, null, null, p.sharp);
  else pass(P.copy, fin, outW, outH, cur.t);
  const out = new Uint8ClampedArray(outW * outH * 4);
  gl.bindFramebuffer(gl.FRAMEBUFFER, fin.f);
  gl.readPixels(0, 0, outW, outH, gl.RGBA, gl.UNSIGNED_BYTE, out);
  drop(cur); drop(fin); drop(orig);
  return out;
}
