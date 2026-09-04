// Task 1903 Stage O — THE SUITE-LANE WITNESS FOR THE HIDE-DERIVE PAIR.
//
// ===========================================================================
// WHAT THIS PINS, AND WHY IT HAD TO BE BUILT
// ===========================================================================
// `Command.apply`'s `beginHideDeriveBatch` / `endHideDeriveBatch` pair
// (source/command.d) exists because task 1330 measured a whole-mesh
// `refreshHiddenDerived` running once per APPENDED ELEMENT inside a bulk
// operation. Stage O set out to delete it, on the reading that every migrated
// family now opens a `MeshEditBatch` whose own `EditBatchFrame.deferSafe`
// covers the same case.
//
// MEASURED 2026-08-28, that reading is wrong, and this file is the number that
// says so. `mesh.paste` is an `Operator` that holds NO batch — it is a §6.6
// undo DECLINE, and a decline about the undo IMAGE says nothing about the
// BATCH — and its VERTEX-MODE arm (`Mesh.appendLooseVertices`) calls
// `addVertex` per pasted point, each ending in `commitChange(Points)`, which
// is a Geometry-class commit. So one paste of N loose points is N + 1
// unbatched Geometry commits on the document mesh, and without the pair each
// of them is a full O(V+E+F+C) derived-plane pass over a mesh that is growing
// while they run.
//
// ===========================================================================
// WHY THE VERTEX-MODE CLIP AND NOT THE OBVIOUS ONE
// ===========================================================================
// A clip WITH faces goes through `Mesh.appendGeometry`, which commits exactly
// TWICE however big the clip is. Measured on this build, same four-step
// gesture with `select.typeFrom polygon`: `hideDerivesDeferred` moves by 2 at
// 98 verts and by 2 at 386 verts — FLAT. A stand built on a polygon copy is
// blind to the entire effect and would go green with the pair deleted. The
// clip's mode is therefore the discriminating term of this rig, and the
// premise asserts it rather than trusting the gesture.
//
// ===========================================================================
// THE EXACT TERMS, AND WHY THEY ARE TERMS AND NOT THRESHOLDS
// ===========================================================================
// The two rounds paste 98 and 386 points. Each demands a delta of EXACTLY
// N + 1 — a number that differs between the rounds, so an implementation that
// ticked a constant, or ticked once per command, satisfies neither. Measured
// on this build: 99 / 99 / 1 and 387 / 387 / 1 for
// (hideDerivesDeferred, unbatchedGeometryCommits, deliveryCount).
//
// The `deliveryCount` half is its own statement: the pair opens a DELIVERY
// batch too, nested inside the one `Command.apply` already opened, and one
// command is one delivery whatever the operand — 387 commits, one delivery.
//
// MUTATION (measured 2026-08-28): drop `hideBatchMesh.beginHideDeriveBatch();`
// and its `scope(exit)` in `source/command.d` →
//   "the hide-derive pair deferred 0 derives across a 386-point vertex-mode
//    paste; the operand demands exactly 387"
// because with the pair gone nothing arms `g_hideDeriveDepth` and every one of
// those commits derives inline instead.
//
// WHAT THIS FILE DOES NOT SAY. Nothing here is about the HIDDEN regime.
// `beginHideDeriveBatch` arms deferral off `!anyHideBitSet()`, so with
// anything hidden the pair defers nothing and this counter reads 0 by
// construction — task 1333's known-open cost, which Stage O neither opened nor
// closed. Do not "fix" a red here by hiding a face.
//
// Runner: ./run_test.d test_hide_derive_deferral

import http_client : getJson, postRaw, testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl : get, post;
import std.json;
import std.format : format;
import std.conv   : to;
import std.array  : join;
import std.range  : iota;
import std.algorithm : map;
import core.thread : Thread;
import core.time   : dur;

void main() {}

alias baseUrl = testBaseUrl;

/// POST and require the app to answer ok. The transport is the shared
/// client (tests/http_client.d); only the assertion is local.
void postOk(string path, string body_) {
    auto resp = postRaw(path, body_);
    auto j = parseJSON(resp);
    assert("error" !in j
        && (("status" !in j) || j["status"].str == "ok"
                             || j["status"].str == "success"),
        path ~ " " ~ body_ ~ " failed: " ~ resp);
}


void settle(int ms = 150) { Thread.sleep(dur!"msecs"(ms)); }

long counter(JSONValue ch, string key) {
    assert(key in ch,
        "/api/changes does not carry `" ~ key ~ "` — the endpoint stopped "
      ~ "serialising the counter this file is about, so every delta below "
      ~ "would be read off a missing key");
    return ch[key].integer;
}

size_t vertCount() { return getJson("/api/model")["vertices"].array.length; }

// Build the stand and drive the four-step gesture, returning the deltas.
// `subdivides` sizes the operand; the two call sites use different values on
// purpose (see the header).
private struct Round { long deferred; long unbatched; long delivered; size_t n; }

private Round pasteRound(int subdivides, bool vertexMode) {
    postOk("/api/command", commandBody("scene.reset", `{"type":"cube"}`));
    settle();
    foreach (i; 0 .. subdivides) { postOk("/api/command", "mesh.subdivide"); settle(80); }

    const size_t n = vertCount();
    assert(n > 8,
        format("PREMISE: the stand has only %d verts after %d subdivides — "
             ~ "the operand must be big enough that N+1 cannot be confused "
             ~ "with a constant", n, subdivides));

    if (vertexMode) {
        postOk("/api/command", "select.typeFrom vertex");
        auto idx = iota(n).map!(i => i.to!string).join(",");
        postOk("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[` ~ idx ~ `]}`));
    } else {
        postOk("/api/command", "select.typeFrom polygon");
    }
    settle();
    postOk("/api/command", "mesh.copy");
    settle();

    auto before = getJson("/api/changes");
    postOk("/api/command", `{"id":"mesh.paste"}`);
    settle();
    auto after = getJson("/api/changes");

    // PREMISE: the paste actually landed. A refused paste ticks nothing and
    // would satisfy a `>= 0` for free; it cannot satisfy the exact terms
    // below, but it would fail them for the wrong reason, so say so here.
    const size_t n2 = vertCount();
    assert(n2 == 2 * n,
        format("PREMISE: the paste did not land — %d verts before, %d after, "
             ~ "expected %d. Nothing below is about the hide-derive pair if "
             ~ "the clipboard was empty or the command refused", n, n2, 2 * n));

    return Round(counter(after, "hideDerivesDeferred")
                     - counter(before, "hideDerivesDeferred"),
                 counter(after, "unbatchedGeometryCommits")
                     - counter(before, "unbatchedGeometryCommits"),
                 counter(after, "deliveryCount")
                     - counter(before, "deliveryCount"),
                 n);
}

unittest { // the vertex-mode arm: the pair's value TRACKS the operand
    Round[] rs;
    foreach (k; [2, 3]) rs ~= pasteRound(k, true);

    assert(rs[0].n != rs[1].n,
        format("PREMISE: both rounds pasted %d points — the two exact terms "
             ~ "would be the same number and a constant tick would satisfy "
             ~ "both", rs[0].n));

    foreach (r; rs) {
        // THE PREMISE THAT MAKES THE CLAIM MEAN SOMETHING: `mesh.paste` is
        // still batchless. If it ever gets a `MeshEditBatch`, its commits stop
        // reaching this arm and this cell has lost its subject — which is a
        // finding to act on (the pair may then be deletable), not a number to
        // relax.
        assert(r.unbatched == cast(long)r.n + 1,
            format("PREMISE: a %d-point vertex-mode paste made %d unbatched "
                 ~ "Geometry commits, expected exactly %d. `mesh.paste` is the "
                 ~ "last batchless Operator in the tree; if it acquired a "
                 ~ "MeshEditBatch this cell no longer measures the hide-derive "
                 ~ "pair at all — re-run task 1903 Stage O's measurement "
                 ~ "instead of editing this number", r.n, r.unbatched, r.n + 1));

        // THE CLAIM.
        assert(r.deferred == cast(long)r.n + 1,
            format("the hide-derive pair deferred %d derives across a "
                 ~ "%d-point vertex-mode paste; the operand demands exactly "
                 ~ "%d. A zero here means `Command.apply` no longer opens "
                 ~ "beginHideDeriveBatch/endHideDeriveBatch, so each of those "
                 ~ "%d commits ran a full whole-mesh refreshHiddenDerived "
                 ~ "inline — task 1330's root cause, re-opened",
                   r.deferred, r.n, r.n + 1, r.n + 1));

        // One command is ONE delivery, whatever the operand.
        assert(r.delivered == 1,
            format("a %d-point paste delivered %d times, expected exactly 1 — "
                 ~ "the delivery batch Command.apply opens (and the one the "
                 ~ "hide-derive pair nests inside it) is what makes a command "
                 ~ "one delivery", r.n, r.delivered));
    }
}

unittest { // the face-clip arm is FLAT — the control that names the blind rig
    // Not decoration. This is the stand Stage O would have built by default,
    // and it cannot see the effect: `appendGeometry` commits twice whatever
    // the clip holds. Recorded as an assertion so that a future reader who
    // reaches for "just paste something" is told why that is not enough.
    Round[] rs;
    foreach (k; [2, 3]) rs ~= pasteRound(k, false);

    assert(rs[0].n != rs[1].n, "PREMISE: the two face-clip rounds are the same size");
    foreach (r; rs)
        assert(r.deferred == 2 && r.unbatched == 2,
            format("a face-mode paste of a %d-vert clip deferred %d derives "
                 ~ "(%d unbatched commits), expected exactly 2 of each. This "
                 ~ "arm is supposed to be FLAT in the operand — if it now "
                 ~ "scales, `appendGeometry` grew a per-element commit and the "
                 ~ "vertex-mode cell above is no longer the only place the "
                 ~ "pair earns its keep", r.n, r.deferred, r.unbatched));
}
