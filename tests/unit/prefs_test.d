// Module unittests for `prefs`, moved verbatim out of source/prefs.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.prefs_test;

import std.json   : JSONValue, JSONType, parseJSON, JSONException;
import std.file   : exists, read, write, mkdirRecurse, copy;
import std.path   : buildPath, absolutePath;
import std.process : environment;
import std.format : format;
import log            : logWarn;
import viewport       : LayoutPreset;
import display_state  : DisplayStyle, WireOverlay;
import coord_rounding : CoordinateRounding, kCoordRoundingDefault,
                        kFixedIncrementDefault, coordRoundingName,
                        parseCoordRounding;
import trackball      : kTrackballDefault, kTrackballSpeedDefault,
                        clampTrackballSpeed, kSpinSwingDefault;
import std.file : tempDir, rmdirRecurse, mkdirRecurse;
import std.path : buildPath;
import std.random : uniform;
import prefs;

// Pure filename math only — no GL context, no filesystem access.
unittest {
    auto p1 = layoutIniPath("/cfg/vibe3d", 1);
    auto p2 = layoutIniPath("/cfg/vibe3d", 2);
    auto p3 = layoutIniPath("/cfg/vibe3d", 3);
    import std.path : baseName, dirName;
    assert(dirName(p1)  == "/cfg/vibe3d",        "path must be under dir");
    assert(baseName(p1) == "imgui_layout_v1.ini", "v1 filename");
    assert(p1 != p2,                              "version bump → different file");
    assert(baseName(p2) == "imgui_layout_v2.ini", "v2 filename");
    assert(p2 != p3,                              "version bump → different file");
    assert(baseName(p3) == "imgui_layout_v3.ini", "v3 filename");
}
