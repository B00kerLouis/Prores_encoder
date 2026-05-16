// MXFBridge.h — Thin Objective-C bridge for mxf::Encoder (C++)
// Exposes frame-by-frame MXF write API callable from Swift.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

// ============================================================
//  MXFBridgeConfig
// ============================================================
@interface MXFBridgeConfig : NSObject
@property (nonatomic) int proResVariant;    // 1-6
@property (nonatomic) int opFormat;         // 0=OP1a, 1=OPAtom
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) int fpsNum;
@property (nonatomic) int fpsDen;
@property (nonatomic) BOOL isDropFrame;
@property (nonatomic, copy) NSString *startTimecode;
@property (nonatomic) int64_t totalFrames;
@property (nonatomic) int audioBitDepth;
@property (nonatomic) int audioSampleRate;
@property (nonatomic, copy) NSArray<NSNumber *> *audioChannelCounts;
// Color ULs (16 bytes each, or nil)
@property (nonatomic, copy, nullable) NSData *colorPrimaries;
@property (nonatomic, copy, nullable) NSData *transferFunction;
@property (nonatomic, copy, nullable) NSData *codingEquations;
@end

// ============================================================
//  MXFBridge — frame-by-frame MXF writer
// ============================================================
@interface MXFBridge : NSObject
- (BOOL)openWithPath:(NSString *)path config:(MXFBridgeConfig *)config;
- (BOOL)writeFrameVideo:(nullable const void *)video
              videoSize:(size_t)videoSize
                  audio:(nullable NSArray<NSData *> *)audioChunks;
- (BOOL)writeFrameSampleBuffer:(CMSampleBufferRef)sampleBuffer
                          audio:(nullable NSArray<NSData *> *)audioChunks;
- (BOOL)close;
@property (nonatomic, readonly) int64_t frameCount;
@property (nonatomic, readonly, nullable, copy) NSString *lastError;
/// 32 bytes UMID of the Source Package written into the MXF.
/// Only valid after a successful open(). Use this as the AAF SourceMob MobID.
@property (nonatomic, readonly, nullable) NSData *sourcePackageUMID;
@end

// ============================================================
//  C helpers callable from Swift
// ============================================================
#ifdef __cplusplus
extern "C" {
#endif
/// Audio cadence helper (wraps mxf::samplesForFrame)
int mxf_samples_for_frame(int64_t frameIdx, int fpsNum, int fpsDen, int sampleRate);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
