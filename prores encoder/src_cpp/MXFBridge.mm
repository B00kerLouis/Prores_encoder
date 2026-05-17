// MXFBridge.mm — Objective-C++ bridge for mxf::Encoder
// Wraps the C++ mxf::Encoder into an ObjC interface callable from Swift.

#import "../include/MXFBridge.h"
#include "../include/mxf_enc.h"
#include <memory>
#include <cstring>

// ============================================================
//  MXFBridgeConfig
// ============================================================
@implementation MXFBridgeConfig
- (instancetype)init {
    if ((self = [super init])) {
        _proResVariant = 4; _opFormat = 0;
        _width = 1920; _height = 1080;
        _fpsNum = 25; _fpsDen = 1;
        _isDropFrame = NO;
        _startTimecode = @"00:00:00:00";
        _totalFrames = 0;
        _audioBitDepth = 24; _audioSampleRate = 48000;
        _audioChannelCounts = @[];
    }
    return self;
}
@end

// ============================================================
//  MXFBridge
// ============================================================
@interface MXFBridge () {
    std::unique_ptr<mxf::Encoder> _enc;
    NSString *_lastError;
}
@end

@implementation MXFBridge

- (instancetype)init {
    if ((self = [super init])) {
        _enc = std::make_unique<mxf::Encoder>();
    }
    return self;
}

- (BOOL)openWithPath:(NSString *)path config:(MXFBridgeConfig *)cfg {
    if (cfg.fpsNum <= 0 || cfg.fpsDen <= 0) {
        _lastError = @"invalid frame rate";
        return NO;
    }
    if (cfg.audioSampleRate <= 0) {
        _lastError = @"invalid audio sample rate";
        return NO;
    }
    if (cfg.audioBitDepth != 16 && cfg.audioBitDepth != 24) {
        _lastError = @"unsupported audio bit depth";
        return NO;
    }

    mxf::Config c;
    c.opFormat   = cfg.opFormat == 0 ? mxf::OPFormat::OP1a : mxf::OPFormat::OPAtom;
    c.variant    = static_cast<mxf::ProResVariant>(cfg.proResVariant);
    c.width      = cfg.width;  c.height   = cfg.height;
    c.fpsNum     = cfg.fpsNum; c.fpsDen   = cfg.fpsDen;
    c.isDropFrame = cfg.isDropFrame;
    c.startTimecode = cfg.startTimecode.UTF8String;
    c.totalFrames   = cfg.totalFrames;

    for (NSNumber *ch in cfg.audioChannelCounts) {
        if (ch.intValue <= 0) {
            _lastError = @"invalid audio channel count";
            return NO;
        }
        mxf::AudioTrackConfig atc;
        atc.channelCount = ch.intValue;
        atc.bitDepth     = cfg.audioBitDepth;
        atc.sampleRate   = cfg.audioSampleRate;
        c.audioTracks.push_back(atc);
    }

    auto readUL = [](NSData * _Nullable data) -> mxf::UL16 {
        mxf::UL16 ul{};
        if (data && data.length >= 16) std::memcpy(ul.data(), data.bytes, 16);
        return ul;
    };
    if (cfg.colorPrimaries || cfg.transferFunction || cfg.codingEquations) {
        c.color.valid = true;
        if (cfg.colorPrimaries)   c.color.colorPrimaries  = readUL(cfg.colorPrimaries);
        if (cfg.transferFunction) c.color.transferFunction = readUL(cfg.transferFunction);
        if (cfg.codingEquations)  c.color.codingEquations  = readUL(cfg.codingEquations);
    }

    if (!_enc->open(path.UTF8String, c)) {
        _lastError = @(_enc->lastError().c_str());
        return NO;
    }
    return YES;
}

- (BOOL)writeFrameVideo:(const void *)video
              videoSize:(size_t)videoSize
                  audio:(NSArray<NSData *> *)audioChunks {
    std::vector<const uint8_t *> ap;
    std::vector<size_t> as;
    for (NSData *d in audioChunks) {
        ap.push_back(static_cast<const uint8_t *>(d.bytes));
        as.push_back(d.length);
    }
    if (!_enc->writeFrame(static_cast<const uint8_t *>(video), videoSize, ap, as)) {
        _lastError = @(_enc->lastError().c_str());
        return NO;
    }
    return YES;
}

- (BOOL)writeFrameSampleBuffer:(CMSampleBufferRef)sampleBuffer
                          audio:(NSArray<NSData *> *)audioChunks {
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) {
        _lastError = @"sample buffer has no compressed data";
        return NO;
    }

    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    char *dataPointer = nullptr;
    OSStatus status = CMBlockBufferGetDataPointer(block, 0, &lengthAtOffset,
                                                  &totalLength, &dataPointer);
    if (status == kCMBlockBufferNoErr && dataPointer && lengthAtOffset == totalLength) {
        return [self writeFrameVideo:dataPointer videoSize:totalLength audio:audioChunks];
    }

    NSMutableData *contiguous = [NSMutableData dataWithLength:totalLength];
    if (!contiguous) {
        _lastError = @"failed to allocate contiguous sample buffer copy";
        return NO;
    }
    status = CMBlockBufferCopyDataBytes(block, 0, totalLength, contiguous.mutableBytes);
    if (status != kCMBlockBufferNoErr) {
        _lastError = [NSString stringWithFormat:@"sample buffer copy failed: %d", (int)status];
        return NO;
    }
    return [self writeFrameVideo:contiguous.bytes videoSize:contiguous.length audio:audioChunks];
}

- (BOOL)close {
    if (!_enc->close()) {
        _lastError = @(_enc->lastError().c_str());
        return NO;
    }
    return YES;
}

- (int64_t)frameCount { return _enc->frameCount(); }
- (NSString *)lastError { return _lastError; }
- (NSData *)sourcePackageUMID {
    const auto& u = _enc->sourcePackageUMID();
    return [NSData dataWithBytes:u.data() length:32];
}

@end

// ============================================================
//  C helper
// ============================================================
extern "C" int mxf_samples_for_frame(int64_t frameIdx, int fpsNum, int fpsDen, int sampleRate) {
    return mxf::samplesForFrame(frameIdx, fpsNum, fpsDen, sampleRate);
}
