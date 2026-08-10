import Foundation

final class SRTTransport {
    var onStateChanged: ((SRTConnectionState) -> Void)?
    var onStatistics: ((SRTStatistics) -> Void)?

    private(set) var state: SRTConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }
    private(set) var statistics = SRTStatistics.empty {
        didSet { onStatistics?(statistics) }
    }

    private var configuration = SRTConnectionConfiguration()

    func configure(_ configuration: SRTConnectionConfiguration) {
        self.configuration = configuration
    }

    func connect() {
        state = .waitingForDependency(Self.dependencyMessage)
    }

    func disconnect() {
        state = .disconnected
        statistics = .empty
    }

    func send(_ data: Data, presentationTime: TimeInterval) {
        state = .waitingForDependency(Self.dependencyMessage)
    }

    private static let dependencyMessage = "Real SRT is dependency-gated until libsrt.xcframework and libcrypto.xcframework are linked."
}
