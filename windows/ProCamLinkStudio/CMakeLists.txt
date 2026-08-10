cmake_minimum_required(VERSION 3.25)

project(ProCamLinkStudioWindows LANGUAGES CXX)

add_executable(ProCamLinkStudio WIN32
    src/App.cpp
    src/App.h
    src/Main.cpp
    src/ReceiverSession.cpp
    src/ReceiverSession.h
    src/StudioState.h
    src/ControlProtocol.h
)

target_compile_features(ProCamLinkStudio PRIVATE cxx_std_20)
target_compile_definitions(ProCamLinkStudio PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(ProCamLinkStudio PRIVATE
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
