// mesh_face_plane_append_test — the BEHAVIOURAL gate for
// `mesh_planes.appendFacePlanes`, the APPEND half of the per-face plane
// funnel (task 4059; `rewriteFaces`'s renumbering half is task 1902 and is
// pinned by tests/unit/mesh_planes_test.d).
//
// THE ONE RULE THAT MAKES THIS A GATE AND NOT THEATRE — the same rule
// mesh_planes_test.d's header states, for the same reason: THE PLANE NAMES
// BELOW ARE SPELLED OUT BY HAND. No line in this file reads `kFacePlanes`.
// An assertion that iterated `kFacePlanes` would shrink together with the
// table it is meant to guard, so deleting `"faceSetMask"` from that table
// would shrink `appendFacePlanes`'s carry AND this test's coverage in one
// edit and the suite would go green straight through the mutation
// (`CLAUDE.md`, "a check that cannot come out differently").
//
// ORDER IS LOAD-BEARING. `faceSetMask` is asserted LAST in each block, and
// it is the plane task 4059's `## Мутация` removes: druntime stops a module
// at its first failed assert, so the four asserts ABOVE it having run is an
// observation about control flow — they passed — bought by the same single
// run that reddens the fifth.
module tests.unit.mesh_face_plane_append_test;

import mesh        : Mesh, makeCube;
import mesh_planes : appendFacePlanes, PlaneFit;
import std.format  : format;

// ---------------------------------------------------------------------------
// Block A — `Mesh.resetSelection`, the wholesale re-sync door.
// ---------------------------------------------------------------------------

unittest // resetSelection brings every per-face plane to faces.length
{
    Mesh m = makeCube();

    // NON-VACUITY, and it is the whole reason this block is first: a fresh
    // cube's per-face planes are EMPTY while `faces` is not, so "every plane
    // has length == faces.length" is FALSE here. Without this the five
    // assertions below would also hold over a mesh whose planes were already
    // the right length, i.e. over a `resetSelection` that did nothing.
    assert(m.faces.length == 6,
           format("fixture: makeCube must give 6 faces, got %d", m.faces.length));
    assert(m.faceSetMask.length < m.faces.length,
           format("fixture: a fresh cube's faceSetMask must start SHORTER than "
                ~ "faces (%d) or this block asserts nothing — got %d",
                  m.faces.length, m.faceSetMask.length));

    m.resetSelection();

    assert(m.faceMarks.length == m.faces.length,
           format("resetSelection left faceMarks at %d against %d faces",
                  m.faceMarks.length, m.faces.length));
    assert(m.faceMaterial.length == m.faces.length,
           format("resetSelection left faceMaterial at %d against %d faces",
                  m.faceMaterial.length, m.faces.length));
    assert(m.facePart.length == m.faces.length,
           format("resetSelection left facePart at %d against %d faces",
                  m.facePart.length, m.faces.length));
    assert(m.faceSelectionOrder.length == m.faces.length,
           format("resetSelection left faceSelectionOrder at %d against %d faces",
                  m.faceSelectionOrder.length, m.faces.length));
    // THE MUTATION TARGET — see this module's header for why it is last.
    assert(m.faceSetMask.length == m.faces.length,
           format("resetSelection left faceSetMask at %d against %d faces — "
                ~ "is `faceSetMask` still in mesh_planes.kFacePlanes?",
                  m.faceSetMask.length, m.faces.length));
}

// ---------------------------------------------------------------------------
// Block B — a real APPENDING kernel. `resetSelection` above is the tidy-up
// door; this is the shape the funnel exists for: a kernel that grew `faces`
// at the tail and must take every plane with it.
// ---------------------------------------------------------------------------

unittest // duplicateSelectedFaces grows every per-face plane with the append
{
    Mesh m = makeCube();
    m.resetSelection();
    m.selectFace(0);

    const size_t before = m.faces.length;
    const size_t made   = m.duplicateSelectedFaces();

    // POPULATION FLOOR: "the planes match `faces`" is satisfied by a kernel
    // that appended NOTHING, which is the vacuous half `CLAUDE.md` names.
    assert(made == 1,
           format("fixture: one selected face must duplicate to one, got %d", made));
    assert(m.faces.length == before + 1,
           format("fixture: faces must have grown %d -> %d, got %d",
                  before, before + 1, m.faces.length));

    assert(m.faceMarks.length == m.faces.length,
           format("duplicateSelectedFaces left faceMarks at %d against %d faces",
                  m.faceMarks.length, m.faces.length));
    assert(m.faceMaterial.length == m.faces.length,
           format("duplicateSelectedFaces left faceMaterial at %d against %d faces",
                  m.faceMaterial.length, m.faces.length));
    assert(m.facePart.length == m.faces.length,
           format("duplicateSelectedFaces left facePart at %d against %d faces",
                  m.facePart.length, m.faces.length));
    assert(m.faceSelectionOrder.length == m.faces.length,
           format("duplicateSelectedFaces left faceSelectionOrder at %d against %d faces",
                  m.faceSelectionOrder.length, m.faces.length));
    // THE MUTATION TARGET.
    assert(m.faceSetMask.length == m.faces.length,
           format("duplicateSelectedFaces left faceSetMask at %d against %d "
                ~ "faces — is `faceSetMask` still in mesh_planes.kFacePlanes?",
                  m.faceSetMask.length, m.faces.length));
}

// ---------------------------------------------------------------------------
// Block C — the POLICY, which is the one thing `appendFacePlanes` could get
// wrong while every length assertion above stayed green. `Mesh.syncSelection`
// is documented as "grow selection arrays to match geometry WITHOUT
// clearing"; collapsing its guarded grows into the funnel with the kernels'
// `Exact` fit would TRUNCATE a plane that is longer than `faces`, silently,
// and no `length == faces.length` check can see the difference — after an
// `Exact` fit that equality is exactly what holds.
// ---------------------------------------------------------------------------

unittest // syncSelection is GrowOnly: a plane longer than faces survives untruncated
{
    Mesh m = makeCube();
    m.resetSelection();

    const size_t over = m.faces.length + 3;
    m.faceSetMask.length = over;
    m.faceSetMask[over - 1] = 0xABCD_1234UL;
    m.facePart.length = over;
    m.facePart[over - 1] = 77u;

    m.syncSelection();

    assert(m.facePart.length == over,
           format("syncSelection truncated facePart %d -> %d: the funnel was "
                ~ "called with PlaneFit.Exact where GrowOnly is the contract",
                  over, m.facePart.length));
    assert(m.facePart[over - 1] == 77u, "syncSelection lost a facePart value past faces.length");
    assert(m.faceSetMask.length == over,
           format("syncSelection truncated faceSetMask %d -> %d", over, m.faceSetMask.length));
    assert(m.faceSetMask[over - 1] == 0xABCD_1234UL,
           "syncSelection lost a faceSetMask value past faces.length");

    // …and it still GROWS. Shrink one plane below `faces` and re-sync.
    m.faceMaterial.length = 1;
    m.syncSelection();
    assert(m.faceMaterial.length == m.faces.length,
           format("syncSelection failed to grow faceMaterial to %d, got %d",
                  m.faces.length, m.faceMaterial.length));
}

// ---------------------------------------------------------------------------
// Block D — the funnel called directly, both fits, so the two arms are pinned
// independently of any kernel that happens to call them today.
// ---------------------------------------------------------------------------

unittest // appendFacePlanes: Exact truncates AND grows; GrowOnly only grows
{
    Mesh m = makeCube();
    m.resetSelection();

    m.faceMaterial.length = m.faces.length + 2;
    m.faceSelectionOrder.length = 2;

    appendFacePlanes(m, PlaneFit.GrowOnly);
    assert(m.faceMaterial.length == m.faces.length + 2, "GrowOnly must not truncate");
    assert(m.faceSelectionOrder.length == m.faces.length, "GrowOnly must grow a short plane");

    appendFacePlanes(m, PlaneFit.Exact);
    assert(m.faceMaterial.length == m.faces.length, "Exact must truncate a long plane");
    assert(m.faceSelectionOrder.length == m.faces.length, "Exact must leave an exact plane alone");
}

// ---------------------------------------------------------------------------
// Block E — the OTHER direction of the policy split, and it is the dangerous
// one. Block C catches "a GrowOnly site was given Exact" (a truncation that
// loses data). Nothing caught the reverse until this block: an `Exact` site
// handed `GrowOnly` leaves a plane LONGER than `faces` after a shrink, and
// those stale entries become readable again the moment the face array
// regrows onto them. Review of task 4059 flipped two call sites from `Exact`
// to `GrowOnly` and BOTH runs stayed green at 487 modules — the split was
// load-bearing in one direction only.
//
// `Mesh.resetSelection` is the discriminating site. It is the ONE `Exact`
// caller whose faces can SHRINK — the six topology kernels
// (`arrayFaces`, `arrayFacesGrid`, `radialArrayFaces`, `mirrorFacesPlane`,
// `duplicateSelectedFaces`, `appendGeometry`) only ever append, so on those
// the two fits are indistinguishable by construction and no cell can pin
// them. What guards THEM is that `appendFacePlanes` now takes `fit` with NO
// DEFAULT: a seventh kernel, or a site that forgets, is a compile error
// rather than a silent inheritance of whatever the default happened to be.
// ---------------------------------------------------------------------------

unittest // resetSelection is Exact: a shrink TRUNCATES, and the stale tail cannot come back
{
    Mesh m = makeCube();
    m.resetSelection();

    // NON-VACUITY. The cell is worthless unless the tail entries it is about
    // to look for actually exist and actually hold the marker values: an
    // assertion over a plane that was already short is satisfied by every
    // candidate policy.
    assert(m.faces.length == 6,
           format("fixture: makeCube must give 6 faces, got %d", m.faces.length));
    assert(m.facePart.length == 6 && m.faceMaterial.length == 6
           && m.faceSetMask.length == 6,
           format("fixture: resetSelection must leave the planes at 6, got "
                ~ "facePart=%d faceMaterial=%d faceSetMask=%d",
                  m.facePart.length, m.faceMaterial.length, m.faceSetMask.length));
    m.facePart[5]     = 77u;
    m.faceMaterial[5] = 42u;
    m.faceSetMask[5]  = 0xABCD_1234UL;
    assert(m.facePart[5] == 77u && m.faceMaterial[5] == 42u
           && m.faceSetMask[5] == 0xABCD_1234UL,
           "fixture: the marker values did not stick on the plane tails");

    // The shrink a face delete leaves behind: `faces` is short, every plane
    // still carries its old tail.
    m.faces.length = 3;
    m.resetSelection();

    // THE MUTATION TARGET. Flipping `Mesh.resetSelection`'s
    // `appendFacePlanes(this, PlaneFit.Exact)` to `PlaneFit.GrowOnly` leaves
    // each of these at 6.
    assert(m.facePart.length == 3,
           format("resetSelection left facePart at %d against %d faces — was "
                ~ "`PlaneFit.Exact` flipped to `PlaneFit.GrowOnly` at "
                ~ "Mesh.resetSelection? A grow-only fit does not truncate.",
                  m.facePart.length, m.faces.length));
    assert(m.faceMaterial.length == 3,
           format("resetSelection left faceMaterial at %d against %d faces — "
                ~ "the fit at Mesh.resetSelection is not Exact",
                  m.faceMaterial.length, m.faces.length));
    assert(m.faceSetMask.length == 3,
           format("resetSelection left faceSetMask at %d against %d faces — "
                ~ "the fit at Mesh.resetSelection is not Exact",
                  m.faceSetMask.length, m.faces.length));

    // …and the harm the truncation prevents, spelled out rather than implied:
    // regrow `faces` over the indices the stale tail occupied and the values
    // read back as `T.init`, not as the markers written before the shrink.
    m.faces.length = 6;
    m.resetSelection();
    assert(m.facePart[5] == 0u && m.faceMaterial[5] == 0u && m.faceSetMask[5] == 0UL,
           format("a stale plane tail survived the shrink and became readable "
                ~ "again on regrow: facePart[5]=%d faceMaterial[5]=%d "
                ~ "faceSetMask[5]=%d", m.facePart[5], m.faceMaterial[5],
                  m.faceSetMask[5]));
}
