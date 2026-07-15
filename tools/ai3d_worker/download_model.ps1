<#
.SYNOPSIS
    Download the TRELLIS image-to-3D model weights (~4 GB) into the
    HuggingFace cache -- the Windows counterpart of download_model.sh.

.DESCRIPTION
    TODO(windows): UNTESTED -- written on Linux, never run on a real
    Windows box. See install_windows.ps1's banner for the same caveat.

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
    run this using the AI-generation venv's python (or set $env:VIBE3D_PYTHON
    to that interpreter). -Check works even in a bare stdlib-only env (it
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
$Python = if ($env:VIBE3D_PYTHON) { $env:VIBE3D_PYTHON } else { "python" }

$env:PYTHONPATH = if ($env:PYTHONPATH) { "$ScriptDir;$env:PYTHONPATH" } else { $ScriptDir }

$fetchArgs = @("-m", "vibe3d_ai3d_worker", "fetch-model")
if ($Model.Length -gt 0)    { $fetchArgs += @("--model", $Model) }
if ($CacheDir.Length -gt 0) { $fetchArgs += @("--cache-dir", $CacheDir) }
if ($Revision.Length -gt 0) { $fetchArgs += @("--revision", $Revision) }
if ($Check.IsPresent)       { $fetchArgs += "--check" }

& $Python @fetchArgs
exit $LASTEXITCODE
