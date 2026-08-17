// A REAL command dispatcher for the Statistics panel's rows (task 1100).
//
// Shared by `stat_rows_invariant_test.d` (which fires a row's action and then
// re-reads the row) and by `stat_panel_widget_test.d` (whose whole point is
// that the drawer's `run` delegate must be a real dispatcher — a recording stub
// would make its own mutation inert).
//
// It constructs the ACTUAL `Command` object for the id, injects the row's own
// `argsJson` through `injectParamsInto` — the same function the HTTP path uses
// — and applies it. Nothing here re-implements a command's behaviour; anything
// that did would let a row and its button drift apart, which is the failure
// this whole task is shaped around.
//
// NO `unittest` BLOCK LIVES IN THIS FILE, deliberately: a shared test helper
// carrying one has made the runtime skip `main` in every test that links it.
module tests.unit.ui.stat_dispatch;

import std.json : JSONValue, parseJSON;

import command   : Command;
import document  : Document;
import editmode  : EditMode;
import mesh      : Mesh;
import params    : injectParamsInto;
import seltype   : SelType;
import view      : View;

import commands.select.by_stat : SelectByStatVertex, SelectByStatEdge,
                                 SelectByStatPolygon;
import commands.select.by_tag  : SelectByTag;
import commands.select.sets    : SelectSetApply;
import commands.layer.commands : LayerSelect;

/// One dispatch's outcome — enough to assert on a refusal without a throw.
struct DispatchResult {
    bool    ran;        ///< `apply()` returned true
    string  reason;     ///< `refusalReason()` when it did not
    Command cmd;        ///< the constructed object, so a caller can `revert()`
}

/// Build + apply the command a Statistics row dispatches.
///
/// `editMode` is the mode the command sees, which for `select.byTag` is a GATE
/// it refuses on — that refusal is a thing tests here want to observe, so it is
/// a parameter rather than something this helper quietly fixes up.
DispatchResult dispatchStatAction(Document* doc, Mesh* mesh, EditMode editMode,
                                  SelType current, string commandId,
                                  string argsJson) {
    View v = new View(0, 0, 1, 1);
    Command c;
    switch (commandId) {
        case "select.byStat.vertex":
            c = new SelectByStatVertex(mesh, v, editMode, null); break;
        case "select.byStat.edge":
            c = new SelectByStatEdge(mesh, v, editMode, null); break;
        case "select.byStat.polygon":
            c = new SelectByStatPolygon(mesh, v, editMode, null); break;
        case "select.byTag":
            c = new SelectByTag(mesh, v, editMode); break;
        case "select.set.apply":
            c = new SelectSetApply(mesh, v, editMode, doc); break;
        case "layer.select":
            c = new LayerSelect(mesh, v, editMode, doc, null); break;
        default:
            return DispatchResult(false, "no such command id: " ~ commandId, null);
    }
    // The production path wraps EVERY factory with the selection-type
    // authority (`registration.d`), and `select.set.apply` reads it to pick its
    // domain — so a test dispatcher that omitted it would silently exercise the
    // unwired fallback instead of the shipped behaviour.
    c.setSelTypeProvider(() => current);
    auto pj = parseJSON(argsJson);
    injectParamsInto(c.params(), pj);
    const bool ok = c.apply();
    return DispatchResult(ok, ok ? "" : c.refusalReason(), c);
}
