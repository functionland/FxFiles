#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

// Send a constructed URI to a running FxFiles instance via WM_COPYDATA,
// using the same protocol as the app_links plugin (APPLINK_MSG_ID = WM_USER + 2).
bool SendUriToInstance(const std::wstring& title, const std::string& uri) {
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());
  if (!hwnd) return false;

  COPYDATASTRUCT cds = { 0 };
  cds.dwData = WM_USER + 2;  // APPLINK_MSG_ID
  cds.cbData = (DWORD)(uri.size() + 1);  // include null terminator
  cds.lpData = (PVOID)uri.c_str();
  ::SendMessage(hwnd, WM_COPYDATA, (WPARAM)hwnd, (LPARAM)&cds);

  // Restore window to front in same state
  WINDOWPLACEMENT place = { sizeof(WINDOWPLACEMENT) };
  GetWindowPlacement(hwnd, &place);

  switch(place.showCmd) {
    case SW_SHOWMAXIMIZED:
        ShowWindow(hwnd, SW_SHOWMAXIMIZED);
        break;
    case SW_SHOWMINIMIZED:
        ShowWindow(hwnd, SW_RESTORE);
        break;
    default:
        ShowWindow(hwnd, SW_NORMAL);
        break;
  }

  SetWindowPos(0, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
  SetForegroundWindow(hwnd);

  return true;
}

bool SendAppLinkToInstance(const std::wstring& title) {
  // Find our exact window
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());

  if (hwnd) {
    // Dispatch new link to current window via app_links plugin
    SendAppLink(hwnd);

    // Restore window to front in same state
    WINDOWPLACEMENT place = { sizeof(WINDOWPLACEMENT) };
    GetWindowPlacement(hwnd, &place);

    switch(place.showCmd) {
      case SW_SHOWMAXIMIZED:
          ShowWindow(hwnd, SW_SHOWMAXIMIZED);
          break;
      case SW_SHOWMINIMIZED:
          ShowWindow(hwnd, SW_RESTORE);
          break;
      default:
          ShowWindow(hwnd, SW_NORMAL);
          break;
    }

    SetWindowPos(0, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    SetForegroundWindow(hwnd);

    return true;
  }

  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {

  // --- Shell integration: detect --shell-upload / --shell-share arguments ---
  // When launched from Explorer context menu, argv looks like:
  //   FxFiles.exe --shell-upload "C:\Users\...\file.txt"
  // We convert this into a fxfiles:// URI for the deep link system.
  std::string shellUri;
  {
    int argc;
    wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
    if (argv && argc == 3) {
      std::string flag = Utf8FromUtf16(argv[1]);
      std::string path = Utf8FromUtf16(argv[2]);
      if (flag == "--shell-upload" || flag == "--shell-share") {
        std::string action = (flag == "--shell-upload") ? "upload" : "share";
        std::string encodedPath = UrlEncodeUtf8(path);
        shellUri = "fxfiles://shell/" + action + "?path=" + encodedPath;
      }
    }
    if (argv) ::LocalFree(argv);
  }

  if (!shellUri.empty()) {
    // Try forwarding to a running instance first
    if (SendUriToInstance(L"FxFiles", shellUri)) {
      return EXIT_SUCCESS;
    }
    // No running instance — fall through to cold start below
  } else {
    // Normal launch: if another instance is running, forward the URI to it
    if (SendAppLinkToInstance(L"FxFiles")) {
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // For shell invocations on cold start, replace args with the constructed URI
  // so Dart receives it via dart_entrypoint_arguments.
  // app_links won't pick this up from GetCommandLineW() since argc==3
  // (it expects argc==2), so there is no double-handling.
  if (!shellUri.empty()) {
    command_line_arguments.clear();
    command_line_arguments.push_back(shellUri);
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"FxFiles", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
