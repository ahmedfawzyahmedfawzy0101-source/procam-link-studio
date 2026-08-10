import CoreMedia
import Foundation

enum TransportStreamCodec: Equatable {
    case h264
    case hevc
    case aac
}

struct TransportStreamSample {
    var payload: Data
    var presentationTime: CMTime
    var decodeTime: CMTime?
    var isKeyFrame: Bool
}

final class MPEGTransportStreamMuxer {
    private let videoPID: UInt16 = 0x0100
    private let audioPID: UInt16 = 0x0101
    private let pmtPID: UInt16 = 0x1000
    private var continuityCounters: [UInt16: UInt8] = [:]
    private var packetsSinceProgramTable = Int.max
    private let videoCodec: TransportStreamCodec

    init(videoCodec: TransportStreamCodec) {
        self.videoCodec = videoCodec
    }

    func muxVideo(_ sample: TransportStreamSample) -> Data {
        var output = Data()
        appendProgramTablesIfNeeded(to: &output, force: sample.isKeyFrame)
        let streamID: UInt8 = 0xE0
        let pes = makePESPacket(sample: sample, streamID: streamID)
        output.append(packetize(payload: pes, pid: videoPID, payloadUnitStart: true, addPCR: sample.isKeyFrame, pcrTime: sample.decodeTime ?? sample.presentationTime))
        return output
    }

    func muxAudio(_ sample: TransportStreamSample) -> Data {
        var output = Data()
        appendProgramTablesIfNeeded(to: &output, force: false)
        let streamID: UInt8 = 0xC0
        let pes = makePESPacket(sample: sample, streamID: streamID)
        output.append(packetize(payload: pes, pid: audioPID, payloadUnitStart: true, addPCR: false, pcrTime: nil))
        return output
    }

    func reset() {
        continuityCounters.removeAll()
        packetsSinceProgramTable = Int.max
    }

    private func appendProgramTablesIfNeeded(to output: inout Data, force: Bool) {
        if force || packetsSinceProgramTable >= 120 {
            output.append(packetize(payload: makePAT(), pid: 0x0000, payloadUnitStart: true, addPCR: false, pcrTime: nil))
            output.append(packetize(payload: makePMT(), pid: pmtPID, payloadUnitStart: true, addPCR: false, pcrTime: nil))
            packetsSinceProgramTable = 0
        }
    }

    private func packetize(payload: Data, pid: UInt16, payloadUnitStart: Bool, addPCR: Bool, pcrTime: CMTime?) -> Data {
        var output = Data()
        var offset = 0
        var first = true

        while offset < payload.count {
            var packet = Data()
            packet.append(0x47)
            packet.append(UInt8((payloadUnitStart && first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)))
            packet.append(UInt8(pid & 0xFF))

            let counter = nextContinuityCounter(for: pid)
            let wantsPCR = addPCR && first
            let headerIndex = packet.count
            packet.append(wantsPCR ? UInt8(0x30 | counter) : UInt8(0x10 | counter))

            var payloadCapacity = 184
            if wantsPCR {
                let pcr = pcrBytes(for: pcrTime ?? .zero)
                packet.append(7)
                packet.append(0x10)
                packet.append(pcr)
                payloadCapacity -= 8
            }

            let remaining = payload.count - offset
            let copyCount = min(payloadCapacity, remaining)
            let needsStuffing = copyCount < payloadCapacity

            if needsStuffing {
                let stuffingCount = payloadCapacity - copyCount
                if wantsPCR {
                    packet[headerIndex + 1] += UInt8(stuffingCount)
                    packet.append(Data(repeating: 0xFF, count: stuffingCount))
                } else {
                    packet[headerIndex] = UInt8(0x30 | counter)
                    packet.append(UInt8(stuffingCount - 1))
                    if stuffingCount > 1 {
                        packet.append(Data(repeating: 0xFF, count: stuffingCount - 1))
                    }
                }
            }

            packet.append(payload.subdata(in: offset..<(offset + copyCount)))
            if packet.count < 188 {
                packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
            }
            output.append(packet.prefix(188))
            offset += copyCount
            first = false
            packetsSinceProgramTable += 1
        }

        return output
    }

    private func makePESPacket(sample: TransportStreamSample, streamID: UInt8) -> Data {
        var pes = Data([0x00, 0x00, 0x01, streamID, 0x00, 0x00, 0x80])
        let hasDTS = sample.decodeTime != nil && sample.decodeTime != sample.presentationTime
        pes.append(hasDTS ? 0xC0 : 0x80)
        pes.append(hasDTS ? 10 : 5)
        pes.append(timestampBytes(sample.presentationTime, prefix: hasDTS ? 0x03 : 0x02))
        if let decodeTime = sample.decodeTime, hasDTS {
            pes.append(timestampBytes(decodeTime, prefix: 0x01))
        }
        pes.append(sample.payload)
        let payloadLength = pes.count - 6
        if payloadLength <= 0xFFFF {
            pes[4] = UInt8((payloadLength >> 8) & 0xFF)
            pes[5] = UInt8(payloadLength & 0xFF)
        }
        return pes
    }

    private func makePAT() -> Data {
        var section = Data([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01])
        section.append(UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)))
        section.append(UInt8(pmtPID & 0xFF))
        appendCRC32(to: &section)
        return Data([0x00]) + section
    }

    private func makePMT() -> Data {
        var section = Data([0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00])
        section.append(UInt8(0xE0 | ((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))
        section.append(0xF0)
        section.append(0x00)
        appendStream(codec: videoCodec, pid: videoPID, to: &section)
        appendStream(codec: .aac, pid: audioPID, to: &section)
        section[1] = 0xB0 | UInt8(((section.count - 3 + 4) >> 8) & 0x0F)
        section[2] = UInt8((section.count - 3 + 4) & 0xFF)
        appendCRC32(to: &section)
        return Data([0x00]) + section
    }

    private func appendStream(codec: TransportStreamCodec, pid: UInt16, to section: inout Data) {
        section.append(streamType(for: codec))
        section.append(UInt8(0xE0 | ((pid >> 8) & 0x1F)))
        section.append(UInt8(pid & 0xFF))
        section.append(0xF0)
        section.append(0x00)
    }

    private func streamType(for codec: TransportStreamCodec) -> UInt8 {
        switch codec {
        case .h264:
            return 0x1B
        case .hevc:
            return 0x24
        case .aac:
            return 0x0F
        }
    }

    private func nextContinuityCounter(for pid: UInt16) -> UInt8 {
        let next = continuityCounters[pid, default: 0] & 0x0F
        continuityCounters[pid] = (next + 1) & 0x0F
        return next
    }

    private func timestampBytes(_ time: CMTime, prefix: UInt8) -> Data {
        let pts = UInt64(max(0, CMTimeGetSeconds(time)) * 90_000) & 0x1FFFFFFFF
        let byte0 = UInt8((UInt64(prefix) << 4) | (((pts >> 30) & 0x07) << 1) | 1)
        let byte1 = UInt8((pts >> 22) & 0xFF)
        let byte2 = UInt8((((pts >> 15) & 0x7F) << 1) | 1)
        let byte3 = UInt8((pts >> 7) & 0xFF)
        let byte4 = UInt8(((pts & 0x7F) << 1) | 1)
        return Data([byte0, byte1, byte2, byte3, byte4])
    }

    private func pcrBytes(for time: CMTime) -> Data {
        let base = UInt64(max(0, CMTimeGetSeconds(time)) * 90_000) & 0x1FFFFFFFF
        return Data([
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8(((base & 0x01) << 7) | 0x7E),
            0x00
        ])
    }

    private func appendCRC32(to data: inout Data) {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : (crc << 1)
            }
        }
        data.append(UInt8((crc >> 24) & 0xFF))
        data.append(UInt8((crc >> 16) & 0xFF))
        data.append(UInt8((crc >> 8) & 0xFF))
        data.append(UInt8(crc & 0xFF))
    }
}
