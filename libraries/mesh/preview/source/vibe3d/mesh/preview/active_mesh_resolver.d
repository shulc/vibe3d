module vibe3d.mesh.preview.active_mesh_resolver;

import vibe3d.mesh.core.mesh : Mesh;

/// Installed once by app.d at init. Returns the mesh currently displayed
/// (the active layer's mesh). Stage 0a: resolves to the one global mesh.
__gshared Mesh* delegate() activeMeshResolver;

