# SRT iOS Integration Note

Real SRT streaming must use Haivision SRT/libsrt or another compatible SRT implementation. It should not be replaced with a custom UDP sender and called SRT.

Upstream Haivision SRT documents iOS/tvOS builds that produce `libsrt.xcframework` and `libcrypto.xcframework` from the SRT build scripts. Those frameworks then need to be linked into the Xcode app target with "Do Not Embed" unless the final framework packaging requires otherwise.

Current project status:

- `VideoToolboxEncoder` is available for H.264/HEVC compressed frames.
- `MPEGTransportStreamMuxer` provides PAT/PMT/PES/TS packetization for H.264/HEVC/AAC payloads.
- Clean and processed frame sources exist.
- `SRTConnectionConfiguration`, `SRTStatistics`, and `SRTTransport` define the app-side SRT surface.
- `SRTTransport` calls a C bridge backed by Haivision libsrt.
- iOS CI builds `libsrt.xcframework` and `libcrypto.xcframework` from pinned upstream source before compiling the Xcode project.

Required dependency work before marking SRT implemented:

1. Finish feeding MPEG-TS packets from the live streaming pipeline into `SRTTransport`.
2. Validate against a real SRT listener such as Haivision tools, OBS Media Source, or an FFmpeg build with libsrt enabled.

No Apple ID, certificate, or signing credentials are required for adding these source dependencies. The final IPA signing policy remains handled by the existing manual IPA workflow and Sideloadly path.
