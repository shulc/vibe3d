module tools.alignment.radial_align_tool;

import operator : VectorStack;

import tools.transform.transform;
import tools.alignment.align_kernels : extractAlignChain, radialAlignTargets, lerp3,
                              MAX_ALIGN_SIDES;
import mesh;
import editmode;
import math : Vec3, Viewport;
import shader;
import params : Param;
import change_bus : MeshEditScope;

/// Radial Align tool (`xfrm.radialAlignTool`) — falloff-aware deform
/// tool, same structural family as Bend/Push (tools/bend.d, tools/push.d):
/// `params()` + `applyHeadless()` only, driven via
/// `tool.attr xfrm.radialAlignTool <attr> <v>; tool.doApply` from the
/// panel (Post-Mode auto-apply). No interactive gizmo drag — the
/// reference tool's own handle layout (`radHandleX/Y/Z`) is
/// viewport-only and was never captured (task 0361 toolcard: "no
/// handles.png/gizmo screenshot taken this round"), so this mirrors
/// Bend/Push's existing headless-attr-driven precedent rather than
/// inventing an undocumented drag gesture.
///
/// Algorithm (measured by live reference-editor capture, task 0361 — see
/// `tools/align_kernels.d`'s module doc comment for the full law).
/// CONFIRMED: the reference tool has NO cylinder/sphere mode — only
/// planar `circle` / `nside` (this is the direct answer to this task's
/// "confirm cylinder-mode presence" question). Extracts an ordered vertex
/// CHAIN from the current selection (same extraction as Linear Align),
/// then distributes it at equal `360/N`-degree slots around a circle
/// (center = mean chain position, radius = mean distance from center,
/// both auto-computed — no interactive override, see `params()`'s doc
/// comment). `angle`/`rotate` additively rotate the slot framework;
/// `weight` blends `lerp(source, aligned, weight * falloff)`.
class RadialAlignTool : TransformTool {
private:
    // "circle" / "nside" — see align_kernels.radialAlignTargets's doc
    // comment (CONFIRMED no cylinder/sphere mode exists).
    string headlessMode   = "circle";
    int    headlessSide   = 4;
    float  headlessRotate = 0.0f;   // N-Sided-only slot offset
    float  headlessAngle  = 0.0f;   // Circle (and, composed, N-Sided) offset
    float  headlessWeight = 1.0f;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
    }

    override string name() const { return "Radial Align"; }

    // Task 0393: headlessMode/headlessSide/headlessRotate/headlessAngle/
    // headlessWeight are STICKY tool-defaults (this tool has no interactive
    // gesture — they're the whole "setting" surface), already restored onto
    // these fields by applyStickyToolDefaults() (tool_presets.d, called from
    // app.d activateToolById) BEFORE activate() runs — don't reset them back
    // to the constructor defaults here. A brand-new (never-activated) tool
    // still gets "circle"/4/0/0/1.0 from the field initializers above.
    override void activate() {
        super.activate();
    }

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
            Param.int_("side", "Side", &headlessSide, 4)
                .min(1).max(MAX_ALIGN_SIDES).enforceBounds(),
            Param.float_("rotate", "Rotate", &headlessRotate, 0.0f).angle(),
            Param.float_("angle", "Angle", &headlessAngle, 0.0f).angle(),
            Param.float_("weight", "Weight", &headlessWeight, 1.0f)
                .min(0.0f).max(1.0f).enforceBounds(),
        ];
    }

    // No gizmo — see class doc comment.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
    }

    /// Headless apply — see class doc comment for the full law.
    override bool applyHeadless() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);

        auto chain = extractAlignChain(mesh, *editMode);
        if (chain.verts.length < 1) return false;

        Vec3[] source = new Vec3[](chain.verts.length);
        foreach (i, vi; chain.verts) source[i] = mesh.vertices[vi];

        bool nsideMode = (headlessMode == "nside");
        auto aligned = radialAlignTargets(source, nsideMode, headlessSide,
                                          headlessAngle, headlessRotate);

        if (toProcess.length != mesh.vertices.length)
            toProcess.length = mesh.vertices.length;
        toProcess[] = false;

        bool any = false;
        foreach (i, vi; chain.verts) {
            float w = headlessWeight * falloffWeight(cast(int)vi);
            if (w == 0.0f) continue;
            mesh.vertices[vi] = lerp3(source[i], aligned[i], w);
            toProcess[vi] = true;
            any = true;
        }
        if (!any) return false;

        applySymmetryToDrag();
        // ToolDoApplyCommand's snapshot/restore owns undo; this bumps
        // mutationVersion for the change-notification bus, matching the
        // one-shot Command's existing convention
        // (commands/mesh/radial_align.d).
        mesh.commitChange(MeshEditScope.Position);
        return true;
    }
}
