module commands.mesh.vertex_position_result;

import math : Vec3;
import operator : VectorStack;

/// Sparse, already-computed vertex positions. Building this value must not
/// mutate the scene mesh; callers choose whether to preview, record, or replay
/// it.
struct VertexPositionResult {
    uint[] indices;
    Vec3[] before;
    Vec3[] after;

    bool empty() const nothrow @nogc { return indices.length == 0; }

    void clear() nothrow @nogc {
        indices = null;
        before = null;
        after = null;
    }
}

/// Capability used by deterministic CommandWrapperTool deforms. Quantize,
/// Smooth and Jitter implement it; EdgeSlide remains on the legacy path.
///
/// The wrapper's packet-reuse arm reconstructs only Subject and an optional
/// owned Falloff packet. An implementation may consume no other pipeline slot
/// unless that slot is explicitly added to the wrapper's cached-packet contract.
interface VertexPositionResultBuilder {
    bool buildVertexPositionResult(const(Vec3)[] source,
                                   ref VectorStack vts,
                                   out VertexPositionResult result);
}
