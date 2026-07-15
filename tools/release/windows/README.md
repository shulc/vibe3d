# Vibe3D — Windows installer

Wraps the self-contained Windows editor payload into a proper
`vibe3d-setup-<version>.exe` using **[Inno Setup](https://jrsoftware.org/isinfo.php)**.
The installer lays the editor down under `Program Files\Vibe3D`, creates
Start-Menu (and optional desktop) shortcuts, and registers an uninstaller in
**Add/Remove Programs**.

> ⚠️ **UNTESTED — FIRST DRAFT.** These files were authored on Linux and have
> **not** been compiled or run on Windows. Build and smoke-test them on a real
> Windows box (see [Verify](#verify) below) before shipping. Anything marked
> `TODO(windows): verify` needs a human check against actual Inno Setup / Windows
> behavior.

## What ships / self-contained guarantee

The end-user needs **nothing but the produced `vibe3d-setup-<version>.exe`**.
There is **no VC++ Redistributable prerequisite, no Python, no bash, no PATH
setup**. The payload is a native binary plus every runtime DLL, laid down flat
next to `vibe3d.exe`:

| Installed to `Program Files\Vibe3D\` | From |
|---|---|
| `vibe3d.exe` | the build |
| `SDL2.dll` | SDL2 devel release |
| `onnxruntime.dll` | ONNX Runtime (default `modeling`/WithAI build only) |
| `MSVCP140*.dll`, `VCRUNTIME140*.dll`, … | the Visual C++ CRT redistributable, shipped **app-local** |
| `config\`, `assets\` | the repo |
| `vibe3d.ico`, `LICENSE.txt`, `THIRD_PARTY_LICENSES.md` | packaging |

This is exactly the file set CI's **"Zip artifact (Windows)"** step produces
(see `.github/workflows/build.yml`) — the installed tree matches the plain
release zip.

The **AI-generation addon** (TRELLIS / `tools/ai3d_worker/`) is **Linux-only**
today and **out of scope** here — this installs the **editor only**. Windows AI
support is a later "Phase 2" and would need its own PowerShell provisioner plus a
bundled/downloaded Python runtime (not the Linux `install_linux.sh` bash flow).

## Files

| File | Purpose |
|---|---|
| `vibe3d.iss` | The Inno Setup script (payload → installer). |
| `build_windows_installer.ps1` | PowerShell helper: stages the payload, ensures `vibe3d.ico`, finds `iscc.exe`, compiles the installer. |
| `README.md` | This file. |

## Prerequisites (maintainer's Windows box only)

These are **build-time** tools on the machine that *produces* the installer.
None of them are needed on the end-user machine.

1. **Inno Setup 6** (provides `iscc.exe`) — **required**:
   ```powershell
   winget install JRSoftware.InnoSetup
   # or:  choco install innosetup
   ```
   Inno Setup **6.3+** is recommended (the script uses the `x64compatible`
   architecture identifier; on older 6.x, change it to `x64` — see the TODO in
   `vibe3d.iss`).
2. **ImageMagick** — *optional*, only used to regenerate `vibe3d.ico` from PNG if
   the icon is ever missing from the payload (it normally ships in
   `assets\icon\vibe3d.ico`, so ImageMagick is usually not needed):
   ```powershell
   winget install ImageMagick.ImageMagick
   ```

`iscc.exe` is auto-discovered on `PATH` and in
`C:\Program Files (x86)\Inno Setup 6\`; pass `-IsccPath` to override.

## Where the payload comes from

The helper accepts either a **flat directory** or a **`.zip`**:

* **CI artifact (recommended):** download `vibe3d-windows.zip` from the GitHub
  Actions "Build" run (the `zip-windows` artifact) and pass it directly:
  ```powershell
  .\build_windows_installer.ps1 -Version 0.4.1 -Payload .\vibe3d-windows.zip
  ```
* **Local build on Windows:** build the default modeling config, then point the
  helper at a directory you assemble with the same file set:
  ```powershell
  dub build --config=modeling --compiler=ldc2 --build=release --d-version=ReleaseBuild
  ```
  (You must stage `vibe3d.exe` + `SDL2.dll` + `onnxruntime.dll` + the VC++ CRT
  DLLs + `config\` + `assets\` into one folder — the CI "Zip artifact (Windows)"
  step in `.github/workflows/build.yml` is the reference for that exact set.)

If `-Payload` is omitted, the helper looks for `vibe3d-windows.zip` in the
current directory and then the repo root.

### noai (Windows 7) variant

The same `vibe3d.iss` builds the `modeling-noai` installer unchanged — just feed
it a noai payload (`vibe3d-windows-win7.zip`): it drops `onnxruntime.dll` and
adds the UCRT app-local DLLs, and the script's `*.dll` glob picks up whichever
set is present. For a true Win7 target you would also lower `MinVersion` to `6.1`
in `vibe3d.iss` (see its header + `MinVersion` note).

## Build it

```powershell
# From the repo root, with the CI zip in hand:
.\tools\release\windows\build_windows_installer.ps1 -Version 0.4.1 -Payload .\vibe3d-windows.zip

# ...or from an already-unzipped payload directory:
.\tools\release\windows\build_windows_installer.ps1 -Version 0.4.1 -Payload C:\stage\vibe3d-windows
```

Options: `-OutputDir <dir>` (default `<repo>\dist`), `-IssPath <file>`,
`-IsccPath <iscc.exe>`. Run `Get-Help .\build_windows_installer.ps1 -Full` for
the full parameter reference.

### Expected output

```
dist\vibe3d-setup-0.4.1.exe
```

(plus a `dist\_stage\` scratch folder the helper stages into — safe to delete).

## Verify

On a Windows machine (ideally a clean VM with **no** Visual C++ redistributable
and **no** dev tools installed, to prove the self-contained guarantee):

1. Run `vibe3d-setup-<version>.exe`, accept the license, install.
2. Confirm the Start-Menu shortcut launches the editor, and that the optional
   desktop shortcut appears only when its task is checked.
3. Confirm `config\` + `assets\` landed under `Program Files\Vibe3D\` and the
   editor finds them (the shortcuts set `WorkingDir` to the install folder).
4. Uninstall from Add/Remove Programs and confirm the folder is removed cleanly.
5. Re-install a newer `-Version` and confirm it **upgrades in place** (same
   `AppId`) rather than creating a second Add/Remove Programs entry.

## Known limitations / notes

- **Untested** on Windows (authored on Linux) — treat every run as a first run.
- **`AppId` is stable and must never change** (`vibe3d.iss` hard-codes the GUID).
  Changing it breaks in-place upgrades and orphans prior installs.
- **`x64compatible`** requires Inno Setup 6.3+. On older 6.x, switch both
  `Architectures*` directives to `x64` (noted in `vibe3d.iss`).
- **`MinVersion=10.0`** is a conservative guess for the modeling (WithAI) build
  (onnxruntime imports Win8+ apisets + relies on the in-box UCRT). Verify the
  real minimum; lower it (and ship UCRT) for a Win7 noai installer.
- **Code signing** is not configured. An unsigned setup triggers SmartScreen
  ("Windows protected your PC"). For a public release, sign the setup with a
  code-signing certificate (`SignTool=` in `[Setup]`, or `signtool.exe` on the
  output) — out of scope for this first draft.
- No **auto-update** mechanism; users download + run each new setup manually.
