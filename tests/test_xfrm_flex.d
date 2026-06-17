// Flex tool (D.7 of doc/deform_d7_flex_plan.md). Verifies the
// xfrm.flex preset wires ACEN=border + AXIS=select + Falloff=
// selection + Transform T=R=S=1.
//
// Selection falloff semantics (`falloff.selection`):
//   - Selected vert on selection boundary (has ≥1 unselected
//     edge-neighbour) → weight = 0 (anchored).
//   - Selected vert depth d hops from boundary, d ≥ steps →
//     weight = 1 (full move with gizmo).
//   - 0 < d < steps                                  →
//     weight = applyShape(1 - d/steps, shape, in_, out_).
//   - Unselected vert                                →
//     weight = 0 (falloff does NOT propagate outside selection).
//
// The default cube (8 verts, 6 faces) is too coarse to host a
// non-trivial selection: any 1-face selection has all verts on
// the boundary → all weight 0 → no movement at all. We test the
// boundary-anchor + zero-unselected-weight invariants here and
// defer "interior verts move" coverage to the cross-engine cases,
// which run on a subdivided cube with a non-trivial interior.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string p) { return parseJSON(cast(string) get(baseUrl ~ p)); }
JSONValue postJson(string p, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ p, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}
double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}
bool approxEq(double a, double b, double eps = 1e-3) {
    return fabs(a - b) < eps;
}

unittest { // Preset round-trip — no exception means the preset is
           // registered and the four pipe stages (ACEN/AXIS/Falloff/
           // ACTR) accept their attr values.
    postJson("/api/reset", "");
    cmd("tool.set xfrm.flex on");
    cmd("tool.set xfrm.flex off");
}

unittest { // Single-face selection on a cube: all 4 selected verts
           // sit on the selection boundary (each has 3 edge-
           // neighbours, only 2 are in the selected face). Every
           // selected vert → weight 0; every unselected vert →
           // weight 0; TX should move NOTHING.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    auto before = dumpVerts();

    cmd("tool.set xfrm.flex on");
    cmd("tool.pipe.attr falloff steps 2");
    cmd("tool.pipe.attr falloff shape smooth");
    cmd("tool.attr xfrm.flex TX 0.5");
    cmd("tool.doApply");

    auto after = dumpVerts();

    // Every vert must stay put: selected verts are all on the
    // boundary (anchor), unselected verts are outside the
    // selection (weight=0).
    foreach (i; 0 .. 8) {
        double dx = after[i][0] - before[i][0];
        assert(approxEq(dx, 0.0, 1e-3),
            "vert " ~ i.to!string ~ " unexpectedly moved by "
            ~ dx.to!string);
    }

    cmd("tool.set xfrm.flex off");
}

unittest { // Selecting EVERY face on the cube means every selected
           // vert has every neighbour also selected → no boundary
           // exists → BFS leaves distance = uint.max → weight = 1
           // (deep-interior fall-through). TX should move every
           // vert by full strength. This pins down the "no
           // boundary, no constraint" edge case.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[0,1,2,3,4,5]}`);
    auto before = dumpVerts();

    cmd("tool.set xfrm.flex on");
    cmd("tool.pipe.attr falloff steps 2");
    cmd("tool.pipe.attr falloff shape smooth");
    cmd("tool.attr xfrm.flex TX 0.5");
    cmd("tool.doApply");

    auto after = dumpVerts();

    foreach (i; 0 .. 8) {
        double dx = after[i][0] - before[i][0];
        assert(approxEq(dx, 0.5, 1e-3),
            "vert " ~ i.to!string ~ " should move by 0.5; got "
            ~ dx.to!string);
    }

    cmd("tool.set xfrm.flex off");
}

unittest { // Unselected verts ALWAYS stay put. Select 1 face, set
           // steps=8 (huge BFS budget). The 4 unselected verts
           // must remain untouched — the falloff does not
           // propagate outside the selection, regardless of steps.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    auto before = dumpVerts();

    cmd("tool.set xfrm.flex on");
    cmd("tool.pipe.attr falloff steps 8");
    cmd("tool.pipe.attr falloff shape smooth");
    cmd("tool.attr xfrm.flex TX 1.0");
    cmd("tool.doApply");

    auto after = dumpVerts();

    // The selection (face 0, 4 verts) is wholly on the boundary
    // → no movement on those either. The 4 unselected verts must
    // also stay put (unselected = weight 0). Net: 8 verts, all
    // dx ≈ 0.
    foreach (i; 0 .. 8) {
        double dx = after[i][0] - before[i][0];
        assert(approxEq(dx, 0.0, 1e-3),
            "vert " ~ i.to!string ~ " unexpectedly moved by "
            ~ dx.to!string);
    }

    cmd("tool.set xfrm.flex off");
}
