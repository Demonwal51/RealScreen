# Real Screen for Spirit City: Lofi Sessions: installs or removes the mod. ASCII only.
# Finds the game in the Steam libraries. -Dossier gives the game folder by hand.
param([string]$Action = 'install', [string]$Dossier = '', [switch]$SansQuestion)
$ErrorActionPreference = 'Stop'
$ici = Split-Path -Parent $MyInvocation.MyCommand.Path
$NomJeu = 'Spirit City Lofi Sessions'

function Trouver-Jeu {
    $racines = New-Object System.Collections.ArrayList
    $cles = 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam'
    foreach ($cle in $cles) {
        $p = Get-ItemProperty $cle -ErrorAction SilentlyContinue
        foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { [void]$racines.Add($v) } }
    }
    foreach ($r in @($racines)) {
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                [void]$racines.Add($m.Groups[1].Value.Replace('\\', '\'))
            }
        }
    }
    foreach ($r in $racines) {
        $d = Join-Path $r "steamapps\common\$NomJeu"
        if (Test-Path (Join-Path $d 'SpiritCity\Binaries\Win64\SpiritCity-Win64-Shipping.exe')) { return $d }
    }
    return $null
}

if (-not $Dossier) { $Dossier = Trouver-Jeu }
if (-not $Dossier -and -not $SansQuestion) {
    Write-Host 'Game folder not found automatically.'
    Write-Host 'In Steam: right click the game, Manage, Browse local files, then copy that folder path here.'
    $Dossier = (Read-Host 'Game folder').Trim('"', ' ')
}
$win64 = Join-Path $Dossier 'SpiritCity\Binaries\Win64'
if (-not $Dossier -or -not (Test-Path (Join-Path $win64 'SpiritCity-Win64-Shipping.exe'))) {
    Write-Host 'ERROR: this is not the Spirit City: Lofi Sessions folder. Nothing was changed.'
    exit 1
}
Write-Host "Game folder: $Dossier"
# An open game locks its files: wait for the player to close it, so nothing has to be started again.
if (Get-Process 'SpiritCity-Win64-Shipping' -ErrorAction SilentlyContinue) {
    if ($SansQuestion) {
        Write-Host 'ERROR: the game is open. Nothing was changed.'
        exit 1
    }
    Write-Host 'Please close the game. This continues by itself once it is closed.'
    while (Get-Process 'SpiritCity-Win64-Shipping' -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 2
}
$ue4ss = Join-Path $win64 'ue4ss'
$mod = Join-Path $ue4ss 'Mods\EcranReel'
$listeMods = Join-Path $ue4ss 'Mods\mods.txt'
$marque = Join-Path $ue4ss 'RealScreen-installed-UE4SS.txt'

if ($Action -eq 'install') {
    $source = Join-Path $ici 'game\SpiritCity\Binaries\Win64'
    if (-not (Test-Path $source)) { Write-Host 'ERROR: unzip the whole archive first.'; exit 1 }
    $reglages = $null
    if (Test-Path (Join-Path $mod 'ecran_reel.ini')) { $reglages = Get-Content (Join-Path $mod 'ecran_reel.ini') -Raw -Encoding UTF8 }
    if ((Test-Path (Join-Path $win64 'dwmapi.dll')) -and (Test-Path $ue4ss) -and -not (Test-Path $marque)) {
        # UE4SS was already there for other mods: only our folder is added, and it is switched on in its list.
        Copy-Item (Join-Path $source 'ue4ss\Mods\EcranReel') (Join-Path $ue4ss 'Mods') -Recurse -Force
        $t = if (Test-Path $listeMods) { [IO.File]::ReadAllText($listeMods) } else { '' }
        if ($t -notmatch '(?m)^EcranReel : 1') { [IO.File]::WriteAllText($listeMods, "EcranReel : 1`r`n" + $t) }
        Write-Host 'UE4SS was already installed: kept as it is.'
    } else {
        Copy-Item (Join-Path $source '*') $win64 -Recurse -Force
        [IO.File]::WriteAllText($marque, "UE4SS was installed by Real Screen`r`n")
    }
    if ($reglages) { [IO.File]::WriteAllText((Join-Path $mod 'ecran_reel.ini'), $reglages) }
    # Check by reading back.
    foreach ($f in 'Scripts\main.lua', 'ecran_capture.dll', 'ecran_entrees.exe', 'ecran_reel.ini') {
        if (-not (Test-Path (Join-Path $mod $f))) { Write-Host "ERROR: missing $f"; exit 1 }
    }
    if (-not (Test-Path (Join-Path $win64 'dwmapi.dll'))) { Write-Host 'ERROR: missing dwmapi.dll'; exit 1 }
    Write-Host 'Installed. Start the game and choose Gaming at the desk: your monitor is on the screen there.'
    Write-Host 'To change anything: Options, General, REAL SCREEN.'
} elseif ($Action -eq 'uninstall') {
    if (Test-Path $mod) { Remove-Item $mod -Recurse -Force }
    if (Test-Path $marque) {
        # UE4SS came with this mod and nothing else uses it: it goes too.
        $autres = @(Get-ChildItem (Join-Path $ue4ss 'Mods') -Directory -ErrorAction SilentlyContinue)
        if ($autres.Count -eq 0) {
            Remove-Item $ue4ss -Recurse -Force
            Remove-Item (Join-Path $win64 'dwmapi.dll') -Force
            $logic = Join-Path $Dossier 'SpiritCity\Content\Paks\LogicMods'
            if ((Test-Path $logic) -and -not (Get-ChildItem $logic)) { Remove-Item $logic -Force }
        } else {
            Write-Host 'Other UE4SS mods found: UE4SS was kept.'
        }
    } elseif (Test-Path $listeMods) {
        $t = [IO.File]::ReadAllText($listeMods)
        [IO.File]::WriteAllText($listeMods, ($t -replace '(?m)^EcranReel : 1\r?\n', ''))
    }
    if (Test-Path $mod) { Write-Host 'ERROR: the mod folder is still there.'; exit 1 }
    Write-Host 'Removed.'
} else {
    Write-Host "Unknown action: $Action"
    exit 1
}
