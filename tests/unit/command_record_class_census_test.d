// The command-record class census for task 4570. The module name
// `command_record_class_census_test` is project-owned: an exact `grep -rl -w`
// over the SDK tree returned zero files before this test was added.
//
// The receiver side is derived, not a spelling list: parse CommandHistory,
// find bodies that assign/compound-assign a stack (or one of its elements),
// then close transitively over direct calls to other members. The resulting
// public set must equal kExpectedStackWriters, so a new primitive names itself
// before anyone can classify its callers. The caller side remains the exact
// symbol|primitive ledger: every entry-producing call is owned by one symbol.
// Navigation/clear/discard methods mutate stacks but cannot add a caller's
// entry and are explicitly classified as such. prepareNextRun remains in the
// prepared caller ledger because it evolves transaction metadata, although it
// does not itself mutate either stack. In particular, the LayerAdd built by
// `/api/test/layer` must cross CommandExecutor instead of becoming a second
// apply+record implementation beside it.
module tests.unit.command_record_class_census_test;

import std.algorithm : canFind, sort;
import std.array : join;
import std.conv : to;
import std.file : dirEntries, exists, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import std.string : indexOf, strip;

import tests.unit.census_symbols : LedgerHit, LedgerRow, blankNonCode,
    declaratorName, historySurface, isIdentChar, reconcile, symbolTokenHits;

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
    LedgerRow("wireHistoryProviders.setBlockHandler|blockEnd", 1,
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
        "transform gesture edit — the in-session writer at "
      ~ "source/tools/transform/transform.d:854"),
    LedgerRow("XfrmTransformTool.recordPipeRefire|replaceInSessionTail", 1,
        "transform re-grade — the task-1905 run-tail replacement at "
      ~ "source/tools/transform/xfrm_transform.d:7207"),
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
// HistoryMember, wordAt, hasWord, matchingBrace, parseHistoryMembers,
// assignmentAt, mutatesHistoryStack, callsMember, derivePublicStackWriters,
// kExpectedStackWriters, kNonEntryStackMutators, renderSetDiff and
// tracksCallerPrimitive. The words describe local syntax, not an external API
// classification.
private struct HistoryMember {
    string name;
    string body;
    bool hidden;
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

private HistoryMember[] parseHistoryMembers(string code) {
    HistoryMember[] members;
    auto headRel = code.indexOf("final class CommandHistory");
    if (headRel < 0) return members;
    const head = cast(size_t)headRel;
    auto openRel = code[head .. $].indexOf("{");
    if (openRel < 0) return members;
    const open = head + cast(size_t)openRel;
    const close = matchingBrace(code, open);
    if (close >= code.length) return members;
    string protection = "public";
    size_t declFrom = open + 1;
    for (size_t i = declFrom; i < close; ++i) {
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
                members ~= HistoryMember(name, code[i .. end + 1],
                    explicitHidden || (!explicitPublic && protection != "public"));
            }
            i = end;
            declFrom = end + 1;
        }
    }
    return members;
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

private bool callsMember(string body, string name) {
    for (size_t p = 0; p < body.length; ++p) {
        if (!wordAt(body, p, name)) continue;
        size_t q = p + name.length;
        while (q < body.length && (body[q] == ' ' || body[q] == '\t'
                || body[q] == '\n' || body[q] == '\r')) ++q;
        if (q < body.length && body[q] == '(') return true;
    }
    return false;
}

private string[] derivePublicStackWriters(string code) {
    auto members = parseHistoryMembers(code);
    assert(members.length >= 60, format(
        "CommandHistory writer derivation parsed only %d member(s)", members.length));
    string[] names;
    foreach (ref m; members) names ~= m.name;
    foreach (anchor; ["record", "undo", "redo", "fire", "prepareRecord"])
        assert(names.canFind(anchor),
            "CommandHistory writer derivation lost anchor " ~ anchor);

    bool[string] reaches;
    size_t direct;
    foreach (ref m; members) if (mutatesHistoryStack(m.body)) {
        reaches[m.name] = true;
        ++direct;
    }
    assert(direct > 0, "CommandHistory writer derivation found no stack mutation");
    bool changed = true;
    while (changed) {
        changed = false;
        foreach (ref m; members) {
            if (m.name in reaches) continue;
            foreach (callee; names) if ((callee in reaches)
                    && callsMember(m.body, callee)) {
                reaches[m.name] = true;
                changed = true;
                break;
            }
        }
    }

    string[] publicWriters, hiddenWriters;
    foreach (ref m; members) if (m.name in reaches)
        (m.hidden ? hiddenWriters : publicWriters) ~= m.name;
    publicWriters.sort();
    hiddenWriters.sort();
    assert(hiddenWriters.canFind("pushEntry"),
        "CommandHistory writer derivation failed to keep private pushEntry hidden");
    return publicWriters;
}

private immutable string[] kExpectedStackWriters = [
    "beginPrepared", "blockEnd", "clear", "consolidate",
    "discardPreparedToken", "discardValidatedPreparedToken", "fire",
    "installPreparedImage", "installPreparedToken", "invalidateRedo",
    "jumpTo", "jumpToVisible", "prepareConsolidate", "prepareCurrentImage",
    "prepareInvalidateRedo", "prepareLifecycle", "prepareLifecycleAppend",
    "prepareRecord", "pushEntryForTest", "record", "recordCoalescing",
    "recordInSession", "recordToolLifecycle", "redo", "refireBegin",
    "refireEnd", "replaceInSessionTail", "replaceInSessionTailWith", "undo",
];

private immutable string[] kNonEntryStackMutators = [
    "clear", "discardPreparedToken", "discardValidatedPreparedToken",
    "invalidateRedo", "jumpTo", "jumpToVisible", "redo", "undo",
];

private string renderSetDiff(const(string)[] expected, const(string)[] actual) {
    string[] unexpected, missing;
    foreach (name; actual) if (!expected.canFind(name)) unexpected ~= name;
    foreach (name; expected) if (!actual.canFind(name)) missing ~= name;
    return "unexpected public stack writer(s): [" ~ unexpected.join(", ")
        ~ "]; missing expected writer(s): [" ~ missing.join(", ") ~ "]";
}

private bool tracksCallerPrimitive(string name, const(string)[] stackWriters) {
    if (stackWriters.canFind(name) && !kNonEntryStackMutators.canFind(name))
        return true;
    const suffix = "|" ~ name;
    foreach (ref row; kResidue)
        if (row.key.length >= suffix.length
                && row.key[$ - suffix.length .. $] == suffix) return true;
    return false;
}

unittest {
    immutable historyPath = buildPath(repoRoot, "source", "command_history.d");
    assert(exists(historyPath),
        "command-record class census: command_history.d is missing");
    auto stackWriters = derivePublicStackWriters(blankNonCode(readText(historyPath)));
    assert(stackWriters == kExpectedStackWriters,
        "command-record class census: derived CommandHistory writer set changed; "
        ~ renderSetDiff(kExpectedStackWriters, stackWriters));

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
            if (!tracksCallerPrimitive(h.name, stackWriters)) continue;
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
    assert(records.length == 25,
        "command-record class census: expected twenty-five allowlisted history "
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
