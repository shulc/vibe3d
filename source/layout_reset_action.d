module layout_reset_action;

import prefs : Prefs;

alias LayoutIniRestore = bool delegate(string userIniPath);
alias LayoutIniLoader = void delegate(string userIniPath);

/// Application-owned Reset Layout state and ordering. Authoring persists the
/// Single preset, restores the shipped ini only outside test mode, and records
/// either a one-shot pre-NewFrame reload or a fallback reseed. The restored
/// bytes must enter ImGui's live settings before its autosave/shutdown save can
/// overwrite them with the old dock tree, but loading inside the button's
/// NewFrame/EndFrame interval is unsafe; therefore authorReset only schedules
/// and reloadBeforeFrame consumes exactly once (task 5850; evidence:
/// viewport_props_roles_test).
final class LayoutResetAction {
private:
    Prefs* prefs_;
    bool testMode_;
    string layoutIniPath_;
    const(char)* layoutIniPathZ_;
    bool pendingReload_;
    bool fallbackReseed_;
    LayoutIniRestore restore_;
    LayoutIniLoader load_;

public:
    this(Prefs* prefs, bool testMode, LayoutIniRestore restore,
         LayoutIniLoader load) {
        assert(prefs !is null, "layout reset requires preferences storage");
        assert(restore !is null, "layout reset requires an ini restore action");
        assert(load !is null, "layout reset requires an ini load action");
        prefs_ = prefs;
        testMode_ = testMode;
        restore_ = restore;
        load_ = load;
    }

    /// Bind the versioned user ini path once. The zero-terminated pointer is
    /// kept by this owner for the full ImGui context lifetime.
    void bindLayoutIniPath(string path) {
        import std.string : toStringz;

        assert(layoutIniPath_.length == 0,
            "layout ini path must be bound at most once");
        layoutIniPath_ = path.dup;
        layoutIniPathZ_ = layoutIniPath_.toStringz;
    }

    const(char)* iniFilename() const nothrow @nogc {
        return layoutIniPathZ_;
    }

    void authorReset() {
        import std.file : exists, remove;
        import viewport : LayoutPreset;

        // Same persisted/live mirror as registration.d's file.new and
        // scene.reset onViewportReset delegates; the rationale lives there.
        prefs_.viewportLayout = LayoutPreset.Single;
        bool restored;
        if (!testMode_ && layoutIniPath_.length != 0) {
            try {
                if (exists(layoutIniPath_)) remove(layoutIniPath_);
            } catch (Exception) {}
            restored = restore_(layoutIniPath_);
        }
        pendingReload_ = restored;
        fallbackReseed_ = !restored;
    }

    /// Called by the application loop strictly before the next NewFrame.
    /// Loading clears the request first so an exception cannot replay it.
    void reloadBeforeFrame() {
        if (!pendingReload_) return;
        pendingReload_ = false;
        load_(layoutIniPath_);
    }

    bool consumeFallbackReseed() nothrow @nogc {
        const requested = fallbackReseed_;
        fallbackReseed_ = false;
        return requested;
    }

    bool pendingReload() const nothrow @nogc { return pendingReload_; }
    bool fallbackReseed() const nothrow @nogc { return fallbackReseed_; }
}

/// Resolve and copy the shipped layout without overwriting an existing user
/// ini. The executable-relative retry preserves installed-build startup/reset
/// behavior when the working directory has no config folder.
bool seedDefaultLayoutIfMissing(string userIniPath) {
    import std.file : exists, thisExePath;
    import std.path : buildPath, dirName;
    import prefs : seedLayoutIniIfMissing;

    string defaultPath = "config/default_layout.ini";
    if (!exists(defaultPath)) {
        try {
            string exeRelative = buildPath(thisExePath().dirName,
                "config", "default_layout.ini");
            if (exists(exeRelative)) defaultPath = exeRelative;
        } catch (Exception) {}
    }
    return seedLayoutIniIfMissing(defaultPath, userIniPath);
}
