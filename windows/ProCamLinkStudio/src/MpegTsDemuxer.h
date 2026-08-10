#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

namespace procam {

enum class ElementaryStreamCodec {
    Unknown,
    H264,
    Hevc,
    Aac
};

struct ElementaryStreamPacket {
    ElementaryStreamCodec codec = ElementaryStreamCodec::Unknown;
    uint16_t pid = 0;
    int64_t pts90k = -1;
    int64_t dts90k = -1;
    std::vector<uint8_t> payload;
};

struct MpegTsStatistics {
    uint64_t transportPackets = 0;
    uint64_t continuityErrors = 0;
    uint64_t patPackets = 0;
    uint64_t pmtPackets = 0;
    uint64_t videoAccessUnits = 0;
    uint64_t audioAccessUnits = 0;
    uint16_t pmtPid = 0;
    uint16_t videoPid = 0;
    uint16_t audioPid = 0;
    ElementaryStreamCodec videoCodec = ElementaryStreamCodec::Unknown;
    ElementaryStreamCodec audioCodec = ElementaryStreamCodec::Unknown;
};

class MpegTsDemuxer {
public:
    using PacketHandler = std::function<void(const ElementaryStreamPacket&)>;

    MpegTsDemuxer();

    void Reset();
    void Push(const uint8_t* data, size_t size, const PacketHandler& handler);
    const MpegTsStatistics& Statistics() const noexcept { return stats_; }

private:
    struct PesAssembly {
        bool active = false;
        uint16_t pid = 0;
        ElementaryStreamCodec codec = ElementaryStreamCodec::Unknown;
        int64_t pts90k = -1;
        int64_t dts90k = -1;
        std::vector<uint8_t> bytes;
    };

    void ParsePacket(const uint8_t* packet, const PacketHandler& handler);
    void ParsePat(const uint8_t* payload, size_t size);
    void ParsePmt(const uint8_t* payload, size_t size);
    void PushPesPayload(uint16_t pid, ElementaryStreamCodec codec, bool startsPes, const uint8_t* payload, size_t size, const PacketHandler& handler);
    void FlushPes(const PacketHandler& handler);
    static int64_t ReadPts(const uint8_t* data);

    std::array<int, 8192> continuity_{};
    MpegTsStatistics stats_;
    PesAssembly pes_;
};

} // namespace procam
