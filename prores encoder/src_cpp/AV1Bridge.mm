// AV1Bridge.mm — SVT-AV1 encoder bridge used by Swift MOV pipeline.

#import "../include/AV1Bridge.h"

#include "../../ThirdParty/SVT-AV1/include/EbSvtAv1.h"
#include "../../ThirdParty/SVT-AV1/include/EbSvtAv1Enc.h"
#include "../../ThirdParty/SVT-AV1/include/EbSvtAv1Metadata.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {

static constexpr OSType kPixelFormatP010 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
static constexpr OSType kPixelFormatNV12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

static uint16_t readBE16(const uint8_t *p) {
    return static_cast<uint16_t>((p[0] << 8) | p[1]);
}

static uint32_t readBE32(const uint8_t *p) {
    return (static_cast<uint32_t>(p[0]) << 24) |
           (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) |
           static_cast<uint32_t>(p[3]);
}

static NSString *errorString(const char *operation, EbErrorType err) {
    return [NSString stringWithFormat:@"%s failed: 0x%08x", operation, static_cast<uint32_t>(err)];
}

static uint32_t clampedBitrate(int64_t bitrate) {
    if (bitrate <= 0) {
        return 1;
    }
    return static_cast<uint32_t>(std::min<int64_t>(
        bitrate,
        std::numeric_limits<uint32_t>::max()
    ));
}

static std::string masteringDisplayString(NSData *data) {
    if (!data || data.length < 24) {
        return {};
    }
    const auto *p = static_cast<const uint8_t *>(data.bytes);
    const double gx = static_cast<double>(readBE16(p + 0)) / 50000.0;
    const double gy = static_cast<double>(readBE16(p + 2)) / 50000.0;
    const double bx = static_cast<double>(readBE16(p + 4)) / 50000.0;
    const double by = static_cast<double>(readBE16(p + 6)) / 50000.0;
    const double rx = static_cast<double>(readBE16(p + 8)) / 50000.0;
    const double ry = static_cast<double>(readBE16(p + 10)) / 50000.0;
    const double wx = static_cast<double>(readBE16(p + 12)) / 50000.0;
    const double wy = static_cast<double>(readBE16(p + 14)) / 50000.0;
    const double maxLuma = static_cast<double>(readBE32(p + 16)) / 10000.0;
    const double minLuma = static_cast<double>(readBE32(p + 20)) / 10000.0;

    char buf[256];
    std::snprintf(
        buf, sizeof(buf),
        "G(%.6f,%.6f)B(%.6f,%.6f)R(%.6f,%.6f)WP(%.6f,%.6f)L(%.6f,%.6f)",
        gx, gy, bx, by, rx, ry, wx, wy, maxLuma, minLuma
    );
    return std::string(buf);
}

static std::string contentLightString(NSData *data) {
    if (!data || data.length < 4) {
        return {};
    }
    const auto *p = static_cast<const uint8_t *>(data.bytes);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%u,%u", readBE16(p), readBE16(p + 2));
    return std::string(buf);
}

static bool readLeb128(const uint8_t *data, size_t size, size_t &cursor, size_t &value) {
    uint64_t result = 0;
    uint32_t shift = 0;
    while (cursor < size && shift <= 56) {
        const uint8_t byte = data[cursor++];
        result |= static_cast<uint64_t>(byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) {
            value = static_cast<size_t>(result);
            return true;
        }
        shift += 7;
    }
    return false;
}

static std::vector<uint8_t> sequenceHeaderOBU(const std::vector<uint8_t> &data) {
    size_t cursor = 0;
    while (cursor < data.size()) {
        const size_t obuStart = cursor;
        const uint8_t header = data[cursor++];
        const uint8_t obuType = (header >> 3) & 0x0f;
        const bool hasExtension = (header & 0x04) != 0;
        const bool hasSize = (header & 0x02) != 0;
        if (hasExtension) {
            if (cursor >= data.size()) {
                return {};
            }
            cursor += 1;
        }
        size_t payloadSize = 0;
        if (hasSize) {
            if (!readLeb128(data.data(), data.size(), cursor, payloadSize)) {
                return {};
            }
        } else {
            payloadSize = data.size() - cursor;
        }
        if (cursor + payloadSize > data.size()) {
            return {};
        }
        const size_t obuEnd = cursor + payloadSize;
        if (obuType == 1) {
            return std::vector<uint8_t>(data.begin() + static_cast<ptrdiff_t>(obuStart),
                                        data.begin() + static_cast<ptrdiff_t>(obuEnd));
        }
        cursor = obuEnd;
    }
    return {};
}

class BitReader {
public:
    BitReader(const uint8_t *data, size_t size) : data_(data), size_(size) {}

    bool read(uint32_t bits, uint32_t &value) {
        value = 0;
        for (uint32_t i = 0; i < bits; ++i) {
            if (bitOffset_ >= size_ * 8) {
                return false;
            }
            const size_t byteOffset = bitOffset_ / 8;
            const uint8_t bitShift = static_cast<uint8_t>(7 - (bitOffset_ % 8));
            value = (value << 1) | ((data_[byteOffset] >> bitShift) & 1);
            ++bitOffset_;
        }
        return true;
    }

    bool skip(uint32_t bits) {
        uint32_t ignored = 0;
        return read(bits, ignored);
    }

    bool readBool(bool &value) {
        uint32_t bit = 0;
        if (!read(1, bit)) {
            return false;
        }
        value = bit != 0;
        return true;
    }

    bool skipUleb128() {
        uint32_t leadingZeroCount = 0;
        bool bit = false;
        while (true) {
            if (!readBool(bit)) {
                return false;
            }
            if (bit) {
                break;
            }
            ++leadingZeroCount;
            if (leadingZeroCount > 31) {
                return false;
            }
        }
        return skip(leadingZeroCount);
    }

private:
    const uint8_t *data_;
    size_t size_;
    size_t bitOffset_ = 0;
};

static uint8_t parsedSequenceLevel(const std::vector<uint8_t> &sequenceOBU) {
    if (sequenceOBU.empty()) {
        return 31;
    }
    size_t cursor = 1;
    const bool hasExtension = (sequenceOBU[0] & 0x04) != 0;
    const bool hasSize = (sequenceOBU[0] & 0x02) != 0;
    if (hasExtension) {
        if (cursor >= sequenceOBU.size()) {
            return 31;
        }
        cursor += 1;
    }
    size_t payloadSize = sequenceOBU.size() - cursor;
    if (hasSize) {
        if (!readLeb128(sequenceOBU.data(), sequenceOBU.size(), cursor, payloadSize)) {
            return 31;
        }
    }
    if (cursor + payloadSize > sequenceOBU.size()) {
        return 31;
    }

    BitReader reader(sequenceOBU.data() + cursor, payloadSize);
    uint32_t ignored = 0;
    bool flag = false;
    if (!reader.read(3, ignored)) { return 31; }
    if (!reader.readBool(flag)) { return 31; } // still_picture
    bool reducedStillPictureHeader = false;
    if (!reader.readBool(reducedStillPictureHeader)) { return 31; }
    if (reducedStillPictureHeader) {
        uint32_t level = 31;
        return reader.read(5, level) ? static_cast<uint8_t>(level) : 31;
    }

    bool timingInfoPresent = false;
    if (!reader.readBool(timingInfoPresent)) { return 31; }
    bool decoderModelInfoPresent = false;
    if (timingInfoPresent) {
        if (!reader.skip(32) || !reader.skip(32)) { return 31; }
        bool equalPictureInterval = false;
        if (!reader.readBool(equalPictureInterval)) { return 31; }
        if (equalPictureInterval && !reader.skipUleb128()) { return 31; }
        if (!reader.readBool(decoderModelInfoPresent)) { return 31; }
        if (decoderModelInfoPresent) {
            if (!reader.skip(5) || !reader.skip(32) || !reader.skip(32) || !reader.skip(32)) {
                return 31;
            }
        }
    }
    bool initialDisplayDelayPresent = false;
    if (!reader.readBool(initialDisplayDelayPresent)) { return 31; }
    uint32_t operatingPointsMinusOne = 0;
    if (!reader.read(5, operatingPointsMinusOne)) { return 31; }

    uint8_t firstLevel = 31;
    const uint32_t operatingPointCount = std::min<uint32_t>(operatingPointsMinusOne + 1, 32);
    for (uint32_t i = 0; i < operatingPointCount; ++i) {
        if (!reader.skip(12)) { return firstLevel; }
        uint32_t level = 31;
        if (!reader.read(5, level)) { return firstLevel; }
        if (i == 0) {
            firstLevel = static_cast<uint8_t>(level);
        }
        if (level > 7) {
            if (!reader.skip(1)) { return firstLevel; }
        }
        if (decoderModelInfoPresent) {
            bool present = false;
            if (!reader.readBool(present)) { return firstLevel; }
            if (present && (!reader.skip(32) || !reader.skip(32) || !reader.skip(1))) {
                return firstLevel;
            }
        }
        if (initialDisplayDelayPresent) {
            bool present = false;
            if (!reader.readBool(present)) { return firstLevel; }
            if (present && !reader.skip(4)) {
                return firstLevel;
            }
        }
    }
    return firstLevel;
}

static NSData *makeAV1CodecConfigurationRecord(const std::vector<uint8_t> &streamHeader) {
    std::vector<uint8_t> sequenceOBU = sequenceHeaderOBU(streamHeader);
    const uint8_t level = parsedSequenceLevel(sequenceOBU);

    std::vector<uint8_t> record;
    record.reserve(4 + sequenceOBU.size());
    record.push_back(0x81);                         // marker + version
    record.push_back(static_cast<uint8_t>(level));  // seq_profile 0 + seq_level_idx_0
    record.push_back(0x4d);                         // Main10, 4:2:0, left chroma siting
    record.push_back(0x00);                         // no initial presentation delay
    record.insert(record.end(), sequenceOBU.begin(), sequenceOBU.end());
    return [NSData dataWithBytes:record.data() length:record.size()];
}

} // namespace

@implementation AV1BridgeConfig
- (instancetype)init {
    if ((self = [super init])) {
        _width = 1920;
        _height = 1080;
        _fpsNum = 25;
        _fpsDen = 1;
        _bitrateBitsPerSecond = 10'000'000;
    }
    return self;
}
@end

@implementation AV1BridgePacket
- (instancetype)initWithData:(NSData *)data
           presentationIndex:(int64_t)presentationIndex
                    keyframe:(BOOL)keyframe {
    if ((self = [super init])) {
        _data = [data copy];
        _presentationIndex = presentationIndex;
        _keyframe = keyframe;
    }
    return self;
}
@end

@interface AV1Bridge ()
@property (nonatomic, readwrite, nullable, copy) NSData *codecConfigurationRecord;
@property (nonatomic, readwrite, nullable, copy) NSString *lastError;
@end

@implementation AV1Bridge {
    EbComponentType *_encoder;
    EbSvtAv1EncConfiguration _config;
    BOOL _opened;
    BOOL _sentEOS;
}

- (BOOL)openWithConfig:(AV1BridgeConfig *)config {
    [self close];
    self.lastError = nil;
    if (config.width <= 0 || config.height <= 0 || config.fpsNum <= 0 || config.fpsDen <= 0) {
        self.lastError = @"invalid AV1 dimensions or frame rate";
        return NO;
    }

    EbErrorType err = svt_av1_enc_init_handle(&_encoder, &_config);
    if (err != EB_ErrorNone || !_encoder) {
        self.lastError = errorString("svt_av1_enc_init_handle", err);
        return NO;
    }

    _config.source_width = static_cast<uint32_t>(config.width);
    _config.source_height = static_cast<uint32_t>(config.height);
    _config.forced_max_frame_width = static_cast<uint32_t>(config.width);
    _config.forced_max_frame_height = static_cast<uint32_t>(config.height);
    _config.frame_rate_numerator = static_cast<uint32_t>(config.fpsNum);
    _config.frame_rate_denominator = static_cast<uint32_t>(config.fpsDen);
    _config.encoder_bit_depth = 10;
    _config.encoder_color_format = EB_YUV420;
    _config.profile = MAIN_PROFILE;
    _config.level = 0;
    _config.tier = 0;
    _config.color_primaries = static_cast<EbColorPrimaries>(config.colorPrimaries);
    _config.transfer_characteristics =
        static_cast<EbTransferCharacteristics>(config.transferCharacteristics);
    _config.matrix_coefficients =
        static_cast<EbMatrixCoefficients>(config.matrixCoefficients);
    _config.color_range = EB_CR_STUDIO_RANGE;
    _config.chroma_sample_position = EB_CSP_VERTICAL;
    _config.rate_control_mode = SVT_AV1_RC_MODE_VBR;
    _config.target_bit_rate = clampedBitrate(config.bitrateBitsPerSecond);
    _config.pred_structure = RANDOM_ACCESS;
    _config.hierarchical_levels = 4;
    _config.intra_refresh_type = SVT_AV1_FWDKF_REFRESH;
    const int32_t targetKeyIntervalFrames = std::max<int32_t>(
        1,
        static_cast<int32_t>(std::lround((static_cast<double>(config.fpsNum) / config.fpsDen) * 2.0))
    );
    const int32_t miniGop = 1 << _config.hierarchical_levels;
    const int32_t alignedKeyIntervalFrames =
        ((targetKeyIntervalFrames + miniGop - 1) / miniGop) * miniGop;
    _config.intra_period_length = alignedKeyIntervalFrames - 1;
    _config.enc_mode = 8;
    _config.enable_overlays = 0;
    _config.scene_change_detection = 1;

    const std::string mastering = masteringDisplayString(config.masteringDisplayColorVolume);
    if (!mastering.empty()) {
        svt_aom_parse_mastering_display(&_config.mastering_display, mastering.c_str());
    }
    const std::string cll = contentLightString(config.contentLightLevelInfo);
    if (!cll.empty()) {
        svt_aom_parse_content_light_level(&_config.content_light_level, cll.c_str());
    }

    err = svt_av1_enc_set_parameter(_encoder, &_config);
    if (err != EB_ErrorNone) {
        self.lastError = errorString("svt_av1_enc_set_parameter", err);
        [self close];
        return NO;
    }
    err = svt_av1_enc_init(_encoder);
    if (err != EB_ErrorNone) {
        self.lastError = errorString("svt_av1_enc_init", err);
        [self close];
        return NO;
    }

    EbBufferHeaderType *streamHeader = nullptr;
    err = svt_av1_enc_stream_header(_encoder, &streamHeader);
    if (err == EB_ErrorNone && streamHeader && streamHeader->p_buffer && streamHeader->n_filled_len > 0) {
        std::vector<uint8_t> bytes(streamHeader->p_buffer, streamHeader->p_buffer + streamHeader->n_filled_len);
        self.codecConfigurationRecord = makeAV1CodecConfigurationRecord(bytes);
        svt_av1_enc_stream_header_release(streamHeader);
    } else {
        self.codecConfigurationRecord = makeAV1CodecConfigurationRecord({});
    }

    _opened = YES;
    _sentEOS = NO;
    return YES;
}

- (nullable NSArray<AV1BridgePacket *> *)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
                                         presentationIndex:(int64_t)presentationIndex {
    if (!_opened || !_encoder) {
        self.lastError = @"AV1 encoder is not open";
        return nil;
    }
    if (![self fillAndSendPixelBuffer:pixelBuffer presentationIndex:presentationIndex]) {
        return nil;
    }
    return [self drainPacketsBlocking:NO];
}

- (nullable NSArray<AV1BridgePacket *> *)finish {
    if (!_opened || !_encoder) {
        return @[];
    }
    if (!_sentEOS) {
        EbBufferHeaderType eos{};
        eos.size = sizeof(EbBufferHeaderType);
        eos.flags = EB_BUFFERFLAG_EOS;
        eos.pic_type = EB_AV1_INVALID_PICTURE;
        EbErrorType err = svt_av1_enc_send_picture(_encoder, &eos);
        if (err != EB_ErrorNone) {
            self.lastError = errorString("svt_av1_enc_send_picture(EOS)", err);
            return nil;
        }
        _sentEOS = YES;
    }
    NSArray<AV1BridgePacket *> *packets = [self drainPacketsBlocking:YES];
    [self close];
    return packets;
}

- (void)close {
    if (_encoder) {
        if (_opened) {
            svt_av1_enc_deinit(_encoder);
        }
        svt_av1_enc_deinit_handle(_encoder);
    }
    _encoder = nullptr;
    _opened = NO;
    _sentEOS = NO;
}

- (void)dealloc {
    [self close];
}

- (BOOL)fillAndSendPixelBuffer:(CVPixelBufferRef)pixelBuffer
             presentationIndex:(int64_t)presentationIndex {
    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (pixelFormat != kPixelFormatP010 && pixelFormat != kPixelFormatNV12) {
        self.lastError = [NSString stringWithFormat:@"unsupported AV1 source pixel format: %u", pixelFormat];
        return NO;
    }

    const size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t chromaWidth = (width + 1) / 2;
    const size_t chromaHeight = (height + 1) / 2;

    std::vector<uint16_t> y(width * height);
    std::vector<uint16_t> u(chromaWidth * chromaHeight);
    std::vector<uint16_t> v(chromaWidth * chromaHeight);

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (pixelFormat == kPixelFormatP010) {
        const auto *srcY = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
        const auto *srcUV = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
        const size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        const size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        for (size_t row = 0; row < height; ++row) {
            const auto *line = reinterpret_cast<const uint16_t *>(srcY + row * yStride);
            for (size_t col = 0; col < width; ++col) {
                y[row * width + col] = line[col] >> 6;
            }
        }
        for (size_t row = 0; row < chromaHeight; ++row) {
            const auto *line = reinterpret_cast<const uint16_t *>(srcUV + row * uvStride);
            for (size_t col = 0; col < chromaWidth; ++col) {
                u[row * chromaWidth + col] = line[col * 2] >> 6;
                v[row * chromaWidth + col] = line[col * 2 + 1] >> 6;
            }
        }
    } else {
        const auto *srcY = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
        const auto *srcUV = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
        const size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        const size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        for (size_t row = 0; row < height; ++row) {
            const auto *line = srcY + row * yStride;
            for (size_t col = 0; col < width; ++col) {
                y[row * width + col] = static_cast<uint16_t>(line[col]) << 2;
            }
        }
        for (size_t row = 0; row < chromaHeight; ++row) {
            const auto *line = srcUV + row * uvStride;
            for (size_t col = 0; col < chromaWidth; ++col) {
                u[row * chromaWidth + col] = static_cast<uint16_t>(line[col * 2]) << 2;
                v[row * chromaWidth + col] = static_cast<uint16_t>(line[col * 2 + 1]) << 2;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    EbSvtIOFormat planes{};
    planes.luma = reinterpret_cast<uint8_t *>(y.data());
    planes.cb = reinterpret_cast<uint8_t *>(u.data());
    planes.cr = reinterpret_cast<uint8_t *>(v.data());
    planes.y_stride = static_cast<uint32_t>(width);
    planes.cb_stride = static_cast<uint32_t>(chromaWidth);
    planes.cr_stride = static_cast<uint32_t>(chromaWidth);

    EbBufferHeaderType header{};
    header.size = sizeof(EbBufferHeaderType);
    header.p_buffer = reinterpret_cast<uint8_t *>(&planes);
    header.n_filled_len = static_cast<uint32_t>((y.size() + u.size() + v.size()) * sizeof(uint16_t));
    header.pts = presentationIndex;
    header.dts = presentationIndex;
    header.pic_type = EB_AV1_INVALID_PICTURE;
    header.flags = 0;

    EbErrorType err = svt_av1_enc_send_picture(_encoder, &header);
    if (err != EB_ErrorNone) {
        self.lastError = errorString("svt_av1_enc_send_picture", err);
        return NO;
    }
    return YES;
}

- (nullable NSArray<AV1BridgePacket *> *)drainPacketsBlocking:(BOOL)blocking {
    NSMutableArray<AV1BridgePacket *> *packets = [NSMutableArray array];
    while (true) {
        EbBufferHeaderType *output = nullptr;
        EbErrorType err = svt_av1_enc_get_packet(_encoder, &output, blocking ? 1 : 0);
        if (err == EB_NoErrorEmptyQueue) {
            break;
        }
        if (err == EB_ErrorMax) {
            self.lastError = @"SVT-AV1 returned an encode error";
            return nil;
        }
        if (err != EB_ErrorNone || !output) {
            self.lastError = errorString("svt_av1_enc_get_packet", err);
            return nil;
        }

        const uint32_t flags = output->flags;
        const BOOL eos = (flags & EB_BUFFERFLAG_EOS) != 0;
        const BOOL altRef = (flags & EB_BUFFERFLAG_IS_ALT_REF) != 0;
        if (!eos && !altRef && output->p_buffer && output->n_filled_len > 0) {
            NSData *data = [NSData dataWithBytes:output->p_buffer length:output->n_filled_len];
            const BOOL keyframe =
                output->pic_type == EB_AV1_KEY_PICTURE ||
                output->pic_type == EB_AV1_INTRA_ONLY_PICTURE ||
                output->pic_type == EB_AV1_FW_KEY_PICTURE;
            AV1BridgePacket *packet = [[AV1BridgePacket alloc]
                initWithData:data
           presentationIndex:output->pts
                    keyframe:keyframe];
            [packets addObject:packet];
        }
        svt_av1_enc_release_out_buffer(&output);
        if (eos) {
            break;
        }
    }
    return packets;
}

@end
