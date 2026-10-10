// ProResEncoderAMAAdapter.h
// Project-owned boundary between the AMA plug-in and ProResEncoderFramework.
// This header does not restate Avid declarations.

#ifndef PRORES_ENCODER_AMA_ADAPTER_H
#define PRORES_ENCODER_AMA_ADAPTER_H

namespace prores_ama {

// The current framework public API is Swift, URL-based, and async/throws.
// Objective-C++ cannot call that surface as a frame stream. Linking the
// framework does not invent the missing session ABI.
bool EncoderFrameworkFrameStreamAvailable();
const char* EncoderFrameworkBoundaryReason();

}  // namespace prores_ama

#endif
