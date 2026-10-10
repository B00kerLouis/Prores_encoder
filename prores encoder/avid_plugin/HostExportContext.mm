#include "HostExportContext.h"

#include "ExportSession.hpp"
#include <fstream>

namespace prores_ama {

ACFRESULT AcquireHostSettings(IACFUnknown* host, AMA::IHostSettings** settings) {
    if (!host || !settings) {
        return ACF_E_POINTER;
    }
    *settings = nullptr;
    IACFComponentFactory* factory = nullptr;
    ACFRESULT result = host->QueryInterface(IID_PPV_ARG(IACFComponentFactory, &factory));
    if (ACFSUCCEEDED(result) && factory) {
        result = factory->CreateComponent(
            AMA::Impl::CompID_HostSettings,
            nullptr,
            NS_IID_PPV_ARG(AMA, IHostSettings, settings));
        factory->Release();
        if (ACFSUCCEEDED(result) && *settings) {
            return ACF_OK;
        }
        if (*settings) {
            (*settings)->Release();
            *settings = nullptr;
        }
    }
    return host->QueryInterface(NS_IID_PPV_ARG(AMA, IHostSettings, settings));
}

void RecordHostExportContext(IACFUnknown* host, ExportSession& session) {
    if (!host) {
        session.addObservation("hostUnknown=missing");
        return;
    }
    AMA::IHostSettings* settings = nullptr;
    const ACFRESULT result = AcquireHostSettings(host, &settings);
    if (ACFFAILED(result) || !settings) {
        session.addObservation("IHostSettings=unavailable");
        return;
    }
    session.addObservation("IHostSettings=present");
#if DEBUG
    // Local probe of the public host-settings snapshot. It must not be used as
    // project color until the returned fields and their scope are verified.
    IACFString* snapshot = nullptr;
    if (settings->GetHostSettings(&snapshot) == ACF_OK && snapshot) {
        AMA::AMAString text(kACFUTF8, snapshot);
        const acfUTF8* xml = text.GetUTF8String();
        if (xml) {
            std::ofstream output("/tmp/ProResAMA-HostSettings-20260930.xml", std::ios::binary);
            output << reinterpret_cast<const char*>(xml);
        }
        snapshot->Release();
    }
#endif
    acfUInt32 projectWidth = 0;
    acfUInt32 projectHeight = 0;
    bool haveProjectRaster = false;
    if (settings->GetHostSettingUInt32(AMA::AMAHostSetting_VideoImageWidth,
                                      AMA::IHostSettings::kProjectScope, &projectWidth) == ACF_OK &&
        settings->GetHostSettingUInt32(AMA::AMAHostSetting_VideoImageHeight,
                                      AMA::IHostSettings::kProjectScope, &projectHeight) == ACF_OK &&
        projectWidth > 0 && projectHeight > 0) {
        session.setRaster(projectWidth, projectHeight);
        haveProjectRaster = true;
        session.addObservation("projectRaster=" + std::to_string(projectWidth) + "x" + std::to_string(projectHeight));
    }
    acfRational32 editRate{};
    if (settings->GetHostSettingRational32(AMA::AMAHostSetting_VideoEditRate,
                                           AMA::IHostSettings::kProjectScope, &editRate) == ACF_OK &&
        editRate.numerator > 0 && editRate.denominator > 0) {
        session.setFrameRate(static_cast<std::uint32_t>(editRate.numerator),
                             static_cast<std::uint32_t>(editRate.denominator));
        session.addObservation("projectEditRate=" + std::to_string(editRate.numerator) +
                               "/" + std::to_string(editRate.denominator));
    }
    acfSInt32 videoFormat = 0;
    if (settings->GetHostSettingSInt32(AMA::AMA_MC_ExportVolumeVideoFormat_ID, AMA::IHostSettings::kProjectScope, &videoFormat) == ACF_OK
        || settings->GetHostSettingSInt32(AMA::AMA_MC_ExportVolumeVideoFormat_ID, AMA::IHostSettings::kGlobalScope, &videoFormat) == ACF_OK) {
        if (!haveProjectRaster &&
            (videoFormat == AMA::AMA_MC_ExportVolumeVideoFormat_1080p || videoFormat == AMA::AMA_MC_ExportVolumeVideoFormat_1080i)) {
            session.setRaster(1920, 1080);
        } else if (!haveProjectRaster && videoFormat == AMA::AMA_MC_ExportVolumeVideoFormat_720p) {
            session.setRaster(1280, 720);
        } else if (!haveProjectRaster && (videoFormat == AMA::AMA_MC_ExportVolumeVideoFormat_625p || videoFormat == AMA::AMA_MC_ExportVolumeVideoFormat_625i)) {
            session.setRaster(720, 576);
        } else if (!haveProjectRaster && (videoFormat == AMA::AMA_MC_ExportVolumeVideoFormat_525p || videoFormat == AMA::AMA_MC_ExportVolumeVideoFormat_525i)) {
            session.setRaster(720, 486);
        }
        session.addObservation("hostVideoFormat=" + std::to_string(videoFormat));
    }
    settings->Release();
}

}  // namespace prores_ama
