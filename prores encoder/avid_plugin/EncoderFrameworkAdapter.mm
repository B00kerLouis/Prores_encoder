#include "ProResEncoderAMAAdapter.h"

namespace prores_ama {

bool EncoderFrameworkFrameStreamAvailable() {
    return false;
}

const char* EncoderFrameworkBoundaryReason() {
    return "ProResEncoderFramework publishes Swift value types and async throws file APIs. "
           "A C or Objective-C frame-stream session, flush, and cancel contract is not available, "
           "so the AMA plug-in does not encode video or mux audio.";
}

}  // namespace prores_ama
