# ProRes Encoder

Native macOS command-line encoder for ProRes media workflows. The tool supports single-file conversion, folder batches, MOV output, MXF OP-1a / OP-Atom output, linked AAF generation, XML timeline bounce, and external audio replacement.

## License

This project is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

## Requirements

- macOS with the standard command-line build tools installed
- Xcode project build support
- The bundled `Frameworks/swiftaaf_Framework.framework` directory kept next to the project file

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
cp "Build/Release/prores encoder" /opt/homebrew/bin/proresencoder
```

## Basic Usage

```bash
proresencoder -i input.mov -o output.mov
```

Set ProRes quality:

```bash
proresencoder -i input.mov -q 422hq -o output.mov
proresencoder -i input.mov -q 4444xq -o output.mov
```

Supported quality values:

```text
proxy, 422lt, 422, 422hq, 4444, 4444xq, pass
```

Use `pass` when you want a stream copy where supported:

```bash
proresencoder -i input.mov -q pass -o output.mov
```

## Output Formats

MOV:

```bash
proresencoder -i input.mov -ef mov -q 422hq -o output.mov
```

MXF OP-1a:

```bash
proresencoder -i input.mov -ef op1a -q 422hq -o output_dir
```

MXF OP-Atom:

```bash
proresencoder -i input.mov -ef opatom -q 422hq --audio-ch-per-file 1 -o output_dir
```

## Audio Replacement

Use `-aa` to provide an external audio file. Add `--audio-replace` or `-ar` to drop the source audio and keep only the supplied audio.

```bash
proresencoder \
  -i input.mov \
  -q 4444xq \
  -aa replacement_7_1.wav \
  --audio-replace \
  -ef mov \
  -o output.mov
```

Short form:

```bash
proresencoder -i input.mov -q 4444xq -aa replacement_7_1.wav -ar -o output.mov
```

Safety rules:

- `--audio-replace` / `-ar` requires `-aa <audio_file>`.
- Unknown arguments stop the process with an error.
- Missing argument values stop the process with an error.
- MXF output accepts `-aa` only when replacement mode is enabled.

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

## Benchmark

The chart below records one local 3840x2160/24p ProRes 4444 XQ benchmark on the same source clip. Higher realtime speed is better.

![ProRes 4444 XQ benchmark](docs/benchmark-prores-4444xq.svg)

Measured data:

| Encoder path | Scope | Wall time | Realtime speed |
|---|---:|---:|---:|
| ProRes Encoder | MOV encode with 7.1 audio replacement | 13.22 s | 7.04x |
| ffmpeg prores_videotoolbox | Video-only encode to null output | 49.52 s | 1.88x |
| ffmpeg prores_ks | Video-only encode to null output | 316.71 s | 0.29x |

Benchmark commands should be re-run on the same host, source clip, codec profile, and output scope before using the numbers for purchasing or delivery decisions.

## Notes

- The CLI prints explicit errors for unsafe argument combinations.
- `-ar` is replacement mode, not an additive mix mode.
- MOV replacement output should contain only the replacement audio stream plus video and timecode/metadata tracks.
