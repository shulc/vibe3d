// Task 1650 — the per-cell overlay decision has no tool-TYPE term.
//
// THE DEFECT. In a Quad layout the transform gizmo drew only in the cell under
// the cursor. The overlay OWNER being the hovered cell is by design, and every
// other cell is meant to draw a world-derived replica (`OverlayMode.Visual`).
// What stopped it was that the non-owner branch was gated on a hand-written
// list of concrete tool classes:
//
//     multiCellEligible =  cast(XfrmTransformTool)  activeTool !is null
//                       || cast(CommandWrapperTool) activeTool !is null
//                       || (activeTool is null && anyFalloffActive());
//
// `EdgeExtendTool` and `EdgeBevelTool` COMPOSE a transform wrapper instead of
// inheriting one, so both casts missed and their cells were told to draw
// nothing. An enumerated list standing in for a capability — the list was a
// hypothesis about which tools are safe, and it was wrong about two of them.
//
// WHAT THIS FILE PINS, and why each block would otherwise be un-failable:
//
//   1. `resolveOverlayMode` decides by cell identity alone. A mutation that
//      reintroduces ANY type term has to change this function's signature to
//      get a tool in, which is the point of putting the decision here.
//
//   2. The RIG'S TOOL CHOICE, stated out loud. A test of this defect built on
//      move / rotate / scale is green whether or not the fix landed, because
//      those ARE `XfrmTransformTool` and were inside the removed list. The
//      HTTP flow in tests/test_quad_overlay_all_cells.d therefore arms
//      `edge.extend`; the assertions below are what make that choice a checked
//      fact rather than a comment. If someone later reparents `EdgeExtendTool`
//      onto `XfrmTransformTool`, this file goes red and says the rig stopped
//      discriminating — instead of the HTTP flow quietly passing forever.
//
// The ORDERING property that makes dropping the list safe (`overlayDrawOrder`
// visits the owner LAST) is pinned in tests/unit/viewport_test.d, and the
// behaviour end-to-end in tests/test_quad_overlay_all_cells.d.
module tests.unit.quad_overlay_eligibility_test;

import editor_app : OverlayMode, resolveOverlayMode;

import tools.transform.xfrm_transform : XfrmTransformTool;
import tools.common.command_wrapper   : CommandWrapperTool;
import tools.edit.edge_extend         : EdgeExtendTool;
import tools.edit.edge_bevel          : EdgeBevelTool;
import tools.transform.move           : MoveTool;
import tool                           : Tool;

unittest {
    // 1. The owner cell is Interactive; EVERY other live cell is Visual.
    //    Asserted across all four owners, not just owner 0, so a decision that
    //    happened to be right for the cell `--test` makes active cannot pass.
    foreach (owner; 0 .. 4) {
        foreach (k; 0 .. 4) {
            immutable want = (k == owner) ? OverlayMode.Interactive
                                          : OverlayMode.Visual;
            assert(resolveOverlayMode(k, owner, true) == want,
                   "cell must be Interactive iff it is the overlay owner, and "
                   ~ "Visual otherwise — no cell is ever told to draw nothing "
                   ~ "while a tool is armed");
        }
    }
}

unittest {
    // 2. Nothing armed ⇒ nothing drawn, in every cell. This is the term that
    //    keeps the change from turning `Visual` into "always", and it is what
    //    makes the block above a real discriminator rather than a constant:
    //    `resolveOverlayMode` returns two different answers over its inputs.
    foreach (owner; 0 .. 4)
        foreach (k; 0 .. 4)
            assert(resolveOverlayMode(k, owner, false) == OverlayMode.None,
                   "no tool and no falloff ⇒ no overlay in ANY cell");
}

unittest {
    // 3. Single layout (the `--test` invariant): the only cell is the owner,
    //    so the Visual branch is unreachable and the decision is exactly the
    //    pre-task-0206 one.
    assert(resolveOverlayMode(0, 0, true)  == OverlayMode.Interactive);
    assert(resolveOverlayMode(0, 0, false) == OverlayMode.None);
}

unittest {
    // 4. THE RIG'S CHOICE, OUT LOUD — see this file's header.
    //
    // `edge.extend` and `edge.bevel` are outside the list task 1650 removed:
    // neither is an `XfrmTransformTool` nor a `CommandWrapperTool`, which is
    // precisely why their cells used to draw nothing and why an HTTP flow
    // armed with one of them can FAIL if the fix is reverted.
    assert(!is(EdgeExtendTool : XfrmTransformTool),
           "EdgeExtendTool must not BE an XfrmTransformTool — it composes one. "
           ~ "If that changed, tests/test_quad_overlay_all_cells.d no longer "
           ~ "discriminates and must be re-aimed at a tool that still does");
    assert(!is(EdgeExtendTool : CommandWrapperTool));
    assert(!is(EdgeBevelTool  : XfrmTransformTool),
           "EdgeBevelTool must not BE an XfrmTransformTool — see above");
    assert(!is(EdgeBevelTool  : CommandWrapperTool));

    // Both are plain `Tool`s, which is what made the two casts miss.
    assert(is(EdgeExtendTool : Tool));
    assert(is(EdgeBevelTool  : Tool));

    // The CONTROL, and the reason it is here: a rig built on move/rotate/scale
    // cannot fail this defect. `XfrmTransformTool` was INSIDE the removed
    // list, so its cells drew replicas before the fix and draw them after.
    // Asserting that directly is what turns "do not use move" from advice into
    // something the suite enforces.
    assert(is(XfrmTransformTool : Tool));
    assert(is(XfrmTransformTool : XfrmTransformTool),
           "move/rotate/scale are XfrmTransformTool — inside the removed list, "
           ~ "hence green either way. Do not build this fixture on them");
    // MoveTool is the bank the wrapper COMPOSES, not the armed tool itself.
    assert(!is(MoveTool : XfrmTransformTool));
}
