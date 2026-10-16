#include <metal_stdlib>
using namespace metal;

// Filled-boundary geometry only; no foreground or desktop pixels. Each cell
// includes every segment within the full shoulder and derivative guard.
static float glassDistance(float2 p, device const void *bytes, uint2 n, float interior) {
    device const uint *w=static_cast<device const uint *>(bytes);
    uint2 c=min(uint2(max(p,float2(0))/float(w[4])),uint2(w[2]-1,w[3]-1));
    uint row=5+(c.y*w[2]+c.x)*2,first=w[row],count=w[row+1];
    device const float4 *segments=reinterpret_cast<device const float4 *>(w+w[0]);
    device const uint *indices=w+w[1];
    float best=interior*interior;
    for (uint i=0;i<count;i++) {
        float4 segment=segments[indices[first+i]];
        float2 v=segment.zw-segment.xy,q=p-segment.xy;
        float t=clamp(dot(q,v)/max(dot(v,v),0.0000001),0.0,1.0);
        float2 delta=q-v*t;best=min(best,dot(delta,delta));
    }
    return sqrt(best);
}

[[ stitchable ]]
half4 workbenchContinuousGlass(float2 p, texture2d<half> background,
    device const void *fieldBytes, int fieldByteCount, float2 fieldSize, float2 localSize,
    float4 surface, float4 imageRect, half4 canvas, half4 panel, float strength, float refracts) {
    float2 q = surface.xy + p / max(localSize, float2(0.001)) * surface.zw;
    uint2 n = uint2(max(fieldSize, float2(0)));
    if (refracts > 0 && strength > 0 && n.x >= 5 && n.y >= 5 && n.x <= 8196 && n.y <= 8196
        && fieldByteCount >= 7 * int(sizeof(uint)) && all(surface.zw > 0)) {
        float2 cell = p / max(localSize, float2(0.001)) * float2(n-4) + 2.0;
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
