# AGENTS.md

Use `B00kerLouis` as the sole first-party author in project notices and new Git
author/committer fields. Do not add AI co-author trailers. Preserve required
third-party copyright and license notices.

This file records the architecture and license constraints for the ProRes Encoder project, including the Media Composer AMA plug-in.

## Toolchain

- Xcode project: `prores encoder.xcodeproj`
- Swift language mode: 6.0
- Framework and CLI deployment target: macOS 14.0, with the project default at 15.7 where a target does not override it
- AMA plug-in deployment target: macOS 14.0, arm64 only

## Targets

- `prores encoder`: command-line tool. Swift, C++, Objective-C++, and Metal sources that already belonged to the encoder stay here.
- `ProResEncoderFramework`: the encoder framework. Do not change its public behavior to satisfy the plug-in.
- `ProResEncoderAMA`: bundle product `ProResEncoderAMA.avx`. New plug-in runtime code is Objective-C++ under `prores encoder/avid_plugin/`.
- `ProResEncoderAMAContractTests`: command-line contract check for the Avid-free export session.
- `Build All`: builds the CLI, the framework, the AMA bundle, and the contract test.

The `prores encoder` synchronized folder excludes `avid_plugin` from the CLI and framework targets. Avid headers are not part of the Swift bridging header.

The AMA bundle uses `CFBundlePackageType=APPL` and Xcode-generated `Contents/PkgInfo=APPL????`, matching installed Avid AMA bundles. Without PkgInfo, macOS classifies a copied `.avx` as a folder. After changing the bundle metadata, an old Build path may retain a stale Spotlight type; verify a fresh deployment copy.

## Avid SDK

`ThirdParty/AvidSDK/` is a local copy of the headers and static libraries required to compile the plug-in:

- `amasdk/include`
- `amasdk/lib` (`libamautillib_s.a`, `libamautillib_sd.a`)
- `acfsdk/inc`, `acfsdk/utils`, `acfsdk/schema`
- `aafsdk/include`

Source package: AMA-SDK 3.5.11 in `AMA-SDK-3rd-party-mac`. `ThirdParty/AvidSDK.manifest.sha256` stores relative paths and hashes only.

The SDK payload is licensed Avid material and remains gitignored. Only the eight first-party README placement files under `ThirdParty/AvidSDK/` are allowlisted for publication. Never commit SDK headers, support sources, libraries, manifests or SDK documentation, including to a private repository. Public CI without the SDK does not build the AMA target.

## Encoder boundary

`ProResFrameStreamSession` is an added Objective-C class in the framework. Supported BGRA options use the direct frame-stream encoder; other options use a temporary ProRes carrier and the existing public `ProResEncoder.encode` API. On the first export frame, the AMA bundle starts its embedded `ProResEncoderAMAWorker`, which resolves the class with `NSBundle`. The AVX registration Mach-O has no encoder framework load command. H.264 Dolby Vision remains invalid. HEVC and AV1 Dolby Vision require a real XML or generated metadata source, a profile, and successful output verification.

The writer's AMA XML maps the public single-file `ProResEncodeOptions` fields: codec, container, numeric bitrate, external audio file, replace/delete source audio, start timecode, Dolby Vision XML/profile, MXF audio channel grouping, direct/LUT color conversion, CMU nits, metadata embedding/tag, raw video, multi-pass, B-frames, and AAF mode. `ProResFrameStreamSession` accepts those values as a validated Objective-C dictionary and passes them to the existing Swift options. `ProResElementaryStreamOptions`, folder/timeline workflows, and CLI-only CBR/VBR/all-intra/recovery controls remain separate gaps; do not present them as completed AMA features.

## Color, Dolby Vision, and audio

- Project primaries, transfer, matrix, and range are recorded as unavailable. They are not defaulted to Rec.2020/PQ.
- `GetImageFormat` describes the buffer the plug-in requests. It is not the project color.
- H.264 with Dolby Vision metadata is an invalid option.
- Generated Dolby Vision requires a verified rendered-input declaration; this is separate from an unavailable host project-color query. Native acceptance is scoped in `docs/feature-coverage.md`.
- Bounce Mix and Bounce Multitrack select a requested host route. Numeric host audio settings are logged when present. That is not proof of Media Composer AAC packets.

## Verification

`ProResEncoderAMAContractTests` checks the Avid-free session's option matrix, bitrate state, cancellation and worker transport. Its no-output finish check covers an unused session branch, not the live writer bridge. It does not load Media Composer. Current native acceptance and remaining audio/reference-picture gaps are scoped in `docs/feature-coverage.md`.

On 2026-09-23, an earlier signed debug bundle loaded in Media Composer 26.8 arm64 and the host reached Ready. At 17:06, 17 minutes after Ready, the host recorded `CORE_AUDIO_STREAM_ID_ERROR1` and exited. A run without the plug-in reached Ready and exited normally after about 12 minutes, without this error; the observation interval was shorter and cannot establish causality. A new debug bundle with lazy framework loading reached Ready at 17:25. `lsof` showed the AMA Mach-O loaded and the encoder framework absent at startup. Continue the host comparison, including a project and clip, before claiming the Core Audio issue resolved. Export settings UI and actual media output also require a selected host project and clip.


## AMA debugging state — 2026-09-30

- Required acceptance is real Media Composer invocation of full-duration ProRes Proxy and Dolby Vision Profile 5 HEVC. Rec.709 is in scope. Synthetic frame tests do not count as host acceptance.
- File and volume writers expose IUncompressedImageConsumer as well as their sample consumers. The generic SMPTE Uncompressed Picture Coding label is required to trigger the writer format query in MC 26.8; CodecDefinition UIDs do not select this path.
- MC delivered 2420x1668 BGRA buffers with 30000/1001 edit rate. The cold sequence repeatedly stalled at 5813 frames in its effect graph. Rendering all 64 selected-track effects through MC allowed the host to deliver all 20320 frames; cold rendering is not fixed by that observation.
- Full delivery currently reaches successful ISampleConsumer Cleanup but host finishing reports std::exception before a logged FinishWrite callback. This remains unpassed. A local-symbol framework loader is the current focused comparison, not a proven fix.
- AMAHDRToneMapper is Objective-C++ runtime code compiled only into ProResEncoderAMA. It maps declared Rec.709, Rec.2020/PQ, Rec.2020/HLG or P3/PQ RGB frames to actual Rec.2020/PQ pixels before CMU when HEVC Profile 5 is selected. An explicit render-color declaration is distinct from a host project-color query; unknown project properties are never defaulted to PQ.
- New files under avid_plugin require explicit membership exceptions for both synchronized CLI and framework targets, plus an explicit AMA Sources entry. A folder exception alone does not exclude future child files in this Xcode project.
- Standalone diagnostic ProRes frame streaming measured 20.36x at 2420x1668 for 20320 generated frames, and BGRA/Metal/P010/HEVC measured 3.47x for 180 generated frames. These diagnose codec throughput only.
- The new frame facade/direct stream helpers are used by the AMA bridge. Existing public file encode functions retain their option validation and behavior; all automatic HDR tone mapping is in the AMA bundle. Do not broaden unrelated CLI or framework color behavior while fixing this export.

## GitHub Release packaging — 2026-10-10

- First-party project notices and new Git author/committer fields use `B00kerLouis`.
- `build/Release/ProResEncoderAMA.avx` is the arm64 Release runtime bundle, including the worker and encoder framework. AAF and SVT-AV1 are statically linked into the encoder framework. The bundle has an ad hoc signature and `PkgInfo=APPL????`.
- Publish only reviewed source/configuration, ordinary usage documentation, and the allowlisted runtime products. SDK files, SDK manifests, build logs, debug symbols, and research records remain local.
- Public CI builds the CLI and framework, runs the Avid-free contract checks, and validates/packages the checked-in AVX. It does not build the SDK-dependent target or establish host export acceptance.
- The worker implementation is the current export path. Earlier lazy loading and local-symbol loader comparisons are historical observations; full-duration Media Composer ProRes Proxy and Dolby Vision Profile 5 HEVC acceptance remains unpassed.


## Current AMA implementation

The dated host observations above are historical. Use `docs/feature-coverage.md`
for the current supported scope and remaining acceptance gaps.

- The Objective-C++ AMA bridge requests progressive packed 10.6 video-range
  pictures for declared Rec.709 and Rec.2020 input. Rec.2020/PQ uses the host's
  supported 709 YCbCr coding equations while retaining Rec.2020 RGB primaries
  and PQ transfer. Matrix coding and RGB color declaration are separate facts.
  P3 and unknown declarations retain the BGRA fallback.
- Color conversion belongs to the existing shared `MetalColorPipeline`.
  Generated compatible fallback profiles prepare a truthful selected-gamut PQ
  half-float carrier before CMU. HLG base profiles apply a real final transform;
  eligible ProRes and single-pass Profile 5 paths stream frames directly.
- Private carrier and final movie time scales preserve the supplied rational
  edit rate. The private AMA AV1 replay path uses bounded software decoding;
  ordinary public decoder defaults remain unchanged. Codec callback delivery
  preserves FIFO order before muxing.
- Worker transport has a total monotonic transfer deadline, scoped buffer
  ownership and cancellable finish. The protocol supports BGRA8, packed 10.6
  and RGBAHalf. AVX registration does not load the encoder framework at startup.
- `ColorPixelContracts.swift` and `ProfileMatrixCheckpoints.swift` are optional
  SDK-free deterministic regressions. The older `--hdr` contract exercises the
  retained legacy mapper, not the active shared color implementation.
- Publish reviewed source/configuration, usage documentation and allowlisted
  runtime products only. Keep user media, diagnostics, measurements, source
  snapshots, SDK payload and detailed research records local.

## Current container and audio implementation

- The Framework owns native Matroska indexing and packet muxing. H.264, HEVC,
  AV1 and the existing Dolby Vision profiles are supported for MKV. Reading
  selects primary video/audio and omits unselected tracks, subtitles and attachments.
- MOV/MP4/MKV preserve source and containerized external audio packets and
  sample descriptions without requiring a registered decoder. Do not assume an
  input audio codec or silently convert it to PCM or AAC. MXF retains its own
  existing audio behavior. Preserve opaque codec configuration and track references.
- AMA receives host-rendered audio separately from pictures. Bounce Mix combines
  delivered left/right sample words losslessly; Direct Out retains host track order.
  Host render-format negotiation is not an assertion about source-file codecs.
- The CLI can use the native Hybrid MOV path for eligible single-source jobs.
  Audio, timed metadata, unsupported options and Matroska input use the ordinary
  encoder path. Hybrid checkpoints and media payloads remain on the output volume.
- Keep local SDK payload, user media, research records and build logs out of Git.
  The public runtime bundle and deterministic SDK-free tests may be published.
