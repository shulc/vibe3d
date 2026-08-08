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

// ---------------------------------------------------------------------------
// Command — base class for every user-visible action.
//
// Undo/redo model (see doc/undo_redo_plan.md):
// - apply()    — runs the operation. Mutating commands MUST snapshot
//                pre-state into instance fields here.
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

    // Run the operation. Two paths post-Phase-6:
    //
    //   * Operator commands (mesh-mutating ones from Phases 2/5) put
    //     their kernel in `evaluate(ref VectorStack vts)`. The default
    //     apply() here builds a minimal vts from the command's mesh +
    //     editMode + selection state and dispatches via the Operator
    //     interface, preserving the bool-return contract for callers
    //     (history.fire, app.d /api/command).
    //
    //   * Non-Operator commands (file load/save, history meta-commands,
    //     selection ops) override apply() with their kernel as before.
    //
    // Mutating commands snapshot pre-state into instance fields so
    // revert() can restore.
    bool apply() {
        import operator        : Operator, VectorStack;
        import toolpipe.packets : SubjectPacket;
        if (auto op = cast(Operator)this) {
            VectorStack vts;
            SubjectPacket subj;
            subj.mesh     = mesh;
            subj.editMode = editMode;
            // The CURRENT selection type, from the app's live authority when
            // one is wired (see `currentType()` and THE RULE above it). This
            // is the command layer's half of the same answer app.d publishes
            // into its own SubjectPacket via `buildToolVts`; the two layers
            // now read one authority instead of two.
            subj.selType  = currentType();
            vts.put(&subj);
            return op.evaluate(vts);
        }
        return true;
    }

    // Restore the pre-apply mesh/selection/state. Default: not undoable.
    // Mutating commands override and return true on success.
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
    string refusalReason() const { return ""; }

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
    // read `subj.selType` off the packet they already hold — `apply()` above
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
