; =============================================================================
; Vibe3D — Windows installer (Inno Setup 6 script)
; =============================================================================
;
; FIRST DRAFT — authored on Linux, NOT yet compiled or tested on Windows.
; The maintainer must build + smoke-test this with iscc.exe on a real Windows
; box before shipping. See tools/release/windows/README.md.
;
; What this produces:
;   vibe3d-setup-<version>.exe — a self-contained installer that lays down the
;   editor into "Program Files\Vibe3D", creates Start-Menu (and optional
;   desktop) shortcuts, and registers an uninstaller in "Add/Remove Programs".
;
; SELF-CONTAINED / NO PREREQUISITES:
;   The payload is a NATIVE binary plus app-local DLLs (SDL2.dll,
;   onnxruntime.dll, and the full Visual C++ CRT redistributable set —
;   MSVCP140*.dll / VCRUNTIME140*.dll). Everything the editor needs at runtime
;   ships INSIDE this installer and is copied next to vibe3d.exe. The end-user
;   machine needs NOTHING else: no VC++ Redistributable prerequisite, no Python,
;   no bash, no PATH setup. This exactly mirrors the CI "Zip artifact (Windows)"
;   payload (see .github/workflows/build.yml) so the installed tree is byte-for
;   -byte the same file set as the plain release zip.
;
; PAYLOAD SOURCE (the {#PayloadDir} defined below) is expected to be a FLAT
; staging directory containing:
;     vibe3d.exe
;     SDL2.dll
;     onnxruntime.dll               (default "modeling" / WithAI build only)
;     MSVCP140.dll, MSVCP140_1.dll, VCRUNTIME140.dll, VCRUNTIME140_1.dll, ...
;     config\                       (tool presets, shortcuts, etc.)
;     assets\                       (app icon set, ...)
;   Optionally: LICENSE, THIRD_PARTY_LICENSES.md, vibe3d.ico
;   This is produced by build_windows_installer.ps1 from either the CI
;   "vibe3d-windows.zip" or a local `dub build --config=modeling` on Windows.
;
; noai VARIANT: the "modeling-noai" (Windows 7) build drops onnxruntime.dll and
;   instead ships the UCRT app-local DLLs (ucrtbase.dll + api-ms-win-crt-*.dll).
;   This SAME script builds that installer unchanged — the [Files] "*.dll" glob
;   below picks up whichever DLL set the payload contains. Only two knobs would
;   differ for a noai installer: pass a payload without onnxruntime.dll, and set
;   MinVersion=6.1 (see the MinVersion note in [Setup]). No script edit needed.
;
; AI GENERATION ADDON is intentionally OUT OF SCOPE here: the TRELLIS/ai3d
;   worker is Linux-only today (Windows support is a later "Phase 2"). This
;   installer ships the EDITOR ONLY — tools/ai3d_worker/ is never staged. A
;   future Windows AI addon would need its own PowerShell provisioner plus a
;   bundled/downloaded Python runtime, NOT the Linux install_linux.sh bash flow.
; =============================================================================


; ---------------------------------------------------------------------------
; Parameters — override any of these on the iscc.exe command line, e.g.
;   iscc /DAppVersion=1.2.3 /DPayloadDir=C:\stage /DOutputDir=C:\dist vibe3d.iss
; build_windows_installer.ps1 passes all of them for you.
; ---------------------------------------------------------------------------

#define AppName "Vibe3D"
#define AppPublisher "Alexander Shagarov"
#define AppURL "https://github.com/shulc/vibe3d"
#define AppExeName "vibe3d.exe"

; Version string shown in the wizard + Add/Remove Programs. A release passes the
; git tag (e.g. "0.4.1" or "nightly"); the fallback keeps a manual compile from
; failing. Not a semver-validated field — any string is accepted.
#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

; Flat staging directory holding the payload (see the header comment). Relative
; paths resolve against this .iss file's own directory (Inno's SourcePath).
#ifndef PayloadDir
  #define PayloadDir "payload"
#endif

; Where the compiled setup .exe is written, and its base file name.
#ifndef OutputDir
  #define OutputDir "dist"
#endif
#ifndef OutputBaseName
  #define OutputBaseName "vibe3d-setup-" + AppVersion
#endif

; Icon used for the setup .exe itself AND (installed to {app}) for the shortcuts.
; Defaults to the multi-resolution icon that already ships inside the payload's
; assets/. build_windows_installer.ps1 overrides this with a staged copy (and
; can regenerate it from PNG via ImageMagick if the .ico is ever missing).
#ifndef AppIcon
  #define AppIcon PayloadDir + "\assets\icon\vibe3d.ico"
#endif

; License shown on the wizard's license page. Defaults to the repo LICENSE
; (three levels up from tools/release/windows/). Only wired in if it exists.
#ifndef LicenseFile
  #define LicenseFile SourcePath + "..\..\..\LICENSE"
#endif


[Setup]
; ---------------------------------------------------------------------------
; AppId — the STABLE identity of this application for upgrades + uninstall.
; It is hard-coded ON PURPOSE and MUST NEVER CHANGE across releases: Inno keys
; the "installed / needs upgrade / uninstall" records off this GUID. Change it
; and Windows treats every future build as a brand-new product (duplicate
; Add/Remove Programs entries, no in-place upgrade, orphaned old install).
; The leading "{{" is Inno's escape for a literal "{" — the stored value is
; "{383E236E-B03E-4D27-B9D6-6FD928769037}".
AppId={{383E236E-B03E-4D27-B9D6-6FD928769037}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}/releases

; Install under Program Files (64-bit): {autopf} = Program Files when elevated.
DefaultDirName={autopf}\Vibe3D
DefaultGroupName=Vibe3D
DisableProgramGroupPage=yes
AllowNoIcons=yes

; Program Files is machine-wide, so require admin elevation.
; TODO(windows): if a per-user (no-admin) install is ever wanted, set
;   PrivilegesRequiredOverridesAllowed=dialog commandline
; and {autopf} will fall back to the per-user Programs folder automatically.
PrivilegesRequired=admin

; 64-bit only. "x64compatible" (Inno Setup 6.3+) also permits ARM64 Windows
; running the x64 build under emulation, and makes {autopf} resolve to the real
; 64-bit "Program Files" (not the x86 one). Verified compiling with Inno Setup
; 6.7.3; the build helper enforces >= 6.3. (Pre-6.3 would need plain "x64".)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; MinVersion 10.0: the default "modeling" (WithAI) payload links onnxruntime.dll,
; which imports Win8+ apisets, and relies on the in-box Universal CRT that ships
; with Windows 10+. (The noai payload ships its own UCRT and would set 6.1 for
; Windows 7 — see the noai note in the header.)
; Verified: the modeling/WithAI build installs + launches on Windows 10.
MinVersion=10.0

; Compression + wizard look.
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

; In-place upgrade over a running editor: use the Restart Manager to detect +
; close a running vibe3d.exe (and any process holding an installed file) so the
; new version can overwrite it, instead of failing with "file in use". We do NOT
; auto-restart the app afterwards (RestartApplications=no) — the user relaunches.
; Verified: reinstalling over an existing install upgrades in place (same AppId,
; same dir); user settings (prefs/imgui.ini, not shipped files) are preserved.
CloseApplications=yes
RestartApplications=no

; Setup .exe icon + the icon shown in Add/Remove Programs.
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}

; Output location + file name of the produced installer.
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}

; License page — only added when the LICENSE file is actually present at compile
; time (the preprocessor drops the directive otherwise so iscc never errors).
#if FileExists(LicenseFile)
LicenseFile={#LicenseFile}
#endif


[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"


[Tasks]
; Desktop shortcut is opt-in (unchecked by default), like most installers.
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked


[Files]
; The executable.
Source: "{#PayloadDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; ALL DLLs shipped flat next to the exe — SDL2.dll, onnxruntime.dll (modeling
; only), and the full app-local VC++ CRT redistributable set. The glob is
; deliberate: it makes the installer self-contained no matter which exact CRT
; DLLs the C++ deps pull in, and it transparently handles the noai payload
; (no onnxruntime.dll, plus the UCRT api-ms-win-crt-*.dll / ucrtbase.dll set).
; The Windows loader does NOT search subdirectories, so every DLL must be
; alongside the exe (flat), exactly as the release zip lays them out.
Source: "{#PayloadDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion

; Data directories (tool presets, app icon set, ...). recursesubdirs +
; createallsubdirs preserve the tree.
Source: "{#PayloadDir}\config\*"; DestDir: "{app}\config"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs

; Standalone icon installed at the app root, used by the shortcuts below. Kept
; separate from the exe's embedded resource so shortcut icons work even if the
; embedded resource ever changes.
Source: "{#AppIcon}"; DestDir: "{app}"; DestName: "vibe3d.ico"; Flags: ignoreversion

; License texts — copied only if present in the payload (the ps1 stages them
; from the repo root; the bare CI zip does not include them).
Source: "{#PayloadDir}\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#PayloadDir}\THIRD_PARTY_LICENSES.md"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; NOTE(windows): tools/ai3d_worker/ (the Linux-only AI generation backend) is
; intentionally NOT staged/installed — the editor ships alone here (see header).


[Icons]
; WorkingDir is set to {app} so the editor resolves its relative config/ and
; assets/ paths from the install folder regardless of where the shortcut is
; launched from. Verified: launching from {app} (Program Files) resolves config/
; and starts the editor. Note: the editor also WRITES runtime files (imgui.ini,
; prefs, event log) to its CWD = {app}; on a standard (non-admin) account those
; writes land in the per-user VirtualStore or are skipped — settings persistence
; from Program Files is imperfect. A future editor change should read config/
; from the exe dir and write user data under %APPDATA% (tracked as a follow-up).
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\vibe3d.ico"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\vibe3d.ico"; Tasks: desktopicon


[Run]
; Offer to launch the editor when the wizard finishes (skipped in silent mode).
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent


[UninstallDelete]
; Remove editor-generated files that would otherwise leave {app} non-empty and
; block full cleanup. imgui.ini is written next to the exe by Dear ImGui.
; TODO(windows): add other runtime-generated files here if the editor writes any
; (logs, recorded event sessions, cached grids) into the install folder.
Type: files; Name: "{app}\imgui.ini"
