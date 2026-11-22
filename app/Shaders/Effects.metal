// Emulsa - app-side effect kernels (GPL-3.0-or-later). Compiled to Effects.metallib by build.sh.
#include <metal_stdlib>
using namespace metal;

constant bool kHalf [[function_constant(0)]];

struct PreU {
  uint w, h;
  float caR, caB;
  int vigOn; float vigAmount, vigMid, vigFeather, vigRound;
  float blurRadius; int blurShape; float focusSize, transition;
  float focusX, focusY, bokehBoost; int taps;
  // Real lens profile (lensfun): distortion, TCA, vignetting. See LensProfile.swift.
  int lensOn; float pxToDist, pxToVig, fillScale, rClampDist, rClampVig;
  float d0, d1, d2, d3, d4;
  float tr0, tr1, tr2, tb0, tb1, tb2;
  float k1, k2, k3;
};

struct PostU {
  uint w, h;
  float dustAmount, dustSize, scratches; int dustWhite; uint seed;
  int frameStyle; float frameSize, frameRough;
  int tone; float toneAmount;
};

// Pixels are float4 or half4 depending on the buffer.
static inline float4 ld(device const uchar *p, uint i) {
  return kHalf ? float4(((device const half4 *)p)[i]) : ((device const float4 *)p)[i];
}
static inline void st(device uchar *p, uint i, float4 v) {
  if (kHalf) ((device half4 *)p)[i] = half4(v); else ((device float4 *)p)[i] = v;
}
static inline float4 bilinear(device const uchar *p, uint w, uint h, float2 xy) {
  xy = clamp(xy - 0.5, float2(0), float2(w - 1, h - 1));
  uint2 a = uint2(xy);
  uint2 b = min(a + 1, uint2(w - 1, h - 1));
  float2 f = xy - float2(a);
  float4 c00 = ld(p, a.y * w + a.x), c10 = ld(p, a.y * w + b.x);
  float4 c01 = ld(p, b.y * w + a.x), c11 = ld(p, b.y * w + b.x);
  return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

static inline uint hash3(uint x, uint y, uint z) {
  uint h = x * 0x8da6b343u ^ y * 0xd8163841u ^ z * 0xcb1ab31fu;
  h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
  return h;
}
static inline float rnd(uint h) { return float(h & 0xffffffu) / 16777216.0; }
static inline float noise1(float x, uint seed) {
  float i = floor(x), f = x - i;
  float a = rnd(hash3(uint(int(i) + 100000), seed, 7u)), b = rnd(hash3(uint(int(i) + 100001), seed, 7u));
  return mix(a, b, f * f * (3 - 2 * f)) * 2 - 1;
}
static inline float fbm1(float x, uint seed) {
  return noise1(x, seed) * 0.6 + noise1(x * 2.7, seed + 1) * 0.3 + noise1(x * 7.1, seed + 2) * 0.1;
}

// ---- before the engine -------------------------------------------------

static inline float vignetteGain(constant PreU &u, float2 pos) {
  if (u.vigOn == 0) return 1;
  float2 c = float2(u.w, u.h) * 0.5;
  float2 d = pos - c;
  float rc = length(d) / length(c);              // circle, 1 at the corners
  float re = length(d / c) * 0.70710678;         // ellipse following the frame
  float r = mix(re, rc, u.vigRound);
  float inner = u.vigMid * (1 - 0.9 * u.vigFeather);
  float outer = max(mix(u.vigMid + 0.05, 1.0, u.vigFeather), inner + 0.02);
  return exp2(u.vigAmount * smoothstep(inner, outer, r));
}

// Undistorted radius for distorted radius rd: Newton on rd = x * (d0 + d1 x + d2 x^2 + d3 x^3 + d4 x^4).
static inline float lensUndistort(constant PreU &u, float rd) {
  float x = rd;
  for (int k = 0; k < 5; k++) {
    float p = u.d0 + x * (u.d1 + x * (u.d2 + x * (u.d3 + x * u.d4)));
    float dp = u.d0 + x * (2 * u.d1 + x * (3 * u.d2 + x * (4 * u.d3 + x * 5 * u.d4)));
    x -= (x * p - rd) / (abs(dp) > 1e-5 ? dp : 1e-5);
  }
  return x;
}

// Lateral chromatic aberration (+ vignette when there is no blur pass); also fills the blur texture.
kernel void lensPrep(device const uchar *src [[buffer(0)]], device uchar *dst [[buffer(1)]],
                     constant PreU &u [[buffer(2)]], texture2d<float, access::write> tex [[texture(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.w || gid.y >= u.h) return;
  float2 pos = float2(gid) + 0.5;
  float2 c = float2(u.w, u.h) * 0.5;
  uint i = gid.y * u.w + gid.x;
  float4 v = ld(src, i);
  if (u.lensOn != 0) {
    // Output pixel sits at distorted radius rn; each channel samples the scene where the lens put it.
    float2 d = pos - c;
    float rn = max(length(d) * u.pxToDist, 1e-4);
    float rq = min(rn, u.rClampDist);
    float tR = u.tr0 + rq * (u.tr1 + rq * u.tr2), tB = u.tb0 + rq * (u.tb1 + rq * u.tb2);
    float sG = lensUndistort(u, rq) / rq;
    float sR = lensUndistort(u, rq / max(tR, 0.5)) / rq;
    float sB = lensUndistort(u, rq / max(tB, 0.5)) / rq;
    float inv = 1.0 / u.fillScale;
    v.r = bilinear(src, u.w, u.h, c + d * (sR * inv * (1 + u.caR * 0.002))).r;
    v.g = bilinear(src, u.w, u.h, c + d * (sG * inv)).g;
    v.b = bilinear(src, u.w, u.h, c + d * (sB * inv * (1 - u.caB * 0.002))).b;
    float rv = min(length(d) * u.pxToVig, u.rClampVig), r2 = rv * rv;
    v.rgb *= max(1 + r2 * (u.k1 + r2 * (u.k2 + r2 * u.k3)), 0.0);
  } else if (u.caR != 0 || u.caB != 0) {
    v.r = bilinear(src, u.w, u.h, c + (pos - c) * (1 + u.caR * 0.002)).r;
    v.b = bilinear(src, u.w, u.h, c + (pos - c) * (1 - u.caB * 0.002)).b;
  }
  v.rgb *= vignetteGain(u, pos);
  st(dst, i, v);
  if (u.blurRadius > 0) {
    // Over the texture size limit the blur copy is smaller: the first pixel of each texel writes it.
    float2 k = float2(tex.get_width(), tex.get_height()) / float2(u.w, u.h);
    uint2 last = uint2(tex.get_width(), tex.get_height()) - 1;
    uint2 t = min(uint2(float2(gid) * k), last);
    uint2 prev = min(uint2(float2(max(gid, 1u) - 1) * k), last);
    if ((gid.x == 0 || prev.x != t.x) && (gid.y == 0 || prev.y != t.y))
      tex.write(clamp(v, -60000.0, 60000.0), t);
  }
}

// Disc (bokeh) blur with a circle of confusion that grows away from the focus zone.
// Taps read a mipmapped copy at the level matching their spacing, so large radii stay smooth.
kernel void lensBlur(device const uchar *src [[buffer(0)]], device uchar *dst [[buffer(1)]],
                     constant PreU &u [[buffer(2)]], texture2d<float> tex [[texture(0)]],
                     sampler s [[sampler(0)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.w || gid.y >= u.h) return;
  float2 pos = float2(gid) + 0.5;
  float2 size = float2(u.w, u.h);
  float2 c = size * 0.5;
  float halfDiag = length(c);
  float2 q = (pos - c) / halfDiag;
  float2 f = float2(u.focusX, -u.focusY) * c / halfDiag;
  float d = u.blurShape == 0 ? length(q - f) : u.blurShape == 1 ? abs(q.y - f.y) * 1.4 : 10.0;
  float coc = smoothstep(u.focusSize, u.focusSize + u.transition, d) * u.blurRadius;
  uint i = gid.y * u.w + gid.x;
  float4 v;
  if (coc < 0.5) {
    v = ((device const float4 *)src)[i];
  } else {
    // Tap spacing in source pixels, less the levels a smaller blur copy has already dropped.
    float lod = max(log2(max(1.0, coc * sqrt(3.14159 / float(u.taps)))) - log2(size.x / float(tex.get_width())), 0.0);
    float rot = fract(52.9829189 * fract(dot(pos, float2(0.06711056, 0.00583715)))) * 6.2831853;
    float3 sum = 0; float wsum = 0;
    for (int k = 0; k < u.taps; k++) {
      float r = sqrt((float(k) + 0.5) / float(u.taps)) * coc;
      float a = float(k) * 2.3999632 + rot;
      float3 t = tex.sample(s, (pos + r * float2(cos(a), sin(a))) / size, level(lod)).rgb;
      float lum = dot(max(t, 0.0), float3(0.2627, 0.678, 0.0593));
      float w = 1 + u.bokehBoost * smoothstep(0.7, 4.0, lum) * 4;
      sum += t * w; wsum += w;
    }
    v = float4(sum / wsum, 1);
  }
  v.rgb *= vignetteGain(u, pos);
  ((device float4 *)dst)[i] = v;
}

// ---- after the engine --------------------------------------------------

// Black-and-white film: drop the residual tint of the colour print path, then tone.
// Same math as MonoTone.apply (used for the LUT bake).
kernel void mono(device uchar *img [[buffer(0)]], constant PostU &u [[buffer(1)]],
                 uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.w || gid.y >= u.h) return;
  uint i = gid.y * u.w + gid.x;
  float4 c = ld(img, i);
  float l = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
  float t = clamp(l, 0.0, 1.0);
  float3 tint = float3(1);
  float w = 0;
  if (u.tone == 1) { tint = float3(1.03, 0.94, 0.98); w = pow(1 - t, 1.5); }
  else if (u.tone == 2) { tint = float3(1.10, 0.98, 0.80); w = 1 - pow(t, 4.0); }
  else if (u.tone == 3) { tint = float3(0.93, 0.98, 1.08); w = 1 - pow(t, 3.0); }
  else if (u.tone == 4) {
    float s = smoothstep(0.25, 0.6, t);
    tint = mix(float3(1.03, 0.94, 0.98), float3(1.10, 0.98, 0.80), s);
    w = 1 - pow(t, 4.0);
  }
  st(img, i, float4(l * mix(float3(1), tint, u.toneAmount * w), c.a));
}

kernel void dust(device uchar *img [[buffer(0)]], constant PostU &u [[buffer(1)]],
                 uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.w || gid.y >= u.h) return;
  float2 pos = float2(gid) + 0.5;
  float S = float(min(u.w, u.h));
  float cellPx = S / 40.0;
  float2 p = pos / cellPx;
  int2 ci = int2(floor(p));
  float aa = 1.0 / cellPx;
  float cover = 0;
  for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
    int2 cell = ci + int2(dx, dy);
    uint cx = uint(cell.x + 100000), cy = uint(cell.y + 100000);
    uint h0 = hash3(cx, cy, u.seed);
    if (rnd(h0) > u.dustAmount * 0.45) continue;
    uint h1 = hash3(h0, 1u, u.seed), h2 = hash3(h0, 2u, u.seed), h3 = hash3(h0, 3u, u.seed);
    uint h4 = hash3(h0, 4u, u.seed), h5 = hash3(h0, 5u, u.seed);
    float2 q = p - (float2(cell) + float2(rnd(h1), rnd(h2)));
    float opacity = 0.55 + 0.45 * rnd(h5);
    float alpha;
    if (rnd(h3) < 0.22) {
      // fibre: a thin bent line
      float ang = rnd(h4) * 6.2831853;
      float2 dir = float2(cos(ang), sin(ang));
      float along = dot(q, dir), across = dot(q, float2(-dir.y, dir.x));
      float len = u.dustSize * (0.15 + 0.4 * rnd(h5 ^ 0x55u));
      across -= (rnd(h1 ^ 0x77u) - 0.5) * 1.6 * along * along / max(len, 0.01);
      float width = max(u.dustSize * 0.012, 0.6 * aa);
      float dist = abs(along) < len ? abs(across) : length(float2(abs(along) - len, across));
      alpha = 1 - smoothstep(width * 0.5 - aa * 0.5, width * 0.5 + aa * 0.5, dist);
    } else {
      // speck: a lumpy disc, mostly tiny
      float r = u.dustSize * (0.012 + 0.16 * pow(rnd(h4), 4.0));
      float th = atan2(q.y, q.x);
      float lump = 1 + 0.25 * sin(3 * th + 6.28 * rnd(h1 ^ 0x33u)) + 0.15 * sin(7 * th + 6.28 * rnd(h2 ^ 0x33u));
      float dist = length(q) - r * lump;
      alpha = 1 - smoothstep(-aa * 0.6, aa * 0.6, dist);
    }
    cover = max(cover, alpha * opacity);
  }
  int count = int(u.scratches * 8 + 0.5);
  for (int k = 0; k < count; k++) {
    uint h = hash3(uint(k), 77u, u.seed);
    float y0 = rnd(hash3(h, 1u, 0u)) * 0.7 * float(u.h);
    float len = (0.3 + 0.7 * rnd(hash3(h, 2u, 0u))) * float(u.h);
    if (pos.y < y0 || pos.y > y0 + len) continue;
    float x = rnd(h) * float(u.w)
      + sin(pos.y / float(u.h) * 6.2831853 * (0.5 + 2 * rnd(hash3(h, 3u, 0u))) + 6.28 * rnd(hash3(h, 4u, 0u))) * S * 0.004;
    float width = max(0.8, S * 0.0005 * u.dustSize);
    float strength = 0.35 + 0.35 * fbm1(pos.y / S * 25.0, h);
    float a = (1 - smoothstep(width * 0.5 - 0.5, width * 0.5 + 0.5, abs(pos.x - x))) * clamp(strength, 0.0, 1.0);
    cover = max(cover, a);
  }
  if (cover <= 0) return;
  uint i = gid.y * u.w + gid.x;
  float4 v = ld(img, i);
  float target = u.dustWhite != 0 ? 1.0 : 0.02;
  v.rgb = mix(v.rgb, float3(target), cover);
  st(img, i, v);
}

// ---- statistical dust (DustModel.swift lays the items out) ------------

struct DustU {
  uint w, h;
  float cellPx; uint gridW, gridH;
  int white; float gain, pad1;
};

struct DustItem {
  float2 a, b;
  float r, opacity, t0, t1;
  uint kind, seed;
  float aux, pad;
};

static inline float vnoise(float2 p, uint seed) {
  float2 i = floor(p), f = p - i;
  f = f * f * (3 - 2 * f);
  uint x = uint(int(i.x) + 100000), y = uint(int(i.y) + 100000);
  float a = rnd(hash3(x, y, seed)), b = rnd(hash3(x + 1, y, seed));
  float c = rnd(hash3(x, y + 1, seed)), d = rnd(hash3(x + 1, y + 1, seed));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static inline float segDist(float2 p, float2 a, float2 b, thread float &h) {
  float2 pa = p - a, ba = b - a;
  h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  return length(pa - ba * h);
}

static inline float dustItemAlpha(DustItem it, float2 pos, float longPx) {
  switch (it.kind) {
  case 0: case 3: {  // speck / dirt blob: lumpy ellipse
    float major = length(it.b);
    if (major < 1e-4) return 0;
    float2 dir = it.b / major;
    float2 q = pos - it.a;
    float2 l = float2(dot(q, dir), dot(q, float2(-dir.y, dir.x)));
    float minor = major * it.r;
    float m = max(major, 0.7), n = max(minor, 0.7);
    float cov = (major * minor) / (m * n);      // sub-pixel specks keep their area as faintness
    float th = atan2(l.y / n, l.x / m);
    float s1 = rnd(hash3(it.seed, 1u, 0u)) * 6.283, s2 = rnd(hash3(it.seed, 2u, 0u)) * 6.283, s3 = rnd(hash3(it.seed, 3u, 0u)) * 6.283;
    float lump = 1 + 0.16 * sin(2 * th + s1) + 0.1 * sin(3 * th + s2) + 0.06 * sin(5 * th + s3);
    float rho = length(l / float2(m, n));
    if (it.kind == 0) {
      float dist = (rho - lump) * n;
      return clamp(0.5 - dist / 0.9, 0.0, 1.0) * cov * it.opacity;
    }
    lump += 0.35 * (vnoise(l / n * 1.3, it.seed) - 0.5);
    float soft = 1.2 + 0.25 * n;
    float dist = (rho - lump) * n;
    float body = 0.55 + 0.45 * vnoise(l / n * 2.5, it.seed ^ 0x5bu);
    return clamp(0.5 - dist / soft, 0.0, 1.0) * cov * it.opacity * body;
  }
  case 1: {  // fibre piece
    float h;
    float d = segDist(pos, it.a, it.b, h);
    float t = mix(it.t0, it.t1, h);
    float hw = it.r * (0.55 + 0.45 * clamp(min(t, 1 - t) * 10, 0.0, 1.0));
    float w = max(hw, 0.5);
    return clamp(w - d + 0.5, 0.0, 1.0) * (hw / w) * it.opacity;
  }
  case 2: {  // scratch piece, fading along its length
    float h;
    float d = segDist(pos, it.a, it.b, h);
    float t = mix(it.t0, it.t1, h);
    float w = max(it.r, 0.5);
    float fade = clamp(0.5 + 0.9 * fbm1(t / (0.012 * longPx), it.seed), 0.0, 1.0);
    return clamp(w - d + 0.5, 0.0, 1.0) * (it.r / w) * it.opacity * fade;
  }
  case 4: {  // drying mark: faint disc, darker rim
    float2 q = pos - it.a;
    float th = atan2(q.y, q.x);
    float s1 = rnd(hash3(it.seed, 1u, 0u)) * 6.283, s2 = rnd(hash3(it.seed, 2u, 0u)) * 6.283;
    float d = length(q) / max(it.r, 0.5) * (1 + 0.07 * sin(3 * th + s1) + 0.04 * sin(7 * th + s2));
    float rim = exp(-pow((d - 0.97) / max(it.aux, 0.02), 2.0));
    float inner = 1 - smoothstep(0.9, 1.0, d);
    return clamp(it.opacity * (0.25 * inner + rim), 0.0, 1.0);
  }
  case 5: {  // fingerprint: warped loop ridges with breaks, under an oily smudge
    float major = length(it.b);
    float2 dir = it.b / max(major, 1e-4);
    float2 q = pos - it.a;
    float2 l = float2(dot(q, dir), dot(q, float2(-dir.y, dir.x)));
    float minor = major * it.r;
    float2 u = l / float2(major, minor);
    float rho = length(u);
    float mask = 1 - smoothstep(0.35, 1.0, rho + 0.45 * (vnoise(u * 3, it.seed) - 0.5));
    if (mask <= 0) return 0;
    float pitch = max(it.aux, 0.5);
    // warp the coordinates by a pitch-scale noise so ridges wander instead of forming circles
    float2 wq = l + pitch * 1.6 * float2(vnoise(l / (pitch * 3.5), it.seed + 2) - 0.5,
                                         vnoise(l / (pitch * 3.5), it.seed + 3) - 0.5);
    // loop pattern: ellipses around an off-centre core, opened up on one side
    float2 c = wq - float2(0.15 * major, 0);
    float rr = length(c * float2(0.8, 1.0)) + 0.35 * max(c.x, 0.0);
    float ph = rr / pitch + 0.6 * vnoise(l / (pitch * 8), it.seed + 4);
    float line = smoothstep(0.55, 0.85, 0.5 + 0.5 * cos(6.2831853 * ph));
    line = mix(0.35, line, smoothstep(1.5, 3.0, pitch));                      // too fine to resolve: haze
    line *= smoothstep(0.25, 0.5, vnoise(l / (pitch * 1.2), it.seed + 1));    // ridge endings and gaps
    float smudge = 0.35 * vnoise(l / (pitch * 6), it.seed + 5);
    return mask * (0.75 * line + smudge) * it.opacity;
  }
  }
  return 0;
}

kernel void dustStat(device uchar *img [[buffer(0)]], constant DustU &u [[buffer(1)]],
                     device const DustItem *items [[buffer(2)]], device const uint *cellStart [[buffer(3)]],
                     device const uint *cellItems [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.w || gid.y >= u.h) return;
  float2 pos = float2(gid) + 0.5;
  uint cx = min(uint(pos.x / u.cellPx), u.gridW - 1), cy = min(uint(pos.y / u.cellPx), u.gridH - 1);
  uint c = cy * u.gridW + cx;
  uint b = cellStart[c], e = cellStart[c + 1];
  if (b == e) return;
  float longPx = float(max(u.w, u.h));
  float cover = 0;
  for (uint k = b; k < e; k++) cover = max(cover, dustItemAlpha(items[cellItems[k]], pos, longPx));
  if (cover <= 0) return;
  uint i = gid.y * u.w + gid.x;
  float4 v = ld(img, i);
  v.rgb = mix(v.rgb, float3(u.white != 0 ? 1.0 : 0.02), min(cover * u.gain, 1.0));
  st(img, i, v);
}

static inline float rectSdf(float2 p, float2 center, float2 hs, float radius) {
  float2 d = abs(p - center) - hs + radius;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

kernel void frame(device const uchar *src [[buffer(0)]], constant PostU &u [[buffer(1)]],
                  device uchar *dst [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.w || gid.y >= u.h) return;
  float W = float(u.w), H = float(u.h), S = min(W, H);
  float2 pos = float2(gid) + 0.5;
  float2 c = float2(W, H) * 0.5;
  float3 paper = float3(0.955, 0.95, 0.93), base = float3(0.025);
  float3 col;
  float imageCover = 0;   // 0..1 coverage of the photo at this pixel
  float2 imgPos = pos;    // where to read the photo

  if (u.frameStyle == 1 || u.frameStyle == 2) {
    // print with a white paper margin; style 2 adds a filed black carrier edge
    float m = S * (0.015 + 0.07 * u.frameSize);
    float band = u.frameStyle == 2 ? S * (0.008 + 0.025 * u.frameSize) : 0.0;
    float k = min((W - 2 * (m + band)) / W, (H - 2 * (m + band)) / H);
    float2 hs = float2(W, H) * k * 0.5;
    imgPos = (pos - c) / k + c;
    float sdf = rectSdf(pos, c, hs, 0);
    if (u.frameStyle == 2) {
      float t = (abs(pos.x - c.x) / hs.x > abs(pos.y - c.y) / hs.y) ? pos.y : pos.x;
      sdf += u.frameRough * band * 0.8 * fbm1(t / (S * 0.012), 11u);
      float blackSdf = rectSdf(pos, c, hs + band * 0.6, 0);
      col = mix(base, paper, smoothstep(-0.7, 0.7, blackSdf));
    } else {
      col = paper;
    }
    imageCover = 1 - smoothstep(-0.7, 0.7, sdf);
  } else if (u.frameStyle == 3) {
    // 35 mm strip: 36x24 mm frame (stretched to the photo's aspect), perforations at 4.75 mm pitch
    bool portrait = H > W;
    float L = max(W, H);
    float imgL = 24.0 * L / S;
    float pxmm = min(L / (imgL + 5.0), S / 35.0);
    float2 local = (pos - c) / pxmm;
    if (portrait) local = float2(local.y, -local.x);
    float aa = 0.7 / pxmm;
    float sdfImg = rectSdf(local, float2(0), float2(imgL * 0.5, 12.0), 0.6);
    float2 hp = float2(fmod(fmod(local.x, 4.75) + 4.75, 4.75) - 2.375, abs(local.y) - 14.5);
    float sdfHole = rectSdf(hp, float2(0), float2(1.4, 0.99), 0.45);
    float sdfStrip = abs(local.y) - 17.5;
    col = mix(float3(0.92, 0.9, 0.86), base, smoothstep(-aa, aa, sdfHole));
    col = mix(col, float3(0.1), smoothstep(-aa, aa, sdfStrip));
    float k = (24.0 * pxmm) / S;
    imgPos = (pos - c) / k + c;
    imageCover = 1 - smoothstep(-aa, aa, sdfImg);
  } else {
    // instant film: thin sides and top, thick bottom; the photo fills its window
    float m = S * (0.035 + 0.05 * u.frameSize);
    float bottom = m * 3.2;
    float2 wmin = float2(m, m), wmax = float2(W - m, H - bottom);
    float2 wc = (wmin + wmax) * 0.5, wh = (wmax - wmin) * 0.5;
    float k = max(wh.x * 2 / W, wh.y * 2 / H);
    imgPos = (pos - wc) / k + c;
    col = float3(0.965, 0.96, 0.945);
    imageCover = 1 - smoothstep(-0.7, 0.7, rectSdf(pos, wc, wh, 0));
  }
  float4 photo = imageCover > 0 ? bilinear(src, u.w, u.h, imgPos) : float4(0, 0, 0, 1);
  st(dst, gid.y * u.w + gid.x, float4(mix(col, photo.rgb, imageCover), 1));
}

// MARK: - Bromide drag (BromideDrag.swift)
// Works on a small grid of scene log luminance (a stand-in for negative density): each cell averages
// the density upstream along the flow, weighted by distance, and the exposure there moves by the
// difference. Below a dense (bright) area the negative develops less, so the print gets a dark tail.

struct DragU {
  uint w, h, sw, sh, cell;
  float k, dx, dy, lenCells; int steps;
};

constant float kDragMaxD = 1.2;  // log10 units either side of middle grey

kernel void dragDown(device const uchar *src [[buffer(0)]], device float *grid [[buffer(1)]],
                     constant DragU &u [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.sw || gid.y >= u.sh) return;
  uint x0 = gid.x * u.cell, y0 = gid.y * u.cell;
  uint x1 = min(x0 + u.cell, u.w), y1 = min(y0 + u.cell, u.h);
  float sum = 0;
  for (uint y = y0; y < y1; y++)
    for (uint x = x0; x < x1; x++) {
      float3 c = ld(src, y * u.w + x).rgb;
      sum += max(dot(c, float3(0.2627, 0.6780, 0.0593)), 0.0);
    }
  float lum = sum / float(max((x1 - x0) * (y1 - y0), 1u));
  grid[gid.y * u.sw + gid.x] = clamp(log10(max(lum, 1e-5) / 0.18), -kDragMaxD, kDragMaxD);
}

kernel void dragShift(device const float *grid [[buffer(0)]], device float *shift [[buffer(1)]],
                      constant DragU &u [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.sw || gid.y >= u.sh) return;
  float here = grid[gid.y * u.sw + gid.x];
  float2 p = float2(gid);
  float sum = 0, wsum = 0;
  float fall = 3.0 / max(u.lenCells, 1e-3);  // about 5% left at the tail length
  for (int i = 1; i <= u.steps; i++) {
    float t = float(i) * u.lenCells / float(u.steps);
    float2 q = p - float2(u.dx, u.dy) * t;
    // Past the frame edge the film was never exposed: no bromide comes from there.
    if (q.x < 0 || q.y < 0 || q.x > float(u.sw - 1) || q.y > float(u.sh - 1)) break;
    uint2 a = uint2(q);
    uint2 b = min(a + 1, uint2(u.sw - 1, u.sh - 1));
    float2 f = q - float2(a);
    float d = mix(mix(grid[a.y * u.sw + a.x], grid[a.y * u.sw + b.x], f.x),
                  mix(grid[b.y * u.sw + a.x], grid[b.y * u.sw + b.x], f.x), f.y);
    float wt = exp(-t * fall);
    sum += d * wt;
    wsum += wt;
  }
  float up = wsum > 0 ? sum / wsum : here;
  shift[gid.y * u.sw + gid.x] = clamp(-u.k * (up - here), -0.6, 0.6);
}

kernel void dragApply(device const uchar *src [[buffer(0)]], device uchar *dst [[buffer(1)]],
                      device const float *shift [[buffer(2)]], constant DragU &u [[buffer(3)]],
                      uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= u.w || gid.y >= u.h) return;
  float2 q = clamp((float2(gid) + 0.5) / float(u.cell) - 0.5, float2(0), float2(u.sw - 1, u.sh - 1));
  uint2 a = uint2(q);
  uint2 b = min(a + 1, uint2(u.sw - 1, u.sh - 1));
  float2 f = q - float2(a);
  float s = mix(mix(shift[a.y * u.sw + a.x], shift[a.y * u.sw + b.x], f.x),
                mix(shift[b.y * u.sw + a.x], shift[b.y * u.sw + b.x], f.x), f.y);
  uint i = gid.y * u.w + gid.x;
  float4 v = ld(src, i);
  st(dst, i, float4(v.rgb * exp10(s), v.a));
}
