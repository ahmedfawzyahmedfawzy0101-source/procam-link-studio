# ProCam Link Studio v1.0 Release Status

## Development Strategy

The current Phase 1 app has been installed and launched on a real iPhone. Future work targets one major professional v1.0 release. Intermediate milestones should use GitHub Actions CI compile checks only. The manual IPA workflow must not be triggered until the final v1.0 release gate.

## Confirmed Defects From Real iPhone Result

- Prototype-style UI.
- Portrait preview did not properly fill the screen.
- Controls were oversized.
- Lens buttons overflowed.
- Duplicated or low-value settings existed.
- Torch control was missing.
- Proper zoom was missing.
- ISO control was missing.
- Shutter control was missing.
- Contrast/image controls were missing.
- Professional looks/filters were missing.

## Milestone 1 Scope

Implemented in this milestone:

- Full-screen redesigned camera surface.
- Fit/fill preview mode wired to `AVCaptureVideoPreviewLayer.videoGravity`.
- Dynamic camera discovery remains the source for the lens strip.
- Compact lens selector using actual discovered camera devices.
- Pinch-to-zoom and zoom slider wired to `AVCaptureDevice.videoZoomFactor`.
- Torch toggle and intensity slider, hidden when unsupported.
- Exposure auto/lock/manual controls wired to AVFoundation.
- ISO and shutter controls using the selected device format's real hardware ranges.
- EV compensation using the real exposure target bias range.
- Continuous autofocus, focus lock, tap-to-focus, and manual lens position where supported.
- White balance auto/lock/manual controls using AVFoundation temperature/tint gain conversion.
- Dynamic video format inspection with selectable real 720p/1080p/4K-style formats and supported frame-rate ranges.
- HDR support detection from `AVCaptureDevice.Format`.
- Preview-only grid, center marker, focus reticle, and thermal display.
- Process thermal state display through `ProcessInfo.thermalState`.

## Milestone 2 Scope

Implemented in this milestone:

- `AVCaptureVideoDataOutput` frame path added alongside the capture session.
- `CVPixelBuffer` frames are delivered through a lightweight sample-buffer proxy.
- Metal-backed `MTKView` preview renderer.
- Core Image processing is rendered into the Metal drawable without `UIImage`.
- Image adjustment sliders wired to actual preview processing:
  - Exposure
  - Contrast
  - Highlights
  - Shadows
  - Whites
  - Blacks
  - Saturation
  - Vibrance
  - Temperature
  - Tint
  - Sharpness
  - Denoise
  - Gamma
  - Vignette
- Professional subtle looks wired to the renderer:
  - Natural
  - Clean
  - Soft
  - Warm
  - Cool
  - Cinematic
  - High Contrast
  - Mono
- Look intensity slider.
- Reset All for image adjustments.

## Milestone 3 Scope

Implemented in this milestone:

- Local recording foundation using `AVCaptureMovieFileOutput`.
- Start/stop recording control.
- Recording timer.
- H.264/HEVC codec selector limited to `availableVideoCodecTypes`.
- Storage warning when available important-use capacity is below 1 GB.
- Last recording filename display after capture completes.

## Milestone 4 Scope

Implemented in this milestone:

- Built-in profiles:
  - Max Quality
  - Creator Portrait
  - 4K Cinema
  - 1080p60
  - Low Light
  - Natural
- Profile application chooses matching real formats only when available.
- Profile application updates actual image-processing settings.
- Custom profile save using current image settings.
- Custom profile persistence with `UserDefaults`.
- Last custom profile delete.

## Milestone 5 Scope

Implemented in this milestone:

- Explicit orientation handling for the processed preview renderer.
- Portrait, portrait upside-down, landscape left, and landscape right map to Core Image EXIF orientation before fit/fill scaling.
- Processed preview no longer relies on `AVCaptureVideoPreviewLayer` for orientation.

## Milestone 6 Scope

Implemented in this milestone:

- `docs/v1-final-audit.md` added with explicit final-gate status categories.
- On-device Vision face detection.
- On-device Vision human/person rectangle detection.
- Reduced-rate Vision analysis that does not block capture rendering.
- Tap-to-select nearest detected subject.
- Nearest-neighbor subject identity continuity across Vision updates.
- Subject confidence overlay.
- Preview-only smart reframing with smoothed crop movement.
- Subject loss behavior that holds and gradually widens the preview crop.
- CoreMotion horizon state.
- Preview-only horizon indicator.

## Milestone 7 Scope

Implemented in this milestone:

- Tracking modes: Face, Person, Group, Manual Subject, Auto Best Subject.
- Tracking lifecycle states: TRACKING, TEMPORARILY_LOST, SEARCHING, REACQUIRED, MANUAL_FALLBACK.
- Improved identity persistence using bounding-box position, size, predicted motion, subject kind, target age, and selected-target bias.
- Velocity estimation and predictive target rectangle.
- Identity-switch protection through selected-target bias and minimum lock state.
- Group bounds framing for group mode.
- Smart framing controls added for look room, horizontal bias, vertical bias, and group safety margin.
- Native stabilization mode enumeration from the active `AVCaptureDevice.Format`.
- Native stabilization application through `AVCaptureConnection.preferredVideoStabilizationMode`.
- Horizon lock / digital stabilization preview transform using CoreMotion roll and GPU-rendered Core Image transforms.
- Central analysis scheduler for reduced-rate Vision processing.
- Performance budget callback for tracking analysis time and frame-budget warning.
- Throttled smart AF/AE metering toward the selected subject when manual focus/exposure are not active.

## Milestone 8 Scope

Implemented in this milestone:

- Reduced-rate monitoring analyzer for luma and YCbCr-derived RGB histograms.
- Clipping and shadow percentage diagnostics from sampled pixel buffers.
- Preview histogram overlay.
- Preview RGB histogram overlay.
- Preview false-color processing using Core Image.
- Preview focus peaking using Core Image edge detection.
- Preview zebra overlay path using Core Image threshold/mask/stripe composition.
- Monitoring analysis timing surfaced in the UI.

## Milestone 9 Scope

Implemented in this milestone:

- Reduced-rate luma waveform trace.
- RGB parade-style traces from YCbCr-derived RGB samples.
- Vectorscope scatter from sampled chroma values.
- Preview overlays for waveform, RGB parade, and vectorscope.
- Visible false-color legend.
- Separate low/high zebra threshold controls wired to preview processing.

## Milestone 10 Scope

Implemented in this milestone:

- Smart Lens Assist recommendation logic from subject size, framing goal, discovered physical lenses, and current digital zoom.
- Optional Auto Lens switching using discovered `AVCaptureDevice`s.
- Auto Lens cooldown, minimum hold time, and pending-switch label to prevent bouncing.
- Clear optical switch versus digital zoom messaging.
- Professional stabilization presets: Tripod, Handheld, Walking, Running, Follow Cam.
- Presets choose only currently supported native stabilization modes.

Not claimed complete in this milestone:

- Local recording.
- Streaming transports.
- Windows receiver.
- Profile persistence.
- Final v1.0 IPA.

## Milestone 11 Scope

Implemented in this milestone:

- Shared `ProcessedFramePipeline` used by the preview renderer and reusable for record/stream paths.
- Preview image processing, smart reframe, horizon/digital stabilization, looks, zebras, false color, and focus peaking now live in one `CVPixelBuffer`/Core Image path.
- Preview monitoring overlays remain optional through `FrameProcessingState.includeMonitoring`.
- Processed master recording path using `AVAssetWriter` and `AVAssetWriterInputPixelBufferAdaptor`.
- Processed recording excludes monitoring overlays by default.
- Clean vs processed recording mode selector.
- Recording quality presets: Match, 4K Pro, 1080p Pro, Creator, Low Light.
- Processed recording frame/dropped-frame/output-resolution diagnostics.
- Processed recording preserves capture timestamps and current preview orientation state.

## Milestone 12 Scope

Implemented in this milestone:

- Optional microphone capture permission flow.
- Microphone input added to `AVCaptureSession` when authorized and enabled.
- Clean movie recording can include session microphone audio.
- Processed master writer can include AAC audio through an audio `AVAssetWriterInput`.
- Audio sample buffers are appended to processed recording while video frames use the processed pixel-buffer path.
- Audio level and peak meter.
- A/V timestamp offset diagnostics surfaced in the Video panel while recording.

## Milestone 13 Scope

Implemented in this milestone:

- Reusable `VideoToolboxEncoder`.
- H.264/HEVC codec mapping from existing recording codec selection.
- Real-time encoder configuration with bitrate, FPS, keyframe interval, and no frame reordering.
- Encoded sample buffers copied to `Data` for future transport layers.
- Keyframe detection for downstream streaming packetization.

Not claimed complete in this milestone:

- End-to-end encoder-to-muxer-to-SRT live streaming.
- Windows receiver/control/virtual camera.
- Final v1.0 IPA.

## Milestone 14 Scope

Implemented in this milestone:

- SRT connection configuration, connection state, and statistics models.
- Reproducible CI build script for pinned Haivision SRT iOS XCFrameworks.
- Swift/C bridge for actual libsrt startup, socket creation, caller/listener connection, send, stats, and shutdown.
- `SRTTransport` backed by the libsrt bridge with reconnect and bounded send queue behavior.
- Native Windows project under `windows/ProCamLinkStudio`.
- Win32 desktop shell with large preview region, side panels, top telemetry, and bottom recording/audio status bar.
- Windows receiver state and statistics model.
- ProCam Control Protocol v1 command/confirmation model.
- Media Foundation startup/shutdown foundation in the Windows receiver session.
- Windows GitHub Actions build workflow that packages a `ProCamLinkStudio-Windows.zip` artifact.

Not claimed complete in this milestone:

- Live VideoToolbox/MPEG-TS/SRT pipeline wiring.
- MPEG-TS mux/demux.
- Media Foundation H.264/HEVC decode pipeline.
- AAC audio decode/playback.
- Remote control networking.
- Bonjour/mDNS discovery.
- Windows virtual camera driver/source.

## Milestone 15 Scope

Implemented in this milestone:

- MPEG-TS muxer foundation for SRT/OBS interoperability.
- PAT and PMT emission.
- PES packetization with PTS/DTS timestamp fields.
- 188-byte transport packet output with continuity counters.
- H.264, HEVC, and AAC stream type declarations.
- PCR insertion on key video packets.

Not claimed complete in this milestone:

- VideoToolbox format conversion to Annex B access units.
- AAC ADTS framing.
- Encoder-to-muxer-to-SRT live wiring.
- OBS Direct compatibility validation.

## Milestone 16 Scope

Implemented in this milestone:

- Live iOS Stream panel with SRT caller/listener mode, host, port, latency, stream ID, passphrase, and start/stop.
- VideoToolbox keyframe parameter-set extraction for H.264 SPS/PPS and HEVC VPS/SPS/PPS.
- Annex B access-unit conversion from VideoToolbox length-prefixed NAL output.
- Live capture video frames wired into `VideoToolboxEncoder`.
- Encoded H.264/HEVC video wired into `MPEGTransportStreamMuxer`.
- Microphone sample buffers wired into `AACEncoder`.
- AAC-LC encoding through `AudioConverter`.
- ADTS framing for AAC packets.
- MPEG-TS audio/video packets wired into `SRTTransport`.
- Real SRT sending through the Haivision libsrt C bridge.
- Stream telemetry for state, bitrate, RTT, loss, queue depth, dropped frames, sent bytes, and encoded frames.
- iOS and Windows CI green after SRT, video streaming, and AAC wiring.

Not claimed complete in this milestone:

- Real iPhone to OBS validation.
- Windows SRT receive/demux/decode.
- Windows virtual camera output.
- Final v1.0 IPA.

## Windows Finalization Pass

Implemented in this pass:

- Windows CMake now requires a real libsrt dependency and the Windows CI resolves `libsrt` through vcpkg.
- Native receiver session starts Winsock, libsrt, COM, and Media Foundation.
- SRT receiver supports caller and listener modes in source, with latency, receive/connect timeout, passphrase, stream ID, reconnect loop, disconnect, and SRT statistics.
- MPEG-TS demux parses PAT, PMT, PES, PTS/DTS, continuity counters, H.264, HEVC, and AAC stream routing.
- Media Foundation H.264/HEVC decoder discovery and input feed are implemented with hardware decoder preference.
- Windows recording writes received MPEG-TS packets without recompression to `recordings/ProCamLinkStudio-capture.ts`.
- Windows artifact packaging includes app runtime DLLs from vcpkg plus SRT/OpenSSL license notices.

Not claimed complete in this pass:

- D3D presentation of decoded frames.
- AAC decode/playback.
- Bonjour/mDNS discovery.
- ProCam Control Protocol network transport and iPhone acknowledgements.
- Windows virtual camera.
- Real iPhone-to-Windows validation.

## No Fake Controls Policy

The UI should expose only controls with real backing behavior. Features that need later pipeline work are tracked here and should not appear as working controls until implemented.

## Final Release Gate

Before triggering `.github/workflows/ios-ipa.yml`, perform a full audit with these categories:

- Implemented and wired to real hardware.
- Implemented as image processing.
- Unsupported by current API/device and dynamically handled.
- Not implemented.

Only after all required camera features are implemented and CI is green:

1. Set version to `1.0.0`.
2. Commit final release.
3. Push `main`.
4. Verify CI green.
5. Trigger the IPA workflow.
6. Download the artifact.
7. Place it at `D:\bika cam\builds\ProCamLinkStudio-v1.0.0.ipa`.
