// Declares the Objective-C++ bridge for the AV1 encoder.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Dimensions, timing, bitrate, and color metadata for one AV1 session.
@interface AV1BridgeConfig : NSObject
@property (nonatomic) int32_t width;
@property (nonatomic) int32_t height;
@property (nonatomic) int32_t fpsNum;
@property (nonatomic) int32_t fpsDen;
@property (nonatomic) int64_t bitrateBitsPerSecond;
@property (nonatomic) int32_t colorPrimaries;
@property (nonatomic) int32_t transferCharacteristics;
@property (nonatomic) int32_t matrixCoefficients;
@property (nonatomic) BOOL fullRange;
@property (nonatomic, nullable, copy) NSData *masteringDisplayColorVolume;
@property (nonatomic, nullable, copy) NSData *contentLightLevelInfo;
@end

/// Encoded AV1 temporal unit with presentation order and random-access state.
@interface AV1BridgePacket : NSObject
@property (nonatomic, readonly, copy) NSData *data;
@property (nonatomic, readonly) int64_t presentationIndex;
@property (nonatomic, readonly) BOOL keyframe;
/// Creates an immutable packet returned by the bridge.
- (instancetype)initWithData:(NSData *)data
           presentationIndex:(int64_t)presentationIndex
                    keyframe:(BOOL)keyframe NS_DESIGNATED_INITIALIZER;
/// Prevents creation of a packet without encoded data and timing.
- (instancetype)init NS_UNAVAILABLE;
@end

/// Owns one AV1 encoder instance and drains its produced packets.
@interface AV1Bridge : NSObject
@property (nonatomic, readonly, nullable, copy) NSData *codecConfigurationRecord;
@property (nonatomic, readonly, nullable, copy) NSString *lastError;

/// Validates configuration and opens the encoder.
- (BOOL)openWithConfig:(AV1BridgeConfig *)config;
/// Encodes one P010 pixel buffer and returns all immediately available packets.
- (nullable NSArray<AV1BridgePacket *> *)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                                         presentationIndex:(int64_t)presentationIndex;
/// Flushes delayed frames and returns the remaining packets.
- (nullable NSArray<AV1BridgePacket *> *)finish;
/// Releases encoder resources and clears session state.
- (void)close;
@end

NS_ASSUME_NONNULL_END
