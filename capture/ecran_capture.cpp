// ecran_capture.dll : shows a chosen picture source in the render target the EcranReel Lua mod puts on the in-game screens.
//
// Sources: a whole monitor (Desktop Duplication), one application window (Windows.Graphics.Capture) or a video file
// (Media Foundation, with its sound).
//
// How the picture gets in, without touching the game's own D3D11 context:
//  1. A vtable patch on ID3D11Device::CreateTexture2D recognises the mod's render target by its odd size
//     (1279x721) and creates it with D3D11_RESOURCE_MISC_SHARED.
//  2. This DLL has its own D3D11 device on its own thread. It opens the shared texture and draws the source into it,
//     scaled, with black bars when the shapes differ.
//
// Files next to the DLL:
//   ecran_reel.ini   settings (UTF-8, key=value), written by the Lua mod, re-read while running
//   actif.txt        written by the Lua mod during the Gaming activity; no file = no capture
//   lister.txt       request: write the monitors and windows into fenetres.txt
//   parcourir.txt    request: open the file dialog, the result goes into video_choisie.txt
//   etat.txt         one line for the menu: what is shown, or why it is not
//   pret.txt         the hook is armed
//   capture.log      diagnostics
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11_4.h>
#include <d3dcompiler.h>
#include <dwmapi.h>
#include <dxgi1_6.h>
#include <mfapi.h>
#include <mfmediaengine.h>
#include <psapi.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <inspectable.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/base.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "windowsapp.lib")

using Microsoft::WRL::ComPtr;
namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgd = winrt::Windows::Graphics::DirectX;

namespace {

const UINT kLargeurCible = 1279;
const UINT kHauteurCible = 721;
const int kIndexCreateTexture2D = 5;

std::wstring g_dossier;
std::atomic<HANDLE> g_poignee{nullptr};
std::atomic<UINT> g_images{0};

using CreateTexture2D_t = HRESULT(STDMETHODCALLTYPE*)(ID3D11Device*, const D3D11_TEXTURE2D_DESC*,
                                                      const D3D11_SUBRESOURCE_DATA*, ID3D11Texture2D**);
CreateTexture2D_t g_original = nullptr;

void Journal(const char* format, ...) {
    char ligne[600];
    va_list args;
    va_start(args, format);
    vsnprintf(ligne, sizeof(ligne), format, args);
    va_end(args);
    SYSTEMTIME t;
    GetLocalTime(&t);
    FILE* f = nullptr;
    if (_wfopen_s(&f, (g_dossier + L"capture.log").c_str(), L"a") == 0 && f) {
        fprintf(f, "%02d:%02d:%02d %s\n", t.wHour, t.wMinute, t.wSecond, ligne);
        fclose(f);
    }
}

std::string VersUtf8(const std::wstring& s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string r(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), r.data(), n, nullptr, nullptr);
    return r;
}

std::wstring DepuisUtf8(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring r(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), r.data(), n);
    return r;
}

bool Existe(const wchar_t* nom) { return GetFileAttributesW((g_dossier + nom).c_str()) != INVALID_FILE_ATTRIBUTES; }

void EcrireFichier(const wchar_t* nom, const std::string& contenu) {
    std::wstring chemin = g_dossier + nom, tmp = chemin + L".tmp";
    FILE* f = nullptr;
    if (_wfopen_s(&f, tmp.c_str(), L"wb") == 0 && f) {
        fwrite(contenu.data(), 1, contenu.size(), f);
        fclose(f);
        MoveFileExW(tmp.c_str(), chemin.c_str(), MOVEFILE_REPLACE_EXISTING);
    }
}

void DireEtat(const std::string& etat) {
    static std::string dernier;
    if (etat != dernier) {
        dernier = etat;
        EcrireFichier(L"etat.txt", etat + "\n");
    }
}

// ------------------------------------------------------------------------ settings

struct Reglages {
    std::string source = "ecran";  // ecran, fenetre, video, aucune
    int ecran = 1;
    int ips = 30;
    int mains = 0;
    int video_son = 1;
    std::string fenetre_titre, fenetre_exe, video;
    bool operator==(const Reglages&) const = default;
};

// False while the file cannot be read: the Lua mod replaces it by a rename, this must not look like a change of source.
bool LireReglages(Reglages& r) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, (g_dossier + L"ecran_reel.ini").c_str(), L"rb") != 0 || !f) return false;
    std::string texte;
    char tampon[4096];
    size_t lus;
    while ((lus = fread(tampon, 1, sizeof(tampon), f)) > 0) texte.append(tampon, lus);
    fclose(f);
    size_t debut = 0;
    while (debut < texte.size()) {
        size_t fin = texte.find('\n', debut);
        if (fin == std::string::npos) fin = texte.size();
        std::string ligne = texte.substr(debut, fin - debut);
        debut = fin + 1;
        if (!ligne.empty() && ligne.back() == '\r') ligne.pop_back();
        if (ligne.empty() || ligne[0] == ';' || ligne[0] == '[') continue;
        size_t egal = ligne.find('=');
        if (egal == std::string::npos) continue;
        std::string cle = ligne.substr(0, egal), valeur = ligne.substr(egal + 1);
        if (cle == "source") r.source = valeur;
        else if (cle == "numero") r.ecran = atoi(valeur.c_str());
        else if (cle == "images_par_seconde") r.ips = std::clamp(atoi(valeur.c_str()), 1, 120);
        else if (cle == "mains") r.mains = atoi(valeur.c_str());
        else if (cle == "video_son") r.video_son = atoi(valeur.c_str());
        else if (cle == "fenetre_titre") r.fenetre_titre = valeur;
        else if (cle == "fenetre_exe") r.fenetre_exe = valeur;
        else if (cle == "video") r.video = valeur;
    }
    return true;
}

// ------------------------------------------------------------------------ hook

HRESULT STDMETHODCALLTYPE CreateTexture2D_Crochet(ID3D11Device* self, const D3D11_TEXTURE2D_DESC* desc,
                                                  const D3D11_SUBRESOURCE_DATA* init, ID3D11Texture2D** sortie) {
    if (desc && sortie && desc->Width == kLargeurCible && desc->Height == kHauteurCible &&
        (desc->BindFlags & D3D11_BIND_RENDER_TARGET)) {
        D3D11_TEXTURE2D_DESC d = *desc;
        d.MiscFlags |= D3D11_RESOURCE_MISC_SHARED;
        HRESULT hr = g_original(self, &d, init, sortie);
        if (SUCCEEDED(hr) && *sortie) {
            ComPtr<IDXGIResource> ressource;
            HANDLE poignee = nullptr;
            if (SUCCEEDED((*sortie)->QueryInterface(IID_PPV_ARGS(&ressource))) &&
                SUCCEEDED(ressource->GetSharedHandle(&poignee))) {
                g_poignee.store(poignee);
            }
            Journal("cible vue : format %d, mips %u, poignee %p", (int)d.Format, d.MipLevels, poignee);
            return hr;
        }
        Journal("creation partagee refusee : %#x", (unsigned)hr);
    }
    return g_original(self, desc, init, sortie);
}

bool PatcherVtable(ID3D11Device* device) {
    void** table = *reinterpret_cast<void***>(device);
    DWORD ancien = 0;
    if (!VirtualProtect(&table[kIndexCreateTexture2D], sizeof(void*), PAGE_READWRITE, &ancien)) return false;
    g_original = reinterpret_cast<CreateTexture2D_t>(table[kIndexCreateTexture2D]);
    table[kIndexCreateTexture2D] = reinterpret_cast<void*>(&CreateTexture2D_Crochet);
    VirtualProtect(&table[kIndexCreateTexture2D], sizeof(void*), ancien, &ancien);
    return true;
}

DXGI_FORMAT FormatEcriture(DXGI_FORMAT f) {
    switch (f) {
        case DXGI_FORMAT_B8G8R8A8_TYPELESS:
        case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
            return DXGI_FORMAT_B8G8R8A8_UNORM;
        case DXGI_FORMAT_R8G8B8A8_TYPELESS:
        case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
            return DXGI_FORMAT_R8G8B8A8_UNORM;
        default:
            return f;
    }
}

// ------------------------------------------------------------------------ windows of the desktop

std::wstring ExeDeFenetre(HWND h) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return L"";
    wchar_t chemin[MAX_PATH];
    DWORD taille = MAX_PATH;
    std::wstring r;
    if (QueryFullProcessImageNameW(p, 0, chemin, &taille)) {
        r = chemin;
        r = r.substr(r.find_last_of(L'\\') + 1);
    }
    CloseHandle(p);
    return r;
}

struct Fenetre {
    HWND h;
    std::wstring titre, exe;
};

BOOL CALLBACK RappelFenetres(HWND h, LPARAM l) {
    auto* liste = reinterpret_cast<std::vector<Fenetre>*>(l);
    if (!IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return TRUE;
    if (GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return TRUE;
    DWORD masquee = 0;
    DwmGetWindowAttribute(h, DWMWA_CLOAKED, &masquee, sizeof(masquee));
    if (masquee) return TRUE;
    wchar_t titre[256];
    if (GetWindowTextW(h, titre, 256) == 0) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid == GetCurrentProcessId()) return TRUE;  // the game filming itself is what the monitor choice is for
    liste->push_back({h, titre, ExeDeFenetre(h)});
    return TRUE;
}

std::vector<Fenetre> ListerFenetres() {
    std::vector<Fenetre> liste;
    EnumWindows(RappelFenetres, reinterpret_cast<LPARAM>(&liste));
    return liste;
}

HWND TrouverFenetre(const Reglages& r) {
    const std::wstring titre = DepuisUtf8(r.fenetre_titre), exe = DepuisUtf8(r.fenetre_exe);
    HWND meme_exe = nullptr;
    for (const Fenetre& f : ListerFenetres()) {
        if (f.titre == titre && (exe.empty() || f.exe == exe)) return f.h;
        if (!meme_exe && !exe.empty() && f.exe == exe) meme_exe = f.h;
    }
    return meme_exe;  // a browser's title changes with its page: the same program is the same choice
}

void EcrireListe(ID3D11Device* device) {
    std::string texte;
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIAdapter> adaptateur;
    if (SUCCEEDED(device->QueryInterface(IID_PPV_ARGS(&dxgi))) && SUCCEEDED(dxgi->GetAdapter(&adaptateur))) {
        ComPtr<IDXGIOutput> sortie;
        for (UINT i = 0; adaptateur->EnumOutputs(i, sortie.ReleaseAndGetAddressOf()) != DXGI_ERROR_NOT_FOUND; ++i) {
            DXGI_OUTPUT_DESC d;
            sortie->GetDesc(&d);
            int numero = 0;
            swscanf_s(d.DeviceName, L"\\\\.\\DISPLAY%d", &numero);
            char ligne[96];
            snprintf(ligne, sizeof(ligne), "E\t%d\t%ldx%ld\n", numero, d.DesktopCoordinates.right - d.DesktopCoordinates.left,
                     d.DesktopCoordinates.bottom - d.DesktopCoordinates.top);
            texte += ligne;
        }
    }
    for (const Fenetre& f : ListerFenetres()) {
        std::wstring titre = f.titre;
        std::replace(titre.begin(), titre.end(), L'\t', L' ');
        std::replace(titre.begin(), titre.end(), L'\n', L' ');
        texte += "F\t" + VersUtf8(f.exe) + "\t" + VersUtf8(titre) + "\n";
    }
    EcrireFichier(L"fenetres.txt", texte);
}

// ------------------------------------------------------------------------ the keyboard and mouse reader

class LecteurEntrees {
   public:
    void Regler(bool voulu) {
        if (voulu == (processus_ != nullptr)) return;
        if (voulu) {
            wchar_t ligne[64];
            swprintf_s(ligne, L"ecran_entrees.exe %lu", GetCurrentProcessId());
            std::wstring chemin = g_dossier + L"ecran_entrees.exe";
            STARTUPINFOW si = {};
            si.cb = sizeof(si);
            PROCESS_INFORMATION pi = {};
            if (CreateProcessW(chemin.c_str(), ligne, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, g_dossier.c_str(), &si, &pi)) {
                CloseHandle(pi.hThread);
                processus_ = pi.hProcess;
                Journal("lecteur d'entrees lance");
            } else {
                Journal("lecteur d'entrees refuse : %lu", GetLastError());
            }
        } else {
            TerminateProcess(processus_, 0);
            CloseHandle(processus_);
            processus_ = nullptr;
            Journal("lecteur d'entrees arrete");
        }
    }

   private:
    HANDLE processus_ = nullptr;
};

// ------------------------------------------------------------------------ file dialog, on its own thread

std::atomic<bool> g_dialogue_ouvert{false};

HWND FenetreDuJeu() {
    struct Cherche {
        HWND h = nullptr;
        LONG surface = 0;
    } c;
    EnumWindows(
        [](HWND h, LPARAM l) -> BOOL {
            DWORD pid = 0;
            GetWindowThreadProcessId(h, &pid);
            if (pid == GetCurrentProcessId() && IsWindowVisible(h)) {
                RECT r;
                GetWindowRect(h, &r);
                auto* c = reinterpret_cast<Cherche*>(l);
                LONG s = (r.right - r.left) * (r.bottom - r.top);
                if (s > c->surface) {
                    c->surface = s;
                    c->h = h;
                }
            }
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&c));
    return c.h;
}

DWORD WINAPI Dialogue(LPVOID) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    ComPtr<IFileOpenDialog> d;
    if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&d)))) {
        COMDLG_FILTERSPEC filtres[] = {{L"Video", L"*.mp4;*.mkv;*.webm;*.mov;*.avi;*.wmv;*.m4v"}, {L"*", L"*.*"}};
        d->SetFileTypes(2, filtres);
        if (SUCCEEDED(d->Show(FenetreDuJeu()))) {
            ComPtr<IShellItem> element;
            PWSTR chemin = nullptr;
            if (SUCCEEDED(d->GetResult(&element)) && SUCCEEDED(element->GetDisplayName(SIGDN_FILESYSPATH, &chemin))) {
                EcrireFichier(L"video_choisie.txt", VersUtf8(chemin) + "\n");
                CoTaskMemFree(chemin);
            }
        }
    }
    CoUninitialize();
    g_dialogue_ouvert = false;
    return 0;
}

// ------------------------------------------------------------------------ video

class AvisVideo : public IMFMediaEngineNotify {
   public:
    STDMETHODIMP QueryInterface(REFIID id, void** p) override {
        if (id == __uuidof(IUnknown) || id == __uuidof(IMFMediaEngineNotify)) {
            *p = static_cast<IMFMediaEngineNotify*>(this);
            AddRef();
            return S_OK;
        }
        *p = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return ++references_; }
    STDMETHODIMP_(ULONG) Release() override {
        ULONG n = --references_;
        if (n == 0) delete this;
        return n;
    }
    STDMETHODIMP EventNotify(DWORD evenement, DWORD_PTR p1, DWORD p2) override {
        if (evenement == MF_MEDIA_ENGINE_EVENT_ERROR) {
            Journal("video refusee : erreur %u, %#x", (unsigned)p1, p2);
            erreur = true;
        }
        return S_OK;
    }
    std::atomic<bool> erreur{false};

   private:
    std::atomic<ULONG> references_{1};
};

// ------------------------------------------------------------------------ capture

const char kShader[] = R"(
Texture2D source : register(t0);
SamplerState lisseur : register(s0);
cbuffer Constantes : register(b0) { float niveau; float3 inutilise; };
struct Sommet { float4 position : SV_Position; float2 uv : TEXCOORD0; };
Sommet vs(uint i : SV_VertexID) {
    Sommet s;
    s.uv = float2((i << 1) & 2, i & 2);
    s.position = float4(s.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return s;
}
float4 ps(Sommet s) : SV_Target {
    float4 c = source.SampleLevel(lisseur, s.uv, niveau);
    c.a = 1;
    return c;
}
)";

class Capture {
   public:
    bool Demarrer(ID3D11Device* device, ID3D11DeviceContext* contexte) {
        device_ = device;
        contexte_ = contexte;
        return PreparerDessin();
    }

    void Tour() {
        RelireReglages();
        TraiterDemandes();
        OuvrirCible();
        const DWORD debut = GetTickCount();
        if (!rtv_) {
            Sleep(100);
            return;
        }
        // A minimized game draws nothing: no need to film for it. A video with its sound goes on, the player is listening.
        const bool ecoute = r_.source == "video" && r_.video_son != 0;
        if (!Existe(L"actif.txt") || r_.source == "aucune" || (!ecoute && JeuReduit())) {
            Suspendre();
            Sleep(150);
            return;
        }
        bool nouvelle = false;
        if (r_.source == "fenetre") nouvelle = TourFenetre();
        else if (r_.source == "video") nouvelle = TourVideo();
        else nouvelle = TourEcran();
        if (nouvelle) Dessiner();
        const DWORD intervalle = 1000 / r_.ips;
        const DWORD ecoule = GetTickCount() - debut;
        if (ecoule < intervalle) Sleep(intervalle - ecoule);
    }

   private:
    // ---------------- the game's own window

    static BOOL CALLBACK NoterFenetreDuJeu(HWND h, LPARAM donnee) {
        DWORD pid = 0;
        GetWindowThreadProcessId(h, &pid);
        if (pid != GetCurrentProcessId() || !IsWindowVisible(h)) return TRUE;
        bool* reduit = reinterpret_cast<bool*>(donnee);
        *reduit = IsIconic(h) != FALSE;
        // The game has one real window: a shown, not minimized one settles it.
        return *reduit ? TRUE : FALSE;
    }

    bool JeuReduit() {
        const DWORD maintenant = GetTickCount();
        if (maintenant - dernier_regard_fenetre_ >= 500) {
            dernier_regard_fenetre_ = maintenant;
            bool reduit = false;
            EnumWindows(NoterFenetreDuJeu, reinterpret_cast<LPARAM>(&reduit));
            if (reduit != jeu_reduit_) {
                jeu_reduit_ = reduit;
                Journal(reduit ? "jeu reduit : capture en pause" : "jeu rouvert : capture reprise");
            }
        }
        return jeu_reduit_;
    }

    // ---------------- settings and requests

    void RelireReglages() {
        const DWORD maintenant = GetTickCount();
        if (maintenant - derniere_lecture_ < 300) return;
        derniere_lecture_ = maintenant;
        Reglages nouveaux;
        if (!LireReglages(nouveaux)) return;
        lecteur_.Regler(nouveaux.mains != 0);
        if (!(nouveaux == r_)) {
            const bool meme_source = nouveaux.source == r_.source && nouveaux.ecran == r_.ecran && nouveaux.fenetre_titre == r_.fenetre_titre &&
                                     nouveaux.fenetre_exe == r_.fenetre_exe && nouveaux.video == r_.video;
            if (moteur_ && nouveaux.video_son != r_.video_son) moteur_->SetMuted(nouveaux.video_son == 0);
            r_ = nouveaux;
            if (!meme_source) {
                FermerSources();
                Journal("source : %s", r_.source.c_str());
            }
        }
    }

    void TraiterDemandes() {
        if (Existe(L"lister.txt")) {
            DeleteFileW((g_dossier + L"lister.txt").c_str());
            EcrireListe(device_.Get());
        }
        if (Existe(L"parcourir.txt")) {
            DeleteFileW((g_dossier + L"parcourir.txt").c_str());
            if (!g_dialogue_ouvert.exchange(true)) {
                HANDLE fil = CreateThread(nullptr, 0, Dialogue, nullptr, 0, nullptr);
                if (fil) CloseHandle(fil);
                else g_dialogue_ouvert = false;
            }
        }
    }

    void FermerSources() {
        duplication_.Reset();
        FermerFenetre();
        FermerVideo();
        source_.Reset();
        vue_source_.Reset();
    }

    void Suspendre() {
        duplication_.Reset();
        FermerFenetre();
        if (moteur_ && !video_en_pause_) {
            moteur_->Pause();
            video_en_pause_ = true;
        }
    }

    void OuvrirCible() {
        HANDLE poignee = g_poignee.load();
        if (poignee == poignee_ouverte_ || !poignee) return;
        cible_.Reset();
        rtv_.Reset();
        poignee_ouverte_ = poignee;
        HRESULT hr = device_->OpenSharedResource(poignee, IID_PPV_ARGS(&cible_));
        if (FAILED(hr)) {
            Journal("ouverture de la cible refusee : %#x", (unsigned)hr);
            return;
        }
        D3D11_TEXTURE2D_DESC d;
        cible_->GetDesc(&d);
        D3D11_RENDER_TARGET_VIEW_DESC vue = {};
        vue.Format = FormatEcriture(d.Format);
        vue.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
        hr = device_->CreateRenderTargetView(cible_.Get(), &vue, &rtv_);
        largeur_cible_ = d.Width;
        hauteur_cible_ = d.Height;
        Journal("cible ouverte : %ux%u format %d, resultat %#x", d.Width, d.Height, (int)d.Format, (unsigned)hr);
        if (a_dessine_) Dessiner();  // a new texture after a map change: no black screen until the next frame
    }

    // ---------------- whole monitor

    bool CreerDuplication() {
        ComPtr<IDXGIDevice> dxgi;
        ComPtr<IDXGIAdapter> adaptateur;
        if (FAILED(device_.As(&dxgi)) || FAILED(dxgi->GetAdapter(&adaptateur))) return false;
        wchar_t attendu[32];
        swprintf_s(attendu, L"\\\\.\\DISPLAY%d", r_.ecran);
        ComPtr<IDXGIOutput> trouve, premier, sortie;
        for (UINT i = 0; adaptateur->EnumOutputs(i, sortie.ReleaseAndGetAddressOf()) != DXGI_ERROR_NOT_FOUND; ++i) {
            DXGI_OUTPUT_DESC d;
            sortie->GetDesc(&d);
            if (wcscmp(d.DeviceName, attendu) == 0) trouve = sortie;
            if (i == 0) premier = sortie;
        }
        if (!trouve) trouve = premier;
        if (!trouve) return false;
        const DXGI_FORMAT formats[] = {DXGI_FORMAT_B8G8R8A8_UNORM};
        ComPtr<IDXGIOutput5> sortie5;
        HRESULT hr = E_FAIL;
        if (SUCCEEDED(trouve.As(&sortie5))) hr = sortie5->DuplicateOutput1(device_.Get(), 0, 1, formats, &duplication_);
        if (FAILED(hr)) {
            ComPtr<IDXGIOutput1> sortie1;
            if (SUCCEEDED(trouve.As(&sortie1))) hr = sortie1->DuplicateOutput(device_.Get(), &duplication_);
        }
        if (FAILED(hr)) {
            duplication_.Reset();
            DireEtat("ecran_refuse");
            return false;
        }
        DXGI_OUTDUPL_DESC d;
        duplication_->GetDesc(&d);
        Journal("capture de l'ecran %d : %ux%u", r_.ecran, d.ModeDesc.Width, d.ModeDesc.Height);
        DireEtat("ok");
        return PreparerSource(d.ModeDesc.Width, d.ModeDesc.Height, d.ModeDesc.Format);
    }

    bool TourEcran() {
        if (!duplication_ && !CreerDuplication()) {
            Sleep(800);
            return false;
        }
        DXGI_OUTDUPL_FRAME_INFO info = {};
        ComPtr<IDXGIResource> ressource;
        HRESULT hr = duplication_->AcquireNextFrame(1000 / r_.ips * 3, &info, &ressource);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) return false;
        if (FAILED(hr)) {
            Journal("capture perdue : %#x, on recommence", (unsigned)hr);
            duplication_.Reset();
            Sleep(500);
            return false;
        }
        bool nouvelle = false;
        if (info.LastPresentTime.QuadPart != 0) {
            ComPtr<ID3D11Texture2D> image;
            if (SUCCEEDED(ressource.As(&image)) && source_) {
                contexte_->CopySubresourceRegion(source_.Get(), 0, 0, 0, 0, image.Get(), 0, nullptr);
                nouvelle = true;
            }
        }
        duplication_->ReleaseFrame();
        return nouvelle;
    }

    // ---------------- one window

    void FermerFenetre() {
        try {
            if (session_) session_.Close();
            if (pool_) pool_.Close();
        } catch (const winrt::hresult_error&) {
        }
        session_ = nullptr;
        pool_ = nullptr;
        fenetre_ = nullptr;
    }

    bool OuvrirFenetre() {
        const DWORD maintenant = GetTickCount();
        if (maintenant - dernier_essai_fenetre_ < 1500) return false;
        dernier_essai_fenetre_ = maintenant;
        HWND h = TrouverFenetre(r_);
        if (!h) {
            DireEtat("fenetre_absente");
            return false;
        }
        try {
            if (!wgc::GraphicsCaptureSession::IsSupported()) {
                DireEtat("fenetre_impossible");
                return false;
            }
            if (!appareil_winrt_) {
                ComPtr<IDXGIDevice> dxgi;
                device_.As(&dxgi);
                winrt::com_ptr<::IInspectable> inspectable;
                winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put()));
                appareil_winrt_ = inspectable.as<wgd::Direct3D11::IDirect3DDevice>();
            }
            auto usine = winrt::get_activation_factory<wgc::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
            wgc::GraphicsCaptureItem element{nullptr};
            winrt::check_hresult(usine->CreateForWindow(h, winrt::guid_of<wgc::GraphicsCaptureItem>(), winrt::put_abi(element)));
            taille_fenetre_ = element.Size();
            pool_ = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(appareil_winrt_, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2,
                                                                        taille_fenetre_);
            session_ = pool_.CreateCaptureSession(element);
            try {
                session_.IsBorderRequired(false);  // no yellow frame around the window, Windows 11 only
            } catch (const winrt::hresult_error&) {
            }
            session_.StartCapture();
            fenetre_ = h;
            Journal("capture d'une fenetre : %dx%d", taille_fenetre_.Width, taille_fenetre_.Height);
            DireEtat("ok");
            return true;
        } catch (const winrt::hresult_error& e) {
            Journal("fenetre refusee : %#x", (unsigned)e.code());
            DireEtat("fenetre_refusee");
            FermerFenetre();
            return false;
        }
    }

    bool TourFenetre() {
        if (fenetre_ && !IsWindow(fenetre_)) {
            Journal("fenetre fermee");
            FermerFenetre();
        }
        if (!session_ && !OuvrirFenetre()) {
            Sleep(100);
            return false;
        }
        try {
            auto image = pool_.TryGetNextFrame();
            if (!image) return false;
            auto taille = image.ContentSize();
            if (taille.Width != taille_fenetre_.Width || taille.Height != taille_fenetre_.Height) {
                taille_fenetre_ = taille;
                pool_.Recreate(appareil_winrt_, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, taille_fenetre_);
            }
            if (taille.Width <= 0 || taille.Height <= 0) return false;
            if (!PreparerSource(taille.Width, taille.Height, DXGI_FORMAT_B8G8R8A8_UNORM)) return false;
            auto acces = image.Surface().as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            ComPtr<ID3D11Texture2D> texture;
            winrt::check_hresult(acces->GetInterface(IID_PPV_ARGS(&texture)));
            D3D11_BOX boite = {0, 0, 0, (UINT)taille.Width, (UINT)taille.Height, 1};
            contexte_->CopySubresourceRegion(source_.Get(), 0, 0, 0, 0, texture.Get(), 0, &boite);
            return true;
        } catch (const winrt::hresult_error& e) {
            Journal("fenetre perdue : %#x", (unsigned)e.code());
            FermerFenetre();
            return false;
        }
    }

    // ---------------- video file

    void FermerVideo() {
        if (moteur_) moteur_->Shutdown();
        moteur_.Reset();
        if (avis_) avis_->Release();
        avis_ = nullptr;
        video_en_pause_ = false;
    }

    bool OuvrirVideo() {
        const DWORD maintenant = GetTickCount();
        if (maintenant - dernier_essai_video_ < 3000) return false;
        dernier_essai_video_ = maintenant;
        const std::wstring chemin = DepuisUtf8(r_.video);
        if (chemin.empty() || GetFileAttributesW(chemin.c_str()) == INVALID_FILE_ATTRIBUTES) {
            DireEtat("video_absente");
            return false;
        }
        if (!gestionnaire_) {
            UINT jeton = 0;
            if (FAILED(MFCreateDXGIDeviceManager(&jeton, &gestionnaire_)) || FAILED(gestionnaire_->ResetDevice(device_.Get(), jeton))) {
                gestionnaire_.Reset();
                DireEtat("video_impossible");
                return false;
            }
        }
        ComPtr<IMFMediaEngineClassFactory> usine;
        ComPtr<IMFAttributes> attributs;
        if (FAILED(CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&usine))) ||
            FAILED(MFCreateAttributes(&attributs, 3))) {
            DireEtat("video_impossible");
            return false;
        }
        avis_ = new AvisVideo();
        attributs->SetUnknown(MF_MEDIA_ENGINE_DXGI_MANAGER, gestionnaire_.Get());
        attributs->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, avis_);
        attributs->SetUINT32(MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM);
        if (FAILED(usine->CreateInstance(0, attributs.Get(), &moteur_))) {
            FermerVideo();
            DireEtat("video_impossible");
            return false;
        }
        moteur_->SetLoop(TRUE);
        moteur_->SetAutoPlay(TRUE);
        moteur_->SetMuted(r_.video_son == 0);
        BSTR url = SysAllocString(chemin.c_str());
        HRESULT hr = moteur_->SetSource(url);
        SysFreeString(url);
        if (FAILED(hr)) {
            Journal("video refusee : %#x", (unsigned)hr);
            FermerVideo();
            DireEtat("video_refusee");
            return false;
        }
        moteur_->Play();
        Journal("video ouverte");
        DireEtat("ok");
        return true;
    }

    bool TourVideo() {
        if (avis_ && avis_->erreur) {
            FermerVideo();
            DireEtat("video_refusee");
        }
        if (!moteur_ && !OuvrirVideo()) {
            Sleep(100);
            return false;
        }
        if (video_en_pause_) {
            moteur_->Play();
            video_en_pause_ = false;
        }
        LONGLONG temps = 0;
        if (moteur_->OnVideoStreamTick(&temps) != S_OK) return false;
        DWORD largeur = 0, hauteur = 0;
        if (FAILED(moteur_->GetNativeVideoSize(&largeur, &hauteur)) || largeur == 0 || hauteur == 0) return false;
        if (!PreparerSource(largeur, hauteur, DXGI_FORMAT_B8G8R8A8_UNORM)) return false;
        MFVideoNormalizedRect entree = {0, 0, 1, 1};
        RECT sortie = {0, 0, (LONG)largeur, (LONG)hauteur};
        MFARGB fond = {0, 0, 0, 255};
        return SUCCEEDED(moteur_->TransferVideoFrame(source_.Get(), &entree, &sortie, &fond));
    }

    // ---------------- drawing

    bool PreparerDessin() {
        ComPtr<ID3DBlob> vs_code, ps_code, erreurs;
        if (FAILED(D3DCompile(kShader, sizeof(kShader) - 1, nullptr, nullptr, nullptr, "vs", "vs_5_0", 0, 0, &vs_code, &erreurs)) ||
            FAILED(D3DCompile(kShader, sizeof(kShader) - 1, nullptr, nullptr, nullptr, "ps", "ps_5_0", 0, 0, &ps_code, &erreurs))) {
            Journal("shader refuse : %s", erreurs ? (const char*)erreurs->GetBufferPointer() : "?");
            return false;
        }
        device_->CreateVertexShader(vs_code->GetBufferPointer(), vs_code->GetBufferSize(), nullptr, &vs_);
        device_->CreatePixelShader(ps_code->GetBufferPointer(), ps_code->GetBufferSize(), nullptr, &ps_);
        D3D11_SAMPLER_DESC s = {};
        s.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        s.AddressU = s.AddressV = s.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        s.MaxLOD = D3D11_FLOAT32_MAX;
        device_->CreateSamplerState(&s, &lisseur_);
        D3D11_BUFFER_DESC b = {};
        b.ByteWidth = 16;
        b.Usage = D3D11_USAGE_DEFAULT;
        b.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        device_->CreateBuffer(&b, nullptr, &constantes_);
        return vs_ && ps_ && lisseur_ && constantes_;
    }

    bool PreparerSource(UINT largeur, UINT hauteur, DXGI_FORMAT format) {
        if (source_ && largeur == largeur_source_ && hauteur == hauteur_source_ && format == format_source_) return true;
        source_.Reset();
        vue_source_.Reset();
        D3D11_TEXTURE2D_DESC d = {};
        d.Width = largeur;
        d.Height = hauteur;
        d.MipLevels = 0;
        d.ArraySize = 1;
        d.Format = format;
        d.SampleDesc.Count = 1;
        d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        d.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
        if (FAILED(device_->CreateTexture2D(&d, nullptr, &source_))) return false;
        if (FAILED(device_->CreateShaderResourceView(source_.Get(), nullptr, &vue_source_))) return false;
        largeur_source_ = largeur;
        hauteur_source_ = hauteur;
        format_source_ = format;
        return true;
    }

    void Dessiner() {
        if (!source_ || !rtv_) return;
        a_dessine_ = true;
        contexte_->GenerateMips(vue_source_.Get());
        // Whole picture in the screen, black bars when the shapes differ.
        const float echelle = std::min((float)largeur_cible_ / largeur_source_, (float)hauteur_cible_ / hauteur_source_);
        const float l = largeur_source_ * echelle, h = hauteur_source_ * echelle;
        D3D11_VIEWPORT vue = {(largeur_cible_ - l) / 2, (hauteur_cible_ - h) / 2, l, h, 0, 1};
        const float noir[4] = {0, 0, 0, 1};
        float valeurs[4] = {std::max(0.0f, std::log2(1.0f / std::max(echelle, 0.0001f))), 0, 0, 0};
        contexte_->UpdateSubresource(constantes_.Get(), 0, nullptr, valeurs, 0, 0);
        contexte_->ClearRenderTargetView(rtv_.Get(), noir);
        ID3D11RenderTargetView* rtv = rtv_.Get();
        ID3D11ShaderResourceView* srv = vue_source_.Get();
        ID3D11SamplerState* lisseur = lisseur_.Get();
        ID3D11Buffer* tampon = constantes_.Get();
        contexte_->OMSetRenderTargets(1, &rtv, nullptr);
        contexte_->RSSetViewports(1, &vue);
        contexte_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        contexte_->VSSetShader(vs_.Get(), nullptr, 0);
        contexte_->PSSetShader(ps_.Get(), nullptr, 0);
        contexte_->PSSetShaderResources(0, 1, &srv);
        contexte_->PSSetSamplers(0, 1, &lisseur);
        contexte_->PSSetConstantBuffers(0, 1, &tampon);
        contexte_->Draw(3, 0);
        ID3D11ShaderResourceView* aucun = nullptr;
        ID3D11RenderTargetView* aucune_rtv = nullptr;
        contexte_->PSSetShaderResources(0, 1, &aucun);
        contexte_->OMSetRenderTargets(1, &aucune_rtv, nullptr);
        contexte_->Flush();
        UINT n = g_images.fetch_add(1) + 1;
        if (n == 1 || n % 3000 == 0) Journal("%u images envoyees", n);
    }

    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> contexte_;
    ComPtr<IDXGIOutputDuplication> duplication_;
    ComPtr<ID3D11Texture2D> cible_, source_;
    ComPtr<ID3D11RenderTargetView> rtv_;
    ComPtr<ID3D11ShaderResourceView> vue_source_;
    ComPtr<ID3D11VertexShader> vs_;
    ComPtr<ID3D11PixelShader> ps_;
    ComPtr<ID3D11SamplerState> lisseur_;
    ComPtr<ID3D11Buffer> constantes_;
    ComPtr<IMFDXGIDeviceManager> gestionnaire_;
    ComPtr<IMFMediaEngine> moteur_;
    AvisVideo* avis_ = nullptr;
    wgd::Direct3D11::IDirect3DDevice appareil_winrt_{nullptr};
    wgc::Direct3D11CaptureFramePool pool_{nullptr};
    wgc::GraphicsCaptureSession session_{nullptr};
    winrt::Windows::Graphics::SizeInt32 taille_fenetre_{};
    HWND fenetre_ = nullptr;
    LecteurEntrees lecteur_;
    Reglages r_;
    HANDLE poignee_ouverte_ = nullptr;
    UINT largeur_cible_ = 0, hauteur_cible_ = 0, largeur_source_ = 0, hauteur_source_ = 0;
    DXGI_FORMAT format_source_ = DXGI_FORMAT_UNKNOWN;
    DWORD derniere_lecture_ = 0, dernier_essai_fenetre_ = 0, dernier_essai_video_ = 0, dernier_regard_fenetre_ = 0;
    bool jeu_reduit_ = false;
    bool video_en_pause_ = false, a_dessine_ = false;
};

DWORD WINAPI Travail(LPVOID) {
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (const winrt::hresult_error&) {
    }
    MFStartup(MF_VERSION);
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> contexte;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device,
                                   nullptr, &contexte);
    if (FAILED(hr)) {
        Journal("pas de peripherique D3D11 : %#x", (unsigned)hr);
        return 1;
    }
    ComPtr<ID3D10Multithread> multifil;
    if (SUCCEEDED(device.As(&multifil))) multifil->SetMultithreadProtected(TRUE);  // the video engine shares the device
    if (!PatcherVtable(device.Get())) {
        Journal("crochet refuse");
        return 1;
    }
    EcrireFichier(L"pret.txt", "");
    Journal("crochet pose");
    Capture capture;
    if (!capture.Demarrer(device.Get(), contexte.Get())) return 1;
    for (;;) {
        try {
            capture.Tour();
        } catch (const winrt::hresult_error& e) {
            Journal("erreur : %#x", (unsigned)e.code());
            Sleep(500);
        }
    }
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD raison, LPVOID) {
    if (raison == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        wchar_t chemin[MAX_PATH];
        GetModuleFileNameW(module, chemin, MAX_PATH);
        g_dossier = chemin;
        g_dossier.resize(g_dossier.find_last_of(L'\\') + 1);
        for (const wchar_t* nom : {L"pret.txt", L"capture.log", L"etat.txt", L"lister.txt", L"parcourir.txt", L"video_choisie.txt", L"fenetres.txt"}) {
            DeleteFileW((g_dossier + nom).c_str());
        }
        HANDLE fil = CreateThread(nullptr, 0, Travail, nullptr, 0, nullptr);
        if (fil) CloseHandle(fil);
    }
    return TRUE;
}
