import AVFoundation
import Foundation

struct CameraDevice: Identifiable {
    let device: AVCaptureDevice

    var id: String { device.uniqueID }

    var displayName: String {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return "Ultra Wide"
        case .builtInWideAngleCamera:
            return device.position == .front ? "Front Wide" : "Wide"
        case .builtInTelephotoCamera:
            return "Telephoto"
        case .builtInDualCamera:
            return "Dual"
        case .builtInDualWideCamera:
            return "Dual Wide"
        case .builtInTripleCamera:
            return "Triple"
        case .builtInTrueDepthCamera:
            return "TrueDepth"
        default:
            return device.localizedName
        }
    }
}

@MainActor
final class CameraDeviceManager: ObservableObject {
    @Published private(set) var devices: [CameraDevice] = []

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera,
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        devices = discovery.devices
            .sorted { lhs, rhs in
                sortKey(for: lhs) < sortKey(for: rhs)
            }
            .map(CameraDevice.init(device:))
    }

    private func sortKey(for device: AVCaptureDevice) -> String {
        "\(positionRank(device.position))-\(typeRank(device.deviceType))-\(device.localizedName)"
    }

    private func positionRank(_ position: AVCaptureDevice.Position) -> Int {
        switch position {
        case .back:
            return 0
        case .front:
            return 1
        default:
            return 2
        }
    }

    private func typeRank(_ type: AVCaptureDevice.DeviceType) -> Int {
        switch type {
        case .builtInUltraWideCamera:
            return 0
        case .builtInWideAngleCamera:
            return 1
        case .builtInTelephotoCamera:
            return 2
        case .builtInTripleCamera:
            return 3
        case .builtInDualWideCamera:
            return 4
        case .builtInDualCamera:
            return 5
        case .builtInTrueDepthCamera:
            return 6
        default:
            return 99
        }
    }
}
