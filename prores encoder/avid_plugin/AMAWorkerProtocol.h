#pragma once
#include <cstdint>
#include <cerrno>
#include <unistd.h>
#include <poll.h>
#include <chrono>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>

namespace ama_worker {
enum Command : std::uint32_t { Initialize = 1, BGRA = 2, ProRes = 3, Finish = 4, RGBAHalf = 5, Packed422 = 6 };
struct Request { std::uint32_t command; std::uint32_t strideOrCodec; std::uint64_t size; };
struct Response { std::int32_t success; std::uint32_t messageSize; };
constexpr std::size_t maximumFrameBytes = 64 * 1024 * 1024;

// Opt-in frame and host-stage evidence, shared by the bridge and worker. No
// pixel bytes are recorded; host-stage events can include owned output paths.
// Separate PID files let a stopped callback be matched
// to a live worker without doing I/O on every frame during ordinary exports.
inline void trace(const char* format, ...) {
    static const int traceFD = [] {
        if (access("/tmp/ProResAMA-enable-frame-trace", F_OK) != 0) return -1;
        char path[128];
        std::snprintf(path, sizeof(path), "/tmp/ProResAMA-Pipeline-%d.log", getpid());
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
        struct stat info{};
        if (fd >= 0 && (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid())) {
            close(fd);
            return -1;
        }
        return fd;
    }();
    if (traceFD < 0) return;
    char line[1024];
    std::uint64_t thread = 0;
    pthread_threadid_np(nullptr, &thread);
    const auto time = std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    int prefix = std::snprintf(line, sizeof(line), "t=%.6f pid=%d tid=%llu ", time, getpid(), (unsigned long long)thread);
    va_list args;
    va_start(args, format);
    std::vsnprintf(line + prefix, sizeof(line) - prefix - 1, format, args);
    va_end(args);
    std::size_t length = std::strlen(line);
    line[length++] = '\n';
    const int saved = errno;
    (void)write(traceFD, line, length);
    errno = saved;
}

inline bool transfer(int fd, void* data, std::size_t size, bool writing, int timeout = 30000) {
    auto* bytes = static_cast<std::uint8_t*>(data);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout < 0 ? 0 : timeout);
    while (size) {
        int remaining = -1;
        if (timeout >= 0) {
            const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count();
            if (milliseconds < 0) { errno = ETIMEDOUT; return false; }
            remaining = static_cast<int>(milliseconds);
        }
        pollfd descriptor{fd, static_cast<short>(writing ? POLLOUT : POLLIN), 0};
        int ready = poll(&descriptor, 1, remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready == 0) { errno = ETIMEDOUT; return false; }
        if (ready < 0) return false;
        ssize_t count = writing ? write(fd, bytes, size) : read(fd, bytes, size);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count == 0) { errno = EPIPE; return false; }
        if (count < 0) return false;
        bytes += count; size -= static_cast<std::size_t>(count);
    }
    return true;
}
}
