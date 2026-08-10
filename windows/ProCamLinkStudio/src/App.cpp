#include "App.h"

#include <windowsx.h>

#include <algorithm>
#include <array>
#include <sstream>
#include <string>
#include <vector>

namespace procam {

namespace {

constexpr wchar_t kWindowClass[] = L"ProCamLinkStudioWindow";
constexpr int kHeaderHeight = 56;
constexpr int kFooterHeight = 64;
constexpr int kLeftWidth = 288;
constexpr int kRightWidth = 344;
constexpr int kGap = 12;

enum CommandId {
    CommandConnect = 1,
    CommandRecord = 2,
    CommandStream = 3,
    CommandVirtualCamera = 4,
    CommandDiscovery = 5,
    CommandAudio = 6
};

struct Theme {
    COLORREF window = RGB(246, 247, 249);
    COLORREF header = RGB(255, 255, 255);
    COLORREF surface = RGB(255, 255, 255);
    COLORREF surfaceRaised = RGB(248, 250, 252);
    COLORREF preview = RGB(4, 5, 7);
    COLORREF stroke = RGB(222, 226, 232);
    COLORREF text = RGB(36, 42, 52);
    COLORREF muted = RGB(92, 101, 115);
    COLORREF dim = RGB(151, 158, 169);
    COLORREF accent = RGB(0, 122, 255);
    COLORREF green = RGB(28, 172, 94);
    COLORREF red = RGB(214, 57, 68);
    COLORREF amber = RGB(211, 139, 35);
};

Theme gTheme;

std::wstring ConnectionText(ConnectionState state) {
    switch (state) {
    case ConnectionState::Disconnected:
        return L"Offline";
    case ConnectionState::Connecting:
        return L"Connecting";
    case ConnectionState::Connected:
        return L"Connected";
    case ConnectionState::Reconnecting:
        return L"Reconnecting";
    case ConnectionState::Failed:
        return L"Needs attention";
    }
    return L"Unknown";
}

COLORREF ConnectionColor(ConnectionState state) {
    switch (state) {
    case ConnectionState::Connected:
        return gTheme.green;
    case ConnectionState::Connecting:
    case ConnectionState::Reconnecting:
        return gTheme.amber;
    case ConnectionState::Failed:
        return gTheme.red;
    default:
        return gTheme.dim;
    }
}

std::wstring FormatDouble(double value, int precision = 1) {
    std::wstringstream stream;
    stream.setf(std::ios::fixed);
    stream.precision(precision);
    stream << value;
    return stream.str();
}

std::wstring FormatBytes(uint64_t bytes) {
    const double mb = static_cast<double>(bytes) / (1024.0 * 1024.0);
    return FormatDouble(mb, mb >= 10 ? 0 : 1) + L" MB";
}

HFONT CreateUiFont(int size, int weight = FW_NORMAL) {
    return CreateFontW(
        -size,
        0,
        0,
        0,
        weight,
        FALSE,
        FALSE,
        FALSE,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_SWISS,
        L"Segoe UI"
    );
}

void FillRectColor(HDC hdc, const RECT& rect, COLORREF color) {
    HBRUSH brush = CreateSolidBrush(color);
    FillRect(hdc, &rect, brush);
    DeleteObject(brush);
}

void RoundedFill(HDC hdc, const RECT& rect, COLORREF fill, COLORREF stroke = CLR_INVALID, int radius = 12) {
    HBRUSH brush = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 1, stroke == CLR_INVALID ? fill : stroke);
    HGDIOBJ oldBrush = SelectObject(hdc, brush);
    HGDIOBJ oldPen = SelectObject(hdc, pen);
    RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
    SelectObject(hdc, oldBrush);
    SelectObject(hdc, oldPen);
    DeleteObject(brush);
    DeleteObject(pen);
}

void DrawTextBlock(HDC hdc, const std::wstring& text, RECT rect, COLORREF color, HFONT font, UINT format) {
    HGDIOBJ oldFont = SelectObject(hdc, font);
    SetTextColor(hdc, color);
    SetBkMode(hdc, TRANSPARENT);
    DrawTextW(hdc, text.c_str(), static_cast<int>(text.size()), &rect, format);
    SelectObject(hdc, oldFont);
}

void DrawLabel(HDC hdc, const std::wstring& text, RECT rect, HFONT font, COLORREF color = gTheme.muted) {
    DrawTextBlock(hdc, text, rect, color, font, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
}

void DrawDot(HDC hdc, int x, int y, COLORREF color) {
    HBRUSH brush = CreateSolidBrush(color);
    HGDIOBJ oldBrush = SelectObject(hdc, brush);
    HPEN pen = CreatePen(PS_SOLID, 1, color);
    HGDIOBJ oldPen = SelectObject(hdc, pen);
    Ellipse(hdc, x - 4, y - 4, x + 4, y + 4);
    SelectObject(hdc, oldBrush);
    SelectObject(hdc, oldPen);
    DeleteObject(brush);
    DeleteObject(pen);
}

void DrawPill(HDC hdc, const std::wstring& text, RECT rect, COLORREF fill, COLORREF stroke, COLORREF textColor, HFONT font) {
    RoundedFill(hdc, rect, fill, stroke, 14);
    DrawTextBlock(hdc, text, rect, textColor, font, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
}

void DrawButton(HDC hdc, const std::wstring& text, RECT rect, COLORREF fill, COLORREF textColor, HFONT font, bool enabled = true) {
    RoundedFill(hdc, rect, enabled ? fill : RGB(235, 238, 243), enabled ? RGB(204, 211, 221) : RGB(226, 230, 236), 10);
    DrawTextBlock(hdc, text, rect, enabled ? textColor : gTheme.dim, font, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
}

void DrawSectionTitle(HDC hdc, const std::wstring& title, RECT& cursor, HFONT font) {
    RECT label{cursor.left, cursor.top, cursor.right, cursor.top + 24};
    DrawTextBlock(hdc, title, label, gTheme.muted, font, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    cursor.top += 28;
}

void DrawMetric(HDC hdc, const std::wstring& title, const std::wstring& value, RECT rect, HFONT labelFont, HFONT valueFont) {
    RoundedFill(hdc, rect, RGB(249, 250, 252), RGB(226, 230, 236), 8);
    RECT label{rect.left + 10, rect.top + 7, rect.right - 10, rect.top + 25};
    RECT body{rect.left + 10, rect.top + 24, rect.right - 10, rect.bottom - 6};
    DrawTextBlock(hdc, title, label, gTheme.dim, labelFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    DrawTextBlock(hdc, value, body, gTheme.text, valueFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
}

void DrawSlider(HDC hdc, const std::wstring& label, const std::wstring& value, int percent, RECT rect, HFONT font, HFONT valueFont) {
    RECT header{rect.left, rect.top, rect.right, rect.top + 22};
    RECT labelRect{header.left, header.top, header.right - 72, header.bottom};
    RECT valueRect{header.right - 70, header.top, header.right, header.bottom};
    DrawTextBlock(hdc, label, labelRect, gTheme.text, font, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    DrawTextBlock(hdc, value, valueRect, gTheme.muted, valueFont, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
    RECT track{rect.left, rect.top + 30, rect.right, rect.top + 36};
    RoundedFill(hdc, track, RGB(225, 229, 235), RGB(225, 229, 235), 6);
    RECT active{track.left, track.top, track.left + ((track.right - track.left) * std::clamp(percent, 0, 100)) / 100, track.bottom};
    RoundedFill(hdc, active, gTheme.accent, gTheme.accent, 6);
}

bool PtInRectLocal(const RECT& rect, int x, int y) {
    return x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom;
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
        1440,
        900,
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
    case WM_KEYDOWN: {
        const bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
        const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        if ((ctrl && wparam == 'R') || wparam == 'R') {
            HandleCommand(CommandRecord);
        } else if ((ctrl && wparam == 'S') || wparam == 'S') {
            HandleCommand(CommandStream);
        } else if (ctrl && shift && wparam == 'V') {
            HandleCommand(CommandVirtualCamera);
        } else if (wparam == 'C') {
            HandleCommand(CommandConnect);
        } else if (wparam == 'D') {
            receiver_.Disconnect();
        } else if (wparam == 'A') {
            HandleCommand(CommandAudio);
        } else if (wparam == 'F') {
            // Fullscreen preview is reserved for the next UI batch.
        }
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    }
    case WM_LBUTTONUP:
        HandleClick(hwnd, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    case WM_CREATE:
        receiver_.StartListener(9000);
        receiver_.AdvertiseDiscovery();
        SetTimer(hwnd, 1, 250, nullptr);
        return 0;
    case WM_TIMER:
        if (++discoveryTimerTicks_ >= 8) {
            discoveryTimerTicks_ = 0;
            receiver_.AdvertiseDiscovery();
        }
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
    case WM_GETMINMAXINFO: {
        auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
        limits->ptMinTrackSize.x = 1120;
        limits->ptMinTrackSize.y = 720;
        return 0;
    }
    case WM_PAINT:
        Paint(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, 1);
        receiver_.Shutdown();
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
}

void App::HandleCommand(int commandId) {
    switch (commandId) {
    case CommandConnect:
        showConnectDialog_ = !showConnectDialog_;
        receiver_.AdvertiseDiscovery();
        break;
    case CommandStream:
        receiver_.StartListener(9000);
        receiver_.AdvertiseDiscovery();
        break;
    case CommandRecord:
        receiver_.ToggleRecording();
        break;
    case CommandAudio:
        receiver_.ToggleAudioPlayback();
        break;
    case CommandDiscovery:
        receiver_.AdvertiseDiscovery();
        break;
    default:
        break;
    }
}

void App::HandleClick(HWND hwnd, int x, int y) {
    RECT rect{};
    GetClientRect(hwnd, &rect);
    RECT header{rect.left, rect.top, rect.right, rect.top + kHeaderHeight};
    const int top = header.top + 10;
    if (PtInRectLocal(RECT{header.right - 406, top, header.right - 326, top + 36}, x, y)) {
        HandleCommand(CommandRecord);
        return;
    }
    if (PtInRectLocal(RECT{header.right - 316, top, header.right - 232, top + 36}, x, y)) {
        HandleCommand(CommandStream);
        return;
    }

    RECT left{rect.left + kGap, rect.top + kHeaderHeight + kGap, rect.left + kLeftWidth, rect.bottom - kFooterHeight - kGap};
    RECT cursor{left.left + 16, left.top + 14, left.right - 16, left.bottom - 16};
    cursor.top += 48 + 132;
    RECT addDevice{cursor.left, cursor.top, cursor.left + 116, cursor.top + 34};
    RECT manualIp{cursor.left + 124, cursor.top, cursor.right, cursor.top + 34};
    if (PtInRectLocal(addDevice, x, y) || PtInRectLocal(manualIp, x, y)) {
        HandleCommand(CommandConnect);
        return;
    }

    const int center = (rect.left + rect.right) / 2;
    RECT footer{rect.left, rect.bottom - kFooterHeight, rect.right, rect.bottom};
    if (PtInRectLocal(RECT{center - 154, footer.top + 12, center - 46, footer.bottom - 12}, x, y)) {
        HandleCommand(CommandRecord);
        return;
    }
    if (PtInRectLocal(RECT{center - 34, footer.top + 12, center + 94, footer.bottom - 12}, x, y)) {
        HandleCommand(CommandStream);
        return;
    }

    RECT inspector{rect.right - kRightWidth, rect.top + kHeaderHeight + kGap, rect.right - kGap, rect.bottom - kFooterHeight - kGap};
    RECT tabCursor{inspector.left + 16, inspector.top + 14, inspector.right - 16, inspector.bottom - 16};
    int tabX = tabCursor.left;
    for (int i = 0; i < 5; ++i) {
        RECT tab{tabX, tabCursor.top, tabX + 58, tabCursor.top + 28};
        if (PtInRectLocal(tab, x, y)) {
            selectedInspectorTab_ = i;
            return;
        }
        tabX += 62;
    }

    if (showConnectDialog_) {
        RECT dialog{rect.left + (rect.right - rect.left) / 2 - 230, rect.top + (rect.bottom - rect.top) / 2 - 170, rect.left + (rect.right - rect.left) / 2 + 230, rect.top + (rect.bottom - rect.top) / 2 + 170};
        RECT connect{dialog.right - 142, dialog.bottom - 56, dialog.right - 24, dialog.bottom - 20};
        RECT close{dialog.right - 34, dialog.top + 14, dialog.right - 14, dialog.top + 34};
        if (PtInRectLocal(connect, x, y)) {
            showConnectDialog_ = false;
            HandleCommand(CommandStream);
        } else if (!PtInRectLocal(dialog, x, y) || PtInRectLocal(close, x, y)) {
            showConnectDialog_ = false;
        }
    }
}

void App::Paint(HWND hwnd) {
    PAINTSTRUCT ps{};
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT client{};
    GetClientRect(hwnd, &client);

    HDC buffer = CreateCompatibleDC(hdc);
    HBITMAP bitmap = CreateCompatibleBitmap(hdc, client.right - client.left, client.bottom - client.top);
    HGDIOBJ oldBitmap = SelectObject(buffer, bitmap);

    FillRectColor(buffer, client, gTheme.window);
    SetBkMode(buffer, TRANSPARENT);

    DrawHeader(buffer, client);
    DrawLeftSidebar(buffer, client);
    DrawPreview(buffer, client);
    DrawRightInspector(buffer, client);
    DrawFooter(buffer, client);

    if (showConnectDialog_) {
        auto titleFont = CreateUiFont(20, FW_SEMIBOLD);
        auto textFont = CreateUiFont(14, FW_NORMAL);
        auto smallFont = CreateUiFont(12, FW_NORMAL);
        const auto state = receiver_.StateSnapshot();
        RECT overlay{client.left, client.top, client.right, client.bottom};
        FillRectColor(buffer, overlay, RGB(8, 10, 14));
        RECT dialog{client.left + (client.right - client.left) / 2 - 230, client.top + (client.bottom - client.top) / 2 - 170, client.left + (client.right - client.left) / 2 + 230, client.top + (client.bottom - client.top) / 2 + 170};
        RoundedFill(buffer, dialog, RGB(26, 31, 41), RGB(71, 86, 108), 18);
        DrawTextBlock(buffer, L"Connect Device", RECT{dialog.left + 24, dialog.top + 18, dialog.right - 60, dialog.top + 54}, gTheme.text, titleFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        DrawPill(buffer, L"x", RECT{dialog.right - 34, dialog.top + 14, dialog.right - 14, dialog.top + 34}, RGB(42, 48, 60), RGB(65, 76, 94), gTheme.muted, smallFont);
        RECT discovered{dialog.left + 24, dialog.top + 76, dialog.right - 24, dialog.top + 154};
        RoundedFill(buffer, discovered, RGB(32, 38, 50), RGB(52, 64, 82), 14);
        DrawDot(buffer, discovered.left + 22, discovered.top + 26, ConnectionColor(state.connection));
        DrawTextBlock(buffer, L"Discovered iPhone / SRT sender", RECT{discovered.left + 42, discovered.top + 12, discovered.right - 18, discovered.top + 38}, gTheme.text, textFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        DrawTextBlock(buffer, state.status, RECT{discovered.left + 42, discovered.top + 38, discovered.right - 18, discovered.bottom - 10}, gTheme.muted, smallFont, DT_LEFT | DT_VCENTER | DT_WORDBREAK | DT_END_ELLIPSIS);
        RECT manual{dialog.left + 24, dialog.top + 170, dialog.right - 24, dialog.top + 230};
        RoundedFill(buffer, manual, RGB(22, 27, 36), RGB(46, 55, 70), 12);
        DrawTextBlock(buffer, L"Manual IP: listen on port 9000   Control: discovery UDP 47777", RECT{manual.left + 14, manual.top, manual.right - 14, manual.bottom}, gTheme.muted, smallFont, DT_LEFT | DT_VCENTER | DT_WORDBREAK);
        DrawButton(buffer, L"Refresh", RECT{dialog.left + 24, dialog.bottom - 56, dialog.left + 124, dialog.bottom - 20}, RGB(42, 50, 64), gTheme.text, textFont);
        DrawButton(buffer, L"Listen", RECT{dialog.right - 142, dialog.bottom - 56, dialog.right - 24, dialog.bottom - 20}, gTheme.accent, gTheme.text, textFont);
        DeleteObject(titleFont);
        DeleteObject(textFont);
        DeleteObject(smallFont);
    }

    BitBlt(hdc, 0, 0, client.right - client.left, client.bottom - client.top, buffer, 0, 0, SRCCOPY);
    SelectObject(buffer, oldBitmap);
    DeleteObject(bitmap);
    DeleteDC(buffer);
    EndPaint(hwnd, &ps);
}

void App::DrawHeader(HDC hdc, const RECT& rect) {
    auto titleFont = CreateUiFont(18, FW_SEMIBOLD);
    auto textFont = CreateUiFont(13, FW_NORMAL);
    auto smallFont = CreateUiFont(12, FW_NORMAL);
    auto buttonFont = CreateUiFont(13, FW_SEMIBOLD);
    const auto state = receiver_.StateSnapshot();

    RECT header{rect.left, rect.top, rect.right, rect.top + kHeaderHeight};
    FillRectColor(hdc, header, gTheme.header);

    RECT logoBox{header.left + 18, header.top + 12, header.left + 46, header.top + 40};
    RoundedFill(hdc, logoBox, RGB(35, 116, 214), RGB(64, 151, 255), 8);
    DrawTextBlock(hdc, L"P", logoBox, RGB(255, 255, 255), titleFont, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    RECT title{header.left + 56, header.top + 8, header.left + 260, header.bottom - 8};
    DrawTextBlock(hdc, L"ProCam Link Studio", title, gTheme.text, titleFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

    RECT stateDot{header.left + 306, header.top, header.left + 322, header.bottom};
    DrawDot(hdc, stateDot.left + 7, stateDot.top + 28, ConnectionColor(state.connection));

    RECT center{header.left + 326, header.top + 7, header.right - 430, header.bottom - 7};
    std::wstring resolution = state.statistics.width > 0 ? std::to_wstring(state.statistics.width) + L"x" + std::to_wstring(state.statistics.height) : L"No signal";
    std::wstring centerLine = L"iPhone  " + ConnectionText(state.connection) +
        L"   " + resolution +
        L"   " + state.statistics.videoCodec +
        L"   Clean   " +
        FormatDouble(state.statistics.srtRttMs, 0) + L" ms RTT";
    DrawTextBlock(hdc, centerLine, center, gTheme.muted, textFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);

    const int top = header.top + 10;
    DrawButton(hdc, state.recordingEnabled ? L"Stop" : L"Record", RECT{header.right - 406, top, header.right - 326, top + 36}, state.recordingEnabled ? gTheme.red : RGB(255, 255, 255), state.recordingEnabled ? RGB(255, 255, 255) : gTheme.text, buttonFont);
    DrawButton(hdc, L"Stream", RECT{header.right - 316, top, header.right - 232, top + 36}, state.connection == ConnectionState::Connected ? gTheme.green : RGB(255, 255, 255), state.connection == ConnectionState::Connected ? RGB(255, 255, 255) : gTheme.text, buttonFont);
    DrawButton(hdc, L"Virtual Camera", RECT{header.right - 222, top, header.right - 96, top + 36}, RGB(244, 246, 249), gTheme.dim, buttonFont, false);
    DrawPill(hdc, L"Perf", RECT{header.right - 86, top + 4, header.right - 38, top + 32}, RGB(255, 255, 255), RGB(222, 226, 232), gTheme.muted, smallFont);
    DrawPill(hdc, L"...", RECT{header.right - 32, top + 4, header.right - 10, top + 32}, RGB(255, 255, 255), RGB(222, 226, 232), gTheme.muted, smallFont);

    DeleteObject(titleFont);
    DeleteObject(textFont);
    DeleteObject(smallFont);
    DeleteObject(buttonFont);
}

void App::DrawLeftSidebar(HDC hdc, const RECT& rect) {
    auto titleFont = CreateUiFont(15, FW_SEMIBOLD);
    auto textFont = CreateUiFont(13, FW_NORMAL);
    auto smallFont = CreateUiFont(12, FW_NORMAL);
    const auto state = receiver_.StateSnapshot();

    RECT sidebar{rect.left + kGap, rect.top + kHeaderHeight + kGap, rect.left + kLeftWidth, rect.bottom - kFooterHeight - kGap};
    RoundedFill(hdc, sidebar, gTheme.surface, RGB(224, 229, 236), 10);

    RECT cursor{sidebar.left + 16, sidebar.top + 14, sidebar.right - 16, sidebar.bottom - 16};
    DrawTextBlock(hdc, L"Devices", RECT{cursor.left, cursor.top, cursor.left + 94, cursor.top + 32}, gTheme.text, titleFont, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    DrawPill(hdc, L"Sources", RECT{cursor.left + 102, cursor.top, cursor.left + 190, cursor.top + 32}, RGB(247, 249, 252), RGB(226, 230, 236), gTheme.muted, smallFont);
    cursor.top += 48;

    RECT device{cursor.left, cursor.top, cursor.right, cursor.top + 118};
    RoundedFill(hdc, device, RGB(255, 255, 255), state.connection == ConnectionState::Connected ? gTheme.green : RGB(216, 222, 231), 12);
    DrawDot(hdc, device.left + 18, device.top + 24, ConnectionColor(state.connection));
    DrawTextBlock(hdc, L"iPhone Camera", RECT{device.left + 34, device.top + 12, device.right - 16, device.top + 36}, gTheme.text, titleFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    DrawTextBlock(hdc, ConnectionText(state.connection), RECT{device.left + 34, device.top + 36, device.right - 16, device.top + 58}, gTheme.muted, smallFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    DrawMetric(hdc, L"Battery", L"--", RECT{device.left + 12, device.top + 70, device.left + 78, device.bottom - 12}, smallFont, textFont);
    DrawMetric(hdc, L"Network", state.connection == ConnectionState::Connected ? L"Good" : L"Waiting", RECT{device.left + 86, device.top + 70, device.left + 164, device.bottom - 12}, smallFont, textFont);
    DrawMetric(hdc, L"Camera", L"Back", RECT{device.left + 172, device.top + 70, device.right - 12, device.bottom - 12}, smallFont, textFont);
    cursor.top += 132;

    DrawButton(hdc, L"+ Add Device", RECT{cursor.left, cursor.top, cursor.left + 116, cursor.top + 34}, RGB(255, 255, 255), gTheme.text, textFont);
    DrawButton(hdc, L"Manual IP", RECT{cursor.left + 124, cursor.top, cursor.right, cursor.top + 34}, RGB(255, 255, 255), gTheme.text, textFont);
    cursor.top += 52;

    DrawSectionTitle(hdc, L"Lens", cursor, smallFont);
    std::array<std::wstring, 5> lenses{L"0.5x", L"1x", L"2x", L"3x", L"5x"};
    int left = cursor.left;
    for (size_t i = 0; i < lenses.size(); ++i) {
        RECT lens{left, cursor.top, left + 46, cursor.top + 34};
        DrawPill(hdc, lenses[i], lens, i == 1 ? gTheme.accent : RGB(255, 255, 255), i == 1 ? RGB(0, 122, 255) : RGB(224, 229, 236), i == 1 ? RGB(255, 255, 255) : gTheme.text, textFont);
        left += 50;
    }
    cursor.top += 54;

    DrawSectionTitle(hdc, L"Camera Source", cursor, smallFont);
    DrawMetric(hdc, L"Resolution", state.statistics.width > 0 ? std::to_wstring(state.statistics.width) + L"x" + std::to_wstring(state.statistics.height) : L"Auto", RECT{cursor.left, cursor.top, cursor.left + 118, cursor.top + 54}, smallFont, textFont);
    DrawMetric(hdc, L"FPS", state.statistics.decodedFps > 0 ? FormatDouble(state.statistics.decodedFps, 0) : L"30", RECT{cursor.left + 126, cursor.top, cursor.right, cursor.top + 54}, smallFont, textFont);
    cursor.top += 66;
    DrawMetric(hdc, L"Codec", state.statistics.videoCodec, RECT{cursor.left, cursor.top, cursor.left + 118, cursor.top + 54}, smallFont, textFont);
    DrawMetric(hdc, L"Stabilization", L"Cinematic", RECT{cursor.left + 126, cursor.top, cursor.right, cursor.top + 54}, smallFont, textFont);

    DeleteObject(titleFont);
    DeleteObject(textFont);
    DeleteObject(smallFont);
}

void App::DrawPreview(HDC hdc, const RECT& rect) {
    auto titleFont = CreateUiFont(22, FW_SEMIBOLD);
    auto textFont = CreateUiFont(14, FW_NORMAL);
    auto smallFont = CreateUiFont(12, FW_NORMAL);
    const auto state = receiver_.StateSnapshot();

    RECT canvas{rect.left + kLeftWidth + kGap, rect.top + kHeaderHeight + kGap, rect.right - kRightWidth - kGap, rect.bottom - kFooterHeight - kGap};
    RoundedFill(hdc, canvas, RGB(255, 255, 255), RGB(224, 229, 236), 10);

    RECT preview{canvas.left + 18, canvas.top + 18, canvas.right - 18, canvas.bottom - 72};
    RoundedFill(hdc, preview, gTheme.preview, RGB(218, 223, 231), 4);

    if (state.streamActive) {
        RECT signal{preview.left + 24, preview.top + 24, preview.right - 24, preview.bottom - 24};
        RoundedFill(hdc, signal, RGB(8, 9, 12), RGB(43, 145, 255), 4);
        DrawTextBlock(hdc, L"Receiving live stream", signal, gTheme.text, titleFont, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    } else {
        RECT icon{preview.left + (preview.right - preview.left) / 2 - 32, preview.top + (preview.bottom - preview.top) / 2 - 86, preview.left + (preview.right - preview.left) / 2 + 32, preview.top + (preview.bottom - preview.top) / 2 - 22};
        RoundedFill(hdc, icon, RGB(34, 39, 48), RGB(68, 78, 94), 14);
        DrawTextBlock(hdc, L"iPhone", RECT{preview.left, icon.bottom + 12, preview.right, icon.bottom + 44}, gTheme.text, titleFont, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        DrawTextBlock(hdc, state.connection == ConnectionState::Connected ? L"Waiting for iPhone video..." : L"No Camera Connected", RECT{preview.left, icon.bottom + 48, preview.right, icon.bottom + 76}, gTheme.muted, textFont, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        DrawTextBlock(hdc, state.status, RECT{preview.left + 40, icon.bottom + 78, preview.right - 40, icon.bottom + 112}, gTheme.dim, smallFont, DT_CENTER | DT_VCENTER | DT_WORDBREAK | DT_END_ELLIPSIS);
    }

    RECT toolbar{preview.left + 22, preview.bottom - 48, preview.right - 22, preview.bottom - 14};
    std::array<std::wstring, 8> tools{L"Fit", L"Fill", L"100%", L"Rotate", L"Mirror", L"Guides", L"Scopes", L"Fullscreen"};
    int x = toolbar.left;
    for (const auto& tool : tools) {
        RECT pill{x, toolbar.top, x + 82, toolbar.bottom};
        DrawPill(hdc, tool, pill, RGB(246, 248, 251), RGB(220, 226, 234), tool == L"Fill" ? gTheme.text : gTheme.muted, smallFont);
        x += 88;
        if (x + 82 > toolbar.right) {
            break;
        }
    }

    DeleteObject(titleFont);
    DeleteObject(textFont);
    DeleteObject(smallFont);
}

void App::DrawRightInspector(HDC hdc, const RECT& rect) {
    auto titleFont = CreateUiFont(15, FW_SEMIBOLD);
    auto textFont = CreateUiFont(13, FW_NORMAL);
    auto smallFont = CreateUiFont(12, FW_NORMAL);
    const auto state = receiver_.StateSnapshot();

    RECT inspector{rect.right - kRightWidth, rect.top + kHeaderHeight + kGap, rect.right - kGap, rect.bottom - kFooterHeight - kGap};
    RoundedFill(hdc, inspector, gTheme.surface, RGB(224, 229, 236), 10);

    RECT cursor{inspector.left + 16, inspector.top + 14, inspector.right - 16, inspector.bottom - 16};
    std::array<std::wstring, 5> tabs{L"CAMERA", L"IMAGE", L"SMART", L"MONITOR", L"PRESETS"};
    int tabX = cursor.left;
    for (size_t i = 0; i < tabs.size(); ++i) {
        RECT tab{tabX, cursor.top, tabX + 58, cursor.top + 28};
        const bool active = selectedInspectorTab_ == static_cast<int>(i);
        DrawPill(hdc, tabs[i], tab, active ? gTheme.accent : RGB(247, 249, 252), active ? gTheme.accent : RGB(224, 229, 236), active ? RGB(255, 255, 255) : gTheme.muted, smallFont);
        tabX += 62;
    }
    cursor.top += 46;

    if (selectedInspectorTab_ != 0) {
        if (selectedInspectorTab_ == 1) {
            DrawSectionTitle(hdc, L"Looks", cursor, smallFont);
            std::array<std::wstring, 6> looks{L"Natural", L"Clean", L"Warm", L"Cool", L"Cinema", L"Mono"};
            int lx = cursor.left;
            int ly = cursor.top;
            for (size_t i = 0; i < looks.size(); ++i) {
                RECT look{lx, ly, lx + 92, ly + 64};
                RoundedFill(hdc, look, i == 0 ? RGB(236, 244, 255) : RGB(255, 255, 255), i == 0 ? gTheme.accent : RGB(224, 229, 236), 10);
                RECT swatch{look.left + 10, look.top + 8, look.right - 10, look.top + 30};
                RoundedFill(hdc, swatch, i % 2 == 0 ? RGB(215, 226, 238) : RGB(238, 224, 209), CLR_INVALID, 6);
                DrawTextBlock(hdc, looks[i], RECT{look.left + 8, look.top + 34, look.right - 8, look.bottom - 6}, gTheme.text, smallFont, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
                lx += 100;
                if (lx + 92 > cursor.right) {
                    lx = cursor.left;
                    ly += 72;
                }
            }
            cursor.top = ly + 84;
            DrawSectionTitle(hdc, L"Adjustments", cursor, smallFont);
            DrawSlider(hdc, L"Exposure", L"0", 50, RECT{cursor.left, cursor.top, cursor.right, cursor.top + 40}, smallFont, textFont);
            cursor.top += 48;
            DrawSlider(hdc, L"Contrast", L"0", 50, RECT{cursor.left, cursor.top, cursor.right, cursor.top + 40}, smallFont, textFont);
            cursor.top += 48;
            DrawSlider(hdc, L"Saturation", L"0", 50, RECT{cursor.left, cursor.top, cursor.right, cursor.top + 40}, smallFont, textFont);
            cursor.top += 48;
            DrawSlider(hdc, L"Sharpness", L"0", 40, RECT{cursor.left, cursor.top, cursor.right, cursor.top + 40}, smallFont, textFont);
        } else if (selectedInspectorTab_ == 2) {
            DrawSectionTitle(hdc, L"Tracking", cursor, smallFont);
            std::array<std::wstring, 5> modes{L"Off", L"Face", L"Person", L"Group", L"Auto"};
            int mx = cursor.left;
            for (size_t i = 0; i < modes.size(); ++i) {
                RECT mode{mx, cursor.top, mx + 58, cursor.top + 30};
                DrawPill(hdc, modes[i], mode, i == 0 ? gTheme.accent : RGB(255, 255, 255), i == 0 ? gTheme.accent : RGB(224, 229, 236), i == 0 ? RGB(255, 255, 255) : gTheme.muted, smallFont);
                mx += 64;
            }
            cursor.top += 48;
            DrawSlider(hdc, L"Follow Speed", L"Medium", 55, RECT{cursor.left, cursor.top, cursor.right, cursor.top + 40}, smallFont, textFont);
            cursor.top += 48;
            DrawSlider(hdc, L"Smoothness", L"70", 70, RECT{cursor.left, cursor.top, cursor.right, cursor.top + 40}, smallFont, textFont);
            cursor.top += 56;
            DrawSectionTitle(hdc, L"Framing Presets", cursor, smallFont);
            std::array<std::wstring, 4> frames{L"Center", L"Left Third", L"Creator Portrait", L"Group"};
            for (const auto& frame : frames) {
                RECT item{cursor.left, cursor.top, cursor.right, cursor.top + 38};
                RoundedFill(hdc, item, RGB(255, 255, 255), RGB(224, 229, 236), 8);
                DrawTextBlock(hdc, frame, RECT{item.left + 12, item.top, item.right - 12, item.bottom}, gTheme.text, textFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
                cursor.top += 44;
            }
        } else if (selectedInspectorTab_ == 3) {
            DrawSectionTitle(hdc, L"Scopes", cursor, smallFont);
            std::array<std::wstring, 4> scopes{L"Histogram", L"Waveform", L"RGB Parade", L"Vectorscope"};
            for (const auto& scope : scopes) {
                RECT card{cursor.left, cursor.top, cursor.right, cursor.top + 76};
                RoundedFill(hdc, card, RGB(255, 255, 255), RGB(224, 229, 236), 8);
                DrawTextBlock(hdc, scope, RECT{card.left + 12, card.top + 8, card.right - 12, card.top + 28}, gTheme.text, textFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
                RECT graph{card.left + 12, card.top + 36, card.right - 12, card.bottom - 12};
                RoundedFill(hdc, graph, RGB(242, 244, 248), RGB(232, 235, 241), 6);
                cursor.top += 84;
            }
            DrawPill(hdc, L"Zebras", RECT{cursor.left, cursor.top, cursor.left + 84, cursor.top + 30}, RGB(255, 255, 255), RGB(224, 229, 236), gTheme.muted, smallFont);
            DrawPill(hdc, L"Peaking", RECT{cursor.left + 92, cursor.top, cursor.left + 180, cursor.top + 30}, RGB(255, 255, 255), RGB(224, 229, 236), gTheme.muted, smallFont);
            DrawPill(hdc, L"Grid", RECT{cursor.left + 188, cursor.top, cursor.left + 252, cursor.top + 30}, RGB(255, 255, 255), RGB(224, 229, 236), gTheme.muted, smallFont);
        } else {
            DrawSectionTitle(hdc, L"Preset Browser", cursor, smallFont);
            std::array<std::wstring, 10> presets{L"Max Quality", L"4K Cinema", L"1080p60 Pro", L"Creator Portrait", L"Talking Head", L"OBS Live", L"Interview", L"Product", L"Group", L"Low Light"};
            for (const auto& preset : presets) {
                RECT card{cursor.left, cursor.top, cursor.right, cursor.top + 52};
                RoundedFill(hdc, card, RGB(255, 255, 255), RGB(224, 229, 236), 8);
                RECT thumb{card.left + 10, card.top + 8, card.left + 58, card.bottom - 8};
                RoundedFill(hdc, thumb, RGB(232, 238, 246), CLR_INVALID, 6);
                DrawTextBlock(hdc, preset, RECT{thumb.right + 10, card.top + 6, card.right - 76, card.top + 28}, gTheme.text, textFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
                DrawTextBlock(hdc, L"Auto camera settings", RECT{thumb.right + 10, card.top + 28, card.right - 76, card.bottom - 6}, gTheme.dim, smallFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
                DrawPill(hdc, L"Apply", RECT{card.right - 64, card.top + 12, card.right - 10, card.bottom - 12}, RGB(236, 244, 255), RGB(174, 207, 247), gTheme.accent, smallFont);
                cursor.top += 58;
                if (cursor.top + 52 > cursor.bottom) {
                    break;
                }
            }
        }

        DeleteObject(titleFont);
        DeleteObject(textFont);
        DeleteObject(smallFont);
        return;
    }

    DrawSectionTitle(hdc, L"Exposure", cursor, smallFont);
    RECT card{cursor.left, cursor.top, cursor.right, cursor.top + 150};
    RoundedFill(hdc, card, gTheme.surfaceRaised, RGB(224, 229, 236), 10);
    RECT inner{card.left + 14, card.top + 12, card.right - 14, card.bottom - 12};
    DrawPill(hdc, L"Auto", RECT{inner.left, inner.top, inner.left + 62, inner.top + 28}, gTheme.accent, RGB(90, 175, 255), gTheme.text, smallFont);
    DrawPill(hdc, L"Manual", RECT{inner.left + 68, inner.top, inner.left + 144, inner.top + 28}, RGB(255, 255, 255), RGB(222, 226, 232), gTheme.muted, smallFont);
    DrawPill(hdc, L"Lock", RECT{inner.left + 150, inner.top, inner.left + 210, inner.top + 28}, RGB(255, 255, 255), RGB(222, 226, 232), gTheme.muted, smallFont);
    DrawSlider(hdc, L"EV", L"0.0", 50, RECT{inner.left, inner.top + 44, inner.right, inner.top + 84}, smallFont, textFont);
    DrawSlider(hdc, L"ISO", L"Auto", 30, RECT{inner.left, inner.top + 92, inner.right, inner.top + 132}, smallFont, textFont);
    cursor.top += 164;

    DrawSectionTitle(hdc, L"Focus", cursor, smallFont);
    RECT focus{cursor.left, cursor.top, cursor.right, cursor.top + 116};
    RoundedFill(hdc, focus, gTheme.surfaceRaised, RGB(224, 229, 236), 10);
    RECT focusInner{focus.left + 14, focus.top + 12, focus.right - 14, focus.bottom - 12};
    DrawPill(hdc, L"Continuous", RECT{focusInner.left, focusInner.top, focusInner.left + 98, focusInner.top + 28}, gTheme.accent, RGB(90, 175, 255), gTheme.text, smallFont);
    DrawPill(hdc, L"Manual", RECT{focusInner.left + 106, focusInner.top, focusInner.left + 180, focusInner.top + 28}, RGB(255, 255, 255), RGB(222, 226, 232), gTheme.muted, smallFont);
    DrawSlider(hdc, L"Lens", L"Auto", 45, RECT{focusInner.left, focusInner.top + 46, focusInner.right, focusInner.top + 86}, smallFont, textFont);
    cursor.top += 130;

    DrawSectionTitle(hdc, L"White Balance", cursor, smallFont);
    RECT wb{cursor.left, cursor.top, cursor.right, cursor.top + 116};
    RoundedFill(hdc, wb, gTheme.surfaceRaised, RGB(224, 229, 236), 10);
    RECT wbInner{wb.left + 14, wb.top + 12, wb.right - 14, wb.bottom - 12};
    DrawSlider(hdc, L"Temperature", L"Auto", 52, RECT{wbInner.left, wbInner.top, wbInner.right, wbInner.top + 40}, smallFont, textFont);
    DrawSlider(hdc, L"Tint", L"0", 50, RECT{wbInner.left, wbInner.top + 48, wbInner.right, wbInner.top + 88}, smallFont, textFont);
    cursor.top += 130;

    DrawSectionTitle(hdc, L"Presets", cursor, smallFont);
    std::array<std::wstring, 4> presets{L"4K Cinema", L"Creator Portrait", L"OBS Live", L"Low Light"};
    for (const auto& preset : presets) {
        RECT presetCard{cursor.left, cursor.top, cursor.right, cursor.top + 42};
        RoundedFill(hdc, presetCard, RGB(255, 255, 255), RGB(224, 229, 236), 8);
        DrawTextBlock(hdc, preset, RECT{presetCard.left + 12, presetCard.top, presetCard.right - 70, presetCard.bottom}, gTheme.text, textFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        DrawPill(hdc, L"Apply", RECT{presetCard.right - 62, presetCard.top + 7, presetCard.right - 10, presetCard.bottom - 7}, RGB(236, 244, 255), RGB(174, 207, 247), gTheme.accent, smallFont);
        cursor.top += 48;
    }

    RECT diag{cursor.left, std::min(cursor.top + 8, cursor.bottom - 64), cursor.right, cursor.bottom};
    RoundedFill(hdc, diag, RGB(249, 250, 252), RGB(224, 229, 236), 10);
    std::wstring diagText = L"Diagnostics   RX " + FormatDouble(state.statistics.receiveBitrateMbps, 2) +
        L" Mbps   TS " + std::to_wstring(state.statistics.transportPackets) +
        L"   Drop " + std::to_wstring(state.statistics.droppedFrames);
    DrawTextBlock(hdc, diagText, RECT{diag.left + 12, diag.top + 8, diag.right - 12, diag.bottom - 8}, gTheme.muted, smallFont, DT_LEFT | DT_VCENTER | DT_WORDBREAK | DT_END_ELLIPSIS);

    DeleteObject(titleFont);
    DeleteObject(textFont);
    DeleteObject(smallFont);
}

void App::DrawFooter(HDC hdc, const RECT& rect) {
    auto textFont = CreateUiFont(13, FW_NORMAL);
    auto valueFont = CreateUiFont(14, FW_SEMIBOLD);
    const auto state = receiver_.StateSnapshot();

    RECT footer{rect.left, rect.bottom - kFooterHeight, rect.right, rect.bottom};
    FillRectColor(hdc, footer, gTheme.header);

    RECT meter{footer.left + 18, footer.top + 14, footer.left + 150, footer.bottom - 14};
    RoundedFill(hdc, meter, RGB(255, 255, 255), RGB(224, 229, 236), 10);
    DrawTextBlock(hdc, state.audioPlaybackEnabled ? L"Mic On" : L"Mic Muted", RECT{meter.left + 12, meter.top, meter.right - 12, meter.bottom}, gTheme.text, textFont, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    DrawDot(hdc, meter.right - 18, meter.top + 18, state.audioPlaybackEnabled ? gTheme.green : gTheme.dim);

    const int center = (footer.left + footer.right) / 2;
    DrawButton(hdc, state.recordingEnabled ? L"Recording" : L"Record", RECT{center - 154, footer.top + 12, center - 46, footer.bottom - 12}, state.recordingEnabled ? gTheme.red : RGB(255, 255, 255), state.recordingEnabled ? RGB(255, 255, 255) : gTheme.text, valueFont);
    DrawButton(hdc, ConnectionText(state.connection), RECT{center - 34, footer.top + 12, center + 94, footer.bottom - 12}, state.connection == ConnectionState::Connected ? gTheme.green : RGB(255, 255, 255), state.connection == ConnectionState::Connected ? RGB(255, 255, 255) : gTheme.text, valueFont);
    DrawButton(hdc, L"Virtual Camera", RECT{center + 106, footer.top + 12, center + 244, footer.bottom - 12}, RGB(244, 246, 249), gTheme.dim, textFont, false);

    int chipRight = footer.right - 18;
    std::vector<std::pair<std::wstring, std::wstring>> chips{
        {L"RX", FormatDouble(state.statistics.receiveBitrateMbps, 2) + L" Mbps"},
        {L"RTT", FormatDouble(state.statistics.srtRttMs, 0) + L" ms"},
        {L"Frames", std::to_wstring(state.statistics.videoAccessUnits)},
        {L"Saved", FormatBytes(state.statistics.recordedBytes)}
    };
    for (auto it = chips.rbegin(); it != chips.rend(); ++it) {
        RECT chip{chipRight - 112, footer.top + 12, chipRight, footer.bottom - 12};
        DrawMetric(hdc, it->first, it->second, chip, textFont, valueFont);
        chipRight -= 120;
    }

    DeleteObject(textFont);
    DeleteObject(valueFont);
}

} // namespace procam
