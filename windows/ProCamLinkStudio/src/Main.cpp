#include "App.h"

#include <windows.h>

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    procam::App app;
    return app.Run(instance, showCommand);
}
