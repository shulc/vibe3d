<#
.SYNOPSIS
    Provision the optional AI-generation runtime (TRELLIS image-to-3D
    backend) on Windows -- the Windows counterpart of install_linux.sh.

.DESCRIPTION
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !! UNTESTED (task "simple-install"): written and reviewed on Linux    !!
    !! with no access to a Windows box or an NVIDIA GPU. Every step below !!
    !! mirrors install_linux.sh's structure and was checked against the   !!
    !! upstream fork's own install.py + README, but it has NEVER been     !!
    !! run for real. TODO(windows): verify end-to-end on real hardware    !!
    !! before removing this banner.                                      !!
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    This is the end-user-facing "Install" button's implementation on
    Windows: source/ai3d/worker_manager.d spawns this script (via
    `powershell -NoProfile -ExecutionPolicy Bypass -File ...`) and streams
    its output into the Generate 3D panel, the same way it spawns
    install_linux.sh on Linux. It can also be run by hand from a terminal.

    What this script does:
      1. Locates a Python 3.11 (fallback 3.10) interpreter on PATH.
      2. GPU preflight: NVIDIA driver present, driver CUDA version high
         enough for the torch wheel index below, and enough VRAM.
      3. Creates a Python venv at <Location>\venv.
      4. Installs a CUDA build of torch/torchvision into that venv.
      5. Clones the TRELLIS fork (--recursive) to <Location>\TRELLIS (or
         reuses -TrellisRoot), then runs ITS OWN install.py inside the venv
         -- see the "Why delegate to install.py" note below.
      6. Installs this worker package itself (`pip install`, non-editable)
         so `python -m vibe3d_ai3d_worker serve` resolves inside the venv.
      7. Writes the config handshake file the editor reads:
         $env:LOCALAPPDATA\vibe3d\ai3d.json

    What this script deliberately does NOT do:
      - Download the ~4 GB TRELLIS model weights. That is a SEPARATE,
        explicit step (download_model.ps1 / `fetch-model`) -- never bundled
        into install, never triggered automatically by this script or by
        the worker itself.
      - Auto-install Python. If no supported interpreter is found on PATH,
        this script prints an actionable error (python.org / winget hint)
        and exits, rather than trying to silently fetch one.
      - Touch anything outside <Location> and the config file above.

    Why delegate to install.py instead of a hand-rolled wheel list:
    the TRELLIS fork's CUDA extensions (spconv, cumm, nvdiffrast,
    diffoctreerast, kaolin) ship as prebuilt win_amd64 wheels checked into
    the fork's own `whl/` directory, built against an exact
    (Python 3.11, CUDA 12.8) combination that shifts with upstream
    releases. install.py already knows the exact wheel filenames and
    install order for the checkout it ships with; hand-pinning URLs here
    would silently rot the next time the fork bumps versions. install.py
    takes no CLI arguments and installs against `sys.executable` (whatever
    interpreter runs it) rather than creating its own venv, so we create
    the venv ourselves and then run install.py THROUGH the venv's python
    -- `<venv>\Scripts\python.exe <TrellisRoot>\install.py` -- which is
    sufficient for its pip calls to land inside our venv, no `activate`
    needed.

.PARAMETER Location
    Where to install the venv + (if cloned) TRELLIS.
    Default: $env:LOCALAPPDATA\vibe3d\ai3d

.PARAMETER TrellisRoot
    Use an existing TRELLIS checkout instead of cloning one. Must already
    exist; not modified by this script beyond what install.py itself
    touches.

.PARAMETER DryRun
    Print the full plan (every command this script WOULD run, and the
    exact size/location warnings) and exit 0 WITHOUT creating,
    downloading, or writing anything. Fully offline-safe -- this is the
    mode the automated test suite would exercise (never a real install),
    mirroring install_linux.sh --dry-run.

.PARAMETER SkipGpuCheck
    Proceed even if the NVIDIA GPU / CUDA / VRAM preflight fails.
    Equivalent of VIBE3D_SKIP_GPU_CHECK=1 in install_linux.sh.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install_windows.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install_windows.ps1 -Location D:\vibe3d-ai3d

.NOTES
    Env overrides (mirroring install_linux.sh's PYTHON / TORCH_INDEX_URL /
    TRELLIS_REPO_URL / VIBE3D_REQUIRED_CUDA / VIBE3D_MIN_VRAM_MB):
      VIBE3D_PYTHON            Python launcher/exe name to build the venv
                                from (default: auto-detect py -3.11 / py -3.10
                                / python3.11 / python3.10 / python on PATH).
      VIBE3D_TORCH_INDEX_URL   pip --index-url for torch (default: the
                                CUDA 12.8 wheel index, matching the fork's
                                own README-documented Windows target).
      VIBE3D_TRELLIS_REPO_URL  git remote to clone when -TrellisRoot is not
                                given (default: the StableProjectorz fork).
      VIBE3D_REQUIRED_CUDA     override the derived minimum driver CUDA.
      VIBE3D_MIN_VRAM_MB       override the minimum VRAM (default 6000).
      VIBE3D_SKIP_GPU_CHECK    "1" == same as -SkipGpuCheck.
      VIBE3D_AI3D_WORKER_EDITABLE  "1" == `pip install -e` this worker
                                package instead of a copying install (dev
                                convenience; production installs should NOT
                                set this -- same rationale as
                                install_linux.sh's non-editable default).
#>
[CmdletBinding()]
param(
    [string]$Location = "",
    [string]$TrellisRoot = "",
    [switch]$DryRun,
    [switch]$SkipGpuCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Yellow
Write-Host "!! install_windows.ps1 is UNTESTED on real Windows/NVIDIA hardware.   !!" -ForegroundColor Yellow
Write-Host "!! Written on Linux without a Windows box or GPU to validate against. !!" -ForegroundColor Yellow
Write-Host "!! Please report any failure -- see doc/tasks for the owning task.    !!" -ForegroundColor Yellow
Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Yellow

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# error+exit helper. Deliberately NOT `Write-Error; exit N`: with
# $ErrorActionPreference = 'Stop' (set above), Write-Error itself becomes a
# TERMINATING error and unwinds the script immediately -- any `exit N` on
# the following line never runs, so the process would always exit 1
# instead of the documented 3/4/etc. Write-Host is not an error record, so
# it can't trigger that, and it lands in the same redirected-stdout log
# file the rest of this script's Write-Host plan/step output does (the
# editor's install log capture doesn't distinguish stdout/stderr -- see
# worker_manager.d's spawnInstallStage, one file for both).
function Die([string]$msg, [int]$code) {
    Write-Host "error: $msg" -ForegroundColor Red
    exit $code
}

# Safe tail-slice for a python-invocation array (e.g. @("py","-3.11") or a
# single-element @("python3.11")). PowerShell's `1..($arr.Length-1)` range
# becomes the DESCENDING sequence (1,0) when Length is 1 (Length-1 = 0 < 1),
# which indexes out of bounds on a 1-element array -- exactly the common
# case here (the 'py' launcher is the only 2-element result Find-Python
# ever returns). This guards that.
function PyTail([string[]]$arr) {
    if ($arr.Length -le 1) { return @() }
    return $arr[1..($arr.Length - 1)]
}

# TODO(windows): verify these wheel-index / version assumptions against a
# real `pip download` dry-run once a Windows+CUDA box is available. cu128
# matches both the fork's README ("A One-click installer for Windows:
# Python 3.11, Cuda 12.8, Torch 2.7") and its win_amd64 wheel filenames
# (e.g. spconv_cu128-*-cp311-cp311-win_amd64.whl), so this is not a guess,
# but it has not been exercised end-to-end here.
$TorchIndexUrl = if ($env:VIBE3D_TORCH_INDEX_URL) { $env:VIBE3D_TORCH_INDEX_URL } else { "https://download.pytorch.org/whl/cu128" }

# The StableProjectorz TRELLIS fork, NOT upstream microsoft/TRELLIS -- same
# choice install_linux.sh makes and for the same reason (per-stage CPU<->GPU
# offload so FP16 TRELLIS fits an 8 GB card; see install_linux.sh's own
# comment for the full rationale). The fork additionally ships prebuilt
# win_amd64 wheels for its CUDA extensions (see install.py's `whl/` folder),
# which is *why* Windows delegates to the fork's own install.py rather than
# reimplementing a wheel list here.
$TrellisRepoUrl = if ($env:VIBE3D_TRELLIS_REPO_URL) { $env:VIBE3D_TRELLIS_REPO_URL } else { "https://github.com/IgorAherne/trellis-stable-projectorz.git" }

# GPU preflight thresholds -- same semantics as install_linux.sh's
# REQUIRED_CUDA / MIN_VRAM_MB. REQUIRED_CUDA is derived from the torch
# index tag (cu128 -> 12.8) so it tracks $TorchIndexUrl automatically.
$cuMatch = [regex]::Match($TorchIndexUrl, 'cu(\d{3,})')
if ($env:VIBE3D_REQUIRED_CUDA) {
    $RequiredCuda = $env:VIBE3D_REQUIRED_CUDA
} elseif ($cuMatch.Success) {
    $tag = $cuMatch.Groups[1].Value
    $RequiredCuda = "$($tag.Substring(0,2)).$($tag.Substring(2))"
} else {
    $RequiredCuda = "12.8"
}
$MinVramMb = if ($env:VIBE3D_MIN_VRAM_MB) { [int]$env:VIBE3D_MIN_VRAM_MB } else { 6000 }
$SkipGpuCheckEff = $SkipGpuCheck.IsPresent -or ($env:VIBE3D_SKIP_GPU_CHECK -eq "1")

$DefaultLocation = Join-Path $env:LOCALAPPDATA "vibe3d\ai3d"
$ConfigDir       = Join-Path $env:LOCALAPPDATA "vibe3d"
$ConfigPath      = Join-Path $ConfigDir "ai3d.json"
$DefaultPort     = 47831

if ([string]::IsNullOrEmpty($Location)) { $Location = $DefaultLocation }
$VenvDir    = Join-Path $Location "venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"

if ($TrellisRoot.Length -gt 0) {
    $TrellisRootResolved   = $TrellisRoot
    $TrellisIsCloneTarget  = $false
} else {
    $TrellisRootResolved   = Join-Path $Location "TRELLIS"
    $TrellisIsCloneTarget  = $true
}

# ---------------------------------------------------------------------------
# Python interpreter discovery. TRELLIS's CUDA-extension wheels (see
# install.py) are built only for Python 3.11 (cp311); 3.10 is offered as a
# fallback in case a 3.11 wheel set is ever unavailable, matching this
# script's stated support window, but the CURRENT fork ships 3.11-only
# wheels -- TODO(windows): confirm 3.10 actually works, or drop the
# fallback, once install.py's wheel set is checked against a real venv.
# ---------------------------------------------------------------------------
function Find-Python {
    if ($env:VIBE3D_PYTHON) {
        return ,@($env:VIBE3D_PYTHON)
    }
    # Prefer the official `py` launcher (installed by python.org's Windows
    # installer by default) with an explicit version pin -- it coexists
    # cleanly with other pythons on PATH.
    $pyLauncher = Get-Command "py" -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        foreach ($ver in @("-3.11", "-3.10")) {
            try {
                & py $ver -c "import sys" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { return ,@("py", $ver) }
            } catch { }
        }
    }
    foreach ($cand in @("python3.11", "python3.10", "python")) {
        $cmd = Get-Command $cand -ErrorAction SilentlyContinue
        if ($cmd) { return ,@($cand) }
    }
    return $null
}

function Get-PyVersionString([string[]]$pyInvoke) {
    try {
        $out = & $pyInvoke[0] @(PyTail $pyInvoke) -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        return $out.Trim()
    } catch {
        return "?"
    }
}

$PyInvoke = Find-Python
if (-not $PyInvoke) {
    Die @"
no Python interpreter found on PATH (looked for the 'py' launcher
with -3.11/-3.10, then python3.11, python3.10, python).

TRELLIS's CUDA extension wheels ship only for Python 3.11 (with a 3.10
fallback). Install Python 3.11 from https://python.org/downloads/ (check
"Add python.exe to PATH" during setup) or via winget:
    winget install Python.Python.3.11
then re-run this script. Or set `$env:VIBE3D_PYTHON to an explicit
interpreter path/command and re-run.
"@ 3
}

$PyVer = Get-PyVersionString $PyInvoke
if ($PyVer -notin @("3.10", "3.11")) {
    $msg = "$($PyInvoke -join ' ') is Python $PyVer -- unsupported. TRELLIS's " +
           "CUDA extension wheels ship only for Python 3.10-3.11. Install " +
           "Python 3.11 (winget install Python.Python.3.11) or set " +
           "`$env:VIBE3D_PYTHON to a 3.10/3.11 interpreter and re-run."
    if ($DryRun) { Write-Warning $msg } else { Die $msg 3 }
}

# A venv left over from a previous run on a DIFFERENT Python (e.g. after a
# system Python upgrade) would be silently reused and fail the same way as
# install_linux.sh's equivalent guard.
if (-not $DryRun -and (Test-Path $VenvPython)) {
    $existingVer = (& $VenvPython -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null)
    if ($existingVer -and $existingVer.Trim() -ne $PyVer) {
        Die "existing venv at $VenvDir is Python $($existingVer.Trim()), but this run uses $PyVer.`n       Remove the stale venv and re-run:  Remove-Item -Recurse -Force '$VenvDir'" 3
    }
}

# ---------------------------------------------------------------------------
# GPU preflight -- mirrors install_linux.sh's preflight_gpu(), reading
# nvidia-smi instead of parsing /proc. Refuses the multi-GB install up
# front rather than failing deep into a pip resolve.
# ---------------------------------------------------------------------------
function Test-GpuPreflight {
    Write-Host "-- GPU preflight (need NVIDIA + driver CUDA >= $RequiredCuda + >= $MinVramMb MiB VRAM)"

    $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        Fail-Gpu "no NVIDIA driver found (nvidia-smi not on PATH). TRELLIS needs an NVIDIA GPU with CUDA."
        return
    }

    try {
        $smiOut = & nvidia-smi 2>$null
    } catch {
        Fail-Gpu "nvidia-smi is present but failed to run -- NVIDIA driver problem (reboot / reinstall the driver?)."
        return
    }
    if ($LASTEXITCODE -ne 0) {
        Fail-Gpu "nvidia-smi is present but failed to run -- NVIDIA driver problem (reboot / reinstall the driver?)."
        return
    }

    $name = $null
    try { $name = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1) } catch { }

    $cudaMatch = [regex]::Match(($smiOut -join "`n"), 'CUDA Version:\s*([0-9]+\.[0-9]+)')
    $cuda = $null
    if ($cudaMatch.Success) { $cuda = $cudaMatch.Groups[1].Value }

    $vram = $null
    try {
        $vramLines = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        $vramNums = $vramLines | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ }
        if ($vramNums) { $vram = ($vramNums | Measure-Object -Maximum).Maximum }
    } catch { }

    Write-Host "   detected: $(if ($name) { $name } else { 'unknown GPU' }), driver CUDA $(if ($cuda) { $cuda } else { '?' }), $(if ($vram) { $vram } else { '?' }) MiB VRAM"

    if ($cuda) {
        if ([version]$cuda -lt [version]$RequiredCuda) {
            Fail-Gpu "NVIDIA driver supports CUDA $cuda, but torch ($TorchIndexUrl) needs CUDA >= $RequiredCuda. Update the NVIDIA driver."
        }
    } else {
        Fail-Gpu "could not read the driver's CUDA version from nvidia-smi (need >= $RequiredCuda)."
    }

    if ($vram) {
        if ($vram -lt $MinVramMb) {
            Fail-Gpu "GPU has $vram MiB VRAM, but TRELLIS (FP16, mesh-only) needs ~$MinVramMb MiB and will likely OOM."
        }
    } else {
        Fail-Gpu "could not read GPU VRAM from nvidia-smi (need >= $MinVramMb MiB)."
    }
}

function Fail-Gpu([string]$msg) {
    if ($DryRun -or $SkipGpuCheckEff) {
        Write-Warning $msg
    } else {
        Die "$msg`n       (override with -SkipGpuCheck, or `$env:VIBE3D_SKIP_GPU_CHECK=1)" 4
    }
}

# ---------------------------------------------------------------------------
# The plan -- printed in both -DryRun and real-run mode, mirroring
# install_linux.sh's print_plan().
# ---------------------------------------------------------------------------
function Show-Plan {
    Write-Host "vibe3d AI-3D runtime install plan (Windows)"
    Write-Host "============================================"
    Write-Host "  install location:   $Location"
    Write-Host "  venv:                $VenvDir"
    Write-Host "  estimated size:      ~8-10 GB (torch + CUDA runtime + TRELLIS deps;"
    Write-Host "                       the ~4 GB model weights are a SEPARATE step,"
    Write-Host "                       see download_model.ps1 -- never fetched here)"
    if ($TrellisIsCloneTarget) {
        Write-Host "  TRELLIS checkout:    will clone $TrellisRepoUrl -> $TrellisRootResolved"
    } else {
        Write-Host "  TRELLIS checkout:    using existing $TrellisRootResolved"
    }
    Write-Host "  torch index:         $TorchIndexUrl"
    Write-Host "  worker package:      pip install $ScriptDir   (copy; set VIBE3D_AI3D_WORKER_EDITABLE=1 for -e)"
    Write-Host "  config written to:   $ConfigPath"
    Write-Host ""
    Write-Host "Steps:"
    Write-Host "  0. GPU preflight: NVIDIA driver present, driver CUDA >= $RequiredCuda,"
    Write-Host "     >= $MinVramMb MiB VRAM (skip with -SkipGpuCheck)"
    Write-Host "  1. New-Item -ItemType Directory '$Location' (if missing)"
    Write-Host "  2. $($PyInvoke -join ' ') -m venv '$VenvDir'   (skipped if it already exists)"
    Write-Host "  3. '$VenvPython' -m pip install --upgrade pip setuptools wheel"
    Write-Host "  4. '$VenvPython' -m pip install torch torchvision --index-url '$TorchIndexUrl'"
    if ($TrellisIsCloneTarget) {
        Write-Host "  5. git clone --recursive '$TrellisRepoUrl' '$TrellisRootResolved'   (skipped if present)"
    } else {
        Write-Host "  5. (using existing checkout)"
    }
    Write-Host "     + git submodule update --init --recursive   (flexicubes)"
    Write-Host "  6. '$VenvPython' '$TrellisRootResolved\install.py'  -- the fork's OWN Windows"
    Write-Host "     installer, run THROUGH our venv's python so its pip calls land there."
    Write-Host "     Installs xformers, huggingface_hub, utils3d, and the prebuilt win_amd64"
    Write-Host "     wheels checked into the fork's whl/ folder (spconv, cumm, nvdiffrast,"
    Write-Host "     diffoctreerast, diff_gaussian_rasterization, kaolin) -- see this"
    Write-Host "     script's header comment for why we delegate instead of hand-pinning."
    Write-Host "  7. '$VenvPython' -m pip install '$ScriptDir'   (copy; -e if VIBE3D_AI3D_WORKER_EDITABLE=1)"
    Write-Host "  8. write $ConfigPath"
    Write-Host ""
    Write-Host "The model weights (jetx/TRELLIS-image-large, ~4 GB) are NOT downloaded"
    Write-Host "by this script. Run download_model.ps1 (or 'fetch-model') separately,"
    Write-Host "once, after this finishes."
}

Show-Plan
Write-Host ""
Test-GpuPreflight

if ($DryRun) {
    Write-Host ""
    Write-Host "-DryRun: no changes made."
    exit 0
}

Write-Host ""
Write-Host "Installing..."

New-Item -ItemType Directory -Force -Path $Location | Out-Null

if (Test-Path $VenvPython) {
    Write-Host "-- venv already exists at $VenvDir, reusing"
} else {
    Write-Host "-- creating venv at $VenvDir"
    & $PyInvoke[0] @(PyTail $PyInvoke) -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { Die "venv creation failed (exit $LASTEXITCODE)" 1 }
}

Write-Host "-- upgrading pip/setuptools/wheel"
& $VenvPython -m pip install --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) { Die "pip self-upgrade failed (exit $LASTEXITCODE)" 1 }

Write-Host "-- installing torch / torchvision (index: $TorchIndexUrl)"
& $VenvPython -m pip install torch torchvision --index-url $TorchIndexUrl
if ($LASTEXITCODE -ne 0) { Die "torch install failed (exit $LASTEXITCODE)" 1 }

if ($TrellisIsCloneTarget) {
    if (Test-Path (Join-Path $TrellisRootResolved ".git")) {
        Write-Host "-- TRELLIS checkout already present at $TrellisRootResolved, reusing"
    } else {
        Write-Host "-- cloning TRELLIS ($TrellisRepoUrl, --recursive) -> $TrellisRootResolved"
        $gitCmd = Get-Command "git" -ErrorAction SilentlyContinue
        if (-not $gitCmd) {
            Die "git not found on PATH. Install Git for Windows (https://git-scm.com/download/win, or winget install Git.Git) and re-run." 3
        }
        & git clone --recursive $TrellisRepoUrl $TrellisRootResolved
        if ($LASTEXITCODE -ne 0) { Die "git clone failed (exit $LASTEXITCODE)" 1 }
    }
} else {
    if (-not (Test-Path $TrellisRootResolved)) {
        Die "-TrellisRoot '$TrellisRootResolved' does not exist" 1
    }
    Write-Host "-- using existing TRELLIS checkout at $TrellisRootResolved"
}

# flexicubes (the mesh extractor on the worker's formats=['mesh'] decode
# path) is a git submodule; populate it whether we cloned fresh or reused a
# checkout -- same as install_linux.sh.
Write-Host "-- initializing TRELLIS submodules (flexicubes)"
Push-Location $TrellisRootResolved
try {
    & git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { Die "git submodule update failed (exit $LASTEXITCODE)" 1 }
} finally {
    Pop-Location
}

# Delegate to the fork's own install.py (see header comment for why): it
# knows the exact win_amd64 wheel filenames in its whl/ folder for the
# checkout it ships with. install.py uses sys.executable directly and does
# NOT create its own venv, so running it via $VenvPython's python.exe makes
# every pip call inside it land in OUR venv.
# TODO(windows): confirm install.py's cwd assumption -- it may expect to be
# run with the TRELLIS checkout as the working directory (it resolves its
# whl/ folder and requirements.txt relative to itself, which should be
# fine either way since __file__-relative resolution doesn't care about
# cwd, but this hasn't been exercised for real).
Write-Host "-- running TRELLIS's own install.py via the venv python (installs torch's"
Write-Host "   CUDA extensions from the fork's prebuilt whl/ wheels + its other deps)"
Push-Location $TrellisRootResolved
try {
    & $VenvPython (Join-Path $TrellisRootResolved "install.py")
    if ($LASTEXITCODE -ne 0) { Die "TRELLIS install.py failed (exit $LASTEXITCODE)" 1 }
} finally {
    Pop-Location
}

# Non-editable (copying) install by default -- same rationale as
# install_linux.sh: a packaged editor build runs this script from a
# location that should not be baked into the venv's install records.
if ($env:VIBE3D_AI3D_WORKER_EDITABLE -eq "1") {
    Write-Host "-- installing vibe3d_ai3d_worker (editable) from $ScriptDir"
    & $VenvPython -m pip install -e $ScriptDir
} else {
    Write-Host "-- installing vibe3d_ai3d_worker (copy) from $ScriptDir"
    & $VenvPython -m pip install $ScriptDir
}
if ($LASTEXITCODE -ne 0) { Die "worker package install failed (exit $LASTEXITCODE)" 1 }

Write-Host "-- writing config: $ConfigPath"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$TrellisRootAbs = (Resolve-Path $TrellisRootResolved).Path
$VenvPythonAbs  = (Resolve-Path $VenvPython).Path

# std.json-compatible JSON via PowerShell's own serializer (handles
# escaping correctly -- no sed-style hand escaping needed the way
# install_linux.sh's dependency-free approach does it).
$configObj = [ordered]@{
    version       = 1
    installed     = $true
    python        = $VenvPythonAbs
    backend       = "trellis"
    trellisRoot   = $TrellisRootAbs
    modelCacheDir = $null
    port          = $DefaultPort
}
$configJson = $configObj | ConvertTo-Json
# NOT `Set-Content -Encoding utf8`: on Windows PowerShell 5.1 (still the
# default on many Windows installs -- PowerShell 7 is a separate,
# opt-in install), -Encoding utf8 prepends a UTF-8 BOM. std.json's
# parseJSON does not skip a BOM, so worker_manager.d's loadAi3dConfig
# would silently treat a real, successful install as "malformed" and
# fall back to not-installed (see its own broad try/catch + logWarn).
# [System.Text.UTF8Encoding]::new($false) writes UTF-8 with NO BOM on
# both PS 5.1 and PS 7, avoiding the version split entirely.
[System.IO.File]::WriteAllText($ConfigPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Install complete."
Write-Host "  venv:    $VenvPythonAbs"
Write-Host "  TRELLIS: $TrellisRootAbs"
Write-Host "  config:  $ConfigPath"
Write-Host ""
Write-Host "Next step (separate, explicit, NOT run by this script):"
Write-Host "  tools\ai3d_worker\download_model.ps1"
Write-Host "to fetch the ~4 GB model weights before starting the worker."
