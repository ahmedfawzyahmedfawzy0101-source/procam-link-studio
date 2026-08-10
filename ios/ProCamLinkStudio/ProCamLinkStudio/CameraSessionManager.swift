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
    @Published var smartFraming = SmartFramingSettings()
    @Published var stabilizationSettings = StabilizationSettings()
    @Published var performanceBudget = PerformanceBudgetState()
    @Published private(set) var currentPreviewOrientation: PreviewOrientation = .portrait
    @Published private(set) var lensAssist = LensAssistState()
    @Published private(set) var trackingState = TrackingState()
    @Published private(set) var horizonState = HorizonState()
    @Published private(set) var monitoringAnalysis = MonitoringAnalysisState()
    @Published private(set) var nativeStabilization = NativeStabilizationState()
    @Published var selectedRecordingCodec: RecordingCodec = .hevc
    @Published var selectedRecordingMode: RecordingMode = .cleanMaster
    @Published var selectedRecordingQuality: RecordingQualityPreset = .matchCamera
    @Published private(set) var availableRecordingCodecs: [RecordingCodec] = [.h264]
    @Published private(set) var recordingState = RecordingState()
    @Published private(set) var profiles: [CameraProfile] = CameraProfile.builtIns
    @Published private(set) var activeProfileName: String = "Natural"
    @Published private(set) var thermalState = ThermalStateLabel(title: "Nominal", isRisky: false)

    private let sessionQueue = DispatchQueue(label: "studio.procamlink.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "studio.procamlink.camera.video-output")
    private var currentInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleBufferProxy = CameraSampleBufferProxy()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let processedRecorder = ProcessedMasterRecorder()
    private var recordingDelegate: MovieRecordingDelegate?
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?
    private var activeRecordingMode: RecordingMode?
    private let intelligentCamera = IntelligentCameraManager()
    private let monitoringAnalyzer = MonitoringAnalyzer()
    private var activeDevice: AVCaptureDevice?
    private var thermalObserver: NSObjectProtocol?
    private var lastSmartMeteringUpdate = Date.distantPast
    private var lensAssistCandidateID: String?
    private var lensAssistCandidateStartedAt: TimeInterval?

    init() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        loadCustomProfiles()
        updateThermalState()
        intelligentCamera.onSubjectsUpdated = { [weak self] state in
            Task { @MainActor in
                self?.trackingState = state
                self?.applySmartMeteringIfNeeded(state)
            }
        }
        intelligentCamera.onHorizonUpdated = { [weak self] state in
            Task { @MainActor in self?.horizonState = state }
        }
        intelligentCamera.onPerformanceUpdated = { [weak self] state in
            Task { @MainActor in self?.performanceBudget = state }
        }
        monitoringAnalyzer.onAnalysisUpdated = { [weak self] state in
            Task { @MainActor in self?.monitoringAnalysis = state }
        }
        processedRecorder.onStats = { [weak self] stats in
            Task { @MainActor in
                self?.recordingState.encodedFrames = stats.encodedFrames
                self?.recordingState.droppedFrames = stats.droppedFrames
                self?.recordingState.outputResolution = "\(stats.outputWidth)x\(stats.outputHeight)"
            }
        }
        processedRecorder.onFinish = { [weak self] outputURL, error in
            Task { @MainActor in
                self?.finishRecording(url: outputURL, error: error)
            }
        }
        intelligentCamera.startMotion()
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
        intelligentCamera.stopMotion()
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

        let videoOutput = videoOutput
        let movieOutput = movieOutput
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

                    if !session.outputs.contains(videoOutput) {
                        videoOutput.alwaysDiscardsLateVideoFrames = true
                        videoOutput.videoSettings = [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                        ]
                        if session.canAddOutput(videoOutput) {
                            session.addOutput(videoOutput)
                        }
                    }

                    if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                        session.addOutput(movieOutput)
                    }
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

    func setFrameConsumer(_ consumer: CameraFrameConsumer?) {
        sampleBufferProxy.previewConsumer = consumer
        sampleBufferProxy.analysisHandler = { [weak self] pixelBuffer, timestamp in
            guard let self else { return }
            self.intelligentCamera.analyze(pixelBuffer: pixelBuffer, timestamp: timestamp)
            self.monitoringAnalyzer.analyze(pixelBuffer: pixelBuffer)
            if self.activeRecordingMode == .processedMaster {
                self.processedRecorder.append(
                    pixelBuffer: pixelBuffer,
                    timestamp: timestamp,
                    state: self.currentFrameProcessingState(includeMonitoring: false)
                )
            }
        }
        videoOutput.setSampleBufferDelegate(sampleBufferProxy, queue: videoOutputQueue)
    }

    func selectTrackedSubject(at normalizedPoint: CGPoint) {
        intelligentCamera.selectSubject(at: normalizedPoint)
    }

    func updateSmartFraming(_ settings: SmartFramingSettings) {
        smartFraming = settings
    }

    func setTrackingMode(_ mode: TrackingMode) {
        intelligentCamera.setTrackingMode(mode)
    }

    func updateStabilizationSettings(_ settings: StabilizationSettings) {
        stabilizationSettings = settings
    }

    func setAutoLensEnabled(_ enabled: Bool) {
        lensAssist.isAutoLensEnabled = enabled
        lensAssist.pendingSwitchLabel = nil
        lensAssistCandidateID = nil
        lensAssistCandidateStartedAt = nil
    }

    func evaluateLensAssist(devices: [CameraDevice]) -> String? {
        guard let recommendation = lensRecommendation(from: devices) else { return nil }
        lensAssist.recommendedDeviceID = recommendation.device.uniqueID
        lensAssist.recommendedLabel = recommendation.label
        lensAssist.reason = recommendation.reason

        guard lensAssist.isAutoLensEnabled, recommendation.device.uniqueID != activeDeviceID else {
            lensAssist.pendingSwitchLabel = nil
            return nil
        }

        let now = Date().timeIntervalSince1970
        guard now - lensAssist.lastSwitchTime > 3.0 else { return nil }
        if lensAssistCandidateID != recommendation.device.uniqueID {
            lensAssistCandidateID = recommendation.device.uniqueID
            lensAssistCandidateStartedAt = now
            lensAssist.pendingSwitchLabel = recommendation.label
            return nil
        }

        guard let started = lensAssistCandidateStartedAt, now - started > 1.2 else { return nil }
        lensAssist.lastSwitchTime = now
        lensAssist.pendingSwitchLabel = nil
        return recommendation.device.uniqueID
    }

    func applyStabilizationPreset(_ preset: StabilizationPreset) {
        var next = stabilizationSettings
        switch preset {
        case .tripod:
            next.horizonMode = .levelAssist
            next.digitalMode = .off
            next.strength = 0.2
            next.cropSafetyMargin = 0.02
            setBestNativeStabilization([.off, .standard])
        case .handheld:
            next.horizonMode = .levelAssist
            next.digitalMode = .low
            next.strength = 0.45
            next.cropSafetyMargin = 0.06
            setBestNativeStabilization([.standard, .auto])
        case .walking:
            next.horizonMode = .horizonLock
            next.digitalMode = .medium
            next.strength = 0.68
            next.cropSafetyMargin = 0.1
            setBestNativeStabilization([.cinematic, .standard, .auto])
        case .running:
            next.horizonMode = .horizonLock
            next.digitalMode = .strong
            next.strength = 0.86
            next.cropSafetyMargin = 0.16
            setBestNativeStabilization([.cinematicExtended, .cinematic, .auto])
        case .followCam:
            next.horizonMode = .horizonLock
            next.digitalMode = .medium
            next.strength = 0.6
            next.cropSafetyMargin = 0.1
            setBestNativeStabilization([.cinematic, .standard, .auto])
        }
        stabilizationSettings = next
    }

    func setNativeStabilization(_ mode: NativeStabilizationMode) {
        guard nativeStabilization.availableModes.contains(mode) else { return }
        nativeStabilization.selectedMode = mode
        applyNativeStabilization(mode)
    }

    func updateImageAdjustments(_ adjustments: ImageAdjustmentState) {
        imageAdjustments = adjustments
    }

    func resetImageAdjustments() {
        imageAdjustments = .neutral
    }

    func applyProfile(_ profile: CameraProfile) {
        activeProfileName = profile.name
        imageAdjustments = profile.imageAdjustments
        applyFormatGoal(profile.formatGoal)
    }

    func saveCustomProfile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let profile = CameraProfile(
            id: UUID(),
            name: "Custom \(formatter.string(from: Date()))",
            formatGoal: .current,
            imageAdjustments: imageAdjustments,
            isBuiltIn: false
        )
        profiles.append(profile)
        persistCustomProfiles()
    }

    func deleteCustomProfile(_ profile: CameraProfile) {
        guard !profile.isBuiltIn else { return }
        profiles.removeAll { $0.id == profile.id }
        persistCustomProfiles()
    }

    func setRecordingCodec(_ codec: RecordingCodec) {
        guard availableRecordingCodecs.contains(codec) else { return }
        selectedRecordingCodec = codec
    }

    func setRecordingMode(_ mode: RecordingMode) {
        guard !recordingState.isRecording else { return }
        selectedRecordingMode = mode
    }

    func setRecordingQuality(_ quality: RecordingQualityPreset) {
        guard !recordingState.isRecording else { return }
        selectedRecordingQuality = quality
    }

    func toggleRecording() {
        recordingState.isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !recordingState.isRecording else { return }
        guard !movieOutput.isRecording else { return }
        guard refreshStorageWarning() == nil else { return }

        if selectedRecordingMode == .processedMaster {
            startProcessedRecording()
            return
        }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let filename = "ProCamLinkStudio-\(Self.recordingTimestamp()).mov"
        let url = directory.appendingPathComponent(filename)
        let codec = selectedRecordingCodec

        if let connection = movieOutput.connection(with: .video),
           movieOutput.availableVideoCodecTypes.contains(codec.avCodec) {
            movieOutput.setOutputSettings([AVVideoCodecKey: codec.avCodec], for: connection)
        }

        let delegate = MovieRecordingDelegate { [weak self] outputURL, error in
            Task { @MainActor in
                self?.finishRecording(url: outputURL, error: error)
            }
        }
        recordingDelegate = delegate
        recordingStartedAt = Date()
        activeRecordingMode = .cleanMaster
        recordingState.isRecording = true
        recordingState.elapsedSeconds = 0
        recordingState.lastRecordingPath = nil
        recordingState.droppedFrames = 0
        recordingState.encodedFrames = 0
        recordingState.outputResolution = nil
        recordingState.syncStatus = "Clean camera file output"
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
        startRecordingTimer()
    }

    func stopRecording() {
        if activeRecordingMode == .processedMaster {
            processedRecorder.stop()
            return
        }
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    func setPreviewFillMode(_ mode: PreviewFillMode) {
        previewFillMode = mode
    }

    func updatePreviewOrientation(_ orientation: PreviewOrientation) {
        currentPreviewOrientation = orientation
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

    func smartFocusAndExpose(on subject: DetectedSubject) {
        guard exposureState.mode != .manual, focusState.mode != .manual else { return }
        let point = CGPoint(x: subject.normalizedRect.midX, y: subject.normalizedRect.midY)
        focusAndExpose(at: point)
    }

    private func applySmartMeteringIfNeeded(_ state: TrackingState) {
        guard Date().timeIntervalSince(lastSmartMeteringUpdate) > 0.45 else { return }
        guard let subject = state.subjects.first(where: { $0.id == state.selectedSubjectID }) else { return }
        guard subject.confidence > 0.45 else { return }
        lastSmartMeteringUpdate = Date()
        smartFocusAndExpose(on: subject)
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

        refreshNativeStabilization(for: activeFormat)

        let codecs = RecordingCodec.allCases.filter { movieOutput.availableVideoCodecTypes.contains($0.avCodec) }
        availableRecordingCodecs = codecs.isEmpty ? [.h264] : codecs
        if !availableRecordingCodecs.contains(selectedRecordingCodec) {
            selectedRecordingCodec = availableRecordingCodecs[0]
        }
        _ = refreshStorageWarning()
    }

    private func refreshNativeStabilization(for format: AVCaptureDevice.Format) {
        let supported = NativeStabilizationMode.allCases.filter { mode in
            mode == .off || format.isVideoStabilizationModeSupported(mode.avMode)
        }
        nativeStabilization.availableModes = supported.isEmpty ? [.off] : supported
        if !nativeStabilization.availableModes.contains(nativeStabilization.selectedMode) {
            nativeStabilization.selectedMode = .off
            nativeStabilization.warning = "Format changed; stabilization reset"
        } else {
            nativeStabilization.warning = nil
        }
        applyNativeStabilization(nativeStabilization.selectedMode)
    }

    private func applyNativeStabilization(_ mode: NativeStabilizationMode) {
        let videoConnection = videoOutput.connection(with: .video)
        let movieConnection = movieOutput.connection(with: .video)
        [videoConnection, movieConnection].forEach { connection in
            guard let connection, connection.isVideoStabilizationSupported else { return }
            connection.preferredVideoStabilizationMode = mode.avMode
        }

        nativeStabilization.activeMode = NativeStabilizationMode.from(videoConnection?.activeVideoStabilizationMode ?? .off)
        nativeStabilization.cropEstimate = estimatedCrop(for: nativeStabilization.activeMode)
    }

    private func estimatedCrop(for mode: NativeStabilizationMode) -> Double {
        switch mode {
        case .off:
            return 0
        case .standard:
            return 4
        case .cinematic:
            return 8
        case .cinematicExtended:
            return 12
        case .auto:
            return 6
        }
    }

    private func setBestNativeStabilization(_ preferred: [NativeStabilizationMode]) {
        if let mode = preferred.first(where: { nativeStabilization.availableModes.contains($0) }) {
            setNativeStabilization(mode)
        }
    }

    private func lensRecommendation(from devices: [CameraDevice]) -> (device: AVCaptureDevice, label: String, reason: String)? {
        guard !devices.isEmpty else { return nil }
        let subjectSize = trackingState.lastSelectedRect.map { max($0.width, $0.height) } ?? 0.28
        let wantsWide = smartFraming.mode == .group || subjectSize > 0.62 || zoomFactor < 0.9
        let wantsTele = subjectSize < 0.22 && zoomFactor > 1.4 && smartFraming.mode != .group

        if wantsWide, let ultra = devices.first(where: { $0.device.deviceType == .builtInUltraWideCamera }) {
            return (ultra.device, "Ultra Wide", "Group/large subject needs wider optical FOV")
        }

        if wantsTele, let tele = devices.first(where: { $0.device.deviceType == .builtInTelephotoCamera }) {
            return (tele.device, "Telephoto", "Small subject with digital zoom pressure")
        }

        if let wide = devices.first(where: { $0.device.deviceType == .builtInWideAngleCamera && $0.device.position == .back }) {
            return (wide.device, "Wide", "Balanced framing with optical wide lens")
        }

        return devices.first.map { ($0.device, $0.displayName, "Only available optical camera") }
    }

    private func applyFormatGoal(_ goal: CameraProfile.FormatGoal) {
        guard !formats.isEmpty else { return }

        let match: CameraFormatOption?
        switch goal {
        case .maxQuality:
            match = formats.max { $0.sortScore < $1.sortScore }
        case .fourK30:
            match = formats.first { max($0.width, $0.height) >= 3840 && $0.maxFPS >= 30 }
        case .fourK60:
            match = formats.first { max($0.width, $0.height) >= 3840 && $0.maxFPS >= 60 }
        case .fullHD60:
            match = formats.first { max($0.width, $0.height) == 1920 && $0.maxFPS >= 60 }
        case .lowLight:
            match = formats
                .filter { $0.maxFPS >= 24 && $0.maxFPS <= 30 }
                .max { $0.sortScore < $1.sortScore }
        case .current:
            match = nil
        }

        if let match {
            let fps = goal == .fourK60 || goal == .fullHD60 ? min(match.maxFPS, 60) : min(match.maxFPS, 30)
            apply(format: match, fps: fps)
        }
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

    private func startProcessedRecording() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let filename = "ProCamLinkStudio-Processed-\(Self.recordingTimestamp()).mov"
        let url = directory.appendingPathComponent(filename)
        let source = activeSourceDimensions()
        recordingStartedAt = Date()
        activeRecordingMode = .processedMaster
        recordingState.isRecording = true
        recordingState.elapsedSeconds = 0
        recordingState.lastRecordingPath = nil
        recordingState.droppedFrames = 0
        recordingState.encodedFrames = 0
        recordingState.outputResolution = nil
        recordingState.syncStatus = "Processed frames encoded from capture timestamps"
        processedRecorder.start(
            url: url,
            codec: selectedRecordingCodec,
            quality: selectedRecordingQuality,
            sourceWidth: source.width,
            sourceHeight: source.height
        )
        startRecordingTimer()
    }

    private func activeSourceDimensions() -> (width: Int, height: Int) {
        guard let activeDevice else { return (1920, 1080) }
        let dimensions = CMVideoFormatDescriptionGetDimensions(activeDevice.activeFormat.formatDescription)
        return (Int(dimensions.width), Int(dimensions.height))
    }

    private func currentFrameProcessingState(includeMonitoring: Bool) -> FrameProcessingState {
        FrameProcessingState(
            orientation: currentPreviewOrientation,
            adjustments: imageAdjustments,
            framing: smartFraming,
            tracking: trackingState,
            horizon: horizonState,
            stabilization: stabilizationSettings,
            monitoring: monitoringState,
            includeMonitoring: includeMonitoring
        )
    }

    private func finishRecording(url: URL?, error: Error?) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingState.isRecording = false
        recordingState.elapsedSeconds = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        activeRecordingMode = nil

        if let error {
            lastError = error.localizedDescription
            recordingState.syncStatus = "Recording failed"
        } else {
            recordingState.lastRecordingPath = url?.path
            recordingState.syncStatus = "Saved"
            lastError = nil
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recordingStartedAt = self.recordingStartedAt else { return }
                self.recordingState.elapsedSeconds = Date().timeIntervalSince(recordingStartedAt)
                _ = self.refreshStorageWarning()
            }
        }
    }

    private func refreshStorageWarning() -> String? {
        do {
            let values = try FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            if available < 1_000_000_000 {
                recordingState.storageWarning = "Low storage"
            } else {
                recordingState.storageWarning = nil
            }
        } catch {
            recordingState.storageWarning = nil
        }
        return recordingState.storageWarning
    }

    private static func recordingTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func loadCustomProfiles() {
        guard let data = UserDefaults.standard.data(forKey: "customCameraProfiles") else {
            profiles = CameraProfile.builtIns
            return
        }

        let custom = (try? JSONDecoder().decode([CameraProfile].self, from: data)) ?? []
        profiles = CameraProfile.builtIns + custom.filter { !$0.isBuiltIn }
    }

    private func persistCustomProfiles() {
        let custom = profiles.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: "customCameraProfiles")
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

private final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let finishHandler: (URL?, Error?) -> Void

    init(finishHandler: @escaping (URL?, Error?) -> Void) {
        self.finishHandler = finishHandler
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        finishHandler(outputFileURL, error)
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
