module tools.capsule;

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

alias CapsuleEditFactory = MeshBevelEdit delegate();

// ---------------------------------------------------------------------------
// CapsuleParams — MODO-aligned wire schema for prim.capsule headless
// invocation.
//
// Field names match cmdhelptools.cfg <hash type="Tool" key="prim.capsule">
// attribute keys verbatim. sizeX/Y/Z are per-axis radii (the labels in the
// schema are "Radius X/Y/Z", same as prim.cylinder).
//
// `endsize` is a *proportional* parameter (verified via modo_cl): the
// hemisphere endcap consumes `endsize · avgPerp` of the axis length, where
// avgPerp = (sizeB + sizeC) / 2 with B, C the two perpendicular axes.
// Clamped so the hemisphere can't exceed sizeA — when endsize·avgPerp ≥
// sizeA the cylinder section collapses to zero height (sphere-equivalent
// shape; the lower and upper equator rings dedup to a single ring and the
// cylinder strips are skipped).
// ---------------------------------------------------------------------------
struct CapsuleParams {
    float cenX  = 0.0f, cenY  = 0.0f, cenZ  = 0.0f;
    float sizeX = 1.0f, sizeY = 1.0f, sizeZ = 1.0f;
    int   sides       = 24;     // verts per ring
    int   segments    = 1;      // cylinder segment count (only matters if cylA > 0)
    int   endsegments = 6;      // hemisphere subdivision (≥ 2)
    float endsize     = 1.0f;   // proportion of avgPerp used as hemisphere height
    int   axis        = 1;      // X=0, Y=1, Z=2 — main axis
}

// ---------------------------------------------------------------------------
// buildCapsule — emit a capsule into `dst` matching MODO prim.capsule's
// vertex layout and winding (verified bit-for-bit against modo_cl).
//
// Topology:
//   south pole + lower hemi intermediates (endsegments-1 rings)
//     + lower equator
//     + cylinder intermediates (segments-1 rings, only if cylA > 0)
//     + upper equator (only if cylA > 0; otherwise lower equator IS shared)
//     + upper hemi intermediates (endsegments-1 rings)
//     + north pole
//
//   ring vertex j (axis-relative, axis=Y example):
//     y = level.aCoord
//     z = -sizeZ · level.radScale · cos(2π·j/S)   [B axis]
//     x = -sizeX · level.radScale · sin(2π·j/S)   [C axis]
//
// Winding (axis=Y):
//   south pole tri: [ring(0,j), pole_south, ring(0,j+1)]   outward -axis
//   ring strip k→k+1: [ring(k+1,j), ring(k,j), ring(k,j+1), ring(k+1,j+1)]
//   north pole tri: [ring(last,j), ring(last,j+1), pole_north]   outward +axis
//
// `axis=X` cycles (A,B,C) = (X,Y,Z); `axis=Z` cycles (A,B,C) = (Z,X,Y).
// ---------------------------------------------------------------------------
void buildCapsule(Mesh* dst, const ref CapsuleParams p)
{
    int S  = p.sides;
    int N  = p.segments;
    int Ne = p.endsegments;
    if (S  < 3) S  = 3;
    if (N  < 1) N  = 1;
    if (Ne < 2) Ne = 2;     // need at least pole + equator

    int axisIdx = p.axis;
    if (axisIdx < 0 || axisIdx > 2) axisIdx = 1;
    int bIdx = (axisIdx + 1) % 3;
    int cIdx = (axisIdx + 2) % 3;

    float[3] cen  = [p.cenX, p.cenY, p.cenZ];
    float[3] size = [p.sizeX, p.sizeY, p.sizeZ];

    float halfA = abs(size[axisIdx]);
    float radB  = size[bIdx];
    float radC  = size[cIdx];

    // Hemisphere axial extent: proportion of the average perpendicular
    // radius, clamped so it can't exceed half the total axis length.
    float avgPerp = (abs(radB) + abs(radC)) * 0.5f;
    float hemH    = abs(p.endsize) * avgPerp;
    if (hemH > halfA) hemH = halfA;
    float cylA = halfA - hemH;

    // Build the list of ring "levels": each (axial coord, radius scale).
    // Equator radii are full size{B,C}; intermediate hemisphere rings scale
    // both perpendicular axes by sin(α).
    struct Level { float aCoord; float radScale; }
    Level[] levels;

    // Lower hemisphere intermediates (k = 1 .. Ne-1; pole at k = 0 is emitted
    // as a single vertex, not part of `levels`).
    foreach (k; 1 .. Ne) {
        float alpha = cast(float)k * (PI * 0.5f) / cast(float)Ne;
        levels ~= Level(-cylA - hemH * cos(alpha), sin(alpha));
    }
    // Lower equator (or shared equator when cylA == 0).
    levels ~= Level(-cylA, 1.0f);
    if (cylA > 1e-9f) {
        // Cylinder intermediate rings + upper equator.
        foreach (m; 1 .. N) {
            float t = cast(float)m / cast(float)N;
            levels ~= Level(-cylA + 2.0f * cylA * t, 1.0f);
        }
        levels ~= Level(+cylA, 1.0f);
    }
    // Upper hemisphere intermediates (mirror of lower, ordered low-α at top).
    foreach (k; 1 .. Ne) {
        int kk = Ne - cast(int)k;
        float alpha = cast(float)kk * (PI * 0.5f) / cast(float)Ne;
        levels ~= Level(+cylA + hemH * cos(alpha), sin(alpha));
    }

    uint base = cast(uint)dst.vertices.length;

    // South pole.
    {
        float[3] pos;
        pos[axisIdx] = cen[axisIdx] - halfA;
        pos[bIdx]    = cen[bIdx];
        pos[cIdx]    = cen[cIdx];
        dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
    }
    uint poleSouth = base;

    // Ring vertices.
    foreach (ref lvl; levels) {
        foreach (j; 0 .. S) {
            float theta = 2.0f * PI * cast(float)j / cast(float)S;
            float aPos = lvl.aCoord;
            float bPos = -radB * lvl.radScale * cos(theta);
            float cPos = -radC * lvl.radScale * sin(theta);
            float[3] pos;
            pos[axisIdx] = cen[axisIdx] + aPos;
            pos[bIdx]    = cen[bIdx]    + bPos;
            pos[cIdx]    = cen[cIdx]    + cPos;
            dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
        }
    }

    // North pole.
    uint poleNorth = base + 1 + cast(uint)(levels.length * S);
    {
        float[3] pos;
        pos[axisIdx] = cen[axisIdx] + halfA;
        pos[bIdx]    = cen[bIdx];
        pos[cIdx]    = cen[cIdx];
        dst.addVertex(Vec3(pos[0], pos[1], pos[2]));
    }

    // Helper: ring vertex by (level index, side index). Wraps j around S.
    uint ringV(int li, int j) {
        int jm = j % S; if (jm < 0) jm += S;
        return base + 1 + cast(uint)(li * S + jm);
    }

    // South pole fan: [ring0(j), pole, ring0(j+1)]  → outward -axis.
    foreach (j; 0 .. S) {
        dst.addFace([ringV(0, j), poleSouth, ringV(0, j + 1)]);
    }

    // Ring strips between adjacent levels.
    foreach (li; 0 .. cast(int)levels.length - 1) {
        foreach (j; 0 .. S) {
            dst.addFace([
                ringV(li + 1, j),
                ringV(li,     j),
                ringV(li,     j + 1),
                ringV(li + 1, j + 1)
            ]);
        }
    }

    // North pole fan: [ringLast(j), ringLast(j+1), pole_north]  → outward +axis.
    int last = cast(int)levels.length - 1;
    foreach (j; 0 .. S) {
        dst.addFace([ringV(last, j), ringV(last, j + 1), poleNorth]);
    }
}

// ---------------------------------------------------------------------------
// CapsuleTool — Create-tool for prim.capsule with two-stage interactive draw.
//
// Mirrors CylinderTool / ConeTool exactly: Idle → DrawingBase (flat ellipse on
// most-facing plane) → BaseSet → DrawingHeight (extrudes into capsule) →
// HeightSet. Box-style anchored-opposite handle drag (size += d/2, cen +=
// outward·d/2, flip-through XOR 1).
// ---------------------------------------------------------------------------

private enum CapsuleState { Idle, DrawingBase, BaseSet, DrawingHeight, HeightSet }

class CapsuleTool : Tool {
private:
    Mesh*              mesh;
    GpuMesh*           gpu;
    LitShader          litShader;

    CapsuleParams      params_;
    CommandHistory     history;
    CapsuleEditFactory factory;

    CapsuleState       state;
    Mesh               previewMesh;
    GpuMesh            previewGpu;
    bool               meshChanged;

    Vec3 planeNormal;
    Vec3 planeAxis1;
    Vec3 planeAxis2;

    Vec3 startPoint;
    Vec3 currentPoint;
    Vec3 hpOrigin;
    Vec3 hpn;
    Vec3 heightDragStart;
    Vec3 baseAnchor;

    bool dragUniform;

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

    void setUndoBindings(CommandHistory history, CapsuleEditFactory factory) {
        this.history = history;
        this.factory = factory;
    }

    override string name() const { return "Capsule"; }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.float_("cenX",  "Position X", &params_.cenX,  0.0f),
            Param.float_("cenY",  "Position Y", &params_.cenY,  0.0f),
            Param.float_("cenZ",  "Position Z", &params_.cenZ,  0.0f),
            Param.float_("sizeX", "Radius X",   &params_.sizeX, 1.0f).min(0.0f),
            Param.float_("sizeY", "Radius Y",   &params_.sizeY, 1.0f).min(0.0f),
            Param.float_("sizeZ", "Radius Z",   &params_.sizeZ, 1.0f).min(0.0f),
            Param.int_("sides",       "Sides",       &params_.sides,       24).min(3).max(256),
            Param.int_("segments",    "Segments",    &params_.segments,    1 ).min(1).max(256),
            Param.int_("endsegments", "End Segments",&params_.endsegments, 6 ).min(2).max(64),
            Param.float_("endsize",   "End Size",    &params_.endsize,     1.0f).min(0.0f),
            Param.intEnum_("axis", "Axis", &params_.axis,
                [IntEnumEntry(0, "x", "X"),
                 IntEnumEntry(1, "y", "Y"),
                 IntEnumEntry(2, "z", "Z")],
                1),
        ];
    }

    override void activate() {
        state         = CapsuleState.Idle;
        meshChanged   = false;
        moverDragAxis = -1;
        sizeDragIdx   = -1;
        previewGpu.init();
    }

    override void deactivate() {
        bool willCommit = (state == CapsuleState.BaseSet)
                       || (state >= CapsuleState.DrawingHeight
                           && currentHeight() > 1e-5f);

        MeshSnapshot pre;
        if (willCommit) pre = MeshSnapshot.capture(*mesh);

        if (state == CapsuleState.BaseSet)
            commitDisk();
        else if (state >= CapsuleState.DrawingHeight && currentHeight() > 1e-5f)
            commitCapsule();
        state = CapsuleState.Idle;
        previewGpu.destroy();

        if (willCommit) commitCapsuleEdit(pre);
    }

    override void evaluate() {
        if (state == CapsuleState.Idle) return;
        rebuildPreview();
    }

    override bool applyHeadless() {
        buildCapsule(mesh, params_);
        mesh.buildLoops();
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) {
        if (e.button == SDL_BUTTON_RIGHT && state != CapsuleState.Idle) {
            state = CapsuleState.Idle;
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        bool ctrlAtClick = (mods & KMOD_CTRL) != 0;

        if (state >= CapsuleState.BaseSet) {
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

        if (state == CapsuleState.Idle) {
            choosePlane(cachedVp);
            Vec3 hit;
            if (!rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                   Vec3(0, 0, 0), planeNormal, hit))
                return false;
            startPoint   = hit;
            currentPoint = hit;
            params_.axis = worldAxisIdxOf(planeNormal);
            params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
            dragUniform = ctrlAtClick;
            state = CapsuleState.DrawingBase;
            uploadPreview();
            return true;
        }

        if (state == CapsuleState.BaseSet) {
            if (ctrlAtClick) {
                baseAnchor = capsuleCenter();
                Vec3 hit;
                if (!rayPlaneIntersect(cachedVp.eye,
                                       screenRay(e.x, e.y, cachedVp),
                                       baseAnchor, planeNormal, hit))
                    return false;
                Vec3  d = hit - baseAnchor;
                float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                setWorldSize(0, r);
                setWorldSize(1, r);
                setWorldSize(2, r);
                dragUniform = true;
                state = CapsuleState.DrawingHeight;
                uploadPreview();
                return true;
            }
            setupHeightPlane();
            baseAnchor = capsuleCenter();
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
                heightDragStart = hit;
            else
                heightDragStart = hpOrigin;
            dragUniform = false;
            state = CapsuleState.DrawingHeight;
            uploadPreview();
            return true;
        }
        return false;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e) {
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (sizeDragIdx >= 0)   { sizeDragIdx = -1;   return true; }
        if (moverDragAxis >= 0) { moverDragAxis = -1; return true; }

        if (state == CapsuleState.DrawingBase) {
            if (dragUniform) {
                if (!(sizeOnAxis(planeAxis1) > 1e-5f)) {
                    state = CapsuleState.Idle;
                    return true;
                }
                state = CapsuleState.HeightSet;
                uploadPreview();
                return true;
            }
            float r1 = sizeOnAxis(planeAxis1);
            float r2 = sizeOnAxis(planeAxis2);
            if (!(r1 > 1e-5f) || !(r2 > 1e-5f)) {
                state = CapsuleState.Idle;
                return true;
            }
            state = CapsuleState.BaseSet;
            uploadPreview();
            return true;
        }
        if (state == CapsuleState.DrawingHeight) {
            state = CapsuleState.HeightSet;
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

        if (state == CapsuleState.DrawingBase) {
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  Vec3(0, 0, 0), planeNormal, hit))
            {
                currentPoint = hit;
                if (dragUniform) syncParamsFromUniformDrag();
                else             syncParamsFromBaseDrag();
                uploadPreview();
            }
            return true;
        }
        if (state == CapsuleState.DrawingHeight) {
            if (dragUniform) {
                Vec3 hit;
                if (rayPlaneIntersect(cachedVp.eye,
                                      screenRay(e.x, e.y, cachedVp),
                                      baseAnchor, planeNormal, hit))
                {
                    Vec3  d = hit - baseAnchor;
                    float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
                    params_.cenX = baseAnchor.x;
                    params_.cenY = baseAnchor.y;
                    params_.cenZ = baseAnchor.z;
                    setWorldSize(0, r);
                    setWorldSize(1, r);
                    setWorldSize(2, r);
                    uploadPreview();
                }
                return true;
            }
            Vec3 hit;
            if (rayPlaneIntersect(cachedVp.eye, screenRay(e.x, e.y, cachedVp),
                                  hpOrigin, hpn, hit))
            {
                // Box-style asymmetric grow: base hemisphere stays anchored
                // at baseAnchor's plane, the upper hemisphere extrudes along
                // signedH·planeNormal. cen sits halfway between baseAnchor
                // and the apex pole; sizeOnAxis is the half-extent.
                float signedH = dot(hit - heightDragStart, planeNormal);
                float fullH   = abs(signedH);
                Vec3  newCen  = baseAnchor + planeNormal * (signedH * 0.5f);
                params_.cenX = newCen.x;
                params_.cenY = newCen.y;
                params_.cenZ = newCen.z;
                writeSizeOnAxis(planeNormal, fullH * 0.5f);
                uploadPreview();
            }
            return true;
        }
        return false;
    }

    override void draw(const ref Shader shader, const ref Viewport vp) {
        cachedVp = vp;
        if (state == CapsuleState.Idle) return;

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

        if (state >= CapsuleState.BaseSet) {
            updateSizeHandlers(vp);
            mover.setPosition(capsuleCenter());
            Vec3 gAx, gAy, gAz;
            pickWorkplaneGizmoBasis(vp, gAx, gAy, gAz);
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
        if (state == CapsuleState.Idle)
            ImGui.TextDisabled("Drag in viewport to draw a base ellipse.");
        else if (state == CapsuleState.BaseSet)
            ImGui.TextDisabled("Drag again to extrude into a capsule.");
    }

private:
    Vec3 capsuleCenter() const {
        return Vec3(params_.cenX, params_.cenY, params_.cenZ);
    }

    static int worldAxisIdxOf(Vec3 v) {
        if (abs(v.x) > 0.5f) return 0;
        if (abs(v.y) > 0.5f) return 1;
        return 2;
    }

    float worldSize(int worldIdx) const {
        final switch (worldIdx) {
            case 0: return params_.sizeX;
            case 1: return params_.sizeY;
            case 2: return params_.sizeZ;
        }
    }

    void setWorldSize(int worldIdx, float v) {
        float a = abs(v);
        final switch (worldIdx) {
            case 0: params_.sizeX = a; break;
            case 1: params_.sizeY = a; break;
            case 2: params_.sizeZ = a; break;
        }
    }

    float sizeOnAxis(Vec3 axisVec) const {
        return worldSize(worldAxisIdxOf(axisVec));
    }

    void writeSizeOnAxis(Vec3 axisVec, float v) {
        setWorldSize(worldAxisIdxOf(axisVec), v);
    }

    float currentHeight() const { return sizeOnAxis(planeNormal) * 2.0f; }

    void choosePlane(const ref Viewport vp) {
        auto bp = pickWorkplane(vp);
        planeNormal = bp.normal;
        planeAxis1  = bp.axis1;
        planeAxis2  = bp.axis2;
    }

    void syncParamsFromBaseDrag() {
        Vec3  d  = currentPoint - startPoint;
        float d1 = dot(d, planeAxis1);
        float d2 = dot(d, planeAxis2);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        params_.sizeX = 0; params_.sizeY = 0; params_.sizeZ = 0;
        writeSizeOnAxis(planeAxis1, abs(d1));
        writeSizeOnAxis(planeAxis2, abs(d2));
    }

    void syncParamsFromUniformDrag() {
        Vec3  d = currentPoint - startPoint;
        float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        params_.cenX = startPoint.x;
        params_.cenY = startPoint.y;
        params_.cenZ = startPoint.z;
        setWorldSize(0, r);
        setWorldSize(1, r);
        setWorldSize(2, r);
    }

    void setupHeightPlane() {
        hpOrigin = capsuleCenter();
        Vec3 toCamera = cachedVp.eye - hpOrigin;
        Vec3 inPlane  = toCamera - planeNormal * dot(toCamera, planeNormal);
        float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
        hpn = len > 1e-6f ? inPlane / len : planeAxis1;
    }

    void rebuildPreview() {
        previewMesh.clear();
        buildCapsule(&previewMesh, params_);
        previewMesh.buildLoops();
        previewGpu.upload(previewMesh);
    }

    void uploadPreview() { rebuildPreview(); }

    void commitDisk() {
        buildCapsule(mesh, params_);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitCapsule() {
        buildCapsule(mesh, params_);
        mesh.buildLoops();
        gpu.upload(*mesh);
        meshChanged = true;
    }

    void commitCapsuleEdit(MeshSnapshot pre) {
        if (history is null || factory is null) return;
        if (!pre.filled) return;
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(pre, post, "Create Capsule");
        history.record(cmd);
    }

    void updateSizeHandlers(const ref Viewport vp) {
        Vec3 cen = capsuleCenter();
        float sx = worldSize(0);
        float sy = worldSize(1);
        float sz = worldSize(2);
        Vec3[6] pts = [
            cen + Vec3( sx, 0, 0), cen + Vec3(-sx, 0, 0),
            cen + Vec3(0,  sy, 0), cen + Vec3(0, -sy, 0),
            cen + Vec3(0, 0,  sz), cen + Vec3(0, 0, -sz),
        ];
        foreach (i; 0 .. 6) {
            sizeH[i].pos  = pts[i];
            sizeH[i].size = gizmoSize(pts[i], vp, 0.04f);
        }
    }

    // Box-style anchored-opposite handle drag — same convention as cylinder
    // and cone (see those tools' applySizeDelta for derivation).
    void applySizeDelta(int idx, Vec3 delta) {
        Vec3  outward  = SIZE_AXES[idx];
        float d        = dot(delta, outward);
        int   worldIdx = idx / 2;
        float oldSize  = worldSize(worldIdx);
        float signedSz = oldSize + d * 0.5f;
        float newSize  = abs(signedSz);

        setWorldSize(worldIdx, newSize);
        Vec3 cenShift = outward * (d * 0.5f);
        params_.cenX += cenShift.x;
        params_.cenY += cenShift.y;
        params_.cenZ += cenShift.z;

        if (signedSz < 0.0f)
            sizeDragIdx ^= 1;

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
