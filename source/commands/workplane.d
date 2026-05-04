module commands.workplane;

import std.math : isNaN, sqrt;
import std.json : JSONValue, JSONType;

import command;
import mesh    : Mesh, GpuMesh;
import view;
import editmode : EditMode;
import math     : Vec3, dot, cross, normalize;

import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stages.workplane : WorkplaneStage;

// ---------------------------------------------------------------------------
// MODO-aligned `workplane.*` commands. All target the singleton
// WorkplaneStage at LXs_ORD_WORK in the global ToolPipeContext.
// Mirrors the user-facing API documented in
// `Modo902/help/.../workplane.html`:
//
//   workplane.reset                         — back to auto / origin
//   workplane.edit cenX:N cenY:N cenZ:N
//                  rotX:N rotY:N rotZ:N     — set absolute (any subset)
//   workplane.rotate axis:X|Y|Z angle:N     — apply delta rotation
//   workplane.offset axis:X|Y|Z dist:N      — apply delta translation
//   workplane.alignToSelection              — derive plane from selection
//
// None of these commands mutate the mesh, so isUndoable=false (matches
// existing tool.set / tool.attr conventions).
// ---------------------------------------------------------------------------

private WorkplaneStage findWorkplane() {
    if (g_pipeCtx is null) return null;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (auto wp = cast(WorkplaneStage)s) return wp;
    }
    return null;
}

// ---------------------------------------------------------------------------
// workplane.reset — return Workplane to the default auto-mode + origin.
// MODO equivalent: "Reset Work Plane" menu entry.
// ---------------------------------------------------------------------------
class WorkplaneResetCommand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.reset"; }
    override string label() const { return "Reset Work Plane"; }
    override bool isUndoable() const { return false; }

    override bool apply() {
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.reset: WorkplaneStage not registered");
        wp.reset();
        return true;
    }
    override bool revert() { return false; }
}

// ---------------------------------------------------------------------------
// workplane.edit — set absolute cen / rot. Any unprovided field is left
// untouched (so `workplane.edit rotZ:90` rotates around Z without
// nuking center). Float values are JSON-typed; missing keys read as
// NaN through the WorkplaneStage.edit signature.
// MODO equivalent: "Edit Work Plane" panel.
// ---------------------------------------------------------------------------
class WorkplaneEditCommand : Command {
    private float cenX_, cenY_, cenZ_, rotX_, rotY_, rotZ_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
        cenX_ = cenY_ = cenZ_ = float.nan;
        rotX_ = rotY_ = rotZ_ = float.nan;
    }
    override string name()  const { return "workplane.edit"; }
    override string label() const { return "Edit Work Plane"; }
    override bool isUndoable() const { return false; }

    void setCenX(float v) { cenX_ = v; }
    void setCenY(float v) { cenY_ = v; }
    void setCenZ(float v) { cenZ_ = v; }
    void setRotX(float v) { rotX_ = v; }
    void setRotY(float v) { rotY_ = v; }
    void setRotZ(float v) { rotZ_ = v; }

    override bool apply() {
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.edit: WorkplaneStage not registered");
        wp.edit(cenX_, cenY_, cenZ_, rotX_, rotY_, rotZ_);
        return true;
    }
    override bool revert() { return false; }
}

// ---------------------------------------------------------------------------
// workplane.rotate axis:X|Y|Z angle:N — delta rotation around a world
// axis. MODO equivalent: "Rotate Work Plane" panel.
// ---------------------------------------------------------------------------
class WorkplaneRotateCommand : Command {
    private string axisStr_;
    private float  angleDeg_ = 0.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.rotate"; }
    override string label() const { return "Rotate Work Plane"; }
    override bool isUndoable() const { return false; }

    void setAxis(string s)  { axisStr_  = s; }
    void setAngle(float v)  { angleDeg_ = v; }

    override bool apply() {
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.rotate: WorkplaneStage not registered");
        int axisIdx = axisCharToIdx(axisStr_);
        if (axisIdx < 0)
            throw new Exception(
                "workplane.rotate: axis must be X / Y / Z, got '" ~ axisStr_ ~ "'");
        wp.rotateBy(axisIdx, angleDeg_);
        return true;
    }
    override bool revert() { return false; }
}

// ---------------------------------------------------------------------------
// workplane.offset axis:X|Y|Z dist:N — delta translation. MODO
// equivalent: "Offset Work Plane".
// ---------------------------------------------------------------------------
class WorkplaneOffsetCommand : Command {
    private string axisStr_;
    private float  dist_ = 0.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.offset"; }
    override string label() const { return "Offset Work Plane"; }
    override bool isUndoable() const { return false; }

    void setAxis(string s) { axisStr_ = s; }
    void setDist(float v)  { dist_    = v; }

    override bool apply() {
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.offset: WorkplaneStage not registered");
        int axisIdx = axisCharToIdx(axisStr_);
        if (axisIdx < 0)
            throw new Exception(
                "workplane.offset: axis must be X / Y / Z, got '" ~ axisStr_ ~ "'");
        wp.offsetBy(axisIdx, dist_);
        return true;
    }
    override bool revert() { return false; }
}

// ---------------------------------------------------------------------------
// workplane.alignToSelection — derive the plane from the current
// selection. MODO supports vertex / edge / polygon selection with
// per-mode rules; phase-7.1 implements the polygon case (most common
// in practice — sets normal = average face normal, center = average
// face centroid). The other modes log a warning and become no-ops
// until needed.
// ---------------------------------------------------------------------------
class WorkplaneAlignToSelectionCommand : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.alignToSelection"; }
    override string label() const { return "Align Work Plane to Selection"; }
    override bool isUndoable() const { return false; }

    override bool apply() {
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.alignToSelection: WorkplaneStage not registered");
        if (mesh is null) return false;

        // Polygon mode: average face normal + centroid across selected
        // faces. This is the bread-and-butter "align to that face" UX.
        if (editMode == EditMode.Polygons) {
            if (mesh.faces.length == 0) return false;
            uint[] selFaces;
            foreach (fi; 0 .. mesh.faces.length) {
                if (fi >= mesh.selectedFaces.length) break;
                if (mesh.selectedFaces[fi]) selFaces ~= cast(uint)fi;
            }
            if (selFaces.length == 0) return false;

            Vec3 nAccum = Vec3(0, 0, 0);
            Vec3 cAccum = Vec3(0, 0, 0);
            int  count  = 0;
            foreach (fi; selFaces) {
                auto face = mesh.faces[fi];
                if (face.length < 3) continue;
                Vec3 n = mesh.faceNormal(fi);
                Vec3 c = Vec3(0, 0, 0);
                foreach (vi; face) c = c + mesh.vertices[vi];
                c = c * (1.0f / cast(float)face.length);
                nAccum = nAccum + n;
                cAccum = cAccum + c;
                ++count;
            }
            if (count == 0) return false;
            Vec3 normal = normalize(nAccum * (1.0f / cast(float)count));
            Vec3 center = cAccum * (1.0f / cast(float)count);

            // Choose axis2 (= local Z, MODO's documented "longest edge
            // along Z axis" rule). For a single polygon: longest edge of
            // that polygon, projected onto the polygon plane. For multiple
            // polygons MODO doc says "best guess" — there's no canonical
            // longest edge across the selection, so fall back to the
            // world-X-projection heuristic.
            Vec3 axis2;
            if (selFaces.length == 1) {
                axis2 = longestEdgeOnPlane(mesh, selFaces[0], normal);
                if (lengthSq(axis2) < 1e-12f)
                    axis2 = inPlaneFallback(normal);
            } else {
                axis2 = inPlaneFallback(normal);
            }

            // Right-handed basis: {axis1, normal, axis2} matches the
            // toWorld matrix column order (axis1 = local X, normal =
            // local Y, axis2 = local Z). axis1 = normal × axis2 makes the
            // triple right-handed; the second cross re-orthonormalises
            // axis2 against the resulting axis1 in case axis2 had any
            // floating drift after projection / normalisation.
            Vec3 axis1 = normalize(cross(normal, axis2));
            axis2      = normalize(cross(axis1, normal));
            wp.setBasis(normal, axis1, axis2, center);
            return true;
        }

        // Vertex / Edge: not implemented in 7.1 (per phase7_plan.md the
        // alignToSelection MODO doc has multi-vertex / multi-edge rules
        // we'll add when the feature becomes blocking).
        return false;
    }
    override bool revert() { return false; }

private:
    static float abs1(float x) { return x < 0 ? -x : x; }

    static float lengthSq(Vec3 v) { return v.x*v.x + v.y*v.y + v.z*v.z; }

    // Returns the longest edge of `face`, projected onto the polygon plane
    // (defined by `normal`). Direction is from face[i] to face[(i+1)%N]
    // for the longest pair. Zero vector when the face is degenerate or
    // every projected edge has near-zero length (all parallel to normal,
    // which can't actually happen for a valid polygon).
    static Vec3 longestEdgeOnPlane(Mesh* m, uint faceIdx, Vec3 normal) {
        auto face = m.faces[faceIdx];
        if (face.length < 2) return Vec3(0, 0, 0);
        size_t bestI    = 0;
        float  bestLen2 = -1.0f;
        foreach (i; 0 .. face.length) {
            size_t j = (i + 1) % face.length;
            Vec3 e  = m.vertices[face[j]] - m.vertices[face[i]];
            Vec3 ep = e - normal * dot(e, normal);
            float l2 = lengthSq(ep);
            if (l2 > bestLen2) {
                bestLen2 = l2;
                bestI    = i;
            }
        }
        if (bestLen2 < 1e-12f) return Vec3(0, 0, 0);
        size_t j = (bestI + 1) % face.length;
        Vec3 best   = m.vertices[face[j]] - m.vertices[face[bestI]];
        Vec3 bestEp = best - normal * dot(best, normal);
        return normalize(bestEp);
    }

    // World-X projected onto the plane (used as fallback for multi-poly
    // selection and degenerate single-poly cases). Falls back to world Z
    // when world X is nearly parallel to normal.
    static Vec3 inPlaneFallback(Vec3 normal) {
        Vec3 candidate = Vec3(1, 0, 0);
        if (abs1(dot(candidate, normal)) > 0.99f)
            candidate = Vec3(0, 0, 1);
        return normalize(candidate - normal * dot(candidate, normal));
    }
}

// ---------------------------------------------------------------------------
// Unit-tests for alignToSelection axis-2-from-longest-edge logic.
// Pure-math; no g_pipeCtx / live View needed — exercises
// WorkplaneAlignToSelectionCommand.longestEdgeOnPlane directly.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    Mesh m;

    // 1×2 rectangle in world XY plane (normal = +Z); longest edge = Y axis.
    // Vertices CCW from outside (+Z).
    m.vertices = [
        Vec3(-0.5f, -1.0f, 0),
        Vec3( 0.5f, -1.0f, 0),
        Vec3( 0.5f,  1.0f, 0),
        Vec3(-0.5f,  1.0f, 0),
    ];
    m.faces = [[0u, 1, 2, 3]];

    Vec3 axis2 = WorkplaneAlignToSelectionCommand.longestEdgeOnPlane(
        &m, 0, Vec3(0, 0, 1));
    // Longest edge is v1→v2 = (0, 2, 0) → axis2 should be +Y.
    assert(abs(axis2.x)        < 1e-5f);
    assert(abs(axis2.y - 1.0f) < 1e-5f);
    assert(abs(axis2.z)        < 1e-5f);
}

unittest {
    import std.math : abs, sin, cos, PI;
    Mesh m;

    // Same 1×2 rectangle rotated 30° around Z. Longest edge stays the
    // v1→v2 pair; its world direction rotates with the mesh.
    float a = 30.0f * cast(float)PI / 180.0f;
    float ca = cos(a), sa = sin(a);
    Vec3 rot(Vec3 v) {
        return Vec3(ca*v.x - sa*v.y, sa*v.x + ca*v.y, v.z);
    }
    m.vertices = [
        rot(Vec3(-0.5f, -1.0f, 0)),
        rot(Vec3( 0.5f, -1.0f, 0)),
        rot(Vec3( 0.5f,  1.0f, 0)),
        rot(Vec3(-0.5f,  1.0f, 0)),
    ];
    m.faces = [[0u, 1, 2, 3]];

    // Normal is rotated by 30° around Z too — but rotation around Z keeps
    // Z fixed, so normal = +Z still.
    Vec3 normal = Vec3(0, 0, 1);
    Vec3 axis2  = WorkplaneAlignToSelectionCommand.longestEdgeOnPlane(
        &m, 0, normal);
    // Longest world edge = v2 - v1 = rot((0, 2, 0)) = (-2sin30, 2cos30, 0)
    //                    → normalized = (-0.5, 0.866, 0).
    assert(abs(axis2.x - (-sa)) < 1e-5f);
    assert(abs(axis2.y -   ca ) < 1e-5f);
    assert(abs(axis2.z)         < 1e-5f);
}

unittest {
    // Square face: all edges equal — first edge wins (face[0]→face[1]).
    import std.math : abs;
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),
        Vec3(1, 0, 0),
        Vec3(1, 1, 0),
        Vec3(0, 1, 0),
    ];
    m.faces = [[0u, 1, 2, 3]];

    Vec3 axis2 = WorkplaneAlignToSelectionCommand.longestEdgeOnPlane(
        &m, 0, Vec3(0, 0, 1));
    // First edge v0→v1 = (1, 0, 0) → axis2 = +X (since all equal,
    // longestI stays 0 because the test l2 > bestLen2 is strict).
    assert(abs(axis2.x - 1.0f) < 1e-5f);
    assert(abs(axis2.y)        < 1e-5f);
    assert(abs(axis2.z)        < 1e-5f);
}

unittest {
    // Right-handed basis check. Given (normal, axis2), reconstruct axis1
    // the same way apply() does and verify the triple is right-handed
    // and orthonormal.
    import std.math : abs;
    Vec3 normal = normalize(Vec3(0.3f, 1.0f, 0.4f));
    Vec3 raw    = Vec3(2, 0, 0);     // some in-plane edge (will be projected)
    Vec3 axis2  = normalize(raw - normal * dot(raw, normal));
    Vec3 axis1  = normalize(cross(normal, axis2));
    Vec3 axis2b = normalize(cross(axis1, normal));

    // Orthogonality.
    assert(abs(dot(axis1, normal)) < 1e-5f);
    assert(abs(dot(axis1, axis2b)) < 1e-5f);
    assert(abs(dot(normal, axis2b)) < 1e-5f);
    // Right-handed: axis1 × normal = axis2.
    Vec3 r = cross(axis1, normal);
    assert(abs(r.x - axis2b.x) < 1e-5f);
    assert(abs(r.y - axis2b.y) < 1e-5f);
    assert(abs(r.z - axis2b.z) < 1e-5f);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
private int axisCharToIdx(string s) {
    if (s.length == 0) return -1;
    switch (s) {
        case "X": case "x": return 0;
        case "Y": case "y": return 1;
        case "Z": case "z": return 2;
        default: return -1;
    }
}
