// Computes PQ frame statistics and Profile 7 residual planes on the GPU.

#include <metal_stdlib>
using namespace metal;

constant uint CMU_HISTOGRAM_BINS = 4096;
constant float CMU_LOG_MAX = 13.2878566f; // log2(10001)
constant float CMU_EXTREMA_SCALE = 1000.0f;

// Image geometry and color interpretation for one statistics dispatch.
struct CMUUniforms {
    uint width;
    uint height;
    uint matrixID;
    uint fullRange;
    float4 lumaCoefficients;
};

// Per-workgroup sums reduced by the CPU after command completion.
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

// Accumulates extrema, a log-luminance histogram, and per-workgroup channel sums.
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
        floor(value + float2(0.5f)), float2(-512.0f), float2(511.0f)
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

// The correction is derived after subtracting the reconstructed projection;
// it therefore has no DC component and preserves uniform white-area level.
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
