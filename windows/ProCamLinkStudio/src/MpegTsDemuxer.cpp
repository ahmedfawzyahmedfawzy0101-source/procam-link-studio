#include "MpegTsDemuxer.h"

#include <algorithm>

namespace procam {

namespace {

constexpr size_t kPacketSize = 188;
constexpr uint8_t kSyncByte = 0x47;
constexpr uint16_t kPatPid = 0x0000;

ElementaryStreamCodec CodecForStreamType(uint8_t streamType) {
    switch (streamType) {
    case 0x0F:
        return ElementaryStreamCodec::Aac;
    case 0x1B:
        return ElementaryStreamCodec::H264;
    case 0x24:
        return ElementaryStreamCodec::Hevc;
    default:
        return ElementaryStreamCodec::Unknown;
    }
}

} // namespace

MpegTsDemuxer::MpegTsDemuxer() {
    Reset();
}

void MpegTsDemuxer::Reset() {
    continuity_.fill(-1);
    stats_ = {};
    pes_ = {};
}

void MpegTsDemuxer::Push(const uint8_t* data, size_t size, const PacketHandler& handler) {
    size_t offset = 0;
    while (offset + kPacketSize <= size) {
        if (data[offset] == kSyncByte) {
            ParsePacket(data + offset, handler);
            offset += kPacketSize;
            continue;
        }

        const auto* next = std::find(data + offset + 1, data + size, kSyncByte);
        if (next == data + size) {
            return;
        }
        offset = static_cast<size_t>(next - data);
    }
}

void MpegTsDemuxer::ParsePacket(const uint8_t* packet, const PacketHandler& handler) {
    if (packet[0] != kSyncByte) {
        return;
    }

    const bool payloadUnitStart = (packet[1] & 0x40) != 0;
    const uint16_t pid = static_cast<uint16_t>(((packet[1] & 0x1F) << 8) | packet[2]);
    const uint8_t adaptationControl = static_cast<uint8_t>((packet[3] >> 4) & 0x03);
    const uint8_t continuityCounter = static_cast<uint8_t>(packet[3] & 0x0F);
    stats_.transportPackets++;

    if (adaptationControl == 0 || adaptationControl == 2) {
        return;
    }

    const int previousCounter = continuity_[pid];
    if (previousCounter >= 0 && ((previousCounter + 1) & 0x0F) != continuityCounter) {
        stats_.continuityErrors++;
    }
    continuity_[pid] = continuityCounter;

    size_t payloadOffset = 4;
    if (adaptationControl == 3) {
        payloadOffset += 1 + packet[4];
    }
    if (payloadOffset >= kPacketSize) {
        return;
    }

    const uint8_t* payload = packet + payloadOffset;
    size_t payloadSize = kPacketSize - payloadOffset;

    if ((pid == kPatPid || pid == stats_.pmtPid) && payloadUnitStart) {
        if (payloadSize < 1 || payload[0] + 1 >= payloadSize) {
            return;
        }
        const size_t pointer = payload[0] + 1;
        payload += pointer;
        payloadSize -= pointer;
    }

    if (pid == kPatPid) {
        ParsePat(payload, payloadSize);
        return;
    }
    if (pid == stats_.pmtPid) {
        ParsePmt(payload, payloadSize);
        return;
    }

    if (pid == stats_.videoPid && stats_.videoCodec != ElementaryStreamCodec::Unknown) {
        PushPesPayload(pid, stats_.videoCodec, payloadUnitStart, payload, payloadSize, handler);
    } else if (pid == stats_.audioPid && stats_.audioCodec != ElementaryStreamCodec::Unknown) {
        PushPesPayload(pid, stats_.audioCodec, payloadUnitStart, payload, payloadSize, handler);
    }
}

void MpegTsDemuxer::ParsePat(const uint8_t* payload, size_t size) {
    if (size < 12 || payload[0] != 0x00) {
        return;
    }
    const size_t sectionLength = ((payload[1] & 0x0F) << 8) | payload[2];
    if (sectionLength + 3 > size || sectionLength < 9) {
        return;
    }

    size_t offset = 8;
    const size_t end = 3 + sectionLength - 4;
    while (offset + 4 <= end) {
        const uint16_t programNumber = static_cast<uint16_t>((payload[offset] << 8) | payload[offset + 1]);
        const uint16_t programPid = static_cast<uint16_t>(((payload[offset + 2] & 0x1F) << 8) | payload[offset + 3]);
        if (programNumber != 0) {
            stats_.pmtPid = programPid;
            stats_.patPackets++;
            return;
        }
        offset += 4;
    }
}

void MpegTsDemuxer::ParsePmt(const uint8_t* payload, size_t size) {
    if (size < 12 || payload[0] != 0x02) {
        return;
    }
    const size_t sectionLength = ((payload[1] & 0x0F) << 8) | payload[2];
    if (sectionLength + 3 > size || sectionLength < 13) {
        return;
    }

    const size_t programInfoLength = ((payload[10] & 0x0F) << 8) | payload[11];
    size_t offset = 12 + programInfoLength;
    const size_t end = 3 + sectionLength - 4;
    while (offset + 5 <= end) {
        const uint8_t streamType = payload[offset];
        const uint16_t elementaryPid = static_cast<uint16_t>(((payload[offset + 1] & 0x1F) << 8) | payload[offset + 2]);
        const size_t esInfoLength = ((payload[offset + 3] & 0x0F) << 8) | payload[offset + 4];
        const ElementaryStreamCodec codec = CodecForStreamType(streamType);
        if (codec == ElementaryStreamCodec::H264 || codec == ElementaryStreamCodec::Hevc) {
            stats_.videoPid = elementaryPid;
            stats_.videoCodec = codec;
        } else if (codec == ElementaryStreamCodec::Aac) {
            stats_.audioPid = elementaryPid;
            stats_.audioCodec = codec;
        }
        offset += 5 + esInfoLength;
    }
    stats_.pmtPackets++;
}

void MpegTsDemuxer::PushPesPayload(uint16_t pid, ElementaryStreamCodec codec, bool startsPes, const uint8_t* payload, size_t size, const PacketHandler& handler) {
    if (startsPes) {
        FlushPes(handler);

        if (size < 9 || payload[0] != 0x00 || payload[1] != 0x00 || payload[2] != 0x01) {
            return;
        }

        const uint8_t ptsDtsFlags = static_cast<uint8_t>((payload[7] >> 6) & 0x03);
        const size_t headerDataLength = payload[8];
        const size_t pesPayloadOffset = 9 + headerDataLength;
        if (pesPayloadOffset > size) {
            return;
        }

        pes_ = {};
        pes_.active = true;
        pes_.pid = pid;
        pes_.codec = codec;
        if ((ptsDtsFlags == 2 || ptsDtsFlags == 3) && size >= 14) {
            pes_.pts90k = ReadPts(payload + 9);
        }
        if (ptsDtsFlags == 3 && size >= 19) {
            pes_.dts90k = ReadPts(payload + 14);
        }
        pes_.bytes.insert(pes_.bytes.end(), payload + pesPayloadOffset, payload + size);
        return;
    }

    if (pes_.active && pes_.pid == pid) {
        pes_.bytes.insert(pes_.bytes.end(), payload, payload + size);
    }
}

void MpegTsDemuxer::FlushPes(const PacketHandler& handler) {
    if (!pes_.active || pes_.bytes.empty()) {
        return;
    }

    ElementaryStreamPacket packet;
    packet.codec = pes_.codec;
    packet.pid = pes_.pid;
    packet.pts90k = pes_.pts90k;
    packet.dts90k = pes_.dts90k;
    packet.payload = std::move(pes_.bytes);

    if (packet.codec == ElementaryStreamCodec::Aac) {
        stats_.audioAccessUnits++;
    } else if (packet.codec == ElementaryStreamCodec::H264 || packet.codec == ElementaryStreamCodec::Hevc) {
        stats_.videoAccessUnits++;
    }

    handler(packet);
    pes_ = {};
}

int64_t MpegTsDemuxer::ReadPts(const uint8_t* data) {
    return ((static_cast<int64_t>(data[0] >> 1) & 0x07) << 30) |
        (static_cast<int64_t>(data[1]) << 22) |
        ((static_cast<int64_t>(data[2] >> 1) & 0x7F) << 15) |
        (static_cast<int64_t>(data[3]) << 7) |
        (static_cast<int64_t>(data[4] >> 1) & 0x7F);
}

} // namespace procam
