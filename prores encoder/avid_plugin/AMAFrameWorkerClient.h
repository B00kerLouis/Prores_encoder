#import <Foundation/Foundation.h>

// Private AMA frame RPC. The worker invokes the existing Objective-C facade;
// no encoder CLI arguments or external timeline reconstruction are involved.
@interface AMAFrameWorkerClient : NSObject
@property(nonatomic, readonly, copy) NSString* lastErrorMessage;
- (instancetype)initWithOutputURL:(NSURL*)outputURL width:(NSInteger)width height:(NSInteger)height
    fpsNumerator:(NSInteger)numerator fpsDenominator:(NSInteger)denominator quality:(NSString*)quality
    containerExtension:(NSString*)container bitrateMbps:(double)bitrate includeDolbyVision:(BOOL)dolby
    advancedOptions:(NSDictionary*)options;
- (BOOL)appendBGRABytes:(const void*)bytes size:(NSUInteger)size stride:(NSInteger)stride;
- (BOOL)appendBGRAFrame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendRGBAHalfFrame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendPacked422Frame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendProResFrame:(NSData*)frame sourceCodec:(NSString*)codec;
- (BOOL)finish;
- (void)cancel;
@end
