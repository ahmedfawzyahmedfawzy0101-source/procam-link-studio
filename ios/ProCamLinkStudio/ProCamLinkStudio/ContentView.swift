import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var cameraSession = CameraSessionManager()
    @StateObject private var deviceManager = CameraDeviceManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch cameraSession.authorizationStatus {
            case .authorized:
                CameraPreviewView(session: cameraSession.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        topBar
                    }
                    .overlay(alignment: .bottom) {
                        cameraPicker
                    }
                    .task {
                        await configureFirstAvailableCamera()
                    }

            case .notDetermined:
                VStack(spacing: 16) {
                    Text("ProCam Link Studio")
                        .font(.title.bold())
                    Button("Allow Camera Access") {
                        Task { await cameraSession.requestCameraAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding()

            default:
                VStack(spacing: 12) {
                    Text("Camera access is required")
                        .font(.title2.bold())
                    Text("Enable camera permission in Settings to use the iPhone preview.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding()
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

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("ProCam Link Studio")
                    .font(.headline)
                Text(cameraSession.activeDeviceName ?? "No camera selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.45))
    }

    private var cameraPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(deviceManager.devices) { camera in
                    Button {
                        Task { await cameraSession.configure(device: camera.device) }
                    } label: {
                        Text(camera.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(camera.device.uniqueID == cameraSession.activeDeviceID ? .blue : .gray)
                }
            }
            .padding()
        }
        .background(.black.opacity(0.45))
    }

    private func configureFirstAvailableCamera() async {
        guard cameraSession.activeDeviceID == nil, let firstDevice = deviceManager.devices.first?.device else {
            return
        }
        await cameraSession.configure(device: firstDevice)
    }
}
