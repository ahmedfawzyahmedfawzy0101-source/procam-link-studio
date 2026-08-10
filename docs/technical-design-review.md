# ProCam Link Studio Technical Design Review

## 1. Architecture Diagram

```text
iPhone Camera App
  SwiftUI control surface
  CameraDeviceManager -> CameraSessionManager -> AVCaptureVideoDataOutput
                                      |             |
                                      |             v
                                      |       CVPixelBuffer
                                      |             |
                                      v             v
                              Preview layer   MetalPipeline
                                                    |
                                                    v
                                              VideoToolbox
                                                    |
                         RemoteControlProtocol <-> TransportManager
                                                    |
                         SRT / low-latency transport / wired research path
                                                    |
Windows Studio App                                  v
  Receiver -> Decoder -> Renderer -> VirtualCamera -> OBS/Zoom/Teams/etc.
       ^         |          |
       |         v          v
       +-- RemoteControlClient    Diagnostics/Recorder
```

## 2. iOS Technology Stack

- Swift, SwiftUI, AVFoundation, CoreVideo, Metal, VideoToolbox, Network framework.
- Phase 1 uses `AVCaptureSession` plus `AVCaptureVideoPreviewLayer` for a native, device-testable preview.
- Future capture uses `AVCaptureVideoDataOutput` and `CMSampleBuffer` timestamps as the single source of frame timing.
- Capabilities are queried from each selected `AVCaptureDevice`, its `formats`, and each format's frame-rate ranges. Apple documents formats as the source for capture capabilities such as dimensions, frame-rate ranges, and active format selection.

## 3. Windows Technology Stack

- C++20, WinUI 3 for shell UI, Direct3D 11/12 for preview rendering, Media Foundation for decode, Windows Runtime/COM for virtual camera output.
- Real-time video path avoids Electron.
- SRT receiver uses libsrt. HEVC/H.264 decode uses hardware acceleration through Media Foundation where available.

## 4. Capture Pipeline

```text
AVCaptureDeviceDiscoverySession
  -> selected physical or virtual camera
  -> selected AVCaptureDevice.Format
  -> AVCaptureVideoDataOutput
  -> CMSampleBuffer/CVPixelBuffer
  -> optional MetalPipeline
  -> VideoToolbox encoder
```

The app never hardcodes camera features. Resolution, frame rates, HDR, ISO, exposure duration, zoom, stabilization, color spaces, and pixel formats are read from the active device/format.

## 5. Metal Pipeline

- Wrap incoming `CVPixelBuffer` objects with `CVMetalTextureCache`.
- Keep processing on GPU textures.
- Modules: color transform, tone map, denoise, sharpen, contrast/saturation, exposure/gamma, LUT, monitoring overlays.
- Preview overlays are separate render passes and are excluded from the outgoing encoded stream unless explicitly enabled later.

## 6. Encoding Pipeline

- VideoToolbox `VTCompressionSession`.
- Codecs: H.264 first, HEVC and HEVC Main10 when hardware support and pixel format permit.
- Preserve `CMSampleBuffer` timing.
- User-settable bitrate, keyframe interval, GOP, real-time mode, and quality-priority mode.
- Encoder diagnostics report captured, submitted, encoded, and dropped frames.

## 7. Networking Design

- SRT mode for high-quality LAN/Wi-Fi with caller/listener support, encryption, latency, reconnect, and stats.
- Low-latency mode based on WebRTC or a similarly mature transport after the SRT vertical slice is stable.
- Control messages travel on a reliable side channel with acknowledgements and actual device values returned by iPhone.

## 8. Virtual-Camera Design

- Windows Studio receives and decodes frames into GPU textures.
- A Windows virtual camera named `ProCam Link Camera` exposes 1920x1080, 1080x1920, and 3840x2160 where the consumer app accepts them.
- Aspect ratio is preserved. Portrait frames remain portrait; no silent stretching or upscaling.

## 9. Remote-Control Protocol

- Message format: versioned JSON or compact binary after profiling.
- Commands include lens, format, FPS, exposure mode, ISO, shutter, focus, white balance, zoom, torch, codec, bitrate, HDR, and recording.
- Every command returns accepted/rejected plus the actual resulting device values.
- State snapshots are periodically sent from iPhone to Windows for UI truth.

## 10. Known Apple API Limitations

- AVFoundation exposes only capabilities available to the app on the current device and OS.
- Some features are format-specific, not device-wide.
- Optical lens availability must be inferred from discovered physical devices and virtual-device switch-over factors, then presented carefully.
- Camera access requires user permission and foreground capture behavior.

## 11. USB Feasibility Using Public APIs

Direct arbitrary iPhone-to-Windows USB video transport is not generally available to third-party iOS apps through a public "open USB socket" API. Apple's External Accessory framework is for communicating with MFi accessories and supported protocols, not for pretending that Wi-Fi transport is USB. The USB milestone will research officially permitted wired paths such as MFi accessory protocols, local network over tethering where available, or documented file/device mechanisms. If none supports real-time camera transport to a Windows app, the product will label USB as unsupported and keep wired alternatives documented honestly.

## 12. HDR/Color-Management Strategy

- Detect HDR and color spaces per `AVCaptureDevice.Format`.
- Preserve color attachments from sample buffers.
- SDR output targets Rec.709.
- HDR passthrough is available only when capture, encode, transport, decode, render, and consumer output can preserve it.
- HDR-to-SDR uses Metal tone mapping to avoid washed-out OBS output.

## 13. Latency Budget

Target low-latency preview mode:

- Capture: 5-16 ms
- Metal processing: 1-6 ms
- Encode: 4-12 ms
- Network: 5-30 ms on LAN
- Decode: 4-12 ms
- Render/virtual camera: 4-16 ms

Expected end-to-end target: 50-100 ms on good LAN for low-latency mode, higher for SRT quality mode depending on configured latency.

## 14. CPU/GPU/Memory Optimization Plan

- Use `CVPixelBuffer` and Metal textures; avoid `UIImage` in the frame path.
- Reuse texture caches, command queues, buffers, and encoder sessions.
- Avoid CPU color conversion unless an API boundary requires it.
- Keep preview, encode, and diagnostics queues separated.
- Back-pressure the pipeline instead of unbounded buffering.

## 15. Dependency/License List

- Apple frameworks: AVFoundation, SwiftUI, CoreVideo, Metal, VideoToolbox, Network.
- libsrt: MPL-2.0.
- Windows App SDK/WinUI 3: Microsoft licensing.
- WebRTC candidate: BSD-style license, final dependency to be selected during low-latency transport phase.
- No dependency may introduce license terms incompatible with commercial distribution without review.

## 16. Project Folder Structure

```text
docs/
  technical-design-review.md
ios/
  ProCamLinkStudio/
    ProCamLinkStudio.xcodeproj/
    ProCamLinkStudio/
      ProCamLinkStudioApp.swift
      ContentView.swift
      Camera/
        CameraDeviceManager.swift
        CameraSessionManager.swift
        CameraPreviewView.swift
windows/
  ProCamLinkStudio/
shared/
  protocol/
```

Phase 1 creates only the iOS app and this design document.

## 17. Milestone Plan

1. Phase 1: native iPhone camera preview, permission flow, device discovery, camera switching.
2. Phase 2: full capability scanner and export.
3. Phase 3: format/resolution/FPS selector.
4. Phase 4: manual exposure, focus, white balance, zoom, torch.
5. Phase 5: true portrait and rotation-safe output.
6. Phase 6: VideoToolbox encoder.
7. Phase 7: SRT transport.
8. Phase 8: Windows receiver prototype.
9. Phase 9: Windows remote controls.
10. Phase 10: Windows virtual camera.
11. Phase 11: Metal image-processing pipeline.
12. Phase 12: HDR/color management.
13. Phase 13: local master recording.
14. Phase 14: low-latency transport.
15. Phase 15: USB public-API research and implementation if feasible.
16. Phase 16: professional monitoring tools.
17. Phase 17: performance optimization.
18. Phase 18: stability, thermal, reconnect, and sustained tests.

## Phase 1 Manual Device Test Checklist

- Open the project in Xcode on macOS.
- Select a real iPhone target running iOS 17 or newer.
- Set a valid signing team and bundle identifier if needed.
- Build and run.
- Grant camera permission.
- Confirm live camera preview appears.
- Switch between every listed camera.
- Confirm unavailable cameras are not shown.
- Rotate the phone and confirm the preview remains usable.
- Background and foreground the app and confirm preview resumes.
- Deny camera permission from Settings and confirm the app shows a permission message instead of crashing.

## Sources

- Apple AVFoundation capture formats documentation: https://developer.apple.com/documentation/avfoundation/capture-device-formats
- Apple `AVCaptureDevice.Format` documentation: https://developer.apple.com/documentation/avfoundation/avcapturedevice/format
- Apple frame-rate ranges documentation: https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videosupportedframerateranges
- Apple External Accessory documentation: https://developer.apple.com/documentation/externalaccessory/
