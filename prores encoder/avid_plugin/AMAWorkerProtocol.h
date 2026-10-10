#pragma once
#include <cstdint>
#include <cerrno>
#include <unistd.h>
#include <poll.h>

namespace ama_worker {
enum Command : std::uint32_t { Initialize = 1, BGRA = 2, ProRes = 3, Finish = 4 };
struct Request { std::uint32_t command; std::uint32_t strideOrCodec; std::uint64_t size; };
struct Response { std::int32_t success; std::uint32_t messageSize; };
constexpr std::size_t maximumFrameBytes = 64 * 1024 * 1024;
inline bool transfer(int fd, void* data, std::size_t size, bool writing, int timeout = 30000) {
    auto* bytes = static_cast<std::uint8_t*>(data);
    while (size) {
        pollfd descriptor{fd, static_cast<short>(writing ? POLLOUT : POLLIN), 0};
        int ready = poll(&descriptor, 1, timeout);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return false;
        ssize_t count = writing ? write(fd, bytes, size) : read(fd, bytes, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        bytes += count; size -= static_cast<std::size_t>(count);
    }
    return true;
}
}
