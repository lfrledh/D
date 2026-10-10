#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The ONLY input texture is SwiftUI's local category content layer. Transparent
// samples stay transparent: no solid canvas substitute or window-server backdrop.
[[ stitchable ]] half4 workbenchCategoryRefraction(float2 p, SwiftUI::Layer content,
                                                   float2 origin, float2 size) {
    float2 center = origin + size * 0.5;
    float2 local = p - center;
    float radius = size.y * 0.5;
    float2 segment = float2(clamp(local.x, -size.x * 0.5 + radius, size.x * 0.5 - radius), 0);
    float2 radial = local - segment;
    float distance = length(radial);
    float inside = radius - distance;
    if (inside <= 0) return content.sample(p);

    float2 normal = radial / max(distance, 0.001);
    // A shallow lens body magnifies the input continuously. Curved shoulders
    // bend it more strongly near the rim, easing to zero at the exact boundary.
    float body = smoothstep(0.0, 4.5, inside);
    float shoulder = sin(clamp(inside / 7.0, 0.0, 1.0) * M_PI_F);
    float2 refracted = p - local * (0.105 * body) - normal * (1.8 * shoulder);
    half4 sharp = content.sample(refracted);
    // Small optical diffusion at the curved boundary, not a blurry label face.
    float blur = 0.22 * shoulder;
    half4 neighbors = (content.sample(refracted + normal * blur)
                     + content.sample(refracted - normal * blur)) * 0.5h;
    half4 transmitted = mix(sharp, neighbors, half(shoulder * 0.35));
    // Blend only over the subpixel edge. No white light stripe or opaque tint.
    return mix(content.sample(p), transmitted, half(smoothstep(0.0, 0.8, inside)));
}
