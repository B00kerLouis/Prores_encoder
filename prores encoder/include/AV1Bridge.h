// AV1Bridge.h — Objective-C++ bridge for SVT-AV1 static library.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface AV1BridgeConfig : NSObject
@property (nonatomic) int32_t width;
@property (nonatomic) int32_t height;
@property (nonatomic) int32_t fpsNum;
@property (nonatomic) int32_t fpsDen;
@property (nonatomic) int64_t bitrateBitsPerSecond;
@property (nonatomic) int32_t colorPrimaries;
@property (nonatomic) int32_t transferCharacteristics;
@property (nonatomic) int32_t matrixCoefficients;
@property (nonatomic, nullable, copy) NSData *masteringDisplayColorVolume;
@property (nonatomic, nullable, copy) NSData *contentLightLevelInfo;
@end

@interface AV1BridgePacket : NSObject
@property (nonatomic, readonly, copy) NSData *data;
@property (nonatomic, readonly) int64_t presentationIndex;
@property (nonatomic, readonly) BOOL keyframe;
- (instancetype)initWithData:(NSData *)data
           presentationIndex:(int64_t)presentationIndex
                    keyframe:(BOOL)keyframe NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface AV1Bridge : NSObject
@property (nonatomic, readonly, nullable, copy) NSData *codecConfigurationRecord;
@property (nonatomic, readonly, nullable, copy) NSString *lastError;

- (BOOL)openWithConfig:(AV1BridgeConfig *)config;
- (nullable NSArray<AV1BridgePacket *> *)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                                         presentationIndex:(int64_t)presentationIndex;
- (nullable NSArray<AV1BridgePacket *> *)finish;
- (void)close;
@end

NS_ASSUME_NONNULL_END
