// R/S relocate ordering is a source-level ownership contract: the wrapper
// owns the open edit, while each input bank alone knows the exact instant a
// successful relocate is about to publish its new ACEN pin.  The callback is
// the narrow hand-off between those owners and must run before either bank
// moves/publishes the pin.
module tests.unit.test_rs_relocate_commit_order;

import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string sourceOf(string name) {
    return blankNonCode(readText(buildPath(repoRoot, "source", "tools",
        "transform", name)));
}

private void assertPreNotifyOrder(string bank, string hitExpr) {
    const code = sourceOf(bank ~ ".d");
    const anchor = code.indexOf("computeClickRelocateHit(e.x, e.y, "
        ~ hitExpr ~ ", vts)");
    assert(anchor >= 0,
        bank ~ " relocate-order witness lost its hit-test landmark");
    const relocateTail = code[anchor .. $];
    const callback = relocateTail.indexOf("beforeRelocate();");
    const movePin = relocateTail.indexOf(
        "handler.setPosition(" ~ hitExpr ~ ");");
    const notify = relocateTail.indexOf(
        "notifyAcenUserPlaced(" ~ hitExpr ~ ");");
    assert(callback >= 0 && movePin >= 0 && notify >= 0,
        bank ~ " relocate-order witness lost one of its three landmarks");
    assert(callback < movePin && movePin < notify,
        bank ~ " relocate must commit the wrapper edit before moving and "
        ~ "publishing the new ACEN pin");
}

unittest // test_rs_relocate_commit_order
{
    const move = sourceOf("move.d");
    const moveAnchor = move.indexOf(
        "computeClickRelocateHit(e.x, e.y, anchor, vts)");
    assert(moveAnchor >= 0,
        "move relocate-order witness lost its hit-test landmark");
    const moveTail = move[moveAnchor .. $];
    const moveCallback = moveTail.indexOf("beforeRelocate();");
    const moveDragArm = moveTail.indexOf("beginScreenPlaneDragAt(");
    assert(moveCallback >= 0 && moveDragArm >= 0,
        "move relocate-order witness lost its callback or drag landmark");
    assert(moveCallback < moveDragArm,
        "move relocate must commit the wrapper edit before arming its drag");

    assertPreNotifyOrder("rotate", "hit");
    assertPreNotifyOrder("scale", "center");

    const wrapper = sourceOf("xfrm_handles.d");
    assert(wrapper.indexOf("&commitBeforeMoveRelocate") >= 0 &&
           wrapper.indexOf("&commitBeforeRotateRelocate") >= 0 &&
           wrapper.indexOf("&commitBeforeScaleRelocate") >= 0,
        "Xfrm wrapper must supply all three pre-relocate commit callbacks");
    assert(wrapper.indexOf("rotWasPinnedOffGizmo && editIsOpen()") >= 0,
        "Rotate's post-bank commit must be limited to the non-relocating "
        ~ "pinned off-gizmo path");
}
