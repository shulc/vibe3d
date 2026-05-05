module tools.torus;

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
import tools.create_common : pickWorkplane, BuildPlane, pickWorkplaneGizmoBasis;

import std.math : sin, cos, PI, abs, sqrt;

alias TorusEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// TorusParams — vibe3d's prim.torus wire schema.
//
// `prim.torus` is a plugin tool in MODO 902 (no entry in cmdhelptools.cfg,
// not loadable in modo_cl). modo_diff parity is therefore impossible in
// the headless harness; the schema below uses conventional torus parameters
// (`majorRadius`, `minorRadius`, `majorSegments`, `minorSegments`, `axis`)
// rather than MODO's per-axis sizeX/Y/Z. If MODO ever exposes prim.torus
// to the modo_cl path with different attribute names, this struct will be
// the only thing that needs to change to add wire-format parity.
// ---------------------------------------------------------------------------
struct TorusParams {
    float cenX         = 0.0f, cenY = 0.0f, cenZ = 0.0f;
    float majorRadius  = 1.0f;   // radius of the centerline of the tube
    float minorRadius  = 0.25f;  // radius of the tube cross-section
    int   majorSegments = 24;    // segments around the major loop
    int   minorSegments = 12;    // segments around the minor (tube) loop
    int   axis          = 1;     // X=0, Y=1, Z=2 — torus's main axis (the "donut hole" axis)
}

// ---------------------------------------------------------------------------
// buildTorus — emit a quad-only torus into `dst`.
//
// Topology (M = majorSegments, N = minorSegments):
//   verts = M · N
//   faces = M · N quads (manifold, no degenerate triangles)
//
// Vertex parameterisation (axis=A, perpendicular axes B, C cyclic):
//   φ_i = 2π · i / M    (i = 0 .. M-1)   — major loop angle
//   θ_j = 2π · j / N    (j = 0 .. N-1)   — minor loop angle
//   pos[A] = r · sin(θ_j)
//   pos[B] = -(R + r · cos(θ_j)) · cos(φ_i)
//   pos[C] = -(R + r · cos(θ_j)) · sin(φ_i)
//
// Cylinder-style sin/cos placement ensures φ=0,θ=0 lies on the outer rim
// in the -B direction (matches cylinder/sphere conventions).
//
// Quad winding: [v(i,j), v(i+1,j), v(i+1,j+1), v(i,j+1)] with i,j wrapping.
// This gives outward radial normals (verified on a small probe with
// axis=Y, M=4, N=4 — face[0] normal points along -B+normal direction).
// ---------------------------------------------------------------------------
void buildTorus(Mesh* dst, const ref TorusParams p)
{
    int M = p.majorSegments;
    int N = p.minorSegments;
    if (M < 3) M = 3;
    if (N < 3) N = 3;

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float R = abs(p.majorRadius);
    float r = abs(p.minorRadius);

    float[3] cen = [p.cenX, p.cenY, p.cenZ];

    uint base = cast(uint)dst.vertices.length;

    foreach (i; 0 .. M) {
        float phi  = 2.0f * PI * cast(float)i / cast(float)M;
        float cphi = cos(phi);
        float sphi = sin(phi);
        foreach (j; 0 .. N) {
            float theta  = 2.0f * PI * cast(float)j / cast(float)N;
            float ctheta = cos(theta);
            float stheta = sin(theta);
            float rad    = R + r * ctheta;
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + r * stheta;
            pos[bIdx]    = cen[bIdx]    - rad * cphi;
            pos[cIdx]    = cen[cIdx]    - rad * sphi;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    uint vert(int i, int j) {
        int im = i % M; if (im < 0) im += M;
        int jm = j % N; if (jm < 0) jm += N;
        return base + cast(uint)(im * N + jm);
    }

    foreach (i; 0 .. M) {
        foreach (j; 0 .. N) {
            dst.addFace([
                vert(i,     j),
                vert(i + 1, j),
                vert(i + 1, j + 1),
                vert(i,     j + 1)
            ]);
        }
    }
}

// ---------------------------------------------------------------------------
// TorusTool — Create-tool with a two-stage interactive draw mirroring
// CylinderTool / ConeTool / CapsuleTool.
//
//   Idle ── LMB drag on plane ─→ DrawingMajor
//                                  (majorRadius = |cursor − click| on plane;
//                                   minorRadius preview kept at 1/4 of major)
//   DrawingMajor ── LMB up    ─→ MajorSet
//   MajorSet ── LMB drag      ─→ DrawingMinor
//                                  (minorRadius = |signedH| from a height
//                                   plane through the torus center)
//   DrawingMinor ── LMB up    ─→ MinorSet
//
// Box-style anchored-opposite handle drag for the 6 size handles: +B/-B
// and +C/-C handles drive majorRadius (no cen shift — the tube grows
// radially outward in all directions, no opposite-face anchor exists);
// +A/-A handles drive minorRadius (also no cen shift — the tube is
// symmetric about the major plane).
// ---------------------------------------------------------------------------

private enum TorusState { Idle, DrawingMajor, MajorSet, DrawingMinor, MinorSet }

class TorusTool : Tool {
private:
    Mesh*            mesh;
    GpuMesh*         gpu;
    LitShader        litShader;

    TorusParams      params_;
    CommandHistory   history;
    TorusEditFactory factory;

    TorusState       state;
    Mesh             previewMesh;
    GpuMesh          previewGpu;
    bool             meshChanged;

    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;

    Vec3 startPoint;
    Vec3 currentPoint;
    Vec3 hpOrigin;
    Vec3 hpn;
    Vec3 heightDragStart;

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

    void setUndoBindings(CommandHistory history, TorusEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

    override string name() const { return "Torus"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",        "Position X",       &params_.cenX,         0.0f),
            Param.float_("cenY",        "Position Y",       &params_.cenY,         0.0f),
            Param.float_("cenZ",        "Position Z",       &params_.cenZ,         0.0f),
            Param.float_("majorRadius", "Major Radius",     &params_.majorRadius,  1.0f).min(0.0f),
            Param.float_("minorRadius", "Minor Radius",     &params_.minorRadius,  0.25f).min(0.0f),
            Param.int_("majorSegments", "Major Segments",   &params_.majorSegments, 24).min(3).max(256),
            Param.int_("minorSegments", "Minor Segments",   &params_.minorSegments, 12).min(3).max(256),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override void activate() {
        state         = TorusState.Idle;
        meshChanged   = false;
        moverDragAxis = -1;
        sizeDragIdx   = -1;
        previewGpu.init();
    }

    override void deactivate() {
        bool willCommit = (state == TorusState.MajorSet)
                       || (state >= TorusState.DrawingMinor
                           && params_.minorRadius > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == TorusState.MajorSet || state >= TorusState.DrawingMinor)
            commitTorus();

        state = TorusState.Idle;
        previewGpu.destroy();

        if (willCommit) commitTorusEdit(pre);
    }

    override void evaluate() {
        if (state == TorusState.Idle) return;
        rebuildPreview();
    }

    override bool applyHeadless() {
        buildTorus(mesh, params_);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != TorusState.Idle) {
            state = TorusState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        if (state >= TorusState.MajorSet) {
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

        if (state == TorusState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            params_.axis = worldAxisIdxOf(planeNormal);
            params_.cenX = hit.x; params_.cenY = hit.y; params_.cenZ = hit.z;
            params_.majorRadius = 0.0f;
            params_.minorRadius = 0.0f;
            state = TorusState.DrawingMajor;
            uploadPreview();
            return true;
        }

        if (state == TorusState.MajorSet) {
            setupHeightPlane();
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            state = TorusState.DrawingMinor;
            uploadPreview();
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (sizeDragIdx >= 0)   { sizeDragIdx = -1;   return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }

        if (state == TorusState.DrawingMajor) {
            if (params_.majorRadius < 1e-5f) {
                state = TorusState.Idle;
                return true;
            }
            // Seed a sensible minorRadius preview so the torus is visible at
            // MajorSet — the user can grow / shrink it via the second drag.
            // 1/4 of major is a common default ratio.
            params_.minorRadius = params_.majorRadius * 0.25f;
            state = TorusState.MajorSet;
            uploadPreview();
            return true;
        }
        if (state == TorusState.DrawingMinor) {
            state = TorusState.MinorSet;
            return true;
        }
        return false;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e) {
        if (sizeDragIdx >= 0) {
            Vec3 outward = SIZE_AXES[sizeDragIdx];
            bool skip;
            Vec3 delta = screenAxisDelta(e.x, e.y, sizeLastMX, sizeLastMY,
                                         sizeH[sizeDragIdx].pos, outward,
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
                params_.cenX += delta.x;
                params_.cenY += delta.y;
                params_.cenZ += delta.z;
                rebuildPreview();
            }
            moverLastMX = e.x; moverLastMY = e.y;
            return true;
        }

        if (state == TorusState.DrawingMajor) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                currentPoint = hit;
                Vec3  d = currentPoint - startPoint;
                float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                params_.majorRadius = r;
                // Show a thin tube during DrawingMajor so the ring is visible.
                params_.minorRadius = r * 0.05f;
                uploadPreview();
            }
            return true;
        }
        if (state == TorusState.DrawingMinor) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                // Magnitude of the projection onto planeNormal sets the tube
                // thickness — the torus grows symmetrically about the major
                // plane (no center shift; the cross-section is symmetric).
                float signedH = dot(hit - heightDragStart, planeNormal);
                params_.minorRadius = abs(signedH);
                uploadPreview();
            }
            return true;
        }
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == TorusState.Idle) return;

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

        if (state >= TorusState.MajorSet) {
            updateSizeHandlers(vp);
            mover.setPosition(torusCenter());
            Vec3 gAx, gAy, gAz;
            pickWorkplaneGizmoBasis(gAx, gAy, gAz);
            mover.setOrientation(gAx, gAy, gAz);
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
        if (state == TorusState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw the major loop.");
        else if (state == TorusState.MajorSet)
            ImGui.TextDisabled("Drag again to thicken the tube.");
    }

private:
    Vec3 torusCenter() const {
        return Vec3(params_.cenX, params_.cenY, params_.cenZ);
    }

    static int worldAxisIdxOf(Vec3 v) {
        if (abs(v.x) > 0.5f) return 0;
        if (abs(v.y) > 0.5f) return 1;
        return 2;
    }

    void choosePlane(const ref Viewport vp) {
        auto bp = pickWorkplane(vp);
        planeNormal = bp.normal;
        planeAxis1  = bp.axis1;
        planeAxis2  = bp.axis2;
    }

    void setupHeightPlane() {
        hpOrigin = torusCenter();
        Vec3 toCamera = cachedVp.eye - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    void rebuildPreview() {
        previewMesh.clear();
        if (params_.majorRadius > 1e-9f && params_.minorRadius > 1e-9f) {
            buildTorus(&previewMesh, params_);
            previewMesh.buildLoops();
        }
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    void commitTorus() {
        if (params_.majorRadius < 1e-5f || params_.minorRadius < 1e-5f) return;
        buildTorus(mesh, params_);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitTorusEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Torus");
        history.record(cmd);
    }

    // Place the 6 size handles at the bounding-box extremes of the torus:
    //   ±B / ±C handles (perpendicular to axis): outer rim, distance R + r
    //   ±A handles (along axis): top / bottom of the tube, distance r
    void updateSizeHandlers(const ref Viewport vp) {
        Vec3 cen = torusCenter();
        int axisIdx = params_.axis;
        if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;
        float R = params_.majorRadius;
        float r = params_.minorRadius;

        float[3] ext;
        ext[axisIdx]            = r;
        ext[(axisIdx + 1) % 3]  = R + r;
        ext[(axisIdx + 2) % 3]  = R + r;

        Vec3[6] pts = [
            cen + Vec3( ext[0], 0, 0), cen + Vec3(-ext[0], 0, 0),
            cen + Vec3(0,  ext[1], 0), cen + Vec3(0, -ext[1], 0),
            cen + Vec3(0, 0,  ext[2]), cen + Vec3(0, 0, -ext[2]),
        ];
        foreach (i; 0 .. 6) {
            sizeH[i].pos  = pts[i];
            sizeH[i].size = gizmoSize(pts[i], vp, 0.04f);
        }
    }

    // Handle drag: pulling a perpendicular handle (on axes B or C) by d
    // along its outward direction grows majorRadius by d (the tube grows
    // radially outward in all directions; there is no "anchored opposite"
    // because the tube is a closed loop). Pulling the axial handle grows
    // minorRadius by d (tube symmetric about the major plane).
    //
    // No flip-through swapping: with abs() clamping at zero, dragging
    // through inverts the tube into a self-intersecting shape; a clean
    // flip would require domain knowledge we don't have at the schema
    // level. Clamp to >= 0 instead.
    void applySizeDelta(int idx, Vec3 delta) {
        Vec3  outward = SIZE_AXES[idx];
        float d       = dot(delta, outward);
        int   handleAxis = idx / 2;
        bool  isAxisHandle = (handleAxis == params_.axis);
        if (isAxisHandle) {
            params_.minorRadius += d;
            if (params_.minorRadius < 0.0f) params_.minorRadius = 0.0f;
        } else {
            params_.majorRadius += d;
            if (params_.majorRadius < 0.0f) params_.majorRadius = 0.0f;
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
