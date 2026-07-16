// Declares the MXF OP-1a and OP-Atom encoder interface.
// Implements structures defined by SMPTE 377-1:2011 and SMPTE RDD-36.
// The encoder uses a three-phase write sequence.
//   Phase 1: open()       — write header partition + primer + metadata + body partition
//   Phase 2: writeFrame() — per-frame system item + essence KLVs
//   Phase 3: close()      — index table + footer + patch header as ClosedComplete + RIP

#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mxf {

// ---- MXF type aliases ----
using UL16   = std::array<uint8_t, 16>;
using UUID16 = std::array<uint8_t, 16>;
using UMID32 = std::array<uint8_t, 32>;

// ---- ProRes variant (SMPTE RDD-36) ----
enum class ProResVariant : uint8_t {
    Proxy       = 1,
    LT          = 2,
    Standard422 = 3,
    HQ422       = 4,
    K4444       = 5,
    XQ          = 6,
};

// ---- Operational pattern ----
enum class OPFormat { OP1a, OPAtom };

// ---- Audio track configuration ----
struct AudioTrackConfig {
    int channelCount = 2;
    int bitDepth     = 24;
    int sampleRate   = 48000;
};

// ---- Color metadata (optional) ----
struct ColorInfo {
    UL16 colorPrimaries  = {};
    UL16 transferFunction = {};
    UL16 codingEquations  = {};
    bool valid = false;
};

// ---- MXF file configuration ----
struct Config {
    OPFormat       opFormat      = OPFormat::OP1a;
    ProResVariant  variant       = ProResVariant::HQ422;
    int            width         = 1920;
    int            height        = 1080;
    int            fpsNum        = 25;
    int            fpsDen        = 1;
    bool           isDropFrame   = false;
    std::string    startTimecode = "00:00:00:00";
    int64_t        totalFrames   = 0;
    ColorInfo      color;
    std::vector<AudioTrackConfig> audioTracks;
};

// ---- MXF Encoder (context-based writer) ----
class Encoder {
public:
    /// Creates an encoder without opening an output file.
    Encoder();
    /// Finalizes an active writer before releasing its context.
    ~Encoder();
    /// Prevents two encoder objects from owning the same writer context.
    Encoder(const Encoder&) = delete;
    Encoder& operator=(const Encoder&) = delete;

    /// Phase 1: Open file, write header partition + metadata + body partition.
    bool open(const std::string& path, const Config& cfg);

    /// Phase 2: Write one edit unit (video + interleaved audio).
    bool writeFrame(const uint8_t* video, size_t videoSize,
                    const std::vector<const uint8_t*>& audio,
                    const std::vector<size_t>& audioSizes);

    /// Convenience: video-only edit unit.
    bool writeVideoFrame(const uint8_t* data, size_t size);

    /// Convenience: audio-only edit unit (OP-Atom audio file).
    bool writeAudioFrame(const uint8_t* data, size_t size);

    /// Phase 3: Write index table + footer + patch header + RIP.
    bool close();

    /// Number of edit units accepted by the current writer.
    int64_t frameCount() const;
    /// Whether the current writer is accepting edit units.
    bool isOpen() const;
    /// Most recent error reported by the current writer.
    const std::string& lastError() const;
    /// Path of the current output file.
    const std::string& filePath() const;

    /// 32-byte UMID of the Source Package written into the MXF.
    /// Valid after a successful open(). Use as the AAF SourceMob MobID.
    const UMID32& sourcePackageUMID() const;

private:
    struct Ctx;
    std::unique_ptr<Ctx> ctx_;
};

// ---- SMPTE audio cadence helpers ----
/// Audio samples assigned to one video edit unit.
int samplesForFrame(int64_t frameIdx, int fpsNum, int fpsDen, int sampleRate);
/// Total audio samples assigned to a video frame range.
int64_t totalSamplesForFrames(int64_t nFrames, int fpsNum, int fpsDen, int sampleRate);

// ---- Color UL constants shared with the Swift encoding pipeline ----
extern const UL16 COLOR_PRIMARIES_BT709;
extern const UL16 COLOR_PRIMARIES_BT2020;
extern const UL16 COLOR_PRIMARIES_P3D65;
extern const UL16 TRANSFER_BT709;
extern const UL16 TRANSFER_ST2084;
extern const UL16 TRANSFER_HLG;
extern const UL16 TRANSFER_LINEAR;
extern const UL16 MATRIX_BT709;
extern const UL16 MATRIX_BT2020;
extern const UL16 MATRIX_SMPTE240M;

} // namespace mxf
