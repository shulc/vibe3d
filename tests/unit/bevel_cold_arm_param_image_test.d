module unit.bevel_cold_arm_param_image_test;

// ---------------------------------------------------------------------------
// Task 4491 — both bevel tools refused to ARM whenever a sticky parameter
// enlisted their param-update resource: the arm replays every sticky name into
// the unpublished candidate (prepared_tool_transition.d, the
// `sticky.changedNames` loop), the tool is COLD (`before` unfilled), and the
// image then failed a preview-cache conjunct it never prepared. Task 9489
// deleted that conjunct with the preview half of the image; these cells keep
// the arm-time contract: a cold image matches and its whole transaction
// validates. ORDER IS LOAD-BEARING: the poly.extrude control sits ABOVE the two
// bevel blocks, and the poly.bevel block above the edge.bevel one.
// ---------------------------------------------------------------------------

import document : Layer;
import editmode : EditMode;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
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

    // ---- control: the same cold state on a third tool.
    {
        auto px = new PolyExtrudeTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto img = px.buildPreparedParamUpdate("", layer.meshRef());
        assert(img.valid,
            "4491 control: the fresh poly.extrude cold image must be valid");
        assert(px.preparedParamUpdateMatches(img, layer.meshRef()),
            "4491 control: poly.extrude must match on a cold arm");
    }

    // ---- poly.bevel: the image must be COMPLETE on the cold path …
    {
        auto pb = new PolyBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto img = pb.buildPreparedParamUpdate("", layer.meshRef());
        assert(img.valid,
            "4491: poly.bevel must be on the COLD path here");
        assert(pb.preparedParamUpdateMatches(img, layer.meshRef()),
            "4491 poly.bevel: cold-arm image must match the live tool");
    }
    // … and the whole arm-time gate that actually refused must pass.
    {
        auto pb = new PolyBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto ctx = new PreparedRecordContext(null, new RecordObserverHub());
        ctx.setResourceIdentity(7, 11);
        auto eff = pb.prepareParamChanged("", ctx, layer, null);
        assert(eff.accepted && eff.kind == PreparedPolyBevelParamKind.Noop,
            "4491 poly.bevel: a cold sticky replay is a noop param update");
        assert(ctx.validate(),
            "4491 poly.bevel: the enlisted ParamUpdateState must "
            ~ "validate at arm time — this is the resource whose refusal threw "
            ~ "`prepared tool arm params validation refused`");
    }

    // ---- edge.bevel: the same two statements on the second tool.
    {
        auto eb = new EdgeBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto img = eb.buildPreparedParamUpdate("", layer.meshRef());
        assert(img.valid,
            "4491: edge.bevel must be on the COLD path here");
        assert(eb.preparedParamUpdateMatches(img, layer.meshRef()),
            "4491 edge.bevel: cold-arm image must match the live tool");
    }
    {
        auto eb = new EdgeBevelTool(() => &layer.meshRef(), &gpu, &mode,
            LitShader.init);
        auto ctx = new PreparedRecordContext(null, new RecordObserverHub());
        ctx.setResourceIdentity(7, 11);
        auto eff = eb.prepareParamChanged("", ctx, layer, null);
        assert(eff.accepted && eff.kind == PreparedEdgeBevelParamKind.Noop,
            "4491 edge.bevel: a cold sticky replay is a noop param update");
        assert(ctx.validate(),
            "4491 edge.bevel: the enlisted ParamUpdateState must "
            ~ "validate at arm time");
    }
}
