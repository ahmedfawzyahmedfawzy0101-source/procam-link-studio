import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var cameraSession = CameraSessionManager()
    @StateObject private var deviceManager = CameraDeviceManager()

    @State private var selectedPanel: StudioPanel = .camera
    @State private var basePinchZoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch cameraSession.authorizationStatus {
            case .authorized:
                GeometryReader { geometry in
                    ZStack {
                        ProcessedCameraPreviewView(
                            cameraSession: cameraSession,
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
                            geometry: geometry
                        )

                        VStack(spacing: 0) {
                            TopTelemetryBar(cameraSession: cameraSession)
                            Spacer()
                            LensStrip(
                                devices: deviceManager.devices,
                                activeDeviceID: cameraSession.activeDeviceID,
                                select: { device in
                                    Task { await cameraSession.configure(device: device) }
                                }
                            )
                            ControlDock(
                                selectedPanel: $selectedPanel,
                                cameraSession: cameraSession
                            )
                        }
                    }
                }
                .task {
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
        .onAppear {
            deviceManager.refreshDevices()
            cameraSession.refreshAuthorizationStatus()
        }
        .onDisappear {
            cameraSession.stop()
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

            Button(cameraSession.recordingState.isRecording ? "Stop" : "Rec") {
                cameraSession.toggleRecording()
            }
            .buttonStyle(RecordButtonStyle(isRecording: cameraSession.recordingState.isRecording))
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
        .background(.black.opacity(0.34))
    }
}

private struct ControlDock: View {
    @Binding var selectedPanel: StudioPanel
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(StudioPanel.allCases) { panel in
                    Button(panel.rawValue) {
                        selectedPanel = panel
                    }
                    .buttonStyle(SegmentButtonStyle(isActive: selectedPanel == panel))
                }
            }

            switch selectedPanel {
            case .camera:
                CameraControlPanel(cameraSession: cameraSession)
            case .video:
                VideoControlPanel(cameraSession: cameraSession)
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
                Badge(title: "Rec", value: cameraSession.selectedRecordingCodec.rawValue)
                Badge(title: "Timer", value: recordingTime)
            }

            HStack(spacing: 8) {
                ForEach(cameraSession.availableRecordingCodecs) { codec in
                    Button(codec.rawValue) {
                        cameraSession.setRecordingCodec(codec)
                    }
                    .buttonStyle(SegmentButtonStyle(isActive: cameraSession.selectedRecordingCodec == codec))
                }
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
        }
    }

    private var recordingTime: String {
        let seconds = Int(cameraSession.recordingState.elapsedSeconds.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
            SliderRow(title: "Tight", value: smartBinding(\.tightness), range: 0.2...1, display: String(format: "%.2f", cameraSession.smartFraming.tightness))

            HStack {
                Badge(title: "Subjects", value: "\(cameraSession.trackingState.subjects.count)")
                Badge(title: "Confidence", value: "\(Int(cameraSession.trackingState.selectedConfidence * 100))%")
                Badge(title: "Horizon", value: cameraSession.horizonState.isAvailable ? String(format: "%+.1f deg", cameraSession.horizonState.rollDegrees) : "Unavailable")
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
}

private struct MonitoringControlPanel: View {
    @ObservedObject var cameraSession: CameraSessionManager

    var body: some View {
        VStack(spacing: 8) {
            ToggleRow(title: "Grid", isOn: $cameraSession.monitoringState.grid)
            ToggleRow(title: "Center", isOn: $cameraSession.monitoringState.centerMarker)
            ToggleRow(title: "Thermal", isOn: $cameraSession.monitoringState.showThermal)
        }
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
