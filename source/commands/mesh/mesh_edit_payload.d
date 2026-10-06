module commands.mesh.mesh_edit_payload;

import mesh : Mesh;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditDelta;

// History owns the successful pair/delta; filled-empty and delta-only are
// payloads, while an untouched carrier is absent. Replay reads only this data
// (task 20261110; radial_align_lifecycle_completion_amendment_2026-10-06.md).
enum MeshRestorePolicy { full, geometryKeepSelection }

struct MeshEditPayload {
private:
    MeshSnapshot before_, after_;
    MeshEditDelta delta_;
    bool deltaOnly_;
    MeshRestorePolicy policy_;
public:
    static MeshEditPayload snapshots(MeshSnapshot before, MeshSnapshot after,
            MeshRestorePolicy policy = MeshRestorePolicy.full) {
        MeshEditPayload p;
        p.before_ = before;
        p.after_ = after;
        p.policy_ = policy;
        return p;
    }
    static MeshEditPayload delta(MeshEditDelta delta) {
        MeshEditPayload p;
        p.delta_ = delta;
        p.deltaOnly_ = true;
        return p;
    }
    bool present() const nothrow @nogc { return deltaOnly_ || after_.filled; }
    bool isDelta() const nothrow @nogc { return deltaOnly_; }
    void forward(ref Mesh m) {
        assert(present(), "cannot replay an absent mesh edit payload");
        if (deltaOnly_) delta_.apply(m);
        else if (policy_ == MeshRestorePolicy.geometryKeepSelection)
            after_.restoreGeometryKeepSelection(m);
        else after_.restore(m);
    }
    void reverse(ref Mesh m) {
        assert(present(), "cannot reverse an absent mesh edit payload");
        if (deltaOnly_) delta_.revert(m);
        else if (policy_ == MeshRestorePolicy.geometryKeepSelection)
            before_.restoreGeometryKeepSelection(m);
        else before_.restore(m);
    }
}
