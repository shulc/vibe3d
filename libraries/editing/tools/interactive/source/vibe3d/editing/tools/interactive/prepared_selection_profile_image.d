module vibe3d.editing.tools.interactive.prepared_selection_profile_image;

import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import vibe3d.editing.tools.state.tools.common.session_mesh_key : SessionMeshKey;

struct RadialSweepProfileImage {
    MeshSnapshot mesh;
    uint[] profile;
    SessionMeshKey sessionKey;
    bool closed;
    uint face = uint.max;
    bool valid;

    bool filled() const nothrow @nogc { return mesh.filled; }
    void clear() nothrow @nogc {
        mesh = MeshSnapshot.init; profile = null; sessionKey = SessionMeshKey.init;
        closed = false; face = uint.max; valid = false;
    }
}
