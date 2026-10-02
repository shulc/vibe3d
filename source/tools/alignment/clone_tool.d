module tools.alignment.clone_tool;

import display_state : DrawPlan;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolParamDoorClient, PreparedPrivateStateToolDoorClient;
import prepared_private_state : PreparedPrivateStateOwner;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedDeactivateEffect, PreparedDeactivateKind;
import document : Layer;

import bindbc.sdl;
import operator : VectorStack;
import tool;
import command : Command;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import editmode : EditMode;
import drag : planeDragDelta;
import overlay_space : OverlaySpace;
import params : Param, IntEnumEntry;
import shader : Shader;
import snapshot : MeshSnapshot;
import display_sync : refreshDisplay;

// mesh.clone is a linear generator followed by a clone effector. `num` is the
// number of ADDED copies; all copies advance by the same 3-D offset. A second
// haul changes that offset and regenerates from the original source cage.
class CloneTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient,
        TopologyStepClient {
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, commandClose: CommandClose.uiDoor,
            sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress,
            imageAttrs: ["num", "offX", "offY", "offZ", "sclX", "sclY", "sclZ",
                "angP", "angH", "angB", "between", "snap", "snapAngle",
                "replace", "flip", "merge", "dist", "source", "item"],
            haulAttrs: ["num", "offX", "offY", "offZ", "sclX", "sclY", "sclZ",
                "angP", "angH", "angB", "between", "snap", "snapAngle",
                "replace", "flip", "merge", "dist", "source", "item"]
        };
        return policy;
    }

    mixin PreparedPrivateStateToolDoorClient!(Layer,
        PreparedPrivateStateOwner.cloneSession);
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh* gpu;
    EditMode* editMode;

    enum SourceMode { Active, Specific, Inactive, Random, Preset }
    static immutable IntEnumEntry[5] sourceTable = [
        IntEnumEntry(cast(int)SourceMode.Active, "active", "Active Meshes"),
        IntEnumEntry(cast(int)SourceMode.Specific, "specific", "Specific Mesh"),
        IntEnumEntry(cast(int)SourceMode.Inactive, "inactive", "All BG"),
        IntEnumEntry(cast(int)SourceMode.Random, "random", "Random BG"),
        IntEnumEntry(cast(int)SourceMode.Preset, "preset", "Preset Shape"),
    ];

    int num_ = 1;
    float offX_ = 0, offY_ = 0, offZ_ = 0;
    float sclX_ = 100, sclY_ = 100, sclZ_ = 100;
    float angP_ = 0, angH_ = 0, angB_ = 0;
    bool between_, snap_ = true;
    float snapAngle_ = 45;
    bool replace_, flip_, merge_;
    float dist_ = 0;
    SourceMode source_ = SourceMode.Active;
    string item_ = "";

    bool active, built, dragging;
    MeshSnapshot before;
    int anchorMX, anchorMY;
    Vec3 anchorWorld, dragBaseOffset;
    OverlaySpace dragSpace;
    Viewport cachedVp;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        this.meshSrc_ = meshSrc;
        this.gpu = gpu;
        this.editMode = editMode;
    }

    override string name() const { return "Clone"; }
    override EditMode[] supportedModes() const { return [EditMode.Polygons]; }

    override Param[] params() {
        return [
            Param.int_("num", "Number of Clones", &num_, 1).min(1).max(255).enforceBounds(),
            Param.float_("offX", "Offset X", &offX_, 0),
            Param.float_("offY", "Offset Y", &offY_, 0),
            Param.float_("offZ", "Offset Z", &offZ_, 0),
            Param.float_("sclX", "Scale X", &sclX_, 100).min(0),
            Param.float_("sclY", "Scale Y", &sclY_, 100).min(0),
            Param.float_("sclZ", "Scale Z", &sclZ_, 100).min(0),
            Param.float_("angP", "Rotate X", &angP_, 0).angle(),
            Param.float_("angH", "Rotate Y", &angH_, 0).angle(),
            Param.float_("angB", "Rotate Z", &angB_, 0).angle(),
            Param.bool_("between", "Between", &between_, false),
            Param.bool_("snap", "Angle Snap", &snap_, true),
            Param.float_("snapAngle", "Angle", &snapAngle_, 45).angle().min(0),
            Param.bool_("replace", "Replace Source", &replace_, false),
            Param.bool_("flip", "Invert Polygons", &flip_, false),
            Param.bool_("merge", "Merge Vertices", &merge_, false),
            Param.float_("dist", "Distance", &dist_, 0).min(0),
            Param.intEnum_("source", "Source", cast(int*)&source_,
                           sourceTable, cast(int)SourceMode.Active),
            Param.string_("item", "Mesh Item", &item_, ""),
        ];
    }
    override bool paramEnabled(string pname) const {
        if (pname == "dist") return merge_;
        if (pname == "item") return source_ == SourceMode.Specific;
        if (pname == "snapAngle") return snap_;
        return true;
    }

    override void activate() {
        active = true; built = dragging = false;
        before = MeshSnapshot.capture(*mesh);
    }
    final MeshSnapshot prepareActivationBaseline() { return MeshSnapshot.capture(*mesh); }
    final void installPreparedActivation(ref MeshSnapshot image) nothrow @nogc {
        active = true; built = dragging = false; image.moveInto(before);
    }
    final PreparedSessionActivateEffect prepareActivate(PreparedRecordContext context,
            PreparedPrivateStateOwner owner) {
        bool accepted = context !is null && owner !is null && owner.owns(this) &&
            context.preparePrivateState(owner) && context.markNoHistoryInstall();
        if (!accepted && context !is null) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.Clone, accepted);
    }
    version(unittest) void seedPreparedActivationForTest() nothrow @nogc {
        active = false; built = dragging = true;
    }
    version(unittest) bool preparedActivationInstalledForTest() const nothrow @nogc {
        return active && !built && !dragging && before.filled;
    }

    override void deactivate() { active = built = dragging = false; }
    override bool hasUncommittedEdit() const { return active && dragging && built; }
    override void cancelUncommittedEdit() { cancelLiveEdit(); }
    override void resyncSession() {
        if (!active) return;
        if (built && before.filled) before.restore(*mesh);
        built = dragging = false;
        before = MeshSnapshot.capture(*mesh);
        refreshCaches();
    }
    override bool commitUncommittedEdit() { return false; }
    override bool commitOperation() {
        if (!active) return false;
        before = MeshSnapshot.capture(*mesh);
        built = dragging = false;
        return true;
    }

    override Mesh* topologyStepMesh() { return mesh; }
    override MeshSnapshot topologyStepBasis() { return before; }
    override Command topologyStepCarrier() {
        return gestureFactory is null ? null : gestureFactory();
    }
    override bool recordTopologyStep(Command cmd) {
        return recordGestureEdit(cmd, GestureRecordMode.Plain);
    }
    override string topologyStepLabel() { return "Clone"; }
    override void setTopologyDormant(bool dormant) {}
    override void rebaseTopologyStep(MeshSnapshot basis) {
        before = basis;
        built = dragging = false;
        refreshCaches();
    }
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot basis) {
        restoreRecordedAttrs(attrs);
        rebaseTopologyStep(basis);
    }

    override void onParamChanged(string pname) {
        if (interactiveParamEdit && active) rebuildPreview();
    }
    // Prepared activation injects scripted/sticky values before the first
    // press. Those writes only change the parameter image; there is no mesh
    // preview to publish until an interactive edit or a viewport gesture.
    override bool prepareDoorParamChanged(string, PreparedRecordContext context,
            Layer, ulong, ulong) {
        return context !is null && context.markNoHistoryInstall();
    }
    override void evaluate() {}
    override bool applyHeadless() {
        if (mesh.faces.length == 0) return false;
        if (built && before.filled) before.restore(*mesh);
        auto mask = mesh.operandFaceMask();
        size_t n = build(mask);
        if (n == 0 && !replace_) return false;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { closeOwnOperation(false); return true; }
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (SDL_GetModState() & (KMOD_ALT | KMOD_SHIFT)) return false;
        if (*editMode != EditMode.Polygons || !mesh.hasAnySelectedFaces()) return false;
        sessionStepBegins();
        anchorMX = e.x; anchorMY = e.y;
        dragSpace = OverlaySpace.ofPrimary();
        anchorWorld = dragSpace.pos(mesh.selectionCentroidFaces());
        dragBaseOffset = offsetVec();
        dragging = true;
        return true;
    }
    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !dragging || e.button != SDL_BUTTON_LEFT) return false;
        dragging = false;
        sessionStepEnds();
        built = false;
        return true;
    }
    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !dragging) return false;
        bool skip;
        Vec3 delta = planeDragDelta(e.x, e.y, anchorMX, anchorMY,
                                    3, anchorWorld, cachedVp, skip);
        if (!skip) {
            Vec3 local = dragSpace.toLocalDelta(delta);
            offX_ = dragBaseOffset.x + local.x;
            offY_ = dragBaseOffset.y + local.y;
            offZ_ = dragBaseOffset.z + local.z;
            rebuildPreview();
        }
        return true;
    }
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        cachedVp = vp;
    }

private:
    Vec3 offsetVec() const { return Vec3(offX_, offY_, offZ_); }
    size_t build(in bool[] mask) {
        return mesh.arrayFacesGrid(mask, num_ + 1, 1, 1, offsetVec(), Vec3(0, 0, 0),
            Vec3(sclX_ / 100, sclY_ / 100, sclZ_ / 100),
            Vec3(angP_, angH_, angB_), between_, replace_, flip_, merge_, dist_, true);
    }
    void rebuildPreview() {
        if (!active || !before.filled) return;
        before.restore(*mesh);
        auto mask = mesh.operandFaceMask();
        size_t n = build(mask);
        built = (n != 0) || replace_;
        refreshCaches();
    }
    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context) {
        if (context is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.Clone, false, false);
        const accepted = context.markNoHistoryInstall();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Clone, false, accepted);
    }
    void cancelLiveEdit() {
        if (built && before.filled) { before.restore(*mesh); refreshCaches(); }
        built = dragging = false;
    }
    void refreshCaches() { refreshDisplay(mesh, gpu); }
}
