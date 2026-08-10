#include "ReceiverSession.h"

#include <sstream>

namespace procam {

ReceiverSession::~ReceiverSession() {
    Shutdown();
}

HRESULT ReceiverSession::Initialize() {
    if (mediaFoundationStarted_) {
        return S_OK;
    }

    const HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr)) {
        state_.connection = ConnectionState::Failed;
        state_.status = L"Media Foundation startup failed";
        return hr;
    }

    mediaFoundationStarted_ = true;
    state_.status = L"Native Windows shell ready; SRT receive is dependency-gated";
    state_.connection = ConnectionState::WaitingForSrtDependency;
    return S_OK;
}

void ReceiverSession::Shutdown() {
    if (mediaFoundationStarted_) {
        MFShutdown();
        mediaFoundationStarted_ = false;
    }
    state_.connection = ConnectionState::Disconnected;
}

void ReceiverSession::ConnectManual(const std::wstring& host, uint16_t port) {
    std::wstringstream endpoint;
    endpoint << host << L":" << port;
    state_.endpoint = endpoint.str();
    state_.connection = ConnectionState::WaitingForSrtDependency;
    state_.status = L"Real SRT receive requires libsrt integration; no fallback transport is active";
}

void ReceiverSession::Disconnect() {
    state_.connection = ConnectionState::Disconnected;
    state_.status = L"Disconnected";
}

void ReceiverSession::ToggleAudioPlayback() {
    state_.audioPlaybackEnabled = !state_.audioPlaybackEnabled;
}

void ReceiverSession::ToggleRecording() {
    state_.recordingEnabled = !state_.recordingEnabled;
}

} // namespace procam
