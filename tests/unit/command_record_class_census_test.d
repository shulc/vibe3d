// The command-record class census for task 4570. The module name
// `command_record_class_census_test` is project-owned: an exact `grep -rl -w`
// over the SDK tree returned zero files before this test was added.
// General pattern: doc/derived_census_pattern.md (project-owned path; an exact
// SDK-tree search for derived_census_pattern returned no files).
//
// The receiver side is derived, not a spelling list: discover every aggregate
// that declares undoStack/redoStack, treat ANY field mention (plus delegate or
// mixin syntax inside that member's own body) as a proposal, then close
// transitively over direct or address-taken member edges. Named residual: a
// member calling another member injected into the same class by a mixin
// template is not followed through the real mixin graph. This is safe today:
// source/command_history.d has no live mixin, and the gate's actor is an
// external caller, which cannot inject a member into the class. A future mixin
// in that file is the trigger to extend and mutation-test this arm.
// `blankNonCode` removes comments AND literals before brace matching. The
// receiver ledger disposes every public proposal as either a caller-tracked
// history primitive or an explicit read/navigation excuse; an unclassified
// proposal fails. `blockEnd` and `refireBegin` really reach record and are
// entry primitives. `blockBegin` is audited beside its peer but only opens
// grouping state. The caller side remains the exact symbol|primitive ledger.
// In particular, the LayerAdd built by `/api/test/layer` must cross
// CommandExecutor instead of becoming a second apply+record implementation
// beside it.
module tests.unit.command_record_class_census_test;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : dirEntries, exists, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : startsWith, strip;

import tests.unit.census_symbols : LedgerHit, LedgerRow, blankNonCode,
    declaratorName, historySurface, isIdentChar, lineOf, reconcile,
    symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// Existing project symbols, not borrowed SDK vocabulary: exact `grep -rl -w`
// over the SDK tree returned zero files for refireEnd/tryRefireDispatch/
// refireEnded. The generic word fire had seven unrelated hits, so its meaning
// here is classified by the CommandHistory receiver and enclosing symbol.
private enum LedgerRow[] kResidue = [
    LedgerRow("CommandExecutor.applyOrRefire|fire", 1,
        "ordinary Command — refire and fire's fallback stay in the executor"),
    LedgerRow("CommandExecutor.applyOrRefire|record", 1,
        "ordinary Command — the sole generic apply/fire/history executor"),
    LedgerRow("CommandExecutor.applyOrRefire|recordCoalescing", 1,
        "ordinary Command — the coalescing mode of the same executor"),
    LedgerRow("PreparedRecordContext.this|beginPrepared", 1,
        "prepared Command arm — opens the detached history transaction at "
      ~ "source/prepared_record_context.d:366"),
    LedgerRow("PreparedRecordContext.prepare|prepareRecord", 1,
        "prepared Command arm — evolves the detached entry at "
      ~ "source/prepared_record_context.d:1313"),
    LedgerRow("PreparedRecordContext.prepareLifecycle|prepareLifecycle", 1,
        "prepared lifecycle arm — evolves the detached entry at "
      ~ "source/prepared_record_context.d:1320"),
    LedgerRow("PreparedRecordContext.consolidate|prepareConsolidate", 1,
        "prepared Command arm — consolidates the detached run at "
      ~ "source/prepared_record_context.d:1336"),
    LedgerRow("PreparedRecordContext.prepareInvalidateRedo|prepareInvalidateRedo", 1,
        "prepared Command arm — evolves redo state in the same transaction at "
      ~ "source/prepared_record_context.d:1342"),
    LedgerRow("PreparedRecordContext.nextRun|prepareNextRun", 1,
        "prepared Command arm — advances the detached run at "
      ~ "source/prepared_record_context.d:1374"),
    LedgerRow("PreparedRecordContext.install|installPreparedToken", 2,
        "prepared Command arm — installs from both journal paths at "
      ~ "source/prepared_record_context.d:1661 and :1971"),
    LedgerRow("HistoryHttpAdapter.wire.setBlockHandler|blockEnd", 1,
        "command block — the history endpoint lands the collected children"),
    LedgerRow("Tool.recordGestureEdit|record", 1,
        "GesturePayload — Tool validates the carrier before recording"),
    LedgerRow("Tool.recordGestureEdit|recordInSession", 1,
        "GesturePayload — the in-session gesture writer at source/tool.d:699"),
    LedgerRow("Tool.recordGestureEdit|replaceInSessionTailWith", 1,
        "GesturePayload — the run-tail gesture writer at source/tool.d:702"),
    LedgerRow("TransformTool.recordCommit|record", 1,
        "transform gesture edit — the deliberately unmigrated task-1905 zone"),
    LedgerRow("TransformTool.recordCommit|recordInSession", 1,
        "transform gesture edit — the base transform in-session writer"),
    LedgerRow("XfrmTransformTool.recordTransformCommand|recordInSession", 1,
        "wrapper-owned transform gesture intent"),
    LedgerRow("XfrmTransformTool.recordTransformCommand|record", 1,
        "wrapper-owned transform boundary intent"),
    LedgerRow("XfrmTransformTool.recordTransformCommand|replaceInSessionTail", 1,
        "wrapper-owned generation-scoped transform refire intent"),
    LedgerRow("Tool.refuseGestureRecord|consolidate", 1,
        "GesturePayload — refusal closes or re-tags the already-open run"),
    LedgerRow("XfrmTransformTool.deactivate|consolidate", 1,
        "transform gesture edit — tool drop collapses the final run"),
    LedgerRow("XfrmTransformTool.consolidateRunAndAdvance|consolidate", 1,
        "transform re-grade — an explicit run boundary collapses its tail"),
    LedgerRow("EditSession.tryRefireDispatch|fire", 1,
        "refire-built Command — the session dispatches it inside the bracket"),
    LedgerRow("EditSession|refireBegin", 1,
        "refire-built Command — the one-line wrapper's defensive begin lands "
      ~ "a dangling command"),
    LedgerRow("EditSession.refireEnded|refireEnd", 1,
        "refire-built Command — the session lands the bracket's final entry"),
    LedgerRow("InputRouter.commitInteractiveSelEdit|recordCoalescing", 1,
        "MeshSelectionEdit — the UI-selection undo class"),
];

// Test-only scanner vocabulary: exact SDK-tree searches returned no files for
// HistoryMember, HistoryOwnerScan, collectHistoryOwnerScans,
// parseHistoryOwnerScans,
// declaresHistoryStackField, mentionsHistoryStackField,
// historyLastIdentifier, historyDelegateFields, hasHistoryIndirectEdge,
// deriveHistoryReceiverHits, kReceiverDisposition, receiverTracksCallers or
// auditedHistoryProtocolPeer. The words describe local syntax, not an external
// API classification.
private struct HistoryMember {
    string owner;
    string name;
    string body;
    size_t line;
    bool hidden;
}

private struct HistoryOwnerScan {
    string name;
    size_t open;
    size_t close;
    size_t line;
    HistoryMember[] members;
}

private bool wordAt(string s, size_t p, string word) {
    return p + word.length <= s.length && s[p .. p + word.length] == word
        && (p == 0 || !isIdentChar(s[p - 1]))
        && (p + word.length == s.length || !isIdentChar(s[p + word.length]));
}

private bool hasWord(string s, string word) {
    foreach (i; 0 .. s.length)
        if (wordAt(s, i, word)) return true;
    return false;
}

private size_t matchingBrace(string code, size_t open) {
    int depth;
    foreach (i; open .. code.length) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return i;
    }
    return code.length;
}

private string aggregateName(string signature) {
    foreach (kind; ["class", "struct", "union"]) {
        foreach (p; 0 .. signature.length) {
            if (!wordAt(signature, p, kind)) continue;
            size_t q = p + kind.length;
            while (q < signature.length && (signature[q] == ' '
                    || signature[q] == '\t' || signature[q] == '\n'
                    || signature[q] == '\r')) ++q;
            const start = q;
            while (q < signature.length && isIdentChar(signature[q])) ++q;
            if (q > start) return signature[start .. q];
        }
    }
    return "";
}

private bool declaresHistoryStackField(string code, size_t open, size_t close) {
    size_t declFrom = open + 1;
    for (size_t i = declFrom; i < close; ++i) {
        if (code[i] == ':') {
            declFrom = i + 1;
        } else if (code[i] == ';') {
            auto declaration = code[declFrom .. i];
            if (!declaration.canFind("(")
                    && (hasWord(declaration, "undoStack")
                        || hasWord(declaration, "redoStack"))) return true;
            declFrom = i + 1;
        } else if (code[i] == '{') {
            const end = matchingBrace(code, i);
            if (end >= code.length) return false;
            i = end;
            declFrom = end + 1;
        }
    }
    return false;
}

private HistoryMember[] parseHistoryMembers(string code,
                                             ref HistoryOwnerScan owner) {
    HistoryMember[] members;
    string protection = "public";
    size_t declFrom = owner.open + 1;
    for (size_t i = declFrom; i < owner.close; ++i) {
        if (code[i] == ':' || code[i] == ';') {
            auto part = code[declFrom .. i].strip;
            if (code[i] == ':' && (part == "public" || part == "private"
                    || part == "protected" || part == "package"))
                protection = part;
            declFrom = i + 1;
        } else if (code[i] == '{') {
            const end = matchingBrace(code, i);
            if (end >= code.length) return members;
            auto signature = code[declFrom .. i];
            auto name = declaratorName(signature);
            const aggregate = hasWord(signature, "class")
                || hasWord(signature, "struct") || hasWord(signature, "union")
                || hasWord(signature, "interface") || hasWord(signature, "template");
            if (name.length && signature.canFind("(") && !aggregate) {
                const explicitPublic = hasWord(signature, "public");
                const explicitHidden = hasWord(signature, "private")
                    || hasWord(signature, "protected")
                    || hasWord(signature, "package");
                members ~= HistoryMember(owner.name, name, code[i .. end + 1],
                    lineOf(code, i),
                    explicitHidden || (!explicitPublic && protection != "public"));
            }
            i = end;
            declFrom = end + 1;
        }
    }
    return members;
}

private void collectHistoryOwnerScans(string code, size_t from, size_t until,
                                      ref HistoryOwnerScan[] owners) {
    size_t declFrom = from;
    for (size_t i = from; i < until; ++i) {
        if (code[i] == ';') {
            declFrom = i + 1;
        } else if (code[i] == '{') {
            const end = matchingBrace(code, i);
            if (end >= code.length || end > until) return;
            const name = aggregateName(code[declFrom .. i]);
            if (name.length && declaresHistoryStackField(code, i, end)) {
                HistoryOwnerScan owner = HistoryOwnerScan(
                    name, i, end, lineOf(code, i));
                owner.members = parseHistoryMembers(code, owner);
                owners ~= owner;
            }
            collectHistoryOwnerScans(code, i + 1, end, owners);
            i = end;
            declFrom = end + 1;
        }
    }
}

private HistoryOwnerScan[] parseHistoryOwnerScans(string code) {
    HistoryOwnerScan[] owners;
    collectHistoryOwnerScans(code, 0, code.length, owners);
    owners.sort!((a, b) => a.name < b.name);
    return owners;
}

private bool assignmentAt(string code, size_t p) {
    while (p < code.length && (code[p] == ' ' || code[p] == '\t'
            || code[p] == '\n' || code[p] == '\r')) ++p;
    if (p + 1 < code.length && (code[p .. p + 2] == "++"
            || code[p .. p + 2] == "--")) return true;
    if (p < code.length && code[p] == '=')
        return p + 1 == code.length || code[p + 1] != '=';
    return p + 1 < code.length && code[p + 1] == '='
        && "+-~*/%&|^".canFind(code[p]);
}

private bool mutatesHistoryStack(string body) {
    foreach (field; ["undoStack", "redoStack"]) {
        for (size_t p = 0; p < body.length; ++p) {
            if (!wordAt(body, p, field)) continue;
            size_t q = p + field.length;
            while (true) {
                while (q < body.length && (body[q] == ' ' || body[q] == '\t'
                        || body[q] == '\n' || body[q] == '\r')) ++q;
                if (q < body.length && body[q] == '[') {
                    int depth;
                    do {
                        if (body[q] == '[') ++depth;
                        else if (body[q] == ']') --depth;
                        ++q;
                    } while (q < body.length && depth);
                } else if (q < body.length && body[q] == '.') {
                    ++q;
                    while (q < body.length && isIdentChar(body[q])) ++q;
                } else break;
            }
            if (assignmentAt(body, q)) return true;
            size_t before = p;
            while (before && (body[before - 1] == ' ' || body[before - 1] == '\t'))
                --before;
            if (before >= 2 && (body[before - 2 .. before] == "++"
                    || body[before - 2 .. before] == "--")) return true;
        }
    }
    return false;
}

private bool mentionsHistoryStackField(string body) {
    return hasWord(body, "undoStack") || hasWord(body, "redoStack");
}

private bool callsMember(string body, string name) {
    for (size_t p = 0; p < body.length; ++p) {
        if (!wordAt(body, p, name)) continue;
        size_t q = p + name.length;
        while (q < body.length && (body[q] == ' ' || body[q] == '\t'
                || body[q] == '\n' || body[q] == '\r')) ++q;
        if (q < body.length && body[q] == '(') return true;
        size_t before = p;
        while (before && (body[before - 1] == ' ' || body[before - 1] == '\t'
                || body[before - 1] == '\n' || body[before - 1] == '\r'))
            --before;
        if (before && body[before - 1] == '&') return true;
    }
    return false;
}

private bool hasHistoryIndirectEdge(string body, const(string)[] delegates) {
    if (hasWord(body, "mixin") || hasWord(body, "delegate")) return true;
    foreach (name; delegates) if (callsMember(body, name)) return true;
    return false;
}

private string historyLastIdentifier(string declaration) {
    size_t end = declaration.length;
    while (end && !isIdentChar(declaration[end - 1])) --end;
    size_t start = end;
    while (start && isIdentChar(declaration[start - 1])) --start;
    return declaration[start .. end];
}

private string[] historyDelegateFields(string code,
                                       ref HistoryOwnerScan owner) {
    string[] delegates;
    size_t i = owner.open + 1;
    size_t declFrom = i;
    while (i < owner.close) {
        if (code[i] == ';') {
            auto declaration = code[declFrom .. i];
            if (hasWord(declaration, "delegate")) {
                auto name = historyLastIdentifier(declaration);
                if (name.length) delegates ~= name;
            }
            declFrom = ++i;
        } else if (code[i] == '{') {
            const end = matchingBrace(code, i);
            if (end >= code.length) break;
            i = end + 1;
            declFrom = i;
        } else {
            ++i;
        }
    }
    return delegates;
}

private enum LedgerRow[] kHistoryOwners = [
    LedgerRow("CommandHistory", 1,
        "the live owner of the undo and redo stacks"),
    LedgerRow("PreparedHistoryImage", 1,
        "the detached owner whose fields are hidden by a private: section"),
];

private enum LedgerRow[] kReceiverDisposition = [
    LedgerRow("CommandHistory.beginPrepared", 1,
        "prepared protocol — opens the owner-held detached transaction"),
    LedgerRow("CommandHistory.blockBegin", 1,
        "EXCUSE: opens grouping state only; it neither names a stack nor reaches record"),
    LedgerRow("CommandHistory.blockEnd", 1,
        "command-block primitive — really reaches record for the collected children"),
    LedgerRow("CommandHistory.canRedo", 1,
        "EXCUSE: read-only availability query"),
    LedgerRow("CommandHistory.canUndo", 1,
        "EXCUSE: read-only availability query"),
    LedgerRow("CommandHistory.canUndoLifecycle", 1,
        "EXCUSE: read-only lifecycle-tail query"),
    LedgerRow("CommandHistory.canUndoModel", 1,
        "EXCUSE: read-only model-tail query"),
    LedgerRow("CommandHistory.canUndoUi", 1,
        "EXCUSE: read-only UI-tail query"),
    LedgerRow("CommandHistory.clear", 1,
        "EXCUSE: clears both timelines but cannot create a caller entry"),
    LedgerRow("CommandHistory.consolidate", 1,
        "gesture primitive — rewrites an already-open run tail"),
    LedgerRow("CommandHistory.discardPreparedToken", 1,
        "EXCUSE: discards a detached image without installing an entry"),
    LedgerRow("CommandHistory.discardValidatedPreparedToken", 1,
        "EXCUSE: discards a validated image without installing an entry"),
    LedgerRow("CommandHistory.fire", 1,
        "command primitive — its no-refire fallback applies and records"),
    LedgerRow("CommandHistory.installPreparedImage", 1,
        "raw prepared-image primitive — transfers a detached history image"),
    LedgerRow("CommandHistory.installPreparedToken", 1,
        "prepared protocol — installs the validated detached transaction"),
    LedgerRow("CommandHistory.invalidateRedo", 1,
        "EXCUSE: clears redo after an external mutation but creates no entry"),
    LedgerRow("CommandHistory.jumpTo", 1,
        "EXCUSE: navigates by undo/redo and creates no caller entry"),
    LedgerRow("CommandHistory.jumpToVisible", 1,
        "EXCUSE: visible-index wrapper over jumpTo"),
    LedgerRow("CommandHistory.prepareConsolidate", 1,
        "prepared protocol — rewrites an already-open detached run tail"),
    LedgerRow("CommandHistory.prepareCurrentImage", 1,
        "raw prepared-image primitive — exposes only an owner-built copy"),
    LedgerRow("CommandHistory.prepareInvalidateRedo", 1,
        "prepared protocol — clears redo in the detached transaction"),
    LedgerRow("CommandHistory.prepareLifecycle", 1,
        "prepared lifecycle primitive — appends to the detached transaction"),
    LedgerRow("CommandHistory.prepareLifecycleAppend", 1,
        "raw prepared-image primitive — appends a lifecycle entry to a copy"),
    LedgerRow("CommandHistory.prepareRecord", 1,
        "prepared command primitive — records into the detached transaction"),
    LedgerRow("CommandHistory.pushEntryForTest", 1,
        "test primitive — directly appends the supplied command"),
    LedgerRow("CommandHistory.record", 1,
        "command primitive — delegates transitively to private pushEntry"),
    LedgerRow("CommandHistory.recordCoalescing", 1,
        "command primitive — merges or reaches record"),
    LedgerRow("CommandHistory.recordInSession", 1,
        "gesture primitive — appends within an open run"),
    LedgerRow("CommandHistory.recordToolLifecycle", 1,
        "lifecycle primitive — appends through private pushEntry"),
    LedgerRow("CommandHistory.redo", 1,
        "EXCUSE: transfers an existing entry from redo to undo"),
    LedgerRow("CommandHistory.redoEntries", 1,
        "EXCUSE: read-only structured stack view"),
    LedgerRow("CommandHistory.redoEntriesVisible", 1,
        "EXCUSE: read-only surfaced stack view"),
    LedgerRow("CommandHistory.redoLabels", 1,
        "EXCUSE: read-only label projection"),
    LedgerRow("CommandHistory.refireBegin", 1,
        "refire primitive — a dangling live command really reaches record"),
    LedgerRow("CommandHistory.refireEnd", 1,
        "refire primitive — records the bracket's final live command"),
    LedgerRow("CommandHistory.replaceInSessionTail", 1,
        "gesture primitive — replaces or appends a re-grade entry"),
    LedgerRow("CommandHistory.replaceInSessionTailWith", 1,
        "gesture primitive — replaces a run tail with the supplied command"),
    LedgerRow("CommandHistory.toolLifecycleCount", 1,
        "EXCUSE: read-only lifecycle-entry count"),
    LedgerRow("CommandHistory.undo", 1,
        "EXCUSE: transfers an existing entry from undo to redo"),
    LedgerRow("CommandHistory.undoDepthCounts", 1,
        "EXCUSE: read-only class-count projection"),
    LedgerRow("CommandHistory.undoEntries", 1,
        "EXCUSE: read-only structured stack view"),
    LedgerRow("CommandHistory.undoEntriesVisible", 1,
        "EXCUSE: read-only surfaced stack view"),
    LedgerRow("CommandHistory.undoEntryCommandLine", 1,
        "EXCUSE: read-only command-line projection"),
    LedgerRow("CommandHistory.undoLabels", 1,
        "EXCUSE: read-only label projection"),
];

private bool auditedHistoryProtocolPeer(string owner, string name) {
    return owner == "CommandHistory" && name == "blockBegin";
}

private LedgerHit[] deriveHistoryReceiverHits(string code) {
    auto owners = parseHistoryOwnerScans(code);
    LedgerHit[] ownerHits;
    foreach (ref owner; owners)
        ownerHits ~= LedgerHit(owner.name, "source/command_history.d",
            owner.line, owner.name);
    auto ownerProblems = reconcile(kHistoryOwners, ownerHits);
    assert(ownerProblems.length == 0,
        "history receiver derivation: stack-owning aggregate set changed.\n"
        ~ ownerProblems);

    HistoryOwnerScan* commandHistory;
    foreach (ref owner; owners)
        if (owner.name == "CommandHistory") commandHistory = &owner;
    assert(commandHistory !is null,
        "history receiver derivation: CommandHistory owner was not parsed");

    // POPULATION FLOOR: all four checks run before any receiver/caller result
    // is reconciled. Keep them independent so each failure names the dead arm.
    assert(commandHistory.members.length >= 60, format(
        "CommandHistory writer derivation parsed only %d member(s)",
        commandHistory.members.length));
    string[] commandNames;
    foreach (ref m; commandHistory.members) commandNames ~= m.name;
    foreach (anchor; ["record", "undo", "redo", "fire", "prepareRecord"])
        assert(commandNames.canFind(anchor),
            "CommandHistory writer derivation lost anchor " ~ anchor);
    size_t hiddenCount;
    foreach (ref m; commandHistory.members) if (m.hidden) ++hiddenCount;
    assert(hiddenCount > 0,
        "CommandHistory writer derivation found no private member");
    size_t directMutators;
    foreach (ref m; commandHistory.members)
        if (mutatesHistoryStack(m.body)) ++directMutators;
    assert(directMutators > 0,
        "CommandHistory writer derivation found no direct stack mutator");

    LedgerHit[] proposals;
    foreach (ref owner; owners) {
        string[] names;
        foreach (ref m; owner.members) names ~= m.name;
        auto delegates = historyDelegateFields(code, owner);

        bool[string] reaches;
        foreach (ref m; owner.members)
            if (mentionsHistoryStackField(m.body)
                    || hasHistoryIndirectEdge(m.body, delegates))
                reaches[m.name] = true;
        bool changed = true;
        while (changed) {
            changed = false;
            foreach (ref m; owner.members) {
                if (m.name in reaches) continue;
                foreach (callee; names) if ((callee in reaches)
                        && callsMember(m.body, callee)) {
                    reaches[m.name] = true;
                    changed = true;
                    break;
                }
            }
        }
        foreach (ref m; owner.members)
            if (!m.hidden && ((m.name in reaches)
                    || auditedHistoryProtocolPeer(owner.name, m.name)))
                proposals ~= LedgerHit(owner.name ~ "." ~ m.name,
                    "source/command_history.d", m.line, m.name);
    }
    proposals.sort!((a, b) => a.key < b.key);
    return proposals;
}

private bool receiverTracksCallers(string name) {
    const key = "CommandHistory." ~ name;
    foreach (ref row; kReceiverDisposition)
        if (row.key == key) return !row.why.startsWith("EXCUSE:");
    const suffix = "|" ~ name;
    foreach (ref row; kResidue)
        if (row.key.length >= suffix.length
                && row.key[$ - suffix.length .. $] == suffix) return true;
    return false;
}

unittest {
    // Literal braces must be blanked before the same matcher used on the real
    // file. The unpaired `}` here used to end the class at the first method.
    enum braceProbe = `final class CommandHistory {
private:
    int[] undoStack, redoStack;
    void delegate() writer;
    void hiddenBySection() { undoStack = null; }
public:
    void first() { auto decoy = "}"; undoStack = null; }
    private void hiddenExplicit() { redoStack = null; }
    void second() { redoStack = null; }
    void viaDelegate() { writer(); }
private:
    public ref int explicitPublic() { return undoStack[0]; }
package:
    void hiddenByPackage() { redoStack = null; }
}`;
    auto probeOwners = parseHistoryOwnerScans(blankNonCode(braceProbe));
    assert(probeOwners.length == 1 && probeOwners[0].members.length == 7,
        format("history receiver scanner: literal brace or member parsing "
            ~ "desynchronised (owners=%d, members=%d)", probeOwners.length,
            probeOwners.length ? probeOwners[0].members.length : 0));
    string[] probePublic;
    foreach (ref m; probeOwners[0].members)
        if (!m.hidden) probePublic ~= m.name;
    probePublic.sort();
    assert(probePublic == ["explicitPublic", "first", "second", "viaDelegate"],
        "history receiver scanner: explicit and section protection disagreed");
    bool sawRefAccessor;
    foreach (ref m; probeOwners[0].members)
        if (m.name == "explicitPublic")
            sawRefAccessor = mentionsHistoryStackField(m.body);
    assert(sawRefAccessor,
        "history receiver scanner: a ref-returning stack accessor was missed");
    auto probeDelegates = historyDelegateFields(
        blankNonCode(braceProbe), probeOwners[0]);
    assert(probeDelegates == ["writer"],
        "history receiver scanner: delegate field discovery failed");
    assert(hasHistoryIndirectEdge("{ writer(); }", probeDelegates)
            && hasHistoryIndirectEdge("{ mixin(buildWriter()); }", null)
            && callsMember("{ auto writer = &pushEntry; }", "pushEntry")
            && mentionsHistoryStackField("{ undoStack.remove(0); }"),
        "history receiver scanner: an indirect/ref/UFCS mitigation arm is dead");

    immutable historyPath = buildPath(repoRoot, "source", "command_history.d");
    assert(exists(historyPath),
        "command-record class census: command_history.d is missing");
    auto receiverProposals = deriveHistoryReceiverHits(
        blankNonCode(readText(historyPath)));
    auto receiverProblems = reconcile(kReceiverDisposition, receiverProposals);
    assert(receiverProblems.length == 0,
        "command-record class census: a receiver proposal is unclassified.\n"
        ~ receiverProblems);

    string[] population;
    immutable sourceRoot = buildPath(repoRoot, "source");
    assert(exists(sourceRoot),
        "command-record class census: source population root is missing");
    foreach (e; dirEntries(sourceRoot, "*.d", SpanMode.depth))
        population ~= relativePath(e.name, repoRoot);
    population.sort();
    assert(population.length > 100,
        "command-record class census: source population is implausibly small: "
        ~ population.length.to!string);

    LedgerHit[] records;
    LedgerHit[] layerClass;
    LedgerHit[] layerDispatch;
    foreach (rel; population) {
        auto raw = readText(buildPath(repoRoot, rel));
        auto code = blankNonCode(raw);
        foreach (h; historySurface(code)) {
            if (!receiverTracksCallers(h.name)) continue;
            records ~= LedgerHit(h.symbol ~ "|" ~ h.name, rel, h.line,
                "history." ~ h.name ~ "(");
        }
        layerClass ~= symbolTokenHits(code, rel,
            "cast(LayerAdd)", "LayerAdd-class");
        if (raw.canFind(
                "executor.applyOrRefire(cmd, RecordMode.Record,\n"
              ~ "                \"command 'layer.add' did not apply\""))
            layerDispatch ~= symbolTokenHits(code, rel,
                "executor.applyOrRefire(cmd, RecordMode.Record",
                "LayerAdd-executor");
    }
    assert(records.length == 27,
        "command-record class census: expected twenty-seven allowlisted history "
        ~ "writer sites, found " ~ records.length.to!string);
    foreach (record; records)
        assert(record.key !=
               "wireMutationHandlers.setInjectLayerHandler|record",
            "command-record class census: LayerAdd gained a direct history "
            ~ "writer outside CommandExecutor at " ~ record.file ~ ":"
            ~ record.line.to!string);
    auto problems = reconcile(kResidue, records);
    assert(problems.length == 0,
        "command-record class census: an unclassified writer may be a second "
        ~ "generic command executor.\n" ~ problems);

    assert(layerClass.length == 1 &&
           layerClass[0].key ==
               "wireMutationHandlers.setInjectLayerHandler|LayerAdd-class",
        "command-record class census: expected exactly one cast(LayerAdd) "
        ~ "across source/, under wireMutationHandlers.setInjectLayerHandler; "
        ~ "found " ~ layerClass.length.to!string ~ " hit(s), first: "
        ~ (layerClass.length ? layerClass[0].key : "no hit"));
    assert(layerDispatch.length == 1 &&
           layerDispatch[0].key ==
               "wireMutationHandlers.setInjectLayerHandler|LayerAdd-executor",
        "LayerAdd must cross CommandExecutor exactly once: "
        ~ (layerDispatch.length ? layerDispatch[0].key : "no hit"));
}
