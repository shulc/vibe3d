// Module unittests for `layer_params`, moved verbatim out of source/layer_params.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.layer_params_test;

import params   : Param, ParamProvider;
import document : Layer, Document, kindInfo, ItemKind, ItemXform,
                  MIN_ITEM_SCALE_MAG, MAX_ITEM_SCALE_MAG, sanitizeItemXform;
import seltype  : SelType;
import layer_params;

// ---------------------------------------------------------------------------
// The universe really is the UNION, not any one kind's bundle.
//
// Discriminating: an implementation that built it from a single default-kind
// (mesh) layer — the tempting one, since a mesh has the most params — returns
// 14 names and NONE of the plane's ten, so the form's whole per-kind section
// would be rejected at boot as ten unknown attrs. The plane-channel assertions
// below read absent for it. The mesh half is the control: a union that somehow
// lost the shared bundle would break every existing transform row.
// ---------------------------------------------------------------------------
unittest {
    auto u = layerAttrUniverse();
    bool has(string n) { foreach (x; u) if (x == n) return true; return false; }

    // Shared bundle — every kind that has a transform contributes these.
    foreach (n; ["name", "visible", "pos.x", "rot.y", "scl.z", "pivot.x"])
        assert(has(n), "the shared attr `" ~ n ~ "` is in the universe");
    // The image kind's bundle.
    foreach (n; ["filename", "colorspace", "useAlpha"])
        assert(has(n), "the image kind's `" ~ n ~ "` is in the universe");
    // The plane's ten — the reason the union has to span kinds at all.
    foreach (n; ["projection", "showInPerspective", "pixelSize", "keepAspect",
                 "brightness", "contrast", "transparency", "invert",
                 "flipHorizontal", "smooth"])
        assert(has(n), "the plane's `" ~ n ~ "` is in the universe — the "
                     ~ "layer-props form's per-kind section binds it, and a "
                     ~ "universe without it rejects that row at boot");

    // No duplicates: `name`/`visible` are contributed by all four kinds and
    // must appear once, or the fence's error messages and any count read off
    // this list would be nonsense.
    bool[string] once;
    foreach (n; u) {
        assert((n in once) is null, "`" ~ n ~ "` appears twice in the universe");
        once[n] = true;
    }
    // 14 shared/transform + 3 image + 10 plane = 27 distinct names.
    assert(u.length == 27, "the union spans every kind's bundle");
}

// ---------------------------------------------------------------------------
// P0.4b (task 0616 Ph4): the properties form follows the FOCUS.
//
// Discriminating: the fixture's focus is an IMAGE while its primary is a mesh,
// so an implementation returning `doc.primary` reads the mesh — a different
// object, with a different name and a different param set. The all-mesh half
// is the control that proves the change is inert where it must be.
// ---------------------------------------------------------------------------
unittest {
    import document : Document, ItemKind, ImageData;
    import mesh     : makeCube;
    import seltype  : SelMode;

    auto doc = Document.bootstrap(makeCube());
    doc.layers[0].name = "the mesh";
    assert(itemPropsTarget(&doc) is doc.primary,
        "all-mesh control: focus and primary coincide, so the binding is "
        ~ "unchanged from what it has always been");

    auto img = new Layer;
    img.name = "the image";
    img.kind = ItemKind.Image;
    img.imageRef() = new ImageData();
    doc.layers ~= img;
    // ADD, not Set (task 0668): the state under test is "focus and primary are
    // different OBJECTS", and an exclusive select of an image now leaves no
    // primary at all — which would make the vacuity guard below pass against
    // `null` and stop discriminating "binds the focus" from "binds the
    // primary". Ctrl-adding the image is the reachable state that keeps both
    // pointers live and different.
    doc.selectItem(img, SelMode.Add);

    assert(doc.primary is doc.layers[0],
        "vacuity guard: an image can never become the primary, so the focus "
        ~ "and the primary here really are different objects");
    assert(doc.focusedItem is img, "precondition: the image took the focus");

    auto bound = itemPropsTarget(&doc);
    assert(bound is img,
        "the properties form binds the FOCUS; binding the primary would show "
        ~ "'" ~ doc.primary.name ~ "' instead of '" ~ img.name ~ "'");

    // And the bound provider really does expose the image's own channels —
    // which is the whole point of following the focus.
    auto prov = new LayerPropsProvider(bound);
    bool sawColorspace = false;
    foreach (p; prov.params()) if (p.name == "colorspace") sawColorspace = true;
    assert(sawColorspace,
        "the image's per-kind channels are reachable through the bound "
        ~ "provider — they are not through the primary's");
}

// ---------------------------------------------------------------------------
// Task 0612 Stage 7: the same binding, for the kind whose channels the whole
// task exists to expose — and the FIRST kind that carries a transform AND a
// per-kind payload at once.
//
// That combination is what this adds over the image case above. An image is
// `hasXform == false`, so its provider is base + payload; a mesh is
// payload-less, so its provider is base + xform. Only a plane exercises both
// bundles in one `params()` call, and the plausible wrong implementation is
// the copy-paste one: the plane's arm nested inside the image arm's
// `if (img !is null)`, which is silently empty for every plane — the bundle
// drops to 14 params, and the first assertion to fire is the `projection`
// name check below (D aborts a module at its first `AssertError`, so the
// count line at the end never gets to speak).
// ---------------------------------------------------------------------------
unittest {
    import document : Document, ItemKind, ImagePlaneData;
    import mesh     : makeCube;
    import seltype  : SelMode;
    import std.conv : to;

    auto doc = Document.bootstrap(makeCube());
    auto plane = new Layer;
    plane.name = "the plane";
    plane.kind = ItemKind.ImagePlane;
    plane.imagePlaneRef() = new ImagePlaneData();
    doc.layers ~= plane;
    // ADD, not Set (task 0668): an exclusive select of a plane leaves NO
    // primary, and the vacuity guard below needs the primary to be a live,
    // DIFFERENT layer — against `null` it would stop discriminating.
    doc.selectItem(plane, SelMode.Add);

    assert(doc.primary is doc.layers[0] && doc.focusedItem is plane,
        "vacuity guard: a plane can never become the primary, so the focus "
        ~ "and the primary really are different objects here");
    auto bound = itemPropsTarget(&doc);
    assert(bound is plane, "the properties form binds the plane");

    auto ps = (new LayerPropsProvider(bound)).params();
    bool has(string n) { foreach (p; ps) if (p.name == n) return true; return false; }

    // All ten authored channels, named one by one. A count alone would pass
    // on ten of the WRONG params.
    foreach (n; ["projection", "showInPerspective", "pixelSize", "keepAspect",
                 "brightness", "contrast", "transparency", "invert",
                 "flipHorizontal", "smooth"])
        assert(has(n), "the plane's `" ~ n ~ "` channel is reachable through "
                     ~ "the form the panel binds");
    // And the transform bundle is there TOO — the plane is placed with the
    // ordinary item transform, so losing these would be losing the feature.
    foreach (n; ["pos.x", "rot.y", "scl.z", "pivot.x"])
        assert(has(n), "the plane's `" ~ n ~ "` transform component is "
                     ~ "reachable alongside its channels");
    assert(ps.length == 24,
        "name + visible + 12 transform + 10 channels — read "
        ~ to!string(ps.length));
}

// ---------------------------------------------------------------------------
// P0.4c (review S4): a STALE focus falls back to the primary.
//
// The guard here used to be `focusedItem !is null`, which is the UNREACHABLE
// case — non-null is a document invariant. The reachable one is stale:
// non-null but no longer a member of `layers`, which is what
// `Document.isMember`'s own doc comment describes and what a whole-document
// replacement by direct field assignment produces. `readV3d` (through
// `FileLoad`) is that replacement, on the live `Document`, every File → Open.
//
// WHY IT MATTERS, and why "it draws the wrong panel" understates it: the bound
// item's index is what the form's rows dispatch `layer.attr` against.
// `indexOf` answers `layers.length` for a non-member and `resolveIndex`
// (`commands/layer/commands.d`) CLAMPS that into range — so every edit made in
// the properties panel would land on the LAST item in the document. The
// assertion below reads that number directly rather than describing it.
//
// Discriminating: the stale item is a real, live `Layer` object with a
// different name, so a `!is null` implementation returns it and every
// assertion here reads it — `is` identity, not "not null".
// ---------------------------------------------------------------------------
unittest {
    import document : Document, Layer;
    import mesh     : makeCube;

    auto doc = Document.bootstrap(makeCube());
    doc.layers[0].name = "the document that was open before";
    auto stale = doc.focusedItem;
    assert(stale !is null, "fixture: there is a focus to go stale");

    // The whole layer list is replaced by direct field assignment — the shape
    // `readV3d` uses, and the only way `focusedItem` can go stale.
    //
    // TASK 0671 — the `doc.primary = fresh` that used to close this block is
    // gone with the field. The edit target is derived by ENUMERATING `layers`,
    // so the replacement alone repoints it: `fresh` is the only member with a
    // selection state, and the old object stops being visible to the walk the
    // instant it leaves the list. `primary` therefore CANNOT go stale any
    // more — which is why the case below is a stale FOCUS only, and why it is
    // still worth testing: `focusedItem` is still a stored pointer.
    auto fresh = new Layer;
    fresh.name = "the document just loaded";
    fresh.meshRef() = makeCube();
    fresh.selected  = true;
    doc.layers      = [fresh];
    // …and `focusedItem` is deliberately NOT repointed: that is the bug state.
    assert(doc.primary is fresh,
        "precondition: the derived target followed the list replacement on its "
        ~ "own — if it had not, this test would be checking the wrong fallback");

    assert(doc.focusedItem is stale,
        "precondition: the focus still points at the OLD object — if a "
        ~ "mutator had already healed it there would be nothing to test");
    assert(!doc.isMember(doc.focusedItem),
        "…and that object is no longer in the document, which is exactly what "
        ~ "`!is null` cannot see");
    assert(doc.indexOf(doc.focusedItem) == doc.layers.length,
        "…so its index is the out-of-range sentinel that `resolveIndex` "
        ~ "clamps onto the last item");

    auto bound = itemPropsTarget(&doc);
    assert(bound is fresh,
        "a stale focus falls back to the primary; a `!is null` guard binds '"
        ~ stale.name ~ "' — an item that left the document, whose index "
        ~ "clamps every `layer.attr` the panel dispatches onto the last row");
    assert(doc.isMember(bound),
        "…and whatever is bound is a genuine member, which is the property "
        ~ "the index arithmetic downstream depends on");
}

unittest {
    import std.math : isClose;
    import std.json : JSONValue;
    import params   : paramToJson, injectParamsInto;
    import math     : Vec3;

    auto l = new Layer;
    l.name = "Layer 1";
    auto prov = new LayerPropsProvider(l);

    // ---- the 14 expected names / kinds, in order ----------------------------
    auto ps = prov.params();
    assert(ps.length == 14, "LayerPropsProvider exposes exactly 14 params");

    struct Spec { string name; Param.Kind kind; }
    Spec[] expect = [
        Spec("pos.x",   Param.Kind.Float),
        Spec("pos.y",   Param.Kind.Float),
        Spec("pos.z",   Param.Kind.Float),
        Spec("rot.x",   Param.Kind.Float),
        Spec("rot.y",   Param.Kind.Float),
        Spec("rot.z",   Param.Kind.Float),
        Spec("scl.x",   Param.Kind.Float),
        Spec("scl.y",   Param.Kind.Float),
        Spec("scl.z",   Param.Kind.Float),
        Spec("pivot.x", Param.Kind.Float),
        Spec("pivot.y", Param.Kind.Float),
        Spec("pivot.z", Param.Kind.Float),
        Spec("name",    Param.Kind.String),
        Spec("visible", Param.Kind.Bool),
    ];
    foreach (i, e; expect) {
        assert(ps[i].name == e.name, "param name at index mismatch");
        assert(ps[i].kind == e.kind, "param kind at index mismatch");
    }
    // The three rotation params carry the angle hint.
    assert(ps[3].hints.isAngle && ps[4].hints.isAngle && ps[5].hints.isAngle,
           "rot.x/y/z are angle params");
    // paramEnabled is true for all (P0).
    foreach (e; expect) assert(prov.paramEnabled(e.name));

    // ---- pointers alias the layer fields (both directions) ------------------
    // Layer → param: mutate the layer, read it back through paramToJson.
    l.xform.pos = Vec3(3, -2, 5);
    auto ps2 = prov.params();
    assert(isClose(paramToJson(ps2[0]).floating, 3.0,  1e-6));
    assert(isClose(paramToJson(ps2[1]).floating, -2.0, 1e-6));
    assert(isClose(paramToJson(ps2[2]).floating, 5.0,  1e-6));

    // Param → layer: write through the param's typed pointer, see the layer.
    *ps2[6].fptr = 2.0f;   // scl.x
    assert(isClose(l.xform.scl.x, 2.0f, 1e-6f),
           "writing through the param pointer mutates the layer");

    // ---- round-trip: paramToJson → injectParamsInto restores values ---------
    // Snapshot current values, perturb the layer, then inject the snapshot back.
    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    auto snap = prov.params();
    foreach (ref p; snap) pj[p.name] = paramToJson(p);

    // Perturb every field away from the snapshot.
    l.xform.pos   = Vec3(0, 0, 0);
    l.xform.rot   = Vec3(9, 9, 9);
    l.xform.scl   = Vec3(7, 7, 7);
    l.xform.pivot = Vec3(1, 1, 1);
    l.name        = "changed";
    l.visible     = false;

    auto sink = prov.params();
    injectParamsInto(sink, pj);

    // Values restored to the snapshot.
    assert(isClose(l.xform.pos.x, 3.0f,  1e-6f));
    assert(isClose(l.xform.pos.z, 5.0f,  1e-6f));
    assert(isClose(l.xform.scl.x, 2.0f,  1e-6f));
    assert(isClose(l.xform.scl.y, 1.0f,  1e-6f));   // unchanged default 1
    assert(l.name == "Layer 1", "name round-tripped");
    assert(l.visible == true,   "visible round-tripped");
}

unittest {
    import std.conv : to;   // `t` is a RUNTIME loop variable: `t.stringof` is
                            // the literal "t", never the enum member's name.
    auto l = new Layer;
    auto prov = new LayerPropsProvider(l);

    static immutable string[] transformRows = [
        "pos.x", "pos.y", "pos.z", "rot.x", "rot.y", "rot.z",
        "scl.x", "scl.y", "scl.z", "pivot.x", "pivot.y", "pivot.z",
    ];

    // No tool at all: everything is editable, whatever the selection type is.
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon, SelType.Item]) {
        prov.setTransformGuard(false, t);
        foreach (n; transformRows)
            assert(prov.paramEnabled(n),
                   "with no transform tool active every transform row stays "
                   ~ "editable, regardless of selection type (" ~ n ~ ")");
    }

    // Transform tool + a GEOMETRY subject: the interlock arms. The gizmo is
    // moving VERTICES in the layer's local frame; the item transform is a
    // second, invisible writer and authoring it mid-gesture desyncs the two.
    foreach (t; [SelType.Vertex, SelType.Edge, SelType.Polygon]) {
        prov.setTransformGuard(true, t);
        foreach (n; transformRows)
            assert(!prov.paramEnabled(n),
                   "a transform tool over a GEOMETRY selection must still grey "
                   ~ "the transform rows (" ~ n ~ ", selType " ~ t.to!string ~ ")");
        assert(prov.paramEnabled("name") && prov.paramEnabled("visible"),
               "name/visible are never part of the interlock");
    }

    // Transform tool + an ITEM subject: the interlock must NOT arm. Here the
    // gizmo's only write target IS `Layer.xform`, so there is no second writer
    // to desync from — and greying the rows would hide the very numbers the
    // gizmo is authoring for as long as the tool is up.
    prov.setTransformGuard(true, SelType.Item);
    foreach (n; transformRows)
        assert(prov.paramEnabled(n),
               "under SelType.Item the transform tool IS the item editor — the "
               ~ "row must stay live (" ~ n ~ ")");
    assert(prov.paramEnabled("name") && prov.paramEnabled("visible"));
}

unittest {
    import std.math : isClose, isNaN, isFinite;
    import math     : Vec3;

    static ItemXform rig() {
        ItemXform x;
        x.pos   = Vec3( 1.3f,  0.7f, -0.9f);
        x.rot   = Vec3(20.0f, 35.0f, -50.0f);
        x.scl   = Vec3( 1.4f,  0.8f,  1.9f);
        x.pivot = Vec3(0.25f, -0.4f,  0.6f);
        return x;
    }

    immutable float nan = float.nan;
    immutable float inf = float.infinity;

    // ---- non-finite on a POSITION component: rejected, prior value restored --
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.pos.y = nan;                    // what injectParamsInto would leave
        assert(prov.sanitizeXform(before), "a NaN write must be reported repaired");
        assert(isClose(l.xform.pos.y, 0.7f, 1e-6f),
               "a rejected write restores the PRE-WRITE value (0.7), not the "
               ~ "channel identity (0.0) — the rig is off-origin precisely so "
               ~ "those two are distinguishable");
        // Nothing else moved.
        assert(l.xform.pos.x == before.pos.x && l.xform.pos.z == before.pos.z);
        assert(l.xform.rot == before.rot && l.xform.scl == before.scl
               && l.xform.pivot == before.pivot,
               "the repair touches only the component that went non-finite");
    }

    // ---- non-finite on a SCALE component: rejected, prior value restored -----
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.z = inf;
        assert(prov.sanitizeXform(before));
        assert(isClose(l.xform.scl.z, 1.9f, 1e-6f),
               "an infinite scale restores the PRE-WRITE 1.9, not the identity "
               ~ "1.0 and not the floor 1e-4");
    }

    // ---- non-finite prior as well: falls back to the channel identity -------
    // A document loaded from a file written before this guard existed can carry
    // a poisoned value; the repair must still terminate somewhere composable.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        before.rot.x = nan;                     // the PRIOR value is unusable too
        auto prov = new LayerPropsProvider(l);

        l.xform.rot.x = nan;
        assert(prov.sanitizeXform(before));
        assert(l.xform.rot.x == 0.0f,
               "with no usable prior, a rotation falls back to its identity (0)");

        before.scl.y = nan;
        l.xform.scl.y = nan;
        assert(prov.sanitizeXform(before));
        assert(l.xform.scl.y == 1.0f,
               "with no usable prior, a scale falls back to its identity (1) — "
               ~ "NOT 0, which would be singular");
    }

    // ---- the degenerate band around zero: clamped, SIGN PRESERVED -----------
    // Sign preservation is the load-bearing half: a negative scale is a legal
    // mirror, so an implementation that clamped to a positive floor would read
    // +1e-4 where this reads -1e-4.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.x =  0.0f;
        l.xform.scl.y = -1e-9f;
        l.xform.scl.z =  1e-9f;
        assert(prov.sanitizeXform(before));
        assert(l.xform.scl.x ==  MIN_ITEM_SCALE_MAG);
        assert(l.xform.scl.y == -MIN_ITEM_SCALE_MAG,
               "a NEGATIVE near-zero scale floors to the NEGATIVE floor — a "
               ~ "mirror must survive the guard that keeps the matrix invertible");
        assert(l.xform.scl.z ==  MIN_ITEM_SCALE_MAG);
    }

    // ---- the magnitude ceiling, both signs ----------------------------------
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.x =  1e30f;
        l.xform.scl.y = -1e30f;
        assert(prov.sanitizeXform(before));
        assert(l.xform.scl.x ==  MAX_ITEM_SCALE_MAG,
               "a finite-but-absurd scale is capped at the ceiling, not passed "
               ~ "through — 1e30 squares to +inf at the first matrix product");
        assert(l.xform.scl.y == -MAX_ITEM_SCALE_MAG,
               "the ceiling preserves the sign, like the floor");
    }

    // ---- a legal xform is left BYTE-IDENTICAL and reports "not repaired" ----
    // Without this, an implementation that unconditionally rewrote every
    // component (rounding, renormalising, clamping to a narrower band) would
    // pass every assertion above.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        assert(!prov.sanitizeXform(before),
               "a legal xform must report NOTHING repaired");
        assert(l.xform.pos   == before.pos   && l.xform.rot   == before.rot
            && l.xform.scl   == before.scl   && l.xform.pivot == before.pivot,
               "a legal xform must come through byte-identical");
    }

    // ---- the composed matrix is finite and non-singular after a repair ------
    // The property R7 actually cares about, asserted directly rather than
    // inferred from the components.
    {
        auto l = new Layer;
        l.xform = rig();
        auto before = l.xform;
        auto prov = new LayerPropsProvider(l);

        l.xform.scl.x = 0.0f;
        l.xform.scl.y = nan;
        prov.sanitizeXform(before);
        auto m = l.xform.composedMatrix();
        foreach (v; m) assert(isFinite(v), "no NaN/Inf survives into the matrix");
        // det of the upper-left 3x3 — non-zero ⇒ invertible.
        immutable float det =
              m[0] * (m[5]*m[10] - m[6]*m[9])
            - m[4] * (m[1]*m[10] - m[2]*m[9])
            + m[8] * (m[1]*m[6]  - m[2]*m[5]);
        assert(det != 0.0f && isFinite(det),
               "the repaired xform composes to an INVERTIBLE matrix — the whole "
               ~ "point of the floor");
    }
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 2, T2 (per-kind channels half): the IMAGE kind's param
// NAME SET must differ from the MESH kind's — SET equality, not count, and
// specifically `pos.x` must be ABSENT, not merely present-and-disabled. An
// implementation that kept the 12 transform params and returned
// `paramEnabled == false` for an image-kind layer would read DIFFERENT from
// this assertion (both the length AND the presence of "pos.x" in the name
// set would differ), so this is the fixture that catches that specific
// wrong shape, not merely "some kind of gating exists".
// ---------------------------------------------------------------------------
unittest {
    import document : ItemKind;

    auto mesh = new Layer;
    mesh.name = "Mesh";
    auto meshProv = new LayerPropsProvider(mesh);
    auto meshParams = meshProv.params();

    auto img = new Layer;
    img.name = "Image";
    img.kind = ItemKind.Image;
    auto imgProv = new LayerPropsProvider(img);
    auto imgParams = imgProv.params();

    assert(meshParams.length == 14, "mesh-kind layer still exposes all 14 params");
    assert(imgParams.length == 2, "image-kind layer exposes only name + visible");

    bool[string] meshSet, imgSet;
    foreach (p; meshParams) meshSet[p.name] = true;
    foreach (p; imgParams)  imgSet[p.name]  = true;

    assert(("pos.x"   in meshSet) !is null, "fixture: pos.x IS a mesh-kind param");
    assert(("pos.x"   in imgSet)  is  null, "pos.x must be ABSENT from the image-kind set, not merely disabled");
    assert(("rot.y"   in imgSet)  is  null, "rot.y must be ABSENT from the image-kind set");
    assert(("pivot.z" in imgSet)  is  null, "pivot.z must be ABSENT from the image-kind set");
    assert(("name"    in imgSet)  !is null, "name survives on every kind");
    assert(("visible" in imgSet)  !is null, "visible survives on every kind");

    // NIT (review round 4): the two assertions above alone don't separate
    // "gated on the `hasXform` CAPABILITY" from "gated on `kind ==
    // ItemKind.Mesh`" — every fixture so far is Mesh on one side and
    // non-Mesh on the other, so a kind-equality check would pass them
    // identically. `Empty` is the discriminator: it `hasXform == true` but
    // `hasMesh == false` (`document.d`'s `kItemKindTable`) — it is neither
    // Mesh nor Image. A `kind == ItemKind.Mesh` implementation would give it
    // only `name`/`visible` (2 params, `pos.x` absent); the real
    // capability-read implementation must give it the full 14, `pos.x`
    // included, because the capability it actually has is true.
    auto placeholder = new Layer;
    placeholder.name = "Placeholder";
    placeholder.kind = ItemKind.Empty;
    auto placeholderProv = new LayerPropsProvider(placeholder);
    auto placeholderParams = placeholderProv.params();
    assert(placeholderParams.length == 14,
        "Empty (hasXform==true, hasMesh==false) must still get the full 14-param set — "
        ~ "a kind==Mesh check would wrongly give it 2");
    bool[string] placeholderSet;
    foreach (p; placeholderParams) placeholderSet[p.name] = true;
    assert(("pos.x" in placeholderSet) !is null,
        "pos.x must be PRESENT for Empty — a kind==Mesh check would wrongly omit it");
}

// ---------------------------------------------------------------------------
// Task 0616 Stage 3: the image kind's own channel bundle —
// `filename` (readonly) / `colorspace` (Enum) / `useAlpha` (Bool) — bound
// to a CONSTRUCTED `ImageData`. The unittest above already pins the
// null-payload fallback (an image-kind layer with no `ImageData` yet reads
// exactly 2 params, same as before this stage); this one pins the bundle
// itself once a payload exists, and every assertion below was verified by a
// deliberate, restored break: dropping `.readonly()` flips the readonly
// assertion; swapping `Param.enum_` for `Param.string_` on `colorspace`
// removes the `enumValues` entries and makes the bogus-tag inject NOT
// throw; deleting the `if (img !is null)` guard's outer condition (i.e.
// always emitting the bundle) makes the null-payload case in the unittest
// above dereference a null `ImageData` instead of reading length 2; and
// binding either default to the LIVE field value instead of a literal
// (`Param.enum_(..., &img.colorspace, tags, img.colorspace)`) makes the
// non-default-snapshot default assertions read "sRGB"/false.
// ---------------------------------------------------------------------------
unittest {
    import std.json  : JSONValue;
    import params    : paramToJson, injectParamsInto;
    import document  : ImageData;

    auto img = new Layer;
    img.name = "logo";
    img.kind = ItemKind.Image;
    img.imageRef() = new ImageData();
    img.imageRef().storedPath = "assets/logo.png";

    auto prov = new LayerPropsProvider(img);
    auto ps = prov.params();

    // Discriminating (count + set): a payload-bearing image layer gets
    // EXACTLY 5 params — filename/colorspace/useAlpha + name/visible — not
    // the bare 2 the null-payload fixture above reads, and not the 14 a
    // hasXform-style bundle would give a kind that has none.
    assert(ps.length == 5,
        "payload-bearing image layer exposes filename+colorspace+useAlpha+name+visible");

    Param* byName(Param[] arr, string n) {
        foreach (ref p; arr) if (p.name == n) return &p;
        return null;
    }
    auto filenameP   = byName(ps, "filename");
    auto colorspaceP = byName(ps, "colorspace");
    auto useAlphaP   = byName(ps, "useAlpha");
    assert(filenameP   !is null, "filename channel present");
    assert(colorspaceP !is null, "colorspace channel present");
    assert(useAlphaP   !is null, "useAlpha channel present");
    assert(byName(ps, "pos.x") is null, "image kind still has no transform channels");
    assert(byName(ps, "format") is null,
        "format is NEVER a channel — it is derived, not authored (plan §Q2)");

    // ---- kinds, exactly (discriminates a String/Bool mix-up) ----------------
    assert(filenameP.kind   == Param.Kind.String, "filename is a String param");
    assert(colorspaceP.kind == Param.Kind.Enum,   "colorspace is an Enum param");
    assert(useAlphaP.kind   == Param.Kind.Bool,   "useAlpha is a Bool param");

    // ---- filename is read-only; the other two channels are NOT --------------
    // Discriminating: a wrong implementation that forgets `.readonly()`
    // reads `filenameP.readonly_ == false` here.
    assert(filenameP.readonly_,    "filename must be marked readonly");
    assert(!colorspaceP.readonly_, "colorspace is a writable channel");
    assert(!useAlphaP.readonly_,   "useAlpha is a writable channel");

    // ---- colorspace's tag set is the closed three-tag set, exactly ----------
    assert(colorspaceP.enumValues.length == 3,
        "colorspace has exactly the three declared tags");
    bool[string] tags;
    foreach (e; colorspaceP.enumValues) tags[e[0]] = true;
    assert(("(default)" in tags) !is null);
    assert(("sRGB"       in tags) !is null);
    assert(("linear"     in tags) !is null);

    // ---- defaults: NOT asserted here, deliberately -------------------------
    // The obvious place for `colorspaceP.default_.s == "(default)"` is right
    // here — and it would be INERT. `ps` was captured off a fresh
    // `new ImageData()`, whose field initialisers ARE "(default)"/true, so a
    // wrong implementation that binds the default to the LIVE value
    // (`Param.enum_(..., &img.colorspace, tags, img.colorspace)`) reads the
    // identical value through the assertion and stays green. That bug is not
    // cosmetic: `default_` is what `isUserSet` compares against (params.d), so
    // a live-bound default makes `isUserSet` permanently false. The default
    // assertions therefore live on the NON-DEFAULT snapshot further down
    // (search "defaults are LITERALS"), where the two implementations read
    // different values.

    // ---- pointers alias the live ImageData (both directions) ----------------
    img.imageRef().storedPath = "changed/path.png";
    auto ps2 = prov.params();
    assert(paramToJson(*byName(ps2, "filename")).str == "changed/path.png",
        "filename param reads the live storedPath");
    *byName(ps2, "colorspace").sptr = "linear";
    assert(img.imageRef().colorspace == "linear",
        "writing through the colorspace param pointer mutates the payload");
    *byName(ps2, "useAlpha").bptr = false;
    assert(img.imageRef().useAlpha == false,
        "writing through the useAlpha param pointer mutates the payload");

    // ---- generic round-trip: paramToJson -> injectParamsInto ----------------
    // Non-default values throughout (mirrors the plan's T8d reasoning: a
    // default-valued fixture cannot tell a codec that drops the block from
    // one that reads it correctly).
    img.imageRef().colorspace = "sRGB";
    img.imageRef().useAlpha  = false;
    auto snap = prov.params();

    // ---- defaults are LITERALS, not the live field value (plan §Q2) --------
    // Asserted HERE, off a snapshot whose live values are "sRGB"/false, NOT
    // off the fresh-`ImageData` snapshot above where the initialisers happen
    // to equal the defaults. Discriminating: an implementation that binds the
    // default to the live value reads "sRGB"/false here and goes RED; the
    // correct one reads the declared literals. (Also pins the measured
    // reference values themselves.)
    assert(byName(snap, "colorspace").default_.s == "(default)",
        "colorspace default is the LITERAL '(default)', not the live field value");
    assert(byName(snap, "useAlpha").default_.b == true,
        "useAlpha default is the LITERAL true, not the live field value");
    // ...and the live values really are the non-default ones, so the two
    // assertions above cannot have been read off a coincidence.
    assert(*byName(snap, "colorspace").sptr == "sRGB",
        "fixture precondition: colorspace's LIVE value differs from its default");
    assert(*byName(snap, "useAlpha").bptr == false,
        "fixture precondition: useAlpha's LIVE value differs from its default");

    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    foreach (ref p; snap) if (!p.readonly_) pj[p.name] = paramToJson(p);

    img.imageRef().colorspace = "(default)";
    img.imageRef().useAlpha  = true;
    auto sink = prov.params();
    injectParamsInto(sink, pj);
    assert(img.imageRef().colorspace == "sRGB",
        "colorspace round-trips a NON-DEFAULT value through paramToJson/injectParamsInto");
    assert(img.imageRef().useAlpha == false,
        "useAlpha round-trips a NON-DEFAULT value through paramToJson/injectParamsInto");

    // ---- Enum kind rejects an unknown tag; discriminates vs. a String impl --
    // If `colorspace` were declared `Param.string_` (the measured reference
    // type — plan divergence 4), this inject would NOT throw: it is
    // specifically `Param.Kind.Enum`'s validation in `injectParamsInto`
    // (params.d) that rejects an unrecognised tag.
    auto sink2 = prov.params();
    JSONValue bad = JSONValue(cast(JSONValue[string]) null);
    bad["colorspace"] = JSONValue("not-a-real-tag");
    bool threw = false;
    try { injectParamsInto(sink2, bad); }
    catch (Exception) { threw = true; }
    assert(threw, "an unknown colorspace tag must be rejected by injectParamsInto");

    // ---- filename is exposed for READING even though it is not authored
    //      through this generic path (the `visible` precedent) -------------
    auto ps3 = prov.params();
    assert(paramToJson(*byName(ps3, "filename")).str == "changed/path.png",
        "filename remains READABLE through the generic param path");
}

// ---------------------------------------------------------------------------
// Task 0612 Stage 2 — the image plane's channel bundle.
//
// A plane is `hasXform == true`, so it gets the 12 transform components too:
// 12 + 10 channels + name/visible = 24. That total is the discriminator for
// the two shapes this could have been got wrong in — a bundle bolted onto the
// wrong `final switch` arm reads 14 (the transform-only count), and a plane
// wrongly declared `hasXform == false` reads 12.
//
// The bounds are asserted through `injectParamsInto` rather than by reading
// the hint fields, because the hints are INERT without `.enforceBounds()` and
// a test that read `p.hints.minF` would pass on a Param that clamps nothing.
// That distinction is the whole content of the guard.
// ---------------------------------------------------------------------------
unittest {
    import std.json  : JSONValue, parseJSON;
    import params    : paramToJson, injectParamsInto;
    import document  : ImagePlaneData;

    auto lyr = new Layer;
    lyr.name = "front sheet";
    lyr.kind = ItemKind.ImagePlane;
    lyr.imagePlaneRef() = new ImagePlaneData();
    auto plane = lyr.imagePlaneRef();

    auto prov = new LayerPropsProvider(lyr);
    auto ps = prov.params();
    assert(ps.length == 24,
        "12 transform + 10 plane channels + name + visible");

    Param* byName(Param[] arr, string n) {
        foreach (ref p; arr) if (p.name == n) return &p;
        return null;
    }
    foreach (n; ["projection", "showInPerspective", "pixelSize", "keepAspect",
                 "brightness", "contrast", "transparency", "invert",
                 "flipHorizontal", "smooth"])
        assert(byName(ps, n) !is null, "channel '" ~ n ~ "' is declared");
    assert(byName(ps, "pos.x") !is null,
        "a plane IS positionable — the transform bundle is present");
    assert(byName(ps, "filename") is null,
        "a plane owns no image and therefore no filename channel: its pixels "
        ~ "come through a LINK, which is not a Param at all");
    assert(byName(ps, "projection").kind == Param.Kind.Enum,
        "projection is a closed token set, not a free string");

    // pixelSize's FLOOR is enforced on the generic write path — the path a
    // `.v3d` channel block, an argstring and an HTTP `layer.attr` all take.
    // Zero is the value that matters: it collapses the plane's world extent
    // to nothing, and the quad becomes degenerate rather than merely small.
    { auto _j0 = parseJSON(`{"pixelSize": 0.0}`); injectParamsInto(ps, _j0); }
    assert(plane.pixelSize == 1e-6f,
        "a zero pixelSize is clamped to the declared floor — without "
        ~ "`.enforceBounds()` it lands as 0 and the plane has no extent");
    { auto _j1 = parseJSON(`{"pixelSize": -5.0}`); injectParamsInto(ps, _j1); }
    assert(plane.pixelSize == 1e-6f, "and so is a negative one");
    { auto _j2 = parseJSON(`{"pixelSize": 1e9}`); injectParamsInto(ps, _j2); }
    assert(plane.pixelSize == 1e3f, "and the ceiling holds at the other end");
    { auto _j3 = parseJSON(`{"pixelSize": 0.004}`); injectParamsInto(ps, _j3); }
    assert(plane.pixelSize == 0.004f,
        "a value INSIDE the range is written through untouched — a clamp that "
        ~ "always fired would pass every assertion above");

    // The three look scalars are bounded too, each at its own range: the
    // signed pair at -1..1 and transparency at 0..1. Asserting all three with
    // the SAME out-of-range input is what separates them — a copy-paste that
    // gave transparency the signed range reads -1 for the third.
    { auto _j4 = parseJSON(`{"brightness": -9.0, "contrast": -9.0, "transparency": -9.0}`); injectParamsInto(ps, _j4); }
    assert(plane.brightness == -1.0f && plane.contrast == -1.0f,
        "brightness and contrast floor at -1");
    assert(plane.transparency == 0.0f,
        "transparency floors at 0 — it is a fraction of invisibility, and a "
        ~ "negative one has no meaning");

    // The enum REJECTS an unknown tag rather than writing it. This is the one
    // channel where a silent accept would be invisible: an unknown projection
    // would resolve to no viewport at all and the plane would simply never
    // appear, with nothing to read that says why.
    bool threw = false;
    try { auto _j5 = parseJSON(`{"projection": "diagonal"}`); injectParamsInto(ps, _j5); }
    catch (Exception) threw = true;
    assert(threw, "an unknown projection tag is refused");
    assert(plane.projection == "front", "and the channel keeps its value");
    { auto _j6 = parseJSON(`{"projection": "right"}`); injectParamsInto(ps, _j6); }
    assert(plane.projection == "right", "a known tag is written");
}

// A plane layer whose payload has not been constructed yet falls back to the
// base bundle instead of dereferencing a null. Same contract, same reason, as
// the image kind's null-payload case: `params()` is a per-frame query and is
// not the place to construct a payload as a side effect.
unittest {
    auto lyr = new Layer;
    lyr.kind = ItemKind.ImagePlane;
    auto ps = (new LayerPropsProvider(lyr)).params();
    assert(ps.length == 14,
        "12 transform + name + visible — the plane channels need a payload to "
        ~ "point at, and there is none");
}
