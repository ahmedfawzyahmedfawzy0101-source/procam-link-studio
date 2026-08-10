#include "VideoDecoder.h"

#include <mferror.h>

#include <cstring>

namespace procam {

HRESULT VideoDecoder::Decode(const ElementaryStreamPacket& packet) {
    if (packet.codec != ElementaryStreamCodec::H264 && packet.codec != ElementaryStreamCodec::Hevc) {
        return S_OK;
    }

    HRESULT hr = EnsureDecoder(packet.codec);
    if (FAILED(hr)) {
        statistics_.droppedFrames++;
        return hr;
    }

    Microsoft::WRL::ComPtr<IMFSample> sample;
    hr = MFCreateSample(&sample);
    if (FAILED(hr)) {
        return hr;
    }

    Microsoft::WRL::ComPtr<IMFMediaBuffer> mediaBuffer;
    hr = MFCreateMemoryBuffer(static_cast<DWORD>(packet.payload.size()), &mediaBuffer);
    if (FAILED(hr)) {
        return hr;
    }

    BYTE* destination = nullptr;
    DWORD maxLength = 0;
    DWORD currentLength = 0;
    hr = mediaBuffer->Lock(&destination, &maxLength, &currentLength);
    if (FAILED(hr)) {
        return hr;
    }
    std::memcpy(destination, packet.payload.data(), packet.payload.size());
    mediaBuffer->Unlock();
    mediaBuffer->SetCurrentLength(static_cast<DWORD>(packet.payload.size()));
    sample->AddBuffer(mediaBuffer.Get());

    if (packet.pts90k >= 0) {
        sample->SetSampleTime(ToHundredNanoseconds(packet.pts90k));
    }

    hr = decoder_->ProcessInput(inputStreamId_, sample.Get(), 0);
    if (FAILED(hr)) {
        statistics_.droppedFrames++;
        return hr;
    }

    while (true) {
        MFT_OUTPUT_DATA_BUFFER output{};
        DWORD status = 0;
        hr = decoder_->ProcessOutput(0, 1, &output, &status);
        if (output.pSample) {
            output.pSample->Release();
        }
        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
            return S_OK;
        }
        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
            hr = SetOutputType();
            if (FAILED(hr)) {
                return hr;
            }
            continue;
        }
        if (FAILED(hr)) {
            statistics_.droppedFrames++;
            return hr;
        }
        statistics_.decodedFrames++;
    }
}

void VideoDecoder::Reset() {
    decoder_.Reset();
    codec_ = ElementaryStreamCodec::Unknown;
    statistics_ = {};
}

HRESULT VideoDecoder::EnsureDecoder(ElementaryStreamCodec codec) {
    if (decoder_ && codec_ == codec) {
        return S_OK;
    }

    Reset();

    MFT_REGISTER_TYPE_INFO inputType{};
    inputType.guidMajorType = MFMediaType_Video;
    inputType.guidSubtype = CodecSubtype(codec);

    IMFActivate** activates = nullptr;
    UINT32 activateCount = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_DECODER,
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        &inputType,
        nullptr,
        &activates,
        &activateCount);

    if (SUCCEEDED(hr) && activateCount > 0) {
        hr = activates[0]->ActivateObject(IID_PPV_ARGS(&decoder_));
        statistics_.hardwareAccelerated = SUCCEEDED(hr);
    }

    for (UINT32 index = 0; index < activateCount; ++index) {
        activates[index]->Release();
    }
    CoTaskMemFree(activates);

    if (!decoder_) {
        hr = MFTEnumEx(
            MFT_CATEGORY_VIDEO_DECODER,
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
            &inputType,
            nullptr,
            &activates,
            &activateCount);
        if (FAILED(hr) || activateCount == 0) {
            CoTaskMemFree(activates);
            return FAILED(hr) ? hr : HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
        }
        hr = activates[0]->ActivateObject(IID_PPV_ARGS(&decoder_));
        for (UINT32 index = 0; index < activateCount; ++index) {
            activates[index]->Release();
        }
        CoTaskMemFree(activates);
        if (FAILED(hr)) {
            return hr;
        }
    }

    Microsoft::WRL::ComPtr<IMFMediaType> mediaType;
    hr = MFCreateMediaType(&mediaType);
    if (FAILED(hr)) {
        return hr;
    }
    mediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    mediaType->SetGUID(MF_MT_SUBTYPE, CodecSubtype(codec));

    hr = decoder_->SetInputType(inputStreamId_, mediaType.Get(), 0);
    if (FAILED(hr)) {
        return hr;
    }

    hr = SetOutputType();
    if (FAILED(hr)) {
        return hr;
    }

    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    codec_ = codec;
    statistics_.initialized = true;
    return S_OK;
}

HRESULT VideoDecoder::SetOutputType() {
    for (DWORD index = 0;; ++index) {
        Microsoft::WRL::ComPtr<IMFMediaType> outputType;
        HRESULT hr = decoder_->GetOutputAvailableType(outputStreamId_, index, &outputType);
        if (hr == MF_E_NO_MORE_TYPES) {
            return hr;
        }
        if (FAILED(hr)) {
            return hr;
        }

        GUID subtype = GUID_NULL;
        outputType->GetGUID(MF_MT_SUBTYPE, &subtype);
        if (subtype != MFVideoFormat_NV12 && subtype != MFVideoFormat_YUY2 && subtype != MFVideoFormat_RGB32) {
            continue;
        }

        hr = decoder_->SetOutputType(outputStreamId_, outputType.Get(), 0);
        if (SUCCEEDED(hr)) {
            UINT32 width = 0;
            UINT32 height = 0;
            if (SUCCEEDED(MFGetAttributeSize(outputType.Get(), MF_MT_FRAME_SIZE, &width, &height))) {
                statistics_.width = width;
                statistics_.height = height;
            }
            return S_OK;
        }
    }
}

GUID VideoDecoder::CodecSubtype(ElementaryStreamCodec codec) {
    return codec == ElementaryStreamCodec::Hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264;
}

LONGLONG VideoDecoder::ToHundredNanoseconds(int64_t pts90k) {
    return static_cast<LONGLONG>((pts90k * 10000000LL) / 90000LL);
}

} // namespace procam
