module tools.sphere;

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
import tools.create_common : pickMostFacingPlane, BuildPlane;

import std.math : sin, cos, PI, abs, sqrt;

// Reuses the generic snapshot-pair edit factory used by BoxTool / BevelTool.
alias SphereEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// SphereParams — MODO-aligned wire schema for prim.sphere headless invocation.
//
// Field names match cmdhelptools.cfg <hash type="Tool" key="prim.sphere">
// attribute keys verbatim. Phase 6.2 covers the Globe (UV-sphere) mode only;
// QuadBall and Tesselation come in 6.3 / 6.4.
//
// IMPORTANT: For prim.sphere, sizeX/Y/Z are PER-AXIS RADII (verified against
// modo_cl), not diameters as in prim.cube. MODO labels them "Radius X/Y/Z".
// ---------------------------------------------------------------------------
struct SphereParams {
    int   method = 0;            // 0=globe, 1=qball, 2=tess (only Globe in 6.2)
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 0.5f, sizeY = 0.5f, sizeZ = 0.5f;  // radii; defaults give D=1
    int   sides    = 24;         // longitude segments (Globe)
    int   segments = 24;         // latitude segments (Globe)
    int   axis     = 1;          // X=0, Y=1, Z=2 — pole axis
}

// ---------------------------------------------------------------------------
// buildSphereGlobeAxisY — UV-sphere with poles along Y.
//
// Topology (sides=S, segments=N): south pole + (N-1) latitude rings of S
// verts + north pole = (N-1)*S + 2 verts. S triangles at the south fan,
// (N-2)*S quads in the middle, S triangles at the north fan.
//
// MODO winding (verified):
//   south fan tri:  [ring0[j], pole_south, ring0[(j+1)%S]]
//   middle quad:    [ring_{k+1}[j], ring_k[j], ring_k[(j+1)%S], ring_{k+1}[(j+1)%S]]
//   north fan tri:  [ring_{N-2}[j], ring_{N-2}[(j+1)%S], pole_north]
// ---------------------------------------------------------------------------
private void buildSphereGlobeAxisY(Mesh* dst, const ref SphereParams p)
{
    int S = p.sides;
    int N = p.segments;
    if (S < 3) S = 3;
    if (N < 2) N = 2;

    uint base = cast(uint)dst.vertices.length;

    dst.addVertex(Vec3(p.cenX, p.cenY - p.sizeY, p.cenZ));   // south pole

    foreach (k; 0 .. N - 1) {
        float phi = -PI * 0.5f + PI * cast(float)(k + 1) / cast(float)N;
        float cphi = cos(phi);
        float sphi = sin(phi);
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float ctheta = cos(theta);
            float stheta = sin(theta);
            dst.addVertex(Vec3(
                p.cenX - p.sizeX * cphi * stheta,
                p.cenY + p.sizeY * sphi,
                p.cenZ - p.sizeZ * cphi * ctheta));
        }
    }

    dst.addVertex(Vec3(p.cenX, p.cenY + p.sizeY, p.cenZ));   // north pole

    uint southPole = base;
    uint northPole = cast(uint)(base + 1 + (N - 1) * S);

    uint ringV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return cast(uint)(base + 1 + k * S + jm);
    }

    foreach (j; 0 .. S)
        dst.addFace([ringV(0, j), southPole, ringV(0, j + 1)]);

    foreach (k; 0 .. N - 2)
        foreach (j; 0 .. S)
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);

    foreach (j; 0 .. S)
        dst.addFace([ringV(N - 2, j), ringV(N - 2, j + 1), northPole]);
}

// ---------------------------------------------------------------------------
// buildSphereGlobe — dispatch on axis. axisX/axisZ are cyclic permutations
// of the axisY parametrization (verified against modo_cl); both have
// determinant +1 so winding is preserved without face reversal.
//   axisY: identity
//   axisX: (x, y, z) → (y, z, x)
//   axisZ: (x, y, z) → (z, x, y)
// ---------------------------------------------------------------------------
void buildSphereGlobe(Mesh* dst, const ref SphereParams p)
{
    if (p.axis == 1) {
        buildSphereGlobeAxisY(dst, p);
        return;
    }

    SphereParams rp = p;
    rp.cenX = 0; rp.cenY = 0; rp.cenZ = 0;

    Mesh tmp;
    buildSphereGlobeAxisY(&tmp, rp);

    Vec3 center = Vec3(p.cenX, p.cenY, p.cenZ);
    foreach (ref v; tmp.vertices) {
        if (p.axis == 0)
            v = Vec3(v.y, v.z, v.x) + center;
        else
            v = Vec3(v.z, v.x, v.y) + center;
    }

    uint base = cast(uint)dst.vertices.length;
    foreach (v; tmp.vertices) dst.addVertex(v);
    foreach (ref f; tmp.faces) {
        uint[] fi;
        fi.length = f.length;
        foreach (i, vi; f) fi[i] = vi + base;
        dst.addFace(fi);
    }
}

// Flat ellipse preview for the DrawingBase phase: a single n-gon laid in
// the construction plane with per-axis radii (sizeOnAxis1, sizeOnAxis2).
// Used during "draw a circle on the floor" before extruding into a sphere.
private void buildEllipseBase(Mesh* dst, const ref SphereParams p,
                              Vec3 axis1, Vec3 axis2)
{
    int S = p.sides;
    if (S < 3) S = 3;

    float r1 = abs(axis1.x) > 0.5f ? p.sizeX
             : abs(axis1.y) > 0.5f ? p.sizeY
                                   : p.sizeZ;
    float r2 = abs(axis2.x) > 0.5f ? p.sizeX
             : abs(axis2.y) > 0.5f ? p.sizeY
                                   : p.sizeZ;
    Vec3 cen = Vec3(p.cenX, p.cenY, p.cenZ);

    uint[] ring;
    ring.length = S;
    foreach (j; 0 .. S) {
        float theta = 2.0f * PI * cast(float)j / cast(float)S;
        Vec3 v = cen + axis1 * (r1 * cos(theta))
                     + axis2 * (r2 * sin(theta));
        ring[j] = dst.addVertex(v);
    }
    dst.addFace(ring);
}

// ---------------------------------------------------------------------------
// SphereTool — Create-tool for prim.sphere with two-stage interactive draw.
//
// Wire schema matches MODO `prim.sphere` cmdhelptools.cfg. Only `method:globe`
// is implemented; qball/tess parametrizations come in 6.3/6.4.
//
// Interaction model (mirrors BoxTool):
//   Idle ── LMB drag on viewport ─→ DrawingBase (flat ellipse on plane)
//   DrawingBase ── LMB up ─→ BaseSet
//   BaseSet ── LMB drag on viewport ─→ DrawingHeight (extrudes ellipse → sphere)
//   DrawingHeight ── LMB up ─→ HeightSet (sphere finalized)
//
// During interactive states the actual scene mesh is untouched; only
// previewMesh is rebuilt each frame from params_. The committed sphere
// lands in the scene mesh at deactivate(), wrapped in a snapshot pair
// for undo.
//
// Headless path (applyHeadless) bypasses the state machine and replaces
// the scene mesh directly from current params_.
// ---------------------------------------------------------------------------

private enum SphereState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class SphereTool : Tool {
private:
    Mesh*              mesh;
    GpuMesh*           gpu;
    LitShader          litShader;

    SphereParams       params_;
    CommandHistory     history;
    SphereEditFactory  factory;

    SphereState        state;
    Mesh               previewMesh;
    GpuMesh            previewGpu;
    bool               meshChanged;

    // Construction-plane frame chosen at first click and locked for the
    // whole interaction.
    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;

    // Drag anchors — only valid for the matching state(s).
    Vec3 startPoint;       // DrawingBase: first click on plane
    Vec3 currentPoint;     // DrawingBase: current mouse hit on plane
    Vec3 hpOrigin;         // DrawingHeight: ray-plane origin
    Vec3 hpn;              // DrawingHeight: ray-plane normal (camera-facing)
    Vec3 heightDragStart;  // DrawingHeight: world hit at second LMB press
    Vec3 baseAnchor;       // DrawingHeight: sphere center captured at start

    Viewport cachedVp;

    // Move gizmo (axis-only).
    MoveHandler mover;
    int         moverDragAxis = -1;
    int         moverLastMX, moverLastMY;

    // Six radius handles on the sphere surface — outward axes:
    //   0:+X  1:-X  2:+Y  3:-Y  4:+Z  5:-Z
    BoxHandler[6] radH;
    int           radDragIdx    = -1;
    int           radHoveredIdx = -1;
    int           radLastMX, radLastMY;

    static immutable Vec3[6] RAD_AXES = [
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
            radH[i] = new BoxHandler(Vec3(0, 0, 0), col);
        }
    }

    void destroy() {
        mover.destroy();
        foreach (h; radH) h.destroy();
    }

    void setUndoBindings(CommandHistory history, SphereEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

    override string name() const { return "Sphere"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.intEnum_("method", "Sphere Mode", &params_.method,
                [IntEnumEntry(0, "globe", "Globe"),
                 IntEnumEntry(1, "qball", "QuadBall"),
                 IntEnumEntry(2, "tess",  "Tesselation")],
                0),
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Radius X",   &params_.sizeX, 0.5f).min(0.0f),
            Param.float_("sizeY", "Radius Y",   &params_.sizeY, 0.5f).min(0.0f),
            Param.float_("sizeZ", "Radius Z",   &params_.sizeZ, 0.5f).min(0.0f),
            Param.int_("sides",    "Sides",    &params_.sides,    24).min(3).max(256),
            Param.int_("segments", "Segments", &params_.segments, 24).min(2).max(256),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override void activate() {
        state         = SphereState.Idle;
        meshChanged   = false;
        moverDragAxis = -1;
        radDragIdx    = -1;
        previewGpu.init();
    }

    override void deactivate() {
        bool willCommit = (state == SphereState.BaseSet)
                       || (state >= SphereState.DrawingHeight
                           && currentHeight() > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == SphereState.BaseSet)
            commitBase();
        else if (state >= SphereState.DrawingHeight && currentHeight() > 1e-5f)
            commitSphere();
        state = SphereState.Idle;
        previewGpu.destroy();

        if (willCommit) commitSphereEdit(pre);
    }

    override void evaluate() {
        // Slider tweak in the property panel — re-render preview if we have
        // an active interactive state. After commit (HeightSet → deactivate),
        // the scene mesh is the authority and the panel can't tweak further.
        if (state == SphereState.Idle) return;
        rebuildPreview();
    }

    override bool applyHeadless() {
        // Only Globe is wired up so far.
        if (params_.method != 0) return false;
        Mesh fresh;
        buildSphereGlobe(&fresh, params_);
        fresh.buildLoops();
        fresh.resetSelection();
        *mesh = fresh;
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != SphereState.Idle) {
            state = SphereState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        // Radius handles take priority once a base/sphere exists.
        if (state >= SphereState.BaseSet) {
            foreach (i; 0 .. 6) {
                if (radH[i].hitTest(e.x, e.y, cachedVp)) {
                    radDragIdx = cast(int)i;
                    radLastMX  = e.x;
                    radLastMY  = e.y;
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

        if (state == SphereState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            // Reset all radii; pole axis matches the construction plane normal
            // so the equator lies on the plane the user clicked.
            params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
            params_.axis  = abs(planeNormal.x) > 0.5f ? 0
                          : abs(planeNormal.y) > 0.5f ? 1 : 2;
            state = SphereState.DrawingBase;
            uploadPreview();
            return true;
        }

        if (state == SphereState.BaseSet) {
            // Plane-normal radius is already 0; second drag adds it.
            setupHeightPlane();
            baseAnchor = sphereCenter();
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            state = SphereState.DrawingHeight;
            uploadPreview();
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (radDragIdx >= 0)    { radDragIdx = -1;    return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }

        if (state == SphereState.DrawingBase) {
            // Reject degenerate ellipses (one radius collapsed).
            float r1 = sizeOnAxis(planeAxis1);
            float r2 = sizeOnAxis(planeAxis2);
            if (!(r1 > 1e-5f) || !(r2 > 1e-5f)) {
                state = SphereState.Idle;
                return true;
            }
            state = SphereState.BaseSet;
            uploadPreview();
            return true;
        }
        if (state == SphereState.DrawingHeight) {
            state = SphereState.HeightSet;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (radDragIdx >= 0) {
            Vec3 outward = RAD_AXES[radDragIdx];
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, radLastMX, radLastMY,
                                         radH[radDragIdx].pos, outward,
                                         cachedVp, skip);
            if (!skip) applyRadiusDelta(radDragIdx, delta);
            radLastMX = e.x; radLastMY = e.y;
            return true;
        }
        if (moverDragAxis >= 0) {
            bool skip;
            Vec3 delta = moverDragAxis <= 2
                ? axisDragDelta (e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover, cachedVp, skip)
                : planeDragDelta(e.x, e.y, moverLastMX, moverLastMY,
                                 moverDragAxis, mover.center, cachedVp, skip);
            if (!skip) {
                params_.cenX += delta.x;
                params_.cenY += delta.y;
                params_.cenZ += delta.z;
                rebuildPreview();
            }
            moverLastMX = e.x; moverLastMY = e.y;
            return true;
        }

        if (state == SphereState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                currentPoint = hit;
                syncParamsFromBaseDrag();
                uploadPreview();
            }
            return true;
        }
        if (state == SphereState.DrawingHeight) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                // Signed projection of drag onto planeNormal.
                // Sphere extends from baseAnchor by signedH along normal,
                // so radius (half-extent) = |signedH|/2 and center sits at
                // baseAnchor + signedH/2.
                float signedH = dot(hit - heightDragStart, planeNormal);
                float r       = abs(signedH) * 0.5f;
                Vec3  newCen  = baseAnchor + planeNormal * (signedH * 0.5f);
                params_.cenX = newCen.x;
                params_.cenY = newCen.y;
                params_.cenZ = newCen.z;
                writeSizeOnAxis(planeNormal, r);
                uploadPreview();
            }
            return true;
        }
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == SphereState.Idle) return;

        immutable float[16] identity = identityMatrix;
        Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));

        // Solid faces of preview.
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

        // Wireframe.
        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);
        previewGpu.drawEdges(shader.locColor, -1, []);

        // Handles only show once base is finalized.
        if (state >= SphereState.BaseSet) {
            updateRadHandlers(vp);
            mover.setPosition(sphereCenter());
            radHoveredIdx = -1;
            bool radBusy = radDragIdx >= 0;
            foreach (i; 0 .. 6) {
                radH[i].setForceHovered(radDragIdx == cast(int)i);
                radH[i].setHoverBlocked(radBusy && radDragIdx != cast(int)i);
                radH[i].draw(shader, vp);
                if (radH[i].isHovered()) radHoveredIdx = cast(int)i;
            }
            mover.arrowX.setForceHovered(moverDragAxis == 0);
            mover.arrowY.setForceHovered(moverDragAxis == 1);
            mover.arrowZ.setForceHovered(moverDragAxis == 2);
            mover.centerBox.setForceHovered(moverDragAxis == 3);
            bool radPriority = radDragIdx >= 0 || radHoveredIdx >= 0;
            mover.arrowX.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 0));
            mover.arrowY.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 1));
            mover.arrowZ.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 2));
            mover.centerBox.setHoverBlocked(radPriority || (moverDragAxis >= 0 && moverDragAxis != 3));
            mover.draw(shader, vp);
        }
    }

    override bool drawImGui() { return false; }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (state == SphereState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw a circle.");
        else if (state == SphereState.BaseSet)
            ImGui.TextDisabled("Drag again to extrude into a sphere.");
    }

private:
    // -----------------------------------------------------------------------
    // Helpers — params_ is the single source of truth.
    // -----------------------------------------------------------------------

    Vec3 sphereCenter() const { return Vec3(params_.cenX, params_.cenY, params_.cenZ); }

    float sizeOnAxis(Vec3 axisVec) const {
        if (abs(axisVec.x) > 0.5f) return params_.sizeX;
        if (abs(axisVec.y) > 0.5f) return params_.sizeY;
        return params_.sizeZ;
    }

    void writeSizeOnAxis(Vec3 axisVec, float radius) {
        float v = abs(radius);
        if      (abs(axisVec.x) > 0.5f) params_.sizeX = v;
        else if (abs(axisVec.y) > 0.5f) params_.sizeY = v;
        else                             params_.sizeZ = v;
    }

    float currentHeight() const { return sizeOnAxis(planeNormal) * 2.0f; }

    void choosePlane(const ref Viewport vp) {
        auto bp = pickMostFacingPlane(vp);
        planeNormal = bp.normal;
        planeAxis1  = bp.axis1;
        planeAxis2  = bp.axis2;
    }

    // Update params_ from startPoint/currentPoint while drawing the base.
    // sizeX/Y/Z on the plane axes get half the bbox extent (radii); the
    // plane-normal radius stays 0 (flat ellipse).
    void syncParamsFromBaseDrag() {
        Vec3  d   = currentPoint - startPoint;
        float d1  = dot(d, planeAxis1);
        float d2  = dot(d, planeAxis2);
        Vec3  cen = (startPoint + currentPoint) * 0.5f;
        params_.cenX = cen.x; params_.cenY = cen.y; params_.cenZ = cen.z;
        params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
        writeSizeOnAxis(planeAxis1, abs(d1) * 0.5f);
        writeSizeOnAxis(planeAxis2, abs(d2) * 0.5f);
    }

    void setupHeightPlane() {
        hpOrigin = sphereCenter();
        Vec3 toCamera = cachedVp.eye - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    void rebuildPreview() {
        previewMesh.clear();
        if (sizeOnAxis(planeNormal) > 1e-9f && state >= SphereState.DrawingHeight)
            buildSphereGlobe(&previewMesh, params_);
        else
            buildEllipseBase(&previewMesh, params_, planeAxis1, planeAxis2);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    // Both commit helpers APPEND into the scene mesh — same convention as
    // BoxTool.commitBase / commitCuboid. Replacing would wipe any existing
    // geometry the user already built.
    void commitBase() {
        buildEllipseBase(mesh, params_, planeAxis1, planeAxis2);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitSphere() {
        buildSphereGlobe(mesh, params_);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitSphereEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Sphere");
        history.record(cmd);
    }

    void updateRadHandlers(const ref Viewport vp) {
        Vec3 cen = sphereCenter();
        Vec3[6] pts = [
            cen + Vec3( params_.sizeX, 0, 0),
            cen + Vec3(-params_.sizeX, 0, 0),
            cen + Vec3(0,  params_.sizeY, 0),
            cen + Vec3(0, -params_.sizeY, 0),
            cen + Vec3(0, 0,  params_.sizeZ),
            cen + Vec3(0, 0, -params_.sizeZ),
        ];
        foreach (i; 0 .. 6) {
            radH[i].pos  = pts[i];
            radH[i].size = gizmoSize(pts[i], vp, 0.04f);
        }
    }

    void applyRadiusDelta(int idx, Vec3 delta) {
        Vec3 axisDir = RAD_AXES[idx];
        float d = delta.x * axisDir.x + delta.y * axisDir.y + delta.z * axisDir.z;
        switch (idx / 2) {
            case 0:
                params_.sizeX += d;
                if (params_.sizeX < 0.0f) params_.sizeX = 0.0f;
                break;
            case 1:
                params_.sizeY += d;
                if (params_.sizeY < 0.0f) params_.sizeY = 0.0f;
                break;
            case 2:
                params_.sizeZ += d;
                if (params_.sizeZ < 0.0f) params_.sizeZ = 0.0f;
                break;
            default: assert(0);
        }
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
