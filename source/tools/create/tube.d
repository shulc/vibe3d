module tools.create.tube;

import bindbc.sdl;
import operator : VectorStack;

import mesh;
import math;
import params : Param;
import shader : LitShader;
import tools.create.primitive_create_tool : PrimitiveCreateTool;
import tools.create.create_common : snapLocalHit;
import editmode : EditMode;
import snap_render : publishLastSnap;

import std.math : sin, cos, PI, abs, sqrt;

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
// Direct PrimitiveCreateTool subclass (task 0414, 0407 sec A.D2 dedup): tube
// is the one primitive with NO size handles at all, so it doesn't extend
// HandledCreateTool — the shared mover-only default drawToolHandles rig
// (arrowX/Y/Z=0/1/2, centerBox=10) already matches tube's pre-refactor id
// scheme exactly, so this class doesn't even need to override draw(),
// drawToolHandles(), destroy(), or the ctor body beyond a bare super() call.
//
// State machine:
//   Idle -> DrawingOuter (LMB drag -> sets outerRadius)
//   DrawingOuter -> OuterSet (LMB up, valid radius)
//   OuterSet -> DrawingHeight (LMB drag -> sets height)
//   DrawingHeight -> HeightSet (LMB up)
//   HeightSet -> DrawingInner (LMB drag -> sets innerRadius)
//   DrawingInner -> InnerSet (LMB up)
//   Right-click / Esc from any state -> Idle
//
// Headless path (applyHeadless, inherited default) bypasses the state
// machine and appends directly from current params_ via buildInto().
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

final class TubeTool : PrimitiveCreateTool {
private:
    TubeParams params_;
    TubeState  state;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        super(meshSrc, gpu, litShader);
    }

    final void installPreparedActivation() nothrow @nogc {
        state = TubeState.Idle;
        installPreparedPrimitiveActivationPre();
        installPreparedPrimitiveActivationPost();
    }
    version(unittest) void seedPreparedActivationForTest() {
        state = TubeState.InnerSet;
        seedPreparedPrimitiveActivationForTest(true, 2, 9);
    }
    version(unittest) bool preparedActivationForTest() const nothrow @nogc {
        return state == TubeState.Idle && preparedPrimitiveActivationBaseForTest();
    }
    version(unittest) bool preparedActivationDirtyForTest() const nothrow @nogc {
        return state == TubeState.InnerSet &&
            preparedPrimitiveActivationDirtyForTest();
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
            // task 0314: segments drives 4 rings of `segments` verts each;
            // `.enforceBounds()` makes the declared hint authoritative on
            // the headless JSON path.
            Param.int_("segments",      "Segments",      &params_.segments,    24).min(3).max(256).enforceBounds(),
            Param.intEnum_("axis",      "Axis",          &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
            Param.bool_("cap",          "Caps",          &params_.cap,         true),
        ];
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
            if (tryGrabMover(e.x, e.y)) return true;
        }

        if (state == TubeState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!localCursorPlane(e.x, e.y, Vec3(0, 0, 0), planeNormal, hit))
                return false;
            lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                    *mesh, EditMode.Vertices);
            publishLastSnap(lastSnap);
            startPoint          = hit;
            currentPoint        = hit;
            params_.axis        = worldAxisIdxOf(planeNormal);
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
            baseAnchor = center();
            Vec3 hit;
            if (localCursorPlane(e.x, e.y, hpOrigin, hpn, hit))
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
            if (!localCursorPlane(e.x, e.y, center(), planeNormal, hit))
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
        if (tryReleaseMover()) return true;

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
        if (state == TubeState.Idle) updateIdleSnap(e.x, e.y);

        if (handleMoverDrag(e.x, e.y)) return true;

        if (state == TubeState.DrawingOuter) {
            Vec3 hit;
            if (localCursorPlane(e.x, e.y, Vec3(0, 0, 0), planeNormal, hit))
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
            if (localCursorPlane(e.x, e.y, hpOrigin, hpn, hit))
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
            if (localCursorPlane(e.x, e.y, center(), planeNormal, hit))
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

    override void drawProperties() {
        import ImGui = d_imgui;
        if (isIdle())
            ImGui.TextDisabled("Drag in viewport to set outer radius.");
        else if (isOuterSet())
            ImGui.TextDisabled("Drag again to set height.");
        else if (isHeightSet())
            ImGui.TextDisabled("Drag again to set inner radius.");
    }

protected:
    override Vec3 center() const { return Vec3(params_.cenX, params_.cenY, params_.cenZ); }
    override void setCenter(Vec3 c) {
        params_.cenX = c.x; params_.cenY = c.y; params_.cenZ = c.z;
    }

    override bool isIdle() const { return state == TubeState.Idle; }
    override bool showHandles() const { return state == TubeState.InnerSet; }

    override bool willCommit() const {
        return state >= TubeState.HeightSet
            && params_.outerRadius > 1e-5f
            && params_.height      > 1e-5f;
    }
    override void goIdle() nothrow @nogc { state = TubeState.Idle; }
    override ulong preparedDeactivateProductWitness() const nothrow @nogc {
        ulong hash = preparedBytesWitness(&params_, TubeParams.sizeof);
        return (hash ^ cast(ubyte) state) * 1099511628211UL;
    }

    // Exposed for drawProperties() so it never needs to reach into
    // TubeState directly.
    bool isOuterSet()  const { return state == TubeState.OuterSet; }
    bool isHeightSet() const { return state == TubeState.HeightSet; }

    override void buildInto(Mesh* dst) { buildTube(dst, params_); }
    override string commitLabel() const { return "Create Tube"; }

private:
    // Update innerRadius from a hit point in local workplane space,
    // measuring the distance from the tube center to the hit projected
    // onto the base plane, clamped below outerRadius.
    void updateInnerRadiusFromHit(Vec3 hit) {
        Vec3  cen = center();
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
}
