#include "ExportSession.hpp"

#include <cstdio>
#include <cmath>
#include <utility>

namespace prores_ama {
namespace {

constexpr std::size_t kMaxObservations = 64;

bool isProRes(CodecChoice codec) {
    return codec <= CodecChoice::ProRes4444XQ;
}

bool isCompressed(CodecChoice codec) {
    return codec == CodecChoice::HEVC || codec == CodecChoice::AV1 || codec == CodecChoice::H264;
}

bool isMXF(ContainerChoice container) {
    return container == ContainerChoice::MXFOP1a || container == ContainerChoice::MXFOPAtom;
}

}  // namespace

const char* CodecName(CodecChoice value) {
    switch (value) {
        case CodecChoice::ProResProxy: return "ProRes Proxy";
        case CodecChoice::ProRes422LT: return "ProRes 422 LT";
        case CodecChoice::ProRes422: return "ProRes 422";
        case CodecChoice::ProRes422HQ: return "ProRes 422 HQ";
        case CodecChoice::ProRes4444: return "ProRes 4444";
        case CodecChoice::ProRes4444XQ: return "ProRes 4444 XQ";
        case CodecChoice::HEVC: return "HEVC";
        case CodecChoice::AV1: return "AV1";
        case CodecChoice::H264: return "H.264";
    }
    return "unknown codec";
}

const char* ContainerName(ContainerChoice value) {
    switch (value) {
        case ContainerChoice::MOV: return "MOV";
        case ContainerChoice::MP4: return "MP4";
        case ContainerChoice::MXFOP1a: return "MXF OP-1a";
        case ContainerChoice::MXFOPAtom: return "MXF OP-Atom";
    }
    return "unknown container";
}

ExportSession::ExportSession() = default;

void ExportSession::setCodec(CodecChoice value) { std::lock_guard<std::mutex> lock(mutex_); codec_ = value; }
void ExportSession::setContainer(ContainerChoice value) { std::lock_guard<std::mutex> lock(mutex_); container_ = value; }
void ExportSession::setDolby(DolbyChoice value) { std::lock_guard<std::mutex> lock(mutex_); dolby_ = value; }
void ExportSession::setAudioRoute(AudioRouteChoice value) { std::lock_guard<std::mutex> lock(mutex_); audioRoute_ = value; }
void ExportSession::setBitrateMbps(double value) { std::lock_guard<std::mutex> lock(mutex_); bitrateMbps_ = value; }
void ExportSession::setAdvancedOptions(AdvancedOptions value) { std::lock_guard<std::mutex> lock(mutex_); advancedOptions_ = std::move(value); }
Status ExportSession::applyOptions(CodecChoice codec, ContainerChoice container, DolbyChoice dolby,
                                   AudioRouteChoice audioRoute, double bitrateMbps,
                                   AdvancedOptions advanced) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Writing || phase_ == Phase::Draining || phase_ == Phase::Committed) {
        failureReason_ = "Export options cannot change after writing starts.";
        return Status::InvalidState;
    }
    codec_ = codec;
    container_ = container;
    dolby_ = dolby;
    audioRoute_ = audioRoute;
    bitrateMbps_ = bitrateMbps;
    advancedOptions_ = std::move(advanced);
    if (phase_ == Phase::Validated) {
        phase_ = Phase::Configured;
    }
    return Status::Ok;
}
void ExportSession::setOutputPath(std::string path) { std::lock_guard<std::mutex> lock(mutex_); outputPath_ = std::move(path); }
void ExportSession::setProjectColorKnown(bool known) { std::lock_guard<std::mutex> lock(mutex_); projectColorKnown_ = known; }
void ExportSession::setRaster(std::uint32_t width, std::uint32_t height) {
    std::lock_guard<std::mutex> lock(mutex_);
    rasterWidth_ = width;
    rasterHeight_ = height;
}
void ExportSession::setFrameRate(std::uint32_t numerator, std::uint32_t denominator) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (numerator == 0 || denominator == 0) {
        return;
    }
    frameRateNumerator_ = numerator;
    frameRateDenominator_ = denominator;
}

void ExportSession::resetOptions() {
    std::lock_guard<std::mutex> lock(mutex_);
    codec_ = CodecChoice::ProRes422HQ;
    container_ = ContainerChoice::MOV;
    dolby_ = DolbyChoice::Off;
    audioRoute_ = AudioRouteChoice::BounceMix;
    bitrateMbps_ = 50;
    advancedOptions_ = AdvancedOptions{};
    if (phase_ == Phase::Configured || phase_ == Phase::Validated) {
        phase_ = Phase::Configured;
        failureReason_.clear();
    }
}

CodecChoice ExportSession::codec() const { std::lock_guard<std::mutex> lock(mutex_); return codec_; }
ContainerChoice ExportSession::container() const { std::lock_guard<std::mutex> lock(mutex_); return container_; }
DolbyChoice ExportSession::dolby() const { std::lock_guard<std::mutex> lock(mutex_); return dolby_; }
AudioRouteChoice ExportSession::audioRoute() const { std::lock_guard<std::mutex> lock(mutex_); return audioRoute_; }
double ExportSession::bitrateMbps() const { std::lock_guard<std::mutex> lock(mutex_); return bitrateMbps_; }
AdvancedOptions ExportSession::advancedOptions() const { std::lock_guard<std::mutex> lock(mutex_); return advancedOptions_; }
Phase ExportSession::phase() const { std::lock_guard<std::mutex> lock(mutex_); return phase_; }
std::string ExportSession::outputPath() const { std::lock_guard<std::mutex> lock(mutex_); return outputPath_; }
std::string ExportSession::failureReason() const { std::lock_guard<std::mutex> lock(mutex_); return failureReason_; }
bool ExportSession::outputFileCreated() const { std::lock_guard<std::mutex> lock(mutex_); return outputFileCreated_; }
bool ExportSession::projectColorKnown() const { std::lock_guard<std::mutex> lock(mutex_); return projectColorKnown_; }
std::uint32_t ExportSession::rasterWidth() const { std::lock_guard<std::mutex> lock(mutex_); return rasterWidth_; }
std::uint32_t ExportSession::rasterHeight() const { std::lock_guard<std::mutex> lock(mutex_); return rasterHeight_; }
std::uint32_t ExportSession::frameRateNumerator() const { std::lock_guard<std::mutex> lock(mutex_); return frameRateNumerator_; }
std::uint32_t ExportSession::frameRateDenominator() const { std::lock_guard<std::mutex> lock(mutex_); return frameRateDenominator_; }

bool ExportSession::colorContextAvailableUnlocked() const {
    return projectColorKnown_ || (advancedOptions_.inputColor > 0 && advancedOptions_.inputColor <= 4);
}

bool ExportSession::dolbyVisionRequestedUnlocked() const {
    if (codec_ != CodecChoice::HEVC && codec_ != CodecChoice::AV1) {
        return false;
    }
    if (advancedOptions_.dolbyProfile == 0) {
        return false;
    }
    if (dolby_ == DolbyChoice::ExternalXML) {
        return !advancedOptions_.dolbyVisionXMLPath.empty();
    }
    return dolby_ == DolbyChoice::Generate && colorContextAvailableUnlocked() &&
        advancedOptions_.cmuMasteringNits != 0 && advancedOptions_.includeGeneratedDolbyVisionMetadata;
}

bool ExportSession::dolbyVisionRequested() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return dolbyVisionRequestedUnlocked();
}

bool ExportSession::isCompressedCodecUnlocked() const {
    return isCompressed(codec_);
}

Status ExportSession::validateUnlocked() {
    if (phase_ == Phase::Cancelled) {
        return Status::Cancelled;
    }
    if (phase_ == Phase::Writing || phase_ == Phase::Draining || phase_ == Phase::Committed) {
        failureReason_ = "ValidateWrite is only valid before samples are accepted.";
        return Status::InvalidState;
    }

    if (container_ == ContainerChoice::MP4 && !isCompressedCodecUnlocked()) {
        failureReason_ = "MP4 output supports H.264, HEVC, or AV1.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (isMXF(container_) && isCompressedCodecUnlocked()) {
        failureReason_ = std::string(CodecName(codec_)) + " output is supported only in MOV or MP4.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (isCompressedCodecUnlocked() &&
        (!std::isfinite(bitrateMbps_) || bitrateMbps_ <= 0 || bitrateMbps_ > 10000)) {
        failureReason_ = "Compressed video bitrate must be finite, greater than zero, and at most 10000 Mb/s.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    const AdvancedOptions& advanced = advancedOptions_;
    if (advanced.inputColor > 4 || advanced.audioChannelsPerMXFFile == 0 || advanced.audioChannelsPerMXFFile > 64 ||
        !std::isfinite(advanced.colorPeakNits) || advanced.colorPeakNits < 1 || advanced.colorPeakNits > 10000 ||
        !std::isfinite(advanced.cmuMasteringNits) || advanced.cmuMasteringNits < 0 || advanced.cmuMasteringNits > 10000) {
        failureReason_ = "An audio channel count or luminance setting is outside its supported range.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.replaceSourceAudio && advanced.extraAudioPath.empty()) {
        failureReason_ = "Replace source audio requires an extra audio file.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (!advanced.forcedStartTimecode.empty() && container_ != ContainerChoice::MOV) {
        failureReason_ = "Start timecode override is available only for MOV output.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.aafMode != 0 && !isMXF(container_)) {
        failureReason_ = "AAF output is available only with MXF.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.colorMode == 2 && advanced.lutPath.empty()) {
        failureReason_ = "LUT color conversion requires a LUT file.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.colorMode != 0 && !colorContextAvailableUnlocked()) {
        failureReason_ = "Declare the verified rendered input color before requesting color conversion.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (codec_ == CodecChoice::H264 && advanced.cmuMasteringNits != 0) {
        failureReason_ = "H.264 cannot output Dolby Vision metadata or a Dolby Vision CMU sidecar.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.cmuMasteringNits != 0 && !colorContextAvailableUnlocked()) {
        failureReason_ = "CMU analysis requires a verified rendered input color declaration.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if ((advanced.multiPass != 0 || advanced.bFrames != 0) &&
        codec_ != CodecChoice::H264 && codec_ != CodecChoice::HEVC) {
        failureReason_ = "Multi-pass and B-frames are available only for H.264 or HEVC.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.useDolbyVisionCodecTag && codec_ != CodecChoice::HEVC && codec_ != CodecChoice::AV1) {
        failureReason_ = "Dolby Vision codec tags require HEVC or AV1.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.includeGeneratedDolbyVisionMetadata && advanced.cmuMasteringNits == 0) {
        failureReason_ = "Embedding generated Dolby Vision metadata requires a CMU mastering peak.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (advanced.includeGeneratedDolbyVisionMetadata && dolby_ != DolbyChoice::Generate) {
        failureReason_ = "Generated Dolby Vision embedding requires Generate as the metadata source.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (isMXF(container_) && advanced.includeGeneratedDolbyVisionMetadata) {
        failureReason_ = "ProRes MXF writes generated Dolby Vision as a sidecar XML; embedding is unavailable.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (isMXF(container_) && dolby_ == DolbyChoice::ExternalXML) {
        failureReason_ = "The framework does not accept external Dolby Vision XML for MXF; use CMU-generated sidecar XML.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ == DolbyChoice::ExternalXML && advanced.cmuMasteringNits != 0) {
        failureReason_ = "External Dolby Vision XML and CMU mastering analysis cannot be combined.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ == DolbyChoice::Generate && !colorContextAvailableUnlocked()) {
        failureReason_ = "Generated Dolby Vision requires a verified rendered input color declaration.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ == DolbyChoice::Generate && advanced.cmuMasteringNits == 0) {
        failureReason_ = "Generated Dolby Vision requires a CMU mastering peak.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ == DolbyChoice::ExternalXML && advanced.dolbyVisionXMLPath.empty()) {
        failureReason_ = "External Dolby Vision requires an XML file path.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ != DolbyChoice::Off && codec_ == CodecChoice::H264) {
        failureReason_ = "H.264 Dolby Vision is unsupported by the framework.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ != DolbyChoice::Off && isCompressed(codec_) && advanced.dolbyProfile == 0) {
        failureReason_ = "HEVC or AV1 Dolby Vision requires a profile.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ != DolbyChoice::Off && codec_ == CodecChoice::HEVC &&
        (advanced.dolbyProfile < 1 || advanced.dolbyProfile > 4)) {
        failureReason_ = "HEVC Dolby Vision supports Profiles 5, 7.6, 8.1, and 8.4.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ != DolbyChoice::Off && codec_ == CodecChoice::AV1 &&
        (advanced.dolbyProfile < 5 || advanced.dolbyProfile > 7)) {
        failureReason_ = "AV1 Dolby Vision supports Profiles 10, 10.1, and 10.4.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ == DolbyChoice::Generate && isMXF(container_) && isCompressed(codec_)) {
        failureReason_ = "Generated Dolby Vision metadata is supported only in MOV or MP4 compressed output.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }
    if (dolby_ != DolbyChoice::Off) {
        addObservationUnlocked("dolbyVision=requested; bitstream and metadata still require output verification");
    }
    if (outputPath_.empty()) {
        failureReason_ = "The host has not provided an output path.";
        phase_ = Phase::Configured;
        return Status::InvalidOption;
    }

    failureReason_.clear();
    phase_ = Phase::Validated;
    return Status::Ok;
}

Status ExportSession::validate() {
    std::lock_guard<std::mutex> lock(mutex_);
    return validateUnlocked();
}

Status ExportSession::reopenUnlocked() {
    if (phase_ != Phase::Failed && phase_ != Phase::Cancelled) {
        return Status::Ok;
    }
    phase_ = Phase::Configured;
    failureReason_.clear();
    tracks_.clear();
    frameCompletions_ = 0;
    outputFileCreated_ = false;
    return Status::Ok;
}

Status ExportSession::beginWrite() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Failed || phase_ == Phase::Cancelled) {
        reopenUnlocked();
    }
    if (phase_ == Phase::Configured) {
        const Status validated = validateUnlocked();
        if (validated != Status::Ok) {
            return validated;
        }
    }
    if (phase_ != Phase::Validated && phase_ != Phase::Writing) {
        failureReason_ = "BeginWrite requires a validated job.";
        return Status::InvalidState;
    }
    phase_ = Phase::Writing;
    return Status::Ok;
}

Status ExportSession::noteMetadata(const std::string& source, std::uint32_t count) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Cancelled || phase_ == Phase::Failed || phase_ == Phase::Committed || phase_ == Phase::Draining) {
        failureReason_ = "Metadata arrived after the job was closed.";
        return Status::InvalidState;
    }
    addObservationUnlocked(source + " count=" + std::to_string(count));
    return Status::Ok;
}

Status ExportSession::noteSample(std::uint32_t track, std::uint64_t sample, std::uint64_t sampleCount, std::uint64_t bytes) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Cancelled) {
        return Status::Cancelled;
    }
    if (phase_ != Phase::Writing) {
        failureReason_ = "Samples arrived outside the writing phase.";
        return Status::InvalidState;
    }
    TrackObservation& observation = tracks_[track];
    if (!observation.seen) {
        observation.firstSample = sample;
        observation.seen = true;
    }
    observation.lastSample = sample;
    observation.samples += sampleCount;
    observation.bytes += bytes;
    return Status::Ok;
}

Status ExportSession::noteFrameComplete(std::uint64_t) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Cancelled) {
        return Status::Cancelled;
    }
    if (phase_ != Phase::Writing) {
        return Status::InvalidState;
    }
    // NotifyFrameIsComplete ends cross-track input for one frame. It does not
    // mean the encoder or container has been drained.
    frameCompletions_ += 1;
    return Status::Ok;
}

Status ExportSession::finishWrite() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Cancelled) {
        return Status::Cancelled;
    }
    if (phase_ != Phase::Writing && phase_ != Phase::Draining) {
        failureReason_ = "FinishWrite requires an active write.";
        return Status::InvalidState;
    }
    phase_ = Phase::Draining;
    // No output file is created. The framework has no frame-stream ABI that
    // this plug-in can call, so committing a container would be a false success.
    outputFileCreated_ = false;
    failureReason_ = "No output file was written. ProResEncoderFramework does not expose a C or Objective-C frame-stream session, so host samples were recorded and then discarded.";
    phase_ = Phase::Failed;
    return Status::EncoderBoundary;
}

Status ExportSession::completeWrite() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Cancelled) {
        return Status::Cancelled;
    }
    if (phase_ != Phase::Writing && phase_ != Phase::Draining) {
        failureReason_ = "Complete requires an active write.";
        return Status::InvalidState;
    }
    outputFileCreated_ = true;
    failureReason_.clear();
    phase_ = Phase::Committed;
    return Status::Ok;
}

Status ExportSession::failWrite(const std::string& reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Cancelled) {
        return Status::Cancelled;
    }
    outputFileCreated_ = false;
    failureReason_ = reason;
    phase_ = Phase::Failed;
    return Status::EncoderBoundary;
}

Status ExportSession::cancel() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (phase_ == Phase::Committed) {
        failureReason_ = "CancelWrite cannot roll back a committed file.";
        return Status::InvalidState;
    }
    phase_ = Phase::Cancelled;
    outputFileCreated_ = false;
    failureReason_ = "Export cancelled. No output file was written.";
    return Status::Cancelled;
}

void ExportSession::addObservationUnlocked(std::string text) {
    if (observations_.size() >= kMaxObservations) {
        return;
    }
    observations_.push_back(std::move(text));
}

void ExportSession::addObservation(std::string text) {
    std::lock_guard<std::mutex> lock(mutex_);
    addObservationUnlocked(std::move(text));
}

std::vector<std::string> ExportSession::observations() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return observations_;
}

std::map<std::uint32_t, TrackObservation> ExportSession::tracks() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return tracks_;
}

std::uint64_t ExportSession::frameCompletions() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return frameCompletions_;
}

int ExportSession::runContractSelfCheck() {
    int failures = 0;
    int step = 0;
    auto expect = [&failures, &step](bool condition) {
        step += 1;
        if (!condition) {
            std::fprintf(stderr, "contract step %d failed\n", step);
            failures += 1;
        }
    };

    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mov");
        expect(session.validate() == Status::Ok);
        expect(session.phase() == Phase::Validated);
        expect(session.beginWrite() == Status::Ok);
        expect(session.noteSample(1, 0, 1, 16) == Status::Ok);
        expect(session.noteFrameComplete(0) == Status::Ok);
        expect(session.finishWrite() == Status::EncoderBoundary);
        expect(session.phase() == Phase::Failed);
        expect(!session.outputFileCreated());
        expect(session.tracks().at(1).samples == 1);
        expect(session.frameCompletions() == 1);
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mov");
        session.setCodec(CodecChoice::H264);
        session.setDolby(DolbyChoice::Generate);
        expect(session.validate() == Status::InvalidOption);
        expect(!session.dolbyVisionRequested());
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mxf");
        session.setCodec(CodecChoice::HEVC);
        session.setContainer(ContainerChoice::MXFOP1a);
        expect(session.validate() == Status::InvalidOption);
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mp4");
        session.setCodec(CodecChoice::ProRes422HQ);
        session.setContainer(ContainerChoice::MP4);
        expect(session.validate() == Status::InvalidOption);
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mp4");
        session.setCodec(CodecChoice::H264);
        session.setContainer(ContainerChoice::MP4);
        session.setBitrateMbps(27.5);
        expect(session.validate() == Status::Ok);
        expect(session.bitrateMbps() == 27.5);
        session.resetOptions();
        expect(session.bitrateMbps() == 50);
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mov");
        session.setCodec(CodecChoice::HEVC);
        session.setDolby(DolbyChoice::Generate);
        expect(session.validate() == Status::InvalidOption);
        expect(!session.dolbyVisionRequested());
        session.setProjectColorKnown(true);
        expect(session.validate() == Status::InvalidOption);
        expect(!session.dolbyVisionRequested());
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mov");
        session.setCodec(CodecChoice::HEVC);
        session.setDolby(DolbyChoice::ExternalXML);
        AdvancedOptions options;
        options.dolbyVisionXMLPath = "/tmp/example.xml";
        options.dolbyProfile = 3;
        options.outputVideoRaw = true;
        options.multiPass = 2;
        options.bFrames = 2;
        session.setAdvancedOptions(options);
        expect(session.validate() == Status::Ok);
        expect(session.dolbyVisionRequested());
        expect(session.advancedOptions().outputVideoRaw);
        expect(session.beginWrite() == Status::Ok);
        expect(session.applyOptions(CodecChoice::H264, ContainerChoice::MP4, DolbyChoice::Off,
                                    AudioRouteChoice::BounceMix, 25, AdvancedOptions{}) == Status::InvalidState);
        expect(session.codec() == CodecChoice::HEVC);
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mxf");
        session.setCodec(CodecChoice::ProRes422HQ);
        session.setContainer(ContainerChoice::MXFOP1a);
        session.setDolby(DolbyChoice::Generate);
        session.setProjectColorKnown(true);
        AdvancedOptions options;
        options.cmuMasteringNits = 1000;
        session.setAdvancedOptions(options);
        expect(session.validate() == Status::Ok);
        options.includeGeneratedDolbyVisionMetadata = true;
        session.setAdvancedOptions(options);
        expect(session.validate() == Status::InvalidOption);
        options.includeGeneratedDolbyVisionMetadata = false;
        options.cmuMasteringNits = 0;
        options.dolbyVisionXMLPath = "/tmp/example.xml";
        session.setAdvancedOptions(options);
        session.setDolby(DolbyChoice::ExternalXML);
        expect(session.validate() == Status::InvalidOption);
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mov");
        AdvancedOptions options;
        options.colorMode = 1;
        session.setAdvancedOptions(options);
        expect(session.validate() == Status::InvalidOption);
        options.colorMode = 0;
        options.replaceSourceAudio = true;
        session.setAdvancedOptions(options);
        expect(session.validate() == Status::InvalidOption);
    }
    {
        ExportSession session;
        session.setOutputPath("/tmp/prores-ama-contract.mov");
        expect(session.noteSample(1, 0, 1, 1) == Status::InvalidState);
        expect(session.validate() == Status::Ok);
        expect(session.beginWrite() == Status::Ok);
        expect(session.cancel() == Status::Cancelled);
        expect(session.finishWrite() == Status::Cancelled);
        expect(!session.outputFileCreated());
        expect(session.beginWrite() == Status::Ok);
        expect(session.phase() == Phase::Writing);
    }
    return failures;
}

}  // namespace prores_ama
