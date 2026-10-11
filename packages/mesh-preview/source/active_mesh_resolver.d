module active_mesh_resolver;

import mesh : Mesh;

/// Installed once by app.d at init. Returns the mesh currently displayed
/// (the active layer's mesh). Stage 0a: resolves to the one global mesh.
__gshared Mesh* delegate() activeMeshResolver;

