#pragma once

#include "MpegTsDemuxer.h"
#include "StudioState.h"
#include "VideoDecoder.h"

#include <mfapi.h>
#include <windows.h>

#include <atomic>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>

namespace procam {

enum class SrtConnectionMode {
    Caller,
    Listener
};

struct SrtReceiverConfiguration {
    SrtConnectionMode mode = SrtConnectionMode::Listener;
    std::wstring host = L"0.0.0.0";
    uint16_t port = 9000;
    int latencyMs = 120;
    int timeoutMs = 1000;
    std::wstring passphrase;
    std::wstring streamId;
    bool reconnect = true;
};

class ReceiverSession {
public:
    ReceiverSession() = default;
    ~ReceiverSession();

    ReceiverSession(const ReceiverSession&) = delete;
    ReceiverSession& operator=(const ReceiverSession&) = delete;

    HRESULT Initialize();
    void Shutdown();

    void ConnectManual(const std::wstring& host, uint16_t port);
    void StartListener(uint16_t port);
    void Connect(const SrtReceiverConfiguration& configuration);
    void Disconnect();
    void ToggleAudioPlayback();
    void ToggleRecording();

    StudioState StateSnapshot() const;

private:
    void ReceiveWorker(SrtReceiverConfiguration configuration);
    bool ConfigureSocket(int socket, const SrtReceiverConfiguration& configuration);
    int OpenCallerSocket(const SrtReceiverConfiguration& configuration);
    int OpenListenerSocket(const SrtReceiverConfiguration& configuration);
    void CloseSockets();
    void HandleAccessUnit(const ElementaryStreamPacket& packet);
    void PublishDemuxStatistics();
    void SetStatus(ConnectionState connection, const std::wstring& status);
    static std::string Narrow(const std::wstring& value);
    static std::wstring Widen(const std::string& value);
    static std::wstring CodecName(ElementaryStreamCodec codec);

    bool mediaFoundationStarted_ = false;
    bool comStarted_ = false;
    bool winsockStarted_ = false;
    bool srtStarted_ = false;
    std::atomic_bool stopRequested_ = false;
    std::thread worker_;
    mutable std::mutex stateMutex_;
    mutable std::mutex socketMutex_;
    int activeSocket_ = -1;
    int listenerSocket_ = -1;
    MpegTsDemuxer demuxer_;
    VideoDecoder videoDecoder_;
    std::ofstream recordingFile_;
    StudioState state_;
};

} // namespace procam
