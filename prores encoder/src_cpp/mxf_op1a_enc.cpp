// mxf_op1a_enc.cpp — MXF OP-1a encoder (extracted from mxf_enc.cpp, unchanged logic)
// References: SMPTE 377-1:2011, SMPTE RDD-36

#include "../include/mxf_common.h"

namespace mxf {

// ============================================================
//  Op1aEncoder — OP-1a interleaved MXF writer
// ============================================================
class Op1aEncoder final : public EncoderImpl {
public:
    Op1aEncoder() = default;
    ~Op1aEncoder() override { if(phase_ == Phase::Streaming) close(); }

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
    uint64_t header_off_ = 0, body_off_ = 0;
    uint64_t footer_field_in_header_ = 0;
    uint64_t essence_start_ = 0;
    std::vector<uint64_t> stream_offsets_;
    std::vector<uint32_t> audio_slices_;
    std::vector<uint8_t> primer_bytes_, meta_bytes_;
    uint64_t header_byte_count_ = 0;
    std::vector<UL16> ess_containers_;
    UL16 vid_key_{};
    std::vector<UL16> aud_keys_;
    std::vector<uint8_t> header_part_klv_, body_part_klv_;
    int fps_round_ = 0;
    int64_t tc_offset_ = 0;
    bool has_audio_ = false;
};

bool Op1aEncoder::open(const std::string& path, const Config& cfg) {
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
    has_audio_ = !cfg.audioTracks.empty();
    int64_t totalF = cfg.totalFrames;

    { auto sl = path.rfind('/'); if(sl!=std::string::npos) ensure_dir(path.substr(0,sl)); }
    if(!io_.open(path)) { error_ = "Cannot create: " + path + " - " + strerror(errno); return false; }

    try {
        UUID16 prefUID=make_uuid(), identUID=make_uuid(), csUID=make_uuid(), ecUID=make_uuid();
        UMID32 matUMID=make_umid(); UUID16 matPkgU=make_uuid();
        srcUMID_ = make_umid();     UUID16 srcPkgU=make_uuid();

        UL16 opPat = UL_OP1A;
        if(has_audio_) ess_containers_ = {EC_BWF, EC_GC, EC_RDD36};
        else           ess_containers_ = {EC_GC, EC_RDD36};

        int aspW=cfg.width, aspH=cfg.height;
        if(aspW>0 && aspH>0) { int a=aspW,bv=aspH; while(bv){int t=bv;bv=a%bv;a=t;} aspW/=a; aspH/=a; }

        std::vector<int64_t> audSamples;
        for(auto& at:cfg.audioTracks)
            audSamples.push_back(totalSamplesForFrames(totalF, cfg.fpsNum, cfg.fpsDen, at.sampleRate));

        UUID16 matTCTrk=make_uuid(),matTCSeq=make_uuid(),matTCComp=make_uuid();
        UUID16 matVidTrk=make_uuid(),matVidSeq=make_uuid(),matVidClip=make_uuid();
        std::vector<UUID16> matAudTrk,matAudSeq,matAudClip;
        UUID16 srcTCTrk=make_uuid(),srcTCSeq=make_uuid(),srcTCComp=make_uuid();
        UUID16 srcVidTrk=make_uuid(),srcVidSeq=make_uuid(),srcVidClip=make_uuid();
        std::vector<UUID16> srcAudTrk,srcAudSeq,srcAudClip;
        UUID16 multiDesc=make_uuid(),vidDesc=make_uuid();
        std::vector<UUID16> audDesc;
        for(size_t i=0;i<cfg.audioTracks.size();i++) {
            matAudTrk.push_back(make_uuid()); matAudSeq.push_back(make_uuid()); matAudClip.push_back(make_uuid());
            srcAudTrk.push_back(make_uuid()); srcAudSeq.push_back(make_uuid()); srcAudClip.push_back(make_uuid());
            audDesc.push_back(make_uuid());
        }

        uint32_t tcTrkID=901, vidTrkID=1001;
        std::vector<uint32_t> audTrkIDs;
        for(size_t i=0;i<cfg.audioTracks.size();i++) audTrkIDs.push_back((uint32_t)(2001+i));

        uint32_t vidTrkNum = rdd36_tracknum(1,EE_RDD36,0);
        std::vector<uint32_t> audTrkNums;
        for(size_t i=0;i<cfg.audioTracks.size();i++) audTrkNums.push_back(bwf_tracknum((uint8_t)(i+1),EE_BWF,0));

        vid_key_ = make_rdd36_key(1,EE_RDD36,0);
        aud_keys_.clear();
        for(size_t i=0;i<cfg.audioTracks.size();i++) aud_keys_.push_back(make_bwf_key((uint8_t)(i+1),EE_BWF,0));

        primer_bytes_ = build_primer();

        meta_bytes_.clear();
        auto append = [&](std::vector<uint8_t> v) { meta_bytes_.insert(meta_bytes_.end(), v.begin(), v.end()); };

        std::string basename;
        { auto sl=path.rfind('/'); auto dot=path.rfind('.');
          if(sl!=std::string::npos) basename=path.substr(sl+1,(dot>sl?dot-sl-1:std::string::npos));
          else basename=(dot!=std::string::npos)?path.substr(0,dot):path; }

        // OP-1a metadata in a broad interoperability order
        append(mk_preface(prefUID,identUID,csUID,opPat,ess_containers_));
        append(mk_content_storage(csUID,{matPkgU,srcPkgU},{ecUID}));

        { std::vector<UUID16> mt={matTCTrk,matVidTrk}; for(auto& u:matAudTrk) mt.push_back(u);
          append(mk_mat_pkg(matPkgU,matUMID,mt)); }

        append(mk_track(matTCTrk,tcTrkID,0,"Timecode",DDEF_TC,cfg.fpsNum,cfg.fpsDen,matTCSeq,true));
        append(mk_sequence(matTCSeq,DDEF_TC,totalF,{matTCComp},true));
        append(mk_tc_comp(matTCComp,totalF,(uint16_t)fps_round_,tc_offset_,cfg.isDropFrame,true));

        append(mk_track(matVidTrk,vidTrkID,0,"Video",DDEF_PIC,cfg.fpsNum,cfg.fpsDen,matVidSeq,true));
        append(mk_sequence(matVidSeq,DDEF_PIC,totalF,{matVidClip},true));
        append(mk_src_clip(matVidClip,DDEF_PIC,totalF,0,srcUMID_,vidTrkID));

        for(size_t i=0;i<cfg.audioTracks.size();i++) {
            append(mk_track(matAudTrk[i],audTrkIDs[i],0,"Audio"+std::to_string(i+1),DDEF_SND,
                cfg.fpsNum,cfg.fpsDen,matAudSeq[i],true));
            append(mk_sequence(matAudSeq[i],DDEF_SND,totalF,{matAudClip[i]},true));
            append(mk_src_clip(matAudClip[i],DDEF_SND,totalF,0,srcUMID_,audTrkIDs[i]));
        }

        { std::vector<UUID16> st={srcTCTrk,srcVidTrk}; for(auto& u:srcAudTrk) st.push_back(u);
          append(mk_src_pkg(srcPkgU,srcUMID_,basename,st,multiDesc)); }

        { std::vector<UUID16> sd={vidDesc}; for(auto& u:audDesc) sd.push_back(u);
          append(mk_multi_desc(multiDesc,cfg.fpsNum,cfg.fpsDen,totalF,EC_GC,sd)); }
        append(mk_cdci(vidDesc,vidTrkID,cfg,aspW,aspH,totalF));
        for(size_t i=0;i<cfg.audioTracks.size();i++) {
            auto& at=cfg.audioTracks[i];
            append(mk_wave(audDesc[i],audTrkIDs[i],at.channelCount,at.bitDepth,at.sampleRate,1,at.sampleRate,audSamples[i]));
        }

        append(mk_track(srcTCTrk,tcTrkID,0,"",DDEF_TC,cfg.fpsNum,cfg.fpsDen,srcTCSeq));
        append(mk_sequence(srcTCSeq,DDEF_TC,totalF,{srcTCComp}));
        append(mk_tc_comp(srcTCComp,totalF,(uint16_t)fps_round_,tc_offset_,cfg.isDropFrame));

        append(mk_track(srcVidTrk,vidTrkID,vidTrkNum,"",DDEF_PIC,cfg.fpsNum,cfg.fpsDen,srcVidSeq));
        append(mk_sequence(srcVidSeq,DDEF_PIC,totalF,{srcVidClip}));
        append(mk_src_clip(srcVidClip,DDEF_PIC,totalF,0,{},0));

        for(size_t i=0;i<cfg.audioTracks.size();i++) {
            append(mk_track(srcAudTrk[i],audTrkIDs[i],audTrkNums[i],"",DDEF_SND,cfg.fpsNum,cfg.fpsDen,srcAudSeq[i]));
            append(mk_sequence(srcAudSeq[i],DDEF_SND,totalF,{srcAudClip[i]}));
            append(mk_src_clip(srcAudClip[i],DDEF_SND,totalF,0,{},0));
        }

        append(mk_ec_data(ecUID,srcUMID_,2,1));
        append(mk_ident(identUID));

        // Write header
        header_byte_count_ = primer_bytes_.size() + meta_bytes_.size();
        header_off_ = io_.tell();
        header_part_klv_ = build_partition(K_HEADER_OPEN, header_off_, 0, 0,
            header_byte_count_, 0, 0, 0, 0, opPat, ess_containers_);
        size_t bsz = ber_field_sz(header_part_klv_);
        footer_field_in_header_ = header_off_ + 16 + bsz + FOOTER_BODY_OFF;

        io_.write(header_part_klv_);
        io_.write(primer_bytes_);
        io_.write(meta_bytes_);

        // Write body partition
        body_off_ = io_.tell();
        body_part_klv_ = build_partition(K_BODY, body_off_, header_off_, 0,
            0, 0, 0, 0, 1, opPat, ess_containers_);
        io_.write(body_part_klv_);

        essence_start_ = io_.tell();
        if(totalF > 0) {
            stream_offsets_.reserve((size_t)totalF);
            if(has_audio_) audio_slices_.reserve((size_t)totalF);
        }

        phase_ = Phase::Streaming;
        return true;
    } catch(const std::exception& ex) {
        error_ = ex.what(); io_.close(); return false;
    }
}

bool Op1aEncoder::writeFrame(const uint8_t* video, size_t vsz,
    const std::vector<const uint8_t*>& audio, const std::vector<size_t>& asz)
{
    if(phase_ != Phase::Streaming) { error_ = "writeFrame: not streaming"; return false; }

    try {
        uint64_t frameStart = io_.tell();
        stream_offsets_.push_back(frameStart - essence_start_);

        io_.write(build_system_item(nb_frames_, cfg_.fpsNum, cfg_.fpsDen,
            tc_offset_, cfg_.isDropFrame, video!=nullptr, has_audio_));

        if(video && vsz>0) {
            io_.write(vid_key_.data(), 16);
            io_.write_ber(vsz);
            io_.write(video, vsz);
        }

        uint32_t sliceOff = (uint32_t)(io_.tell() - frameStart);
        if(has_audio_) audio_slices_.push_back(sliceOff);

        for(size_t i=0; i<audio.size() && i<aud_keys_.size(); i++) {
            if(audio[i] && asz[i]>0) {
                io_.write(aud_keys_[i].data(), 16);
                io_.write_ber(asz[i]);
                io_.write(audio[i], asz[i]);
            }
        }
        nb_frames_++;
        return true;
    } catch(const std::exception& ex) { error_ = ex.what(); return false; }
}

bool Op1aEncoder::close() {
    if(phase_ != Phase::Streaming) { error_ = "close: not streaming"; return false; }
    try {
        UL16 opPat = UL_OP1A;

        // Build index segments (300 frames per chunk)
        const int IDX_CHUNK = 300;
        std::vector<std::vector<uint8_t>> idxSegs;
        uint32_t indexSID = 2;

        for(int64_t s=0; s<(int64_t)stream_offsets_.size(); s+=IDX_CHUNK) {
            int64_t e = std::min(s+IDX_CHUNK, (int64_t)stream_offsets_.size());
            std::vector<uint64_t> offs(stream_offsets_.begin()+s, stream_offsets_.begin()+e);
            std::vector<uint32_t> asl;
            if(has_audio_ && !audio_slices_.empty())
                asl.assign(audio_slices_.begin()+s, audio_slices_.begin()+e);
            idxSegs.push_back(build_index_segment(cfg_.fpsNum, cfg_.fpsDen, s, offs, asl,
                (int)indexSID, 1, has_audio_, true));
        }
        uint64_t totalIdxBytes = 0;
        for(auto& seg:idxSegs) totalIdxBytes += seg.size();

        // Index partition
        uint64_t idxPartStart = io_.tell();
        if(totalIdxBytes > 0) {
            io_.write(build_partition(K_BODY, idxPartStart, body_off_, 0,
                0, totalIdxBytes, indexSID, 0, 0, opPat, ess_containers_));
            for(auto& seg:idxSegs) io_.write(seg);
        }

        // Footer partition (repeats primer + meta + index)
        uint64_t footerStart = io_.tell();
        uint64_t prevPart = (totalIdxBytes>0) ? idxPartStart : body_off_;

        io_.write(build_partition(K_FOOTER, footerStart, prevPart, footerStart,
            header_byte_count_, totalIdxBytes, indexSID, 0, 0, opPat, ess_containers_));
        io_.write(primer_bytes_);
        io_.write(meta_bytes_);
        for(auto& seg:idxSegs) io_.write(seg);

        // RIP
        std::vector<RIPEntry> rip = {{0,header_off_},{1,body_off_}};
        if(totalIdxBytes>0) rip.push_back({0,idxPartStart});
        rip.push_back({0,footerStart});
        io_.write(build_rip(rip));

        // Patch header: FooterPartition + ClosedComplete
        io_.patch_u64(footer_field_in_header_, footerStart);
        io_.patch_byte(header_off_ + 14, 0x04);

        // Patch body partition: FooterPartition
        { size_t bsz = ber_field_sz(body_part_klv_);
          io_.patch_u64(body_off_ + 16 + bsz + FOOTER_BODY_OFF, footerStart); }

        // Patch index partition: FooterPartition
        if(totalIdxBytes>0) {
            size_t bsz = ber_field_sz(body_part_klv_);
            io_.patch_u64(idxPartStart + 16 + bsz + FOOTER_BODY_OFF, footerStart);
        }

        io_.close();
        phase_ = Phase::Done;
        return true;
    } catch(const std::exception& ex) {
        error_ = ex.what(); io_.close(); phase_ = Phase::Done; return false;
    }
}

// Factory function (called from mxf_enc.cpp dispatcher)
std::unique_ptr<EncoderImpl> createOp1aEncoder() {
    return std::make_unique<Op1aEncoder>();
}

} // namespace mxf
