module tools.bend;

import bindbc.opengl;
import operator : VectorStack;

import tools.transform;
import mesh;
import editmode;
import math : Vec3, Vec4, Viewport, dot, cross,
              pivotRotationMatrix, mulMV;
import shader;

import params : Param;

import std.math : PI, abs, sqrt;

/// Bend tool — rotates each vertex around a perpendicular axis through
/// the selection centre by `angle * (spine_coord / spine_half_extent)`,
/// where spine_coord is the vert's signed distance along the user-
/// specified spine direction. A simplified bend operation
/// (angle + spine{X,Y,Z}); a fuller behaviour would also reshape the
/// cross-section into a true arc, which is deferred — this MVP keeps
/// the rotation simple and verifiable against an analytical reference.
///
/// Default spine: +X (`spineX=1`). Bend axis
/// is computed as spine × world-up (`(0, 1, 0)`), falling back to
/// spine × world-Z if the cross is degenerate.
class BendTool : TransformTool {
private:
    float headlessAngleDeg = 0.0f;
    Vec3  headlessSpine    = Vec3(1, 0, 0);

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
    }

    override string name() const { return "Bend"; }

    // Task 0393: headlessAngleDeg/headlessSpine are STICKY tool-defaults
    // (this tool has no interactive gesture — they're the whole "setting"
    // surface), already restored onto these fields by
    // applyStickyToolDefaults() (tool_presets.d, called from app.d
    // activateToolById) BEFORE activate() runs — don't reset them back to
    // the constructor defaults here. A brand-new (never-activated) tool
    // still gets 0/+X from the field initializers above.
    override void activate() {
        super.activate();
    }

    override Param[] params() {
        return [
            // `angle` is the bend angle attr (degrees).
            Param.float_("angle",  "Angle",   &headlessAngleDeg, 0.0f).angle(),
            // spineX/Y/Z are the per-axis spine vector attrs.
            Param.float_("spineX", "Spine X", &headlessSpine.x, 1.0f),
            Param.float_("spineY", "Spine Y", &headlessSpine.y, 0.0f),
            Param.float_("spineZ", "Spine Z", &headlessSpine.z, 0.0f),
        ];
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
        // No gizmo for now. The falloff ring/sphere overlay is emitted
        // once per cell from the app.d `Viewport##k` window loop (task
        // 0213) — a per-tool call here used to draw on ImGui's occluded
        // background list and was never visible.
    }

    /// Headless apply. Bend each masked vert around an axis
    /// perpendicular to the spine, through the selection centre,
    /// scaled by signed distance along spine.
    override bool applyHeadless() {
        if (headlessAngleDeg == 0.0f) return true;
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);
        vertexCacheDirty = true;
        buildVertexCacheIfNeeded();
        if (vertexProcessCount == 0) return false;

        // Normalise the spine.
        float sl2 = headlessSpine.x*headlessSpine.x
                  + headlessSpine.y*headlessSpine.y
                  + headlessSpine.z*headlessSpine.z;
        if (sl2 < 1e-12f) return false;
        float si = 1.0f / sqrt(sl2);
        Vec3 spine = Vec3(headlessSpine.x * si,
                          headlessSpine.y * si,
                          headlessSpine.z * si);

        // Bend axis = spine × world-up; degenerate (spine ∥ up) →
        // spine × world-Z. Both fallbacks land on a clean unit axis.
        Vec3 up = Vec3(0, 1, 0);
        Vec3 bendAx = cross(spine, up);
        float bl2 = bendAx.x*bendAx.x + bendAx.y*bendAx.y + bendAx.z*bendAx.z;
        if (bl2 < 1e-9f) {
            bendAx = cross(spine, Vec3(0, 0, 1));
            bl2    = bendAx.x*bendAx.x + bendAx.y*bendAx.y + bendAx.z*bendAx.z;
            if (bl2 < 1e-9f) return false;  // pathological spine
        }
        float bi = 1.0f / sqrt(bl2);
        bendAx.x *= bi; bendAx.y *= bi; bendAx.z *= bi;

        // Pivot = selection centroid via ACEN.
        cachedCenter = queryActionCenter(vts);
        Vec3 pivot   = cachedCenter;

        // Spine half-extent: max |dot(v - pivot, spine)| over masked verts.
        float halfExt = 0.0f;
        foreach (vi; vertexIndicesToProcess) {
            Vec3 d = mesh.vertices[vi] - pivot;
            float s = abs(d.x*spine.x + d.y*spine.y + d.z*spine.z);
            if (s > halfExt) halfExt = s;
        }
        if (halfExt < 1e-9f) return true;   // all verts on the pivot

        float totalAngle = headlessAngleDeg * cast(float)(PI / 180.0);

        // Apply per-vert rotation. phi = totalAngle · (s / halfExt) · weight.
        foreach (vi; vertexIndicesToProcess) {
            Vec3 d = mesh.vertices[vi] - pivot;
            float s = d.x*spine.x + d.y*spine.y + d.z*spine.z;
            float w = falloffWeight(vi);
            if (w == 0.0f) continue;
            float phi = totalAngle * (s / halfExt) * w;
            auto m = pivotRotationMatrix(pivot, bendAx, phi);
            auto v0 = Vec4(mesh.vertices[vi].x, mesh.vertices[vi].y,
                           mesh.vertices[vi].z, 1.0f);
            auto v1 = mulMV(m, v0);
            mesh.vertices[vi] = Vec3(v1.x, v1.y, v1.z);
        }
        applySymmetryToDrag();
        return true;
    }
}
