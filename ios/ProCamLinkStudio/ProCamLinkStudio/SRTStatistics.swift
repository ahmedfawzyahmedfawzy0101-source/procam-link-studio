import Foundation

struct SRTStatistics: Equatable {
    var sendBitrateMbps: Double = 0
    var rttMS: Double = 0
    var packetLossPercent: Double = 0
    var retransmittedPackets: Int64 = 0
    var sendBufferBytes: Int64 = 0
    var connectionUptimeSeconds: TimeInterval = 0
    var lastUpdated: Date?

    static let empty = SRTStatistics()
}
