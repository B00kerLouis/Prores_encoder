// Dispatches MXF operations to the selected OP-1a or OP-Atom writer.
// Exposes shared color identifiers and audio cadence helpers.

#include "../include/mxf_common.h"

namespace mxf {

// Create the concrete writer selected by the public dispatcher.
std::unique_ptr<EncoderImpl> createOp1aEncoder();
std::unique_ptr<EncoderImpl> createOpAtomEncoder();

// ============================================================
//  Color UL constants (exported via mxf_enc.h)
// ============================================================
const UL16 COLOR_PRIMARIES_BT709  = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x06,0x04,0x01,0x01,0x01,0x03,0x03,0x00,0x00};
const UL16 COLOR_PRIMARIES_BT2020 = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,0x04,0x01,0x01,0x01,0x03,0x03,0x00,0x00};
const UL16 COLOR_PRIMARIES_P3D65  = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,0x04,0x01,0x01,0x01,0x03,0x06,0x00,0x00};
const UL16 TRANSFER_BT709         = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x01,0x04,0x01,0x01,0x01,0x01,0x02,0x00,0x00};
const UL16 TRANSFER_ST2084        = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,0x04,0x01,0x01,0x01,0x01,0x08,0x00,0x00};
const UL16 TRANSFER_HLG           = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,0x04,0x01,0x01,0x01,0x01,0x0e,0x00,0x00};
const UL16 TRANSFER_LINEAR        = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,0x04,0x01,0x01,0x01,0x01,0x09,0x00,0x00};
const UL16 MATRIX_BT709           = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x01,0x04,0x01,0x01,0x01,0x02,0x02,0x00,0x00};
const UL16 MATRIX_BT2020          = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,0x04,0x01,0x01,0x01,0x02,0x06,0x00,0x00};
const UL16 MATRIX_SMPTE240M       = {0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,0x04,0x01,0x01,0x01,0x02,0x03,0x00,0x00};

// ============================================================
//  Audio cadence helpers (SMPTE)
// ============================================================
// Returns the exact audio cadence sample count for one video edit unit.
int samplesForFrame(int64_t idx, int fpsNum, int fpsDen, int sr) {
    if(idx < 0 || fpsNum <= 0 || fpsDen <= 0 || sr <= 0) return 0;
    const __int128 rateNumerator = static_cast<__int128>(sr) * fpsDen;
    const __int128 current = static_cast<__int128>(idx) * rateNumerator / fpsNum;
    const __int128 next = (static_cast<__int128>(idx) + 1) * rateNumerator / fpsNum;
    const __int128 count = next - current;
    return count > std::numeric_limits<int>::max()
        ? std::numeric_limits<int>::max()
        : static_cast<int>(count);
}
// Returns the rounded total audio samples assigned to a frame range.
int64_t totalSamplesForFrames(int64_t n, int fpsNum, int fpsDen, int sr) {
    if(n <= 0 || fpsNum <= 0 || fpsDen <= 0 || sr <= 0) return 0;
    const __int128 numerator =
        static_cast<__int128>(n) * sr * fpsDen + fpsNum / 2;
    const __int128 count = numerator / fpsNum;
    return count > std::numeric_limits<int64_t>::max()
        ? std::numeric_limits<int64_t>::max()
        : static_cast<int64_t>(count);
}

// ============================================================
//  Encoder — public API (delegates to EncoderImpl)
// ============================================================
// Owns the selected writer behind the stable public encoder object.
struct Encoder::Ctx {
    std::unique_ptr<EncoderImpl> impl;
    std::string error;
    UMID32 emptyUMID{};
};

// Creates an encoder without selecting an operational pattern.
Encoder::Encoder() : ctx_(std::make_unique<Ctx>()) {}
// Finalizes an active writer before releasing its context.
Encoder::~Encoder() { if(ctx_->impl && ctx_->impl->isOpen()) ctx_->impl->close(); }

// Selects the operational pattern and opens its concrete writer.
bool Encoder::open(const std::string& path, const Config& cfg) {
    ctx_->error.clear();
    const auto variant = static_cast<uint8_t>(cfg.variant);
    const bool audioOnly = cfg.opFormat == OPFormat::OPAtom && variant == 0 &&
        cfg.width == 0 && cfg.height == 0 && !cfg.audioTracks.empty();
    if(path.empty() ||
       (cfg.opFormat != OPFormat::OP1a && cfg.opFormat != OPFormat::OPAtom) ||
       cfg.fpsNum <= 0 || cfg.fpsDen <= 0 || cfg.totalFrames < 0 ||
       (!audioOnly && (cfg.width <= 0 || cfg.height <= 0))) {
        ctx_->error = "open: invalid path or video configuration";
        return false;
    }
    if((!audioOnly && (variant < static_cast<uint8_t>(ProResVariant::Proxy) ||
                      variant > static_cast<uint8_t>(ProResVariant::XQ))) ||
       cfg.audioTracks.size() > std::numeric_limits<uint8_t>::max()) {
        ctx_->error = "open: unsupported variant or audio track count";
        return false;
    }
    if(cfg.opFormat == OPFormat::OP1a)
        ctx_->impl = createOp1aEncoder();
    else
        ctx_->impl = createOpAtomEncoder();
    return ctx_->impl->open(path, cfg);
}

// Forwards one edit unit to the selected writer.
bool Encoder::writeFrame(const uint8_t* video, size_t videoSize,
    const std::vector<const uint8_t*>& audio,
    const std::vector<size_t>& audioSizes)
{
    ctx_->error.clear();
    if(!ctx_->impl) { ctx_->error = "writeFrame: encoder is not open"; return false; }
    if(audio.size() != audioSizes.size()) {
        ctx_->error = "writeFrame: audio pointer and size counts differ";
        return false;
    }
    if(videoSize > 0 && !video) {
        ctx_->error = "writeFrame: nonempty essence has a null buffer";
        return false;
    }
    for(size_t index = 0; index < audioSizes.size(); ++index) {
        if(audioSizes[index] > 0 && !audio[index]) {
            ctx_->error = "writeFrame: nonempty essence has a null buffer";
            return false;
        }
    }
    return ctx_->impl->writeFrame(video, videoSize, audio, audioSizes);
}

// Forwards a video-only edit unit.
bool Encoder::writeVideoFrame(const uint8_t* data, size_t size) {
    return writeFrame(data, size, {}, {});
}

// Forwards an audio-only edit unit.
bool Encoder::writeAudioFrame(const uint8_t* data, size_t size) {
    std::vector<const uint8_t*> a = {data};
    std::vector<size_t> as = {size};
    return writeFrame(nullptr, 0, a, as);
}

// Finalizes the selected writer.
bool Encoder::close() {
    ctx_->error.clear();
    if(!ctx_->impl) { ctx_->error = "close: encoder is not open"; return false; }
    return ctx_->impl->close();
}

// Returns the accepted edit-unit count.
int64_t Encoder::frameCount() const { return ctx_->impl ? ctx_->impl->frameCount() : 0; }
// Reports whether a concrete writer is active.
bool Encoder::isOpen() const { return ctx_->impl && ctx_->impl->isOpen(); }
// Returns the concrete writer's latest error.
const std::string& Encoder::lastError() const {
    return !ctx_->error.empty()
        ? ctx_->error
        : (ctx_->impl ? ctx_->impl->lastError() : ctx_->error);
}
// Returns the concrete writer's output path.
const std::string& Encoder::filePath() const {
    static const std::string empty;
    return ctx_->impl ? ctx_->impl->filePath() : empty;
}
// Returns the concrete writer's source-package UMID.
const UMID32& Encoder::sourcePackageUMID() const {
    return ctx_->impl ? ctx_->impl->sourcePackageUMID() : ctx_->emptyUMID;
}

} // namespace mxf
