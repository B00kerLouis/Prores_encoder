// Compiles embedded GPU kernels when a packaged Metal library is unavailable.

import Foundation
import Metal

/// Resolves required GPU functions and compiles the embedded source when needed.
enum EmbeddedMetalLibrary {
    /// Returns the first library containing every required function.
    static func load(
        device: MTLDevice,
        bundle: Bundle,
        requiredFunctions: [String]
    ) -> MTLLibrary? {
        if let library = device.makeDefaultLibrary(),
           library.hasMetalFunctions(requiredFunctions) {
            return library
        }
        if let embedded = makeEmbeddedLibrary(device: device),
           embedded.hasMetalFunctions(requiredFunctions) {
            return embedded
        }

        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        let candidates = [
            bundle.url(forResource: "default", withExtension: "metallib"),
            Bundle.main.url(forResource: "default", withExtension: "metallib"),
            executableDirectory.appendingPathComponent("default.metallib")
        ].compactMap { $0 }

        var visited = Set<URL>()
        for url in candidates
            where visited.insert(url.standardizedFileURL).inserted
                && FileManager.default.fileExists(atPath: url.path) {
            if let library = try? device.makeLibrary(URL: url),
               library.hasMetalFunctions(requiredFunctions) {
                return library
            }
        }
        return nil
    }

    /// Compiles the concatenated color and analysis kernels at runtime.
    private static func makeEmbeddedLibrary(device: MTLDevice) -> MTLLibrary? {
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        return try? device.makeLibrary(
            source: colorScienceKernels + "\n" + cmuAnalysisKernels,
            options: options
        )
    }

    private static let colorScienceKernels = #"""
#include <metal_stdlib>
using namespace metal;

// CPU-mirrored parameters for color conversion and LUT sampling.
struct ColorUniforms {
    float4 matrix0;
    float4 matrix1;
    float4 matrix2;
    uint inputTransfer;
    uint outputTransfer;
    uint inputYCbCrMatrix;
    uint outputYCbCrMatrix;
    float sourcePeakNits;
    float targetPeakNits;
    uint chromaVerticalSubsampling;
    uint gamutLimitMode;
    float4 inputLuma;
    float4 outputLuma;
    float4 lut1DMin;
    float4 lut1DScale;
    float4 lut3DMin;
    float4 lut3DScale;
    uint hasLUT1D;
    uint hasLUT3D;
    uint reserved0;
    uint reserved1;
};

constant float PQ_M1 = 0.25f * 2610.0f / 4096.0f;
constant float PQ_M2 = 128.0f * 2523.0f / 4096.0f;
constant float PQ_C2 = 32.0f * 2413.0f / 4096.0f;
constant float PQ_C3 = 32.0f * 2392.0f / 4096.0f;
constant float PQ_C1 = PQ_C3 - PQ_C2 + 1.0f;

constant float HLG_A = 0.17883277f;
constant float HLG_E_MAX = 3.0f;
constant float HLG_B = 0.07116723f;
constant float HLG_C = 0.80782559f;
constant float HLG_E_BREAK = 0.25f;

// Returns luma coefficients for the supported YCbCr matrix identifier.
inline float3 luma_coefficients(uint matrixID) {
    return matrixID == 0
        ? float3(0.2126f, 0.7152f, 0.0722f)
        : float3(0.2627f, 0.6780f, 0.0593f);
}

// Reconstructs encoded RGB from normalized YCbCr components.
inline float3 ycbcr_to_rgb(float y, float cb, float cr, uint matrixID) {
    const float3 k = luma_coefficients(matrixID);
    const float kr = k.r;
    const float kg = k.g;
    const float kb = k.b;
    const float r = y + 2.0f * (1.0f - kr) * cr;
    const float b = y + 2.0f * (1.0f - kb) * cb;
    const float g = (y - kr * r - kb * b) / kg;
    return float3(r, g, b);
}

// Converts encoded RGB to normalized luma and chroma components.
inline float3 rgb_to_ycbcr(float3 rgb, uint matrixID) {
    const float3 k = luma_coefficients(matrixID);
    const float y = dot(k, rgb);
    const float cb = (rgb.b - y) / (2.0f * (1.0f - k.b));
    const float cr = (rgb.r - y) / (2.0f * (1.0f - k.r));
    return float3(y, cb, cr);
}

// Converts normalized PQ values to absolute luminance in nits.
inline float3 pq_to_nits(float3 signal) {
    const float3 x = pow(max(signal, 0.0f), float3(1.0f / PQ_M2));
    const float3 numerator = max(x - PQ_C1, 0.0f);
    const float3 denominator = max(PQ_C2 - PQ_C3 * x, 1.0e-7f);
    return 10000.0f * pow(numerator / denominator, float3(1.0f / PQ_M1));
}

// Converts absolute luminance to normalized PQ values.
inline float3 nits_to_pq(float3 nits) {
    const float3 l = max(nits, 0.0f) / 10000.0f;
    const float3 y = pow(l, float3(PQ_M1));
    const float3 ratio = (PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y);
    return pow(max(ratio, 0.0f), float3(PQ_M2));
}

// Applies the inverse HLG opto-electronic transfer to one channel.
inline float hlg_inverse_scalar(float value) {
    const float ePrime = max(value, 0.0f);
    return ePrime < 0.5f
        ? ePrime * ePrime
        : HLG_B + exp((ePrime - HLG_C) / HLG_A);
}

// Applies the HLG opto-electronic transfer to one channel.
inline float hlg_oetf_scalar(float value) {
    const float e = max(value, 0.0f);
    return e < HLG_E_BREAK
        ? sqrt(e)
        : HLG_A * log(max(e - HLG_B, 1.0e-7f)) + HLG_C;
}

// Converts HLG signal values to display-referred luminance.
inline float3 hlg_to_nits(float3 signal, float peakNits, float3 lumaCoefficients) {
    float3 scene = float3(
        hlg_inverse_scalar(signal.r),
        hlg_inverse_scalar(signal.g),
        hlg_inverse_scalar(signal.b)
    );
    const float gamma = 1.2f + 0.42f * log10(max(peakNits, 1.0f) / 1000.0f);
    const float y = max(abs(dot(lumaCoefficients, scene)), 1.0e-4f);
    const float3 displayScaled = scene * pow(y, gamma - 1.0f);
    return displayScaled * (peakNits / pow(HLG_E_MAX, gamma));
}

// Converts display-referred luminance to HLG signal values.
inline float3 nits_to_hlg(float3 nits, float peakNits, float3 lumaCoefficients) {
    const float gamma = 1.2f + 0.42f * log10(max(peakNits, 1.0f) / 1000.0f);
    float3 displayScaled = max(nits, 0.0f) * (pow(HLG_E_MAX, gamma) / max(peakNits, 1.0f));
    const float y = max(abs(dot(lumaCoefficients, displayScaled)), 1.0e-4f);
    const float3 scene = displayScaled * pow(y, 1.0f / gamma - 1.0f);
    return float3(
        hlg_oetf_scalar(scene.r),
        hlg_oetf_scalar(scene.g),
        hlg_oetf_scalar(scene.b)
    );
}

// Decodes the selected input transfer function to absolute luminance.
inline float3 decode_transfer(float3 signal, constant ColorUniforms &u) {
    switch (u.inputTransfer) {
        case 0:
            return pow(max(signal, 0.0f), float3(2.4f)) * u.sourcePeakNits;
        case 1:
            return pow(max(signal, 0.0f), float3(2.6f)) * u.sourcePeakNits;
        case 2:
            return pq_to_nits(signal);
        case 3:
            return hlg_to_nits(signal, u.sourcePeakNits, u.inputLuma.xyz);
        default:
            return float3(0.0f);
    }
}

// Encodes absolute luminance with the selected output transfer function.
inline float3 encode_transfer(float3 nits, constant ColorUniforms &u) {
    switch (u.outputTransfer) {
        case 0:
            return pow(max(nits / max(u.targetPeakNits, 1.0f), 0.0f), float3(1.0f / 2.4f));
        case 1:
            return pow(max(nits / max(u.targetPeakNits, 1.0f), 0.0f), float3(1.0f / 2.6f));
        case 2:
            return nits_to_pq(nits);
        case 3:
            return nits_to_hlg(nits, u.targetPeakNits, u.outputLuma.xyz);
        default:
            return float3(0.0f);
    }
}

// Applies the source-to-target linear RGB matrix.
inline float3 apply_matrix(float3 rgb, constant ColorUniforms &u) {
    return u.matrix0.xyz * rgb.r
        + u.matrix1.xyz * rgb.g
        + u.matrix2.xyz * rgb.b;
}

// Compresses one luminance value from a higher source peak to a lower target peak.
inline float bt2446a_forward(float nits, float sourcePeak, float targetPeak) {
    const float phdr = 1.0f + 32.0f * pow(sourcePeak / 10000.0f, 1.0f / 2.4f);
    const float psdr = 1.0f + 32.0f * pow(targetPeak / 10000.0f, 1.0f / 2.4f);
    float x = pow(clamp(nits / sourcePeak, 0.0f, 1.0f), 1.0f / 2.4f);
    x = log(1.0f + (phdr - 1.0f) * x) / log(phdr);

    if (x <= 0.7399f) {
        x = 1.0770f * x;
    } else if (x < 0.9909f) {
        x = (-1.1510f * x + 2.7811f) * x - 0.6302f;
    } else {
        x = 0.5f * x + 0.5f;
    }

    x = (pow(psdr, x) - 1.0f) / (psdr - 1.0f);
    return targetPeak * pow(max(x, 0.0f), 2.4f);
}

// Evaluates the unnormalized inverse expansion curve.
inline float bt2446a_inverse_raw(float nits, float sourcePeak, float targetPeak) {
    float x = pow(clamp(nits / sourcePeak, 0.0f, 1.0f), 1.0f / 2.4f);
    x *= 255.0f;
    const float exponent = x > 70.0f
        ? (2.8305e-6f * x - 7.4622e-4f) * x + 1.2528f
        : (1.8712e-5f * x - 2.7334e-3f) * x + 1.3141f;
    x = pow(max(x, 0.0f), exponent);
    return targetPeak * pow(x / 1000.0f, 2.4f);
}

// Expands one luminance value and normalizes the endpoint to the target peak.
inline float bt2446a_inverse(float nits, float sourcePeak, float targetPeak) {
    const float endpoint = bt2446a_inverse_raw(sourcePeak, sourcePeak, targetPeak);
    return bt2446a_inverse_raw(nits, sourcePeak, targetPeak)
        * (targetPeak / max(endpoint, 1.0e-6f));
}

// Maps luminance between unequal mastering peaks while preserving RGB ratios.
inline float3 tone_map(float3 rgb, constant ColorUniforms &u) {
    const float sourcePeak = max(u.sourcePeakNits, 1.0f);
    const float targetPeak = max(u.targetPeakNits, 1.0f);

    // ITU-R BT.2446 Method A is a display-referred EETF intended for converting
    // mastered HDR/SDR programme material.  Its published inverse is used for
    // range expansion so every peak-direction combination follows one matched
    // pair of curves.  Equal-peak conversions remain strictly colorimetric.
    if (abs(sourcePeak - targetPeak) <= 0.01f) {
        return rgb;
    }

    const float luminance = max(dot(u.outputLuma.xyz, rgb), 0.0f);
    if (luminance <= 1.0e-7f) {
        return rgb;
    }

    const float mappedLuminance = sourcePeak > targetPeak
        ? bt2446a_forward(luminance, sourcePeak, targetPeak)
        : bt2446a_inverse(luminance, sourcePeak, targetPeak);
    const float scale = mappedLuminance / max(luminance, 1.0e-6f);
    return rgb * scale;
}

// Reduces out-of-range chroma around target-gamut luminance.
inline float3 gamut_compress(float3 rgb, constant ColorUniforms &u) {
    const float peak = max(u.targetPeakNits, 1.0f);
    const float luma = clamp(dot(u.outputLuma.xyz, rgb), 0.0f, peak);
    const float3 chroma = rgb - luma;
    float scale = 1.0f;

    for (uint channel = 0; channel < 3; ++channel) {
        const float c = chroma[channel];
        if (c > 0.0f) {
            scale = min(scale, (peak - luma) / c);
        } else if (c < 0.0f) {
            scale = min(scale, (0.0f - luma) / c);
        }
    }

    if (scale < 1.0f) {
        scale = max(scale, 0.0f) * (0.96f + 0.04f * max(scale, 0.0f));
    }
    return clamp(float3(luma) + chroma * scale, 0.0f, peak);
}

// Applies the same chroma compression with explicit luma coefficients.
inline float3 gamut_compress_with_luma(float3 rgb, float3 lumaCoefficients, float peak) {
    const float luma = clamp(dot(lumaCoefficients, rgb), 0.0f, peak);
    const float3 chroma = rgb - luma;
    float scale = 1.0f;

    for (uint channel = 0; channel < 3; ++channel) {
        const float c = chroma[channel];
        if (c > 0.0f) {
            scale = min(scale, (peak - luma) / c);
        } else if (c < 0.0f) {
            scale = min(scale, (0.0f - luma) / c);
        }
    }

    if (scale < 1.0f) {
        scale = max(scale, 0.0f) * (0.96f + 0.04f * max(scale, 0.0f));
    }
    return clamp(float3(luma) + chroma * scale, 0.0f, peak);
}

// Compresses Rec.2020 values through P3-D65 and converts them back for tagging.
inline float3 limit_rec2020_to_p3d65(float3 rec2020, float peak) {
    // D65-adapted linear-light matrices derived from the same Rec.2020 and
    // P3-D65 RGB-to-XYZ matrices used by ColorTransform.swift.
    float3 p3;
    p3.r = 1.34357825f * rec2020.r - 0.28217967f * rec2020.g - 0.06139859f * rec2020.b;
    p3.g = -0.06529745f * rec2020.r + 1.07578791f * rec2020.g - 0.01049045f * rec2020.b;
    p3.b = 0.00282179f * rec2020.r - 0.01959850f * rec2020.g + 1.01677671f * rec2020.b;
    p3 = gamut_compress_with_luma(
        p3,
        float3(0.22897456f, 0.69173852f, 0.07928691f),
        peak
    );

    float3 limited;
    limited.r = 0.75383304f * p3.r + 0.19859737f * p3.g + 0.04756960f * p3.b;
    limited.g = 0.04574384f * p3.r + 0.94177722f * p3.g + 0.01247892f * p3.b;
    limited.b = -0.00121034f * p3.r + 0.01760172f * p3.g + 0.98360862f * p3.b;
    return clamp(limited, 0.0f, peak);
}

// Normalized linear sampler used by both LUT dimensions.
constexpr sampler lut_sampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

// Applies per-channel 1D sampling with domain and texel-center correction.
inline float3 apply_1d_lut(
    float3 rgb,
    texture2d<float, access::sample> lut,
    constant ColorUniforms &u
) {
    if (u.hasLUT1D == 0) {
        return rgb;
    }
    const float3 normalized = clamp(
        (rgb - u.lut1DMin.xyz) * u.lut1DScale.xyz,
        float3(0.0f),
        float3(1.0f)
    );
    const float width = float(lut.get_width());
    const float3 coordinate = (normalized * (width - 1.0f) + 0.5f) / width;
    return float3(
        lut.sample(lut_sampler, float2(coordinate.r, 0.5f)).r,
        lut.sample(lut_sampler, float2(coordinate.g, 0.5f)).g,
        lut.sample(lut_sampler, float2(coordinate.b, 0.5f)).b
    );
}

// Applies trilinear 3D sampling with domain and texel-center correction.
inline float3 apply_3d_lut(
    float3 rgb,
    texture3d<float, access::sample> lut,
    constant ColorUniforms &u
) {
    if (u.hasLUT3D == 0) {
        return rgb;
    }
    const float3 normalized = clamp(
        (rgb - u.lut3DMin.xyz) * u.lut3DScale.xyz,
        float3(0.0f),
        float3(1.0f)
    );
    const float3 dimensions = float3(
        float(lut.get_width()),
        float(lut.get_height()),
        float(lut.get_depth())
    );
    const float3 coordinate = (normalized * (dimensions - 1.0f) + 0.5f) / dimensions;
    return lut.sample(lut_sampler, coordinate).rgb;
}

// Reconstructs encoded RGB and decodes transfer only for direct mapping mode.
kernel void color_decode_yuv(
    texture2d<float, access::read> sourceY [[texture(0)]],
    texture2d<float, access::read> sourceUV [[texture(1)]],
    texture2d<half, access::write> linearOutput [[texture(2)]],
    constant ColorUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= linearOutput.get_width() || gid.y >= linearOutput.get_height()) {
        return;
    }
    const float rawY = sourceY.read(gid).r;
    const uint2 uvPosition = uint2(gid.x / 2, gid.y / max(u.chromaVerticalSubsampling, 1u));
    const float2 rawUV = sourceUV.read(uvPosition).rg;
    const float y = (rawY * 1023.0f - 64.0f) / 876.0f;
    const float cb = (rawUV.r * 1023.0f - 512.0f) / 896.0f;
    const float cr = (rawUV.g * 1023.0f - 512.0f) / 896.0f;
    const float3 signal = ycbcr_to_rgb(y, cb, cr, u.inputYCbCrMatrix);
    const bool lutMode = u.hasLUT1D != 0 || u.hasLUT3D != 0;
    const float3 workingRGB = lutMode ? signal : decode_transfer(signal, u);
    linearOutput.write(half4(half3(workingRGB), half(1.0f)), gid);
}

// Reads BGRA source pixels and decodes transfer only for direct mapping mode.
kernel void color_decode_bgra(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<half, access::write> linearOutput [[texture(1)]],
    constant ColorUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= linearOutput.get_width() || gid.y >= linearOutput.get_height()) {
        return;
    }
    const float4 pixel = source.read(gid);
    const bool lutMode = u.hasLUT1D != 0 || u.hasLUT3D != 0;
    const float3 workingRGB = lutMode ? pixel.rgb : decode_transfer(pixel.rgb, u);
    linearOutput.write(half4(half3(workingRGB), half(pixel.a)), gid);
}

// Runs LUT burn-in on encoded RGB or the complete direct linear-light transform.
kernel void color_transform_linear(
    texture2d<half, access::read> linearInput [[texture(0)]],
    texture2d<half, access::write> encodedOutput [[texture(1)]],
    texture2d<float, access::sample> lut1D [[texture(2)]],
    texture3d<float, access::sample> lut3D [[texture(3)]],
    constant ColorUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= encodedOutput.get_width() || gid.y >= encodedOutput.get_height()) {
        return;
    }
    const float4 source = float4(linearInput.read(gid));
    const bool lutMode = u.hasLUT1D != 0 || u.hasLUT3D != 0;
    float3 rgb;
    if (lutMode) {
        // LUT target options describe the table output; the table consumes
        // encoded RGB reconstructed from the source sample.
        rgb = apply_1d_lut(source.rgb, lut1D, u);
        rgb = apply_3d_lut(rgb, lut3D, u);
    } else {
        rgb = apply_matrix(source.rgb, u);
        rgb = tone_map(rgb, u);
        rgb = u.gamutLimitMode == 1
            ? limit_rec2020_to_p3d65(rgb, max(u.targetPeakNits, 1.0f))
            : gamut_compress(rgb, u);
        rgb = encode_transfer(rgb, u);
    }
    encodedOutput.write(half4(half3(clamp(rgb, 0.0f, 1.0f)), half(source.a)), gid);
}

// Writes video-range 10-bit luma from output encoded RGB.
kernel void color_pack_y(
    texture2d<half, access::read> encodedInput [[texture(0)]],
    texture2d<float, access::write> outputY [[texture(1)]],
    constant ColorUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputY.get_width() || gid.y >= outputY.get_height()) {
        return;
    }
    const float3 rgb = float3(encodedInput.read(gid).rgb);
    const float y = rgb_to_ycbcr(rgb, u.outputYCbCrMatrix).x;
    const float code = (64.0f + 876.0f * clamp(y, 0.0f, 1.0f)) / 1023.0f;
    outputY.write(float4(code, 0.0f, 0.0f, 1.0f), gid);
}

// Averages encoded RGB over the output chroma footprint and writes CbCr.
kernel void color_pack_uv(
    texture2d<half, access::read> encodedInput [[texture(0)]],
    texture2d<float, access::write> outputUV [[texture(1)]],
    constant ColorUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputUV.get_width() || gid.y >= outputUV.get_height()) {
        return;
    }
    const uint sourceY = gid.y * max(u.chromaVerticalSubsampling, 1u);
    float3 average = float3(0.0f);
    uint count = 0;
    for (uint dy = 0; dy < max(u.chromaVerticalSubsampling, 1u); ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            const uint2 position = uint2(
                min(gid.x * 2 + dx, encodedInput.get_width() - 1),
                min(sourceY + dy, encodedInput.get_height() - 1)
            );
            average += float3(encodedInput.read(position).rgb);
            count += 1;
        }
    }
    average /= float(max(count, 1u));
    const float3 yuv = rgb_to_ycbcr(average, u.outputYCbCrMatrix);
    const float cbCode = (512.0f + 896.0f * clamp(yuv.y, -0.5f, 0.5f)) / 1023.0f;
    const float crCode = (512.0f + 896.0f * clamp(yuv.z, -0.5f, 0.5f)) / 1023.0f;
    outputUV.write(float4(cbCode, crCode, 0.0f, 1.0f), gid);
}

// Writes output encoded RGB to a BGRA-compatible texture.
kernel void color_pack_bgra(
    texture2d<half, access::read> encodedInput [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ColorUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    output.write(float4(encodedInput.read(gid)), gid);
}

"""#

    private static let cmuAnalysisKernels = #"""
#include <metal_stdlib>
using namespace metal;

constant uint CMU_HISTOGRAM_BINS = 4096;
constant float CMU_LOG_MAX = 13.2878566f; // log2(10001)
constant float CMU_EXTREMA_SCALE = 1000.0f;

// Image geometry and color interpretation for one analysis dispatch.
struct CMUUniforms {
    uint width;
    uint height;
    uint matrixID;
    uint fullRange;
    float4 lumaCoefficients;
};

// Per-workgroup sums reduced after GPU completion.
struct CMUPartialStats {
    float4 sums0; // luma, red, green, blue
    float4 sums1; // saturation, count, PQ(maxRGB), PQ(maxRGB)^2
};

// Returns luma coefficients for the supported YCbCr matrix identifier.
inline float3 cmu_luma_coefficients(uint matrixID) {
    return matrixID == 0
        ? float3(0.2126f, 0.7152f, 0.0722f)
        : float3(0.2627f, 0.6780f, 0.0593f);
}

// Reconstructs encoded RGB from normalized YCbCr components.
inline float3 cmu_ycbcr_to_rgb(float y, float cb, float cr, uint matrixID) {
    const float3 k = cmu_luma_coefficients(matrixID);
    const float r = y + 2.0f * (1.0f - k.r) * cr;
    const float b = y + 2.0f * (1.0f - k.b) * cb;
    const float g = (y - k.r * r - k.b * b) / k.g;
    return float3(r, g, b);
}

// Converts normalized PQ code values to absolute luminance in nits.
inline float3 cmu_pq_to_nits(float3 signal) {
    constexpr float m1 = 2610.0f / 16384.0f;
    constexpr float m2 = 2523.0f / 32.0f;
    constexpr float c1 = 3424.0f / 4096.0f;
    constexpr float c2 = 2413.0f / 128.0f;
    constexpr float c3 = 2392.0f / 128.0f;
    const float3 powered = pow(max(signal, 0.0f), float3(1.0f / m2));
    const float3 numerator = max(powered - c1, 0.0f);
    const float3 denominator = max(c2 - c3 * powered, 1.0e-7f);
    return 10000.0f * pow(numerator / denominator, float3(1.0f / m1));
}

// Accumulates extrema, a log-luminance histogram, and workgroup channel sums.
kernel void cmu_analyze_yuv(
    texture2d<float, access::read> sourceY [[texture(0)]],
    texture2d<float, access::read> sourceUV [[texture(1)]],
    device atomic_uint *histogram [[buffer(0)]],
    device atomic_uint *extrema [[buffer(1)]],
    device CMUPartialStats *partials [[buffer(2)]],
    constant CMUUniforms &uniforms [[buffer(3)]],
    uint2 position [[thread_position_in_grid]],
    uint2 threadgroupPosition [[threadgroup_position_in_grid]],
    uint localIndex [[thread_index_in_threadgroup]],
    uint2 groupsPerGrid [[threadgroups_per_grid]]
) {
    threadgroup float lumaSums[256];
    threadgroup float redSums[256];
    threadgroup float greenSums[256];
    threadgroup float blueSums[256];
    threadgroup float saturationSums[256];
    threadgroup float counts[256];
    threadgroup float maxRGBPQSums[256];
    threadgroup float maxRGBPQSquareSums[256];

    float luma = 0.0f;
    float3 rgbNits = float3(0.0f);
    float saturation = 0.0f;
    float count = 0.0f;
    float maxRGBPQ = 0.0f;

    if (position.x < uniforms.width && position.y < uniforms.height) {
        const float yCode = sourceY.read(position).r * 1023.0f;
        const uint2 uvPosition = uint2(position.x / 2, position.y / 2);
        const float2 uvCode = sourceUV.read(uvPosition).rg * 1023.0f;

        const float y = uniforms.fullRange != 0
            ? yCode / 1023.0f
            : (yCode - 64.0f) / 876.0f;
        const float cb = uniforms.fullRange != 0
            ? (uvCode.x - 512.0f) / 1023.0f
            : (uvCode.x - 512.0f) / 896.0f;
        const float cr = uniforms.fullRange != 0
            ? (uvCode.y - 512.0f) / 1023.0f
            : (uvCode.y - 512.0f) / 896.0f;

        const float3 rgbSignal = clamp(
            cmu_ycbcr_to_rgb(y, cb, cr, uniforms.matrixID),
            0.0f,
            1.0f
        );
        maxRGBPQ = max(max(rgbSignal.r, rgbSignal.g), rgbSignal.b);
        rgbNits = cmu_pq_to_nits(rgbSignal);
        luma = clamp(dot(uniforms.lumaCoefficients.xyz, rgbNits), 0.0f, 10000.0f);
        const float maximum = max(max(rgbNits.r, rgbNits.g), rgbNits.b);
        const float minimum = min(min(rgbNits.r, rgbNits.g), rgbNits.b);
        saturation = maximum > 1.0e-6f ? (maximum - minimum) / maximum : 0.0f;
        count = 1.0f;

        const float normalizedLog = log2(1.0f + luma) / CMU_LOG_MAX;
        const uint bin = min(
            uint(clamp(normalizedLog, 0.0f, 1.0f) * float(CMU_HISTOGRAM_BINS - 1)),
            CMU_HISTOGRAM_BINS - 1
        );
        atomic_fetch_add_explicit(&histogram[bin], 1u, memory_order_relaxed);

        const uint maxRGBScaled = uint(clamp(maximum, 0.0f, 10000.0f) * CMU_EXTREMA_SCALE + 0.5f);
        const uint maxLumaScaled = uint(luma * CMU_EXTREMA_SCALE + 0.5f);
        atomic_fetch_max_explicit(&extrema[0], maxRGBScaled, memory_order_relaxed);
        atomic_fetch_max_explicit(&extrema[1], maxLumaScaled, memory_order_relaxed);
        atomic_fetch_min_explicit(&extrema[2], maxLumaScaled, memory_order_relaxed);
    }

    lumaSums[localIndex] = luma;
    redSums[localIndex] = rgbNits.r;
    greenSums[localIndex] = rgbNits.g;
    blueSums[localIndex] = rgbNits.b;
    saturationSums[localIndex] = saturation;
    counts[localIndex] = count;
    maxRGBPQSums[localIndex] = maxRGBPQ;
    maxRGBPQSquareSums[localIndex] = maxRGBPQ * maxRGBPQ;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (localIndex < stride) {
            lumaSums[localIndex] += lumaSums[localIndex + stride];
            redSums[localIndex] += redSums[localIndex + stride];
            greenSums[localIndex] += greenSums[localIndex + stride];
            blueSums[localIndex] += blueSums[localIndex + stride];
            saturationSums[localIndex] += saturationSums[localIndex + stride];
            counts[localIndex] += counts[localIndex + stride];
            maxRGBPQSums[localIndex] += maxRGBPQSums[localIndex + stride];
            maxRGBPQSquareSums[localIndex] += maxRGBPQSquareSums[localIndex + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (localIndex == 0) {
        const uint groupIndex = threadgroupPosition.y * groupsPerGrid.x + threadgroupPosition.x;
        partials[groupIndex].sums0 = float4(
            lumaSums[0],
            redSums[0],
            greenSums[0],
            blueSums[0]
        );
        partials[groupIndex].sums1 = float4(
            saturationSums[0],
            counts[0],
            maxRGBPQSums[0],
            maxRGBPQSquareSums[0]
        );
    }
}

// Source geometry and padding shared by BL preparation and FEL analysis.
struct P7RasterUniforms {
    uint sourceWidth;
    uint sourceHeight;
    uint canvasWidth;
    uint canvasHeight;
    uint leftOffset;
    uint topOffset;
    uint reserved0;
    uint reserved1;
};

constant float P7_WORD_MAX = 65535.0f;
constant float P7_P010_SHIFT = 64.0f;
constant float P7_SOURCE12_SHIFT = 16.0f;
constant float P7_HORIZONTAL_WEIGHTS[8] = {
    22.0f / 4096.0f,
    94.0f / 4096.0f,
    -524.0f / 4096.0f,
    2456.0f / 4096.0f,
    2456.0f / 4096.0f,
    -524.0f / 4096.0f,
    94.0f / 4096.0f,
    22.0f / 4096.0f
};
constant int P7_HORIZONTAL_OFFSETS[8] = {-3, -2, -1, 0, 1, 2, 3, 4};
constant float P7_LUMA_VERTICAL_EVEN_WEIGHTS[4] = {
    -3.0f / 128.0f, 29.0f / 128.0f, 111.0f / 128.0f, -9.0f / 128.0f
};
constant int P7_LUMA_VERTICAL_EVEN_OFFSETS[4] = {-2, -1, 0, 1};
constant float P7_LUMA_VERTICAL_ODD_WEIGHTS[4] = {
    -9.0f / 128.0f, 111.0f / 128.0f, 29.0f / 128.0f, -3.0f / 128.0f
};
constant int P7_LUMA_VERTICAL_ODD_OFFSETS[4] = {-1, 0, 1, 2};
constant float P7_CHROMA_VERTICAL_EVEN_WEIGHTS[2] = {64.0f / 256.0f, 192.0f / 256.0f};
constant int P7_CHROMA_VERTICAL_EVEN_OFFSETS[2] = {-1, 0};
constant float P7_CHROMA_VERTICAL_ODD_WEIGHTS[2] = {192.0f / 256.0f, 64.0f / 256.0f};
constant int P7_CHROMA_VERTICAL_ODD_OFFSETS[2] = {0, 1};

inline int p7_clamped_index(int value, int upperBound) {
    return clamp(value, 0, upperBound - 1);
}

inline float p7_source12(float normalizedWord) {
    return round(normalizedWord * P7_WORD_MAX / P7_SOURCE12_SHIFT);
}

inline float p7_p010_code(float normalizedWord) {
    return round(normalizedWord * P7_WORD_MAX / P7_P010_SHIFT);
}

inline float2 p7_p010_code(float2 normalizedWord) {
    return round(normalizedWord * P7_WORD_MAX / P7_P010_SHIFT);
}

inline float p7_p010_normalized(float code) {
    return clamp(code, 0.0f, 1023.0f) * P7_P010_SHIFT / P7_WORD_MAX;
}

inline float p7_forward_nlq(float desiredContribution12) {
    const float integerContribution = round(desiredContribution12);
    const float offset = integerContribution > 0.0f
        ? integerContribution
        : (integerContribution < 0.0f ? integerContribution - 1.0f : 0.0f);
    return clamp(offset, -512.0f, 511.0f);
}

inline bool p7_inside_luma(uint2 position, constant P7RasterUniforms &u) {
    return position.x >= u.leftOffset && position.y >= u.topOffset
        && position.x < u.leftOffset + u.sourceWidth
        && position.y < u.topOffset + u.sourceHeight;
}

inline bool p7_inside_chroma(uint2 position, constant P7RasterUniforms &u) {
    const uint left = u.leftOffset / 2;
    const uint top = u.topOffset / 2;
    return position.x >= left && position.y >= top
        && position.x < left + u.sourceWidth / 2
        && position.y < top + u.sourceHeight / 2;
}

inline float2 p7_source_chroma12(
    texture2d<float, access::read> sourceUV,
    uint2 canvasPosition,
    constant P7RasterUniforms &u
) {
    if (!p7_inside_chroma(canvasPosition, u)) {
        return float2(2048.0f);
    }
    const uint2 sourcePosition = uint2(
        canvasPosition.x - u.leftOffset / 2,
        (canvasPosition.y - u.topOffset / 2) * 2
    );
    const uint nextRow = min(sourcePosition.y + 1, u.sourceHeight - 1);
    const float2 averageWord = 0.5f * (
        sourceUV.read(sourcePosition).rg +
        sourceUV.read(uint2(sourcePosition.x, nextRow)).rg
    );
    return round(averageWord * P7_WORD_MAX / P7_SOURCE12_SHIFT);
}

// Pads high-precision 4:2:2 luma and quantizes only the HDR10 base layer.
kernel void p7_prepare_bl_luma(
    texture2d<float, access::read> sourceY [[texture(0)]],
    texture2d<float, access::write> outputY [[texture(1)]],
    constant P7RasterUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputY.get_width() || position.y >= outputY.get_height()) {
        return;
    }
    float sourceCode12 = 256.0f;
    if (p7_inside_luma(position, u)) {
        sourceCode12 = p7_source12(
            sourceY.read(position - uint2(u.leftOffset, u.topOffset)).r
        );
    }
    outputY.write(float4(p7_p010_normalized(round(sourceCode12 / 4.0f))), position);
}

// Converts high-precision 4:2:2 chroma to 4:2:0 while padding the BL canvas.
kernel void p7_prepare_bl_chroma(
    texture2d<float, access::read> sourceUV [[texture(0)]],
    texture2d<float, access::write> outputUV [[texture(1)]],
    constant P7RasterUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= outputUV.get_width() || position.y >= outputUV.get_height()) {
        return;
    }
    const float2 sourceCode12 = p7_source_chroma12(sourceUV, position, u);
    const float2 code10 = round(sourceCode12 / 4.0f);
    outputUV.write(float4(
        p7_p010_normalized(code10.x),
        p7_p010_normalized(code10.y),
        0.0f,
        1.0f
    ), position);
}

// Builds the exact full-resolution EL offset requested by the fixed FEL NLQ.
kernel void p7_make_target_luma(
    texture2d<float, access::read> sourceY [[texture(0)]],
    texture2d<float, access::read> reconstructedY [[texture(1)]],
    texture2d<float, access::write> target [[texture(2)]],
    constant P7RasterUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= target.get_width() || position.y >= target.get_height()) {
        return;
    }
    float sourceCode12 = 256.0f;
    if (p7_inside_luma(position, u)) {
        sourceCode12 = p7_source12(
            sourceY.read(position - uint2(u.leftOffset, u.topOffset)).r
        );
    }
    const float reconstructedCode12 = 4.0f * p7_p010_code(reconstructedY.read(position).r);
    target.write(float4(p7_forward_nlq(sourceCode12 - reconstructedCode12)), position);
}

kernel void p7_make_target_chroma(
    texture2d<float, access::read> sourceUV [[texture(0)]],
    texture2d<float, access::read> reconstructedUV [[texture(1)]],
    texture2d<float, access::write> target [[texture(2)]],
    constant P7RasterUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= target.get_width() || position.y >= target.get_height()) {
        return;
    }
    const float2 sourceCode12 = p7_source_chroma12(sourceUV, position, u);
    const float2 reconstructedCode12 = 4.0f * p7_p010_code(reconstructedUV.read(position).rg);
    const float2 desired = sourceCode12 - reconstructedCode12;
    target.write(float4(
        p7_forward_nlq(desired.x),
        p7_forward_nlq(desired.y),
        0.0f,
        1.0f
    ), position);
}

inline float p7_adjoint_horizontal_luma_value(
    texture2d<float, access::read> input,
    uint2 position,
    uint halfWidth
) {
    const int n = int(position.x);
    float sum = input.read(uint2(position.x * 2, position.y)).r;
    const int start = max(0, n - 4);
    const int end = min(int(halfWidth) - 1, n + 3);
    for (int m = start; m <= end; ++m) {
        const float oddValue = input.read(uint2(uint(m * 2 + 1), position.y)).r;
        for (uint k = 0; k < 8; ++k) {
            if (p7_clamped_index(m + P7_HORIZONTAL_OFFSETS[k], int(halfWidth)) == n) {
                sum += P7_HORIZONTAL_WEIGHTS[k] * oddValue;
            }
        }
    }
    return sum;
}

inline float2 p7_adjoint_horizontal_chroma_value(
    texture2d<float, access::read> input,
    uint2 position,
    uint halfWidth
) {
    const int n = int(position.x);
    float2 sum = input.read(uint2(position.x * 2, position.y)).rg;
    const int start = max(0, n - 4);
    const int end = min(int(halfWidth) - 1, n + 3);
    for (int m = start; m <= end; ++m) {
        const float2 oddValue = input.read(uint2(uint(m * 2 + 1), position.y)).rg;
        for (uint k = 0; k < 8; ++k) {
            if (p7_clamped_index(m + P7_HORIZONTAL_OFFSETS[k], int(halfWidth)) == n) {
                sum += P7_HORIZONTAL_WEIGHTS[k] * oddValue;
            }
        }
    }
    return sum;
}

kernel void p7_adjoint_horizontal_luma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    output.write(float4(0.5f * p7_adjoint_horizontal_luma_value(
        input, position, output.get_width()
    )), position);
}

kernel void p7_adjoint_horizontal_chroma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    const float2 value = 0.5f * p7_adjoint_horizontal_chroma_value(
        input, position, output.get_width()
    );
    output.write(float4(value, 0.0f, 1.0f), position);
}

inline float p7_adjoint_vertical_luma_value(
    texture2d<float, access::read> input,
    uint2 position,
    uint halfHeight
) {
    const int n = int(position.y);
    float sum = 0.0f;
    const int start = max(0, n - 2);
    const int end = min(int(halfHeight) - 1, n + 2);
    for (int m = start; m <= end; ++m) {
        const float evenValue = input.read(uint2(position.x, uint(m * 2))).r;
        const float oddValue = input.read(uint2(position.x, uint(m * 2 + 1))).r;
        for (uint k = 0; k < 4; ++k) {
            if (p7_clamped_index(m + P7_LUMA_VERTICAL_EVEN_OFFSETS[k], int(halfHeight)) == n) {
                sum += P7_LUMA_VERTICAL_EVEN_WEIGHTS[k] * evenValue;
            }
            if (p7_clamped_index(m + P7_LUMA_VERTICAL_ODD_OFFSETS[k], int(halfHeight)) == n) {
                sum += P7_LUMA_VERTICAL_ODD_WEIGHTS[k] * oddValue;
            }
        }
    }
    return sum;
}

inline float2 p7_adjoint_vertical_chroma_value(
    texture2d<float, access::read> input,
    uint2 position,
    uint halfHeight
) {
    const int n = int(position.y);
    float2 sum = float2(0.0f);
    const int start = max(0, n - 1);
    const int end = min(int(halfHeight) - 1, n + 1);
    for (int m = start; m <= end; ++m) {
        const float2 evenValue = input.read(uint2(position.x, uint(m * 2))).rg;
        const float2 oddValue = input.read(uint2(position.x, uint(m * 2 + 1))).rg;
        for (uint k = 0; k < 2; ++k) {
            if (p7_clamped_index(m + P7_CHROMA_VERTICAL_EVEN_OFFSETS[k], int(halfHeight)) == n) {
                sum += P7_CHROMA_VERTICAL_EVEN_WEIGHTS[k] * evenValue;
            }
            if (p7_clamped_index(m + P7_CHROMA_VERTICAL_ODD_OFFSETS[k], int(halfHeight)) == n) {
                sum += P7_CHROMA_VERTICAL_ODD_WEIGHTS[k] * oddValue;
            }
        }
    }
    return sum;
}

// Annex B performs (+ half divisor) integer rounding and clips each spatial
// resampling stage in the unsigned 10-bit EL-code domain. Scratch textures
// carry that signal with the 512 NLQ offset removed, translating [0, 1023] to
// [-512, 511]. Keeping the upper limit in the same 10-bit code domain is
// essential: a 16-bit-word limit here would permit positive filter overshoot
// at bright edges while clipping the negative side.
inline float p7_reference_resample_offset(float value) {
    return clamp(floor(value + 0.5f), -512.0f, 511.0f);
}

inline float2 p7_reference_resample_offset(float2 value) {
    return clamp(
        floor(value + float2(0.5f)),
        float2(-512.0f), float2(511.0f)
    );
}

kernel void p7_adjoint_vertical_luma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    output.write(float4(0.5f * p7_adjoint_vertical_luma_value(
        input, position, output.get_height()
    )), position);
}

kernel void p7_adjoint_vertical_chroma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    const float2 value = 0.5f * p7_adjoint_vertical_chroma_value(
        input, position, output.get_height()
    );
    output.write(float4(value, 0.0f, 1.0f), position);
}

inline float p7_upsample_vertical_luma_value(
    texture2d<float, access::read> input,
    uint2 position
) {
    const int n = int(position.y / 2);
    const bool odd = (position.y & 1u) != 0;
    float sum = 0.0f;
    for (uint k = 0; k < 4; ++k) {
        const int offset = odd
            ? P7_LUMA_VERTICAL_ODD_OFFSETS[k]
            : P7_LUMA_VERTICAL_EVEN_OFFSETS[k];
        const float weight = odd
            ? P7_LUMA_VERTICAL_ODD_WEIGHTS[k]
            : P7_LUMA_VERTICAL_EVEN_WEIGHTS[k];
        const int y = p7_clamped_index(n + offset, int(input.get_height()));
        sum += weight * input.read(uint2(position.x, uint(y))).r;
    }
    return p7_reference_resample_offset(sum);
}

inline float2 p7_upsample_vertical_chroma_value(
    texture2d<float, access::read> input,
    uint2 position
) {
    const int n = int(position.y / 2);
    const bool odd = (position.y & 1u) != 0;
    float2 sum = float2(0.0f);
    for (uint k = 0; k < 2; ++k) {
        const int offset = odd
            ? P7_CHROMA_VERTICAL_ODD_OFFSETS[k]
            : P7_CHROMA_VERTICAL_EVEN_OFFSETS[k];
        const float weight = odd
            ? P7_CHROMA_VERTICAL_ODD_WEIGHTS[k]
            : P7_CHROMA_VERTICAL_EVEN_WEIGHTS[k];
        const int y = p7_clamped_index(n + offset, int(input.get_height()));
        sum += weight * input.read(uint2(position.x, uint(y))).rg;
    }
    return p7_reference_resample_offset(sum);
}

kernel void p7_upsample_vertical_luma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    output.write(float4(p7_upsample_vertical_luma_value(input, position)), position);
}

kernel void p7_upsample_vertical_chroma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    const float2 value = p7_upsample_vertical_chroma_value(input, position);
    output.write(float4(value, 0.0f, 1.0f), position);
}

inline float p7_upsample_horizontal_luma_value(
    texture2d<float, access::read> input,
    uint2 position
) {
    const uint n = position.x / 2;
    if ((position.x & 1u) == 0) {
        return input.read(uint2(n, position.y)).r;
    }
    float sum = 0.0f;
    for (uint k = 0; k < 8; ++k) {
        const int x = p7_clamped_index(
            int(n) + P7_HORIZONTAL_OFFSETS[k],
            int(input.get_width())
        );
        sum += P7_HORIZONTAL_WEIGHTS[k] * input.read(uint2(uint(x), position.y)).r;
    }
    return p7_reference_resample_offset(sum);
}

inline float2 p7_upsample_horizontal_chroma_value(
    texture2d<float, access::read> input,
    uint2 position
) {
    const uint n = position.x / 2;
    if ((position.x & 1u) == 0) {
        return input.read(uint2(n, position.y)).rg;
    }
    float2 sum = float2(0.0f);
    for (uint k = 0; k < 8; ++k) {
        const int x = p7_clamped_index(
            int(n) + P7_HORIZONTAL_OFFSETS[k],
            int(input.get_width())
        );
        sum += P7_HORIZONTAL_WEIGHTS[k] * input.read(uint2(uint(x), position.y)).rg;
    }
    return p7_reference_resample_offset(sum);
}

kernel void p7_upsample_horizontal_luma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    output.write(float4(p7_upsample_horizontal_luma_value(input, position)), position);
}

kernel void p7_upsample_horizontal_chroma(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    const float2 value = p7_upsample_horizontal_chroma_value(input, position);
    output.write(float4(value, 0.0f, 1.0f), position);
}

kernel void p7_subtract_projection_luma(
    texture2d<float, access::read_write> target [[texture(0)]],
    texture2d<float, access::read> projection [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= target.get_width() || position.y >= target.get_height()) {
        return;
    }
    target.write(float4(target.read(position).r - projection.read(position).r), position);
}

kernel void p7_subtract_projection_chroma(
    texture2d<float, access::read_write> target [[texture(0)]],
    texture2d<float, access::read> projection [[texture(1)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= target.get_width() || position.y >= target.get_height()) {
        return;
    }
    const float2 value = target.read(position).rg - projection.read(position).rg;
    target.write(float4(value, 0.0f, 1.0f), position);
}

// Applies the residual-only luma correction in the signed EL-code domain. Its
// target is the source residual left after reconstructing the projected EL,
// so it preserves uniform-region DC.
kernel void p7_finalize_luma(
    texture2d<float, access::read> horizontalCorrection [[texture(0)]],
    texture2d<float, access::read> initial [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    const float correction = 0.5f * p7_adjoint_vertical_luma_value(
        horizontalCorrection, position, output.get_height()
    );
    const float offset = clamp(round(initial.read(position).r + correction), -512.0f, 511.0f);
    output.write(float4(p7_p010_normalized(offset + 512.0f)), position);
}

kernel void p7_finalize_chroma(
    texture2d<float, access::read> horizontalCorrection [[texture(0)]],
    texture2d<float, access::read> initial [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= output.get_width() || position.y >= output.get_height()) {
        return;
    }
    const float2 correction = 0.5f * p7_adjoint_vertical_chroma_value(
        horizontalCorrection, position, output.get_height()
    );
    const float2 offset = clamp(
        round(initial.read(position).rg + correction),
        float2(-512.0f),
        float2(511.0f)
    );
    output.write(float4(
        p7_p010_normalized(offset.x + 512.0f),
        p7_p010_normalized(offset.y + 512.0f),
        0.0f,
        1.0f
    ), position);
}

// Legacy residual kernels retained only so older packaged metallibs remain readable.
// Averages each 2x2 luma residual into the half-resolution enhancement layer.
kernel void p7_make_luma_residual(
    texture2d<float, access::read> sourceY [[texture(0)]],
    texture2d<float, access::read> reconstructedY [[texture(1)]],
    texture2d<float, access::write> enhancementY [[texture(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= enhancementY.get_width() ||
        position.y >= enhancementY.get_height()) {
        return;
    }

    const uint2 sourceOrigin = position * 2;
    float residual = 0.0f;
    for (uint y = 0; y < 2; ++y) {
        for (uint x = 0; x < 2; ++x) {
            const uint2 sourcePosition = sourceOrigin + uint2(x, y);
            const float sourceCode = sourceY.read(sourcePosition).r * 1023.0f;
            const float reconstructedCode =
                reconstructedY.read(sourcePosition).r * 1023.0f;
            residual += sourceCode - reconstructedCode;
        }
    }
    const float enhancementCode = clamp(512.0f + residual * 0.25f, 0.0f, 1023.0f);
    enhancementY.write(float4(enhancementCode / 1023.0f), position);
}

// Averages each 2x2 chroma residual into the enhancement-layer UV plane.
kernel void p7_make_chroma_residual(
    texture2d<float, access::read> sourceUV [[texture(0)]],
    texture2d<float, access::read> reconstructedUV [[texture(1)]],
    texture2d<float, access::write> enhancementUV [[texture(2)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= enhancementUV.get_width() ||
        position.y >= enhancementUV.get_height()) {
        return;
    }

    const uint2 sourceOrigin = position * 2;
    float2 residual = float2(0.0f);
    for (uint y = 0; y < 2; ++y) {
        for (uint x = 0; x < 2; ++x) {
            const uint2 sourcePosition = sourceOrigin + uint2(x, y);
            const float2 sourceCode = sourceUV.read(sourcePosition).rg * 1023.0f;
            const float2 reconstructedCode =
                reconstructedUV.read(sourcePosition).rg * 1023.0f;
            residual += sourceCode - reconstructedCode;
        }
    }
    const float2 enhancementCode = clamp(
        float2(512.0f) + residual * 0.25f,
        float2(0.0f),
        float2(1023.0f)
    );
    enhancementUV.write(float4(enhancementCode / 1023.0f, 0.0f, 1.0f), position);
}

"""#
}

/// Function-availability checks used when selecting a kernel library.
private extension MTLLibrary {
    /// Returns true only when every requested function can be resolved.
    func hasMetalFunctions(_ names: [String]) -> Bool {
        names.allSatisfy { makeFunction(name: $0) != nil }
    }
}
