module tests.unit.topology_pen_election_consumers_test;
import tools.edit.topology_pen.tool : TopologyPenTool;
import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;
import std.algorithm : canFind;
import tests.unit.census_symbols : countOccurrences;
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
    const projection = move.indexOf("projectToWindowFull(snapCenter, vp, sx, sy, sz)");
    const election = move.indexOf("placementSnap_ = placementElection(snapCenter,");
    const convert = move.indexOf("targets[0] = primaryModelSpace().toLocalPoint(placementSnap_.worldPos);");
    assert(countOccurrences(move, "projectToWindowFull(snapCenter, vp, sx, sy, sz)") == 1
        && projection >= 0 && election > projection,
        "Move projects its resolved snap center before election exactly once");
    assert(move.canFind("cast(int)sx, cast(int)sy, vp, dragSnap_, exclude)"),
        "Move election transports projected resolved-center pixels");
    assert(countOccurrences(move, "placementSnap_ = placementElection(snapCenter,") == 1,
        "Move retains the resolved-center election answer");
    assert(countOccurrences(move, "if (placementSnap_.snapped)") == 1 && convert > election,
        "Move converts the retained snapped world answer into primary targets");
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
