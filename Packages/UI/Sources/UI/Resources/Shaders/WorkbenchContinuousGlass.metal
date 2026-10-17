#include <metal_stdlib>
using namespace metal;

// Filled-boundary geometry only; no foreground or desktop pixels. Each cell
// includes every segment within the full shoulder and derivative guard.
static float glassDistance(float2 p, device const void *bytes, uint2 n, float interior, bool oriented = false) {
    device const uint *w=static_cast<device const uint *>(bytes);
    uint2 c=min(uint2(max(p,float2(0))/float(w[4])),uint2(w[2]-1,w[3]-1));
    uint row=5+(c.y*w[2]+c.x)*2,first=w[row],count=w[row+1];
    device const float4 *segments=reinterpret_cast<device const float4 *>(w+w[0]);
    device const uint *indices=w+w[1];
    float best=interior*interior,side=1.0;
    for (uint i=0;i<count;i++) {
        uint index=indices[first+i]*2;
        float4 segment=segments[index];
        float2 v=segment.zw-segment.xy,q=p-segment.xy;
        float t=clamp(dot(q,v)/max(dot(v,v),0.0000001),0.0,1.0);
        float2 delta=q-v*t;float squared=dot(delta,delta);
        if (squared<best) {
            best=squared;
            if (oriented) {
                // At a shared vertex use the adjacent inward normals. A single
                // edge cross product is ambiguous on the other edge's extension.
                float4 ends=segments[index+1];
                float2 normal=t<=0 ? ends.xy : (t>=1 ? ends.zw : float2(-v.y,v.x));
                side=dot(delta,normal)<0 ? -1.0 : 1.0;
            }
        }
    }
    return sqrt(best)*side;
}

static float2 glassContourPosition(float2 p,float2 localSize,float2 fieldSize) {
    return p / max(localSize,float2(0.001)) * (fieldSize-4.0) + 2.0;
}

// Pure sampling coordinates are shared with the offscreen GPU regression probe.
static float2 glassSamplePosition(float2 p, device const void *fieldBytes, int fieldByteCount,
    float2 fieldSize, float2 localSize, float4 surface, float strength, float refracts) {
    float2 q = surface.xy + p / max(localSize, float2(0.001)) * surface.zw;
    uint2 n = uint2(ceil(max(fieldSize, float2(0))));
    if (refracts > 0 && strength > 0 && n.x >= 5 && n.y >= 5 && n.x <= 8196 && n.y <= 8196
        && fieldByteCount >= 7 * int(sizeof(uint)) && all(surface.zw > 0)) {
        float2 cell = glassContourPosition(p,localSize,fieldSize);
        float pixel = min(surface.z / (fieldSize.x-4), surface.w / (fieldSize.y-4));
        float interior = 36.0 / max(pixel,0.001) + 4.0;
        float d = glassDistance(cell, fieldBytes, n, interior, true) * pixel;
        // Keep the accepted shoulder width; displacement gain is independent.
        float rim = min(18.0, min(surface.z, surface.w) * 0.25);
        if (d > 0.0 && d < rim) {
        float t = d / max(rim,0.001);
        // Signed distance keeps the outward sample negative: a straight edge
        // retains its full inward direction instead of losing half the lens.
        // Keep the full shoulder average, without near-zero normalization.
        float h = max(1.0, rim / max(pixel,0.001));
        float2 g = float2(glassDistance(cell + float2(h,0),fieldBytes,n,interior,true) - glassDistance(cell-float2(h,0),fieldBytes,n,interior,true),
                          glassDistance(cell + float2(0,h),fieldBytes,n,interior,true) - glassDistance(cell-float2(0,h),fieldBytes,n,interior,true)) / (2.0*h);
        // Move the peak outward and use the remaining shoulder for a gentle
        // return to the unchanged center. Both ends have zero value and slope.
        float shoulder = smoothstep(0.0,0.2,t) * (1.0-smoothstep(0.2,1.0,t));
        // The former unsigned straight-edge peak was .32 * 16*.6^3*.4^2.
        // Double that physical displacement, not a coefficient that folds it.
        float peakGain = 2.0 * 0.32 * 0.55296;
        q += g * (peakGain * rim * clamp(strength,0.0,1.0) * shoulder);
        }
    }
    return q;
}

[[ stitchable ]]
half4 workbenchContinuousGlass(float2 p, texture2d<half> background,
    device const void *fieldBytes, int fieldByteCount, float2 fieldSize, float2 localSize,
    float4 surface, float4 imageRect, half4 canvas, half4 panel, float strength, float refracts) {
    float2 q = glassSamplePosition(p,fieldBytes,fieldByteCount,fieldSize,localSize,surface,strength,refracts);
    float2 uv = (q - imageRect.xy) / max(imageRect.zw, float2(0.001));
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    half4 source = all(uv >= 0.0) && all(uv <= 1.0) ? background.sample(linearSampler, uv) : canvas;
    source = half4(source.rgb + canvas.rgb * (1.0h-source.a), 1.0h);
    // Prepared input is already opaque; the same equation safely handles allocation fallback.
    return mix(panel, source, half(clamp(strength,0.0,1.0) * 0.82));
}
