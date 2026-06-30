module tools.tube;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tool;
import mesh;
import math;
import params : Param;
import handler : MoveHandler, gizmoSize, ToolHandles;
import eventlog : queryMouse;
import drag : axisDragDelta, planeDragDelta;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.bevel_edit : MeshBevelEdit;
import snapshot : MeshSnapshot;
import tools.create_common : pickWorkplaneFrame, WorkplaneFrame, currentWorkplaneFrame,
                              transformPoint, transformDir, snapLocalHit;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;

import std.math : sin, cos, PI, abs, sqrt, fmax, fmin;

alias TubeEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// TubeParams — wire schema for prim.tube headless invocation.
//
// A tube is a hollow cylinder: outer wall + inner wall (reversed winding) +
// annular top cap + annular bottom cap.
//
// Vertex layout (S = segments, 4 blocks of S verts each):
//   outerBottom[j]  (k=0, outer radius, axis coord = cen[axis] - height/2)
//   outerTop[j]     (k=1, outer radius, axis coord = cen[axis] + height/2)
//   innerBottom[j]  (k=0, inner radius)
//   innerTop[j]     (k=1, inner radius)
//
// Counts (cap=true):  verts = 4*S, faces = 4*S
//         (cap=false): verts = 4*S, faces = 2*S
//
// Winding (outward-facing normals chosen, axis-convention matches buildCylinder):
//   bIdx = (axis+1)%3, cIdx = (axis+2)%3
//   ring vertex j: pos[bIdx] = -r*cos(2π·j/S), pos[cIdx] = -r*sin(2π·j/S)
//
//   outer wall j:  [outerV(1,j), outerV(0,j), outerV(0,j+1), outerV(1,j+1)]  → outward normal
//   inner wall j:  [innerV(1,j+1), innerV(0,j+1), innerV(0,j), innerV(1,j)]   → inward normal
//   top cap j:     [outerV(1,j), outerV(1,j+1), innerV(1,j+1), innerV(1,j)]   → +axis normal
//   bottom cap j:  [outerV(0,j), innerV(0,j), innerV(0,j+1), outerV(0,j+1)]  → -axis normal
//
// Degenerate-radii contract (enforced by buildTube, not the caller):
//   outerRadius = max(outerRadius, 1e-6)
//   innerRadius = clamp(innerRadius, outerRadius*1e-4, outerRadius*(1-1e-4))
// ---------------------------------------------------------------------------
struct TubeParams {
    float cenX        = 0.0f, cenY = 0.0f, cenZ = 0.0f;
    float outerRadius = 1.0f;
    float innerRadius = 0.5f;
    float height      = 2.0f;
    int   segments    = 24;
    int   axis        = 1;   // X=0, Y=1, Z=2
    bool  cap         = true;
}

// ---------------------------------------------------------------------------
// buildTube — emit a hollow cylinder into `dst`.
// ---------------------------------------------------------------------------
void buildTube(Mesh* dst, const ref TubeParams p)
{
    int S = p.segments;
    if (S < 3) S = 3;

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;

    // Cyclic-perp convention (identical to buildCylinder, cylinder.d:87-88):
    //   axis=X(0): perp=(Y,Z);  axis=Y(1): perp=(Z,X);  axis=Z(2): perp=(X,Y)
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen = [p.cenX, p.cenY, p.cenZ];

    // Strict positive-interval radii contract: 0 < innerRadius < outerRadius.
    float outerR = p.outerRadius;
    if (outerR < 1e-6f) outerR = 1e-6f;
    float eps    = outerR * 1e-4f;
    float innerR = p.innerRadius;
    if (innerR < eps)          innerR = eps;
    if (innerR > outerR - eps) innerR = outerR - eps;

    float halfH = p.height * 0.5f;
    if (halfH < 0.0f) halfH = -halfH;

    uint base = cast(uint)dst.vertices.length;

    // Emit S verts on a ring of radius r at axis-coord cen[axis]+aPos.
    void emitRing(float r, float aPos) {
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float bPos  = -r * cos(theta);
            float cPos  = -r * sin(theta);
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + aPos;
            pos[bIdx]    = cen[bIdx]    + bPos;
            pos[cIdx]    = cen[cIdx]    + cPos;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    // 4 rings: outerBottom(0..S-1), outerTop(S..2S-1),
    //          innerBottom(2S..3S-1), innerTop(3S..4S-1).
    emitRing(outerR, -halfH);   // outerBottom
    emitRing(outerR, +halfH);   // outerTop
    emitRing(innerR, -halfH);   // innerBottom
    emitRing(innerR, +halfH);   // innerTop

    uint outerV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return base + cast(uint)(k * S + jm);
    }
    uint innerV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return base + cast(uint)(2 * S + k * S + jm);
    }

    // Outer wall: S quads, normal points radially outward.
    foreach (j; 0 .. S) {
        dst.addFace([
            outerV(1, j),
            outerV(0, j),
            outerV(0, j + 1),
            outerV(1, j + 1),
        ]);
    }

    // Inner wall: S quads, reversed winding — normal points radially inward.
    foreach (j; 0 .. S) {
        dst.addFace([
            innerV(1, j + 1),
            innerV(0, j + 1),
            innerV(0, j),
            innerV(1, j),
        ]);
    }

    if (!p.cap) return;

    // Top cap: S annular quads, normal points +axis.
    foreach (j; 0 .. S) {
        dst.addFace([
            outerV(1, j),
            outerV(1, j + 1),
            innerV(1, j + 1),
            innerV(1, j),
        ]);
    }

    // Bottom cap: S annular quads, normal points -axis.
    foreach (j; 0 .. S) {
        dst.addFace([
            outerV(0, j),
            innerV(0, j),
            innerV(0, j + 1),
            outerV(0, j + 1),
        ]);
    }
}

// ---------------------------------------------------------------------------
// TubeTool — Create-tool for prim.tube with three-stage interactive draw.
//
// State machine:
//   Idle → DrawingOuter (LMB drag → sets outerRadius)
//   DrawingOuter → OuterSet (LMB up, valid radius)
//   OuterSet → DrawingHeight (LMB drag → sets height)
//   DrawingHeight → HeightSet (LMB up)
//   HeightSet → DrawingInner (LMB drag → sets innerRadius)
//   DrawingInner → InnerSet (LMB up)
//   Right-click / Esc from any state → Idle
//
// Headless path (applyHeadless) bypasses the state machine and appends
// directly from current params_.
// ---------------------------------------------------------------------------

private enum TubeState {
    Idle,
    DrawingOuter,
    OuterSet,
    DrawingHeight,
    HeightSet,
    DrawingInner,
    InnerSet,
}

class TubeTool : Tool {
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*        gpu;
    LitShader       litShader;

    TubeParams      params_;
    CommandHistory  history;
    TubeEditFactory factory;

    TubeState       state;
    Mesh            previewMesh;
    GpuMesh         previewGpu;
    bool            meshChanged;

    // Construction-plane frame captured at first click.
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;
    WorkplaneFrame frame;

    // Drag anchors.
    Vec3 startPoint;
    Vec3 currentPoint;
    Vec3 hpOrigin;
    Vec3 hpn;
    Vec3 heightDragStart;
    Vec3 baseAnchor;

    SnapResult lastSnap;
    Viewport   cachedVp;

    // Mover gizmo for cenX/Y/Z after tube is placed.
    MoveHandler mover;
    int         moverDragAxis = -1;
    int         moverLastMX, moverLastMY;
    ToolHandles toolHandles;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_ = meshSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        mover = new MoveHandler(Vec3(0, 0, 0));
        mover.circleXY.setVisible(false);
        mover.circleYZ.setVisible(false);
        mover.circleXZ.setVisible(false);
        toolHandles = new ToolHandles();
    }

    void destroy() {
        mover.destroy();
    }

    void setUndoBindings(CommandHistory history, TubeEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

    override string name() const { return "Tube"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",        "Position X",    &params_.cenX,        0.0f),
            Param.float_("cenY",        "Position Y",    &params_.cenY,        0.0f),
            Param.float_("cenZ",        "Position Z",    &params_.cenZ,        0.0f),
            Param.float_("outerRadius", "Outer Radius",  &params_.outerRadius, 1.0f).min(0.0f),
            Param.float_("innerRadius", "Inner Radius",  &params_.innerRadius, 0.5f).min(0.0f),
            Param.float_("height",      "Height",        &params_.height,      2.0f).min(0.0f),
            Param.int_("segments",      "Segments",      &params_.segments,    24).min(3).max(256),
            Param.intEnum_("axis",      "Axis",          &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
            Param.bool_("cap",          "Caps",          &params_.cap,         true),
        ];
    }

    override void activate() {
        state         = TubeState.Idle;
        meshChanged   = false;
        moverDragAxis = -1;
        toolHandles.clearHaul();
        previewGpu.init();
    }

    override void deactivate() {
        bool willCommit = state >= TubeState.HeightSet
                       && params_.outerRadius > 1e-5f
                       && params_.height      > 1e-5f;

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (willCommit)
            commitTube();
        state = TubeState.Idle;
        previewGpu.destroy();

        if (willCommit) commitTubeEdit(pre);

        lastSnap = SnapResult.init;
        clearLastSnap();
    }

    override void evaluate() {
        if (state == TubeState.Idle) return;
        rebuildPreview();
    }

    override bool applyHeadless() {
        frame = currentWorkplaneFrame();
        size_t firstNewVert = mesh.vertices.length;
        buildTube(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button == SDL_BUTTON_RIGHT && state != TubeState.Idle) {
            state = TubeState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;

        // Mover drag once tube is fully placed.
        if (state == TubeState.InnerSet) {
            int hit = moverHitTest(e.x, e.y);
            if (hit >= 0) {
                moverDragAxis = hit;
                moverLastMX   = e.x;
                moverLastMY   = e.y;
                return true;
            }
        }

        if (state == TubeState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                    *mesh, EditMode.Vertices);
            publishLastSnap(lastSnap);
            startPoint         = hit;
            currentPoint       = hit;
            params_.axis       = worldAxisIdxOf(planeNormal);
            params_.outerRadius = 0.0f;
            params_.innerRadius = 0.0f;
            params_.height      = 0.0f;
            state = TubeState.DrawingOuter;
            uploadPreview();
            return true;
        }

        if (state == TubeState.OuterSet) {
            // Second drag: height.
            setupHeightPlane();
            baseAnchor = Vec3(params_.cenX, params_.cenY, params_.cenZ);
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            state = TubeState.DrawingHeight;
            uploadPreview();
            return true;
        }

        if (state == TubeState.HeightSet) {
            // Third drag: inner radius on the base plane.
            Vec3 hit;
            if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                   Vec3(params_.cenX, params_.cenY, params_.cenZ),
                                   planeNormal, hit))
                return false;
            state = TubeState.DrawingInner;
            updateInnerRadiusFromHit(hit);
            uploadPreview();
            return true;
        }

        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (moverDragAxis >= 0) { moverDragAxis = -1; toolHandles.clearHaul(); return true; }

        if (state == TubeState.DrawingOuter) {
            if (!(params_.outerRadius > 1e-5f)) {
                state = TubeState.Idle;
                return true;
            }
            state = TubeState.OuterSet;
            uploadPreview();
            return true;
        }
        if (state == TubeState.DrawingHeight) {
            state = TubeState.HeightSet;
            return true;
        }
        if (state == TubeState.DrawingInner) {
            state = TubeState.InnerSet;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (state == TubeState.Idle) {
            WorkplaneFrame f = pickWorkplaneFrame(cachedVp);
            Vec3 lEye = transformPoint(f.toLocal, cachedVp.eye);
            Vec3 lRay = transformDir  (f.toLocal, screenRay(e.x, e.y, cachedVp));
            Vec3 hit;
            if (rayPlaneIntersect(lEye, lRay, Vec3(0, 0, 0), Vec3(0, 1, 0), hit)) {
                lastSnap = snapLocalHit(hit, f, e.x, e.y, cachedVp,
                                        *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
            } else {
                lastSnap = SnapResult.init;
                clearLastSnap();
            }
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

        if (state == TubeState.DrawingOuter) {
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                        *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
                currentPoint = hit;
                // Outer radius = distance from start to current.
                Vec3  d = currentPoint - startPoint;
                float r = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
                params_.cenX = startPoint.x;
                params_.cenY = startPoint.y;
                params_.cenZ = startPoint.z;
                params_.outerRadius = r;
                // Inner radius defaults to half outer, clamped.
                params_.innerRadius = r * 0.5f;
                uploadPreview();
            }
            return true;
        }
        if (state == TubeState.DrawingHeight) {
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
            {
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                        *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
                float signedH   = dot(hit - heightDragStart, planeNormal);
                float fullH     = abs(signedH);
                Vec3  newCen    = baseAnchor + planeNormal * (signedH * 0.5f);
                params_.cenX    = newCen.x;
                params_.cenY    = newCen.y;
                params_.cenZ    = newCen.z;
                params_.height  = fullH;
                uploadPreview();
            }
            return true;
        }
        if (state == TubeState.DrawingInner) {
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  Vec3(params_.cenX, params_.cenY, params_.cenZ),
                                  planeNormal, hit))
            {
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                        *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
                updateInnerRadiusFromHit(hit);
                uploadPreview();
            }
            return true;
        }
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {
        cachedVp = vp;
        drawSnapOverlay(lastSnap, vp, *mesh);
        if (state == TubeState.Idle) return;

        immutable float[16] identity = identityMatrix;
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

        glUseProgram(litShader.program);
        glUniformMatrix4fv(litShader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(litShader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(litShader.locProj,  1, GL_FALSE, vp.proj.ptr);
        glUniform3f(litShader.locLightDir, lightDir.x, lightDir.y, lightDir.z);
        glUniform3f(litShader.locEyePos,   vp.eye.x,   vp.eye.y,   vp.eye.z);
        glUniform1f(litShader.locAmbient,  0.20f);
        glUniform1f(litShader.locSpecStr,  0.25f);
        glUniform1f(litShader.locSpecPow,  32.0f);
        previewGpu.drawFaces(litShader);

        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        previewGpu.drawEdges(shader.locColor, -1, []);

        if (state == TubeState.InnerSet) {
            mover.setPosition(toWorldP(Vec3(params_.cenX, params_.cenY, params_.cenZ)));
            mover.setOrientation(frame.axis1, frame.normal, frame.axis2);
            toolHandles.begin();
            toolHandles.add(mover.centerBox, 10);
            toolHandles.add(mover.arrowX,    0);
            toolHandles.add(mover.arrowY,    1);
            toolHandles.add(mover.arrowZ,    2);
            if (moverDragAxis >= 0) toolHandles.setHaul(moverDragAxis <= 2 ? moverDragAxis : 10);
            else                    toolHandles.setHaul(-1);
            int hmx, hmy;
            queryMouse(hmx, hmy);
            toolHandles.update(hmx, hmy, vp);
            mover.draw(shader, vp);
        }
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (state == TubeState.Idle)
            ImGui.TextDisabled("Drag in viewport to set outer radius.");
        else if (state == TubeState.OuterSet)
            ImGui.TextDisabled("Drag again to set height.");
        else if (state == TubeState.HeightSet)
            ImGui.TextDisabled("Drag again to set inner radius.");
    }

    // History-coordination hooks (undo/redo migration).
    public override bool hasUncommittedEdit() const {
        return state >= TubeState.HeightSet
            && params_.outerRadius > 1e-5f
            && params_.height      > 1e-5f;
    }
    public override void cancelUncommittedEdit() { state = TubeState.Idle; }
    public override void resyncSession()         { state = TubeState.Idle; }

private:
    static int worldAxisIdxOf(Vec3 v) {
        if (abs(v.x) > 0.5f) return 0;
        if (abs(v.y) > 0.5f) return 1;
        return 2;
    }

    Vec3 localEye() const { return transformPoint(frame.toLocal, cachedVp.eye); }
    Vec3 localRay(int x, int y) const {
        return transformDir(frame.toLocal, screenRay(x, y, cachedVp));
    }
    Vec3 toWorldP(Vec3 p) const { return transformPoint(frame.toWorld, p); }
    Vec3 toWorldD(Vec3 d) const { return transformDir  (frame.toWorld, d); }
    Vec3 toLocalD(Vec3 d) const { return transformDir  (frame.toLocal, d); }

    // Copied from CylinderTool (cylinder.d:729) — NOT a shared create_common helper.
    void applyFrameToMeshRange(Mesh* m, size_t firstIdx) {
        foreach (i; firstIdx .. m.vertices.length)
            m.vertices[i] = transformPoint(frame.toWorld, m.vertices[i]);
    }

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

    void setupHeightPlane() {
        hpOrigin = Vec3(params_.cenX, params_.cenY, params_.cenZ);
        Vec3 toCamera = localEye() - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    // Update innerRadius from a hit point in local workplane space,
    // measuring the distance from the tube center to the hit projected
    // onto the base plane, clamped below outerRadius.
    void updateInnerRadiusFromHit(Vec3 hit) {
        Vec3  cen = Vec3(params_.cenX, params_.cenY, params_.cenZ);
        Vec3  d   = hit - cen;
        // Project out the axis component (stay in the plane).
        d = d - planeNormal * dot(d, planeNormal);
        float r = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        // Clamp strictly below outerRadius.
        float maxInner = params_.outerRadius * (1.0f - 1e-4f);
        if (r > maxInner) r = maxInner;
        if (r < params_.outerRadius * 1e-4f) r = params_.outerRadius * 1e-4f;
        params_.innerRadius = r;
    }

    void rebuildPreview() {
        previewMesh.clear();
        buildTube(&previewMesh, params_);
        applyFrameToMeshRange(&previewMesh, 0);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    void commitTube() {
        size_t firstNewVert = mesh.vertices.length;
        buildTube(mesh, params_);
        applyFrameToMeshRange(mesh, firstNewVert);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitTubeEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Tube");
        history.record(cmd);
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

// ---------------------------------------------------------------------------
// Pure module unittests for buildTube (run by `dub test --config=modeling`).
// ---------------------------------------------------------------------------
unittest {  // (a) default → 96 verts / 96 faces (S=24, capped)
    Mesh m;
    TubeParams p;   // defaults: outerRadius=1, innerRadius=0.5, height=2, S=24, cap=true
    buildTube(&m, p);
    assert(m.vertices.length == 96,
        "default tube: expected 96 verts, got " ~ m.vertices.length.stringof);
    assert(m.faces.length == 96,
        "default tube: expected 96 faces, got " ~ m.faces.length.stringof);
}

unittest {  // (b) on-circle radii and axis positions
    import std.math : fabs, sqrt;
    Mesh m;
    TubeParams p;
    p.outerRadius = 2.0f;
    p.innerRadius = 1.0f;
    p.height      = 4.0f;
    p.segments    = 8;
    p.axis        = 1;   // Y
    buildTube(&m, p);
    // outerBottom: verts 0..7  — Y=-2, perp radius=2
    // outerTop:    verts 8..15 — Y=+2, perp radius=2
    // innerBottom: verts 16..23 — Y=-2, perp radius=1
    // innerTop:    verts 24..31 — Y=+2, perp radius=1
    assert(m.vertices.length == 32);
    // Check axis coords and radii for a few verts.
    auto v = m.vertices;
    foreach (j; 0 .. 8) {
        // outerBottom
        assert(fabs(v[j].y + 2.0f) < 1e-4f);
        float rOB = sqrt(v[j].x*v[j].x + v[j].z*v[j].z);
        assert(fabs(rOB - 2.0f) < 1e-4f);
        // outerTop
        assert(fabs(v[8 + j].y - 2.0f) < 1e-4f);
        float rOT = sqrt(v[8+j].x*v[8+j].x + v[8+j].z*v[8+j].z);
        assert(fabs(rOT - 2.0f) < 1e-4f);
        // innerBottom
        assert(fabs(v[16 + j].y + 2.0f) < 1e-4f);
        float rIB = sqrt(v[16+j].x*v[16+j].x + v[16+j].z*v[16+j].z);
        assert(fabs(rIB - 1.0f) < 1e-4f);
        // innerTop
        assert(fabs(v[24 + j].y - 2.0f) < 1e-4f);
        float rIT = sqrt(v[24+j].x*v[24+j].x + v[24+j].z*v[24+j].z);
        assert(fabs(rIT - 1.0f) < 1e-4f);
    }
}

unittest {  // (c) watertight + directed half-edge consistency (capped)
    import std.format : format;
    Mesh m;
    TubeParams p;
    p.segments = 6;
    buildTube(&m, p);

    // Build undirected edge → count map and directed half-edge → count map.
    int[ulong] undirected;
    int[ulong] directed;

    // Encode directed edge (a → b) as ulong.
    static ulong encDir(uint a, uint b) { return (cast(ulong)a << 32) | b; }
    // Encode undirected edge as canonical pair (min, max).
    static ulong encUnd(uint a, uint b) {
        uint lo = a < b ? a : b;
        uint hi = a < b ? b : a;
        return (cast(ulong)lo << 32) | hi;
    }

    foreach (f; m.faces) {
        for (int i = 0; i < cast(int)f.length; ++i) {
            uint a = f[i];
            uint b = f[(i + 1) % cast(int)f.length];
            directed[encDir(a, b)] += 1;
            undirected[encUnd(a, b)] += 1;
        }
    }

    // Every undirected edge must appear in exactly 2 faces (watertight).
    foreach (k, cnt; undirected)
        assert(cnt == 2, format("watertight: undirected edge has count %d (expected 2)", cnt));

    // Every directed half-edge must appear exactly once (consistent orientation).
    foreach (k, cnt; directed)
        assert(cnt == 1, format("consistency: directed half-edge has count %d (expected 1)", cnt));
}

unittest {  // (d) cap=false → 2*S faces, has boundary edges
    Mesh m;
    TubeParams p;
    p.segments = 6;
    p.cap      = false;
    buildTube(&m, p);
    assert(m.faces.length == 12,   // 2*6 faces
        "cap=false: expected 12 faces");
    assert(m.vertices.length == 24, // still 4*6 verts
        "cap=false: expected 24 verts");

    // At least one boundary edge (undirected edge count == 1).
    int[ulong] undirected;
    static ulong encUnd(uint a, uint b) {
        uint lo = a < b ? a : b;
        uint hi = a < b ? b : a;
        return (cast(ulong)lo << 32) | hi;
    }
    foreach (f; m.faces) {
        for (int i = 0; i < cast(int)f.length; ++i) {
            uint a = f[i];
            uint b = f[(i + 1) % cast(int)f.length];
            undirected[encUnd(a, b)] += 1;
        }
    }
    bool hasBoundary = false;
    foreach (k, cnt; undirected)
        if (cnt == 1) { hasBoundary = true; break; }
    assert(hasBoundary, "cap=false: expected at least one boundary edge");
}

unittest {  // (e) per-family normal SIGN — the inside-out guard
    import std.math : fabs, sqrt;
    import std.format : format;

    Mesh m;
    TubeParams p;
    p.segments = 8;
    p.axis     = 1;   // Y
    buildTube(&m, p);

    int S = p.segments;
    // Face families: [0..S) outer wall, [S..2S) inner wall,
    //                [2S..3S) top cap, [3S..4S) bottom cap.

    // Geometric face normal via cross product of diagonals:
    //   n = (v2-v0) × (v3-v1)
    Vec3 faceNormal(int fi) {
        auto f = m.faces[fi];
        Vec3 v0 = m.vertices[f[0]];
        Vec3 v1 = m.vertices[f[1]];
        Vec3 v2 = m.vertices[f[2]];
        Vec3 v3 = m.vertices[f[3]];
        Vec3 d0 = Vec3(v2.x-v0.x, v2.y-v0.y, v2.z-v0.z);
        Vec3 d1 = Vec3(v3.x-v1.x, v3.y-v1.y, v3.z-v1.z);
        return Vec3(d0.y*d1.z - d0.z*d1.y,
                    d0.z*d1.x - d0.x*d1.z,
                    d0.x*d1.y - d0.y*d1.x);
    }

    // Face centroid.
    Vec3 faceCentroid(int fi) {
        auto f = m.faces[fi];
        Vec3 c = Vec3(0, 0, 0);
        foreach (vi; f) {
            c.x += m.vertices[vi].x;
            c.y += m.vertices[vi].y;
            c.z += m.vertices[vi].z;
        }
        float n = cast(float)f.length;
        return Vec3(c.x/n, c.y/n, c.z/n);
    }

    // axis=Y: axisIdx=1, +axis direction = (0,1,0).
    // Radial direction for a face = (centroid - axis) projected onto XZ plane.
    Vec3 radialDir(Vec3 cen) {
        // Project onto XZ plane (remove Y component).
        float rx = cen.x - p.cenX;
        float rz = cen.z - p.cenZ;
        float len = sqrt(rx*rx + rz*rz);
        if (len < 1e-9f) return Vec3(1, 0, 0);
        return Vec3(rx/len, 0.0f, rz/len);
    }

    // Outer wall faces [0..S): normal dot radialDir > 0 (outward).
    foreach (fi; 0 .. S) {
        Vec3 n    = faceNormal(fi);
        Vec3 cen  = faceCentroid(fi);
        Vec3 rdir = radialDir(cen);
        float d   = n.x*rdir.x + n.y*rdir.y + n.z*rdir.z;
        assert(d > 0.0f,
            format("outer wall face %d: normal not outward (dot=%f)", fi, d));
    }

    // Inner wall faces [S..2S): normal dot radialDir < 0 (inward).
    foreach (fi; S .. 2*S) {
        Vec3 n    = faceNormal(fi);
        Vec3 cen  = faceCentroid(fi);
        Vec3 rdir = radialDir(cen);
        float d   = n.x*rdir.x + n.y*rdir.y + n.z*rdir.z;
        assert(d < 0.0f,
            format("inner wall face %d: normal not inward (dot=%f)", fi, d));
    }

    // Top cap faces [2S..3S): normal dot (0,1,0) > 0 (+Y).
    foreach (fi; 2*S .. 3*S) {
        Vec3 n = faceNormal(fi);
        assert(n.y > 0.0f,
            format("top cap face %d: normal not +axis (ny=%f)", fi, n.y));
    }

    // Bottom cap faces [3S..4S): normal dot (0,1,0) < 0 (-Y).
    foreach (fi; 3*S .. 4*S) {
        Vec3 n = faceNormal(fi);
        assert(n.y < 0.0f,
            format("bottom cap face %d: normal not -axis (ny=%f)", fi, n.y));
    }
}

unittest {  // degenerate-radii contract: inner=0 → clamped to outerRadius*1e-4
    import std.math : fabs;
    Mesh m;
    TubeParams p;
    p.outerRadius = 1.0f;
    p.innerRadius = 0.0f;   // should be clamped to 1e-4
    p.segments    = 6;
    buildTube(&m, p);
    // Inner bottom ring: verts 12..17 (2*S..3*S-1)
    // Perp radius should be outerRadius*1e-4 = 1e-4.
    import std.math : sqrt;
    foreach (j; 0 .. 6) {
        Vec3 v = m.vertices[12 + j];
        float r = sqrt(v.x*v.x + v.z*v.z);
        assert(r > 0.0f, "clamped inner ring must have non-zero radius");
        assert(fabs(r - 1e-4f) < 1e-5f,
            "inner=0 clamped radius mismatch");
    }
}

unittest {  // degenerate-radii: inner >= outer → clamped to outerRadius*(1-1e-4)
    import std.math : fabs, sqrt;
    Mesh m;
    TubeParams p;
    p.outerRadius = 1.0f;
    p.innerRadius = 2.0f;   // > outer → clamp
    p.segments    = 6;
    buildTube(&m, p);
    float expectedInner = 1.0f * (1.0f - 1e-4f);
    foreach (j; 0 .. 6) {
        Vec3 v = m.vertices[12 + j];
        float r = sqrt(v.x*v.x + v.z*v.z);
        assert(fabs(r - expectedInner) < 1e-4f,
            "inner>=outer clamped radius mismatch");
    }
}
