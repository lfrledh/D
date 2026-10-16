#include <metal_stdlib>
using namespace metal;

// Signed distance samples from D's actual contour, with a two-sample exterior.
// This buffer contains geometry only, not foreground or desktop pixels.
static float glassSample(uint2 p, device const void *bytes, uint2 n, float interior) {
    device const uint *words = static_cast<device const uint *>(bytes);
    uint first = words[1+p.y*2], count = words[2+p.y*2];
    device const uint *spans = words + 1 + n.y*2;
    uint lo=0, hi=count;
    while (lo < hi) {
        uint mid=(lo+hi)/2;
        device const uint *span=spans+(first+mid)*3;
        if (p.x < span[0]) hi=mid;
        else if (p.x >= span[1]) lo=mid+1;
        else {
            device const half *values = reinterpret_cast<device const half *>(static_cast<device const uchar *>(bytes)+words[0]);
            return float(values[span[2]+p.x-span[0]]);
        }
    }
    return interior;
}
static float glassDistance(float2 p, device const void *bytes, uint2 n, float interior) {
    p = clamp(p, float2(0), float2(n - 1));
    uint2 a = uint2(floor(p)), b = min(a + 1, n - 1);
    float2 f = fract(p);
    return mix(mix(glassSample(a,bytes,n,interior), glassSample(uint2(b.x,a.y),bytes,n,interior), f.x),
               mix(glassSample(uint2(a.x,b.y),bytes,n,interior), glassSample(b,bytes,n,interior), f.x), f.y);
}

[[ stitchable ]]
half4 workbenchContinuousGlass(float2 p, texture2d<half> background,
    device const void *fieldBytes, int fieldByteCount, float2 fieldSize, float2 localSize,
    float4 surface, float4 imageRect, half4 canvas, half4 panel, float strength, float refracts) {
    float2 q = surface.xy + p / max(localSize, float2(0.001)) * surface.zw;
    uint2 n = uint2(max(fieldSize, float2(0)));
    if (refracts > 0 && strength > 0 && n.x >= 5 && n.y >= 5 && n.x <= 8196 && n.y <= 8196
        && fieldByteCount >= int((1 + n.y * 2) * sizeof(uint)) && all(surface.zw > 0)) {
        float2 cell = p / max(localSize, float2(0.001)) * float2(n-4) + 1.5;
        float pixel = min(surface.z / float(n.x-4), surface.w / float(n.y-4));
        float interior = 12.0 / max(pixel,0.001) + 4.0;
        float d = glassDistance(cell, fieldBytes, n, interior) * pixel;
        float rim = min(12.0, min(surface.z, surface.w) * 0.25);
        if (d > 0.0 && d < rim) {
        float t = d / max(rim,0.001);
        float2 g = float2(glassDistance(cell + float2(1,0),fieldBytes,n,interior) - glassDistance(cell-float2(1,0),fieldBytes,n,interior),
                          glassDistance(cell + float2(0,1),fieldBytes,n,interior) - glassDistance(cell-float2(0,1),fieldBytes,n,interior)) * 0.5;
        // Smooth normalization tends to zero on a medial axis, instead of a hard normal flip.
        float2 normal = g * rsqrt(dot(g,g) + 0.04);
        float shoulder = 16.0 * t*t * (1.0-t)*(1.0-t);
        // For a flat shoulder A/w=.12 has |A*g'/w|<.37; no discrete rings.
        q += normal * (0.12 * rim * clamp(strength,0.0,1.0) * shoulder);
        }
    }
    float2 uv = (q - imageRect.xy) / max(imageRect.zw, float2(0.001));
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    half4 source = all(uv >= 0.0) && all(uv <= 1.0) ? background.sample(linearSampler, uv) : canvas;
    source = half4(source.rgb + canvas.rgb * (1.0h-source.a), 1.0h);
    // Prepared input is already opaque; the same equation safely handles allocation fallback.
    return mix(panel, source, half(clamp(strength,0.0,1.0) * 0.82));
}
