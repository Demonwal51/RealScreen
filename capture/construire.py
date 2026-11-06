"""Compile ecran_capture.dll et ecran_entrees.exe avec Visual Studio, sans fenetre, et verifie le resultat.
Le jeu verrouille la DLL dans le jeu, pas celle-ci : compiler ne demande pas de le fermer.
"""
import glob
import pathlib
import subprocess
import sys

ICI = pathlib.Path(__file__).resolve().parent
SORTIE = ICI.parent / "mods" / "EcranReel" / "ecran_capture.dll"
OBJETS = ICI.parent / "logs" / "construction"
OBJETS.mkdir(parents=True, exist_ok=True)
vcvars = glob.glob(r"C:\Program Files\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvars64.bat")
if not vcvars:
    sys.exit("ECHEC : vcvars64.bat introuvable")
AIDE = ICI.parent / "mods" / "EcranReel" / "ecran_entrees.exe"
commandes = {
    SORTIE: (
        # Sans le chemin de ce PC dans le binaire : C++/WinRT garde l'emplacement du source pour ses messages d'erreur.
        f'"{vcvars[0]}" >nul && cl /nologo /std:c++20 /O2 /MT /EHsc /W3 /utf-8 /LD /DWINRT_NO_SOURCE_LOCATION "/d1trimfile:{ICI}\\\\" '
        f'"{ICI / "ecran_capture.cpp"}" '
        f'/Fo"{OBJETS}\\\\" /Fe"{SORTIE}" /link /NOLOGO /IMPLIB:"{OBJETS / "ecran_capture.lib"}"'
    ),
    AIDE: (
        f'"{vcvars[0]}" >nul && cl /nologo /std:c++17 /O2 /MT /EHsc /W3 /utf-8 "{ICI / "ecran_entrees.cpp"}" '
        f'/Fo"{OBJETS}\\\\" /Fe"{AIDE}" /link /NOLOGO /SUBSYSTEM:WINDOWS'
    ),
}
for cible, commande in commandes.items():
    avant = cible.stat().st_mtime if cible.exists() else 0
    r = subprocess.run(commande, shell=True, capture_output=True, text=True, errors="replace",
                       creationflags=subprocess.CREATE_NO_WINDOW)
    lignes = (r.stdout + r.stderr).splitlines()
    utile = [l for l in lignes if "error" in l.lower() or "warning" in l.lower()]
    print("\n".join(utile[:15]))
    if r.returncode != 0 or not cible.exists() or cible.stat().st_mtime == avant:
        print("\n".join(lignes[-6:]))
        sys.exit(f"ECHEC de la compilation de {cible.name}, code {r.returncode}")
    print(f"OK {cible.name} {cible.stat().st_size} octets")
