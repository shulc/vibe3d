module tools.alignment.radial_align_tool;
import display_state : DrawPlan;

import operator : VectorStack;

import tools.transform.transform;
import tools.alignment.align_kernels : extractAlignChain, radialAlignTargets, alignOutsideNeighbours,
                              MAX_ALIGN_SIDES;
import falloff : weightedLerp;
import mesh;
import mesh_gpu : GpuMesh;
import editmode;
import math : Vec3, Viewport;
import shader;
import params : Param;
import tool : ToolSessionPolicy, HeadlessSourcePolicy, InputBindable;
import bindbc.sdl : SDL_MouseButtonEvent, SDL_GetModState;
import tool_input : InputBinding, InputButton, InputMod, InputPhase, ToolAction,
    toButton, toMods;
import change_bus : MeshEditScope;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import document : Layer;
import prepared_transform_activation : PreparedTransformActivationOwner;
import prepared_tool_effect : PreparedTransformActivationEffect,
    PreparedTransformActivationKind;

/// Radial Align uses the existing Apply command for panel and plain viewport
/// clicks (task 20261210; doc/tasks/work/20261210-radial-viewport-apply.md).
/// Native handles/drag remain deferred; a click changes no parameters.
///
/// Shared target/source law (tasks 9490, 20261040, 20261110): Circle retains its start/search;
/// N-sided uses integer knot ownership and double chords. Weight blends source
/// to target with falloff evaluated at the target (task 9446, K-F2).
class RadialAlignTool : TransformTool, PreparedToolDoorClient, InputBindable {
private:
    // "circle" / "nside" — see align_kernels.radialAlignTargets's doc
    // comment (CONFIRMED no cylinder/sphere mode exists).
    void delegate() viewportApply_;
    string headlessMode   = "circle";
    int    headlessSide   = 4;
    int    headlessRotate = 0;   // N-Sided-only slot offset
    float  headlessAngle  = 0.0f;   // Circle (and, composed, N-Sided) offset
    float  headlessWeight = 1.0f;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
    }

    void bindViewportApply(void delegate() apply) { viewportApply_ = apply; }

    override const(InputBinding)[] bindings() const {
        static immutable rows = [InputBinding(InputButton.Left, InputMod.None, 0)];
        return rows;
    }

    override bool onToolAction(ToolAction action, InputPhase phase,
            ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (phase == InputPhase.Down) viewportApply_();
        return true;
    }

    override void onInputResetAll() {}

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (viewportApply_ is null) return false;
        return dispatchInput(toButton(e.button), toMods(SDL_GetModState()),
            InputPhase.Down, e, vts);
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        return dispatchInput(toButton(e.button), toMods(SDL_GetModState()),
            InputPhase.Up, e, vts);
    }

    override string name() const { return "Radial Align"; }

    // The session owns original positions; this leaf only borrows
    // them during evaluation (radial lifecycle completion amendment, L2).
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            headlessSource: HeadlessSourcePolicy.retainedPositions,
            activationRow: true, sessionSteps: true, historyRecordedSteps: true
        };
        return policy;
    }

    // Task 0393: headlessMode/headlessSide/headlessRotate/headlessAngle/
    // headlessWeight are STICKY tool-defaults, already restored onto
    // these fields by the attribute cache recall (prepareStickyToolDefaults, from
    // the prepared arm) BEFORE activate() runs — don't reset them back
    // to the constructor defaults here. A brand-new (never-activated) tool
    // still gets "circle"/4/0/0/1.0 from the field initializers above.
    override void activate() {
        super.activate();
    }

    final PreparedTransformActivationEffect prepareActivate(
            PreparedRecordContext context) {
        if (context is null) return PreparedTransformActivationEffect(
            preparedToolStateOwner, PreparedTransformActivationKind.RadialAlign, false);
        scope(failure) context.discard();
        auto owner = PreparedTransformActivationOwner.prepare(this);
        bool ok = owner !is null && context.prepareTransformActivation(owner) &&
            context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedTransformActivationEffect(preparedToolStateOwner,
            PreparedTransformActivationKind.RadialAlign, ok);
    }

    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong, ulong) { return prepareActivate(context).accepted; }
    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer,
            ulong, ulong) { return context.markNoHistoryInstall(); }

    // `radius` / `centerX/Y/Z` are deliberately NOT exposed here: the
    // reference tool auto-computes both at activation and lets the user
    // override them interactively (viewport handle drag) — that
    // interaction was never captured/verified this round (toolcard:
    // "Explicit numeric override of radius/centerX/Y/Z NOT tested this
    // round"). Rather than invent an override sentinel/UX for an
    // unverified interaction, this port implements ONLY the bit-exact
    // auto-compute law (see radialAlignTargets: center = mean position,
    // radius = mean distance from center) — always live, never
    // overridable. `smooth`/`flatten` are Polygons-mode-only smoothing
    // knobs the toolcard never exercised either (untested, deferred) —
    // not exposed for the same reason.
    override Param[] params() {
        return [
            Param.enum_("mode", "Mode", &headlessMode,
                [["circle", "Circle"], ["nside", "N-Sided"]], "circle"),
            Param.int_("side", "Side", &headlessSide, 4),
            Param.int_("rotate", "Rotate", &headlessRotate, 0),
            Param.float_("angle", "Angle", &headlessAngle, 0.0f).angle(),
            Param.float_("weight", "Weight", &headlessWeight, 1.0f),
        ];
    }

    // No gizmo — see class doc comment.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        cachedVp = vp;
    }

    /// Headless apply — see class doc comment for the full law.
    override bool applyHeadless() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        beginHeadlessDeform(subj, vts);

        auto chain = extractAlignChain(mesh, *editMode);
        if (chain.verts.length < 1) return false;

        const positions = headlessSourcePositions(mesh.vertices);
        Vec3[] source = new Vec3[](chain.verts.length);
        foreach (i, vi; chain.verts) source[i] = positions[vi];

        bool nsideMode = (headlessMode == "nside");
        auto aligned = radialAlignTargets(source, nsideMode, headlessSide,
                                          headlessAngle, headlessRotate,
                                          alignOutsideNeighbours(mesh, *editMode, chain.verts, positions));

        if (toProcess.length != mesh.vertices.length)
            toProcess.length = mesh.vertices.length;
        toProcess[] = false;

        bool any = false;
        float[] weights = new float[](chain.verts.length);
        // Task 0619: hoisted — see bend.d.
        const auto aim = dragAimSpace();
        foreach (i, vi; chain.verts) {
            weights[i] = headlessWeight * falloffWeightAt(aligned[i], cast(int)vi, aim);
            any |= weights[i] != 0.0f;
        }
        if (!any) return false;
        foreach (i, vi; chain.verts) {
            const w = weights[i];
            if (w == 0.0f) continue;
            mesh.vertices[vi] = weightedLerp(source[i], aligned[i], w);
            toProcess[vi] = true;
        }

        applySymmetryToDrag();
        // The command owns the reversible payload and delivery batch; this
        // publishes the actual position writes without a structural increment.
        mesh.commitChange(MeshEditScope.Position);
        return true;
    }
}
