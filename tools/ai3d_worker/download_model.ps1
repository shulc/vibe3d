<#
.SYNOPSIS
    Download the TRELLIS image-to-3D model weights (~4 GB) into the
    HuggingFace cache -- the Windows counterpart of download_model.sh.

.DESCRIPTION
    The Vibe3D AI-3D worker NEVER auto-downloads the model at generation
    time. Run this script ONCE, explicitly, before you start the `trellis`
    backend. It is a thin wrapper around the worker's `fetch-model`
    subcommand (vibe3d_ai3d_worker/server.py) -- every argument is passed
    straight through.

    NOTE: source/ai3d/worker_manager.d does NOT spawn this wrapper for the
    editor's "Install" button chain on Windows -- it calls the venv python
    directly (`<venv>\Scripts\python.exe -m vibe3d_ai3d_worker fetch-model`),
    since `fetch-model` is a stdlib-only, fully cross-platform argparse
    subcommand and needs no shell wrapper for that path. This script exists
    for a user who wants to run the download by hand from a terminal, or
    re-fetch/`-Check` later -- mirroring download_model.sh's standalone role
    on Linux.

.PARAMETER Model
    HuggingFace model id (default: jetx/TRELLIS-image-large).

.PARAMETER CacheDir
    HuggingFace cache dir (default: the standard cache, honoring
    $env:HF_HUB_CACHE / $env:HF_HOME).

.PARAMETER Revision
    Pin a commit / tag / branch for reproducibility.

.PARAMETER Check
    Report whether the model is already cached WITHOUT downloading
    (offline-safe; exit 0 = present, 3 = absent).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File download_model.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File download_model.ps1 -Check

.NOTES
    Environment: the actual download needs `huggingface_hub` installed, so
    this runs the AI-generation venv's python -- taken from the install
    handshake config ($env:LOCALAPPDATA\vibe3d\ai3d.json) that
    install_windows.ps1 writes, or from $env:VIBE3D_PYTHON, which overrides
    it. Only if neither is available does it fall back to a bare `python`
    off PATH (which will almost certainly lack huggingface_hub -- hence the
    warning it prints). -Check works even in a bare stdlib-only env (it
    falls back to a filesystem probe of the cache). $env:PYTHONPATH is set
    to this directory so `-m vibe3d_ai3d_worker` resolves without an
    install, whether or not a venv is active.
#>
[CmdletBinding()]
param(
    [string]$Model = "",
    [string]$CacheDir = "",
    [string]$Revision = "",
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Resolve the interpreter: explicit override, else the venv install_windows.ps1
# recorded in the handshake config, else a bare `python`. That last one is a
# near-certain failure for a real download (no huggingface_hub in a system
# python), so it warns rather than failing later with an opaque ImportError --
# the editor's own Install chain never lands here (worker_manager.d calls the
# venv python directly, see the note above), so this path only ever runs for
# someone at a terminal, who deserves to be told which python they got.
function Resolve-Python {
    if ($env:VIBE3D_PYTHON) { return $env:VIBE3D_PYTHON }

    $cfg = Join-Path $env:LOCALAPPDATA "vibe3d\ai3d.json"
    if (Test-Path $cfg) {
        try {
            $json = Get-Content -Raw -Path $cfg | ConvertFrom-Json
            # -notin on a PSCustomObject's properties: guard both a missing
            # key and a null/empty value before trusting the path.
            if ($json.PSObject.Properties.Name -contains "python" -and $json.python) {
                if (Test-Path $json.python) { return $json.python }
                Write-Warning "config $cfg points at a python that does not exist: $($json.python)"
            }
        } catch {
            Write-Warning "could not read $cfg ($($_.Exception.Message)) -- falling back to PATH"
        }
    }

    Write-Warning "no AI-generation venv found (is the add-on installed?) -- using 'python' from PATH, which probably lacks huggingface_hub. Set `$env:VIBE3D_PYTHON to override."
    return "python"
}

$Python = Resolve-Python

$env:PYTHONPATH = if ($env:PYTHONPATH) { "$ScriptDir;$env:PYTHONPATH" } else { $ScriptDir }

$fetchArgs = @("-m", "vibe3d_ai3d_worker", "fetch-model")
if ($Model.Length -gt 0)    { $fetchArgs += @("--model", $Model) }
if ($CacheDir.Length -gt 0) { $fetchArgs += @("--cache-dir", $CacheDir) }
if ($Revision.Length -gt 0) { $fetchArgs += @("--revision", $Revision) }
if ($Check.IsPresent)       { $fetchArgs += "--check" }

& $Python @fetchArgs
exit $LASTEXITCODE
