# macOS release runner

The `macos-arm64` and `macos-x64` release jobs both run on the Apple Silicon
Mac mini. The Intel job uses Rosetta 2 and the tools under
`~/opt/vibe3d-macos-x64`; the arm64 job keeps using `/opt/homebrew`.

Provision the mini once as the runner account:

```bash
softwareupdate --install-rosetta --agree-to-license
tools/macos/setup_x64_toolchain.sh
```

The setup script installs pinned x86_64 LDC 1.42.0, universal CMake 4.3.3
(invoked in x86_64 mode), and x86_64 SDL2 2.32.10 targeting macOS 11. It
checks release SHA-256 hashes and does not change the arm64 Homebrew prefix.
It places symlinks to LDC's x64 static runtime in the x64 SDL2 library directory
so the linker selects them before Homebrew's arm64 libraries. The x64 app
requires macOS 13.3 because its pinned ONNX Runtime library has that minimum.
The x64 job keeps its DUB cache under `~/opt/vibe3d-macos-x64/dub`; the arm64
job uses `~/.dub`. Package builds and native CMake outputs are therefore
isolated by architecture. Re-run the setup script to repair an incomplete
installation or update SDL2 after changing its deployment target.

The workflow checks the architecture of the compiler, SDL2, executable and
bundled dynamic libraries before uploading an artifact. `build_app.sh` also
rewrites SDL2's install name in the executable to load the bundled copy.
