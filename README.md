# ProRes Encoder 1.2.1

Native macOS CLI and Framework for professional video encoding, HDR color
conversion, dynamic metadata processing, MOV/MXF mastering, linked timeline
workflows, batch encoding, and external-audio replacement.

All supported MOV outputs are written as `.mov` files. The encoder does not
create MP4 containers; Profile 7.6 can optionally emit separate BL/EL HEVC
elementary streams with `--dual`.

## What’s New in 1.2.1

- Dolby Vision Profile 7.6 verifier compliance updates for BL/EL HEVC output.
- Optional `--dual` output for Profile 7.6 BL/EL `.hevc` elementary streams.
- Default verifier-oriented AV1 sample entry remains `av01`; `-df` keeps the
  explicit `dav1` compatibility path.
- Native 10-bit long-GOP encoding paths for MOV output.
- Native 10-bit HEVC encoding with configurable bitrate.
- Dynamic HDR metadata workflows for HEVC and AV1 output.
- Profile-dependent metadata Application ID handling.
- Final-stream metadata detection and failure when requested metadata injection
  is absent.
- Verifier-oriented sample-entry defaults with an optional alternate sample
  entry flag when explicitly required.
- MOV external-audio passthrough plus source-audio deletion.
- GPU-based HDR gamut, transfer-function, and luminance conversion.
- GPU-based metadata analysis with optional sidecar inclusion.
- Synthetic or preserved MOV timecode.
- MOV, MXF OP-1a, MXF OP-Atom, AAF, XML/FCPXML timeline, folder batch, and
  external-audio workflows.
- Public `ProResEncoderFramework` target with CLI feature parity.

## License

This project is licensed under the GNU Affero General Public License v3.0 for
general public use. See [LICENSE](LICENSE).

A designated commercial-license grant may be provided in the LICENSE file for
specific organizations and their eligible subsidiaries or controlled affiliates.
That grant applies only to source code owned by this project and does not apply
to third-party components.

## Third-Party and Trademark Notice

This repository may refer to industry formats, codecs, containers, metadata
schemes, and operating-system technologies only for identification and
interoperability purposes.

No third-party certification, endorsement, partnership, official compatibility,
or trademark license is claimed or implied by this README.

Third-party components, if included in the repository or required by a build,
remain governed by their own license terms. The project license and any
designated commercial-license exception do not relicense third-party code,
frameworks, SDKs, tools, assets, documentation, or generated files.

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
Build/Release/default.metallib
```

Optional local install:

```bash
cp "Build/Release/prores encoder" ~/bin/proresencoder
cp "Build/Release/default.metallib" ~/bin/default.metallib
```

Keep `default.metallib` next to the executable when using the CLI outside the
build directory; it contains the GPU kernels used by the encoder.

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

`default.metallib` is embedded in the framework Resources directory, so
framework clients do not need to copy the GPU library separately.

Set the Framework codec-tag option to `true` only when the target workflow
requires the alternate dynamic-HDR sample entry; its default should remain
`false` for normal output.

Set `ProResEncodeOptions.deleteSourceAudio` to `true` to omit input audio.
It can be combined with `extraAudioURL` so the source audio is removed before
the external track is added.

## Native Pipeline Architecture

- MOV outputs always use the MOV container.
- Source decode for compressed inputs uses native media sessions plus project
  pixel conversion and chroma downsampling.
- Dynamic HDR metadata generation and writing are implemented in project code,
  then packaged into the selected output bitstream or metadata track.
- Enhanced-layer workflows perform closed-loop base-layer encode and
  reconstruction, derive a residual signal on the GPU, encode the enhanced
  layer, and interleave metadata directly into output samples.
- No separate elementary-stream files are emitted during normal MOV output
  unless Profile 7.6 `--dual` output is explicitly requested.

Final compressed samples are inspected before the file is accepted:

- HEVC output uses a verifier-oriented sample entry by default, including
  streams carrying dynamic HDR metadata.
- AV1 output similarly uses a verifier-oriented sample entry by default.
- Pass `--dv-flag` / `-df` only when an explicit alternate dynamic-HDR sample entry is
  required.
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
proxy, 422lt, 422, 422hq, 4444, 4444xq, pass, hevc, av1
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
  --gamunt rec709 \
  --oetf gamma2.4 \
  --nit 100
```

Supported targets:

- `--gamunt rec709|rec2020|p3d65`
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

# HEVC: generate and inject one metadata unit per frame
proresencoder -i hdr.mov -o hevc_metadata.mov -q hevc -b 50 -dp 81 \
  --cmu 1000 --cmu-include

# HEVC enhanced-layer workflow
proresencoder -i hdr.mov -o hevc_enhanced.mov -q hevc -b 80 -dp 76 \
  --cmu 1000 --cmu-include

# AV1: generate and inject one metadata unit per frame
proresencoder -i hdr.mov -o av1_metadata.mov -q av1 -b 50 -dp 10 \
  --cmu 1000 --cmu-include
```

Add `--dv-flag` / `-df` only when an explicit alternate dynamic-HDR sample entry is
required by the target workflow:

```bash
proresencoder -i hdr.mov -o hevc_metadata.mov -q hevc -b 50 -dp 81 \
  -dovi metadata.xml --dv-flag
proresencoder -i hdr.mov -o av1_metadata.mov -q av1 -b 50 -dp 10 \
  -dovi metadata.xml -df
```

`--cmu` and `-dovi` are mutually exclusive.
`--cmu-include` requires `--cmu`, supports MOV output only, and requires the
matching `-dp` value for HEVC or AV1. For HEVC/AV1, the internally generated
XML is converted to one native metadata unit per frame and injected during the
encode; for ProRes it is embedded as a metadata track.

## Output Formats

MOV:

```bash
proresencoder -i input.mov -ef mov -q 422hq -o output.mov
proresencoder -i input.mov -ef mov -q hevc -b 50 -o output_hevc.mov
proresencoder -i input.mov -ef mov -q av1 -b 50 -o output_av1.mov
```

The CLI normalizes every MOV encode filename to `.mov`. The Framework requires
an output URL ending in `.mov` for AV1. Neither interface emits MP4; raw HEVC
elementary streams are emitted only for Dolby Vision Profile 7.6 when `--dual`
is explicitly requested.

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

Use `-aa` to add an external audio track. The encoder accepts audio readable
through the native runtime, including common PCM and compressed audio formats.
MOV-compatible codecs are muxed where supported; inputs that require conversion
use an explicit channel layout.

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
- Third-party names, if any remain in code comments, build scripts, or source
  paths, should be reviewed separately before public release.
