// Tests for FalloffStage.connect — the Element falloff's
// "Connected Elements" gate, realigned to the reference modeling app's
// taxonomy: Ignore / UseConnectivity / Rigid / EdgeLoops.
//
//   * Ignore          — ignore connectivity; pure geometric falloff
//                       (a vert in range moves regardless of which
//                       surface it belongs to).
//   * UseConnectivity — only the same connected surface; verts in other
//                       components are gated to 0 (still attenuating
//                       within the picked component).
//   * Rigid           — the whole connected component moves rigidly the
//                       full distance (weight 1, no attenuation).
//   * EdgeLoops        — documented stub; behaves as UseConnectivity
//                       (pending quad edge-loop detection + a reference
//                       capture).
//
// Part A asserts the setAttr / listAttrs round-trip for every key
// (bogus rejected). Part B builds a genuinely TWO-component mesh
// (default cube + an appended disjoint cube) and checks the three
// implemented modes shape the per-vert weight differently: the
// connectMask is now resolved headless from `anchorRing` at packet
// publish time, so connect works in `tool.doApply` without an
// interactive click.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

string falloffAttr(string key) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            return st["attrs"][key].str;
    assert(false, "WGHT stage missing");
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

double[][] dumpVerts() {
    double[][] vs;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        vs ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return vs;
}

// ----------------------------------------------------------------------
// Part A — round-trip the new connect keys through setAttr / listAttrs.
// ----------------------------------------------------------------------

unittest { // connect attr round-trips for every realigned key
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff type element");
    foreach (mode; ["ignore", "useConnectivity", "rigid", "edgeLoops"]) {
        cmd("tool.pipe.attr falloff connect " ~ mode);
        assert(falloffAttr("connect") == mode,
            "connect=" ~ mode ~ " should round-trip; got "
            ~ falloffAttr("connect"));
    }
}

unittest { // old (retired) keys are now rejected — hard rename, no alias
    postJson("/api/reset", "");
    cmd("tool.set xfrm.elementMove on");
    cmd("tool.pipe.attr falloff type element");
    foreach (stale; ["off", "vertex", "polygon", "material", "bogus"]) {
        auto r = postJson("/api/command",
                          "tool.pipe.attr falloff connect " ~ stale);
        assert(r["status"].str != "ok",
            "retired/unknown connect value `" ~ stale
            ~ "` should fail; got " ~ r.toString);
    }
}

// ----------------------------------------------------------------------
// Part B — two-component connectivity behaviour, headless.
//
// `/api/reset` leaves the default ±0.5 cube (verts 0..7). `prim.cube`
// APPENDS a disjoint cuboid centred at x=3 (verts 8..15) — two
// connected components that share no edge. We anchor the Element
// falloff on a vert of the SECOND cube (index 8) with a large radius so
// EVERY vert is within geometric range, then compare the three modes.
// ----------------------------------------------------------------------

// Build the two-component scene; assert 16 verts in two clusters.
void buildTwoComponents() {
    postJson("/api/reset", "");          // default cube → verts 0..7 (±0.5)
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:3 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:1 segmentsZ:1 radius:0");  // append → 8..15
    auto vs = dumpVerts();
    assert(vs.length == 16,
        "expected 8 (default cube) + 8 (appended cube) = 16 verts; got "
        ~ vs.length.to!string);
}

// True if vert v is one of the SECOND cube's verts (x ≈ 2.5 or 3.5),
// using its ORIGINAL (pre-move) x. After a +TX move on cube B, x
// shifts, so we classify on y/z box membership at ±0.5 and an x>1 test.
bool onCubeB(double[] v) { return v[0] > 1.5; }   // both 2.5 and 3.5 (+ moved) > 1.5
bool onCubeA(double[] v) { return v[0] < 1.5; }

// Configure the Element falloff anchored on vert 8 of cube B, radius 5
// (whole mesh in geometric range), Move TX 0.3, then apply.
void runElementMove(string connectMode) {
    buildTwoComponents();
    cmd("tool.set move on");
    cmd("tool.pipe.attr falloff type element");
    // Anchor on a single vert of the SECOND cube (index 8 = [2.5,-0.5,-0.5]).
    // anchorRing both short-circuits that vert to weight 1 AND seeds the
    // headless connectMask BFS for the connectivity modes.
    cmd("tool.pipe.attr falloff anchorRing 8");
    cmd("tool.pipe.attr actionCenter userPlacedCenter \"2.5,-0.5,-0.5\"");
    cmd("tool.pipe.attr falloff dist 5.0");      // large → all verts in range
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.pipe.attr falloff connect " ~ connectMode);
    cmd("tool.attr move TX 0.3");
    cmd("tool.doApply");
}

// Count how many verts on each cube moved in X (delta > eps), and the
// max X-delta seen on cube B (to detect rigid full-distance motion).
struct MoveStats { int movedA; int movedB; double maxDeltaB = 0; double minMovedDeltaB = double.max; }

MoveStats measure() {
    // Original X for each cube cluster (pre-move): cube A on ±0.5,
    // cube B on {2.5, 3.5}. We can't read pre-move state post-apply, so
    // we reason from the box geometry: any cube-A vert with |x| != 0.5
    // moved; any cube-B vert whose x is not exactly 2.5 or 3.5 moved.
    MoveStats s;
    foreach (v; dumpVerts()) {
        if (onCubeA(v)) {
            // unmoved cube-A vert sits on ±0.5 in x
            if (!approxEq(fabs(v[0]), 0.5)) s.movedA++;
        } else {
            // cube B: original x ∈ {2.5, 3.5}; moved verts shift by +0.3·w
            double d25 = v[0] - 2.5, d35 = v[0] - 3.5;
            double delta = (fabs(d25) < fabs(d35)) ? d25 : d35;
            if (fabs(delta) > 1e-4) {
                s.movedB++;
                if (delta > s.maxDeltaB) s.maxDeltaB = delta;
                if (delta < s.minMovedDeltaB) s.minMovedDeltaB = delta;
            }
        }
    }
    return s;
}

unittest { // Ignore: connectivity ignored → verts on BOTH cubes move
    runElementMove("ignore");
    auto s = measure();
    assert(s.movedB > 0, "Ignore: cube-B verts should move; got 0");
    assert(s.movedA > 0,
        "Ignore: cube-A verts (other component, but in geometric range) "
        ~ "should ALSO move; got " ~ s.movedA.to!string);
}

unittest { // UseConnectivity: only the picked (B) component moves
    runElementMove("useConnectivity");
    auto s = measure();
    assert(s.movedB > 0,
        "UseConnectivity: cube-B verts should move; got 0");
    assert(s.movedA == 0,
        "UseConnectivity: cube-A verts (unconnected) must be gated to 0; "
        ~ "got " ~ s.movedA.to!string ~ " moved");
}

unittest { // Rigid: whole picked component moves the FULL distance
    runElementMove("rigid");
    auto s = measure();
    assert(s.movedA == 0,
        "Rigid: cube-A verts (unconnected) must not move; got "
        ~ s.movedA.to!string);
    // All 8 cube-B verts move, every one by the full +0.3 (weight 1, no
    // attenuation) — min and max moved delta both ≈ 0.3.
    assert(s.movedB == 8,
        "Rigid: all 8 cube-B verts should move; got " ~ s.movedB.to!string);
    assert(approxEq(s.maxDeltaB, 0.3, 1e-3) && approxEq(s.minMovedDeltaB, 0.3, 1e-3),
        "Rigid: every cube-B vert should shift by the FULL 0.3 (uniform); "
        ~ "got min=" ~ s.minMovedDeltaB.to!string ~ " max=" ~ s.maxDeltaB.to!string);
}

unittest { // EdgeLoops no longer gates by component — it attenuates by
    // distance to the loop polyline (no component zeroing). With a SINGLE
    // non-edge anchor (vert 8, not a 2-vert edge) there is no loop to walk,
    // so the ring stays the single vert and the weight is the ungated
    // point-distance sphere — exactly like Ignore. The distinguishing
    // property here is that, unlike UseConnectivity / Rigid, EdgeLoops does
    // NOT zero the unconnected cube A: verts within geometric range move.
    runElementMove("edgeLoops");
    auto s = measure();
    assert(s.movedB > 0,
        "EdgeLoops: cube-B verts (near the anchor) should move; got 0");
    assert(s.movedA > 0,
        "EdgeLoops: no component zeroing gate — cube-A verts in geometric "
        ~ "range should ALSO move; got " ~ s.movedA.to!string);
}

// Differential sanity: Ignore moves strictly MORE of cube A than
// UseConnectivity (which moves none), and Rigid's cube-B motion is
// uniform whereas UseConnectivity's attenuates (min < max).
unittest {
    runElementMove("ignore");
    auto ig = measure();
    runElementMove("useConnectivity");
    auto uc = measure();
    runElementMove("rigid");
    auto rg = measure();

    assert(ig.movedA > uc.movedA,
        "Ignore should move more of cube A than UseConnectivity");
    assert(uc.movedA == 0 && rg.movedA == 0,
        "connectivity modes must not move the unconnected cube");
    // UseConnectivity attenuates inside the component (anchor vert full,
    // far verts less) → spread between min and max moved delta. Rigid is
    // uniform → min ≈ max.
    assert(uc.maxDeltaB - uc.minMovedDeltaB > 1e-3,
        "UseConnectivity should attenuate within the component (non-uniform "
        ~ "deltas); got min=" ~ uc.minMovedDeltaB.to!string
        ~ " max=" ~ uc.maxDeltaB.to!string);
    assert(rg.maxDeltaB - rg.minMovedDeltaB < 1e-3,
        "Rigid should move the component uniformly (min ≈ max); got min="
        ~ rg.minMovedDeltaB.to!string ~ " max=" ~ rg.maxDeltaB.to!string);
}
