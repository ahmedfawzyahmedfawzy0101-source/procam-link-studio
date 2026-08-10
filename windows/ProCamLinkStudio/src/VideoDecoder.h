#pragma once

#include "MpegTsDemuxer.h"

#include <mfapi.h>
#include <mftransform.h>
#include <wrl/client.h>

#include <cstdint>

namespace procam {

struct VideoDecoderStatistics {
    bool initialized = false;
    bool hardwareAccelerated = false;
    uint32_t decodedFrames = 0;
    uint32_t droppedFrames = 0;
    uint32_t width = 0;
    uint32_t height = 0;
};

class VideoDecoder {
public:
    HRESULT Decode(const ElementaryStreamPacket& packet);
    void Reset();
    const VideoDecoderStatistics& Statistics() const noexcept { return statistics_; }

private:
    HRESULT EnsureDecoder(ElementaryStreamCodec codec);
    HRESULT SetOutputType();
    static GUID CodecSubtype(ElementaryStreamCodec codec);
    static LONGLONG ToHundredNanoseconds(int64_t pts90k);

    ElementaryStreamCodec codec_ = ElementaryStreamCodec::Unknown;
    Microsoft::WRL::ComPtr<IMFTransform> decoder_;
    DWORD inputStreamId_ = 0;
    DWORD outputStreamId_ = 0;
    VideoDecoderStatistics statistics_;
};

} // namespace procam
