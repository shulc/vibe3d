module tools.push;

import bindbc.opengl;

import tools.transform;
import mesh;
import editmode;
import math : Vec3, Viewport;
import shader;

import params : Param;

import toolpipe.packets : FalloffPacket;

/// Push tool — translates each selected vert along its smooth (per-vert
/// average of incident face normals) by `dist` units, weighted by the
/// active falloff stage. Mirrors MODO's `xfrm.push` tool's `dist`
/// attribute. The headless apply path is the primary integration point;
/// interactive drag (LMB-Y → live `dist`) is intentionally deferred —
/// the script-friendly attr API is what the cross-engine diff and the
/// other-deform-tool consumers actually need.
class PushTool : TransformTool {
private:
    float headlessDist = 0.0f;

public:
    this(Mesh* mesh, GpuMesh* gpu, EditMode* editMode) {
        super(mesh, gpu, editMode);
    }

    override string name() const { return "Push"; }

    override void activate() {
        super.activate();
        headlessDist = 0.0f;
    }

    override Param[] params() {
        return [
            // `dist` matches MODO `xfrm.push` attr name (Distance).
            Param.float_("dist", "Distance", &headlessDist, 0.0f),
        ];
    }

    // No drag-handler hooks: this tool is currently driven entirely
    // through `tool.attr xfrm.push dist <v>; tool.doApply` (the
    // headless / scripted path). Interactive Y-drag-to-distance can
    // land later if a use case surfaces.
    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        // No gizmo for now; the falloff overlay still renders if the
        // user has set up a falloff stage.
        FalloffPacket fp = currentFalloff();
        if (fp.enabled) {
            import falloff_render : drawFalloffOverlay;
            drawFalloffOverlay(fp, vp);
        }
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

    /// Headless apply: each selected vert moves by
    /// `dist · weight(vi) · normal(vi)`. Same falloff / symmetry
    /// plumbing as MoveTool — captured at apply-time then consumed
    /// through the per-vert loop.
    override bool applyHeadless() {
        if (headlessDist == 0.0f) return true;  // no-op
        captureFalloffForDrag();
        captureSymmetryForDrag();
        vertexCacheDirty = true;
        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;

        Vec3[] vn = computeVertexNormals();
        foreach (vi; vertexIndicesToProcess) {
            float w = falloffWeight(vi);
            if (w == 0.0f) continue;
            Vec3 n = vn[vi];
            float k = headlessDist * w;
            mesh.vertices[vi].x += n.x * k;
            mesh.vertices[vi].y += n.y * k;
            mesh.vertices[vi].z += n.z * k;
        }
        applySymmetryToDrag();
        return true;
    }
}
