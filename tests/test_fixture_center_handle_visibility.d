// Frozen reference behaviour — the transform gizmo's CENTRE HANDLE defaults
// on, the item-move configuration turns it off, and its state leaves the axis
// banks alone.
// Fixture: tests/fixtures/center_handle_visibility.json.
//
// MECHANISM DIFFERS, OBSERVABLE MATCHES. The reference carries a per-
// configuration boolean; vibe3d has no such flag and no item-specific
// transform configuration at all — one tool branches on whether the subject
// is items or mesh components, and registers the centre handle in both
// branches while reporting it invisible in the item one. So the two frozen
// observables ARE testable here; see the fixture's `not_tested_and_why` for
// the two clauses that are not.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
//   * "no subject gate on the centre handle" — registers it the same way in
//     both branches. That implementation reads visible = TRUE for part 3 in
//     the item branch, where the correct one reads false.
//   * "hide the whole gizmo in the item branch" — a lazier way to make the
//     centre handle disappear. That implementation reads visible = false for
//     the axis ARM parts 0/1/2 and the plane parts 4/5/6 as well, where the
//     correct one keeps all six visible.
//   * "a sticky setter" — one that hides the handle on entering the item
//     branch and never restores it on the way back. Visiting each subject
//     ONCE, in one order, cannot see this: the readings are 1 then 0, which
//     is what both the correct and the sticky implementation produce. This
//     is why the subjects are visited in an ALTERNATING sequence below,
//     crossing the boundary in BOTH directions twice.
// None is caught by looking at part 3 in one branch, which is why all three
// halves — the centre handle, the axis banks, and the round trip — are
// asserted on the same sequence of reads.
//
// The fixture declares the reference's own order-independence protocol
// (`attribute.order_independent`, evidence "1, 0, 1" and "0, 1, 0"): a
// configuration RESETS attributes it does not itself list, so the item-move
// configuration's 0 is a real override and not a leftover. vibe3d's analogue
// of that protocol is that the observable must be a function of the CURRENT
// subject alone and not of the order in which subjects were visited — which
// is exactly what the alternating sequence tests. A driver that ran one
// direction only would leave the fixture declaring a protocol nothing
// enforced.
//
// The fixture also records, on purpose, a DRAG probe that could not answer
// grabbability (this tool free-moves on any viewport drag, so both
// hypotheses predict the same motion). No drag assertion is written here.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import core.thread: Thread;
import core.time  : msecs;

import fixture_helpers : requireProvenance;

void main() {}

alias baseUrl = testBaseUrl;

// vibe3d-side gizmo part ids for the move bank. The fixture holds the
// REFERENCE measurement and cannot name these; the mapping to our surface
// belongs here.
enum int PART_CENTER = 3;                      // the centre handle
immutable int[] PART_ARMS   = [0, 1, 2];       // the three axis arms
immutable int[] PART_PLANES = [4, 5, 6];       // the three plane handles


JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void postOk(string path, string body_) {
    auto j = parseJSON(cast(string) post(baseUrl ~ path, body_));
    assert(j["status"].str == "ok", path ~ " failed: " ~ j.toString);
}

/// part id -> visible, for the live tool. The gizmo is posed on a frame, so
/// give the app a couple of frames to publish a non-empty part list before
/// concluding anything about visibility.
bool[int] handleVisibility(string ctx) {
    foreach (attempt; 0 .. 40) {
        auto h = getJson("/api/tool/handles");
        if ("handles" in h && h["handles"].type == JSONType.object
            && "parts" in h["handles"] && h["handles"]["parts"].array.length) {
            bool[int] vis;
            foreach (p; h["handles"]["parts"].array)
                vis[cast(int) p["part"].integer] = p["visible"].type == JSONType.true_;
            return vis;
        }
        Thread.sleep(50.msecs);
    }
    assert(false, ctx ~ ": /api/tool/handles never published a part list");
}

void assertAxisBanksIntact(bool[int] vis, string ctx) {
    foreach (p; PART_ARMS)
        assert(p in vis && vis[p],
               format("%s: axis arm part %d must stay present and visible — if it is not, "
                      ~ "the centre handle's state is disturbing the axis banks (or the "
                      ~ "whole gizmo was hidden instead of just the centre handle)", ctx, p));
    foreach (p; PART_PLANES)
        assert(p in vis && vis[p],
               format("%s: plane part %d must stay present and visible", ctx, p));
}

/// Put the app on `subject` ("component" or "item"), arm the move tool, read
/// the gizmo part list, drop the tool again. Returns the visibility map.
bool[int] readOnSubject(string subject, string ctx) {
    if (subject == "component") {
        postOk("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1]}`));
        assert(getJson("/api/selection")["selType"].str == "vertex",
               ctx ~ ": component subject must be current");
    } else {
        cmd("layer.select index:0 mode:set");
        assert(getJson("/api/selection")["selType"].str == "item",
               ctx ~ ": item subject must be current");
    }

    cmd("tool.set move on");

    auto st = getJson("/api/tool/state");
    assert("subject" in st && st["subject"].str == subject,
           format("%s: the tool must actually be on its %s branch: %s",
                  ctx, subject, st.toString));

    auto vis = handleVisibility(ctx);
    cmd("tool.set move off");
    return vis;
}

unittest {
    enum string fixtureJson = import("fixtures/center_handle_visibility.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "center_handle_visibility");

    immutable bool refDefaultOn  = fx["attribute"]["default"].integer == 1;
    immutable bool refItemMoveOn = fx["attribute"]["item_move_configuration"].integer == 1;
    assert(refDefaultOn && !refItemMoveOn,
           "fixture premise: the reference default is ON and the item-move "
           ~ "configuration turns it OFF — the whole test is that pair");
    assert(fx["does_not_disturb"]["axis_frame_identical"].type == JSONType.true_,
           "fixture premise: the reference measured the axis banks undisturbed");
    assert(fx["attribute"]["order_independent"].type == JSONType.true_,
           "fixture premise: the reference measured this ORDER-INDEPENDENT — the "
           ~ "alternating sequence below is what carries that claim over here; if the "
           ~ "fixture ever stops declaring it, drop the sequence rather than leaving a "
           ~ "protocol nothing enforces");

    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);

    // Both directions, twice each. `component` must read the handle VISIBLE
    // every time it comes round and `item` INVISIBLE every time — a value that
    // latched on the first crossing would be caught on the third read.
    static struct Visit { string subject; bool centerVisible; }
    immutable Visit[] sequence = [
        Visit("component", true),
        Visit("item",      false),
        Visit("component", true),   // <- the return leg: a sticky hide dies here
        Visit("item",      false),
        Visit("component", true),
    ];

    foreach (i, v; sequence) {
        immutable string ctx = format("visit %d (%s subject)", i + 1, v.subject);
        auto vis = readOnSubject(v.subject, ctx);

        assert(PART_CENTER in vis,
               format("%s: the centre handle (part %d) must be a registered gizmo part in "
                      ~ "BOTH branches — in the item branch it is turned off, not removed",
                      ctx, PART_CENTER));

        if (v.centerVisible)
            assert(vis[PART_CENTER],
                   format("%s: the centre handle (part %d) must be VISIBLE — the reference "
                          ~ "default is on. Reading false on a RETURN to this subject is a "
                          ~ "setter that hid the handle and never restored it; reading "
                          ~ "false on the first visit is a wrong default",
                          ctx, PART_CENTER));
        else
            assert(!vis[PART_CENTER],
                   format("%s: the centre handle (part %d) must be INVISIBLE. Reading "
                          ~ "visible=true here is the 'no subject gate' implementation — "
                          ~ "the reference's item-move configuration carries the flag off",
                          ctx, PART_CENTER));

        // The other half of the same read: turning the centre handle off must
        // not take the axis banks with it, in either branch.
        assertAxisBanksIntact(vis, ctx);
    }
}
