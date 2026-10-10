#ifndef PRORES_ENCODER_AMA_MEDIA_CONTAINER_WRITER_H
#define PRORES_ENCODER_AMA_MEDIA_CONTAINER_WRITER_H

#include "ExportParameters.h"
#include "ProResEncoderAMAIDs.h"

namespace prores_ama {

class ProResMediaContainerWriter final
    : public AMA::IMediaContainerWriter
    , public AMA::IUncompressedImageConsumer
    , public IACFParametersXML
    , public CACFUnknown {
public:
    ACF_DECLARE_CONCRETE();
    explicit ProResMediaContainerWriter(IACFUnknown* outer);

    ACFRESULT ACFMETHODCALLTYPE InternalQueryInterface(const acfIID& riid, void** ppv) override;
    ACFRESULT ACFMETHODCALLTYPE InitializeInstance(IACFUnknown* host) override;

    ACFRESULT ACFMETHODCALLTYPE GetImageFormat(
        AMA::IUncompressedImageProvider::PixelFormat* pixelFormat,
        AMA::IUncompressedImageProvider::ChromaSubSampling* chromaSubSampling,
        AMA::IUncompressedImageProvider::ComponentType* componentType,
        AMA::IUncompressedImageProvider::ComponentRangeType* componentRangeType,
        AMA::IUncompressedImageProvider::ColorSpace* colorSpace,
        AMA::IUncompressedImageProvider::TemporalFieldOrder* fieldOrder,
        AMA::IUncompressedImageProvider::FrameBufferLayout* frameLayout,
        AMA::IUncompressedImageProvider::BufferLineOrientation* orientation) const override;

    ACFRESULT ACFMETHODCALLTYPE BeginWrite() override;
    ACFRESULT ACFMETHODCALLTYPE GetMediaWriterParameter(const acfUID id, IACFValue** parameter) override;
    ACFRESULT ACFMETHODCALLTYPE SetMediaWriterParameter(const acfUID id, IACFValue* parameter) override;
    ACFRESULT ACFMETHODCALLTYPE ValidateWrite() override;
    ACFRESULT ACFMETHODCALLTYPE BeginClip(const acfUInt32 index, AMA::ISampleConsumer** consumer) override;
    ACFRESULT ACFMETHODCALLTYPE GetProgress(acfFloat32* percentComplete, ACFRESULT* errorResult) const override;
    ACFRESULT ACFMETHODCALLTYPE FinishWrite() override;
    ACFRESULT ACFMETHODCALLTYPE CancelWrite() override;
    ACFRESULT ACFMETHODCALLTYPE SetInteractor(AMA::IWriterInteractor* interactor) override;
    ACFRESULT ACFMETHODCALLTYPE InteractorResponse(const acfUInt32 response) override;
    ACFRESULT ACFMETHODCALLTYPE GetWriterCapabilities(acfUInt64* caps) const override;
    ACFRESULT ACFMETHODCALLTYPE GetWriterShortName(IACFString** name) const override;
    ACFRESULT ACFMETHODCALLTYPE GetWriterDescription(IACFString** name) const override;
    ACFRESULT ACFMETHODCALLTYPE GetContainerCapabilities(acfUInt64* caps) const override;
    ACFRESULT ACFMETHODCALLTYPE SetContainerPath(IACFString* path) override;
    ACFRESULT ACFMETHODCALLTYPE AddClips(AMA::IClips* clips) override;
    ACFRESULT ACFMETHODCALLTYPE AddAAFClips(AMA::IAAFClips* clips) override;

    ACFRESULT ACFMETHODCALLTYPE GetValues(IACFString** xml) const override;
    ACFRESULT ACFMETHODCALLTYPE GetParameterInfos(IACFString** xml) const override;
    ACFRESULT ACFMETHODCALLTYPE GetPresets(IACFString** xml) const override;
    ACFRESULT ACFMETHODCALLTYPE SetValues(const IACFString* xml) override;
    ACFRESULT ACFMETHODCALLTYPE LoadValues(const IACFString* pathToFile) override;
    ACFRESULT ACFMETHODCALLTYPE ResetValues() override;

private:
    mutable WriterJob job_;
};

}  // namespace prores_ama

#endif
