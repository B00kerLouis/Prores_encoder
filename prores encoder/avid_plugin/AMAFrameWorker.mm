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
- (BOOL)appendRGBAHalfFrame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendPacked422Frame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendProResFrame:(NSData*)frame sourceCodec:(NSString*)codec;
- (BOOL)setTimelineAudioFiles:(NSArray*)paths;
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
        fcntl(responseFD, F_SETFL, fcntl(responseFD, F_GETFL) | O_NONBLOCK);
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
        // Opt-in evidence of the values actually passed by the host UI. This
        // logs owned configuration fields, never SDK text or frame contents.
        NSDictionary* values = [config[@"options"] isKindOfClass:NSDictionary.class] ? config[@"options"] : @{};
        NSString* settings = [NSString stringWithFormat:
            @"worker.config output=%@ quality=%@ container=%@ profile=%@ includeGenerated=%@ inputGamut=%@ inputTransfer=%@ inputMatrix=%@ gamut=%@ transfer=%@ peak=%@ cmu=%@ multiPass=%@ bFrames=%@",
            [config[@"output"] lastPathComponent], config[@"quality"], config[@"container"], values[@"dolbyVisionProfile"], values[@"includeGeneratedDolbyVisionMetadata"], values[@"inputColorGamut"],
            values[@"inputColorTransfer"], values[@"amaPacked422Matrix"], values[@"colorGamut"], values[@"colorTransfer"], values[@"colorPeakNits"],
            values[@"cmuMasteringNits"], values[@"multiPass"], values[@"bFrames"]];
        ama_worker::trace("%s", settings.UTF8String);
        id<AMAEncoderSession> session = [[cls alloc] initWithOutputURL:[NSURL fileURLWithPath:config[@"output"]]
            width:[config[@"width"] integerValue] height:[config[@"height"] integerValue]
            fpsNumerator:[config[@"numerator"] integerValue] fpsDenominator:[config[@"denominator"] integerValue]
            quality:config[@"quality"] containerExtension:config[@"container"] bitrateMbps:[config[@"bitrate"] doubleValue]
            includeDolbyVision:[config[@"dolby"] boolValue] advancedOptions:config[@"options"]];
        if (!reply(responseFD, session != nil, @"")) return 9;
        bool finished = false;
        std::uint64_t requestIndex = 0;
        ama_worker::trace("worker.ready");
        while (ama_worker::transfer(STDIN_FILENO, &request, sizeof(request), false, -1)) {
            @autoreleasepool {
                if (request.size > ama_worker::maximumFrameBytes) { reply(responseFD, false, @"AMA frame exceeds shared region."); break; }
                ++requestIndex;
                ama_worker::trace("framework.enter request=%llu command=%u bytes=%llu argument=%u",
                    (unsigned long long)requestIndex, request.command, (unsigned long long)request.size, request.strideOrCodec);
                std::atomic_thread_fence(std::memory_order_acquire);
                NSData* frame = [NSData dataWithBytesNoCopy:mapping length:request.size freeWhenDone:NO];
                BOOL result = NO;
                if (request.command == ama_worker::Packed422) result = [session appendPacked422Frame:frame stride:request.strideOrCodec];
                else if (request.command == ama_worker::RGBAHalf) result = [session appendRGBAHalfFrame:frame stride:request.strideOrCodec];
                else if (request.command == ama_worker::BGRA) result = [session appendBGRAFrame:frame stride:request.strideOrCodec];
                else if (request.command == ama_worker::ProRes && request.strideOrCodec < 6) {
                    NSArray* names = @[@"proxy", @"422lt", @"422", @"422hq", @"4444", @"4444xq"];
                    result = [session appendProResFrame:frame sourceCodec:names[request.strideOrCodec]];
                } else if (request.command == ama_worker::TimelineAudio) {
                    id paths = [NSPropertyListSerialization propertyListWithData:frame options:0 format:nil error:nil];
                    if ([paths isKindOfClass:NSArray.class]) result = [session setTimelineAudioFiles:paths];
                } else if (request.command == ama_worker::Finish) { result = [session finish]; finished = result; }
                ama_worker::trace("framework.return request=%llu success=%d", (unsigned long long)requestIndex, result);
                if (!reply(responseFD, result, result ? @"" : session.lastErrorMessage) || !result || finished) break;
            }
        }
        if (!finished) [session cancel];
        [session release]; munmap(mapping, ama_worker::maximumFrameBytes); close(responseFD);
        return finished ? 0 : 10;
    }
}
