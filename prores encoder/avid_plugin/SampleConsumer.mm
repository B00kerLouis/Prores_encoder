#include "SampleConsumer.h"

#include "ExportSession.hpp"

#include <atomic>
#include <fstream>

namespace prores_ama {
namespace {

ACFRESULT MapStatus(Status status) {
    switch (status) {
        case Status::Ok: return ACF_OK;
        case Status::InvalidOption: return ACF_E_INVALIDARG;
        case Status::InvalidState: return ACF_E_UNEXPECTED;
        case Status::EncoderBoundary: return ACF_E_UNEXPECTED;
        case Status::Cancelled: return ACF_E_ABORT;
    }
    return ACF_E_UNEXPECTED;
}

}  // namespace

class ProResSampleConsumer final
    : public AMA::ISampleConsumer2
    , public AMA::IUncompressedImageConsumer
    , public CACFUnknown {
public:
    ACF_DECLARE_CONCRETE();
    explicit ProResSampleConsumer(IACFUnknown* outer)
        : CACFUnknown(outer) {}

    void attach(std::shared_ptr<ExportSession> session, VideoFrameHandler videoFrames) {
        session_ = std::move(session);
        videoFrames_ = std::move(videoFrames);
    }

    ACFRESULT ACFMETHODCALLTYPE InternalQueryInterface(const acfIID& riid, void** ppv) override {
        if (!ppv) {
            return ACF_E_POINTER;
        }
        *ppv = nullptr;
        if (riid == AMA::IID_ISampleConsumer || riid == AMA::IID_ISampleConsumer2) {
            auto* consumer = static_cast<AMA::ISampleConsumer2*>(this);
            *ppv = consumer;
            consumer->AddRef();
            return ACF_OK;
        }
        if (riid == AMA::IID_IUncompressedImageConsumer) {
#if DEBUG
            std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
            trace << "QueryInterface IUncompressedImageConsumer" << '\n';
#endif
            auto* image = static_cast<AMA::IUncompressedImageConsumer*>(this);
            *ppv = image;
            image->AddRef();
            return ACF_OK;
        }
        return CACFUnknown::InternalQueryInterface(riid, ppv);
    }

    static ACFRESULT CreateForSession(const std::shared_ptr<ExportSession>& session, VideoFrameHandler videoFrames, AMA::ISampleConsumer** consumer) {
        if (!consumer) {
            return ACF_E_POINTER;
        }
        *consumer = nullptr;
        auto* object = new (std::nothrow) ProResSampleConsumer(nullptr);
        if (!object) {
            return ACF_E_OUTOFMEMORY;
        }
        object->attach(session, std::move(videoFrames));
        object->InternalAddRef();
        const ACFRESULT result = object->InternalQueryInterface(AMA::IID_ISampleConsumer, reinterpret_cast<void**>(consumer));
        object->InternalRelease();
        return result;
    }

    ACFRESULT ACFMETHODCALLTYPE Setup(const acfUInt32 track, const acfUInt64 flags) override {
        try {
            if (!session_) {
                return ACF_E_UNEXPECTED;
            }
            session_->addObservation("ISampleConsumer::Setup track=" + std::to_string(track) + " flags=" + std::to_string(flags));
            return ACF_OK;
        } catch (...) {
            return ACF_E_UNEXPECTED;
        }
    }

    ACFRESULT ACFMETHODCALLTYPE ConsumeSample(AMA::IAVBuffer* buffer) override {
        return ConsumeSampleEx(buffer, 0, 0);
    }

    ACFRESULT ACFMETHODCALLTYPE ConsumeSampleEx(AMA::IAVBuffer* buffer, const acfUInt64, const acfUInt64) override {
        try {
            if (!session_ || !buffer) {
                return ACF_E_POINTER;
            }
            acfUInt32 track = 0;
            acfUInt64 sample = 0;
            acfUInt64 sampleCount = 0;
            const ACFRESULT rangeResult = buffer->GetSampleRange(&track, &sample, &sampleCount);
            if (ACFFAILED(rangeResult)) {
                return rangeResult;
            }
            acfUInt64 bytes = 0;
            IACFBuffer* storage = nullptr;
            const std::uint8_t* pointer = nullptr;
            if (buffer->GetBuffer(&storage) == ACF_OK && storage) {
                storage->GetSize(&bytes);
                void* raw = nullptr;
                if (storage->GetBufferPointer(&raw) == ACF_OK) {
                    pointer = static_cast<const std::uint8_t*>(raw);
                }
            }
#if DEBUG
            static std::atomic<unsigned int> sampleCalls{0};
            const unsigned int callIndex = sampleCalls.fetch_add(1);
            if (callIndex < 20 || callIndex % 1000 == 0) {
                std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
                trace << "ConsumeSampleEx call=" << callIndex << " track=" << track
                      << " sample=" << sample << " count=" << sampleCount
                      << " bytes=" << bytes << " pointer=" << (pointer != nullptr) << '\n';
                if (pointer && callIndex < 4) {
                    trace << "  firstBytes=" << std::hex;
                    for (acfUInt64 index = 0; index < bytes && index < 16; ++index) {
                        trace << static_cast<unsigned int>(pointer[index]) << ' ';
                    }
                    trace << std::dec << '\n';
                }
            }
#endif
            const ACFRESULT noted = MapStatus(session_->noteSample(track, sample, sampleCount, bytes));
            ACFRESULT pushed = ACF_OK;
            if (!pointer || bytes == 0) {
                session_->failWrite("The AMA host did not provide readable picture bytes.");
                pushed = ACF_E_FAIL;
            } else if (videoFrames_ && sampleCount == 1) {
                pushed = videoFrames_(pointer, static_cast<std::size_t>(bytes));
            } else if (sampleCount != 1) {
                session_->failWrite("The video-only AMA writer received a non-picture sample range.");
                pushed = ACF_E_INVALIDARG;
            }
            if (storage) {
                storage->Release();
            }
            if (ACFFAILED(noted) || ACFFAILED(pushed)) {
                std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
                trace << "ConsumeSampleEx FAILED track=" << track << " sample=" << sample
                      << " count=" << sampleCount << " bytes=" << bytes
                      << " noted=" << static_cast<unsigned int>(noted)
                      << " pushed=" << static_cast<unsigned int>(pushed)
                      << " reason=" << session_->failureReason() << '\n';
            }
            if (ACFFAILED(noted)) { return noted; }
            return pushed;
        } catch (...) {
            return ACF_E_UNEXPECTED;
        }
    }

    ACFRESULT ACFMETHODCALLTYPE Cleanup(const acfUInt32 track) override {
        try {
            if (session_) {
                session_->addObservation("ISampleConsumer::Cleanup track=" + std::to_string(track));
                std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
                trace << "Cleanup track=" << track << " completed=" << session_->frameCompletions()
                      << " reason=" << session_->failureReason() << '\n';
            }
            return ACF_OK;
        } catch (...) {
            return ACF_E_UNEXPECTED;
        }
    }

    ACFRESULT ACFMETHODCALLTYPE NotifyFrameIsComplete(const acfUInt64 sample) override {
        try {
            if (!session_) {
                return ACF_E_UNEXPECTED;
            }
            return MapStatus(session_->noteFrameComplete(sample));
        } catch (...) {
            return ACF_E_UNEXPECTED;
        }
    }

    ACFRESULT ACFMETHODCALLTYPE GetImageFormat(
        AMA::IUncompressedImageProvider::PixelFormat* pixelFormat,
        AMA::IUncompressedImageProvider::ChromaSubSampling* chromaSubSampling,
        AMA::IUncompressedImageProvider::ComponentType* componentType,
        AMA::IUncompressedImageProvider::ComponentRangeType* componentRangeType,
        AMA::IUncompressedImageProvider::ColorSpace* colorSpace,
        AMA::IUncompressedImageProvider::TemporalFieldOrder* fieldOrder,
        AMA::IUncompressedImageProvider::FrameBufferLayout* frameLayout,
        AMA::IUncompressedImageProvider::BufferLineOrientation* orientation) const override {
        return GetRenderedImageFormat(pixelFormat, chromaSubSampling, componentType,
            componentRangeType, colorSpace, fieldOrder, frameLayout, orientation);
    }

private:
    std::shared_ptr<ExportSession> session_;
    VideoFrameHandler videoFrames_;
};

ACFRESULT GetRenderedImageFormat(
    AMA::IUncompressedImageProvider::PixelFormat* pixelFormat,
    AMA::IUncompressedImageProvider::ChromaSubSampling* chromaSubSampling,
    AMA::IUncompressedImageProvider::ComponentType* componentType,
    AMA::IUncompressedImageProvider::ComponentRangeType* componentRangeType,
    AMA::IUncompressedImageProvider::ColorSpace* colorSpace,
    AMA::IUncompressedImageProvider::TemporalFieldOrder* fieldOrder,
    AMA::IUncompressedImageProvider::FrameBufferLayout* frameLayout,
    AMA::IUncompressedImageProvider::BufferLineOrientation* orientation) {
        if (!pixelFormat || !chromaSubSampling || !componentType || !componentRangeType || !colorSpace || !fieldOrder || !frameLayout || !orientation) {
            return ACF_E_POINTER;
        }
#if DEBUG
        std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
        trace << "GetImageFormat called" << '\n';
#endif
        // This is the buffer layout the plug-in asks the host to deliver.
        // It is not evidence of the project color space.
        *pixelFormat = AMA::IUncompressedImageProvider::PF_BGRA;
        *chromaSubSampling = AMA::IUncompressedImageProvider::CSS_4444;
        *componentType = AMA::IUncompressedImageProvider::CT_UCHAR_FullRange;
        *componentRangeType = AMA::IUncompressedImageProvider::CRT_FullRange;
        *colorSpace = AMA::IUncompressedImageProvider::CS_RGB;
        *fieldOrder = AMA::IUncompressedImageProvider::TFO_Progressive;
        *frameLayout = AMA::IUncompressedImageProvider::FBL_Merged;
        *orientation = AMA::IUncompressedImageProvider::BLO_Top_Bot;
        return ACF_OK;
}

ACF_DEFINE_FACTORY(ProResSampleConsumer)

ACFRESULT CreateSampleConsumer(
    const std::shared_ptr<ExportSession>& session,
    VideoFrameHandler videoFrames,
    AMA::ISampleConsumer** consumer) {
    if (!session) {
        return ACF_E_INVALIDARG;
    }
    return ProResSampleConsumer::CreateForSession(session, std::move(videoFrames), consumer);
}

}  // namespace prores_ama
