module vibe3d.mesh.contracts.mesh_scope;

// ---------------------------------------------------------------------------
// Change-scope bitfield — declared at beginEditBatch to describe the kinds of
// mutation a batch covers. Advisory in Ph1 (the log is self-describing); kept
// so commands can surface change scope later.
// ---------------------------------------------------------------------------
enum MeshEditScope : uint {
    None     = 0,
    Position = 1 << 0,  // vertex coords moved (no count change)
    Points   = 1 << 1,  // verts added / removed
    Polygons = 1 << 2,  // faces added / removed / reshaped
    Marks    = 1 << 3,  // selection + subpatch bits, order arrays, counters
    Material = 1 << 4,  // faceMaterial[] / surfaces[]
    // The per-element Hide bit (task 0613). A Marks-class change in every
    // other respect — but `Marks` is dominated by SELECTION, which fires on
    // every click and must never rebuild a GPU buffer, so a Hide cannot be
    // signalled through it alone: hidden geometry leaves the vertex / edge /
    // face buffers at UPLOAD time, so a hide is one of the few marks edits
    // that DOES require the buffers to be rebuilt.
    //
    // Its own class, for the same reason `Material` has one: a per-face
    // display attribute whose change needs a re-upload without a topology
    // edit. Publishers OR it alongside `Marks` (never instead of), so
    // consumers that key on Marks — the subpatch-preview gate, the marks
    // caches — are unaffected, and only the ones that opt in through
    // DisplayRefreshMask act on it.
    Visibility = 1 << 5,
    // A per-element MAP value changed (task 1069). Its own class for the same
    // reason `Visibility` has one: a morph write moves no vertex and adds no
    // face, but the viewport draws base+delta (Phase 0, measured), so the GPU
    // buffers must be rebuilt. `Material` cannot stand in — it is the
    // per-face surface class and its consumers are a different set. Publishers
    // use it INSTEAD of Material for morph writes; the pre-existing
    // `setMeshMapValue` keeps publishing Material so no existing consumer
    // changes behaviour.
    Maps = 1 << 6,
    // The DISPLAY-ONLY twin of `Maps` (task 1073 / review B1). What the
    // viewport DRAWS changed because the morph ROUTING TARGET was bound or
    // unbound — but no saveable datum moved: the binding lives in app state
    // (`morph_target`), not in the document, and a `.v3d` written before and
    // after is byte-identical.
    //
    // It is a separate bit and not a flag on `Maps` because the ONE consumer
    // that must tell them apart cannot see anything else: `ChangeBus.flush`
    // is handed a bare `uint` of scope bits, and `docRevision()` — the
    // unsaved-changes counter behind the window-title asterisk and the
    // quit-time save prompt — is a sum over those counters. Publishing `Maps`
    // for a target change would mark a freshly-opened, unedited document
    // dirty the moment the user picked a morph to look at; publishing nothing
    // would leave the last-uploaded surface on screen (measured — see
    // `MorphSelect.publishTargetChange`). This bit is the third answer: it
    // rides `DisplayRefreshMask` exactly like `Maps`, and is counted by
    // NOTHING in `docRevision`.
    MapsDisplay = 1 << 7,
    Geometry = Points | Polygons,
}

/// Change classes whose values are consumed while rebuilding display buffers
/// (task 5110). Geometry classes alter buffer shape or coordinates; Material,
/// Visibility, Maps and MapsDisplay alter upload-time attributes or routing.
/// Marks stays excluded because selection/hover highlight reads marks at draw
/// time. The fixed roster and its upload-visible effects are pinned by
/// `tests/unit/display_refresh_mask_semantics_test.d` and the display suites.
enum uint DisplayRefreshMask =
      MeshEditScope.Position
    | MeshEditScope.Points
    | MeshEditScope.Polygons
    | MeshEditScope.Material
    | MeshEditScope.Visibility
    | MeshEditScope.Maps
    | MeshEditScope.MapsDisplay;

