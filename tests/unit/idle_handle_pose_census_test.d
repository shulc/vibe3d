module tests.unit.idle_handle_pose_census_test;

import std.algorithm : count;
import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest // Every idle publication uses the one translated-centre helper.
{
    const host = blankNonCode(readText(buildPath(repoRoot, "source", "tools",
        "transform", "xfrm_transform.d")));
    const handles = blankNonCode(readText(buildPath(repoRoot, "source", "tools",
        "transform", "xfrm_handles.d")));
    const apply = blankNonCode(readText(buildPath(repoRoot, "source", "tools",
        "transform", "xfrm_apply.d")));

    assert(host.count("setSharedGizmoPose(") == 10
        && handles.count("setSharedGizmoPose(") == 4,
        "6207 shared-pose census must remain 13 calls plus one definition");
    assert(host.count("setSharedGizmoPose(idleHandleCentre(vts), vts)") == 2,
        "6207 update/draw idle pose must use idleHandleCentre");
    assert(handles.count("setSharedGizmoPose(idleHandleCentre(vts), vts)") == 2,
        "6207 Move/Rotate restart pose must use idleHandleCentre before arm");
    assert(host.count("image.center = idleHandleCentre(vts)") == 1,
        "6207 prepared update tail must use idleHandleCentre");
    assert(handles.count("private Vec3 idleHandleCentre(") == 1,
        "6207 idleHandleCentre must have one definition");
    assert(handles.count("if (!flagT || !runFrameValid) return acen;") == 1,
        "6207 composite idle pose gate changed");
    const idleBegin = handles.indexOf("private Vec3 idleHandleCentre(");
    const idleEnd = handles.indexOf("private void setSharedGizmoPose(");
    assert(idleBegin >= 0 && idleEnd > idleBegin,
        "6207 idle pose body markers vanished");
    assert(handles[cast(size_t)idleBegin .. cast(size_t)idleEnd]
            .indexOf("itemSubjectActive") < 0,
        "6207 idle pose must not gain an item gate");
    assert(apply.count("composeRunMatrix(") == 1,
        "6207 apply fold must have one composition door");
}
