module ui.availability;

// ---------------------------------------------------------------------------
// TASK 0669 — why a button is unavailable, and the record of what was drawn.
//
// 0654 made the refusal correct and left it INVISIBLE. Arming a tool or firing
// a mesh command with an empty item selection declines with a named reason —
// but the button looked exactly like a working one, so the only way to learn
// about the refusal was to press. The owner reported it as "Box and Sphere do
// not work".
//
// This module holds the two halves of the fix that are not drawing:
//
//   1. `actionRefusal` — resolve a `buttonset.Action` (of any kind) to the
//      one-clause reason pressing it would refuse right now, or "". It is a
//      thin fan-out over `Registry.actionRefusal`, which reads the fact the
//      COMMAND ITSELF declared (`Command.needsEditTarget`). No list of names
//      exists at any level of this chain, so a button cannot disagree with the
//      behaviour and a newly registered command needs no edit here.
//
//   2. the draw-time RECORD — what the frame actually drew, per button, with
//      the disabled flag and reason it drew it WITH. Recorded from inside the
//      render (`--test` only) and published whole, exactly like
//      `property_panel.toolPropsIdsJson`.
//
// Why the record exists rather than a test that re-asks `actionRefusal`: a
// test that calls the resolver proves the resolver, not the button. Reading
// back what the draw put on screen is what makes "the grey row and the refusal
// agree" an assertion about the UI instead of about a function the UI is free
// to stop calling.
// ---------------------------------------------------------------------------

import buttonset : Action, ActionKind;
import registry  : Registry;

// ---------------------------------------------------------------------------
// Resolving an Action
// ---------------------------------------------------------------------------

/// The command id a `kind: script` line dispatches — its leading whitespace-
/// delimited token, which is exactly what `argstring.parseArgstring` puts in
/// `commandId`. Sliced, not parsed: this runs for every script button of every
/// frame, and the full parse allocates a `JSONValue` bag the answer does not
/// need. Returns "" for a blank line (the dispatch skips those too).
string scriptLineCommandId(string line) {
    size_t b = 0;
    while (b < line.length && (line[b] == ' ' || line[b] == '\t')) ++b;
    size_t e = b;
    while (e < line.length && line[e] != ' ' && line[e] != '\t') ++e;
    return line[b .. e];
}

/// The one-clause reason pressing `a` would refuse right now, or "" when it
/// would run.
///
///   * `tool`    — asks the registry, passing `activeToolId` so the armed
///                 tool's own button (which DROPS it) stays live.
///   * `command` — asks the registry.
///   * `script`  — refuses if ANY of its lines would. A script is dispatched
///                 line by line with no rollback, so a run that would stop
///                 partway is not "mostly available"; the first refusing line
///                 names the reason.
///   * `popup`   — never. Opening a menu is always allowed; the ITEMS inside
///                 it gate themselves through this same function (that is
///                 where Import/Export already greys itself for a missing
///                 decoder), and a popup whose rows are all unavailable still
///                 has to open so the user can read why.
string actionRefusal(ref Registry reg, ref const Action a,
                     bool hasEditTarget, string activeToolId) {
    final switch (a.kind) {
        case ActionKind.tool:
            return reg.actionRefusal("tool", a.id, hasEditTarget, activeToolId);
        case ActionKind.command:
            return reg.actionRefusal("command", a.id, hasEditTarget, activeToolId);
        case ActionKind.script:
            foreach (line; a.scriptLines) {
                auto id = scriptLineCommandId(line);
                if (id.length == 0) continue;
                auto why = reg.actionRefusal("command", id, hasEditTarget, activeToolId);
                if (why.length > 0) return why;
            }
            return "";
        case ActionKind.popup:
            return "";
    }
}

// ---------------------------------------------------------------------------
// The draw-time record — `GET /api/buttons/availability`
// ---------------------------------------------------------------------------

/// One button as the frame drew it.
struct DrawnButton {
    string source;    // "side" | "status" | "popup" — which bar drew it
    string label;     // the visible text, after variant / dynamic-label swaps
    string kind;      // the resolved action kind ("tool" / "command" / …)
    string id;        // action id ("" for script / popup)
    bool   disabled;  // what the render was actually handed
    string reason;    // the availability reason, "" when it is not why
}

private __gshared DrawnButton[] g_scratch;        // main thread only
private __gshared bool          g_scratchTarget;  // main thread only
private __gshared string        g_scratchTool;    // main thread only
private __gshared uint          g_scratchMods;    // main thread only
private __gshared DrawnButton[] g_published;      // guarded by g_mx
private __gshared bool          g_publishedTarget;// guarded by g_mx
private __gshared string        g_publishedTool;  // guarded by g_mx
private __gshared uint          g_publishedMods;  // guarded by g_mx
private __gshared Object        g_mx;

shared static this() { g_mx = new Object(); }

/// Start a fresh recording for one frame's button bars. Called once per frame
/// before the side panel draws; without it successive frames pile up.
///
/// `hasEditTarget` is recorded WITH the frame rather than read by the endpoint
/// later: the reader is the HTTP thread, and the document state it would sample
/// there belongs to whatever frame happens to be in flight. Taken here it is by
/// construction the state the buttons below were drawn against, so a reader
/// comparing the two is comparing one frame with itself.
/// `activeToolId` is recorded for the same reason and used for the same
/// judgement: whether a greyed tool button is CORRECTLY greyed depends on
/// whether that tool is the armed one (pressing the armed tool's button drops
/// it, which needs no target). A reader without it cannot tell a correct grey
/// from a user stranded inside a tool.
///
/// `mods` is the THIRD input to what got drawn, and it is recorded for a reason
/// that cost a CI lane a day. A side-panel row whose YAML declares a `ctrl:` /
/// `alt:` / `shift:` variant draws the VARIANT while that modifier is held —
/// a different label, a different action, the same row. So a reader that finds
/// no button called "Box" is looking at one of two completely different facts:
/// the row is gone, or the row is currently called "Unit Box". Without the
/// modifiers in the record those are indistinguishable, and the reader is told
/// only the number of rows — which is the SAME either way, because nothing was
/// lost.
///
/// Taken here, once, rather than per button: it is then by construction the
/// state the whole frame's labels were chosen against, and a reader comparing
/// the two is comparing one frame with itself.
void beginButtonAvailabilityFrame(bool hasEditTarget, string activeToolId,
                                  uint mods = 0) {
    import command : g_testMode;
    if (!g_testMode) return;
    g_scratch.length = 0;
    g_scratch.assumeSafeAppend();
    g_scratchTarget = hasEditTarget;
    g_scratchTool   = activeToolId;
    g_scratchMods   = mods;
}

/// Record one drawn button. No-op outside `--test`, so a normal run pays a
/// single predictable branch per button and allocates nothing.
void recordDrawnButton(string source, string label, ActionKind kind, string id,
                       bool disabled, string reason) {
    import command : g_testMode;
    if (!g_testMode) return;
    import std.conv : to;
    g_scratch ~= DrawnButton(source, label, kind.to!string, id, disabled, reason);
}

/// Publish the frame just drawn. One assignment under the lock: a reader gets
/// a whole frame or the previous whole frame, never a prefix.
void endButtonAvailabilityFrame() {
    import command : g_testMode;
    if (!g_testMode) return;
    synchronized (g_mx) {
        g_published       = g_scratch.dup;
        g_publishedTarget = g_scratchTarget;
        g_publishedTool   = g_scratchTool;
        g_publishedMods   = g_scratchMods;
    }
}

/// `GET /api/buttons/availability` payload — every button of the last complete
/// frame, with the disabled flag and reason it was drawn with.
string buttonAvailabilityJson() {
    import std.json : JSONValue;
    DrawnButton[] snap;
    bool   hasEditTarget;
    string activeToolId;
    uint   mods;
    synchronized (g_mx) {
        snap          = g_published.dup;
        hasEditTarget = g_publishedTarget;
        activeToolId  = g_publishedTool;
        mods          = g_publishedMods;
    }
    JSONValue[] items;
    foreach (ref b; snap) {
        JSONValue j;
        j["source"]   = JSONValue(b.source);
        j["label"]    = JSONValue(b.label);
        j["kind"]     = JSONValue(b.kind);
        j["id"]       = JSONValue(b.id);
        j["disabled"] = JSONValue(b.disabled);
        j["reason"]   = JSONValue(b.reason);
        items ~= j;
    }
    JSONValue root;
    root["hasEditTarget"] = JSONValue(hasEditTarget);
    root["activeToolId"]  = JSONValue(activeToolId);
    root["mods"]          = JSONValue(mods);
    root["buttons"]       = JSONValue(items);
    return root.toString();
}

// ---------------------------------------------------------------------------
// Unit tests — the Action fan-out. (The button/behaviour CORRESPONDENCE is
// asserted over the live app in tests/test_command_availability.d; these pin
// the parts that are pure data.)
// ---------------------------------------------------------------------------

unittest {
    // The script-line id is the leading token, with no parse and no
    // allocation-visible difference from what the dispatcher resolves.
    assert(scriptLineCommandId("prim.cube cenX:0 sizeX:1") == "prim.cube");
    assert(scriptLineCommandId("   prim.sphere method:globe") == "prim.sphere");
    assert(scriptLineCommandId("select.typeFrom vertex") == "select.typeFrom");
    assert(scriptLineCommandId("history.undo") == "history.undo");
    assert(scriptLineCommandId("") == "");
    assert(scriptLineCommandId("   ") == "");
}

unittest {
    import command  : Command, kNoEditTargetReason;
    import tool     : Tool;
    import mesh     : Mesh;
    import view     : View;
    import editmode : EditMode;

    static final class NeedsCmd : Command {
        private Mesh  _m;
        private View  _v = new View(0, 0, 1, 1);
        this() { super(&_m, _v, EditMode.Vertices); }
        override string name() const { return "test.needs"; }
        override bool needsEditTarget() const { return true; }
    }
    static final class FreeCmd : Command {
        private Mesh  _m;
        private View  _v = new View(0, 0, 1, 1);
        this() { super(&_m, _v, EditMode.Vertices); }
        override string name() const { return "test.free"; }
        override bool needsEditTarget() const { return false; }
    }
    static final class NeedsTool : Tool {
        override bool needsEditTarget() const { return true; }
    }

    Registry reg;
    reg.commandNeedsTarget["test.needs"] = true;
    reg.commandNeedsTarget["test.free"]  = false;
    reg.toolNeedsTarget["test.tool"]     = true;

    // WITH a target nothing is refused — the both-sides half. An
    // implementation that greys everything always fails right here.
    {
        auto a = Action(ActionKind.command, "test.needs");
        assert(actionRefusal(reg, a, true, "") == "");
        auto t = Action(ActionKind.tool, "test.tool");
        assert(actionRefusal(reg, t, true, "") == "");
    }
    // WITHOUT one, only what declared the requirement is refused.
    {
        auto need = Action(ActionKind.command, "test.needs");
        assert(actionRefusal(reg, need, false, "") == kNoEditTargetReason);
        auto free = Action(ActionKind.command, "test.free");
        assert(actionRefusal(reg, free, false, "") == "");
        auto unknown = Action(ActionKind.command, "test.never.registered");
        assert(actionRefusal(reg, unknown, false, "") == "");
    }
    // The armed tool's own button stays live: pressing it DROPS the tool, and
    // dropping never needed a target.
    {
        auto t = Action(ActionKind.tool, "test.tool");
        assert(actionRefusal(reg, t, false, "")          == kNoEditTargetReason);
        assert(actionRefusal(reg, t, false, "test.tool") == "");
        assert(actionRefusal(reg, t, false, "other")     == kNoEditTargetReason);
    }
    // A script is refused by any one of its lines. This is the ctrl-variant
    // path ("Unit Box" et al. in config/buttons.yaml) — a `kind: script`
    // button whose one line dispatches a command id — and it has no HTTP
    // counterpart, because the frame record only carries the variant the
    // unmodified button shows.
    {
        Action s;
        s.kind = ActionKind.script;
        s.scriptLines = ["test.free a:1", "test.needs b:2"];
        assert(actionRefusal(reg, s, false, "") == kNoEditTargetReason,
            "a script whose SECOND line would refuse was reported available. "
            ~ "A script is dispatched line by line with no rollback, so a run "
            ~ "that stops partway is not 'mostly available'. Got: '"
            ~ actionRefusal(reg, s, false, "") ~ "'");
        s.scriptLines = ["test.free a:1"];
        assert(actionRefusal(reg, s, false, "") == "",
            "a script none of whose lines needs a target was refused");
    }
    // A popup always opens.
    {
        Action p;
        p.kind = ActionKind.popup;
        assert(actionRefusal(reg, p, false, "") == "");
    }
    // The defaults the two base classes declare, off real instances: a
    // non-Operator command needs nothing, every tool needs a target.
    assert(!(new FreeCmd()).needsEditTarget());
    assert((new NeedsCmd()).needsEditTarget());
    assert((new NeedsTool()).needsEditTarget());
    assert((new class Tool {}).needsEditTarget(),
        "Tool.needsEditTarget() must default to true — a tool binds Mesh* when "
        ~ "it arms");
}
