module vibe3d.editing.commands.runtime.record_observer_hub;

import core.atomic : atomicOp;
import vibe3d.editing.commands.runtime.command_history : HistoryFlags;

private shared ulong nextRecordObserverOwnerId_;

/// Detached image of the two exact production record observers: MacroRecorder
/// and the HTTP-only step-trace chain. Storage is private and owner-copied.
struct PreparedRecordObserverImage {
private:
    ulong owner;
    string[] macroLines;
    string[] traceEntries;
    bool macroActive, traceArmed, consumable;
public:
    @disable this(this);
}

/// The prepared-path observer owner. Legacy `CommandHistory.onRecord` is still
/// wired beside it, and a production caller DOES reach this now: app.d builds
/// one hub and hands it to every `prepareArm`. Every DROP transition is owned
/// by the LEGACY door and reaches none of this — task 4053 measured why, and
/// source/tool_activation_ownership.d is the table that says so.
final class RecordObserverHub {
private:
    immutable ulong owner_;
    string[] macroLines_;
    string[] traceEntries_;
    bool macroActive_, traceArmed_;
public:
    this() nothrow @nogc {
        owner_ = atomicOp!"+="(nextRecordObserverOwnerId_, 1UL);
    }

    void setMacroActive(bool active) nothrow @nogc { macroActive_ = active; }
    void setTraceArmed(bool armed) nothrow @nogc { traceArmed_ = armed; }
    size_t macroLength() const nothrow @nogc { return macroLines_.length; }
    size_t traceLength() const nothrow @nogc { return traceEntries_.length; }
    string macroAt(size_t i) const nothrow @nogc { return macroLines_[i]; }
    string traceAt(size_t i) const nothrow @nogc { return traceEntries_[i]; }
    bool macroActive() const nothrow @nogc { return macroActive_; }
    void startMacro() nothrow {
        macroActive_ = true; macroLines_.length = 0;
    }
    void stopMacro() nothrow @nogc { macroActive_ = false; }
    void clearMacro() nothrow { macroLines_.length = 0; }
    void observeLegacy(string line, uint /+flags+/ _flags) {
        if (macroActive_ && line.length) macroLines_ ~= line;
    }
    string[] macroLines() const { return macroLines_.dup; }

    PreparedRecordObserverImage prepareRecord(string line, uint flags,
                                               string preparedTraceJson = null) {
        PreparedRecordObserverImage result;
        result.owner = owner_;
        result.macroLines = macroLines_.dup;
        result.traceEntries = traceEntries_.dup;
        result.macroActive = macroActive_;
        result.traceArmed = traceArmed_;
        result.consumable = true;
        evolvePrepared(result, line, flags, preparedTraceJson);
        return result;
    }

    /// Evolve an already-detached owner image in producer order. This never
    /// rereads or clones the live hub, so a multi-effect arm cannot lose an
    /// earlier prepared observation.
    bool evolvePrepared(ref PreparedRecordObserverImage result, string line,
                        uint flags, string preparedTraceJson = null) {
        if (!validates(result)) return false;
        if (result.macroActive && line.length) result.macroLines ~= line.idup;
        if (result.traceArmed && preparedTraceJson.length &&
            !(flags & (HistoryFlags.InSession | HistoryFlags.Refire |
                       HistoryFlags.ToolLifecycle))) {
            result.traceEntries ~= preparedTraceJson.idup;
            if (result.traceEntries.length > 500)
                result.traceEntries = result.traceEntries[$ - 500 .. $].dup;
        }
        return true;
    }

    bool validates(ref PreparedRecordObserverImage image) const nothrow @nogc {
        return image.owner == owner_ && image.consumable;
    }

    void installPrepared(ref PreparedRecordObserverImage image) nothrow @nogc {
        if (image.owner != owner_ || !image.consumable) return;
        image.consumable = false;
        macroLines_ = image.macroLines;
        traceEntries_ = image.traceEntries;
        macroActive_ = image.macroActive;
        traceArmed_ = image.traceArmed;
        image.macroLines = null;
        image.traceEntries = null;
    }
}



static assert(!__traits(compiles, {
    PreparedRecordObserverImage a; PreparedRecordObserverImage b = a;
}));
