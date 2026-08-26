module command;

import mesh;
import view;
import editmode;
import seltype : SelType, geometrySelType;
import math : Viewport;
import params : Param, ParamHints;
import mesh_edit_delta : MeshEditScope;

// Test-automation gate (re-eval plan D5). Set true ONLY when the editor is
// launched with --test (app.d), mirroring the HttpServer.setTestMode flag the
// /api/play-events machinery uses. testMode-gated commands (tool.beginSession,
// tool.panelEdit) reject themselves unless this is set, so they are inert and
// unreachable in a normal build/run.
__gshared bool g_testMode = false;

// Task 0654 — "does the document have a mesh edit target right now?", as a
// resolver rather than a `Document` import.
//
// `command.d` deliberately does not know about `document.d` (this module is
// imported by every command, including ones a headless test constructs over a
// bare `Mesh` with no Document in sight). app.d installs this at init, exactly
// as it installs `display_sync.activeMeshResolver` and
// `document.primaryModelSpaceResolver`.
//
// NULL means "assume there is a target" — the pre-0654 behaviour, which is the
// right default for the direct-construction test path (the caller passed the
// mesh it wants written, and there is no selection to consult).
__gshared bool delegate() g_editTargetResolver;

// The one-clause reason a command names when it refuses for want of an edit
// target. Kept BYTE-IDENTICAL to `document.kNoEditTargetReason` by the
// `static assert` in that module's unittest — `command.d` cannot import
// `document.d` (see `g_editTargetResolver`), so the string is duplicated and
// the equality is asserted rather than assumed.
//
// TASK 0668 — it reads "no MESH item is selected", not "no item is selected".
// The old wording was true only while an absent edit target implied an empty
// selection; since 0668 the ordinary way to reach this refusal is a reference
// plane selected ALONE, and a message denying that anything is selected while
// the panel shows a selected plane sends the user looking for the wrong
// problem. The new wording is true in BOTH states and, unlike the old one,
// says what to do about it.
enum string kNoEditTargetReason =
    "no mesh item is selected: there is no mesh edit target";

// ---------------------------------------------------------------------------
// Command — base class for every user-visible action.
//
// Undo/redo model (see doc/undo_redo_plan.md):
// - apply()    — runs the operation. `final`: it opens the change-bus
//                delivery batch and calls applyImpl(), so every command is
//                inside one (task 1906 stage 0b). Callers call THIS.
// - applyImpl()— the override point, and the only one. Mutating commands MUST
//                snapshot pre-state into instance fields here.
// - revert()   — restore the pre-apply state (using the snapshot).
//                Default: no-op (returns false). Mutating commands MUST
//                override and return true on successful revert.
// - cmdFlags() — bitfield classifying the command (see CmdFlags).
//                Undoability is DERIVED from it: a command is undoable
//                iff its flags carry CmdFlags.Model. Read-only /
//                non-mutating commands override cmdFlags() to drop Model;
//                the dispatcher then skips pushing to the undo stack.
// - label()    — short human-readable text for the Edit menu / history
//                viewer ("Bevel edges", "Move 3 verts"). Defaults to
//                name().
// ---------------------------------------------------------------------------

// WHO asked for this command line to run (task 1520).
//
// The refusal POLICY is a property of the CALLER, not of the command and not
// of the dispatcher: a script that asked for something impossible must be
// told (an exception it can see), while the same refusal raised from inside an
// ImGui draw has nowhere to go but `_Dmain` — which killed the editor every
// time a file dialog was cancelled from a panel button.
//
// One dispatcher body serves both; this enum is the only thing that differs,
// and it is read at exactly one place (`refused()` in http_providers.d).
enum CommandOrigin {
    ui,      /// a panel button, a menu item, a keyboard shortcut — REFUSAL IS A NOTICE
    script,  /// `/api/command`, `/api/script`, a macro — REFUSAL IS AN EXCEPTION
}

// Bitfield classifying a command's effect on the application. The
// undo dispatcher and history panel read these bits; behaviour for any
// single command is determined entirely by which bits are set.
enum CmdFlags : uint {
    None       = 0,
    Model      = 1 << 0, // Alters scene/document (mesh) state → undoable (Model-undo class).
    UI         = 1 << 1, // Alters UI/view state only (camera, panels) — no undo entry.
    Quiet      = 1 << 2, // Suppress logging / notification for this command.
    SideEffect = 1 << 3, // Transient session/tool-pipe change — no undo entry.
    UiState    = 1 << 4, // Alters undoable UI state (selection / edit mode) →
                         // undoable, but in the UI-undo class (distinct from
                         // Model-undo). Lands on the same stack and Ctrl+Z
                         // undoes it; the class bit lets history/panel/tests
                         // tell selection-undo apart from geometry-undo. This
                         // is the vibe3d-native analog of a UI-undo command.
    UndoForce    = 1 << 5, // Explicit opt-IN to undoability, OVERRIDING the
                           // derived (Model | UiState) rule. Lets a command that
                           // carries neither Model nor UiState (e.g. a transient
                           // SideEffect-flavored op the author still wants on the
                           // stack) land an undo entry. Loses to UndoSuppress.
    UndoSuppress = 1 << 6, // Explicit opt-OUT of undoability, OVERRIDING both the
                           // derived rule AND UndoForce. A Model-mutating command
                           // that sets this records NO undo entry — the author
                           // takes responsibility for the state change being
                           // unrecoverable / handled elsewhere. Highest priority.
    UndoBoundary = 1 << 7, // Hard stop for the class-aware T-SEP undo cursor.
                           // The entry IS on the stack and IS undoable (carries
                           // Model), but the cursor scan stops here — it will not
                           // step to this entry during a model undo. When the
                           // boundary entry is the ONLY entry left (tail-at-
                           // boundary), Case B applies: the boundary entry itself
                           // IS reverted as the B1 fallback (it is a Model entry
                           // that the cursor stopped in front of, so it becomes
                           // the lone "UI head" in the fallback sense). Applied
                           // to scene.reset and file.new: a reset delimits "current
                           // editing session" from "prior session"; a plain geometry
                           // undo should not reach across it, but if it is the only
                           // thing on the stack the user CAN undo the reset.
    ToolLifecycle = 1 << 8, // Alters tool-lifecycle state (tool exit/entry). Undoable
                            // (lands on the stack); cursor treats it as transparent when
                            // its own-gesture Model entry sits below it.
}

// Result of comparing a freshly-applied command against the command that
// currently sits on top of the undo stack. `Compatible` means the new command
// is a CONTINUATION of the previous one (same logical edit, same targets) and
// should be MERGED into the existing top entry rather than appended as a new
// step — so a run of repeated identical-target edits collapses to one undo.
// `Different` (the default for every command) means "append normally". Only
// commands that explicitly opt in by overriding compareOp() ever coalesce; the
// merge mechanism is driven by CommandHistory.recordCoalescing().
enum CompareResult { Different, Compatible }

class Command {
    // Internal command id (e.g. "mesh.bevel"). Used by the dispatcher.
    string name() const { return "Command"; }

    // TASK 1906 stage 0b — THE UNIVERSAL DELIVERY ANCHOR, and the reason this
    // method is `final` rather than the one commands override.
    //
    // Every caller still calls `apply()`; not one call site moved. What moved
    // is the OVERRIDE point: a command's kernel is `applyImpl()` now, so this
    // wrapper is the ONE place a delivery batch is opened and there is no way
    // for a command to be outside it. The production call sites are
    // `grep -rn '\.apply()' source --include=*.d` minus comment lines and
    // `unittest` blocks; no count or file list is quoted here because the last
    // one in this comment was wrong in both. None of them CAN bypass this
    // wrapper: `applyImpl()` is `protected` on the base and on every override,
    // so `apply()` is the only entry a caller outside the hierarchy has.
    //
    // WHY A WRAPPER AND NOT THE TOP OF A VIRTUAL `apply()`. An override
    // REPLACES the base body, and `grep -rn 'super\.apply'` over `source/` is
    // 0 — no override reached the base at all. So "put the pair at the
    // unconditional top of `Command.apply`" was unreachable code for the 148
    // commands in `source/` (plus three test doubles in `tests/`) that
    // implement their kernel as an override rather than as an
    // `Operator.evaluate` —
    // `grep -rn '^\s*protected override bool applyImpl()' source tests --include=*.d`
    // — including the four wholesale `*mesh = m` ones
    // (`SceneReset`, `MeshLoadRaw`, `FileLoad`, `MeshRemesh`). Stage 0's
    // anchor was the `Operator` branch below and it left exactly those
    // commands uncovered; the gap was bounded (a listener is dirty-bit-only
    // and idempotent, so N deliveries where 1 was wanted is a parity wart, not
    // a corruption) but it was also invisible, resting on the INCIDENTAL fact
    // that no override-`apply()` command loop-commits today.
    //
    // `final` is what makes the fix complete rather than merely intended: a
    // missed rename is "cannot override final function" at compile time, so
    // the build IS the completeness proof. Nothing enumerates commands
    // anywhere, and a command written next year is anchored the day it
    // compiles.
    //
    // A BARE DELIVERY PAIR, NOT THE HIDE-DERIVE PAIR — deliberate, and the two
    // are not interchangeable even though `beginHideDeriveBatch` opens a
    // delivery batch of its own (task 1906 review S3). The hide-derive pair
    // also arms `g_hideDeriveDeferSafe`, which DEFERS `refreshHiddenDerived`
    // to the batch close; hoisting it here would change WHEN the derive runs
    // for those 148 override-`applyImpl()` commands, none of which was measured
    // for task 1330 and none of which needs it (they commit once). Those
    // commands keep deriving eagerly, exactly as today, and only their DELIVERY
    // is coalesced. The hide-derive pair stays in the `Operator` branch below,
    // where it nests strictly inside this batch — which is also what makes
    // §1.4 (d)'s "delivery closes AFTER the derive flush" true BY
    // CONSTRUCTION here instead of by a LIFO `scope(exit)` convention.
    //
    // NO MESH IS CAPTURED AND NO `mesh is null` TEST GUARDS THE PAIR (task 1906
    // review S1). The batch is module state — `mesh.g_deliveryDepth` — and
    // neither the open nor the close reads a receiver, which is why the
    // module-level `beginDeliveryBatchGlobal` / `endDeliveryBatchGlobal` are
    // what this calls; `Mesh.beginDeliveryBatch` is a forwarder to the same
    // function. So there is nothing to capture, and skipping the batch when
    // this command's own `mesh` is null would be a HOLE, not a saving:
    // `tools/create/box.d :: BoxLiveEditCommand` is a shipped command
    // constructed `super(null, …)`, and a command that holds no mesh of its own
    // can still drive commits on one it reaches through a tool, a Document
    // layer or an inner command. `tests/unit/command_apply_anchor_test.d`'s
    // null-`mesh` block is the red for putting that test back.
    //
    // `revert()` is NOT wrapped by a `final`-style forwarder of its own — it
    // stays a plain virtual, same as `applyImpl()`. TASK 1932 (stage 1)
    // re-measured the "two undo paths differ in delivery granularity" claim
    // this comment used to make here and found it FALSE: every PRODUCTION
    // entry point that drives a `revert()` already holds a global delivery
    // batch of its own — `Command.apply` (this method, at its
    // `beginDeliveryBatchGlobal` below),
    // `CommandHistory.undo()` (`command_history.d:1091`), `.redo()`
    // (`:1208`) and `.fire()` (`:1507`) each open
    // `beginDeliveryBatchGlobal()` before running any `revert()` they own,
    // including `CompositeCommand.revert`'s child loop
    // (`command_history.d:232`), which nests inside the caller's batch
    // rather than opening its own. Nested opens coalesce by depth, so the
    // outcome is the SAME batch no matter how deep the revert call chain
    // runs.
    //
    // So there is no asymmetry between "wrapped registered `history.undo`
    // command" and "raw `/api/undo` / `navHistory` call" — all THREE
    // production callers of `history.undo()` (`/api/undo` via
    // `http_providers.d:3179`, `app.d`'s `navHistory` via
    // `edit_session.d:430`, and `BoxTool.cancelUncommittedEdit`'s undo
    // ladder via `tools/create/box.d:306`) land inside the same batch
    // `undo()` opens, exactly like the registered `HistoryUndo.applyImpl()`
    // calling `history.undo()` from inside `Command.apply`'s own batch.
    // Every undo/redo/re-fire step delivers exactly once. Counter-evidence
    // the batches put in place: before `undo()` held this batch, a
    // 3 000-edge `mesh.remove` delivered 3 003 times on UNDO — one per
    // `selectEdge` the tracker's delta replay drives — and before `fire()`
    // held it, a re-fire's revert delivered 3 005 times the same way;
    // both are 1 today (`tests/test_bus_delivery_granularity.d` blocks
    // (7)/(8)). `redo()` never calls `revert()` in production (it replays
    // forward through `cmd.apply()`), so its pre-fix count was already 1 —
    // it holds the batch for uniformity with the other two, not because it
    // showed the per-element shape.
    //
    // Benign today either way: listeners are dirty-bit-only and idempotent,
    // and an OR over a whole undo step is what they would compute anyway.
    // One consequence is worth naming — inside any of these batches,
    // `deliverPending`'s "a layer unlinked between a deferring commit and
    // the batch close" drop window spans a WHOLE undo/redo/re-fire step
    // everywhere, not on some asymmetric subset of paths. Not live:
    // `commands/layer/commands.d` contains no `commitChange` at all, so no
    // layer lifecycle command defers anything into that window.
    // TASK 1906 STAGE 3 — THE CLOSE ALSO OFFERS THIS COMMAND'S OWN MESH, and
    // that is what lets the per-frame drain go.
    //
    // The batch close delivers every mesh that REGISTERED itself, and a mesh
    // registers only through `deliverPending` — i.e. only if some publisher
    // inside the command called `publishChange` / `commitChange`. A command
    // whose publishers are all accumulate-only (`noteChange`,
    // `noteSelectionChange`) therefore delivered NOTHING, and reached the bus
    // only through the frame drain of `Mesh.pendingChanges_`. Measured on the
    // live app, one command per `/api/reset`: `select.invert` and
    // `select.byStat.{vertex,edge,polygon}` each moved `deliveryCount` by 0
    // while moving `flushCount` by 1 and `totalMarks` by 1.
    //
    // TASK 1932 (stage 3): this anchor and the per-writer `deliverPending`
    // calls on the six scalar setters / three bulk `clear*` / `applySelectedFrom_`
    // (`mesh.d`) are REDUNDANT on `select.invert`-shaped commands but not on
    // each other — measured with four isolated single-line removals, each
    // read against a full `dub test --config=tests` pass (282 modules).
    // Removing THIS anchor alone reddens exactly one cell,
    // `tests/unit/command_apply_anchor_test.d`'s `NoteOnlyProbe` (delta 0
    // instead of 1) — nothing else moves, because every other command's tail
    // is a real publisher already registered in the batch. Removing a
    // writer's own `deliverPending()` reddens `tests/unit/change_bus_test.d`'s
    // matching clause every time, and once (the six scalar setters) it ALSO
    // reddens a second, unrelated cell, `tests/unit/subpatch_osd_test.d`'s
    // RIG premise — a caller at delivery depth 0 outside any batch, the same
    // shape `source/symmetry_pick.d`'s own doc comment names as "the Topology
    // Pen's undo path". A caller INSIDE a batch is unaffected by a writer's
    // own `deliverPending()` regardless — `symmetry_pick.d`'s
    // `symmetricSelectVertex` is itself a THIRD delivery boundary
    // (`mesh.beginDeliveryBatch()` / `deliverAccumulated()` at every return),
    // wrapping every click and paint-stroke pick, so a paint stroke's
    // delivery count is untouched by the scalar setters' own calls — measured
    // directly (`tests/test_bus_delivery_granularity.d` block (6) stays green
    // under the same mutation that reddens the two unit cells above). If the
    // anchor and the writers are ever collapsed to one mechanism, delete THIS
    // anchor, not the writers — the writers are what a caller outside every
    // batch depends on, and this anchor covers only what already reaches a
    // batch close another way.
    //
    // The offer is made HERE rather than in seventeen selection commands for
    // the same reason `apply()` is `final`: a command written next year is
    // anchored the day it compiles. It costs nothing when there is nothing to
    // say (`deliverPending` returns on two empty words) and it cannot double a
    // delivery — inside the batch it only REGISTERS, and `noteDeliveryPending`
    // dedupes by pointer, so a command that already published still delivers
    // exactly once, at the close.
    //
    // A null `mesh` is skipped and that is a NAMED gap, not an oversight: a
    // command that holds no mesh of its own (`BoxLiveEditCommand`, constructed
    // `super(null, …)`) can still drive commits on one it reaches through a
    // tool or a Document layer — those commits deliver on their own, register
    // themselves, and ride the same close. What is not covered is a null-mesh
    // command whose ONLY publisher is accumulate-only; none exists today.
    final bool apply() {
        beginDeliveryBatchGlobal();
        scope(exit) {
            if (mesh !is null) mesh.deliverAccumulated();
            endDeliveryBatchGlobal();
        }
        return applyImpl();
    }

    // Run the operation. Two paths post-Phase-6:
    //
    //   * Operator commands (mesh-mutating ones from Phases 2/5) put
    //     their kernel in `evaluate(ref VectorStack vts)`. The default
    //     applyImpl() here builds a minimal vts from the command's mesh +
    //     editMode + selection state and dispatches via the Operator
    //     interface, preserving the bool-return contract for callers
    //     (history.fire, app.d /api/command).
    //
    //   * Non-Operator commands (file load/save, history meta-commands,
    //     selection ops) override applyImpl() with their kernel as before.
    //
    // Mutating commands snapshot pre-state into instance fields so
    // revert() can restore.
    //
    // THE OVERRIDE POINT, and the only one: `apply()` above is `final`. A
    // command overrides THIS.
    //
    // EVERY OVERRIDE SPELLS `protected` TOO, and that is not decoration (task
    // 1906 review NIT1). D lets an override WIDEN protection, and an
    // unqualified `override bool applyImpl()` inside a class whose default is
    // public IS a widening: on that concrete type the kernel becomes callable
    // from anywhere, and a caller who reached for it would skip the delivery
    // batch that `apply()` is `final` in order to guarantee. Keeping every
    // override at `protected` is what makes "there is no way for a command to
    // be outside the batch" true of the CONCRETE types and not only of the
    // base. `grep -rn 'applyImpl(' source tests --include=*.d` outside this
    // file is comments only.
    protected bool applyImpl() {
        import operator        : Operator, VectorStack;
        import toolpipe.packets : SubjectPacket;
        if (auto op = cast(Operator)this) {
            // TASK 0654 — THE mesh-write refusal, for every Operator command at
            // once. An empty item selection means there is no mesh edit target,
            // and an operator kernel has nothing to write to. Refusing HERE
            // rather than in ~200 kernels is what makes the rule impossible to
            // forget in the next one: every mesh-mutating command in the build
            // reaches its kernel through this branch.
            //
            // Gated on the RESOLVER, not on `mesh is null`: the command
            // factories bind `&app.mesh()`, which is a pointer to the empty
            // read-only stand-in (`document.noEditTargetMesh`) rather than null,
            // so the pointer alone cannot tell "no target" from "empty mesh" —
            // and an empty mesh is a perfectly legal edit target that must keep
            // working (`layer.add` then `mesh.*` on the fresh layer).
            //
            // Uninstalled resolver (headless unit tests that construct a
            // command directly over a local `Mesh`) means "there is a target":
            // those callers own the mesh they passed and never went through a
            // Document at all.
            //
            // TASK 0669 — the condition itself now lives in
            // `refusedForNoEditTarget()` / `needsEditTarget()` so the BUTTON can
            // ask it before the press. Same test, same reason, one copy.
            if (refusedForNoEditTarget()) return false;
            // TASK 1330 — one hide-derive per COMMAND, not per appended
            // element. `Mesh.commitChange` refreshes the derived hidden
            // planes on every geometry commit, and the per-element mutators
            // commit per element (`addEdge` per edge, `addFace` per face), so
            // a bulk kernel paid one full-mesh pass per element: measured
            // exponent ~2.0 on a 100K grid (per-face bevel 74 s, poly_inset
            // 72 s, edge_extrude 66 s), and 40-60x worse again with a single
            // face hidden, when the word-OR early-out stops firing.
            //
            // This branch is the right place precisely BECAUSE of the refusal
            // above it: it is the one gate every mesh-mutating Operator
            // command reaches its kernel through. A command is also exactly
            // the granularity the derive needs — nothing reads the derived
            // planes between two appends of one command, and the batch runs
            // the (unchanged, still-fresh-reading) refresh once at the end.
            //
            // The pointer is captured so the exit hook cannot close a
            // DIFFERENT mesh than the one it opened.
            //
            // TASK 1906 — THIS PAIR IS ALSO THE DELIVERY BOUNDARY, and there is
            // deliberately no second pair beside it.
            //
            // `beginHideDeriveBatch` opens a delivery batch and
            // `endHideDeriveBatch` closes it after its derive flush
            // (`source/mesh.d`, review S3), so one command that moves 8 vertices
            // or appends 400 faces produces exactly ONE synchronous delivery,
            // and that delivery lands after the derived hide planes are current.
            // An earlier cut of this task put a second `beginDeliveryBatch` /
            // `scope(exit) endDeliveryBatch` pair immediately above this one and
            // relied on `scope(exit)` being LIFO to order the two closes — a
            // contract a reader could break by tidying two adjacent blocks, and
            // one that the eight `beginHideDeriveBatch` call sites in `mesh.d`
            // did not honour at all.
            //
            // THIS IS NO LONGER THE ANCHOR (stage 0b, 2026-08-25). It used to
            // be — and as the `Operator` branch it left the 148 commands that
            // implement their kernel as an override outside any delivery batch.
            // The template-method split closed that gap: `final apply()` above
            // opens the OUTERMOST delivery batch for EVERY command, and this
            // pair now nests strictly inside it.
            //
            // DO NOT DELETE THE PAIR — and the reason is TASK 1330, not anybody
            // else's dependency on this call. The `beginHideDeriveBatch` sites
            // in `mesh.d` open their own batch; nothing outside this branch
            // relies on this one. What it does is arm the hide-derive DEFERRAL
            // (`g_hideDeriveDeferSafe`), so an Operator that appends N faces
            // runs ONE whole-mesh `refreshHiddenDerived` instead of N — the
            // measured root cause recorded above. Removing this call reddens
            // `tests/unit/command_hide_derive_test.d`, in those words:
            // "mesh.spikey: hide-derives per ONE apply grew with the mesh
            // ([66, 258, 1026] at [16, 64, 256] faces respectively). That is
            // task 1330's root cause verbatim — a full-mesh derived-plane
            // refresh per appended element instead of per command."
            //
            // Its close is also what brings the derived hide planes up to date
            // before the OUTER batch delivers; the delivery batch it opens of
            // its own (review S3) is now the inner one and is harmless — the
            // depth counter composes.
            Mesh* hideBatchMesh = mesh;
            if (hideBatchMesh !is null) {
                hideBatchMesh.beginHideDeriveBatch();
            }
            scope(exit) if (hideBatchMesh !is null) hideBatchMesh.endHideDeriveBatch();
            VectorStack vts;
            SubjectPacket subj;
            // The CURRENT selection type, from the app's live authority when
            // one is wired (see `currentType()` and THE RULE above it). This
            // is the command layer's half of the same answer app.d publishes
            // into its own SubjectPacket via `buildToolVts`; the two layers
            // now read one authority instead of two.
            //
            // The camera the operator evaluates against (task 0619). An
            // `Operator`'s `evaluate` can only see the viewport this packet
            // carries, and the pixel-space falloff types read it through
            // `aimSpace` — so leaving it default-constructed here made the
            // SAME operator answer differently depending on which entry point
            // fired it: a real camera down the toolpipe (app.d's
            // `buildToolVts`), an UNINITIALISED one down `/api/command`
            // (`Viewport`'s matrices carry no initialiser, so the default is
            // NaN, not zero — every product through it is NaN). No
            // live divergence resulted (the JSON parser rejects the pixel
            // falloff types, and the tool path records a positional edit
            // rather than the command, so redo cannot diverge either), but
            // the invariant "a packet handed to `aimSpace` carries a real
            // viewport" should hold on EVERY path, not on the one that
            // happened to be exercised.
            //
            // `effectiveViewport()` is the command layer's sole camera
            // accessor — the same call `MeshSelect`/`MeshTransform` already
            // make two files away when they build a SubjectPacket by hand —
            // so this adds no authority and widens no contract. Its
            // no-provider fallback dereferences `view`, which a directly
            // constructed headless command may leave null; that one case
            // keeps the field's default (width 0 / NaN matrices, which
            // every viewport-dependent stage already treats as "invalid,
            // early out") instead of crashing. Guard and fallback preserved
            // verbatim (task 1904 Stage 3): `SubjectSource.viewport` simply
            // stays `Viewport.init` when `view is null`, matching the old
            // "leave the field's default" branch exactly.
            import toolpipe.subject : SubjectSource, fillSubject;
            Viewport vp = (view !is null) ? effectiveViewport() : Viewport.init;
            fillSubject(subj, SubjectSource(mesh, editMode, currentType(), vp));
            vts.put(&subj);
            return op.evaluate(vts);
        }
        return true;
    }

    // Restore the pre-apply mesh/selection/state. Default: not undoable.
    // Mutating commands override and return true on success.
    //
    // AN OVERRIDE MEANS "THIS COMMAND IS UNDOABLE". Task 0705 deleted 41
    // overrides that were a bare `return false;` — the default, retyped. They
    // cost nothing at runtime and a real amount at reading time: with them
    // present, "does this class override revert()?" answered nothing, so the
    // question a reader actually has (is this command on the undo stack?) had
    // to be re-answered by reading each body. Do not restate the default here;
    // silence is the statement.
    bool revert() { return false; }

    // WHY the last apply() returned false, in one clause — or "" when the
    // command has nothing to add beyond "it declined". The dispatch funnel
    // (app.d's applyOrRefire) appends it to the generic
    // "command 'x' did not apply" it throws, so a script / HTTP / panel caller
    // is told WHICH argument it got wrong instead of only that something was.
    //
    // Empty by default, and the appended message is byte-identical to the old
    // one for every command that does not override this — opting in is per
    // command, and worth it exactly where a command refuses for several
    // different reasons (a bad index vs. an unreadable path vs. a row of the
    // wrong kind all read the same otherwise). A command that overrides it
    // owes the reason a reset at the top of apply(): the value must describe
    // the LATEST call, since a command object can be applied more than once
    // (redo, re-dispatch).
    // Task 0654: the BASE applyImpl() has a refusal of its own now (no edit
    // target), so the default is no longer the empty string but whatever the
    // base recorded on the latest call. Commands that override applyImpl()
    // never reach the base branch, so this stays "" for them unless they also
    // override this method; commands that override BOTH keep their own reason,
    // which is correct — they did not go through the base refusal either.
    protected string baseRefusal_;

    string refusalReason() const { return baseRefusal_; }

    // TASK 0669 — does running this command require a mesh edit target?
    //
    // THE POINT: this is the SAME question `apply()` asks, asked WITHOUT
    // running the command, so a button can be drawn unavailable BEFORE the
    // press instead of the press being the only way to find out. 0654 made the
    // refusal correct and left it invisible: the button looked exactly like a
    // working one.
    //
    // The default answer is derived from the command's own TYPE — an
    // `Operator` command reaches its kernel through the base `applyImpl()`
    // above and is refused there, so `needsEditTarget` is exactly "am I an
    // Operator". Nothing enumerates command NAMES anywhere: a new mesh
    // operator is covered the day it is written, and a list that could drift
    // from behaviour is never created (which is the whole reason this is a
    // method on `Command` and not a `requires:` key in `config/buttons.yaml`).
    //
    // Override it when a command writes the mesh through an `applyImpl()` of
    // its own and therefore never reaches the base branch — `ToolHeadlessCommand`
    // is the one such case in the build (it runs a Tool's `applyHeadless()`
    // against `*mesh`), and it pairs the override with the
    // `refusedForNoEditTarget()` guard below. An override that ADDS the
    // requirement without the guard would make the button lie in the other
    // direction: grey, but working.
    //
    // MUST BE A TYPE PROPERTY, NOT LIVE STATE. `Registry.cacheSupportedModes`
    // snapshots this off one COLD instance per registered id at startup (the
    // same walk that caches `supportedModes()` / `params()`, and for the same
    // reason: a factory call is GL work that may not happen on the HTTP
    // thread). A state-dependent answer would stale that cache.
    bool needsEditTarget() const {
        import operator : Operator;
        return (cast(const(Operator)) this) !is null;
    }

    // TASK 1521 — does running this command THROW AWAY unsaved work?
    //
    // THE POINT: the guard is a property of the ACTION, not a list of command
    // names kept somewhere else. Before this, exactly one path asked
    // `docDirty()` — the quit confirm (0434) — so File → New and File → Open
    // replaced the document in silence. A fourth such path already existed
    // when this was written (`file.import.*`, which is the same `FileLoad`),
    // which is the whole argument for putting the question on the command
    // rather than on each call site.
    //
    // NOT NAMED "replaces the document": quitting replaces nothing, and the
    // question is the same one — "is unsaved work about to become
    // unreachable". Declared `true` by `SceneReset` (file.new / scene.reset),
    // `FileLoad` (file.open / file.import.*), `MeshLoadRaw` and `FileQuit`.
    //
    // MUST BE A TYPE PROPERTY, NOT LIVE STATE, for the same reason
    // `needsEditTarget` must: `Registry.cacheSupportedModes` snapshots it off
    // one COLD instance per registered id at startup, and a state-dependent
    // answer would stale that cache.
    //
    // The declaration is checked against BEHAVIOUR, in both directions, by
    // `tests/test_discard_census.d`: a command whose result does not depend on
    // what the document held before it threw the work away, and the census
    // fails an undeclared one AND a declared one it could not make discard.
    bool discardsUnsavedWork() const { return false; }

    // The refusal a mesh-writing command owes when there is no edit target,
    // as a guard any `apply()` can open with. Returns true when the command
    // must decline — and records the reason, so the dispatch funnel's message
    // and the disabled button's tooltip read the same sentence.
    //
    // Uninstalled resolver means "there is a target" (see `g_editTargetResolver`).
    protected final bool refusedForNoEditTarget() {
        if (needsEditTarget()
            && g_editTargetResolver !is null && !g_editTargetResolver()) {
            baseRefusal_ = kNoEditTargetReason;
            return true;
        }
        baseRefusal_ = "";
        return false;
    }

    // Classify the command. BASE default is CmdFlags.Model — most
    // commands alter scene state and are therefore undoable. Read-only /
    // view-only / transient commands override this to drop Model (and
    // pick UI or SideEffect as appropriate).
    CmdFlags cmdFlags() const { return CmdFlags.Model; }

    // Whether this command should land on the undo stack after a
    // successful apply(). Layered, in priority order:
    //
    //   1. UndoSuppress  → false (explicit opt-OUT always wins, even over a
    //                      Model bit — author takes responsibility).
    //   2. UndoForce     → true  (explicit opt-IN; lands a command that carries
    //                      neither Model nor UiState).
    //   3. derived       → (Model | UiState) != 0 — the default from P5: a
    //                      command is undoable iff it alters scene/document
    //                      state (Model-undo class) OR undoable UI state
    //                      (UiState, the UI-undo class).
    //
    // UndoForce/UndoSuppress are GENUINE special cases the derived rule cannot
    // express — NOT patches over a mis-derived rule (audit 0062 B5 re-verified,
    // task 0070): a transient tool-preview edit (e.g. BoxLiveEditCommand,
    // box.d) is correctly SideEffect (mutates no committed mesh) yet must be
    // Ctrl+Z-steppable → UndoForce. UndoSuppress is its dual (a Model mutation
    // the author marks unrecoverable). `box.d`'s BoxLiveEditCommand is the one
    // production UndoForce user; UndoSuppress has only test users today but is
    // kept as the legitimate opt-out. Do NOT remove these by "fixing" the rule —
    // reclassifying box to Model would be factually wrong (and wouldn't even
    // change its T-SEP cursor class, which is already Model via Undoable&&!UiUndo).
    final bool isUndoable() const {
        CmdFlags cf = cmdFlags();
        if (cf & CmdFlags.UndoSuppress) return false;
        if (cf & CmdFlags.UndoForce)    return true;
        return (cf & (CmdFlags.Model | CmdFlags.UiState | CmdFlags.ToolLifecycle)) != 0;
    }

    // Which undo CLASS this command belongs to once it lands on the stack.
    // UI-undo (selection / edit-mode state) is undoable but distinct from
    // Model-undo (geometry). A command is UI-undo iff it carries UiState and
    // NOT Model (a command touching real geometry stays Model-class even if it
    // also nudges selection — Model dominates). History/panel/tests read this
    // to tell the two classes apart; Ctrl+Z behavior is identical for both.
    final bool isUiUndo() const {
        CmdFlags cf = cmdFlags();
        return (cf & CmdFlags.UiState) != 0 && (cf & CmdFlags.Model) == 0;
    }

    // Short human-readable label. Defaults to name() — override for a
    // friendlier menu / history-viewer string.
    string label() const { return name(); }

    // Coalescing predicate (op-merge analog). Called by
    // CommandHistory.recordCoalescing() with `prev` = the command on top of
    // the undo stack. Return Compatible iff `this` is a continuation of `prev`
    // that should merge into the existing top entry (so consecutive compatible
    // edits become ONE undo step). Default: Different — no command coalesces
    // unless it overrides this. A Compatible verdict obliges the command to
    // also implement an in-place merge (e.g. mergeFrom()) that the history
    // invokes on `prev`.
    CompareResult compareOp(const Command prev) const {
        return CompareResult.Different;
    }

    // In-place merge of a newer, COMPATIBLE command into THIS (the existing
    // top undo entry), invoked by CommandHistory.recordCoalescing() right after
    // compareOp() returned Compatible. The contract: keep THIS entry's pre-state
    // (the state before the FIRST command of the run) and adopt `newer`'s
    // post-state, so the coalesced entry's revert() unwinds the whole run and
    // its apply()/redo lands the latest result. The dispatcher has ALREADY
    // applied `newer`, so the mesh holds the merged post-state — do not mutate
    // here. Return true on a successful merge. Default false: a command that
    // never returns Compatible from compareOp() never needs to override this.
    // (Type-erased base hook so the history module stays command-type-agnostic;
    // each coalescing command downcasts `newer` to its own type.)
    bool mergeFrom(Command newer) { return false; }

    // Change-scope metadata (doc/undo_change_tracker_plan.md, Phase 4 §b).
    // Declares which classes of mesh state an op touches via a scope bitfield.
    // Default None — most commands do
    // not carry topology-scope provenance. The delta-backed migrated commands
    // (edge extrude / delete / remove / dissolve) override it to Geometry|Marks.
    // Lightweight metadata only: no speculative consumer machinery is built — the
    // history panel may surface it, but nothing depends on it yet.
    MeshEditScope editScope() const { return MeshEditScope.None; }

    // Whether this command's undo is stored as an OPERATION INVERSE (a per-mutation
    // MeshEditDelta / op-log replayed LIFO) rather than a whole-mesh MeshSnapshot
    // pair (parent plan P3 formalization). Default false — snapshot-backed. The
    // delta-backed commands override → true. Marker/metadata only.
    bool isOperationInverse() const { return false; }

    // Schema: list of parameters. Default: none. Commands that surface
    // an args dialog or accept JSON params via /api/command override this.
    Param[] params() { return []; }

    // Called immediately before opening an args dialog. Override to set
    // defaults that depend on the current selection / scene state.
    void dialogInit() {}

    // Called by the renderer after a parameter value changes. Override
    // to recompute dependent parameters (cross-field rules).
    void onParamChanged(string name) {}

    // Whether the named parameter widget should be enabled. Override for
    // cross-field graying (arg-enable callback).
    bool paramEnabled(string name) const { return true; }

    // Per-parameter hint overrides at runtime (e.g. cap a range to mesh
    // size).
    void paramHints(string name, ref ParamHints hints) {}

    // Edit modes in which this command makes sense. The status-bar /
    // side-panel button auto-disables when the current `editMode` is
    // not in this list — visual cue that the row is "available but
    // not in this mode". `apply()` may also throw defensively (e.g.
    // mesh.subdivide enforces Polygons inside apply too). Default:
    // every mode — most commands are mode-agnostic.
    EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        this.mesh = mesh;
        this.view = view;
        this.editMode = editMode;
    }

    // Read-only accessors to the construction context. Needed so a wrapper
    // command in another module (e.g. CompositeCommand in command_history.d)
    // can forward another command's mesh/view/editMode into the base ctor —
    // `protected` fields are only reachable on `this`, not on a sibling
    // instance across module boundaries.
    final Mesh*    meshPtr() { return mesh; }
    final ref View viewRef() { return view; }
    final EditMode editModeVal() const { return editMode; }

    // -----------------------------------------------------------------------
    // THE RULE (task 0621) — which question a command asks about selection
    // -----------------------------------------------------------------------
    // A command that branches on "which kind of thing is the user selecting
    // right now" asks `currentType()`. It NEVER reads `editMode` for that
    // question.
    //
    // WHY the two are not interchangeable: `editMode` is a MATERIALIZED VIEW
    // of the geometry part of the selection type (source/seltype.d). Under
    // `SelType.Item` it deliberately RETAINS the most-recent geometry type
    // rather than clearing, so geometry picking and drawing always have a
    // defined mode. That is correct for picking and wrong for a command: with
    // an item selected the user sees NO geometry selection on screen, while
    // `editMode` still reads `Polygons` and the stale face selection from
    // before the switch is still in the mesh. A command that branches on
    // `editMode` therefore acts on geometry the user cannot see and did not
    // choose. app.d's Tab handler already asks `currentSelType(selTypeOrder)`;
    // before this rule the command layer asked the derivative, so the two
    // layers answered the same question differently and every new command was
    // a coin flip about which one it copied.
    //
    // The consequence that falls out, and the reason no command needs its own
    // Item branch: under `SelType.Item` no geometry type is current, so THERE
    // IS NO CURRENT GEOMETRY SELECTION — a geometry-scoped command sees the
    // selection as EMPTY and takes whatever it already does for "nothing
    // selected" (usually: operate on the whole mesh).
    //
    // THE ONE EXCEPTION, named so the next reader does not "fix" it: a
    // command that is asking "which geometry PLANE do I read/write", not
    // "what is the user selecting", legitimately keeps `editMode` — that is
    // exactly what the view is for, and it must stay defined under Item. The
    // commands that WRITE the mode through `editModePtr` (select.typeFrom,
    // select.convert, select.fill, mesh.select, scene.reset, scene.loadMesh,
    // mesh.selectionEdit) are all of this kind: they are establishing the
    // geometry type, not reacting to it, and they route their write through
    // app.d's geometry-type funnel which updates the order. Reading the
    // REMEMBERED type on purpose is legitimate there and nowhere else so far;
    // if you add such a command, say in a comment that you meant it.
    //
    // Mechanism: the app wires one live provider onto every registered
    // command factory (registration.d), so this is the same authority the
    // toolpipe's SubjectPacket carries. Operator commands can equivalently
    // read `subj.selType` off the packet they already hold — `applyImpl()` above
    // stamps it from here.
    //
    // HAZARD, for whoever makes a WRAPPED command type-aware: the provider is
    // setter-injected onto the instance the FACTORY returned, so a command
    // that builds another command inside itself (CompositeCommand, the
    // copilot cycle/select pair, the vertex-edit and layer-xform run merges,
    // the layer-delete an image command delegates to) hands the inner
    // instance mesh/view/editMode and NOT the provider — the inner one
    // silently takes `currentType()`'s fallback. That is inert today because
    // no wrapped command branches on the current type; the moment one does,
    // forward the provider explicitly (`inner.setSelTypeProvider(...)`)
    // rather than assuming construction carried it.

    // Install the live selection-type authority. Called by the app's command
    // registration for EVERY registered factory, never by a command itself —
    // same injection shape as `setResolvedVpProvider`. `final` so no override
    // can bypass `currentType()`.
    final void setSelTypeProvider(SelType delegate() provider) {
        selTypeSrc_ = provider;
    }

    // The CURRENT selection type — the sole accessor a command body should
    // use to ask "what is the user selecting right now".
    //
    // Falls back to `geometrySelType(editMode)` when no provider is wired.
    // That fallback is EXACTLY the pre-0621 behaviour (it re-derives the type
    // from the captured mode), so an unwired command — a unittest that
    // constructs the class directly, a standalone/headless caller — behaves
    // bit-identically to before and the change's blast radius is confined to
    // the wired path. It is a compatibility shim, not a second authority: the
    // production path always has the provider, because registration.d wraps
    // every factory rather than opting commands in one at a time (opting in
    // per command is what let the two layers drift apart in the first place).
    protected final SelType currentType() {
        if (selTypeSrc_ !is null) return selTypeSrc_();
        return geometrySelType(editMode);
    }

    // Injection point for the follow-resolved viewport snapshot (viewport
    // camera single-source, doc/tasks/work/0181). Nullable delegate set by a
    // command factory right after construction (app.d), never by the command
    // itself. `final` so no override can bypass `effectiveViewport()`.
    final void setResolvedVpProvider(Viewport delegate() provider) {
        resolvedVpProvider = provider;
    }

    // The SOLE accessor a command body should use to obtain a camera
    // snapshot for screen-space math (camera-plane cuts, symmetry-packet
    // capture, workplane picks). Prefers the injected resolved-snapshot
    // provider; falls back to the cell's RAW OWN transform inputs
    // (`view.viewportWith(view.focus, ...)` — exactly what `view.viewport()`
    // computes, minus the write-back) when no provider was set.
    //
    // HAZARD: the null-provider fallback is the cell's raw own snapshot —
    // on a linked-follower cell that is precisely the wrong answer (it
    // ignores `resolveFollow`'s focus/distance/az/el substitution), which is
    // the mechanism behind the follower-cell mispick this task removes. The
    // fallback is safe here ONLY because every command that calls this
    // (`MeshScreenSlice` / `MeshSelect` / `MeshTransform`) is `new`'d in
    // exactly ONE place — its factory delegate in app.d's `run()` — and that
    // factory sets `resolvedVpProvider` immediately after construction, so
    // production code never takes the null branch (it fires only in a
    // headless/standalone unit where "own" already equals "resolved", e.g.
    // no active viewport manager). Do not add a second construction site for
    // these commands without also wiring the provider, and do not read
    // `resolvedVpProvider` directly anywhere but here.
    protected final Viewport effectiveViewport() {
        if (resolvedVpProvider !is null) return resolvedVpProvider();
        return view.viewportWith(view.focus, view.distance, view.orientation);
    }

protected:
    Mesh* mesh;
    View view;
    EditMode editMode;

private:
    // Live "current selection type" authority (task 0621). Null until the
    // app's command registration injects it; read ONLY through
    // `currentType()`, which owns the null fallback.
    SelType delegate() selTypeSrc_;
    Viewport delegate() resolvedVpProvider;
}

// ---------------------------------------------------------------------------
// Task 0619 — the packet `Command.applyImpl()` builds carries a REAL camera.
//
// `SubjectPacket.viewport` is the only camera an `Operator`'s `evaluate` can
// see, and four operator commands (`mesh.jitter`, `mesh.quantize`,
// `mesh.smooth`, `MeshMagnet`) now read it through `aimSpace`. The toolpipe
// path fills it (app.d's `buildToolVts`); this path used to leave it
// default-constructed, so the same operator saw a real camera or an all-NaN
// one depending on who fired it.
//
// VERIFIED BY MUTATION, twice:
//   * replacing `Command.applyImpl`'s
//     `Viewport vp = (view !is null) ? effectiveViewport() : Viewport.init;`
//     ternary with an unconditional `Viewport vp = Viewport.init;` — i.e.
//     the code as it behaved before this fix — gives "Command.apply() must
//     publish the live camera onto the subject packet: got width=0, want
//     width=800";
//   * dropping only the `view !is null` guard in front of it (always taking
//     the `effectiveViewport()` branch) kills the process with SIGSEGV
//     (exit 139) on the second case below, which is why that case exists:
//     without it the guard is dead weight nobody reaches.
// ---------------------------------------------------------------------------
version (unittest) {
    import operator         : Operator, VectorStack, OperatorActrCommon,
                              Task, PacketKind;
    import toolpipe.packets : SubjectPacket;

    /// A terminal Operator that mutates nothing and reports the packet the
    /// base `applyImpl()` handed it.
    private class SubjectEchoOp : Command, Operator {
        SubjectPacket seen;
        bool          sawSubject;

        this(Mesh* mesh, ref View view, EditMode editMode) {
            super(mesh, view, editMode);
        }
        override string name() const { return "test.subjectEcho"; }

        mixin OperatorActrCommon;
        bool evaluate(ref VectorStack vts) {
            if (auto s = vts.get!SubjectPacket()) {
                seen = *s;
                sawSubject = true;
            }
            return true;
        }
    }
}

unittest {
    import view       : View;
    import math       : Vec3, lookAt, perspectiveMatrix;
    import std.math   : PI, isNaN;
    import std.format : format;

    Mesh m;
    auto v = new View(0, 0, 800, 600);
    auto op = new SubjectEchoOp(&m, v, EditMode.Vertices);

    // The camera the app would resolve for this command. Deliberately not the
    // default: a default-constructed Viewport has NaN matrices and width 0,
    // which is what the unplumbed code published.
    Viewport want;
    immutable Vec3 eye = Vec3(4.0f, 3.0f, 9.0f);
    want.view   = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    want.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 800.0f / 600.0f,
                                    0.01f, 100.0f);
    want.width  = 800; want.height = 600;
    want.eye    = eye; want.focus  = Vec3(0, 0, 0);
    op.setResolvedVpProvider(() => want);

    // Vacuity guard: the fixture camera must differ from the default in the
    // fields asserted below, or the case could not distinguish the two.
    assert(want.width != Viewport.init.width,
        "vacuous fixture: the probe camera's width equals the default's");
    assert(isNaN(Viewport.init.view[0]),
        "vacuous fixture: a default Viewport's matrix is expected to be "
        ~ "uninitialised (float.init), so a plumbed one is unmistakable");

    assert(op.apply(), "the echo operator applies");
    assert(op.sawSubject, "apply() must have dispatched through evaluate()");

    assert(op.seen.viewport.width == want.width
        && op.seen.viewport.height == want.height,
        format("Command.apply() must publish the live camera onto the "
               ~ "subject packet: got width=%d, want width=%d",
               op.seen.viewport.width, want.width));
    foreach (i; 0 .. 16)
        assert(op.seen.viewport.view[i] == want.view[i],
            format("subject packet view matrix element %d diverged: got %f, "
                   ~ "want %f", i, op.seen.viewport.view[i], want.view[i]));
}

unittest { // ...and a command with no View does not crash trying.
    // `effectiveViewport()`'s no-provider fallback dereferences `view`. A
    // headless/direct construction may leave it null (see
    // commands/test_undo_flags.d, which does exactly that), so the plumb is
    // guarded — and the packet then keeps the documented default rather than
    // taking down the process.
    import std.math : isNaN;

    Mesh m;
    View nullView;
    auto op = new SubjectEchoOp(&m, nullView, EditMode.Vertices);

    assert(op.apply(), "a View-less operator command still applies");
    assert(op.sawSubject, "apply() must still dispatch through evaluate()");
    assert(op.seen.viewport.width == 0 && isNaN(op.seen.viewport.view[0]),
        "with no View and no provider the packet keeps its documented "
        ~ "default, which every viewport-dependent stage already refuses");
}

// ---------------------------------------------------------------------------
// RunMergeable — task 0614 Phase 4 (doc/item_mode_transform_plan.md, §Undo).
//
// A command that can absorb the LATER commands of the same in-session run
// into itself, so `CommandHistory.consolidate` can collapse the run into ONE
// surviving entry. `this` is the run's EARLIEST entry (it owns the run-start
// `before`); `later` are the rest of the run, oldest -> newest. Return the
// merged command to splice in at the run's position, or `null` to decline —
// a decline leaves the stack untouched, exactly like an unrecognized command
// type falling through `consolidate`'s existing `MeshVertexEdit` arm.
//
// `consolidate()` tries this arm only after the `MeshVertexEdit` arm has
// declined (the gathered run is not all `MeshVertexEdit`), so an ordinary
// vertex-edit run is byte-identical to before this interface existed.
// `LayerXformEdit` (commands/layer/xform_edit.d) is the one production
// implementer today.
// ---------------------------------------------------------------------------
interface RunMergeable {
    Command mergeRunTail(Command[] later);
}
