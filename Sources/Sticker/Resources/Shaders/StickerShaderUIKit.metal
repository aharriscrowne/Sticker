//  StickerShaderUIKit.metal
//
//  UIKit-compatible Metal pipeline using the original foil + reflection logic.
//

#include <metal_stdlib>
using namespace metal;

// ===== Shared structs =====

struct VertexIn {
    float2 position [[attribute(0)]]; // clip-space position (-1..1)
    float2 uv       [[attribute(1)]]; // 0..1
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Must match the Swift FoilUniforms struct exactly
struct FoilUniforms {
    float2 size;               // view size in pixels
    float2 offset;             // "offset" / motion
    float  scale;
    float  intensity;
    float  contrast;
    float  blendFactor;
    float  checkerScale;
    float  checkerIntensity;
    float  noiseScale;
    float  noiseIntensity;
    float  patternType;        // 0 = diamond, 1 = square
    float2 reflectionPosition; // UV coords (0..1)
    float  reflectionSize;     // radius-ish
    float  reflectionIntensity;
};

// ===== Helpers copied from FoilShader.metal =====

// A helper function to generate pseudo-random noise based on position
float uf_random(float2 uv) {
    return fract(sin(dot(uv.xy, float2(12.9898, 78.233))) * 43758.5453);
}

// Helper function to calculate brightness
float uf_calculateBrightness(half4 color) {
    return (color.r * 0.299 + color.g * 0.587 + color.b * 0.114);
}

float uf_noisePattern(float2 uv) {
    float2 i = floor(uv);
    float2 f = fract(uv);

    // Four corners in 2D of a tile
    float a = uf_random(i);
    float b = uf_random(i + float2(1.0, 0.0));
    float c = uf_random(i + float2(0.0, 1.0));
    float d = uf_random(i + float2(1.0, 1.0));

    // Smooth Interpolation
    float2 u = smoothstep(0.0, 1.0, f);

    // Mix 4 corners percentages
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// Function to mix colors with more intensity on lighter colors
half4 uf_lightnessMix(half4 baseColor, half4 overlayColor, float intensity, float baselineFactor) {
    // Calculate brightness of the base color
    float brightness = uf_calculateBrightness(baseColor);

    // Adjust mix factor based on brightness, with a minimum baseline for darker colors
    float adjustedMixFactor = max(smoothstep(0.2, 1.0, brightness) * intensity, baselineFactor);

    // Perform color mixing
    return mix(baseColor, overlayColor, adjustedMixFactor);
}

// Function to increase contrast based on a pattern value
half4 uf_increaseContrast(half4 source, float pattern, float intensity) {
    // Calculate the brightness of the source color
    float brightness = uf_calculateBrightness(source);

    // Determine the amount of contrast to apply, based on pattern and brightness
    float contrastFactor = mix(1.0, intensity, pattern * brightness);

    // Center the source color around 0.5, apply contrast adjustment, then re-center
    half4 contrastedColor = (source - half4(0.5)) * contrastFactor + half4(0.5);

    return contrastedColor;
}

float uf_squarePattern(float2 uv, float scale, float degreesAngle) {
    float radiansAngle = degreesAngle * M_PI_F / 180.0f;

    // Scale the UV coordinates
    uv *= scale;

    // Rotate the UV coordinates by the specified angle
    float cosAngle = cos(radiansAngle);
    float sinAngle = sin(radiansAngle);
    float2 rotatedUV = float2(
        cosAngle * uv.x - sinAngle * uv.y,
        sinAngle * uv.x + cosAngle * uv.y
    );

    // Determine if the current tile is black or white
    return fmod(floor(rotatedUV.x) + floor(rotatedUV.y), 2.0) == 0.0 ? 0.0 : 1.0;
}

float uf_diamondPattern(float2 uv, float scale) {
    // Hardcoded angle of 45 degrees for the diamond pattern
    return uf_squarePattern(uv, scale, 45.0);
}

float uf_stickerPattern(float option, float2 uv, float scale) {
    int iOption = int(round(option));

    switch (iOption) {
        case 0:
            return uf_diamondPattern(uv, scale);
        case 1:
            return uf_squarePattern(uv, scale, 0.0);
        default:
            return uf_diamondPattern(uv, scale); // Default as diamond
    }
}

// ===== Foil & reflection logic adapted from your stitchable shaders =====

half4 applyFoil(float2 position,
                half4 color,
                constant FoilUniforms& u)
{
    half originalAlpha = color.a;
    float2 size = u.size;

    // Calculate aspect ratio (width / height)
    float aspectRatio = size.x / size.y;

    // Normalize the offset by dividing by size to keep it consistent across different view sizes
    float2 normalizedOffset = (u.offset + size * 250.0f) / (size * u.scale) * 0.01f;
    float2 normalizedPosition = float2(position.x * aspectRatio, position.y);

    // Adjust UV coordinates by adding the normalized offset, then apply scaling
    float2 uv = (position / (size * u.scale)) + normalizedOffset;

    // Scale the noise based on the normalized position and noiseScale parameter
    float gradientNoise = uf_random(position) * 0.1f;
    float pattern = uf_stickerPattern(u.patternType, normalizedPosition / size * u.checkerScale, u.checkerScale);
    float noise = uf_noisePattern(position / size * u.noiseScale);

    // Calculate less saturated color shifts for a metallic effect
    half r = half(u.contrast + 0.25f * sin(uv.x * 10.0f + gradientNoise));
    half g = half(u.contrast + 0.25f * cos(uv.y * 10.0f + gradientNoise));
    half b = half(u.contrast + 0.25f * sin((uv.x + uv.y) * 10.0f - gradientNoise));

    half4 foilColor = half4(r, g, b, 1.0);
    half4 mixedFoilColor = uf_lightnessMix(color, foilColor, u.intensity, 0.3f);

    half4 checkerFoil = uf_increaseContrast(mixedFoilColor, pattern, u.checkerIntensity);
    half4 noiseCheckerFoil = uf_increaseContrast(checkerFoil, noise, u.noiseIntensity);

    // In the original foil() the blendFactor wasn’t used; here we use it
    // to control how much foil replaces the original.
    half4 result = mix(color, noiseCheckerFoil, u.blendFactor);
    result.a = originalAlpha;
    // Ensure premultiplied alpha: fully transparent pixels have zero RGB
    result.rgb *= originalAlpha;
    return result;
}

half4 applyReflection(float2 position,
                      half4 color,
                      constant FoilUniforms& u)
{
    half originalAlpha = color.a;
    float2 uv = position / u.size;

    float d = distance(uv, u.reflectionPosition);

    // Create a gradient based on the distance to achieve a smooth, blurred edge
    float blurFactor = smoothstep(u.reflectionSize / u.size.x, 0.0, d);

    // Calculate the reflection color based on intensity and blur factor
    half4 reflectionColor = half4(1.0, 1.0, 1.0, u.reflectionIntensity * blurFactor);

    // Blend the reflection with the original color
    half4 outColor = mix(color, reflectionColor, reflectionColor.a);
    outColor.a = originalAlpha;
    // Ensure premultiplied alpha for correct compositing around transparent areas
    outColor.rgb *= originalAlpha;
    return outColor;
}

// ===== Classic vertex + fragment entry points =====

vertex VertexOut stickerFoilVertex(VertexIn in [[stage_in]])
{
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    return out;
}

fragment half4 stickerFoilFragment(VertexOut in                 [[stage_in]],
                                   constant FoilUniforms& u     [[buffer(1)]],
                                   texture2d<half> colorTex     [[texture(0)]],
                                   sampler     colorSampler     [[sampler(0)]])
{
    float2 size = u.size;
    float2 position = in.uv * size;

    half4 baseColor = colorTex.sample(colorSampler, in.uv);

    half4 foil = applyFoil(position, baseColor, u);
    half4 withReflection = applyReflection(position, foil, u);

    return withReflection;
}
