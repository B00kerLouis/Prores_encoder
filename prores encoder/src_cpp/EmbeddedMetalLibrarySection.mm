// Locates the precompiled Metal library inserted by the linker's -sectcreate flag.

#include "EmbeddedMetalLibrarySection.h"

#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>

const void *ProResEmbeddedMetalLibraryBytes(size_t *byteCount) {
    if (byteCount != nullptr) {
        *byteCount = 0;
    }

    Dl_info imageInfo{};
    if (dladdr(
            reinterpret_cast<const void *>(&ProResEmbeddedMetalLibraryBytes),
            &imageInfo
        ) == 0 || imageInfo.dli_fbase == nullptr) {
        return nullptr;
    }

    unsigned long sectionSize = 0;
    const auto *bytes = getsectiondata(
        static_cast<const mach_header_64 *>(imageInfo.dli_fbase),
        "__TEXT",
        "__proresmetallib",
        &sectionSize
    );
    if (bytes == nullptr || sectionSize == 0) {
        return nullptr;
    }

    if (byteCount != nullptr) {
        *byteCount = static_cast<size_t>(sectionSize);
    }
    return bytes;
}
