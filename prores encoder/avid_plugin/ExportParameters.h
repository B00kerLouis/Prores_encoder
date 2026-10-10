#ifndef PRORES_ENCODER_AMA_EXPORT_PARAMETERS_H
#define PRORES_ENCODER_AMA_EXPORT_PARAMETERS_H

#include "AvidSDKUmbrella.h"
#include "ExportSession.hpp"

#include <memory>

namespace prores_ama {

struct FrameBridge;

class WriterJob {
public:
    WriterJob();
    ~WriterJob();

    WriterJob(const WriterJob&) = delete;
    WriterJob& operator=(const WriterJob&) = delete;

    ACFRESULT bindHost(IACFUnknown* host);
    ACFRESULT setInteractor(AMA::IWriterInteractor* interactor);
    ACFRESULT interactorResponse(acfUInt32 response);
    ACFRESULT validate();
    ACFRESULT beginWrite();
    ACFRESULT beginClip(acfUInt32 index, AMA::ISampleConsumer** consumer);
    ACFRESULT progress(acfFloat32* percent, ACFRESULT* errorResult) const;
    ACFRESULT finishWrite();
    ACFRESULT cancelWrite();
    ACFRESULT setOutputPath(IACFString* path);
    ACFRESULT noteMetadata(const char* source, acfUInt32 count);
    ACFRESULT getMediaWriterParameter(const acfUID& id, IACFValue** parameter) const;

    ACFRESULT getParameterInfos(const acfUID& componentID, IACFString** xml) const;
    ACFRESULT getValues(const acfUID& componentID, IACFString** xml) const;
    ACFRESULT getPresets(const acfUID& componentID, IACFString** xml) const;
    ACFRESULT setValues(const IACFString* xml);
    ACFRESULT loadValues(const IACFString* path);
    ACFRESULT resetValues();

    const std::shared_ptr<ExportSession>& session() const { return session_; }

private:
    void collectHostFacts();
    void logFailure() const;

    std::shared_ptr<ExportSession> session_;
    std::shared_ptr<FrameBridge> frameBridge_;
    IACFUnknown* host_ = nullptr;
    IACFComponentFactory* factory_ = nullptr;
    AMA::IWriterInteractor* interactor_ = nullptr;
    bool recordedFacts_ = false;
};

ACFRESULT CopyPluginString(const char* utf8, IACFString** stringOut);

}  // namespace prores_ama

#endif
