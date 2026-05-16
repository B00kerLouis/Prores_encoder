// mxf_enc.cpp — MXF encoder dispatcher (thin facade)
//
// Delegates to Op1aEncoder or OpAtomEncoder via EncoderImpl polymorphism.
// Keeps: public Encoder class, color UL constants, audio cadence helpers.
//
// References: SMPTE 377-1:2011, SMPTE RDD-36

#include "../include/mxf_common.h"

namespace mxf {

// Factory functions defined in mxf_op1a_enc.cpp / mxf_opatom_enc.cpp
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
int samplesForFrame(int64_t idx, int fpsNum, int fpsDen, int sr) {
    if(fpsNum <= 0 || fpsDen <= 0 || sr <= 0) return 0;
    int64_t base = (int64_t)sr * fpsDen / fpsNum;
    int64_t rem  = (int64_t)sr * fpsDen % fpsNum;
    return (int)(base + ((idx*rem%fpsNum + rem >= fpsNum) ? 1 : 0));
}
int64_t totalSamplesForFrames(int64_t n, int fpsNum, int fpsDen, int sr) {
    if(n <= 0 || fpsNum <= 0 || fpsDen <= 0 || sr <= 0) return 0;
    return (n*(int64_t)sr*fpsDen + fpsNum/2) / fpsNum;
}

// ============================================================
//  Encoder — public API (delegates to EncoderImpl)
// ============================================================
struct Encoder::Ctx {
    std::unique_ptr<EncoderImpl> impl;
};

Encoder::Encoder() : ctx_(std::make_unique<Ctx>()) {}
Encoder::~Encoder() { if(ctx_->impl && ctx_->impl->isOpen()) ctx_->impl->close(); }

bool Encoder::open(const std::string& path, const Config& cfg) {
    if(cfg.opFormat == OPFormat::OP1a)
        ctx_->impl = createOp1aEncoder();
    else
        ctx_->impl = createOpAtomEncoder();
    return ctx_->impl->open(path, cfg);
}

bool Encoder::writeFrame(const uint8_t* video, size_t videoSize,
    const std::vector<const uint8_t*>& audio,
    const std::vector<size_t>& audioSizes)
{
    return ctx_->impl->writeFrame(video, videoSize, audio, audioSizes);
}

bool Encoder::writeVideoFrame(const uint8_t* data, size_t size) {
    return writeFrame(data, size, {}, {});
}

bool Encoder::writeAudioFrame(const uint8_t* data, size_t size) {
    std::vector<const uint8_t*> a = {data};
    std::vector<size_t> as = {size};
    return writeFrame(nullptr, 0, a, as);
}

bool Encoder::close() { return ctx_->impl->close(); }

int64_t Encoder::frameCount() const { return ctx_->impl->frameCount(); }
bool Encoder::isOpen() const { return ctx_->impl && ctx_->impl->isOpen(); }
const std::string& Encoder::lastError() const { return ctx_->impl->lastError(); }
const std::string& Encoder::filePath() const { return ctx_->impl->filePath(); }
const UMID32& Encoder::sourcePackageUMID() const { return ctx_->impl->sourcePackageUMID(); }

} // namespace mxf
