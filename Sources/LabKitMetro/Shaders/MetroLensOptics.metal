// Metro Station lens optics (design spec §14), packaged for LabKitMetro.
//
// One SwiftUI layer shader for the decorative ink under the isolated native glass lens: a bounded achromatic shift that
// feathers to zero at the rim, plus a subtle red/blue split confined to diagonal edge arcs. The same maths, in Double,
// is `MetroLensRefraction` (Swift); keep them in step. Only decorative SwiftUI drawing enters this layer: native glass,
// the readout and the controls stay separate, unfiltered siblings.
//
// Package use: this file is compiled into LabKitMetro's own resource bundle (SwiftPM `.process("Shaders")` builds its
// default.metallib), and `MetroShaders.library` looks it up with `ShaderLibrary.bundle(Bundle.module)`. The starter's
// `ShaderLibrary.instrumentLensOptics` (the app's default library) would not find it from a package.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

static float metroSmootherstep(float value) {
    float t = clamp(value, 0.0, 1.0);
    return t * t * t * (10.0 + t * (-15.0 + 6.0 * t));
}

[[ stitchable ]] half4 metroLensOptics(
    float2 position, SwiftUI::Layer layer, float2 center, float radius, float2 tilt,
    float maximumShift, float rimStart, float curvature,
    float maximumChannelSplit, float chromaticInnerStart, float chromaticPeakRadius
) {
    if (radius <= 0.0 || maximumShift <= 0.0) return layer.sample(position);
    float2 local = (position - center) / radius;
    float r = length(local);
    if (r >= 1.0) return layer.sample(position);

    float t = clamp((r - rimStart) / (1.0 - rimStart), 0.0, 1.0);
    float remaining = 1.0 - t;
    float feather = remaining * remaining * remaining * (1.0 + 3.0 * t + 6.0 * t * t);
    float weight = feather * (1.0 - curvature * r * r);
    float2 boundedTilt = clamp(tilt, -1.0, 1.0);
    float2 source = position - boundedTilt * maximumShift * weight;
    half4 green = layer.sample(source);
    if (r <= chromaticInnerStart || maximumChannelSplit <= 0.0) return green;

    float radial = r <= chromaticPeakRadius
        ? metroSmootherstep((r - chromaticInnerStart) / (chromaticPeakRadius - chromaticInnerStart))
        : 1.0 - metroSmootherstep((r - chromaticPeakRadius) / (1.0 - chromaticPeakRadius));
    float diagonal = 2.0 * local.x * local.y / (r * r);
    // The supplied bound is the total red-to-blue separation; each side uses half.
    float2 split = boundedTilt * (0.5 * maximumChannelSplit * radial * diagonal * diagonal);
    half4 red = layer.sample(source + split);
    half4 blue = layer.sample(source - split);
    // Samples are already premultiplied: union alpha keeps the thin coloured fringe on transparent ink without
    // premultiplying twice, and each selected channel stays bounded by that alpha (SDR ink).
    half alpha = max(red.a, max(green.a, blue.a));
    half3 rgb = min(half3(red.r, green.g, blue.b), half3(alpha));
    return half4(rgb, alpha);
}
