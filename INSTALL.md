# Installing Vibe3D

Vibe3D ships as a **self-contained download per platform** — no separate runtime
or dependency install for the editor itself. Grab the artifact for your OS from
the [Releases page](https://github.com/shulc/vibe3d/releases) and run it.

Optional AI image→3D generation is a **Linux-only opt-in add-on** installed from
inside the editor (it is *not* bundled) — see [AI generation](#optional-ai-image3d-generation-linux).

---

## Linux — AppImage

The Linux download is a single self-contained **`Vibe3D-x86_64.AppImage`**. It
bundles SDL2 and the GTK3 file-dialog stack, so no system packages are required.

```bash
chmod +x Vibe3D-x86_64.AppImage
./Vibe3D-x86_64.AppImage
```

- **Compatibility:** built against **glibc 2.30**, so it runs on Ubuntu 20.04+,
  Debian 11+, Fedora 32+, and anything newer. Works on both **Wayland and X11**
  (SDL2 picks the backend at runtime; falls back to XWayland if needed).
- **Graphics:** needs an OpenGL **3.3 Core** driver — i.e. your GPU's normal
  system driver (Mesa/NVIDIA/AMD). This is the one thing the AppImage does *not*
  bundle (drivers are host-specific). In a GPU-less VM you can force software
  rendering with Mesa's `llvmpipe` (`LIBGL_ALWAYS_SOFTWARE=1`).
- **Desktop integration:** optional — the AppImage carries its `.desktop` + icon;
  tools like [Gear Lever](https://github.com/mijorus/gearlever) or
  `AppImageLauncher` can register it in your menu.

---

## Windows

Two self-contained options (pick either):

### Zip (portable)
Download **`vibe3d-windows.zip`**, unzip it anywhere **writable** (e.g. your
Desktop or Documents — not `C:\Program Files`), and run `vibe3d.exe`. The zip
already contains `SDL2.dll`, `onnxruntime.dll`, and the Visual C++ runtime DLLs
app-local, so **no VC++ Redistributable is required**.

- **`vibe3d-windows.zip`** — the full build. Requires **Windows 10 or newer**
  (its `onnxruntime.dll` uses Win10-era APIs).
- **`vibe3d-windows-win7.zip`** — a reduced build for **Windows 7/8** (no
  onnxruntime; the "AI" panel is compiled out).

### Installer *(first version — verify before relying on it)*
`vibe3d-setup-<version>.exe` installs into `Program Files\Vibe3D` with Start-Menu
and optional desktop shortcuts and an uninstaller. See
[`tools/release/windows/README.md`](tools/release/windows/README.md) for how it
is built. It is unsigned, so SmartScreen will warn on first run
(*More info → Run anyway*).

> **Graphics note:** Windows needs an OpenGL 3.3 driver too. Real hardware has
> this via the GPU driver. A GPU-less VM (QEMU VESA, etc.) does **not** — drop a
> Mesa `llvmpipe` `opengl32.dll` next to `vibe3d.exe` (from
> [mesa-dist-win](https://github.com/pal1000/mesa-dist-win)) for software OpenGL.

AI image→3D generation is **not available on Windows yet** (the generation
worker is Linux-only); its buttons appear greyed out.

---

## macOS

Download **`vibe3d-macos-arm64.zip`** (Apple Silicon) or **`vibe3d-macos-x64.zip`**
(Intel), unzip, and move `Vibe3D.app` to Applications. SDL2 is bundled inside the
`.app`.

The app is **not code-signed / notarized**, so Gatekeeper blocks it on first
launch. Either right-click the app → **Open** → **Open**, or clear the quarantine
flag:

```bash
xattr -dr com.apple.quarantine /Applications/Vibe3D.app
```

AI image→3D generation is **not available on macOS** (the generation worker is
Linux-only); its buttons appear greyed out.

---

## Optional: AI image→3D generation (Linux)

An opt-in add-on turns a reference image into a mesh. It is **not part of the
base download** — you install it from inside the editor, and it downloads a
~several-GB model from Hugging Face on first setup.

**Requirements (Linux only):**
- An **NVIDIA GPU** with a recent driver (the installer preflights driver +
  CUDA version and **≥ 6 GB VRAM**).
- **Python 3.11** (or 3.10) on `PATH`.
- Several GB of disk for the Python environment + the model weights.
- Network access for the first-time model + dependency download.

**How to install:** open **Generate 3D** in the editor and click **Install AI
generation**. That runs `tools/ai3d_worker/install_linux.sh` (shipped next to the
editor), which builds an isolated environment and provisions the generation
backend; then use **Start** / **Stop** to run it. Model download is a separate,
explicit step (`Download model`, or `tools/ai3d_worker/download_model.sh`).

The first generation after starting the worker is slow (it loads the model and
compiles GPU kernels — up to a few minutes); subsequent runs take ~15–35 s.

---

## Build from source

See [`README.md`](README.md) for building with `dub` + LDC.
