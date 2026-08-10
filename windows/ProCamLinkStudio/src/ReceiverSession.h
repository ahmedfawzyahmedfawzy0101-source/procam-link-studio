#pragma once

#include "StudioState.h"

#include <mfapi.h>
#include <windows.h>

#include <string>

namespace procam {

class ReceiverSession {
public:
    ReceiverSession() = default;
    ~ReceiverSession();

    ReceiverSession(const ReceiverSession&) = delete;
    ReceiverSession& operator=(const ReceiverSession&) = delete;

    HRESULT Initialize();
    void Shutdown();

    void ConnectManual(const std::wstring& host, uint16_t port);
    void Disconnect();
    void ToggleAudioPlayback();
    void ToggleRecording();

    const StudioState& State() const noexcept { return state_; }

private:
    bool mediaFoundationStarted_ = false;
    StudioState state_;
};

} // namespace procam
