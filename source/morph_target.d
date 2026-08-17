module morph_target;

// The app-level MORPH ROUTING TARGET (task 1069).
//
// "Which morph map does an edit go into?" — exactly one, or none. The same
// shape `FalloffStage`'s active weight map has (`toolpipe/packets.d`'s
// `string mapName`, resolved against the live mesh at use time), and the same
// shape the reference SDK's map-selection packet exposes: a NAME and a TYPE,
// never a pointer.
//
// **By name, resolved per use, deliberately.** `Mesh.removeMeshMap` splices
// the registry array, so every outstanding `MeshMap*` is invalidated by any
// remove; a cached pointer here would dangle. Resolving by name means a
// removed or renamed map degrades to "no target", which is a state the whole
// routing seam already handles, rather than to a crash.
//
// Main-thread only, like `io.doc_state` — the HTTP command routes are
// dispatched as `Answered.mainThread`.
//
// Cleared on a primary-layer change (`app.d`'s `onActiveLayerChanged` hook),
// by File → New / `scene.reset` (`commands/scene/reset.d`) and by File → Open
// (`commands/file/load.d`): the same NAME may denote a different map on
// another layer — a duplicated layer carries the same map names by
// construction — and silently retargeting an edit at a same-named map on a
// layer the user just switched to is worse than dropping the target. OUR
// choice, not a measurement — registry row 50.
//
// Those three call sites are the WHOLE list, and `clearMorphTarget` is
// otherwise called only by `MorphSelect` and `forgetMorphTargetIfNamed`. The
// gate is `grep -rn 'clearMorphTarget' source/`; if this comment ever names a
// site the grep does not, the comment is the thing that is wrong. (It was:
// task 1069 shipped this paragraph with none of the three wired, so a bound
// target survived a layer switch, a File → New AND `/api/reset` — the last of
// which is a cross-test bleed vector in the shared `--test` process. Task
// 1073, review B2.)

import mesh : MapKind, Mesh, isMorphKind;

private string  g_targetName;
private MapKind g_targetKind = MapKind.unclassified;

/// The bound target's name, or "" when nothing is bound.
string morphTargetName() { return g_targetName; }

/// The bound target's kind, or `unclassified` when nothing is bound.
MapKind morphTargetKind() { return g_targetKind; }

/// Is a morph target bound at all? NOTE: this says nothing about whether the
/// named map still exists on the current mesh — call `resolveMorphTarget`
/// for that. The two are separate on purpose: the binding is app state, the
/// resolution is per-mesh.
bool hasMorphTarget() { return g_targetName.length > 0 && isMorphKind(g_targetKind); }

/// Bind (or, with an empty name, clear) the routing target.
void setMorphTarget(string name, MapKind kind) {
    if (name.length == 0 || !isMorphKind(kind)) {
        g_targetName = null;
        g_targetKind = MapKind.unclassified;
        return;
    }
    g_targetName = name;
    g_targetKind = kind;
}

/// Drop the binding. Called on a primary-layer change, by File → New /
/// `scene.reset` (which is what `/api/reset` fires) and by File → Open.
void clearMorphTarget() {
    g_targetName = null;
    g_targetKind = MapKind.unclassified;
}

/// Is `m` the mesh the binding applies to — the PRIMARY (edit-target) layer's
/// mesh? (task 1073, review SF2.)
///
/// The binding is ONE app-global name, and the resolution below is by name
/// against whatever mesh it is handed. Background layers are handed to the
/// same readers as the primary — `ui/viewport_render.d` uploads every visible
/// background layer through `GpuMesh.upload`, and `snap.d` walks them for
/// snap candidates — so without this test a background layer carrying a map
/// of the same name (which a DUPLICATED layer does by construction) is drawn,
/// snapped to and picked MORPHED by the primary's binding. The user bound a
/// target on one layer and three others silently deformed.
///
/// The authority is `display_sync.activeMeshResolver`, which `app.d` installs
/// once as `() => document.activeMesh()` — i.e. the primary's mesh. Reused
/// rather than duplicated so there is one answer to "which mesh is the edit
/// target" and one place to wire it.
///
/// NULL RESOLVER MEANS YES. Module unittests and every headless construction
/// build a bare `Mesh` with no `Document` and no app behind it; there is
/// exactly one mesh there and it is the edit target by definition. This is
/// what keeps the existing morph unittests byte-identical.
private bool isMorphPreviewMesh(const Mesh* m) {
    if (m is null) return false;
    import display_sync : activeMeshResolver;
    if (activeMeshResolver is null) return true;
    const(Mesh)* primary = activeMeshResolver();
    return primary is m;
}

/// Resolve the binding against a live mesh: returns true, plus the name and
/// the map's OWN stored kind, only when `m` is the primary mesh AND a map of
/// that name exists on it AND is a morph kind. The kind returned is the
/// mesh's, not the binding's — if they ever disagree (a `.v3d` load replacing
/// a map with one of the other kind under the same name) the mesh is the
/// authority, because it is what the write will land in.
bool resolveMorphTarget(const Mesh* m, out string name, out MapKind kind) {
    name = null;
    kind = MapKind.unclassified;
    if (m is null || !hasMorphTarget()) return false;
    if (!isMorphPreviewMesh(m)) return false;
    const k = m.mapKind(g_targetName);
    if (!isMorphKind(k)) return false;
    name = g_targetName;
    kind = k;
    return true;
}

/// Drop the binding if it names `removedOrRenamed`. Called by the remove and
/// rename commands so a stale name never survives its map.
void forgetMorphTargetIfNamed(string removedOrRenamed) {
    if (g_targetName == removedOrRenamed) clearMorphTarget();
}

// ---------------------------------------------------------------------------
// The PREVIEW indirection (task 1069, plan Stage 7).
//
// Phase 0 measured the reference's viewport with a morph selected: it draws
// BASE + DELTA, as ONE deformed mesh (not a ghost overlay), and polygon
// picking follows the drawn surface. Four boots, a 70x margin on the decisive
// per-vertex pixel shift, bit-identical across three independent boots.
//
// So the morph is live geometry as far as the DISPLAY and the AIM are
// concerned — and is NOT geometry as far as the KERNELS are concerned (law L8:
// topology ops hit the base). That split is the whole design: exactly the
// consumers listed below read through here; bevel, subdivide, the workplane,
// UV and every mesh op keep reading `vertices` directly.
//
// `displayVertices` returns `null` whenever no target is bound, and every
// consumer falls back to `mesh.vertices` on null — which is what makes every
// existing test byte-identical.
// ---------------------------------------------------------------------------

import math : Vec3;
import mesh_morph : morphApply;

/// Is a morph preview live on `m`? False whenever nothing is bound, the bound
/// name does not resolve on THIS mesh, or the map has no entries at all.
bool morphPreviewActive(const Mesh* m) {
    string nm; MapKind kind;
    if (!resolveMorphTarget(m, nm, kind)) return false;
    auto map = m.meshMap(nm);
    return map !is null && map.data.length == m.vertices.length * 3;
}

/// The vertex's DRAWN position: base with the bound map's value applied at
/// full strength. Identical to `m.vertices[vi]` whenever nothing is bound.
Vec3 displayPosition(const Mesh* m, size_t vi) {
    if (m is null || vi >= m.vertices.length) return Vec3(0, 0, 0);
    string nm; MapKind kind;
    if (!resolveMorphTarget(m, nm, kind)) return m.vertices[vi];
    return morphApply(m.vertices[vi], m.morphEvaluate(nm, vi), kind, 1.0f);
}

/// The whole drawn vertex array, or `null` when no preview is live.
///
/// Allocates. That is deliberate and affordable: every consumer of this is
/// itself version-gated (the GPU upload runs on a mutation-version change, the
/// BVH on a topology change), not per-frame — and returning a fresh array
/// rather than caching one keeps this free of the stale-cache class of bug
/// that a second version key would introduce. If a profile ever says
/// otherwise, cache it on `Mesh` with a `MeshCacheKey`, not here.
Vec3[] displayVertices(const Mesh* m) {
    if (m is null) return null;
    string nm; MapKind kind;
    if (!resolveMorphTarget(m, nm, kind)) return null;
    auto map = m.meshMap(nm);
    if (map is null || map.data.length != m.vertices.length * 3) return null;
    Vec3[] out_;
    out_.length = m.vertices.length;
    foreach (i; 0 .. m.vertices.length)
        out_[i] = morphApply(m.vertices[i], m.morphEvaluate(nm, i), kind, 1.0f);
    return out_;
}
