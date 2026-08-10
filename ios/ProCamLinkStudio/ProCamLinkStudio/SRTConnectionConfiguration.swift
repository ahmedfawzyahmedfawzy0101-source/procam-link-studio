import Foundation

enum SRTConnectionMode: String, CaseIterable, Identifiable, Codable {
    case caller = "Caller"
    case listener = "Listener"

    var id: String { rawValue }
}

enum SRTConnectionState: Equatable {
    case disconnected
    case waitingForDependency(String)
    case connecting
    case connected(Date)
    case reconnecting(Int)
    case disconnecting
    case failed(String)
}

struct SRTConnectionConfiguration: Equatable, Codable {
    var mode: SRTConnectionMode = .caller
    var host: String = "127.0.0.1"
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
