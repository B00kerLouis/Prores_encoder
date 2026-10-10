#ifndef PRORES_ENCODER_AMA_SAMPLE_CONSUMER_H
#define PRORES_ENCODER_AMA_SAMPLE_CONSUMER_H

#include "AvidSDKUmbrella.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

namespace prores_ama {
class ExportSession;

using VideoFrameHandler = std::function<ACFRESULT(const std::uint8_t* bytes, std::size_t size)>;

// One contract shared by the writer and its per-clip sample consumer.
ACFRESULT GetRenderedImageFormat(
    AMA::IUncompressedImageProvider::PixelFormat* pixelFormat,
    AMA::IUncompressedImageProvider::ChromaSubSampling* chromaSubSampling,
    AMA::IUncompressedImageProvider::ComponentType* componentType,
    AMA::IUncompressedImageProvider::ComponentRangeType* componentRangeType,
    AMA::IUncompressedImageProvider::ColorSpace* colorSpace,
    AMA::IUncompressedImageProvider::TemporalFieldOrder* fieldOrder,
    AMA::IUncompressedImageProvider::FrameBufferLayout* frameLayout,
    AMA::IUncompressedImageProvider::BufferLineOrientation* orientation);

ACFRESULT CreateSampleConsumer(
    const std::shared_ptr<ExportSession>& session,
    VideoFrameHandler videoFrames,
    AMA::ISampleConsumer** consumer);
}
#endif
