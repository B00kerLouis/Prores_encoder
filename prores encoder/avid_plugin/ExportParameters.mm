#include "ExportParameters.h"

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include "HostAudioRouting.h"
#include "HostExportContext.h"
#include "PluginHooks.h"
#include "ProResEncoderAMAAdapter.h"
#include "ProResEncoderAMAIDs.h"
#include "SampleConsumer.h"
#import "AMAFrameWorkerClient.h"
#include "AMAWorkerProtocol.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <fstream>
#include <sstream>
#include <limits>
#include <cmath>
#include <atomic>
#include <dlfcn.h>
#include <mutex>

@protocol ProResFrameStreamSessionAPI <NSObject>
@property (nonatomic, readonly, copy) NSString* lastErrorMessage;
- (instancetype)initWithOutputURL:(NSURL*)outputURL
                            width:(NSInteger)width
                           height:(NSInteger)height
                    fpsNumerator:(NSInteger)fpsNumerator
                  fpsDenominator:(NSInteger)fpsDenominator
                          quality:(NSString*)quality
               containerExtension:(NSString*)containerExtension
                      bitrateMbps:(double)bitrateMbps
              includeDolbyVision:(BOOL)includeDolbyVision
                 advancedOptions:(NSDictionary*)advancedOptions;
- (BOOL)appendBGRAFrame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendRGBAHalfFrame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendPacked422Frame:(NSData*)frame stride:(NSInteger)stride;
- (BOOL)appendProResFrame:(NSData*)frame sourceCodec:(NSString*)sourceCodec;
- (BOOL)setTimelineAudioFiles:(NSArray*)paths;
- (BOOL)finish;
- (void)cancel;
@end

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

std::string FormatUID(const acfUID& identifier) {
    char buffer[48];
    std::snprintf(
        buffer,
        sizeof(buffer),
        "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",
        identifier.Data1,
        identifier.Data2,
        identifier.Data3,
        identifier.Data4[0], identifier.Data4[1], identifier.Data4[2], identifier.Data4[3],
        identifier.Data4[4], identifier.Data4[5], identifier.Data4[6], identifier.Data4[7]);
    return buffer;
}


std::string UpperASCII(std::string text) {
    for (char& character : text) {
        if (character >= 'a' && character <= 'z') {
            character = static_cast<char>(character - 'a' + 'A');
        }
    }
    return text;
}

void LogText(acfDebugLevel level, const char* message) {
    if (!message) {
        return;
    }
    try {
        AMA::AMAString moduleName(reinterpret_cast<const acfUTF8*>("ProResEncoderAMA"));
        AMA::AMALogger logger(moduleName.InArg());
        logger.Write(level, reinterpret_cast<const acfUTF8*>(message));
    } catch (...) {
    }
}

void TraceHost(const std::string& event) {
    // Use the existing opt-in pipeline trace for release-host negotiation too.
    // An image request can fail before any worker exists to report an error.
    ama_worker::trace("host.%s", event.c_str());
#if DEBUG
    std::ofstream trace("/tmp/ProResAMA-HostTrace-20260924.log", std::ios::app);
    trace << event << '\n';
#else
    (void)event;
#endif
}

Class LoadFrameStreamClass(std::string* errorOut) {
    static std::mutex loadMutex;
    std::lock_guard<std::mutex> lock(loadMutex);
    Dl_info imageInfo{};
    if (!dladdr(reinterpret_cast<const void*>(&LoadFrameStreamClass), &imageInfo) || !imageInfo.dli_fname) {
        if (errorOut) *errorOut = "The AMA plug-in bundle path is unavailable.";
        return Nil;
    }
    NSString* executable = [NSString stringWithUTF8String:imageInfo.dli_fname];
    NSString* contents = [[executable stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString* frameworkPath = [[contents stringByAppendingPathComponent:@"Frameworks"]
        stringByAppendingPathComponent:@"ProResEncoderFramework.framework"];
    NSBundle* framework = [NSBundle bundleWithPath:frameworkPath];
    // MC ships its own C++ runtime. Keep encoder symbols local so loading the
    // framework cannot participate in the host's global C++ symbol lookup.
    // Objective-C class registration still exposes the intended frame facade.
    static void* frameworkHandle = nullptr;
    if (!frameworkHandle && framework.executablePath) {
        frameworkHandle = dlopen(framework.executablePath.fileSystemRepresentation,
            RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    }
    if (!frameworkHandle) {
        if (errorOut) {
            const char* reason = dlerror();
            *errorOut = reason ? reason : "The embedded encoder framework could not be loaded locally.";
        }
        return Nil;
    }
    Class streamClass = NSClassFromString(@"ProResFrameStreamSession");
    if (!streamClass && errorOut) {
        *errorOut = "The embedded framework did not expose ProResFrameStreamSession.";
    } else if (streamClass && ![[NSBundle bundleForClass:streamClass].bundlePath isEqualToString:framework.bundlePath]) {
        if (errorOut) *errorOut = "Another framework registered the ProResFrameStreamSession class.";
        return Nil;
    }
    return streamClass;
}

ACFRESULT MakeTypedValue(IACFComponentFactory* factory, const acfUID& typeID,
                         const void* data, acfUInt32 size, IACFValue** valueOut) {
    if (!factory || !valueOut) {
        return ACF_E_POINTER;
    }
    *valueOut = nullptr;
    IACFTypeDefinition* definition = nullptr;
    ACFRESULT result = factory->FindDefinition(
        typeID,
        IID_IACFTypeDefinition,
        reinterpret_cast<IACFDefinition**>(&definition));
    if (ACFFAILED(result) || !definition) {
        return ACFFAILED(result) ? result : ACF_E_UNKNOWNDEFINITION;
    }
    result = definition->CreateValue(valueOut);
    definition->Release();
    if (ACFFAILED(result) || !*valueOut) {
        return ACFFAILED(result) ? result : ACF_E_UNEXPECTED;
    }
    result = (*valueOut)->InitializeValue(typeID, data, size, kACFFalse);
    if (ACFFAILED(result)) {
        (*valueOut)->Release();
        *valueOut = nullptr;
    }
    return result;
}

ACFRESULT MakeUInt32Value(IACFComponentFactory* factory, acfUInt32 value, IACFValue** valueOut) {
    return MakeTypedValue(factory, ACFTypeID_UInt32, &value, sizeof(value), valueOut);
}

ACFRESULT MakeDoubleValue(IACFComponentFactory* factory, double value, IACFValue** valueOut) {
    return MakeTypedValue(factory, ACFTypeID_Double, &value, sizeof(value), valueOut);
}

ACFRESULT MakeStringValue(IACFComponentFactory* factory, const std::string& value, IACFValue** valueOut) {
    if (!factory || !valueOut) {
        return ACF_E_POINTER;
    }
    if (value.size() > 4095) {
        return ACF_E_INVALIDARG;
    }
    return MakeTypedValue(factory, ACFTypeID_UTF8String, value.c_str(),
                          static_cast<acfUInt32>(value.size() + 1), valueOut);
}

bool ReadUInt32Parameter(const std::string& xml, const acfUID& parameterID, std::uint32_t* valueOut) {
    if (!valueOut) {
        return false;
    }
    const std::string xmlUpper = UpperASCII(xml);
    const std::string idUpper = UpperASCII(FormatUID(parameterID));
    std::size_t searchFrom = 0;
    while (true) {
        const std::size_t idPosition = xmlUpper.find(idUpper, searchFrom);
        if (idPosition == std::string::npos) {
            return false;
        }
        const std::size_t parameterEnd = xmlUpper.find("</PARAMETER>", idPosition);
        if (parameterEnd == std::string::npos) {
            return false;
        }
        const std::size_t valuePosition = xmlUpper.find("<VALUEUINT32>", idPosition);
        if (valuePosition != std::string::npos && valuePosition < parameterEnd) {
            const std::size_t digits = valuePosition + std::strlen("<VALUEUINT32>");
            char* end = nullptr;
            const unsigned long parsed = std::strtoul(xml.c_str() + digits, &end, 10);
            const std::size_t closing = xmlUpper.find("</VALUEUINT32>", digits);
            if (end == xml.c_str() + digits || closing == std::string::npos || closing > parameterEnd ||
                static_cast<std::size_t>(end - xml.c_str()) != closing || parsed > std::numeric_limits<std::uint32_t>::max()) {
                return false;
            }
            *valueOut = static_cast<std::uint32_t>(parsed);
            return true;
        }
        searchFrom = parameterEnd + std::strlen("</PARAMETER>");
    }
}

bool ReadDoubleParameter(const std::string& xml, const acfUID& parameterID, double* valueOut) {
    if (!valueOut) {
        return false;
    }
    const std::string xmlUpper = UpperASCII(xml);
    const std::string idUpper = UpperASCII(FormatUID(parameterID));
    std::size_t searchFrom = 0;
    while (true) {
        const std::size_t idPosition = xmlUpper.find(idUpper, searchFrom);
        if (idPosition == std::string::npos) {
            return false;
        }
        const std::size_t parameterEnd = xmlUpper.find("</PARAMETER>", idPosition);
        if (parameterEnd == std::string::npos) {
            return false;
        }
        const std::size_t valuePosition = xmlUpper.find("<VALUEDOUBLE>", idPosition);
        if (valuePosition != std::string::npos && valuePosition < parameterEnd) {
            const std::size_t digits = valuePosition + std::strlen("<VALUEDOUBLE>");
            char* end = nullptr;
            const double parsed = std::strtod(xml.c_str() + digits, &end);
            const std::size_t closing = xmlUpper.find("</VALUEDOUBLE>", digits);
            if (end == xml.c_str() + digits || closing == std::string::npos || closing > parameterEnd ||
                static_cast<std::size_t>(end - xml.c_str()) != closing || !std::isfinite(parsed)) {
                return false;
            }
            *valueOut = parsed;
            return true;
        }
        searchFrom = parameterEnd + std::strlen("</PARAMETER>");
    }
}

bool ReadStringParameter(const std::string& xml, const acfUID& parameterID, std::string* valueOut) {
    if (!valueOut || xml.size() > 1024 * 1024) {
        return false;
    }
    @autoreleasepool {
        NSString* input = [NSString stringWithUTF8String:xml.c_str()];
        if (!input) {
            return false;
        }
        NSError* error = nil;
        NSXMLDocument* document = [[NSXMLDocument alloc] initWithXMLString:input options:0 error:&error];
        if (!document) {
            return false;
        }
        NSArray* parameters = [document nodesForXPath:@"//parameterSet/parameter" error:&error];
        NSString* wanted = [NSString stringWithUTF8String:FormatUID(parameterID).c_str()];
        for (NSXMLElement* parameter in parameters) {
            NSString* identifier = [[parameter attributeForName:@"id"] stringValue];
            if ([identifier caseInsensitiveCompare:wanted] != NSOrderedSame) {
                continue;
            }
            NSArray* values = [parameter elementsForName:@"valueString"];
            if (values.count != 1) {
                continue;
            }
            NSString* stringValue = [values.firstObject stringValue];
            const char* utf8 = stringValue.UTF8String;
            if (!utf8 || std::strlen(utf8) > 4095) {
                [document release];
                return false;
            }
            *valueOut = utf8;
            [document release];
            return true;
        }
        [document release];
        return false;
    }
}

ACFRESULT AddDiscreteParameter(
    AMA::IParametersWriter* writer,
    const acfUID& parameterID,
    const char* name,
    const char* description,
    const char* const* choices,
    acfUInt32 choiceCount,
    acfUInt32 selected) {
    AMA::AMAString shortName(reinterpret_cast<const acfUTF8*>(name));
    AMA::AMAString longName(reinterpret_cast<const acfUTF8*>(description));
    AMA::AMAString unit(reinterpret_cast<const acfUTF8*>(""));
    ACFRESULT result = writer->AddParameterInfo(parameterID, shortName.InArg(), longName.InArg(), unit.InArg(), AMA::AMATypeID_Discrete);
    if (ACFFAILED(result)) {
        return result;
    }
    for (acfUInt32 index = 0; index < choiceCount; ++index) {
        AMA::AMAString choice(reinterpret_cast<const acfUTF8*>(choices[index]));
        result = writer->AddParameterInfoValueDiscrete(choice.InArg(), index, index == selected ? kACFTrue : kACFFalse);
        if (ACFFAILED(result)) {
            return result;
        }
    }
    return ACF_OK;
}

ACFRESULT AddDiscreteVisibilityRule(
    AMA::IParametersWriter* writer, IACFComponentFactory* factory,
    acfUInt32 whenValue, const acfUID& target, bool visible) {
    IACFValue* condition = nullptr;
    ACFRESULT result = MakeUInt32Value(factory, whenValue, &condition);
    if (ACFFAILED(result)) {
        return result;
    }
    result = writer->AddParameterInfoDisplayRule(
        visible ? AMA::IParametersWriter::kShow : AMA::IParametersWriter::kHide,
        &target,
        condition,
        AMA::IParametersWriter::kAlways);
    condition->Release();
    return result;
}

ACFRESULT AddCodecVisibilityRules(AMA::IParametersWriter* writer, IACFComponentFactory* factory) {
    for (acfUInt32 codec = 0; codec <= static_cast<acfUInt32>(CodecChoice::H264); ++codec) {
        const bool compressed = codec >= static_cast<acfUInt32>(CodecChoice::HEVC);
        const bool dolby = codec != static_cast<acfUInt32>(CodecChoice::H264);
        const bool profile = codec == static_cast<acfUInt32>(CodecChoice::HEVC) ||
                             codec == static_cast<acfUInt32>(CodecChoice::AV1);
        const bool videoToolboxGOP = codec == static_cast<acfUInt32>(CodecChoice::HEVC) ||
                                     codec == static_cast<acfUInt32>(CodecChoice::H264);
        const struct { const acfUID& target; bool visible; } rules[] = {
            {ProResEncoderAMA_BitrateParameterID, compressed},
            {ProResEncoderAMA_DolbyParameterID, dolby},
            {ProResEncoderAMA_CMUMasteringNitsParameterID, dolby},
            {ProResEncoderAMA_DolbyProfileParameterID, profile},
            {ProResEncoderAMA_DolbyCodecTagParameterID, profile},
            {ProResEncoderAMA_MultiPassParameterID, videoToolboxGOP},
            {ProResEncoderAMA_BFramesParameterID, videoToolboxGOP}
        };
        for (const auto& rule : rules) {
            const ACFRESULT result = AddDiscreteVisibilityRule(writer, factory, codec, rule.target, rule.visible);
            if (ACFFAILED(result)) {
                return result;
            }
        }
    }
    return ACF_OK;
}

ACFRESULT AddContainerVisibilityRules(AMA::IParametersWriter* writer, IACFComponentFactory* factory) {
    for (acfUInt32 container = 0; container <= static_cast<acfUInt32>(ContainerChoice::MKV); ++container) {
        const bool mxf = container == static_cast<acfUInt32>(ContainerChoice::MXFOP1a) || container == static_cast<acfUInt32>(ContainerChoice::MXFOPAtom);
        const bool mov = container == static_cast<acfUInt32>(ContainerChoice::MOV);
        const struct { const acfUID& target; bool visible; } rules[] = {
            {ProResEncoderAMA_StartTimecodeParameterID, mov},
            {ProResEncoderAMA_DolbyXMLPathParameterID, !mxf},
            {ProResEncoderAMA_IncludeGeneratedDVParameterID, !mxf},
            {ProResEncoderAMA_AudioChannelsPerMXFFileParameterID, mxf},
            {ProResEncoderAMA_AAFModeParameterID, mxf}
        };
        for (const auto& rule : rules) {
            const ACFRESULT result = AddDiscreteVisibilityRule(writer, factory, container, rule.target, rule.visible);
            if (ACFFAILED(result)) {
                return result;
            }
        }
    }
    return ACF_OK;
}

ACFRESULT AddTextParameter(
    AMA::IParametersWriter* writer,
    const acfUID& parameterID,
    const char* name,
    const char* description,
    bool filePath) {
    AMA::AMAString shortName(reinterpret_cast<const acfUTF8*>(name));
    AMA::AMAString longName(reinterpret_cast<const acfUTF8*>(description));
    AMA::AMAString unit(reinterpret_cast<const acfUTF8*>(""));
    return writer->AddParameterInfo(
        parameterID,
        shortName.InArg(),
        longName.InArg(),
        unit.InArg(),
        filePath ? AMA::AMATypeID_FilePath : ACFTypeID_UTF8String);
}

ACFRESULT AddDoubleParameter(
    AMA::IParametersWriter* writer, IACFComponentFactory* factory,
    const acfUID& parameterID, const char* name, const char* description,
    double defaultValue, double minimum, double maximum) {
    AMA::AMAString shortName(reinterpret_cast<const acfUTF8*>(name));
    AMA::AMAString longName(reinterpret_cast<const acfUTF8*>(description));
    AMA::AMAString unit(reinterpret_cast<const acfUTF8*>(""));
    ACFRESULT result = writer->AddParameterInfo(parameterID, shortName.InArg(), longName.InArg(), unit.InArg(), ACFTypeID_Double);
    if (ACFFAILED(result)) return result;
    IACFValue* values[3] = {nullptr, nullptr, nullptr};
    const double numbers[3] = {defaultValue, minimum, maximum};
    for (int index = 0; index < 3 && ACFSUCCEEDED(result); ++index) {
        result = MakeDoubleValue(factory, numbers[index], &values[index]);
    }
    if (ACFSUCCEEDED(result)) {
        result = writer->AddParameterInfoValueConstraints(values[0], values[1], values[2]);
    }
    for (IACFValue* value : values) {
        if (value) value->Release();
    }
    return result;
}

ACFRESULT AddUInt32Parameter(
    AMA::IParametersWriter* writer, IACFComponentFactory* factory,
    const acfUID& parameterID, const char* name, const char* description,
    std::uint32_t defaultValue, std::uint32_t minimum, std::uint32_t maximum) {
    AMA::AMAString shortName(reinterpret_cast<const acfUTF8*>(name));
    AMA::AMAString longName(reinterpret_cast<const acfUTF8*>(description));
    AMA::AMAString unit(reinterpret_cast<const acfUTF8*>(""));
    ACFRESULT result = writer->AddParameterInfo(parameterID, shortName.InArg(), longName.InArg(), unit.InArg(), ACFTypeID_UInt32);
    if (ACFFAILED(result)) return result;
    IACFValue* values[3] = {nullptr, nullptr, nullptr};
    const std::uint32_t numbers[3] = {defaultValue, minimum, maximum};
    for (int index = 0; index < 3 && ACFSUCCEEDED(result); ++index) {
        result = MakeUInt32Value(factory, numbers[index], &values[index]);
    }
    if (ACFSUCCEEDED(result)) {
        result = writer->AddParameterInfoValueConstraints(values[0], values[1], values[2]);
    }
    for (IACFValue* value : values) {
        if (value) value->Release();
    }
    return result;
}

ACFRESULT BuildParameterXML(IACFComponentFactory* factory, const ExportSession& session, const acfUID& componentID, bool includeInfos, IACFString** xmlOut) {
    if (!factory || !xmlOut) {
        return ACF_E_POINTER;
    }
    *xmlOut = nullptr;
    AMA::IParametersWriter* writer = nullptr;
    std::string stage = "CreateParametersWriter";
    ACFRESULT result = factory->CreateComponent(
        AMA::Impl::CompID_ParametersWriter,
        nullptr,
        NS_IID_PPV_ARG(AMA, IParametersWriter, &writer));
    if (ACFFAILED(result) || !writer) {
#if DEBUG
        std::ofstream debug("/tmp/ProResAMA-XML-debug-20260924.log", std::ios::app);
        debug << stage << " result=0x" << std::hex << static_cast<unsigned int>(result) << '\n';
#endif
        return ACFFAILED(result) ? result : ACF_E_UNEXPECTED;
    }

    stage = "StartParametersXML";
    result = writer->StartParametersXML(componentID, 1.0f);
    if (ACFSUCCEEDED(result)) {
        stage = "StartTrack";
        result = writer->StartTrack(0);
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "StartParameterInfos";
        result = writer->StartParameterInfos(1.0f);
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "StartParameterGroup";
        AMA::AMAString groupName(reinterpret_cast<const acfUTF8*>("ProRes Encoder export options"));
        AMA::AMAString groupDescription(reinterpret_cast<const acfUTF8*>("Codec, container, color, metadata, audio, and advanced output"));
        result = writer->StartParameterGroup(
            ProResEncoderAMA_ParameterGroupID,
            groupName.InArg(),
            groupDescription.InArg(),
            AMA::IParametersWriter::kExpanded);
    }

    const char* codecs[] = {
        "ProRes Proxy", "ProRes 422 LT", "ProRes 422", "ProRes 422 HQ",
        "ProRes 4444", "ProRes 4444 XQ", "HEVC", "AV1", "H.264"
    };
    const char* containers[] = {"MOV", "MP4", "MXF OP-1a", "MXF OP-Atom", "MKV"};
    const char* dolby[] = {"Off", "Generate from rendered frames", "External XML"};
    const char* audio[] = {"Bounce Mix", "Bounce Multitrack"};
    const AdvancedOptions advanced = session.advancedOptions();
    const char* yesNo[] = {"Off", "On"};
    const char* dolbyProfiles[] = {"None", "Profile 5", "Profile 7.6", "Profile 8.1", "Profile 8.4", "Profile 10", "Profile 10.1", "Profile 10.4"};
    const char* inputColors[] = {"Unspecified", "Rec.709 / Gamma 2.4", "Rec.2020 / PQ", "Rec.2020 / HLG", "P3-D65 / PQ"};
    const char* colorModes[] = {"Off", "Direct conversion", "LUT burn-in"};
    const char* gamuts[] = {"Rec.709", "Rec.2020", "Rec.2020 limited to P3-D65", "P3-D65"};
    const char* transfers[] = {"Gamma 2.4", "Gamma 2.6", "PQ", "HLG"};
    const char* triState[] = {"Encoder default", "On", "Off"};
    const char* aafModes[] = {"None", "Sequence", "Per clip"};
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Codec";
        result = AddDiscreteParameter(writer, ProResEncoderAMA_CodecParameterID, "Codec", "Video codec", codecs, 9, static_cast<acfUInt32>(session.codec()));
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Codec visibility rules";
        result = AddCodecVisibilityRules(writer, factory);
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Container";
        result = AddDiscreteParameter(writer, ProResEncoderAMA_ContainerParameterID, "Container", "Output container", containers, 5, static_cast<acfUInt32>(session.container()));
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Container visibility rules";
        result = AddContainerVisibilityRules(writer, factory);
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Dolby Vision";
        result = AddDiscreteParameter(writer, ProResEncoderAMA_DolbyParameterID, "Dolby Vision", "Metadata source. H.264 Dolby Vision is rejected.", dolby, 3, static_cast<acfUInt32>(session.dolby()));
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Audio";
        result = AddDiscreteParameter(writer, ProResEncoderAMA_AudioParameterID, "Audio", "Host mix or direct-out routing", audio, 2, static_cast<acfUInt32>(session.audioRoute()));
    }
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Compressed video bitrate";
        result = AddDoubleParameter(writer, factory, ProResEncoderAMA_BitrateParameterID,
                                    "Compressed video bitrate (Mb/s)", "Used by H.264, HEVC, and AV1", session.bitrateMbps(), 0.001, 10000);
    }
    auto addChoiceInfo = [&](const acfUID& id, const char* name, const char* description,
                             const char* const* choices, acfUInt32 count, acfUInt32 selected) {
        if (includeInfos && ACFSUCCEEDED(result)) {
            stage = name;
            result = AddDiscreteParameter(writer, id, name, description, choices, count, selected);
        }
    };
    auto addTextInfo = [&](const acfUID& id, const char* name, const char* description, bool filePath) {
        if (includeInfos && ACFSUCCEEDED(result)) {
            stage = name;
            result = AddTextParameter(writer, id, name, description, filePath);
        }
    };
    addTextInfo(ProResEncoderAMA_ExtraAudioPathParameterID, "Extra audio file", "Optional audio file accepted by the encoder", true);
    addChoiceInfo(ProResEncoderAMA_ReplaceSourceAudioParameterID, "Replace source audio", "Use the extra audio file instead of source audio", yesNo, 2, advanced.replaceSourceAudio);
    addChoiceInfo(ProResEncoderAMA_DeleteSourceAudioParameterID, "Delete source audio", "Remove source audio from the output", yesNo, 2, advanced.deleteSourceAudio);
    addTextInfo(ProResEncoderAMA_StartTimecodeParameterID, "Start timecode", "MOV output start timecode", false);
    addTextInfo(ProResEncoderAMA_DolbyXMLPathParameterID, "Dolby Vision XML", "External Dolby Vision metadata file", true);
    addChoiceInfo(ProResEncoderAMA_DolbyProfileParameterID, "Dolby Vision profile", "Profile supported by the selected video codec", dolbyProfiles, 8, advanced.dolbyProfile);
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "MXF audio channels per file";
        result = AddUInt32Parameter(writer, factory, ProResEncoderAMA_AudioChannelsPerMXFFileParameterID,
                                    "MXF audio channels per file", "Audio grouping for OP-Atom MXF",
                                    advanced.audioChannelsPerMXFFile, 1, 64);
    }
    addChoiceInfo(ProResEncoderAMA_InputColorParameterID, "Rendered input color",
        "Explicit declaration of the rendered frame color; match the project output", inputColors, 5, advanced.inputColor);
    addChoiceInfo(ProResEncoderAMA_ColorModeParameterID, "Color conversion", "Off, direct transform, or LUT burn-in", colorModes, 3, advanced.colorMode);
    addChoiceInfo(ProResEncoderAMA_ColorGamutParameterID, "Output gamut", "Target gamut for color conversion", gamuts, 4, advanced.colorGamut);
    addChoiceInfo(ProResEncoderAMA_ColorTransferParameterID, "Output transfer", "Target transfer for color conversion", transfers, 4, advanced.colorTransfer);
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "Output peak";
        result = AddDoubleParameter(writer, factory, ProResEncoderAMA_ColorPeakNitsParameterID,
                                    "Output peak (nits)", "Target peak luminance", advanced.colorPeakNits, 1, 10000);
    }
    addTextInfo(ProResEncoderAMA_LUTPathParameterID, "LUT file", "LUT file for burn-in color conversion", true);
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "CMU mastering peak";
        result = AddDoubleParameter(writer, factory, ProResEncoderAMA_CMUMasteringNitsParameterID,
                                    "CMU mastering peak (nits)", "Zero disables CMU analysis", advanced.cmuMasteringNits, 0, 10000);
    }
    addChoiceInfo(ProResEncoderAMA_IncludeGeneratedDVParameterID, "Embed generated Dolby Vision", "Use generated CMU metadata in the output", yesNo, 2, advanced.includeGeneratedDolbyVisionMetadata);
    addChoiceInfo(ProResEncoderAMA_DolbyCodecTagParameterID, "Dolby Vision codec tag", "Use a Dolby Vision sample entry where supported", yesNo, 2, advanced.useDolbyVisionCodecTag);
    addChoiceInfo(ProResEncoderAMA_OutputVideoRawParameterID, "Raw video beside container", "Also write an elementary video stream", yesNo, 2, advanced.outputVideoRaw);
    addChoiceInfo(ProResEncoderAMA_MultiPassParameterID, "Multi-pass", "Encoder default uses live single-pass for generated Rec.709 Profile 5; On retains multi-pass replay", triState, 3, advanced.multiPass);
    addChoiceInfo(ProResEncoderAMA_BFramesParameterID, "B-frames", "H.264 or HEVC B-frame reordering", triState, 3, advanced.bFrames);
    addChoiceInfo(ProResEncoderAMA_AAFModeParameterID, "AAF output", "AAF mode for MXF output", aafModes, 3, advanced.aafMode);
    if (includeInfos && ACFSUCCEEDED(result)) {
        stage = "EndParameterGroup";
        result = writer->EndParameterGroup();
    }

    AMA::AMAString presetName(reinterpret_cast<const acfUTF8*>("Current"));
    if (ACFSUCCEEDED(result)) {
        stage = "StartParameterSet";
        result = writer->StartParameterSet(ProResEncoderAMA_DefaultPresetID, presetName.InArg(), 1.0f, kACFTrue, kACFFalse);
    }
    auto addValue = [&](const acfUID& parameterID, std::uint32_t value) {
        if (ACFFAILED(result)) {
            return;
        }
        stage = "AddUInt32Value " + FormatUID(parameterID);
        IACFValue* stored = nullptr;
        result = MakeUInt32Value(factory, value, &stored);
        if (ACFSUCCEEDED(result) && stored) {
            result = writer->AddParameterValue(parameterID, stored);
            stored->Release();
        }
    };
    addValue(ProResEncoderAMA_CodecParameterID, static_cast<std::uint32_t>(session.codec()));
    addValue(ProResEncoderAMA_ContainerParameterID, static_cast<std::uint32_t>(session.container()));
    addValue(ProResEncoderAMA_DolbyParameterID, static_cast<std::uint32_t>(session.dolby()));
    addValue(ProResEncoderAMA_AudioParameterID, static_cast<std::uint32_t>(session.audioRoute()));
    auto addDoubleValue = [&](const acfUID& parameterID, double value) {
        if (ACFFAILED(result)) {
            return;
        }
        stage = "AddDoubleValue " + FormatUID(parameterID);
        IACFValue* stored = nullptr;
        result = MakeDoubleValue(factory, value, &stored);
        if (ACFSUCCEEDED(result) && stored) {
            result = writer->AddParameterValue(parameterID, stored);
            stored->Release();
        }
    };
    addDoubleValue(ProResEncoderAMA_BitrateParameterID, session.bitrateMbps());
    auto addStringValue = [&](const acfUID& parameterID, const std::string& value) {
        if (ACFFAILED(result) || value.empty()) {
            return;
        }
        stage = "AddStringValue " + FormatUID(parameterID);
        IACFValue* stored = nullptr;
        result = MakeStringValue(factory, value, &stored);
        if (ACFSUCCEEDED(result) && stored) {
            result = writer->AddParameterValue(parameterID, stored);
            stored->Release();
        }
    };
    addStringValue(ProResEncoderAMA_ExtraAudioPathParameterID, advanced.extraAudioPath);
    addValue(ProResEncoderAMA_ReplaceSourceAudioParameterID, advanced.replaceSourceAudio);
    addValue(ProResEncoderAMA_DeleteSourceAudioParameterID, advanced.deleteSourceAudio);
    addStringValue(ProResEncoderAMA_StartTimecodeParameterID, advanced.forcedStartTimecode);
    addStringValue(ProResEncoderAMA_DolbyXMLPathParameterID, advanced.dolbyVisionXMLPath);
    addValue(ProResEncoderAMA_DolbyProfileParameterID, advanced.dolbyProfile);
    addValue(ProResEncoderAMA_AudioChannelsPerMXFFileParameterID, advanced.audioChannelsPerMXFFile);
    addValue(ProResEncoderAMA_InputColorParameterID, advanced.inputColor);
    addValue(ProResEncoderAMA_ColorModeParameterID, advanced.colorMode);
    addValue(ProResEncoderAMA_ColorGamutParameterID, advanced.colorGamut);
    addValue(ProResEncoderAMA_ColorTransferParameterID, advanced.colorTransfer);
    addDoubleValue(ProResEncoderAMA_ColorPeakNitsParameterID, advanced.colorPeakNits);
    addStringValue(ProResEncoderAMA_LUTPathParameterID, advanced.lutPath);
    addDoubleValue(ProResEncoderAMA_CMUMasteringNitsParameterID, advanced.cmuMasteringNits);
    addValue(ProResEncoderAMA_IncludeGeneratedDVParameterID, advanced.includeGeneratedDolbyVisionMetadata);
    addValue(ProResEncoderAMA_DolbyCodecTagParameterID, advanced.useDolbyVisionCodecTag);
    addValue(ProResEncoderAMA_OutputVideoRawParameterID, advanced.outputVideoRaw);
    addValue(ProResEncoderAMA_MultiPassParameterID, advanced.multiPass);
    addValue(ProResEncoderAMA_BFramesParameterID, advanced.bFrames);
    addValue(ProResEncoderAMA_AAFModeParameterID, advanced.aafMode);
    if (ACFSUCCEEDED(result)) {
        stage = "FinishParametersXML";
        result = writer->FinishParametersXML(xmlOut);
    }
#if DEBUG
    {
        std::ofstream debug("/tmp/ProResAMA-XML-debug-20260924.log", std::ios::app);
        debug << (includeInfos ? "infos " : "values ") << stage << " result=0x"
              << std::hex << static_cast<unsigned int>(result) << '\n';
        if (ACFSUCCEEDED(result) && xmlOut && *xmlOut) {
            AMA::AMAString text(kACFUTF8, *xmlOut);
            const acfUTF8* utf8 = text.GetUTF8String();
            if (utf8) {
                std::ofstream xmlFile(includeInfos
                    ? "/tmp/ProResAMA-ParameterInfos-debug-20260924.xml"
                    : "/tmp/ProResAMA-Values-debug-20260924.xml", std::ios::binary);
                xmlFile << reinterpret_cast<const char*>(utf8);
            }
        }
    }
#endif
    if (ACFFAILED(result)) {
        char message[96];
        std::snprintf(message, sizeof(message), "AMA parameter XML generation failed: 0x%08X", static_cast<unsigned int>(result));
        LogText(kACFDebugLevel_Error, message);
    }
    writer->Release();
    return result;
}

}  // namespace

ACFRESULT CopyPluginString(const char* utf8, IACFString** stringOut) {
    if (!stringOut) {
        return ACF_E_POINTER;
    }
    *stringOut = nullptr;
    try {
        AMA::AMAString text(reinterpret_cast<const acfUTF8*>(utf8 ? utf8 : ""));
        IACFString* raw = text.InArg();
        if (!raw) {
            return ACF_E_UNEXPECTED;
        }
        raw->AddRef();
        *stringOut = raw;
        return ACF_OK;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

struct FrameBridge {
    // AMA can enter consumers concurrently. Serialize initialization, mapping,
    // append and finish, while allowing cancellation to interrupt an RPC wait.
    std::mutex processing;
    std::mutex streamOwnership;
    std::atomic<bool> cancelled{false};
    id<ProResFrameStreamSessionAPI> stream = nil;
    std::uint64_t deliveredFrames = 0;
    std::uint32_t audioSampleRate = 0;
    std::uint32_t audioBitDepth = 0;
    struct AudioTrack {
        AudioFileID file = nullptr;
        std::string path;
        std::uint32_t channels = 0;
        std::uint64_t endSample = 0;
    };
    std::map<std::uint32_t, AudioTrack> audioTracks;

    void clearAudio() {
        for (auto& item : audioTracks) {
            if (item.second.file) AudioFileClose(item.second.file);
            if (!item.second.path.empty()) unlink(item.second.path.c_str());
        }
        audioTracks.clear();
    }

    ACFRESULT appendAudio(const std::shared_ptr<ExportSession>& session, std::uint32_t track,
        std::uint64_t sample, std::uint64_t count, const std::uint8_t* bytes, std::size_t size) {
        std::lock_guard<std::mutex> operation(processing);
        if (cancelled.load()) return ACF_E_ABORT;
        const auto options = session->advancedOptions();
        if (options.deleteSourceAudio || options.replaceSourceAudio) return ACF_OK;
        const auto reject = [&](const char* message) { session->failWrite(message); return ACF_E_FAIL; };
        const std::uint32_t word = audioBitDepth / 8;
        if (!bytes || !size || !count || !audioSampleRate || !word || count > UINT64_MAX / word ||
            size % (count * word) != 0 || size / (count * word) == 0 || size / (count * word) > 64 || track > 64)
            return reject("The host PCM buffer does not match the negotiated rate, bit depth or sample range.");
        const auto channels = static_cast<std::uint32_t>(size / (count * word));
        auto& audio = audioTracks[track];
        if (!audio.file) {
            audio.channels = channels;
            NSString* directory = [[NSString stringWithUTF8String:session->outputPath().c_str()] stringByDeletingLastPathComponent];
            NSString* path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".ama-host-audio-%@-%u.caf", NSUUID.UUID.UUIDString, track]];
            audio.path = path.UTF8String;
            AudioStreamBasicDescription format{};
            format.mSampleRate = audioSampleRate;
            format.mFormatID = kAudioFormatLinearPCM;
            format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            format.mBytesPerPacket = format.mBytesPerFrame = channels * word;
            format.mFramesPerPacket = 1;
            format.mChannelsPerFrame = channels;
            format.mBitsPerChannel = audioBitDepth;
            if (AudioFileCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path], kAudioFileCAFType, &format, 0, &audio.file) != noErr)
                return reject("The host PCM transaction could not be created on the output volume.");
            ama_worker::trace("audio.open track=%u rate=%u bits=%u channels=%u", track, audioSampleRate, audioBitDepth, channels);
        }
        if (channels != audio.channels || sample < audio.endSample || sample > INT64_MAX / (channels * word) ||
            count > UINT64_MAX - sample || size > UINT32_MAX)
            return reject("The host changed PCM layout or supplied overlapping audio ranges.");
        // Missing sample ranges represent timeline silence, never concatenation.
        std::uint8_t zeros[65536]{};
        auto offset = audio.endSample * channels * word;
        const auto target = sample * channels * word;
        while (offset < target) {
            if (cancelled.load()) return ACF_E_ABORT;
            UInt32 chunk = static_cast<UInt32>(std::min<std::uint64_t>(sizeof(zeros), target - offset));
            if (AudioFileWriteBytes(audio.file, false, offset, &chunk, zeros) != noErr || !chunk)
                return reject("The host PCM silence range could not be written.");
            offset += chunk;
        }
        UInt32 written = static_cast<UInt32>(size);
        if (AudioFileWriteBytes(audio.file, false, target, &written, bytes) != noErr || written != size)
            return reject("The host PCM sample range could not be written.");
        audio.endSample = sample + count;
        ama_worker::trace("audio.append track=%u sample=%llu count=%llu bytes=%zu", track,
            (unsigned long long)sample, (unsigned long long)count, size);
        return ACF_OK;
    }

    ~FrameBridge() {
        cancel();
    }

    ACFRESULT appendBGRA(const std::shared_ptr<ExportSession>& session, const std::uint8_t* bytes, std::size_t size) {
        ama_worker::trace("bridge.wait object=%p bytes=%zu", this, size);
        std::lock_guard<std::mutex> operation(processing);
        if (cancelled.load()) return ACF_E_ABORT;
        if (!session || !bytes || size == 0) {
            return ACF_E_INVALIDARG;
        }
        std::uint32_t width = session->rasterWidth();
        std::uint32_t height = session->rasterHeight();
        std::size_t stride = static_cast<std::size_t>(width) * 4;
        const bool compressedProRes = size >= 8 && std::memcmp(bytes + 4, "icpf", 4) == 0;
#if DEBUG
        static std::atomic<unsigned int> seenFrames{0};
        const unsigned int callIndex = seenFrames.fetch_add(1);
        if (callIndex < 20 || callIndex % 1000 == 0) {
            TraceHost("FrameBridge frame=" + std::to_string(callIndex) +
                      " bytes=" + std::to_string(size) +
                      " raster=" + std::to_string(width) + "x" + std::to_string(height));
        }
#endif
        bool validRaster = compressedProRes || (width > 0 && height > 0 &&
            stride <= std::numeric_limits<std::size_t>::max() / height &&
            size == stride * height);
        if (!compressedProRes && !validRaster && width > 0 && height > 0 && size % height == 0) {
            const std::size_t deliveredStride = size / height;
            if (deliveredStride >= stride && deliveredStride <= stride + 4096) {
                stride = deliveredStride;
                validRaster = true;
            }
        }
        if (!validRaster) {
            const std::pair<std::uint32_t, std::uint32_t> known[] = {
                {1920, 1080}, {3840, 2160}, {1280, 720}, {720, 576}, {720, 486}, {320, 180}
            };
            for (const auto& raster : known) {
                if (size == static_cast<std::size_t>(raster.first) * raster.second * 4) {
                    width = raster.first;
                    height = raster.second;
                    stride = static_cast<std::size_t>(width) * 4;
                    session->setRaster(width, height);
                    validRaster = true;
                    break;
                }
            }
            if (!validRaster) {
#if DEBUG
                if (callIndex < 20 || callIndex % 1000 == 0) {
                    TraceHost("FrameBridge rejected buffer: no valid BGRA row stride");
                }
#endif
                session->failWrite("The host picture buffer does not match the project raster or a valid BGRA row stride.");
                return ACF_E_INVALIDARG;
            }
        }
        if (!compressedProRes && access("/tmp/ProResAMA-capture-water", F_OK) == 0 &&
            (deliveredFrames == 240 || deliveredFrames == 500 || deliveredFrames == 1000 || deliveredFrames == 1800)) {
            @autoreleasepool {
                NSString* file = [NSString stringWithUTF8String:session->outputPath().c_str()];
                NSString* name = [NSString stringWithFormat:@"%@-frame-%04llu-%s.raw", file.stringByDeletingPathExtension,
                    (unsigned long long)deliveredFrames, session->renderedPackedImage() ? "cbycry10_6" : "bgra8"];
                int fd = open(name.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
                if (fd >= 0) { std::size_t remaining=size; const auto* ptr=bytes;
                    while (remaining) { ssize_t n=write(fd,ptr,remaining); if(n<=0) break; ptr+=n; remaining-=n; }
                    close(fd);
                }
            }
        }
        ama_worker::trace("bridge.format object=%p kind=%s width=%u height=%u stride=%zu bytes=%zu",
            this, compressedProRes ? "prores" : (session->renderedPackedImage() ? "cbycry10_6" : "bgra8"), width, height, stride, size);
        if (!stream) {
            TraceHost("FrameBridge creating encoder stream");
            Class streamClass = [AMAFrameWorkerClient class];
            const char* quality = "422hq";
            switch (session->codec()) {
                case CodecChoice::ProResProxy: quality = "proxy"; break;
                case CodecChoice::ProRes422LT: quality = "422lt"; break;
                case CodecChoice::ProRes422: quality = "422"; break;
                case CodecChoice::ProRes422HQ: quality = "422hq"; break;
                case CodecChoice::ProRes4444: quality = "4444"; break;
                case CodecChoice::ProRes4444XQ: quality = "4444xq"; break;
                case CodecChoice::HEVC: quality = "hevc"; break;
                case CodecChoice::AV1: quality = "av1"; break;
                case CodecChoice::H264: quality = "h264"; break;
            }
            const char* extension = "mov";
            switch (session->container()) {
                case ContainerChoice::MOV: extension = "mov"; break;
                case ContainerChoice::MP4: extension = "mp4"; break;
                case ContainerChoice::MXFOP1a: extension = "op1a"; break;
                case ContainerChoice::MXFOPAtom: extension = "opatom"; break;
                case ContainerChoice::MKV: extension = "mkv"; break;
            }
            const AdvancedOptions advanced = session->advancedOptions();
            NSMutableDictionary* options = [NSMutableDictionary dictionary];
            constexpr const char* kInputGamuts[] = {"", "rec709", "rec2020", "rec2020", "p3d65"};
            constexpr const char* kInputTransfers[] = {"", "gamma2.4", "pq", "hlg", "pq"};
            if (advanced.inputColor > 0 && advanced.inputColor <= 4) {
                options[@"inputColorGamut"] = [NSString stringWithUTF8String:kInputGamuts[advanced.inputColor]];
                options[@"inputColorTransfer"] = [NSString stringWithUTF8String:kInputTransfers[advanced.inputColor]];
                session->addObservation("renderColor=explicit declaration choice=" + std::to_string(advanced.inputColor));
            }
            auto addText = [&](NSString* key, const std::string& value) {
                NSString* text = [NSString stringWithUTF8String:value.c_str()];
                if (text) {
                    options[key] = text;
                }
            };
            addText(@"extraAudioPath", advanced.extraAudioPath);
            options[@"replaceSourceAudio"] = [NSNumber numberWithBool:advanced.replaceSourceAudio];
            options[@"deleteSourceAudio"] = [NSNumber numberWithBool:advanced.deleteSourceAudio];
            options[@"amaHostAudioEnabled"] = @(!advanced.deleteSourceAudio && !advanced.replaceSourceAudio &&
                (session->container() == ContainerChoice::MOV || session->container() == ContainerChoice::MP4 || session->container() == ContainerChoice::MKV));
            options[@"amaBounceMix"] = @(session->audioRoute() == AudioRouteChoice::BounceMix);
            addText(@"forcedStartTimecode", advanced.forcedStartTimecode);
            if (session->dolby() == DolbyChoice::ExternalXML) {
                addText(@"dolbyVisionXMLPath", advanced.dolbyVisionXMLPath);
            }
            constexpr const char* kDolbyProfiles[] = {"", "5", "76", "81", "84", "10", "101", "104"};
            if (advanced.dolbyProfile < 8 && advanced.dolbyProfile != 0) {
                addText(@"dolbyVisionProfile", kDolbyProfiles[advanced.dolbyProfile]);
            }
            options[@"audioChannelsPerMXFFile"] = [NSNumber numberWithUnsignedInt:advanced.audioChannelsPerMXFFile];
            constexpr const char* kColorModes[] = {"off", "direct", "lut"};
            constexpr const char* kGamuts[] = {"rec709", "rec2020", "rec2020lm", "p3d65"};
            constexpr const char* kTransfers[] = {"gamma2.4", "gamma2.6", "pq", "hlg"};
            if (advanced.colorMode < 3 && advanced.colorGamut < 4 && advanced.colorTransfer < 4) {
                addText(@"colorMode", kColorModes[advanced.colorMode]);
                addText(@"colorGamut", kGamuts[advanced.colorGamut]);
                addText(@"colorTransfer", kTransfers[advanced.colorTransfer]);
                options[@"colorPeakNits"] = [NSNumber numberWithDouble:advanced.colorPeakNits];
            }
            addText(@"lutPath", advanced.lutPath);
            if (advanced.cmuMasteringNits != 0) {
                options[@"cmuMasteringNits"] = [NSNumber numberWithDouble:advanced.cmuMasteringNits];
            }
            options[@"includeGeneratedDolbyVisionMetadata"] = [NSNumber numberWithBool:advanced.includeGeneratedDolbyVisionMetadata];
            options[@"useDolbyVisionCodecTag"] = [NSNumber numberWithBool:advanced.useDolbyVisionCodecTag];
            options[@"outputVideoRaw"] = [NSNumber numberWithBool:advanced.outputVideoRaw];
            if (advanced.multiPass != 0) {
                options[@"multiPass"] = [NSNumber numberWithBool:advanced.multiPass == 1];
            }
            if (advanced.bFrames != 0) {
                options[@"bFrames"] = [NSNumber numberWithBool:advanced.bFrames == 1];
            }
            constexpr const char* kAAFModes[] = {"none", "sequence", "perClip"};
            if (advanced.aafMode < 3) {
                addText(@"aafMode", kAAFModes[advanced.aafMode]);
            }
            // One owner: MC supplies its declared render space; the framework
            // applies the same color transform as CLI. No second AMA EETF/gamut
            // curve or RGB8 PQ intermediate is used.
            if (advanced.inputColor > 0) options[@"amaSharedColorPipeline"] = @YES;
            if (session->codec() == CodecChoice::HEVC && advanced.dolbyProfile == 1 && session->dolbyVisionRequested()) {
                if (compressedProRes || advanced.inputColor == 0) {
                    session->failWrite("Profile 5 requires a declared rendered input color."); return ACF_E_INVALIDARG;
                }
                if (advanced.colorMode == 0 && advanced.inputColor == 1) {
                    options[@"colorMode"] = @"direct"; options[@"colorGamut"] = @"rec2020";
                    options[@"colorTransfer"] = @"pq"; options[@"colorPeakNits"] = @(advanced.colorPeakNits);
                }
            }
            options[@"amaPacked422Input"] = @(session->renderedPackedImage());
            if (session->renderedPackedImage()) {
                options[@"amaPacked422Matrix"] = @(session->renderedMatrix());
            }
            std::uint32_t fpsNumerator = session->frameRateNumerator();
            std::uint32_t fpsDenominator = session->frameRateDenominator();
            if (fpsNumerator == 0) {
                fpsNumerator = 24;
                fpsDenominator = 1;
            }
            NSString* outputPath = [NSString stringWithUTF8String:session->outputPath().c_str()];
            if ((session->container() == ContainerChoice::MOV || session->container() == ContainerChoice::MP4 || session->container() == ContainerChoice::MKV) &&
                outputPath.pathExtension.length == 0) {
                outputPath = [outputPath stringByAppendingPathExtension:[NSString stringWithUTF8String:extension]];
            }
            NSURL* url = [NSURL fileURLWithPath:outputPath];
            id<ProResFrameStreamSessionAPI> created = [[streamClass alloc] initWithOutputURL:url
                                                                    width:static_cast<NSInteger>(width)
                                                                   height:static_cast<NSInteger>(height)
                                                            fpsNumerator:static_cast<NSInteger>(fpsNumerator)
                                                          fpsDenominator:static_cast<NSInteger>(fpsDenominator)
                                                                  quality:[NSString stringWithUTF8String:quality]
                                                       containerExtension:[NSString stringWithUTF8String:extension]
                                                             bitrateMbps:session->bitrateMbps()
                                                             includeDolbyVision:session->dolbyVisionRequested()
                                                               advancedOptions:options];
            {
                std::lock_guard<std::mutex> ownership(streamOwnership);
                stream = created;
            }
            if (cancelled.load()) { [stream cancel]; return ACF_E_ABORT; }
            TraceHost(stream ? "FrameBridge encoder stream created" : "FrameBridge encoder stream allocation failed");
        }
        NSData* frame = (session->renderedPackedImage() || compressedProRes) ? [NSData dataWithBytes:bytes length:size] : nil;
        const CodecChoice hostCodec = session->codec() <= CodecChoice::ProRes4444XQ
            ? session->codec() : CodecChoice::ProRes4444XQ;
        constexpr const char* hostQualities[] = {"proxy", "422lt", "422", "422hq", "4444", "4444xq"};
        const BOOL appended = compressedProRes
            ? [stream appendProResFrame:frame sourceCodec:[NSString stringWithUTF8String:hostQualities[static_cast<std::size_t>(hostCodec)]]]
            : (session->renderedPackedImage()
                ? [stream appendPacked422Frame:frame stride:static_cast<NSInteger>(stride)]
                : [(AMAFrameWorkerClient*)stream appendBGRABytes:bytes size:size stride:static_cast<NSInteger>(stride)]);
        ama_worker::trace("bridge.append.return object=%p success=%d", this, appended);
        if (!appended) {
            const std::string message = stream.lastErrorMessage.UTF8String ? stream.lastErrorMessage.UTF8String : "Frame append failed.";
            session->failWrite(message);
            return ACF_E_FAIL;
        }
        ++deliveredFrames;
        return ACF_OK;
    }

    ACFRESULT finish(const std::shared_ptr<ExportSession>& session) {
        std::lock_guard<std::mutex> operation(processing);
        if (cancelled.load()) return ACF_E_ABORT;
        ama_worker::trace("bridge.finish.enter object=%p", this);
        if (!stream) {
            session->failWrite("No video frames were received.");
            return ACF_E_FAIL;
        }
        NSMutableArray* audioFiles = [NSMutableArray array];
        for (auto& item : audioTracks) {
            if (item.second.file) {
                const OSStatus status = AudioFileClose(item.second.file);
                item.second.file = nullptr;
                if (status != noErr) { session->failWrite("The host PCM transaction did not close."); return ACF_E_FAIL; }
            }
            [audioFiles addObject:[NSString stringWithUTF8String:item.second.path.c_str()]];
        }
        if (audioFiles.count && ![stream setTimelineAudioFiles:audioFiles]) {
            session->failWrite(stream.lastErrorMessage.UTF8String ?: "Host PCM delivery failed."); return ACF_E_FAIL;
        }
        if (![stream finish]) {
            const std::string message = stream.lastErrorMessage.UTF8String ? stream.lastErrorMessage.UTF8String : "Encoding failed.";
            session->failWrite(message);
            return ACF_E_FAIL;
        }
        clearAudio();
        ama_worker::trace("bridge.finish.return object=%p success=1", this);
        return ACF_OK;
    }

    void cancel() {
        cancelled.store(true);
        id<ProResFrameStreamSessionAPI> active = nil;
        {
            std::lock_guard<std::mutex> ownership(streamOwnership);
            active = [stream retain];
        }
        [active cancel];
        [active release];
        std::lock_guard<std::mutex> operation(processing);
        {
            std::lock_guard<std::mutex> ownership(streamOwnership);
            [stream release];
            stream = nil;
        }
        clearAudio();
    }
};

WriterJob::WriterJob()
    : session_(std::make_shared<ExportSession>()),
      frameBridge_(std::make_shared<FrameBridge>()) {}

WriterJob::~WriterJob() {
    if (interactor_) {
        interactor_->Release();
        interactor_ = nullptr;
    }
    if (factory_) {
        factory_->Release();
        factory_ = nullptr;
    }
    if (host_) {
        host_->Release();
        host_ = nullptr;
    }
}

ACFRESULT WriterJob::bindHost(IACFUnknown* host) {
    if (!host) {
        return ACF_E_POINTER;
    }
    host->AddRef();
    if (host_) {
        host_->Release();
    }
    host_ = host;
    IACFComponentFactory* factory = nullptr;
    const ACFRESULT result = host->QueryInterface(IID_PPV_ARG(IACFComponentFactory, &factory));
    if (ACFFAILED(result)) {
        return result;
    }
    if (factory_) {
        factory_->Release();
    }
    factory_ = factory;
    return ACF_OK;
}

void WriterJob::collectHostFacts() {
    if (recordedFacts_ || !session_) {
        return;
    }
    RecordColorPolicy(*session_);
    RecordHostExportContext(host_, *session_);
    RecordHostAudioRouting(host_, *session_);
    RecordDolbyMetadataMode(*session_);
    recordedFacts_ = true;
}

void WriterJob::logFailure() const {
    const std::string reason = session_ ? session_->failureReason() : std::string();
    if (!reason.empty()) {
        LogText(kACFDebugLevel_Error, reason.c_str());
    }
}

ACFRESULT WriterJob::setInteractor(AMA::IWriterInteractor* interactor) {
    if (interactor) {
        interactor->AddRef();
    }
    if (interactor_) {
        interactor_->Release();
    }
    interactor_ = interactor;
    return ACF_OK;
}

ACFRESULT WriterJob::interactorResponse(acfUInt32 response) {
    if (session_) {
        session_->addObservation("InteractorResponse=" + std::to_string(response));
    }
    return ACF_OK;
}

ACFRESULT WriterJob::validate() {
    try {
        TraceHost("ValidateWrite entered path=" + session_->outputPath());
        collectHostFacts();
        const Status status = session_->validate();
        TraceHost("ValidateWrite status=" + std::to_string(static_cast<int>(status)) + " reason=" + session_->failureReason());
        if (status != Status::Ok) {
            logFailure();
        }
        return MapStatus(status);
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::beginWrite() {
    try {
        TraceHost("BeginWrite codec=" + std::string(CodecName(session_->codec())) + " entered path=" + session_->outputPath());
        collectHostFacts();
        if (session_->phase() == Phase::Cancelled || session_->phase() == Phase::Failed) {
            // Old consumers may still retain their bridge during host cleanup.
            // Stop that stream before reopening the shared session for a retry.
            frameBridge_->cancel();
            frameBridge_ = std::make_shared<FrameBridge>();
        }
        const Status status = session_->beginWrite();
        TraceHost("BeginWrite status=" + std::to_string(static_cast<int>(status)) + " reason=" + session_->failureReason());
        if (status != Status::Ok) {
            logFailure();
        }
        return MapStatus(status);
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::beginClip(acfUInt32 index, AMA::ISampleConsumer** consumer) {
    try {
        if (!consumer) {
            return ACF_E_POINTER;
        }
        session_->addObservation("BeginClip index=" + std::to_string(index));
        TraceHost("BeginClip index=" + std::to_string(index) +
                  " raster=" + std::to_string(session_->rasterWidth()) + "x" +
                  std::to_string(session_->rasterHeight()) +
                  " rate=" + std::to_string(session_->frameRateNumerator()) + "/" +
                  std::to_string(session_->frameRateDenominator()));
        auto session = session_;
        auto bridge = frameBridge_;
        const ACFRESULT result = CreateSampleConsumer(session_, [session, bridge](const std::uint8_t* bytes, std::size_t size) {
            @autoreleasepool {
                return bridge->appendBGRA(session, bytes, size);
            }
        }, [session, bridge](std::uint32_t track, std::uint64_t sample, std::uint64_t count, const std::uint8_t* bytes, std::size_t size) {
            @autoreleasepool { return bridge->appendAudio(session, track, sample, count, bytes, size); }
        }, consumer);
        TraceHost("BeginClip consumer result=" + std::to_string(static_cast<unsigned int>(result)));
        return result;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::progress(acfFloat32* percent, ACFRESULT* errorResult) const {
    if (!percent || !errorResult || !session_) {
        return ACF_E_POINTER;
    }
    *percent = 0.0f;
    *errorResult = ACF_OK;
    switch (session_->phase()) {
        case Phase::Configured:
        case Phase::Validated:
        case Phase::Writing:
            *percent = 0.0f;
            break;
        case Phase::Draining:
            *percent = 0.9f;
            break;
        case Phase::Committed:
            *percent = 1.0f;
            break;
        case Phase::Failed:
            *errorResult = ACF_E_UNEXPECTED;
            break;
        case Phase::Cancelled:
            *errorResult = ACF_E_ABORT;
            break;
    }
    return ACF_OK;
}

ACFRESULT WriterJob::finishWrite() {
    try {
        TraceHost("FinishWrite entered frames=" + std::to_string(session_->frameCompletions()));
        const ACFRESULT pushed = frameBridge_->finish(session_);
        if (ACFFAILED(pushed)) {
            TraceHost("FinishWrite frame bridge failed reason=" + session_->failureReason());
            logFailure();
            return pushed;
        }
        const Status status = session_->completeWrite();
        TraceHost("FinishWrite complete status=" + std::to_string(static_cast<int>(status)));
        return MapStatus(status);
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::cancelWrite() {
    try {
        TraceHost("CancelWrite entered frames=" + std::to_string(session_->frameCompletions()));
        const Status status = session_->cancel();
        frameBridge_->cancel();
        logFailure();
        return MapStatus(status);
    } catch (...) {
        return ACF_E_ABORT;
    }
}

ACFRESULT WriterJob::setOutputPath(IACFString* path) {
    if (!path) {
        return ACF_E_POINTER;
    }
    try {
        AMA::AMAString text(kACFUTF8, path);
        const acfUTF8* utf8 = text.GetUTF8String();
        session_->setOutputPath(utf8 ? reinterpret_cast<const char*>(utf8) : "");
        TraceHost("SetContainerPath=" + session_->outputPath());
        return ACF_OK;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::noteMetadata(const char* source, acfUInt32 count) {
    try {
        TraceHost(std::string("Host metadata ") + (source ? source : "metadata") +
                  " count=" + std::to_string(count));
        return MapStatus(session_->noteMetadata(source ? source : "metadata", count));
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::getMediaWriterParameter(const acfUID& id, IACFValue** parameter) const {
    if (!parameter) {
        return ACF_E_POINTER;
    }
    *parameter = nullptr;
    TraceHost("GetMediaWriterParameter id=" + FormatUID(id));
    if (id == AMA::AMA_MC_ExportVolumeVideoFormat_ID) {
        AMA::IHostSettings* settings = nullptr;
        if (AcquireHostSettings(host_, &settings) != ACF_OK || !settings) return ACF_E_PARAMETERNOTAVAILABLE;
        acfUInt32 width = 0, height = 0;
        acfBoolean progressive = kACFFalse;
        const auto widthResult = settings->GetHostSettingUInt32(AMA::AMAHostSetting_VideoImageWidth,
            AMA::IHostSettings::kProjectScope, &width);
        const auto heightResult = settings->GetHostSettingUInt32(AMA::AMAHostSetting_VideoImageHeight,
            AMA::IHostSettings::kProjectScope, &height);
        const auto scanResult = settings->GetHostSettingBoolean(AMA::AMAHostSetting_VideoIsProgressive,
            AMA::IHostSettings::kProjectScope, &progressive);
        acfSInt32 hostFormat = 0;
        ACFRESULT hostFormatResult = settings->GetHostSettingSInt32(id, AMA::IHostSettings::kProjectScope, &hostFormat);
        if (ACFFAILED(hostFormatResult)) {
            hostFormatResult = settings->GetHostSettingSInt32(id, AMA::IHostSettings::kGlobalScope, &hostFormat);
        }
        settings->Release();
        // The image-consumer contract currently requests progressive pictures.
        // Map only verified SD/HD projects; never guess a format from frame bytes.
        acfSInt32 format = ACFSUCCEEDED(hostFormatResult) && hostFormat > 0 ? hostFormat : 0;
        TraceHost("host video-format query result=" + std::to_string(static_cast<unsigned int>(hostFormatResult)) +
            " value=" + std::to_string(hostFormat));
        if (format == 0 && ACFSUCCEEDED(widthResult) && ACFSUCCEEDED(heightResult) && ACFSUCCEEDED(scanResult) && progressive) {
            if (width == 1920 && height == 1080) format = AMA::AMA_MC_ExportVolumeVideoFormat_1080p;
            else if (width == 1280 && height == 720) format = AMA::AMA_MC_ExportVolumeVideoFormat_720p;
            else if (width == 720 && height == 576) format = AMA::AMA_MC_ExportVolumeVideoFormat_625p;
            else if (width == 720 && height == 486) format = AMA::AMA_MC_ExportVolumeVideoFormat_525p;
        }
        TraceHost("GetMediaWriterParameter video-format=" + std::to_string(format) +
            " raster=" + std::to_string(width) + "x" + std::to_string(height) +
            " progressive=" + std::to_string(progressive));
        if (format == 0) return ACF_E_PARAMETERNOTAVAILABLE;
        session_->setRaster(width, height);
        // MC's AMA exporter reads this as SInt32 (not the UInt32 used by XML
        // discrete controls); the wrong type asserts before BeginWrite.
        const ACFRESULT result = MakeTypedValue(factory_, ACFTypeID_SInt32, &format, sizeof(format), parameter);
        TraceHost("GetMediaWriterParameter video-format SInt32 result=" + std::to_string(static_cast<unsigned int>(result)));
        return result;
    }
    if (id == AMA::AMA_MC_ExportVolumeAudioSampleRate_ID) {
        AMA::IHostSettings* settings = nullptr;
        if (AcquireHostSettings(host_, &settings) != ACF_OK || !settings) {
            TraceHost("GetMediaWriterParameter audio-rate -> IHostSettings unavailable");
            return ACF_E_PARAMETERNOTAVAILABLE;
        }
        acfRational32 projectRate{};
        const ACFRESULT sourceResult = settings->GetHostSettingRational32(
            AMA::AMAHostSetting_AudioEditRate,
            AMA::IHostSettings::kProjectScope,
            &projectRate);
        settings->Release();
        if (ACFFAILED(sourceResult) || projectRate.numerator <= 0 || projectRate.denominator <= 0 ||
            projectRate.numerator % projectRate.denominator != 0) {
            TraceHost("GetMediaWriterParameter audio-rate -> project rate unavailable result=" +
                      std::to_string(static_cast<unsigned int>(sourceResult)));
            return ACF_E_PARAMETERNOTAVAILABLE;
        }
        const acfSInt32 sampleRate = projectRate.numerator / projectRate.denominator;
        frameBridge_->audioSampleRate = sampleRate;
        const ACFRESULT result = MakeTypedValue(
            factory_, ACFTypeID_SInt32, &sampleRate, sizeof(sampleRate), parameter);
        TraceHost("GetMediaWriterParameter audio-rate=" + std::to_string(sampleRate) +
                  " result=" + std::to_string(static_cast<unsigned int>(result)));
        if (ACFSUCCEEDED(result)) {
            session_->addObservation("projectAudioRate=" + std::to_string(sampleRate));
        }
        return result;
    }
    if (id == AMA::AMA_MC_ExportVolumeAudioBitDepth_ID) {
        AMA::IHostSettings* settings = nullptr;
        if (AcquireHostSettings(host_, &settings) != ACF_OK || !settings) return ACF_E_PARAMETERNOTAVAILABLE;
        acfUInt32 bits = 0;
        for (const auto scope : {AMA::IHostSettings::kProjectScope, AMA::IHostSettings::kUserScope, AMA::IHostSettings::kGlobalScope}) {
            if (settings->GetHostSettingUInt32(id, scope, &bits) == ACF_OK && bits > 0) break;
            acfSInt32 signedBits = 0;
            if (settings->GetHostSettingSInt32(id, scope, &signedBits) == ACF_OK && signedBits > 0) { bits = signedBits; break; }
        }
        settings->Release();
        const bool suppliedByHost = bits == 16 || bits == 24 || bits == 32;
        if (!suppliedByHost) {
            // Writeback requires the receiver to request a rendered PCM layout
            // before any sequence metadata arrives. MC's integer render export
            // supports 16/24 bits; request its full precision. This is a wire
            // format request, never a declaration about source-file codecs or
            // source bit depth. File workflows bypass this host renderer and
            // retain original compressed audio, including unknown codecs.
            bits = 24;
        }
        frameBridge_->audioBitDepth = bits;
        ama_worker::trace("audio.negotiate bits=%u source=%s", bits,
            suppliedByHost ? "host-setting" : "writer-render-delivery-request");
        return MakeTypedValue(factory_, ACFTypeID_SInt32, &bits, sizeof(bits), parameter);
    }
    if (id == AMA::AMA_MC_ExportVolumeAudioMixFormat_ID) {
        const acfSInt32 mix = session_->audioRoute() == AudioRouteChoice::BounceMix
            ? AMA::AMA_MC_ExportVolumeAudioMixFormat_Stereo : AMA::AMA_MC_ExportVolumeAudioMixFormat_DirectOut;
        return MakeTypedValue(factory_, ACFTypeID_SInt32, &mix, sizeof(mix), parameter);
    }
    if (id == AMA::AMA_MC_ExportVolumeAudioFileArrangement_ID) {
        const char* arrangement = session_->audioRoute() == AudioRouteChoice::BounceMix ? "two channel" : "single channel";
        return MakeTypedValue(factory_, ACFTypeID_UTF8String, arrangement, static_cast<acfUInt32>(std::strlen(arrangement) + 1), parameter);
    }
    if (id == AMA::AMA_MC_ExportVolumeAudioEssenceCoding_ID) {
        // SMPTE ST 382 uncompressed little-endian PCM, identical to the
        // project's existing MXF PCM coding label (UL registry version 0x0a).
        const acfUID coding = {0x04020201, 0x0100, 0,
            {0x06, 0x0e, 0x2b, 0x34, 0x04, 0x01, 0x01, 0x0a}};
        return MakeTypedValue(factory_, ACFTypeID_UID, &coding, sizeof(coding), parameter);
    }
    if (id == AMA::AMA_MC_ExportVolumeVideoSampleRate_ID) {
        AMA::IHostSettings* settings = nullptr;
        if (AcquireHostSettings(host_, &settings) != ACF_OK || !settings) {
            TraceHost("GetMediaWriterParameter video-rate -> IHostSettings unavailable");
            return ACF_E_PARAMETERNOTAVAILABLE;
        }
        acfRational32 projectRate{};
        const ACFRESULT projectResult = settings->GetHostSettingRational32(
            AMA::AMAHostSetting_VideoEditRate,
            AMA::IHostSettings::kProjectScope,
            &projectRate);
        if (ACFSUCCEEDED(projectResult) && projectRate.numerator > 0 && projectRate.denominator > 0) {
            const acfSInt32 components[2] = {projectRate.numerator, projectRate.denominator};
            const ACFRESULT result = MakeTypedValue(
                factory_, ACFTypeID_Int32Array, components, sizeof(components), parameter);
            if (ACFSUCCEEDED(result)) {
                session_->setFrameRate(static_cast<std::uint32_t>(projectRate.numerator),
                                       static_cast<std::uint32_t>(projectRate.denominator));
            }
            TraceHost("GetMediaWriterParameter project-video-rate=" +
                      std::to_string(projectRate.numerator) + "/" +
                      std::to_string(projectRate.denominator) +
                      " result=" + std::to_string(static_cast<unsigned int>(result)));
            settings->Release();
            return result;
        }
        TraceHost("GetMediaWriterParameter AMAHostSetting_VideoEditRate unavailable result=" +
                  std::to_string(static_cast<unsigned int>(projectResult)));
        const AMA::IHostSettings::EHostSettingScope scopes[] = {
            AMA::IHostSettings::kProjectScope,
            AMA::IHostSettings::kGlobalScope
        };
        for (const auto scope : scopes) {
            IACFValue* hostValue = nullptr;
            if (settings->GetHostSetting(id, scope, &hostValue) != ACF_OK || !hostValue) {
                continue;
            }
            acfUID typeID{};
            const ACFRESULT typeResult = hostValue->GetTypeID(&typeID);
            const acfUInt32 size = hostValue->GetSize();
            if (ACFSUCCEEDED(typeResult) && typeID == ACFTypeID_Int32Array && size == 2 * sizeof(acfSInt32)) {
                const acfByte* bytes = hostValue->GetBuffer();
                if (bytes) {
                    acfSInt32 numerator = 0;
                    acfSInt32 denominator = 0;
                    std::memcpy(&numerator, bytes, sizeof(numerator));
                    std::memcpy(&denominator, bytes + sizeof(numerator), sizeof(denominator));
                    if (numerator > 0 && denominator > 0) {
                        session_->setFrameRate(static_cast<std::uint32_t>(numerator), static_cast<std::uint32_t>(denominator));
                    }
                    TraceHost("GetMediaWriterParameter video-rate=" + std::to_string(numerator) +
                              "/" + std::to_string(denominator) +
                              " scope=" + std::to_string(static_cast<int>(scope)));
                }
                *parameter = hostValue;
                settings->Release();
                return ACF_OK;
            }
            TraceHost("GetMediaWriterParameter video-rate wrong type=" + FormatUID(typeID) +
                      " bytes=" + std::to_string(size));
            hostValue->Release();
        }
        settings->Release();
        TraceHost("GetMediaWriterParameter video-rate -> unavailable");
        return ACF_E_PARAMETERNOTAVAILABLE;
    }
    if (id == AMA::AMA_MC_ExportVolumeVideoEssenceCoding_ID) {
        // SMPTE Uncompressed Picture Coding, in AAF/ACF UID field order.
        // MC requires this generic coding label before it queries the WRITER's
        // IUncompressedImageConsumer. A CodecDefinition UID is not a coding
        // label; returning unavailable also prevents the export from starting.
        // UL: urn:smpte:ul:060e2b34.04010101.04010201.00000000
        const acfUID coding = {0x04010201, 0, 0,
            {0x06, 0x0e, 0x2b, 0x34, 0x04, 0x01, 0x01, 0x01}};
        const ACFRESULT result = MakeTypedValue(factory_, ACFTypeID_UID, &coding, sizeof(coding), parameter);
        TraceHost("GetMediaWriterParameter uncompressed-essence-coding=" + FormatUID(coding) +
                  " result=" + std::to_string(static_cast<unsigned int>(result)));
        return result;
    }
    if (id != AMA::AMA_MC_ExportHighestQualityNeeded) {
        TraceHost("GetMediaWriterParameter -> unavailable");
        return ACF_E_PARAMETERNOTAVAILABLE;
    }
    if (!factory_) {
        return ACF_E_UNEXPECTED;
    }
    // Proxy export does not request the host's highest-quality effect mode.
    // Keep full raster/frame rate while allowing MC's normal render scheduling.
    const acfBoolean highestQuality = session_->codec() == CodecChoice::ProResProxy ? kACFFalse : kACFTrue;
    const ACFRESULT result = MakeTypedValue(factory_, ACFTypeID_Boolean, &highestQuality, sizeof(highestQuality), parameter);
    TraceHost("GetMediaWriterParameter highest-quality result=" + std::to_string(static_cast<unsigned int>(result)));
    return result;
}

ACFRESULT WriterJob::getParameterInfos(const acfUID& componentID, IACFString** xml) const {
    try {
        return BuildParameterXML(factory_, *session_, componentID, true, xml);
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::getValues(const acfUID& componentID, IACFString** xml) const {
    try {
        return BuildParameterXML(factory_, *session_, componentID, false, xml);
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::getPresets(const acfUID& componentID, IACFString** xml) const {
    (void)componentID;
    return CopyPluginString("", xml);
}

ACFRESULT WriterJob::setValues(const IACFString* xml) {
    if (!xml || !session_) {
        return ACF_E_POINTER;
    }
    try {
        AMA::AMAString text(kACFUTF8, const_cast<IACFString*>(xml));
        const acfUTF8* utf8 = text.GetUTF8String();
        const std::string document = utf8 ? reinterpret_cast<const char*>(utf8) : "";
        if (document.size() > 1024 * 1024) {
            return ACF_E_INVALIDARG;
        }
        std::uint32_t value = 0;
        CodecChoice codec = session_->codec();
        ContainerChoice container = session_->container();
        DolbyChoice dolby = session_->dolby();
        AudioRouteChoice audioRoute = session_->audioRoute();
        double bitrateMbps = session_->bitrateMbps();
        if (ReadUInt32Parameter(document, ProResEncoderAMA_CodecParameterID, &value) && value <= static_cast<std::uint32_t>(CodecChoice::H264)) {
            codec = static_cast<CodecChoice>(value);
        }
        if (ReadUInt32Parameter(document, ProResEncoderAMA_ContainerParameterID, &value) && value <= static_cast<std::uint32_t>(ContainerChoice::MKV)) {
            container = static_cast<ContainerChoice>(value);
        }
        if (ReadUInt32Parameter(document, ProResEncoderAMA_DolbyParameterID, &value) && value <= static_cast<std::uint32_t>(DolbyChoice::ExternalXML)) {
            dolby = static_cast<DolbyChoice>(value);
        }
        if (ReadUInt32Parameter(document, ProResEncoderAMA_AudioParameterID, &value) && value <= static_cast<std::uint32_t>(AudioRouteChoice::BounceMultitrack)) {
            audioRoute = static_cast<AudioRouteChoice>(value);
        }
        ReadDoubleParameter(document, ProResEncoderAMA_BitrateParameterID, &bitrateMbps);
        AdvancedOptions advanced = session_->advancedOptions();
        auto readChoice = [&](const acfUID& id, std::uint32_t maximum, std::uint32_t* target) {
            std::uint32_t selected = 0;
            if (!ReadUInt32Parameter(document, id, &selected)) {
                return true;
            }
            if (selected > maximum) {
                return false;
            }
            *target = selected;
            return true;
        };
        auto readBoolean = [&](const acfUID& id, bool* target) {
            std::uint32_t selected = *target ? 1 : 0;
            if (!readChoice(id, 1, &selected)) {
                return false;
            }
            *target = selected != 0;
            return true;
        };
        auto readText = [&](const acfUID& id, std::string* target) {
            std::string selected;
            if (ReadStringParameter(document, id, &selected)) {
                *target = std::move(selected);
            }
        };
        readText(ProResEncoderAMA_ExtraAudioPathParameterID, &advanced.extraAudioPath);
        readText(ProResEncoderAMA_StartTimecodeParameterID, &advanced.forcedStartTimecode);
        readText(ProResEncoderAMA_DolbyXMLPathParameterID, &advanced.dolbyVisionXMLPath);
        readText(ProResEncoderAMA_LUTPathParameterID, &advanced.lutPath);
        if (!readBoolean(ProResEncoderAMA_ReplaceSourceAudioParameterID, &advanced.replaceSourceAudio) ||
            !readBoolean(ProResEncoderAMA_DeleteSourceAudioParameterID, &advanced.deleteSourceAudio) ||
            !readBoolean(ProResEncoderAMA_IncludeGeneratedDVParameterID, &advanced.includeGeneratedDolbyVisionMetadata) ||
            !readBoolean(ProResEncoderAMA_DolbyCodecTagParameterID, &advanced.useDolbyVisionCodecTag) ||
            !readBoolean(ProResEncoderAMA_OutputVideoRawParameterID, &advanced.outputVideoRaw) ||
            !readChoice(ProResEncoderAMA_DolbyProfileParameterID, 7, &advanced.dolbyProfile) ||
            !readChoice(ProResEncoderAMA_InputColorParameterID, 4, &advanced.inputColor) ||
            !readChoice(ProResEncoderAMA_ColorModeParameterID, 2, &advanced.colorMode) ||
            !readChoice(ProResEncoderAMA_ColorGamutParameterID, 3, &advanced.colorGamut) ||
            !readChoice(ProResEncoderAMA_ColorTransferParameterID, 3, &advanced.colorTransfer) ||
            !readChoice(ProResEncoderAMA_MultiPassParameterID, 2, &advanced.multiPass) ||
            !readChoice(ProResEncoderAMA_BFramesParameterID, 2, &advanced.bFrames) ||
            !readChoice(ProResEncoderAMA_AAFModeParameterID, 2, &advanced.aafMode)) {
            return ACF_E_INVALIDARG;
        }
        ReadUInt32Parameter(document, ProResEncoderAMA_AudioChannelsPerMXFFileParameterID, &advanced.audioChannelsPerMXFFile);
        ReadDoubleParameter(document, ProResEncoderAMA_ColorPeakNitsParameterID, &advanced.colorPeakNits);
        ReadDoubleParameter(document, ProResEncoderAMA_CMUMasteringNitsParameterID, &advanced.cmuMasteringNits);
        if (codec == CodecChoice::H264) {
            dolby = DolbyChoice::Off;
            advanced.dolbyProfile = 0;
            advanced.cmuMasteringNits = 0;
            advanced.includeGeneratedDolbyVisionMetadata = false;
            advanced.useDolbyVisionCodecTag = false;
        }
        if (dolby == DolbyChoice::Off) {
            advanced.dolbyProfile = 0;
            advanced.includeGeneratedDolbyVisionMetadata = false;
            advanced.useDolbyVisionCodecTag = false;
        } else if (dolby == DolbyChoice::ExternalXML) {
            advanced.includeGeneratedDolbyVisionMetadata = false;
            advanced.cmuMasteringNits = 0;
        }
        if (codec == CodecChoice::HEVC && advanced.dolbyProfile == 1 && dolby != DolbyChoice::Off) {
            // The shared framework owns pixel conversion. Preserve explicit
            // gamut/transfer choices instead of replacing 2020lm or P3 with
            // Rec.2020 when MC submits the parameter XML.
            if (dolby == DolbyChoice::Generate) {
                if (advanced.cmuMasteringNits == 0) advanced.cmuMasteringNits = advanced.colorPeakNits;
                advanced.includeGeneratedDolbyVisionMetadata = true;
            }
        }
        if (codec <= CodecChoice::ProRes4444XQ) {
            advanced.dolbyProfile = 0;
            advanced.useDolbyVisionCodecTag = false;
            advanced.multiPass = 0;
            advanced.bFrames = 0;
        } else if (codec == CodecChoice::AV1) {
            advanced.multiPass = 0;
            advanced.bFrames = 0;
        }
        if (container != ContainerChoice::MOV) {
            advanced.forcedStartTimecode.clear();
        }
        if (container == ContainerChoice::MOV || container == ContainerChoice::MP4 || container == ContainerChoice::MKV) {
            advanced.aafMode = 0;
        } else {
            advanced.includeGeneratedDolbyVisionMetadata = false;
        }
        return MapStatus(session_->applyOptions(codec, container, dolby, audioRoute, bitrateMbps, std::move(advanced)));
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::loadValues(const IACFString* path) {
    if (!path) {
        return ACF_E_POINTER;
    }
    try {
        AMA::AMAString text(kACFUTF8, const_cast<IACFString*>(path));
        const acfUTF8* utf8 = text.GetUTF8String();
        if (!utf8) {
            return ACF_E_INVALIDARG;
        }
        std::ifstream input(reinterpret_cast<const char*>(utf8), std::ios::binary);
        if (!input) {
            return ACF_E_INVALIDARG;
        }
        std::ostringstream contents;
        contents << input.rdbuf();
        const std::string document = contents.str();
        if (document.size() > 1024 * 1024) {
            return ACF_E_INVALIDARG;
        }
        AMA::AMAString xmlText(reinterpret_cast<const acfUTF8*>(document.c_str()));
        return setValues(xmlText.InArg());
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

ACFRESULT WriterJob::resetValues() {
    try {
        session_->resetOptions();
        recordedFacts_ = false;
        return ACF_OK;
    } catch (...) {
        return ACF_E_UNEXPECTED;
    }
}

}  // namespace prores_ama
