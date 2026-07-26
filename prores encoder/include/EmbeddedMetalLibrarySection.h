#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the precompiled default.metallib bytes linked into this Mach-O image.
const void *ProResEmbeddedMetalLibraryBytes(size_t *byteCount);

#ifdef __cplusplus
}
#endif
