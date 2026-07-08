// Regression test for task 0310 — mesh.sliceTool corrupting the topology of a
// CONCAVE polygon: a plane cut through an lshape's reflex-corner notch used to
// leave the SAME vertex index twice in one face's boundary array (a "keyhole"
// terminus splice from task 0289 misfiring once a concave polygon is anywhere
// near the crossing — see source/mesh.d planeCutCore's concave guard).
//
// Repro (fuzz-found, task 0310): reset lshape (hexagonal concave top/bottom
// caps, reflex vertex at (0,0,±0.5)) → a single plain cut (no split/gap/caps)
// with default axis (the drawn-line ⟂ work-plane construction), line
// (-0.3,0.2,-0.3) -> (0.3,-0.1,0.3), clipped (infinite=off, the tool default).
// The plane crosses the concave notch region; several faces used to gain a
// [..,B,T,B,..] keyhole splice with repeated index B and an interior T vertex
// that lands off any pre-existing edge. The fix declines the keyhole whenever
// either crossing edge borders a concave face — those faces simply keep their
// single Pass-1-spliced crossing vertex (or clean chord-split, if both
// crossings land in-band) instead.
import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;

void main() {}

enum BASE = "http://localhost:8080";

JSONValue postCmd(string path, string body_) {
    auto resp = cast(string) post(BASE ~ path, body_);
    return parseJSON(resp);
}

JSONValue model() { return parseJSON(cast(string) get(BASE ~ "/api/model")); }

void cmd(string argstring) {
    auto r = postCmd("/api/command", argstring);
    assert(r["status"].str == "ok", "command `" ~ argstring ~ "` failed: " ~ r.toString);
}

void resetLshape() {
    auto r = postCmd("/api/reset?type=lshape", "");
    assert(r["status"].str == "ok", "/api/reset?type=lshape failed: " ~ r.toString);
}

// True iff any face repeats a vertex index within its own boundary array.
bool anyFaceHasRepeatedIndex(JSONValue m, out int faultyFace) {
    foreach (i, f; m["faces"].array) {
        bool[long] seen;
        foreach (c; f.array) {
            long vi = c.integer;
            if (vi in seen) { faultyFace = cast(int) i; return true; }
            seen[vi] = true;
        }
    }
    faultyFace = -1;
    return false;
}

double[3] jvec3(JSONValue v) {
    auto c = v.array;
    return [c[0].floating, c[1].floating, c[2].floating];
}

bool approxEq(double a, double b, double eps = 1e-4) {
    import std.math : fabs;
    return fabs(a - b) <= eps;
}

// True iff `p` lies (within eps) on the segment between original vertices a
// and b — i.e. it is a genuine edge-crossing lerp, not an interior point
// dropped mid-face by a keyhole splice.
bool onSegment(double[3] p, double[3] a, double[3] b, double eps = 1e-4) {
    import std.math : fabs, sqrt;
    double[3] ab = [b[0]-a[0], b[1]-a[1], b[2]-a[2]];
    double[3] ap = [p[0]-a[0], p[1]-a[1], p[2]-a[2]];
    double abLen2 = ab[0]*ab[0] + ab[1]*ab[1] + ab[2]*ab[2];
    if (abLen2 < 1e-12) return false;
    double t = (ap[0]*ab[0] + ap[1]*ab[1] + ap[2]*ab[2]) / abLen2;
    if (t < -eps || t > 1.0 + eps) return false;
    double[3] proj = [a[0] + t*ab[0], a[1] + t*ab[1], a[2] + t*ab[2]];
    double dx = p[0]-proj[0], dy = p[1]-proj[1], dz = p[2]-proj[2];
    return sqrt(dx*dx + dy*dy + dz*dz) <= eps;
}

unittest { // concave lshape cut through the reflex notch: no repeated index
    resetLshape();
    auto m0 = model();
    assert(m0["vertices"].array.length == 12, "lshape starts with 12 verts");
    assert(m0["faces"].array.length == 8, "lshape starts with 8 faces");

    cmd("tool.set mesh.sliceTool on");
    cmd("tool.attr mesh.sliceTool startX -0.3");
    cmd("tool.attr mesh.sliceTool startY 0.2");
    cmd("tool.attr mesh.sliceTool startZ -0.3");
    cmd("tool.attr mesh.sliceTool endX 0.3");
    cmd("tool.attr mesh.sliceTool endY -0.1");
    cmd("tool.attr mesh.sliceTool endZ 0.3");
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");

    auto m1 = model();
    int faulty;
    assert(!anyFaceHasRepeatedIndex(m1, faulty),
        format("face %d repeats a vertex index: %s", faulty,
               faulty >= 0 ? m1["faces"].array[faulty].toString : "n/a"));

    // The cut must still have done SOMETHING (not silently no-op'd away).
    assert(m1["vertices"].array.length > m0["vertices"].array.length,
        "expected new crossing vertices from the cut");
    assert(m1["faces"].array.length >= m0["faces"].array.length,
        "expected at least as many faces after the cut");

    // Every vertex beyond the original 12 must be a genuine edge-crossing lerp
    // of two ORIGINAL vertices joined by a REAL pre-op edge (task 0310: the
    // buggy keyhole path additionally dropped interior "terminus" points that
    // land off any pre-op edge, inside a face but not on its boundary).
    double[3][] origVerts;
    foreach (v; m0["vertices"].array) origVerts ~= jvec3(v);
    Tuple2[] origEdges;
    foreach (e; m0["edges"].array) origEdges ~= Tuple2(cast(int) e.array[0].integer,
                                                       cast(int) e.array[1].integer);
    foreach (i, v; m1["vertices"].array) {
        if (i < origVerts.length) continue;
        double[3] p = jvec3(v);
        bool onAnyEdge = false;
        foreach (e; origEdges)
            if (onSegment(p, origVerts[e.a], origVerts[e.b])) { onAnyEdge = true; break; }
        assert(onAnyEdge,
            format("new vertex %d at %s is not on any original EDGE (terminus artifact?)", i, p));
    }
}

private struct Tuple2 { int a, b; }
