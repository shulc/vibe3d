// The per-frame draw path must not allocate in proportion to the MESH.
//
// Task 0585. `Mesh.selectedVertices / selectedEdges / selectedFaces` are
// materialized read views: each call does `new bool[](marks.length)`. They were
// read from the draw path, every frame, once per viewport cell. Measured on the
// perf harness's default grid (n=316: V=100489, E=200344, F=99856), reading
// `lastScene.allocBytes` from /api/frames/counts:
//
//     Vertices                  108 720 B/frame   ->  6 320
//     Edges                     207 024           ->  6 320
//     Polygons, no selection    211 120           ->  6 320
//     Polygons, 3 faces         313 520           ->  6 320
//
// Every one of those figures is `k * Q(S) + 6320`, where S is the element count
// of the mode's domain, Q(S) is the GC BLOCK size of `bool[S]`, and k is the
// number of accessor calls per frame counted off the source. The 6320 residual
// is FLAT: identical to the byte across V = 289 .. 100489, and identical again
// in the four RED readings this test produced against an unfixed binary --
// there is no per-allocation component hiding in it.
//
// Q IS A MEASURED SIZE CLASS AND IT IS NOT A POWER OF TWO. That is the one
// thing to get right before re-deriving any number here, and getting it wrong
// invents a residual that does not exist. On this host's druntime
// (`new bool[N]`, delta of `GC.allocatedInCurrentThread`):
//
//     Q(256) = 368     Q(544)   =    816     Q(16641) = 20480
//     Q(289) = 368     Q(16384) =  20480     Q(33024) = 36864
//
// so the four deltas this test has to see, at n = 16 -> 128, are exactly
//
//     vertices           1 * (Q(16641) - Q(289)) = 20 112     measured 20 112
//     edges              1 * (Q(33024) - Q(544)) = 36 048     measured 36 048
//     polygons, empty    2 * (Q(16384) - Q(256)) = 40 224     measured 40 224
//     polygons, selected 3 * (Q(16384) - Q(256)) = 60 336     measured 60 336
//
// Zero deviation on all four. Assume the next power of two instead (512, 1024)
// and the predictions come out 19 968 / 35 840 / 39 936 / 59 904, which reads
// as "about +144 per allocation, +208 in the edge domain" -- an artefact of
// the wrong Q, not a property of the frame.
//
// WHAT THIS TEST ASSERTS, AND WHAT IT DELIBERATELY DOES NOT. It asserts only a
// SLOPE: that growing the mesh does not grow the frame's allocation. It never
// asserts an absolute floor. `allocBytes` is a delta instrument with a nonzero
// ImGui floor that has nothing to do with this task, and a threshold on the
// absolute number would be a number nobody can defend six months from now.
//
// THE THRESHOLD IS 4096 AND MUST NOT BE RELAXED. That is one GC page. The
// signal it has to separate from is 20 112 B at the smallest (Vertices) and
// 60 336 B at the largest -- 4.9x to 14.7x the threshold. A failure here is
// therefore a real regression, never instrument noise, and moving the number
// up to make a red run green would convert this file into decoration.
//
// WHY BOTH A DIFFERENTIAL *AND* A POSITIVE CONTROL. A delta of zero is what
// this test wants to see -- and it is also what it would see if nothing was
// drawn at all, if both legs measured the same mesh, or if the selection mode
// never actually took effect. So every reading also carries:
//   * `pass.faces.verts`, asserted equal to 6*F(n) (grid faces are quads, so
//     (4-2)*3 = 6 fan-triangulated vertices each) and asserted to GROW between
//     the legs -- that is the proof two different meshes were measured;
//   * the frame ordinal, asserted to advance -- proof the app kept rendering;
//   * a CONSUMER-LIVENESS counter chosen per mode (see `checkLive`) -- proof
//     the mask consumer for THAT mode ran. `drawFaces` submits in EVERY mode,
//     so `pass.faces` alone cannot tell "no allocation" from "the mode was
//     never set"; the per-mode counter can.
//   * `/api/selection`'s own report of the selection type, asserted to be the
//     one that was asked for.
import std.net.curl;
import std.json;
import std.exception : enforce;
import std.format : format;
import std.conv : to;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue gj(string p) { return parseJSON(cast(string)get(baseUrl ~ p)); }

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

JSONValue counts() { return gj("/api/frames/counts"); }

/// One settled frame's reading.
struct Reading {
    long alloc;         /// lastScene.allocBytes
    long seq;           /// lastScene.seq  (frame ordinal)
    long frames;        /// total committed frames
    long faceVerts;     /// pass.faces.verts   -- the "something was drawn" term
    long vertCalls;     /// pass.verts.calls
    long edgeCalls;     /// pass.edges.calls
    long overlayCalls;  /// pass.faceOverlay.calls
    string selType;     /// what the app says the selection type is
}

Reading readNow() {
    auto c = counts();
    auto s = c["lastScene"];
    Reading r;
    r.alloc        = s["allocBytes"].integer;
    r.seq          = s["seq"].integer;
    r.frames       = c["frames"].integer;
    r.faceVerts    = s["pass"]["faces"]["verts"].integer;
    r.vertCalls    = s["pass"]["verts"]["calls"].integer;
    r.edgeCalls    = s["pass"]["edges"]["calls"].integer;
    r.overlayCalls = s["pass"]["faceOverlay"]["calls"].integer;
    r.selType      = gj("/api/selection")["selType"].str;
    return r;
}

/// The next reading taken from a frame STRICTLY LATER than `afterSeq`.
///
/// This is what makes the window below a window over five FRAMES rather than
/// five reads of whatever `lastScene` happens to hold. Reading the same frame
/// five times produces five trivially identical numbers, which is exactly the
/// "settled" signature — the stale-frame failure this instrument exists to
/// catch, relocated one level up. On exhaustion this asserts: a reading that
/// cannot be refreshed is an instrument failure, never a number to report.
Reading readNext(long afterSeq, string what) {
    Reading r;
    foreach (i; 0 .. 100) {                       // bounded: ~6 s at 60 ms
        Thread.sleep(60.msecs);
        r = readNow();
        if (r.seq > afterSeq) return r;
    }
    assert(false, format("%s: the scene frame ordinal has not moved past %d in "
                         ~ "~6 s (still %d). Nothing is being rendered, so every "
                         ~ "further reading would be one frozen frame reported "
                         ~ "five times as a settled value.",
                         what, afterSeq, r.seq));
}

/// The settled floor for the current state.
///
/// NOT a plain min-of-N over a fixed window, and that is a MEASURED
/// requirement, not caution. For a short window after a mode switch,
/// `lastScene` can still be the PREVIOUS state's frame: driving
/// edges -> polygons on a grid read 207 024 once (the edges value) and 211 120
/// four times, and a min picked the stale 207 024 because it is the SMALLER of
/// the two -- silently attributing one mode's cost to another. So: gate on the
/// frame ORDINAL advancing well past the state change, then demand N
/// CONSECUTIVE IDENTICAL readings FROM N DISTINCT FRAMES. A window that still
/// disagrees with itself fails loudly instead of being averaged into a
/// plausible number.
///
/// BOTH GATES ASSERT ON EXHAUSTION, and that is the whole point of them. An
/// earlier form of this function `break`-ed out of the seq gate only on
/// success and simply carried on when the loop ran out — so a frozen app
/// reached the window, the window read one frame five times, found five
/// identical numbers and returned that stale reading AS IF settled. The
/// existing `faceVerts == gridFaceVerts(n)` check in `leg` does not cover it:
/// `faceVerts` is mode-INDEPENDENT, so a reading held over from the previous
/// mode at the same n passes it, and `selType` comes from a live
/// `/api/selection` read that reports the new type no matter which frame
/// `lastScene` is holding.
Reading settled(string what) {
    immutable long seq0 = readNow().seq;
    bool advanced = false;
    foreach (i; 0 .. 200) {                       // bounded: ~10 s at 50 ms
        if (readNow().seq >= seq0 + 60) { advanced = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(advanced,
           format("%s: the scene frame ordinal did not reach %d within ~10 s "
                  ~ "(started at %d, now %d). The app is not rendering, so "
                  ~ "there is no settled state to measure — this is an "
                  ~ "instrument failure, not a slow machine.",
                  what, seq0 + 60, seq0, readNow().seq));
    Thread.sleep(400.msecs);

    Reading[5] w;
    foreach (attempt; 0 .. 6) {
        long after = readNow().seq;
        foreach (k; 0 .. 5) {
            w[k] = readNext(after, what);
            after = w[k].seq;
        }
        // Stated explicitly rather than left implicit in `readNext`: the
        // window's claim is "five DIFFERENT frames agreed", and the only thing
        // that distinguishes that from "one frame read five times" is the
        // ordinal. `.alloc` alone cannot tell them apart.
        foreach (k; 1 .. 5)
            assert(w[k].seq > w[k - 1].seq,
                   format("%s: window frame ordinals are not strictly "
                          ~ "increasing (%d %d %d %d %d) — the same frame was "
                          ~ "read more than once and its agreement with itself "
                          ~ "means nothing",
                          what, w[0].seq, w[1].seq, w[2].seq, w[3].seq, w[4].seq));
        bool same = true;
        foreach (k; 1 .. 5) if (w[k].alloc != w[0].alloc) { same = false; break; }
        if (same) return w[4];
        Thread.sleep(300.msecs);
    }
    assert(false, format("%s: allocBytes never settled — five consecutive "
                         ~ "readings still disagree (%d %d %d %d %d). This is "
                         ~ "an instrument failure, not a threshold question.",
                         what, w[0].alloc, w[1].alloc, w[2].alloc, w[3].alloc,
                         w[4].alloc));
}

void resetGrid(int n) {
    httpPost("/api/reset?type=grid&n=" ~ n.to!string, "");
    Thread.sleep(600.msecs);
}

void selectAs(string mode, string indices) {
    auto r = parseJSON(httpPost("/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ indices ~ `}`));
    enforce("status" in r && r["status"].str == "ok",
            "/api/select " ~ mode ~ " failed: " ~ r.toString);
}

long gridFaces(int n)    { return cast(long)n * n; }
long gridFaceVerts(int n){ return 6 * gridFaces(n); }   // quads: (4-2)*3

/// The counter that proves the MASK CONSUMER for this mode ran this frame.
/// Chosen per mode because the obvious candidate does not work: `drawFaces`
/// submits `DrawPass.faces` in EVERY mode, so `pass.faces` grows with n and the
/// frame ordinal advances even when `selectMode` silently failed and the mask
/// consumer never executed.
void checkLive(string mode, string indices, Reading r, string what) {
    switch (mode) {
        case "vertices":
            // drawVertices submits one batch for the whole cloud and one MORE
            // per selected vertex. The bare floor is EXACTLY 1, so only a
            // strict `> 1` on a non-empty selection proves the mask was read.
            assert(r.vertCalls > 1,
                   format("%s: pass.verts.calls == %d. The bare vertex cloud is "
                          ~ "exactly one submission and happens whatever the "
                          ~ "mask says — the selection mask consumer did not run",
                          what, r.vertCalls));
            break;
        case "edges":
            assert(r.edgeCalls >= 1,
                   format("%s: pass.edges.calls == 0 — the edge pass did not run",
                          what));
            break;
        case "polygons":
            assert(r.edgeCalls >= 1,
                   format("%s: pass.edges.calls == 0 — the face->edge highlight "
                          ~ "cache's consumer did not run", what));
            if (indices != "[]")
                assert(r.overlayCalls >= 1,
                       format("%s: pass.faceOverlay.calls == 0 with faces "
                              ~ "selected — the checker overlay's mask consumer "
                              ~ "did not run", what));
            break;
        default: assert(false, "unknown mode " ~ mode);
    }
}

/// Bring the app to `mode`/`indices` on a grid of `n`, settle, and check every
/// non-vacuity term before handing the reading back.
Reading leg(int n, string mode, string indices, string what) {
    resetGrid(n);
    selectAs(mode, indices);
    auto r = settled(what);

    immutable string wantType = mode == "vertices" ? "vertex"
                              : mode == "edges"    ? "edge" : "polygon";
    assert(r.selType == wantType,
           format("%s: asked for %s, the app reports selType=%s — every number "
                  ~ "in this leg belongs to a different mode's draw path",
                  what, mode, r.selType));
    assert(r.faceVerts == gridFaceVerts(n),
           format("%s: face pass submitted %d verts, a grid n=%d implies %d "
                  ~ "(6 per quad) — this leg did not draw the mesh it says it did",
                  what, r.faceVerts, n, gridFaceVerts(n)));
    checkLive(mode, indices, r, what);
    return r;
}

// A = 16  -> V=289,   E=544,   F=256
// B = 128 -> V=16641, E=33024, F=16384
enum int kSmall = 16;
enum int kLarge = 128;

/// One GC page. See the header: NEVER raise this to make a run green.
enum long kMaxDelta = 4096;

void checkMode(string mode, string indices, string what) {
    auto a = leg(kSmall, mode, indices, what ~ " @n=" ~ kSmall.to!string);
    auto b = leg(kLarge, mode, indices, what ~ " @n=" ~ kLarge.to!string);

    // Positive controls, from the same two readings the delta comes from.
    assert(b.faceVerts > a.faceVerts,
           format("%s: both legs submitted %d face verts — the same mesh was "
                  ~ "measured twice and the delta below means nothing",
                  what, a.faceVerts));
    assert(b.frames > a.frames,
           format("%s: the frame counter did not advance between the legs "
                  ~ "(%d -> %d) — the app stopped rendering",
                  what, a.frames, b.frames));

    immutable long delta = b.alloc - a.alloc;
    assert(delta <= kMaxDelta,
           format("%s: per-frame GC allocation grew by %d B when the mesh went "
                  ~ "from n=%d to n=%d (%d -> %d B/frame). The draw path is "
                  ~ "allocating in proportion to the mesh again — look for a "
                  ~ "materialized bool[] view (mesh.selectedVertices / "
                  ~ "selectedEdges / selectedFaces) back on a per-frame path. "
                  ~ "The threshold is one GC page and is not the thing to "
                  ~ "adjust.",
                  what, delta, kSmall, kLarge, a.alloc, b.alloc));
}

unittest { // Vertices mode
    checkMode("vertices", "[0,1,2]", "vertices");
}

unittest { // Edges mode
    checkMode("edges", "[0,1,2]", "edges");
}

unittest { // Polygons mode, NOTHING selected
    // The empty-selection case is not redundant with the one below: it is the
    // state in which the face->edge highlight cache's change detector runs and
    // the checker overlay does not, so it is the only leg that isolates the
    // detector's own per-frame cost.
    checkMode("polygons", "[]", "polygons-empty");
}

unittest { // Polygons mode, three faces selected
    // Covers drawSelectedFacesOverlay's mask and the face->edge cache REBUILD
    // path at the same time.
    checkMode("polygons", "[0,1,2]", "polygons-selected");
}
