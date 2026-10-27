#define PRORES_ENCODER_AMA_INCLUDE_AAF 1
#include "MediaVolumeWriter.h"
#include "SampleConsumer.h"

namespace prores_ama {
namespace {

ACFRESULT RejectDelete() {
    return ACF_E_FAIL;
}

}  // namespace

ProResMediaVolumeWriter::ProResMediaVolumeWriter(IACFUnknown* outer)
    : CACFUnknown(outer) {}

ACF_DEFINE_FACTORY(ProResMediaVolumeWriter)

ACFRESULT ProResMediaVolumeWriter::InternalQueryInterface(const acfIID& riid, void** ppv) {
    if (!ppv) {
        return ACF_E_POINTER;
    }
    if (riid == AMA::IID_IMediaVolumeWriter2 || riid == AMA::IID_IMediaVolumeWriter || riid == AMA::IID_IMediaWriter) {
        auto* writer = static_cast<AMA::IMediaVolumeWriter2*>(this);
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

ACFRESULT ProResMediaVolumeWriter::InitializeInstance(IACFUnknown* host) { return job_.bindHost(host); }
// AMA negotiates the rendered image format on the writer before BeginClip.
ACFRESULT ProResMediaVolumeWriter::GetImageFormat(
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

ACFRESULT ProResMediaVolumeWriter::BeginWrite() { return job_.beginWrite(); }
ACFRESULT ProResMediaVolumeWriter::ValidateWrite() { return job_.validate(); }
ACFRESULT ProResMediaVolumeWriter::BeginClip(const acfUInt32 index, AMA::ISampleConsumer** consumer) { return job_.beginClip(index, consumer); }
ACFRESULT ProResMediaVolumeWriter::GetProgress(acfFloat32* percentComplete, ACFRESULT* errorResult) const { return job_.progress(percentComplete, errorResult); }
ACFRESULT ProResMediaVolumeWriter::FinishWrite() { return job_.finishWrite(); }
ACFRESULT ProResMediaVolumeWriter::CancelWrite() { return job_.cancelWrite(); }
ACFRESULT ProResMediaVolumeWriter::SetInteractor(AMA::IWriterInteractor* interactor) { return job_.setInteractor(interactor); }
ACFRESULT ProResMediaVolumeWriter::InteractorResponse(const acfUInt32 response) { return job_.interactorResponse(response); }

ACFRESULT ProResMediaVolumeWriter::GetMediaWriterParameter(const acfUID id, IACFValue** parameter) {
    return job_.getMediaWriterParameter(id, parameter);
}

ACFRESULT ProResMediaVolumeWriter::SetMediaWriterParameter(const acfUID, IACFValue* parameter) {
    if (!parameter) return ACF_E_POINTER;
    job_.session()->addObservation("SetMediaWriterParameter bytes=" + std::to_string(parameter->GetSize()));
    return ACF_OK;
}

ACFRESULT ProResMediaVolumeWriter::GetWriterCapabilities(acfUInt64* caps) const {
    if (!caps) return ACF_E_POINTER;
    // ConsumeSample acknowledges only after the worker has accepted the frame.
    // The host-facing consumer is synchronous even though codec work overlaps.
    const auto options = job_.session()->advancedOptions();
    const bool audio = !options.deleteSourceAudio && !options.replaceSourceAudio &&
        (job_.session()->container() == ContainerChoice::MOV || job_.session()->container() == ContainerChoice::MP4 || job_.session()->container() == ContainerChoice::MKV);
    *caps = AMA::IMediaWriter::kSupportsVideoResolutionsOtherThanSDHD |
        (audio ? 0 : AMA::IMediaWriter::kOnlySupportsVideo);
    return ACF_OK;
}

ACFRESULT ProResMediaVolumeWriter::GetWriterShortName(IACFString** name) const {
    return CopyPluginString("ProRes Encoder AMA Volume", name);
}

ACFRESULT ProResMediaVolumeWriter::GetWriterDescription(IACFString** name) const {
    return CopyPluginString("ProRes Encoder AMA volume export", name);
}

ACFRESULT ProResMediaVolumeWriter::GetVolumeCapabilities(acfUInt64* caps) const {
    if (!caps) return ACF_E_POINTER;
    *caps = AMA::IMediaVolumeWriter::kFullSequenceAccepted;
    return ACF_OK;
}

ACFRESULT ProResMediaVolumeWriter::SetVolumePath(IACFString* path) { return job_.setOutputPath(path); }

ACFRESULT ProResMediaVolumeWriter::SetVolumeName(IACFString* name) {
    if (!name) return ACF_E_POINTER;
    try {
        AMA::AMAString text(kACFUTF8, name);
        const acfUTF8* utf8 = text.GetUTF8String();
        volumeName_ = utf8 ? reinterpret_cast<const char*>(utf8) : "";
        job_.session()->addObservation("volumeName=" + volumeName_);
        return ACF_OK;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT ProResMediaVolumeWriter::SetVolumeSerialNumber(acfUInt32 serNo) {
    job_.session()->addObservation("volumeSerial=" + std::to_string(serNo));
    return ACF_OK;
}

ACFRESULT ProResMediaVolumeWriter::SetDeviceSerialNumber(IACFString* serNo) {
    if (!serNo) return ACF_E_POINTER;
    try {
        AMA::AMAString text(kACFUTF8, serNo);
        const acfUTF8* utf8 = text.GetUTF8String();
        job_.session()->addObservation(std::string("deviceSerial=") + (utf8 ? reinterpret_cast<const char*>(utf8) : ""));
        return ACF_OK;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT ProResMediaVolumeWriter::AddClips(AMA::IClips* clips) {
    if (!clips) return ACF_E_POINTER;
    return job_.noteMetadata("Volume AddClips host IClips", clips->Count());
}

ACFRESULT ProResMediaVolumeWriter::AddSequences(AMA::ISequences* sequences) {
    if (!sequences) return ACF_E_POINTER;
    return job_.noteMetadata("Volume AddSequences host ISequences", sequences->Count());
}

ACFRESULT ProResMediaVolumeWriter::AddAAFClips(AMA::IAAFClips* clips) {
    if (!clips) return ACF_E_POINTER;
    return job_.noteMetadata("Volume AddAAFClips host IAAFClips", clips->Count());
}

ACFRESULT ProResMediaVolumeWriter::AddAAFSequences(AMA::IAAFSequences* sequences) {
    if (!sequences) return ACF_E_POINTER;
    return job_.noteMetadata("Volume AddAAFSequences host IAAFSequences", sequences->Count());
}

ACFRESULT ProResMediaVolumeWriter::AddFullAAFSequences(AMA::IAAFSequences* sequences) {
    if (!sequences) return ACF_E_POINTER;
    const acfUInt32 count = sequences->Count();
    const ACFRESULT result = job_.noteMetadata("AddFullAAFSequences host IAAFSequences", count);
    if (count > 0) {
        IAAFFile* file = nullptr;
        if (sequences->GetMetadata(0, &file) == ACF_OK && file) {
            job_.session()->addObservation("AddFullAAFSequences metadata=IAAFFile supplied by the host callback");
            file->Release();
        } else {
            job_.session()->addObservation("AddFullAAFSequences metadata=host did not return IAAFFile");
        }
    }
    return result;
}

ACFRESULT ProResMediaVolumeWriter::DeleteClips(AMA::IClips*) { return RejectDelete(); }
ACFRESULT ProResMediaVolumeWriter::DeleteSequences(AMA::ISequences*) { return RejectDelete(); }
ACFRESULT ProResMediaVolumeWriter::DeleteAAFClips(AMA::IAAFClips*) { return RejectDelete(); }
ACFRESULT ProResMediaVolumeWriter::DeleteAAFSequences(AMA::IAAFSequences*) { return RejectDelete(); }

ACFRESULT ProResMediaVolumeWriter::GetPartnerContainerWriterGUID(acfUID* guid) {
    if (!guid) return ACF_E_POINTER;
    *guid = ProResEncoderAMA_FileWriterCLSID;
    return ACF_OK;
}

ACFRESULT ProResMediaVolumeWriter::GetVolumePathCount(acfUInt32* count) {
    if (!count) return ACF_E_POINTER;
    *count = job_.session()->outputPath().empty() ? 0 : 1;
    return ACF_OK;
}

ACFRESULT ProResMediaVolumeWriter::GetVolumePath(acfUInt32 index, IACFString** path) {
    if (!path) return ACF_E_POINTER;
    *path = nullptr;
    if (index != 0 || job_.session()->outputPath().empty()) {
        return ACF_E_INVALIDARG;
    }
    return CopyPluginString(job_.session()->outputPath().c_str(), path);
}

ACFRESULT ProResMediaVolumeWriter::GetValues(IACFString** xml) const {
    return job_.getValues(ProResEncoderAMA_VolumeWriterComponentID, xml);
}
ACFRESULT ProResMediaVolumeWriter::GetParameterInfos(IACFString** xml) const {
    return job_.getParameterInfos(ProResEncoderAMA_VolumeWriterComponentID, xml);
}
ACFRESULT ProResMediaVolumeWriter::GetPresets(IACFString** xml) const {
    return job_.getPresets(ProResEncoderAMA_VolumeWriterComponentID, xml);
}
ACFRESULT ProResMediaVolumeWriter::SetValues(const IACFString* xml) { return job_.setValues(xml); }
ACFRESULT ProResMediaVolumeWriter::LoadValues(const IACFString* pathToFile) { return job_.loadValues(pathToFile); }
ACFRESULT ProResMediaVolumeWriter::ResetValues() { return job_.resetValues(); }

}  // namespace prores_ama
