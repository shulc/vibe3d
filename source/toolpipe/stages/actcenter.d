module toolpipe.stages.actcenter;

import std.format : format;

import math    : Vec3, Viewport, screenRay, rayPlaneIntersect;
import mesh    : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordAcen;
import toolpipe.pipeline : ToolState;
import popup_state       : setStatePath;

// ---------------------------------------------------------------------------
// ActionCenterStage — phase 7.2a. Sits at LXs_ORD_ACEN = 0x60. Replaces
// hard-coded `selectionCentroid*` in Move / Rotate / Scale with a pluggable
// origin produced by one of the MODO `actr.<mode>` modes.
//
// Modes (mirror MODO `cmdhelptools.cfg` `actr.<X>`):
//   - Auto       — selection centroid if anything selected, else
//                  geometry centroid. Click-outside-gizmo writes
//                  `userPlacedCenter` and `userPlaced=true` but mode
//                  STAYS Auto (matches MODO "Auto NOT fixed; click
//                  away → new center"). Re-selecting "Auto" in the
//                  popup clears userPlaced.
//   - Select     — strict selection centroid (no fallback to geometry).
//                  `selectSubMode` picks which side of the bounding
//                  box of the selection (center / top / bottom / back
//                  / front / left / right — bbox in world XYZ).
//   - SelectAuto — selection centroid, axis is realigned to the
//                  major world axis (the axis pick lives in AxisStage;
//                  ActionCenterStage just emits centroid).
//   - Origin     — world (0,0,0).
//   - Screen     — picture-plane center (camera-derived; 7.2b).
//   - Manual     — sticky `manualCenter`, ignores selection (7.2b).
//   - Element / Local / Border — see 7.2d / 7.2e.
//
// 7.2a implements Auto + Select + SelectAuto only — Origin is trivial
// (constant), the others land in subsequent subphases.
// ---------------------------------------------------------------------------
class ActionCenterStage : Stage {
    enum Mode {
        Auto       = 0,
        Select     = 1,
        SelectAuto = 2,
        Element    = 3,    // 7.2d
        Local      = 4,    // 7.2e
        Origin     = 5,    // 7.2b
        Screen     = 6,    // 7.2b
        Border     = 7,    // 7.2e
        Manual     = 8,    // 7.2b
    }
    enum SelectSubMode {
        Center = 0,
        Top    = 1, Bottom = 2,
        Back   = 3, Front  = 4,
        Left   = 5, Right  = 6,
    }

    Mode mode = Mode.Auto;
    Vec3 userPlacedCenter = Vec3(0, 0, 0);  // valid when userPlaced is true
    bool userPlaced = false;                // Auto-mode click-outside marker
    Vec3 manualCenter = Vec3(0, 0, 0);      // valid for Mode.Manual
    int  selectSubMode = SelectSubMode.Center;

private:
    // Stage holds direct refs to the live mesh + edit mode; re-evaluating
    // on each pipeline pass walks the current selection arrays. Cheap —
    // centroid is O(verts) and only runs when a tool actually consumes
    // state.actionCenter (typically Move/Rotate/Scale's per-frame update).
    Mesh*     mesh_;
    EditMode* editMode_;
    // Cached viewport from the last evaluate() — Screen mode needs it to
    // ray-cast the screen-center pixel onto the workplane. listAttrs()
    // doesn't run inside the pipeline, so it reads back the cache.
    Viewport  lastView_;
    // Cached upstream workplane state (origin + normal) for Screen mode.
    Vec3      lastWpCenter_  = Vec3(0, 0, 0);
    Vec3      lastWpNormal_  = Vec3(0, 1, 0);

public:
    this(Mesh* mesh, EditMode* editMode) {
        this.mesh_     = mesh;
        this.editMode_ = editMode;
        publishState();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Acen; }
    override string   id()       const                          { return "actionCenter"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAcen; }

    override void evaluate(ref ToolState state) {
        // Cache live view + upstream workplane so listAttrs (called
        // outside evaluation) and Screen mode can re-derive the same
        // value the pipeline just produced.
        lastView_     = state.view;
        lastWpCenter_ = state.workplane.center;
        lastWpNormal_ = state.workplane.normal;
        state.actionCenter.center = computeCenter();
        state.actionCenter.isAuto = (mode == Mode.Auto && !userPlaced);
        state.actionCenter.type   = cast(int)mode;
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    override string[2][] listAttrs() const {
        return [
            ["mode",          modeLabel()],
            ["cenX",          format("%g", currentCenter().x)],
            ["cenY",          format("%g", currentCenter().y)],
            ["cenZ",          format("%g", currentCenter().z)],
            ["userPlaced",    userPlaced ? "true" : "false"],
            ["selectSubMode", selectSubModeLabel()],
        ];
    }

    /// `tool.set actr.auto` semantics — reset Auto sub-state to "follow
    /// selection". Switching mode to Auto via setAttr also goes through
    /// here so the popup re-click clears any previous click-outside.
    void resetAuto() {
        mode = Mode.Auto;
        userPlaced = false;
        publishState();
    }

    /// Click-outside-gizmo entrypoint for transform tools. Move/Rotate
    /// /Scale call this when the user clicks on the empty viewport
    /// while in Auto mode (sets a sticky center without leaving Auto).
    /// Outside Auto mode this is a no-op — Manual mode has its own
    /// `setManualCenter` which switches mode explicitly.
    void setAutoUserPlaced(Vec3 worldHit) {
        userPlacedCenter = worldHit;
        userPlaced       = true;
        publishState();
    }

    /// Switch into Manual mode and pin the center. Mirror of
    /// `setAutoUserPlaced` for callers that want strict "stay here"
    /// semantics regardless of selection changes.
    void setManualCenter(Vec3 worldPos) {
        mode         = Mode.Manual;
        manualCenter = worldPos;
        publishState();
    }

private:
    // Returns the actual Vec3 the next pipeline.evaluate would publish.
    // Used both by evaluate() and by listAttrs() so the panel's cenX/Y/Z
    // displays the live computed center, not a stale cache.
    Vec3 currentCenter() const {
        return computeCenter();
    }

    Vec3 computeCenter() const {
        final switch (mode) {
            case Mode.Auto:
                if (userPlaced) return userPlacedCenter;
                return centroidWithGeometryFallback();
            case Mode.Select:
                return selectionCentroid(/*sub*/ selectSubMode);
            case Mode.SelectAuto:
                // Same center as Select; AxisStage realigns the basis.
                return selectionCentroid(SelectSubMode.Center);
            case Mode.Origin:
                return Vec3(0, 0, 0);
            case Mode.Manual:
                return manualCenter;
            case Mode.Screen:
                return screenCenter();
            case Mode.Element:
                return elementCenter();
            case Mode.Local:
            case Mode.Border:
                // 7.2e — degrade to selection centroid until
                // implemented (better than 0,0,0; keeps existing tool
                // behaviour intact).
                return centroidWithGeometryFallback();
        }
    }

    // Element mode: average of per-element centroids of the selected
    // elements (NOT the bbox of all their vertices). Differs from
    // Select sub-mode=Center for face/edge selection — here we treat
    // each selected face / edge as one logical "element" and average
    // its own centroid. With a single face selected this gives the
    // face centroid (matches MODO's "click on a polygon → center to
    // its centroid"). Vertex mode collapses to per-vertex average,
    // which equals the regular selection centroid.
    Vec3 elementCenter() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        final switch (*editMode_) {
            case EditMode.Vertices: {
                bool any = mesh_.hasAnySelectedVertices();
                foreach (i, v; mesh_.vertices) {
                    if (!any || (i < mesh_.selectedVertices.length
                                 && mesh_.selectedVertices[i])) {
                        sum += v;
                        count++;
                    }
                }
                break;
            }
            case EditMode.Edges: {
                bool any = mesh_.hasAnySelectedEdges();
                foreach (i, edge; mesh_.edges) {
                    if (any && !(i < mesh_.selectedEdges.length
                                 && mesh_.selectedEdges[i])) continue;
                    Vec3 mid = (mesh_.vertices[edge[0]] + mesh_.vertices[edge[1]]) * 0.5f;
                    sum += mid;
                    count++;
                }
                break;
            }
            case EditMode.Polygons: {
                bool any = mesh_.hasAnySelectedFaces();
                foreach (i, face; mesh_.faces) {
                    if (any && !(i < mesh_.selectedFaces.length
                                 && mesh_.selectedFaces[i])) continue;
                    Vec3 c = Vec3(0, 0, 0);
                    foreach (vi; face) c += mesh_.vertices[vi];
                    if (face.length > 0) c = c / cast(float)face.length;
                    sum += c;
                    count++;
                }
                break;
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    // Screen mode: cast a ray from the camera's eye through the screen
    // center pixel and intersect with the workplane plane. Matches MODO
    // "the action center and axis to be based on the frame of the
    // viewport, or screen space" — picture-plane center projected to the
    // construction plane. If the workplane is parallel to the camera
    // ray the projection degenerates; fall back to the camera focus
    // point so we never publish a NaN center.
    Vec3 screenCenter() const {
        // No view captured yet (stage just constructed) — use the
        // workplane center as a sane default.
        if (lastView_.width == 0 || lastView_.height == 0)
            return lastWpCenter_;
        Vec3 ray = screenRay(cast(int)(lastView_.width / 2),
                             cast(int)(lastView_.height / 2),
                             lastView_);
        Vec3 hit;
        if (rayPlaneIntersect(lastView_.eye, ray,
                              lastWpCenter_, lastWpNormal_, hit))
            return hit;
        // Degenerate (ray ⟂ plane normal). Fall back to camera focus.
        // In practice this hits when the camera looks along the
        // workplane plane edge-on; use the perpendicular projection of
        // eye onto the workplane.
        Vec3 d = lastView_.eye - lastWpCenter_;
        float h = d.x * lastWpNormal_.x + d.y * lastWpNormal_.y + d.z * lastWpNormal_.z;
        return lastView_.eye - lastWpNormal_ * h;
    }

    // Auto mode: selection centroid if any selection, else geometry-bbox
    // centroid (matches MODO "handles at center of selection / geometry").
    Vec3 centroidWithGeometryFallback() const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        // mesh.selectionCentroid* already implements this: when the
        // selection bit-array is empty it sums all vertices.
        final switch (*editMode_) {
            case EditMode.Vertices: return mesh_.selectionCentroidVertices();
            case EditMode.Edges:    return mesh_.selectionCentroidEdges();
            case EditMode.Polygons: return mesh_.selectionCentroidFaces();
        }
    }

    // Strict selection centroid — falls back to all-geometry only if
    // there genuinely is no selection AND no geometry (empty mesh).
    // Sub-mode picks one of the 7 bbox positions in WORLD axis-aligned
    // space, decision per phase7_2_plan.md §1 (resolved).
    Vec3 selectionCentroid(int sub) const {
        if (mesh_ is null) return Vec3(0, 0, 0);
        if (sub == SelectSubMode.Center)
            return centroidWithGeometryFallback();
        // For non-center sub-modes, walk the same vert set as the
        // centroid path and track per-axis min/max.
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool any = false;
        void touch(Vec3 v) {
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            any = true;
        }
        // Determine which verts contribute (matches selectionCentroid* logic).
        bool hasSelV = mesh_.hasAnySelectedVertices();
        bool hasSelE = mesh_.hasAnySelectedEdges();
        bool hasSelF = mesh_.hasAnySelectedFaces();
        bool[] visited = new bool[](mesh_.vertices.length);
        final switch (*editMode_) {
            case EditMode.Vertices:
                foreach (i, v; mesh_.vertices) {
                    if (!hasSelV || (i < mesh_.selectedVertices.length
                                  && mesh_.selectedVertices[i])) touch(v);
                }
                break;
            case EditMode.Edges:
                foreach (i, edge; mesh_.edges) {
                    if (hasSelE && !(i < mesh_.selectedEdges.length
                                  && mesh_.selectedEdges[i])) continue;
                    foreach (vi; edge)
                        if (!visited[vi]) { touch(mesh_.vertices[vi]); visited[vi] = true; }
                }
                break;
            case EditMode.Polygons:
                foreach (i, face; mesh_.faces) {
                    if (hasSelF && !(i < mesh_.selectedFaces.length
                                  && mesh_.selectedFaces[i])) continue;
                    foreach (vi; face)
                        if (!visited[vi]) { touch(mesh_.vertices[vi]); visited[vi] = true; }
                }
                break;
        }
        if (!any) return Vec3(0, 0, 0);
        Vec3 cen = (mn + mx) * 0.5f;
        final switch (cast(SelectSubMode)sub) {
            case SelectSubMode.Center: return cen;
            case SelectSubMode.Top:    return Vec3(cen.x, mx.y, cen.z);
            case SelectSubMode.Bottom: return Vec3(cen.x, mn.y, cen.z);
            case SelectSubMode.Back:   return Vec3(cen.x, cen.y, mn.z);
            case SelectSubMode.Front:  return Vec3(cen.x, cen.y, mx.z);
            case SelectSubMode.Left:   return Vec3(mn.x, cen.y, cen.z);
            case SelectSubMode.Right:  return Vec3(mx.x, cen.y, cen.z);
        }
    }

    bool applySetAttr(string name, string value) {
        switch (name) {
            case "mode": {
                Mode m;
                if      (value == "auto")       m = Mode.Auto;
                else if (value == "select")     m = Mode.Select;
                else if (value == "selectauto") m = Mode.SelectAuto;
                else if (value == "element")    m = Mode.Element;
                else if (value == "local")      m = Mode.Local;
                else if (value == "origin")     m = Mode.Origin;
                else if (value == "screen")     m = Mode.Screen;
                else if (value == "border")     m = Mode.Border;
                else if (value == "manual")     m = Mode.Manual;
                else return false;
                // Switching mode (including Auto→Auto re-pick) clears the
                // Auto-userPlaced sub-state — matches MODO popup re-click.
                mode = m;
                userPlaced = false;
                return true;
            }
            case "cenX": case "cenY": case "cenZ": {
                import std.conv : to;
                float v;
                try v = value.to!float;
                catch (Exception) return false;
                if      (name == "cenX") manualCenter.x = v;
                else if (name == "cenY") manualCenter.y = v;
                else                     manualCenter.z = v;
                // Setting a coord component implies the user wants a
                // sticky pin — promote to Manual unless already there.
                if (mode != Mode.Manual) mode = Mode.Manual;
                return true;
            }
            case "selectSubMode": {
                if      (value == "center") selectSubMode = SelectSubMode.Center;
                else if (value == "top")    selectSubMode = SelectSubMode.Top;
                else if (value == "bottom") selectSubMode = SelectSubMode.Bottom;
                else if (value == "back")   selectSubMode = SelectSubMode.Back;
                else if (value == "front")  selectSubMode = SelectSubMode.Front;
                else if (value == "left")   selectSubMode = SelectSubMode.Left;
                else if (value == "right")  selectSubMode = SelectSubMode.Right;
                else return false;
                return true;
            }
            default: return false;
        }
    }

    string modeLabel() const {
        final switch (mode) {
            case Mode.Auto:       return "auto";
            case Mode.Select:     return "select";
            case Mode.SelectAuto: return "selectauto";
            case Mode.Element:    return "element";
            case Mode.Local:      return "local";
            case Mode.Origin:     return "origin";
            case Mode.Screen:     return "screen";
            case Mode.Border:     return "border";
            case Mode.Manual:     return "manual";
        }
    }

    string selectSubModeLabel() const {
        final switch (cast(SelectSubMode)selectSubMode) {
            case SelectSubMode.Center: return "center";
            case SelectSubMode.Top:    return "top";
            case SelectSubMode.Bottom: return "bottom";
            case SelectSubMode.Back:   return "back";
            case SelectSubMode.Front:  return "front";
            case SelectSubMode.Left:   return "left";
            case SelectSubMode.Right:  return "right";
        }
    }

    void publishState() {
        setStatePath("actionCenter/mode", modeLabel());
        setStatePath("actionCenter/userPlaced", userPlaced ? "true" : "false");
        setStatePath("actionCenter/selectSubMode", selectSubModeLabel());
    }
}
