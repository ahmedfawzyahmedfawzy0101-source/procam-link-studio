#pragma once

#include <string>

namespace procam {

inline constexpr int kControlProtocolVersion = 1;

enum class ControlCommand {
    SelectCamera,
    SetZoom,
    SetTorch,
    SetResolution,
    SetFps,
    SetStabilizationMode,
    SetIso,
    SetShutter,
    SetExposureValue,
    SetFocusMode,
    SetFocusPosition,
    SetWhiteBalanceMode,
    SetKelvinTint,
    SetTrackingMode,
    SetFollowMode,
    SetFramingPreset,
    SetHorizonLock,
    SetAutoLens,
    SetImageAdjustments,
    SetActiveLook,
    SetCodec,
    SetBitrate,
    StartRecording,
    StopRecording,
    StartStreaming,
    StopStreaming
};

struct ControlEnvelope {
    int version = kControlProtocolVersion;
    std::wstring requestId;
    ControlCommand command = ControlCommand::SetZoom;
    std::wstring jsonPayload;
};

struct ControlConfirmation {
    int version = kControlProtocolVersion;
    std::wstring requestId;
    bool accepted = false;
    std::wstring confirmedStateJson;
    std::wstring error;
};

} // namespace procam
