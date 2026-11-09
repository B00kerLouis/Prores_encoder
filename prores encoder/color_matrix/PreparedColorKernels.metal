// B00kerLouis. Independent opt-in external matrix; existing kernels unchanged.
#include <metal_stdlib>
using namespace metal;
struct PreparedMatrixUniforms {
    float4 row0, row1, row2;
    float inputWhite, outputWhite;
    uint inputPQ, outputPQ;
};
static float prepared_decode(float v, uint pq, float white) {
    v = clamp(v, 0.0f, 1.0f);
    if (!pq) return white * (v < 0.081f ? v / 4.5f : pow((v + 0.099f) / 1.099f, 1.0f / 0.45f));
    float p = pow(v, 32.0f / 2523.0f);
    return 10000.0f * pow(max(p - 3424.0f / 4096.0f, 0.0f) / max(2413.0f / 128.0f - 2392.0f / 128.0f * p, 1e-7f), 16384.0f / 2610.0f);
}
static float prepared_encode(float nits, uint pq, float white) {
    if (!pq) {
        float v = clamp(nits / white, 0.0f, 1.0f);
        return v < 0.018f ? 4.5f * v : 1.099f * pow(v, 0.45f) - 0.099f;
    }
    float p = pow(clamp(nits / 10000.0f, 0.0f, 1.0f), 2610.0f / 16384.0f);
    return pow((3424.0f / 4096.0f + 2413.0f / 128.0f * p) / (1.0f + 2392.0f / 128.0f * p), 2523.0f / 32.0f);
}
kernel void prepared_absolute_rgb_matrix(texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]], constant PreparedMatrixUniforms &u [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) return;
    float4 pixel = float4(source.read(position));
    float3 n = float3(prepared_decode(pixel.r,u.inputPQ,u.inputWhite), prepared_decode(pixel.g,u.inputPQ,u.inputWhite), prepared_decode(pixel.b,u.inputPQ,u.inputWhite));
    float3 m = float3(dot(u.row0.xyz,n),dot(u.row1.xyz,n),dot(u.row2.xyz,n));
    destination.write(half4(prepared_encode(m.r,u.outputPQ,u.outputWhite), prepared_encode(m.g,u.outputPQ,u.outputWhite), prepared_encode(m.b,u.outputPQ,u.outputWhite),pixel.a),position);
}
