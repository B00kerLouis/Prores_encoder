#include <metal_stdlib>
using namespace metal;

constant uint CMU_HISTOGRAM_BINS = 4096;
constant float CMU_LOG_MAX = 13.2878566f; // log2(10001)
constant float CMU_EXTREMA_SCALE = 1000.0f;

struct CMUUniforms {
    uint width;
    uint height;
    uint matrixID;
    uint fullRange;
    float4 lumaCoefficients;
};

struct CMUPartialStats {
    float4 sums0; // luma, red, green, blue
    float4 sums1; // saturation, count, reserved, reserved
};

inline float3 cmu_luma_coefficients(uint matrixID) {
    return matrixID == 0
        ? float3(0.2126f, 0.7152f, 0.0722f)
        : float3(0.2627f, 0.6780f, 0.0593f);
}

inline float3 cmu_ycbcr_to_rgb(float y, float cb, float cr, uint matrixID) {
    const float3 k = cmu_luma_coefficients(matrixID);
    const float r = y + 2.0f * (1.0f - k.r) * cr;
    const float b = y + 2.0f * (1.0f - k.b) * cb;
    const float g = (y - k.r * r - k.b * b) / k.g;
    return float3(r, g, b);
}

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

    float luma = 0.0f;
    float3 rgbNits = float3(0.0f);
    float saturation = 0.0f;
    float count = 0.0f;

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
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (localIndex < stride) {
            lumaSums[localIndex] += lumaSums[localIndex + stride];
            redSums[localIndex] += redSums[localIndex + stride];
            greenSums[localIndex] += greenSums[localIndex + stride];
            blueSums[localIndex] += blueSums[localIndex + stride];
            saturationSums[localIndex] += saturationSums[localIndex + stride];
            counts[localIndex] += counts[localIndex + stride];
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
            0.0f,
            0.0f
        );
    }
}
