module vibe3d.editing.tools.interactive.tools.create.create_common_source_cells;

import vibe3d.editing.tools.interactive.tools.create.create_common;
import vibe3d.editing.selection.query.toolpipe.guide : SnapQueryPolicy, SnapPurpose, SnapGuideScope;
import vibe3d.util.math.math : Vec3, dot, matMul4, matrixMirrorsWinding, normalize, rayPlaneIntersect;
import vibe3d.util.spatial.spatial : Viewport, isOrtho, projectToWindowFull, screenPointToRay;
import std.math : abs;
public import vibe3d.util.spatial.workplane_basis : BuildPlane, mostFacingAxis, pickMostFacingPlane;
import vibe3d.editing.selection.query.viewgrid : vectorSnap, viewVectorQuantum, viewWorkPlaneAnchor;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline       : g_pipeCtx;
import vibe3d.editing.pipeline.contracts.toolpipe.packets        : SubjectPacket, WorkplanePacket;
import vibe3d.editing.pipeline.runtime.toolpipe.stage          : TaskCode;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.workplane : WorkplaneStage;
import vibe3d.editing.pipeline.contracts.operator                : VectorStack;
import vibe3d.editing.tools.interactive.drag                    : HandleDrag, DragFrame, DragKind, planeDragDelta;
import vibe3d.editing.tools.interactive.handler                 : MoveHandler;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.contracts.seltype : SelType;
import vibe3d.editing.pipeline.runtime.toolpipe.subject : evaluateSubject, viewOnlySubject, SubjectSource;
import vibe3d.editing.selection.query.snap : SnapResult, snapCursor, snapPacketOf;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.snap : liveSnapGuides;
import vibe3d.editing.tools.interactive.snap_render : publishLastSnap, clearLastSnap;
import vibe3d.documents.model.document : primaryModelSpace;

// ---------------------------------------------------------------------------
// workplaneCursorPlaneHit — the ortho arm, and the equality that makes it the
// ported law rather than a second opinion (task 0661).
//
// Rig: the Front axis preset. Camera at (0,0,dist) looking down -Z, ortho,
// construction plane = the camera-facing principal plane (normal +Z) through
// the focus. `frame` is identity-basis-with-normal-Z so local == world here,
// which keeps the assertions readable in world coordinates.
// ---------------------------------------------------------------------------
private Viewport frontOrthoViewport(float dist, Vec3 focus) {
    import vibe3d.util.math.math : orthographicMatrix;
    import std.math : tan, PI;
    Viewport vp;
    vp.width = 640; vp.height = 480;
    vp.x = 0; vp.y = 0;
    vp.focus = focus;
    vp.eye = Vec3(focus.x, focus.y, focus.z + dist);
    // Front basis: right=+X, up=+Y, back=+Z. View matrix rows are the basis
    // vectors (column-major m[row + col*4]).
    vp.view = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        -focus.x, -focus.y, -(focus.z + dist), 1,
    ];
    float halfH = dist * tan(cast(float)(PI / 8.0));
    vp.proj = orthographicMatrix(halfH, cast(float)vp.width / vp.height, 0.1f, 100.0f);
    return vp;
}

unittest { // ortho: the in-plane answer is the click, NOT the click times distance
    import std.math : abs, tan, PI;

    immutable float dist = 3.0f;
    immutable Vec3  focus = Vec3(0, 0, 0);
    auto vp = frontOrthoViewport(dist, focus);
    assert(isOrtho(vp), "rig premise: the Front preset is orthographic");

    // Pick a pixel that unprojects to a known world point on the plane.
    float halfH  = dist * tan(cast(float)(PI / 8.0));
    float aspect = cast(float)vp.width / vp.height;
    immutable Vec3 want = Vec3(0.4f, 0.3f, 0.0f);   // right 0.4, up 0.3 of focus
    float ndcX = want.x / (halfH * aspect);
    float ndcY = want.y / halfH;
    float px = (ndcX * 0.5f + 0.5f) * vp.width;
    float py = (1.0f - (ndcY * 0.5f + 0.5f)) * vp.height;

    auto f = frameFromBasis(Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0),
                            focus, true);
    // Plane normal in LOCAL space is +Y by construction (toWorld's middle
    // column is the frame normal), and the plane passes through local origin.
    Vec3 hitLocal;
    assert(workplaneCursorPlaneHit(f, vp, px, py, Vec3(0, 0, 0), Vec3(0, 1, 0),
                                   hitLocal),
           "an axis-facing plane can never be parallel to its own view ray");
    Vec3 got = transformPoint(f.toWorld, hitLocal);

    assert(abs(got.x - want.x) < 1e-4f && abs(got.y - want.y) < 1e-4f,
           "ortho click must land AT the pixel it was taken from; the "
           ~ "perspective pencil lands at distance times that offset");
    assert(abs(got.z - focus.z) < 1e-5f, "and on the plane");
}

unittest { // ortho: the plane's DEPTH is the focus snapped to q (K-W2 finding 2)
    import std.math : abs;
    // Focus depth OFF the q lattice; `placementPlaneHit` is UNQUANTISED, so
    // only the anchor's own snap can put the hit's depth on the lattice.
    auto vp = frontOrthoViewport(3.0f, Vec3(0.7f, 0.5f, 2.01234f));
    immutable float q = viewVectorQuantum(vp);
    immutable float want = vectorSnap(vp.focus, q).z;
    assert(q > 0 && abs(want - vp.focus.z) > 1e-4f,
           "rig premise: the focus depth must sit off the q lattice");
    int axisLocal;
    immutable Vec3 hit = placementPlaneHit(500.0f, 120.0f, vp,
                                           primitivePlacementFrame(), axisLocal);
    assert(axisLocal == 2, "a Front view's principal plane is the Z plane");
    assert(abs(hit.z - want) < 1e-6f,
           "the ortho anchor's depth must be the focus snapped to the view "
           ~ "quantum, not the raw focus");
}

unittest { // the placement click is TOTAL where the old floor plane refused
    import std.math : abs;
    import vibe3d.util.spatial.spatial : screenPointToRay;

    immutable float dist  = 3.0f;
    // The focus is deliberately OFF the world origin on all three axes. With
    // it at the origin this test cannot tell the view-following plane from
    // the world floor: the camera-perpendicular fallback below would rescue
    // the floor case and land on z = 0, which is also the right answer. The
    // displaced focus is what makes the DEPTH a discriminator.
    immutable Vec3  focus = Vec3(0.7f, 0.5f, 2.0f);
    auto vp = frontOrthoViewport(dist, focus);

    // The premise of the whole task, asserted rather than stated in prose:
    // the fixed world floor (Y = 0, normal (0,1,0)) that the deleted
    // `math.screenToWorkPlane` defaulted to is EXACTLY parallel to a Front
    // view's ray, so a projection onto it refuses. This is the shape of that
    // call, spelled out.
    Vec3 rayO, rayD, floorHit;
    screenPointToRay(500.0f, 120.0f, vp, rayO, rayD);
    assert(!rayPlaneIntersect(rayO, rayD, Vec3(0, 0, 0), Vec3(0, 1, 0), floorHit),
           "premise: the Y=0 floor is degenerate in a horizontal view");

    // No `g_pipeCtx` in a unittest, so `primitivePlacementFrame` is the auto
    // identity — the frame this defect lived in (task 7139 moved the
    // placement arm into `screenToPlacementLocal`).
    int axisLocal;
    Vec3 got = screenToPlacementLocal(
        500.0f, 120.0f, vp, primitivePlacementFrame(), axisLocal);
    assert(axisLocal == 2, "a Front view's principal plane is the Z plane");
    assert(abs(got.z - focus.z) < 1e-5f,
           "the plane follows the view AND is anchored at the camera focus: "
           ~ "a Front view lands on Z = focus.z, not Z = 0");
    // ...and in-plane it is the point under the cursor (under ortho the
    // unprojected click itself) snapped to the view quantum.
    immutable float q = viewVectorQuantum(vp);
    assert(q > 0 && abs(got.x - vectorSnap(rayO, q).x) < 1e-5f
                 && abs(got.y - vectorSnap(rayO, q).y) < 1e-5f,
           "in-plane, an ortho click lands where it was made, on the q lattice");
    assert(abs(got.x - focus.x) > 1e-3f || abs(got.y - focus.y) > 1e-3f,
           "rig premise: the pixel must be off-centre, or nothing is measured");
}
