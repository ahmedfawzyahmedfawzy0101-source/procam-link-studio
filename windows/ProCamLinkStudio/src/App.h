#pragma once

#include "ReceiverSession.h"

#include <windows.h>

namespace procam {

class App {
public:
    int Run(HINSTANCE instance, int showCommand);

private:
    static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
    LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
    void Paint(HWND hwnd);
    void DrawHeader(HDC hdc, const RECT& rect);
    void DrawLeftSidebar(HDC hdc, const RECT& rect);
    void DrawPreview(HDC hdc, const RECT& rect);
    void DrawRightInspector(HDC hdc, const RECT& rect);
    void DrawFooter(HDC hdc, const RECT& rect);
    void HandleCommand(int commandId);
    void HandleClick(HWND hwnd, int x, int y);

    ReceiverSession receiver_;
    int discoveryTimerTicks_ = 0;
    bool showConnectDialog_ = false;
};

} // namespace procam
