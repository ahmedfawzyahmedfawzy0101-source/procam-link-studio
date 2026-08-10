#pragma once

#include <chrono>
#include <cstdint>
#include <string>

namespace procam {

enum class ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    Failed
};

struct ReceiverStatistics {
    double receiveBitrateMbps = 0.0;
    double srtRttMs = 0.0;
    int64_t srtPacketsReceived = 0;
    int srtPacketsLost = 0;
    int srtReceiveBufferBytes = 0;
    double networkReceiveMs = 0.0;
    double demuxMs = 0.0;
    double decodeMs = 0.0;
    double renderMs = 0.0;
    double estimatedEndToEndMs = 0.0;
    double decodedFps = 0.0;
    uint64_t droppedFrames = 0;
    uint64_t transportPackets = 0;
    uint64_t continuityErrors = 0;
    uint64_t videoAccessUnits = 0;
    uint64_t audioAccessUnits = 0;
    uint64_t recordedBytes = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    bool hardwareDecoder = false;
    std::wstring videoCodec = L"Unknown";
    std::wstring audioCodec = L"Unknown";
};

struct StudioState {
    ConnectionState connection = ConnectionState::Disconnected;
    ReceiverStatistics statistics;
    std::wstring endpoint = L"Listener :9000";
    std::wstring status = L"Ready";
    std::wstring deviceName = L"Manual SRT";
    std::wstring remoteAddress = L"Not connected";
    std::wstring protocolStatus = L"SRT + MPEG-TS";
    bool audioPlaybackEnabled = true;
    bool recordingEnabled = false;
    bool streamActive = false;
};

} // namespace procam
