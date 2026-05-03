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

import std.math : sin, cos, PI, abs;

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
// Vertex parametrization (axisY):
//   pole_south  = (0, -sizeY, 0)
//   ring k (k = 0 .. N-2):
//     phi_k = -pi/2 + pi*(k+1)/N
//     for j in 0..S-1, theta_j = 2*pi*j/S:
//       v = (-sizeX * cos(phi) * sin(theta),
//             sizeY * sin(phi),
//            -sizeZ * cos(phi) * cos(theta))
//   pole_north  = (0, +sizeY, 0)
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

    // South pole (index 0 relative to base).
    dst.addVertex(Vec3(p.cenX, p.cenY - p.sizeY, p.cenZ));

    // Latitude rings.
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

    // North pole.
    dst.addVertex(Vec3(p.cenX, p.cenY + p.sizeY, p.cenZ));

    uint southPole = base;
    uint northPole = cast(uint)(base + 1 + (N - 1) * S);

    // Index of vertex j on ring k (k in [0, N-2]).
    uint ringV(int k, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return cast(uint)(base + 1 + k * S + jm);
    }

    // South fan.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(0, j), southPole, ringV(0, j + 1)]);
    }

    // Middle quad rings.
    foreach (k; 0 .. N - 2) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(k + 1, j),
                ringV(k,     j),
                ringV(k,     j + 1),
                ringV(k + 1, j + 1)
            ]);
        }
    }

    // North fan.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(N - 2, j), ringV(N - 2, j + 1), northPole]);
    }
}

// ---------------------------------------------------------------------------
// buildSphereGlobe — dispatch on axis. axisX/axisZ are cyclic permutations
// of the axisY parametrization (verified against modo_cl); both have
// determinant +1 so winding is preserved without face reversal.
//
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

    // Build at origin in axisY frame, then permute and translate.
    SphereParams rp = p;
    rp.cenX = 0; rp.cenY = 0; rp.cenZ = 0;

    Mesh tmp;
    buildSphereGlobeAxisY(&tmp, rp);

    Vec3 center = Vec3(p.cenX, p.cenY, p.cenZ);
    foreach (ref v; tmp.vertices) {
        if (p.axis == 0) {
            // axisX: (x, y, z) → (y, z, x)
            v = Vec3(v.y, v.z, v.x) + center;
        } else {
            // axisZ: (x, y, z) → (z, x, y)
            v = Vec3(v.z, v.x, v.y) + center;
        }
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

// ---------------------------------------------------------------------------
// SphereTool — Create-tool for prim.sphere.
//
// Wire schema matches MODO `prim.sphere` cmdhelptools.cfg. Only `method:globe`
// is implemented; qball/tess parametrizations come in 6.3/6.4.
//
// Interaction model:
//   - activate()   : take pre-snapshot, build default sphere, upload to GPU
//   - drag handles : MoveHandler arrows translate; 6 surface handles (±X/Y/Z)
//                    grow / shrink the corresponding sizeX/Y/Z radius
//   - evaluate()   : rebuild from current params_ on every slider change
//   - deactivate() : commit (pre, post) snapshot pair to history for undo
//
// Headless path (applyHeadless) is the same generator, used by HTTP/modo_diff.
// ---------------------------------------------------------------------------
class SphereTool : Tool {
private:
    Mesh*              mesh;
    GpuMesh*           gpu;
    SphereParams       params_;
    CommandHistory     history;
    SphereEditFactory  factory;
    MeshSnapshot       pre;

    // Move gizmo (3 axis arrows + center plane handle).
    MoveHandler mover;
    int         moverDragAxis = -1;   // 0/1/2 = X/Y/Z arrow, 3 = center plane
    int         moverLastMX, moverLastMY;

    // Six radius handles on the sphere surface — outward axes:
    //   0:+X  1:-X  2:+Y  3:-Y  4:+Z  5:-Z
    BoxHandler[6] radH;
    int           radDragIdx    = -1;
    int           radHoveredIdx = -1;
    int           radLastMX, radLastMY;

    Viewport cachedVp;

    static immutable Vec3[6] RAD_AXES = [
        Vec3( 1, 0, 0), Vec3(-1, 0, 0),
        Vec3( 0, 1, 0), Vec3( 0,-1, 0),
        Vec3( 0, 0, 1), Vec3( 0, 0,-1),
    ];

public:
    this(Mesh* mesh, GpuMesh* gpu) {
        this.mesh = mesh;
        this.gpu  = gpu;
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
        pre = MeshSnapshot.capture(*mesh);
        moverDragAxis = -1;
        radDragIdx    = -1;
        rebuildAndUpload();
    }

    override void deactivate() {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Sphere");
        history.record(cmd);
        pre = MeshSnapshot.init;
    }

    override void evaluate() {
        rebuildAndUpload();
    }

    override bool applyHeadless() {
        // Only Globe is wired up so far.
        if (params_.method != 0) return false;
        rebuildAndUpload();
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT | KMOD_CTRL)) return false;

        // Radius handles take priority — they sit on the surface, often visible
        // even when the move gizmo is occluded by the sphere.
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
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        if (radDragIdx >= 0)    { radDragIdx = -1;    return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }
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
            radLastMX = e.x;
            radLastMY = e.y;
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
                rebuildAndUpload();
            }
            moverLastMX = e.x;
            moverLastMY = e.y;
            return true;
        }
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;

        // Radius handles on the six surface points.
        Vec3 cen = Vec3(params_.cenX, params_.cenY, params_.cenZ);
        Vec3[6] pts = [
            cen + Vec3( params_.sizeX, 0, 0),
            cen + Vec3(-params_.sizeX, 0, 0),
            cen + Vec3(0,  params_.sizeY, 0),
            cen + Vec3(0, -params_.sizeY, 0),
            cen + Vec3(0, 0,  params_.sizeZ),
            cen + Vec3(0, 0, -params_.sizeZ),
        ];
        radHoveredIdx = -1;
        bool radBusy = radDragIdx >= 0;
        foreach (i; 0 .. 6) {
            radH[i].pos  = pts[i];
            radH[i].size = gizmoSize(pts[i], vp, 0.04f);
            radH[i].setForceHovered(radDragIdx == cast(int)i);
            radH[i].setHoverBlocked(radBusy && radDragIdx != cast(int)i);
            radH[i].draw(shader, vp);
            if (radH[i].isHovered()) radHoveredIdx = cast(int)i;
        }

        // Move gizmo at sphere center.
        mover.setPosition(cen);
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

    override void drawProperties() {
        // Schema panel handles all widgets.
    }

private:
    void rebuildAndUpload() {
        Mesh fresh;
        buildSphereGlobe(&fresh, params_);
        fresh.buildLoops();
        fresh.resetSelection();
        *mesh = fresh;
        gpu.upload(*mesh);
    }

    // Apply a world-space drag delta (along the handle's outward axis) to
    // the corresponding sizeX/Y/Z radius. Drag outward grows the sphere;
    // dragging inward past the center clamps to 0.
    void applyRadiusDelta(int idx, Vec3 delta) {
        // Project delta onto the outward axis (handles 0/2/4 along +axis,
        // 1/3/5 along -axis). screenAxisDelta already returns a vector
        // along RAD_AXES[idx], so the dot is essentially a signed scalar.
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
        rebuildAndUpload();
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
