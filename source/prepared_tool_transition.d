module prepared_tool_transition;

// P1.0a inert owner seam. Neither production activation door imports/calls it.
import std.algorithm.mutation : move;
import prepared_tool_effect;
import command_history : CommandHistory, PreparedHistoryImage;
import change_bus : ChangeBus, PreparedDeliveryJournal;
import tool : Tool;
import registry : ToolFactory;

version (unittest) private __gshared bool failPreparedArmAfterFactory_;
version (unittest) void setPreparedArmAfterFactoryFaultForTest(bool enabled) nothrow {
    failPreparedArmAfterFactory_ = enabled;
}

@PreparedOwnedContainer struct PreparedEffectList {
    alias Element = PreparedToolEffect;
private:
    PreparedToolEffect[] entries_;
public:
    @disable this(this);
    void append(PreparedToolEffect effect) {
        entries_.length = entries_.length + 1;
        move(effect, entries_[$ - 1]);
    }
    size_t length() const pure nothrow @safe @nogc { return entries_.length; }
}

/// Actual candidate lifetime owner. Tool references never enter the prepared
/// algebra; the future commit exchanges them through this typed owner only.
struct PreparedCandidateOwner {
private:
    Tool candidate_;
    Tool retainedOld_;
public:
    @disable this(this);
    void prepareFrom(ToolFactory factory, Tool retainedOld) {
        auto next = factory(); // failure leaves the previously prepared value owned
        prepare(next, retainedOld);
    }
    void prepare(Tool candidate, Tool retainedOld) {
        discardCandidate();
        candidate_ = candidate;
        retainedOld_ = retainedOld;
    }
    void discardCandidate() nothrow {
        if (candidate_ !is null) destroy(candidate_);
        candidate_ = null;
    }
    Tool preparedCandidate() nothrow { return candidate_; }
    void publish(ref Tool active) nothrow {
        active = candidate_;
        candidate_ = null;
    }
    void disposeRetained() nothrow {
        if (retainedOld_ !is null) destroy(retainedOld_);
        retainedOld_ = null;
    }
}

/// One noncopyable transaction owns every owner-issued prepared handle. It is
/// consumed as a unit; none of its pieces can be independently committed.
struct PreparedArm {
private:
    PreparedEffectList effects_;
    PreparedCandidateOwner candidate_;
    PreparedHistoryImage history_;
    PreparedDeliveryJournal journal_;
    bool consumed_;
public:
    @disable this(this);
    size_t effectCount() const pure nothrow @safe @nogc { return effects_.length; }
    bool consumed() const pure nothrow @safe @nogc { return consumed_; }
}

PreparedArm prepareArm(ToolFactory factory, Tool retainedOld,
                       CommandHistory history,
                       const(PreparedJournalEntry)[] journalRows,
                       const(ubyte)[] copiedInput) {
    PreparedArm result;
    result.candidate_.prepareFrom(factory, retainedOld);
    // Ownership starts at the successful factory return, not at function
    // return. Every later prepare step may allocate/throw, so arm cleanup
    // before the first one and disarm it only after the whole value is built.
    bool candidateCleanupArmed = true;
    scope(failure) if (candidateCleanupArmed)
        result.candidate_.discardCandidate();
    version (unittest) {
        if (failPreparedArmAfterFactory_)
            throw new Exception("prepared arm injected failure after factory");
    }
    result.history_ = history.prepareCurrentImage();
    result.journal_ = PreparedDeliveryJournal.copyOf(journalRows);
    PreparedToolEffect effect;
    effect.kind = PreparedEffectKind.OwnedBuffer;
    effect.ownedBuffer = OwnedBytes.copyOf(copiedInput);
    result.effects_.append(effect);
    candidateCleanupArmed = false;
    return result;
}

bool commitPreparedArm(ref Tool active, CommandHistory history,
                       ref ChangeBus bus, ref PreparedArm prepared) nothrow {
    if (prepared.consumed_) return false;
    prepared.candidate_.publish(active);
    history.installPreparedImage(prepared.history_);
    prepared.journal_.replay(bus);
    prepared.candidate_.disposeRetained();
    prepared.consumed_ = true;
    return true;
}

static assert(is(typeof(&commitPreparedArm) == bool function(
    ref Tool, CommandHistory, ref ChangeBus, ref PreparedArm) nothrow));
private void proveCandidateDiscard(ref PreparedCandidateOwner owner) nothrow {
    owner.discardCandidate();
}
static assert(is(typeof(&proveCandidateDiscard) ==
    void function(ref PreparedCandidateOwner) nothrow));
