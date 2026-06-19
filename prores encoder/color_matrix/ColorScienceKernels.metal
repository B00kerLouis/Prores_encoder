#include <metal_stdlib>
using namespace metal;

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

inline float3 luma_coefficients(uint matrixID) {
    return matrixID == 0
        ? float3(0.2126f, 0.7152f, 0.0722f)
        : float3(0.2627f, 0.6780f, 0.0593f);
}

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

inline float3 rgb_to_ycbcr(float3 rgb, uint matrixID) {
    const float3 k = luma_coefficients(matrixID);
    const float y = dot(k, rgb);
    const float cb = (rgb.b - y) / (2.0f * (1.0f - k.b));
    const float cr = (rgb.r - y) / (2.0f * (1.0f - k.r));
    return float3(y, cb, cr);
}

inline float3 pq_to_nits(float3 signal) {
    const float3 x = pow(max(signal, 0.0f), float3(1.0f / PQ_M2));
    const float3 numerator = max(x - PQ_C1, 0.0f);
    const float3 denominator = max(PQ_C2 - PQ_C3 * x, 1.0e-7f);
    return 10000.0f * pow(numerator / denominator, float3(1.0f / PQ_M1));
}

inline float3 nits_to_pq(float3 nits) {
    const float3 l = max(nits, 0.0f) / 10000.0f;
    const float3 y = pow(l, float3(PQ_M1));
    const float3 ratio = (PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y);
    return pow(max(ratio, 0.0f), float3(PQ_M2));
}

inline float hlg_inverse_scalar(float value) {
    const float ePrime = max(value, 0.0f);
    return ePrime < 0.5f
        ? ePrime * ePrime
        : HLG_B + exp((ePrime - HLG_C) / HLG_A);
}

inline float hlg_oetf_scalar(float value) {
    const float e = max(value, 0.0f);
    return e < HLG_E_BREAK
        ? sqrt(e)
        : HLG_A * log(max(e - HLG_B, 1.0e-7f)) + HLG_C;
}

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

inline float3 apply_matrix(float3 rgb, constant ColorUniforms &u) {
    return u.matrix0.xyz * rgb.r
        + u.matrix1.xyz * rgb.g
        + u.matrix2.xyz * rgb.b;
}

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

inline float bt2446a_inverse_raw(float nits, float sourcePeak, float targetPeak) {
    float x = pow(clamp(nits / sourcePeak, 0.0f, 1.0f), 1.0f / 2.4f);
    x *= 255.0f;
    const float exponent = x > 70.0f
        ? (2.8305e-6f * x - 7.4622e-4f) * x + 1.2528f
        : (1.8712e-5f * x - 2.7334e-3f) * x + 1.3141f;
    x = pow(max(x, 0.0f), exponent);
    return targetPeak * pow(x / 1000.0f, 2.4f);
}

inline float bt2446a_inverse(float nits, float sourcePeak, float targetPeak) {
    const float endpoint = bt2446a_inverse_raw(sourcePeak, sourcePeak, targetPeak);
    return bt2446a_inverse_raw(nits, sourcePeak, targetPeak)
        * (targetPeak / max(endpoint, 1.0e-6f));
}

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
    const float3 nits = decode_transfer(signal, u);
    linearOutput.write(half4(half3(nits), half(1.0f)), gid);
}

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
    linearOutput.write(half4(half3(decode_transfer(pixel.rgb, u)), half(pixel.a)), gid);
}

kernel void color_transform_linear(
    texture2d<half, access::read> linearInput [[texture(0)]],
    texture2d<half, access::write> encodedOutput [[texture(1)]],
    constant ColorUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= encodedOutput.get_width() || gid.y >= encodedOutput.get_height()) {
        return;
    }
    const float4 source = float4(linearInput.read(gid));
    float3 rgb = apply_matrix(source.rgb, u);
    rgb = tone_map(rgb, u);
    rgb = u.gamutLimitMode == 1
        ? limit_rec2020_to_p3d65(rgb, max(u.targetPeakNits, 1.0f))
        : gamut_compress(rgb, u);
    rgb = encode_transfer(rgb, u);
    encodedOutput.write(half4(half3(clamp(rgb, 0.0f, 1.0f)), half(source.a)), gid);
}

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
