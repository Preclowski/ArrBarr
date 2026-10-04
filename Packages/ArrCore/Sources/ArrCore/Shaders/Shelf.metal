#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Helpers

static float shelfHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float shelfNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(shelfHash(i), shelfHash(i + float2(1, 0)), u.x),
               mix(shelfHash(i + float2(0, 1)), shelfHash(i + float2(1, 1)), u.x), u.y);
}

static float shelfFbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * shelfNoise(p);
        p *= 2.03;
        a *= 0.5;
    }
    return v;
}

// MARK: - Warp

// The strip bulges vertically toward the edges and splits into RGB fringes; `smear` (pt) is motion blur.
// Within `flat` (pt) of the centre nothing bends, so the selected poster stays a clean rectangle.
[[stitchable]] half4 shelfWarp(float2 p, SwiftUI::Layer layer, float2 size, float flat, float smear, float time) {
    float2 c = float2(size.x * 0.5, size.y * 0.44);
    float a = min(max(abs(p.x - c.x) - flat, 0.0) / max(size.x * 0.5 - flat, 1.0), 1.3);
    float k = 1.0 + 1.9 * pow(a, 2.4);
    float wobble = sin(p.x * 0.011 + time * 1.3) * 7.0 * a;
    float sy = c.y + (p.y - c.y) / k + wobble;
    float fringe = 14.0 * a * a + abs(smear) * 0.35;

    half4 acc = half4(0);
    const int taps = 9;
    for (int i = 0; i < taps; i++) {
        float t = (float(i) / float(taps - 1) - 0.5) * smear;
        float2 q = float2(p.x + t, sy);
        half4 r = layer.sample(q + float2(0, -fringe));
        half4 g = layer.sample(q);
        half4 b = layer.sample(q + float2(0, fringe));
        acc += half4(r.r, g.g, b.b, max(max(r.a, g.a), b.a));
    }
    return acc / half(taps);
}

// MARK: - Morph

// Liquid crossfade between two posters: both flow along an fbm field and a noise front eats one into the other.
[[stitchable]] half4 shelfMorph(float2 p, half4 color, float2 size, texture2d<half> from, texture2d<half> to, float progress, float time) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = p / size;
    float t = clamp(progress, 0.0, 1.0);
    float n = shelfFbm(uv * 2.6 + float2(time * 0.04, time * 0.03));
    float2 flow = float2(shelfFbm(uv * 1.8 + 7.3 + time * 0.08),
                         shelfFbm(uv * 1.8 + 1.7 - time * 0.07)) - 0.5;

    float front = t * 1.4 - 0.2;
    float mask = smoothstep(n - 0.12, n + 0.12, front);
    float seam = 1.0 - abs(mask * 2.0 - 1.0);

    float pull = sin(t * 3.14159);
    half4 a = from.sample(s, uv + flow * pull * 0.45);
    half4 b = to.sample(s, uv - flow * pull * 0.45);

    float ca = seam * 0.012;
    half4 aR = from.sample(s, uv + flow * pull * 0.45 + float2(ca, 0));
    half4 bB = to.sample(s, uv - flow * pull * 0.45 - float2(ca, 0));
    a.r = aR.r;
    b.b = bB.b;

    half4 col = mix(a, b, half(mask));
    half3 glow = half3(0.55 + 0.45 * sin(time + uv.y * 6.0), 0.4, 0.95) * half(seam * seam * 0.9);
    return half4(col.rgb + glow, 1.0) * color.a;
}

// MARK: - Tunnel

// Radial zoom blur toward the vanishing point, with a chromatic split that grows with speed.
[[stitchable]] half4 shelfZoomBlur(float2 p, SwiftUI::Layer layer, float2 center, float strength) {
    if (strength < 0.002) { return layer.sample(p); }
    float2 dir = p - center;
    half4 acc = half4(0);
    const int taps = 12;
    for (int i = 0; i < taps; i++) {
        float t = float(i) / float(taps - 1) * strength;
        half4 r = layer.sample(center + dir * (1.0 - t * 1.15));
        half4 g = layer.sample(center + dir * (1.0 - t));
        half4 b = layer.sample(center + dir * (1.0 - t * 0.85));
        acc += half4(r.r, g.g, b.b, max(max(r.a, g.a), b.a));
    }
    return acc / half(taps);
}

// MARK: - Earth at night

static float shelfHash3(float3 p) {
    return fract(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453);
}

static float shelfNoise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = mix(shelfHash3(i), shelfHash3(i + float3(1, 0, 0)), u.x);
    float b = mix(shelfHash3(i + float3(0, 1, 0)), shelfHash3(i + float3(1, 1, 0)), u.x);
    float c = mix(shelfHash3(i + float3(0, 0, 1)), shelfHash3(i + float3(1, 0, 1)), u.x);
    float d = mix(shelfHash3(i + float3(0, 1, 1)), shelfHash3(i + float3(1, 1, 1)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

static float shelfFbm3(float3 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * shelfNoise3(p);
        p = p * 2.03 + 17.1;
        a *= 0.5;
    }
    return v;
}

// The Planet's night side: continents traced by faint coasts and lit by clusters of city lights. The view is a
// 2.2r square; each pixel is ray-cast onto the same sphere the posters ride (camera 2.6 radii away), then turned
// back by the planet's rotation so the land moves with the posters.
[[stitchable]] half4 shelfEarth(float2 p, half4 color, float radius, float lon, float lat) {
    const float dist = 2.6;
    float2 s = (p - radius * 1.1) / radius;
    s.y = -s.y;
    float qa = dot(s, s) + dist * dist;
    float qb = -2.0 * dist * dist;
    float qc = dist * dist - 1.0;
    float disc = qb * qb - 4.0 * qa * qc;
    if (disc < 0.0) { return half4(0); }
    float k = (-qb - sqrt(disc)) / (2.0 * qa);
    float3 v = float3(s * k, dist * (1.0 - k));

    float y = v.y * cos(lat) + v.z * sin(lat);
    float z = -v.y * sin(lat) + v.z * cos(lat);
    float longitude = atan2(v.x, z) + lon;
    float latitude = asin(clamp(y, -1.0, 1.0));
    float3 point = float3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude));

    float h = shelfFbm3(point * 1.7 + 4.0);
    float land = smoothstep(0.525, 0.54, h);
    float coast = 1.0 - smoothstep(0.0, 0.008, abs(h - 0.532));
    float inland = smoothstep(0.54, 0.6, h);
    float density = smoothstep(0.36, 0.62, shelfFbm3(point * 5.0 + 9.0)) * max(inland, land * 0.35);
    float sparks = smoothstep(0.7, 0.93, shelfNoise3(point * 170.0)) + 0.6 * smoothstep(0.75, 0.95, shelfNoise3(point * 60.0 + 5.0));
    float glow = density * 0.45 + sparks * density * 2.6;

    half3 col = mix(half3(0.01h, 0.03h, 0.075h), half3(0.07h, 0.07h, 0.075h), half(land));
    col += half3(0.3h, 0.55h, 0.85h) * half(coast * 0.6);
    col += half3(1.0h, 0.72h, 0.35h) * half(glow);

    float facing = v.z;
    col *= half(0.3 + 0.7 * smoothstep(0.38, 0.95, facing));
    float rim = pow(1.0 - smoothstep(0.38, 0.7, facing), 2.0);
    col += half3(0.25h, 0.5h, 1.0h) * half(rim * 0.45);
    return half4(col, 1.0h) * color.a;
}

// MARK: - Lightbox tritone

/// The poster is put together from its three colour separations, the tunnel's split pulled apart: each drifts in
/// on its own random path, turn and scale, in a random order, and eases into register.
[[stitchable]] half4 posterTritone(float2 p, SwiftUI::Layer layer, float2 size, float progress, float seed) {
    const float lag = 0.1;
    float2 c = size * 0.5;
    float2 q = p - c;
    float reach = length(c);
    int order = int(seed * 6.0);                        // one of the six channel orders

    half3 rgb = half3(0.0);
    half alpha = 0.0h;
    for (int k = 0; k < 3; k++) {
        float4 h = float4(shelfHash(float2(seed * 91.7 + float(k) * 17.3, 1.3)),
                          shelfHash(float2(seed * 53.1 + float(k) * 11.9, 4.7)),
                          shelfHash(float2(seed * 37.9 + float(k) * 23.1, 8.2)),
                          shelfHash(float2(seed * 71.3 + float(k) * 5.7, 2.9)));
        int slot = order < 3 ? (k + order) % 3 : (2 - k + order) % 3;
        float t = clamp((progress - float(slot) * lag) / (1.0 - 2.0 * lag), 0.0, 1.0);
        float away = pow(1.0 - t, 3.0);
        float dir = h.x * 2.0 * M_PI_F;
        float2 r = q - float2(cos(dir), sin(dir)) * reach * (0.06 + 0.08 * h.y) * away;
        float ang = (h.z - 0.5) * 0.3 * away;
        float2 src = c + float2(r.x * cos(ang) - r.y * sin(ang), r.x * sin(ang) + r.y * cos(ang))
                       * (1.0 + (h.w - 0.5) * 0.25 * away);
        if (any(src < 0.0) || any(src > size)) { continue; }
        half4 s = layer.sample(src);
        half fade = half(smoothstep(0.0, 0.3, t));
        rgb[k] = s[k] * fade;
        alpha = max(alpha, s.a * fade);
    }
    return half4(rgb, alpha);
}
