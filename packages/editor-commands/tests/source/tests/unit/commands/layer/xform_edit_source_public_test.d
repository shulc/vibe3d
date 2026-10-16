module tests.unit.commands.layer.xform_edit_source_public_test;

import commands.layer.xform_edit;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.viewport.camera.view : View;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.documents.model.document : Layer, ItemXform;

version (unittest) {
    import math : Vec3;
    private ItemXform xf(float px) {
        ItemXform x;
        x.pos = Vec3(px, 0, 0);
        return x;
    }
}

unittest { // mergeRunTail: single target, first-touch before + latest after.
    Mesh mesh;
    View view = new View(0, 0, 1, 1);
    auto layer = new Layer();

    auto c1 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c1.setEdit([ LayerXformTarget(layer, xf(0), xf(1)) ]);
    auto c2 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c2.setEdit([ LayerXformTarget(layer, xf(1), xf(2)) ]);
    auto c3 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c3.setEdit([ LayerXformTarget(layer, xf(2), xf(3)) ]);

    auto merged = cast(LayerXformEdit) c1.mergeRunTail([c2, c3]);
    assert(merged !is null);
    auto ts = merged.targets();
    assert(ts.length == 1);
    assert(ts[0].target is layer);
    assert(ts[0].before.pos.x == 0, "must keep the RUN-START (first-touch) before");
    assert(ts[0].after.pos.x  == 3, "must adopt the LATEST after");
}

unittest { // mergeRunTail: two targets unioned by Layer IDENTITY.
    Mesh mesh;
    View view = new View(0, 0, 1, 1);
    auto layerA = new Layer();
    auto layerB = new Layer();

    // Gesture 1 touches only A; gesture 2 touches only B (a run that changed
    // which item was under the cursor mid-run would look like this).
    auto c1 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c1.setEdit([ LayerXformTarget(layerA, xf(0), xf(1)) ]);
    auto c2 = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    c2.setEdit([ LayerXformTarget(layerB, xf(10), xf(11)) ]);

    auto merged = cast(LayerXformEdit) c1.mergeRunTail([c2]);
    assert(merged !is null);
    auto ts = merged.targets();
    assert(ts.length == 2, "targets must union by Layer identity, not overwrite");
    bool sawA = false, sawB = false;
    foreach (t; ts) {
        if (t.target is layerA) { sawA = true; assert(t.before.pos.x == 0); assert(t.after.pos.x == 1); }
        if (t.target is layerB) { sawB = true; assert(t.before.pos.x == 10); assert(t.after.pos.x == 11); }
    }
    assert(sawA && sawB);

    // NIT (0614 review) — order must be the deterministic FIRST-TOUCH
    // insertion order (A touched by c1, B touched by c2), not whatever order
    // an associative array's `.values` happens to iterate in (unspecified by
    // the language). Multi-target merges only ship in Phase 6, but the API
    // is exercised here today, so pin it now rather than let a future caller
    // discover the non-determinism first.
    assert(ts[0].target is layerA && ts[1].target is layerB,
        "targets must preserve deterministic first-touch insertion order");
}

unittest { // apply()/revert() write the WHOLE xform, both directions.
    Mesh mesh;
    View view = new View(0, 0, 1, 1);
    auto layer = new Layer();
    layer.xform = xf(5);

    auto cmd = new LayerXformEdit(&mesh, view, EditMode.Vertices);
    cmd.setEdit([ LayerXformTarget(layer, xf(5), xf(9)) ]);

    assert(cmd.apply());
    assert(layer.xform.pos.x == 9);

    assert(cmd.revert());
    assert(layer.xform.pos.x == 5);
}
