# Feature coverage

Verification applies to the recorded configurations, not every combination of
all public options. Native Media Composer results are separate from standalone
fixtures and public CI.

## Media Composer export path

The arm64 AMA writeback plug-in starts its embedded worker on the first picture.
The registration module does not load the encoder framework at host startup.
The worker uses the existing framework encoder and shared Metal color pipeline;
it does not reconstruct the timeline from source files or invoke the encoder CLI.

Declared Rec.709 and Rec.2020 inputs use packed high-precision host pictures.
For the tested Rec.2020/PQ host configuration, the packed YCbCr coding matrix is
709 while RGB primaries and transfer remain Rec.2020/PQ. These are independent
properties. Unknown and P3 rendered-input declarations retain the BGRA fallback.
The plug-in cannot query a verified project color context automatically.

Eligible generated HEVC P5 and ProRes routes stream while host frames arrive.
Other generated profiles prepare an actual selected-gamut PQ RGBAHalf ProRes4444XQ
carrier before CMU analysis, then replay it for final encoding. Compatible base
layers use real BT.2020 RGB conversion; P8.4/P10.4 perform a real PQ-to-HLG
conversion. Native P5/P10 use the framework's IPT-PQ-C2 pipeline. Peak metadata
records the transformed master; reconstructed codec/chroma excursions are not
clamped by a mastering tag.

The private frame path preserves rational movie/video timing. Codec callbacks
use serial delivery to retain decode order through mux back-pressure. AMA AV1
carrier replay uses bounded synchronous software ProRes decoding. Public file
encoder defaults and decoder selection are preserved.

## Verified and limited behavior

| Area | Behavior and scope |
|---|---|
| ProRes | Native Proxy exports with composited effects, and tested UHD HDR10/PHDR configurations completed. Other options and historical cold custom-raster stalls remain separate tests. |
| Generated Dolby Vision | HEVC P5/7.6/8.1/8.4 and AV1 P10/10.1/10.4 completed the recorded 21-case matrices for declared Rec.709/Gamma2.4 and Rec.2020/PQ inputs, across Rec.2020 limited to P3-D65, Rec.2020 and P3-D65 output gamuts. |
| Profile validation | Native acceptance requires complete host delivery, successful FinishWrite, normal host UI, whole-movie decoding, exact RPU coverage and zero Dolby bitstream errors. P7.6 also requires enhancement-picture coverage. Short synthetic fixtures do not establish host acceptance. |
| H.264 Dolby Vision | Rejected by the existing framework validation. |
| Color | Shared range/geometry/transfer/primaries GPU contracts cover the active path. An explicit rendered-input declaration is required; GetImageFormat is a buffer request. DCI-P3/ST2084 project input has not been validated. |
| Bitrate and codec controls | AMA numeric bitrate and tri-state multi-pass/B-frame controls map to existing single-file framework options. AV1 normalizes unsupported tri-state controls to encoder default. |
| Containers | MOV/MP4 compressed export paths retain framework restrictions. MP4 rejects ProRes; MXF rejects H.264/HEVC/AV1. |
| Audio | External-file options are mapped. Native host PCM/AAC packet delivery has not been accepted. |
| Timecode and AAF | Standalone forced timecode/AAF paths exist. Nonzero host timecode readback and host sequence mapping remain unverified. |
| External XML and LUT | Controls are mapped; native host acceptance remains unverified. |
| Progress and cancellation | Normal completion and cancellation are supported. MC's estimate can remain unchanged during carrier replay/final encoding. |
| Batch and elementary workflows | Folder/timeline APIs, elementary fan-out and CLI-only CBR/VBR/all-intra/recovery controls are not presented as completed AMA features. |

## Single-file option mapping

AMA maps the existing single-file codec/container, numeric bitrate, external
audio replacement/deletion, start timecode, Dolby XML/profile, MXF grouping,
direct/LUT conversion, CMU peak, metadata/tag, raw-video, multi-pass, B-frame and
AAF controls into `ProResEncodeOptions`. Mapping a field is not proof that every
combination has completed inside Media Composer. Unsupported combinations retain
existing validation rather than silently choosing another codec or profile.

## Building and testing

Use the [local SDK placement guide](../ThirdParty/AvidSDK/README.md) for AMA builds.
Only its directory README placeholders are distributed; licensed SDK files and
local manifests remain ignored. Public CI builds the CLI/framework, runs the
Avid-free CPU contracts, and verifies/packages the checked-in runtime bundle.
It does not build the SDK-dependent AMA target or run Media Composer.

`ProResEncoderAMAContractTests` checks session options, cancellation and worker
transport. `ColorPixelContracts.swift` is an opt-in SDK-free GPU check of the
shared active color path; build the framework with `ENABLE_TESTABILITY=YES` for
its `@testable` import. `ProfileMatrixCheckpoints.swift` supplies deterministic
packed-frame profile/gamut regressions. The legacy `--hdr` contract mode tests
the retained older mapper and is not validation of the active shared path.

Detailed media, logs, measurements, source snapshots and research records remain
local and are not included in GitHub source or runtime packages.
