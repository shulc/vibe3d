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
import trackball      : kTrackballDefault, kTrackballSpeedDefault,
                        clampTrackballSpeed, kSpinSwingDefault;

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

    /// Trackball navigation (task 0573): whether the orbit drag runs the
    /// trackball (orbit AND bank, chosen by where the press lands) instead of
    /// the two-axis orbit, plus the override that makes every viewport read
    /// this value regardless of its own setting.
    ///
    /// NOT a schema bump, for the same reason `coordRounding` was not: a file
    /// without these keys reads back at the defaults, and the defaults are the
    /// shipped behaviour. The PER-VIEWPORT override is deliberately absent from
    /// this struct — it is camera state, and camera state is runtime-only and
    /// reset on startup (see `View.reset`).
    bool trackball      = kTrackballDefault;
    bool trackballGlobalOverride = false;

    /// The trackball speed multipliers. Two, because the reference keeps a
    /// separate value for a tablet and picks between them by querying the input
    /// device; this editor has no tablet path, so the second one round-trips
    /// and is never selected. Storing it anyway means a profile written by a
    /// future tablet arm is not silently dropped on the next save.
    float trackballSpeed       = kTrackballSpeedDefault;
    float trackballTabletSpeed = kTrackballSpeedDefault;

    /// Momentum spin (task 0582): which curve the spin a release leaves
    /// behind follows. False = Settle, which coasts to a stop in exactly four
    /// seconds; true = Swing, an undamped 1.6-second oscillation that runs
    /// until the next press. Persisted next to the other four because it is one
    /// feature with one reset — and NOT schema-bumping, same as they are: an
    /// older file without the key reads back as the shipped Settle.
    bool trackballSwing = kSpinSwingDefault;

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

    /// Task 0570: the grid's mantissa-ladder mask — which rungs the
    /// zoom-derived grid step is allowed to land on. A 3-bit set (bit 0
    /// admits 2, bit 1 admits 2.5, bit 2 admits 5; 1 and 10 are always in),
    /// so the legal range is 0..7 and the default 5 is the set {1, 2, 5, 10}.
    ///
    /// APPLICATION-WIDE, not per cell — unlike `viewportDisplay` above. A
    /// cell's grid differs from its neighbour's only through its own zoom,
    /// which is the whole law; making the ladder per-cell would offer a knob
    /// with no meaning attached to it.
    ///
    /// See `viewgrid.ViewGridPrefs.rungMask`, which is the LIVE value the
    /// renderer reads; this field is its persisted mirror, seeded into it at
    /// startup and written back by `viewport.gridSteps`.
    int gridStepMask = 5;
}

/// One cell's persisted display state (task 0559).
struct ViewportCellDisplay {
    DisplayStyle style     = DisplayStyle.Shaded;
    WireOverlay  wire      = WireOverlay.Uniform;
    float        wireAlpha = 1.0f;

    /// Task 0594: did a USER choose this style, or is it just the default
    /// this file happened to be written with?
    ///
    /// This distinction did not exist while the default was one value for
    /// every cell, and without it the projection-dependent default cannot be
    /// shipped safely. Two failures it prevents, in opposite directions:
    ///
    ///  * `false` had to be the IN-MEMORY default, or a fresh profile (no
    ///    file at all, so every field is its default) would look like four
    ///    deliberate Shaded choices and suppress the ortho template entirely.
    ///  * `true` has to be what a file WITHOUT the key reads back as. Such a
    ///    file predates this field, its four cells were written
    ///    unconditionally, and there is no way to tell a chosen Shaded from an
    ///    inherited one — so the saved value wins, which is the stated
    ///    precedence. `loadPrefs` sets it per cell OBJECT PRESENT in the file,
    ///    not per key, which is what makes those two rules coexist.
    ///
    /// It is also what stops the shutdown flush from eating the feature. The
    /// live `g_prefs.viewportDisplay` is only written by the `viewport.
    /// display*` command mirror, so an untouched session flushes the values
    /// it loaded; persisting `false` alongside them keeps the next run's
    /// template application correct instead of pinning it to a default that
    /// was never chosen.
    bool styleUserSet = false;
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
                    // Task 0594: a cell OBJECT in the file means the file has
                    // an opinion about this cell. Files written before the
                    // provenance key carry no `styleUserSet`, and their values
                    // must still win over the projection-dependent default —
                    // so presence of the object, not of the key, is what sets
                    // this. An explicit key then overrides it, which is how a
                    // file written by this version says "never chosen" and
                    // lets the template through.
                    p.viewportDisplay[i].styleUserSet = true;
                    if (auto up = "styleUserSet" in cellJson) {
                        if (up.type == JSONType.true_)  p.viewportDisplay[i].styleUserSet = true;
                        if (up.type == JSONType.false_) p.viewportDisplay[i].styleUserSet = false;
                    }
                    if (auto sp = "style" in cellJson)
                        if (sp.type == JSONType.string)
                            switch (sp.str) {
                                case "Wireframe": p.viewportDisplay[i].style = DisplayStyle.Wireframe; break;
                                case "Shaded":    p.viewportDisplay[i].style = DisplayStyle.Shaded;    break;
                                // Task 0589: the face pass now reads
                                // `DrawPlan.facesLit`, so an unshaded fill is
                                // something we DRAW and therefore something we
                                // may persist. Joining this switch and the
                                // command's together is exactly what the note
                                // above asked for.
                                case "Solid":     p.viewportDisplay[i].style = DisplayStyle.Solid;     break;
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

        // Trackball navigation (task 0573).
        if (auto tp = "trackball" in doc)
            if (tp.type == JSONType.true_ || tp.type == JSONType.false_)
                p.trackball = (tp.type == JSONType.true_);
        if (auto tp = "trackballGlobalOverride" in doc)
            if (tp.type == JSONType.true_ || tp.type == JSONType.false_)
                p.trackballGlobalOverride = (tp.type == JSONType.true_);
        if (auto tp = "trackballSwing" in doc)
            if (tp.type == JSONType.true_ || tp.type == JSONType.false_)
                p.trackballSwing = (tp.type == JSONType.true_);

        // Both multipliers go through the SAME clamp the setter uses, so a
        // hand-edited file cannot put a value into the camera's rotation that
        // the command would have refused.
        float readNumber(string key, float def) {
            auto np = key in doc;
            if (np is null) return def;
            float v = float.nan;
            if      (np.type == JSONType.float_)   v = cast(float) np.floating;
            else if (np.type == JSONType.integer)  v = cast(float) np.integer;
            else if (np.type == JSONType.uinteger) v = cast(float) np.uinteger;
            else return def;
            return clampTrackballSpeed(v);
        }
        p.trackballSpeed       = readNumber("trackballSpeed",       p.trackballSpeed);
        p.trackballTabletSpeed = readNumber("trackballTabletSpeed", p.trackballTabletSpeed);
        // Task 0570: the grid rung mask. Out of range is REJECTED (falls back
        // to the default), not clamped: 0..7 is a bit SET, so "8" is not a
        // coarser 7 — it is a value with no meaning, and clamping it would
        // silently answer a question the file did not ask.
        if (auto gsp = "gridStepMask" in doc) {
            long m = long.min;
            if (gsp.type == JSONType.integer)       m = gsp.integer;
            else if (gsp.type == JSONType.uinteger) m = cast(long)gsp.uinteger;
            else if (gsp.type == JSONType.float_)   m = cast(long)gsp.floating;
            if (m >= 0 && m <= 7) p.gridStepMask = cast(int)m;
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
    doc["trackball"]            = JSONValue(p.trackball);
    doc["trackballGlobalOverride"]       = JSONValue(p.trackballGlobalOverride);
    doc["trackballSpeed"]       = JSONValue(p.trackballSpeed);
    doc["trackballTabletSpeed"] = JSONValue(p.trackballTabletSpeed);
    doc["trackballSwing"]   = JSONValue(p.trackballSwing);

    // Task 0559: per-cell display state. Written unconditionally for all four
    // cells, including cells the current layout does not show — a cell's
    // setting has to survive a round trip through Single and back to Quad.
    JSONValue[] vd;
    foreach (ref c; p.viewportDisplay) {
        JSONValue cj = JSONValue(cast(JSONValue[string]) null);
        cj["style"]     = JSONValue(to!string(c.style));
        cj["wire"]      = JSONValue(to!string(c.wire));
        cj["wireAlpha"] = JSONValue(c.wireAlpha);
        // Task 0594: written explicitly, including when false. That `false`
        // is the whole point — it is how the next run learns these three
        // values are an inherited default rather than a choice, and so lets
        // the projection-dependent template apply instead of being pinned by
        // a value nobody picked.
        cj["styleUserSet"] = JSONValue(c.styleUserSet);
        vd ~= cj;
    }
    doc["viewportDisplay"] = JSONValue(vd);

    // Task 0570: the grid's mantissa-ladder mask (app-wide).
    doc["gridStepMask"] = JSONValue(p.gridStepMask);

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

// Task 0570: gridStepMask round-trip, default, and rejection-on-load.
unittest {
    import viewgrid : kGridMaskDefault;

    auto dir = makeScratch("gridstepmask");
    scope(exit) cleanScratch(dir);

    auto def = loadPrefs(dir);
    assert(def.gridStepMask == kGridMaskDefault,
           "unset -> the shipped ladder {1,2,5,10}");
    assert(def.gridStepMask == 5);

    // Every legal mask round-trips, including 0 (which a `if (m)` truthiness
    // bug would drop back to the default while looking like it worked).
    foreach (m; 0 .. 8) {
        Prefs p;
        p.gridStepMask = m;
        savePrefs(p, dir);
        assert(loadPrefs(dir).gridStepMask == m, "every mask 0..7 must round-trip");
    }

    // Out of range is REJECTED, not clamped: the mask is a bit set, so 8 is
    // not "a coarser 7".
    write(buildPath(dir, "prefs.json"), `{ "version": 1, "gridStepMask": 8 }`);
    assert(loadPrefs(dir).gridStepMask == 5, "8 -> default, not clamped to 7");
    write(buildPath(dir, "prefs.json"), `{ "version": 1, "gridStepMask": -1 }`);
    assert(loadPrefs(dir).gridStepMask == 5, "-1 -> default");
    write(buildPath(dir, "prefs.json"), `{ "version": 1, "gridStepMask": "five" }`);
    assert(loadPrefs(dir).gridStepMask == 5, "a non-number -> default");
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
        // Task 0594. A FRESH profile has chosen nothing, and this must read
        // false — if it defaulted to true, a first-run user would look like
        // four deliberate Shaded choices and the projection-dependent
        // template would be suppressed on the machine of every new user.
        assert(!c.styleUserSet,
            format("cell %d: a profile with no file has chosen nothing", i));
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
}

// Task 0594: the PERSISTED half of the display-default precedence.
//
// The runtime half (a chosen style surviving a layout switch) is an HTTP test.
// This is the half that only a file can answer: does a style saved by one run
// still outrank the shipped projection-dependent template on the NEXT launch,
// and does a profile that chose nothing let the template through?
unittest {
    auto dir = makeScratch("viewportdisplayprov");
    scope(exit) cleanScratch(dir);

    // 1. A CHOICE survives the round trip, carrying its provenance with it.
    //    Without the provenance surviving, app.d cannot tell this Shaded from
    //    the Shaded that every pre-0594 file happens to contain, and would
    //    have to either ignore both (losing the choice) or honour both
    //    (killing the feature).
    Prefs p;
    p.viewportDisplay[1].style       = DisplayStyle.Shaded;
    p.viewportDisplay[1].styleUserSet = true;
    savePrefs(p, dir);
    auto q = loadPrefs(dir);
    assert(q.viewportDisplay[1].styleUserSet,
        "a style the user chose must come back marked as chosen");
    assert(q.viewportDisplay[1].style == DisplayStyle.Shaded,
        "the chosen style itself must round-trip");

    // 2. A cell nobody chose comes back UNCHOSEN even though `savePrefs`
    //    wrote its three values out. This is the one that keeps the feature
    //    alive across restarts: the shutdown flush persists whatever was
    //    loaded, so every untouched cell is written to disk on every clean
    //    exit. If those writes read back as choices, the template would apply
    //    exactly once — on a profile's very first run — and never again.
    foreach (i; [0, 2, 3])
        assert(!q.viewportDisplay[i].styleUserSet,
            format("cell %d was never chosen and must not read back as "
                   ~ "chosen — otherwise one clean shutdown pins the "
                   ~ "viewport to a default nobody picked", i));

    // 3. A file that PREDATES the key: its cells carry no `styleUserSet` at
    //    all. Those values must win, because there is no way to tell a chosen
    //    Shaded from an inherited one in a file written before the
    //    distinction existed, and the stated precedence is that a persisted
    //    value beats a new default. Note this is keyed on the cell OBJECT
    //    being present, not on any particular key inside it.
    auto legacy = makeScratch("viewportdisplaylegacy");
    scope(exit) cleanScratch(legacy);
    write(buildPath(legacy, "prefs.json"),
        `{ "version": 1, "viewportDisplay": [ {"style":"Shaded","wire":"Uniform","wireAlpha":1.0},`
        ~ ` {"style":"Shaded"}, {"style":"Shaded"}, {"style":"Shaded"} ] }`);
    auto old = loadPrefs(legacy);
    foreach (i; 0 .. 4)
        assert(old.viewportDisplay[i].styleUserSet,
            format("cell %d came from a file that predates the provenance "
                   ~ "key; its saved value must outrank the new default", i));

    // 4. And the discrimination is real, not "everything is true": a file
    //    written by THIS version that says false must read back false. If
    //    both branches produced true, assertion 3 would pass vacuously.
    auto mixed = makeScratch("viewportdisplaymixed");
    scope(exit) cleanScratch(mixed);
    write(buildPath(mixed, "prefs.json"),
        `{ "version": 1, "viewportDisplay": [ {"style":"Shaded","styleUserSet":false},`
        ~ ` {"style":"Shaded","styleUserSet":true} ] }`);
    auto mx = loadPrefs(mixed);
    assert(!mx.viewportDisplay[0].styleUserSet,
        "an explicit false must be honoured, or the template can never apply "
        ~ "after the first clean shutdown");
    assert(mx.viewportDisplay[1].styleUserSet,
        "an explicit true must be honoured");
    // A cell absent from the array entirely keeps the in-memory default.
    assert(!mx.viewportDisplay[3].styleUserSet,
        "a cell the file does not mention has chosen nothing");

    // A name we resolve but do not DRAW falls back to the default rather than
    // coming back as a viewport that renders something other than what it
    // reports. Same stance the commands take, for the same reason.
    //
    // TASK 0589 CHANGED WHAT BELONGS ON EACH SIDE OF THIS LINE, and it is
    // worth saying why rather than just editing the literal. This case used to
    // read `{"style":"Solid","wire":"Colored"}` and assert BOTH fell back. The
    // reason given was "a style no pass draws" — and that reason is now false
    // for Solid: the face pass reads `DrawPlan.facesLit`, so an unshaded fill
    // is drawn, and a profile naming it must come back naming it (proven by
    // its own round-trip block below). Keeping the old assertion would not be
    // conservatism, it would pin prefs to silently discard a style the app can
    // render. `Colored` is untouched — nothing resolves a per-item line colour
    // — and an unknown name stands in for the style side.
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "viewportDisplay": [ {"style":"Texture","wire":"Colored"} ] }`);
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

// Task 0589: the unshaded fill round-trips through a saved profile.
//
// This is a SEPARATE block from the one above on purpose. The save side writes
// the enum's own name (`to!string`), and the load side is a hand-written
// switch, so a style is persistable only if somebody remembers to add it to
// that switch — which is precisely the step that was deliberately NOT taken
// while the style was undrawable. Writing it through `savePrefs` rather than a
// JSON literal is what makes this catch the omission: a literal would only
// test the reader, and the two sides drifting is the failure that matters
// (a profile that saves "Solid" and reloads as "Shaded" loses the user's
// viewport silently, once, at the next launch).
unittest {
    auto dir = makeScratch("viewportdisplaysolid");
    scope(exit) cleanScratch(dir);

    Prefs p;
    p.viewportDisplay[1].style = DisplayStyle.Solid;
    savePrefs(p, dir);

    // The file must literally name it — if `to!string` ever stopped agreeing
    // with the reader's case labels this is where it shows, in the artefact
    // rather than in the round-trip's result.
    import std.file : readText;
    import std.algorithm : canFind;
    assert(readText(buildPath(dir, "prefs.json")).canFind(`"Solid"`),
        "the saved profile must name the style it is persisting");

    auto q = loadPrefs(dir);
    assert(q.viewportDisplay[1].style == DisplayStyle.Solid,
        "an unshaded-fill cell must come back unshaded, not silently Shaded");
    foreach (i; [0, 2, 3])
        assert(q.viewportDisplay[i].style == DisplayStyle.Shaded,
            format("cell %d must be untouched by a write to cell 1", i));
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

// ---------------------------------------------------------------------------
// Task 0705 (audit 4, wave 2, A8) — EXHAUSTIVE round-trip gate.
//
// `Prefs` is 17 fields with three hand-written mirrors each (declaration, a
// line in `savePrefs`, a line in `loadPrefs`) and, until this test, no gate
// that all three existed. The round-trip test above claims in its own comment
// to serialize "a fully populated Prefs" and asserts SIX of the seventeen;
// seven fields had no round-trip coverage at all (the whole trackball group,
// and both coordinate-rounding fields).
//
// The audit asked for a generic `__traits(allMembers, Prefs)` SERIALIZER. That
// is not expressible: of the 17 fields a naive generic handles about 10, and
// the other 7 carry per-field policy a generic would have to be told anyway —
// `version_` writes the CONSTANT rather than the field, `toolDefaults` drops
// empty inner maps, `recentFiles` caps at load, four floats clamp at load, and
// `viewportDisplay[].styleUserSet` is decided by the PRESENCE of the cell
// object rather than by its key. Replacing hand-written I/O that encodes real
// decisions with a generic that has to be handed the same decisions field by
// field buys nothing.
//
// What the enumeration IS worth is the GATE. Every field is set to a
// non-default value, saved, loaded and compared — and because the walk comes
// from `tupleof`, a field added tomorrow is covered the moment it is declared.
// The `static assert` below is the enforcement: a new field must be handled by
// one of the type arms or named in `kPrefsRoundTripExempt` with a reason, or
// this file does not compile. That is the half the audit was really after.
version (unittest) {
    /// Fields the round-trip gate cannot compare, each for a stated reason.
    /// Adding a name here is a decision someone has to write down; leaving a
    /// new field out of BOTH this list and the type arms is a build error.
    private enum string[] kPrefsRoundTripExempt = [
        // Deliberately NOT a mirror of the field: `savePrefs` writes
        // `kPrefsVersion`, so a struct carrying any other value saves as the
        // current schema version. Comparing it would assert the opposite of
        // the intended behaviour.
        "version_",
        // The presence/absence rule (`styleUserSet` follows the cell OBJECT,
        // not its key) and `WireOverlay.Colored`, which the loader's switch
        // deliberately does not accept, are both covered by the four dedicated
        // `viewportDisplay` tests above — a blanket equality here would either
        // duplicate them or contradict them.
        "viewportDisplay",
    ];
}

unittest {
    import std.traits : isFloatingPoint, isIntegral, EnumMembers;

    auto dir = makeScratch("roundtripall");
    scope(exit) cleanScratch(dir);

    Prefs p;

    // `tupleof`, not `allMembers`: it yields exactly the FIELDS, in
    // declaration order, and skips the nested `Window` type declaration and
    // every method. Same enumeration `FalloffConfig.dup` uses.
    //
    // Every field gets a value that is (a) different from its default and
    // (b) inside whatever range the LOADER accepts — an out-of-range value
    // would be clamped or rejected on load, which is a documented behaviour of
    // its own, tested separately, not here.
    static foreach (i, F; typeof(Prefs.tupleof)) {{
        enum name   = __traits(identifier, Prefs.tupleof[i]);
        enum exempt = () {
            foreach (x; kPrefsRoundTripExempt) if (x == name) return true;
            return false;
        }();
        static if (exempt) {
            // nothing to set — see kPrefsRoundTripExempt
        } else static if (is(F == bool)) {
            p.tupleof[i] = !p.tupleof[i];
        } else static if (is(F == enum)) {
            // The last member that is not the default, so the choice stays
            // stable as members are appended.
            foreach (e; EnumMembers!F)
                if (e != Prefs.init.tupleof[i]) p.tupleof[i] = e;
        } else static if (isFloatingPoint!F) {
            p.tupleof[i] = 0.25f;      // inside every loader range
        } else static if (isIntegral!F) {
            p.tupleof[i] = 3;          // gridStepMask's range is 0..7
        } else static if (is(F == string)) {
            p.tupleof[i] = "/abs/roundtrip";
        } else static if (is(F == string[])) {
            p.tupleof[i] = ["/abs/a.v3d", "/abs/b.obj"];
        } else static if (is(F == Prefs.Window)) {
            p.tupleof[i] = Prefs.Window(1426, 966);
        } else static if (is(F == string[string][string])) {
            p.tupleof[i]["bevel"] = ["width": "0.25"];
        } else {
            static assert(false,
                "Prefs." ~ name ~ " has a type the round-trip gate does not "
                ~ "know how to exercise. Add an arm for it, or name it in "
                ~ "kPrefsRoundTripExempt with the reason it cannot be "
                ~ "compared — a field in neither is a field nothing checks "
                ~ "was saved and loaded at all.");
        }
    }}

    savePrefs(p, dir);
    auto q = loadPrefs(dir);

    static foreach (i, F; typeof(Prefs.tupleof)) {{
        enum name   = __traits(identifier, Prefs.tupleof[i]);
        enum exempt = () {
            foreach (x; kPrefsRoundTripExempt) if (x == name) return true;
            return false;
        }();
        static if (!exempt)
            assert(q.tupleof[i] == p.tupleof[i],
                "Prefs." ~ name ~ " did not survive save+load — it is missing "
                ~ "from savePrefs, from loadPrefs, or the two spell its JSON "
                ~ "key differently");
    }}

    // And the exempt one that still has a checkable contract.
    assert(q.version_ == kPrefsVersion);
}
