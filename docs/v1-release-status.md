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

Not claimed complete in this milestone:

- Metal/Core Image image-processing pipeline.
- Histogram/RGB histogram/waveform/zebras/focus peaking rendering.
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
