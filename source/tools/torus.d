module tools.torus;

import bindbc.sdl;
import operator : VectorStack;

import mesh;
import math;
import params : Param;
import handler : gizmoSize;
import shader : LitShader;
import tools.primitive_create_tool : HandledCreateTool;
import tools.create_common : snapLocalHit;
import editmode : EditMode;
import snap_render : publishLastSnap;

import std.math : sin, cos, PI, abs, sqrt;

// ---------------------------------------------------------------------------
// TorusParams — vibe3d's prim.torus wire schema.
//
// The schema below uses conventional torus parameters (`majorRadius`,
// `minorRadius`, `majorSegments`, `minorSegments`, `axis`). It's the only
// thing that would need to change to adopt a different wire format.
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

    // Degenerate-radii guard (task 0315, mirrors buildTube's outer/inner
    // clamp): majorRadius <= 0 collapses the whole ring to a point (or
    // flips inside-out with a negative `rad`); minorRadius <= 0 collapses
    // every minor-loop ring to a single point per major-loop position
    // (coincident verts — all N points at fixed i land on the same
    // (bIdx,cIdx) coordinate); minorRadius >= majorRadius makes
    // `rad = R + r·cos(θ)` go non-positive for θ near π, folding the tube
    // through the central axis (self-intersecting). Floor R to a small
    // epsilon, then clamp r into the open interval (0, R) with the same
    // relative epsilon inset buildTube uses for its inner/outer pair.
    float R = abs(p.majorRadius);
    if (R < 1e-6f) R = 1e-6f;
    float rEps = R * 1e-4f;
    float r = abs(p.minorRadius);
    if (r < rEps)     r = rEps;
    if (r > R - rEps) r = R - rEps;

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
// TorusTool — Create-tool with a two-stage interactive draw mirroring the
// cylinder family. Direct HandledCreateTool subclass (task 0414, 0407 sec
// A.D2 dedup): the shared infra (preview/commit plumbing, mover + size-
// handle rig, local<->world workplane helpers) lives in
// source/tools/primitive_create_tool.d, but the major/minor 2-scalar model
// and per-stage math are torus's own (not the cylinder family's sizeX/Y/Z
// shape), so this stays a direct HandledCreateTool subclass rather than
// going through SizedRadialCreateTool!P.
//
//   Idle -- LMB drag on plane --> DrawingMajor
//                                  (majorRadius = |cursor - click| on plane;
//                                   minorRadius preview kept at 1/4 of major)
//   DrawingMajor -- LMB up    --> MajorSet
//   MajorSet -- LMB drag      --> DrawingMinor
//                                  (minorRadius = |signedH| from a height
//                                   plane through the torus center)
//   DrawingMinor -- LMB up    --> MinorSet
//
// Box-style anchored-opposite handle drag for the 6 size handles: +B/-B
// and +C/-C handles drive majorRadius (no cen shift — the tube grows
// radially outward in all directions, no opposite-face anchor exists);
// +A/-A handles drive minorRadius (also no cen shift — the tube is
// symmetric about the major plane).
// ---------------------------------------------------------------------------

private enum TorusState { Idle, DrawingMajor, MajorSet, DrawingMinor, MinorSet }

final class TorusTool : HandledCreateTool {
private:
    TorusParams params_;
    TorusState  state;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        super(meshSrc, gpu, litShader);
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
            // task 0314: majorSegments*minorSegments is the full vertex
            // count (O(M*N)); `.enforceBounds()` makes the declared hint
            // authoritative on the headless JSON path.
            Param.int_("majorSegments", "Major Segments",   &params_.majorSegments, 24).min(3).max(256).enforceBounds(),
            Param.int_("minorSegments", "Minor Segments",   &params_.minorSegments, 12).min(3).max(256).enforceBounds(),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button == SDL_BUTTON_RIGHT && state != TorusState.Idle) {
            state = TorusState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        if (state >= TorusState.MajorSet) {
            if (tryGrabHandles(e.x, e.y)) return true;
        }

        if (state == TorusState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                    *mesh, EditMode.Vertices);
            publishLastSnap(lastSnap);
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
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
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

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (tryReleaseHandles()) return true;

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

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (state == TorusState.Idle) updateIdleSnap(e.x, e.y);

        if (handleSizeDrag(e.x, e.y))  return true;
        if (handleMoverDrag(e.x, e.y)) return true;

        if (state == TorusState.DrawingMajor) {
            Vec3 hit;
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
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
            if (rayPlaneIntersect(localEye(), localRay(e.x, e.y),
                                  hpOrigin, hpn, hit))
            {
                lastSnap = snapLocalHit(hit, frame, e.x, e.y, cachedVp,
                                         *mesh, EditMode.Vertices);
                publishLastSnap(lastSnap);
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

    override void drawProperties() {
        import ImGui = d_imgui;
        if (isIdle())
            ImGui.TextDisabled("Drag in viewport to draw the major loop.");
        else if (isMajorSet())
            ImGui.TextDisabled("Drag again to thicken the tube.");
    }

protected:
    override Vec3 center() const { return Vec3(params_.cenX, params_.cenY, params_.cenZ); }
    override void setCenter(Vec3 c) {
        params_.cenX = c.x; params_.cenY = c.y; params_.cenZ = c.z;
    }

    override bool isIdle() const { return state == TorusState.Idle; }
    override bool showHandles() const { return state >= TorusState.MajorSet; }

    // Commit guard: compound, keyed on minorRadius (NOT `state != Idle`).
    // Category B preview-only cancel: the scene mesh is untouched until
    // commit.
    //
    // RE-DERIVATION (task 0414 PRAVKA 2 — see the plan): pre-refactor the
    // deactivate() CALL guard for commitTorus() (`state==MajorSet ||
    // state>=DrawingMinor`) was WEAKER than this willCommit() (missing the
    // `&& minorRadius>1e-5` term); commitTorus() was safe only because of
    // its OWN internal guard (`if majorRadius<1e-5||minorRadius<1e-5
    // return`, old torus.d:583). willCommit() alone does NOT reproduce
    // that internal guard — see commitValid()'s override below (task 0414
    // review, post-Phase-5 fix) for why and how it's restored.
    override bool willCommit() const {
        return (state == TorusState.MajorSet)
            || (state >= TorusState.DrawingMinor && params_.minorRadius > 1e-5f);
    }

    // Reproduces commitTorus()'s pre-refactor internal guard exactly
    // (old torus.d:583: `if majorRadius<1e-5||minorRadius<1e-5 return;`).
    //
    // willCommit() ==> (major>1e-5 && minor>1e-5) is FALSE in general — the
    // MajorSet arm of willCommit() is unconditional on minorRadius (true
    // regardless of its live value), and minorRadius CAN be under 1e-5
    // while state==MajorSet: either (a) a live size-handle drag on the
    // axis-aligned handle shrinks it there (applySizeDelta clamps at 0,
    // handle drags never touch `state`), or (b) even on the untouched
    // MajorSet baseline, for majorRadius in [1e-5, 4e-5) the auto-seeded
    // minorRadius = major*0.25 already lands under 1e-5. The mirror case
    // (shrinking majorRadius via a perpendicular handle while minorRadius
    // stays healthy, from MinorSet or later) fails the same way: the base's
    // deactivate() only gated appendBuildInto() on willCommit() at first,
    // which does not check majorRadius on that arm either. buildTorus
    // itself CLAMPS degenerate radii rather than rejecting (R floors to
    // 1e-6, r floors to R*1e-4 — never a no-op), so gating appendBuildInto()
    // on willCommit() alone would silently commit a thin torus in exactly
    // the cases the pre-refactor tool committed nothing.
    //
    // The willCommit()-gated snapshot/record skeleton in the shared
    // deactivate() still runs in these degenerate cases (matching
    // commitTorus() being CALLED pre-refactor) — only appendBuildInto() is
    // skipped (matching commitTorus()'s internal early return) — so an
    // empty (pre==post) undo entry gets recorded, byte-for-byte the same
    // as pre-refactor. See tests/test_primitive_torus_interactive.d's
    // "MajorSet degenerate-minor commit guard" and "Undo ladder" unittests
    // for the executable pins (MajorSet-with-dragged-to-zero-minor, and the
    // MinorSet-reached-with-zero-minor-delta case respectively — the two
    // are different code paths: the former has willCommit()==true with
    // commitValid()==false; the latter has both false).
    override bool commitValid() const {
        return willCommit()
            && params_.majorRadius > 1e-5f
            && params_.minorRadius > 1e-5f;
    }

    override void goIdle() { state = TorusState.Idle; }

    // Exposed for drawProperties() so it never needs to reach into
    // TorusState directly.
    bool isMajorSet() const { return state == TorusState.MajorSet; }

    override bool previewValid() const {
        return params_.majorRadius > 1e-9f && params_.minorRadius > 1e-9f;
    }

    override void buildInto(Mesh* dst) { buildTorus(dst, params_); }
    override string commitLabel() const { return "Create Torus"; }

    // Place the 6 size handles at the bounding-box extremes of the torus:
    //   +-B / +-C handles (perpendicular to axis): outer rim, distance R + r
    //   +-A handles (along axis): top / bottom of the tube, distance r
    override void updateSizeHandlers(const ref Viewport vp) {
        Vec3 cen = center();   // local
        int axisIdx = params_.axis;
        if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;
        float R = params_.majorRadius;
        float r = params_.minorRadius;

        float[3] ext;
        ext[axisIdx]            = r;
        ext[(axisIdx + 1) % 3]  = R + r;
        ext[(axisIdx + 2) % 3]  = R + r;

        Vec3[6] localPts = [
            cen + Vec3( ext[0], 0, 0), cen + Vec3(-ext[0], 0, 0),
            cen + Vec3(0,  ext[1], 0), cen + Vec3(0, -ext[1], 0),
            cen + Vec3(0, 0,  ext[2]), cen + Vec3(0, 0, -ext[2]),
        ];
        foreach (i; 0 .. 6) {
            Vec3 worldPos = toWorldP(localPts[i]);
            sizeH[i].pos  = worldPos;
            sizeH[i].size = gizmoSize(worldPos, vp, 0.04f);
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
    override void applySizeDelta(int idx, Vec3 delta) {
        // delta in WORLD; SIZE_AXES are LOCAL outward dirs.
        Vec3  outward = SIZE_AXES[idx];
        Vec3  deltaL  = toLocalD(delta);
        float d       = dot(deltaL, outward);
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
}
