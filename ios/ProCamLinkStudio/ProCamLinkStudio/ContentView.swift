import AVFoundation
import SwiftUI

struct ContentView: View {
    var body: some View {
        CameraStudioView()
    }
}

private struct CameraStudioView: View {
    @StateObject private var cameraSession = CameraSessionManager()
    @StateObject private var deviceManager = CameraDeviceManager()

    @State private var selectedPanel: StudioPanel = .camera
    @State private var basePinchZoom: CGFloat = 1
    @State private var isSettingsPresented = false
    private let lensAssistTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch cameraSession.authorizationStatus {
            case .authorized:
                GeometryReader { geometry in
                    ZStack {
                        CameraPreviewView(
                            session: cameraSession.session,
                            fillMode: cameraSession.previewFillMode,
                            tapHandler: { point in
                                cameraSession.focusAndExpose(at: point)
                                cameraSession.selectTrackedSubject(at: point)
                            }
                        )
                        .ignoresSafeArea()
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    cameraSession.setZoom(basePinchZoom * value, ramp: false)
                                }
                                .onEnded { _ in
                                    basePinchZoom = cameraSession.zoomFactor
                                }
                        )

                        MonitoringOverlay(
                            monitoring: cameraSession.monitoringState,
                            thermal: cameraSession.thermalState,
                            focusPoint: cameraSession.focusState.focusPoint,
                            tracking: cameraSession.trackingState,
                            horizon: cameraSession.horizonState,
                            analysis: cameraSession.monitoringAnalysis,
                            geometry: geometry
                        )

                        CameraHUD(
                            cameraSession: cameraSession,
                            devices: deviceManager.devices,
                            activeDeviceID: cameraSession.activeDeviceID,
                            openSettings: { isSettingsPresented = true },
                            selectDevice: { device in
                                Task { await cameraSession.configure(device: device) }
                            }
                        )
                    }
                }
                .task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await configureFirstAvailableCamera()
                }

            case .notDetermined:
                PermissionView {
                    Task { await cameraSession.requestCameraAccess() }
                }

            default:
                PermissionDeniedView()
            }
        }
        .statusBarHidden(true)
        .onAppear {
            deviceManager.refreshDevices()
            cameraSession.refreshAuthorizationStatus()
            cameraSession.refreshAudioAuthorizationStatus()
        }
        .onDisappear {
            cameraSession.stop()
        }
        .onReceive(lensAssistTimer) { _ in
            guard let deviceID = cameraSession.evaluateLensAssist(devices: deviceManager.devices),
                  let device = deviceManager.devices.first(where: { $0.device.uniqueID == deviceID })?.device else {
                return
            }
            Task { await cameraSession.configure(device: device) }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(
                selectedPanel: $selectedPanel,
                cameraSession: cameraSession
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
    }

    private func configureFirstAvailableCamera() async {
        guard cameraSession.activeDeviceID == nil, let firstDevice = deviceManager.devices.first?.device else {
            return
        }
        await cameraSession.configure(device: firstDevice)
        basePinchZoom = cameraSession.zoomFactor
    }
}

private struct CameraHUD: View {
    @ObservedObject var cameraSession: CameraSessionManager
    let devices: [CameraDevice]
    let activeDeviceID: String?
    let openSettings: () -> Void
    let selectDevice: (AVCaptureDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopTelemetryBar(cameraSession: cameraSession, openSettings: openSettings)

            Spacer()

            LensStrip(
                devices: devices,
                activeDeviceID: activeDeviceID,
                select: selectDevice
            )
            .padding(.bottom, 6)
        }
        .foregroundStyle(.white)
    }
}

private struct SettingsSheet: View {
    @Binding var selectedPanel: StudioPanel
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        NavigationStack {
            ControlDock(
                selectedPanel: $selectedPanel,
                cameraSession: cameraSession
            )
            .padding(.top, 8)
            .navigationTitle(selectedPanel.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
        .background(Color.black)
    }
}

private struct PermissionView: View {
    let requestAccess: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("ProCam Link Studio")
                .font(.title2.weight(.semibold))
            Button("Allow Camera") {
                requestAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding()
    }
}

private struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Camera access required")
                .font(.title3.weight(.semibold))
            Text("Enable camera permission in iOS Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding()
    }
}

private struct TopTelemetryBar: View {
    @ObservedObject var cameraSession: CameraSessionManager
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cameraSession.activeDeviceName ?? "No Camera")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 7) {
                Button(cameraSession.previewFillMode.rawValue) {
                    cameraSession.setPreviewFillMode(cameraSession.previewFillMode == .fill ? .fit : .fill)
                }
                .buttonStyle(CompactButtonStyle())

                if cameraSession.capabilities.hasTorch {
                    Button("Torch") {
                        cameraSession.toggleTorch()
                    }
                    .buttonStyle(CompactButtonStyle())
                }

                Button(cameraSession.streamingStatus.isStreaming ? "Stop SRT" : "Stream") {
                    cameraSession.toggleStreaming()
                }
                .buttonStyle(RecordButtonStyle(isRecording: cameraSession.streamingStatus.isStreaming))

                Button(cameraSession.recordingState.isRecording ? "Stop" : "Rec") {
                    cameraSession.toggleRecording()
                }
                .buttonStyle(RecordButtonStyle(isRecording: cameraSession.recordingState.isRecording))

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(IconPillButtonStyle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.42))
    }

    private var statusLine: String {
        let iso = Int(cameraSession.exposureState.iso.rounded())
        let shutter = shutterLabel(seconds: cameraSession.exposureState.shutterSeconds)
        let ev = String(format: "%+.1fEV", cameraSession.exposureState.exposureBias)
        let zoom = String(format: "%.1fx", cameraSession.zoomFactor)
        return "\(zoom)  ISO \(iso)  \(shutter)  \(ev)"
    }
}

private struct LensStrip: View {
    let devices: [CameraDevice]
    let activeDeviceID: String?
    let select: (AVCaptureDevice) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(devices) { camera in
                    Button {
                        select(camera.device)
                    } label: {
                        VStack(spacing: 1) {
                            Text(camera.zoomBadge)
                                .font(.footnote.weight(.bold))
                            Text(camera.device.position == .front ? "Front" : "Optical")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .frame(width: 68, height: 42)
                    }
                    .buttonStyle(LensButtonStyle(isActive: camera.id == activeDeviceID))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.black.opacity(0.24))
    }
}

private struct ControlDock: View {
    @Binding var selectedPanel: StudioPanel
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(StudioPanel.allCases) { panel in
                        Button(panel.rawValue) {
                            selectedPanel = panel
                        }
                        .buttonStyle(SegmentButtonStyle(isActive: selectedPanel == panel))
                    }
                }
            }

            switch selectedPanel {
            case .camera:
                CameraControlPanel(cameraSession: cameraSession)
            case .video:
                VideoControlPanel(cameraSession: cameraSession)
            case .stream:
                StreamControlPanel(cameraSession: cameraSession)
            case .image:
                ImageControlPanel(cameraSession: cameraSession)
            case .smart:
                SmartControlPanel(cameraSession: cameraSession)
            case .monitoring:
                MonitoringControlPanel(cameraSession: cameraSession)
            case .app:
                AppControlPanel(cameraSession: cameraSession)
            }
        }
        .padding(10)
        .background(.black.opacity(0.62))
    }
}

private struct CameraControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 12) {
            SliderRow(
                title: "Zoom",
                value: Binding(
                    get: { Double(cameraSession.zoomFactor) },
                    set: { cameraSession.setZoom(CGFloat($0), ramp: true) }
                ),
                range: Double(cameraSession.capabilities.minZoom)...Double(cameraSession.capabilities.maxZoom),
                display: String(format: "%.1fx", cameraSession.zoomFactor)
            )

            if cameraSession.capabilities.hasTorch {
                SliderRow(
                    title: "Torch",
                    value: Binding(
                        get: { Double(cameraSession.torchLevel) },
                        set: { cameraSession.setTorch(enabled: true, level: Float($0)) }
                    ),
                    range: 0.01...1,
                    display: "\(Int(cameraSession.torchLevel * 100))%"
                )
            }

            PickerRow(title: "Exposure", selection: Binding(
                get: { cameraSession.exposureState.mode },
                set: { cameraSession.setExposureMode($0) }
            ))

            if cameraSession.capabilities.supportsManualExposure {
                SliderRow(
                    title: "ISO",
                    value: Binding(
                        get: { Double(cameraSession.exposureState.iso) },
                        set: { cameraSession.setManualExposure(iso: Float($0)) }
                    ),
                    range: Double(cameraSession.capabilities.minISO)...Double(cameraSession.capabilities.maxISO),
                    display: "\(Int(cameraSession.exposureState.iso.rounded()))"
                )

                SliderRow(
                    title: "Shutter",
                    value: Binding(
                        get: { cameraSession.exposureState.shutterSeconds },
                        set: { cameraSession.setManualExposure(shutterSeconds: $0) }
                    ),
                    range: cameraSession.capabilities.minExposureSeconds...cameraSession.capabilities.maxExposureSeconds,
                    display: shutterLabel(seconds: cameraSession.exposureState.shutterSeconds)
                )
            }

            if cameraSession.capabilities.supportsExposureBias {
                SliderRow(
                    title: "EV",
                    value: Binding(
                        get: { Double(cameraSession.exposureState.exposureBias) },
                        set: { cameraSession.setExposureBias(Float($0)) }
                    ),
                    range: Double(cameraSession.capabilities.minExposureBias)...Double(cameraSession.capabilities.maxExposureBias),
                    display: String(format: "%+.1f", cameraSession.exposureState.exposureBias)
                )
            }

            PickerRow(title: "Focus", selection: Binding(
                get: { cameraSession.focusState.mode },
                set: { cameraSession.setFocusMode($0) }
            ))

            if cameraSession.capabilities.supportsManualFocus {
                SliderRow(
                    title: "Lens",
                    value: Binding(
                        get: { Double(cameraSession.focusState.lensPosition) },
                        set: { cameraSession.setManualFocus(Float($0)) }
                    ),
                    range: 0...1,
                    display: String(format: "%.2f", cameraSession.focusState.lensPosition)
                )
            }

            PickerRow(title: "WB", selection: Binding(
                get: { cameraSession.whiteBalanceState.mode },
                set: { cameraSession.setWhiteBalanceMode($0) }
            ))

            if cameraSession.capabilities.supportsManualWhiteBalance {
                HStack(spacing: 6) {
                    ForEach([3200, 4300, 5600, 6500], id: \.self) { kelvin in
                        Button("\(kelvin)K") {
                            cameraSession.setManualWhiteBalance(temperature: Float(kelvin))
                        }
                        .buttonStyle(CompactButtonStyle())
                    }
                }

                SliderRow(
                    title: "Kelvin",
                    value: Binding(
                        get: { Double(cameraSession.whiteBalanceState.temperature) },
                        set: { cameraSession.setManualWhiteBalance(temperature: Float($0)) }
                    ),
                    range: 2_000...10_000,
                    display: "\(Int(cameraSession.whiteBalanceState.temperature))K"
                )

                SliderRow(
                    title: "Tint",
                    value: Binding(
                        get: { Double(cameraSession.whiteBalanceState.tint) },
                        set: { cameraSession.setManualWhiteBalance(tint: Float($0)) }
                    ),
                    range: -150...150,
                    display: String(format: "%+.0f", cameraSession.whiteBalanceState.tint)
                )
            }
        }
    }
}

private struct VideoControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 8) {
            if cameraSession.formats.isEmpty {
                Text("No selectable video formats reported by this camera.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cameraSession.formats.prefix(14)) { format in
                            Button(format.label) {
                                let targetFPS = min(format.maxFPS, format.maxFPS >= 60 ? 60 : 30)
                                cameraSession.apply(format: format, fps: targetFPS)
                            }
                            .buttonStyle(SegmentButtonStyle(isActive: format.id == cameraSession.selectedFormatID))
                        }
                    }
                }
            }

            HStack {
                Badge(title: "HDR", value: cameraSession.capabilities.supportsHDR ? "Supported" : "Unavailable")
                Badge(title: "Color", value: cameraSession.capabilities.supportsHDR ? "SDR/HDR" : "Rec.709")
                Badge(title: "Rec", value: cameraSession.selectedRecordingMode.rawValue)
                Badge(title: "Timer", value: recordingTime)
            }

            ToggleRow(
                title: "Audio",
                isOn: Binding(
                    get: { cameraSession.audioMeter.isEnabled },
                    set: { cameraSession.setAudioEnabled($0) }
                )
            )

            HStack(spacing: 8) {
                ForEach(RecordingMode.allCases) { mode in
                    Button(mode.rawValue) {
                        cameraSession.setRecordingMode(mode)
                    }
                    .buttonStyle(SegmentButtonStyle(isActive: cameraSession.selectedRecordingMode == mode))
                    .disabled(cameraSession.recordingState.isRecording)
                }

                ForEach(cameraSession.availableRecordingCodecs) { codec in
                    Button(codec.rawValue) {
                        cameraSession.setRecordingCodec(codec)
                    }
                    .buttonStyle(SegmentButtonStyle(isActive: cameraSession.selectedRecordingCodec == codec))
                    .disabled(cameraSession.recordingState.isRecording)
                }
            }

            HStack(spacing: 8) {
                ForEach(RecordingQualityPreset.allCases) { quality in
                    Button(quality.rawValue) {
                        cameraSession.setRecordingQuality(quality)
                    }
                    .buttonStyle(SegmentButtonStyle(isActive: cameraSession.selectedRecordingQuality == quality))
                    .disabled(cameraSession.recordingState.isRecording)
                }
            }

            HStack(spacing: 8) {
                if let warning = cameraSession.recordingState.storageWarning {
                    Text(warning)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                }
                if let path = cameraSession.recordingState.lastRecordingPath {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }

            HStack {
                Badge(title: "Quality", value: cameraSession.selectedRecordingQuality.rawValue)
                Badge(title: "Output", value: cameraSession.recordingState.outputResolution ?? "Pending")
                Badge(title: "Frames", value: "\(cameraSession.recordingState.encodedFrames)")
                Badge(title: "Dropped", value: "\(cameraSession.recordingState.droppedFrames)")
            }

            HStack {
                Badge(title: "Mic", value: cameraSession.audioMeter.isAuthorized ? "Ready" : "No Access")
                Badge(title: "Level", value: cameraSession.audioMeter.levelLabel)
                Badge(title: "Peak", value: "\(Int((cameraSession.audioMeter.peakLevel * 100).rounded()))%")
                Badge(title: "Sync", value: syncOffsetLabel)
            }

            if let sync = cameraSession.recordingState.syncStatus {
                Text(sync)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
    }

    private var recordingTime: String {
        let seconds = Int(cameraSession.recordingState.elapsedSeconds.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var syncOffsetLabel: String {
        guard let offset = cameraSession.audioMeter.syncOffsetMS else { return "-" }
        return String(format: "%+.1fms", offset)
    }
}

private struct StreamControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(SRTConnectionMode.allCases) { mode in
                    Button(mode.rawValue) {
                        updateConfig { $0.mode = mode }
                    }
                    .buttonStyle(SegmentButtonStyle(isActive: cameraSession.srtConfiguration.mode == mode))
                    .disabled(cameraSession.streamingStatus.isStreaming)
                }

                Button(cameraSession.streamingStatus.isStreaming ? "Stop SRT" : "Start SRT") {
                    cameraSession.toggleStreaming()
                }
                .buttonStyle(RecordButtonStyle(isRecording: cameraSession.streamingStatus.isStreaming))
            }

            HStack(spacing: 8) {
                TextField("Host", text: Binding(
                    get: { cameraSession.srtConfiguration.host },
                    set: { value in updateConfig { $0.host = value } }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(StreamTextFieldStyle())

                TextField("Port", text: Binding(
                    get: { "\(cameraSession.srtConfiguration.port)" },
                    set: { value in
                        updateConfig { $0.port = UInt16(value) ?? $0.port }
                    }
                ))
                .keyboardType(.numberPad)
                .frame(width: 72)
                .textFieldStyle(StreamTextFieldStyle())
            }

            if cameraSession.srtConfiguration.host == "127.0.0.1" || cameraSession.srtConfiguration.host.lowercased() == "localhost" {
                Text("127.0.0.1 sends to the iPhone itself. Enter the Windows IP shown in ProCam Link Studio.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField("Stream ID", text: Binding(
                    get: { cameraSession.srtConfiguration.streamID },
                    set: { value in updateConfig { $0.streamID = value } }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(StreamTextFieldStyle())

                SecureField("Passphrase", text: Binding(
                    get: { cameraSession.srtConfiguration.passphrase },
                    set: { value in updateConfig { $0.passphrase = value } }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(StreamTextFieldStyle())
            }

            SliderRow(
                title: "Latency",
                value: Binding(
                    get: { Double(cameraSession.srtConfiguration.latencyMS) },
                    set: { value in updateConfig { $0.latencyMS = Int(value.rounded()) } }
                ),
                range: 40...800,
                display: "\(cameraSession.srtConfiguration.latencyMS)ms"
            )

            HStack {
                Badge(title: "State", value: streamStateLabel)
                Badge(title: "Rate", value: String(format: "%.2f Mbps", cameraSession.streamingStatus.statistics.sendBitrateMbps))
                Badge(title: "RTT", value: String(format: "%.0f ms", cameraSession.streamingStatus.statistics.rttMS))
                Badge(title: "Frames", value: "\(cameraSession.streamingStatus.encodedFrames)")
            }

            HStack {
                Badge(title: "Loss", value: String(format: "%.2f%%", cameraSession.streamingStatus.statistics.packetLossPercent))
                Badge(title: "Queue", value: "\(cameraSession.streamingStatus.statistics.sendQueueDepth)")
                Badge(title: "Dropped", value: "\(cameraSession.streamingStatus.droppedFrames + cameraSession.streamingStatus.statistics.droppedQueuePackets)")
                Badge(title: "Sent", value: sentSizeLabel)
            }
        }
    }

    private var streamStateLabel: String {
        switch cameraSession.streamingStatus.state {
        case .disconnected:
            return "Idle"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .reconnecting(let attempt):
            return "Retry \(attempt)"
        case .disconnecting:
            return "Stopping"
        case .failed:
            return "Failed"
        }
    }

    private var sentSizeLabel: String {
        let megabytes = Double(cameraSession.streamingStatus.sentBytes) / 1_000_000
        return String(format: "%.1f MB", megabytes)
    }

    private func updateConfig(_ update: (inout SRTConnectionConfiguration) -> Void) {
        var next = cameraSession.srtConfiguration
        update(&next)
        cameraSession.updateSRTConfiguration(next)
    }
}

private struct ImageControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LookPreset.allCases) { look in
                            Button(look.rawValue) {
                                var next = cameraSession.imageAdjustments
                                next.look = look
                                if look == .natural {
                                    next.lookIntensity = 0
                                } else if next.lookIntensity == 0 {
                                    next.lookIntensity = 0.5
                                }
                                cameraSession.updateImageAdjustments(next)
                            }
                            .buttonStyle(SegmentButtonStyle(isActive: cameraSession.imageAdjustments.look == look))
                        }
                    }
                }

                AdjustmentSlider(
                    title: "Look",
                    value: imageBinding(\.lookIntensity),
                    range: 0...1,
                    display: String(format: "%.0f%%", cameraSession.imageAdjustments.lookIntensity * 100)
                )

                AdjustmentSlider(title: "Exposure", value: imageBinding(\.exposure), range: -2...2, display: signed(cameraSession.imageAdjustments.exposure))
                AdjustmentSlider(title: "Contrast", value: imageBinding(\.contrast), range: 0.5...1.5, display: String(format: "%.2f", cameraSession.imageAdjustments.contrast))
                AdjustmentSlider(title: "Highlights", value: imageBinding(\.highlights), range: -1...1, display: signed(cameraSession.imageAdjustments.highlights))
                AdjustmentSlider(title: "Shadows", value: imageBinding(\.shadows), range: -1...1, display: signed(cameraSession.imageAdjustments.shadows))
                AdjustmentSlider(title: "Whites", value: imageBinding(\.whites), range: -1...1, display: signed(cameraSession.imageAdjustments.whites))
                AdjustmentSlider(title: "Blacks", value: imageBinding(\.blacks), range: -1...1, display: signed(cameraSession.imageAdjustments.blacks))
                AdjustmentSlider(title: "Saturation", value: imageBinding(\.saturation), range: 0...2, display: String(format: "%.2f", cameraSession.imageAdjustments.saturation))
                AdjustmentSlider(title: "Vibrance", value: imageBinding(\.vibrance), range: -1...1, display: signed(cameraSession.imageAdjustments.vibrance))
                AdjustmentSlider(title: "Temperature", value: imageBinding(\.temperature), range: -1500...1500, display: String(format: "%+.0fK", cameraSession.imageAdjustments.temperature))
                AdjustmentSlider(title: "Tint", value: imageBinding(\.tint), range: -100...100, display: signed(cameraSession.imageAdjustments.tint))
                AdjustmentSlider(title: "Sharpness", value: imageBinding(\.sharpness), range: 0...1, display: String(format: "%.2f", cameraSession.imageAdjustments.sharpness))
                AdjustmentSlider(title: "Denoise", value: imageBinding(\.denoise), range: 0...1, display: String(format: "%.2f", cameraSession.imageAdjustments.denoise))
                AdjustmentSlider(title: "Gamma", value: imageBinding(\.gamma), range: 0.5...1.8, display: String(format: "%.2f", cameraSession.imageAdjustments.gamma))
                AdjustmentSlider(title: "Vignette", value: imageBinding(\.vignette), range: 0...2, display: String(format: "%.2f", cameraSession.imageAdjustments.vignette))

                Button("Reset All") {
                    cameraSession.resetImageAdjustments()
                }
                .buttonStyle(CompactButtonStyle())
            }
        }
        .frame(maxHeight: 330)
    }

    private func imageBinding(_ keyPath: WritableKeyPath<ImageAdjustmentState, Double>) -> Binding<Double> {
        Binding(
            get: { cameraSession.imageAdjustments[keyPath: keyPath] },
            set: { value in
                var next = cameraSession.imageAdjustments
                next[keyPath: keyPath] = value
                cameraSession.updateImageAdjustments(next)
            }
        )
    }

    private func signed(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }
}

private struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 82, alignment: .leading)
            Slider(value: $value, in: range)
            Text(display)
                .font(.caption.monospacedDigit())
                .frame(width: 62, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }
}

private struct SmartControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 10) {
            PickerRow(title: "Track", selection: Binding(
                get: { cameraSession.trackingState.mode },
                set: { cameraSession.setTrackingMode($0) }
            ))

            PickerRow(title: "Frame", selection: Binding(
                get: { cameraSession.smartFraming.mode },
                set: {
                    var next = cameraSession.smartFraming
                    next.mode = $0
                    cameraSession.updateSmartFraming(next)
                }
            ))

            SliderRow(title: "Speed", value: smartBinding(\.followSpeed), range: 0.05...1, display: String(format: "%.2f", cameraSession.smartFraming.followSpeed))
            SliderRow(title: "Smooth", value: smartBinding(\.smoothness), range: 0...1, display: String(format: "%.2f", cameraSession.smartFraming.smoothness))
            SliderRow(title: "Dead", value: smartBinding(\.deadZone), range: 0...0.25, display: String(format: "%.2f", cameraSession.smartFraming.deadZone))
            SliderRow(title: "Max Z", value: smartBinding(\.maxDigitalZoom), range: 1...3, display: String(format: "%.1fx", cameraSession.smartFraming.maxDigitalZoom))
            SliderRow(title: "Min Z", value: smartBinding(\.minDigitalZoom), range: 1...2, display: String(format: "%.1fx", cameraSession.smartFraming.minDigitalZoom))
            SliderRow(title: "Head", value: smartBinding(\.headroom), range: -0.2...0.3, display: String(format: "%+.2f", cameraSession.smartFraming.headroom))
            SliderRow(title: "Look", value: smartBinding(\.lookRoom), range: -0.25...0.25, display: String(format: "%+.2f", cameraSession.smartFraming.lookRoom))
            SliderRow(title: "H Bias", value: smartBinding(\.horizontalBias), range: -0.35...0.35, display: String(format: "%+.2f", cameraSession.smartFraming.horizontalBias))
            SliderRow(title: "V Bias", value: smartBinding(\.verticalBias), range: -0.35...0.35, display: String(format: "%+.2f", cameraSession.smartFraming.verticalBias))
            SliderRow(title: "Tight", value: smartBinding(\.tightness), range: 0.2...1, display: String(format: "%.2f", cameraSession.smartFraming.tightness))

            HStack(spacing: 8) {
                Text("Native")
                    .font(.caption.weight(.semibold))
                    .frame(width: 58, alignment: .leading)
                ForEach(cameraSession.nativeStabilization.availableModes) { mode in
                    Button(mode.rawValue) {
                        cameraSession.setNativeStabilization(mode)
                    }
                    .buttonStyle(SegmentButtonStyle(isActive: cameraSession.nativeStabilization.selectedMode == mode))
                }
            }

            PickerRow(title: "Horizon", selection: Binding(
                get: { cameraSession.stabilizationSettings.horizonMode },
                set: {
                    var next = cameraSession.stabilizationSettings
                    next.horizonMode = $0
                    cameraSession.updateStabilizationSettings(next)
                }
            ))

            PickerRow(title: "Digital", selection: Binding(
                get: { cameraSession.stabilizationSettings.digitalMode },
                set: {
                    var next = cameraSession.stabilizationSettings
                    next.digitalMode = $0
                    cameraSession.updateStabilizationSettings(next)
                }
            ))

            SliderRow(title: "Stab", value: stabilizationBinding(\.strength), range: 0...1, display: String(format: "%.2f", cameraSession.stabilizationSettings.strength))
            SliderRow(title: "Crop", value: stabilizationBinding(\.cropSafetyMargin), range: 0...0.25, display: String(format: "%.0f%%", cameraSession.stabilizationSettings.cropSafetyMargin * 100))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StabilizationPreset.allCases) { preset in
                        Button(preset.rawValue) {
                            cameraSession.applyStabilizationPreset(preset)
                        }
                        .buttonStyle(CompactButtonStyle())
                    }
                }
            }

            ToggleRow(
                title: "Auto Lens",
                isOn: Binding(
                    get: { cameraSession.lensAssist.isAutoLensEnabled },
                    set: { cameraSession.setAutoLensEnabled($0) }
                )
            )

            HStack {
                Badge(title: "Subjects", value: "\(cameraSession.trackingState.subjects.count)")
                Badge(title: "Confidence", value: "\(Int(cameraSession.trackingState.selectedConfidence * 100))%")
                Badge(title: "State", value: cameraSession.trackingState.lifecycle.rawValue)
                Badge(title: "Native", value: cameraSession.nativeStabilization.activeMode.rawValue)
                Badge(title: "Horizon", value: cameraSession.horizonState.isAvailable ? String(format: "%+.1f deg", cameraSession.horizonState.rollDegrees) : "Unavailable")
            }

            HStack {
                Badge(title: "Lens", value: cameraSession.lensAssist.recommendedLabel)
                Badge(title: "Reason", value: cameraSession.lensAssist.pendingSwitchLabel.map { "OPTICAL SWITCH \($0)" } ?? cameraSession.lensAssist.reason)
                Badge(title: "Digital", value: String(format: "%.1fx", cameraSession.zoomFactor))
            }
        }
    }

    private func smartBinding(_ keyPath: WritableKeyPath<SmartFramingSettings, Double>) -> Binding<Double> {
        Binding(
            get: { cameraSession.smartFraming[keyPath: keyPath] },
            set: { value in
                var next = cameraSession.smartFraming
                next[keyPath: keyPath] = value
                cameraSession.updateSmartFraming(next)
            }
        )
    }

    private func stabilizationBinding(_ keyPath: WritableKeyPath<StabilizationSettings, Double>) -> Binding<Double> {
        Binding(
            get: { cameraSession.stabilizationSettings[keyPath: keyPath] },
            set: { value in
                var next = cameraSession.stabilizationSettings
                next[keyPath: keyPath] = value
                cameraSession.updateStabilizationSettings(next)
            }
        )
    }
}

private struct MonitoringControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 8) {
            ToggleRow(title: "Grid", isOn: $cameraSession.monitoringState.grid)
            ToggleRow(title: "Center", isOn: $cameraSession.monitoringState.centerMarker)
            ToggleRow(title: "Thermal", isOn: $cameraSession.monitoringState.showThermal)
            ToggleRow(title: "Histogram", isOn: $cameraSession.monitoringState.histogram)
            ToggleRow(title: "RGB Hist", isOn: $cameraSession.monitoringState.rgbHistogram)
            ToggleRow(title: "Waveform", isOn: $cameraSession.monitoringState.waveform)
            ToggleRow(title: "RGB Parade", isOn: $cameraSession.monitoringState.rgbParade)
            ToggleRow(title: "Vectorscope", isOn: $cameraSession.monitoringState.vectorscope)
            ToggleRow(title: "False Color", isOn: $cameraSession.monitoringState.falseColor)
            SliderRow(title: "FC Op", value: monitoringBinding(\.falseColorOpacity), range: 0...1, display: String(format: "%.0f%%", cameraSession.monitoringState.falseColorOpacity * 100))
            ToggleRow(title: "Peaking", isOn: $cameraSession.monitoringState.focusPeaking)
            SliderRow(title: "Peak", value: monitoringBinding(\.focusPeakingSensitivity), range: 0.1...1, display: String(format: "%.2f", cameraSession.monitoringState.focusPeakingSensitivity))
            ToggleRow(title: "Zebras", isOn: $cameraSession.monitoringState.zebras)
            SliderRow(title: "Z Low", value: monitoringBinding(\.zebraLowThreshold), range: 0...1, display: String(format: "%.0f%%", cameraSession.monitoringState.zebraLowThreshold * 100))
            SliderRow(title: "Z High", value: monitoringBinding(\.zebraHighThreshold), range: 0...1, display: String(format: "%.0f%%", cameraSession.monitoringState.zebraHighThreshold * 100))

            HStack {
                Badge(title: "Clip", value: String(format: "%.1f%%", cameraSession.monitoringAnalysis.clippingPercent * 100))
                Badge(title: "Shadows", value: String(format: "%.1f%%", cameraSession.monitoringAnalysis.shadowsPercent * 100))
                Badge(title: "Scope", value: String(format: "%.1f ms", cameraSession.monitoringAnalysis.analysisMS))
            }
        }
    }

    private func monitoringBinding(_ keyPath: WritableKeyPath<MonitoringState, Double>) -> Binding<Double> {
        Binding(
            get: { cameraSession.monitoringState[keyPath: keyPath] },
            set: { cameraSession.monitoringState[keyPath: keyPath] = $0 }
        )
    }
}

private struct AppControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Badge(title: "Thermal", value: cameraSession.thermalState.title)
                Badge(title: "Preview", value: cameraSession.previewFillMode.rawValue)
                Badge(title: "Profile", value: cameraSession.activeProfileName)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cameraSession.profiles) { profile in
                        Button(profile.name) {
                            cameraSession.applyProfile(profile)
                        }
                        .buttonStyle(SegmentButtonStyle(isActive: cameraSession.activeProfileName == profile.name))
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Save Custom") {
                    cameraSession.saveCustomProfile()
                }
                .buttonStyle(CompactButtonStyle())

                if let custom = cameraSession.profiles.last(where: { !$0.isBuiltIn }) {
                    Button("Delete Last") {
                        cameraSession.deleteCustomProfile(custom)
                    }
                    .buttonStyle(CompactButtonStyle())
                }
            }

            if let error = cameraSession.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }
}

private struct MonitoringOverlay: View {
    let monitoring: MonitoringState
    let thermal: ThermalStateLabel
    let focusPoint: CGPoint?
    let tracking: TrackingState
    let horizon: HorizonState
    let analysis: MonitoringAnalysisState
    let geometry: GeometryProxy

    var body: some View {
        ZStack {
            if monitoring.grid {
                GridOverlay()
                    .stroke(.white.opacity(0.28), lineWidth: 0.7)
            }

            if monitoring.centerMarker {
                CenterMarker()
                    .stroke(.white.opacity(0.72), lineWidth: 1)
                    .frame(width: 34, height: 34)
            }

            if let focusPoint {
                FocusReticle()
                    .stroke(.yellow, lineWidth: 1.6)
                    .frame(width: 70, height: 70)
                    .position(x: focusPoint.x * geometry.size.width, y: focusPoint.y * geometry.size.height)
            }

            ForEach(tracking.subjects) { subject in
                SubjectBox(subject: subject)
                    .frame(width: subject.normalizedRect.width * geometry.size.width, height: subject.normalizedRect.height * geometry.size.height)
                    .position(x: subject.normalizedRect.midX * geometry.size.width, y: subject.normalizedRect.midY * geometry.size.height)
            }

            if horizon.isAvailable {
                HorizonOverlay()
                    .stroke(abs(horizon.rollDegrees) > 2 ? .yellow : .green, lineWidth: 1.5)
                    .frame(width: 150, height: 28)
                    .rotationEffect(.degrees(horizon.rollDegrees))
            }

            if monitoring.histogram || monitoring.rgbHistogram {
                HistogramOverlay(
                    luma: analysis.lumaHistogram,
                    red: monitoring.rgbHistogram ? analysis.redHistogram : [],
                    green: monitoring.rgbHistogram ? analysis.greenHistogram : [],
                    blue: monitoring.rgbHistogram ? analysis.blueHistogram : []
                )
                .frame(width: 150, height: 70)
                .position(x: 90, y: 118)
            }

            if monitoring.waveform {
                ScopeTraceOverlay(title: "WFM", traces: [(analysis.lumaWaveform, .white)])
                    .frame(width: 160, height: 70)
                    .position(x: geometry.size.width - 92, y: 118)
            }

            if monitoring.rgbParade {
                ScopeTraceOverlay(title: "RGB", traces: [
                    (analysis.redParade, .red),
                    (analysis.greenParade, .green),
                    (analysis.blueParade, .blue)
                ])
                .frame(width: 160, height: 70)
                .position(x: geometry.size.width - 92, y: 198)
            }

            if monitoring.vectorscope {
                VectorscopeOverlay(points: analysis.vectorscopePoints)
                    .frame(width: 92, height: 92)
                    .position(x: 70, y: 208)
            }

            if monitoring.falseColor {
                FalseColorLegend()
                    .frame(width: 34, height: 130)
                    .position(x: geometry.size.width - 28, y: geometry.size.height * 0.5)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if monitoring.showThermal {
                        Text(thermal.title)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background((thermal.isRisky ? Color.red : Color.black).opacity(0.55))
                            .clipShape(Capsule())
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 188)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 58, alignment: .leading)
            Slider(value: $value, in: range)
            Text(display)
                .font(.caption.monospacedDigit())
                .frame(width: 66, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }
}

private struct PickerRow<Value>: View where Value: CaseIterable & Hashable & Identifiable & RawRepresentable, Value.RawValue == String {
    let title: String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 58, alignment: .leading)
            ForEach(Array(Value.allCases), id: \.self) { value in
                Button(value.rawValue) {
                    selection = value
                }
                .buttonStyle(SegmentButtonStyle(isActive: selection == value))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .toggleStyle(.switch)
    }
}

private struct Badge: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

private struct CenterMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + 10))
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY - 10))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + 10, y: rect.midY))
        path.move(to: CGPoint(x: rect.maxX - 10, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct FocusReticle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
        return path
    }
}

private struct SubjectBox: View {
    let subject: DetectedSubject

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(subject.isSelected ? .yellow : .cyan, lineWidth: subject.isSelected ? 2 : 1)
            Text("\(subject.kind.rawValue) \(Int(subject.confidence * 100))%")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(subject.isSelected ? Color.yellow : Color.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .offset(x: 4, y: 4)
        }
    }
}

private struct HorizonOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - 10))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 10))
        return path
    }
}

private struct HistogramOverlay: View {
    let luma: [Double]
    let red: [Double]
    let green: [Double]
    let blue: [Double]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.black.opacity(0.52))
            HistogramPath(values: luma)
                .stroke(.white, lineWidth: 1)
                .padding(6)
            if !red.isEmpty {
                HistogramPath(values: red)
                    .stroke(.red.opacity(0.72), lineWidth: 1)
                    .padding(6)
                HistogramPath(values: green)
                    .stroke(.green.opacity(0.72), lineWidth: 1)
                    .padding(6)
                HistogramPath(values: blue)
                    .stroke(.blue.opacity(0.72), lineWidth: 1)
                    .padding(6)
            }
        }
    }
}

private struct HistogramPath: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for index in values.indices {
            let x = rect.minX + CGFloat(index) * step
            let y = rect.maxY - rect.height * CGFloat(min(max(values[index], 0), 1))
            if index == values.startIndex {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

private struct ScopeTraceOverlay: View {
    let title: String
    let traces: [([Double], Color)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.black.opacity(0.52))
            ForEach(Array(traces.enumerated()), id: \.offset) { _, trace in
                HistogramPath(values: trace.0)
                    .stroke(trace.1.opacity(0.82), lineWidth: 1)
                    .padding(6)
            }
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(5)
        }
    }
}

private struct VectorscopeOverlay: View {
    let points: [CGPoint]

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.52))
            Circle()
                .stroke(.white.opacity(0.28), lineWidth: 1)
                .padding(8)
            Path { path in
                path.move(to: CGPoint(x: 46, y: 10))
                path.addLine(to: CGPoint(x: 46, y: 82))
                path.move(to: CGPoint(x: 10, y: 46))
                path.addLine(to: CGPoint(x: 82, y: 46))
            }
            .stroke(.white.opacity(0.22), lineWidth: 1)

            ForEach(Array(points.prefix(180).enumerated()), id: \.offset) { _, point in
                Circle()
                    .fill(.green.opacity(0.55))
                    .frame(width: 2, height: 2)
                    .position(x: 10 + point.x * 72, y: 82 - point.y * 72)
            }
        }
    }
}

private struct FalseColorLegend: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { index in
                Rectangle()
                    .fill(falseColor(for: Double(index) / 23.0))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(.white.opacity(0.35), lineWidth: 1)
        }
    }

    private func falseColor(for value: Double) -> Color {
        switch value {
        case 0..<0.25:
            return .blue
        case 0.25..<0.45:
            return .cyan
        case 0.45..<0.65:
            return .green
        case 0.65..<0.85:
            return .yellow
        default:
            return .red
        }
    }
}

private struct CompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(configuration.isPressed ? 0.24 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(isActive ? Color.blue.opacity(0.82) : Color.white.opacity(configuration.isPressed ? 0.2 : 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct StreamTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(.white.opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct LensButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(isActive ? Color.blue.opacity(0.86) : Color.black.opacity(configuration.isPressed ? 0.65 : 0.46))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(isActive ? 0.55 : 0.16), lineWidth: 1)
            }
    }
}

private struct RecordButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isRecording ? Color.red.opacity(configuration.isPressed ? 0.65 : 0.86) : Color.white.opacity(configuration.isPressed ? 0.24 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct IconPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.24 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
