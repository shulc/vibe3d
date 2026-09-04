// tests/test_bus_layer_scale_rebuild_rate.d — TASK 1932 stage 4.4, SUITE TIER:
// THE COST OF THE SLOT-CEILING CLIFF (closing task 1906 item 4's price half).
//
// `tests/unit/mesh_dirty_cliff_series_test.d` answers WHERE the cliff is,
// with no engine, no `BgGpu`, no primary-layer confound — that is the only
// tier where `epochFor` is read directly and a mutation to either of
// `mesh_dirty.d`'s two chained tables produces an unambiguous formula
// mismatch. This file answers a DIFFERENT question the unit tier cannot: what
// does a real document, driven through the real HTTP surface, actually PAY
// once the tables are healthy — one background GPU re-upload per layer added,
// not a rebuild storm.
//
// TWO CONFOUNDS, BOTH MEASURED AND BOTH NAMED BEFORE THIS STAND WAS WRITTEN
// (review round 1, O6a/O6b; round 2, R2-1's consequence 3):
//
//   (a) `layer.duplicate` MOVES THE PRIMARY. `commands/layer/commands.d`
//       clones the mesh, appends it to the document, then calls
//       `doc.setActive(addedIndex)` — the new layer becomes primary and the
//       PREVIOUS primary is demoted to background. A demoted layer's
//       `bgGpuByLayer` entry is fresh (`MeshDirtyKey.init`, `epoch =
//       ulong.max`, "never a real epoch" — `mesh_dirty.d`), so it re-uploads
//       UNCONDITIONALLY the next time it is drawn, independently of either
//       table. So "add a layer, measure the delta" is NEVER zero on a
//       healthy tree — the ceiling below is a small constant, not zero.
//   (b) THE STAND MUST RUN IN MODE B (birth + immediate publish), NOT MODE A
//       (births only), or arm (3) cannot redden from its own mutation.
//       `layer.duplicate`'s clone (`MeshSnapshot.capture(src).restore(...)`)
//       runs BEFORE the clone is appended to `doc.layers`, so
//       `g_isDocumentMesh` (`app.d`, `document.ownsMesh`) rejects the
//       `commitRestored` the clone step drives and the new layer's address
//       never reaches a watcher THERE. It reaches one through the
//       `/api/transform` edit this stand fires immediately after, while the
//       new layer is already primary (mode B's shape). Skip that edit and
//       the stand silently runs in mode A, where the cliff sits at
//       `B + D + 1` — and a `D`-only mutation would then need to lower `D`
//       past `B` before this stand's low-N run could see it at all.
//   (c) THE TOTAL COST OF BUILDING N BRAND-NEW LAYERS IS *NOT* THE NUMBER
//       THIS STAND MEASURES, and a first draft that measured it that way
//       failed on a HEALTHY tree (delta == kN, not <= 3) — caught before
//       this file was finished, not after. Each new layer's FIRST upload is
//       unavoidable and legitimately O(N); confusing that with the
//       EVICTION-DRIVEN re-upload of an ALREADY-SETTLED, UNCHANGED layer
//       hides the exact regression this arm exists to catch. So the stand
//       WARMS UP `kN - 1` layers first (their first-time uploads, not
//       asserted tightly) and settles them, THEN adds exactly ONE MORE
//       layer and reads the delta THAT publish alone produces. Below the
//       ceiling that marginal delta is O(1) (itself + the layer it
//       demotes); once the ceiling is crossed it is not, because the one
//       new publish evicts a slot and every layer NOT currently tracked —
//       which, past the cliff, is most of the document — reads `evicted_`
//       and mismatches on the next frame.
//
// WHY N IS A FIXED RIG CONSTANT, NOT DERIVED FROM `D` (review round 3, R3-1,
// blocking). An earlier draft sized N from `meshDirtySlotCeiling()` read over
// HTTP so the stand would "stay below the ceiling" — but the SAME mutation
// that lowers the ceiling (`D = 8`) also lowers the N the stand would then
// choose, so the arm-3 assert never crossed the ceiling and stayed green
// UNDER ITS OWN MUTATION. That is CLAUDE.md's Shape 8 ("the threshold is
// derived from the measurement it is meant to judge"). `kN` below is a
// literal, independent of `D`; the PREMISE clause `kN < meshDirtySlotCeiling`
// is what a `D`-lowering mutation reddens FIRST, by name, before arm (3) ever
// runs — and if the premise were a silent branch instead of an assert, the
// ceiling assert itself would redden instead (both paths are named in the
// premise's own message).
//
// `bgGpuUploads` IS KEYED ON `g_displayEpochs`, NOT `g_geomEpochs` — say so
// here too, not just in `mesh_dirty.d`'s own comment on the counter. The card
// that first asked for this rate named the GEOMETRY consumer (BVH rebuilds,
// snap grids); this stand measures the DISPLAY consumer instead, because it
// is the only one with a counter wired to `/api/changes` today. The two
// watchers share the same cliff (a birth's fail-safe `noteMeshChange(addr,
// uint.max)` passes every watcher's mask), so this stand answers "where is
// the cliff", not "what does the geometry consumer specifically pay" — that
// remains a named non-goal (a hover/snap sweep over background layers would
// need its own stand and its own card).
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.format  : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;


void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}
void resetApp() {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}
void settle() { Thread.sleep(400.msecs); }

long bgGpuUploads()      { return getJson("/api/changes")["bgGpuUploads"].integer; }
int  dirtySlotCeiling()  { return cast(int)getJson("/api/changes")["meshDirtySlotCeiling"].integer; }
int  birthSlotCeiling()  { return cast(int)getJson("/api/changes")["meshBirthSlotCeiling"].integer; }
long birthsRecorded()    { return getJson("/api/changes")["meshBirthsRecorded"].integer; }
long framesNow()         { return getJson("/api/frames/counts")["frames"].integer; }

/// One `layer.duplicate` (new layer becomes primary, previous primary is
/// demoted — confound (a) above) followed by ONE geometry edit on the new
/// primary (mode B's shape — confound (b) above). Alternates the translate
/// delta so the edit is never a no-op the compare-before-set guards elsewhere
/// in this codebase could drop.
void addLayerAndPublish(int i) {
    cmd("layer.duplicate");
    const double d = (i % 2 == 0) ? 0.01 : -0.01;
    postJson("/api/command", commandBody("mesh.transform", format(`{"kind":"translate","delta":[%f,0,0]}`, d)));
}

// ---------------------------------------------------------------------------
// N is a rig constant, not derived from D — see the header's R3-1 paragraph.
// 24 leaves comfortable room under the default ceiling (32) while still being
// well above the O(1) ceiling arm (3) asserts (3), so a stand that regressed
// to O(N) would fail LOUDLY rather than by one or two counts.
// ---------------------------------------------------------------------------
enum int kN = 24;

unittest {
    resetApp();

    // PREMISE (R3-1): this stand's arithmetic assumes kN sits BELOW the
    // watcher's ceiling. If a mutation lowers `meshDirtySlotCeiling()` to
    // something at or below kN, THIS premise is what reddens — named,
    // by design, rather than letting arm (3) fail confusingly (or, worse,
    // pass for the wrong reason the way a `D`-derived N would).
    const int D = dirtySlotCeiling();
    assert(kN < D, format(
        "PREMISE: this stand needs kN (%d) < meshDirtySlotCeiling() (%d). "
      ~ "kN is a FIXED rig constant and does NOT follow a lowered D — if D "
      ~ "dropped to or below kN, the watcher is now BELOW the stand's own "
      ~ "churn, arm (3)'s O(1) ceiling would be meaningless (every layer "
      ~ "past D re-uploads its neighbours), and that is exactly the "
      ~ "regression this premise exists to name before arm (3) can hide it",
        kN, D));

    // THE SECOND CEILING IS NOT THIS STAND'S BUSINESS, AND THAT IS MEASURED,
    // NOT ASSUMED. The cliff is a chain of two tables (§4.3): a birth takes a
    // free `MeshBirthTable` slot (B) and notifies nobody, while a birth past B
    // — and every `noteMeshChange` — inserts into each watcher (D). A draft of
    // this block asserted `kN < B` and `total births < B`, and the suite
    // reddened it at once: a suite process has already recorded **129** births
    // by the time this file runs (every earlier module's layers and resets),
    // i.e. it is permanently past B. Arm (3) is green there anyway, because
    // this stand runs in REGIME B — one publish per added layer — where the
    // watcher is fed by the publishes and the birth table's state does not
    // enter the arithmetic. So B is read only to be REPORTED beside the
    // numbers, and the birth counter is used for one thing: proving the
    // layers this stand drives actually reached the bus.
    const int  B            = birthSlotCeiling();
    const long birthsBefore = birthsRecorded();

    // ---- WARM-UP: kN-1 layers, mode B, NOT tightly asserted. ---------------
    // Each NEW background layer's FIRST upload is unavoidable — that cost is
    // legitimately O(N) and is not what this stand is measuring. What matters
    // is what happens to the layers ALREADY uploaded once warm-up settles:
    // under the default ceiling (kN-1 < D), none of their watcher slots is
    // evicted, so all kN-1 uploads below are "first time, legitimate" and the
    // marginal step after them pays only for ITSELF.
    foreach (i; 1 .. kN) addLayerAndPublish(i);
    settle();
    settle();
    const long uploadsAfterWarmup = bgGpuUploads();

    // ---- THE MARGINAL LAYER — arms (2) and (3) both read THIS delta. ------
    addLayerAndPublish(kN);
    settle();
    const long uploadsAfterMarginal = bgGpuUploads();

    // The births this stand actually caused, read from the same endpoint: the
    // arithmetic above is only about the watcher's ceiling while this stays
    // below B (asserted at the premise), and a silent saturation of the birth
    // counter would make that argument unfalsifiable.
    const long birthsHere = birthsRecorded() - birthsBefore;
    assert(birthsHere >= kN, format(
        "PREMISE: %d layer births were driven but the birth counter moved by "
      ~ "only %d (process total %d, birth ceiling %d) — either the counter "
      ~ "saturates (it must not; the unit cell in "
      ~ "tests/unit/mesh_dirty_cliff_series_test.d pins that) or the layers "
      ~ "never reached the bus, and every number below would be measuring "
      ~ "nothing", kN, birthsHere, birthsRecorded(), B));
    const long deltaMarginal = uploadsAfterMarginal - uploadsAfterWarmup;

    // ---- ARM (2) — WIRING: the counter is connected to something. ---------
    assert(deltaMarginal >= 1, format(
        "ARM (2) WIRING: one marginal layer.duplicate + edit, after a %d-layer "
      ~ "warm-up, moved bgGpuUploads by %d — the counter is not connected to "
      ~ "the background re-upload site at all", kN - 1, deltaMarginal));

    // ---- ARM (3) — LAW, the lower ceiling: O(1), not O(N). ----------------
    // 3 = the new layer's own first upload + the demoted previous primary's
    // first upload (confound (a)) + one slot of slack for scheduling/frame
    // timing. Below the ceiling, adding ONE layer to an ALREADY-SETTLED
    // document must not disturb the kN-1 layers that were already uploaded
    // and have not changed since — that disturbance (a slot eviction forcing
    // an unrelated, unchanged layer's cached key to miss) is the exact price
    // the card asked this arm to name.
    assert(deltaMarginal <= 3, format(
        "ARM (3) LAW — the lower ceiling: one marginal layer, after a "
      ~ "settled %d-layer document, moved bgGpuUploads by %d, expected <= 3 "
      ~ "(O(1): the new layer's own upload + the demoted previous primary's "
      ~ "+ one slot of slack). A delta near %d means every ALREADY-SETTLED "
      ~ "background layer is being re-uploaded again because its watcher "
      ~ "slot was evicted by this ONE new publish — the eviction cliff "
      ~ "(meshDirtySlotCeiling() = %d) has been crossed, exactly the "
      ~ "O(V+T)-per-churn regression `mesh_dirty.d`'s header describes",
        kN - 1, deltaMarginal, kN - 1, D));

    // ---- ARM (1) — QUIET WINDOW: a settled document re-uploads NOTHING. ---
    // Two clauses, and R2-3's second one is load-bearing on its own: a delta
    // of 0 is ALSO what "no frame ran at all" would produce, so "0 uploads"
    // alone cannot tell a live, correctly-keyed epoch apart from a renderer
    // that silently stopped drawing — `/api/frames/counts`'s own `frames`
    // must ALSO have advanced (same instrument `test_frame_counts.d:339`
    // already leans on for the identical reason).
    const long uploadsBeforeQuiet = bgGpuUploads();
    const long framesBeforeQuiet  = framesNow();
    settle();
    settle();   // two settle() windows: comfortably several frames, no gesture
    const long uploadsAfterQuiet = bgGpuUploads();
    const long framesAfterQuiet  = framesNow();

    assert(uploadsAfterQuiet == uploadsBeforeQuiet, format(
        "ARM (1) QUIET WINDOW: with %d layers built and NO gesture in "
      ~ "between, bgGpuUploads moved by %d over the quiet window — the "
      ~ "epoch key is not holding still, so every background layer is being "
      ~ "re-uploaded even though nothing changed",
        kN, uploadsAfterQuiet - uploadsBeforeQuiet));
    assert(framesAfterQuiet - framesBeforeQuiet >= 3, format(
        "ARM (1) QUIET WINDOW, second clause: the frame counter only "
      ~ "advanced by %d during the quiet window — without this, the 0-delta "
      ~ "assert above cannot tell a LIVE, correctly-keyed epoch apart from "
      ~ "a renderer that silently stopped drawing (R2-3)",
        framesAfterQuiet - framesBeforeQuiet));
}
