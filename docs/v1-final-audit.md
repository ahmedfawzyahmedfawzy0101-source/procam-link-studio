# ProCam Link Studio v1.0 Final Audit

Status values:

- IMPLEMENTED + HARDWARE WIRED
- IMPLEMENTED + SOFTWARE PROCESSING
- DYNAMICALLY UNSUPPORTED
- NOT IMPLEMENTED

Do not mark a feature implemented because UI exists. End-to-end function is required.

## Intelligent Camera / AI Cinematography

| Feature | Status | Notes |
| --- | --- | --- |
| On-device Vision face detection | IMPLEMENTED + SOFTWARE PROCESSING | Runs locally with Vision at a reduced analysis rate. |
| On-device human/person rectangle detection | IMPLEMENTED + SOFTWARE PROCESSING | Uses Vision human rectangle detection when available. |
| Multi-subject overlay | IMPLEMENTED + SOFTWARE PROCESSING | Preview overlay draws detected subject boxes and confidence. |
| Tap selected subject | IMPLEMENTED + SOFTWARE PROCESSING | Tap point selects nearest detected subject. |
| Maintain selected target across frames | IMPLEMENTED + SOFTWARE PROCESSING | Uses position, size, velocity prediction, kind, age, and selected-target continuity bias. Full biometric re-identification is not claimed. |
| Tracking modes | IMPLEMENTED + SOFTWARE PROCESSING | Face, Person, Group, Manual Subject, Auto Best Subject. |
| Group tracking mode | IMPLEMENTED + SOFTWARE PROCESSING | Computes stable group bounds from visible subjects. |
| Auto reframe / smart follow preview | IMPLEMENTED + SOFTWARE PROCESSING | Preview crop is smoothed and follows selected/group subjects. |
| Auto reframe recorded output | IMPLEMENTED + SOFTWARE PROCESSING | Processed master recording uses the shared processed frame pipeline without monitoring overlays. |
| Auto reframe streamed output | NOT IMPLEMENTED | Requires SRT/WebRTC transport integration. |
| Subject loss recovery | IMPLEMENTED + SOFTWARE PROCESSING | Holds last frame briefly and widens smoothly on loss. |
| Velocity + predictive follow | IMPLEMENTED + SOFTWARE PROCESSING | Predicts near-future target position with damped velocity. |
| Look-room / headroom controls | IMPLEMENTED + SOFTWARE PROCESSING | Controls affect smart crop. Face-direction landmark inference is not yet implemented. |
| Face-priority autofocus/exposure | IMPLEMENTED + HARDWARE WIRED | Uses tracked subject center as AF/AE metering point where public camera APIs support points; respects manual focus/exposure. |
| Skin highlight warning | NOT IMPLEMENTED | Required before final v1.0. |
| Smart zoom | IMPLEMENTED + SOFTWARE PROCESSING | Preview smart crop respects configured min/max digital zoom. |
| Smart lens recommendation | IMPLEMENTED + SOFTWARE PROCESSING | Recommends from real discovered lenses based on subject size, framing mode, and digital zoom pressure. |
| Optional automatic physical lens switching | IMPLEMENTED + HARDWARE WIRED | Opt-in switching uses real `AVCaptureDevice`s with hold time and cooldown. |

## Stabilization / Motion

| Feature | Status | Notes |
| --- | --- | --- |
| Native stabilization mode discovery | IMPLEMENTED + HARDWARE WIRED | Enumerates active format-supported Apple stabilization modes. |
| Native stabilization mode application | IMPLEMENTED + HARDWARE WIRED | Applies selected mode to video/movie capture connections. |
| Professional stabilization presets | IMPLEMENTED + HARDWARE WIRED | Tripod, Handheld, Walking, Running, Follow Cam choose only supported native modes and digital settings. |
| CoreMotion horizon indicator | IMPLEMENTED + SOFTWARE PROCESSING | Roll is read locally from CoreMotion and rendered in preview. |
| Horizon lock / roll correction | IMPLEMENTED + SOFTWARE PROCESSING | Preview transform uses smoothed CoreMotion roll with max correction and crop safety. |
| Digital post stabilization | IMPLEMENTED + SOFTWARE PROCESSING | Preview and processed master recording use the shared Core Image transform. Streaming output still requires transport wiring. |
| Analysis scheduler | IMPLEMENTED + SOFTWARE PROCESSING | Vision analysis runs at independent reduced rate. |
| Resource budget manager | IMPLEMENTED + SOFTWARE PROCESSING | Tracks Vision analysis time against FPS frame budget; broader capture/GPU/encoder timing still required. |

## Monitoring / Scopes

| Feature | Status | Notes |
| --- | --- | --- |
| Grid / center marker | IMPLEMENTED + SOFTWARE PROCESSING | Preview only. |
| Histogram / RGB histogram | IMPLEMENTED + SOFTWARE PROCESSING | Reduced-rate sampled luma and YCbCr-derived RGB histograms. |
| Waveform / RGB parade / vectorscope | IMPLEMENTED + SOFTWARE PROCESSING | Reduced-rate sampled waveform, RGB parade traces, and vectorscope scatter overlays. |
| False color with legend | IMPLEMENTED + SOFTWARE PROCESSING | Preview false color plus visible legend. |
| Zebras | IMPLEMENTED + SOFTWARE PROCESSING | Preview zebra overlay uses low/high threshold masks and stripe composition. |
| Focus peaking | IMPLEMENTED + SOFTWARE PROCESSING | Preview peaking uses Core Image edge detection with sensitivity/opacity controls. |

## Capture / Recording / Audio

| Feature | Status | Notes |
| --- | --- | --- |
| Local recording | IMPLEMENTED + HARDWARE WIRED | Uses `AVCaptureMovieFileOutput`. |
| H.264/HEVC recording codec detection | IMPLEMENTED + HARDWARE WIRED | Codec list comes from `availableVideoCodecTypes`. |
| Clean master recording | IMPLEMENTED + HARDWARE WIRED | Uses `AVCaptureMovieFileOutput` with selected codec and optional session audio. |
| Processed master recording | IMPLEMENTED + SOFTWARE PROCESSING | Uses `AVAssetWriterInputPixelBufferAdaptor` and the shared processed frame pipeline; monitoring overlays are excluded by default. |
| Recording quality presets | IMPLEMENTED + SOFTWARE PROCESSING | Match, 4K Pro, 1080p Pro, Creator, Low Light. |
| Pre-record buffer | NOT IMPLEMENTED | Required before final v1.0. |
| Dual master/proxy recording | NOT IMPLEMENTED | Required before final v1.0 where performance permits. |
| Audio meter / input tools | IMPLEMENTED + HARDWARE WIRED | Requests microphone permission, captures mic sample buffers, displays RMS/peak level, and reports A/V timestamp offset. |
| Reusable VideoToolbox encoder | IMPLEMENTED + SOFTWARE PROCESSING | H.264/HEVC real-time encoder foundation exists for future streaming/proxy paths. |

## Streaming / Windows

| Feature | Status | Notes |
| --- | --- | --- |
| SRT transport | NOT IMPLEMENTED | Requires linking Haivision `libsrt.xcframework` and `libcrypto.xcframework`; no fake UDP transport is claimed. |
| Clean stream path | NOT IMPLEMENTED | Requires transport sender wiring. |
| Processed stream path | NOT IMPLEMENTED | Requires transport sender wiring from the shared processed frame pipeline and VideoToolbox encoder. |
| Windows receiver | NOT IMPLEMENTED | Not started. |
| Windows remote controls | NOT IMPLEMENTED | Not started. |
| Windows virtual camera | NOT IMPLEMENTED | Not started. |

## Image / Looks

| Feature | Status | Notes |
| --- | --- | --- |
| GPU-backed preview image controls | IMPLEMENTED + SOFTWARE PROCESSING | Core Image rendered through Metal-backed `MTKView`. |
| Professional looks | IMPLEMENTED + SOFTWARE PROCESSING | Natural, Clean, Soft, Warm, Cool, Cinematic, High Contrast, Mono. |
| `.cube` LUT import | NOT IMPLEMENTED | Architecture still required before final v1.0. |

## Final Gate

The final IPA must not be generated until this audit has no accidental UI-only claims and every v1.0-required feature is either implemented end-to-end or honestly marked dynamically unsupported because of public API/device limits.
