import Foundation

final class SRTTransport {
    var onStateChanged: ((SRTConnectionState) -> Void)?
    var onStatistics: ((SRTStatistics) -> Void)?

    private let queue = DispatchQueue(label: "studio.procamlink.srt.transport")
    private let maxQueuedPackets = 240
    private var sendQueue: [(data: Data, presentationTime: TimeInterval)] = []
    private var isSending = false
    private var droppedQueuePackets = 0
    private var handle: OpaquePointer?
    private(set) var state: SRTConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }
    private(set) var statistics = SRTStatistics.empty {
        didSet { onStatistics?(statistics) }
    }

    private var configuration = SRTConnectionConfiguration()

    init() {
        if ProCamSRTStartup() != 0 {
            state = .failed("libsrt startup failed")
        }
    }

    deinit {
        disconnect()
        ProCamSRTCleanup()
    }

    func configure(_ configuration: SRTConnectionConfiguration) {
        queue.async {
            self.configuration = configuration
        }
    }

    func connect() {
        queue.async {
            self.connectLocked(attempt: 0)
        }
    }

    func disconnect() {
        queue.sync {
            if let handle = self.handle {
                ProCamSRTDisconnect(handle)
            }
            self.handle = nil
            self.sendQueue.removeAll()
            self.isSending = false
            self.updateState(.disconnected)
            self.updateStatistics(.empty)
        }
    }

    func send(_ data: Data, presentationTime: TimeInterval) {
        queue.async {
            guard self.handle != nil else { return }
            if self.sendQueue.count >= self.maxQueuedPackets {
                self.sendQueue.removeFirst()
                self.droppedQueuePackets += 1
            }
            self.sendQueue.append((data, presentationTime))
            self.drainSendQueueLocked()
        }
    }

    private func connectLocked(attempt: Int) {
        updateState(attempt == 0 ? .connecting : .reconnecting(attempt))
        var error = [CChar](repeating: 0, count: 512)
        let host = configuration.host
        let passphrase = configuration.passphrase
        let streamID = configuration.streamID

        let connectedHandle: OpaquePointer? = host.withCString { hostPointer in
            passphrase.withCString { passphrasePointer in
                streamID.withCString { streamIDPointer in
                    var cConfig = ProCamSRTConfig(
                        mode: configuration.mode == .listener ? 1 : 0,
                        host: hostPointer,
                        port: configuration.port,
                        latencyMS: Int32(configuration.latencyMS),
                        passphrase: passphrasePointer,
                        streamID: streamIDPointer,
                        connectTimeoutMS: Int32(configuration.connectTimeoutMS)
                    )
                    return ProCamSRTConnect(&cConfig, &error, Int32(error.count))
                }
            }
        }

        guard let connectedHandle else {
            let message = String(cString: error)
            if configuration.reconnectEnabled,
               configuration.maxReconnectAttempts == 0 || attempt < configuration.maxReconnectAttempts {
                queue.asyncAfter(deadline: .now() + .milliseconds(configuration.reconnectDelayMS)) {
                    self.connectLocked(attempt: attempt + 1)
                }
            } else {
                updateState(.failed(message.isEmpty ? "SRT connection failed" : message))
            }
            return
        }

        handle = connectedHandle
        droppedQueuePackets = 0
        updateState(.connected(Date()))
        refreshStatsLocked()
        drainSendQueueLocked()
    }

    private func drainSendQueueLocked() {
        guard !isSending, let handle else { return }
        isSending = true
        while !sendQueue.isEmpty {
            let packet = sendQueue.removeFirst()
            var error = [CChar](repeating: 0, count: 512)
            let result = packet.data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(-1)
                }
                return ProCamSRTSend(handle, baseAddress, Int32(packet.data.count), &error, Int32(error.count))
            }
            if result < 0 {
                let message = String(cString: error)
                ProCamSRTDisconnect(handle)
                self.handle = nil
                isSending = false
                updateState(.failed(message.isEmpty ? "SRT send failed" : message))
                if configuration.reconnectEnabled {
                    connectLocked(attempt: 1)
                }
                return
            }
        }
        isSending = false
        refreshStatsLocked()
    }

    private func refreshStatsLocked() {
        guard let handle else { return }
        var error = [CChar](repeating: 0, count: 512)
        var raw = ProCamSRTStats()
        guard ProCamSRTGetStats(handle, &raw, &error, Int32(error.count)) == 0 else {
            updateState(.failed(String(cString: error)))
            return
        }
        updateStatistics(
            SRTStatistics(
                sendBitrateMbps: raw.sendBitrateMbps,
                rttMS: raw.rttMS,
                packetLossPercent: raw.packetLossPercent,
                packetsSent: raw.packetsSent,
                packetsLost: raw.packetsLost,
                retransmittedPackets: raw.retransmittedPackets,
                sendBufferBytes: raw.sendBufferBytes,
                sendQueueDepth: sendQueue.count,
                droppedQueuePackets: droppedQueuePackets,
                connectionUptimeSeconds: raw.uptimeSeconds,
                lastUpdated: Date()
            )
        )
    }

    private func updateState(_ next: SRTConnectionState) {
        DispatchQueue.main.async {
            self.state = next
        }
    }

    private func updateStatistics(_ next: SRTStatistics) {
        DispatchQueue.main.async {
            self.statistics = next
        }
    }
}
