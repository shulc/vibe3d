module tests.unit.topology_pen_election_consumers_test;
import tools.edit.topology_pen.tool : TopologyPenTool;
import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;
import std.algorithm : canFind;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, balancedSpan;
private enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private string body(string file, string declaration) {
    const code = blankUnittestBodies(blankNonCode(readText(buildPath(root, file))));
    const at = code.indexOf(declaration);
    assert(at >= 0, "election consumer population: " ~ declaration);
    const result = balancedSpan(code, code.indexOf('{', at), '{', '}');
    assert(result.length > 30, "election consumer body floor: " ~ declaration);
    return result;
}
unittest {
    enum tool = "source/tools/edit/topology_pen/tool.d";
    const place = body(tool, "Vec3 placeSnapped(");
    assert(place.canFind("placementSnap_ = placementElection(")
        && place.canFind("return placementSnap_.worldPos;"),
        "Point placement must consume and retain its actual election");
    const move = body(tool, "Vec3[] moveTargets(");
    assert(move.canFind("placementSnap_ = placementElection(")
        && move.canFind("px, py, vp, dragSnap_, exclude)")
        && move.canFind("targets[0] = primaryModelSpace().toLocalPoint(placementSnap_.worldPos);"),
        "Move placement must consume and retain its actual election");
    const hit = body(tool, "void readHit(");
    assert(hit.canFind("placementSnap_ = placementElection("),
        "real cursor transport must produce the placement election");
    const update = body(tool, "PreparedTopologyPenUpdateImage buildPreparedUpdate(");
    assert(update.canFind("image.nextPlacementSnap = placementElection("),
        "prepared cursor transport must produce the same placement election");
    const dispatch = body("source/tools/edit/topology_pen/render.d", "override void draw(");
    assert(dispatch.indexOf("drawSnapTargetMarker(dl, vp);") >= 0
        && dispatch.indexOf("drawSnapTargetMarker(dl, vp);") < dispatch.indexOf("if (!lastHit_.hit)"),
        "elected marker must reach draw even without a constraint hit");
    const render = body("source/tools/edit/topology_pen/render.d", "void drawSnapTargetMarker(");
    assert(!render.canFind("resolveHoverTarget") && render.canFind("placementSnap_.snapped")
        && render.canFind("snapHighlightPixels(placementSnap_, vp, *m, targetPixels)"),
        "draw marker must project the actual elected source and element");
    const json = body("source/tools/edit/topology_pen/json.d", "JSONValue toolStateJson(");
    assert(json.canFind("placementSnap_.targetSource") && json.canFind("placementSnap_.targetIndex")
        && !json.canFind("lastTarget_.kind"),
        "target readout must consume the actual elected source and element");
}
