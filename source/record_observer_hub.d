module record_observer_hub;

import core.atomic : atomicOp;
import command_history : HistoryFlags;

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
/// one hub and hands it to every `prepareArm` and, since task 4053, to
/// `prepareDrop`.
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

unittest {
    auto hub = new RecordObserverHub();
    hub.setMacroActive(true); hub.setTraceArmed(true);
    auto image = hub.prepareRecord("mesh.delete", 0, `{"seq":0}`);
    assert(hub.macroLength == 0 && hub.traceLength == 0);
    assert(hub.validates(image));
    hub.installPrepared(image);
    assert(hub.macroLength == 1 && hub.macroAt(0) == "mesh.delete");
    assert(hub.traceLength == 1 && hub.traceAt(0) == `{"seq":0}`);
    hub.installPrepared(image);
    assert(hub.macroLength == 1 && hub.traceLength == 1);

    auto inSession = hub.prepareRecord("tool.attr", HistoryFlags.InSession,
                                       `{"must":"not append"}`);
    hub.installPrepared(inSession);
    assert(hub.macroLength == 2 && hub.traceLength == 1);

    auto refire = hub.prepareRecord("refire", HistoryFlags.Refire, `{"must":"not append"}`);
    hub.installPrepared(refire);
    auto lifecycle = hub.prepareRecord("tool.set x off", HistoryFlags.ToolLifecycle,
                                       `{"must":"not append"}`);
    hub.installPrepared(lifecycle);
    auto emptyTrace = hub.prepareRecord("empty.trace", 0, null);
    hub.installPrepared(emptyTrace);
    assert(hub.macroLength == 5 && hub.traceLength == 1);

    hub.setMacroActive(false);
    foreach (i; 0 .. 501) {
        import std.conv : to;
        auto row = i.to!string;
        auto next = hub.prepareRecord("ignored", 0, row);
        hub.installPrepared(next);
    }
    assert(hub.traceLength == 500);
    assert(hub.traceAt(0) == "1");
    assert(hub.traceAt(499) == "500");

    auto other = new RecordObserverHub();
    auto wrong = hub.prepareRecord("wrong", 0);
    assert(!other.validates(wrong));
    other.installPrepared(wrong);
    assert(other.macroLength == 0);
}

static assert(!__traits(compiles, {
    PreparedRecordObserverImage a; PreparedRecordObserverImage b = a;
}));
