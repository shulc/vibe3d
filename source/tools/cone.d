module tools.cone;

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

alias ConeEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// ConeParams — MODO-aligned wire schema for prim.cone headless invocation.
//
// Field names match cmdhelptools.cfg <hash type="Tool" key="prim.cone">
// attribute keys verbatim. Same schema as prim.cylinder — sizeX/Y/Z are
// per-axis half-extents (verified via modo_cl: default sizeX=Y=Z=1 →
// bounds [-1, 1]). The cone tapers linearly along its main axis; the cap
// at the negative end is a full ellipse, the positive end is a single
// apex vertex. Frustum (truncated cone) is NOT a MODO mode — no
// radiusTop parameter.
// ---------------------------------------------------------------------------
struct ConeParams {
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 1.0f, sizeY = 1.0f, sizeZ = 1.0f;
    int   sides    = 24;     // verts per ring (MODO default 24)
    int   segments = 1;      // ring count = segments; +1 apex vertex
    int   axis     = 1;      // X=0, Y=1, Z=2 — main axis (apex on +axis side)
}

// ---------------------------------------------------------------------------
// buildCone — emit a closed cone into `dst` with MODO prim.cone vertex
// layout and winding (verified bit-for-bit against modo_cl).
//
// Topology (S = sides, N = segments):
//   verts = N·S + 1                      (N rings + 1 apex)
//   faces = 1 + N·S                      (cap + (N-1)·S quads + S apex tris)
//
// Vertex layout (axis=Y example):
//   ring k = 0..N-1 at axisCoord = -sizeA + 2·sizeA·(k/N)
//     with linear taper: radius(k) = (1 − k/N) · sizeB,C
//   apex at axisCoord = +sizeA, on the axis line
//
// Winding (axis=Y, perp axes (B,C)=(Z,X) cyclic — same as cylinder):
//   ring vertex j: position[B] = -sizeB·(1 − k/N) · cos(2π·j/S)
//                  position[C] = -sizeC·(1 − k/N) · sin(2π·j/S)
//   bottom cap: [v0, v(S-1), ..., v1]                       outward -axis
//   strip k→k+1 (for k < N-1):
//     [ring(k+1,j), ring(k,j), ring(k,(j+1)%S), ring(k+1,(j+1)%S)]
//   apex fan (k = N-1):
//     [ring(N-1,j), ring(N-1,(j+1)%S), apex]
//
// axis=X cycles (A,B,C)=(X,Y,Z); axis=Z cycles (A,B,C)=(Z,X,Y).
// ---------------------------------------------------------------------------
void buildCone(Mesh* dst, const ref ConeParams p)
{
    int S = p.sides;
    int N = p.segments;
    if (S < 3) S = 3;
    if (N < 1) N = 1;

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen  = [p.cenX, p.cenY, p.cenZ];
    float[3] size = [p.sizeX, p.sizeY, p.sizeZ];

    float halfA = size[axisIdx];
    float radB  = size[bIdx];
    float radC  = size[cIdx];

    uint base = cast(uint)dst.vertices.length;

    // Emit a ring at parametric t ∈ [0, 1) along the axis. Radius scales
    // linearly from full at t=0 to 0 at t=1.
    void emitRing(float t) {
        float aPos = -halfA + 2.0f * halfA * t;
        float scale = 1.0f - t;
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float bPos = -radB * scale * cos(theta);
            float cPos = -radC * scale * sin(theta);
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + aPos;
            pos[bIdx]    = cen[bIdx]    + bPos;
            pos[cIdx]    = cen[cIdx]    + cPos;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    foreach (k; 0 .. N) {
        float t = cast(float)k / cast(float)N;
        emitRing(t);
    }

    // Apex vertex on the +axis end.
    {
        float[3] apex;
        apex[axisIdx] = cen[axisIdx] + halfA;
        apex[bIdx]    = cen[bIdx];
        apex[cIdx]    = cen[cIdx];
        dst.addVertex(Vec3(apex[0], apex[1], apex[2]));
    }

    uint apexV = base + cast(uint)(N * S);

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

    // Quad strips between adjacent rings.
    foreach (k; 0 .. N - 1) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);
        }
    }

    // Apex fan (last ring → apex), all triangles.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(N - 1, j), ringV(N - 1, j + 1), apexV]);
    }
}

// ---------------------------------------------------------------------------
// ConeTool — Create-tool for prim.cone with two-stage interactive draw.
//
// Mirrors CylinderTool's interaction model exactly (so users get identical
// muscle memory across primitives):
//   Idle ── LMB drag on plane ─→ DrawingBase (flat ellipse)
//   DrawingBase ── LMB up      ─→ BaseSet
//   BaseSet ── LMB drag        ─→ DrawingHeight (extrudes ellipse → cone)
//   DrawingHeight ── LMB up    ─→ HeightSet
//
// The two-drag asymmetry matches BoxTool/CylinderTool: the disk is one face
// of the cone (the base); the height drag extrudes the apex along signedH
// projection on planeNormal.
// ---------------------------------------------------------------------------

private enum ConeState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class ConeTool : Tool {
private:
    Mesh*           mesh;
    GpuMesh*        gpu;
    LitShader       litShader;

    ConeParams      params_;
    CommandHistory  history;
    ConeEditFactory factory;

    ConeState       state;
    Mesh            previewMesh;
    GpuMesh         previewGpu;
    bool            meshChanged;

    // After workplane refactor these are LOCAL canonical (1,0,0)/(0,1,0)/
    // (0,0,1); world basis is encoded in `frame`.
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;
    /// Workplane local↔world transform captured at choosePlane().
    WorkplaneFrame frame;

    Vec3 startPoint;
    Vec3 currentPoint;
    Vec3 hpOrigin;
    Vec3 hpn;
    Vec3 heightDragStart;
    Vec3 baseAnchor;

    bool dragUniform;

    Viewport cachedVp;

    MoveHandler mover;
    int         moverDragAxis = -1;
    int         moverLastMX, moverLastMY;

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

    void setUndoBindings(CommandHistory history, ConeEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

    override string name() const { return "Cone"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Size X",     &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Size Y",     &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Size Z",     &params_.sizeZ, 1.0f).min(0.0f),
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
        state         = ConeState.Idle;
        meshChanged   = false;
        moverDragAxis = -1;
        sizeDragIdx   = -1;
        previewGpu.init();
    }

    override void deactivate() {
        bool willCommit = (state == ConeState.BaseSet)
                       || (state >= ConeState.DrawingHeight
                           && currentHeight() > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == ConeState.BaseSet)
            commitDisk();
        else if (state >= ConeState.DrawingHeight && currentHeight() > 1e-5f)
            commitCone();
        state = ConeState.Idle;
        previewGpu.destroy();

        if (willCommit) commitConeEdit(pre);
    }

    override void evaluate() {
        if (state == ConeState.Idle) return;
        rebuildPreview();
    }

    override bool applyHeadless() {
        frame = currentWorkplaneFrame();
        size_t firstNewVert = mesh.vertices.length;
        buildCone(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != ConeState.Idle) {
            state = ConeState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        bool ctrlAtClick = (mods & KMOD_CTRL) != 0;

        if (state >= ConeState.BaseSet) {
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

        if (state == ConeState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            params_.axis = worldAxisIdxOf(planeNormal);
            params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
            dragUniform = ctrlAtClick;
            state = ConeState.DrawingBase;
            uploadPreview();
            return true;
        }

        if (state == ConeState.BaseSet) {
            if (ctrlAtClick) {
                baseAnchor = coneCenter();
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
                state = ConeState.DrawingHeight;
                uploadPreview();
                return true;
            }
            setupHeightPlane();
            baseAnchor = coneCenter();
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            dragUniform = false;
            state = ConeState.DrawingHeight;
            uploadPreview();
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (sizeDragIdx >= 0)   { sizeDragIdx = -1;   return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }

        if (state == ConeState.DrawingBase) {
            if (dragUniform) {
                if (!(sizeOnAxis(planeAxis1) > 1e-5f)) {
                    state = ConeState.Idle;
                    return true;
                }
                state = ConeState.HeightSet;
                uploadPreview();
                return true;
            }
            float r1 = sizeOnAxis(planeAxis1);
            float r2 = sizeOnAxis(planeAxis2);
            if (!(r1 > 1e-5f) || !(r2 > 1e-5f)) {
                state = ConeState.Idle;
                return true;
            }
            state = ConeState.BaseSet;
            uploadPreview();
            return true;
        }
        if (state == ConeState.DrawingHeight) {
            state = ConeState.HeightSet;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (sizeDragIdx >= 0) {
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
                Vec3 dl = toLocalD(delta);
                params_.cenX += dl.x;
                params_.cenY += dl.y;
                params_.cenZ += dl.z;
                rebuildPreview();
            }
            moverLastMX = e.x; moverLastMY = e.y;
            return true;
        }

        if (state == ConeState.DrawingBase) {
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
        if (state == ConeState.DrawingHeight) {
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
                // Box-style asymmetric grow: base disk stays anchored on
                // baseAnchor's plane, apex extrudes along signedH·planeNormal.
                // Cone center sits halfway between baseAnchor and apex along
                // the axis. sizeOnAxis is half the full bounding-box extent
                // (matches MODO's sizeY = halfA when axis=Y).
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
        if (state == ConeState.Idle) return;

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

        if (state >= ConeState.BaseSet) {
            updateSizeHandlers(vp);
            mover.setPosition(toWorldP(coneCenter()));
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
        if (state == ConeState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw a base ellipse.");
        else if (state == ConeState.BaseSet)
            ImGui.TextDisabled("Drag again to extrude into a cone.");
    }

private:
    Vec3 coneCenter() const {
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

    float currentHeight() const { return sizeOnAxis(planeNormal) * 2.0f; }

    void choosePlane(const ref Viewport vp) {
        frame = pickWorkplaneFrame(vp);
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
        hpOrigin = coneCenter();
        Vec3 toCamera = localEye() - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    void rebuildPreview() {
        previewMesh.clear();
        buildCone(&previewMesh, params_);
        applyFrameToMeshRange(&previewMesh, 0);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    void commitDisk() {
        size_t firstNewVert = mesh.vertices.length;
        buildCone(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitCone() {
        size_t firstNewVert = mesh.vertices.length;
        buildCone(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitConeEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Cone");
        history.record(cmd);
    }

    void updateSizeHandlers(const ref Viewport vp) {
        Vec3 cen = coneCenter();   // local
        float sx = worldSize(0);
        float sy = worldSize(1);
        float sz = worldSize(2);
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
    // Since MODO's prim.cone size is half-extent, the change in half-extent
    // equals d/2, and the center shifts by d/2 along the outward direction
    // so the opposite face's world position is preserved (full height
    // changes by exactly d, not 2·d as in the previous symmetric scaling).
    //
    // Flip-through: if the drag pushed the size negative, the cone has
    // crossed the opposite face. Swap to the OPPOSITE handle so subsequent
    // motion continues to follow the cursor on the new "front" side.
    // SIZE_AXES is laid out in pairs (+/-) per world axis — XOR 1 toggles
    // 0↔1, 2↔3, 4↔5.
    void applySizeDelta(int idx, Vec3 delta) {
        // delta in WORLD; SIZE_AXES are LOCAL outward dirs.
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
