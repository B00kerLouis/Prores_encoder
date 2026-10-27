// ExportSession.hpp
// Avid-free export job state. The Objective-C++ plug-in maps host callbacks
// onto this type. ContractTests compile it without the Avid SDK.

#ifndef PRORES_ENCODER_AMA_EXPORT_SESSION_HPP
#define PRORES_ENCODER_AMA_EXPORT_SESSION_HPP

#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace prores_ama {

enum class CodecChoice : std::uint32_t {
    ProResProxy = 0,
    ProRes422LT = 1,
    ProRes422 = 2,
    ProRes422HQ = 3,
    ProRes4444 = 4,
    ProRes4444XQ = 5,
    HEVC = 6,
    AV1 = 7,
    H264 = 8
};

enum class ContainerChoice : std::uint32_t {
    MOV = 0,
    MP4 = 1,
    MXFOP1a = 2,
    MXFOPAtom = 3,
    MKV = 4
};

enum class DolbyChoice : std::uint32_t {
    Off = 0,
    Generate = 1,
    ExternalXML = 2
};

enum class AudioRouteChoice : std::uint32_t {
    BounceMix = 0,
    BounceMultitrack = 1
};

enum class Phase {
    Configured,
    Validated,
    Writing,
    Draining,
    Committed,
    Cancelled,
    Failed
};

enum class Status {
    Ok,
    InvalidState,
    InvalidOption,
    EncoderBoundary,
    Cancelled
};

struct TrackObservation {
    std::uint64_t samples = 0;
    std::uint64_t bytes = 0;
    std::uint64_t firstSample = 0;
    std::uint64_t lastSample = 0;
    bool seen = false;
};

// Mirrors the remaining public ProResEncodeOptions fields that can be
// represented in the AMA export settings UI. Choice numbers are XML values.
struct AdvancedOptions {
    // Explicit render-output declaration; never evidence of a queried project.
    std::uint32_t inputColor = 0; // unknown, 709 gamma2.4, 2020 PQ, 2020 HLG, P3 PQ
    std::string extraAudioPath;
    bool replaceSourceAudio = false;
    bool deleteSourceAudio = false;
    std::string forcedStartTimecode;
    std::string dolbyVisionXMLPath;
    std::uint32_t dolbyProfile = 0; // 0 off; 1:5, 2:7.6, 3:8.1, 4:8.4, 5:10, 6:10.1, 7:10.4
    std::uint32_t audioChannelsPerMXFFile = 1;
    std::uint32_t colorMode = 0; // off, direct, LUT
    std::uint32_t colorGamut = 0; // Rec.709, Rec.2020, Rec.2020 limited to P3, P3-D65
    std::uint32_t colorTransfer = 0; // gamma 2.4, gamma 2.6, PQ, HLG
    double colorPeakNits = 1000;
    std::string lutPath;
    double cmuMasteringNits = 0;
    bool includeGeneratedDolbyVisionMetadata = false;
    bool useDolbyVisionCodecTag = false;
    bool outputVideoRaw = false;
    std::uint32_t multiPass = 0; // default, on, off
    std::uint32_t bFrames = 0; // default, on, off
    std::uint32_t aafMode = 0; // none, sequence, per clip
};

// One host export job. Sample counters stay bounded by track count.
class ExportSession {
public:
    ExportSession();

    void setCodec(CodecChoice value);
    void setContainer(ContainerChoice value);
    void setDolby(DolbyChoice value);
    void setAudioRoute(AudioRouteChoice value);
    void setBitrateMbps(double value);
    void setAdvancedOptions(AdvancedOptions value);
    Status applyOptions(CodecChoice codec, ContainerChoice container, DolbyChoice dolby,
                        AudioRouteChoice audioRoute, double bitrateMbps,
                        AdvancedOptions advanced);
    void setOutputPath(std::string path);
    void setProjectColorKnown(bool known);
    void setRaster(std::uint32_t width, std::uint32_t height);
    void setFrameRate(std::uint32_t numerator, std::uint32_t denominator);
    void resetOptions();

    CodecChoice codec() const;
    ContainerChoice container() const;
    DolbyChoice dolby() const;
    AudioRouteChoice audioRoute() const;
    double bitrateMbps() const;
    AdvancedOptions advancedOptions() const;
    Phase phase() const;
    std::string outputPath() const;
    std::string failureReason() const;
    bool outputFileCreated() const;
    bool projectColorKnown() const;
    std::uint32_t rasterWidth() const;
    std::uint32_t rasterHeight() const;
    std::uint32_t frameRateNumerator() const;
    std::uint32_t frameRateDenominator() const;
    // Describes a validated metadata request, not a verified output bitstream.
    bool dolbyVisionRequested() const;

    Status validate();
    Status beginWrite();
    Status noteMetadata(const std::string& source, std::uint32_t count);
    Status noteSample(std::uint32_t track, std::uint64_t sample, std::uint64_t sampleCount, std::uint64_t bytes);
    Status noteFrameComplete(std::uint64_t sample);
    Status finishWrite();
    Status completeWrite();
    Status failWrite(const std::string& reason);
    Status cancel();

    void addObservation(std::string text);
    std::vector<std::string> observations() const;
    std::map<std::uint32_t, TrackObservation> tracks() const;
    // Negotiated image layout is fixed for this export, even if MC asks both
    // writer and sample consumer at different stages of option negotiation.
    bool negotiatePackedImage(bool forcePacked);
    bool renderedPackedImage() const;
    std::uint32_t renderedMatrix() const;
    std::uint64_t frameCompletions() const;

    // Returns the number of failed checks. Zero means the contract holds.
    static int runContractSelfCheck();

private:
    Status validateUnlocked();
    Status reopenUnlocked();
    void addObservationUnlocked(std::string text);
    bool dolbyVisionRequestedUnlocked() const;
    bool colorContextAvailableUnlocked() const;
    bool isCompressedCodecUnlocked() const;

    mutable std::mutex mutex_;
    CodecChoice codec_ = CodecChoice::ProRes422HQ;
    ContainerChoice container_ = ContainerChoice::MOV;
    DolbyChoice dolby_ = DolbyChoice::Off;
    AudioRouteChoice audioRoute_ = AudioRouteChoice::BounceMix;
    double bitrateMbps_ = 50;
    AdvancedOptions advancedOptions_;
    bool projectColorKnown_ = false;
    std::uint32_t rasterWidth_ = 0;
    std::uint32_t rasterHeight_ = 0;
    std::uint32_t frameRateNumerator_ = 0;
    std::uint32_t frameRateDenominator_ = 1;
    std::string outputPath_;
    Phase phase_ = Phase::Configured;
    std::string failureReason_;
    bool outputFileCreated_ = false;
    std::vector<std::string> observations_;
    std::map<std::uint32_t, TrackObservation> tracks_;
    std::uint64_t frameCompletions_ = 0;
    bool imageFormatChosen_ = false, renderedPackedImage_ = false;
    std::uint32_t renderedMatrix_ = 709;
};

const char* CodecName(CodecChoice value);
const char* ContainerName(ContainerChoice value);

}  // namespace prores_ama

#endif
