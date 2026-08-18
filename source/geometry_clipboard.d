module geometry_clipboard;

import math : Vec3;
import mesh : Mesh;

/// In-memory geometry clipboard for mesh.copy / mesh.cut / mesh.paste.
/// Faces are stored as 0-based indices into `verts` (the clip-local vertex
/// array), so the clip is self-contained and independent of any specific Mesh.
///
/// A clip may hold verts and NO faces — that is a VERTEX-mode copy (task 1200,
/// ledger row 19), and `mesh.paste` turns it back into that many free-standing
/// vertices. `empty` therefore asks about both arrays, not just `faces`.
///
/// Thread-safety: this module is main-thread-only. HTTP /api/command is
/// bridged through the main loop so commands run on the main thread only;
/// no locking is needed. Do NOT read or write `geometryClipboard` from the
/// HTTP background thread.
struct GeometryClip {
    Vec3[]   verts;
    uint[][] faces;
    bool[]   subpatch;  /// per-face subpatch flag (parallel to faces[])
    uint[]   material;  /// per-face material index (parallel to faces[])
    uint[]   part;      /// per-face part id (parallel to faces[])
    ulong[]  setMask;   /// per-face selection-set membership bits (task 1060,
                        /// Stage 5c; parallel to faces[], carried the same way
                        /// `part` is)

    bool empty() const { return faces.length == 0 && verts.length == 0; }

    /// True for the vertex-mode clip: points with no topology on them.
    bool looseOnly() const { return faces.length == 0 && verts.length > 0; }

    void clear() {
        verts    = null;
        faces    = null;
        subpatch = null;
        material = null;
        part     = null;
        setMask  = null;
    }

    /// Build a clip from the currently selected faces of `m`.
    /// Verts shared by multiple selected faces are deduplicated: only one
    /// entry in `verts` is created per unique original vertex index.
    /// Uses `m.isFaceSubpatch(fi)` — the non-allocating scalar accessor —
    /// NOT `m.isSubpatch[fi]` (which allocates a full bool[] on each call,
    /// making a per-face loop O(F²)).
    /// Returns an empty clip when nothing is selected.
    static GeometryClip fromSelectedFaces(const ref Mesh m) {
        if (!m.hasAnySelectedFaces()) return GeometryClip.init;

        GeometryClip clip;

        // Map original vertex index → clip-local 0-based index.
        // Built lazily as we iterate selected faces; shared verts across
        // two selected faces are cloned once.
        uint[uint] vertMap;
        foreach (fi, ref f; m.faces) {
            if (!m.isFaceSelected(fi)) continue;
            foreach (vid; f) {
                if (vid !in vertMap) {
                    vertMap[vid] = cast(uint)clip.verts.length;
                    clip.verts  ~= m.vertices[vid];
                }
            }
        }
        if (clip.verts.length == 0) return GeometryClip.init;

        // Build 0-based face index lists and per-face metadata.
        foreach (fi, ref f; m.faces) {
            if (!m.isFaceSelected(fi)) continue;
            uint[] remapped;
            remapped.length = f.length;
            foreach (k, vid; f) remapped[k] = vertMap[vid];
            clip.faces    ~= remapped;
            // Non-allocating isFaceSubpatch avoids the O(F²) isSubpatch[] trap.
            clip.subpatch ~= m.isFaceSubpatch(fi);
            clip.material ~= (fi < m.faceMaterial.length ? m.faceMaterial[fi] : 0u);
            clip.part     ~= (fi < m.facePart.length     ? m.facePart[fi]     : 0u);
            clip.setMask  ~= (fi < m.faceSetMask.length  ? m.faceSetMask[fi]  : 0UL);
        }

        return clip;
    }

    /// Build a clip from the currently selected VERTICES of `m` — positions
    /// only, no faces (task 1200, ledger row 19). Copying in vertex mode used to
    /// refuse outright; the reference takes the points, and a paste puts that
    /// many free vertices back.
    ///
    /// Order is ascending vertex index, not click order. The reference cell that
    /// froze this behaviour pastes every point on top of its original, so it
    /// cannot see any order at all; ascending index is the deterministic choice
    /// and nothing measured argues for another.
    static GeometryClip fromSelectedVertices(const ref Mesh m) {
        if (!m.hasAnySelectedVertices()) return GeometryClip.init;

        GeometryClip clip;
        const sv = m.selectedVertices;         // materialised bool[] snapshot
        foreach (vi; 0 .. sv.length)
            if (sv[vi]) clip.verts ~= m.vertices[vi];
        // `faces` (and every per-face array beside it) stays null: there is no
        // face to carry a material, a part, a subpatch flag or a set mask.
        return clip;
    }
}

/// Module-level clipboard. Main-thread-only (see thread-safety note above).
__gshared GeometryClip geometryClipboard;
