// mxf_opatom_enc.cpp — MXF OP-Atom encoder (clip-wrapped essence model)
//
// Key differences from previous OP-Atom implementation:
//   1. KAG-512 alignment with KLV fill after header metadata and body partition
//   2. Video clip-wrapping: single EE key + BER9 placeholder, all ProRes frames
//      contiguous (no per-frame KLV). BER9 length patched on close().
//   3. VBR index table in footer (not separate index partition)
//   4. Body partition rewrite on close (update BER9 essence length)
//   5. Audio clip-wrapping: single EE key + BER9, CBR index in footer
//
// References: SMPTE 377-1:2011, SMPTE RDD-36, OP-Atom partition/index behavior

#include "../include/mxf_common.h"

namespace mxf {

// ============================================================
//  OpAtomEncoder — OP-Atom clip-wrapped MXF writer
// ============================================================
class OpAtomEncoder final : public EncoderImpl {
public:
    OpAtomEncoder() = default;
    ~OpAtomEncoder() override { if(phase_ == Phase::Streaming) close(); }

    bool open(const std::string& path, const Config& cfg) override;
    bool writeFrame(const uint8_t* video, size_t videoSize,
                    const std::vector<const uint8_t*>& audio,
                    const std::vector<size_t>& audioSizes) override;
    bool close() override;
    int64_t frameCount() const override { return nb_frames_; }
    bool isOpen() const override { return phase_ == Phase::Streaming; }
    const std::string& lastError() const override { return error_; }
    const std::string& filePath() const override { return path_; }
    const UMID32& sourcePackageUMID() const override { return srcUMID_; }

private:
    enum class Phase { Init, Streaming, Done };
    Phase phase_ = Phase::Init;
    Config cfg_;
    std::string path_, error_;
    FileIO io_;
    int64_t nb_frames_ = 0;
    UMID32 srcUMID_{};

    bool isVideo_ = false;        // true = video file, false = audio file
    UL16 opPat_{};
    std::vector<UL16> ess_containers_;
    UL16 ee_key_{};               // essence element key (video or audio)

    // Partition offsets
    uint64_t header_off_ = 0;
    uint64_t body_off_ = 0;       // body partition start
    uint64_t footer_field_in_header_ = 0;
    std::vector<uint8_t> header_part_klv_;

    // Clip-wrap tracking
    uint64_t body_part_start_ = 0;     // file offset where body partition KLV starts
    uint64_t ee_ber9_off_ = 0;         // file offset of BER9 length field (byte after 0x88 marker)
    uint64_t body_offset_ = 0;         // total clip-wrapped essence bytes written

    // VBR index entries for video (offset within essence blob)
    std::vector<uint64_t> frame_offsets_;

    // CBR audio
    bool cbr_audio_ = false;
    int cbr_bytes_per_sample_ = 0;

    // Metadata cache for header_byte_count computation
    std::vector<uint8_t> primer_bytes_, meta_bytes_;
    uint64_t header_byte_count_ = 0;

    int fps_round_ = 0;
    int64_t tc_offset_ = 0;

    void writeBodyPartition();
};

// ============================================================
//  open() — write header partition + KLV fill + body partition + EE key + BER9
// ============================================================
bool OpAtomEncoder::open(const std::string& path, const Config& cfg) {
    if(phase_ != Phase::Init) { error_ = "open: already in use"; return false; }
    if(cfg.fpsNum <= 0 || cfg.fpsDen <= 0) { error_ = "open: invalid frame rate"; return false; }
    if(cfg.totalFrames < 0) { error_ = "open: invalid frame count"; return false; }
    for(const auto& at : cfg.audioTracks) {
        if(at.channelCount <= 0 || at.sampleRate <= 0 || (at.bitDepth != 16 && at.bitDepth != 24)) {
            error_ = "open: invalid audio configuration";
            return false;
        }
    }
    cfg_ = cfg; path_ = path;
    fps_round_ = (int)((double)cfg.fpsNum/cfg.fpsDen + 0.5);
    tc_offset_ = parse_tc(cfg.startTimecode, fps_round_);
    isVideo_ = (cfg.width > 0);
    opPat_ = UL_OPATOM;
    int64_t totalF = cfg.totalFrames;

    { auto sl = path.rfind('/'); if(sl!=std::string::npos) ensure_dir(path.substr(0,sl)); }
    if(!io_.open(path)) { error_ = "Cannot create: " + path + " - " + strerror(errno); return false; }

    try {
        // Essence container
        if(isVideo_) ess_containers_ = {EC_RDD36};
        else         ess_containers_ = {EC_BWF};

        // Essence element key
        if(isVideo_) ee_key_ = make_rdd36_key(1, EE_RDD36, 0);
        else         ee_key_ = make_bwf_key(1, EE_BWF, 0);

        // CBR audio detection
        if(!isVideo_ && !cfg.audioTracks.empty()) {
            auto& at = cfg.audioTracks[0];
            cbr_audio_ = true;
            cbr_bytes_per_sample_ = at.channelCount * at.bitDepth / 8;
        }

        // Aspect ratio
        int aspW=cfg.width, aspH=cfg.height;
        if(aspW>0 && aspH>0) { int a=aspW,bv=aspH; while(bv){int t=bv;bv=a%bv;a=t;} aspW/=a; aspH/=a; }

        // Audio total samples
        std::vector<int64_t> audSamples;
        for(auto& at:cfg.audioTracks)
            audSamples.push_back(totalSamplesForFrames(totalF, cfg.fpsNum, cfg.fpsDen, at.sampleRate));

        // ---- Generate UUIDs ----
        UUID16 prefUID=make_uuid(), identUID=make_uuid(), csUID=make_uuid(), ecUID=make_uuid();
        UMID32 matUMID=make_umid(); UUID16 matPkgU=make_uuid();
        srcUMID_ = make_umid();     UUID16 srcPkgU=make_uuid();

        uint32_t tkID=2, tcID=1;
        uint32_t tkNum = isVideo_ ? rdd36_tracknum(1,EE_RDD36,0) : bwf_tracknum(1,EE_BWF,0);
        UL16 ddef = isVideo_ ? DDEF_PIC : DDEF_SND;

        UUID16 matTCTrk=make_uuid(),matTCSeq=make_uuid(),matTCComp=make_uuid();
        UUID16 mTrk=make_uuid(),mSeq=make_uuid(),mClip=make_uuid();
        UUID16 srcTCTrk=make_uuid(),srcTCSeq=make_uuid(),srcTCComp=make_uuid();
        UUID16 sTrk=make_uuid(),sSeq=make_uuid(),sClip=make_uuid();
        UUID16 descU=make_uuid();

        std::string basename;
        { auto sl=path.rfind('/'); auto dot=path.rfind('.');
          if(sl!=std::string::npos) basename=path.substr(sl+1,(dot>sl?dot-sl-1:std::string::npos));
          else basename=(dot!=std::string::npos)?path.substr(0,dot):path; }

        // ---- Build Primer ----
        primer_bytes_ = build_primer();

        // ---- Build Metadata ----
        meta_bytes_.clear();
        auto append = [&](std::vector<uint8_t> v) { meta_bytes_.insert(meta_bytes_.end(), v.begin(), v.end()); };

        append(mk_preface(prefUID,identUID,csUID,opPat_,ess_containers_));
        append(mk_ident(identUID));
        append(mk_content_storage(csUID,{matPkgU,srcPkgU},{ecUID}));
        append(mk_ec_data(ecUID,srcUMID_,2,1));

        // Material Package
        append(mk_mat_pkg(matPkgU,matUMID,{matTCTrk,mTrk}));
        append(mk_track(matTCTrk,tcID,0,"Timecode",DDEF_TC,cfg.fpsNum,cfg.fpsDen,matTCSeq));
        append(mk_sequence(matTCSeq,DDEF_TC,totalF,{matTCComp}));
        append(mk_tc_comp(matTCComp,totalF,(uint16_t)fps_round_,tc_offset_,cfg.isDropFrame));

        if(isVideo_) {
            append(mk_track(mTrk,tkID,0,"Video",ddef,cfg.fpsNum,cfg.fpsDen,mSeq));
            append(mk_sequence(mSeq,ddef,totalF,{mClip}));
            append(mk_src_clip(mClip,ddef,totalF,0,srcUMID_,tkID));
        } else {
            auto& at=cfg.audioTracks[0];
            int64_t aDur = audSamples.empty() ? 0 : audSamples[0];
            append(mk_track(mTrk,tkID,0,"Audio",ddef,at.sampleRate,1,mSeq));
            append(mk_sequence(mSeq,ddef,aDur,{mClip}));
            append(mk_src_clip(mClip,ddef,aDur,0,srcUMID_,tkID));
        }

        // Source Package
        append(mk_src_pkg(srcPkgU,srcUMID_,basename,{srcTCTrk,sTrk},descU));
        append(mk_track(srcTCTrk,tcID,0,"Timecode",DDEF_TC,cfg.fpsNum,cfg.fpsDen,srcTCSeq));
        append(mk_sequence(srcTCSeq,DDEF_TC,totalF,{srcTCComp}));
        append(mk_tc_comp(srcTCComp,totalF,(uint16_t)fps_round_,tc_offset_,cfg.isDropFrame));

        if(isVideo_) {
            append(mk_track(sTrk,tkID,tkNum,"Video",ddef,cfg.fpsNum,cfg.fpsDen,sSeq));
            append(mk_sequence(sSeq,ddef,totalF,{sClip}));
            append(mk_src_clip(sClip,ddef,totalF,0,{},0));
        } else {
            auto& at=cfg.audioTracks[0];
            int64_t aDur = audSamples.empty() ? 0 : audSamples[0];
            append(mk_track(sTrk,tkID,tkNum,"Audio",ddef,at.sampleRate,1,sSeq));
            append(mk_sequence(sSeq,ddef,aDur,{sClip}));
            append(mk_src_clip(sClip,ddef,aDur,0,{},0));
        }

        // Descriptor
        if(isVideo_) {
            append(mk_cdci(descU,tkID,cfg,aspW,aspH,totalF));
        } else if(!cfg.audioTracks.empty()) {
            auto& at=cfg.audioTracks[0];
            int64_t aDur = audSamples.empty() ? 0 : audSamples[0];
            append(mk_wave(descU,tkID,at.channelCount,at.bitDepth,
                at.sampleRate,1,at.sampleRate,aDur));
        }

        // ============================================================
        //  Write Header Partition (with KAG-512 alignment)
        // ============================================================
        header_byte_count_ = primer_bytes_.size() + meta_bytes_.size();
        header_off_ = io_.tell();

        // Header partition: ClosedComplete will be patched at close()
        // KAG=512 for OP-Atom alignment
        header_part_klv_ = build_partition(K_HEADER_OPEN, header_off_, 0, 0,
            header_byte_count_, 0, 0, 0, 0, opPat_, ess_containers_, KAG_SIZE);
        size_t bsz = ber_field_sz(header_part_klv_);
        footer_field_in_header_ = header_off_ + 16 + bsz + FOOTER_BODY_OFF;

        io_.write(header_part_klv_);
        io_.write(primer_bytes_);
        io_.write(meta_bytes_);

        // KLV fill to align to KAG-512
        write_klv_fill(io_);

        // ============================================================
        //  Write Body Partition + EE key + BER9 placeholder
        //  using the OP-Atom clip-wrapped layout
        // ============================================================
        writeBodyPartition();

        // Reserve space for VBR index
        if(isVideo_ && totalF > 0) {
            frame_offsets_.reserve((size_t)totalF);
        }

        phase_ = Phase::Streaming;
        return true;
    } catch(const std::exception& ex) {
        error_ = ex.what(); io_.close(); return false;
    }
}

// Helper: write body partition + KLV fill + EE key + BER9 placeholder
void OpAtomEncoder::writeBodyPartition() {
    body_off_ = io_.tell();
    body_part_start_ = body_off_;

    // Body partition with BodySID=1
    auto body_klv = build_partition(K_BODY, body_off_, header_off_, 0,
        0, 0, 0, 0, 1, opPat_, ess_containers_, KAG_SIZE);
    io_.write(body_klv);

    // KLV fill to KAG-512 alignment
    write_klv_fill(io_);

    // Write EE key (16 bytes)
    io_.write(ee_key_.data(), 16);

    // BER9 placeholder (9 bytes: 0x88 marker + 8-byte length, to be patched at close)
    std::vector<uint8_t> ber9_placeholder;
    ber9(ber9_placeholder, body_offset_);  // initially 0
    // The 8-byte length starts at offset +1 (after the 0x88 marker byte)
    ee_ber9_off_ = io_.tell() + 1;
    io_.write(ber9_placeholder);
}

// ============================================================
//  writeFrame() — append essence data (clip-wrapped)
// ============================================================
bool OpAtomEncoder::writeFrame(const uint8_t* video, size_t vsz,
    const std::vector<const uint8_t*>& audio, const std::vector<size_t>& asz)
{
    if(phase_ != Phase::Streaming) { error_ = "writeFrame: not streaming"; return false; }

    try {
        if(isVideo_) {
            // Video clip-wrap: track per-frame offset for VBR index, write raw data
            if(video && vsz > 0) {
                frame_offsets_.push_back(body_offset_);
                io_.write(video, vsz);
                body_offset_ += vsz;
            }
        } else {
            // Audio clip-wrap: write raw PCM data directly (no per-frame KLV)
            if(!audio.empty() && audio[0] && asz[0] > 0) {
                io_.write(audio[0], asz[0]);
                body_offset_ += asz[0];
            }
        }
        nb_frames_++;
        return true;
    } catch(const std::exception& ex) { error_ = ex.what(); return false; }
}

// ============================================================
//  close() — footer partition (with index) + body rewrite + header patch
// ============================================================
bool OpAtomEncoder::close() {
    if(phase_ != Phase::Streaming) { error_ = "close: not streaming"; return false; }
    try {
        // ============================================================
        //  1. KLV fill before footer (align to KAG-512)
        // ============================================================
        write_klv_fill(io_);

        // ============================================================
        //  2. Footer partition with index table
        //     OP-Atom VBR -> footer uses IndexSID=2
        //     OP-Atom CBR -> footer also uses IndexSID=2
        // ============================================================
        uint64_t footerStart = io_.tell();

        if(isVideo_) {
            // Video: VBR index in footer
            auto vbrIndex = build_opatom_vbr_index(
                cfg_.fpsNum, cfg_.fpsDen, frame_offsets_, 2, 1);

            io_.write(build_partition(K_FOOTER, footerStart, body_off_, footerStart,
                0, (uint64_t)vbrIndex.size(), 2, 0, 0, opPat_, ess_containers_, KAG_SIZE));
            write_klv_fill(io_);
            io_.write(vbrIndex);
        } else {
            // Audio: CBR index in footer
            int sr = cfg_.audioTracks.empty() ? 48000 : cfg_.audioTracks[0].sampleRate;
            auto cbrIndex = build_audio_cbr_index(sr, 1, cbr_bytes_per_sample_, 2, 1);

            io_.write(build_partition(K_FOOTER, footerStart, body_off_, footerStart,
                0, (uint64_t)cbrIndex.size(), 2, 0, 0, opPat_, ess_containers_, KAG_SIZE));
            write_klv_fill(io_);
            io_.write(cbrIndex);
        }

        // ============================================================
        //  3. KLV fill + RIP
        // ============================================================
        write_klv_fill(io_);
        std::vector<RIPEntry> rip = {{0, header_off_}, {1, body_off_}, {0, footerStart}};
        io_.write(build_rip(rip));

        // ============================================================
        //  4. Patch BER9 length in body partition (total essence bytes)
        //     Seek back to the body partition and update recorded lengths
        // ============================================================
        io_.patch_u64(ee_ber9_off_, body_offset_);

        // ============================================================
        //  5. Rewrite body partition to update EssenceLength
        //     The body partition itself doesn't change, but we update its
        //     FooterPartition field.
        // ============================================================
        {
            // Reconstruct body partition KLV to get BER field size
            auto body_klv = build_partition(K_BODY, body_off_, header_off_, footerStart,
                0, 0, 0, 0, 1, opPat_, ess_containers_, KAG_SIZE);
            size_t bsz = ber_field_sz(body_klv);
            io_.patch_u64(body_off_ + 16 + bsz + FOOTER_BODY_OFF, footerStart);
        }

        // ============================================================
        //  6. Patch header: FooterPartition + ClosedComplete status
        // ============================================================
        io_.patch_u64(footer_field_in_header_, footerStart);
        io_.patch_byte(header_off_ + 14, 0x04);  // ClosedComplete

        io_.close();
        phase_ = Phase::Done;
        return true;
    } catch(const std::exception& ex) {
        error_ = ex.what(); io_.close(); phase_ = Phase::Done; return false;
    }
}

// Factory function (called from mxf_enc.cpp dispatcher)
std::unique_ptr<EncoderImpl> createOpAtomEncoder() {
    return std::make_unique<OpAtomEncoder>();
}

} // namespace mxf
