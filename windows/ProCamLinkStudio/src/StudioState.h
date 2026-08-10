#pragma once

#include <chrono>
#include <cstdint>
#include <string>

namespace procam {

enum class ConnectionState {
    Disconnected,
    WaitingForSrtDependency,
    Connecting,
    Connected,
    Reconnecting,
    Failed
};

struct ReceiverStatistics {
    double receiveBitrateMbps = 0.0;
    double networkReceiveMs = 0.0;
    double demuxMs = 0.0;
    double decodeMs = 0.0;
    double renderMs = 0.0;
    double estimatedEndToEndMs = 0.0;
    double decodedFps = 0.0;
    uint64_t droppedFrames = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    bool hardwareDecoder = false;
};

struct StudioState {
    ConnectionState connection = ConnectionState::Disconnected;
    ReceiverStatistics statistics;
    std::wstring endpoint = L"Manual IP required";
    std::wstring status = L"Ready";
    bool audioPlaybackEnabled = true;
    bool recordingEnabled = false;
};

} // namespace procam
