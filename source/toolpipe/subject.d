module toolpipe.subject;

// Task 1904 (doc/subject_stage_plan.md) Stage 0 — the one funnel every
// SubjectPacket builder goes through.
//
// Before this module, ~15 call sites in 7 files each decided by hand what
// "the subject" is (which Mesh*, which editMode, which selType, which
// viewport, whether a cursor is valid) and two existing builders
// (`InputFrameState.buildToolVts`, `TransformTool.buildLocalVts`) already
// duplicated most of that logic against each other. This module does not
// change what any of those sixteen sites compute — every migrated call
// site keeps passing exactly the values it passes today, including a
// silent default where one exists (see `SubjectSource` below and
// `viewOnlySubject`). It only gives the fill+put+evaluate sequence one
// name and one place.
//
// Why this is a plain module with two free functions, not a registered
// pipe stage and not a `ToolPipeContext` method — see the plan's §1.1 and
// §1.2. The short version: the reference's task/order tables have no
// subject entry; the subject is a packet the host seeds in, not a stage
// that runs (provenance: plan §1.1). A registered stage would add a row to
// `/api/toolpipe`'s verbatim `Pipeline.all()` dump, and `ToolPipeContext`
// cannot see the mesh/editMode/selType/viewport without duplicating
// `EditorApp`'s own wiring (task 1901's question, not this one's).
//
// Hazard R1 (plan §2), and why `SubjectSource` is a value the caller
// builds and `fillSubject` writes into a caller-owned `out` parameter
// rather than this module owning storage: `VectorStack` stores raw
// pointers (`source/operator.d`), and the pipe is genuinely re-entered
// while an outer `VectorStack` is still alive — e.g.
// `PenTool.onMouseButtonDown` receives a stack built by
// `InputFrameState.buildToolVts` and, inside that same handler, calls
// `create_common.d :: snapLocalHit`, which builds its OWN subject and runs
// a second `pipeline.evaluate`. A stage — one storage slot — would have
// the second evaluate silently overwrite the first subject in place. Every
// caller here keeps owning its own `SubjectPacket` in its own frame; this
// module only writes into it.

import mesh             : Mesh, MapKind;
import editmode          : EditMode;
import seltype            : SelType;
import math                : Viewport;
import toolpipe.packets    : SubjectPacket, GesturePacket;
import operator            : VectorStack;
import toolpipe.pipeline   : g_pipeCtx;

/// Everything about a subject that ONLY the caller can know.
///
/// The four fields every site already varies carry NO default, so a
/// migrated site cannot silently inherit one (plan §1.3). A plain struct
/// field with no initialiser still has a `.init` in D, so "just leave the
/// default off" is not a mechanism by itself — the mechanism is the
/// constructor: `@disable this()` kills default construction and an
/// explicit four-argument `this` kills the field-wise literal, so the
/// only way to build a `SubjectSource` is to name all four. That is what
/// stops a future call site from re-acquiring the "forgot selType, got
/// Vertex" shape six of today's sixteen sites already have.
///
/// The opt-in trio below keeps a field initialiser deliberately: "off" is
/// today's behaviour at every site but one for each, and `SubjectPacket`'s
/// own comments already document the `cursorValid` gate and the morph
/// target as opt-in.
struct SubjectSource {
    @disable this();
    this(Mesh* mesh, EditMode editMode, SelType selType, Viewport viewport) {
        this.mesh     = mesh;
        this.editMode = editMode;
        this.selType  = selType;
        this.viewport = viewport;
    }

    Mesh*     mesh;      // may be null (the workplane pickers) -- but SAID so
    EditMode  editMode;
    SelType   selType;   // seven sites pass Vertex explicitly (plan §1.3)
    Viewport  viewport;  // four distinct live sources -- see plan hazard R2,
                          // never unify them

    // The opt-in trio: inert default, exactly one call site turns each on
    // today. `cursorValid`'s thread-safety gate and the morph opt-in are
    // documented in full on `SubjectPacket` itself (toolpipe/packets.d);
    // this struct does not repeat that discipline, only carries it.
    int  cursorX            = -1;
    int  cursorY            = -1;
    bool cursorValid        = false;
    bool resolveMorphTarget = false;   // buildLocalVts only
}

/// Fill a caller-owned packet. This IS the only place `SubjectPacket`
/// fields are assigned outside a literal `unittest { }` body anywhere in
/// `source/**` (plan §3) — the nine hand-fill sites that used to decide
/// this by hand (`command.d :: Command.apply`, `symmetry_pick.d`,
/// `commands/mesh/select.d`, `create_common.d` (×4), `command_wrapper.d`
/// (×2)) are all migrated. Enforced by the §6 census test
/// (`tests/unit/toolpipe/subject_construction_census_test.d`), which scans
/// `source/**` only and excludes literal `unittest { }` bodies — not
/// `version (unittest)` blocks, which it does NOT exclude.
///
/// `subj` is `out`, matching every existing builder: the caller's own
/// local is the storage `evaluateSubject` below later hands to
/// `VectorStack.put`, so its address stays valid for exactly as long as
/// it always has — the caller's frame, per hazard R1.
void fillSubject(out SubjectPacket subj, in SubjectSource src) {
    // `in` marks `src` const, which propagates through the `Mesh*` field to
    // `const(Mesh)*`. This line only copies the pointer VALUE into
    // `subj.mesh` (a plain `Mesh*`, matching SubjectPacket's own declared
    // field and every existing builder) -- nothing in this function
    // dereferences or mutates through `src.mesh`, so the cast widens
    // mutability on a value this function never treats as const past this
    // point; it does not defeat the point of `in`.
    subj.mesh        = cast(Mesh*) src.mesh;
    subj.editMode    = src.editMode;
    subj.selType     = src.selType;
    subj.viewport    = src.viewport;
    subj.cursorX     = src.cursorX;
    subj.cursorY     = src.cursorY;
    subj.cursorValid = src.cursorValid;

    // Task 1069's morph routing target (SubjectPacket.morphTargetKind/
    // morphTargetName) — opt-in, resolved AGAINST THIS MESH so a target
    // naming a map the mesh does not carry degrades to "no target" rather
    // than a stale name. Only `TransformTool.buildLocalVts` turns this on
    // (plan §1.3); every other migrated site leaves the packet's own
    // `MapKind.unclassified` / empty-string defaults alone.
    if (src.resolveMorphTarget && src.mesh !is null) {
        import morph_target : resolveMorphTarget;
        string  mtName;
        MapKind mtKind;
        if (resolveMorphTarget(src.mesh, mtName, mtKind)) {
            subj.morphTargetName = mtName;
            subj.morphTargetKind = mtKind;
        }
    }
}

/// fill + put + (optionally publish a gesture) + evaluate. THE ONLY caller
/// of `g_pipeCtx.pipeline.evaluate` outside `toolpipe/pipeline.d` (plan
/// §5) — now that every call site is migrated, the grep
/// `grep -rn 'pipeline\.evaluate(' source --include=*.d | grep -vE ':[0-9]+: *(//|\*|///)'`
/// returns exactly the one line inside this function.
///
/// `gestSlot`, when non-null, is published into the SAME stack — matching
/// `InputFrameState.buildToolVts`'s combined subject+gesture publish. The
/// storage it points at belongs to the CALLER (e.g. `gestureSlot`, kept
/// out of the per-call stack frame for the same lifetime reason `subj`
/// is `out` — see this module's header comment on hazard R1); this
/// function never allocates or owns gesture storage.
///
/// Returns false when no pipe is registered (unit-test contexts) — the
/// same answer `TransformTool.buildLocalVts` already returns today. The
/// packet is filled and published either way (matching
/// `InputFrameState.buildToolVts`'s existing unconditional fill); only the
/// evaluate itself is gated on `g_pipeCtx`.
bool evaluateSubject(out SubjectPacket subj, ref VectorStack vts,
                      in SubjectSource src, GesturePacket* gestSlot = null) {
    fillSubject(subj, src);
    vts.put(&subj);
    if (gestSlot !is null)
        vts.put(gestSlot);
    if (g_pipeCtx is null)
        return false;
    g_pipeCtx.pipeline.evaluate(vts);
    return true;
}

/// The FROZEN view-only source: no mesh, and the two type fields held at
/// the values today's two workplane pickers (`create_common.d ::
/// pickWorkplane`, `:: pickWorkplaneFrame`) publish IMPLICITLY today by
/// never naming them — D's `.init` for `EditMode`/`SelType`
/// (`source/editmode.d`, `source/seltype.d`).
///
/// This is not a convenience wrapper — it is the one home of a pinned
/// constant. `SubjectSource`'s mandatory four-argument constructor removes
/// the silence those two sites relied on: the implementer is forced to
/// type three values that were previously invisible, and the "obvious"
/// thing to type is the live editor state. That would be a BEHAVIOUR
/// CHANGE with no test able to see it (plan §1.3a traces why:
/// `ActionCenterStage.evaluate` and `AxisStage.evaluate` both branch on
/// `subj.selType` unconditionally on every evaluate, but the packets those
/// two pickers' evaluates produce go into a stack from which only
/// `WorkplanePacket` is ever read). So this function exists to make that
/// freeze a single, named, reviewable line instead of two invisible ones.
///
/// Do NOT add other callers: every other call site has a real mesh and a
/// real live selection type.
SubjectSource viewOnlySubject(Viewport vp) {
    return SubjectSource(null, EditMode.Vertices, SelType.Vertex, vp);
}
