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
| Maintain selected target across frames | IMPLEMENTED + SOFTWARE PROCESSING | Uses nearest-neighbor matching between Vision updates; full re-identification is not claimed. |
| Group tracking mode | NOT IMPLEMENTED | Required before final v1.0. |
| Auto reframe / smart follow preview | IMPLEMENTED + SOFTWARE PROCESSING | Preview crop is smoothed and follows selected/group subjects. |
| Auto reframe recorded/streamed output | NOT IMPLEMENTED | Required before final v1.0 if smart framed output is enabled. |
| Subject loss recovery | IMPLEMENTED + SOFTWARE PROCESSING | Holds last frame briefly and widens smoothly on loss. |
| Face-priority autofocus/exposure | NOT IMPLEMENTED | Required before final v1.0. |
| Skin highlight warning | NOT IMPLEMENTED | Required before final v1.0. |
| Smart zoom | IMPLEMENTED + SOFTWARE PROCESSING | Preview smart crop respects configured min/max digital zoom. |
| Smart lens recommendation | NOT IMPLEMENTED | Required before final v1.0. |
| Optional automatic physical lens switching | NOT IMPLEMENTED | Required before final v1.0 if enabled; must include hysteresis. |

## Stabilization / Motion

| Feature | Status | Notes |
| --- | --- | --- |
| Native stabilization mode discovery | NOT IMPLEMENTED | Required before final v1.0. |
| CoreMotion horizon indicator | IMPLEMENTED + SOFTWARE PROCESSING | Roll is read locally from CoreMotion and rendered in preview. |
| Horizon lock / roll correction | NOT IMPLEMENTED | Required before final v1.0. |
| Digital post stabilization | NOT IMPLEMENTED | Required before final v1.0 if enabled. |

## Monitoring / Scopes

| Feature | Status | Notes |
| --- | --- | --- |
| Grid / center marker | IMPLEMENTED + SOFTWARE PROCESSING | Preview only. |
| Focus peaking | NOT IMPLEMENTED | Required before final v1.0. |
| Histogram / RGB histogram | NOT IMPLEMENTED | Required before final v1.0. |
| Waveform / RGB parade / vectorscope | NOT IMPLEMENTED | Required before final v1.0. |
| False color with legend | NOT IMPLEMENTED | Required before final v1.0. |
| Zebras | NOT IMPLEMENTED | Required before final v1.0. |

## Capture / Recording / Audio

| Feature | Status | Notes |
| --- | --- | --- |
| Local recording | IMPLEMENTED + HARDWARE WIRED | Uses `AVCaptureMovieFileOutput`. |
| H.264/HEVC recording codec detection | IMPLEMENTED + HARDWARE WIRED | Codec list comes from `availableVideoCodecTypes`. |
| Pre-record buffer | NOT IMPLEMENTED | Required before final v1.0. |
| Dual master/proxy recording | NOT IMPLEMENTED | Required before final v1.0 where performance permits. |
| Audio meter / input tools | NOT IMPLEMENTED | Required before final v1.0. |

## Image / Looks

| Feature | Status | Notes |
| --- | --- | --- |
| GPU-backed preview image controls | IMPLEMENTED + SOFTWARE PROCESSING | Core Image rendered through Metal-backed `MTKView`. |
| Professional looks | IMPLEMENTED + SOFTWARE PROCESSING | Natural, Clean, Soft, Warm, Cool, Cinematic, High Contrast, Mono. |
| `.cube` LUT import | NOT IMPLEMENTED | Architecture still required before final v1.0. |

## Final Gate

The final IPA must not be generated until this audit has no accidental UI-only claims and every v1.0-required feature is either implemented end-to-end or honestly marked dynamically unsupported because of public API/device limits.
