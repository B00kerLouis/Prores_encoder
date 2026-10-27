# ProRes Encoder 1.2.5

Author: [B00kerLouis](https://github.com/B00kerLouis).

Native macOS CLI and Framework for professional video encoding, HDR color
conversion, dynamic metadata processing, MOV/MP4/MKV/MXF mastering, linked timeline
workflows, batch encoding, and external-audio replacement.

MOV remains the default container. H.264, HEVC, and AV1 can also be written to
MP4 or MKV with `-ef mp4` / `-ef mkv`, or by giving `-o` the corresponding
`.mp4` / `.mkv` extension. `--outupt-video-raw`
(`-ovr`) writes the final encoded video elementary stream; Dolby Vision Profile
7.6 writes its required separate BL and EL HEVC streams.

## What’s New in 1.2.5

- Fix known issues

## License

This project is licensed under the GNU Affero General Public License v3.0 for
general public use. See [LICENSE](LICENSE).

A designated commercial-license grant may be provided in the LICENSE file for
specific organizations and their eligible subsidiaries or controlled affiliates.
That grant applies only to source code owned by this project.

## Bundled Dependencies

The AV1 encoder integration uses the bundled SVT-AV1 library. AAF interchange
uses the bundled AAF Framework. Their files and license terms remain separate
from project-owned source code.

The project license and any designated commercial-license exception do not
relicense those bundled dependencies.

## Media Composer AMA

Build All also builds `ProResEncoderAMA.avx`, an AMA writeback bundle. Its
Objective-C++ sources are not part of the CLI or framework targets. The Avid
SDK payload it compiles against stays local in `ThirdParty/AvidSDK/` and must
not be published. The repository includes only first-party directory READMEs;
the [SDK placement guide](ThirdParty/AvidSDK/README.md) explains how licensed
SDK owners can populate those locations and build. The bundle is packaged like the installed Avid AMA
plug-ins, with `CFBundlePackageType=APPL` and `Contents/PkgInfo=APPL????`.
Media Composer 26.8 on this machine loaded the signed arm64 bundle at startup.
The encoder framework is embedded. On the first export picture, the plug-in
starts its bundled `ProResEncoderAMAWorker`, which loads that framework with
`NSBundle`. The registration Mach-O has no encoder framework load command.
The AMA parameter XML maps the existing single-file
`ProResEncodeOptions` fields, including codec/container, numeric bitrate,
timecode, audio file replacement, Dolby Vision, color/LUT, raw video, B-frames,
multi-pass, and AAF. Native Media Composer 26.8 exports have been verified for
the tested ProRes and generated HEVC/AV1 Dolby Vision configurations described
in [feature coverage](docs/feature-coverage.md). H.264 Dolby Vision remains
unsupported. Project color lookup is unavailable: select an explicit, verified
rendered-input gamut/transfer. A requested buffer format does not identify the
project color space. Timeline PCM delivery with Delete source audio Off has
completed a full native export; Bounce Mix packages the delivered left/right
words as one stereo stream. Host-encoded AAC, external XML/LUT and nonzero host
timecode remain separate acceptance work.

The arm64 Release bundle is checked in at
[`build/Release/ProResEncoderAMA.avx`](build/Release/ProResEncoderAMA.avx).
It includes the worker and encoder framework, uses an ad hoc signature, and
requires macOS 14 or later. Public GitHub Actions build the CLI and framework,
run the Avid-free contract checks, verify the prebuilt AVX package and its
checksums, and package it as `ProResEncoderAMA-arm64.zip`. They do not compile
the AMA target or verify Media Composer exports. Building `Build All` locally
requires your licensed Avid SDK in the documented placeholder directories;
SDK headers, support sources, libraries, manifests, debug symbols and local
research records are excluded from the release files.

## Requirements

- macOS with standard command-line build tools installed.
- Project build support for the included project file.
- Bundled project-owned framework directories kept in their expected locations.
- Self-contained runtime behavior; the CLI does not require users to install
  separate external command-line media tools for normal operation.

## Build

```bash
xcodebuild -project "prores encoder.xcodeproj" \
  -scheme "prores encoder" \
  -configuration Release build
```

The Release binary is written to:

```bash
Build/Release/prores encoder
```

Optional local install:

```bash
cp "Build/Release/prores encoder" ~/bin/proresencoder
```

The CLI embeds its Metal kernel fallback in the Mach-O binary, so the executable
can be copied by itself without a neighboring `default.metallib` or helper
program.

## Framework

The `ProResEncoderFramework` target builds the same native Swift/C++/GPU
encoding pipeline as the CLI:

```bash
xcodebuild -project "prores encoder.xcodeproj" \
  -scheme ProResEncoderFramework \
  -configuration Release build
```

The framework is written to:

```text
Build/Release/ProResEncoderFramework.framework
```

Its public API supports MOV, MXF OP-1a, and MXF OP-Atom output, including the
same gamut, transfer-function, and peak-luminance conversion used by the CLI:

```swift
import ProResEncoderFramework

let encoder = ProResEncoder()
let options = ProResEncodeOptions(
    quality: "422hq",
    forcedOutputStartTimecode: "01:00:00:00",
    colorConversion: ProResColorConversion(
        gamut: .rec709,
        transferFunction: .gamma24,
        targetPeakNits: 100
    )
)

try await encoder.encode(
    inputURL: inputURL,
    outputURL: outputURL,
    options: options
)
```

The framework also embeds the Metal kernel fallback in code. A bundled
`default.metallib` remains compatible with older layouts, but framework clients
do not need to copy a GPU library or invoke helper programs separately.

Set the Framework codec-tag option to `true` only when the target workflow
requires the alternate dynamic-HDR sample entry; its default should remain
`false` for normal output.

Set `ProResEncodeOptions.deleteSourceAudio` to `true` to omit input audio.
It can be combined with `extraAudioURL` so the source audio is removed before
the external track is added.

Framework clients can also fan one input out to independently encoded raw video
streams. Unlike `ProResEncodeOptions.outputVideoRaw` / CLI `-ovr`, this method is
multi-format and raw-only: its temporary MOV staging files are deleted, and the
result contains only `.prores`, `.hevc`, or `.obu` artifacts. Profile 7.6 returns
separate base-layer and enhancement-layer files.

```swift
let rawResult = try await encoder.encodeVideoElementaryStreams(
    inputURL: gradedMasterURL,
    outputDirectoryURL: deliveryDirectoryURL,
    options: ProResElementaryStreamOptions(
        formats: ProResElementaryStreamFormat.allDolbyVision,
        dolbyVisionXMLURL: dolbyVisionXMLURL,
        hevcBitrateMbps: 50,
        profile76BitrateMbps: 80,
        av1BitrateMbps: 50,
        dolbyVisionGamut: .rec2020,
        targetPeakNits: 1_000
    )
)
```

`ProResElementaryStreamFormat.allStandard` includes every ProRes variant plus
plain HEVC and AV1 and is the default. `allCases` adds every Dolby Vision
profile, which requires `dolbyVisionXMLURL`. This batch API is Framework only;
the CLI intentionally has no equivalent multi-format option.

## Native Pipeline Architecture

- MOV is the default container; MP4 is available for H.264, HEVC, and AV1.
- Source decode for compressed inputs uses native media sessions plus project
  pixel conversion and chroma downsampling.
- Dynamic HDR metadata generation and writing are implemented in project code,
  then packaged into the selected output bitstream or metadata track.
- Enhanced-layer workflows perform closed-loop base-layer encode and
  reconstruction, derive a residual signal on the GPU, encode the enhanced
  layer, and interleave metadata directly into output samples.
- CLI encoding emits no separate elementary-stream files unless
  `--outupt-video-raw` (`-ovr`) is explicitly requested. Framework clients may
  instead use the raw-only multi-format batch API described above.

Final compressed samples are inspected before the file is accepted:

- HEVC output uses a verifier-oriented sample entry by default, including
  streams carrying dynamic HDR metadata.
- AV1 output similarly uses a verifier-oriented sample entry by default.
- Profile 5 writes `dvh1` and Profile 7.6 writes `dvhe`. Cross-compatible Profile
  8.1 / 8.4 retain `hvc1`, and Profile 10.1 retains `av01`; these sample entries
  are required for Dolby verifier container conformance. `--dv-flag` / `-df` selects
  `dav1` only for AV1 Profile 10 and 10.4, where that entry is valid.
- A requested dynamic HDR metadata encode fails instead of returning a file if
  the finalized stream contains no requested metadata.

## Basic Usage

```bash
proresencoder -i input.mov -o output.mov
```

Set output quality:

```bash
proresencoder -i input.mov -q 422hq -o output.mov
proresencoder -i input.mov -q 4444xq -o output.mov
```

Supported quality values:

```text
proxy, 422lt, 422, 422hq, 4444, 4444xq, pass, h264, hevc, av1
```

H.264 and HEVC use VBR by default. Use `--cbr` for constant bitrate, or pass
`--vbr` explicitly. `--all-intra` makes every encoded H.264/HEVC frame an
I-frame and cannot be combined with `--b-frames on`. GOP encodes (the default)
use B-frame reordering, including Dolby Vision Profile 5. Pass `--b-frames off`
to encode I/P only. The flag is optional and defaults to on. Profile 7.6 always
encodes I/P so the independent BL and EL VideoToolbox sessions emit matching
picture types; `--b-frames on` is ignored for that profile. The hardware HEVC
encoder chooses its own consecutive B-frame count when reordering is on.

`--muti-pass on|off` (also `--multi-pass`) controls VideoToolbox multi-pass
H.264/HEVC encoding (`VTMultiPassStorage`, `VTFrameSilo`, Begin/EndPass). It
defaults to on for GOP encodes and off for `--all-intra`; either default can
be overridden. Dolby Vision profile selection does not change this default.
Each extra pass re-reads only the time ranges VideoToolbox requested; pixel
buffers are not retained between passes.

```bash
proresencoder -i input.mov -o output.mp4 -q h264 -b 40 --all-intra --cbr
proresencoder -i input.mov -o output.mov -q hevc -b 50 --vbr
proresencoder -i input.mov -o output.mov -q hevc -b 50 --b-frames off
proresencoder -i input.mov -o output.mov -q hevc -b 50 --muti-pass off
```

Use `pass` when you want a stream copy where supported:

```bash
proresencoder -i input.mov -q pass -o output.mov
```

## GPU Color Conversion and Tone Mapping

The three target-color options are atomic: all three must be present, or
encoding is refused.

```bash
proresencoder -i hdr.mov -o sdr.mov -q 422hq \
  --gamut rec709 \
  --oetf gamma2.4 \
  --nit 100
```

Supported targets:

- `--gamut` or `--color-space` `rec709|rec2020|rec2020lm|p3d65`
- `--oetf gamma2.4|gamma2.6|pq|hlg`
- `--nit <target peak nits>`, from 1 through 10000

The source gamut and transfer function are read from the input video metadata.
Rec.709, Rec.2020, and P3-D65 sources with Gamma 2.4, Gamma 2.6, PQ, or HLG
are supported. Pixel processing runs on the GPU before ProRes/HEVC/AV1
submission; there is no CPU color-conversion fallback.

`--nit` controls the actual pixel luminance mapping. Already-mastered programme
material is mapped with a display-referred EETF-style curve and a matched
inverse for range expansion. This provides one monotonic mapping for HDR-to-SDR,
SDR-to-HDR, HDR-to-HDR, and SDR-to-SDR conversions. Equal source/target peaks
remain colorimetric; different peaks preserve tonal separation while mapping
the detected source peak to the requested target peak.

When these options are omitted, the encoder keeps its previous behavior and
does not perform color conversion or tone mapping.

`--gamunt` was the original misspelled option. It remains accepted for backward
compatibility and prints a deprecation warning.

## Metal LUT Burn-In

Burn a `.cube` LUT into the encoded pixels with the LUT's declared output color
space. LUT processing uses the built-in parser and GPU texture sampling without
invoking a separate media-processing executable.

```bash
proresencoder -i input.mov -o graded.mov -q 422hq \
  --lut look.cube \
  --gamut-lut rec709 \
  --oetf-lut gamma2.4 \
  --nit-lut 100
```

`--color-space-lut` is an alias for `--gamut-lut`. The LUT form supports 1D,
3D, and combined 1D+3D `.cube` files, including `TITLE`, comments,
`DOMAIN_MIN`, `DOMAIN_MAX`, `LUT_1D_INPUT_RANGE`, and `LUT_3D_INPUT_RANGE`.
The 1D table is applied first, followed by the 3D table with Metal linear
sampling. `--lut` and its three `*-lut` target options are atomic and cannot
be combined with direct `--gamut`/`--color-space`, `--oetf`, and `--nit`
mapping. LUT burn-in is also rejected with Dolby Vision XML/RPU metadata,
because those metadata must be generated from the graded pixels.

## Metadata Analysis and Inclusion

Generate an analyzed XML sidecar:

```bash
proresencoder -i hdr.mov -o prores.mov -q 422hq --cmu 1000
```

For ProRes/MXF output, metadata analysis writes only the `.xml` sidecar; it does
not create JSON or Markdown log files. HEVC/AV1 output can use a temporary XML
internally and remove it after encoding.

Add `--cmu-include` to use the generated XML directly as the native metadata
source. Do not also pass an external metadata XML:

```bash
# ProRes MOV: remux the encoded video with a metadata track
proresencoder -i hdr.mov -o prores_metadata.mov -q 422hq \
  --cmu 1000 --cmu-include

# HEVC Profile 8.1: generate and inject one metadata unit per frame
proresencoder -i hdr.mov -o hevc_metadata.mov -q hevc -b 50 -dp 81 \
  --cmu 1000 --cmu-include

# HEVC Profile 5: convert Rec.2020/PQ to Native IPT-PQ-C2 with Metal
proresencoder -i hdr.mov -o hevc_native_p5.mov -q hevc -b 50 -dp 5 \
  --gamut rec2020 --oetf pq --nit 1000 \
  --cmu 1000 --cmu-include

# HEVC enhanced-layer workflow
proresencoder -i hdr.mov -o hevc_enhanced.mov -q hevc -b 80 -dp 76 \
  --cmu 1000 --cmu-include

# AV1 Native Profile 10: full-range IPT-PQ-C2 plus T.35/EMDF RPU
proresencoder -i hdr.mov -o av1_native_p10.mov -q av1 -b 50 -dp 10 \
  --gamut rec2020 --oetf pq --nit 1000 \
  --cmu 1000 --cmu-include

# AV1 Profile 10.1: HDR10-compatible base layer
proresencoder -i hdr.mov -o av1_p101.mov -q av1 -b 50 -dp 101 \
  --cmu 1000 --cmu-include
```

For AV1 Profile 10 or 10.4, add `--dv-flag` / `-df` when the target workflow requires
the valid `dav1` sample entry:

```bash
proresencoder -i hdr.mov -o av1_native.mov -q av1 -b 50 -dp 10 \
  -dovi metadata.xml -df
proresencoder -i hdr.mov -o av1_hlg.mov -q av1 -b 50 -dp 104 \
  -dovi metadata.xml -df
```

Profile arguments are strict integers: `-dp 5` is HEVC Profile 5, `-dp 10`
is Native AV1 Profile 10, `-dp 101` is Profile 10.1, and `-dp 104` is Profile
10.4. Decimal aliases such as `10.1` and the former `100` alias are rejected.
Profile 5 and Native Profile 10 accept only direct `rec2020`, `rec2020lm`, or
`p3d65` output together with `pq` and `--nit`. The declared PQ reference pixels
are then converted to full-range IPT-PQ-C2; they are not tagged or encoded as an
HDR10 base layer. Without `-df`, P5/P10 keep the ordinary `hvc1`/`av01` sample
entry for verifier compatibility. `-df` changes only the reserved player-facing
sample entry to `dvh1`/`dav1`; it does not alter pixels, RPU, or bitstream
processing. These additions target stream, color, RPU/EMDF, and container
conformance.

`--cmu` and `-dovi` are mutually exclusive.
`--cmu-include` requires `--cmu`, supports MOV or compressed MP4 output, and requires the
matching `-dp` value for HEVC or AV1. For HEVC/AV1, the internally generated
XML is converted to one native metadata unit per frame and injected during the
encode; for ProRes it is embedded as a metadata track.

## Output Formats

MOV:

```bash
proresencoder -i input.mov -ef mov -q 422hq -o output.mov
proresencoder -i input.mov -ef mov -q hevc -b 50 -o output_hevc.mov
proresencoder -i input.mov -ef mov -q av1 -b 50 -o output_av1.mov
proresencoder -i input.mov -ef mp4 -q hevc -b 50 -o output_hevc.mp4
proresencoder -i input.mov -q av1 -b 50 -o output_av1.mp4  # infers MP4
```

The CLI defaults to `.mov` and normalizes an explicit `-ef mov` output to that
extension. `-ef mp4`, or a `.mp4` `-o` filename when `-ef` is omitted, selects
MP4; MP4 accepts H.264, HEVC, and AV1. `-ovr` writes `*_raw.prores`,
`*_raw.h264`, `*_raw.hevc`, or `*_raw.obu` next to the container. With HEVC Dolby
Vision Profile 7.6 it instead writes `*_P7_6_BL.hevc` and `*_P7_6_EL.hevc`.

### Matroska input and output

```bash
proresencoder -i input.mkv -q hevc -b 50 -o output.mkv
proresencoder -i input.mkv -q h264 -b 20 -o output.mp4
proresencoder -i input.mov -q av1 -b 50 -ef mkv -o output.mkv
```

MKV supports H.264, HEVC and AV1, including the encoder's HEVC Dolby Vision
P5/7.6/8.1/8.4 and AV1 P10/10.1/10.4 configurations. Existing profile, frame-rate
and color requirements still apply. QuickTime timecode tracks remain MOV-only.
The Framework exposes `ProResOutputFormat.mkv`, and AMA exposes MKV in Container.

MKV input selects the default enabled video/audio track, or the first enabled
track when no default exists. Subtitles, attachments and unselected additional
tracks are omitted. Native EBML indexing supplies an on-demand movie view to the
existing decoder; it does not stage or decode the entire source movie. Output
repackages the existing encoder's compressed packets on the destination volume.
Dolby configuration, in-band RPUs/enhancement NALs, color and static HDR metadata
are retained by the container layer. MKV uses the ordinary encoding path.

MOV timecode behavior:

- If the source already contains a MOV timecode track, the output MOV keeps
  that source timecode.
- If the source has no MOV timecode track, the output MOV writes a synthetic
  timecode track.
- The default synthetic start timecode is `01:00:00:00`.
- Use `-ffoa` to override that synthetic start value when needed.

Example:

```bash
proresencoder -i input.mov -ef mov -q 422hq -ffoa 10:00:00:00 -o output.mov
```

MXF OP-1a:

```bash
proresencoder -i input.mov -ef op1a -q 422hq -o output_dir
```

MXF OP-Atom:

```bash
proresencoder -i input.mov -ef opatom -q 422hq --audio-ch-per-file 1 -o output_dir
```

## External Audio and Source-Audio Deletion

Use `-aa` to add external audio. For MOV/MP4/MKV output, source audio and
containerized `-aa` audio are copied as original packets and configurations.
The software does not require an audio decoder or a registered codec name to
preserve an ISO BMFF sound track. AC-4, AV3A, MPEG-H and future sample entries
are not classified as PCM/AAC or rejected because AVFoundation does not decode
them. No implicit PCM/AAC transcode is performed. The two MXF modes retain their
existing audio handling.

MOV/MP4 sample entries are preserved in full. MKV uses registered native codec
mappings where available and `A_QUICKTIME` to retain otherwise unrecognized ISO
sample entries and configuration boxes. Containerized AC-4, AV3A and MPEG-H supplied
through `-aa` have been checked by complete configuration and payload hashes
across all three output containers. Raw audio without packet/configuration
metadata still needs a parser for its source framing; this is independent of
whether a destination container can carry the codec.

Add `--audio-replace` / `-ar`, or combine `-aa` with
`--delete-source-audio` / `-dsa`, to drop source audio and keep only the
supplied track.

```bash
proresencoder \
  -i input.mov \
  -q 4444xq \
  -aa audio_if_needed.wav \
  --audio-replace \
  -ef mov \
  -o output.mov
```

Short form:

```bash
proresencoder -i input.mov -q 4444xq -aa replacement_7_1.wav -ar -o output.mov
proresencoder -i input.mov -q pass -dsa -aa external_audio.ec3 -o output.mov
proresencoder -i input.mov -q pass -dsa -o silent_output.mov
```

Safety rules:

- `--audio-replace` / `-ar` requires `-aa <audio_file>`.
- `--delete-source-audio` / `-dsa` does not conflict with `-aa`; deletion is
  applied first, then the external audio is added.
- Unknown arguments stop the process with an error.
- Missing argument values stop the process with an error.
- MXF output accepts `-aa` when replacement or source-audio deletion is enabled.

## Batch Encoding

```bash
proresencoder -if input_folder -ef mov -q 422hq -o output_folder
```

Batch mode writes one output per supported input file.

## Timeline Tools

Bounce an XML timeline to MOV:

```bash
proresencoder -xml timeline.xml -o output_folder
```

Convert supported timeline documents:

```bash
proresencoder -i timeline.xml -trans AAF -o sequence.aaf
proresencoder -i sequence.aaf -trans XML -o sequence.xml
```

Add a media relink path:

```bash
proresencoder -i sequence.aaf -trans XML \
  --media-search-path /path/to/media \
  -o sequence.xml
```

## AAF Export

Generate one linked AAF for an MXF encode:

```bash
proresencoder -i input.mov -ef op1a -q 422hq --export-aaf -o output_dir
```

Generate one linked AAF per clip in batch mode:

```bash
proresencoder -if input_folder -ef opatom -q 422hq --export-aaf-all -o output_dir
```

## Notes

- The CLI prints explicit errors for unsafe argument combinations.
- `-ar` is replacement mode, not an additive mix mode.
- MOV replacement output should contain only the replacement audio stream plus
  video and timecode/metadata tracks.
- Generated files and bundled dependency files retain their own notices.

## External Storage and NAS Recovery

The encoder never stages source or delivery media to the system disk. MOV, MP4,
OP-1a, and OP-Atom jobs write to a hidden working file or directory beside the
requested destination on the same volume, so Thunderbolt and NAS bandwidth stay
on the selected storage path. A completed job is published with same-volume
rename/replace operations; this is metadata-only and does not copy media bytes.

MOV and MP4 output writes a closed movie fragment every 10 seconds. Apple
recommends intervals of at least 10 seconds for high-performance external media;
if a write is interrupted, the retained recovery file is playable through the
last completed fragment. Failed MOV/MP4 and MXF jobs are retained beside the
delivery as `*.recoverable-*`, while any pre-existing completed delivery remains
untouched.

For source or destination I/O interruptions, the MOV/MP4 path waits up to 30
minutes for storage to reconnect and retries the direct-to-volume job up to three
times. When a failed MOV/MP4 contains scanner-verified complete fragments, the
encoder preserves that prefix, encodes only the missing source tail, and performs
a pass-through remux on the same destination volume. This avoids recompressing
the intact prefix. If track layouts or frame-indexed Dolby Vision/CMU side data
cannot be safely reconstructed, it falls back to a fresh direct transaction
instead of emitting a potentially invalid file.

After an application crash or power loss, resume an eligible MOV/MP4 manually:

```bash
proresencoder -i source.mov -q hevc -b 20 \
  --resume-recovery output.recoverable-XXXXXXXX.mov \
  -o output.mov
```

### Hybrid MOV and parallel VideoToolbox sessions

The CLI automatically uses Hybrid MOV for eligible single-file ProRes, H.264,
and HEVC MOV output from a CFR source directly readable by AVFoundation.
Automatic parallelism targets **two encoding jobs**. Use `--vt-workers 1` or
`--vt-workers 2` to select single/dual encoding, or `--no-hybrid-mov` for the
ordinary writer. `--hybrid-mov` remains an explicit force-on option.

```bash
proresencoder -i source.mov -q proxy -o output.mov # automatic Hybrid MOV, target 2
proresencoder -i source.mov -q proxy --vt-workers 1 -o single.mov
# After interruption, repeat the same source, output and encoding options:
proresencoder -i source.mov -q proxy --hybrid-resume --vt-workers 2 -o output.mov
```

This native muxer follows the documented [OBS Hybrid MOV design](https://obsproject.com/blog/obs-studio-hybrid-mp4):
it writes an initialization movie and recoverable fragments, then appends full
sample tables and changes a 16-byte header to expose an ordinary MOV. Finishing
does not copy the completed media payload. No OBS source code is included.

Omitting `--vt-workers`, or setting it to `0`, targets two jobs. The selected
codec/raster's VT parallel limit caps the target. Candidates are prepared
simultaneously with hardware acceleration required; a missing recommendation
does not force a Pro/Max/Ultra chip to one job. A limit below two or an unavailable
second hardware session falls back to one, with a CLI reason. Chip names and CPU
core counts do not determine the result. This verifies concurrent hardware
contexts, not a physical media-engine count or a measured fastest configuration.
Short inputs can use one job because there is only one subdivision; that reason
is logged separately. Explicit values 3 through 8 remain for advanced testing.
Unconverted ProRes streams compressed pictures directly to their
final offsets with four in-flight pictures per session and an ordered source reader.
Transformed ProRes and H.264/HEVC use bounded, independently encoded subdivisions
on the output volume. Completed out-of-order subdivisions are retained for reuse.
More sessions do not guarantee more throughput or identical HEVC rate control.

`--hybrid-fragment-frames 0` selects the encoder's recommended minimum frame count
and duration, with a 240-frame minimum and a 2400-frame cap. Set 24 through 2400
explicitly for a different recovery/performance tradeoff. A resume keeps the saved
subdivision size. It may change the worker count. The movie and video clocks use
the exact edit-rate numerator, including 30000/1001.

The visible `output.hybrid-partial.mov` and hidden `.output.mov.hybrid-state`
directory form one recovery job; retain both. The journal is checksummed and
committed only after fragment synchronization. Resume verifies committed fragment
SHA-256 hashes and the source path, size, modification time, head/tail fingerprint,
and encoding/LUT parameters before discarding an incomplete tail. A damaged
committed fragment fails explicitly. An exclusive job lock prevents two encoders
from continuing the same file. Existing delivery files are refused for new jobs.
SMB uses a same-volume move when exclusive-rename extensions are unavailable.
Filesystem synchronization relies on the destination server's durability behavior.
Unfinalized duration/seeking support varies by reader; fragmented B-frame media
can have a demuxer-applied decoder-delay timestamp bias. Resume/finalize for
delivery; the completed movie uses the exact zero-based presentation timeline.

This mode currently preserves one video track and QuickTime timecode. Default
selection preserves source audio by using the ordinary writer unless `-dsa` was
explicitly selected. External audio/XML, timed metadata, pass-through, raw output,
AV1 and standalone/ProRes CMU also retain their ordinary paths with a CLI reason.
Explicit Hybrid options reject unsupported combinations. Sources requiring a
temporary sample-entry retag retain the ordinary path; a recovery job always
identifies the persistent source file. Batch/timeline workflows and AMA sequence
resume retain their existing paths. Generated HEVC Dolby Vision can use `--cmu N -ci` with an
explicit profile and the existing color options. Analysis and GOP/rate-control
state are scoped to each subdivision, so metadata and HEVC bytes need not match
an uninterrupted single-session encode. `--no-hybrid-mov` selects the existing
ordinary encoding behavior.

The Framework's existing default remains opt-in, including AMA's private calls.
Framework callers can set `ProResEncodeOptions.hybridMovie` to
`ProResHybridMovieOptions(workers: 2)` and set its `resume` property for continuation.
The public file `encode` entry point uses the same muxer. Independent full decode,
timestamp and real process-kill regressions are in `Tests/HybridMOV/`.
