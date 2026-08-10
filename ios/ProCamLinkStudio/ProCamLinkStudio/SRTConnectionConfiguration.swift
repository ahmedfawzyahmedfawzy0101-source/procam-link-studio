import Foundation
import Combine
import Network

enum SRTConnectionMode: String, CaseIterable, Identifiable, Codable {
    case caller = "Caller"
    case listener = "Listener"

    var id: String { rawValue }
}

enum SRTConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(Date)
    case reconnecting(Int)
    case disconnecting
    case failed(String)
}

struct SRTConnectionConfiguration: Equatable, Codable {
    var mode: SRTConnectionMode = .caller
    var host: String = "192.168.1.7"
    var port: UInt16 = 9000
    var latencyMS: Int = 120
    var passphrase: String = ""
    var streamID: String = "procamlink/studio"
    var connectTimeoutMS: Int = 3000
    var reconnectEnabled: Bool = true
    var reconnectDelayMS: Int = 800
    var maxReconnectAttempts: Int = 0

    var endpointLabel: String {
        "\(host):\(port)"
    }
}

struct DiscoveredReceiver: Equatable {
    var host: String
    var port: UInt16
    var name: String
    var seenAt: Date

    var endpointLabel: String {
        "\(host):\(port)"
    }
}

final class ReceiverDiscoveryManager: ObservableObject {
    @Published private(set) var receiver: DiscoveredReceiver?
    @Published private(set) var status: String = "Discovery idle"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "studio.procamlink.discovery")
    private let discoveryPort: NWEndpoint.Port = 47777

    func start() {
        guard listener == nil else { return }
        do {
            let nextListener = try NWListener(using: .udp, on: discoveryPort)
            nextListener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .global())
                self?.receive(on: connection)
            }
            nextListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.status = "Searching for Windows receiver"
                    case .failed(let error):
                        self?.status = "Discovery failed: \(error.localizedDescription)"
                    case .cancelled:
                        self?.status = "Discovery stopped"
                    default:
                        break
                    }
                }
            }
            listener = nextListener
            nextListener.start(queue: queue)
        } catch {
            status = "Discovery unavailable: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, let payload = String(data: data, encoding: .utf8),
               var receiver = Self.parse(payload) {
                if case .hostPort(let host, _) = connection.endpoint {
                    let senderHost = String(describing: host)
                    if senderHost.contains(".") && senderHost != "255.255.255.255" {
                        receiver.host = senderHost
                    }
                }
                DispatchQueue.main.async {
                    self?.receiver = receiver
                    self?.status = "Found \(receiver.endpointLabel)"
                }
            }
            if error == nil {
                self?.receive(on: connection)
            }
        }
    }

    private static func parse(_ payload: String) -> DiscoveredReceiver? {
        guard payload.hasPrefix("PROCAMLINK_STUDIO") else { return nil }
        var values: [String: String] = [:]
        for part in payload.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                values[pair[0]] = pair[1]
            }
        }
        guard let host = values["host"], let portText = values["port"], let port = UInt16(portText) else {
            return nil
        }
        return DiscoveredReceiver(
            host: host,
            port: port,
            name: values["name"] ?? "ProCam Link Studio",
            seenAt: Date()
        )
    }
}
