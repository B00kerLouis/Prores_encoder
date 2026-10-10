#import "AMAFrameWorkerClient.h"
#include "AMAWorkerProtocol.h"
#include <sys/mman.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <mutex>
#include <atomic>
#include <string>

@implementation AMAFrameWorkerClient {
    NSTask* _task;
    NSPipe* _requests;
    NSPipe* _responses;
    NSFileHandle* _log;
    NSString* _mappingPath;
    NSString* _error;
    void* _mapping;
    int _fd;
    std::mutex _rpc;
    std::atomic<bool> _cancelled;
}
- (NSString*)lastErrorMessage { return _error ?: @""; }
- (void)setFailure:(NSString*)message { [_error release]; _error = [message copy]; }
- (BOOL)responseWithTimeout:(int)timeout {
    ama_worker::Response response{};
    int fd = _responses.fileHandleForReading.fileDescriptor;
    if (!ama_worker::transfer(fd, &response, sizeof(response), false, timeout) || response.messageSize > 65536) {
        [self setFailure:_cancelled ? @"Export cancelled." : @"The AMA encoder worker stopped or timed out."];
        return NO;
    }
    NSMutableData* message = [NSMutableData dataWithLength:response.messageSize];
    if (response.messageSize && !ama_worker::transfer(fd, message.mutableBytes, message.length, false)) return NO;
    if (!response.success) {
        NSString* text = [[[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding] autorelease];
        [self setFailure:text ?: @"The AMA encoder worker failed."];
    }
    return response.success != 0;
}
- (instancetype)initWithOutputURL:(NSURL*)outputURL width:(NSInteger)width height:(NSInteger)height
    fpsNumerator:(NSInteger)numerator fpsDenominator:(NSInteger)denominator quality:(NSString*)quality
    containerExtension:(NSString*)container bitrateMbps:(double)bitrate includeDolbyVision:(BOOL)dolby
    advancedOptions:(NSDictionary*)options {
    self = [super init];
    if (!self) return nil;
    _fd = -1; _mapping = MAP_FAILED; _cancelled.store(false);
    // A shared region holds one frame. A synchronous acknowledgement permits
    // reuse only after the worker has copied it into its bounded codec pool.
    std::string pattern = std::string(NSTemporaryDirectory().fileSystemRepresentation) + "ama-frames-XXXXXX";
    _fd = mkstemp(pattern.data());
    if (_fd < 0 || ftruncate(_fd, ama_worker::maximumFrameBytes) != 0) {
        [self setFailure:@"AMA frame sharing could not be allocated."]; return self;
    }
    _mappingPath = [[NSString stringWithUTF8String:pattern.c_str()] copy];
    _mapping = mmap(nullptr, ama_worker::maximumFrameBytes, PROT_READ | PROT_WRITE, MAP_SHARED, _fd, 0);
    if (_mapping == MAP_FAILED) { [self setFailure:@"AMA frame sharing could not be mapped."]; return self; }
    Dl_info location{};
    if (!dladdr((const void*)&ama_worker::transfer, &location) || !location.dli_fname) {
        [self setFailure:@"The AMA worker bundle path is unavailable."]; return self;
    }
    NSString* executable = [NSString stringWithUTF8String:location.dli_fname];
    NSString* contents = [[executable stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString* worker = [contents stringByAppendingPathComponent:@"MacOS/ProResEncoderAMAWorker"];
    NSString* framework = [contents stringByAppendingPathComponent:@"Frameworks/ProResEncoderFramework.framework"];
    _requests = [[NSPipe alloc] init]; _responses = [[NSPipe alloc] init];
    NSString* logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"AMA-worker-%@.log", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    _log = [[NSFileHandle fileHandleForWritingAtPath:logPath] retain];
    _task = [[NSTask alloc] init];
    _task.executableURL = [NSURL fileURLWithPath:worker];
    _task.arguments = @[_mappingPath, framework];
    fcntl(_requests.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1);
    _task.standardInput = _requests; _task.standardOutput = _responses; _task.standardError = _log;
    NSError* error = nil;
    if (![_task launchAndReturnError:&error]) { [self setFailure:error.localizedDescription]; return self; }
    NSDictionary* configuration = @{ @"output": outputURL.path, @"width": @(width), @"height": @(height),
        @"numerator": @(numerator), @"denominator": @(denominator), @"quality": quality,
        @"container": container, @"bitrate": @(bitrate), @"dolby": @(dolby), @"options": options };
    NSData* plist = [NSPropertyListSerialization dataWithPropertyList:configuration format:NSPropertyListBinaryFormat_v1_0
        options:0 error:&error];
    ama_worker::Request request{ama_worker::Initialize, 0, plist.length};
    int fd = _requests.fileHandleForWriting.fileDescriptor;
    if (!plist || !ama_worker::transfer(fd, &request, sizeof(request), true) ||
        !ama_worker::transfer(fd, (void*)plist.bytes, plist.length, true) || ![self responseWithTimeout:30000]) {
        if (!_error) [self setFailure:error.localizedDescription ?: @"AMA encoder worker initialization failed."];
    } else { unlink(_mappingPath.fileSystemRepresentation); }
    return self;
}
- (BOOL)sendBytes:(const void*)bytes size:(NSUInteger)size command:(std::uint32_t)command argument:(std::uint32_t)argument {
    std::lock_guard<std::mutex> lock(_rpc);
    if (_error || _cancelled || _mapping == MAP_FAILED || size > ama_worker::maximumFrameBytes) return NO;
    memcpy(_mapping, bytes, size);
    std::atomic_thread_fence(std::memory_order_release);
    ama_worker::Request request{command, argument, size};
    int fd = _requests.fileHandleForWriting.fileDescriptor;
    return ama_worker::transfer(fd, &request, sizeof(request), true) && [self responseWithTimeout:30000];
}
- (BOOL)appendBGRABytes:(const void*)bytes size:(NSUInteger)size stride:(NSInteger)stride {
    return [self sendBytes:bytes size:size command:ama_worker::BGRA argument:(std::uint32_t)stride];
}
- (BOOL)appendBGRAFrame:(NSData*)frame stride:(NSInteger)stride {
    return [self appendBGRABytes:frame.bytes size:frame.length stride:stride];
}
- (BOOL)appendProResFrame:(NSData*)frame sourceCodec:(NSString*)codec {
    NSArray* names = @[@"proxy", @"422lt", @"422", @"422hq", @"4444", @"4444xq"];
    NSUInteger index = [names indexOfObject:codec];
    if (index == NSNotFound) return NO;
    return [self sendBytes:frame.bytes size:frame.length command:ama_worker::ProRes argument:(std::uint32_t)index];
}
- (BOOL)finish {
    std::lock_guard<std::mutex> lock(_rpc);
    if (_error || _cancelled) return NO;
    ama_worker::Request request{ama_worker::Finish, 0, 0};
    int fd = _requests.fileHandleForWriting.fileDescriptor;
    return ama_worker::transfer(fd, &request, sizeof(request), true) && [self responseWithTimeout:-1];
}
- (void)cancel { _cancelled = true; if (_task.running) [_task terminate]; }
- (void)dealloc {
    [self cancel];
    [_requests.fileHandleForWriting closeFile]; [_responses.fileHandleForReading closeFile]; [_log closeFile];
    if (_mapping != MAP_FAILED) munmap(_mapping, ama_worker::maximumFrameBytes);
    if (_fd >= 0) close(_fd);
    if (_mappingPath) unlink(_mappingPath.fileSystemRepresentation);
    [_mappingPath release]; [_error release]; [_task release]; [_requests release]; [_responses release]; [_log release];
    [super dealloc];
}
@end
