module commands.workplane;

import std.math : isNaN, sqrt;
import std.json : JSONValue, JSONType;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh    : Mesh;
import view;
import editmode : EditMode;
import params : Param, wireArgs;
import math     : Vec3, dot, cross, normalize;

import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stages.workplane : WorkplaneStage;

// ---------------------------------------------------------------------------
// `workplane.*` commands. All target the singleton WorkplaneStage
// (ordinal 0x30) in the global ToolPipeContext. User-facing API:
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
// Equivalent to a "Reset Work Plane" menu entry.
// ---------------------------------------------------------------------------
class WorkplaneResetCommand : Command, Operator {
    mixin OperatorActrCommon;
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.reset"; }
    override string label() const { return "Reset Work Plane"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.reset: WorkplaneStage not registered");
        wp.reset();
        // Task 0791 — the stage's reset() is shared with the lifecycle paths,
        // so the count lives here, where the user actually asked for it.
        wp.noteSlotArmed();
        return true;
    }
}

// ---------------------------------------------------------------------------
// workplane.edit — set absolute cen / rot. Any unprovided field is left
// untouched (so `workplane.edit rotZ:90` rotates around Z without
// nuking center). Float values are JSON-typed; missing keys read as
// NaN through the WorkplaneStage.edit signature.
// Equivalent to an "Edit Work Plane" panel.
// ---------------------------------------------------------------------------
class WorkplaneEditCommand : Command, Operator {
    mixin OperatorActrCommon;
    private float cenX_, cenY_, cenZ_, rotX_, rotY_, rotZ_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
        cenX_ = cenY_ = cenZ_ = float.nan;
        rotX_ = rotY_ = rotZ_ = float.nan;
    }
    override string name()  const { return "workplane.edit"; }
    override string label() const { return "Edit Work Plane"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// The six declared arguments (task 4062). All NAMED — this command has
    /// no positional form, and declaring them is what gives it one for free.
    /// Each field starts at NaN, which `WorkplaneStage.edit` reads as "leave
    /// this channel alone"; an absent key is never written, so the sentinel
    /// survives exactly as it did through the injector's `readFloat`.
    override Param[] params() {
        return wireArgs(
            Param.float_("cenX", "Center X", &cenX_, float.nan),
            Param.float_("cenY", "Center Y", &cenY_, float.nan),
            Param.float_("cenZ", "Center Z", &cenZ_, float.nan),
            Param.float_("rotX", "Rotate X", &rotX_, float.nan),
            Param.float_("rotY", "Rotate Y", &rotY_, float.nan),
            Param.float_("rotZ", "Rotate Z", &rotZ_, float.nan)
        );
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.edit: WorkplaneStage not registered");
        wp.edit(cenX_, cenY_, cenZ_, rotX_, rotY_, rotZ_);
        return true;
    }
}

// ---------------------------------------------------------------------------
// workplane.rotate axis:X|Y|Z angle:N — delta rotation around a world
// axis. Equivalent to a "Rotate Work Plane" panel.
// ---------------------------------------------------------------------------
class WorkplaneRotateCommand : Command, Operator {
    mixin OperatorActrCommon;
    private string axisStr_;
    private float  angleDeg_ = 0.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.rotate"; }
    override string label() const { return "Rotate Work Plane"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return wireArgs(
            Param.string_("axis", "Axis", &axisStr_, ""),
            Param.float_("angle", "Angle", &angleDeg_, 0.0f)
        );
    }

    void setAxis(string s)  { axisStr_  = s; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
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
}

// ---------------------------------------------------------------------------
// workplane.offset axis:X|Y|Z dist:N — delta translation. Equivalent
// to "Offset Work Plane".
// ---------------------------------------------------------------------------
class WorkplaneOffsetCommand : Command, Operator {
    mixin OperatorActrCommon;
    private string axisStr_;
    private float  dist_ = 0.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.offset"; }
    override string label() const { return "Offset Work Plane"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return wireArgs(
            Param.string_("axis", "Axis", &axisStr_, ""),
            Param.float_("dist", "Distance", &dist_, 0.0f)
        );
    }

    void setAxis(string s) { axisStr_ = s; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
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
}

// ---------------------------------------------------------------------------
// workplane.alignToSelection — derive the plane from the current
// selection. Vertex / edge / polygon selection each have per-mode
// rules; phase-7.1 implements the polygon case (most common in
// practice — sets normal = average face normal, center = average
// face centroid). The other modes log a warning and become no-ops
// until needed.
// ---------------------------------------------------------------------------
class WorkplaneAlignToSelectionCommand : Command, Operator {
    mixin OperatorActrCommon;
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }
    override string name()  const { return "workplane.alignToSelection"; }
    override string label() const { return "Align Work Plane to Selection"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        auto wp = findWorkplane();
        if (wp is null)
            throw new Exception("workplane.alignToSelection: WorkplaneStage not registered");
        if (mesh is null) return false;

        // Polygon mode: average face normal + centroid across selected
        // faces. This is the bread-and-butter "align to that face" UX.
        if (editMode == EditMode.Polygons) {
            if (mesh.faces.length == 0) return false;
            // Perf (task 0388): `mesh.selectedFaces` is a @property that
            // rebuilds a whole `bool[]` per read — both the `.length` guard
            // and the index below allocated one every iteration. `fi` is
            // monotonically increasing, so once it runs past
            // `faceMarks.length` every later `isFaceSelected` call is also
            // out-of-range and returns false — same net effect as the old
            // `break`, without per-iteration allocation.
            uint[] selFaces;
            foreach (fi; 0 .. mesh.faces.length)
                if (mesh.isFaceSelected(fi)) selFaces ~= cast(uint)fi;
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

            // Choose axis2 (= local Z) via the "longest edge along Z
            // axis" rule. For a single polygon: longest edge of that
            // polygon, projected onto the polygon plane. For multiple
            // polygons there's no canonical longest edge across the
            // selection, so fall back to the world-X-projection heuristic.
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

        // Vertex / edge selections (task 7120): one rule table keyed on the
        // selection's element type and count, every row a captured cell of
        // tests/fixtures/workplane_align_and_primitive_placement.json
        // (`align`, `laws.skew_edge_pair`; measured_laws §23). A shape the
        // capture did not cover (>= 4 vertices, >= 3 edges, a non-parallel
        // pair on one polygon, degenerate frames) refuses.
        if (editMode == EditMode.Vertices) return alignToVertices(wp);
        if (editMode == EditMode.Edges)    return alignToEdges(wp);
        return false;
    }
private:
    // Selected elements in selection order: the smallest positive order
    // first; elements never ordered by hand follow, by index.
    static uint[] inSelectionOrder(size_t count, scope bool delegate(size_t) sel,
                                   const(int)[] order) {
        import std.algorithm : sort;
        uint[] ids;
        foreach (i; 0 .. count) if (sel(i)) ids ~= cast(uint)i;
        long key(uint i) {
            const o = i < order.length ? order[i] : 0;
            return o > 0 ? o : long.max;
        }
        ids.sort!((a, b) => key(a) != key(b) ? key(a) < key(b) : a < b);
        return ids;
    }

    // Vertex normal: the UNIFORM average of the adjacent faces' unit normals
    // (unnormalised; callers normalise the sum they need).
    Vec3 vertexNormalSum(uint v) {
        Vec3 acc = Vec3(0, 0, 0);
        foreach (fi, f; mesh.faces)
            foreach (vi; f)
                if (vi == v) { acc = acc + mesh.faceNormal(cast(uint)fi); break; }
        return acc;
    }

    // `dir` projected off `normal`, normalised; false when it vanishes.
    static bool inPlane(Vec3 dir, Vec3 normal, out Vec3 x) {
        Vec3 p = dir - normal * dot(dir, normal);
        if (lengthSq(p) < 1e-12f) return false;
        x = normalize(p);
        return true;
    }

    // Sign convention of a direction the capture fixes only up to sign:
    // the largest-magnitude component positive.
    static Vec3 largestPositive(Vec3 v) {
        import workplane_fit : axisMaxExtent;
        const k = axisMaxExtent([v.x, v.y, v.z]);
        const c = k == 0 ? v.x : k == 1 ? v.y : v.z;
        return c < 0 ? v * -1.0f : v;
    }

    // Commit Y = normal, X, Z = X x Y at `origin` (right-handed, the same
    // column order the polygon branch writes).
    static bool commit(WorkplaneStage wp, Vec3 x, Vec3 y, Vec3 origin) {
        wp.setBasis(y, x, cross(x, y), origin);
        return true;
    }

    // Three points in selection order: origin s, Y = (a-s) x (b-s), X to a.
    static bool threePointFrame(WorkplaneStage wp, Vec3 s, Vec3 a, Vec3 b) {
        Vec3 n = cross(a - s, b - s);
        if (lengthSq(n) < 1e-12f) return false;
        Vec3 y = normalize(n), x;
        if (!inPlane(a - s, y, x)) return false;
        return commit(wp, x, y, s);
    }

    bool alignToVertices(WorkplaneStage wp) {
        auto ids = inSelectionOrder(mesh.vertices.length,
                                    (size_t i) => mesh.isVertexSelected(i),
                                    mesh.vertexSelectionOrder);
        if (ids.length == 1)
            return commit(wp, Vec3(1, 0, 0), Vec3(0, 1, 0), mesh.vertices[ids[0]]);
        if (ids.length == 2) {
            Vec3 v0 = mesh.vertices[ids[0]], v1 = mesh.vertices[ids[1]];
            Vec3 n = vertexNormalSum(ids[0]) + vertexNormalSum(ids[1]);
            if (lengthSq(n) < 1e-12f) return false;
            Vec3 y = normalize(n), x;
            if (!inPlane(v1 - v0, y, x)) return false;
            return commit(wp, largestPositive(x), y, v0);
        }
        if (ids.length == 3)
            return threePointFrame(wp, mesh.vertices[ids[0]], mesh.vertices[ids[1]],
                                   mesh.vertices[ids[2]]);
        return false;
    }

    // Does some polygon carry both edges (each as a consecutive pair)?
    bool sharePolygon(uint[2] e1, uint[2] e2) {
        bool hasEdge(const(uint)[] f, uint[2] e) {
            foreach (i; 0 .. f.length) {
                const a = f[i], b = f[(i + 1) % f.length];
                if ((a == e[0] && b == e[1]) || (a == e[1] && b == e[0])) return true;
            }
            return false;
        }
        foreach (f; mesh.faces)
            if (hasEdge(f, e1) && hasEdge(f, e2)) return true;
        return false;
    }

    bool alignToEdges(WorkplaneStage wp) {
        auto ids = inSelectionOrder(mesh.edges.length,
                                    (size_t i) => mesh.isEdgeSelected(i),
                                    mesh.edgeSelectionOrder);
        if (ids.length == 1) {
            const e = mesh.edges[ids[0]];
            Vec3 a = mesh.vertices[e[0]], b = mesh.vertices[e[1]];
            Vec3 n = vertexNormalSum(e[0]) + vertexNormalSum(e[1]);
            if (lengthSq(n) < 1e-12f) return false;
            Vec3 y = normalize(n), x;
            if (!inPlane(b - a, y, x)) return false;
            return commit(wp, x, y, (a + b) * 0.5f);
        }
        if (ids.length != 2) return false;
        uint[2] e1 = [mesh.edges[ids[0]][0], mesh.edges[ids[0]][1]];
        uint[2] e2 = [mesh.edges[ids[1]][0], mesh.edges[ids[1]][1]];
        // Adjacent pair: the three-vertex frame at the shared vertex, `a` on
        // the FIRST edge.
        foreach (i; 0 .. 2) foreach (j; 0 .. 2) if (e1[i] == e2[j])
            return threePointFrame(wp, mesh.vertices[e1[i]],
                                   mesh.vertices[e1[1 - i]], mesh.vertices[e2[1 - j]]);
        uint[4] ends = [e1[0], e1[1], e2[0], e2[1]];
        Vec3 lo = mesh.vertices[ends[0]], hi = lo;
        foreach (v; ends) {
            Vec3 p = mesh.vertices[v];
            lo = Vec3(p.x < lo.x ? p.x : lo.x, p.y < lo.y ? p.y : lo.y, p.z < lo.z ? p.z : lo.z);
            hi = Vec3(p.x > hi.x ? p.x : hi.x, p.y > hi.y ? p.y : hi.y, p.z > hi.z ? p.z : hi.z);
        }
        Vec3 centre = (lo + hi) * 0.5f;
        if (!sharePolygon(e1, e2)) {
            // No shared endpoint, no shared polygon: the fitted-plane rule.
            import workplane_fit : skewEdgePairFrame, SkewFit;
            import std.stdio : stderr;
            Vec3[] pts;
            foreach (v; ends) pts ~= mesh.vertices[v];
            Vec3 x, y, z;
            final switch (skewEdgePairFrame(pts, x, y, z)) {
                case SkewFit.ok:
                    wp.setBasis(y, x, z, centre);
                    return true;
                case SkewFit.singular:
                    stderr.writeln("align to selection: skew edges lie on a plane through"
                                 ~ " the world origin (reference behaviour not captured)");
                    return false;
                case SkewFit.antiparallel:
                    stderr.writeln("align to selection: skew edges fit a normal opposite its"
                                 ~ " dominant axis (reference behaviour not captured)");
                    return false;
                case SkewFit.degenerate:
                    return false;
            }
        }
        // A pair on one polygon: only the parallel case was captured.
        Vec3 d1 = mesh.vertices[e1[1]] - mesh.vertices[e1[0]];
        Vec3 d2 = mesh.vertices[e2[1]] - mesh.vertices[e2[0]];
        if (lengthSq(d1) < 1e-12f || lengthSq(d2) < 1e-12f) return false;
        if (lengthSq(cross(normalize(d1), normalize(d2))) >= 1e-12f) return false;
        Vec3 n = Vec3(0, 0, 0);
        foreach (v; ends) n = n + vertexNormalSum(v);
        if (lengthSq(n) < 1e-12f) return false;
        Vec3 y = normalize(n), x;
        if (!inPlane(d1, y, x)) return false;
        return commit(wp, largestPositive(x), y, centre);
    }

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
