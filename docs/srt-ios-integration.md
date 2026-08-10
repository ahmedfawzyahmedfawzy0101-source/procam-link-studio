# SRT iOS Integration Note

Real SRT streaming must use Haivision SRT/libsrt or another compatible SRT implementation. It should not be replaced with a custom UDP sender and called SRT.

Upstream Haivision SRT documents iOS/tvOS builds that produce `libsrt.xcframework` and `libcrypto.xcframework` from the SRT build scripts. Those frameworks then need to be linked into the Xcode app target with "Do Not Embed" unless the final framework packaging requires otherwise.

Current project status:

- `VideoToolboxEncoder` is available for H.264/HEVC compressed frames.
- `MPEGTransportStreamMuxer` provides PAT/PMT/PES/TS packetization for H.264/HEVC/AAC payloads.
- Clean and processed frame sources exist.
- `SRTConnectionConfiguration`, `SRTStatistics`, and `SRTTransport` define the app-side SRT surface.
- `SRTTransport` intentionally reports a dependency-gated state and does not send traffic until real libsrt bindings are linked.
- The actual SRT socket sender is blocked until `libsrt.xcframework` and `libcrypto.xcframework` are added to the repo or produced in CI.

Required dependency work before marking SRT implemented:

1. Build `libsrt.xcframework` for iOS device and simulator using Haivision's iOS build instructions.
2. Build or provide the compatible `libcrypto.xcframework` dependency.
3. Add both frameworks to the Xcode project.
4. Add a thin Swift/C bridge for `srt_startup`, socket creation, caller/listener mode, connection, latency, encryption options, send, stats, and shutdown.
5. Feed length-prefixed encoded frames from `VideoToolboxEncoder` into the SRT sender.
6. Convert encoded video and AAC audio into MPEG-TS packets suitable for OBS/FFmpeg SRT input.
7. Validate against a real SRT listener such as Haivision tools, OBS Media Source, or an FFmpeg build with libsrt enabled.

No Apple ID, certificate, or signing credentials are required for adding these source dependencies. The final IPA signing policy remains handled by the existing manual IPA workflow and Sideloadly path.
