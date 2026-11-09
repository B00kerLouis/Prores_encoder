# Prepared external color in ProResEncoderFramework

Author: B00kerLouis.

`ProResPreparedFrameSession` is an explicit Swift Framework entry point for an
external GPU/color pipeline. Existing file APIs, CLI defaults, built-in color
transforms and AMA transport retain their existing paths.

| Item | Negotiated support |
| --- | --- |
| Codec/container | All six ProRes variants, MOV only |
| Input | Metal-compatible interleaved little-endian RGBA IEEE binary16 CVPixelBuffer (`kCVPixelFormatType_64RGBAHalf`) |
| Layout | Even dimensions, maximum 16384 each; CVPixelBuffer byte stride at least width × 8, divisible by 8 |
| Precision | 16-bit storage/component with binary16 precision; ProRes codec precision/subsampling still applies |
| RGB color | Rec.709, Rec.2020 or P3-D65, always D65; actual BT.709 OETF or absolute ST2084 PQ |
| Range | Normalized full-domain RGB samples; coded ProRes YCbCr is video range |
| Luminance | Explicit reference white and nominal peak in nits; PQ signal 1 means 10000 nits |
| Timing | Consecutive, zero-based CFR PTS at the supplied exact rational rate |
| Retention | Capacity 2–16; each warmed pool is limited to 1 GiB and allocations use a hard count threshold |
| Metadata | Descriptor configures input attachments and VT color properties; compressed color tags are verified |
| Mastering | ST2086 only with explicit PQ `masteringMinimumNits`; no measured MaxCLL/FALL is invented |

BT.709 OETF is distinct from Gamma 2.4. A BT.709 descriptor requires equal
reference white and nominal peak; extended SDR is not negotiated. Input sample
values must be finite and consistent with their descriptor. Primaries and
transfer are facts about the pixels delivered by the producer, not retagging
instructions. The optional matrix performs a real transform. There is no
automatic tone mapping, OCIO/ACES dependency, audio, Dolby Vision authoring, or
carrier replay behind this API. Unsupported configurations fail during setup.

## Already-processed frames

```swift
import ProResEncoderFramework
import CoreMedia
import CoreVideo
import Metal

let device = MTLCreateSystemDefaultDevice()!
let color = ProResPreparedColorDescriptor(
    primaries: .rec2020, transfer: .pq,
    referenceWhiteNits: 203, nominalPeakNits: 1000,
    masteringMinimumNits: 0.005) // omit when the mastering black is unknown
let session = try ProResPreparedFrameSession(
    outputURL: outputURL, width: 1920, height: 1080,
    frameRateNumerator: 30000, frameRateDenominator: 1001,
    codec: .proRes4444XQ, color: color, capacity: 4, device: device)

// Supply a compatible externally allocated buffer, or request one from the
// session's bounded pool. Finish all writes before declaring .completed.
let frame = try session.makePixelBuffer()
// ... producer fills normalized PQ RGBAHalf pixels ...
let receipt = try session.tryAppend(frame, presentationTime: .zero,
                                    readiness: .completed)
// nil means backpressure: await a prior accepted receipt, then retry the same
// frame/PTS. A rejected frame remains entirely owned by the caller.
try await session.finish()
try await receipt?.waitUntilReleased()
```

The caller keeps accepted pixels immutable until their receipt resolves. A
receipt can remain pending until another frame or `finish()` flushes the
codec. Keep the session alive through `finish()` or `cancel()`. Pool exhaustion
is explicit; callers must release completed buffers before allocating more.
For cancellation, call `cancel()` and await each outstanding receipt before
reusing producer memory. A receipt fails only after its outstanding GPU work
has completed. `finish()` itself reports cancellation without claiming the
GPU has stopped.

## External GPU producer

Register completion **before** committing the producer command buffer. Metal
does not permit adding a completion handler after commit. The token records
both in-flight and already-completed work and includes command errors.

```swift
let command = producerQueue.makeCommandBuffer()!
// ... encode the producer's writes to frame, retaining its CVMetalTextures ...
let producer = try ProResPreparedMetalProducer(commandBuffer: command)
command.commit()
let receipt = try session.tryAppend(frame, presentationTime: pts,
                                    readiness: .metal(producer))
```

The producer queue/device must match `session.device.registryID`. The caller
owns its queue, command encoding, texture-wrapper lifetime, synchronization
and storage visibility. `.completed` is an explicit assertion that all CPU/GPU
writes are complete and visible. The Framework never commits an external
command buffer or calls `waitUntilCompleted()` per frame. Different producer
queues may finish out of order; submission still follows accepted PTS order.

The Framework retains at most `capacity` accepted frames, including external
GPU work, matrix work, compression and muxing. `tryAppend` is nonblocking and
returns nil when full. On encoders supporting `MaxFrameDelayCount`, setup
requires successful setting/readback. ProRes implementations that do not
support that optional VT property report `usesBackpressureCodecDrain == true`;
the new facade then completes codec work at fixed batch saturation. This is a
bounded codec synchronization point, not a per-frame GPU wait. `finish()` also
flushes the codec.

## Parameter-only external matrix

`ProResExternalRGBMatrix` is a separate explicit choice. Rows multiply
**absolute linear RGB nits** after the input EOTF and before the output OETF.
Caller coefficients own gamut conversion. No implicit chromatic adaptation or
grading is added. Negative matrix results clip to zero; BT.709 output clips at
reference white and PQ clips at 10000 nits. Nominal mastering peak does not cap
pixels or select a tone-mapping algorithm. Alpha is preserved.

```swift
let inputColor = ProResPreparedColorDescriptor(
    primaries: .rec709, transfer: .bt709,
    referenceWhiteNits: 100, nominalPeakNits: 100)
let matrix = ProResExternalRGBMatrix(inputColor: inputColor,
    row0: [0.627404, 0.329283, 0.043313],
    row1: [0.069097, 0.919540, 0.011362],
    row2: [0.016391, 0.088013, 0.895595])
// Pass matrix: matrix to the session initializer and declare the actual
// Rec.2020 output transfer/luminance in color. This matrix alone changes gamut;
// it does not expand 100-nit SDR white to a 1000-nit HDR grade.
```

Matrix mode dispatches one independent Metal kernel into a bounded owned
RGBAHalf output. Already-processed mode dispatches no Framework color kernel.
Neither path copies a full-frame CPU payload. Metal texture binding and
IOSurface do not establish driver-level zero copy; VT may internally convert
RGB to the codec's YCbCr/subsampling/precision. GPU interval sums and retained
frame counts are exposed in `statistics`; intervals exclude VT internals and
producer intervals can include unrelated work in that producer command.

Output grows in a private sibling transaction on the output volume. Final
metadata is added to its owned trailing moov and the completed movie is
atomically renamed. An existing final output survives failure/cancellation.
There is no automatic interrupted-session resume or new persistent job schema.

## Build and regression

Build `ProResEncoderFramework` or `Build All` with Xcode 26.3, Swift mode 6 and
macOS 14+ arm64. Set isolated `SYMROOT`, `OBJROOT`, module cache and DerivedData
paths when running local checks; project defaults otherwise use existing
Build outputs. The kernel is compiled and embedded in the Framework image.

`Tests/ExternalColor/PreparedFrameContracts.swift` is an SDK-free public-API
driver. Compile it with `-parse-as-library -swift-version 6 -O`, Framework search
paths for the built Framework and existing `Frameworks/swiftaaf_Framework`,
and a runtime rpath for the built Framework. The existing AAF dependency is
statically linked at runtime but its module is required when importing the
Swift Framework. Run `driver contracts <owned-output-directory>` with
`MTL_DEBUG_LAYER=1 MTL_DEVICE_WRAPPER_TYPE=1` and an outer 120-second timeout.
Independent decoded-pixel checks use local FFmpeg/FFprobe; no Avid SDK or host
application is required. Synthetic tests do not establish Media Composer,
Dolby, ACES or OCIO conformance.
