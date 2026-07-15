<#
.SYNOPSIS
    Provision the optional AI-generation runtime (TRELLIS image-to-3D
    backend) on Windows -- the Windows counterpart of install_linux.sh.

.DESCRIPTION
    This is the end-user-facing "Install" button's implementation on
    Windows: source/ai3d/worker_manager.d spawns this script (via
    `powershell -NoProfile -ExecutionPolicy Bypass -File ...`) and streams
    its output into the Generate 3D panel, the same way it spawns
    install_linux.sh on Linux. It can also be run by hand from a terminal.

    Verified end-to-end on real hardware (Win10 + RTX 3070 Ti, driver
    560.94 / CUDA 12.6) -- the earlier "UNTESTED, written on Linux" banner
    is gone along with the four first-real-run bugs it warned about; see
    the notes on the GPU preflight, the Python floor, and the install.py
    delegation below for what each of them was.

    What this script does:
      1. Locates a Python 3.11 interpreter, INSTALLING one (winget, or a
         silent python.org per-user installer) if none is present.
      2. GPU preflight: NVIDIA driver present, driver CUDA new enough to
         run the torch wheel index below under CUDA minor version
         compatibility, and enough VRAM.
      3. Creates a Python venv at <Location>\venv.
      4. Installs a CUDA build of torch/torchvision into that venv.
      5. Clones the TRELLIS fork (--recursive) to <Location>\TRELLIS (or
         reuses -TrellisRoot).
      6. Installs the fork's dependency set into the venv -- the same steps
         its own install.py runs, reimplemented here; see the "Why NOT
         delegate to install.py" note below.
      7. Installs this worker package itself (`pip install`, non-editable)
         so `python -m vibe3d_ai3d_worker serve` resolves inside the venv.
      8. Writes the config handshake file the editor reads:
         $env:LOCALAPPDATA\vibe3d\ai3d.json

    What this script deliberately does NOT do:
      - Download the ~4 GB TRELLIS model weights. That is a SEPARATE,
        explicit step (download_model.ps1 / `fetch-model`) -- never bundled
        into install, never triggered automatically by this script or by
        the worker itself.
      - Touch anything outside <Location>, the config file above, and (only
        when Python 3.11 is missing) a per-user Python 3.11 install.

    Why Python 3.11 EXACTLY (no 3.10 fallback): every CUDA-extension wheel
    the fork checks into its `whl/` folder is cp311-only --
    cumm_cu128-0.7.13-cp311-cp311-win_amd64.whl,
    spconv_cu128-2.3.8-cp311-cp311-win_amd64.whl, kaolin, nvdiffrast,
    diffoctreerast, diff_gaussian_rasterization. pip rejects every one of
    them on 3.10/3.12 ("not a supported wheel on this platform"). The old
    3.10 fallback here was a trap: it let the install run for many GB and
    then fail deep in the wheel step. There is no 3.10 wheel set to fall
    back TO, so 3.11 is a hard floor -- and since a missing 3.11 would
    otherwise dead-end the editor's one-click Install button, we install it
    rather than printing "go install Python and come back".

    Why NOT delegate to install.py (this script used to, before its first
    real Windows run): the fork's install.py is written for the
    StableProjectorz PORTABLE distribution, and its get_git_env() -- which
    it applies to EVERY pip/git command it runs -- unconditionally
    overwrites GIT_SSL_CAINFO and SSL_CERT_FILE with paths into a portable
    MinGit tree (`<install.py>/../tools/git/mingw64/etc/ssl/certs/...`)
    that does not exist in our layout. Git then refuses every https clone
    with "error setting certificate file", so install.py's
    `pip install git+https://.../utils3d.git` step fails and it exits 1.
    Nothing in the environment can undo that (get_git_env() overrides the
    inherited env, not the reverse), and patching a third-party checkout we
    just cloned is worse than owning the steps. So we run the same sequence
    it does -- torch, requirements.txt, xformers, huggingface_hub, utils3d,
    then the local wheels -- directly. Wheel-filename rot (the original
    reason for delegating) is handled by GLOBBING `whl\*.whl` instead of
    hard-coding the six names, so a fork bump changes nothing here.

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

.PARAMETER SkipPythonInstall
    Never install Python; fail with the old actionable error instead if no
    3.11 interpreter is found. Equivalent of
    VIBE3D_NO_PYTHON_INSTALL=1. -DryRun implies this.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install_windows.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install_windows.ps1 -Location D:\vibe3d-ai3d

.NOTES
    No CUDA Toolkit install is needed: the torch wheels from the index
    below BUNDLE the CUDA runtime, and the fork's extension wheels are
    prebuilt. Only an NVIDIA DRIVER is required -- which is exactly what
    the preflight checks.

    Env overrides (mirroring install_linux.sh's PYTHON / TORCH_INDEX_URL /
    TRELLIS_REPO_URL / VIBE3D_REQUIRED_CUDA / VIBE3D_MIN_VRAM_MB):
      VIBE3D_PYTHON            Python 3.11 launcher/exe to build the venv
                                from (default: auto-detect py -3.11 /
                                python3.11 / the standard per-user install
                                path; installed on demand if absent).
      VIBE3D_NO_PYTHON_INSTALL "1" == same as -SkipPythonInstall.
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
    [switch]$SkipGpuCheck,
    [switch]$SkipPythonInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

# cu128 matches both the fork's README ("A One-click installer for Windows:
# Python 3.11, Cuda 12.8, Torch 2.7") and its win_amd64 wheel filenames
# (e.g. spconv_cu128-*-cp311-cp311-win_amd64.whl). Confirmed against a real
# install: the wheels ship sm_86 cubins, so a pre-12.8 driver still runs
# them (see $MinDriverCuda below).
$TorchIndexUrl = if ($env:VIBE3D_TORCH_INDEX_URL) { $env:VIBE3D_TORCH_INDEX_URL } else { "https://download.pytorch.org/whl/cu128" }

# torch is PINNED, and this pin is load-bearing -- do not "modernize" it.
# The fork's prebuilt extension wheels (kaolin, nvdiffrast, diffoctreerast,
# diff_gaussian_rasterization) are compiled against libtorch's C++ ABI,
# which is NOT stable across torch minor releases: import them against the
# wrong torch and you get a bare "DLL load failed" with nothing pointing at
# the version skew. The fork targets torch 2.7 (its README's headline:
# "Python 3.11, Cuda 12.8, Torch 2.7").
#
# install.py -- which this script used to delegate to -- runs an UNPINNED
# `pip install torch torchvision torchaudio --index-url .../cu128`. That
# was only ever correct while 2.7 happened to be the current release; the
# cu128 index now serves 2.11, so the fork's own installer has quietly
# rotted into installing a torch its wheels cannot load. Pinning here (the
# way install_linux.sh pins torch==2.4.0 to match ITS wheel set) is what
# keeps the extension wheels loadable. Bump these two together, and only
# alongside a fork whose wheels are built for the new torch.
$TorchVersion       = if ($env:VIBE3D_TORCH_VERSION)       { $env:VIBE3D_TORCH_VERSION }       else { "2.7.1" }
$TorchvisionVersion = if ($env:VIBE3D_TORCHVISION_VERSION) { $env:VIBE3D_TORCHVISION_VERSION } else { "0.22.1" }
# xformers pins torch EXACTLY (0.0.31.post1's own metadata says
# `torch==2.7.1`), so it must be pinned in lockstep with $TorchVersion above
# -- and for the same reason install.py's version of this step
# (`pip install -U xformers`) is unsafe: `-U` resolves to the newest
# xformers, which drags its own newer torch in and silently undoes the pin
# two steps earlier. Same lockstep install_linux.sh keeps between its torch
# 2.4.0 and xformers 0.0.27.post2.
#
# ".post1" is REQUIRED, not incidental: the plain 0.0.31 win_amd64 wheel on
# the pytorch index is mispackaged -- its compiled extensions are stored as
# `xformers/pyd` and `xformers/flash_attn_3/pyd` instead of `_C.pyd` (the
# RECORD says so; it is the wheel, not our install). xformers then imports
# "successfully" but with NO C++ extensions, degrading to a warning at
# import and an exception at the first memory_efficient_attention call --
# i.e. mid-generation, long after install reported success. .post1 ships the
# files under their real names. The worker asks for this backend explicitly
# (server.py: ATTN_BACKEND=xformers), so a warning here is not survivable.
$XformersVersion    = if ($env:VIBE3D_XFORMERS_VERSION)    { $env:VIBE3D_XFORMERS_VERSION }    else { "0.0.31.post1" }

# The StableProjectorz TRELLIS fork, NOT upstream microsoft/TRELLIS -- same
# choice install_linux.sh makes and for the same reason (per-stage CPU<->GPU
# offload so FP16 TRELLIS fits an 8 GB card; see install_linux.sh's own
# comment for the full rationale). The fork additionally ships prebuilt
# win_amd64 wheels for its CUDA extensions in its `whl/` folder, which is
# what spares Windows the from-source CUDA build Linux does -- we install
# them straight out of the checkout (globbed; see the wheel step below).
$TrellisRepoUrl = if ($env:VIBE3D_TRELLIS_REPO_URL) { $env:VIBE3D_TRELLIS_REPO_URL } else { "https://github.com/IgorAherne/trellis-stable-projectorz.git" }

# GPU preflight thresholds. $WheelCuda is the CUDA the wheels were BUILT
# with, derived from the torch index tag (cu128 -> 12.8) so it tracks
# $TorchIndexUrl. $MinDriverCuda is what the DRIVER must actually report,
# and the two are NOT the same number:
#
# CUDA minor version compatibility (NVIDIA's guarantee since 11.0) means an
# application built against CUDA 12.x runs on ANY driver from the same major
# family -- 12.0 and up -- because the wheels bundle their own CUDA runtime
# and the driver ABI is stable within the major version. Demanding
# driver >= 12.8 for cu128 wheels, as this script did on its first real run,
# rejected working hardware: an RTX 3070 Ti on driver 560.94 (CUDA 12.6)
# runs the cu128 torch + the fork's cu128 extension wheels fine, verified
# by a real install + a real generation. The one case minor-version
# compatibility does NOT cover is PTX JIT of a newer ISA than the driver
# knows; that only bites GPUs with no precompiled cubin in the wheel, which
# for this wheel set (sm_86 and friends) is a Blackwell-era concern, not a
# 12.6-driver concern.
#
# So: hard-fail below the MAJOR floor, and merely WARN between the major
# floor and the wheel's own CUDA (where a brand-new GPU might need PTX JIT).
$cuMatch = [regex]::Match($TorchIndexUrl, 'cu(\d{3,})')
if ($cuMatch.Success) {
    $tag = $cuMatch.Groups[1].Value
    $WheelCuda = "$($tag.Substring(0,2)).$($tag.Substring(2))"
} else {
    $WheelCuda = "12.8"
}
# VIBE3D_REQUIRED_CUDA keeps overriding the hard floor (same name/semantics
# as install_linux.sh's, so the two scripts stay configurable alike).
$MinDriverCuda = if ($env:VIBE3D_REQUIRED_CUDA) {
    $env:VIBE3D_REQUIRED_CUDA
} else {
    "$(([version]$WheelCuda).Major).0"
}
$MinVramMb = if ($env:VIBE3D_MIN_VRAM_MB) { [int]$env:VIBE3D_MIN_VRAM_MB } else { 6000 }
$SkipGpuCheckEff = $SkipGpuCheck.IsPresent -or ($env:VIBE3D_SKIP_GPU_CHECK -eq "1")
$SkipPyInstallEff = $SkipPythonInstall.IsPresent -or ($env:VIBE3D_NO_PYTHON_INSTALL -eq "1") -or $DryRun.IsPresent

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
# Python interpreter discovery. EXACTLY 3.11 -- every CUDA-extension wheel
# the fork ships is cp311-only (see the header's "Why Python 3.11 EXACTLY").
# A 3.10/3.12 interpreter is not a degraded option, it is a guaranteed
# failure several GB into the install, so it is not accepted at all.
# ---------------------------------------------------------------------------
$RequiredPyVer      = "3.11"
$PythonWingetId     = "Python.Python.3.11"
# Pinned python.org fallback for hosts with no winget (pre-1809 Win10, or
# winget stripped from the image). 3.11.9 is the last 3.11 with an official
# binary installer; 3.11 is security-fix-only upstream, so this URL is
# stable rather than something that needs periodic bumping.
$PythonFallbackUrl  = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
$PythonUserInstall  = Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"

function Get-PyVersionString([string[]]$pyInvoke) {
    try {
        $out = & $pyInvoke[0] @(PyTail $pyInvoke) -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return "?" }
        return ([string]$out).Trim()
    } catch {
        return "?"
    }
}

function Test-PyInvoke([string[]]$pyInvoke) {
    return ((Get-PyVersionString $pyInvoke) -eq $RequiredPyVer)
}

function Find-Python {
    if ($env:VIBE3D_PYTHON) {
        return ,@($env:VIBE3D_PYTHON)
    }
    # Prefer the official `py` launcher (python.org's installer ships it by
    # default) with an explicit version pin -- it finds a 3.11 through the
    # registry even when only 3.12 is first on PATH, which is the common
    # multi-Python desktop case.
    if (Get-Command "py" -ErrorAction SilentlyContinue) {
        if (Test-PyInvoke @("py", "-3.11")) { return ,@("py", "-3.11") }
    }
    foreach ($cand in @("python3.11", $PythonUserInstall,
                        (Join-Path $env:ProgramFiles "Python311\python.exe"),
                        "python")) {
        # A full path needs Test-Path; a bare command needs Get-Command.
        $usable = if ($cand -match '[\\/]') { Test-Path $cand } else { [bool](Get-Command $cand -ErrorAction SilentlyContinue) }
        if ($usable -and (Test-PyInvoke @($cand))) { return ,@($cand) }
    }
    return $null
}

# Install Python 3.11 per-user (no admin, no PATH pollution -- we address
# the interpreter by absolute path / the py launcher afterwards, so we never
# need it to win a PATH race against the user's own Python).
function Install-Python311 {
    Write-Host "-- no Python $RequiredPyVer found; installing it (TRELLIS's CUDA wheels are cp311-only)"

    if (Get-Command "winget" -ErrorAction SilentlyContinue) {
        Write-Host "   winget install $PythonWingetId --scope user"
        # winget's exit code is unreliable here (it reports non-zero for
        # benign outcomes like "already installed"), so the re-discovery
        # below -- not $LASTEXITCODE -- is what decides success.
        & winget install --id $PythonWingetId --source winget --scope user --silent `
                         --accept-package-agreements --accept-source-agreements
        $found = Find-Python
        if ($found) { return $found }
        Write-Host "   winget did not yield a usable $RequiredPyVer; falling back to the python.org installer"
    } else {
        Write-Host "   winget not available; using the python.org installer"
    }

    $exe = Join-Path ([System.IO.Path]::GetTempPath()) "python-3.11.9-amd64.exe"
    Write-Host "   downloading $PythonFallbackUrl"
    try {
        # Explicit TLS 1.2: PS 5.1 still defaults to SSL3/TLS1.0 here, which
        # python.org refuses.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $PythonFallbackUrl -OutFile $exe -UseBasicParsing
    } catch {
        Die "failed to download the Python $RequiredPyVer installer: $($_.Exception.Message)`n       Install Python $RequiredPyVer yourself (https://python.org/downloads/) and re-run, or set `$env:VIBE3D_PYTHON." 3
    }
    Write-Host "   running the installer (per-user, silent)"
    # Start-Process -Wait, NOT `& $exe`: the python.org installer is a GUI
    # subsystem binary, and the call operator does not block on those -- it
    # would return instantly, and the Find-Python + Remove-Item below would
    # then race an installer that has not written python.exe yet (and delete
    # its own running image out from under it).
    #
    # InstallAllUsers=0 keeps it admin-free; PrependPath=0 leaves the user's
    # PATH alone; Include_launcher=1 gives us `py -3.11` for the re-discovery.
    $proc = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList @(
        "/quiet", "InstallAllUsers=0", "PrependPath=0", "Include_launcher=1", "Include_test=0")
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        Die "the Python $RequiredPyVer installer failed (exit $($proc.ExitCode))`n       Install Python $RequiredPyVer yourself (https://python.org/downloads/) and re-run, or set `$env:VIBE3D_PYTHON." 3
    }

    return (Find-Python)
}

$PyInvoke = Find-Python
if (-not $PyInvoke -and -not $SkipPyInstallEff) {
    $PyInvoke = Install-Python311
}
if (-not $PyInvoke) {
    $msg = @"
no Python $RequiredPyVer found (looked for the 'py' launcher with -3.11,
then python3.11, the standard per-user/all-users install paths, and a bare
'python' that happens to be $RequiredPyVer).

TRELLIS's CUDA extension wheels are cp311-only -- 3.10 and 3.12 cannot work.
Install Python $RequiredPyVer from https://python.org/downloads/ or via winget:
    winget install $PythonWingetId
then re-run. Or set `$env:VIBE3D_PYTHON to an explicit $RequiredPyVer interpreter.
"@
    if ($DryRun) { Write-Warning $msg } else { Die $msg 3 }
    $PyVer = "?"
} else {
    $PyVer = Get-PyVersionString $PyInvoke
    # Only reachable via VIBE3D_PYTHON -- Find-Python version-checks everything
    # else -- but a wrong explicit override deserves the same early, cheap
    # failure rather than a wheel error several GB in.
    if ($PyVer -ne $RequiredPyVer) {
        $msg = "$($PyInvoke -join ' ') is Python $PyVer -- unsupported. TRELLIS's " +
               "CUDA extension wheels are cp311-only, so Python $RequiredPyVer is required. " +
               "Point `$env:VIBE3D_PYTHON at a $RequiredPyVer interpreter and re-run."
        if ($DryRun) { Write-Warning $msg } else { Die $msg 3 }
    }
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
    Write-Host "-- GPU preflight (need NVIDIA + driver CUDA >= $MinDriverCuda + >= $MinVramMb MiB VRAM)"

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
        if ([version]$cuda -lt [version]$MinDriverCuda) {
            Fail-Gpu "NVIDIA driver supports CUDA $cuda, but the torch wheels ($TorchIndexUrl) need a CUDA $($([version]$MinDriverCuda).Major).x driver (>= $MinDriverCuda). Update the NVIDIA driver."
        } elseif ([version]$cuda -lt [version]$WheelCuda) {
            # Fine under CUDA minor version compatibility -- see $MinDriverCuda's
            # comment. Said out loud anyway so that if a very new GPU ever does
            # hit the PTX-JIT edge, the driver gap is already in the install log.
            Write-Host "   note: driver CUDA $cuda is older than the wheels' CUDA $WheelCuda -- fine (CUDA $($([version]$WheelCuda).Major).x minor version compatibility); update the driver if you hit PTX JIT errors on a very new GPU."
        }
    } else {
        Fail-Gpu "could not read the driver's CUDA version from nvidia-smi (need >= $MinDriverCuda)."
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
    Write-Host "  0. GPU preflight: NVIDIA driver present, driver CUDA >= $MinDriverCuda,"
    Write-Host "     >= $MinVramMb MiB VRAM (skip with -SkipGpuCheck). No CUDA Toolkit"
    Write-Host "     needed -- the torch wheels bundle the CUDA runtime; only a driver is."
    Write-Host "  1. New-Item -ItemType Directory '$Location' (if missing)"
    Write-Host "  2. $($PyInvoke -join ' ') -m venv '$VenvDir'   (skipped if it already exists)"
    Write-Host "  3. '$VenvPython' -m pip install --upgrade pip setuptools wheel"
    Write-Host "  4. '$VenvPython' -m pip install torch==$TorchVersion torchvision==$TorchvisionVersion --index-url '$TorchIndexUrl'"
    if ($TrellisIsCloneTarget) {
        Write-Host "  5. git clone --recursive '$TrellisRepoUrl' '$TrellisRootResolved'   (skipped if present)"
    } else {
        Write-Host "  5. (using existing checkout)"
    }
    Write-Host "     + git submodule update --init --recursive   (flexicubes)"
    Write-Host "  6. TRELLIS deps into the venv -- the same sequence the fork's own"
    Write-Host "     install.py runs, reimplemented here (its get_git_env() hard-wires a"
    Write-Host "     portable-MinGit CA path we don't have, which breaks its utils3d clone;"
    Write-Host "     see this script's header): requirements.txt, xformers, huggingface_hub,"
    Write-Host "     utils3d, then every prebuilt win_amd64 wheel in the fork's whl\ folder"
    Write-Host "     (spconv, cumm, nvdiffrast, diffoctreerast, diff_gaussian_rasterization,"
    Write-Host "     kaolin -- globbed, never hand-pinned), then fast-simplification."
    Write-Host "  7. '$VenvPython' -m pip install '$ScriptDir'   (copy; -e if VIBE3D_AI3D_WORKER_EDITABLE=1)"
    Write-Host "  8. verify: import torch/xformers/spconv/kaolin/utils3d + run one GPU"
    Write-Host "     kernel (a failure here means NO config is written)"
    Write-Host "  9. write $ConfigPath"
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

Write-Host "-- installing torch $TorchVersion / torchvision $TorchvisionVersion (index: $TorchIndexUrl)"
& $VenvPython -m pip install "torch==$TorchVersion" "torchvision==$TorchvisionVersion" --index-url $TorchIndexUrl
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

# The fork's dependency set. This mirrors install.py's own sequence rather
# than calling it -- see the header's "Why NOT delegate to install.py" (its
# get_git_env() forces GIT_SSL_CAINFO at a portable-MinGit CA bundle that
# only exists in the StableProjectorz distribution, so its utils3d step
# cannot clone in our layout).
#
# Ordering is install.py's, and it matters: requirements.txt pins the cu118
# spconv/cumm, and the cu128 wheels from whl\ must land AFTER it to win.
# torch is already installed above (step 4), which is install.py's first
# step too.
function Invoke-VenvPip([string[]]$pipArgs, [string]$desc) {
    Write-Host "-- $desc"
    & $VenvPython -m pip install @pipArgs
    if ($LASTEXITCODE -ne 0) { Die "$desc failed (exit $LASTEXITCODE)" 1 }
}

$ReqTxt = Join-Path $TrellisRootResolved "requirements.txt"
if (Test-Path $ReqTxt) {
    Invoke-VenvPip @("-r", $ReqTxt) "installing TRELLIS requirements.txt"
} else {
    Write-Warning "no requirements.txt in $TrellisRootResolved -- skipping (fork layout changed?)"
}

Invoke-VenvPip @("xformers==$XformersVersion", "--index-url", $TorchIndexUrl) "installing xformers $XformersVersion (index: $TorchIndexUrl)"
Invoke-VenvPip @("huggingface_hub") "installing huggingface_hub"

# utils3d is pinned to the same commit install.py pins -- an unpinned master
# is exactly the kind of drift the fork pinned away from.
Invoke-VenvPip @("git+https://github.com/EasternJournalist/utils3d.git@9a4eb15e4021b67b12c460c7057d642626897ec8") "installing utils3d (pinned commit)"

# The prebuilt CUDA extensions. GLOBBED, not hand-pinned: the fork bumps
# these filenames (cumm/spconv carry both a version and a cu-tag) and a
# hard-coded list would rot silently on the next fork bump, which was the
# original argument for delegating to install.py in the first place.
$WhlDir = Join-Path $TrellisRootResolved "whl"
if (-not (Test-Path $WhlDir)) {
    Die "no whl\ folder in $TrellisRootResolved -- this checkout does not look like the StableProjectorz fork (its prebuilt win_amd64 CUDA extension wheels live there)." 1
}
$Wheels = @(Get-ChildItem -Path (Join-Path $WhlDir "*.whl") -File | Sort-Object Name)
if ($Wheels.Count -eq 0) {
    Die "no .whl files in $WhlDir -- expected the fork's prebuilt CUDA extension wheels (spconv, cumm, kaolin, ...)." 1
}
Write-Host "-- installing $($Wheels.Count) prebuilt CUDA extension wheels from $WhlDir"
foreach ($w in $Wheels) {
    Invoke-VenvPip @($w.FullName) "installing $($w.Name)"
}

# fast_simplification: the worker's quadric decimate (server.py
# TrellisBackend) -- same explicit step install_linux.sh carries, and not
# something either requirements.txt or the wheels pull in.
Invoke-VenvPip @("fast-simplification") "installing fast-simplification (worker mesh decimate)"

# Deliberately NOT installing gradio/gradio_litmodel3d the way install.py
# finishes: that is for the fork's own web demo app, which we never launch
# (the worker drives the pipeline in-process). requirements.txt already
# pulls gradio in anyway, so this only skips install.py's redundant re-pin.

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

# Verify BEFORE writing the config: the config is a handshake that tells the
# editor "installed: true", and the editor believes it. An environment that
# resolved wrong must fail here, loudly, rather than be advertised as ready
# and then blow up at generation time as a stack trace in the worker log.
#
# Importing kaolin/spconv is the point -- they are the compiled extensions
# whose C++ ABI must match the pinned torch, so a torch re-resolve anywhere
# in the steps above (a fork requirements.txt bump, a transitive dep pulling
# a newer torch) surfaces right here as an ImportError instead of a "DLL
# load failed" mid-generation weeks later.
Write-Host "-- verifying the installed environment"
# Written to a temp .py and run as a FILE, not passed to `python -c`: Windows
# PowerShell 5.1 mangles double quotes inside an argument handed to a native
# exe, so `-c` arrived at python with every string literal stripped of its
# quotes (`expected = "2.7.1"` -> `expected = 2.7.1` -> SyntaxError). A file
# hands python the bytes we wrote, with no shell in the middle.
#
# The here-string is SINGLE-quoted (literal): the expected torch version comes
# in through argv instead of PowerShell interpolation, so nothing in this
# python source can be rewritten by the shell.
$verifyScript = Join-Path ([System.IO.Path]::GetTempPath()) "vibe3d_ai3d_verify.py"
$verifyPy = @'
import sys
import torch

expected = sys.argv[1]
actual = torch.__version__.split("+")[0]
if actual != expected:
    sys.exit("torch is %s but this install pinned %s -- something re-resolved it; "
             "the fork's prebuilt extension wheels are built against %s and will "
             "not load." % (actual, expected, expected))

import xformers            # noqa: F401
import spconv              # noqa: F401
import kaolin              # noqa: F401
import utils3d             # noqa: F401

print("   torch %s (cuda build %s), cuda available: %s"
      % (torch.__version__, torch.version.cuda, torch.cuda.is_available()))
if not torch.cuda.is_available():
    sys.exit("torch cannot see the GPU -- generation would fail. Check the "
             "NVIDIA driver.")

print("   device: %s" % torch.cuda.get_device_name(0))
# Touch the GPU for real: is_available() only checks the driver, while a
# cubin/PTX mismatch (the one thing CUDA minor version compatibility does
# not cover) only shows up once a kernel actually runs.
torch.zeros(8, device="cuda").add_(1).sum().item()
print("   GPU kernel launch: ok")

# xformers' C++ extensions specifically, exercised rather than imported.
# `import xformers` SUCCEEDS with a mispackaged wheel and only prints a
# warning -- the failure surfaces at the first attention call, which is deep
# inside a generation. The worker forces this backend (server.py sets
# ATTN_BACKEND=xformers), so prove the actual kernel runs here instead.
import xformers.ops
q = torch.randn(1, 8, 4, 16, device="cuda", dtype=torch.float16)
xformers.ops.memory_efficient_attention(q, q, q)
print("   xformers memory_efficient_attention: ok")
'@
Set-Content -Path $verifyScript -Value $verifyPy -Encoding ASCII
& $VenvPython $verifyScript $TorchVersion
$verifyRc = $LASTEXITCODE
Remove-Item $verifyScript -Force -ErrorAction SilentlyContinue
if ($verifyRc -ne 0) { Die "environment verification failed (exit $verifyRc) -- NOT writing $ConfigPath, so the editor will keep treating the add-on as not installed." 1 }

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
