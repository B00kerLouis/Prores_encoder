// Converts Rec.2020/PQ YCbCr into the full-range IPT-PQ-C2 base layer used
// by the native full-range profiles.

#include <metal_stdlib>
using namespace metal;

constant float NDV_PQ_M1 = 2610.0f / 16384.0f;
constant float NDV_PQ_M2 = 2523.0f / 32.0f;
constant float NDV_PQ_C1 = 3424.0f / 4096.0f;
constant float NDV_PQ_C2 = 2413.0f / 128.0f;
constant float NDV_PQ_C3 = 2392.0f / 128.0f;
constant float NDV_P010_SCALE = 65535.0f / 64.0f;

inline float3 ndv_pq_eotf(float3 signal) {
    const float3 p = pow(max(signal, 0.0f), float3(1.0f / NDV_PQ_M2));
    const float3 numerator = max(p - NDV_PQ_C1, 0.0f);
    const float3 denominator = max(NDV_PQ_C2 - NDV_PQ_C3 * p, 1.0e-7f);
    return pow(numerator / denominator, float3(1.0f / NDV_PQ_M1));
}

inline float3 ndv_pq_oetf(float3 linear) {
    const float3 p = pow(max(linear, 0.0f), float3(NDV_PQ_M1));
    const float3 ratio = (NDV_PQ_C1 + NDV_PQ_C2 * p) / (1.0f + NDV_PQ_C3 * p);
    return pow(max(ratio, 0.0f), float3(NDV_PQ_M2));
}

inline float3 ndv_decode_bt2020(float yCode, float uCode, float vCode) {
    const float y = (yCode - 64.0f) / 876.0f;
    const float cb = (uCode - 512.0f) / 896.0f;
    const float cr = (vCode - 512.0f) / 896.0f;
    return float3(
        y + 1.4746f * cr,
        y - 0.1645531268f * cb - 0.5713531268f * cr,
        y + 1.8814f * cb
    );
}

inline float3 ndv_rgb_to_iptpqc2(float3 pqRGB, uint inputGamut) {
    const float3 rgb = ndv_pq_eotf(clamp(pqRGB, 0.0f, 1.0f));

    // Convert the declared D65 RGB gamut to HPE LMS. rec2020lm remains a
    // Rec.2020 encoding after its P3-D65 gamut limiter, so it uses the first
    // matrix. Values are derived from the same D65 RGB-to-XYZ definitions as
    // ColorTransform.swift and the fixed profile matrix.
    float3 hpeLMS;
    if (inputGamut == 2) {
        hpeLMS.x = 0.3567655860f * rgb.r + 0.5921667203f * rgb.g + 0.0510732323f * rgb.b;
        hpeLMS.y = 0.1567173553f * rgb.r + 0.7480487384f * rgb.g + 0.0952348158f * rgb.b;
        hpeLMS.z = 0.0000001946f * rgb.r + 0.0414218411f * rgb.g + 0.9584282105f * rgb.b;
    } else {
        hpeLMS.x = 0.4408196242f * rgb.r + 0.5353728475f * rgb.g + 0.0238130739f * rgb.b;
        hpeLMS.y = 0.1619850896f * rgb.r + 0.7586528815f * rgb.g + 0.0793629501f * rgb.b;
        hpeLMS.z = 0.0000000012f * rgb.r + 0.0257773102f * rgb.g + 0.9740729348f * rgb.b;
    }

    // Apply the profile's 2% C2 crosstalk in linear LMS before PQ encoding.
    float3 c2LMS;
    c2LMS.x = 0.9600126966f * hpeLMS.x + 0.0200241711f * hpeLMS.y + 0.0200241711f * hpeLMS.z;
    c2LMS.y = 0.0200241711f * hpeLMS.x + 0.9600126966f * hpeLMS.y + 0.0200241711f * hpeLMS.z;
    c2LMS.z = 0.0200241711f * hpeLMS.x + 0.0200241711f * hpeLMS.y + 0.9600126966f * hpeLMS.z;

    const float3 lmsPQ = ndv_pq_oetf(c2LMS);

    // Inverse of the exact Profile 5 ycc_to_rgb matrix carried in the RPU.
    float3 ipt;
    ipt.x = 0.4001284427f * lmsPQ.x + 0.3998902763f * lmsPQ.y + 0.1999812811f * lmsPQ.z;
    ipt.y = 4.4553440415f * lmsPQ.x - 4.8514641416f * lmsPQ.y + 0.3961201001f * lmsPQ.z;
    ipt.z = 0.8056680003f * lmsPQ.x + 0.3571794801f * lmsPQ.y - 1.1628474804f * lmsPQ.z;
    return ipt;
}

inline float3 ndv_transform_pixel(
    texture2d<float, access::read> sourceY,
    texture2d<float, access::read> sourceUV,
    uint2 position,
    uint inputGamut
) {
    const float yCode = sourceY.read(position).r * NDV_P010_SCALE;
    const float2 uvCode = sourceUV.read(position / 2).rg * NDV_P010_SCALE;
    return ndv_rgb_to_iptpqc2(ndv_decode_bt2020(yCode, uvCode.x, uvCode.y), inputGamut);
}

kernel void native_dv_transform(
    texture2d<float, access::read> sourceY [[texture(0)]],
    texture2d<float, access::read> sourceUV [[texture(1)]],
    texture2d<half, access::write> iptOutput [[texture(2)]],
    constant uint &inputGamut [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= iptOutput.get_width() || gid.y >= iptOutput.get_height()) {
        return;
    }
    iptOutput.write(half4(half3(ndv_transform_pixel(sourceY, sourceUV, gid, inputGamut)), half(1.0f)), gid);
}

kernel void native_dv_pack_y(
    texture2d<half, access::read> iptInput [[texture(0)]],
    texture2d<float, access::write> outputY [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputY.get_width() || gid.y >= outputY.get_height()) {
        return;
    }
    outputY.write(float4(clamp(float(iptInput.read(gid).x), 0.0f, 1.0f)), gid);
}

kernel void native_dv_pack_uv(
    texture2d<half, access::read> iptInput [[texture(0)]],
    texture2d<float, access::write> outputUV [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputUV.get_width() || gid.y >= outputUV.get_height()) {
        return;
    }
    float2 chroma = float2(0.0f);
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            const uint2 position = min(
                gid * 2 + uint2(dx, dy),
                uint2(iptInput.get_width() - 1, iptInput.get_height() - 1)
            );
            chroma += float2(iptInput.read(position).yz);
        }
    }
    chroma = clamp(chroma * 0.25f + 0.5f, 0.0f, 1.0f);
    outputUV.write(float4(chroma, 0.0f, 1.0f), gid);
}
