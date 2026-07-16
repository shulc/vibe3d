module mesh_ops.cut;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshCutOps — plane-cut kernel family, mixed into struct Mesh (source/mesh.d)
// via `mixin MeshCutOps;`. Split out of mesh.d as the pilot of the mesh.d
// decomposition campaign (0407 §B.V2, task 0412) — see that task/doc for the
// architectural decision (mixin template over a package move or UFCS
// free-functions) and the full symbol inventory.
// ---------------------------------------------------------------------------
mixin template MeshCutOps() {
}
