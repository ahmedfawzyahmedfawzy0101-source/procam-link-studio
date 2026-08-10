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
