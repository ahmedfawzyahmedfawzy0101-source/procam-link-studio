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
    void DrawPanels(HDC hdc, const RECT& rect);
    void DrawPreview(HDC hdc, const RECT& rect);
    void DrawFooter(HDC hdc, const RECT& rect);

    ReceiverSession receiver_;
};

} // namespace procam
