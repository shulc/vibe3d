<#
.SYNOPSIS
    Build the Vibe3D Windows installer (vibe3d-setup-<version>.exe) from a
    self-contained editor payload, using Inno Setup (iscc.exe).

.DESCRIPTION
    FIRST DRAFT — authored on Linux, NOT yet run on Windows. Pure PowerShell:
    no bash / sh / Unix coreutils are used or required. The only external
    build-time tools are:
        * Inno Setup 6 (iscc.exe)          — REQUIRED
        * ImageMagick (magick / convert)   — OPTIONAL, only to regenerate the
                                             .ico from PNG if it is ever missing
    Both are checked with a clear error + install hint if absent.

    The script:
      1. Resolves the payload — either a flat directory or the CI
         "vibe3d-windows.zip" — and stages a mutable copy.
      2. Validates that vibe3d.exe (and at least SDL2.dll) are present.
      3. Ensures a vibe3d.ico exists at the stage root (prefers the one shipped
         in the payload's assets\icon\; else regenerates from PNG via
         ImageMagick; else errors clearly).
      4. Copies LICENSE + THIRD_PARTY_LICENSES.md from the repo root into the
         stage (so the wizard shows a license page and installs the texts).
      5. Locates iscc.exe (PATH, -IsccPath, or the standard install dir).
      6. Compiles tools\release\windows\vibe3d.iss, passing the version, the
         staged payload dir, the output dir, and the icon/license paths.
      7. Emits <OutputDir>\vibe3d-setup-<version>.exe.

    The END-USER needs nothing but the produced .exe — the payload bundles the
    native binary and every runtime DLL (SDL2, onnxruntime, VC++ CRT) app-local.

    NOTE: The AI-generation addon (TRELLIS / ai3d worker) is Linux-only and OUT
    OF SCOPE — this builds the EDITOR ONLY. A future Windows AI addon would need
    its own PowerShell provisioner + a bundled/downloaded Python, not the Linux
    install_linux.sh bash flow.

.PARAMETER Version
    Version string stamped into the installer + Add/Remove Programs (e.g.
    "0.4.1" or "nightly"). Also used in the output file name. REQUIRED.

.PARAMETER Payload
    Path to the payload: either a flat directory (containing vibe3d.exe + DLLs +
    config\ + assets\) or a .zip (the CI "vibe3d-windows.zip"). Defaults to
    "vibe3d-windows.zip" in the current directory, then in the repo root.

.PARAMETER OutputDir
    Directory to write vibe3d-setup-<version>.exe into. Default: "<repo>\dist".

.PARAMETER IssPath
    Path to vibe3d.iss. Default: the vibe3d.iss next to this script.

.PARAMETER IsccPath
    Explicit path to iscc.exe. If omitted, PATH and the standard Inno Setup 6
    install directory are searched.

.EXAMPLE
    # From an unzipped CI payload directory:
    .\build_windows_installer.ps1 -Version 0.4.1 -Payload C:\stage\vibe3d-windows

.EXAMPLE
    # Straight from the CI zip:
    .\build_windows_installer.ps1 -Version nightly -Payload .\vibe3d-windows.zip

.NOTES
    UNTESTED on Windows. Verify iscc/ImageMagick discovery + the emitted setup
    on a real Windows box before release. See tools\release\windows\README.md.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Payload,

    [string]$OutputDir,

    [string]$IssPath,

    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths -----------------------------------------------------------------
# This script lives in <repo>\tools\release\windows\.
$scriptDir = $PSScriptRoot
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path

if (-not $IssPath)    { $IssPath    = Join-Path $scriptDir 'vibe3d.iss' }
if (-not $OutputDir)  { $OutputDir  = Join-Path $repoRoot  'dist' }

if (-not (Test-Path $IssPath)) {
    throw "Inno Setup script not found: $IssPath"
}

Write-Host "[installer] repo root : $repoRoot"
Write-Host "[installer] iss script: $IssPath"
Write-Host "[installer] version   : $Version"

# --- Resolve the payload ---------------------------------------------------
# Accept an explicit -Payload (dir or .zip), else look for the CI zip in the
# current directory, then the repo root.
if (-not $Payload) {
    foreach ($cand in @((Join-Path (Get-Location) 'vibe3d-windows.zip'),
                        (Join-Path $repoRoot 'vibe3d-windows.zip'))) {
        if (Test-Path $cand) { $Payload = $cand; break }
    }
    if (-not $Payload) {
        throw "No -Payload given and vibe3d-windows.zip not found in the current directory or repo root. " +
              "Pass -Payload <dir-or-zip> (the unzipped/zipped CI Windows artifact, or a local " +
              "'dub build --config=modeling' output directory)."
    }
}
if (-not (Test-Path $Payload)) {
    throw "Payload not found: $Payload"
}
$Payload = (Resolve-Path $Payload).Path
Write-Host "[installer] payload   : $Payload"

# --- Stage a mutable copy of the payload -----------------------------------
# We stage into <OutputDir>\_stage so we can add vibe3d.ico + LICENSE without
# mutating the caller's payload. A .zip is expanded here; a directory is copied.
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stage = Join-Path $OutputDir '_stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

if ((Get-Item $Payload).PSIsContainer) {
    Write-Host "[installer] staging directory payload -> $stage"
    Copy-Item -Path (Join-Path $Payload '*') -Destination $stage -Recurse -Force
} elseif ($Payload -match '\.zip$') {
    Write-Host "[installer] expanding zip payload -> $stage"
    Expand-Archive -Path $Payload -DestinationPath $stage -Force
    # Some archives wrap everything in a single top-level folder; if the exe is
    # not at the stage root but sits one level down, flatten that wrapper.
    if (-not (Test-Path (Join-Path $stage 'vibe3d.exe'))) {
        $inner = Get-ChildItem $stage -Directory
        if ($inner.Count -eq 1 -and (Test-Path (Join-Path $inner[0].FullName 'vibe3d.exe'))) {
            Write-Host "[installer] flattening wrapper folder '$($inner[0].Name)'"
            Move-Item -Path (Join-Path $inner[0].FullName '*') -Destination $stage -Force
            Remove-Item $inner[0].FullName -Recurse -Force
        }
    }
} else {
    throw "Payload must be a directory or a .zip file: $Payload"
}

# --- Validate the staged payload -------------------------------------------
$exe = Join-Path $stage 'vibe3d.exe'
if (-not (Test-Path $exe)) {
    throw "vibe3d.exe not found in the staged payload ($stage). Is this the Windows editor payload?"
}
if (-not (Test-Path (Join-Path $stage 'SDL2.dll'))) {
    Write-Warning "[installer] SDL2.dll not found in payload - the editor will not start without it."
}
$dllCount = @(Get-ChildItem (Join-Path $stage '*.dll')).Count
Write-Host "[installer] payload has vibe3d.exe + $dllCount DLL(s) app-local"
if (-not (Test-Path (Join-Path $stage 'onnxruntime.dll'))) {
    Write-Host "[installer] note: no onnxruntime.dll present -> this looks like a noai (Win7) payload"
}

# --- Ensure a vibe3d.ico at the stage root ---------------------------------
# Prefer the multi-resolution icon that already ships in the payload. If it is
# somehow absent, regenerate it from the largest bundled PNG via ImageMagick.
$stageIco  = Join-Path $stage 'vibe3d.ico'
$shippedIco = Join-Path $stage 'assets\icon\vibe3d.ico'
if (Test-Path $shippedIco) {
    Copy-Item $shippedIco $stageIco -Force
    Write-Host "[installer] icon      : reused $shippedIco"
} else {
    Write-Warning "[installer] $shippedIco missing - attempting to generate vibe3d.ico from PNG via ImageMagick"
    $srcPng = $null
    foreach ($p in @('assets\icon\png\vibe3d_256.png', 'assets\icon\png\vibe3d_512.png',
                     'assets\icon\png\vibe3d_1024.png', 'assets\icon\png\vibe3d_128.png')) {
        $full = Join-Path $stage $p
        if (Test-Path $full) { $srcPng = $full; break }
    }
    if (-not $srcPng) {
        throw "Cannot produce vibe3d.ico: neither assets\icon\vibe3d.ico nor a source PNG " +
              "(assets\icon\png\vibe3d_*.png) is present in the payload."
    }
    # ImageMagick v7 exposes 'magick'; v6 exposes 'convert'.
    $magick = Get-Command magick -ErrorAction SilentlyContinue
    if (-not $magick) { $magick = Get-Command convert -ErrorAction SilentlyContinue }
    if (-not $magick) {
        throw "vibe3d.ico is missing and ImageMagick was not found on PATH to regenerate it. " +
              "Either add assets\icon\vibe3d.ico to the payload, or install ImageMagick " +
              "(winget install ImageMagick.ImageMagick) and re-run."
    }
    # -define icon:auto-resize packs the standard Windows icon sizes into one .ico.
    # ImageMagick v7's launcher is magick.exe (takes a 'convert' subcommand);
    # v6's is convert.exe (called directly). Get-Command .Name is like
    # "magick.exe" / "convert.exe", so match the stem rather than compare exactly.
    $magickArgs = @($srcPng, '-define', 'icon:auto-resize=256,128,64,48,32,16', $stageIco)
    if ($magick.Name -imatch '^magick') { $magickArgs = @('convert') + $magickArgs }
    & $magick.Source @magickArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $stageIco)) {
        throw "ImageMagick failed to generate vibe3d.ico from $srcPng"
    }
    Write-Host "[installer] icon      : generated $stageIco from $srcPng"
}

# --- Stage the license texts (for the wizard license page + install) -------
foreach ($lic in @('LICENSE', 'THIRD_PARTY_LICENSES.md')) {
    $src = Join-Path $repoRoot $lic
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $stage $lic) -Force
        Write-Host "[installer] staged    : $lic"
    } else {
        Write-Warning "[installer] $lic not found at repo root - it will be omitted"
    }
}
$licenseArg = $null
$stagedLicense = Join-Path $stage 'LICENSE'
if (Test-Path $stagedLicense) { $licenseArg = $stagedLicense }

# --- Locate iscc.exe (Inno Setup compiler) ---------------------------------
if (-not $IsccPath) {
    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $IsccPath = $cmd.Source
    } else {
        foreach ($cand in @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe")) {
            if ($cand -and (Test-Path $cand)) { $IsccPath = $cand; break }
        }
    }
}
if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
    throw "iscc.exe (Inno Setup compiler) not found. Install Inno Setup 6, e.g.:`n" +
          "    winget install JRSoftware.InnoSetup`n" +
          "  or:`n" +
          "    choco install innosetup`n" +
          "then re-run (or pass -IsccPath 'C:\Path\To\ISCC.exe')."
}
Write-Host "[installer] iscc      : $IsccPath"

# --- Compile the installer -------------------------------------------------
$outBase = "vibe3d-setup-$Version"
$isccArgs = @(
    "/DAppVersion=$Version",
    "/DPayloadDir=$stage",
    "/DOutputDir=$OutputDir",
    "/DOutputBaseName=$outBase",
    "/DAppIcon=$stageIco"
)
if ($licenseArg) { $isccArgs += "/DLicenseFile=$licenseArg" }
$isccArgs += $IssPath

Write-Host "[installer] compiling : $IsccPath $($isccArgs -join ' ')"
& $IsccPath @isccArgs
if ($LASTEXITCODE -ne 0) {
    throw "iscc.exe failed with exit code $LASTEXITCODE"
}

$outExe = Join-Path $OutputDir "$outBase.exe"
if (-not (Test-Path $outExe)) {
    throw "iscc reported success but $outExe was not produced."
}
$sizeMB = (Get-Item $outExe).Length / 1MB
Write-Host ("[installer] DONE      : {0} ({1:N1} MB)" -f $outExe, $sizeMB)
