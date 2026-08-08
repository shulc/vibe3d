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
// Neither is caught by looking at part 3 alone, which is why both halves are
// asserted on the same read.
//
// The fixture also records, on purpose, a DRAG probe that could not answer
// grabbability (this tool free-moves on any viewport drag, so both
// hypotheses predict the same motion). No drag assertion is written here.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import core.thread: Thread;
import core.time  : msecs;

import fixture_helpers : requireProvenance;

void main() {}

immutable baseUrl = "http://localhost:8080";

// vibe3d-side gizmo part ids for the move bank. The fixture holds the
// REFERENCE measurement and cannot name these; the mapping to our surface
// belongs here.
enum int PART_CENTER = 3;                      // the centre handle
immutable int[] PART_ARMS   = [0, 1, 2];       // the three axis arms
immutable int[] PART_PLANES = [4, 5, 6];       // the three plane handles

JSONValue getJson(string path) { return parseJSON(cast(string) get(baseUrl ~ path)); }

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

    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);

    // ---- default: the component subject, centre handle ON -------------------
    {
        postOk("/api/select", `{"mode":"vertices","indices":[0,1]}`);
        assert(getJson("/api/selection")["selType"].str == "vertex",
               "component subject must be current");
        cmd("tool.set move on");
        auto vis = handleVisibility("component subject");
        assert(PART_CENTER in vis,
               "the centre handle must be a registered gizmo part in the component branch");
        assert(vis[PART_CENTER],
               format("component subject: the centre handle (part %d) must be VISIBLE — "
                      ~ "the reference default is on", PART_CENTER));
        assertAxisBanksIntact(vis, "component subject");
        cmd("tool.set move off");
    }

    // ---- the item subject: centre handle OFF --------------------------------
    {
        cmd("layer.select index:0 mode:set");
        assert(getJson("/api/selection")["selType"].str == "item",
               "item subject must be current");
        cmd("tool.set move on");

        auto st = getJson("/api/tool/state");
        assert("subject" in st && st["subject"].str == "item",
               "the tool must actually be on its item branch: " ~ st.toString);

        auto vis = handleVisibility("item subject");
        assert(PART_CENTER in vis,
               format("the centre handle (part %d) must still be a registered part in the "
                      ~ "item branch — it is turned off, not removed", PART_CENTER));
        assert(!vis[PART_CENTER],
               format("item subject: the centre handle (part %d) must be INVISIBLE. Reading "
                      ~ "visible=true here is the 'no subject gate' implementation — the "
                      ~ "reference's item-move configuration carries the flag off",
                      PART_CENTER));

        // The other half of the same read: turning the centre handle off must
        // not take the axis banks with it.
        assertAxisBanksIntact(vis, "item subject");

        cmd("tool.set move off");
    }
}
