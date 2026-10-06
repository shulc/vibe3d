module tests.unit.render_camera_intrinsics_wiring_test;
import std.file : readText;
import std.algorithm : canFind;
import std.path : buildPath,dirName;
import tests.unit.census_symbols : blankNonCode;
private enum root=dirName(dirName(dirName(__FILE_FULL_PATH__)));
unittest {
    const code=blankNonCode(readText(buildPath(root,"source/render/render_mvp.d")));
    // Lens is consumed by the descriptor and BOTH existing independent baselines.
    string[] needles=["cd.fovRadiansVertical  = v.projKind == ProjKind.Ortho ? View.defaultFovY : v.fovY;",
        "v.fovY      != g.lastSeenFovY", "v.fovY      != g.appliedFovY",
        "g.lastSeenFovY      = v.fovY;", "g.appliedFovY      = v.fovY;"];
    assert(needles.length==5,"IPR_LENS_WIRING_POPULATION");
    foreach(n;needles)assert(code.canFind(n),"IPR_LENS_PRODUCTION_WIRING: "~n);
}
