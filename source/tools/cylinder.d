module tools.cylinder;

import bindbc.opengl;
import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import handler : MoveHandler, BoxHandler, gizmoSize;
import drag : axisDragDelta, planeDragDelta, screenAxisDelta;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import tools.create_common : pickWorkplane, BuildPlane, pickWorkplaneGizmoBasis,
                              pickWorkplaneFrame, WorkplaneFrame, currentWorkplaneFrame,
                              transformPoint, transformDir;

import std.math : sin, cos, PI, abs, sqrt;

// Reuses the generic snapshot-pair edit factory (same convention as
// BoxTool / SphereTool).
alias CylinderEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// CylinderParams — MODO-aligned wire schema for prim.cylinder headless
// invocation.
//
// Field names match cmdhelptools.cfg <hash type="Tool" key="prim.cylinder">
// attribute keys verbatim.
//
// IMPORTANT: For prim.cylinder, sizeX/Y/Z are PER-AXIS RADII (verified via
// modo_cl probes), not diameters as in prim.cube. The size along the
// cylinder's axis is the half-height (e.g. axis=Y, sizeY=1.0 → cylinder
// extends y∈[-1, 1], total height 2). MODO labels them "Radius X/Y/Z".
// ---------------------------------------------------------------------------
struct CylinderParams {
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 1.0f, sizeY = 1.0f, sizeZ = 1.0f;  // radii (default unit cylinder)
    int   sides    = 24;     // verts per ring (MODO default 24)
    int   segments = 1;      // ring count along axis = segments+1 (MODO default 1)
    int   axis     = 1;      // X=0, Y=1, Z=2 — cylinder's main axis
}

// ---------------------------------------------------------------------------
// buildCylinder — emit a closed cylinder into `dst` with MODO prim.cylinder
// vertex layout and winding (verified bit-for-bit against modo_cl).
//
// Topology (S = sides, N = segments):
//   verts = (N + 1) * S
//   faces = 2 + N * S  (bottom n-gon cap, side quads, top n-gon cap)
//
// Vertex layout: ring k = 0..N along the cylinder axis, each ring contains S
// verts CCW around the axis.
//   ring 0 at axis = -size_axis  (bottom cap)
//   ring N at axis = +size_axis  (top cap)
//
// Winding (axis=Y, perp axes (B,C)=(Z,X) cyclic):
//   ring vertex j: position[B] = -sizeB * cos(2π·j/S)
//                  position[C] = -sizeC * sin(2π·j/S)
//   bottom cap:    [v0, v(S-1), v(S-2), ..., v1]   (reverse → outward normal -axis)
//   side quad k,j: [ring_{k+1}[j], ring_k[j], ring_k[(j+1)%S], ring_{k+1}[(j+1)%S]]
//   top cap:       [v_{N·S}, v_{N·S+1}, ..., v_{N·S+S-1}]  (forward → outward +axis)
//
// Disk degenerate (size_axis = 0): a single S-gon face, winding so the
// outward normal points along +axis (matches MODO; flip param inverts it
// but we leave that as a follow-up — not in plan-required cases).
//
// axis=X cycles (A,B,C) = (X,Y,Z); axis=Z cycles (A,B,C) = (Z,X,Y).
// ---------------------------------------------------------------------------
void buildCylinder(Mesh* dst, const ref CylinderParams p)
{
    int S = p.sides;
    int N = p.segments;
    if (S < 3) S = 3;
    if (N < 1) N = 1;

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;

    // (axisIdx, bIdx, cIdx) is a cyclic permutation of (0,1,2):
    //   axis=X (0): (X, Y, Z) — perp axes (Y, Z)
    //   axis=Y (1): (Y, Z, X) — perp axes (Z, X)
    //   axis=Z (2): (Z, X, Y) — perp axes (X, Y)
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen  = [p.cenX, p.cenY, p.cenZ];
    float[3] size = [p.sizeX, p.sizeY, p.sizeZ];

    float halfA = size[axisIdx];
    float radB  = size[bIdx];
    float radC  = size[cIdx];

    bool isDisk = abs(halfA) < 1e-9f;

    uint base = cast(uint)dst.vertices.length;

    // Helper: emit a single ring at axisCoord = aPos.
    void emitRing(float aPos) {
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float bPos = -radB * cos(theta);
            float cPos = -radC * sin(theta);
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + aPos;
            pos[bIdx]    = cen[bIdx]    + bPos;
            pos[cIdx]    = cen[cIdx]    + cPos;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    // Disk: single ring + single face.
    if (isDisk) {
        emitRing(0.0f);
        // Face winding so outward normal points +axis (verified vs. modo_cl
        // disk case for axis=Y: face = [0,1,2,3]).
        uint[] cap;
        cap.length = S;
        foreach (j; 0 .. S) cap[j] = base + cast(uint)j;
        dst.addFace(cap);
        return;
    }

    // Full cylinder: emit (N+1) rings bottom-to-top.
    foreach (k; 0 .. N + 1) {
        float t = cast(float)k / cast(float)N;
        float aPos = -halfA + 2.0f * halfA * t;
        emitRing(aPos);
    }

    uint ringV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return base + cast(uint)(k * S + jm);
    }

    // Bottom cap: ring 0 reversed → outward normal -axis.
    {
        uint[] cap;
        cap.length = S;
        cap[0] = ringV(0, 0);
        foreach (i; 1 .. S) cap[i] = ringV(0, S - cast(int)i);
        dst.addFace(cap);
    }

    // Side strips, ring k → k+1.
    foreach (k; 0 .. N) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);
        }
    }

    // Top cap: ring N forward → outward normal +axis.
    {
        uint[] cap;
        cap.length = S;
        foreach (j; 0 .. S) cap[j] = ringV(N, cast(int)j);
        dst.addFace(cap);
    }
}

// ---------------------------------------------------------------------------
// CylinderTool — Create-tool for prim.cylinder with two-stage interactive draw.
//
// Wire schema matches MODO `prim.cylinder` cmdhelptools.cfg.
//
// Interaction model (mirrors BoxTool / SphereTool):
//   Idle ── LMB drag on viewport ─→ DrawingBase (flat ellipse on plane;
//                                     params_.axis = world axis of plane normal)
//   DrawingBase ── LMB up ─→ BaseSet
//   BaseSet ── LMB drag on viewport ─→ DrawingHeight (extrudes ellipse → cylinder)
//   DrawingHeight ── LMB up ─→ HeightSet
//
// During interactive states the scene mesh is untouched; only previewMesh
// is rebuilt each frame from params_. The committed cylinder lands in the
// scene mesh at deactivate(), wrapped in a snapshot pair for undo.
//
// Headless path (applyHeadless) bypasses the state machine and appends
// directly from current params_.
// ---------------------------------------------------------------------------

private enum CylinderState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class CylinderTool : Tool {
private:
    Mesh*               mesh;
    GpuMesh*            gpu;
    LitShader           litShader;

    CylinderParams      params_;
    CommandHistory      history;
    CylinderEditFactory factory;

    CylinderState       state;
    Mesh                previewMesh;
    GpuMesh             previewGpu;
    bool                meshChanged;

    // Construction-plane frame chosen at first click and locked for the
    // whole interaction. After the workplane refactor these are in LOCAL
    // workplane coords (canonical (1,0,0)/(0,1,0)/(0,0,1) — actual world
    // basis is encoded in `frame`); ray-plane sites use localEye() /
    // localRay() and produce hits in local space.
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;
    /// Workplane local↔world transform captured at choosePlane(). All
    /// internal coords (params_.cen*, cylinderCenter, baseAnchor,
    /// hpOrigin, sizeH positions) live in this frame's local space; mesh
    /// upload / commit transforms vertices through `frame.toWorld`.
    WorkplaneFrame frame;

    // Drag anchors — only valid for the matching state(s).
    Vec3 startPoint;
    Vec3 currentPoint;
    Vec3 hpOrigin;
    Vec3 hpn;
    Vec3 heightDragStart;
    Vec3 baseAnchor;

    // Sticky modifier captured at LMB-down: Ctrl held forces a uniform
    // drag (all three radii equal during DrawingBase, all three sizes
    // equal during DrawingHeight).
    bool dragUniform;

    Viewport cachedVp;

    // Move gizmo (axis-only).
    MoveHandler mover;
    int         moverDragAxis = -1;
    int         moverLastMX, moverLastMY;

    // Six handles on the cylinder bbox surface — outward axes:
    //   0:+X  1:-X  2:+Y  3:-Y  4:+Z  5:-Z
    // For the cylinder's cap axes (matching params_.axis) the handle drives
    // height (radius along that axis = half-height); for the perpendicular
    // axes it drives radius.
    BoxHandler[6] sizeH;
    int           sizeDragIdx    = -1;
    int           sizeHoveredIdx = -1;
    int           sizeLastMX, sizeLastMY;

    static immutable Vec3[6] SIZE_AXES = [
        Vec3( 1, 0, 0), Vec3(-1, 0, 0),
        Vec3( 0, 1, 0), Vec3( 0,-1, 0),
        Vec3( 0, 0, 1), Vec3( 0, 0,-1),
    ];

public:
    this(Mesh* mesh, GpuMesh* gpu, LitShader litShader) {
        this.mesh      = mesh;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0, 0, 0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        foreach (i; 0 .. 6) {
            Vec3 col = (i < 2) ? Vec3(0.9f, 0.2f, 0.2f)
                     : (i < 4) ? Vec3(0.2f, 0.9f, 0.2f)
                               : Vec3(0.2f, 0.2f, 0.9f);
            sizeH[i] = new BoxHandler(Vec3(0, 0, 0), col);
        }
    }

    void destroy() {
        mover.destroy();
        foreach (h; sizeH) h.destroy();
    }

    void setUndoBindings(CommandHistory history, CylinderEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

    override string name() const { return "Cylinder"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Radius X",   &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Radius Y",   &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Radius Z",   &params_.sizeZ, 1.0f).min(0.0f),
            Param.int_("sides",    "Sides",    &params_.sides,    24).min(3).max(256),
            Param.int_("segments", "Segments", &params_.segments, 1 ).min(1).max(256),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override void activate() {
        state         = CylinderState.Idle;
        meshChanged   = false;
        moverDragAxis = -1;
        sizeDragIdx   = -1;
        previewGpu.init();
    }

    override void deactivate() {
        bool willCommit = (state == CylinderState.BaseSet)
                       || (state >= CylinderState.DrawingHeight
                           && currentHeight() > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == CylinderState.BaseSet)
            commitDisk();
        else if (state >= CylinderState.DrawingHeight && currentHeight() > 1e-5f)
            commitCylinder();
        state = CylinderState.Idle;
        previewGpu.destroy();

        if (willCommit) commitCylinderEdit(pre);
    }

    override void evaluate() {
        if (state == CylinderState.Idle) return;
        rebuildPreview();
    }

    override bool applyHeadless() {
        // Append into the scene mesh (same convention as Box / Sphere).
        // Headless prim.cylinder honours the active WorkplaneStage —
        // params_ are LOCAL workplane coords; vertices are emitted in
        // local then transformed via frame.toWorld.
        frame = currentWorkplaneFrame();
        size_t firstNewVert = mesh.vertices.length;
        buildCylinder(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != CylinderState.Idle) {
            state = CylinderState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        bool ctrlAtClick = (mods & KMOD_CTRL) != 0;

        // Size handles take priority once a base/cylinder exists.
        if (state >= CylinderState.BaseSet) {
            foreach (i; 0 .. 6) {
                if (sizeH[i].hitTest(e.x, e.y, cachedVp)) {
                    sizeDragIdx = cast(int)i;
                    sizeLastMX  = e.x;
                    sizeLastMY  = e.y;
                    return true;
                }
            }
            int hit = moverHitTest(e.x, e.y);
            if (hit >= 0) {
                moverDragAxis = hit;
                moverLastMX   = e.x;
                moverLastMY   = e.y;
                return true;
            }
        }

        if (state == CylinderState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            // Set params_.axis = local axis index of plane normal so the
            // cylinder's topology aligns with the construction plane.
            params_.axis = worldAxisIdxOf(planeNormal);
            params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
            dragUniform = ctrlAtClick;
            state = CylinderState.DrawingBase;
            uploadPreview();
            return true;
        }

        if (state == CylinderState.BaseSet) {
            if (ctrlAtClick) {
                baseAnchor = cylinderCenter();
                Vec3 hit;
                if (!rayPlaneIntersect(localEye(),
                                       localRay(e.x, e.y),
                                       baseAnchor, planeNormal, hit))
                    return false;
                Vec3  d = hit - baseAnchor;
                float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                setWorldSize(0, r);
                setWorldSize(1, r);
                setWorldSize(2, r);
                dragUniform = true;
                state = CylinderState.DrawingHeight;
                uploadPreview();
                return true;
            }
            setupHeightPlane();
            baseAnchor = cylinderCenter();
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            dragUniform = false;
            state = CylinderState.DrawingHeight;
            uploadPreview();
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (sizeDragIdx >= 0)   { sizeDragIdx = -1;   return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }

        if (state == CylinderState.DrawingBase) {
            if (dragUniform) {
                if (!(sizeOnAxis(planeAxis1) > 1e-5f)) {
                    state = CylinderState.Idle;
                    return true;
                }
                state = CylinderState.HeightSet;
                uploadPreview();
                return true;
            }
            float r1 = sizeOnAxis(planeAxis1);
            float r2 = sizeOnAxis(planeAxis2);
            if (!(r1 > 1e-5f) || !(r2 > 1e-5f)) {
                state = CylinderState.Idle;
                return true;
            }
            state = CylinderState.BaseSet;
            uploadPreview();
            return true;
        }
        if (state == CylinderState.DrawingHeight) {
            state = CylinderState.HeightSet;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (sizeDragIdx >= 0) {
            // SIZE_AXES are LOCAL outward directions; screenAxisDelta
            // consumes WORLD origin + axis, so route through toWorldD.
            Vec3 outwardWorld = toWorldD(SIZE_AXES[sizeDragIdx]);
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, sizeLastMX, sizeLastMY,
                                         sizeH[sizeDragIdx].pos, outwardWorld,
                                         cachedVp, skip);
            if (!skip) applySizeDelta(sizeDragIdx, delta);
            sizeLastMX = e.x; sizeLastMY = e.y;
            return true;
        }
        if (moverDragAxis >= 0) {
            bool skip;
            Vec3 delta = moverDragAxis <= 2
                ? axisDragDelta (e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover, cachedVp, skip)
                : planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover.center, cachedVp, skip,
                                 mover.axisX, mover.axisY, mover.axisZ);
            if (!skip) {
                // delta is in WORLD; params_ are in LOCAL workplane space.
                Vec3 dl = toLocalD(delta);
                params_.cenX += dl.x;
                params_.cenY += dl.y;
                params_.cenZ += dl.z;
                rebuildPreview();
            }
            moverLastMX = e.x; moverLastMY = e.y;
            return true;
        }

        if (state == CylinderState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                currentPoint = hit;
                if (dragUniform) syncParamsFromUniformDrag();
                else             syncParamsFromBaseDrag();
                uploadPreview();
            }
            return true;
        }
        if (state == CylinderState.DrawingHeight) {
            if (dragUniform) {
                Vec3 hit;
                if (rayPlaneIntersect(localEye(),
                                      localRay(e.x, e.y),
                                      baseAnchor, planeNormal, hit))
                {
                    Vec3  d = hit - baseAnchor;
                    float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                    params_.cenX = baseAnchor.x;
                    params_.cenY = baseAnchor.y;
                    params_.cenZ = baseAnchor.z;
                    setWorldSize(0, r);
                    setWorldSize(1, r);
                    setWorldSize(2, r);
                    uploadPreview();
                }
                return true;
            }
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
            {
                // Box-style asymmetric grow: the disk drawn in DrawingBase is
                // one face of the cylinder; the second drag extrudes the
                // OTHER face along signedH. Center sits halfway between
                // baseAnchor (anchored face) and the moving face. Sign of
                // the projection decides which side grows.
                //   sizeOnAxis = halfH (MODO stores per-axis radius).
                //   cen        = baseAnchor + planeNormal * signedH/2.
                // For signedH > 0 the cylinder spans [baseAnchor, baseAnchor+H];
                // for signedH < 0 it spans [baseAnchor-|H|, baseAnchor].
                float signedH = dot(hit - heightDragStart, planeNormal);
                float fullH   = abs(signedH);
                Vec3  newCen  = baseAnchor + planeNormal * (signedH * 0.5f);
                params_.cenX = newCen.x;
                params_.cenY = newCen.y;
                params_.cenZ = newCen.z;
                writeSizeOnAxis(planeNormal, fullH * 0.5f);
                uploadPreview();
            }
            return true;
        }
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == CylinderState.Idle) return;

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

        if (state >= CylinderState.BaseSet) {
            updateSizeHandlers(vp);
            // cylinderCenter is in workplane local; transform to world.
            mover.setPosition(toWorldP(cylinderCenter()));
            // Mover gizmo aligned to the captured frame's basis.
            mover.setOrientation(frame.axis1, frame.normal, frame.axis2);
            sizeHoveredIdx = -1;
            bool sizeBusy = sizeDragIdx >= 0;
            foreach (i; 0 .. 6) {
                sizeH[i].setForceHovered(sizeDragIdx == cast(int)i);
                sizeH[i].setHoverBlocked(sizeBusy && sizeDragIdx != cast(int)i);
                sizeH[i].draw(shader, vp);
                if (sizeH[i].isHovered()) sizeHoveredIdx = cast(int)i;
            }
            mover.arrowX.setForceHovered(moverDragAxis == 0);
            mover.arrowY.setForceHovered(moverDragAxis == 1);
            mover.arrowZ.setForceHovered(moverDragAxis == 2);
            mover.centerBox.setForceHovered(moverDragAxis == 3);
            bool sizePriority = sizeDragIdx >= 0 || sizeHoveredIdx >= 0;
            mover.arrowX.setHoverBlocked(sizePriority || (moverDragAxis >= 0 && moverDragAxis != 0));
            mover.arrowY.setHoverBlocked(sizePriority || (moverDragAxis >= 0 && moverDragAxis != 1));
            mover.arrowZ.setHoverBlocked(sizePriority || (moverDragAxis >= 0 && moverDragAxis != 2));
            mover.centerBox.setHoverBlocked(sizePriority || (moverDragAxis >= 0 && moverDragAxis != 3));
            mover.draw(shader, vp);
        }
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (state == CylinderState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw a base ellipse.");
        else if (state == CylinderState.BaseSet)
            ImGui.TextDisabled("Drag again to extrude into a cylinder.");
    }

private:
    Vec3 cylinderCenter() const {
        return Vec3(params_.cenX, params_.cenY, params_.cenZ);
    }

    static int worldAxisIdxOf(Vec3 v) {
        if (abs(v.x) > 0.5f) return 0;
        if (abs(v.y) > 0.5f) return 1;
        return 2;
    }

    float worldSize(int worldIdx) const {
        final switch (worldIdx) {
            case 0: return params_.sizeX;
            case 1: return params_.sizeY;
            case 2: return params_.sizeZ;
        }
    }

    void setWorldSize(int worldIdx, float v) {
        float a = abs(v);
        final switch (worldIdx) {
            case 0: params_.sizeX = a; break;
            case 1: params_.sizeY = a; break;
            case 2: params_.sizeZ = a; break;
        }
    }

    float sizeOnAxis(Vec3 axisVec) const {
        return worldSize(worldAxisIdxOf(axisVec));
    }

    void writeSizeOnAxis(Vec3 axisVec, float v) {
        setWorldSize(worldAxisIdxOf(axisVec), v);
    }

    // Total cylinder height along its main axis = 2× half-height stored in
    // the size param along that axis. Used by deactivate() to decide commit.
    float currentHeight() const { return sizeOnAxis(planeNormal) * 2.0f; }

    void choosePlane(const ref Viewport vp) {
        // Capture workplane as a local↔world transform; tool-internal
        // coords are in local-space (workplane = identity XZ plane).
        frame = pickWorkplaneFrame(vp);
        // Pick the construction plane by camera (most-facing-axis in
        // workplane basis), matching BoxTool / SphereTool / corner gizmo.
        Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
        float aA = abs(dot(camBack, frame.axis1));
        float aN = abs(dot(camBack, frame.normal));
        float aZ = abs(dot(camBack, frame.axis2));
        if (aA >= aN && aA >= aZ) {
            planeNormal = Vec3(1, 0, 0);
            planeAxis1  = Vec3(0, 1, 0);
            planeAxis2  = Vec3(0, 0, 1);
        } else if (aN >= aA && aN >= aZ) {
            planeNormal = Vec3(0, 1, 0);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 0, 1);
        } else {
            planeNormal = Vec3(0, 0, 1);
            planeAxis1  = Vec3(1, 0, 0);
            planeAxis2  = Vec3(0, 1, 0);
        }
    }

    // ---- Local ↔ world helpers (workplane refactor) ---------------------
    Vec3 localEye() const { return transformPoint(frame.toLocal, cachedVp.eye); }
    Vec3 localRay(int x, int y) const {
        return transformDir(frame.toLocal, screenRay(x, y, cachedVp));
    }
    Vec3 toWorldP(Vec3 p) const { return transformPoint(frame.toWorld, p); }
    Vec3 toWorldD(Vec3 d) const { return transformDir  (frame.toWorld, d); }
    Vec3 toLocalD(Vec3 d) const { return transformDir  (frame.toLocal, d); }
    void applyFrameToMeshRange(Mesh* m, size_t firstIdx) {
        foreach (i; firstIdx .. m.vertices.length)
            m.vertices[i] = transformPoint(frame.toWorld, m.vertices[i]);
    }

    // First click anchors the cylinder center; the cursor traces a point on
    // the ellipse perimeter, so each in-plane radius equals the absolute
    // projection of the drag onto that plane axis (no /2). Plane-normal
    // size stays 0 (flat ellipse).
    void syncParamsFromBaseDrag() {
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
        writeSizeOnAxis(planeAxis1, abs(d1));
        writeSizeOnAxis(planeAxis2, abs(d2));
    }

    void syncParamsFromUniformDrag() {
        Vec3  d = currentPoint - startPoint;
        float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        setWorldSize(0, r);
        setWorldSize(1, r);
        setWorldSize(2, r);
    }

    void setupHeightPlane() {
        hpOrigin = cylinderCenter();
        Vec3 toCamera = localEye() - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    // Build a single-ring "disk" preview to use during DrawingBase. The
    // generator handles this via the isDisk path — sizeOnAxis(planeNormal)
    // is 0, so buildCylinder produces a single S-gon face. Mesh built in
    // LOCAL workplane space; vertices transformed via frame.toWorld for
    // rendering.
    void rebuildPreview() {
        previewMesh.clear();
        buildCylinder(&previewMesh, params_);
        applyFrameToMeshRange(&previewMesh, 0);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    // Append into the scene mesh (same convention as Box / Sphere).
    // Mesh emitted in LOCAL workplane space; only the newly-appended
    // vertex range is transformed via frame.toWorld so existing scene
    // geometry stays put.
    void commitDisk() {
        size_t firstNewVert = mesh.vertices.length;
        buildCylinder(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitCylinder() {
        size_t firstNewVert = mesh.vertices.length;
        buildCylinder(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitCylinderEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Cylinder");
        history.record(cmd);
    }

    void updateSizeHandlers(const ref Viewport vp) {
        Vec3 cen = cylinderCenter();   // local
        float sx = worldSize(0);
        float sy = worldSize(1);
        float sz = worldSize(2);
        // Compute in LOCAL frame, then transform each to world for hit-
        // test / gizmoSize against the live viewport.
        Vec3[6] localPts = [
            cen + Vec3( sx, 0, 0), cen + Vec3(-sx, 0, 0),
            cen + Vec3(0,  sy, 0), cen + Vec3(0, -sy, 0),
            cen + Vec3(0, 0,  sz), cen + Vec3(0, 0, -sz),
        ];
        foreach (i; 0 .. 6) {
            Vec3 worldPos = toWorldP(localPts[i]);
            sizeH[i].pos  = worldPos;
            sizeH[i].size = gizmoSize(worldPos, vp, 0.04f);
        }
    }

    // Box-style anchored-opposite handle drag: the dragged face follows the
    // cursor while the opposite face stays fixed in world space. d is the
    // signed projection of the cursor delta on the outward face normal.
    // MODO's prim.cylinder size is half-extent, so the change in half-extent
    // equals d/2 and the center shifts by d/2 along the outward direction —
    // full height (or full diameter on radial axes) changes by exactly d,
    // not 2·d as the previous symmetric scaling produced.
    //
    // Flip-through: if the drag pushed the size negative, the cylinder has
    // crossed the opposite face. Swap to the OPPOSITE handle so subsequent
    // motion continues to follow the cursor on the new "front" side.
    void applySizeDelta(int idx, Vec3 delta) {
        // delta arrives in WORLD; SIZE_AXES are LOCAL outward dirs.
        // Convert delta to local once, then project & shift in local.
        Vec3  outward  = SIZE_AXES[idx];
        Vec3  deltaL   = toLocalD(delta);
        float d        = dot(deltaL, outward);
        int   worldIdx = idx / 2;
        float oldSize  = worldSize(worldIdx);
        float signedSz = oldSize + d * 0.5f;
        float newSize  = abs(signedSz);

        setWorldSize(worldIdx, newSize);
        Vec3 cenShift = outward * (d * 0.5f);
        params_.cenX += cenShift.x;
        params_.cenY += cenShift.y;
        params_.cenZ += cenShift.z;

        if (signedSz < 0.0f)
            sizeDragIdx ^= 1;

        rebuildPreview();
    }

    int moverHitTest(int mx, int my) {
        import handler : Arrow;
        if (mover.centerBox.hitTest(mx, my, cachedVp)) return 3;
        Arrow[3] arrows = [mover.arrowX, mover.arrowY, mover.arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, ndcZa, sbx, sby, ndcZb;
            if (!projectToWindowFull(arrow.start, cachedVp, sax, say, ndcZa)) continue;
            if (!projectToWindowFull(arrow.end,   cachedVp, sbx, sby, ndcZb)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }
}
