import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class CameraSessionManager: ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationStatus: AVAuthorizationStatus
    @Published private(set) var activeDeviceID: String?
    @Published private(set) var activeDeviceName: String?
    @Published private(set) var lastError: String?
    @Published private(set) var capabilities: CameraCapabilities = .empty
    @Published private(set) var formats: [CameraFormatOption] = []
    @Published private(set) var selectedFormatID: String?
    @Published var previewFillMode: PreviewFillMode = .fill
    @Published var zoomFactor: CGFloat = 1
    @Published var torchLevel: Float = 1
    @Published var exposureState = ExposureState()
    @Published var focusState = FocusState()
    @Published var whiteBalanceState = WhiteBalanceState()
    @Published var monitoringState = MonitoringState()
    @Published var imageAdjustments = ImageAdjustmentState.neutral
    @Published private(set) var thermalState = ThermalStateLabel(title: "Nominal", isRisky: false)

    private let sessionQueue = DispatchQueue(label: "studio.procamlink.camera.session")
    private var currentInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
    private var thermalObserver: NSObjectProtocol?

    init() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        updateThermalState()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateThermalState() }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestCameraAccess() async {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        authorizationStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
    }

    func configure(device: AVCaptureDevice) async {
        guard authorizationStatus == .authorized else {
            return
        }

        let result = await withCheckedContinuation { continuation in
            sessionQueue.async { [session, currentInput] in
                do {
                    let input = try AVCaptureDeviceInput(device: device)

                    session.beginConfiguration()
                    session.sessionPreset = .high

                    if let currentInput {
                        session.removeInput(currentInput)
                    }

                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        continuation.resume(returning: Result<AVCaptureDeviceInput, Error>.failure(CameraSessionError.unsupportedInput))
                        return
                    }

                    session.addInput(input)
                    session.commitConfiguration()

                    if !session.isRunning {
                        session.startRunning()
                    }

                    continuation.resume(returning: .success(input))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }

        switch result {
        case .success(let input):
            currentInput = input
            activeDevice = device
            activeDeviceID = device.uniqueID
            activeDeviceName = device.localizedName
            refreshState(for: device)
            lastError = nil
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func setPreviewFillMode(_ mode: PreviewFillMode) {
        previewFillMode = mode
    }

    func setZoom(_ factor: CGFloat, ramp: Bool = true) {
        guard let device = activeDevice else { return }
        let clamped = min(max(factor, capabilities.minZoom), capabilities.maxZoom)
        zoomFactor = clamped

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if ramp, device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                if ramp {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 8)
                } else {
                    device.videoZoomFactor = clamped
                }
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func toggleTorch() {
        guard capabilities.hasTorch else { return }
        let enabled = activeDevice?.torchMode == .on
        setTorch(enabled: !enabled, level: torchLevel)
    }

    func setTorch(enabled: Bool, level: Float) {
        guard let device = activeDevice, device.hasTorch else { return }
        let clampedLevel = min(max(level, 0.01), 1)
        torchLevel = clampedLevel

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if enabled {
                    try device.setTorchModeOn(level: clampedLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func setExposureMode(_ mode: ExposureControlMode) {
        guard let device = activeDevice else { return }
        exposureState.mode = mode
        let shutterSeconds = exposureState.shutterSeconds
        let iso = exposureState.iso

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                switch mode {
                case .continuousAuto:
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                case .locked:
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                case .manual:
                    if device.isExposureModeSupported(.custom) {
                        let duration = CMTime(seconds: shutterSeconds, preferredTimescale: 1_000_000_000)
                        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                    }
                }
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func setManualExposure(iso: Float? = nil, shutterSeconds: Double? = nil) {
        guard let device = activeDevice, capabilities.supportsManualExposure else { return }
        let nextISO = min(max(iso ?? exposureState.iso, capabilities.minISO), capabilities.maxISO)
        let nextShutter = min(max(shutterSeconds ?? exposureState.shutterSeconds, capabilities.minExposureSeconds), capabilities.maxExposureSeconds)
        exposureState.iso = nextISO
        exposureState.shutterSeconds = nextShutter
        exposureState.mode = .manual

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let duration = CMTime(seconds: nextShutter, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(duration: duration, iso: nextISO, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func setExposureBias(_ bias: Float) {
        guard let device = activeDevice, capabilities.supportsExposureBias else { return }
        let clamped = min(max(bias, capabilities.minExposureBias), capabilities.maxExposureBias)
        exposureState.exposureBias = clamped

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func setFocusMode(_ mode: FocusControlMode) {
        guard let device = activeDevice else { return }
        focusState.mode = mode
        let lensPosition = focusState.lensPosition

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                switch mode {
                case .continuousAuto:
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                case .locked:
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                case .manual:
                    if device.isFocusModeSupported(.locked) {
                        device.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
                    }
                }
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func setManualFocus(_ lensPosition: Float) {
        guard let device = activeDevice, capabilities.supportsManualFocus else { return }
        let clamped = min(max(lensPosition, 0), 1)
        focusState.lensPosition = clamped
        focusState.mode = .manual

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func focusAndExpose(at previewPoint: CGPoint) {
        guard let device = activeDevice else { return }
        focusState.focusPoint = previewPoint

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = previewPoint
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = previewPoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func setWhiteBalanceMode(_ mode: WhiteBalanceControlMode) {
        guard let device = activeDevice else { return }
        whiteBalanceState.mode = mode
        let temperature = whiteBalanceState.temperature
        let tint = whiteBalanceState.tint

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                switch mode {
                case .continuousAuto:
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                case .locked:
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.whiteBalanceMode = .locked
                    }
                case .manual:
                    if device.isWhiteBalanceModeSupported(.locked) {
                        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                            temperature: temperature,
                            tint: tint
                        )
                        let gains = device.deviceWhiteBalanceGains(for: values).normalized(for: device)
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    }
                }
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func setManualWhiteBalance(temperature: Float? = nil, tint: Float? = nil) {
        guard let device = activeDevice, capabilities.supportsManualWhiteBalance else { return }
        let clampedTemperature = min(max(temperature ?? whiteBalanceState.temperature, 2_000), 10_000)
        let clampedTint = min(max(tint ?? whiteBalanceState.tint, -150), 150)
        whiteBalanceState.temperature = clampedTemperature
        whiteBalanceState.tint = clampedTint
        whiteBalanceState.mode = .manual

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: clampedTemperature,
                    tint: clampedTint
                )
                let gains = device.deviceWhiteBalanceGains(for: values).normalized(for: device)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    func apply(format option: CameraFormatOption, fps: Double) {
        guard let device = activeDevice else { return }
        selectedFormatID = option.id
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps.rounded()))))

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.activeFormat = option.format
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                device.unlockForConfiguration()
                Task { @MainActor in self.refreshState(for: device) }
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    private func refreshState(for device: AVCaptureDevice) {
        let activeFormat = device.activeFormat
        formats = device.formats.enumerated()
            .map { CameraFormatOption.make(format: $0.element, index: $0.offset) }
            .filter { option in
                let longEdge = max(option.width, option.height)
                let allowedResolution = longEdge == 1280 || longEdge == 1920 || longEdge >= 3840
                let allowedFPS = option.maxFPS >= 24
                return allowedResolution && allowedFPS
            }
            .sorted { $0.sortScore > $1.sortScore }

        selectedFormatID = formats.first { $0.format === activeFormat }?.id
        zoomFactor = device.videoZoomFactor
        exposureState.iso = device.iso
        exposureState.shutterSeconds = CMTimeGetSeconds(device.exposureDuration)
        exposureState.exposureBias = device.exposureTargetBias
        focusState.lensPosition = device.lensPosition

        let wbValues = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        whiteBalanceState.temperature = wbValues.temperature
        whiteBalanceState.tint = wbValues.tint

        capabilities = CameraCapabilities(
            minZoom: 1,
            maxZoom: max(1, device.activeFormat.videoMaxZoomFactor),
            neutralZoom: 1,
            hasTorch: device.hasTorch,
            supportsVariableTorch: device.hasTorch,
            supportsTapFocus: device.isFocusPointOfInterestSupported,
            supportsManualFocus: device.isLockingFocusWithCustomLensPositionSupported,
            supportsExposurePoint: device.isExposurePointOfInterestSupported,
            supportsManualExposure: device.isExposureModeSupported(.custom),
            supportsExposureBias: device.minExposureTargetBias != device.maxExposureTargetBias,
            supportsWhiteBalanceLock: device.isWhiteBalanceModeSupported(.locked),
            supportsManualWhiteBalance: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            minISO: activeFormat.minISO,
            maxISO: activeFormat.maxISO,
            minExposureSeconds: CMTimeGetSeconds(activeFormat.minExposureDuration),
            maxExposureSeconds: CMTimeGetSeconds(activeFormat.maxExposureDuration),
            minExposureBias: device.minExposureTargetBias,
            maxExposureBias: device.maxExposureTargetBias,
            supportsHDR: device.formats.contains { $0.isVideoHDRSupported }
        )
    }

    private func updateThermalState() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            thermalState = ThermalStateLabel(title: "Nominal", isRisky: false)
        case .fair:
            thermalState = ThermalStateLabel(title: "Fair", isRisky: false)
        case .serious:
            thermalState = ThermalStateLabel(title: "Serious", isRisky: true)
        case .critical:
            thermalState = ThermalStateLabel(title: "Critical", isRisky: true)
        @unknown default:
            thermalState = ThermalStateLabel(title: "Unknown", isRisky: true)
        }
    }
}

enum CameraSessionError: LocalizedError {
    case unsupportedInput

    var errorDescription: String? {
        switch self {
        case .unsupportedInput:
            return "This camera cannot be added to the current capture session."
        }
    }
}

private extension AVCaptureDevice.WhiteBalanceGains {
    func normalized(for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(redGain, 1), maxGain),
            greenGain: min(max(greenGain, 1), maxGain),
            blueGain: min(max(blueGain, 1), maxGain)
        )
    }
}
