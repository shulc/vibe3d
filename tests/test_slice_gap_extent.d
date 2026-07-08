// Regression test for task 0309 — mesh.sliceTool Split+Gap silently
// destroying (or silently reverting) the mesh once `gap` reaches or exceeds
// the mesh's own extent along the cut-plane normal.
//
// Root cause (source/mesh.d): `cutByPlaneSplitGap` cuts two REAL parallel
// planes `gap` apart and then deletes whichever connected component's whole
// vertex range falls inside that slab (`deleteComponentsInSlab`). Once the
// slab offset reaches/exceeds the mesh's own extent, one (or both) of the two
// cuts no longer crosses any geometry (n1/n2 == 0) — the mesh stays a SINGLE
// untouched component whose own bounding range can then trivially satisfy the
// slab-containment test, and `deleteComponentsInSlab` deletes EVERY face,
// silently emptying the document (status still "ok"). The fix adds an
// empty-mesh guard directly in `deleteComponentsInSlab`: a mask that would
// remove every remaining face is refused (0 removed, mesh untouched), so
// `cutByPlaneSplitGap`'s `separated` flag correctly reads false and the
// EXISTING caller-side fallback (roll back the two cuts, re-cut via the
// legacy single-cut + along-edge gap slide) engages instead of nuking the
// mesh.
//
// Repro (fuzz-found): reset cube, plane line (-1,0,0)->(1,0,0) (default axis
// -> cut normal = Z, cube spans z in [-0.5,0.5]), Split on. gap up to 0.99
// (loAmt=hiAmt=0.495, strictly inside the cube's half-extent) cuts correctly
// (16v/12f). At gap=1.0 (loAmt=hiAmt=0.5, exactly the cube's half-extent) the
// unfixed kernel wiped the mesh to 0v/0f; this test pins gap=1.0/2.0/100 all
// staying non-empty.
import std.net.curl;
import std.json;
import std.format : format;
import std.conv   : to;

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

void resetCube() {
    auto r = postCmd("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

// Drives mesh.sliceTool through one Split+Gap cut on the standard X-line cube
// case and returns the resulting /api/model.
JSONValue runSplitGapCut(double gap, string gapSide) {
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    cmd("tool.attr mesh.sliceTool startX -1");
    cmd("tool.attr mesh.sliceTool startY 0");
    cmd("tool.attr mesh.sliceTool startZ 0");
    cmd("tool.attr mesh.sliceTool endX 1");
    cmd("tool.attr mesh.sliceTool endY 0");
    cmd("tool.attr mesh.sliceTool endZ 0");
    cmd("tool.attr mesh.sliceTool split 1");
    cmd(format("tool.attr mesh.sliceTool gap %g", gap));
    cmd("tool.attr mesh.sliceTool gapSide " ~ gapSide);
    cmd("tool.doApply");
    cmd("tool.set mesh.sliceTool off");
    return model();
}

unittest { // gap just under the cube's extent: correct 16v/24e/12f (control)
    auto m = runSplitGapCut(0.99, "center");
    assert(m["vertices"].array.length == 16,
        "gap=0.99 center: expected 16 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 12,
        "gap=0.99 center: expected 12 faces, got " ~ m["faces"].array.length.to!string);
}

unittest { // gap AT the cube's extent (task 0309's exact failure threshold): must not empty
    auto m = runSplitGapCut(1.0, "center");
    assert(m["vertices"].array.length > 0,
        "gap=1.0 center silently emptied the mesh (0 vertices)");
    assert(m["faces"].array.length > 0,
        "gap=1.0 center silently emptied the mesh (0 faces)");
}

unittest { // gap well beyond the cube's extent: must not empty
    foreach (gap; [2.0, 100.0]) {
        auto m = runSplitGapCut(gap, "center");
        assert(m["vertices"].array.length > 0,
            format("gap=%g center silently emptied the mesh (0 vertices)", gap));
        assert(m["faces"].array.length > 0,
            format("gap=%g center silently emptied the mesh (0 faces)", gap));
    }
}

unittest { // gapSide positive/negative at a large gap: not empty, and the cut
    // must not be silently dropped. `gapSide` keeps only ONE shell (the huge
    // gap swallows the other), so the untouched FAR face of the kept shell
    // legitimately stays at the original +-0.5 extent -- checking for that
    // alone is not a valid "was the cut dropped" test. What DOES prove the
    // cut survived: the kept shell's OWN z-span is strictly narrower than the
    // full original cube's span (1.0) -- a genuine silent revert would show
    // the complete, untouched 8v/6f cube spanning the full [-0.5, 0.5].
    foreach (side; ["positive", "negative"]) {
        auto m = runSplitGapCut(100.0, side);
        assert(m["vertices"].array.length > 0,
            "gap=100 " ~ side ~ " silently emptied the mesh (0 vertices)");
        assert(m["faces"].array.length > 0,
            "gap=100 " ~ side ~ " silently emptied the mesh (0 faces)");

        double minZ = double.infinity, maxZ = -double.infinity;
        foreach (v; m["vertices"].array) {
            double z = v.array[2].floating;
            if (z < minZ) minZ = z;
            if (z > maxZ) maxZ = z;
        }
        double span = maxZ - minZ;
        assert(span < 1.0 - 1e-4,
            format("gap=100 %s: kept shell spans the FULL [-0.5,0.5] extent" ~
                   " (z %g..%g) -- looks like the cut was silently dropped" ~
                   " (reverted to the unsliced cube)", side, minZ, maxZ));
    }
}
