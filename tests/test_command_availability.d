// Task 0669 — a button that would REFUSE if pressed looks unavailable BEFORE
// the press.
//
// ---------------------------------------------------------------------------
// The two assertions that would be worth nothing here
// ---------------------------------------------------------------------------
// 1. "the Box button is drawn grey when no item is selected" tests APPEARANCE,
//    not CORRESPONDENCE. An implementation carrying a hardcoded list of
//    command names — `["prim.cube", "prim.sphere", ...]` — passes it on the day
//    it is written and diverges from behaviour on the very next command
//    registered. Nothing below names a command it expects to be grey; the
//    expectation is COMPUTED from what the commands themselves declared
//    (`/api/registry`'s `commandsNeedingTarget` / `toolsNeedingTarget`, which
//    is `Command.needsEditTarget()` snapshotted per id).
//
// 2. "grey when nothing is selected" alone passes for an implementation that
//    greys EVERY button ALWAYS — the most obviously wrong one available. So
//    every row below is asserted in BOTH states, and W1 exists solely to fail
//    that implementation.
//
// ---------------------------------------------------------------------------
// The chain, and what each link is worth
// ---------------------------------------------------------------------------
//   N1  declaration ⟷ behaviour, TOTAL over every registered command that
//       declares it needs a target: fire it with no item selected and it must
//       refuse, naming the reason. This is the link a hardcoded list cannot
//       fake, because the list being checked is the app's own and the check is
//       "does pressing it actually do what you claimed".
//   N2  declaration ⟷ what was DRAWN, over every command/tool button of the
//       real frame (`/api/buttons/availability` reads back the disabled flag
//       and reason the render was handed). This is the link that fails if the
//       draw stops consulting the resolver.
//   W1  with a target, NOTHING is greyed for this reason — the other side.
//   B1  the owner's two buttons, by name, in both states, with the press
//       agreeing each time. Concrete enough to read as a bug report.
//   R1  a greyed row SAYS why (the tooltip's string is the one the dispatch
//       funnel would have thrown).
//
// N1 ∘ N2 is grey ⟺ refuses, over the whole button bar.
//
// ---------------------------------------------------------------------------
// The wrong implementations each row catches (observed reds in the task log)
// ---------------------------------------------------------------------------
//   * a mesh-writing command that overrides apply() and so never reaches the
//     no-edit-target refusal (ToolHeadlessCommand — `prim.cube` reported
//     `{"status":"ok"}` and built a cube into the read-only stand-in)
//       -> N1, B1
//   * the draw stops consulting availability (the pre-0669 state: the refusal
//     is correct and the button looks identical to a working one)
//       -> N2, B1
//   * the resolver greys every button always
//       -> W1
//   * the armed tool's own button greys, stranding the user in a tool they
//     cannot press their way out of
//       -> D1
//   * grey, but silent about why
//       -> R1

import std.net.curl;
import std.json;
import std.conv      : to;
import std.format    : format;
import std.algorithm : canFind, filter, map;
import std.array     : array;

void main() {}

enum string BASE = "http://localhost:8080";

/// The one sentence a refusal for want of an edit target reads. Duplicated
/// from `command.kNoEditTargetReason` on purpose — a test that imported the
/// constant would keep passing if the app changed the words to something
/// meaningless, and the words are half the point of task 0669.
///
/// TASK 0668 REWORDED IT: "no MESH item is selected". The old wording denied
/// that anything was selected, which since 0668 can be said while a reference
/// plane is selected and visibly highlighted — an absent edit target no longer
/// implies an empty selection. Being a deliberate duplicate, this literal does
/// not follow the app on its own; it is updated BY HAND when the app's wording
/// changes, and the N1 block below is written so the failure tells you that is
/// what happened.
enum string kReason = "no mesh item is selected: there is no mesh edit target";

private JSONValue getJson(string p) { return parseJSON(cast(string) get(BASE ~ p)); }

private JSONValue post_(string argstring) {
    return parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
}

/// Fire a command that must SUCCEED.
private void cmdOk(string argstring) {
    auto j = post_(argstring);
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

/// The button record of the last complete frame, keyed by (kind, id) for the
/// rows that have an id and by label for the rest.
private struct Bar {
    JSONValue[] rows;
    bool   hasEditTarget;
    string activeToolId;

    JSONValue byLabel(string label) {
        foreach (r; rows) if (r["label"].str == label) return r;
        assert(false, "no button labelled '" ~ label ~ "' was drawn — the record "
               ~ "has " ~ rows.length.to!string ~ " rows");
    }
}

private Bar readBar() {
    // The record is published once per frame; give the app a frame to draw
    // after a state change before reading it back.
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(250.msecs);
    auto j = getJson("/api/buttons/availability");
    Bar b;
    b.rows = j["buttons"].array;
    b.hasEditTarget = j["hasEditTarget"].boolean;
    b.activeToolId  = j["activeToolId"].str;
    assert(b.rows.length > 0,
        "the button-availability record is EMPTY. Nothing recorded means the "
        ~ "draw is not reporting what it drew, and every correspondence row "
        ~ "below would pass vacuously.");
    return b;
}

// ---------------------------------------------------------------------------

unittest {
    post(BASE ~ "/api/reset", "");

    // ---- the declaration, straight from the registry ----------------------
    auto reg = getJson("/api/registry");
    auto allCmds   = reg["commands"].array.map!(v => v.str).array;
    auto needCmds  = reg["commandsNeedingTarget"].array.map!(v => v.str).array;
    auto needTools = reg["toolsNeedingTarget"].array.map!(v => v.str).array;

    assert(needCmds.length > 0,
        "no registered command declares it needs an edit target. Either the "
        ~ "declaration is not reaching the wire or every command claims it can "
        ~ "run with nothing selected — both make N1/N2 below vacuous.");
    assert(needTools.length > 0, "no registered tool declares it needs a target");
    // The declaration is a PROPER subset: a build in which everything needs a
    // target would pass a grey-everything implementation.
    assert(needCmds.length < allCmds.length,
        format("every one of the %d registered commands claims to need an edit "
               ~ "target; that cannot be right and would make W1 vacuous",
               allCmds.length));

    // =======================================================================
    // W1 — WITH an edit target, nothing is unavailable for this reason.
    //
    // The row that fails an implementation which greys every button always.
    // =======================================================================
    {
        auto bar = readBar();
        assert(bar.hasEditTarget,
            "a freshly reset document has one selected layer; the record says "
            ~ "otherwise, so nothing below is testing what it claims to");
        auto greyed = bar.rows.filter!(r => r["reason"].str.length > 0).array;
        assert(greyed.length == 0,
            format("with a layer selected, %d button(s) were still drawn "
                   ~ "unavailable for want of an edit target: %s. There IS one.",
                   greyed.length,
                   greyed.map!(r => r["label"].str).array.to!string));

        // …and the two the owner named are live and press through.
        foreach (label; ["Box", "Sphere"]) {
            auto b = bar.byLabel(label);
            assert(!b["disabled"].boolean,
                format("'%s' was drawn unavailable WITH a layer selected", label));
        }
        cmdOk("tool.set prim.cube");
        cmdOk("tool.set prim.cube off");
    }

    // =======================================================================
    // Clear the item selection — the state the owner was in.
    // =======================================================================
    // TASK 0671 — `layer.select mode:clear` no longer reaches this state, and
    // that is the point of the task: deselecting moves a mesh into its kind's
    // recently-deselected cache and the edit target is the head of a walk over
    // [current ++ that cache], so an empty item selection keeps its target
    // (frozen: tests/fixtures/edit_target_legality.json, cell
    // `target_set_nothing_selected`). Reaching "no edit target" now means
    // taking the target AWAY: duplicate the layer — the duplicate's exclusive
    // select flushes the mesh bucket, so the original loses its state — then
    // delete the duplicate, which removes the only item that had one.
    cmdOk("layer.duplicate");
    cmdOk("layer.delete index:1");
    {
        auto layers = getJson("/api/layers");
        assert(layers["active"].integer == -1,
            "the document did not actually lose its edit target; every row "
            ~ "below would be asserting the WITH-target state a second time");
        assert(layers["layers"].array.length == 1,
            "…and it is a one-layer document again, so the rows below see the "
            ~ "same shape they did with a target");
    }

    // =======================================================================
    // N1 — declaration ⟷ behaviour, over EVERY command that declared the need.
    //
    // Each of these refuses at the first line of its apply(), before it can
    // touch anything, so firing all of them is inert. A command that declared
    // the need and does NOT enforce it is the ToolHeadlessCommand defect:
    // `prim.cube` answered `{"status":"ok"}` and built a cube into the
    // read-only stand-in mesh that nothing draws.
    // =======================================================================
    {
        string[] liars;
        string[] anonymous;
        string[] misworded;
        string   sampleMsg;
        foreach (id; needCmds) {
            auto j = post_(id);
            if (j["status"].str != "error") { liars ~= id; continue; }
            immutable msg = j["message"].str;
            if (msg.canFind(kReason)) continue;
            // TASK 0668 — these are TWO different defects and the difference is
            // the whole instruction. `app.d`'s dispatch funnel (`failMsg`)
            // appends `": " ~ refusalReason()` only when there IS one, so a
            // refusal that carries no reason reads exactly the bare boilerplate
            // and nothing else. Anything longer HAS a reason; it is simply not
            // the one this file froze.
            //
            // Lumping them together cost real time once: this block reported
            // "refused ANONYMOUSLY (no reason in the message)" for 98 commands
            // that were in fact refusing correctly and naming the reason —
            // 0668 had reworded the sentence and this file's deliberate
            // duplicate still held the old words. The message sent the reader
            // hunting for a lost reason that was never lost.
            if (msg == "command '" ~ id ~ "' did not apply") anonymous ~= id;
            else { misworded ~= id; if (sampleMsg.length == 0) sampleMsg = msg; }
        }
        assert(liars.length == 0,
            format("%d command(s) DECLARE they need an edit target and then "
                   ~ "report success without one: %s. The button for each is "
                   ~ "drawn grey, so the grey is a lie in the other direction.",
                   liars.length, liars.to!string));
        assert(anonymous.length == 0,
            format("%d command(s) refused ANONYMOUSLY — the message is the bare "
                   ~ "boilerplate with no reason appended at all, which is the "
                   ~ "defect this task exists to remove: %s",
                   anonymous.length, anonymous.to!string));
        assert(misworded.length == 0,
            format("%d command(s) refused WITH a reason, but not the one this "
                   ~ "file froze. Read:\n  %s\nExpected to contain:\n  %s\n"
                   ~ "Nothing is anonymous — this is a WORDING drift. If the "
                   ~ "app's wording changed on purpose, update `kReason` at the "
                   ~ "top of this file (it is a deliberate duplicate of "
                   ~ "`command.kNoEditTargetReason` and does not follow it "
                   ~ "automatically). Commands: %s",
                   misworded.length, sampleMsg, kReason, misworded.to!string));
    }

    // =======================================================================
    // N2 — declaration ⟷ what the frame DREW, over every id-bearing button.
    //
    // The expectation is computed from the declaration lists above; no command
    // name appears in this block. An implementation with a hardcoded list of
    // names diverges here the moment its list and the declaration differ, and
    // a draw that stopped calling the resolver fails every row at once.
    // =======================================================================
    {
        auto bar = readBar();
        assert(!bar.hasEditTarget);
        string[] wrong;
        int checked = 0;
        foreach (r; bar.rows) {
            const kind = r["kind"].str;
            const id   = r["id"].str;
            if (id.length == 0) continue;             // script / popup rows
            bool expect;
            if      (kind == "tool")    expect = needTools.canFind(id);
            else if (kind == "command") expect = needCmds.canFind(id);
            else continue;
            ++checked;
            // `disabled` may ALSO be true for reasons this task does not own
            // (an unsupported edit mode, a build gate) — those carry no
            // reason string, so the availability verdict is `reason`, and the
            // enabled direction is asserted through it.
            bool got = r["reason"].str.length > 0;
            if (got != expect)
                wrong ~= format("%s '%s' (%s): drawn %s, declaration says %s",
                                kind, id, r["label"].str,
                                got ? "unavailable" : "available",
                                expect ? "it needs a target" : "it does not");
            if (expect && !r["disabled"].boolean)
                wrong ~= format("%s '%s' carries a reason but was NOT drawn "
                                ~ "disabled", kind, id);
        }
        assert(checked >= 10,
            format("only %d id-bearing buttons were checked — too few for this "
                   ~ "row to mean anything", checked));
        assert(wrong.length == 0,
            format("%d button(s) disagree with what their action declared:\n  %s",
                   wrong.length, wrong.to!string));
    }

    // =======================================================================
    // B1 — the owner's report, by name, with the press agreeing.
    // =======================================================================
    {
        auto bar = readBar();
        foreach (label; ["Box", "Sphere"]) {
            auto b = bar.byLabel(label);
            assert(b["disabled"].boolean,
                format("'%s' was drawn as a working button with no item "
                       ~ "selected — which is the whole report: pressing it is "
                       ~ "the only way to find out it will not work", label));
        }
        // …and pressing really does refuse, both as an arm and as the
        // headless command the button's ctrl-variant script fires.
        foreach (line; ["tool.set prim.cube", "prim.cube", "prim.sphere"]) {
            auto j = post_(line);
            assert(j["status"].str == "error" && j["message"].str.canFind(kReason),
                format("`%s` did not refuse with no edit target: %s",
                       line, j.toString));
        }
    }

    // =======================================================================
    // R1 — a greyed row says WHY, in the same words the dispatch funnel uses.
    // =======================================================================
    {
        auto bar = readBar();
        auto greyed = bar.rows.filter!(r => r["reason"].str.length > 0).array;
        assert(greyed.length > 0, "nothing was greyed, so R1 is vacuous");
        foreach (r; greyed)
            assert(r["reason"].str == kReason,
                format("'%s' is unavailable but its reason reads '%s' — the "
                       ~ "user is told the button is dead and not why",
                       r["label"].str, r["reason"].str));
    }

    // =======================================================================
    // D1 — nobody is stranded inside a tool they cannot press their way out of.
    //
    // Pressing the ARMED tool's button DROPS the tool, and dropping never
    // needed an edit target (`activateToolById` takes its same-id branch before
    // the refusal), so greying that one button would be a trap. Arming a
    // DIFFERENT tool still needs a target and stays grey.
    //
    // MEASURED, not assumed: emptying the item selection under an armed tool
    // DROPS it today (the primary-change hook), so the state this row guards
    // against is not currently reachable — `activeToolId` comes back "" and
    // 'Box' is correctly grey. Both outcomes are correct and the assertion
    // covers both; what is NOT correct is the pair "still armed AND greyed",
    // which is the only combination this rejects. Written as a disjunction so
    // it keeps its meaning if the drop is ever removed, rather than freezing
    // today's incidental branch.
    // =======================================================================
    {
        cmdOk("layer.select index:0 mode:set");
        // TASK 0671 — the tool has to be armed on a layer that is then TAKEN
        // AWAY, because `layer.select mode:clear` (what this row used to use)
        // leaves the target latched. Duplicate, arm on the clone, delete the
        // clone: the document ends with one layer and no edit target, under an
        // armed tool — the exact state this row guards.
        cmdOk("layer.duplicate");
        cmdOk("tool.set prim.cube");
        cmdOk("layer.delete index:1");
        {
            auto ls = getJson("/api/layers");
            assert(ls["active"].integer == -1,
                "precondition: the arming layer is gone and no target replaced it");
        }
        auto bar = readBar();
        auto box = bar.byLabel("Box");
        if (bar.activeToolId == "prim.cube")
            assert(!box["disabled"].boolean,
                "'prim.cube' is still ARMED with no edit target, and its own "
                ~ "button — the one that DROPS it — was drawn unavailable. That "
                ~ "strands the user inside a tool with no way to press out.");
        else
            assert(box["disabled"].boolean,
                format("the tool was dropped when the edit target went away "
                       ~ "(activeToolId '%s'), so arming 'Box' again needs a "
                       ~ "target and it must be unavailable", bar.activeToolId));
        // A DIFFERENT tool needs a target either way.
        assert(bar.byLabel("Sphere")["disabled"].boolean,
            "arming a tool that is not the armed one always needs a target");
    }

    // Leave the app the way it was found.
    cmdOk("layer.select index:0 mode:set");
    post(BASE ~ "/api/reset", "");
}
