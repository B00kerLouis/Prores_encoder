// mxf_enc.h — MXF OP-1a / OP-Atom encoder (standards-oriented architecture)
// Consolidated from NativeMXF_impl.h + MXFStreamWriter.h/.cpp
// References: SMPTE 377-1:2011, SMPTE RDD-36
//
// Architecture: single context-based encoder with three-phase write.
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
    Encoder();
    ~Encoder();
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

    int64_t frameCount() const;
    bool isOpen() const;
    const std::string& lastError() const;
    const std::string& filePath() const;

    /// 32-byte UMID of the Source Package written into the MXF.
    /// Valid after a successful open(). Use as the AAF SourceMob MobID.
    const UMID32& sourcePackageUMID() const;

private:
    struct Ctx;
    std::unique_ptr<Ctx> ctx_;
};

// ---- SMPTE audio cadence helpers ----
int samplesForFrame(int64_t frameIdx, int fpsNum, int fpsDen, int sampleRate);
int64_t totalSamplesForFrames(int64_t nFrames, int fpsNum, int fpsDen, int sampleRate);

// ---- Color UL constants (used by DirectProResEncoder) ----
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
