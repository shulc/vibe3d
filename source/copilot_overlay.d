module copilot_overlay;

// ===========================================================================
// copilot_overlay — a lightweight, decoupled ghost-overlay drawer for the
// AI Modeling Copilot's ACTIVE finding (task 0402 Phase 3,
// doc/ai_copilot_plan.md). Harvested from the abandoned A1 branch's
// ghost-draw pattern (`support_loops_tool.d:224-248`, ~20 lines: a
// `drawWorldSegment(a, b, vp, color, width, program)` loop with depth-test
// off) — NOT a merge of that branch and NOT a `mesh.d` change: this is a
// pure, standalone overlay PASS reusing the same `drawWorldSegment`
// primitive (`handler.d:370`) every other ghost/preview overlay in the
// codebase already uses.
//
// Passive by construction (the copilot never mutates geometry — see
// `ai.analysis`'s and `copilot_panel`'s doc comments): this module has NO
// mutation surface at all. `drawCopilotFindingOverlay` takes a
// `const ref Mesh` and a `const ref Finding` and only issues GL draw calls;
// it never touches selection, history, or the mesh.
//
// Face-set findings (Phase 4: Cleanup/Topology/Retopo) are drawn as their
// boundary segments (via `Mesh.faceEdges`) rather than a translucent fill —
// the plan's preferred "decoupled overlay pass" option (a); a real
// `checkerShader` translucent-tint second pass (option (b)) is deferred
// until a face-set finding category actually exists (Phase 1 only emits
// SubdivReadiness, which is edges-only), so there is nothing to fill yet.
// This keeps Phase 3 to a single, self-contained draw primitive with no new
// shader wiring.
// ===========================================================================

import bindbc.opengl : GLuint, glEnable, glDisable, GL_DEPTH_TEST;

import mesh    : Mesh;
import math    : Vec3;
import math    : Viewport;
import handler : drawWorldSegment;
import ai.analysis : Finding;

/// "Recommendation" ghost color — deliberately distinct from the Loop-Slice
/// / support-loop ghost family (`GHOST_COLOR`/`HOVER_COLOR`, dim/bright
/// teal-cyan) and from selection-yellow, so a Copilot finding ghost is never
/// confused with either when both happen to be visible at once. A clear
/// amber reads well against the default grey viewport background; the
/// owner eyeballs the final look live (headless cannot verify appearance).
enum Vec3  COPILOT_GHOST_COLOR = Vec3(1.0f, 0.65f, 0.05f);
enum float COPILOT_GHOST_WIDTH = 2.5f;

/// Draw a ghost highlight of `finding`'s element set — its `edges` directly,
/// plus each `faces` entry's boundary (as segments, see module doc comment).
/// `verts` carries no drawable primitive of its own in this phase (no
/// SubdivReadiness/Phase-1 finding populates it) and is intentionally
/// skipped rather than guessed at.
///
/// Depth-test is disabled for the duration (mirrors the harvested pattern
/// exactly — the ghost must read through the mesh) and restored before
/// returning; `drawWorldSegment` itself only swaps the program + VAO, so no
/// other GL state is touched.
///
/// Defensive against staleness on its own: a finding's element indices can
/// go stale across a mesh edit between "Analyze" runs (same staleness
/// `commands.copilot.select_finding` already guards against for act-on) —
/// any index at or past the live mesh's current bound is silently skipped
/// rather than indexing out of range.
void drawCopilotFindingOverlay(const ref Mesh mesh, const ref Finding finding,
                                const ref Viewport vp, GLuint program) {
    if (finding.edges.length == 0 && finding.faces.length == 0) return;

    glDisable(GL_DEPTH_TEST);

    foreach (ei; finding.edges) {
        if (ei >= mesh.edges.length) continue;
        const edge = mesh.edges[ei];
        if (edge[0] >= mesh.vertices.length || edge[1] >= mesh.vertices.length)
            continue;
        drawWorldSegment(mesh.vertices[edge[0]], mesh.vertices[edge[1]],
                          vp, COPILOT_GHOST_COLOR, COPILOT_GHOST_WIDTH, program);
    }

    foreach (fi; finding.faces) {
        if (fi >= mesh.faces.length) continue;
        foreach (fe; mesh.faceEdges(fi)) {
            if (fe.a >= mesh.vertices.length || fe.b >= mesh.vertices.length)
                continue;
            drawWorldSegment(mesh.vertices[fe.a], mesh.vertices[fe.b],
                              vp, COPILOT_GHOST_COLOR, COPILOT_GHOST_WIDTH, program);
        }
    }

    glEnable(GL_DEPTH_TEST);
}
