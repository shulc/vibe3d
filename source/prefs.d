// User-preference persistence: a single, flat, versioned JSON file in the
// user config directory that survives across sessions. One app, one file —
// no plugin ABI, no registered-client atom tree; the goal is simply "state
// persists across sessions in one user config file".
//
// What persists (schema v1): the main window size, a recent-files MRU list,
// the last directory used in a file dialog, and sticky tool-option defaults
// keyed by preset id. Camera / view / edit-mode / per-document state are
// deliberately NOT persisted here (see doc).
//
// Format follows io/native.d: versioned (`version` key), tolerant `parseJSON`
// read with `JSONException` handling, JSON write. std.json — NOT dyaml (dyaml
// is load-only in this project; prefs is machine-written + machine-read).
//
// Threading: main-thread only, same stance as io/doc_state.d. There is no
// cross-thread access — the menu, the file commands and the app shutdown all
// run on the main thread.
//
// Concurrency across instances: last writer wins. Accepted for a single-user
// desktop app in v1.
//
// Reader durability: loadPrefs NEVER throws. Missing file → defaults;
// malformed JSON → logWarn("prefs", …) + defaults; unknown keys ignored; a
// `version` greater than we know → best-effort read of recognized keys.
module prefs;

import std.json   : JSONValue, JSONType, parseJSON, JSONException;
import std.file   : exists, read, write, mkdirRecurse, copy;
import std.path   : buildPath, absolutePath;
import std.process : environment;
import std.format : format;

import log            : logWarn;
import viewport       : LayoutPreset;
import display_state  : DisplayStyle, WireOverlay;
import coord_rounding : CoordinateRounding, kCoordRoundingDefault,
                        kFixedIncrementDefault, coordRoundingName,
                        parseCoordRounding;

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

/// The schema version the writer emits and the highest the reader fully
/// understands. A file written by a newer vibe3d (higher `version`) is read
/// best-effort: recognized keys only.
enum int kPrefsVersion = 1;

/// Cap on the recent-files MRU list.
enum size_t kRecentFilesMax = 10;

/// Persisted user preferences (schema v1). Field order mirrors the JSON
/// shape: `version`, `window`, `recentFiles`, `lastDir`, `toolDefaults`,
/// `viewportLayout`.
struct Prefs {
    /// Schema version of the loaded document (kPrefsVersion for a fresh struct).
    int version_ = kPrefsVersion;

    /// Main window size in EXACT physical pixels (already post-uiScale). 0/0
    /// means "unset" — the app falls back to its default + uiScale growth.
    struct Window { int w; int h; }
    Window window;

    /// Most-recently-used file paths, newest first, absolute, capped at
    /// kRecentFilesMax.
    string[] recentFiles;

    /// Last directory used in a file dialog (absolute), seeded into the next
    /// dialog's defaultPath.
    string lastDir;

    /// Sticky tool-option defaults: presetId -> (attrName -> value-string).
    /// Captured on clean tool drop, re-applied at activation so they override
    /// config/tool_presets.yaml. TOOL-LEVEL attrs only — never pipe-stage.
    string[string][string] toolDefaults;

    /// Persisted viewport-cell split preset (Single/SplitH/SplitV/Quad). The
    /// ImGui layout ini also carries a `Viewport##k` cell-node subtree, but
    /// that subtree is NOT trusted as the source of truth (a stale multi-cell
    /// tree can survive from a prior session even when the preset reverted
    /// to Single) — the startup `applyLayout(g_prefs.viewportLayout)` call
    /// deterministically rebuilds the cell tree from THIS field instead.
    LayoutPreset viewportLayout = LayoutPreset.Single;

    /// Task 0223 (quad cross splitter): the user-adjustable cell-split
    /// ratios (ViewportManager.hRatio/vRatio — see source/viewport.d's
    /// cellRectsForRatios doc comment for the axis-naming convention). These
    /// are a SEPARATE store from the ImGui layout ini deliberately: the cells
    /// are procedurally positioned, non-docked, `NoSavedSettings` windows
    /// (task 0223 M2/M3), so nothing about their geometry lives in the ini at
    /// all — ratios persist here instead, independent of the (unbumped)
    /// `kLayoutIniVersion`.
    float hRatio = 0.5f;
    float vRatio = 0.5f;

    /// Coordinate Rounding (task 0562): which law rounds a gizmo axis drag's
    /// scalar, stored by wire name so a hand-edited file is readable and a
    /// future arm does not renumber the existing ones. `None` switches the
    /// rounding off entirely. Default = the reference's own default.
    /// NOT a schema bump: a file without the key reads back at the default,
    /// which is the same call `viewportDisplay` below made.
    CoordinateRounding coordRounding = kCoordRoundingDefault;

    /// The increment (world units) the two Fixed arms of `coordRounding`
    /// read. Ignored by the other three.
    float coordRoundingFixedIncrement = kFixedIncrementDefault;

    /// Task 0559: per-viewport-cell display state — the FIRST per-cell state
    /// this app persists at all. Everything else a cell owns (camera,
    /// independence flags, master override) is deliberately runtime-only and
    /// reset on startup; only manager-level layout survived a session.
    ///
    /// Fixed-length rather than dynamic because the cell count is fixed at
    /// four by the layout presets, so a short or over-long array on disk
    /// needs no policy: extra entries are ignored, missing ones keep their
    /// defaults.
    ///
    /// Defaults MUST equal the display model's own defaults. A fresh profile
    /// and a profile whose file predates this key have to produce the same
    /// viewport, or "no default changed" quietly stops being true after one
    /// save.
    ViewportCellDisplay[4] viewportDisplay;
}

/// One cell's persisted display state (task 0559).
struct ViewportCellDisplay {
    DisplayStyle style     = DisplayStyle.Shaded;
    WireOverlay  wire      = WireOverlay.Uniform;
    float        wireAlpha = 1.0f;
}

/// Module-level live preferences. Loaded once at startup, mutated by the
/// note* helpers + sticky-default capture, written at clean shutdown.
__gshared Prefs g_prefs;

// ---------------------------------------------------------------------------
// File location
// ---------------------------------------------------------------------------

/// The directory holding `prefs.json`. Resolution order:
///   1. $VIBE3D_CONFIG_DIR  (tests, multi-instance debugging — highest)
///   2. platform user-config dir + "/vibe3d"
/// Only Linux is exercised in v1; the macOS / Windows branches compile but
/// are stubs.
string prefsDir() {
    if (auto over = environment.get("VIBE3D_CONFIG_DIR"))
        if (over.length > 0) return over;

    version (OSX) {
        // ~/Library/Application Support/vibe3d
        const home = environment.get("HOME", "");
        return buildPath(home, "Library", "Application Support", "vibe3d");
    } else version (Windows) {
        // %APPDATA%\vibe3d
        const appData = environment.get("APPDATA", "");
        return buildPath(appData, "vibe3d");
    } else {
        // Linux / other POSIX: $XDG_CONFIG_HOME/vibe3d else ~/.config/vibe3d
        if (auto xdg = environment.get("XDG_CONFIG_HOME"))
            if (xdg.length > 0) return buildPath(xdg, "vibe3d");
        const home = environment.get("HOME", "");
        return buildPath(home, ".config", "vibe3d");
    }
}

private string prefsFilePath(string dir) { return buildPath(dir, "prefs.json"); }

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Load preferences from `dir`/prefs.json into a Prefs struct. NEVER throws:
/// missing file → defaults; malformed JSON → logWarn + defaults; unknown keys
/// ignored; a higher `version` is read best-effort (recognized keys only).
/// The explicit `dir` lets unittests inject a tempDir without touching
/// ~/.config; the `loadPrefs()` wrapper uses `prefsDir()`.
Prefs loadPrefs(string dir) {
    Prefs p;  // defaults
    const path = prefsFilePath(dir);

    if (!exists(path)) return p;

    JSONValue doc;
    try {
        doc = parseJSON(cast(string) read(path));
    } catch (JSONException e) {
        logWarn("prefs", format("malformed prefs.json, using defaults: %s", e.msg));
        return p;
    } catch (Exception e) {
        logWarn("prefs", format("could not read prefs.json, using defaults: %s", e.msg));
        return p;
    }

    if (doc.type != JSONType.object) {
        logWarn("prefs", "prefs.json top-level value is not an object, using defaults");
        return p;
    }

    // Any unguarded typed std.json access below (e.g. .integer on a value
    // std.json stored as uinteger) throws JSONException. Wrap the whole
    // field-extraction body so a hand-mangled file degrades to whatever was
    // parsed so far rather than crashing startup. Each block is independently
    // tolerant; this is the structural backstop.
    try {
        if (auto vp = "version" in doc)
            if (vp.type == JSONType.integer) p.version_ = cast(int) vp.integer;

        if (auto wp = "window" in doc)
            if (wp.type == JSONType.object) {
                if (auto a = "w" in *wp) if (a.type == JSONType.integer) p.window.w = cast(int) a.integer;
                if (auto a = "h" in *wp) if (a.type == JSONType.integer) p.window.h = cast(int) a.integer;
            }

        if (auto rp = "recentFiles" in doc)
            if (rp.type == JSONType.array)
                foreach (ref e; rp.array)
                    if (e.type == JSONType.string) {
                        if (p.recentFiles.length >= kRecentFilesMax) break;
                        p.recentFiles ~= e.str;
                    }

        if (auto lp = "lastDir" in doc)
            if (lp.type == JSONType.string) p.lastDir = lp.str;

        if (auto tp = "toolDefaults" in doc)
            if (tp.type == JSONType.object)
                foreach (presetId, attrsJson; tp.object)
                    if (attrsJson.type == JSONType.object) {
                        string[string] attrs;
                        foreach (attrName, valJson; attrsJson.object)
                            if (valJson.type == JSONType.string)
                                attrs[attrName] = valJson.str;
                        if (attrs.length > 0) p.toolDefaults[presetId] = attrs;
                    }

        if (auto vlp = "viewportLayout" in doc)
            if (vlp.type == JSONType.string)
                switch (vlp.str) {
                    case "Single": p.viewportLayout = LayoutPreset.Single; break;
                    case "SplitH": p.viewportLayout = LayoutPreset.SplitH; break;
                    case "SplitV": p.viewportLayout = LayoutPreset.SplitV; break;
                    case "Quad":   p.viewportLayout = LayoutPreset.Quad;   break;
                    default: break; // unrecognized -> keep default (Single)
                }

        // Task 0223: cross-splitter ratios. Accept either JSON number kind
        // (std.json parses "0.5" as floating but a hand-edited "1" or "0"
        // would parse as integer/uinteger) and clamp to a sane range so a
        // corrupted/out-of-range value can't degenerate a cell to zero size.
        float readRatio(string key, float def) {
            auto rp = key in doc;
            if (rp is null) return def;
            float v = def;
            if (rp.type == JSONType.float_) v = cast(float) rp.floating;
            else if (rp.type == JSONType.integer) v = cast(float) rp.integer;
            else if (rp.type == JSONType.uinteger) v = cast(float) rp.uinteger;
            else return def;
            if (v < 0.05f) v = 0.05f;
            if (v > 0.95f) v = 0.95f;
            return v;
        }
        p.hRatio = readRatio("hRatio", 0.5f);
        p.vRatio = readRatio("vRatio", 0.5f);

        // Task 0559: per-cell display state.
        //
        // Only the values a render pass ACTUALLY CONSUMES are accepted here;
        // anything else falls back to the default, exactly like an
        // unrecognized viewportLayout above. The display enums are
        // deliberately wider than the renderer honours today, and the
        // commands that write this state refuse the unconsumed values for the
        // same reason: a hand-edited file naming a style we resolve but do
        // not draw would otherwise come back as a viewport that silently
        // renders something else. When a pass starts consuming one, it joins
        // this switch and the command's, together.
        if (auto vdp = "viewportDisplay" in doc)
            if (vdp.type == JSONType.array) {
                foreach (i, cellJson; vdp.array) {
                    if (i >= p.viewportDisplay.length) break;
                    if (cellJson.type != JSONType.object) continue;
                    if (auto sp = "style" in cellJson)
                        if (sp.type == JSONType.string)
                            switch (sp.str) {
                                case "Wireframe": p.viewportDisplay[i].style = DisplayStyle.Wireframe; break;
                                case "Shaded":    p.viewportDisplay[i].style = DisplayStyle.Shaded;    break;
                                default: break;   // incl. styles no pass draws yet
                            }
                    if (auto wp = "wire" in cellJson)
                        if (wp.type == JSONType.string)
                            switch (wp.str) {
                                case "None":    p.viewportDisplay[i].wire = WireOverlay.None;    break;
                                case "Uniform": p.viewportDisplay[i].wire = WireOverlay.Uniform; break;
                                default: break;   // incl. the per-item colour we cannot resolve
                            }
                    // Out-of-range opacity is CLAMPED, not rejected: unlike a
                    // style name there is a sane nearest meaning, and the
                    // ratios above set the precedent for a numeric field.
                    if (auto ap = "wireAlpha" in cellJson) {
                        float a = float.nan;
                        if (ap.type == JSONType.float_)        a = cast(float)ap.floating;
                        else if (ap.type == JSONType.integer)  a = cast(float)ap.integer;
                        else if (ap.type == JSONType.uinteger) a = cast(float)ap.uinteger;
                        if (a == a) {   // not NaN
                            if (a < 0.0f) a = 0.0f;
                            if (a > 1.0f) a = 1.0f;
                            p.viewportDisplay[i].wireAlpha = a;
                        }
                    }
                }
            }

        // Coordinate Rounding (task 0562). An unrecognized name keeps the
        // default rather than falling to `None`: a typo that silently
        // switched the rounding off would look exactly like the term
        // regressing.
        if (auto cp = "coordRounding" in doc)
            if (cp.type == JSONType.string) {
                CoordinateRounding m;
                if (parseCoordRounding(cp.str, m)) p.coordRounding = m;
                else logWarn("prefs", format(
                    "unknown coordRounding '%s', keeping %s",
                    cp.str, coordRoundingName(p.coordRounding)));
            }

        if (auto fp = "coordRoundingFixedIncrement" in doc) {
            float v = float.nan;
            if      (fp.type == JSONType.float_)   v = cast(float) fp.floating;
            else if (fp.type == JSONType.integer)  v = cast(float) fp.integer;
            else if (fp.type == JSONType.uinteger) v = cast(float) fp.uinteger;
            // A non-positive increment leaves the two Fixed arms with nothing
            // to round to; refuse it here rather than let it reach the law.
            if (v > 0) p.coordRoundingFixedIncrement = v;
        }
    } catch (JSONException e) {
        logWarn("prefs", format("prefs.json partially malformed, using what parsed: %s", e.msg));
    }

    return p;
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Serialize `p` to `dir`/prefs.json (creating `dir` if needed). The `dir`
/// param lets unittests target a tempDir; the `savePrefs()` wrapper uses
/// `prefsDir()`. Always writes `version: kPrefsVersion` (the writer's schema).
/// Throws only on filesystem failure (caller at shutdown swallows — a failed
/// save is non-fatal).
void savePrefs(ref const Prefs p, string dir) {
    JSONValue doc = JSONValue(cast(JSONValue[string]) null);
    doc["version"] = JSONValue(kPrefsVersion);

    JSONValue win = JSONValue(cast(JSONValue[string]) null);
    win["w"] = JSONValue(p.window.w);
    win["h"] = JSONValue(p.window.h);
    doc["window"] = win;

    JSONValue[] recent;
    foreach (f; p.recentFiles) recent ~= JSONValue(f);
    doc["recentFiles"] = JSONValue(recent);

    doc["lastDir"] = JSONValue(p.lastDir);

    JSONValue td = JSONValue(cast(JSONValue[string]) null);
    foreach (presetId, attrs; p.toolDefaults) {
        JSONValue av = JSONValue(cast(JSONValue[string]) null);
        foreach (k, v; attrs) av[k] = JSONValue(v);
        td[presetId] = av;
    }
    doc["toolDefaults"] = td;

    import std.conv : to;
    doc["viewportLayout"] = JSONValue(to!string(p.viewportLayout));
    doc["hRatio"] = JSONValue(p.hRatio);
    doc["vRatio"] = JSONValue(p.vRatio);
    doc["coordRounding"] = JSONValue(coordRoundingName(p.coordRounding));
    doc["coordRoundingFixedIncrement"] =
        JSONValue(p.coordRoundingFixedIncrement);

    // Task 0559: per-cell display state. Written unconditionally for all four
    // cells, including cells the current layout does not show — a cell's
    // setting has to survive a round trip through Single and back to Quad.
    JSONValue[] vd;
    foreach (ref c; p.viewportDisplay) {
        JSONValue cj = JSONValue(cast(JSONValue[string]) null);
        cj["style"]     = JSONValue(to!string(c.style));
        cj["wire"]      = JSONValue(to!string(c.wire));
        cj["wireAlpha"] = JSONValue(c.wireAlpha);
        vd ~= cj;
    }
    doc["viewportDisplay"] = JSONValue(vd);

    mkdirRecurse(dir);
    write(prefsFilePath(dir), doc.toPrettyString());
}

// ---------------------------------------------------------------------------
// Global-state wrappers (use prefsDir())
// ---------------------------------------------------------------------------

/// Load `g_prefs` from the resolved user-config dir. Wrapper over
/// `loadPrefs(prefsDir())`.
void loadPrefs() { g_prefs = loadPrefs(prefsDir()); }

/// Write `g_prefs` to the resolved user-config dir. Wrapper over
/// `savePrefs(g_prefs, prefsDir())`.
void savePrefs() { savePrefs(g_prefs, prefsDir()); }

// ---------------------------------------------------------------------------
// Layout ini versioning
// ---------------------------------------------------------------------------

/// Version of the ImGui dock layout ini file.  Bump this constant whenever
/// the docking format or the default-seed layout changes; the versioned
/// filename then points at a non-existent file → ImGui falls back to the
/// programmatic default seed (auto-reset on bump, no old-format crash).
///
/// v1 -> v2 (task 0211): the outer dock-tree node shape changed — the
/// central node now hosts a "ViewportHost" window nesting its own
/// `viewportDockId` DockSpace (instead of docking `Viewport##0` directly),
/// so a `Viewport##k` cell subtree can be rebuilt on a layout switch without
/// touching chrome. A restored v1 ini has no ViewportHost window / no
/// ViewportDockSpace node, so the bump is required — restoring it as-is
/// would leave `Viewport##0` double-claimed (docked in the outer central
/// node per the old shape, but the new seed code looks for "ViewportHost"
/// there instead).
///
/// v2 -> v3 (task 0211 rework): the outer seed's split ORDER changed (sides
/// off the root first — full window height — THEN tab bar/status line off
/// the remaining center column; previously top/bottom were split off the
/// root first, leaving the side panels short). A restored v2 ini has the
/// old node shape/ratios baked in, so it must be invalidated too. This bump
/// also sweeps any ini written by the broken pre-rework v2 build (dead seed
/// guard → floating panels) — keyed on file existence, that build's v2 file
/// would otherwise be treated as "already seeded" and skip the fix.
enum int kLayoutIniVersion = 3;

/// Return the full path to the versioned ImGui layout ini in `dir`.
/// Pure string builder: no file I/O, no GL context.  A bump of `ver` yields
/// a different filename so a stale restored ini is never opened.
string layoutIniPath(string dir, int ver) pure {
    return buildPath(dir, format("imgui_layout_v%d.ini", ver));
}

// Pure filename math only — no GL context, no filesystem access.
unittest {
    auto p1 = layoutIniPath("/cfg/vibe3d", 1);
    auto p2 = layoutIniPath("/cfg/vibe3d", 2);
    auto p3 = layoutIniPath("/cfg/vibe3d", 3);
    import std.path : baseName, dirName;
    assert(dirName(p1)  == "/cfg/vibe3d",        "path must be under dir");
    assert(baseName(p1) == "imgui_layout_v1.ini", "v1 filename");
    assert(p1 != p2,                              "version bump → different file");
    assert(baseName(p2) == "imgui_layout_v2.ini", "v2 filename");
    assert(p2 != p3,                              "version bump → different file");
    assert(baseName(p3) == "imgui_layout_v3.ini", "v3 filename");
}

/// Copy `defaultIniPath` (the shipped, user-confirmed default arrangement,
/// `config/default_layout.ini`) into `userIniPath` if nothing lives at
/// `userIniPath` yet. NEVER overwrites an existing user file — a first-run
/// seed only. Best-effort: any I/O failure (missing shipped file, unwritable
/// dir, etc.) is swallowed; the caller then falls back to whatever ran
/// before this helper existed (ImGui's own bare programmatic default seed).
/// Returns true iff a copy actually happened.
bool seedLayoutIniIfMissing(string defaultIniPath, string userIniPath) {
    try {
        if (!exists(userIniPath) && exists(defaultIniPath)) {
            copy(defaultIniPath, userIniPath);
            return true;
        }
    } catch (Exception) {}
    return false;
}

unittest {
    auto dir = makeScratch("seedlayout");
    scope(exit) cleanScratch(dir);

    auto defaultIni = buildPath(dir, "shipped_default.ini");
    auto userIni    = buildPath(dir, "user.ini");
    write(defaultIni, "[Window][Mesh Info]\nDockId=0x00000003,0\n");

    // First run: no user ini yet -> copies the shipped default.
    assert(seedLayoutIniIfMissing(defaultIni, userIni) == true);
    assert(exists(userIni));
    assert(cast(string) read(userIni) == cast(string) read(defaultIni));

    // Second run: user ini already exists (e.g. re-arranged by the user) ->
    // NEVER overwritten, even though the shipped default still exists.
    write(userIni, "[Window][Mesh Info]\nDockId=0x00000099,0\n");
    assert(seedLayoutIniIfMissing(defaultIni, userIni) == false);
    assert(cast(string) read(userIni) == "[Window][Mesh Info]\nDockId=0x00000099,0\n");

    // Missing shipped default (best-effort, non-fatal) -> no-op, no throw.
    auto missingDefault = buildPath(dir, "does_not_exist.ini");
    auto freshUser      = buildPath(dir, "fresh_user.ini");
    assert(seedLayoutIniIfMissing(missingDefault, freshUser) == false);
    assert(!exists(freshUser));
}

// ---------------------------------------------------------------------------
// Mutators (main-thread only)
// ---------------------------------------------------------------------------

/// MRU-push `path` onto g_prefs.recentFiles: store the absolute path, dedupe
/// (an existing entry moves to the front), cap at kRecentFilesMax.
void prefsNoteRecentFile(string path) {
    if (path.length == 0) return;
    string abs;
    try abs = absolutePath(path);
    catch (Exception) abs = path;

    // Dedupe: drop any existing occurrence, then prepend.
    string[] kept;
    foreach (f; g_prefs.recentFiles)
        if (f != abs) kept ~= f;
    g_prefs.recentFiles = abs ~ kept;
    if (g_prefs.recentFiles.length > kRecentFilesMax)
        g_prefs.recentFiles = g_prefs.recentFiles[0 .. kRecentFilesMax];
}

/// Record `path`'s directory as the last-used dialog directory (absolute).
/// Accepts either a directory or a file path — callers pass dirName(chosen).
void prefsNoteLastDir(string path) {
    if (path.length == 0) return;
    try g_prefs.lastDir = absolutePath(path);
    catch (Exception) g_prefs.lastDir = path;
}

// ---------------------------------------------------------------------------
// Unittests — injected tempDir; NEVER touch ~/.config.
// ---------------------------------------------------------------------------

version (unittest) {
    import std.file : tempDir, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;

    // A fresh, unique scratch dir per test, cleaned on scope exit.
    private string makeScratch(string tag) {
        import std.random : uniform;
        auto d = buildPath(tempDir(), format("vibe3d_prefs_ut_%s_%d", tag, uniform(0, int.max)));
        mkdirRecurse(d);
        return d;
    }

    // try/catch can't sit directly inside a scope(exit); call this instead.
    private void cleanScratch(string dir) nothrow {
        try rmdirRecurse(dir); catch (Exception) {}
    }
}

// round-trip: a fully populated Prefs serializes and parses back identically.
unittest {
    auto dir = makeScratch("roundtrip");
    scope(exit) cleanScratch(dir);

    Prefs p;
    p.window = Prefs.Window(1426, 966);
    p.recentFiles = ["/abs/a.v3d", "/abs/b.obj"];
    p.lastDir = "/abs/dir";
    p.toolDefaults["bevel"] = ["width": "0.25", "segments": "4"];
    p.viewportLayout = LayoutPreset.SplitH;

    savePrefs(p, dir);
    auto q = loadPrefs(dir);

    assert(q.version_ == kPrefsVersion);
    assert(q.window.w == 1426 && q.window.h == 966);
    assert(q.recentFiles == ["/abs/a.v3d", "/abs/b.obj"]);
    assert(q.lastDir == "/abs/dir");
    assert(q.toolDefaults["bevel"]["width"] == "0.25");
    assert(q.toolDefaults["bevel"]["segments"] == "4");
    assert(q.viewportLayout == LayoutPreset.SplitH);
}

// viewportLayout: default is Single; unrecognized string tolerantly falls
// back to the default instead of throwing.
unittest {
    auto dir = makeScratch("viewportlayout");
    scope(exit) cleanScratch(dir);

    auto def = loadPrefs(dir);
    assert(def.viewportLayout == LayoutPreset.Single, "unset -> default Single");

    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "viewportLayout": "Quad" }`);
    auto q = loadPrefs(dir);
    assert(q.viewportLayout == LayoutPreset.Quad);

    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "viewportLayout": "NotARealPreset" }`);
    auto r = loadPrefs(dir);
    assert(r.viewportLayout == LayoutPreset.Single, "unrecognized -> default Single");
}

// Task 0223: hRatio/vRatio round-trip, default, and clamp-on-load.
unittest {
    auto dir = makeScratch("crossratio");
    scope(exit) cleanScratch(dir);

    auto def = loadPrefs(dir);
    assert(def.hRatio == 0.5f && def.vRatio == 0.5f, "unset -> default 0.5/0.5");

    Prefs p;
    p.hRatio = 0.3f;
    p.vRatio = 0.7f;
    savePrefs(p, dir);
    auto q = loadPrefs(dir);
    assert(q.hRatio == 0.3f && q.vRatio == 0.7f, "round-trip");

    // Out-of-range values (corrupted / hand-edited) are clamped, not thrown.
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "hRatio": 1.5, "vRatio": -0.2 }`);
    auto r = loadPrefs(dir);
    assert(r.hRatio == 0.95f, "hRatio clamped to max");
    assert(r.vRatio == 0.05f, "vRatio clamped to min");

    // A hand-edited integer literal (no decimal point) still parses.
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "hRatio": 1, "vRatio": 0 }`);
    auto s = loadPrefs(dir);
    assert(s.hRatio == 0.95f, "integer 1 clamped to max");
    assert(s.vRatio == 0.05f, "integer 0 clamped to min");
}

// Task 0559: per-cell display state — defaults, round-trip, per-cell
// independence, and tolerant reads.
unittest {
    auto dir = makeScratch("viewportdisplay");
    scope(exit) cleanScratch(dir);

    // The default here is load-bearing well beyond this file: a fresh profile
    // and a profile saved before this key existed both have to reproduce the
    // viewport the app has always drawn. If someone "improves" a default to
    // match something prettier, this is where it gets caught, before any
    // pixel is involved.
    auto def = loadPrefs(dir);
    foreach (i, ref c; def.viewportDisplay) {
        assert(c.style == DisplayStyle.Shaded,
            format("cell %d: unset style must default to Shaded", i));
        assert(c.wire == WireOverlay.Uniform,
            format("cell %d: unset overlay must default to Uniform", i));
        assert(c.wireAlpha == 1.0f,
            format("cell %d: unset opacity must default to fully opaque", i));
    }

    // Round-trip, and PER-CELL INDEPENDENCE: writing one cell must not
    // disturb its neighbours. This is the persisted-side mirror of the
    // isolation property the four-cell HTTP test asserts at runtime — a
    // schema that collapsed the cells into one shared record would pass every
    // single-cell assertion and fail here.
    Prefs p;
    p.viewportDisplay[2].style     = DisplayStyle.Wireframe;
    p.viewportDisplay[2].wire      = WireOverlay.None;
    p.viewportDisplay[2].wireAlpha = 0.25f;
    savePrefs(p, dir);
    auto q = loadPrefs(dir);
    assert(q.viewportDisplay[2].style == DisplayStyle.Wireframe, "cell 2 style round-trip");
    assert(q.viewportDisplay[2].wire  == WireOverlay.None,       "cell 2 overlay round-trip");
    assert(q.viewportDisplay[2].wireAlpha == 0.25f,              "cell 2 opacity round-trip");
    foreach (i; [0, 1, 3]) {
        assert(q.viewportDisplay[i].style == DisplayStyle.Shaded,
            format("cell %d must be untouched by a write to cell 2", i));
        assert(q.viewportDisplay[i].wire == WireOverlay.Uniform,
            format("cell %d overlay must be untouched by a write to cell 2", i));
        assert(q.viewportDisplay[i].wireAlpha == 1.0f,
            format("cell %d opacity must be untouched by a write to cell 2", i));
    }

    // A name we resolve but do not DRAW falls back to the default rather than
    // coming back as a viewport that renders something other than what it
    // reports. Same stance the commands take, for the same reason.
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "viewportDisplay": [ {"style":"Solid","wire":"Colored"} ] }`);
    auto r = loadPrefs(dir);
    assert(r.viewportDisplay[0].style == DisplayStyle.Shaded,
        "a style no pass draws must fall back to the default");
    assert(r.viewportDisplay[0].wire == WireOverlay.Uniform,
        "an overlay mode no pass draws must fall back to the default");

    // Garbage, a short array, and an out-of-range opacity: none may throw,
    // and a short array must leave the remaining cells at their defaults.
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "viewportDisplay": [ {"style":"Wireframe","wireAlpha":9.5},`
        ~ ` "not-an-object" ] }`);
    auto t = loadPrefs(dir);
    assert(t.viewportDisplay[0].style == DisplayStyle.Wireframe);
    assert(t.viewportDisplay[0].wireAlpha == 1.0f, "opacity above 1 clamps to opaque");
    assert(t.viewportDisplay[1].style == DisplayStyle.Shaded, "junk entry -> defaults");
    assert(t.viewportDisplay[3].style == DisplayStyle.Shaded, "absent entry -> defaults");

    // Wrong type for the whole key, and a negative opacity.
    write(buildPath(dir, "prefs.json"), `{ "version": 1, "viewportDisplay": 17 }`);
    assert(loadPrefs(dir).viewportDisplay[0].style == DisplayStyle.Shaded,
        "a non-array value must be ignored, not throw");
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "viewportDisplay": [ {"wireAlpha":-3} ] }`);
    assert(loadPrefs(dir).viewportDisplay[0].wireAlpha == 0.0f,
        "negative opacity clamps to fully transparent");
}

// missing file → defaults, no throw.
unittest {
    auto dir = makeScratch("missing");
    scope(exit) cleanScratch(dir);
    // No prefs.json written.
    auto p = loadPrefs(dir);
    assert(p.version_ == kPrefsVersion);
    assert(p.window.w == 0 && p.window.h == 0);
    assert(p.recentFiles.length == 0);
    assert(p.lastDir.length == 0);
    assert(p.toolDefaults.length == 0);
}

// malformed JSON → defaults, no throw.
unittest {
    auto dir = makeScratch("malformed");
    scope(exit) cleanScratch(dir);
    write(buildPath(dir, "prefs.json"), "{ this is not valid json ]]");
    auto p = loadPrefs(dir);   // must not throw
    assert(p.window.w == 0 && p.window.h == 0);
    assert(p.recentFiles.length == 0);
}

// non-object top level → defaults.
unittest {
    auto dir = makeScratch("nonobject");
    scope(exit) cleanScratch(dir);
    write(buildPath(dir, "prefs.json"), "[1,2,3]");
    auto p = loadPrefs(dir);
    assert(p.window.w == 0 && p.recentFiles.length == 0);
}

// unknown keys are ignored; recognized keys still read.
unittest {
    auto dir = makeScratch("unknown");
    scope(exit) cleanScratch(dir);
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "window": {"w": 800, "h": 600},
           "futureKey": {"nested": true}, "anotherUnknown": [1,2,3],
           "lastDir": "/x" }`);
    auto p = loadPrefs(dir);
    assert(p.window.w == 800 && p.window.h == 600);
    assert(p.lastDir == "/x");
}

// a higher `version` is tolerated: recognized keys read best-effort.
unittest {
    auto dir = makeScratch("future");
    scope(exit) cleanScratch(dir);
    write(buildPath(dir, "prefs.json"),
        format(`{ "version": %d, "window": {"w": 1024, "h": 768},
                  "recentFiles": ["/r.v3d"] }`, kPrefsVersion + 99));
    auto p = loadPrefs(dir);
    assert(p.version_ == kPrefsVersion + 99);
    assert(p.window.w == 1024 && p.window.h == 768);
    assert(p.recentFiles == ["/r.v3d"]);
}

// MRU dedupe (existing entry moves to front) + cap at kRecentFilesMax.
unittest {
    // Operate on the global through the note helper; reset around the test.
    auto saved = g_prefs;
    scope(exit) g_prefs = saved;
    g_prefs = Prefs.init;

    // Absolute paths so dedupe compares stably (the helper absolutePath()s).
    prefsNoteRecentFile("/abs/a.v3d");
    prefsNoteRecentFile("/abs/b.v3d");
    prefsNoteRecentFile("/abs/a.v3d");   // dedupe → a moves to front
    assert(g_prefs.recentFiles == ["/abs/a.v3d", "/abs/b.v3d"]);

    // Cap: push more than the limit; oldest fall off the tail.
    g_prefs.recentFiles = null;
    foreach (i; 0 .. kRecentFilesMax + 5)
        prefsNoteRecentFile(format("/abs/f%d.v3d", i));
    assert(g_prefs.recentFiles.length == kRecentFilesMax);
    // Newest push is at the front.
    assert(g_prefs.recentFiles[0] == format("/abs/f%d.v3d", kRecentFilesMax + 4));
}
