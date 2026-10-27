#include "MediaContainerWriter.h"
#include "SampleConsumer.h"

#include <string>
#include <fstream>
#include <os/log.h>

namespace prores_ama {

ProResMediaContainerWriter::ProResMediaContainerWriter(IACFUnknown* outer)
    : CACFUnknown(outer) {}

ACF_DEFINE_FACTORY(ProResMediaContainerWriter)

ACFRESULT ProResMediaContainerWriter::InternalQueryInterface(const acfIID& riid, void** ppv) {
    if (!ppv) {
        return ACF_E_POINTER;
    }
    if (riid == AMA::IID_IMediaContainerWriter || riid == AMA::IID_IMediaWriter) {
        auto* writer = static_cast<AMA::IMediaContainerWriter*>(this);
        *ppv = writer;
        writer->AddRef();
        return ACF_OK;
    }
    if (riid == AMA::IID_IUncompressedImageConsumer) {
        auto* image = static_cast<AMA::IUncompressedImageConsumer*>(this);
        *ppv = image;
        image->AddRef();
        return ACF_OK;
    }
    if (riid == IID_IACFParametersXML) {
        auto* parameters = static_cast<IACFParametersXML*>(this);
        *ppv = parameters;
        parameters->AddRef();
        return ACF_OK;
    }
    return CACFUnknown::InternalQueryInterface(riid, ppv);
}

ACFRESULT ProResMediaContainerWriter::InitializeInstance(IACFUnknown* host) {
    const ACFRESULT result = job_.bindHost(host);
#if DEBUG
    std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
    trace << "InitializeInstance result=" << std::hex << static_cast<unsigned int>(result) << '\n';
#endif
    return result;
}

// AMA negotiates the rendered image format on the writer before BeginClip.
ACFRESULT ProResMediaContainerWriter::GetImageFormat(
    AMA::IUncompressedImageProvider::PixelFormat* pixelFormat,
    AMA::IUncompressedImageProvider::ChromaSubSampling* chromaSubSampling,
    AMA::IUncompressedImageProvider::ComponentType* componentType,
    AMA::IUncompressedImageProvider::ComponentRangeType* componentRangeType,
    AMA::IUncompressedImageProvider::ColorSpace* colorSpace,
    AMA::IUncompressedImageProvider::TemporalFieldOrder* fieldOrder,
    AMA::IUncompressedImageProvider::FrameBufferLayout* frameLayout,
    AMA::IUncompressedImageProvider::BufferLineOrientation* orientation) const {
    return GetRenderedImageFormat(job_.session(), pixelFormat, chromaSubSampling, componentType,
        componentRangeType, colorSpace, fieldOrder, frameLayout, orientation);
}

ACFRESULT ProResMediaContainerWriter::BeginWrite() { return job_.beginWrite(); }
ACFRESULT ProResMediaContainerWriter::ValidateWrite() { return job_.validate(); }
ACFRESULT ProResMediaContainerWriter::BeginClip(const acfUInt32 index, AMA::ISampleConsumer** consumer) { return job_.beginClip(index, consumer); }
ACFRESULT ProResMediaContainerWriter::GetProgress(acfFloat32* percentComplete, ACFRESULT* errorResult) const { return job_.progress(percentComplete, errorResult); }
ACFRESULT ProResMediaContainerWriter::FinishWrite() {
    os_log_error(OS_LOG_DEFAULT, "ProResAMA FinishWrite callback entered");
    std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
    trace << "FinishWrite callback entered" << std::endl;
    const ACFRESULT result = job_.finishWrite();
    trace << "FinishWrite callback returned=" << static_cast<unsigned int>(result)
          << " reason=" << job_.session()->failureReason() << std::endl;
    os_log_error(OS_LOG_DEFAULT, "ProResAMA FinishWrite returned %{public}u", static_cast<unsigned int>(result));
    return result;
}
ACFRESULT ProResMediaContainerWriter::CancelWrite() { return job_.cancelWrite(); }
ACFRESULT ProResMediaContainerWriter::SetInteractor(AMA::IWriterInteractor* interactor) { return job_.setInteractor(interactor); }
ACFRESULT ProResMediaContainerWriter::InteractorResponse(const acfUInt32 response) { return job_.interactorResponse(response); }

ACFRESULT ProResMediaContainerWriter::GetMediaWriterParameter(const acfUID id, IACFValue** parameter) {
    return job_.getMediaWriterParameter(id, parameter);
}

ACFRESULT ProResMediaContainerWriter::SetMediaWriterParameter(const acfUID id, IACFValue* parameter) {
    if (!parameter) {
        return ACF_E_POINTER;
    }
#if DEBUG
    acfUID typeID{};
    const ACFRESULT typeResult = parameter->GetTypeID(&typeID);
    std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
    trace << "SetMediaWriterParameter id.Data1=" << std::hex << id.Data1
          << " typeResult=" << static_cast<unsigned int>(typeResult)
          << " type.Data1=" << typeID.Data1
          << " bytes=" << std::dec << parameter->GetSize() << '\n';
#endif
    job_.session()->addObservation("SetMediaWriterParameter bytes=" + std::to_string(parameter->GetSize()));
    (void)id;
    return ACF_OK;
}

ACFRESULT ProResMediaContainerWriter::GetWriterCapabilities(acfUInt64* caps) const {
    if (!caps) {
        return ACF_E_POINTER;
    }
    // ConsumeSample acknowledges only after the worker has accepted the frame.
    // The host-facing consumer is synchronous even though codec work overlaps.
    const auto options = job_.session()->advancedOptions();
    const bool audio = !options.deleteSourceAudio && !options.replaceSourceAudio &&
        (job_.session()->container() == ContainerChoice::MOV || job_.session()->container() == ContainerChoice::MP4 || job_.session()->container() == ContainerChoice::MKV);
    *caps = AMA::IMediaWriter::kSupportsVideoResolutionsOtherThanSDHD |
        (audio ? 0 : AMA::IMediaWriter::kOnlySupportsVideo);
#if DEBUG
    std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
    trace << "GetWriterCapabilities=" << *caps << '\n';
#endif
    return ACF_OK;
}

ACFRESULT ProResMediaContainerWriter::GetWriterShortName(IACFString** name) const {
    return CopyPluginString("ProRes Encoder AMA", name);
}

ACFRESULT ProResMediaContainerWriter::GetWriterDescription(IACFString** name) const {
    return CopyPluginString("ProRes Encoder AMA file export", name);
}

ACFRESULT ProResMediaContainerWriter::GetContainerCapabilities(acfUInt64* caps) const {
    if (!caps) {
        return ACF_E_POINTER;
    }
    *caps = 0;
#if DEBUG
    std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
    trace << "GetContainerCapabilities=" << *caps << '\n';
#endif
    return ACF_OK;
}

ACFRESULT ProResMediaContainerWriter::SetContainerPath(IACFString* path) {
    return job_.setOutputPath(path);
}

ACFRESULT ProResMediaContainerWriter::AddClips(AMA::IClips* clips) {
    if (!clips) {
        return ACF_E_POINTER;
    }
    return job_.noteMetadata("AddClips host IClips", clips->Count());
}

ACFRESULT ProResMediaContainerWriter::AddAAFClips(AMA::IAAFClips* clips) {
    if (!clips) {
        return ACF_E_POINTER;
    }
    return job_.noteMetadata("AddAAFClips host IAAFClips", clips->Count());
}

ACFRESULT ProResMediaContainerWriter::GetValues(IACFString** xml) const {
    return job_.getValues(ProResEncoderAMA_FileWriterComponentID, xml);
}
ACFRESULT ProResMediaContainerWriter::GetParameterInfos(IACFString** xml) const {
    return job_.getParameterInfos(ProResEncoderAMA_FileWriterComponentID, xml);
}
ACFRESULT ProResMediaContainerWriter::GetPresets(IACFString** xml) const {
    return job_.getPresets(ProResEncoderAMA_FileWriterComponentID, xml);
}
ACFRESULT ProResMediaContainerWriter::SetValues(const IACFString* xml) { return job_.setValues(xml); }
ACFRESULT ProResMediaContainerWriter::LoadValues(const IACFString* pathToFile) { return job_.loadValues(pathToFile); }
ACFRESULT ProResMediaContainerWriter::ResetValues() { return job_.resetValues(); }

}  // namespace prores_ama
