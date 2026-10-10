# Feature coverage

Status values: `mapped` means the plug-in has a parameter or callback for the behavior but Media Composer output is not verified. `blocked` means the current framework or host evidence cannot satisfy it. `unchanged` means the existing CLI or framework behavior was not retargeted. Nothing in this table has passed a Media Composer export.

The current bridge starts `ProResEncoderAMAWorker` on the first picture and
loads the bundled encoder framework inside that process. Supported BGRA options
use direct streaming; other options use the carrier/file encode path. Public CI
checks the prebuilt Release bundle and the Avid-free contracts. Full-duration
Media Composer ProRes Proxy and Dolby Vision Profile 5 HEVC exports remain
unpassed; those checks do not replace host acceptance.

| Area | Existing behavior | Plug-in entry | Limit | Status |
|---|---|---|---|---|
| ProRes profiles | Proxy, LT, 422, HQ, 4444, 4444 XQ | Codec parameter and `ProResFrameStreamSession` | Host BGRA frames go through the existing `encode` API. A 320x180 two-frame MOV was written outside Media Composer. | mapped |
| H.264 / HEVC / AV1 | Framework codec validation | Codec, container, and compressed bitrate parameters | MOV/MP4 only for these codecs; host frames and output remain untested | mapped |
| Compressed video bitrate, multi-pass, B-frames | Framework options | AMA numeric bitrate and tri-state controls passed to `ProResFrameStreamSession` | A two-frame H.264 MOV plus raw stream was written outside MC with B-frames off; Output dialog needs host verification | mapped |
| H.264 Dolby Vision | Framework rejects the combination | Dolby parameter | Still rejected; not replaced by HEVC or a tag | blocked |
| CBR/VBR, all-intra, recovery | CLI features, not all public framework options | none | Not called through the CLI | unchanged |
| Containers | MOV, MP4, MXF OP-1a, OP-Atom | Container parameter | MP4 rejects ProRes; MXF rejects H.264/HEVC/AV1 | mapped |
| Dolby Vision profiles | HEVC 5/7.6/8.1/8.4, AV1 10/10.1/10.4, ProRes metadata | Dolby Off / Generate / External XML | Generate blocked until project color is known; no bitstream check | blocked |
| Color, LUT, CMU | Framework direct/LUT and CMU options | AMA mode, gamut, transfer, nits, LUT path, and CMU controls | Project primaries/transfer/matrix/range unread; no PQ default; selected transforms reject until verified context exists | blocked |
| Audio | Framework keep/replace/external audio | AMA route, external file path, replace/delete, MXF grouping | External WAV replacement yielded PCM audio outside MC; host PCM/AAC packets are not captured by the bridge | blocked |
| Timecode / AAF | Framework start TC and AAF modes | AMA start TC and AAF controls | 10:00:00:00 MOV timecode and OP-Atom AAF were written outside MC; host sequence mapping remains unverified | mapped |
| Batch / folder | Framework file APIs | not a host timeline | Left on the existing API | unchanged |
| Timeline interchange | External AAF/XML file APIs | separate from AMA callbacks | Not used as the Media Composer timeline | unchanged |
| Raw video | Framework `outputVideoRaw` | AMA toggle passed to frame-stream bridge | ProRes and H.264 raw streams were written outside MC | mapped |
| Elementary multi-format / P7.6 fan-out | `ProResElementaryStreamOptions` | none | Separate framework workflow not yet exposed by the AMA bridge | blocked |
| Progress, cancel, errors | Framework job controls | GetProgress, CancelWrite, FinishWrite | Host-visible progress and cancel during the final encode are not proven | mapped |

`ProResEncoderAMAContractTests` covers the Avid-free session option matrix, bitrate state, and cancellation. Its no-output finish check exercises an unused session branch, not the live `WriterJob` bridge. It does not cover T01–T14 host scenarios in the AMA plan.

## Public single-file option mapping

The AMA XML fields below feed the existing `ProResEncodeOptions` through `ProResFrameStreamSession`. This lists all fields in that public struct; it does not claim that Media Composer has displayed or successfully used every control.

| `ProResEncodeOptions` field | AMA control | Current evidence or limit |
|---|---|---|
| `quality` | Codec | ProRes and H.264 short movies written outside MC |
| output format argument | Container | MOV and OP-Atom short outputs written outside MC |
| `extraAudioURL` | Extra audio file | WAV replacement produced PCM audio outside MC |
| `replaceSourceAudio`, `deleteSourceAudio` | Replace source audio, Delete source audio | Replacement tested outside MC; host audio is not captured |
| `forcedOutputStartTimecode` | Start timecode | MOV track verified at 10:00:00:00 outside MC |
| `dolbyVisionXMLURL`, `dolbyVisionProfile` | Dolby Vision XML, Dolby Vision profile | Mapped and validated; host metadata output untested |
| `bitrateMbps` | Numeric compressed video bitrate | Passed to the frame-stream bridge; exact host bitrate untested |
| `audioChannelsPerMXFFile` | Numeric MXF audio channels per file | OP-Atom AAF generated outside MC without host audio |
| `colorConversion` | Color mode, output gamut/transfer/peak | Rejected until host project color is verified |
| `lutColorConversion` | Color mode, LUT file, output gamut/transfer/peak | Rejected until host project color is verified |
| `cmuMasteringNits` | Numeric CMU mastering peak | Rejected until host project color is verified |
| `includeGeneratedDolbyVisionMetadata` | Embed generated Dolby Vision | Requires CMU nits and verified project color |
| `useDolbyVisionCodecTag` | Dolby Vision codec tag | Mapped; compressed Dolby output untested |
| `outputVideoRaw` | Raw video beside container | ProRes and H.264 raw files written outside MC |
| `multiPass`, `bFrames` | Tri-state Multi-pass, B-frames | H.264 B-frames off verified outside MC; multi-pass host output untested |
| `aafMode` | AAF output | OP-Atom AAF written outside MC |

Separate `ProResElementaryStreamOptions`, folder/timeline APIs, and CLI-only controls remain unimplemented in the AMA Output UI. Native Media Composer PCM/AAC delivery, project color lookup, and volume link-back still need host integration.
