# Opt-in ProRes spatial processing

Author: B00kerLouis.

`ProResSpatialPlan` and `ProResSpatialProcessor` compose before the existing typed `ProResPreparedFrameSession`. Existing file/CLI paths and Matrix V1 signatures/loops/kernels retain their behavior. No generic file-resize flag is silently enabled.

| Target | Actual canvas pixels |
| --- | --- |
| source/default | Original raster, no processing |
| DCI 2K Full / Flat / Scope | 2048×1080 / 1998×1080 / 2048×858 |
| DCI 4K Full / Flat / Scope | 4096×2160 / 3996×2160 / 4096×1716 |
| UHD / FHD | 3840×2160 / 1920×1080 |
| custom | Positive even width/height <=16384, subject to device and budget validation |

Mode `fit` uses uniform scale with centered padding; `fill` uses uniform scale with centered crop. `crop` is an integer 1:1 centered crop and rejects enlargement; `pad` is integer 1:1 centered padding and rejects reduction. Source/canvas, contentRect, activeContentRect and sourceVisibleRect are exposed using top-left pixel-edge coordinates. Rectangles may be fractional for scaled fit/fill; the kernel samples destination pixel centers. No stretching is performed.

Only Metal-compatible interleaved little-endian RGBAHalf with square pixels and full clean aperture is supported. The source declaration and actual CVPixelBuffer PAR/clean-aperture/preferred-aperture/display-dimension attachments are checked. Non-square PAR, non-full/offset aperture, premultiplied-alpha input, malformed metadata and unsupported stride are rejected. Normalize those inputs in the producer before using this facade. Input rows are a top-left raster; no display-orientation transform is inferred.

The fixed filter is **bilinear**, distinct from JPEG's 4×4 bicubic. `interpolationDomain: .linearLight` (default) applies the selected BT.709/PQ EOTF, alpha-correct bilinear blending, then the same OETF. `.encoded` explicitly interpolates encoded samples. Selected primaries/white/transfer/luminance descriptors remain unchanged; there is no gamut transform or tone mapping. Integer 1:1 crop/pad directly preserves interior half bits.

Straight alpha uses premultiplied accumulation followed by straight output, preventing hidden transparent colors from bleeding. `.opaque` is an assertion that input is already opaque; identity never rewrites its alpha. Padding is opaque black by default, or explicit transparent black with straight alpha. Codec alpha support is independent of this RGBAHalf processor.

## Compose with the encoder

```swift
let plan = try ProResSpatialPlan(
    source: ProResSpatialSourceGeometry(width: sourceWidth, height: sourceHeight),
    target: .dci2KFlat, mode: .fit)
let encoder = try ProResPreparedFrameSession(
    outputURL: outputURL, width: plan.canvas.width, height: plan.canvas.height,
    frameRateNumerator: 30000, frameRateDenominator: 1001,
    color: color, capacity: 4, device: device)

// Choose at setup. For plan.isPassthrough, use the existing encoder entry
// directly with the original input/readiness: no new PSO/pool/dispatch/copy.
let spatial = try ProResSpatialProcessor(plan: plan, encodingSession: encoder)
let command = queue.makeCommandBuffer()!
let output = try spatial.encode(input, into: command, readiness: .completed)
// nil output is bounded backpressure. Await a prior encoder receipt, release
// its corresponding output lease, and retry without advancing PTS.
let producer = try ProResPreparedMetalProducer(commandBuffer: command)
command.commit() // completion token must already exist
let receipt = try encoder.tryAppend(output!.pixelBuffer, presentationTime: pts,
                                   readiness: .metal(producer))
// Retain/retry output if encoder returned nil; do not advance/drop the frame.
try await encoder.finish()
try await receipt?.waitUntilReleased()
```

The recommended initializer copies capacity/device/inputColor from the encoder and validates the target canvas. `inputColor` is intentional: spatial processing precedes an optional Matrix transform in the encoder. A standalone processor must call `validate(encodingSession:)`; its capacity must be at least the encoder capacity. A spatial pool of 2 combined with an encoder needing 4 inputs before a bounded batch drain could otherwise deadlock. The example uses matched capacities.

`.completed` explicitly asserts all CPU/GPU input writes are complete and visible. `.sameCommandBuffer` asserts producer writes are encoded earlier in the supplied command and the producer encoder has ended. The supplied command must be notEnqueued, same-device, retain resources, and not be concurrently committed. The facade never creates or commits a command. Register `ProResPreparedMetalProducer` before commit. Nil command is accepted only for an identity plan with `.completed` readiness.

The returned `ProResSpatialFrame` owns the output; keep it until the encoder accepts that frame. The encoder then retains the output through its receipt. The command independently retains source/output/CVMetalTexture leases until GPU completion, including cancellation; no command/handler ownership cycle is used. Discarded uncommitted commands resolve failure and release pending GPU resources. `waitForGPUCompletion()` covers that command, while the encoder receipt controls subsequent buffer reuse. Cancel both processor and encoder to cancel a whole movie; cancelling the processor does not claim to cancel already-encoded GPU work.

Pools use hard allocation thresholds. Initialization checks source max stride/data and actual output plane data at capacity against a 1 GiB working-set limit using overflow-checked arithmetic. The default source row limit rounds width×8 up to 256 bytes; explicitly provide a larger row limit when required. Actual source data/stride must fit the declared limit. This plane-data bound excludes driver/codec allocations. Warmup uses explicit autorelease scopes. Actual processing uses one GPU dispatch and no full-frame CPU copy; identity allocates no spatial pool/cache/PSO and returns the original pixel buffer.

Actual output pixels match canvas width/height. Output attachments describe full canvas aperture, square PAR/display dimensions and the chosen color. Active/visible rectangles remain separate plan information, never a false output aperture. Geometry does not blindly carry source-measured CLL/FALL or source mastering payload. The existing encoder may attach only explicitly configured mastering metadata. Texture binding/IOSurface alone is not a driver-level zero-copy claim.
