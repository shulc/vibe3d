# Vendored `nfde` — pins and local patches

This directory is a **vendored** copy of the `nfde` D bindings for
[Native File Dialog Extended](https://github.com/btzy/nativefiledialog-extended)
(NFD). It was vendored into vibe3d (task 0431) to build the Linux file-dialog
backend against **xdg-desktop-portal** (`NFD_PORTAL=ON`) instead of GTK3, and to
make the build hermetic (the upstream `nfde` package git-cloned NFD from GitHub
at build time, so the NFD revision could silently drift between hosts).

## Upstream pins

| Component | Upstream | Pin |
|-----------|----------|-----|
| `nfde` D wrapper (`source/`, `dub.json`, `LICENSE`) | Chance Snow, dub registry package `nfde` | 0.1.3 (Zlib) |
| Native File Dialog Extended (`nativefiledialog-extended/`) | `github.com/btzy/nativefiledialog-extended` | `e092bbb4578583c6fd0edc2cd14fb9c658194a4d` (Zlib) |
| `xdg-foreign-unstable-v1.xml` (Wayland xdg-foreign protocol) | `wayland-protocols` submodule of NFD | submodule commit `88223018d1b578d0d8869866da66d9608e05f928`; file sha256 `bf5ea82077193a03b511e04f483a2a1bcf7f91e3e93bc550be4a69a74c0ad571` (MIT/X11, © Red Hat) |

Only the files needed to build the static library were vendored. Not copied:
`nfde`'s `bin/ docs/ examples/ scripts/ views/`; NFD's `test/ screens/ .github/
out/ .git`; all of `wayland-protocols` except the single `xdg-foreign`
`.xml`. Build artefacts (`nativefiledialog-extended/out/`, `bin/`, `.dub/`) are
git-ignored.

## Local patches (diff vs. the pins above)

### 1. `dub.json` — build the portal backend, hermetically

- `preBuildCommands-posix` was split into `preBuildCommands-linux` (adds
  `-DNFD_PORTAL=ON`) and `preBuildCommands-osx` (no `NFD_PORTAL`; portal is a
  Linux-only NFD option). The `git clone` step was removed from the linux/osx/
  windows preBuild commands — NFD is vendored, not fetched.
- `libs-linux`: `gtk-3` → `dbus-1` (the portal backend links libdbus-1, not GTK).
- Removed the `buildTypes` (`docs`), `stringImportPaths` (`views`), and
  `subPackages` (`./examples/dialogs`) entries — none are needed to build the
  library, and their supporting directories were not vendored.
- Windows/macOS link config (`lflags-windows`, `libs-windows`, `lflags-osx`) is
  carried over verbatim; those platforms build byte-for-byte as before, minus
  the network clone.

### 2. `source/nfde.d` — do not abort the process on a failed init

Upstream `static this()` `assert`ed that `NFD_Init()` succeeded. Under the
portal backend `NFD_Init()` opens a D-Bus **session-bus** connection, which
fails on a host that has a `DISPLAY` but no session bus (e.g. CI running
`vibe3d --test` under `xvfb-run`, or a headless service account). An assert
there would abort **every** process start. Patch:

- `static this()`: replace the `assert` with a `stderr` warning; leave
  `isInitialized = false` on failure.
- `openDialog` / `openDialogMultiple` / `saveDialog` / `pickFolder`: each now
  early-returns `Result.error` when `!isInitialized`, so a failed init degrades
  to a no-op menu action instead of dereferencing the (null) global D-Bus
  connection inside NFD. (vibe3d only calls `openDialog`/`saveDialog`, but all
  four public entry points are guarded for safety.)

- `static this()` (task 0431 CI-fix): the stderr-warning soften above assumes
  `NFD_Init()` **returns** on failure. It does not always. With no
  `DBUS_SESSION_BUS_ADDRESS`, the portal backend's `dbus_bus_get()` attempts
  **autolaunch** (spawns `dbus-launch`); on a restricted/headless service env
  (the self-hosted CI runner) `dbus-launch` "terminates abnormally" and trips an
  **internal libdbus assertion that `abort()`s the process** before `NFD_Init()`
  can return — killing the shared `vibe3d --test` server and cascading every
  test on that worker to FAIL. So, on `version (linux)` only, skip `NFD_Init()`
  entirely when `DBUS_SESSION_BUS_ADDRESS` is empty/unset (leave
  `isInitialized=false`): no session-bus address ⇒ the portal is unreachable
  regardless, and autolaunch is never provoked. A real desktop always exports
  `DBUS_SESSION_BUS_ADDRESS`, so interactive dialogs are unaffected.

Neutral on Windows/macOS: their `NFD_Init()` does not fail this way, so
`isInitialized` stays true and the guards never trip (the `DBUS_*` skip is
`version (linux)`-gated).

### 3. `nativefiledialog-extended/src/nfd_portal.cpp` — survive a bus disconnect

libdbus defaults `exit_on_disconnect = TRUE`: if the session bus drops
mid-session (user logout, `dbus-daemon` restart) libdbus calls `_exit(1)` and
kills the host application, losing unsaved work. The portal backend holds its
`dbus_conn` **process-wide for the whole app lifetime** (unlike the old GTK
backend, which used a transient connection), so this default is dangerous here.
Patch: immediately after `NFD_Init()` obtains the connection, call
`dbus_connection_set_exit_on_disconnect(dbus_conn, FALSE)` so a disconnect is a
soft failure (subsequent dialog calls return an error) rather than process
death.

### 4. `configure_guarded.cmake` — a new file; the build survives its own path changing

Not present upstream in any form. Added by task 0673 and wired in front of the
`cmake -B` in each of the three `preBuildCommands` sets.

CMake bakes the absolute paths it was configured for into `CMakeCache.txt`
(`CMAKE_CACHEFILE_DIR`, `CMAKE_HOME_DIRECTORY`). Reach these same files under a
second absolute path and CMake refuses to reuse `nativefiledialog-extended/out`
and fails the build. vibe3d does exactly that on every release run: the matrix
build compiles under the runner's own workspace path, then the AppImage step
bind-mounts that same workspace into a container at `/src` and runs its own
`dub build` there. Before this file, the second build died on the first
directory the first build had left behind.

Until task 0662 the situation could not arise, because these commands began
with `rm -rf .../out` and a directory that never survives cannot be stale.
Removing that wipe was right on its own terms (it rebuilt the whole C++ backend
for a one-line D change) but it silently took the path-indifference with it.
This script restores the property and keeps the speed: the `cmake -B` runs
unchanged, and the directory is cleared **only** when CMake refused **and** the
cache in it names some other directory.

Two things not to "simplify", both measured in 0673 and both explained at
length in the script's own header:

- Do not replace it with an up-front string comparison of the cached path.
  CMake compares by device+inode, so the same directory seen under two visible
  names is *accepted*; a string test is stricter than CMake and would discard
  warm caches CMake is happy with.
- Do not check only `CMAKE_CACHEFILE_DIR`. A configure CMake accepted under a
  second path rewrites that entry but leaves `CMAKE_HOME_DIRECTORY` on the old
  path, so a cache can be stale in the source half alone.

Regression test: `tests/test_cmake_path_guard.d` — it exercises the path
change, not the build, and asserts the two negatives (an unchanged path and an
unrelated configure error must both leave the directory alone) as well as the
recovery.

## Re-vendoring procedure

1. `git clone https://github.com/btzy/nativefiledialog-extended` and check out
   the desired pin; `git submodule update --init 3ps/wayland-protocols` to
   obtain `unstable/xdg-foreign/xdg-foreign-unstable-v1.xml`.
2. Fetch the matching `nfde` D wrapper from the dub registry (`dub fetch nfde@<version>`).
3. Copy the file set listed above into `third_party/nfde/`.
4. Re-apply patches 1–4 (4 is a whole file — keep `configure_guarded.cmake` and
   the `preBuildCommands` that call it) and update the pin table.
5. Rebuild: `rm -f dub.selections.json && dub build`, then confirm with
   `nm -D ./vibe3d | grep dbus_message` (present) and
   `ldd ./vibe3d | grep -i gtk` (absent).
