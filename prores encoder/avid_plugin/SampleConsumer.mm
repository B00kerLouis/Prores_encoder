#include "SampleConsumer.h"

#include "ExportSession.hpp"
#include "AMAWorkerProtocol.h"

#include <atomic>
#include <fstream>
#include <memory>

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

    void attach(std::shared_ptr<ExportSession> session, VideoFrameHandler videoFrames, AudioSampleHandler audioSamples) {
        session_ = std::move(session);
        videoFrames_ = std::move(videoFrames);
        audioSamples_ = std::move(audioSamples);
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

    static ACFRESULT CreateForSession(const std::shared_ptr<ExportSession>& session, VideoFrameHandler videoFrames, AudioSampleHandler audioSamples, AMA::ISampleConsumer** consumer) {
        if (!consumer) {
            return ACF_E_POINTER;
        }
        *consumer = nullptr;
        auto* object = new (std::nothrow) ProResSampleConsumer(nullptr);
        if (!object) {
            return ACF_E_OUTOFMEMORY;
        }
        object->attach(session, std::move(videoFrames), std::move(audioSamples));
        object->InternalAddRef();
        const ACFRESULT result = object->InternalQueryInterface(AMA::IID_ISampleConsumer, reinterpret_cast<void**>(consumer));
        object->InternalRelease();
        return result;
    }

    ACFRESULT ACFMETHODCALLTYPE Setup(const acfUInt32 track, const acfUInt64 flags) override {
        ama_worker::trace("consumer.setup object=%p track=%u flags=%llu", this, track, (unsigned long long)flags);
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

    ACFRESULT ACFMETHODCALLTYPE ConsumeSampleEx(AMA::IAVBuffer* buffer, const acfUInt64 offset, const acfUInt64 flags) override {
        const auto call = calls_.fetch_add(1);
        ama_worker::trace("consumer.enter object=%p call=%llu offset=%llu flags=%llu", this,
            (unsigned long long)call, (unsigned long long)offset, (unsigned long long)flags);
        struct ReturnTrace {
            const void* object;
            std::uint64_t call;
            ACFRESULT result = ACF_E_UNEXPECTED;
            ~ReturnTrace() { ama_worker::trace("consumer.return object=%p call=%llu result=0x%08x", object,
                (unsigned long long)call, (unsigned int)result); }
        } returned{this, call};
        try {
            if (!session_ || !buffer) {
                return returned.result = ACF_E_POINTER;
            }
            acfUInt32 track = 0;
            acfUInt64 sample = 0;
            acfUInt64 sampleCount = 0;
            const ACFRESULT rangeResult = buffer->GetSampleRange(&track, &sample, &sampleCount);
            if (ACFFAILED(rangeResult)) {
                return returned.result = rangeResult;
            }
            acfUInt64 bytes = 0;
            IACFBuffer* storage = nullptr;
            const std::uint8_t* pointer = nullptr;
            const ACFRESULT bufferResult = buffer->GetBuffer(&storage);
            const auto releaseBuffer = [](IACFBuffer* value) { if (value) value->Release(); };
            std::unique_ptr<IACFBuffer, decltype(releaseBuffer)> storageOwner(storage, releaseBuffer);
            if (bufferResult == ACF_OK && storage) {
                storage->GetSize(&bytes);
                void* raw = nullptr;
                if (storage->GetBufferPointer(&raw) == ACF_OK) {
                    pointer = static_cast<const std::uint8_t*>(raw);
                }
            }
            ama_worker::trace("consumer.buffer object=%p call=%llu track=%u sample=%llu count=%llu bytes=%llu readable=%d",
                this, (unsigned long long)call, track, (unsigned long long)sample,
                (unsigned long long)sampleCount, (unsigned long long)bytes, pointer != nullptr);
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
            if (ACFFAILED(noted)) return returned.result = noted;
            ACFRESULT pushed = ACF_OK;
            if (track > 0) {
                if (audioSamples_) pushed = audioSamples_(track, sample, sampleCount, pointer, static_cast<std::size_t>(bytes));
                else { session_->failWrite("The AMA audio sample handler is unavailable."); pushed = ACF_E_UNEXPECTED; }
            } else if (!pointer || bytes == 0) {
                session_->failWrite("The AMA host did not provide readable picture bytes.");
                pushed = ACF_E_FAIL;
            } else if (videoFrames_ && sampleCount == 1) {
                pushed = videoFrames_(pointer, static_cast<std::size_t>(bytes));
            } else if (sampleCount != 1) {
                session_->failWrite("The video-only AMA writer received a non-picture sample range.");
                pushed = ACF_E_INVALIDARG;
            } else {
                session_->failWrite("The AMA video frame handler is unavailable.");
                pushed = ACF_E_UNEXPECTED;
            }
            if (ACFFAILED(noted) || ACFFAILED(pushed)) {
                std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
                trace << "ConsumeSampleEx FAILED track=" << track << " sample=" << sample
                      << " count=" << sampleCount << " bytes=" << bytes
                      << " noted=" << static_cast<unsigned int>(noted)
                      << " pushed=" << static_cast<unsigned int>(pushed)
                      << " reason=" << session_->failureReason() << '\n';
            }
            return returned.result = pushed;
        } catch (...) {
            ama_worker::trace("consumer.exception object=%p call=%llu", this, (unsigned long long)call);
            return returned.result = ACF_E_UNEXPECTED;
        }
    }

    ACFRESULT ACFMETHODCALLTYPE Cleanup(const acfUInt32 track) override {
        ama_worker::trace("consumer.cleanup object=%p track=%u", this, track);
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
        ama_worker::trace("consumer.frame_complete object=%p sample=%llu", this, (unsigned long long)sample);
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
        return GetRenderedImageFormat(session_, pixelFormat, chromaSubSampling, componentType,
            componentRangeType, colorSpace, fieldOrder, frameLayout, orientation);
    }

private:
    std::shared_ptr<ExportSession> session_;
    VideoFrameHandler videoFrames_;
    AudioSampleHandler audioSamples_;
    std::atomic<std::uint64_t> calls_{0};
};

ACFRESULT GetRenderedImageFormat(
    const std::shared_ptr<ExportSession>& session,
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
        const bool packed = session && session->negotiatePackedImage(access("/tmp/ProResAMA-force-packed422", F_OK) == 0);
        ama_worker::trace("image.request packed422=%d input=%u matrix=%u", packed,
            session ? session->advancedOptions().inputColor : 0, session ? session->renderedMatrix() : 0);
        *pixelFormat = packed ? AMA::IUncompressedImageProvider::PF_CbYCrY : AMA::IUncompressedImageProvider::PF_BGRA;
        *chromaSubSampling = packed ? AMA::IUncompressedImageProvider::CSS_4220 : AMA::IUncompressedImageProvider::CSS_4444;
        *componentType = packed ? AMA::IUncompressedImageProvider::CT_USHORT_10_6 : AMA::IUncompressedImageProvider::CT_UCHAR_FullRange;
        *componentRangeType = packed ? AMA::IUncompressedImageProvider::CRT_VideoRange : AMA::IUncompressedImageProvider::CRT_FullRange;
        *colorSpace = packed ? (session->renderedMatrix() == 2020 ? AMA::IUncompressedImageProvider::CS_YCbCr_2020 : AMA::IUncompressedImageProvider::CS_YCbCr_709) : AMA::IUncompressedImageProvider::CS_RGB;
        *fieldOrder = AMA::IUncompressedImageProvider::TFO_Progressive;
        *frameLayout = AMA::IUncompressedImageProvider::FBL_Merged;
        *orientation = AMA::IUncompressedImageProvider::BLO_Top_Bot;
        return ACF_OK;
}

ACF_DEFINE_FACTORY(ProResSampleConsumer)

ACFRESULT CreateSampleConsumer(
    const std::shared_ptr<ExportSession>& session,
    VideoFrameHandler videoFrames,
    AudioSampleHandler audioSamples,
    AMA::ISampleConsumer** consumer) {
    if (!session) {
        return ACF_E_INVALIDARG;
    }
    return ProResSampleConsumer::CreateForSession(session, std::move(videoFrames), std::move(audioSamples), consumer);
}

}  // namespace prores_ama
