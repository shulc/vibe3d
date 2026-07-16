module ai3d.worker_manager;

// ---------------------------------------------------------------------------
// Ai3dWorkerManager — editor-owned lifecycle for the optional AI-3D
// (TRELLIS) worker subprocess (task 0403). Before this module existed, the
// end user had to run `python -m vibe3d_ai3d_worker serve` by hand in a
// terminal before opening the Generate 3D panel. This module lets the
// editor do that itself: Install (spawn install_linux.sh on Linux /
// install_windows.ps1 on Windows, then chain into the model-download stage
// — see downloadStageArgs()), Start (spawn the worker, then the caller
// polls /v1/health via ai3d.stage_artifact.probeHealthCheck — the SAME call
// the Generate 3D modal's health line already drives through
// Ai3dJobController.probeHealth(), so no new health-check code path exists),
// and Stop (signal + reap the worker WE spawned).
//
// Config handshake: a small versioned JSON file written by the platform
// install script (install_linux.sh / install_windows.ps1) and read here —
// see Ai3dInstallConfig / loadAi3dConfig / saveAi3dConfig. Format follows
// prefs.d's convention (versioned, tolerant parseJSON read, std.json write
// — never dyaml, this file is machine-written + machine-read). Default
// location honors XDG_DATA_HOME on Linux / %LOCALAPPDATA% on Windows (see
// ai3dConfigDir()) — this is desired-state DATA the editor manages, not
// user config preferences, hence the XDG_DATA_HOME-style location rather
// than prefs.d's XDG_CONFIG_HOME-style one.
//
// Process ownership: this class tracks ONLY processes IT spawned (its own
// `Pid`). It never discovers or touches a worker running on the configured
// port that some OTHER process started — Stop can only ever kill a PID this
// object itself holds. This is deliberate: a stray/foreign process on
// 127.0.0.1:<port> (e.g. an operator's own manually-started worker) must
// never be killed by an unrelated Stop click.
//
// Non-blocking, single-threaded: like remesh.remesh_job.RemeshJob, there is
// no worker thread here — the "worker" is the OS process itself.
// pollWorker()/pollInstall() are non-blocking per-frame polls (tryWait);
// nothing in this module blocks on I/O except the bounded SIGTERM-then-wait
// escalation inside stopWorker()/shutdown() (capped well under a second of
// worst case grace before the SIGKILL fallback).
// ---------------------------------------------------------------------------

import std.array   : replace;
import std.conv    : to;
import std.file    : exists, read, write, mkdirRecurse, getSize, dirEntries, SpanMode, thisExePath;
import std.json    : JSONValue, JSONType, parseJSON, JSONException;
import std.path    : buildPath, dirName, isAbsolute;
import std.process : environment, Pid, spawnProcess, tryWait, kill, wait;
import std.stdio   : File, stdin;
import core.time   : MonoTime, msecs, seconds;
import core.thread : Thread;

import log : logWarn;
import ai3d.stage_artifact : normalizeLocalWorkerUrl;

// ---------------------------------------------------------------------------
// Config schema (v1)
// ---------------------------------------------------------------------------

enum int kAi3dConfigVersion = 1;

/// The worker's own `serve --port` argparse default in
/// vibe3d_ai3d_worker/server.py — kept in sync manually. `startWorker()`
/// below always passes `--port` explicitly when THIS module spawns the
/// worker, so the constant is inert on that path; it matters for the
/// manually-started-worker case the module doc comment (top of file)
/// describes (`python -m vibe3d_ai3d_worker serve` run by hand with no
/// `--port`, so the worker binds ITS OWN default) — health-probe /
/// "already running" detection reads `config_.port`, which falls back to
/// this constant, so a stale value here makes vibe3d probe the wrong port
/// and miss a manually-started worker. Cross-checked against server.py by
/// the hermetic sync-check unittest below.
enum int kAi3dDefaultPort = 47831;

/// The model install_linux.sh provisions by default (TrellisBackend's own
/// default in vibe3d_ai3d_worker/server.py — kept in sync manually, this is
/// display/probe-only, never sent to the worker itself: the worker resolves
/// its own default independently). Also cross-checked against server.py by
/// the hermetic sync-check unittest below.
enum string kAi3dDefaultModel = "jetx/TRELLIS-image-large";

/// Persisted install handshake (schema v1), written by install_linux.sh and
/// read by the editor. One flat file, last-writer-wins — same concurrency
/// stance as prefs.d (accepted for a single-user desktop app).
struct Ai3dInstallConfig {
    int    version_ = kAi3dConfigVersion;
    bool   installed;
    string python;          // absolute venv python (or a bare command name in tests)
    string backend = "trellis"; // "trellis" | "fake" (test-only) | "triposr"
    string trellisRoot;     // absolute TRELLIS checkout path; unused for non-trellis backends
    string modelCacheDir;   // absolute HF cache override, or "" == standard cache
    int    port = kAi3dDefaultPort;
}

/// Clamp a JSON/user-supplied port to the legal TCP port range, falling back
/// to the default rather than passing a bogus `--port` through to the
/// spawned worker (kernel-boundary clamp, independent of any UI hint).
private int clampPort(int p) {
    if (p < 1 || p > 65535) return kAi3dDefaultPort;
    return p;
}

/// Directory holding `ai3d.json`. Resolution order:
///   1. $VIBE3D_AI3D_CONFIG_DIR  (tests, multi-instance debugging — highest)
///   2. Windows: %LOCALAPPDATA%\vibe3d
///      else:    $XDG_DATA_HOME/vibe3d else ~/.local/share/vibe3d
string ai3dConfigDir() {
    if (auto over = environment.get("VIBE3D_AI3D_CONFIG_DIR"))
        if (over.length > 0) return over;
    version (Windows) {
        // %LOCALAPPDATA%\vibe3d -- LOCALAPPDATA (not the roaming %APPDATA%
        // prefs.d itself uses) matches the module doc comment's framing:
        // this is desired-state DATA the editor manages (mirrors XDG_DATA_HOME
        // on Linux), not roaming user config/preferences. Matches
        // install_windows.ps1's own default location.
        const local = environment.get("LOCALAPPDATA", "");
        return buildPath(local, "vibe3d");
    } else {
        if (auto xdg = environment.get("XDG_DATA_HOME"))
            if (xdg.length > 0) return buildPath(xdg, "vibe3d");
        const home = environment.get("HOME", "");
        return buildPath(home, ".local", "share", "vibe3d");
    }
}

/// Full path to the config handshake file the editor reads and
/// install_linux.sh writes.
string ai3dConfigPath() { return buildPath(ai3dConfigDir(), "ai3d.json"); }

/// The install location install_linux.sh uses when `--location` is not
/// given (display-only — the Install confirmation popup names this path so
/// the user knows where the ~6-8 GB runtime lands before confirming).
string ai3dDefaultInstallLocation() { return buildPath(ai3dConfigDir(), "ai3d"); }

/// Load `path` into an Ai3dInstallConfig. NEVER throws: missing file ->
/// defaults (not installed); malformed JSON -> logWarn + defaults; unknown
/// keys ignored; a corrupted `port` falls back to the default rather than
/// being passed through as-is.
Ai3dInstallConfig loadAi3dConfig(string path) {
    Ai3dInstallConfig c; // defaults: not installed
    if (!exists(path)) return c;

    JSONValue doc;
    try {
        doc = parseJSON(cast(string) read(path));
    } catch (Exception e) {
        logWarn("ai3d", "malformed ai3d.json, treating as not installed: " ~ e.msg);
        return c;
    }
    if (doc.type != JSONType.object) {
        logWarn("ai3d", "ai3d.json top-level value is not an object");
        return c;
    }

    try {
        if (auto vp = "version" in doc)
            if (vp.type == JSONType.integer) c.version_ = cast(int) vp.integer;

        if (auto ip = "installed" in doc) {
            if (ip.type == JSONType.true_) c.installed = true;
            else if (ip.type == JSONType.false_) c.installed = false;
        }

        if (auto pp = "python" in doc)
            if (pp.type == JSONType.string) c.python = pp.str;

        if (auto bp = "backend" in doc)
            if (bp.type == JSONType.string) c.backend = bp.str;

        if (auto tp = "trellisRoot" in doc)
            if (tp.type == JSONType.string) c.trellisRoot = tp.str;

        if (auto mp = "modelCacheDir" in doc)
            if (mp.type == JSONType.string) c.modelCacheDir = mp.str;
            // JSONType.null_ -> leave "" (== null / standard cache)

        if (auto po = "port" in doc) {
            long v = -1;
            if (po.type == JSONType.integer) v = po.integer;
            else if (po.type == JSONType.uinteger) v = cast(long) po.uinteger;
            c.port = clampPort(v > int.max || v < int.min ? -1 : cast(int) v);
        }
    } catch (JSONException e) {
        logWarn("ai3d", "ai3d.json partially malformed, using what parsed: " ~ e.msg);
    }

    return c;
}

/// Serialize `c` to `path` (creating the parent dir if needed). Throws only
/// on filesystem failure — callers driving this from install_linux.sh (a
/// bash script) never hit this D path directly; it exists for tests and any
/// future in-editor "repair config" affordance.
void saveAi3dConfig(ref const Ai3dInstallConfig c, string path) {
    JSONValue doc = JSONValue(cast(JSONValue[string]) null);
    doc["version"]       = JSONValue(kAi3dConfigVersion);
    doc["installed"]     = JSONValue(c.installed);
    doc["python"]        = JSONValue(c.python);
    doc["backend"]       = JSONValue(c.backend);
    doc["trellisRoot"]   = JSONValue(c.trellisRoot);
    doc["modelCacheDir"] = c.modelCacheDir.length ? JSONValue(c.modelCacheDir) : JSONValue(null);
    doc["port"]          = JSONValue(clampPort(c.port));

    mkdirRecurse(dirName(path));
    write(path, doc.toPrettyString());
}

// ---------------------------------------------------------------------------
// Model-cache presence probe — a pure filesystem check, mirroring
// vibe3d_ai3d_worker/server.py's `_resolve_cache_dir` / `_fs_find_snapshot`
// fallback path (used there when huggingface_hub itself isn't installed).
// Deliberately NEVER shells out to python for this: it runs on the UI
// thread (panel refresh), so it must be fast and non-blocking.
// ---------------------------------------------------------------------------

/// The user's home directory, resolved the way PYTHON resolves `~` -- which
/// is what matters here, because every path this module derives from it is
/// really "wherever huggingface_hub (a python library) put the weights".
///
/// On Windows that is CPython's ntpath.expanduser: %USERPROFILE%, then
/// %HOMEDRIVE%%HOMEPATH%. Emphatically NOT $HOME -- that is a POSIX-ism
/// Windows does not set (only a Git-Bash/MSYS shell injects one). Reading
/// $HOME here used to leave the cache path RELATIVE ("" joined with
/// ".cache"), so the editor probed `.cache\huggingface\hub` under its own
/// CWD while python downloaded to `C:\Users\<you>\.cache\huggingface\hub`:
/// the ~4 GB of weights were on disk and the panel reported them missing,
/// forever.
private string userHomeDir() {
    version (Windows) {
        if (auto up = environment.get("USERPROFILE"))
            if (up.length) return up;
        const drive = environment.get("HOMEDRIVE", "");
        const path  = environment.get("HOMEPATH", "");
        if (path.length) return drive ~ path;
        return "";
    } else {
        return environment.get("HOME", "");
    }
}

/// Resolve the HuggingFace hub cache directory the same way
/// huggingface_hub itself does: explicit override > $HF_HUB_CACHE >
/// $HF_HOME/hub > $XDG_CACHE_HOME/huggingface/hub > ~/.cache/huggingface/hub.
/// (huggingface_hub honors $XDG_CACHE_HOME on every platform, Windows
/// included -- see its constants.py -- so that step is NOT posix-only.)
string resolveModelCacheDir(string explicitOverride) {
    if (explicitOverride.length) return explicitOverride;
    if (auto hub = environment.get("HF_HUB_CACHE"))
        if (hub.length) return hub;
    if (auto hfHome = environment.get("HF_HOME"))
        if (hfHome.length) return buildPath(hfHome, "hub");
    string base;
    if (auto xdg = environment.get("XDG_CACHE_HOME"))
        if (xdg.length) base = xdg;
    if (base.length == 0) base = buildPath(userHomeDir(), ".cache");
    return buildPath(base, "huggingface", "hub");
}

/// True iff a non-empty snapshot directory for `model` exists under the
/// resolved cache. Best-effort/heuristic (a partial download could
/// false-positive, same caveat as the python fallback it mirrors); never
/// throws.
bool modelSnapshotPresent(string model, string cacheDirOverride) {
    const cache = resolveModelCacheDir(cacheDirOverride);
    const repoFolder = "models--" ~ model.replace("/", "--");
    const snapshots = buildPath(cache, repoFolder, "snapshots");
    if (!exists(snapshots)) return false;
    try {
        foreach (snapEntry; dirEntries(snapshots, SpanMode.shallow)) {
            if (!snapEntry.isDir) continue;
            foreach (fileEntry; dirEntries(snapEntry.name, SpanMode.depth))
                if (fileEntry.isFile) return true;
        }
    } catch (Exception) {
        // best-effort probe; any I/O hiccup reads as "not present"
    }
    return false;
}

// ---------------------------------------------------------------------------
// Ai3dWorkerManager
// ---------------------------------------------------------------------------

enum Ai3dWorkerState { notInstalled, installedStopped, running }

enum Ai3dInstallState { idle, runningInstall, runningDownload, succeeded, failed }

final class Ai3dWorkerManager {
    private string configPath_;
    private Ai3dInstallConfig config_;
    private bool   configExists_;
    private bool   modelPresent_;

    private Pid    pid_;
    private bool   hasPid_;

    private Pid    installPid_;
    private bool   hasInstallPid_;
    private string installLogPath_;
    private File   installLogFile_;
    private Ai3dInstallState installState_ = Ai3dInstallState.idle;
    private string installMessage_;
    private string downloadScriptPath_;
    private bool   downloadModelAfterInstall_;

    this(string configPath = ai3dConfigPath()) {
        configPath_ = configPath;
        refresh();
    }

    // --- config / state --------------------------------------------------

    /// Re-read the config file and re-probe model presence. Call on panel
    /// open and after an install finishes; cheap (one small JSON parse +
    /// a bounded directory walk), safe to call from the UI thread.
    void refresh() {
        configExists_ = exists(configPath_);
        config_       = loadAi3dConfig(configPath_);
        modelPresent_ = (config_.backend == "trellis")
            ? modelSnapshotPresent(kAi3dDefaultModel, config_.modelCacheDir)
            : true; // non-trellis backends (fake, triposr) need no HF model cache
    }

    Ai3dWorkerState state() const {
        if (hasPid_) return Ai3dWorkerState.running;
        if (!configExists_ || !config_.installed) return Ai3dWorkerState.notInstalled;
        return Ai3dWorkerState.installedStopped;
    }

    bool modelPresent() const { return modelPresent_; }
    Ai3dInstallConfig config() const { return config_; }
    string configPath() const { return configPath_; }

    /// The loopback URL the spawned (or to-be-spawned) worker listens on.
    /// Always run through normalizeLocalWorkerUrl (loopback-only, project
    /// convention) even though the host half is hardcoded to 127.0.0.1 here
    /// — defense in depth against a future config gaining a host field.
    string workerUrl() const {
        const raw = "http://127.0.0.1:" ~ clampPort(config_.port).to!string;
        const norm = normalizeLocalWorkerUrl(raw);
        return norm.length ? norm : raw;
    }

    private string dataDir() const { return buildPath(dirName(configPath_), "data"); }

    // --- worker lifecycle --------------------------------------------------

    /// Spawn the worker subprocess (non-blocking — does NOT wait for
    /// /v1/health). No-op (false) if already running, not installed, or the
    /// interpreter path looks unusable. `extraEnv` merges into the child's
    /// environment (tests use it to set PYTHONPATH for an uninstalled
    /// worker package against a bare system python3 — see the fake-backend
    /// lifecycle unittest below); production installs never need it, since
    /// install_linux.sh's venv has the worker package installed.
    bool startWorker(const string[string] extraEnv = null) {
        if (hasPid_) return false;
        if (!configExists_ || !config_.installed) return false;
        if (!pythonLooksUsable(config_.python)) return false;

        const port = clampPort(config_.port);
        string[] args = [
            config_.python, "-m", "vibe3d_ai3d_worker", "serve",
            "--host", "127.0.0.1",
            "--port", port.to!string,
            "--data-dir", dataDir(),
            "--backend", config_.backend,
        ];
        if (config_.backend == "trellis") {
            if (config_.trellisRoot.length) args ~= ["--trellis-root", config_.trellisRoot];
            if (config_.modelCacheDir.length) args ~= ["--trellis-cache-dir", config_.modelCacheDir];
        }

        try {
            mkdirRecurse(dataDir());
            auto log = File(buildPath(dataDir(), "worker.log"), "w");
            pid_    = spawnProcess(args, stdin, log, log, extraEnv);
            hasPid_ = true;
            return true;
        } catch (Exception e) {
            logWarn("ai3d", "failed to spawn worker: " ~ e.msg);
            return false;
        }
    }

    /// Non-blocking — call once per frame while a worker may be running.
    /// Detects an unexpected exit (crash, or a bad config the process
    /// rejected at startup) so state() falls back to installedStopped
    /// instead of reporting a dead PID as running.
    void pollWorker() {
        if (!hasPid_) return;
        typeof(tryWait(pid_)) w;
        try w = tryWait(pid_);
        catch (Exception) { hasPid_ = false; return; }
        if (w.terminated) hasPid_ = false;
    }

    /// Stop the worker WE spawned: SIGTERM, then a short bounded wait for a
    /// graceful exit, escalating to SIGKILL only if it hasn't exited by the
    /// deadline. No-op (false) if we hold no Pid (including: it already
    /// exited on its own and pollWorker() observed that).
    bool stopWorker() {
        if (!hasPid_) return false;
        try {
            version (Posix) {
                import core.sys.posix.signal : SIGTERM, SIGKILL;
                kill(pid_, SIGTERM);
            } else {
                kill(pid_);
            }
            typeof(tryWait(pid_)) w;
            const deadline = MonoTime.currTime + 5.seconds;
            while (MonoTime.currTime < deadline) {
                w = tryWait(pid_);
                if (w.terminated) break;
                Thread.sleep(20.msecs);
            }
            if (!w.terminated) {
                version (Posix) {
                    import core.sys.posix.signal : SIGKILL;
                    kill(pid_, SIGKILL);
                }
                wait(pid_);
            }
        } catch (Exception e) {
            logWarn("ai3d", "stopWorker: " ~ e.msg);
        }
        hasPid_ = false;
        return true;
    }

    /// Editor shutdown hook (wired into app.d's scope(exit)): best-effort,
    /// never throws, kills anything WE spawned — the worker subprocess and
    /// any in-flight install/download stage — so vibe3d never leaves an
    /// orphaned child behind. Safe to call unconditionally, running or not.
    void shutdown() nothrow {
        try {
            if (hasPid_) stopWorker();
            if (hasInstallPid_) cancelInstall();
        } catch (Exception) {}
    }

    private static bool pythonLooksUsable(string python) {
        if (python.length == 0) return false;
        // An absolute path must actually exist; a bare command name (tests,
        // or a python resolved purely via $PATH) is trusted to spawnProcess
        // itself — which does its own PATH search and fails loudly if the
        // command is missing.
        if (isAbsolute(python)) return exists(python);
        return true;
    }

    // --- install lifecycle ---------------------------------------------

    Ai3dInstallState installState() const { return installState_; }
    string installMessage() const { return installMessage_; }
    bool installBusy() const {
        return installState_ == Ai3dInstallState.runningInstall
            || installState_ == Ai3dInstallState.runningDownload;
    }

    /// Best-effort tail of the install/download log (streamed into the
    /// panel while installBusy()). Never throws; "" if nothing has run yet.
    string installLogTail(size_t maxBytes = 4000) const {
        if (installLogPath_.length == 0 || !exists(installLogPath_)) return "";
        try {
            const sz = getSize(installLogPath_);
            auto f = File(installLogPath_, "rb");
            if (sz > maxBytes) f.seek(cast(long)(sz - maxBytes));
            auto buf = new ubyte[](sz > maxBytes ? maxBytes : cast(size_t) sz);
            f.rawRead(buf);
            return cast(string) buf.idup;
        } catch (Exception) {
            return "";
        }
    }

    /// Spawn the platform install script (install_linux.sh /
    /// install_windows.ps1, non-blocking); on its success, chain into the
    /// model-download stage (unless `downloadModel` is false; see
    /// downloadStageArgs()); pollInstall() drives both stages and reloads
    /// the config once the chain finishes. No-op (false) if a prior
    /// install/download stage is still running.
    bool runInstall(string installLocation = "", string trellisRoot = "",
                     bool downloadModel = true) {
        if (installBusy()) return false;

        auto script = locateInstallScript();
        if (script is null) {
            installState_   = Ai3dInstallState.failed;
            installMessage_ = installScriptName() ~ " not found "
                             ~ "(set VIBE3D_AI3D_INSTALL_SCRIPT)";
            return false;
        }
        // Linux-path only: Windows' pollInstall() builds its own fetch-model
        // invocation directly off config_.python (see downloadStageArgs()),
        // no wrapper script needed there.
        downloadScriptPath_       = buildPath(dirName(script), "download_model.sh");
        downloadModelAfterInstall_ = downloadModel;
        installLogPath_            = null; // fresh log for this run

        string[] args;
        version (Windows) {
            // .ps1 files have no exec-bit/shebang mechanism on Windows --
            // spawnProcess can't run one directly the way it runs the Linux
            // shell script. -NoProfile skips a possibly slow/broken user
            // profile script; -ExecutionPolicy Bypass sidesteps the default
            // Restricted policy rejecting an unsigned script, scoped to just
            // this one process (never touches the user's persistent policy).
            args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script];
            if (installLocation.length) args ~= ["-Location", installLocation];
            if (trellisRoot.length)     args ~= ["-TrellisRoot", trellisRoot];
        } else {
            args = [script];
            if (installLocation.length) args ~= ["--location", installLocation];
            if (trellisRoot.length)     args ~= ["--trellis-root", trellisRoot];
        }

        return spawnInstallStage(args, Ai3dInstallState.runningInstall);
    }

    private bool spawnInstallStage(string[] args, Ai3dInstallState nextState) {
        try {
            if (installLogPath_.length == 0) {
                const dir = buildPath(dirName(configPath_), "install-logs");
                mkdirRecurse(dir);
                installLogPath_ = buildPath(dir,
                    "install-" ~ MonoTime.currTime.ticks.to!string ~ ".log");
            }
            const append = nextState == Ai3dInstallState.runningDownload;
            if (installLogFile_.isOpen) try installLogFile_.close(); catch (Exception) {}
            installLogFile_ = File(installLogPath_, append ? "a" : "w");
            installPid_     = spawnProcess(args, stdin, installLogFile_, installLogFile_);
            hasInstallPid_  = true;
            installState_   = nextState;
            installMessage_ = null;
            return true;
        } catch (Exception e) {
            installState_   = Ai3dInstallState.failed;
            installMessage_ = "failed to launch: " ~ e.msg;
            return false;
        }
    }

    /// Non-blocking — call once per frame while installBusy(). Advances
    /// install -> download -> succeeded, or fails the whole chain on a
    /// non-zero exit from either stage.
    void pollInstall() {
        if (!installBusy()) return;
        typeof(tryWait(installPid_)) w;
        try w = tryWait(installPid_);
        catch (Exception e) {
            installState_   = Ai3dInstallState.failed;
            installMessage_ = "tryWait failed: " ~ e.msg;
            hasInstallPid_  = false;
            return;
        }
        if (!w.terminated) return;
        hasInstallPid_ = false;

        if (w.status != 0) {
            installState_   = Ai3dInstallState.failed;
            installMessage_ = "install step exited with status " ~ w.status.to!string;
            return;
        }

        if (installState_ == Ai3dInstallState.runningInstall) {
            refresh(); // the install script just wrote the config
            if (downloadModelAfterInstall_) {
                auto dlArgs = downloadStageArgs();
                if (dlArgs.length) {
                    if (spawnInstallStage(dlArgs, Ai3dInstallState.runningDownload))
                        return;
                    return; // spawnInstallStage already set failed
                }
            }
            installState_ = Ai3dInstallState.succeeded;
            return;
        }

        // runningDownload finished successfully.
        refresh();
        installState_ = Ai3dInstallState.succeeded;
    }

    /// Args to spawn the model-download stage chained right after a
    /// successful install (see pollInstall()). Platform-dependent:
    ///   Linux:   download_model.sh next to the install script (a thin
    ///            PYTHONPATH-setting wrapper around `fetch-model`).
    ///   Windows: the just-installed venv python (config_.python -- valid
    ///            here because refresh() already reloaded the config the
    ///            install script wrote) running the cross-platform
    ///            `fetch-model` subcommand directly. No wrapper script is
    ///            needed: fetch-model is a stdlib-only argparse subcommand
    ///            (see vibe3d_ai3d_worker/server.py), so there is nothing
    ///            a .ps1 wrapper would add here that spawnProcess can't
    ///            already do by invoking the venv python.
    /// Empty (no chaining) if the required piece isn't there.
    private string[] downloadStageArgs() const {
        version (Windows) {
            if (!pythonLooksUsable(config_.python)) return null;
            return [config_.python, "-m", "vibe3d_ai3d_worker", "fetch-model"];
        } else {
            return exists(downloadScriptPath_) ? [downloadScriptPath_] : null;
        }
    }

    /// Cooperative cancel of an in-flight install/download stage: SIGKILL +
    /// reap (mirrors RemeshJob.cancel() — this can run at shutdown, where a
    /// script that traps SIGTERM must not hang the editor). No-op if idle.
    void cancelInstall() {
        if (!hasInstallPid_) return;
        try {
            version (Posix) {
                import core.sys.posix.signal : SIGKILL;
                kill(installPid_, SIGKILL);
            } else {
                kill(installPid_);
            }
            wait(installPid_);
        } catch (Exception) {}
        hasInstallPid_ = false;
        installState_  = Ai3dInstallState.idle;
    }

    /// Reset a terminal install outcome (succeeded/failed) back to idle so
    /// the panel can offer Install again. No-op while busy.
    void clearInstall() {
        if (installBusy()) return;
        installState_   = Ai3dInstallState.idle;
        installMessage_ = null;
    }

    /// The platform installer script's filename inside tools/ai3d_worker/:
    /// install_linux.sh on Linux (and any other non-Windows target -- macOS
    /// never actually reaches this in practice, since kGenerateAiAvailable
    /// gates the whole Generate-3D feature off there in app.d, TRELLIS
    /// needing an NVIDIA CUDA GPU Macs don't have), install_windows.ps1 on
    /// Windows.
    private static string installScriptName() {
        version (Windows) return "install_windows.ps1";
        else               return "install_linux.sh";
    }

    /// Locate the platform install script: env override first (tests,
    /// non-standard layouts), then relative to the running executable's
    /// directory (a packaged install that ships `tools/` alongside the
    /// binary), then the repo-relative path resolved from THIS module's own
    /// source location at compile time (dev convenience — works for a
    /// freshly built binary run from any cwd against its own source tree).
    private static string locateInstallScript() {
        if (auto over = environment.get("VIBE3D_AI3D_INSTALL_SCRIPT"))
            if (over.length && exists(over)) return over;

        const name = installScriptName();

        try {
            auto exeRel = buildPath(dirName(thisExePath()), "tools", "ai3d_worker", name);
            if (exists(exeRel)) return exeRel;
        } catch (Exception) {}

        enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
        auto devPath = buildPath(repoRoot, "tools", "ai3d_worker", name);
        if (exists(devPath)) return devPath;

        return null;
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

version (unittest) {
    import std.file : tempDir, rmdirRecurse;
    import std.random : uniform;

    private string makeScratchDir(string tag) {
        auto d = buildPath(tempDir(),
            "vibe3d_ai3d_worker_mgr_ut_" ~ tag ~ "_" ~ uniform(0, int.max).to!string);
        mkdirRecurse(d);
        return d;
    }

    private void cleanScratchDir(string dir) nothrow {
        try rmdirRecurse(dir); catch (Exception) {}
    }
}

// Hermetic sync-check: kAi3dDefaultPort / kAi3dDefaultModel against the
// python worker's own argparse defaults in
// tools/ai3d_worker/vibe3d_ai3d_worker/server.py. This repo layout (the
// worker checkout living alongside the editor checkout) is a dev-checkout
// convenience, not a build dependency — worker_manager.d never reads
// server.py at runtime (see the two enums' doc comments above) — so a
// machine that doesn't carry tools/ai3d_worker (another dev's box, a
// packaging/release CI image, `dub test` invoked from outside the repo
// root) must not fail here: skip silently when the file can't be found.
unittest {
    import std.file  : exists, readText;
    import std.regex : matchFirst, regex;

    enum serverPyPath = "tools/ai3d_worker/vibe3d_ai3d_worker/server.py";
    if (!exists(serverPyPath)) return;

    const src = readText(serverPyPath);

    auto portMatch = matchFirst(src,
        regex(`add_argument\("--port"[^)]*?default=(\d+)`));
    assert(!portMatch.empty,
        "server.py's --port argparse default has changed shape — update " ~
        "the regex above or the manual-sync comment on kAi3dDefaultPort");
    assert(portMatch[1].to!int == kAi3dDefaultPort,
        "kAi3dDefaultPort (" ~ kAi3dDefaultPort.to!string ~ ") no longer " ~
        "matches server.py's --port default (" ~ portMatch[1] ~ ") — the " ~
        "two are NOT wired together at runtime for the manually-started-" ~
        "worker case (see the constant's doc comment), only kept in sync " ~
        "by convention. Update kAi3dDefaultPort to match.");

    auto modelMatch = matchFirst(src,
        regex(`add_argument\("--trellis-model"[^)]*?default="([^"]+)"`));
    assert(!modelMatch.empty,
        "server.py's --trellis-model argparse default has changed shape " ~
        "— update the regex above or the manual-sync comment on " ~
        "kAi3dDefaultModel");
    assert(modelMatch[1] == kAi3dDefaultModel,
        "kAi3dDefaultModel (" ~ kAi3dDefaultModel ~ ") no longer matches " ~
        "server.py's --trellis-model default (" ~ modelMatch[1] ~ "). " ~
        "Update kAi3dDefaultModel to match.");
}

// Config round-trip: a fully populated Ai3dInstallConfig serializes and
// parses back identically.
unittest {
    auto dir = makeScratchDir("roundtrip");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");

    Ai3dInstallConfig c;
    c.installed     = true;
    c.python        = "/opt/vibe3d-ai3d/venv/bin/python";
    c.backend       = "trellis";
    c.trellisRoot   = "/opt/vibe3d-ai3d/TRELLIS";
    c.modelCacheDir = "/opt/vibe3d-ai3d/hf-cache";
    c.port          = 47899;

    saveAi3dConfig(c, path);
    auto q = loadAi3dConfig(path);

    assert(q.version_ == kAi3dConfigVersion);
    assert(q.installed == true);
    assert(q.python == "/opt/vibe3d-ai3d/venv/bin/python");
    assert(q.backend == "trellis");
    assert(q.trellisRoot == "/opt/vibe3d-ai3d/TRELLIS");
    assert(q.modelCacheDir == "/opt/vibe3d-ai3d/hf-cache");
    assert(q.port == 47899);
}

// Missing file -> defaults (not installed), no throw.
unittest {
    auto dir = makeScratchDir("missing");
    scope(exit) cleanScratchDir(dir);
    auto c = loadAi3dConfig(buildPath(dir, "does_not_exist.json"));
    assert(c.installed == false);
    assert(c.port == kAi3dDefaultPort);
}

// Malformed JSON -> defaults, no throw.
unittest {
    auto dir = makeScratchDir("malformed");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");
    write(path, "{ not json ]]");
    auto c = loadAi3dConfig(path);
    assert(c.installed == false);
}

// A corrupted/out-of-range port falls back to the default rather than being
// passed through as-is (kernel-boundary clamp).
unittest {
    auto dir = makeScratchDir("badport");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");
    write(path, `{"version":1,"installed":true,"python":"/x/python",
                  "backend":"trellis","trellisRoot":"/x","port":999999}`);
    auto c = loadAi3dConfig(path);
    assert(c.port == kAi3dDefaultPort);
}

// null modelCacheDir round-trips to "" (== standard cache), not the literal
// string "null".
unittest {
    auto dir = makeScratchDir("nullcache");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");

    Ai3dInstallConfig c;
    c.installed = true;
    c.python    = "/x/python";
    saveAi3dConfig(c, path);

    auto text = cast(string) read(path);
    import std.algorithm.searching : canFind;
    assert(text.canFind(`"modelCacheDir": null`));

    auto q = loadAi3dConfig(path);
    assert(q.modelCacheDir.length == 0);
}

// resolveModelCacheDir must always yield an ABSOLUTE path, on every host.
// The regression this pins is Windows-specific and was silent: the home
// fallback read $HOME (unset on Windows outside a Git-Bash shell), so the
// path came out relative -- `.cache\huggingface\hub` off the editor's CWD --
// and modelPresent() reported a downloaded model as missing forever. Written
// host-agnostically (no env writes, no platform assumptions beyond the one
// the code makes) so it holds on Linux and CI too.
unittest {
    import std.path : isAbsolute;

    // An explicit override wins and is returned verbatim.
    version (Windows) const over = `D:\hf-cache`;
    else               const over = "/opt/hf-cache";
    assert(resolveModelCacheDir(over) == over);

    // userHomeDir itself: non-empty and absolute. This is the actual
    // regression site, and it is env-independent to assert -- USERPROFILE
    // (Windows) / HOME (posix) are set by the OS on any host that can run
    // this test. The $HOME-on-Windows bug made this "".
    const home = userHomeDir();
    assert(home.length > 0, "userHomeDir must resolve on every supported host");
    assert(home.isAbsolute, "userHomeDir must be absolute, got: " ~ home);

    // Windows: pin the SOURCE, not just the shape -- and pin it against a
    // HOSTILE $HOME rather than whatever the ambient shell happens to have.
    // Without that, this test is a no-op for the very bug it exists to catch:
    // run from Git Bash, $HOME is injected and equals %USERPROFILE%, so the
    // broken code passes here and still fails for the editor (launched from
    // Explorer, where no $HOME exists at all). Planting a $HOME that must NOT
    // be chosen makes the assertion bite in every environment.
    version (Windows) {
        const userProfile = environment.get("USERPROFILE", "");
        if (userProfile.length) {
            const savedHome = environment.get("HOME", "");
            environment["HOME"] = `Z:\not-the-home-dir`;
            scope(exit) {
                if (savedHome.length) environment["HOME"] = savedHome;
                else                  environment.remove("HOME");
            }
            assert(userHomeDir() == userProfile,
                   "on Windows the home dir must come from %USERPROFILE% (" ~
                   userProfile ~ ") like python's Path.home() -- never $HOME; got: " ~
                   userHomeDir());
        }
    }

    // The derived cache path must be absolute -- buildPath("", ".cache")
    // silently yields a relative one, which is how the bug hid. Asserted only
    // when no HF_* / XDG_ override is in play: those are the operator's own
    // paths, and asserting their SHAPE would make this test fail on a host
    // that legitimately points its cache elsewhere (the env-dependent-unittest
    // trap this module has been bitten by before).
    const noOverride = environment.get("HF_HUB_CACHE", "").length == 0
                    && environment.get("HF_HOME", "").length == 0
                    && environment.get("XDG_CACHE_HOME", "").length == 0;
    if (noOverride) {
        const derived = resolveModelCacheDir("");
        assert(derived.isAbsolute,
               "resolved HF cache dir must be absolute, got: " ~ derived);
        import std.algorithm.searching : canFind;
        assert(derived.canFind("huggingface"), derived);
    }
}

// Ai3dWorkerManager.state(): notInstalled (no config file) ->
// installedStopped (config written, not started) -> the running transition
// is covered end-to-end by the fake-backend lifecycle test below (it needs
// a real subprocess to prove running/stopped honestly).
unittest {
    auto dir = makeScratchDir("state");
    scope(exit) cleanScratchDir(dir);
    const path = buildPath(dir, "ai3d.json");

    auto mgr = new Ai3dWorkerManager(path);
    assert(mgr.state() == Ai3dWorkerState.notInstalled);
    // The default (no config file) backend is trellis, so modelPresent() probes
    // the real HF model cache during construction. Whether the model is actually
    // there is HOST-DEPENDENT — present on a dev box that ran a generation, absent
    // on a clean CI runner — so assert only that constructing + probing ran
    // WITHOUT THROWING (the old `== true` asserted the cache-hit value and was a
    // latent CI-only failure). modelPresent() itself is a pure getter.
    cast(void) mgr.modelPresent();

    Ai3dInstallConfig c;
    c.installed = true;
    c.python    = "/x/python";
    c.backend   = "fake";
    saveAi3dConfig(c, path);

    mgr.refresh();
    assert(mgr.state() == Ai3dWorkerState.installedStopped);
    assert(mgr.modelPresent() == true, "fake backend needs no HF model cache");
}

// resolveModelCacheDir precedence + modelSnapshotPresent's filesystem probe
// (mirrors vibe3d_ai3d_worker/server.py's _resolve_cache_dir /
// _fs_find_snapshot pair exactly).
unittest {
    auto dir = makeScratchDir("modelcache");
    scope(exit) cleanScratchDir(dir);

    assert(resolveModelCacheDir(dir) == dir, "explicit override wins");

    assert(!modelSnapshotPresent("jetx/TRELLIS-image-large", dir),
           "empty cache dir -> not present");

    const snap = buildPath(dir, "models--jetx--TRELLIS-image-large", "snapshots", "deadbeef");
    mkdirRecurse(snap);
    write(buildPath(snap, "config.json"), "{}");
    assert(modelSnapshotPresent("jetx/TRELLIS-image-large", dir),
           "a non-empty snapshot dir -> present");

    const emptySnapModel = "org/empty-model";
    const emptySnap = buildPath(dir, "models--org--empty-model", "snapshots", "emptyrev");
    mkdirRecurse(emptySnap);
    assert(!modelSnapshotPresent(emptySnapModel, dir),
           "a snapshot dir with no files -> treated as not present");
}

version (Posix)
unittest {
    // Editor worker lifecycle (task 0403): spawn -> health -> kill, driven
    // through the worker's `fake` backend (no torch/GPU/model -- a
    // deterministic canned OBJ), proving the REAL subprocess + health-poll
    // + kill machinery end to end, entirely offline. Reuses
    // ai3d.stage_artifact.probeHealthCheck for the health poll -- the SAME
    // call the Generate 3D modal's health line already drives.
    //
    // Never touches the owner's live TRELLIS worker on :47831: a fresh
    // ephemeral port is picked the same way ai3d.job_controller's own
    // join()-timeout unittest does (bind :0, read the OS-assigned port
    // back, close, reuse the number -- a tiny, accepted race window).
    import std.socket : TcpSocket, InternetAddress;
    import ai3d.stage_artifact : probeHealthCheck;

    ushort pickFreePort() {
        auto s = new TcpSocket();
        scope(exit) s.close();
        s.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
        return (cast(InternetAddress) s.localAddress).port;
    }

    // Repo-root-relative path to tools/ai3d_worker, resolved at COMPILE
    // TIME from this module's own source location -- works regardless of
    // the test binary's cwd. Set as PYTHONPATH so a bare system python3
    // (no venv, no install) can `-m vibe3d_ai3d_worker` without an
    // editable install -- exactly the "fake backend, no torch/GPU" ask.
    enum repoRoot  = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    enum workerDir = buildPath(repoRoot, "tools", "ai3d_worker");
    assert(exists(buildPath(workerDir, "vibe3d_ai3d_worker", "server.py")),
           "sanity: the worker package must be findable at " ~ workerDir);

    auto dir = makeScratchDir("lifecycle");
    scope(exit) cleanScratchDir(dir);
    const cfgPath = buildPath(dir, "ai3d.json");

    Ai3dInstallConfig cfg;
    cfg.installed = true;
    cfg.python    = "python3"; // resolved via $PATH -- never a venv here
    cfg.backend   = "fake";
    cfg.port      = pickFreePort();
    saveAi3dConfig(cfg, cfgPath);

    auto mgr = new Ai3dWorkerManager(cfgPath);
    assert(mgr.state() == Ai3dWorkerState.installedStopped);

    const started = mgr.startWorker(["PYTHONPATH": workerDir]);
    assert(started, "startWorker must spawn the fake-backend subprocess");
    assert(mgr.state() == Ai3dWorkerState.running);

    // Poll /v1/health until ready. The fake backend boots in well under a
    // second; a generous ceiling keeps this robust on a loaded CI box.
    shared bool neverStop = false;
    bool healthy;
    const deadline = MonoTime.currTime + 10.seconds;
    while (MonoTime.currTime < deadline) {
        mgr.pollWorker();
        assert(mgr.state() == Ai3dWorkerState.running, "must not have exited early");
        auto h = probeHealthCheck(mgr.workerUrl(), neverStop);
        if (h.ok) { healthy = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(healthy, "worker must become healthy: " ~ mgr.workerUrl());

    assert(mgr.stopWorker(), "stopWorker must report it killed a live process");
    assert(mgr.state() == Ai3dWorkerState.installedStopped);

    // Process is actually gone -- a second stopWorker() is a no-op, and the
    // health endpoint is unreachable (connection refused, not just slow).
    assert(!mgr.stopWorker());
    auto afterKill = probeHealthCheck(mgr.workerUrl(), neverStop);
    assert(!afterKill.ok, "worker must actually be dead after stopWorker()");
}
