#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwctype>
#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

namespace {

// Case-insensitive equality for two Windows paths.
bool PathsEqualIgnoreCase(const std::wstring& a, const std::wstring& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (std::towlower(a[i]) != std::towlower(b[i])) return false;
  }
  return true;
}

// Full path of the executable hosting the current process.
std::wstring OwnExePath() {
  wchar_t buf[MAX_PATH];
  const DWORD len = ::GetModuleFileNameW(nullptr, buf, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) return std::wstring();
  return std::wstring(buf, len);
}

// Full image path of the process that owns [hwnd], or empty on failure.
std::wstring WindowProcessImagePath(HWND hwnd) {
  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) return std::wstring();
  HANDLE proc = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!proc) return std::wstring();
  wchar_t buf[MAX_PATH];
  DWORD len = MAX_PATH;
  std::wstring path;
  if (::QueryFullProcessImageNameW(proc, 0, buf, &len) && len > 0) {
    path.assign(buf, len);
  }
  ::CloseHandle(proc);
  return path;
}

struct FindContext {
  std::wstring ownExe;
  HWND found;
};

BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lparam) {
  // Only consider top-level Flutter windows of the same class our runner uses.
  wchar_t cls[64];
  const int clsLen = ::GetClassNameW(hwnd, cls, 64);
  if (clsLen <= 0) return TRUE; // continue enumeration
  if (std::wstring(cls, clsLen) != L"FLUTTER_RUNNER_WIN32_WINDOW") return TRUE;

  // Ignore hidden/tool windows; we want the main visible instance.
  if (!::IsWindowVisible(hwnd)) return TRUE;

  auto* ctx = reinterpret_cast<FindContext*>(lparam);
  const std::wstring procPath = WindowProcessImagePath(hwnd);
  if (procPath.empty()) return TRUE;
  if (!PathsEqualIgnoreCase(procPath, ctx->ownExe)) return TRUE;

  ctx->found = hwnd;
  return FALSE; // stop enumeration
}

// Locate the running FxFiles instance's main window by enumerating top-level
// windows and matching both the Flutter class name AND the owning process's
// executable path. Win10's classic context menu path was previously hitting
// ::FindWindow(class, title), which silently returned NULL when the running
// instance's title had been rewritten by the Flutter app (the title can
// change after launch as routes/screens update). EnumWindows with a process-
// path match is title-agnostic and works the same on Win10 and Win11.
HWND FindRunningInstance() {
  const std::wstring ownExe = OwnExePath();
  if (ownExe.empty()) return nullptr;
  FindContext ctx{ ownExe, nullptr };
  ::EnumWindows(EnumProc, reinterpret_cast<LPARAM>(&ctx));
  return ctx.found;
}

} // namespace

// Send a constructed URI to a running FxFiles instance via WM_COPYDATA,
// using the same protocol as the app_links plugin (APPLINK_MSG_ID = WM_USER + 2).
//
// Returns true ONLY when the running instance acknowledged the message
// within the timeout. On any failure (no instance, message blocked by UIPI,
// timeout) the caller falls through to cold-start launch so a click in
// Explorer's context menu never silently does nothing.
bool SendUriToInstance(const std::wstring& title, const std::string& uri) {
  (void)title; // legacy parameter — we now match by process path instead.
  HWND hwnd = FindRunningInstance();
  if (!hwnd) return false;

  COPYDATASTRUCT cds = { 0 };
  cds.dwData = WM_USER + 2;  // APPLINK_MSG_ID
  cds.cbData = (DWORD)(uri.size() + 1);  // include null terminator
  cds.lpData = (PVOID)uri.c_str();

  // SendMessageTimeout instead of SendMessage so a UIPI-blocked or
  // unresponsive target doesn't make us claim success. 2s is plenty for an
  // in-process message handler to ack.
  DWORD_PTR ack = 0;
  const LRESULT result = ::SendMessageTimeoutA(
      hwnd, WM_COPYDATA, /*wParam (source hwnd; nullable)*/ 0,
      (LPARAM)&cds, SMTO_NORMAL, 2000, &ack);
  if (result == 0) {
    // Timeout / send blocked / window died mid-call. Don't pretend success.
    return false;
  }

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
  (void)title; // legacy parameter — process-path match is title-agnostic.
  HWND hwnd = FindRunningInstance();

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

  // --- Shell integration: detect --shell-upload / --shell-share / --shell-collab arguments ---
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
      if (flag == "--shell-upload" || flag == "--shell-share" || flag == "--shell-collab" || flag == "--shell-accept-collab" || flag == "--shell-accept-share") {
        std::string action;
        if (flag == "--shell-upload") action = "upload";
        else if (flag == "--shell-share") action = "share";
        else if (flag == "--shell-collab") action = "collab";
        else if (flag == "--shell-accept-collab") action = "accept-collab";
        else action = "accept-share";
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
