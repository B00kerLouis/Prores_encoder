// B00kerLouis. Opt-in RGBAHalf geometry; existing color kernels unchanged.
#include <metal_stdlib>
using namespace metal;
struct SpatialUniforms {
    float4 content; // x,y,width,height in destination pixel-edge coordinates
    float scale;
    float whiteNits;
    uint pq;
    uint linearLight;
    uint opaqueAlpha;
    uint transparentPadding;
    uint unitScale;
    uint reserved;
};
static float spatial_decode(float v, uint pq, float white) {
    v = clamp(v,0.0f,1.0f);
    if(!pq) return white*(v<0.081f ? v/4.5f : pow((v+0.099f)/1.099f,1.0f/0.45f));
    float p=pow(v,32.0f/2523.0f);
    return 10000.0f*pow(max(p-3424.0f/4096.0f,0.0f)/max(2413.0f/128.0f-2392.0f/128.0f*p,1e-7f),16384.0f/2610.0f);
}
static float spatial_encode(float n, uint pq, float white) {
    if(!pq) { float v=clamp(n/white,0.0f,1.0f); return v<0.018f ? 4.5f*v : 1.099f*pow(v,0.45f)-0.099f; }
    float p=pow(clamp(n/10000.0f,0.0f,1.0f),2610.0f/16384.0f);
    return pow((3424.0f/4096.0f+2413.0f/128.0f*p)/(1.0f+2392.0f/128.0f*p),2523.0f/32.0f);
}
static float4 spatial_sample(texture2d<half,access::read> source, int2 p, constant SpatialUniforms &u) {
    int2 last=int2(source.get_width()-1,source.get_height()-1);
    float4 v=float4(source.read(uint2(clamp(p,int2(0),last))));
    float alpha=u.opaqueAlpha ? 1.0f : clamp(v.a,0.0f,1.0f);
    float3 rgb=u.linearLight ? float3(spatial_decode(v.r,u.pq,u.whiteNits),spatial_decode(v.g,u.pq,u.whiteNits),spatial_decode(v.b,u.pq,u.whiteNits)) : v.rgb;
    return float4(rgb*alpha,alpha);
}
kernel void prores_spatial_rgba_half(texture2d<half,access::read> source [[texture(0)]],
    texture2d<half,access::write> output [[texture(1)]],constant SpatialUniforms &u [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width() || p.y>=output.get_height()) return;
    float2 center=float2(p)+0.5f;
    if(any(center<u.content.xy) || any(center>=u.content.xy+u.content.zw)) {
        output.write(half4(0,0,0,u.transparentPadding ? 0.0h : 1.0h),p); return;
    }
    float2 s=(center-u.content.xy)/u.scale-0.5f;
    if(u.unitScale) {
        half4 v=source.read(uint2(int2(round(s))));
        if(u.opaqueAlpha) v.a=1.0h;
        output.write(v,p); return;
    }
    int2 base=int2(floor(s));float2 f=s-float2(base);
    float4 top=mix(spatial_sample(source,base,u),spatial_sample(source,base+int2(1,0),u),f.x);
    float4 bottom=mix(spatial_sample(source,base+int2(0,1),u),spatial_sample(source,base+int2(1,1),u),f.x);
    float4 v=mix(top,bottom,f.y);
    float3 rgb=v.a>1e-8f ? v.rgb/v.a : float3(0);
    if(u.linearLight) rgb=float3(spatial_encode(rgb.r,u.pq,u.whiteNits),spatial_encode(rgb.g,u.pq,u.whiteNits),spatial_encode(rgb.b,u.pq,u.whiteNits));
    output.write(half4(half3(rgb),half(v.a)),p);
}
