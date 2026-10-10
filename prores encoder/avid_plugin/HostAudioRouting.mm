#include "HostAudioRouting.h"

#include "ExportSession.hpp"
#include "HostExportContext.h"

#include <string>

namespace prores_ama {
namespace {

void noteNumericSetting(AMA::IHostSettings* settings, const acfUID& settingID, const char* name, ExportSession& session) {
    const AMA::IHostSettings::EHostSettingScope scopes[] = {
        AMA::IHostSettings::kProjectScope,
        AMA::IHostSettings::kGlobalScope
    };
    for (AMA::IHostSettings::EHostSettingScope scope : scopes) {
        const char* scopeName = scope == AMA::IHostSettings::kProjectScope ? "project" : "global";
        acfSInt32 signedValue = 0;
        if (settings->GetHostSettingSInt32(settingID, scope, &signedValue) == ACF_OK) {
            std::string text = std::string(name) + "=" + std::to_string(signedValue) + " scope=" + scopeName;
            if (settingID == AMA::AMA_MC_ExportVolumeAudioMixFormat_ID) {
                if (signedValue == AMA::AMA_MC_ExportVolumeAudioMixFormat_DirectOut) text += " DirectOut";
                else if (signedValue == AMA::AMA_MC_ExportVolumeAudioMixFormat_Stereo) text += " Stereo";
                else if (signedValue == AMA::AMA_MC_ExportVolumeAudioMixFormat_Mono) text += " Mono";
                else if (signedValue == AMA::AMA_MC_ExportVolumeAudioMixFormat_5dot1) text += " 5.1";
                else if (signedValue == AMA::AMA_MC_ExportVolumeAudioMixFormat_7dot1) text += " 7.1";
            }
            session.addObservation(std::move(text));
            return;
        }
        acfUInt32 unsignedValue = 0;
        if (settings->GetHostSettingUInt32(settingID, scope, &unsignedValue) == ACF_OK) {
            session.addObservation(std::string(name) + "=" + std::to_string(unsignedValue) + " scope=" + scopeName + " type=UInt32");
            return;
        }
    }
    session.addObservation(std::string(name) + "=unavailable");
}

void notePresentSetting(AMA::IHostSettings* settings, const acfUID& settingID, const char* name, ExportSession& session) {
    IACFValue* value = nullptr;
    const AMA::IHostSettings::EHostSettingScope scopes[] = {
        AMA::IHostSettings::kProjectScope,
        AMA::IHostSettings::kGlobalScope
    };
    for (AMA::IHostSettings::EHostSettingScope scope : scopes) {
        if (settings->GetHostSetting(settingID, scope, &value) == ACF_OK && value) {
            const char* scopeName = scope == AMA::IHostSettings::kProjectScope ? "project" : "global";
            session.addObservation(std::string(name) + "=present scope=" + scopeName + " bytes=" + std::to_string(value->GetSize()));
            value->Release();
            return;
        }
    }
    session.addObservation(std::string(name) + "=unavailable");
}

}  // namespace

void RecordHostAudioRouting(IACFUnknown* host, ExportSession& session) {
    session.addObservation(session.audioRoute() == AudioRouteChoice::BounceMix
        ? "requestedAudio=BounceMix stereo stream"
        : "requestedAudio=BounceMultitrack direct-out streams");
    if (!host) {
        session.addObservation("audioHostSettings=missing host");
        return;
    }
    AMA::IHostSettings* settings = nullptr;
    if (AcquireHostSettings(host, &settings) != ACF_OK || !settings) {
        session.addObservation("audioHostSettings=IHostSettings unavailable");
        return;
    }
    noteNumericSetting(settings, AMA::AMA_MC_ExportVolumeAudioSampleRate_ID, "hostAudioSampleRate", session);
    noteNumericSetting(settings, AMA::AMA_MC_ExportVolumeAudioBitDepth_ID, "hostAudioBitDepth", session);
    noteNumericSetting(settings, AMA::AMA_MC_ExportVolumeAudioMixFormat_ID, "hostAudioMixFormat", session);
    notePresentSetting(settings, AMA::AMA_MC_ExportVolumeAudioFileArrangement_ID, "hostAudioFileArrangement", session);
    notePresentSetting(settings, AMA::AMA_MC_ExportVolumeAudioEssenceCoding_ID, "hostAudioEssenceCoding", session);
    session.addObservation("aacPackets=not observed; parameter presence is not host-encoded AAC");
    settings->Release();
}

}  // namespace prores_ama
