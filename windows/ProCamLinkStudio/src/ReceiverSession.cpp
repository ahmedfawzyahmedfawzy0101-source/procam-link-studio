#include "ReceiverSession.h"

#include <srt/srt.h>
#include <ws2tcpip.h>

#include <chrono>
#include <filesystem>
#include <set>
#include <sstream>
#include <vector>

namespace procam {

namespace {

constexpr size_t kReceiveBufferSize = 1316;

std::wstring WidenUtf8(const std::string& value) {
    if (value.empty()) {
        return {};
    }
    const int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
    std::wstring result(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), result.data(), length);
    return result;
}

std::wstring LastSrtError() {
    return WidenUtf8(srt_getlasterror_str());
}

std::wstring LocalSrtEndpoint(uint16_t port) {
    char hostname[256]{};
    if (gethostname(hostname, sizeof(hostname)) != 0) {
        return L"srt://<this-pc-ip>:" + std::to_wstring(port);
    }

    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    addrinfo* results = nullptr;
    if (getaddrinfo(hostname, nullptr, &hints, &results) != 0 || !results) {
        return L"srt://<this-pc-ip>:" + std::to_wstring(port);
    }

    std::set<std::wstring> addresses;
    for (addrinfo* item = results; item != nullptr; item = item->ai_next) {
        auto* ipv4 = reinterpret_cast<sockaddr_in*>(item->ai_addr);
        char text[INET_ADDRSTRLEN]{};
        if (inet_ntop(AF_INET, &ipv4->sin_addr, text, sizeof(text))) {
            std::string address(text);
            if (address.rfind("127.", 0) != 0) {
                addresses.insert(WidenUtf8(address));
            }
        }
    }
    freeaddrinfo(results);

    if (addresses.empty()) {
        return L"srt://<this-pc-ip>:" + std::to_wstring(port);
    }
    return L"srt://" + *addresses.begin() + L":" + std::to_wstring(port);
}

} // namespace

ReceiverSession::~ReceiverSession() {
    Shutdown();
}

HRESULT ReceiverSession::Initialize() {
    if (mediaFoundationStarted_) {
        return S_OK;
    }

    const HRESULT comHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(comHr) && comHr != RPC_E_CHANGED_MODE) {
        state_.connection = ConnectionState::Failed;
        state_.status = L"COM startup failed";
        return comHr;
    }
    comStarted_ = SUCCEEDED(comHr);

    WSADATA wsaData{};
    const int wsaResult = WSAStartup(MAKEWORD(2, 2), &wsaData);
    if (wsaResult != 0) {
        state_.connection = ConnectionState::Failed;
        state_.status = L"Winsock startup failed";
        return HRESULT_FROM_WIN32(wsaResult);
    }
    winsockStarted_ = true;

    if (srt_startup() == SRT_ERROR) {
        state_.connection = ConnectionState::Failed;
        state_.status = L"SRT startup failed";
        return E_FAIL;
    }
    srtStarted_ = true;

    const HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr)) {
        state_.connection = ConnectionState::Failed;
        state_.status = L"Media Foundation startup failed";
        return hr;
    }

    mediaFoundationStarted_ = true;
    state_.status = L"Ready. iPhone Stream host: " + LocalSrtEndpoint(9000);
    state_.connection = ConnectionState::Disconnected;
    return S_OK;
}

void ReceiverSession::Shutdown() {
    Disconnect();

    if (mediaFoundationStarted_) {
        MFShutdown();
        mediaFoundationStarted_ = false;
    }

    if (comStarted_) {
        CoUninitialize();
        comStarted_ = false;
    }

    if (srtStarted_) {
        srt_cleanup();
        srtStarted_ = false;
    }

    if (winsockStarted_) {
        WSACleanup();
        winsockStarted_ = false;
    }

    state_.connection = ConnectionState::Disconnected;
}

void ReceiverSession::ConnectManual(const std::wstring& host, uint16_t port) {
    SrtReceiverConfiguration configuration;
    configuration.mode = SrtConnectionMode::Caller;
    configuration.host = host;
    configuration.port = port;
    Connect(configuration);
}

void ReceiverSession::StartListener(uint16_t port) {
    SrtReceiverConfiguration configuration;
    configuration.mode = SrtConnectionMode::Listener;
    configuration.host = L"0.0.0.0";
    configuration.port = port;
    Connect(configuration);
}

void ReceiverSession::Connect(const SrtReceiverConfiguration& configuration) {
    Disconnect();

    std::wstringstream endpoint;
    endpoint << (configuration.mode == SrtConnectionMode::Listener ? L"listen " : L"call ")
             << configuration.host << L":" << configuration.port;

    {
        std::scoped_lock lock(stateMutex_);
        state_.endpoint = endpoint.str();
        state_.connection = ConnectionState::Connecting;
        state_.status = L"Opening SRT receiver";
        state_.streamActive = false;
        state_.statistics = {};
    }

    stopRequested_ = false;
    worker_ = std::thread(&ReceiverSession::ReceiveWorker, this, configuration);
}

void ReceiverSession::Disconnect() {
    stopRequested_ = true;
    CloseSockets();
    if (worker_.joinable()) {
        worker_.join();
    }
    if (recordingFile_.is_open()) {
        recordingFile_.close();
    }
    SetStatus(ConnectionState::Disconnected, L"Disconnected");
}

void ReceiverSession::ToggleAudioPlayback() {
    std::scoped_lock lock(stateMutex_);
    state_.audioPlaybackEnabled = !state_.audioPlaybackEnabled;
}

void ReceiverSession::ToggleRecording() {
    std::scoped_lock lock(stateMutex_);
    state_.recordingEnabled = !state_.recordingEnabled;
    if (!state_.recordingEnabled && recordingFile_.is_open()) {
        recordingFile_.close();
    }
}

StudioState ReceiverSession::StateSnapshot() const {
    std::scoped_lock lock(stateMutex_);
    return state_;
}

void ReceiverSession::ReceiveWorker(SrtReceiverConfiguration configuration) {
    demuxer_.Reset();
    videoDecoder_.Reset();
    std::vector<char> buffer(kReceiveBufferSize);

    while (!stopRequested_) {
        const int socket = configuration.mode == SrtConnectionMode::Listener
            ? OpenListenerSocket(configuration)
            : OpenCallerSocket(configuration);

        if (socket == SRT_INVALID_SOCK) {
            SetStatus(ConnectionState::Failed, L"SRT connection failed: " + LastSrtError());
            if (!configuration.reconnect || stopRequested_) {
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(750));
            SetStatus(ConnectionState::Reconnecting, L"Retrying SRT connection");
            continue;
        }

        {
            std::scoped_lock socketLock(socketMutex_);
            activeSocket_ = socket;
        }
        SetStatus(ConnectionState::Connected, L"Receiving SRT MPEG-TS");

        auto lastPacketTime = std::chrono::steady_clock::now();
        while (!stopRequested_) {
            SRT_MSGCTRL messageControl = srt_msgctrl_default;
            const auto receiveStart = std::chrono::steady_clock::now();
            const int received = srt_recvmsg2(socket, buffer.data(), static_cast<int>(buffer.size()), &messageControl);
            const auto receiveEnd = std::chrono::steady_clock::now();

            if (received == SRT_ERROR) {
                if (stopRequested_) {
                    break;
                }
                SetStatus(ConnectionState::Reconnecting, L"SRT receive interrupted: " + LastSrtError());
                break;
            }

            if (received == 0) {
                continue;
            }

            lastPacketTime = receiveEnd;
            const auto demuxStart = std::chrono::steady_clock::now();
            demuxer_.Push(reinterpret_cast<const uint8_t*>(buffer.data()), static_cast<size_t>(received), [this](const ElementaryStreamPacket& packet) {
                HandleAccessUnit(packet);
            });
            const auto demuxEnd = std::chrono::steady_clock::now();

            {
                std::scoped_lock lock(stateMutex_);
                state_.statistics.networkReceiveMs = std::chrono::duration<double, std::milli>(receiveEnd - receiveStart).count();
                state_.statistics.demuxMs = std::chrono::duration<double, std::milli>(demuxEnd - demuxStart).count();
                state_.statistics.estimatedEndToEndMs = state_.statistics.networkReceiveMs + state_.statistics.demuxMs + state_.statistics.decodeMs + state_.statistics.renderMs;

                if (state_.recordingEnabled) {
                    if (!recordingFile_.is_open()) {
                        std::filesystem::create_directories("recordings");
                        recordingFile_.open("recordings\\ProCamLinkStudio-capture.ts", std::ios::binary | std::ios::app);
                    }
                    if (recordingFile_.is_open()) {
                        recordingFile_.write(buffer.data(), received);
                        state_.statistics.recordedBytes += static_cast<uint64_t>(received);
                    }
                }
            }

            PublishDemuxStatistics();

            SRT_TRACEBSTATS srtStats{};
            if (srt_bistats(socket, &srtStats, 0, 1) != SRT_ERROR) {
                std::scoped_lock lock(stateMutex_);
                state_.statistics.receiveBitrateMbps = srtStats.mbpsRecvRate;
                state_.statistics.srtRttMs = srtStats.msRTT;
                state_.statistics.srtPacketsReceived = srtStats.pktRecvTotal;
                state_.statistics.srtPacketsLost = srtStats.pktRcvLossTotal;
                state_.statistics.srtReceiveBufferBytes = srtStats.byteRcvBuf;
            }

            if (std::chrono::steady_clock::now() - lastPacketTime > std::chrono::seconds(5)) {
                SetStatus(ConnectionState::Reconnecting, L"No SRT payload received within timeout");
                break;
            }
        }

        {
            std::scoped_lock socketLock(socketMutex_);
            if (activeSocket_ == socket) {
                activeSocket_ = SRT_INVALID_SOCK;
            }
        }
        srt_close(socket);

        if (!configuration.reconnect || stopRequested_) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
}

bool ReceiverSession::ConfigureSocket(int socket, const SrtReceiverConfiguration& configuration) {
    const SRT_TRANSTYPE live = SRTT_LIVE;
    const int yes = 1;
    const int latency = configuration.latencyMs;
    const int timeout = configuration.timeoutMs;

    if (srt_setsockflag(socket, SRTO_TRANSTYPE, &live, sizeof(live)) == SRT_ERROR) {
        return false;
    }
    srt_setsockflag(socket, SRTO_TSBPDMODE, &yes, sizeof(yes));
    srt_setsockflag(socket, SRTO_LATENCY, &latency, sizeof(latency));
    srt_setsockflag(socket, SRTO_RCVTIMEO, &timeout, sizeof(timeout));
    srt_setsockflag(socket, SRTO_CONNTIMEO, &timeout, sizeof(timeout));

    const std::string passphrase = Narrow(configuration.passphrase);
    if (!passphrase.empty() && srt_setsockflag(socket, SRTO_PASSPHRASE, passphrase.c_str(), static_cast<int>(passphrase.size())) == SRT_ERROR) {
        return false;
    }

    const std::string streamId = Narrow(configuration.streamId);
    if (!streamId.empty() && srt_setsockflag(socket, SRTO_STREAMID, streamId.c_str(), static_cast<int>(streamId.size())) == SRT_ERROR) {
        return false;
    }

    return true;
}

int ReceiverSession::OpenCallerSocket(const SrtReceiverConfiguration& configuration) {
    const int socket = srt_create_socket();
    if (socket == SRT_INVALID_SOCK || !ConfigureSocket(socket, configuration)) {
        return SRT_INVALID_SOCK;
    }

    addrinfo hints{};
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_family = AF_UNSPEC;

    const std::string host = Narrow(configuration.host);
    const std::string service = std::to_string(configuration.port);
    addrinfo* result = nullptr;
    if (getaddrinfo(host.c_str(), service.c_str(), &hints, &result) != 0) {
        srt_close(socket);
        return SRT_INVALID_SOCK;
    }

    bool connected = false;
    for (addrinfo* item = result; item != nullptr; item = item->ai_next) {
        if (srt_connect(socket, item->ai_addr, static_cast<int>(item->ai_addrlen)) != SRT_ERROR) {
            connected = true;
            break;
        }
    }
    freeaddrinfo(result);

    if (!connected) {
        srt_close(socket);
        return SRT_INVALID_SOCK;
    }
    return socket;
}

int ReceiverSession::OpenListenerSocket(const SrtReceiverConfiguration& configuration) {
    int listener = srt_create_socket();
    if (listener == SRT_INVALID_SOCK || !ConfigureSocket(listener, configuration)) {
        return SRT_INVALID_SOCK;
    }

    const int reuse = 1;
    srt_setsockflag(listener, SRTO_REUSEADDR, &reuse, sizeof(reuse));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(configuration.port);
    address.sin_addr.s_addr = INADDR_ANY;

    if (srt_bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SRT_ERROR ||
        srt_listen(listener, 1) == SRT_ERROR) {
        srt_close(listener);
        return SRT_INVALID_SOCK;
    }

    SetStatus(ConnectionState::Connecting, L"Listening. Set iPhone Stream host to " + LocalSrtEndpoint(configuration.port));

    {
        std::scoped_lock socketLock(socketMutex_);
        listenerSocket_ = listener;
    }

    sockaddr_storage peer{};
    int peerLength = sizeof(peer);
    const int accepted = srt_accept(listener, reinterpret_cast<sockaddr*>(&peer), &peerLength);
    srt_close(listener);
    {
        std::scoped_lock socketLock(socketMutex_);
        listenerSocket_ = SRT_INVALID_SOCK;
    }

    if (accepted == SRT_INVALID_SOCK) {
        return SRT_INVALID_SOCK;
    }

    wchar_t host[NI_MAXHOST]{};
    wchar_t service[NI_MAXSERV]{};
    if (GetNameInfoW(reinterpret_cast<sockaddr*>(&peer), peerLength, host, NI_MAXHOST, service, NI_MAXSERV, NI_NUMERICHOST | NI_NUMERICSERV) == 0) {
        std::scoped_lock lock(stateMutex_);
        state_.remoteAddress = std::wstring(host) + L":" + service;
    }
    return accepted;
}

void ReceiverSession::CloseSockets() {
    std::scoped_lock socketLock(socketMutex_);
    if (activeSocket_ != SRT_INVALID_SOCK) {
        srt_close(activeSocket_);
        activeSocket_ = SRT_INVALID_SOCK;
    }
    if (listenerSocket_ != SRT_INVALID_SOCK) {
        srt_close(listenerSocket_);
        listenerSocket_ = SRT_INVALID_SOCK;
    }
}

void ReceiverSession::HandleAccessUnit(const ElementaryStreamPacket& packet) {
    std::scoped_lock lock(stateMutex_);
    state_.streamActive = true;
    if (packet.codec == ElementaryStreamCodec::H264 || packet.codec == ElementaryStreamCodec::Hevc) {
        const auto decodeStart = std::chrono::steady_clock::now();
        const HRESULT hr = videoDecoder_.Decode(packet);
        const auto decodeEnd = std::chrono::steady_clock::now();
        const auto decoderStats = videoDecoder_.Statistics();
        state_.statistics.videoAccessUnits++;
        state_.statistics.videoCodec = CodecName(packet.codec);
        state_.statistics.decodeMs = std::chrono::duration<double, std::milli>(decodeEnd - decodeStart).count();
        state_.statistics.hardwareDecoder = decoderStats.hardwareAccelerated;
        state_.statistics.droppedFrames = decoderStats.droppedFrames;
        state_.statistics.decodedFps = static_cast<double>(decoderStats.decodedFrames);
        state_.statistics.width = decoderStats.width;
        state_.statistics.height = decoderStats.height;
        if (FAILED(hr)) {
            state_.status = L"Video decoder rejected an access unit";
        }
    } else if (packet.codec == ElementaryStreamCodec::Aac) {
        state_.statistics.audioAccessUnits++;
        state_.statistics.audioCodec = CodecName(packet.codec);
    }
}

void ReceiverSession::PublishDemuxStatistics() {
    const auto& demuxStats = demuxer_.Statistics();
    std::scoped_lock lock(stateMutex_);
    state_.statistics.transportPackets = demuxStats.transportPackets;
    state_.statistics.continuityErrors = demuxStats.continuityErrors;
    state_.statistics.videoCodec = CodecName(demuxStats.videoCodec);
    state_.statistics.audioCodec = CodecName(demuxStats.audioCodec);
}

void ReceiverSession::SetStatus(ConnectionState connection, const std::wstring& status) {
    std::scoped_lock lock(stateMutex_);
    state_.connection = connection;
    state_.status = status;
    if (connection != ConnectionState::Connected) {
        state_.streamActive = false;
    }
}

std::string ReceiverSession::Narrow(const std::wstring& value) {
    if (value.empty()) {
        return {};
    }
    const int length = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), result.data(), length, nullptr, nullptr);
    return result;
}

std::wstring ReceiverSession::Widen(const std::string& value) {
    if (value.empty()) {
        return {};
    }
    const int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
    std::wstring result(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), result.data(), length);
    return result;
}

std::wstring ReceiverSession::CodecName(ElementaryStreamCodec codec) {
    switch (codec) {
    case ElementaryStreamCodec::H264:
        return L"H.264";
    case ElementaryStreamCodec::Hevc:
        return L"HEVC";
    case ElementaryStreamCodec::Aac:
        return L"AAC";
    case ElementaryStreamCodec::Unknown:
    default:
        return L"Unknown";
    }
}

} // namespace procam
