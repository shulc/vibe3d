// select.set.* command-layer refusal tests (task 1060 review, BLOCKER 2).
//
// All five verbs got buttons in config/buttons.yaml, which route through the
// UI's plain runCommand dispatch (source/app.d) — a throwMsg = null caller.
// An uncaught Exception there unwinds past the args dialog's own popup-close
// call. Two conditions reach `apply()` on the VERY FIRST use with no other
// input:
//   - `name_`/`from_` default to "" (`Param.string_` with no seed), so
//     pressing OK on a freshly opened dialog hits the empty-name refusal;
//   - opening any of these five buttons while `currentType()` is
//     `SelType.Item` hits the domain gate (`domainOf` in
//     `commands/select/sets.d`).
// Before the review fix, both `domainOf` and `validateSetName`'s callers
// threw a bare `Exception` for these cases. `tests/test_selection_sets.d`
// exercises the SAME two conditions but only through the HTTP `/api/command`
// path (`applyOrRefire`'s throwMsg != null branch), which synthesizes its
// OWN Exception off `refusalReason()` whether `apply()` throws or merely
// refuses — so that suite cannot tell the two mechanisms apart. These tests
// construct each command directly (the same shape as
// `tests/unit/edge_crease_weight_test.d`'s own refusal tests) and call
// `apply()` with no HTTP layer in between, so a reintroduced `throw` becomes
// an UNCAUGHT EXCEPTION out of the unittest body — not merely a failed
// assert — matching what actually broke the UI dispatch frame.
//
// Mutation: reintroducing `throw new Exception(...)` in place of any
// `baseRefusal_ = ...; return false;` pair this task added to
// `commands/select/sets.d` turns the corresponding `assert(!cmd.apply())`
// below into an uncaught-exception failure.
module tests.unit.select_set_commands_test;

import command;
import mesh : Mesh, makeCube;
import view : View;
import editmode : EditMode;
import seltype : SelType;
import document : Document;
import commands.select.sets : SelectSetStore, SelectSetEdit, SelectSetApply,
                               SelectSetRename, SelectSetDelete;

version (unittest) {
    private View freshView() { return new View(0, 0, 1, 1); }

    private void assertRefuses(Command cmd) {
        assert(!cmd.apply(),
            cmd.name() ~ " must refuse (not throw) — see module doc");
        assert(cmd.refusalReason().length > 0,
            cmd.name() ~ ": a refusal without a reason renders as a silent "
          ~ "no-op (ui/command_notice.d)");
    }
}

unittest { // the domain gate: SelType.Item, all five verbs, default params
    auto m = new Mesh;
    *m = makeCube();
    View v = freshView();
    Document doc = Document.bootstrap(*m);

    Command[] cmds = [
        new SelectSetStore(m, v, EditMode.Polygons),
        new SelectSetEdit(m, v, EditMode.Polygons),
        new SelectSetApply(m, v, EditMode.Polygons, &doc),
        new SelectSetRename(m, v, EditMode.Polygons),
        new SelectSetDelete(m, v, EditMode.Polygons),
    ];
    foreach (cmd; cmds) {
        cmd.setSelTypeProvider(() => SelType.Item);
        assertRefuses(cmd);
    }
}

unittest { // the empty-name gate: freshly-opened-dialog "press OK", default params
    auto m = new Mesh;
    *m = makeCube();
    View v = freshView();
    Document doc = Document.bootstrap(*m);

    // EditMode.Polygons -> SelType.Polygon via the unwired-provider fallback
    // (`currentType()`'s compatibility shim) — a real geometry domain, so
    // the ONLY refusal these five can hit is the empty name/from field.
    Command[] cmds = [
        new SelectSetStore(m, v, EditMode.Polygons),
        new SelectSetEdit(m, v, EditMode.Polygons),
        new SelectSetApply(m, v, EditMode.Polygons, &doc),
        new SelectSetRename(m, v, EditMode.Polygons),
        new SelectSetDelete(m, v, EditMode.Polygons),
    ];
    foreach (cmd; cmds) assertRefuses(cmd);
}
