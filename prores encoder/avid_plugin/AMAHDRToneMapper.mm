#import "AMAHDRToneMapper.h"
#import <Metal/Metal.h>
#include <simd/simd.h>

// RGB primaries are converted in linear light; HDR compression operates on
// luminance in nits. PQ is applied to actual pixels, before CMU analysis.
static const char* kAMAHDRKernel = R"metal(
#include <metal_stdlib>
using namespace metal;
struct Params { uint width, height, stride, transfer; float peak; float3 pad;
                float4 row0, row1, row2; };
float3 pqDecode(float3 x) {
    float3 p = pow(max(x, 0.0f), float3(32.0f / 2523.0f));
    return 10000.0f * pow(max(p - 3424.0f / 4096.0f, 0.0f) /
        max(2413.0f / 128.0f - 2392.0f / 128.0f * p, 1.0e-7f), float3(16384.0f / 2610.0f));
}
float3 pqEncode(float3 nits) {
    float3 p = pow(clamp(nits / 10000.0f, 0.0f, 1.0f), float3(2610.0f / 16384.0f));
    return pow((3424.0f / 4096.0f + 2413.0f / 128.0f * p) /
        (1.0f + 2392.0f / 128.0f * p), float3(2523.0f / 32.0f));
}
kernel void amaHDR(const device uchar* source [[buffer(0)]],
                   device uchar4* output [[buffer(1)]],
                   constant Params& p [[buffer(2)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.width || xy.y >= p.height) return;
    uint offset = xy.y * p.stride + xy.x * 4;
    float3 rgb = float3(source[offset + 2], source[offset + 1], source[offset]) / 255.0f;
    if (p.transfer == 0) rgb = pow(rgb, float3(2.4f)) * 100.0f;
    else if (p.transfer == 1) rgb = pqDecode(rgb);
    else {
        float3 scene = select(rgb * rgb / 3.0f,
            (exp((rgb - 0.55991073f) / 0.17883277f) + 0.28466892f) / 12.0f, rgb > 0.5f);
        float y = max(dot(scene, float3(0.2627f, 0.6780f, 0.0593f)), 1.0e-7f);
        rgb = scene * pow(y, 0.2f) * 1000.0f;
    }
    rgb = float3(dot(p.row0.xyz, rgb), dot(p.row1.xyz, rgb), dot(p.row2.xyz, rgb));
    float luma = max(dot(rgb, float3(0.2627f, 0.6780f, 0.0593f)), 1.0e-7f);
    float knee = p.peak * 0.75f;
    if (luma > knee) {
        float mapped = knee + (p.peak - knee) * (1.0f - exp(-(luma - knee) / (p.peak - knee)));
        rgb *= mapped / luma;
    }
    rgb = pqEncode(clamp(rgb, 0.0f, p.peak));
    output[xy.y * p.width + xy.x] = uchar4(uchar3(round(rgb.bgr * 255.0f)), source[offset + 3]);
}
)metal";

struct AMAHDRParams {
    uint32_t width, height, stride, transfer;
    float peak;
    simd_float3 pad;
    simd_float4 row0, row1, row2;
};

@implementation AMAHDRToneMapper {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _pipeline;
    id<MTLBuffer> _destination;
    AMAHDRParams _params;
}

- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height
                   inputColor:(NSUInteger)inputColor peakNits:(float)peakNits error:(NSError**)error {
    self = [super init];
    if (!self) return nil;
    if (width == 0 || height == 0 || inputColor < 1 || inputColor > 4 ||
        !isfinite(peakNits) || peakNits < 1 || peakNits > 10000) {
        if (error) *error = [NSError errorWithDomain:@"AMAHDR" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"HDR mapping requires a verified input color and valid raster/peak."}];
        [self release]; return nil;
    }
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    id<MTLLibrary> library = [_device newLibraryWithSource:[NSString stringWithUTF8String:kAMAHDRKernel] options:nil error:error];
    id<MTLFunction> function = [library newFunctionWithName:@"amaHDR"];
    _pipeline = [_device newComputePipelineStateWithFunction:function error:error];
    [function release]; [library release];
    _destination = [_device newBufferWithLength:width * height * 4 options:MTLResourceStorageModeShared];
    if (!_queue || !_pipeline || !_destination) {
        if (error && !*error) *error = [NSError errorWithDomain:@"AMAHDR" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Metal HDR mapping could not allocate its pipeline."}];
        [self release]; return nil;
    }
    _params.width = (uint32_t)width; _params.height = (uint32_t)height; _params.peak = peakNits;
    _params.transfer = inputColor == 1 ? 0 : inputColor == 3 ? 2 : 1;
    _params.row0 = simd_make_float4(1, 0, 0, 0);
    _params.row1 = simd_make_float4(0, 1, 0, 0);
    _params.row2 = simd_make_float4(0, 0, 1, 0);
    if (inputColor == 1) {
        // D65 Rec.709 linear RGB -> D65 Rec.2020 linear RGB.
        _params.row0 = simd_make_float4(0.627403896f, 0.329283038f, 0.043313066f, 0);
        _params.row1 = simd_make_float4(0.069097289f, 0.919540395f, 0.011362316f, 0);
        _params.row2 = simd_make_float4(0.016391439f, 0.088013308f, 0.895595253f, 0);
    } else if (inputColor == 4) {
        _params.row0 = simd_make_float4(0.753833035f, 0.198597369f, 0.047569596f, 0);
        _params.row1 = simd_make_float4(0.045743849f, 0.941777219f, 0.012478932f, 0);
        _params.row2 = simd_make_float4(-0.001210340f, 0.017601717f, 0.983608623f, 0);
    }
    return self;
}

- (NSData*)mapBGRA:(NSData*)source stride:(NSUInteger)stride error:(NSError**)error {
    if (stride < _params.width * 4 || source.length < stride * _params.height || stride > UINT32_MAX) return nil;
    _params.stride = (uint32_t)stride;
    id<MTLBuffer> input = [_device newBufferWithBytes:source.bytes length:source.length options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:_pipeline];
    [encoder setBuffer:input offset:0 atIndex:0];
    [encoder setBuffer:_destination offset:0 atIndex:1];
    [encoder setBytes:&_params length:sizeof(_params) atIndex:2];
    [encoder dispatchThreads:MTLSizeMake(_params.width, _params.height, 1)
        threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    [input release];
    if (command.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = command.error;
        return nil;
    }
    return [NSData dataWithBytes:_destination.contents length:_params.width * _params.height * 4];
}

- (void)dealloc {
    [_destination release]; [_pipeline release]; [_queue release]; [_device release];
    [super dealloc];
}
@end
