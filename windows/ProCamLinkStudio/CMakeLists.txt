cmake_minimum_required(VERSION 3.25)

project(ProCamLinkStudioWindows LANGUAGES CXX)

find_path(PROCAM_SRT_INCLUDE_DIR NAMES srt/srt.h REQUIRED)
find_library(PROCAM_SRT_LIBRARY NAMES srt srt_static REQUIRED)

add_library(ProCamLinkStudioSrt UNKNOWN IMPORTED)
set_target_properties(ProCamLinkStudioSrt PROPERTIES
    IMPORTED_LOCATION "${PROCAM_SRT_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PROCAM_SRT_INCLUDE_DIR}"
)

add_executable(ProCamLinkStudio WIN32
    src/App.cpp
    src/App.h
    src/Main.cpp
    src/MpegTsDemuxer.cpp
    src/MpegTsDemuxer.h
    src/ReceiverSession.cpp
    src/ReceiverSession.h
    src/StudioState.h
    src/VideoDecoder.cpp
    src/VideoDecoder.h
    src/ControlProtocol.h
)

target_compile_features(ProCamLinkStudio PRIVATE cxx_std_20)
target_compile_definitions(ProCamLinkStudio PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(ProCamLinkStudio PRIVATE
    ProCamLinkStudioSrt
    mfplat
    mf
    mfuuid
    mfreadwrite
    d3d11
    dxgi
    ws2_32
)

if(MSVC)
    target_compile_options(ProCamLinkStudio PRIVATE /W4 /permissive-)
endif()
