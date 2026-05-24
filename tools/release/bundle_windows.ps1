# Windows with-render release bundler.
# Windows' DLL loader does NOT search subdirectories of the exe by default,
# and the loader resolves static imports BEFORE main() runs (so the PATH
# tweak in app.d's ensureRuntimeLibPath() is too late for direct imports).
# Simplest reliable layout: flatten every DLL next to vibe3d.exe.
# hipbin\ (AMD GPU kernels, looked up by name) stays a subdirectory.
#
# Usage:
#   .\tools\release\bundle_windows.ps1 [-NoBuild] [-Output <path>]

[CmdletBinding()]
param(
    [switch]$NoBuild,
    [string]$Output
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
if (-not $Output) { $Output = "$repoRoot\vibe3d-windows-render.zip" }

Push-Location $repoRoot
try {
    if (-not $NoBuild) {
        # NOTE: --build=release currently SEGVs at startup on Windows
        # shortly after [osd_gl_smoke]. Latent UB exposed by
        # -O -inline -release -boundscheck=off; debug build is fine.
        # TODO: track down the offending site; until then ship debug.
        dub build --config=with-render
        if ($LASTEXITCODE -ne 0) { throw "dub build failed" }
    }
    if (-not (Test-Path "vibe3d.exe")) { throw "vibe3d.exe not present" }

    $stage = Join-Path $env:TEMP "vibe3d-windows-render"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Path $stage | Out-Null

    # `dub describe` occasionally writes "Warning" lines to stderr — under
    # $ErrorActionPreference = Stop PowerShell 5.1 promotes those to
    # terminating NativeCommandErrors regardless of `2>$null`. Drop pref
    # to Continue only for this call; we only need stdout (the JSON).
    $describe = $null
    & {
        $ErrorActionPreference = 'Continue'
        $script:describe = (dub describe --config=with-render 2>$null | Where-Object {
            $_ -match '^[\{\}\[\]\"\s\d]' -or $_ -match '^\s+'
        } | Out-String)
    }
    $j = $describe | ConvertFrom-Json
    $dCycles = ($j.packages | Where-Object { $_.name -eq 'd-cycles' }).path
    $rprPkg  = ($j.packages | Where-Object { $_.name -eq 'bindbc-rpr' }).path

    $cyclesLibBase = Join-Path $dCycles 'extern\blender\lib\windows_x64'
    $rprBinBase    = Join-Path $rprPkg  'extern\RadeonProRenderSDK\RadeonProRender\binWin64'
    $rprHipbin     = Join-Path $rprPkg  'extern\RadeonProRenderSDK\hipbin'

    # --- RPR runtime (flat, next to exe) --------------------------------
    Write-Host "[bundle] copying RPR runtime from $rprBinBase"
    foreach ($f in 'Northstar64.dll','RadeonProRender64.dll','HybridPro.dll',
                   'Hybrid.dll','Tahoe64.dll','RprLoadStore64.dll',
                   'ProRenderGLTF.dll') {
        $src = Join-Path $rprBinBase $f
        if (Test-Path $src) { Copy-Item $src -Destination "$stage\$f" }
    }
    # hipbin stays a subdirectory (RPR loads kernels from it by relative path)
    if (Test-Path $rprHipbin) { Copy-Item -Recurse $rprHipbin "$stage\hipbin" }

    # --- Cycles runtime (release DLLs only, skip _d / _debug variants) --
    Write-Host "[bundle] copying Cycles runtime from $cyclesLibBase"
    foreach ($subdir in 'openimageio','opencolorio','embree','openimagedenoise',
                        'openexr','imath','opensubdiv','tbb','dpcpp') {
        $bin = Join-Path $cyclesLibBase "$subdir\bin"
        if (-not (Test-Path $bin)) { continue }
        $allInDir = @(Get-ChildItem "$bin\*.dll" | ForEach-Object { $_.Name })
        Get-ChildItem "$bin\*.dll" | Where-Object {
            $n = $_.Name
            $isDebugSuffix  = $n -match '_d\.dll$|_d_.*\.dll$|_debug\.dll$'
            $isDebugVariant = ($n -match 'd\.dll$') -and
                              ($allInDir -contains ($n -replace 'd\.dll$', '.dll'))
            -not $isDebugSuffix -and -not $isDebugVariant
        } | ForEach-Object {
            Copy-Item $_.FullName "$stage\$($_.Name)"
        }
    }

    Copy-Item vibe3d.exe "$stage\vibe3d.exe"

    # SDL2.dll: try project root, then PATH, then C:\SDL2*\lib\x64\
    $sdl2src = $null
    if (Test-Path "SDL2.dll") {
        $sdl2src = "SDL2.dll"
    } else {
        $found = Get-Command "SDL2.dll" -ErrorAction SilentlyContinue
        if ($found) { $sdl2src = $found.Source }
    }
    if (-not $sdl2src) {
        $sdl2src = Get-ChildItem "C:\SDL2*\lib\x64\SDL2.dll" -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($sdl2src) {
        Write-Host "[bundle] SDL2.dll <- $sdl2src"
        Copy-Item $sdl2src "$stage\SDL2.dll"
    } else {
        Write-Warning "[bundle] SDL2.dll not found -- target machine must have SDL2 on PATH"
    }

    if (Test-Path "config")    { Copy-Item -Recurse config "$stage\config" }

    # Licenses: own MIT + attribution / full texts for bundled deps
    if (Test-Path "LICENSE")                  { Copy-Item LICENSE                  "$stage\LICENSE" }
    if (Test-Path "THIRD_PARTY_LICENSES.md")  { Copy-Item THIRD_PARTY_LICENSES.md  "$stage\THIRD_PARTY_LICENSES.md" }

    Write-Host "[bundle] zipping -> $Output"
    if (Test-Path $Output) { Remove-Item $Output }
    Compress-Archive -Path $stage -DestinationPath $Output
    $sz = (Get-Item $Output).Length / 1MB
    Write-Host ("[bundle] done: $Output ({0:N1} MB)" -f $sz)
} finally {
    Pop-Location
}
