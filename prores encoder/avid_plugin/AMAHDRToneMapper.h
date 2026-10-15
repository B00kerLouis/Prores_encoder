#import <Foundation/Foundation.h>

// AMA-only pixel processing. Does not change the framework/CLI color paths.
@interface AMAHDRToneMapper : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height
                   inputColor:(NSUInteger)inputColor peakNits:(float)peakNits
                        error:(NSError**)error;
- (NSData*)mapBGRA:(NSData*)source stride:(NSUInteger)stride error:(NSError**)error;
- (NSData*)mapRGBAHalf:(NSData*)source stride:(NSUInteger)stride error:(NSError**)error;
@end
