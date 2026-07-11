module tools.radial_sweep_tool;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import std.math : PI, abs, cos, sin;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import shader : Shader, LitShader;
import handler : ToolHandles, BoxHandler, gizmoSize, drawThickLinesExt;
import drag : planeDragDelta, screenAxisDelta;
import eventlog : queryMouse;

version (unittest) import std.conv : to;

// ---------------------------------------------------------------------------
// Radial Sweep — interactive revolve/lathe tool (task 0326) wrapping
// `Mesh.revolveProfileEx` (source/mesh.d), which itself wraps the original
// `Mesh.revolveProfile` kernel behind the `mesh.sweep` one-shot command.
// Modelled directly on MirrorTool (tools/mirror.d): a self-contained
// PREVIEW mesh that never touches the document mesh during interaction
// (rebuilt every param change / handle drag from a base snapshot + the
// captured profile), committed once at deactivate().
//
// Captured attrs (toolcards/radial_sweep/spec.json, task 0326) implemented
// here: Count (`sides`, translated per the measured Count-semantics gap —
// see `toKernelParams`), Axis (free 3D vector + X/Y/Z/Custom quick-set,
// draggable axis-line handles), Center, Start/End Angle (draggable angle
// handles), Offset (axial spiral pitch), Cap Start/End.
//
// Deferred (captured in the toolcard but NOT wired into the vibe3d kernel —
// see `RadialSweepParams`' trailing comment block for the documented
// reference defaults a future pass should honour):
//   - Square mode — the reference's own companion "Start Segment" control
//     could not be confirmed as a live attribute in the captured install;
//     the base "Square" toggle's effect (aligning swept segments along a
//     square instead of a circle) has no vibe3d kernel analogue at all.
//   - Sweep UVs (none/u/v) — vibe3d's revolve kernel generates no UVs for
//     the swept surface; would need PolyVertex per-corner UV authoring
//     (see source/mesh_maps or the UV-maps stage), out of scope here.
//   - Invert Polygons — `revolveProfileEx`'s winding is fixed; parity vs.
//     the reference's default orientation was never captured live.
//   - Curve Cage / Size / Tolerance / Pivot / OffsetX-Y / profile Angle /
//     ReverseX-Y — reference "Profiles Attributes" group, collapsed by
//     default even in the reference panel and explicitly out of scope per
//     the toolcard's own parity case (selection-based sweep only, no
//     profile-preset library in vibe3d).
// ---------------------------------------------------------------------------

alias RadialSweepEditFactory = MeshBevelEdit delegate();

/// RadialSweepParams — single source of truth for the tool (mirrors
/// MirrorParams, tools/mirror.d). Every handle drag and panel edit writes
/// into this struct; preview + handle positions + the kernel call all
/// derive from it on demand.
struct RadialSweepParams {
    // Reference "Count" convention: the number of NEW bands on an open /
    // partial-angle sweep (ring count = sides+1); coincides with vibe3d's
    // own ring-count convention ONLY on a closed 360° sweep. Translated to
    // Mesh.RevolveParams.count in `toKernelParams` below — the measured gap
    // from the task 0326 toolcard (a literal count->sides port would
    // silently under-count bands by one on every open sweep).
    int   sides         = 24;
    // Quick-set preset for `axis`: 0=X 1=Y 2=Z 3=Custom. Selecting X/Y/Z
    // snaps `axis` to that coordinate direction (preserving its current
    // magnitude); it is NOT a mode gate — `axis` stays directly editable
    // (panel or handle drag) at all times, same as the reference. Any
    // manual edit of `axis` flips this back to Custom (3).
    int   axisPreset    = 1;
    // Free 3D rotation axis — the RAW half-vector (reference vecX/Y/Z),
    // not a unit direction: the axis LINE spans `center - axis` to
    // `center + axis` (reference help text: "If you set all the values to
    // 1m, [it] sets one end at (-1,-1,-1) and the other end at (1,1,1)").
    Vec3  axis          = Vec3(0, 1, 0);
    // Pivot point the axis line passes through (reference cenX/Y/Z).
    Vec3  center         = Vec3(0, 0, 0);
    // Rotational placement of ring 0 / the last ring, in DEGREES (reference
    // Start Angle / End Angle). Angle SPAN = endAngleDeg - startAngleDeg.
    float startAngleDeg  = 0.0f;
    float endAngleDeg    = 360.0f;
    // Axial translation per ring step, world units (spiral pitch;
    // reference "Offset" — springs/telephone-cord shapes at End Angle >
    // 360°, which this tool allows since endAngleDeg has no upper clamp).
    float offset          = 0.0f;
    // Close the start/end ring with an n-gon (reference Cap Start/End,
    // both default ON). Only takes effect for a CLOSED profile ring
    // (polygon-mode sweep) on a non-closed sweep — see
    // Mesh.revolveProfileEx's doc comment. Harmless at the default full
    // 360° sweep (no exposed end to cap either way).
    bool  cap0            = true;
    bool  cap1            = true;

    // --- Deferred (see module doc comment above) — NOT panel params, so
    // the UI never offers a control with no effect. Documented reference
    // defaults for whoever wires these into the kernel later:
    //   square = false   (reference "Square")
    //   uvs    = "u"     (reference "Sweep UVs": none/u/v)
    //   flip   = false   (reference "Invert Polygons")
}

/// Upper bound on `RadialSweepParams.sides` (reference "Count"). Enforced
/// TWICE (task 0326 review finding B1 — Count was previously unbounded):
///   1. The `sides` Param itself opts into `.max(MAX_SWEEP_SIDES)
///      .enforceBounds()` (see `params()` below), so an out-of-range
///      headless `tool.attr ... sides <n>` write is clamped BEFORE it ever
///      reaches `onParamChanged`/`evaluate` — this is the PRIMARY defense,
///      since `evaluate()` runs `rebuildRadialSweepPreview` SYNCHRONOUSLY
///      on the UI/HTTP thread.
///   2. `toKernelParams` (below) re-clamps defensively: `revolveProfileEx`
///      is a shared PUBLIC kernel method, so this belt-and-braces clamp
///      protects any future caller that reaches it through a path other
///      than the Param write above.
/// Without either, `tool.attr ... sides 100000000` allocated ~1.6GB
/// synchronously and hung the editor.
enum int MAX_SWEEP_SIDES = 1024;

/// Translate `RadialSweepParams` (reference "Count" convention + every
/// other panel field) into `Mesh.RevolveParams` (vibe3d's ring-count
/// convention). The two nontrivial steps: the Count-semantics fix (task
/// 0326 measured gap, see `sides`'s doc comment) and the `sides` DoS clamp
/// (see `MAX_SWEEP_SIDES`) — everything else is a direct field copy /
/// degrees-to-radians conversion.
Mesh.RevolveParams toKernelParams(in RadialSweepParams p) pure nothrow @nogc @safe {
    enum float D2R = cast(float)(PI / 180.0);
    Mesh.RevolveParams kp;
    immutable float angleSpanRad = (p.endAngleDeg - p.startAngleDeg) * D2R;
    // revolveSweepClosedWithOffset (NOT the bare angle-only
    // revolveSweepClosed): a nonzero spiral `offset` must be treated as an
    // OPEN sweep even at a >=360° angle span, or the ring-count
    // translation below disagrees with revolveProfileEx's own OPEN
    // wrap-bridge decision (task 0326 review finding S1) — same single
    // source of truth the kernel itself uses.
    immutable bool  closed = Mesh.revolveSweepClosedWithOffset(angleSpanRad, p.offset);

    int sidesClamped = p.sides;
    if (sidesClamped < 1) sidesClamped = 1;
    else if (sidesClamped > MAX_SWEEP_SIDES) sidesClamped = MAX_SWEEP_SIDES;

    kp.count      = closed ? sidesClamped : sidesClamped + 1;
    kp.axis       = p.axis;
    kp.center     = p.center;
    kp.angle      = angleSpanRad;
    kp.startAngle = p.startAngleDeg * D2R;
    kp.offset     = p.offset;
    kp.cap0       = p.cap0;
    kp.cap1       = p.cap1;
    return kp;
}

/// The non-cumulative preview recompute (mirrors `rebuildMirrorPreview`,
/// tools/mirror.d) — a free function (not a method) so a module unittest
/// can exercise it directly against a plain `Mesh`, without constructing a
/// RadialSweepTool (whose constructor builds GL-backed handlers via
/// BoxHandler — unsafe outside a live GL context).
///
/// `baseSnap.restore(previewMesh)` fully overwrites `previewMesh` with the
/// pristine base EVERY call — the guarantee that N successive calls never
/// accumulate N sweeps (revolveProfileEx APPENDS; see mesh.d).
///
/// `profileFaceIdx` (polygon-mode only, `uint.max` sentinel for edge mode)
/// is the SOURCE face's index at capture time — still valid against the
/// freshly-restored `previewMesh` since revolveProfileEx only appends
/// (never reindexes existing faces) and `baseSnap` reproduces the exact
/// mesh state the index was captured against.
void rebuildRadialSweepPreview(const ref MeshSnapshot baseSnap, ref Mesh previewMesh,
                               in uint[] profile, bool profileClosed, uint profileFaceIdx,
                               in RadialSweepParams params_)
{
    baseSnap.restore(previewMesh);
    if (profile.length == 0) return;   // no valid selection captured — bare base

    auto   kp       = toKernelParams(params_);
    size_t inserted = previewMesh.revolveProfileEx(profile, profileClosed, kp);
    if (inserted > 0 && profileFaceIdx != uint.max
        && profileFaceIdx < previewMesh.faces.length) {
        auto delMask = new bool[](previewMesh.faces.length);
        delMask[profileFaceIdx] = true;
        previewMesh.deleteFacesByMask(delMask);   // rebuilds loops internally
    }
}

// ---------------------------------------------------------------------------
// RadialSweepTool
// ---------------------------------------------------------------------------
class RadialSweepTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*  gpu;
    LitShader litShader;
    EditMode* editMode;

    RadialSweepParams params_;

    // Base state captured at activate()/resyncSession() — the pristine
    // mesh + the profile the preview/commit sweep from. `validProfile_` is
    // false when the current edit-mode selection doesn't yield a usable
    // profile (empty edge chain / not exactly one selected face) — the
    // tool then shows only the axis gizmo and commits nothing.
    MeshSnapshot baseSnap;
    uint[]       profile_;
    bool         profileClosed_;
    uint         profileFaceIdx_ = uint.max;
    bool         validProfile_;

    // Own preview mesh (never touches the document mesh until deactivate()).
    Mesh    previewMesh;
    GpuMesh previewGpu;

    // Dirty guard — evaluate() is called every frame the panel is open AND
    // on every handle-drag motion event; skip the restore+sweep+GPU-upload
    // round trip when nothing actually changed.
    bool  havePreviewCache;
    int   cachedSides;
    int   cachedAxisPreset;
    Vec3  cachedAxis;
    Vec3  cachedCenter;
    float cachedStartAngle;
    float cachedEndAngle;
    float cachedOffset;
    bool  cachedCap0;
    bool  cachedCap1;

    // Commit guard: true once the user has actually interacted (handle
    // drag / param edit / headless attr write).
    bool engaged;

    CommandHistory         history;
    RadialSweepEditFactory editFactory;

    // ----- Handles: 0 = axis start point, 1 = axis end point (drag either
    // to reposition/reorient the free 3D axis line — the OTHER endpoint
    // stays planted, standard two-endpoint line-edit UX; the reference
    // toolcard itself notes the drag law is "a direct 1:1 numeric mapping,
    // not a bespoke formula requiring its own discriminating capture"), 2 =
    // start-angle handle, 3 = end-angle handle.
    BoxHandler  axisStartH, axisEndH, startAngleH, endAngleH;
    ToolHandles toolHandles;
    int         dragPart = -1;
    int         lastMX, lastMY;
    Viewport    cachedVp;

    GLuint axisLineVao, axisLineVbo;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        axisStartH  = new BoxHandler(Vec3(0, 0, 0), Vec3(0.95f, 0.55f, 0.05f));
        axisEndH    = new BoxHandler(Vec3(0, 0, 0), Vec3(0.95f, 0.55f, 0.05f));
        startAngleH = new BoxHandler(Vec3(0, 0, 0), Vec3(0.25f, 0.75f, 0.95f));
        endAngleH   = new BoxHandler(Vec3(0, 0, 0), Vec3(0.35f, 0.95f, 0.35f));
        toolHandles = new ToolHandles();
    }

    void destroy() {
        axisStartH.destroy();
        axisEndH.destroy();
        startAngleH.destroy();
        endAngleH.destroy();
        if (axisLineVao != 0) { glDeleteVertexArrays(1, &axisLineVao); glDeleteBuffers(1, &axisLineVbo); }
    }

    override string name() const { return "Radial Sweep"; }

    override EditMode[] supportedModes() const { return [EditMode.Edges, EditMode.Polygons]; }

    override void activate() {
        baseSnap      = MeshSnapshot.capture(*mesh);
        validProfile_ = captureProfile(mesh, profile_, profileClosed_, profileFaceIdx_);
        engaged       = false;
        dragPart      = -1;
        toolHandles.clearHaul();
        previewGpu.init();
        havePreviewCache = false;
        evaluate();
    }

    override void deactivate() {
        bool willCommit = engaged && validProfile_;
        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        size_t inserted = 0;
        if (willCommit) {
            auto kp = toKernelParams(params_);
            inserted = mesh.revolveProfileEx(profile_, profileClosed_, kp);
            if (inserted > 0) {
                if (profileFaceIdx_ != uint.max && profileFaceIdx_ < mesh.faces.length) {
                    auto delMask = new bool[](mesh.faces.length);
                    delMask[profileFaceIdx_] = true;
                    mesh.deleteFacesByMask(delMask);
                }
                mesh.buildLoops();
                gpu.upload(*mesh);
            }
        }

        previewGpu.destroy();
        if (willCommit && inserted > 0) commitSweepEdit(pre);
        engaged          = false;
        havePreviewCache = false;
    }

    // ----- History-coordination hooks (mirror MirrorTool's, tools/mirror.d) -

    public override bool hasUncommittedEdit() const { return engaged && validProfile_; }

    public override void cancelUncommittedEdit() {
        // The document mesh was never touched during interaction (own
        // preview mesh) — nothing to revert, just drop the guard.
        engaged = false;
    }

    public override void resyncSession() {
        baseSnap         = MeshSnapshot.capture(*mesh);
        validProfile_    = captureProfile(mesh, profile_, profileClosed_, profileFaceIdx_);
        havePreviewCache = false;
        evaluate();
    }

    /// Inject undo plumbing — called by app.d after construction (mirrors
    /// MirrorTool.setUndoBindings).
    void setUndoBindings(CommandHistory h, RadialSweepEditFactory factory) {
        this.history     = h;
        this.editFactory = factory;
    }

    private void commitSweepEdit(MeshSnapshot pre) {
        if (history is null || editFactory is null) return;
        auto cmd  = editFactory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Radial Sweep");
        history.record(cmd);
    }

    // ----- Profile capture — shared by activate()/resyncSession() (which
    // populate the tool's own fields against the live mesh) AND
    // applyHeadless() (which builds its OWN profile fresh from the live
    // mesh, since ToolHeadlessCommand never calls activate() on its
    // throwaway instance — mirrors MirrorTool's `buildMaskFromSelection`
    // fold #4). Matches MeshSweep.evaluate()'s extraction rule exactly
    // (commands/mesh/sweep.d) so headless `mesh.radialSweepTool` and the
    // pre-existing `mesh.sweep` command agree on what counts as a profile.
    private bool captureProfile(Mesh* m, out uint[] profile, out bool profileClosed,
                                out uint profileFaceIdx) {
        profileFaceIdx = uint.max;
        if (*editMode == EditMode.Polygons) {
            uint[] selFaces;
            foreach (fi; 0 .. m.faces.length)
                if (m.isFaceSelected(fi)) selFaces ~= cast(uint)fi;
            if (selFaces.length != 1) return false;
            profileFaceIdx = selFaces[0];
            profile        = m.faceVertexRing(profileFaceIdx).dup;
            profileClosed  = true;
            return true;
        } else if (*editMode == EditMode.Edges) {
            profile = m.extractSelectedEdgeChain(profileClosed);
            return profile.length > 0;
        }
        return false;
    }

    // ----- Params / panel -----------------------------------------------

    override Param[] params() {
        return [
            Param.int_("sides", "Count", &params_.sides, 24)
                .min(1).max(MAX_SWEEP_SIDES).enforceBounds(),
            Param.intEnum_("axisPreset", "Axis", &params_.axisPreset,
                [IntEnumEntry(0, "x",      "X"),
                 IntEnumEntry(1, "y",      "Y"),
                 IntEnumEntry(2, "z",      "Z"),
                 IntEnumEntry(3, "custom", "Custom")],
                1),
            Param.vec3_("axis",   "Axis Vector", &params_.axis,   Vec3(0, 1, 0)),
            Param.vec3_("center", "Center",      &params_.center, Vec3(0, 0, 0)),
            Param.float_("startAngle", "Start Angle", &params_.startAngleDeg, 0.0f).angle(),
            Param.float_("endAngle",   "End Angle",   &params_.endAngleDeg, 360.0f).angle(),
            Param.float_("offset", "Offset", &params_.offset, 0.0f),
            Param.bool_("cap0", "Cap Start", &params_.cap0, true),
            Param.bool_("cap1", "Cap End",   &params_.cap1, true),
        ];
    }

    override void onParamChanged(string name) {
        if (name == "axisPreset") {
            // Quick-set: snap `axis` to the chosen coordinate direction,
            // preserving its current magnitude (falls back to 1.0 world
            // unit — the reference default — if the axis had collapsed to
            // ~zero). Not a mode gate: `axis` stays directly editable.
            float len = params_.axis.length;
            if (len < 1e-6f) len = 1.0f;
            switch (params_.axisPreset) {
                case 0: params_.axis = Vec3(len, 0, 0); break;
                case 1: params_.axis = Vec3(0, len, 0); break;
                case 2: params_.axis = Vec3(0, 0, len); break;
                default: break;   // 3 = Custom — leave axis as-is
            }
        } else if (name == "axis") {
            params_.axisPreset = 3;   // manual edit -> Custom
        }
        engaged = true;
        evaluate();
    }

    override bool applyHeadless() {
        uint[] profile;
        bool   profileClosed;
        uint   profileFaceIdx;
        if (!captureProfile(mesh, profile, profileClosed, profileFaceIdx)) return false;

        auto   kp       = toKernelParams(params_);
        size_t inserted = mesh.revolveProfileEx(profile, profileClosed, kp);
        if (inserted == 0) return false;

        if (profileFaceIdx != uint.max && profileFaceIdx < mesh.faces.length) {
            auto delMask = new bool[](mesh.faces.length);
            delMask[profileFaceIdx] = true;
            mesh.deleteFacesByMask(delMask);
        }
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool drawImGui() { return false; }

    // ----- Live preview ---------------------------------------------------

    override void evaluate() {
        if (havePreviewCache
            && cachedSides      == params_.sides
            && cachedAxisPreset == params_.axisPreset
            && cachedAxis       == params_.axis
            && cachedCenter     == params_.center
            && cachedStartAngle == params_.startAngleDeg
            && cachedEndAngle   == params_.endAngleDeg
            && cachedOffset     == params_.offset
            && cachedCap0       == params_.cap0
            && cachedCap1       == params_.cap1)
            return;

        rebuildRadialSweepPreview(baseSnap, previewMesh, profile_, profileClosed_,
                                  profileFaceIdx_, params_);
        previewGpu.upload(previewMesh);

        cachedSides      = params_.sides;
        cachedAxisPreset = params_.axisPreset;
        cachedAxis       = params_.axis;
        cachedCenter     = params_.center;
        cachedStartAngle = params_.startAngleDeg;
        cachedEndAngle   = params_.endAngleDeg;
        cachedOffset     = params_.offset;
        cachedCap0       = params_.cap0;
        cachedCap1       = params_.cap1;
        havePreviewCache = true;
    }

    // ----- Draw -------------------------------------------------------------

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        if (!visualOnly) cachedVp = vp;

        if (validProfile_) {
            immutable float[16] identity = identityMatrix;
            Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

            glUseProgram(litShader.program);
            glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
            glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
            glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
            glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
            glUniform3f(litShader.locEyePos,   vp.eye.x, vp.eye.y, vp.eye.z);
            glUniform1f(litShader.locAmbient,  0.20f);
            glUniform1f(litShader.locSpecStr,  0.25f);
            glUniform1f(litShader.locSpecPow,  32.0f);
            previewGpu.drawFaces(litShader);

            glUseProgram(shader.program);
            glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
            glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
            glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
            previewGpu.drawEdges(shader.locColor, -1, []);
        }

        // --- Handle positions, derived fresh every frame from params_ ---
        immutable float D2R = cast(float)(PI / 180.0);
        float axisMag = params_.axis.length;
        Vec3  axisDirUnit = axisMag > 1e-6f ? params_.axis / axisMag : Vec3(0, 1, 0);
        Vec3  S = params_.center - params_.axis;   // axis start point
        Vec3  E = params_.center + params_.axis;   // axis end point

        // Fixed reference direction perpendicular to the axis (recomputed
        // live each frame — safe here since, unlike a rotate-drag, moving
        // the ANGLE handles never changes axisDirUnit itself, so there is
        // no per-frame basis-flip oscillation risk during that drag).
        Vec3 tmp        = (abs(axisDirUnit.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        Vec3 refDir     = normalize(cross(axisDirUnit, tmp));
        Vec3 tangentDir = cross(axisDirUnit, refDir);

        float gs       = gizmoSize(params_.center, vp);
        float armAngle = gs * 0.7f;
        float startRad = params_.startAngleDeg * D2R;
        float endRad   = params_.endAngleDeg   * D2R;
        Vec3 startPos = params_.center + refDir * (cos(startRad) * armAngle)
                                        + tangentDir * (sin(startRad) * armAngle);
        Vec3 endPos   = params_.center + refDir * (cos(endRad) * armAngle)
                                        + tangentDir * (sin(endRad) * armAngle);

        axisStartH.pos  = S;        axisStartH.size  = gs * 0.05f;
        axisEndH.pos    = E;        axisEndH.size    = gs * 0.05f;
        startAngleH.pos = startPos; startAngleH.size = gs * 0.045f;
        endAngleH.pos   = endPos;   endAngleH.size   = gs * 0.045f;

        drawAxisLine(vp, S, E, shader.program);

        if (!visualOnly) {
            toolHandles.begin();
            toolHandles.add(axisStartH,  0);
            toolHandles.add(axisEndH,    1);
            toolHandles.add(startAngleH, 2);
            toolHandles.add(endAngleH,   3);
            toolHandles.setHaul(dragPart);
            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);
        }

        axisStartH.draw(shader, vp);
        axisEndH.draw(shader, vp);
        startAngleH.draw(shader, vp);
        endAngleH.draw(shader, vp);
    }

    /// Solid line from `s` to `e` — the visible axis line (task 0326).
    /// Lazy VAO init + `GL_DYNAMIC_DRAW` re-upload every call, mirroring
    /// MirrorTool's `drawPlaneViz` pattern (tools/mirror.d): the geometry
    /// changes every frame the axis moves, so only the buffer OBJECT is
    /// cached, not its contents.
    private void drawAxisLine(const ref Viewport vp, Vec3 s, Vec3 e, GLuint restoreProgram) {
        immutable Vec3 axisColor = Vec3(0.85f, 0.65f, 0.15f);   // amber
        float[6] lineData = [s.x, s.y, s.z, e.x, e.y, e.z];

        if (axisLineVao == 0) {
            glGenVertexArrays(1, &axisLineVao);
            glGenBuffers(1, &axisLineVbo);
            glBindVertexArray(axisLineVao);
            glBindBuffer(GL_ARRAY_BUFFER, axisLineVbo);
            glBufferData(GL_ARRAY_BUFFER, lineData.sizeof, lineData.ptr, GL_DYNAMIC_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
            glEnableVertexAttribArray(0);
            glBindVertexArray(0);
        } else {
            glBindBuffer(GL_ARRAY_BUFFER, axisLineVbo);
            glBufferData(GL_ARRAY_BUFFER, lineData.sizeof, lineData.ptr, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, 0);
        }

        glDisable(GL_DEPTH_TEST);
        drawThickLinesExt(axisLineVao, 2, GL_LINES, identityMatrix, vp, axisColor, 2.0f, restoreProgram);
        glEnable(GL_DEPTH_TEST);
    }

    // ----- Input ------------------------------------------------------------

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;   // reserved for camera

        int hit = hitTestHandles(e.x, e.y);
        if (hit < 0) return false;
        dragPart = hit;
        lastMX   = e.x;
        lastMY   = e.y;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (dragPart < 0) return false;
        dragPart = -1;
        toolHandles.clearHaul();
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (dragPart < 0) return false;

        if (dragPart == 0 || dragPart == 1) {
            // Axis endpoint drag: the DRAGGED end moves on a screen-facing
            // plane through its current position; the OTHER end stays
            // planted (see the field-block comment on axisStartH/axisEndH).
            Vec3 curS = params_.center - params_.axis;
            Vec3 curE = params_.center + params_.axis;
            Vec3 anchor = dragPart == 0 ? curS : curE;

            bool skip;
            Vec3 delta = planeDragDelta(e.x, e.y, lastMX, lastMY, 3, anchor, cachedVp, skip);
            if (!skip) {
                if (dragPart == 0) {
                    Vec3 newS = curS + delta;
                    params_.center = (newS + curE) * 0.5f;
                    params_.axis   = (curE - newS) * 0.5f;
                } else {
                    Vec3 newE = curE + delta;
                    params_.center = (curS + newE) * 0.5f;
                    params_.axis   = (newE - curS) * 0.5f;
                }
                params_.axisPreset = 3;   // handle drag -> Custom
                engaged = true;
                evaluate();
            }
            lastMX = e.x;
            lastMY = e.y;
            return true;
        }

        // Angle-handle drag (2 = Start Angle, 3 = End Angle): single-DOF
        // drag along the handle's own live rotational tangent (mirrors
        // MirrorTool's rotate-box drag, tools/mirror.d), converted to a
        // degrees delta via arc length / radius.
        immutable float D2R = cast(float)(PI / 180.0);
        float axisMag = params_.axis.length;
        Vec3  axisDirUnit = axisMag > 1e-6f ? params_.axis / axisMag : Vec3(0, 1, 0);
        Vec3  tmp    = (abs(axisDirUnit.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        Vec3  refDir = normalize(cross(axisDirUnit, tmp));
        Vec3  tangentDir = cross(axisDirUnit, refDir);

        float gs       = gizmoSize(params_.center, cachedVp);
        float armAngle = gs * 0.7f;
        float* angleDeg = dragPart == 2 ? &params_.startAngleDeg : &params_.endAngleDeg;
        float  angRad   = *angleDeg * D2R;
        Vec3   handlePos = params_.center + refDir * (cos(angRad) * armAngle)
                                           + tangentDir * (sin(angRad) * armAngle);
        // Rotational velocity of a point orbiting `axisDirUnit`: exactly
        // axisDirUnit × (pos − center) — the live tangent at this angle.
        Vec3 liveTangent = normalize(cross(axisDirUnit, handlePos - params_.center));

        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, lastMX, lastMY, handlePos, liveTangent, cachedVp, skip);
        if (!skip && armAngle > 1e-6f) {
            float d = dot(delta, liveTangent);
            *angleDeg += (d / armAngle) * (180.0f / PI);
            engaged = true;
            evaluate();
        }
        lastMX = e.x;
        lastMY = e.y;
        return true;
    }

    /// Priority order: angle handles first (smaller on-screen targets at
    /// the default 0.7·gizmoSize radius vs. the axis handles' arbitrary
    /// world-space arm, which can be much larger or smaller), then the two
    /// axis-endpoint handles.
    private int hitTestHandles(int mx, int my) {
        if (startAngleH.hitTest(mx, my, cachedVp)) return 2;
        if (endAngleH.hitTest(mx, my, cachedVp))   return 3;
        if (axisStartH.hitTest(mx, my, cachedVp))  return 0;
        if (axisEndH.hitTest(mx, my, cachedVp))    return 1;
        return -1;
    }
}
