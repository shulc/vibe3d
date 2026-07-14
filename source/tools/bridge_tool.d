module tools.bridge_tool;

import bindbc.opengl;
import bindbc.sdl;

import operator : VectorStack;
import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import shader : Shader, LitShader;
import std.json : JSONValue;

version (unittest) import std.conv : to;

// Reuses the same generic (pre, post) MeshSnapshot pair as Mirror/Tack
// (MeshBevelEdit / bevelEditFactory) — see tools/mirror.d's
// MirrorEditFactory doc comment. Despite the name, it's a fully generic
// snapshot-diff undo command, not bevel-specific.
alias BridgeEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// BridgeParams — single source of truth for the Bridge tool (task 0357),
// mirrors MirrorParams / TackParams. Every drag / panel edit / headless
// attr write goes into this struct; the preview + commit derive from it.
//
// `segments` is vibe3d's own span-count convention (spans = max(1, value);
// spans-1 interior rings, linearly interpolated at t=i/spans) — the
// reference tool's wire default of 0 (meaning "1 span, no interior rings")
// collapses to the same geometry through the same formula, so vibe3d's
// Param just defaults straight to 1 and clamps its floor there (task 0357
// finding: UI-convention translation belongs at the tool layer, not a
// special-cased kernel default — see project memory
// project_radial_sweep_tool.md).
//
// `flip` is vibe3d's PRE-EXISTING loop-pairing override (mesh.bridgeLoops'
// own `flip` param — picks the reversed nearest-vertex pairing direction).
// This is a DIFFERENT concept from the reference tool's "Flip Polygons"
// (a true per-face normal flip, not ported here) — labelled "Flip Loop
// Pairing" in the panel to keep the two concepts visually distinct (task
// 0357 naming caution).
struct BridgeParams {
    int   segments = 1;
    float twist    = 0.0f;
    bool  remove   = true;
    bool  flip     = false;
}

// ---------------------------------------------------------------------------
// resolveBridgeSelection — builds the two boundary loops + the face
// index(es), if any, Remove Polygons should delete, from the mesh's LIVE
// selection state. Shared by activate() (interactive) and applyHeadless()
// (fold #1, mirroring Mirror/Tack: a throwaway ToolHeadlessCommand instance
// never calls activate(), so this must be independently callable).
//
// Polygon mode: exactly 2 selected faces; capFaces = those 2 faces
// (unconditional, matching commands.mesh.bridge's existing Polygon-mode
// behaviour when remove is on).
//
// Edge mode: selected edges must form exactly 2 disjoint chains — EITHER
// both closed simple vertex cycles OR both OPEN rows (task 0395; a mix of
// one open + one closed is a no-op, deferred — see task 0395 plan).
// capFaces = whatever EXISTING faces (0, 1, or 2) are exactly bounded by
// one of the two loops (facesMatchingLoop) — task 0357 generalizes
// commands.mesh.bridge's Polygon-only Remove Polygons to Edge mode: most
// edge-mode bridges bound no face at all (an open hole, OR any open-row
// bridge — an open chain never bounds a face), in which case this is an
// empty, safe no-op, exactly matching vibe3d's pre-existing edge-mode
// behaviour.
// ---------------------------------------------------------------------------
struct BridgeSelectionResolved {
    bool   valid;
    bool   polygonMode;
    bool   openRows;      // task 0395: true when both chains are OPEN rows
    uint[] loopA, loopB;
    uint[] capFaces;
}

BridgeSelectionResolved resolveBridgeSelection(ref Mesh m, EditMode editMode) {
    BridgeSelectionResolved r;
    if (editMode == EditMode.Polygons) {
        uint[] selFaces;
        foreach (fi; 0 .. m.faces.length)
            if (m.isFaceSelected(fi)) selFaces ~= cast(uint)fi;
        if (selFaces.length != 2) return r;
        r.loopA       = m.faceVertexRing(selFaces[0]);
        r.loopB       = m.faceVertexRing(selFaces[1]);
        r.capFaces    = selFaces;
        r.polygonMode = true;
        r.valid       = true;
    } else if (editMode == EditMode.Edges) {
        // extractSelectedEdgeChains (task 0395) generalizes the pre-existing
        // extractSelectedEdgeCycles (closed-only) to also recognize OPEN
        // rows — extractSelectedEdgeCycles itself is left untouched.
        auto chains = m.extractSelectedEdgeChains();
        if (chains.length != 2) return r;
        immutable bool bothClosed = chains[0].closed && chains[1].closed;
        immutable bool bothOpen   = !chains[0].closed && !chains[1].closed;
        if (!bothClosed && !bothOpen) return r;   // mixed open+closed: no-op, deferred (task 0395)
        r.loopA       = chains[0].verts;
        r.loopB       = chains[1].verts;
        r.openRows    = bothOpen;
        r.capFaces    = facesMatchingLoop(m, r.loopA) ~ facesMatchingLoop(m, r.loopB);
        r.polygonMode = false;
        r.valid       = true;
    }
    return r;
}

/// Face indices in `m` whose vertex ring is a cyclic rotation (either
/// winding direction) of `loop` — the Edge-mode Remove Polygons lookup
/// (see resolveBridgeSelection's doc comment). O(faces * loop-length^2);
/// fine for interactive-tool-sized meshes.
uint[] facesMatchingLoop(const ref Mesh m, const(uint)[] loop) {
    uint[] hits;
    const size_t N = loop.length;
    outer: foreach (fi; 0 .. m.faces.length) {
        auto fv = m.faces[fi];
        if (fv.length != N) continue;
        foreach (start; 0 .. N) {
            bool fwd = true, rev = true;
            foreach (i; 0 .. N) {
                if (fwd && fv[i] != loop[(start + i) % N]) fwd = false;
                if (rev && fv[i] != loop[(start + N - i) % N]) rev = false;
                if (!fwd && !rev) break;
            }
            if (fwd || rev) { hits ~= cast(uint)fi; continue outer; }
        }
    }
    return hits;
}

/// Result of one bridge application — faces added by the kernel (0 = the
/// kernel rejected the loops) and whether a cap/bounded-face deletion ran
/// (deleteFacesByMask already rebuilds loops internally when it does).
struct BridgeApplyResult {
    size_t added;
    bool   removed;
}

/// Apply one bridge (multi-span + twist kernel, then optional Remove
/// Polygons) onto `m`. `capFaces` is only consulted when `p.remove` is
/// true; an empty `capFaces` (the common Edge-mode "no bounding face"
/// case) is a safe no-op for the deletion step regardless.
///
/// `openRows` (task 0395) selects the kernel: closed loops / polygon rings
/// use the pre-existing `bridgeLoopsSpans`; two OPEN edge rows use
/// `bridgeOpenRows` (proximity pairing, fan on unequal length, no wrap).
BridgeApplyResult applyBridgeOp(ref Mesh m, const(uint)[] loopA, const(uint)[] loopB,
                                const(uint)[] capFaces, in BridgeParams p,
                                bool openRows = false) {
    BridgeApplyResult r;
    uint spans = (p.segments < 1) ? 1u : cast(uint)p.segments;
    r.added = openRows
        ? m.bridgeOpenRows(loopA, loopB, p.flip, spans, p.twist)
        : m.bridgeLoopsSpans(loopA, loopB, p.flip, spans, p.twist);
    if (r.added == 0) return r;

    if (p.remove && capFaces.length > 0) {
        auto mask = new bool[](m.faces.length);
        bool any = false;
        foreach (fi; capFaces)
            if (fi < mask.length) { mask[fi] = true; any = true; }
        if (any && m.deleteFacesByMask(mask) > 0)
            r.removed = true;
    }
    if (!r.removed) m.buildLoops();
    return r;
}

/// Non-cumulative preview rebuild (mirrors tools/mirror.d's
/// rebuildMirrorPreview / tools/tack.d's rebuildTackPreview): restores
/// `previewMesh` fully from `baseSnap` EVERY call, then re-applies the
/// bridge fresh — so N successive evaluate() calls never accumulate new
/// rings on top of each other.
void rebuildBridgePreview(const ref MeshSnapshot baseSnap, ref Mesh previewMesh,
                          in uint[] loopA, in uint[] loopB, in uint[] capFaces,
                          in BridgeParams params_, bool openRows = false) {
    baseSnap.restore(previewMesh);
    if (loopA.length == 0 || loopB.length == 0) return;
    applyBridgeOp(previewMesh, loopA, loopB, capFaces, params_, openRows);
}

// ---------------------------------------------------------------------------
// BridgeTool — interactive multi-span/twist bridge (factory id
// `mesh.bridgeTool`). A generator tool (Mirror/Tack precedent, project
// memory project_radial_sweep_tool.md): own preview Mesh/GpuMesh that is
// NEVER the document mesh during interaction; committed once in
// deactivate() via the generic MeshBevelEdit snapshot-diff undo path.
//
// No gizmo/handle (task 0357 toolcard: the reference tool is ACTR-class,
// same family as edge.slide/sweep — a click-drag single-numeric-value
// generator, not a T/R/S transform-gizmo tool; the captured viewport
// screenshot shows no handle drawn on activation). The boundary selection
// (2 polygons, or 2 disjoint closed edge cycles) is picked BEFORE
// activation and frozen at activate() time — Bridge does not support
// re-picking mid-session, matching the reference tool's own documented
// gesture ("select at least two polygons/edges ... clicking the tool icon
// activates the tool").
//
// Interaction: any LMB click+drag in the viewport (no handle to hit)
// adjusts Segments, mapping horizontal pixel delta to an integer span
// count; Twist / Remove Polygons / Flip Loop Pairing are panel-only.
// ---------------------------------------------------------------------------
class BridgeTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    LitShader        litShader;
    EditMode*        editModePtr;

    CommandHistory     history;
    BridgeEditFactory  bridgeEditFactory;

    BridgeParams params_;

    // Selection frozen at activate() (fold #1 mirror: applyHeadless()
    // re-derives its OWN copy via resolveBridgeSelection rather than
    // reading these fields — a throwaway ToolHeadlessCommand instance
    // never calls activate()).
    bool   valid_;
    bool   polygonMode_;
    bool   openRows_;      // task 0395: true when both selected chains are OPEN rows
    uint[] loopA_, loopB_, capFaces_;

    MeshSnapshot baseSnap_;
    Mesh         previewMesh_;
    GpuMesh      previewGpu_;

    // Dirty guard (mirrors Mirror's havePreviewCache/cached* fields):
    // evaluate() is called every frame the Tool Properties panel is open,
    // and on every drag-motion event — without this, a full snapshot-
    // restore + kernel run + buildLoops + GPU upload would happen every
    // such call even when nothing changed.
    bool  havePreviewCache;
    int   cachedSegments;
    float cachedTwist;
    bool  cachedRemove;
    bool  cachedFlip;

    // Commit guard: true once the user has actually interacted (drag or
    // panel/headless attr write) — mirrors Mirror's `engaged`.
    bool engaged;

    // Drag state (Segments-only; no handle to hit-test against).
    bool dragging_;
    int  dragStartX_;
    int  dragStartSegments_;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader, EditMode* editModePtr) {
        this.meshSrc_     = meshSrc;
        this.gpu          = gpu;
        this.litShader    = litShader;
        this.editModePtr  = editModePtr;
    }

    void destroy() {}

    void setUndoBindings(CommandHistory h, BridgeEditFactory factory) {
        this.history           = h;
        this.bridgeEditFactory = factory;
    }

    override string name() const { return "Bridge"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Edges, EditMode.Polygons];
    }

    private EditMode editModeVal() const {
        return (editModePtr is null) ? EditMode.Polygons : *editModePtr;
    }

    override void activate() {
        if (meshSrc_ is null) return;
        auto resolved = resolveBridgeSelection(*mesh, editModeVal());
        valid_       = resolved.valid;
        polygonMode_ = resolved.polygonMode;
        openRows_    = resolved.openRows;
        loopA_       = resolved.loopA;
        loopB_       = resolved.loopB;
        capFaces_    = resolved.capFaces;

        baseSnap_        = MeshSnapshot.capture(*mesh);
        engaged          = false;
        dragging_        = false;
        havePreviewCache = false;
        previewGpu_.init();
        if (valid_) evaluate();
    }

    override void deactivate() {
        bool willCommit = engaged && valid_;
        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        size_t inserted = 0;
        if (willCommit) {
            auto res = applyBridgeOp(*mesh, loopA_, loopB_, capFaces_, params_, openRows_);
            inserted = res.added;
            if (inserted > 0) gpu.upload(*mesh);
        }

        previewGpu_.destroy();
        if (willCommit && inserted > 0) commitBridgeEdit(pre);
        engaged          = false;
        havePreviewCache = false;
    }

    // ----- History-coordination hooks (mirror Mirror's, tools/mirror.d) ----

    public override bool hasUncommittedEdit() const { return engaged; }

    public override void cancelUncommittedEdit() {
        // The document mesh was never touched during interaction (own
        // preview mesh) — nothing to revert, just drop the guard.
        engaged = false;
    }

    public override void resyncSession() {
        // External undo/redo moved geometry beneath the tool — re-resolve
        // the selection against the now-current mesh and force the
        // preview to rebuild from the new baseline.
        auto resolved = resolveBridgeSelection(*mesh, editModeVal());
        valid_       = resolved.valid;
        polygonMode_ = resolved.polygonMode;
        openRows_    = resolved.openRows;
        loopA_       = resolved.loopA;
        loopB_       = resolved.loopB;
        capFaces_    = resolved.capFaces;
        baseSnap_        = MeshSnapshot.capture(*mesh);
        havePreviewCache = false;
        if (valid_) evaluate();
    }

    private void commitBridgeEdit(MeshSnapshot pre) {
        if (history is null || bridgeEditFactory is null) return;
        auto cmd  = bridgeEditFactory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Bridge");
        history.record(cmd);
    }

    // ----- Params / panel ----------------------------------------------

    override Param[] params() {
        return [
            Param.int_("segments", "Segments", &params_.segments, 1)
                .min(1).max(64).enforceBounds(),
            Param.float_("twist", "Twist", &params_.twist, 0.0f)
                .min(-16.0f).max(16.0f).enforceBounds(),
            Param.bool_("remove", "Remove Polygons", &params_.remove, true),
            Param.bool_("flip", "Flip Loop Pairing", &params_.flip, false),
        ];
    }

    override void onParamChanged(string name) {
        engaged = true;
    }

    override bool drawImGui() { return false; }

    // ----- Headless one-shot (fold #1: builds its OWN selection from the
    // live mesh — ToolHeadlessCommand never calls activate()). -----------

    override bool applyHeadless() {
        auto resolved = resolveBridgeSelection(*mesh, editModeVal());
        if (!resolved.valid) return false;
        auto res = applyBridgeOp(*mesh, resolved.loopA, resolved.loopB,
                                 resolved.capFaces, params_, resolved.openRows);
        if (res.added == 0) return false;
        gpu.upload(*mesh);
        return true;
    }

    // ----- Test-introspection (task 0234 pattern, GET /api/tool/state) ----

    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("mesh.bridgeTool");
        root["valid"]       = JSONValue(valid_);
        root["polygonMode"] = JSONValue(polygonMode_);
        root["openRows"]    = JSONValue(openRows_);
        root["engaged"]     = JSONValue(engaged);
        root["segments"]    = JSONValue(params_.segments);
        root["twist"]       = JSONValue(params_.twist);
        root["remove"]      = JSONValue(params_.remove);
        root["flip"]        = JSONValue(params_.flip);
        return root;
    }

    // ----- Live preview ---------------------------------------------------

    private void rebuildPreviewMesh() {
        rebuildBridgePreview(baseSnap_, previewMesh_, loopA_, loopB_, capFaces_, params_, openRows_);
    }

    override void evaluate() {
        if (!valid_) return;
        if (havePreviewCache
            && cachedSegments == params_.segments
            && cachedTwist    == params_.twist
            && cachedRemove   == params_.remove
            && cachedFlip     == params_.flip)
            return;

        rebuildPreviewMesh();
        previewGpu_.upload(previewMesh_);

        cachedSegments   = params_.segments;
        cachedTwist      = params_.twist;
        cachedRemove     = params_.remove;
        cachedFlip       = params_.flip;
        havePreviewCache = true;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        if (!valid_ || !havePreviewCache) return;

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

        previewGpu_.drawFaces(litShader);

        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        previewGpu_.drawEdges(shader.locColor, -1, []);
    }

    // ----- Segments drag (no handle — any LMB click+drag adjusts it) ------

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!valid_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;   // reserved for camera

        dragging_          = true;
        dragStartX_        = e.x;
        dragStartSegments_ = params_.segments;
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (!dragging_) return false;
        dragging_ = false;
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!dragging_) return false;

        enum int pxPerSegment = 20;   // drag sensitivity — unmeasured (see task 0357 toolcard:
                                       // the reference drag-to-Segments pixel sensitivity was
                                       // never RFB-captured, only the resulting Segments->
                                       // geometry law was verified numerically via tool.attr)
        int dx = e.x - dragStartX_;
        int newSegments = dragStartSegments_ + (dx / pxPerSegment);
        if (newSegments < 1)  newSegments = 1;
        if (newSegments > 64) newSegments = 64;   // mirrors the Param's own UI max

        if (newSegments != params_.segments) {
            params_.segments = newSegments;
            engaged = true;
            evaluate();
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Module unittests — dubtest-lane parity + regression gate (task 0357).
// CPU-only (plain Mesh, no GpuMesh/GL): exercises resolveBridgeSelection /
// applyBridgeOp / rebuildBridgePreview directly, mirroring
// tools/mirror.d's / tools/tack.d's free-function unittest pattern.
// ---------------------------------------------------------------------------

private Mesh makeTwoCapMesh() {
    // Same fixture as tests/test_bridge.d's loadCaps(): two coaxial unit
    // squares, cap A at z=0 (face 0), cap B at z=1 (face 1).
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    m.buildLoops();
    // selectFace/selectEdge index straight into faceMarks/edgeMarks without
    // auto-growing (addFace/addEdge don't touch them) — size explicitly so
    // the unittests below can select() before running the tool.
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;
    return m;
}

unittest { // Polygon mode, spans=1: remove=true/false are bit-exact both
           // states (task 0357 Remove Polygons requirement).
    Mesh m1 = makeTwoCapMesh();
    m1.selectFace(0);
    m1.selectFace(1);
    auto sel1 = resolveBridgeSelection(m1, EditMode.Polygons);
    assert(sel1.valid && sel1.polygonMode, "polygon-mode selection must resolve");
    assert(sel1.capFaces.length == 2, "polygon mode: capFaces = the 2 selected faces");

    BridgeParams p1; p1.segments = 1; p1.remove = true;
    auto r1 = applyBridgeOp(m1, sel1.loopA, sel1.loopB, sel1.capFaces, p1);
    assert(r1.added == 4, "spans=1: expected 4 bridge quads");
    assert(r1.removed, "remove=true must delete the 2 caps");
    assert(m1.faces.length == 4, "remove=true: expected 4 faces, got "
        ~ m1.faces.length.to!string);
    assert(m1.vertices.length == 8, "remove=true: no new verts at spans=1");

    Mesh m2 = makeTwoCapMesh();
    m2.selectFace(0);
    m2.selectFace(1);
    auto sel2 = resolveBridgeSelection(m2, EditMode.Polygons);
    BridgeParams p2; p2.segments = 1; p2.remove = false;
    auto r2 = applyBridgeOp(m2, sel2.loopA, sel2.loopB, sel2.capFaces, p2);
    assert(r2.added == 4, "spans=1: expected 4 bridge quads");
    assert(!r2.removed, "remove=false must NOT delete the caps");
    assert(m2.faces.length == 6, "remove=false: expected 6 faces (2 caps + 4 bridge), got "
        ~ m2.faces.length.to!string);
    assert(m2.vertices.length == 8, "remove=false: no new verts at spans=1");
}

unittest { // Edge mode: remove=true generalizes to deleting a face that
           // happens to be exactly bounded by a bridged loop (task 0357
           // closes the "edge-mode never removes" gap on the NEW tool
           // only — commands.mesh.bridge's existing one-shot Command is
           // untouched and keeps its own always-preserve behaviour).
    Mesh m = makeTwoCapMesh();
    // Select every edge of both cap rims (mirrors test_bridge.d's edge-mode
    // setup) — no explicit vertex/edge selection API on the bare Mesh here,
    // so drive it through markEdgeSelected by scanning for the two rims.
    foreach (ei; 0 .. m.edges.length) {
        auto e = m.edges[ei];
        bool bothA = e[0] < 4 && e[1] < 4;
        bool bothB = e[0] >= 4 && e[1] >= 4;
        if (bothA || bothB) m.selectEdge(cast(int)ei);
    }
    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid && !sel.polygonMode, "edge-mode selection must resolve");
    assert(sel.capFaces.length == 2,
        "edge mode: both cap faces are exactly bounded by their rim loop, expected 2 capFaces, got "
        ~ sel.capFaces.length.to!string);

    BridgeParams p; p.segments = 1; p.remove = true;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p);
    assert(r.added == 4, "edge mode spans=1: expected 4 bridge quads");
    assert(r.removed, "edge mode remove=true must delete the 2 bounding caps");
    assert(m.faces.length == 4, "edge mode remove=true: expected 4 faces, got "
        ~ m.faces.length.to!string);
}

unittest { // Edge mode: remove=true is a safe no-op when the loop bounds
           // no existing face (the common "open hole" case — matches
           // vibe3d's pre-existing edge-mode behaviour).
    Mesh m;
    // Two disjoint square rims with NO cap faces at all — just the 4 side
    // quads connecting them (an already-open tube).
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    m.addFace([0u,1u,5u,4u]);
    m.addFace([1u,2u,6u,5u]);
    m.addFace([2u,3u,7u,6u]);
    m.addFace([3u,0u,4u,7u]);
    m.buildLoops();
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;
    foreach (ei; 0 .. m.edges.length) {
        auto e = m.edges[ei];
        bool bothA = e[0] < 4 && e[1] < 4;
        bool bothB = e[0] >= 4 && e[1] >= 4;
        if (bothA || bothB) m.selectEdge(cast(int)ei);
    }
    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid, "edge-mode selection must resolve");
    assert(sel.capFaces.length == 0, "no face bounds either rim on an open tube");

    BridgeParams p; p.segments = 1; p.remove = true;
    size_t facesBefore = m.faces.length;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p);
    assert(r.added == 4, "expected 4 new bridge quads");
    assert(!r.removed, "no cap face existed to remove");
    assert(m.faces.length == facesBefore + 4, "face count: 4 existing + 4 new");
}

unittest { // rebuildBridgePreview is NON-CUMULATIVE — 5 repeat calls land
           // on the identical vertex/face count (mirrors tools/mirror.d's
           // / tools/tack.d's own non-cumulative proof).
    Mesh baseMesh = makeTwoCapMesh();
    baseMesh.selectFace(0);
    baseMesh.selectFace(1);
    auto sel = resolveBridgeSelection(baseMesh, EditMode.Polygons);
    assert(sel.valid);

    import snapshot : MeshSnapshot;
    MeshSnapshot baseSnap = MeshSnapshot.capture(baseMesh);

    BridgeParams p; p.segments = 3; p.twist = 1.0f; p.remove = true;

    Mesh previewMesh;
    size_t expectedVerts = size_t.max, expectedFaces = size_t.max;
    foreach (i; 0 .. 5) {
        rebuildBridgePreview(baseSnap, previewMesh, sel.loopA, sel.loopB, sel.capFaces, p);
        if (i == 0) {
            expectedVerts = previewMesh.vertices.length;
            expectedFaces = previewMesh.faces.length;
            assert(expectedVerts == 16, "expected 8 orig + 8 new verts, got "
                ~ expectedVerts.to!string);
            assert(expectedFaces == 12, "expected 12 faces (3 spans * 4), got "
                ~ expectedFaces.to!string);
        } else {
            assert(previewMesh.vertices.length == expectedVerts,
                "preview accumulated verts on repeat #" ~ i.to!string);
            assert(previewMesh.faces.length == expectedFaces,
                "preview accumulated faces on repeat #" ~ i.to!string);
        }
    }
}

unittest { // Edge mode OPEN rows (task 0395 owner repro): cube minus 2
           // adjacent faces (8v/4f), select the 4 boundary edges away from
           // the two connector edges (two 2-edge open arcs) — resolve must
           // be valid + openRows=true + capFaces EMPTY (an open chain never
           // bounds an existing face), and applyBridgeOp(spans=1) must
           // reconstruct the 2 deleted faces bit-for-bit: 8v/4f -> 8v/6f,
           // reusing the existing boundary vertices (no new verts).
    int findEdge(ref Mesh m, uint a, uint b) {
        foreach (ei; 0 .. m.edges.length) {
            auto e = m.edges[ei];
            if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) return cast(int)ei;
        }
        return -1;
    }

    Mesh m;
    m.addVertex(Vec3(-0.5,-0.5,-0.5)); m.addVertex(Vec3(0.5,-0.5,-0.5));
    m.addVertex(Vec3(0.5,0.5,-0.5));   m.addVertex(Vec3(-0.5,0.5,-0.5));
    m.addVertex(Vec3(-0.5,-0.5,0.5));  m.addVertex(Vec3(0.5,-0.5,0.5));
    m.addVertex(Vec3(0.5,0.5,0.5));    m.addVertex(Vec3(-0.5,0.5,0.5));
    m.addFace([0u,3u,2u,1u]);
    m.addFace([4u,5u,6u,7u]);
    m.addFace([0u,4u,7u,3u]);
    m.addFace([0u,1u,5u,4u]);
    m.buildLoops();
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;

    int e32 = findEdge(m, 3, 2), e21 = findEdge(m, 2, 1);
    int e56 = findEdge(m, 5, 6), e67 = findEdge(m, 6, 7);
    assert(e32 >= 0 && e21 >= 0 && e56 >= 0 && e67 >= 0,
        "owner repro: all 4 boundary edges must exist on the fixture mesh");
    m.selectEdge(e32); m.selectEdge(e21);
    m.selectEdge(e56); m.selectEdge(e67);

    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid, "owner repro: two open rows must resolve valid (was a silent no-op pre-0395)");
    assert(sel.openRows, "owner repro: must be detected as openRows");
    assert(!sel.polygonMode, "owner repro: edge mode is not polygonMode");
    assert(sel.capFaces.length == 0,
        "owner repro: open rows never bound an existing face, expected empty capFaces, got "
        ~ sel.capFaces.length.to!string);

    BridgeParams p; p.segments = 1; p.remove = true;
    size_t facesBefore = m.faces.length, vertsBefore = m.vertices.length;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p, sel.openRows);
    assert(r.added == 2, "owner repro: expected 2 new quads, got " ~ r.added.to!string);
    assert(!r.removed, "owner repro: capFaces empty, nothing to remove");
    assert(m.faces.length == facesBefore + 2,
        "owner repro: expected 8v/6f (4+2 quads), got " ~ m.faces.length.to!string ~ " faces");
    assert(m.vertices.length == vertsBefore,
        "owner repro: bridge must reuse existing boundary verts, no new verts");

    // Winding-consistency (task 0395 rr-refinement): each new bridge face
    // must traverse any edge it shares with a PRE-EXISTING face in the
    // OPPOSITE direction — the same half-edge manifold invariant
    // `orientFaceConsistent` enforces for `makePolygonFromVerts` (task
    // 0394), now reused by `bridgeStripPaired`/`bridgeFanRows`. A
    // same-direction shared edge would corrupt the half-edge fan there —
    // this is exactly the connected-topology case the owner repro exercises
    // (both new quads border two of the cube's 4 remaining original faces).
    bool sharesEdgeSameDirection(const(uint)[] a, const(uint)[] b) {
        foreach (i; 0 .. a.length) {
            uint u = a[i], v = a[(i + 1) % a.length];
            foreach (k; 0 .. b.length) {
                uint p = b[k], q = b[(k + 1) % b.length];
                if (u == p && v == q) return true;
            }
        }
        return false;
    }
    foreach (nfi; facesBefore .. m.faces.length)
        foreach (ofi; 0 .. facesBefore)
            assert(!sharesEdgeSameDirection(m.faces[nfi], m.faces[ofi]),
                "owner repro: new face " ~ nfi.to!string ~ " traverses a shared edge in the "
                ~ "SAME direction as pre-existing face " ~ ofi.to!string ~ " (winding corruption)");
}

unittest { // Edge mode: mixed open+closed selection is a safe no-op
           // (deferred, task 0395) — resolve must report invalid, not crash
           // or silently pick one interpretation.
    Mesh m;
    // Open chain: verts 0-1-2.
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
    // Closed cycle: verts 3-4-5-6.
    m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0));
    m.addVertex(Vec3(1,2,0)); m.addVertex(Vec3(0,2,0));
    m.addEdge(0, 1); m.addEdge(1, 2);
    m.addEdge(3, 4); m.addEdge(4, 5); m.addEdge(5, 6); m.addEdge(6, 3);
    m.buildLoops();
    m.resizeEdgeSelection();
    foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(!sel.valid, "mixed open+closed selection must resolve invalid (no-op), not pick a side");
}
