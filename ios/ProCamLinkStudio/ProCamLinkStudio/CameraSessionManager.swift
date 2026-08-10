import AVFoundation
import Foundation

@MainActor
final class CameraSessionManager: ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationStatus: AVAuthorizationStatus
    @Published private(set) var activeDeviceID: String?
    @Published private(set) var activeDeviceName: String?
    @Published private(set) var lastError: String?

    private let sessionQueue = DispatchQueue(label: "studio.procamlink.camera.session")
    private var currentInput: AVCaptureDeviceInput?

    init() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
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
            activeDeviceID = device.uniqueID
            activeDeviceName = device.localizedName
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
