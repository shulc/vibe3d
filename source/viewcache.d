module viewcache;

import math;

// Screen space cache for vertex picking
struct VertexCache {
    float[] sx, sy, ndcZ;
    bool[] valid;
    size_t lastVertexCount = 0;
    float[16] lastView;
    float[16] lastProj;

    void resize(size_t count) {
        if (count != lastVertexCount) {
            sx.length = cast(int)count;
            sy.length = cast(int)count;
            ndcZ.length = cast(int)count;
            valid.length = cast(int)count;
            lastVertexCount = count;
            invalidate();
        }
    }

    void invalidate() {
        foreach (ref v; valid) v = false;
    }

    bool needsUpdate(const ref Viewport vp) {
        if (lastVertexCount == 0) return true;

        for (int i = 0; i < 16; i++) {
            if (lastView[i] != vp.view[i]) return true;
            if (lastProj[i] != vp.proj[i]) return true;
        }
        return false;
    }

    void update(const ref Viewport vp) {
        lastView[] = vp.view[];
        lastProj[] = vp.proj[];
    }
}

// Screen space bounds cache for face picking
struct FaceBoundsCache {
    float[] minX, maxX, minY, maxY;
    bool[] valid;
    float[] centerX, centerY, centerZ;
    bool[] centerValid;
    bool[] projected;  // whether all vertices have been projected
    size_t lastVertexCount = 0;
    float[16] lastView;
    float[16] lastProj;

    void resize(size_t vertexCount, size_t faceCount) {
        if (vertexCount != lastVertexCount) {
            minX.length = cast(int)faceCount;
            maxX.length = cast(int)faceCount;
            minY.length = cast(int)faceCount;
            maxY.length = cast(int)faceCount;
            centerX.length = cast(int)faceCount;
            centerY.length = cast(int)faceCount;
            centerZ.length = cast(int)faceCount;
            valid.length = cast(int)faceCount;
            centerValid.length = cast(int)faceCount;
            projected.length = cast(int)faceCount;
            lastVertexCount = vertexCount;
            invalidate();
        }
    }

    void invalidate() {
        foreach (ref v; valid) v = false;
        foreach (ref v; centerValid) v = false;
        foreach (ref v; projected) v = false;
    }

    bool needsUpdate(const ref Viewport vp) {
        if (lastVertexCount == 0) return true;

        for (int i = 0; i < 16; i++) {
            if (lastView[i] != vp.view[i]) return true;
            if (lastProj[i] != vp.proj[i]) return true;
        }
        return false;
    }

    void update(const ref Viewport vp) {
        lastView[] = vp.view[];
        lastProj[] = vp.proj[];
    }
}

// Screen space cache for edge picking
struct EdgeCache {
    float[] ax_sx, ax_sy, ax_ndcZ;  // vertex A screen coords
    float[] bx_sx, bx_sy, bx_ndcZ;  // vertex B screen coords
    bool[] valid;
    bool[] bothVisible;  // both ends projected successfully
    size_t lastEdgeCount = 0;
    float[16] lastView;
    float[16] lastProj;

    void resize(size_t edgeCount) {
        if (edgeCount != lastEdgeCount) {
            ax_sx.length = cast(int)edgeCount;
            ax_sy.length = cast(int)edgeCount;
            ax_ndcZ.length = cast(int)edgeCount;
            bx_sx.length = cast(int)edgeCount;
            bx_sy.length = cast(int)edgeCount;
            bx_ndcZ.length = cast(int)edgeCount;
            valid.length = cast(int)edgeCount;
            bothVisible.length = cast(int)edgeCount;
            lastEdgeCount = edgeCount;
            invalidate();
        }
    }

    void invalidate() {
        foreach (ref v; valid) v = false;
        foreach (ref v; bothVisible) v = false;
    }

    bool needsUpdate(const ref Viewport vp) {
        if (lastEdgeCount == 0) return true;

        for (int i = 0; i < 16; i++) {
            if (lastView[i] != vp.view[i]) return true;
            if (lastProj[i] != vp.proj[i]) return true;
        }
        return false;
    }

    void update(const ref Viewport vp) {
        lastView[] = vp.view[];
        lastProj[] = vp.proj[];
    }
}
