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
    std::mutex _errorLock;
    std::atomic<bool> _cancelled;
    std::uint64_t _requestIndex;
    bool _finished;
}
- (NSString*)lastErrorMessage {
    std::lock_guard<std::mutex> lock(_errorLock);
    return [[(_error ?: @"") copy] autorelease];
}
- (void)setFailure:(NSString*)message {
    std::lock_guard<std::mutex> lock(_errorLock);
    [_error release]; _error = [message copy];
}
- (void)transportFailure:(NSString*)stage {
    const int code = errno;
    [self setFailure:_cancelled ? @"Export cancelled." :
        [NSString stringWithFormat:@"AMA worker %@ failed: %s (errno %d).", stage, strerror(code), code]];
    ama_worker::trace("rpc.failure object=%p request=%llu errno=%d stage=%s", self,
        (unsigned long long)_requestIndex, code, stage.UTF8String);
}
- (BOOL)responseWithTimeout:(int)timeout {
    ama_worker::Response response{};
    int fd = _responses.fileHandleForReading.fileDescriptor;
    if (!ama_worker::transfer(fd, &response, sizeof(response), false, timeout)) {
        [self transportFailure:@"response header"];
        return NO;
    }
    if (response.messageSize > 65536 || (response.success != 0 && response.success != 1)) {
        [self setFailure:@"The AMA encoder worker sent an invalid response."];
        return NO;
    }
    NSMutableData* message = [NSMutableData dataWithLength:response.messageSize];
    if (response.messageSize && !ama_worker::transfer(fd, message.mutableBytes, message.length, false)) {
        [self transportFailure:@"response message"]; return NO;
    }
    if (!response.success) {
        NSString* text = [[[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding] autorelease];
        [self setFailure:text.length ? text : @"The AMA encoder worker failed without a message."];
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
    if (_fd >= 0) {
        _mappingPath = [[NSString stringWithUTF8String:pattern.c_str()] copy];
        fcntl(_fd, F_SETFD, FD_CLOEXEC);
    }
    if (_fd < 0 || ftruncate(_fd, ama_worker::maximumFrameBytes) != 0) {
        [self setFailure:@"AMA frame sharing could not be allocated."]; return self;
    }
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
    for (int descriptor : {_requests.fileHandleForWriting.fileDescriptor, _responses.fileHandleForReading.fileDescriptor}) {
        fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK);
    }
    _task.standardInput = _requests; _task.standardOutput = _responses; _task.standardError = _log;
    NSError* error = nil;
    if (![_task launchAndReturnError:&error]) { [self setFailure:error.localizedDescription]; return self; }
    ama_worker::trace("rpc.launch object=%p worker_pid=%d width=%ld height=%ld rate=%ld/%ld", self,
        _task.processIdentifier, (long)width, (long)height, (long)numerator, (long)denominator);
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
    if (self.lastErrorMessage.length) return NO;
    if (_cancelled) { [self setFailure:@"Export cancelled."]; return NO; }
    if (_finished) { [self setFailure:@"The AMA encoder worker has already finished."]; return NO; }
    if (!bytes || size == 0 || _mapping == MAP_FAILED || size > ama_worker::maximumFrameBytes) {
        [self setFailure:@"The AMA frame is empty, unavailable, or exceeds the 64 MiB shared region."]; return NO;
    }
    ++_requestIndex;
    ama_worker::trace("rpc.submit object=%p request=%llu command=%u bytes=%lu argument=%u", self,
        (unsigned long long)_requestIndex, command, (unsigned long)size, argument);
    memcpy(_mapping, bytes, size);
    std::atomic_thread_fence(std::memory_order_release);
    ama_worker::Request request{command, argument, size};
    int fd = _requests.fileHandleForWriting.fileDescriptor;
    if (!ama_worker::transfer(fd, &request, sizeof(request), true)) { [self transportFailure:@"frame request"]; return NO; }
    const BOOL result = [self responseWithTimeout:30000];
    ama_worker::trace("rpc.ack object=%p request=%llu success=%d", self, (unsigned long long)_requestIndex, result);
    return result;
}
- (BOOL)appendBGRABytes:(const void*)bytes size:(NSUInteger)size stride:(NSInteger)stride {
    if (stride <= 0 || (NSUInteger)stride > UINT32_MAX) { [self setFailure:@"The AMA BGRA stride is invalid."]; return NO; }
    return [self sendBytes:bytes size:size command:ama_worker::BGRA argument:(std::uint32_t)stride];
}
- (BOOL)appendBGRAFrame:(NSData*)frame stride:(NSInteger)stride {
    return [self appendBGRABytes:frame.bytes size:frame.length stride:stride];
}
- (BOOL)appendPacked422Frame:(NSData*)frame stride:(NSInteger)stride {
    if (stride <= 0 || (NSUInteger)stride > UINT32_MAX) { [self setFailure:@"Invalid packed 422 stride."]; return NO; }
    return [self sendBytes:frame.bytes size:frame.length command:ama_worker::Packed422 argument:(std::uint32_t)stride];
}
- (BOOL)appendRGBAHalfFrame:(NSData*)frame stride:(NSInteger)stride {
    if (stride <= 0 || (NSUInteger)stride > UINT32_MAX) { [self setFailure:@"The AMA half-float stride is invalid."]; return NO; }
    return [self sendBytes:frame.bytes size:frame.length command:ama_worker::RGBAHalf argument:(std::uint32_t)stride];
}
- (BOOL)appendProResFrame:(NSData*)frame sourceCodec:(NSString*)codec {
    NSArray* names = @[@"proxy", @"422lt", @"422", @"422hq", @"4444", @"4444xq"];
    NSUInteger index = [names indexOfObject:codec];
    if (index == NSNotFound) { [self setFailure:@"The AMA source ProRes codec is invalid."]; return NO; }
    return [self sendBytes:frame.bytes size:frame.length command:ama_worker::ProRes argument:(std::uint32_t)index];
}
- (BOOL)finish {
    std::lock_guard<std::mutex> lock(_rpc);
    if (self.lastErrorMessage.length) return NO;
    if (_cancelled) { [self setFailure:@"Export cancelled."]; return NO; }
    if (_finished) return YES;
    ama_worker::trace("rpc.finish.enter object=%p", self);
    ama_worker::Request request{ama_worker::Finish, 0, 0};
    int fd = _requests.fileHandleForWriting.fileDescriptor;
    if (!ama_worker::transfer(fd, &request, sizeof(request), true)) { [self transportFailure:@"finish request"]; return NO; }
    _finished = [self responseWithTimeout:-1];
    ama_worker::trace("rpc.finish.return object=%p success=%d", self, _finished);
    return _finished;
}
- (void)cancel {
    if (_cancelled.exchange(true)) return;
    ama_worker::trace("rpc.cancel object=%p", self);
    // The child may have exited between the running query and terminate.
    @try { if (_task.running) [_task terminate]; } @catch (NSException*) {}
}
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
