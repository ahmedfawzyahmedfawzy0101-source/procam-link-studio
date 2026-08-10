# SRT iOS Integration Note

Real SRT streaming must use Haivision SRT/libsrt or another compatible SRT implementation. It should not be replaced with a custom UDP sender and called SRT.

Upstream Haivision SRT documents iOS/tvOS builds that produce `libsrt.xcframework` and `libcrypto.xcframework` from the SRT build scripts. Those frameworks then need to be linked into the Xcode app target with "Do Not Embed" unless the final framework packaging requires otherwise.

Current project status:

- `VideoToolboxEncoder` is available for H.264/HEVC compressed frames.
- Key video frames expose H.264 SPS/PPS or HEVC VPS/SPS/PPS parameter sets for Annex B stream output.
- `StreamingManager` converts VideoToolbox length-prefixed NAL units to Annex B access units.
- `AACEncoder` encodes microphone `CMSampleBuffer` PCM into AAC-LC with ADTS framing.
- `MPEGTransportStreamMuxer` provides PAT/PMT/PES/TS packetization for H.264/HEVC/AAC payloads.
- Clean and processed frame sources exist.
- `SRTConnectionConfiguration`, `SRTStatistics`, and `SRTTransport` define the app-side SRT surface.
- `SRTTransport` calls a C bridge backed by Haivision libsrt.
- The Stream panel configures caller/listener mode, host, port, latency, stream ID, passphrase, and start/stop.
- iOS CI builds `libsrt.xcframework` and `libcrypto.xcframework` from pinned upstream source before compiling the Xcode project.

Current stream path:

```text
AVCaptureVideoDataOutput
  -> VideoToolboxEncoder
  -> Annex B H.264/HEVC access units
  -> MPEGTransportStreamMuxer
  -> SRTTransport
  -> Haivision libsrt

AVCaptureAudioDataOutput
  -> AACEncoder
  -> ADTS AAC
  -> MPEGTransportStreamMuxer
  -> SRTTransport
  -> Haivision libsrt
```

Required external validation before marking OBS Direct release-ready:

1. Install the final IPA on the iPhone at the release gate.
2. Start an OBS Media Source or FFmpeg listener using the same SRT port.
3. Start the app Stream panel in caller mode toward the listener IP.
4. Confirm video decodes, audio decodes, A/V timing is acceptable, and reconnect behavior is sane.

No Apple ID, certificate, or signing credentials are required for adding these source dependencies. The final IPA signing policy remains handled by the existing manual IPA workflow and Sideloadly path.
