// Metal compute kernels, compiled at launch with MTLDevice.makeLibrary(source:).
// Compiling at runtime means the app builds with only the Xcode Command Line Tools
// (which do not ship the offline `metal` compiler).

enum Shaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- color spaces

constant float SIG_C = 0.75f;   // sigmoid center (mpv defaults)
constant float SIG_S = 6.5f;    // sigmoid slope

inline float3 srgbToLinear(float3 c) {
    c = clamp(c, float3(0.0f), float3(1.0f));
    return select(pow((c + 0.055f) / 1.055f, float3(2.4f)), c / 12.92f, c <= float3(0.04045f));
}

inline float3 linearToSrgb(float3 c) {
    c = clamp(c, float3(0.0f), float3(1.0f));
    return select(1.055f * pow(c, float3(1.0f / 2.4f)) - 0.055f, c * 12.92f, c <= float3(0.0031308f));
}

inline float sigOffset() { return 1.0f / (1.0f + exp(SIG_S * SIG_C)); }
inline float sigScale()  { return 1.0f / (1.0f + exp(SIG_S * (SIG_C - 1.0f))) - sigOffset(); }

// Sigmoidal light: upscaling in this space keeps ringing around bright/dark edges small.
inline float3 sigmoidize(float3 x) {
    x = clamp(x, float3(0.0f), float3(1.0f));
    return SIG_C - log(1.0f / (x * sigScale() + sigOffset()) - 1.0f) / SIG_S;
}
inline float3 unsigmoidize(float3 x) {
    return (1.0f / (1.0f + exp(SIG_S * (SIG_C - x))) - sigOffset()) / sigScale();
}

inline float luma(float3 c) { return c.b * 0.5f + (c.r * 0.5f + c.g); }

inline uint2 cc(int2 p, int2 size) { return uint2(clamp(p, int2(0), size - 1)); }

// ---------------------------------------------------------------- EASU core
// Port of AMD FidelityFX Super Resolution 1.0 "Edge Adaptive Spatial Upsampling".
// `guide` decides edge direction, `values` is what gets resampled. For a plain
// upscale they are the same texture. For back-projection the guide is the original
// image and the values are the residual error, so corrections follow real edges.

constant int2 kOff[12] = {
    int2( 0,-1), int2( 1,-1),
    int2(-1, 0), int2( 0, 0), int2( 1, 0), int2( 2, 0),
    int2(-1, 1), int2( 0, 1), int2( 1, 1), int2( 2, 1),
    int2( 0, 2), int2( 1, 2)
};

inline void easuSet(thread float2 &dir, thread float &len, float w,
                    float lA, float lB, float lC, float lD, float lE) {
    float lenX = max(abs(lD - lC), abs(lC - lB));
    lenX = 1.0f / max(lenX, 1e-5f);
    float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = saturate(abs(dirX) * lenX);
    lenX *= lenX;
    len += lenX * w;

    float lenY = max(abs(lE - lC), abs(lC - lA));
    lenY = 1.0f / max(lenY, 1e-5f);
    float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = saturate(abs(dirY) * lenY);
    lenY *= lenY;
    len += lenY * w;
}

inline void easuTap(thread float4 &aC, thread float &aW, float2 off, float2 dir, float2 len,
                    float lob, float clp, float4 c) {
    float2 v = float2(off.x * dir.x + off.y * dir.y, off.x * (-dir.y) + off.y * dir.x) * len;
    float d2 = min(dot(v, v), clp);
    float wB = 0.4f * d2 - 1.0f;
    float wA = lob * d2 - 1.0f;
    wB *= wB;
    wA *= wA;
    wB = 1.5625f * wB - 0.5625f;
    float w = wB * wA;
    aC += c * w;
    aW += w;
}

inline float4 easuCore(texture2d<float, access::read> guide,
                       texture2d<float, access::read> values,
                       uint2 gid, float2 inSize, float2 outSize,
                       bool dering, bool sqrtGuide) {
    float2 pp = (float2(gid) + 0.5f) * inSize / outSize - 0.5f;
    float2 fp = floor(pp);
    pp -= fp;
    int2 ip = int2(fp);
    int2 sz = int2(inSize);

    float L[12];
    float4 C[12];
    for (int t = 0; t < 12; t++) {
        uint2 q = cc(ip + kOff[t], sz);
        float3 g = guide.read(q).rgb;
        if (sqrtGuide) { g = sqrt(max(g, float3(0.0f))); }
        L[t] = luma(g);
        C[t] = values.read(q);
    }
    // b=0 c=1 e=2 f=3 g=4 h=5 i=6 j=7 k=8 l=9 n=10 o=11
    float2 dir = float2(0.0f);
    float len = 0.0f;
    easuSet(dir, len, (1.0f - pp.x) * (1.0f - pp.y), L[0], L[2], L[3], L[4], L[7]);
    easuSet(dir, len, pp.x * (1.0f - pp.y),          L[1], L[3], L[4], L[5], L[8]);
    easuSet(dir, len, (1.0f - pp.x) * pp.y,          L[3], L[6], L[7], L[8], L[10]);
    easuSet(dir, len, pp.x * pp.y,                   L[4], L[7], L[8], L[9], L[11]);

    float2 dir2 = dir * dir;
    float dirR = dir2.x + dir2.y;
    bool zro = dirR < (1.0f / 32768.0f);
    dirR = rsqrt(max(dirR, 1e-12f));
    dirR = zro ? 1.0f : dirR;
    dir.x = zro ? 1.0f : dir.x;
    dir *= dirR;

    len = len * 0.5f;
    len *= len;
    float stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));
    float2 len2 = float2(1.0f + (stretch - 1.0f) * len, 1.0f - 0.5f * len);
    float lob = 0.5f + ((1.0f / 4.0f - 0.04f) - 0.5f) * len;
    float clp = 1.0f / lob;

    float4 aC = float4(0.0f);
    float aW = 0.0f;
    for (int t = 0; t < 12; t++) {
        easuTap(aC, aW, float2(kOff[t]) - pp, dir, len2, lob, clp, C[t]);
    }
    float4 r = (abs(aW) > 1e-6f) ? aC / aW : C[3];
    if (dering) {
        float4 mn = min(min(C[3], C[4]), min(C[7], C[8]));
        float4 mx = max(max(C[3], C[4]), max(C[7], C[8]));
        r = clamp(r, mn, mx);
    }
    return r;
}

// ---------------------------------------------------------------- kernels

// Optional edge-preserving (bilateral) denoise, 5x5. Upscaling magnifies JPEG
// noise and blocking, so cleaning the source first gives smoother results.
kernel void k_denoise(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float &strength [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    int2 sz = int2(src.get_width(), src.get_height());
    if (int(gid.x) >= sz.x || int(gid.y) >= sz.y) { return; }
    float4 c0 = src.read(gid);
    float sr = max(strength * 0.12f, 1e-4f);
    float inv = 1.0f / (2.0f * sr * sr);
    float4 acc = float4(0.0f);
    float ws = 0.0f;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            float4 c = src.read(cc(int2(gid) + int2(dx, dy), sz));
            float3 d = c.rgb - c0.rgb;
            float w = exp(-float(dx * dx + dy * dy) / 4.5f - dot(d, d) * inv);
            acc += c * w;
            ws += w;
        }
    }
    dst.write(acc / ws, gid);
}

// Source (premultiplied, sRGB-encoded) -> working spaces.
//   up : space the upscalers run in (sigmoidal linear light, or plain gamma)
//   ref: space back-projection runs in (linear light, or plain gamma)
kernel void k_prep(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> up [[texture(1)]],
                   texture2d<float, access::write> ref [[texture(2)]],
                   constant int &mode [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) { return; }
    float4 c = src.read(gid);
    float a = saturate(c.a);
    float3 s = (a > 1e-6f) ? clamp(c.rgb / a, float3(0.0f), float3(1.0f)) : float3(0.0f);
    if (mode == 1) {
        float3 l = srgbToLinear(s);
        ref.write(float4(l * a, a), gid);
        up.write(float4(sigmoidize(l) * a, a), gid);
    } else {
        ref.write(float4(s * a, a), gid);
        up.write(float4(s * a, a), gid);
    }
}

kernel void k_easu(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float2 inS = float2(src.get_width(), src.get_height());
    float2 outS = float2(dst.get_width(), dst.get_height());
    dst.write(easuCore(src, src, gid, inS, outS, true, false), gid);
}

inline float lanczos3(float x) {
    x = abs(x);
    if (x < 1e-5f) { return 1.0f; }
    if (x >= 3.0f) { return 0.0f; }
    float px = M_PI_F * x;
    return 3.0f * sin(px) * sin(px / 3.0f) / (px * px);
}

// One separable Lanczos-3 pass. axis 0 = horizontal, 1 = vertical.
kernel void k_lanczos(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant int &axis [[buffer(0)]],
                      constant int &antiring [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    int2 sz = int2(src.get_width(), src.get_height());
    float s = (axis == 0)
        ? (float(gid.x) + 0.5f) * float(sz.x) / float(dst.get_width()) - 0.5f
        : (float(gid.y) + 0.5f) * float(sz.y) / float(dst.get_height()) - 0.5f;
    float b = floor(s);
    float4 acc = float4(0.0f);
    float ws = 0.0f;
    float4 mn = float4(1e9f);
    float4 mx = float4(-1e9f);
    for (int i = -2; i <= 3; i++) {
        int x = int(b) + i;
        float w = lanczos3(s - float(x));
        int2 q = (axis == 0) ? int2(x, int(gid.y)) : int2(int(gid.x), x);
        float4 c = src.read(cc(q, sz));
        acc += c * w;
        ws += w;
        if (i == 0 || i == 1) { mn = min(mn, c); mx = max(mx, c); }
    }
    acc /= ws;
    if (antiring != 0) { acc = clamp(acc, mn, mx); }
    dst.write(acc, gid);
}

inline float4 catmullRom(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return float4(-0.5f * t3 + t2 - 0.5f * t,
                   1.5f * t3 - 2.5f * t2 + 1.0f,
                  -1.5f * t3 + 2.0f * t2 + 0.5f * t,
                   0.5f * t3 - 0.5f * t2);
}

kernel void k_bicubic(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant int &antiring [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    int2 sz = int2(src.get_width(), src.get_height());
    float2 s = (float2(gid) + 0.5f) * float2(sz) / float2(dst.get_width(), dst.get_height()) - 0.5f;
    float2 b = floor(s);
    float2 f = s - b;
    int2 ib = int2(b);
    float4 wx = catmullRom(f.x);
    float4 wy = catmullRom(f.y);
    float4 acc = float4(0.0f);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            acc += src.read(cc(ib + int2(i - 1, j - 1), sz)) * (wx[i] * wy[j]);
        }
    }
    if (antiring != 0) {
        float4 a = src.read(cc(ib, sz));
        float4 c = src.read(cc(ib + int2(1, 0), sz));
        float4 d = src.read(cc(ib + int2(0, 1), sz));
        float4 e = src.read(cc(ib + int2(1, 1), sz));
        acc = clamp(acc, min(min(a, c), min(d, e)), max(max(a, c), max(d, e)));
    }
    dst.write(acc, gid);
}

// Upscale space -> refinement space.
kernel void k_toRef(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant int &mode [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    float a = saturate(c.a);
    float3 s = (a > 1e-6f) ? c.rgb / a : float3(0.0f);
    float3 l = (mode == 1) ? unsigmoidize(s) : s;
    l = clamp(l, float3(0.0f), float3(1.0f));
    dst.write(float4(l * a, a), gid);
}

// Back-projection step 1: shrink the current result back to the source size with an
// exact area average and store how far it is from the real source pixels.
kernel void k_residual(texture2d<float, access::read> lr [[texture(0)]],
                       texture2d<float, access::read> hr [[texture(1)]],
                       texture2d<float, access::write> err [[texture(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= lr.get_width() || gid.y >= lr.get_height()) { return; }
    int2 hs = int2(hr.get_width(), hr.get_height());
    float2 s = float2(hs) / float2(lr.get_width(), lr.get_height());
    float2 a = float2(gid) * s;          // footprint start, in result pixels
    float2 b = a + s;                    // footprint end
    int x0 = int(floor(a.x));
    int x1 = int(ceil(b.x)) - 1;
    int y0 = int(floor(a.y));
    int y1 = int(ceil(b.y)) - 1;
    float4 acc = float4(0.0f);
    float ws = 0.0f;
    for (int y = y0; y <= y1; y++) {
        float wy = min(b.y, float(y + 1)) - max(a.y, float(y));
        if (wy <= 0.0f) { continue; }
        for (int x = x0; x <= x1; x++) {
            float wx = min(b.x, float(x + 1)) - max(a.x, float(x));
            if (wx <= 0.0f) { continue; }
            float w = wx * wy;
            acc += hr.read(cc(int2(x, y), hs)) * w;
            ws += w;
        }
    }
    float4 down = (ws > 0.0f) ? acc / ws : float4(0.0f);
    err.write(lr.read(gid) - down, gid);
}

// Back-projection step 2: upsample the error along the source's edges, add it to the
// result, and keep every pixel inside the range of its 2x2 source neighbourhood so the
// correction can't create halos.
kernel void k_backproject(texture2d<float, access::read> hrIn [[texture(0)]],
                          texture2d<float, access::read> err [[texture(1)]],
                          texture2d<float, access::read> guide [[texture(2)]],
                          texture2d<float, access::write> hrOut [[texture(3)]],
                          constant float &lambda [[buffer(0)]],
                          constant int &sqrtGuide [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= hrOut.get_width() || gid.y >= hrOut.get_height()) { return; }
    float2 inS = float2(guide.get_width(), guide.get_height());
    float2 outS = float2(hrOut.get_width(), hrOut.get_height());
    float4 e = easuCore(guide, err, gid, inS, outS, false, sqrtGuide != 0);
    float4 h = hrIn.read(gid) + lambda * e;

    float2 pp = (float2(gid) + 0.5f) * inS / outS - 0.5f;
    int2 ip = int2(floor(pp));
    int2 sz = int2(inS);
    float4 q0 = guide.read(cc(ip, sz));
    float4 q1 = guide.read(cc(ip + int2(1, 0), sz));
    float4 q2 = guide.read(cc(ip + int2(0, 1), sz));
    float4 q3 = guide.read(cc(ip + int2(1, 1), sz));
    h = clamp(h, min(min(q0, q1), min(q2, q3)), max(max(q0, q1), max(q2, q3)));
    hrOut.write(h, gid);
}

// Refinement space -> straight-alpha, sRGB-encoded.
kernel void k_display(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant int &mode [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    float4 c = src.read(gid);
    float a = saturate(c.a);
    float3 s = (a > 1e-6f) ? c.rgb / a : float3(0.0f);
    s = clamp(s, float3(0.0f), float3(1.0f));
    if (mode == 1) { s = linearToSrgb(s); }
    dst.write(float4(s, a), gid);
}

// FidelityFX RCAS (robust contrast-adaptive sharpening) + final write.
kernel void k_rcas(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant float &sharp [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    int2 sz = int2(src.get_width(), src.get_height());
    int2 p = int2(gid);
    float4 e4 = src.read(gid);
    float3 e = e4.rgb;
    float3 b = src.read(cc(p + int2(0, -1), sz)).rgb;
    float3 d = src.read(cc(p + int2(-1, 0), sz)).rgb;
    float3 f = src.read(cc(p + int2(1, 0), sz)).rgb;
    float3 h = src.read(cc(p + int2(0, 1), sz)).rgb;
    float bL = luma(b), dL = luma(d), eL = luma(e), fL = luma(f), hL = luma(h);

    float nz = 0.25f * (bL + dL + fL + hL) - eL;
    float rng = max(max(max(bL, dL), max(eL, fL)), hL) - min(min(min(bL, dL), min(eL, fL)), hL);
    nz = saturate(abs(nz) / max(rng, 1e-5f));
    nz = -0.5f * nz + 1.0f;

    float3 mn4 = min(min(b, d), min(f, h));
    float3 mx4 = max(max(b, d), max(f, h));
    float3 hitMin = min(mn4, e) / max(4.0f * mx4, float3(1e-5f));
    float3 hitMax = (1.0f - max(mx4, e)) / min(4.0f * mn4 - 4.0f, float3(-1e-5f));
    float3 lr = max(-hitMin, hitMax);
    float lobe = max(-0.1875f, min(max(lr.r, max(lr.g, lr.b)), 0.0f)) * sharp;
    lobe *= nz;
    float3 c = (lobe * (b + d + f + h) + e) / (4.0f * lobe + 1.0f);
    dst.write(float4(saturate(c), e4.a), gid);
}
"""#
}
