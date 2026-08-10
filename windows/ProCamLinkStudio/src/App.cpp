#include "App.h"

#include <string>

namespace procam {

namespace {

constexpr wchar_t kWindowClass[] = L"ProCamLinkStudioWindow";

std::wstring ConnectionText(ConnectionState state) {
    switch (state) {
    case ConnectionState::Disconnected:
        return L"Disconnected";
    case ConnectionState::WaitingForSrtDependency:
        return L"SRT dependency required";
    case ConnectionState::Connecting:
        return L"Connecting";
    case ConnectionState::Connected:
        return L"Connected";
    case ConnectionState::Reconnecting:
        return L"Reconnecting";
    case ConnectionState::Failed:
        return L"Failed";
    }
    return L"Unknown";
}

void FillRectColor(HDC hdc, const RECT& rect, COLORREF color) {
    HBRUSH brush = CreateSolidBrush(color);
    FillRect(hdc, &rect, brush);
    DeleteObject(brush);
}

void DrawTextLine(HDC hdc, const std::wstring& text, RECT rect, UINT format = DT_LEFT | DT_VCENTER | DT_SINGLELINE) {
    DrawTextW(hdc, text.c_str(), static_cast<int>(text.size()), &rect, format);
}

} // namespace

int App::Run(HINSTANCE instance, int showCommand) {
    receiver_.Initialize();

    WNDCLASSW wc{};
    wc.lpfnWndProc = App::WindowProc;
    wc.hInstance = instance;
    wc.lpszClassName = kWindowClass;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassW(&wc);

    HWND hwnd = CreateWindowExW(
        0,
        kWindowClass,
        L"ProCam Link Studio",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        1280,
        820,
        nullptr,
        nullptr,
        instance,
        this
    );

    if (!hwnd) {
        return 1;
    }

    ShowWindow(hwnd, showCommand);
    UpdateWindow(hwnd);

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return static_cast<int>(msg.wParam);
}

LRESULT CALLBACK App::WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    App* app = nullptr;
    if (message == WM_NCCREATE) {
        auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
        app = static_cast<App*>(create->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    } else {
        app = reinterpret_cast<App*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }

    if (app) {
        return app->HandleMessage(hwnd, message, wparam, lparam);
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT App::HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_KEYDOWN:
        if (wparam == 'A') {
            receiver_.ToggleAudioPlayback();
            InvalidateRect(hwnd, nullptr, FALSE);
        } else if (wparam == 'R') {
            receiver_.ToggleRecording();
            InvalidateRect(hwnd, nullptr, FALSE);
        }
        return 0;
    case WM_PAINT:
        Paint(hwnd);
        return 0;
    case WM_DESTROY:
        receiver_.Shutdown();
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
}

void App::Paint(HWND hwnd) {
    PAINTSTRUCT ps{};
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT client{};
    GetClientRect(hwnd, &client);

    FillRectColor(hdc, client, RGB(16, 18, 22));
    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, RGB(236, 240, 244));

    DrawHeader(hdc, client);
    DrawPanels(hdc, client);
    DrawPreview(hdc, client);
    DrawFooter(hdc, client);

    EndPaint(hwnd, &ps);
}

void App::DrawHeader(HDC hdc, const RECT& rect) {
    RECT header{rect.left, rect.top, rect.right, rect.top + 56};
    FillRectColor(hdc, header, RGB(25, 29, 36));

    const auto& state = receiver_.State();
    RECT title{header.left + 18, header.top, header.left + 320, header.bottom};
    DrawTextLine(hdc, L"ProCam Link Studio", title);

    RECT status{header.left + 340, header.top, header.right - 18, header.bottom};
    const std::wstring line = L"Connection: " + ConnectionText(state.connection) +
        L"   Endpoint: " + state.endpoint +
        L"   Codec: H.264/HEVC   Container: MPEG-TS planned";
    DrawTextLine(hdc, line, status);
}

void App::DrawPanels(HDC hdc, const RECT& rect) {
    RECT left{rect.left, rect.top + 56, rect.left + 245, rect.bottom - 64};
    RECT right{rect.right - 285, rect.top + 56, rect.right, rect.bottom - 64};
    FillRectColor(hdc, left, RGB(22, 25, 31));
    FillRectColor(hdc, right, RGB(22, 25, 31));

    RECT leftText{left.left + 16, left.top + 14, left.right - 12, left.bottom};
    DrawTextW(hdc, L"Camera\nExposure\nFocus\nWhite Balance\nImage\nTracking\nStabilization", -1, &leftText, DT_LEFT | DT_TOP);

    RECT rightText{right.left + 16, right.top + 14, right.right - 12, right.bottom};
    DrawTextW(hdc, L"Receiver\nSRT stats\nDecoder stats\nAudio\nRecording\nControl confirmations", -1, &rightText, DT_LEFT | DT_TOP);
}

void App::DrawPreview(HDC hdc, const RECT& rect) {
    RECT preview{rect.left + 245, rect.top + 56, rect.right - 285, rect.bottom - 64};
    FillRectColor(hdc, preview, RGB(7, 9, 12));
    SetTextColor(hdc, RGB(146, 156, 168));
    DrawTextLine(hdc, L"Live preview surface - Media Foundation/D3D decoder integration pending real SRT demux", preview, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SetTextColor(hdc, RGB(236, 240, 244));
}

void App::DrawFooter(HDC hdc, const RECT& rect) {
    RECT footer{rect.left, rect.bottom - 64, rect.right, rect.bottom};
    FillRectColor(hdc, footer, RGB(25, 29, 36));

    const auto& state = receiver_.State();
    RECT text{footer.left + 18, footer.top, footer.right - 18, footer.bottom};
    const std::wstring line =
        std::wstring(L"Record: ") + (state.recordingEnabled ? L"On" : L"Off") +
        L"   Audio: " + (state.audioPlaybackEnabled ? L"On" : L"Off") +
        L"   Shortcuts: R record, A audio";
    DrawTextLine(hdc, line, text);
}

} // namespace procam
