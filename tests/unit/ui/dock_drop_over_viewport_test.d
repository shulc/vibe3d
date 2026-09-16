module tests.unit.ui.dock_drop_over_viewport_test;

import d_imgui.imgui_h : ImVec2;
import tests.unit.ui.headless_dock : HeadlessDockScene, openScene;
import ui.imgui_window_class : kDockFlagNoDockingOverMe;

private ImVec2 tabGrab() { return ImVec2(190, 10); }

unittest { // control: the harness can dock into an ordinary panel node
    auto scene = openScene(kDockFlagNoDockingOverMe);
    scope(exit) scene.close();
    const before = scene.tabDockId;
    scene.dragTo(tabGrab(), scene.rightRect.center());
    assert(scene.tabDockId != 0 && scene.tabDockId != before,
        "6245 F4b(1) control: ordinary panel drop did not change DockId");
}

unittest { // target: the top edge creates a sibling split above the viewport
    auto scene = openScene(kDockFlagNoDockingOverMe);
    scope(exit) scene.close();
    const edge = ImVec2(scene.viewportRect.center().x,
                        scene.viewportRect.center().y - 46);
    scene.dragTo(tabGrab(), edge);
    assert(scene.tabDockId != 0,
        "6245 F4b(2) edge: panel did not dock over the viewport");
    assert(scene.tabDockId != scene.viewportHostDockId,
        "6245 F4b(2) edge: panel merged into the live ViewportHost node instead of splitting it");
}

unittest { // centre merging is refused
    auto scene = openScene(kDockFlagNoDockingOverMe);
    scope(exit) scene.close();
    scene.dragTo(tabGrab(), scene.viewportRect.center());
    assert(scene.tabDockId == 0,
        "6245 F4b(3) centre: panel merged into ViewportHost");
}

unittest { // the class-derived refusal follows ViewportHost after a split
    auto control = openScene(kDockFlagNoDockingOverMe, true);
    scope(exit) control.close();
    const edge = ImVec2(control.viewportRect.center().x,
                        control.viewportRect.center().y - 46);
    control.dragTo(tabGrab(), edge);
    const mateBefore = control.mateDockId;
    control.dragTo(tabGrab(), control.rightRect.center());
    assert(control.mateDockId != mateBefore,
        "6245 F4b(4) floor: the second panel could not dock into an ordinary node");

    auto scene = openScene(kDockFlagNoDockingOverMe, true);
    scope(exit) scene.close();
    const splitEdge = ImVec2(scene.viewportRect.center().x,
                             scene.viewportRect.center().y - 46);
    scene.dragTo(tabGrab(), splitEdge);
    assert(scene.tabDockId != 0
        && scene.tabDockId != scene.viewportHostDockId,
        "6245 F4b(4) floor: first gesture did not split ViewportHost");
    scene.dragTo(tabGrab(), scene.viewportRect.center());
    assert(scene.mateDockId == 0,
        "6245 F4b(4) post-split centre: second panel merged into ViewportHost");
}
