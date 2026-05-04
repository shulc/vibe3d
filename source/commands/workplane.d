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
            Vec3 nAccum = Vec3(0, 0, 0);
            Vec3 cAccum = Vec3(0, 0, 0);
            int  count  = 0;
            foreach (fi; 0 .. mesh.faces.length) {
                if (fi >= mesh.selectedFaces.length) break;
                if (!mesh.selectedFaces[fi]) continue;
                auto face = mesh.faces[fi];
                if (face.length < 3) continue;
                Vec3 n = mesh.faceNormal(cast(uint)fi);
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
            // Pick axis1: world X projected onto the plane (perpendicular
            // to normal). Fall back to world Z if X is parallel to normal.
            Vec3 candidate = Vec3(1, 0, 0);
            if (abs1(dot(candidate, normal)) > 0.99f)
                candidate = Vec3(0, 0, 1);
            Vec3 axis1 = normalize(candidate - normal * dot(candidate, normal));
            Vec3 axis2 = normalize(cross(normal, axis1));
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
