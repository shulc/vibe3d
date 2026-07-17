module tools.deform.push;

import bindbc.opengl;
import operator : VectorStack;

import tools.transform.transform;
import mesh;
import editmode;
import math : Vec3, Viewport, dot;
import shader;

import params : Param;

/// Push tool — translates each selected vert along its smooth (per-vert
/// average of incident face normals) by `dist` units, weighted by the
/// active falloff stage. An `xfrm.push` tool driven by a `dist`
/// attribute. The headless apply path is the primary integration point;
/// interactive drag (LMB-Y → live `dist`) is intentionally deferred —
/// the script-friendly attr API is what the cross-engine diff and the
/// other-deform-tool consumers actually need.
class PushTool : TransformTool {
private:
    float headlessDist = 0.0f;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
    }

    override string name() const { return "Push"; }

    // Task 0393: headlessDist is a STICKY tool-default (this tool has no
    // interactive gesture — it's the whole "setting" surface), already
    // restored onto this field by applyStickyToolDefaults() (tool_presets.d,
    // called from app.d activateToolById) BEFORE activate() runs — don't
    // reset it back to the constructor default here. A brand-new
    // (never-activated) tool still gets 0.0 from the field initializer above.
    override void activate() {
        super.activate();
    }

    override Param[] params() {
        return [
            // `dist` is the push Distance attr.
            Param.float_("dist", "Distance", &headlessDist, 0.0f),
        ];
    }

    // No drag-handler hooks: this tool is currently driven entirely
    // through `tool.attr xfrm.push dist <v>; tool.doApply` (the
    // headless / scripted path). Interactive Y-drag-to-distance can
    // land later if a use case surfaces.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // No gizmo for now. The falloff ring/sphere overlay is emitted
        // once per cell from the app.d `Viewport##k` window loop (task
        // 0213) — a per-tool call here used to draw on ImGui's occluded
        // background list and was never visible.
    }

    /// Compute per-vert normals on demand: average of incident face
    /// normals, then renormalise. Smooth normal — same convention
    /// `mesh.faceNormal` uses (Newell's method) but per-vertex.
    private Vec3[] computeVertexNormals() {
        // D's `float x, y, z;` defaults to NaN — so `new Vec3[](N)`
        // gives every component NaN. Zero-init explicitly before
        // accumulating face normals (otherwise NaN + finite = NaN
        // and the whole mesh collapses).
        Vec3[] norms = new Vec3[](mesh.vertices.length);
        foreach (i; 0 .. norms.length) norms[i] = Vec3(0, 0, 0);
        foreach (fi; 0 .. mesh.faces.length) {
            Vec3 fn = mesh.faceNormal(cast(uint)fi);
            foreach (vi; mesh.faces[fi]) {
                norms[vi].x += fn.x;
                norms[vi].y += fn.y;
                norms[vi].z += fn.z;
            }
        }
        foreach (i; 0 .. norms.length) {
            import std.math : sqrt;
            float l = sqrt(norms[i].x*norms[i].x
                         + norms[i].y*norms[i].y
                         + norms[i].z*norms[i].z);
            if (l > 1e-9f) {
                norms[i].x /= l;
                norms[i].y /= l;
                norms[i].z /= l;
            }
        }
        return norms;
    }

    /// Overshoot guard (task 0319 — fuzz-found: a large negative `dist`
    /// collapsed every vertex of an octahedron onto (0,0,0), status "ok").
    /// Mirrors the bevel/edge-extrude overshoot-clamp pattern (mesh.d
    /// `maxSafeUniformInset` / the edge-extrude face-aware inset clamp):
    /// each moving vert's position is affine in `dist`
    /// (`origPos[vi] + dist*vel[vi]`, `vel[vi] = weight(vi)*normal(vi)`,
    /// zero for verts the falloff/selection didn't pick up). For every
    /// mesh edge, the edge's length PROJECTED ONTO ITS OWN ORIGINAL
    /// DIRECTION is therefore also affine in `dist`; solving where that
    /// projection reaches zero gives the largest safe |dist| in each sign
    /// direction before the edge collapses. A radially symmetric mesh
    /// (octahedron, cube corner — vertex normal parallel to the vector
    /// from the origin) collapses every incident edge simultaneously at
    /// the SAME critical `dist`, which is exactly the reported overshoot.
    /// Unlike bevel (which mints new ring vertices and welds the
    /// coincident ones away), push moves the SAME vertices the mesh
    /// already has, so there is no sane "reuse the coincident vertex"
    /// fallback here — the honest fix is to never let an edge reach zero
    /// length in the first place. `negBound`/`posBound` come back as
    /// ±infinity when no edge constrains that direction (e.g. push can
    /// grow a convex mesh outward without limit).
    private void maxSafePushRange(const Vec3[] vel, out float negBound, out float posBound) {
        import std.math : abs;
        negBound = -float.infinity;
        posBound = float.infinity;
        foreach (e; mesh.edges) {
            const uint va = e[0], vb = e[1];
            Vec3 e0 = mesh.vertices[vb] - mesh.vertices[va];
            const float edgeLen = e0.length;
            if (edgeLen < 1e-9f) continue;
            Vec3 edgeDir = e0 / edgeLen;
            Vec3 p = vel[vb] - vel[va];
            const float denom = -dot(p, edgeDir);
            if (abs(denom) < 1e-9f) continue;
            const float critT = edgeLen / denom;
            if (critT > 0.0f) { if (critT < posBound) posBound = critT; }
            else               { if (critT > negBound) negBound = critT; }
        }
    }

    /// Headless apply: each selected vert moves by
    /// `dist · weight(vi) · normal(vi)`. Same falloff / symmetry
    /// plumbing as MoveTool — captured at apply-time then consumed
    /// through the per-vert loop.
    override bool applyHeadless() {
        if (headlessDist == 0.0f) return true;  // no-op
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        vertexCacheDirty = true;
        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;

        Vec3[] vn = computeVertexNormals();

        // Per-unit-dist velocity for every vertex (zero where the vert
        // isn't moving at all) — feeds the overshoot guard below.
        Vec3[] vel = new Vec3[](mesh.vertices.length);
        foreach (i; 0 .. vel.length) vel[i] = Vec3(0, 0, 0);
        foreach (vi; vertexIndicesToProcess) {
            float w = falloffWeight(vi);
            if (w == 0.0f) continue;
            vel[vi] = vn[vi] * w;
        }

        float negBound, posBound;
        maxSafePushRange(vel, negBound, posBound);
        // Land just short of the collapse point, not exactly on it —
        // push doesn't mint new topology to weld away a coincident
        // vertex like bevel does, so the safe range must stay open.
        const float SAFETY = 0.999f;
        float effDist = headlessDist;
        if (effDist > 0.0f && posBound < float.infinity && effDist > posBound * SAFETY)
            effDist = posBound * SAFETY;
        else if (effDist < 0.0f && negBound > -float.infinity && effDist < negBound * SAFETY)
            effDist = negBound * SAFETY;

        foreach (vi; vertexIndicesToProcess) {
            if (vel[vi].x == 0.0f && vel[vi].y == 0.0f && vel[vi].z == 0.0f) continue;
            Vec3 n = vel[vi];
            mesh.vertices[vi].x += n.x * effDist;
            mesh.vertices[vi].y += n.y * effDist;
            mesh.vertices[vi].z += n.z * effDist;
        }
        applySymmetryToDrag();
        return true;
    }
}
