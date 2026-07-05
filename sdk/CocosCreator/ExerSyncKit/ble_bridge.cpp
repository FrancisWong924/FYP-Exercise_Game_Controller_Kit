#include "ble_bridge.h"

#include "cocos/bindings/jswrapper/SeApi.h"
#include "cocos/plugins/Plugins.h"
#include "cocos/plugins/bus/EventBus.h"

#include <string>
#include <vector>
#include <windows.h>

namespace {

PROCESS_INFORMATION serverPi = {0};

static bool isTrackedServerAlive() {
    if (serverPi.hProcess == nullptr) {
        return false;
    }
    DWORD exitCode = STILL_ACTIVE;
    if (!GetExitCodeProcess(serverPi.hProcess, &exitCode)) {
        return false;
    }
    return exitCode == STILL_ACTIVE;
}

/** Directory of the quoted .exe in `"...exe" args` so the child cwd matches published layouts (native DLLs next to ExerSyncKitServer.exe). */
static std::string extractQuotedExeDirectory(const std::string& commandLine) {
    const size_t open = commandLine.find('"');
    if (open == std::string::npos) {
        return {};
    }
    const size_t close = commandLine.find('"', open + 1);
    if (close == std::string::npos || close <= open + 1) {
        return {};
    }
    const std::string exe = commandLine.substr(open + 1, close - open - 1);
    const size_t slash = exe.find_last_of("\\/");
    if (slash == std::string::npos) {
        return {};
    }
    return exe.substr(0, slash + 1);
}

static void clearServerProcessHandles() {
    if (serverPi.hThread != nullptr) {
        CloseHandle(serverPi.hThread);
        serverPi.hThread = nullptr;
    }
    if (serverPi.hProcess != nullptr) {
        CloseHandle(serverPi.hProcess);
        serverPi.hProcess = nullptr;
    }
}

struct CloseWindowTarget {
    DWORD pid = 0;
    bool posted = false;
};

static BOOL CALLBACK postWmCloseForPid(HWND hwnd, LPARAM lParam) {
    auto* target = reinterpret_cast<CloseWindowTarget*>(lParam);
    if (target == nullptr) {
        return TRUE;
    }
    DWORD windowPid = 0;
    GetWindowThreadProcessId(hwnd, &windowPid);
    if (windowPid == target->pid) {
        PostMessage(hwnd, WM_CLOSE, 0, 0);
        target->posted = true;
    }
    return TRUE;
}

static bool waitTrackedServerExit(DWORD timeoutMs) {
    if (serverPi.hProcess == nullptr) {
        return true;
    }
    const DWORD wait = WaitForSingleObject(serverPi.hProcess, timeoutMs);
    return wait == WAIT_OBJECT_0;
}

bool launchExternalExeImpl(const std::string& commandLine) {
    // Avoid a second ExerSyncKitServer while the first is still running: the C# server kills duplicate
    // processes and tears down WebSockets, which matches an immediate disconnect in the game.
    if (isTrackedServerAlive()) {
        return true;
    }
    clearServerProcessHandles();

    const std::string cwd = extractQuotedExeDirectory(commandLine);
    const char* cwdPtr = cwd.empty() ? nullptr : cwd.c_str();

    STARTUPINFOA si = {sizeof(si)};
    std::vector<char> cmd(commandLine.begin(), commandLine.end());
    cmd.push_back('\0');
    constexpr DWORD creationFlags = CREATE_NEW_PROCESS_GROUP;
    if (!CreateProcessA(nullptr, cmd.data(), nullptr, nullptr, FALSE, creationFlags, nullptr, cwdPtr, &si, &serverPi)) {
        return false;
    }

    CloseHandle(serverPi.hThread);
    serverPi.hThread = nullptr;

    // CreateProcess can succeed even if the child exits immediately (crash, missing runtime, wrong cwd).
    Sleep(300);
    DWORD exitCode = 0;
    if (!GetExitCodeProcess(serverPi.hProcess, &exitCode)) {
        clearServerProcessHandles();
        return false;
    }
    if (exitCode != STILL_ACTIVE) {
        OutputDebugStringA("[ble_bridge] ExerSyncKitServer exited shortly after launch (check deps, .NET runtime, and cwd).\n");
        clearServerProcessHandles();
        return false;
    }
    return true;
}

void closeExternalExeImpl() {
    if (serverPi.hProcess == nullptr) {
        return;
    }
    if (!isTrackedServerAlive()) {
        clearServerProcessHandles();
        return;
    }

    // 1) Graceful close for WPF window
    CloseWindowTarget target{serverPi.dwProcessId, false};
    EnumWindows(postWmCloseForPid, reinterpret_cast<LPARAM>(&target));
    if (target.posted && waitTrackedServerExit(1500)) {
        clearServerProcessHandles();
        return;
    }

    // 2) Graceful close for console-aware handlers (Program.CancelKeyPress)
    if (GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, serverPi.dwProcessId) && waitTrackedServerExit(1500)) {
        clearServerProcessHandles();
        return;
    }

    // 3) Last resort: hard kill to avoid orphan server instances.
    TerminateProcess(serverPi.hProcess, 0);
    waitTrackedServerExit(1000);
    clearServerProcessHandles();
    OutputDebugStringA("[ble_bridge] closeExternalExe: used TerminateProcess fallback.\n");
}

static bool js_launchExternalExe(se::State& s) {
    const auto& args = s.args();
    if (args.empty() || !args[0].isString()) {
        SE_REPORT_ERROR("launchExternalExe: expected string command line");
        s.rval().setBoolean(false);
        return false;
    }
    const bool ok = launchExternalExeImpl(args[0].toString());
    s.rval().setBoolean(ok);
    return true;
}
SE_BIND_FUNC(js_launchExternalExe)

static bool js_closeExternalExe(se::State& s) {
    closeExternalExeImpl();
    s.rval().setBoolean(!isTrackedServerAlive());
    return true;
}
SE_BIND_FUNC(js_closeExternalExe)

static bool js_isExternalExeAlive(se::State& s) {
    s.rval().setBoolean(isTrackedServerAlive());
    return true;
}
SE_BIND_FUNC(js_isExternalExeAlive)

static bool js_getGamePid(se::State& s) {
    s.rval().setUint32(GetCurrentProcessId());
    return true;
}
SE_BIND_FUNC(js_getGamePid)

static bool register_ble_bridge(se::Object* global) {
    global->defineFunction("launchExternalExe", _SE(js_launchExternalExe));
    global->defineFunction("closeExternalExe", _SE(js_closeExternalExe));
    global->defineFunction("isExternalExeAlive", _SE(js_isExternalExeAlive));
    global->defineFunction("getGamePid", _SE(js_getGamePid));
    return true;
}

static void ExerSyncKit_plugin_load() {
    using namespace cc::plugin;
    static Listener listener(BusType::SCRIPT_ENGINE);
    listener.receive([](ScriptEngineEvent event) {
        if (event == ScriptEngineEvent::POST_INIT) {
            se::ScriptEngine::getInstance()->addRegisterCallback(register_ble_bridge);
        }
    });
}

} // namespace

CC_PLUGIN_ENTRY(ExerSyncKit_glue, ExerSyncKit_plugin_load)
