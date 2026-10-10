#import <Foundation/Foundation.h>
#include "AMAWorkerProtocol.h"
#include <sys/mman.h>
#include <fcntl.h>
#include <atomic>

@protocol AMAEncoderSession <NSObject>
@property(nonatomic, readonly, copy) NSString* lastErrorMessage;
- (instancetype)initWithOutputURL:(NSURL*)outputURL width:(NSInteger)width height:(NSInteger)height
    fpsNumerator:(NSInteger)numerator fpsDenominator:(NSInteger)denominator quality:(NSString*)quality
    containerExtension:(NSString*)container bitrateMbps:(double)bitrate includeDolbyVision:(BOOL)dolby
    advancedOptions:(NSDictionary*)options;
- (BOOL)appendBGRAFrame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendProResFrame:(NSData*)frame sourceCodec:(NSString*)codec;
- (BOOL)finish;
- (void)cancel;
@end
static bool reply(int fd, bool success, NSString* message) {
    NSData* text = [(message ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    ama_worker::Response response{success ? 1 : 0, (std::uint32_t)text.length};
    return ama_worker::transfer(fd, &response, sizeof(response), true) &&
        ama_worker::transfer(fd, (void*)text.bytes, text.length, true);
}
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        int responseFD = dup(STDOUT_FILENO);
        fcntl(responseFD, F_SETNOSIGPIPE, 1);
        // Framework logs are separate from the binary status channel.
        dup2(STDERR_FILENO, STDOUT_FILENO);
        int fd = open(argv[1], O_RDWR);
        if (fd < 0) { reply(responseFD, false, @"Shared AMA frame region is unavailable."); return 3; }
        void* mapping = mmap(nullptr, ama_worker::maximumFrameBytes, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (mapping == MAP_FAILED) return 4;
        ama_worker::Request request{};
        if (!ama_worker::transfer(STDIN_FILENO, &request, sizeof(request), false) ||
            request.command != ama_worker::Initialize || request.size > 1024 * 1024) return 5;
        NSMutableData* plist = [NSMutableData dataWithLength:request.size];
        if (!ama_worker::transfer(STDIN_FILENO, plist.mutableBytes, plist.length, false)) return 6;
        NSError* error = nil;
        NSDictionary* config = [NSPropertyListSerialization propertyListWithData:plist options:0 format:nil error:&error];
        NSBundle* framework = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[2]]];
        if (![framework loadAndReturnError:&error]) { reply(responseFD, false, error.localizedDescription); return 7; }
        Class cls = NSClassFromString(@"ProResFrameStreamSession");
        if (!cls || ![config isKindOfClass:NSDictionary.class]) { reply(responseFD, false, @"The frame session is unavailable."); return 8; }
        id<AMAEncoderSession> session = [[cls alloc] initWithOutputURL:[NSURL fileURLWithPath:config[@"output"]]
            width:[config[@"width"] integerValue] height:[config[@"height"] integerValue]
            fpsNumerator:[config[@"numerator"] integerValue] fpsDenominator:[config[@"denominator"] integerValue]
            quality:config[@"quality"] containerExtension:config[@"container"] bitrateMbps:[config[@"bitrate"] doubleValue]
            includeDolbyVision:[config[@"dolby"] boolValue] advancedOptions:config[@"options"]];
        if (!reply(responseFD, session != nil, @"")) return 9;
        bool finished = false;
        while (ama_worker::transfer(STDIN_FILENO, &request, sizeof(request), false, -1)) {
            @autoreleasepool {
                if (request.size > ama_worker::maximumFrameBytes) break;
                std::atomic_thread_fence(std::memory_order_acquire);
                NSData* frame = [NSData dataWithBytesNoCopy:mapping length:request.size freeWhenDone:NO];
                BOOL result = NO;
                if (request.command == ama_worker::BGRA) result = [session appendBGRAFrame:frame stride:request.strideOrCodec];
                else if (request.command == ama_worker::ProRes && request.strideOrCodec < 6) {
                    NSArray* names = @[@"proxy", @"422lt", @"422", @"422hq", @"4444", @"4444xq"];
                    result = [session appendProResFrame:frame sourceCodec:names[request.strideOrCodec]];
                } else if (request.command == ama_worker::Finish) { result = [session finish]; finished = true; }
                if (!reply(responseFD, result, result ? @"" : session.lastErrorMessage) || !result || finished) break;
            }
        }
        if (!finished) [session cancel];
        [session release]; munmap(mapping, ama_worker::maximumFrameBytes); close(responseFD);
        return finished ? 0 : 10;
    }
}
