// wrapper_shift_apply_inheritance_test — success criterion 3 of task 1905, for
// the four tools it is about, not for the one that happens to be constructible.
//
// THE CRITERION: "T7 закрыт по построению (4 тула получают Shift+apply без
// override)" — the four wrapper tools get apply-and-continue WITHOUT each
// declaring its own `commitUncommittedEdit`. Audit 0678 T7 found the opposite
// state: `CommandWrapperTool` kept `Tool`'s base opt-out (`return false`), so
// `EditSession.applyAndContinue` refused, and Shift+LMB was a SILENT no-op for
// XfrmSmooth / XfrmJitter / XfrmQuantize / EdgeSlide while sixteen non-wrapper
// tools honoured the gesture.
//
// "CLOSED BY CONSTRUCTION" IS THE CLAIM THAT NEEDS THE WITNESS, and the witness
// that existed did not cover it. Measured 2026-08-29:
//
//   * the in-module cell in `source/tools/common/command_wrapper.d` drives
//     `XfrmSmoothTool` and counts the record — ONE of the four, at class level;
//   * NO test in `tests/` drives `applyAndContinue` on a wrapper tool at all
//     (`grep -rln applyAndContinue tests/` returns `test_poly_bevel_tool_drag.d`,
//     a G4 tool with its own override, and this file's siblings);
//   * `xfrm.jitter` and `xfrm.quantize` appear in ZERO suite tests
//     (`grep -rln 'xfrm.jitter' tests/*.d` is empty), so for two of the four
//     there was nothing at all.
//
// So the inheritance itself is asserted here, for all four, in the only form
// that is exact: which DECLARATION each class's `commitUncommittedEdit`
// resolves to. This is a compile-time fact and it is the whole of "without an
// override" — it cannot be satisfied by a tool that stopped being reached, and
// it does not pretend to be the gesture-level witness that is still missing
// (named as a gap in card 3330's Результат, not papered over here).
//
// WHY TWO ASSERTIONS AND NOT ONE. `__traits(isSame)` was PROBED, not reasoned
// about (dmd, 2026-08-29, a four-class fixture):
//
//     Leaf (no own override)  == Mid  -> true     <- member 1 wants this
//     LeafOwn (own override)  == Mid  -> false    <- member 1 catches this
//     Mid's override DELETED:  Leaf   == Mid -> STILL true
//
// The last row is the point. If `CommandWrapperTool`'s override is deleted, all
// four classes resolve to `Tool`'s opt-out TOGETHER, member 1 stays GREEN, and
// Shift+apply is silently a no-op again — the exact regression T7 named. Member
// 2 is what refuses that, and it is load-bearing rather than decorative.
//
// MUTATIONS:
//   1. add `override bool commitUncommittedEdit() { return true; }` to
//      `XfrmJitterTool` -> member 1 reddens, naming that class.
//   2. delete `CommandWrapperTool.commitUncommittedEdit` -> member 2 reddens;
//      member 1 does NOT (see the probe above).
//
// LANE: `dub test --config=tests`.
module tests.unit.wrapper_shift_apply_inheritance_test;

import tool : Tool;
import tools.common.command_wrapper : CommandWrapperTool,
                                      XfrmSmoothTool, XfrmJitterTool,
                                      XfrmQuantizeTool;
import tools.slice.edge_slide : EdgeSlideTool;

// ---------------------------------------------------------------------------
// 1. EACH OF THE FOUR RESOLVES TO THE FAMILY'S OVERRIDE, AND DECLARES NONE.
//
//    `EdgeSlideTool` is in this list for a reason worth stating: it is the one
//    wrapper tool living outside `command_wrapper.d`, so the in-module cell
//    cannot reach it (importing it there would close an import cycle —
//    `edge_slide.d` imports `command_wrapper.d`). A file in `tests/unit/` can
//    import both, which is why this member lives here and not beside the other.
// ---------------------------------------------------------------------------
unittest {
    static assert(__traits(isSame, XfrmSmoothTool.commitUncommittedEdit,
                                   CommandWrapperTool.commitUncommittedEdit),
        "XfrmSmoothTool declares its own commitUncommittedEdit. The four "
      ~ "wrapper tools are meant to inherit ONE implementation from "
      ~ "CommandWrapperTool (task 1905 criterion 3, audit 0678 T7): a per-tool "
      ~ "override is a second place to get the `true iff it really committed` "
      ~ "invariant wrong, and commitNow already answers it for the family.");

    static assert(__traits(isSame, XfrmJitterTool.commitUncommittedEdit,
                                   CommandWrapperTool.commitUncommittedEdit),
        "XfrmJitterTool declares its own commitUncommittedEdit — see the "
      ~ "XfrmSmoothTool message above. This tool has NO suite coverage at all, "
      ~ "so this assertion is the only thing standing between it and a silent "
      ~ "divergence.");

    static assert(__traits(isSame, XfrmQuantizeTool.commitUncommittedEdit,
                                   CommandWrapperTool.commitUncommittedEdit),
        "XfrmQuantizeTool declares its own commitUncommittedEdit — see the "
      ~ "XfrmSmoothTool message above. This tool has NO suite coverage at all.");

    static assert(__traits(isSame, EdgeSlideTool.commitUncommittedEdit,
                                   CommandWrapperTool.commitUncommittedEdit),
        "EdgeSlideTool declares its own commitUncommittedEdit — see the "
      ~ "XfrmSmoothTool message above. It is also the one wrapper tool the "
      ~ "in-module cell in command_wrapper.d cannot construct, so this is its "
      ~ "only witness of any kind.");
}

// ---------------------------------------------------------------------------
// 2. AND THE FAMILY'S OVERRIDE IS NOT THE BASE OPT-OUT.
//
//    Member 1 alone is satisfied by the regression it exists to catch: with
//    `CommandWrapperTool.commitUncommittedEdit` deleted, all four classes
//    resolve to `Tool.commitUncommittedEdit` TOGETHER and every `isSame` above
//    stays true. Probed on dmd, not assumed.
// ---------------------------------------------------------------------------
unittest {
    static assert(!__traits(isSame, CommandWrapperTool.commitUncommittedEdit,
                                    Tool.commitUncommittedEdit),
        "CommandWrapperTool no longer overrides commitUncommittedEdit, so all "
      ~ "four wrapper tools have fallen back to Tool's base opt-out "
      ~ "(`return false`). EditSession.applyAndContinue then returns false and "
      ~ "does NOTHING, and Shift+LMB on XfrmSmooth / XfrmJitter / XfrmQuantize "
      ~ "/ EdgeSlide is a SILENT no-op — audit 0678 T7, verbatim. Note that "
      ~ "member 1 above stays GREEN through this: the four still agree with "
      ~ "their base, because their base is now Tool's. That is why this "
      ~ "assertion exists separately.");
}
