// ecran_entrees.exe : tells the EcranReel Lua mod what the real mouse and keyboard are doing, so the avatar can copy them.
//
// It runs as its own hidden process because raw input registration is per process: registering inside the game would
// replace Unreal's own registration. It keeps only the present state (mouse movement since the last question, keys
// held down, keys pressed since the last question). Nothing is written anywhere and nothing is kept: a key is forgotten
// as soon as it is released and reported.
//
// Protocol, one line per question on two named pipes: the mod writes any line to \\.\pipe\ecranreel_q and reads
//   dx dy buttons|held,held|pressed,pressed
// from \\.\pipe\ecranreel_r. A key is its scan code, plus 0xE000 for extended keys.
// usage: ecran_entrees.exe <game pid>   (exits when that process ends)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#pragma comment(lib, "user32.lib")

namespace {

const int kMaxPressees = 16;

CRITICAL_SECTION g_verrou;
long long g_dx = 0, g_dy = 0;
int g_boutons = 0;
bool g_bas[0x200] = {};
int g_pressees[kMaxPressees];
int g_nbPressees = 0;

int Indice(int code) { return (code >= 0xE000) ? (code - 0xE000 + 0x100) & 0x1FF : code & 0xFF; }
int Code(int indice) { return indice >= 0x100 ? indice - 0x100 + 0xE000 : indice; }

void TraiterEntree(HRAWINPUT poignee) {
    UINT taille = 0;
    GetRawInputData(poignee, RID_INPUT, nullptr, &taille, sizeof(RAWINPUTHEADER));
    if (taille == 0 || taille > 256) return;
    BYTE tampon[256];
    if (GetRawInputData(poignee, RID_INPUT, tampon, &taille, sizeof(RAWINPUTHEADER)) != taille) return;
    const RAWINPUT* e = reinterpret_cast<const RAWINPUT*>(tampon);
    EnterCriticalSection(&g_verrou);
    if (e->header.dwType == RIM_TYPEMOUSE) {
        if (!(e->data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE)) {
            g_dx += e->data.mouse.lLastX;
            g_dy += e->data.mouse.lLastY;
        }
        const USHORT b = e->data.mouse.usButtonFlags;
        if (b & RI_MOUSE_LEFT_BUTTON_DOWN) g_boutons |= 1;
        if (b & RI_MOUSE_LEFT_BUTTON_UP) g_boutons &= ~1;
        if (b & RI_MOUSE_RIGHT_BUTTON_DOWN) g_boutons |= 2;
        if (b & RI_MOUSE_RIGHT_BUTTON_UP) g_boutons &= ~2;
    } else if (e->header.dwType == RIM_TYPEKEYBOARD) {
        int code = e->data.keyboard.MakeCode;
        if (e->data.keyboard.Flags & RI_KEY_E0) code += 0xE000;
        const bool relache = (e->data.keyboard.Flags & RI_KEY_BREAK) != 0;
        const int i = Indice(code);
        if (relache) {
            g_bas[i] = false;
        } else if (!g_bas[i]) {
            g_bas[i] = true;
            if (g_nbPressees < kMaxPressees) g_pressees[g_nbPressees++] = code;
        }
    }
    LeaveCriticalSection(&g_verrou);
}

std::string Reponse() {
    char ligne[64];
    EnterCriticalSection(&g_verrou);
    snprintf(ligne, sizeof(ligne), "%lld %lld %d|", g_dx, g_dy, g_boutons);
    std::string s = ligne;
    g_dx = g_dy = 0;
    bool premier = true;
    for (int i = 0; i < 0x200; ++i) {
        if (g_bas[i]) {
            s += (premier ? "" : ",") + std::to_string(Code(i));
            premier = false;
        }
    }
    s += "|";
    for (int i = 0; i < g_nbPressees; ++i) s += (i ? "," : "") + std::to_string(g_pressees[i]);
    g_nbPressees = 0;
    LeaveCriticalSection(&g_verrou);
    s += "\n";
    return s;
}

DWORD WINAPI Serveur(LPVOID) {
    for (;;) {
        HANDLE q = CreateNamedPipeW(L"\\\\.\\pipe\\ecranreel_q", PIPE_ACCESS_INBOUND, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                    1, 256, 256, 0, nullptr);
        HANDLE r = CreateNamedPipeW(L"\\\\.\\pipe\\ecranreel_r", PIPE_ACCESS_OUTBOUND, PIPE_TYPE_BYTE | PIPE_WAIT, 1, 4096, 256, 0,
                                    nullptr);
        if (q == INVALID_HANDLE_VALUE || r == INVALID_HANDLE_VALUE) {
            Sleep(1000);
            continue;
        }
        ConnectNamedPipe(q, nullptr);
        ConnectNamedPipe(r, nullptr);
        char c[64];
        DWORD lus = 0;
        while (ReadFile(q, c, sizeof(c), &lus, nullptr) && lus > 0) {
            const std::string s = Reponse();
            DWORD ecrits = 0;
            if (!WriteFile(r, s.data(), (DWORD)s.size(), &ecrits, nullptr)) break;
        }
        CloseHandle(q);
        CloseHandle(r);
    }
}

LRESULT CALLBACK Fenetre(HWND h, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_INPUT) {
        TraiterEntree(reinterpret_cast<HRAWINPUT>(l));
        return 0;
    }
    return DefWindowProcW(h, message, w, l);
}

DWORD WINAPI Gardien(LPVOID parent) {
    WaitForSingleObject(static_cast<HANDLE>(parent), INFINITE);
    ExitProcess(0);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR ligne, int) {
    const DWORD pid = wcstoul(ligne, nullptr, 10);
    HANDLE parent = pid ? OpenProcess(SYNCHRONIZE, FALSE, pid) : nullptr;
    if (!parent) return 1;
    CreateMutexW(nullptr, TRUE, L"ecranreel_entrees");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    InitializeCriticalSection(&g_verrou);
    WNDCLASSW classe = {};
    classe.lpfnWndProc = Fenetre;
    classe.hInstance = instance;
    classe.lpszClassName = L"EcranReelEntrees";
    RegisterClassW(&classe);
    HWND h = CreateWindowExW(0, classe.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, nullptr);
    if (!h) return 1;
    RAWINPUTDEVICE appareils[2] = {};
    appareils[0].usUsagePage = 1;
    appareils[0].usUsage = 2;  // mouse
    appareils[0].dwFlags = RIDEV_INPUTSINK;
    appareils[0].hwndTarget = h;
    appareils[1].usUsagePage = 1;
    appareils[1].usUsage = 6;  // keyboard
    appareils[1].dwFlags = RIDEV_INPUTSINK;
    appareils[1].hwndTarget = h;
    if (!RegisterRawInputDevices(appareils, 2, sizeof(RAWINPUTDEVICE))) return 1;

    CloseHandle(CreateThread(nullptr, 0, Gardien, parent, 0, nullptr));
    CloseHandle(CreateThread(nullptr, 0, Serveur, nullptr, 0, nullptr));
    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0) > 0) DispatchMessageW(&m);
    return 0;
}
