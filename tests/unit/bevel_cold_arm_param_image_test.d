module unit.bevel_cold_arm_param_image_test;

// ---------------------------------------------------------------------------
// Task 4491 — both bevel tools refused to ARM whenever a sticky parameter
// enlisted their param-update resource.
//
// The arm transaction replays every sticky parameter name into the unpublished
// candidate (prepared_tool_transition.d, the `sticky.changedNames` loop), so
// each name enlists a PreparedPolyBevelParamUpdateOwner / …EdgeBevel… into the
// params context. Validation then walks `resources_` and calls each owner's
// `validate()`, whose last disjunct is `preparedParamUpdateMatches`.
//
// At that moment the tool is COLD: `prepareArm` has not published the
// activation yet, so `before` is unfilled. `buildPreparedParamUpdate` used to
// return early on exactly that condition WITHOUT capturing the preview image,
// while `preparedParamUpdateMatches` checks `preview_.matchesImage(...)`
// unconditionally — and `matchesImage` gates on the image's own `valid`. The
// conjunct was therefore false for reasons that had nothing to do with the
// tool's state, and the arm refused.
//
// WHY ONLY THE TWO BEVELS. Of the tools with sticky prefs entries, only these
// two carry the preview conjunct UNGUARDED. `EdgeExtendTool` uses the same
// PreviewRebuild seam but writes `(!image.appliesMesh || preview_.matchesImage
// (image.preview))`, and `PolyExtrudeTool` — the control below — takes the very
// same `!before.filled` early return with no preview conjunct at all.
//
// ORDER IS LOAD-BEARING (CLAUDE.md): the poly.extrude control sits ABOVE the
// two bevel blocks, and the poly.bevel block above the edge.bevel one, so a
// mutation of one builder reddens a named line while everything above it is
// proven green by control flow in the same run.
// ---------------------------------------------------------------------------

import document : Layer;
import editmode : EditMode;
import mesh : Mesh, GpuMesh, makeCube;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedPolyBevelParamKind, PreparedEdgeBevelParamKind,
                              PreparedPolyExtrudeParamKind;
import record_observer_hub : RecordObserverHub;
import shader : LitShader;
import tools.edit.edge_bevel : EdgeBevelTool;
import tools.edit.poly_bevel : PolyBevelTool;
import tools.edit.poly_extrude : PolyExtrudeTool;

unittest {
    auto layer = new Layer; layer.meshRef() = makeCube();
    layer.meshRef().syncSelection(); layer.meshRef().selectFace(0);
    GpuMesh gpu; EditMode mode = EditMode.Polygons;

    // POPULATION FLOOR. Everything below is a statement about a real mesh with
    // a real selection; over an empty one the matches would hold vacuously.
    assert(layer.meshRef().vertices.length == 8 &&
           layer.meshRef().faces.length == 6 &&
           layer.meshRef().countSelectedFaces() == 1,
        "4491 floor: the cold-arm cells need a populated cube with one face "
        ~ "selected, or every snapshot compare below is vacuous");

    // ---- control: same cold state, same early return, no preview conjunct.
    {
        auto px = new PolyExtrudeTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto img = px.buildPreparedParamUpdate(layer.meshRef());
        assert(img.valid && !img.expectedBefore.filled,
            "4491 control: poly.extrude must be on the COLD path (before "
            ~ "unfilled) or it is not the same cell as the bevels below");
        assert(px.preparedParamUpdateMatches(img, layer.meshRef()),
            "4491 control: poly.extrude matches on a cold arm and always did — "
            ~ "if THIS reddened, the defect is not the preview conjunct");
    }

    // ---- poly.bevel: the image must be COMPLETE on the cold path …
    {
        auto pb = new PolyBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto img = pb.buildPreparedParamUpdate(layer.meshRef());
        assert(img.valid && !img.expectedBefore.filled,
            "4491: poly.bevel must be on the COLD path here");
        assert(img.preview.valid,
            "4491 poly.bevel: buildPreparedParamUpdate left the preview image "
            ~ "unprepared on the cold-arm path; matchesImage gates on this "
            ~ "flag, so the arm conjunct can never hold");
        assert(pb.preparedParamUpdateMatches(img, layer.meshRef()),
            "4491 poly.bevel: cold-arm image must match the live tool");
    }
    // … and the whole arm-time gate that actually refused must pass.
    {
        auto pb = new PolyBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto ctx = new PreparedRecordContext(null, new RecordObserverHub());
        ctx.setResourceIdentity(7, 11);
        auto eff = pb.prepareParamChanged(ctx, layer, null);
        assert(eff.accepted && eff.kind == PreparedPolyBevelParamKind.Noop,
            "4491 poly.bevel: a cold sticky replay is a noop param update");
        assert(ctx.validate(),
            "4491 poly.bevel: the enlisted PolyBevelParamUpdateState must "
            ~ "validate at arm time — this is the resource whose refusal threw "
            ~ "`prepared tool arm params validation refused`");
    }

    // ---- edge.bevel: the same two statements on the second tool.
    {
        auto eb = new EdgeBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto img = eb.buildPreparedParamUpdate(layer.meshRef());
        assert(img.valid && !img.expectedBefore.filled,
            "4491: edge.bevel must be on the COLD path here");
        assert(img.preview.valid,
            "4491 edge.bevel: buildPreparedParamUpdate left the preview image "
            ~ "unprepared on the cold-arm path");
        assert(eb.preparedParamUpdateMatches(img, layer.meshRef()),
            "4491 edge.bevel: cold-arm image must match the live tool");
    }
    {
        auto eb = new EdgeBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto ctx = new PreparedRecordContext(null, new RecordObserverHub());
        ctx.setResourceIdentity(7, 11);
        auto eff = eb.prepareParamChanged(ctx, layer, null);
        assert(eff.accepted && eff.kind == PreparedEdgeBevelParamKind.Noop,
            "4491 edge.bevel: a cold sticky replay is a noop param update");
        assert(ctx.validate(),
            "4491 edge.bevel: the enlisted EdgeBevelParamUpdateState must "
            ~ "validate at arm time");
    }
}
