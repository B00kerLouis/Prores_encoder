#define INITACFIDS
#include "ProResEncoderAMAIDs.h"
#include "MediaContainerWriter.h"
#include "MediaVolumeWriter.h"

#include <cwchar>
#include <mutex>

namespace {

std::mutex gStartupMutex;
bool gUtilInitialized = false;

}  // namespace

ACFPLUGINAPI ACFRegisterPlugin(IACFUnknown* host, IACFPluginDefinition** definition) {
    try {
        if (!host || !definition) {
            return ACF_E_POINTER;
        }
        *definition = nullptr;
        IACFComponentFactory* factory = nullptr;
        ACFRESULT result = host->QueryInterface(IID_PPV_ARG(IACFComponentFactory, &factory));
        if (ACFFAILED(result)) {
            return result;
        }
        result = factory->CreateComponent(ACFCompID_PluginDefinition, nullptr, IID_PPV_ARG(IACFPluginDefinition, definition));
        factory->Release();
        if (ACFFAILED(result)) {
            return result;
        }
        result = (*definition)->InitializePlugin(
            ProResEncoderAMA_PluginID,
            1,
            0,
            L"ProRes Encoder AMA",
            ProResEncoderAMA_VendorID,
            L"ProRes Encoder",
            2,
            kACFFalse);
        if (ACFSUCCEEDED(result)) {
            const acfWChar* description = L"ProRes Encoder * AMA Writeback Plug-in";
            result = (*definition)->DefineAttribute(
                ACFATTR_Definition_Description,
                ACFTypeID_UnicodeString,
                description,
                static_cast<acfUInt32>((std::wcslen(description) + 1) * sizeof(acfWChar)));
        }
        if (ACFFAILED(result)) {
            (*definition)->Release();
            *definition = nullptr;
        }
        return result;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFPLUGINAPI ACFRegisterComponent(IACFUnknown* host, acfUInt32 index, IACFComponentDefinition** definition) {
    try {
        if (!host || !definition) {
            return ACF_E_POINTER;
        }
        *definition = nullptr;
        if (index > 1) {
            return ACF_E_INVALIDARG;
        }
        IACFComponentFactory* factory = nullptr;
        ACFRESULT result = host->QueryInterface(IID_PPV_ARG(IACFComponentFactory, &factory));
        if (ACFFAILED(result)) {
            return result;
        }
        result = factory->CreateComponent(ACFCompID_ComponentDefinition, nullptr, IID_PPV_ARG(IACFComponentDefinition, definition));
        factory->Release();
        if (ACFFAILED(result)) {
            return result;
        }
        const acfWChar* description = nullptr;
        if (index == 0) {
            result = (*definition)->InitializeComponent(
                ProResEncoderAMA_FileWriterComponentID,
                ACFCompType_AvidMediaAccess,
                1,
                0,
                ProResEncoderAMA_FileWriterCLSID,
                L"ProRes Encoder File");
            description = L"ProRes Encoder * AMA File Writeback Plug-in";
        } else {
            result = (*definition)->InitializeComponent(
                ProResEncoderAMA_VolumeWriterComponentID,
                ACFCompType_AvidMediaAccess,
                1,
                0,
                ProResEncoderAMA_VolumeWriterCLSID,
                L"ProRes Encoder Volume");
            description = L"ProRes Encoder * AMA Volume Writeback Plug-in";
        }
        if (ACFSUCCEEDED(result)) {
            result = (*definition)->DefineAttribute(
                ACFATTR_Definition_Description,
                ACFTypeID_UnicodeString,
                description,
                static_cast<acfUInt32>((std::wcslen(description) + 1) * sizeof(acfWChar)));
        }
        if (ACFFAILED(result)) {
            (*definition)->Release();
            *definition = nullptr;
        }
        return result;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFPLUGINAPI ACFGetClassFactory(IACFUnknown*, const acfCLSID& clsid, const acfIID& iid, void** output) {
    try {
        if (!output) {
            return ACF_E_POINTER;
        }
        *output = nullptr;
        if (clsid == ProResEncoderAMA_FileWriterCLSID) {
            return CACFClassFactory::Create(prores_ama::ProResMediaContainerWriter::ACFCreate, iid, output);
        }
        if (clsid == ProResEncoderAMA_VolumeWriterCLSID) {
            return CACFClassFactory::Create(prores_ama::ProResMediaVolumeWriter::ACFCreate, iid, output);
        }
        return ACF_CLASS_E_CLASSNOTAVAILABLE;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFPLUGINAPI ACFCanUnloadNow(IACFUnknown*) {
    return CACFUnknown::GetActiveObjectCount() == 0 ? ACF_OK : ACF_FALSE;
}

ACFPLUGINAPI ACFStartup(IACFUnknown* host) {
    try {
        if (!host) {
            return ACF_E_POINTER;
        }
        std::lock_guard<std::mutex> lock(gStartupMutex);
        if (gUtilInitialized) {
            return ACF_OK;
        }
        IACFComponentFactory* factory = nullptr;
        const ACFRESULT query = host->QueryInterface(IID_PPV_ARG(IACFComponentFactory, &factory));
        if (ACFFAILED(query)) {
            return query;
        }
        const ACFRESULT result = AMAInitialize(factory);
        factory->Release();
        if (ACFFAILED(result)) {
            return result;
        }
        gUtilInitialized = true;
        return ACF_OK;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFPLUGINAPI ACFShutdown(IACFUnknown*) {
    try {
        std::lock_guard<std::mutex> lock(gStartupMutex);
        if (!gUtilInitialized) {
            return ACF_OK;
        }
        const ACFRESULT result = AMATerminate();
        gUtilInitialized = false;
        return result;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}
