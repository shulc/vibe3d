module image_plane_source_cells;

import image_plane;
import vibe3d.documents.model.document : Document, Layer, LinkState, ImagePlaneData, ItemXform;
import math;
import vibe3d.viewport.camera.view : ViewPreset, presetBasis;

version (unittest) {
    import vibe3d.documents.model.document : ItemKind, ImageData, ImagePlaneData;

    /// [mesh, clipA, clipB(middle target), clipC, plane] — three clips, the
    /// plane bound to the MIDDLE one, and clipA / clipC sharing ONE file path
    /// with it. The sharing is the point: with three distinct paths a
    /// path-identity bug would resolve to nothing and look like a broken
    /// link; with two decoys on the same path it resolves to the WRONG clip
    /// and every count still adds up.
    Document planeFixture(out Layer plane, out Layer target) {
        import vibe3d.mesh.core.mesh : makeCube;
        auto doc = Document.bootstrap(makeCube());

        Layer clip(string name, string path, bool missing) {
            auto l = new Layer;
            l.name = name;
            l.kind = ItemKind.Image;
            l.imageRef() = new ImageData();
            l.imageRef().storedPath = path;
            l.imageRef().missing    = missing;
            if (!missing) { l.imageRef().width = 5; l.imageRef().height = 7; }
            return l;
        }

        auto a = clip("decoy A", "sheet.png", false);
        auto b = clip("target",  "sheet.png", false);
        auto c = clip("decoy C", "sheet.png", false);

        auto p = new Layer;
        p.name = "front";
        p.kind = ItemKind.ImagePlane;
        p.imagePlaneRef() = new ImagePlaneData();

        doc.layers ~= a;      // 1
        doc.layers ~= b;      // 2  <- the target
        doc.layers ~= c;      // 3
        doc.layers ~= p;      // 4
        plane  = p;
        target = b;
        return doc;
    }
}

version (unittest) {
    private bool near(float a, float b, float tol = 1e-4f) {
        import std.math : abs, isFinite;
        return isFinite(a) && isFinite(b) && abs(a - b) <= tol;
    }
    private bool nearV(Vec3 a, Vec3 b, float tol = 1e-4f) {
        return near(a.x, b.x, tol) && near(a.y, b.y, tol) && near(a.z, b.z, tol);
    }
    private string fmtV(Vec3 v) {
        import std.format : format;
        return format("(%.6f, %.6f, %.6f)", v.x, v.y, v.z);
    }

    /// A plane's channels at their defaults, with `projection` overridable.
    private ImagePlaneData planeData(string projection = "front") {
        auto p = new ImagePlaneData();
        p.projection = projection;
        return p;
    }

    /// Resolve with the boilerplate a placement test does not care about:
    /// visible, `Ready`, a Front ortho cell.
    private ImagePlanePlacement place(const ImagePlaneData p, int w, int h,
                                      ItemXform x,
                                      ViewPreset cell = ViewPreset.Front,
                                      bool ortho = true, bool visible = true,
                                      ImagePlaneSource src = ImagePlaneSource.Ready)
    {
        return resolvePlacement(p, visible, w, h, src, "/tmp/fixture.png",
                                cell, ortho, x);
    }
}

unittest {
    import std.format : format;
    auto p = planeData();
    ItemXform x;                       // identity: pos 0, rot 0, scl 1, pivot 0
    auto r = place(p, 512, 256, x);

    assert(nearV(r.halfU, Vec3(2.56f, 0, 0)),
        format("T-P1 halfU: expected (2.56, 0, 0), got %s", fmtV(r.halfU)));
    assert(nearV(r.halfV, Vec3(0, 1.28f, 0)),
        format("T-P1 halfV: expected (0, 1.28, 0), got %s", fmtV(r.halfV)));
    assert(nearV(r.center, Vec3(0, 0, 0)),
        format("T-P1 center: expected the origin, got %s", fmtV(r.center)));
    // Stated in FULL extents too, because that is the unit the measurement is
    // in and the unit a QA pass measures against a cube.
    assert(near(2 * r.halfU.length, 5.12f) && near(2 * r.halfV.length, 2.56f),
        format("T-P1 full extent: expected 5.120000 x 2.560000, got %.6f x %.6f",
               2 * r.halfU.length, 2 * r.halfV.length));
    assert(r.drawn, "T-P1: a Ready, visible plane in its own ortho cell draws");
    assert(r.sourcePath == "/tmp/fixture.png",
        "T-P1: a Ready placement carries the resolved path for the draw to look up");
}

unittest {
    import std.format : format;
    import std.math   : cos, sin, PI;

    auto p = planeData();
    ItemXform x;
    x.pos   = Vec3(1, 2, 3);
    x.rot   = Vec3(0, 0, 30);
    x.scl   = Vec3(2, 3, 1);
    x.pivot = Vec3(0.5f, 0, 0);
    auto r = place(p, 512, 256, x);

    assert(near(r.halfU.length, 5.12f),
        format("T-P2 |halfU|: expected 5.120000 (base 2.56 x min(2,3)=2), got %.6f",
               r.halfU.length));
    assert(near(r.halfV.length, 2.56f),
        format("T-P2 |halfV|: expected 2.560000 (base 1.28 x min(2,3)=2, NOT x3), "
               ~ "got %.6f", r.halfV.length));

    immutable float c = cos(30.0f * PI / 180.0f), s = sin(30.0f * PI / 180.0f);
    // R * pivot, with pivot on +X.
    immutable Vec3 rp = Vec3(0.5f * c, 0.5f * s, 0);
    immutable Vec3 expCenter = Vec3(1 + 0.5f - rp.x, 2 + 0 - rp.y, 3);
    assert(nearV(r.center, expCenter, 1e-3f),
        format("T-P2 center: expected %s (pos + pivot - R*pivot), got %s",
               fmtV(expCenter), fmtV(r.center)));

    immutable Vec3 expHalfU = Vec3( 5.12f * c, 5.12f * s, 0);
    immutable Vec3 expHalfV = Vec3(-2.56f * s, 2.56f * c, 0);
    assert(nearV(r.halfU, expHalfU, 1e-3f),
        format("T-P2 halfU: expected %s, got %s", fmtV(expHalfU), fmtV(r.halfU)));
    assert(nearV(r.halfV, expHalfV, 1e-3f),
        format("T-P2 halfV: expected %s, got %s", fmtV(expHalfV), fmtV(r.halfV)));

    // The four corners, restated from centre ± halves, are what a draw pass
    // consumes — asserted here so a sign error in the fan cannot hide behind
    // two correct magnitudes.
    immutable Vec3 c0 = r.center - r.halfU - r.halfV;
    immutable Vec3 expC0 = expCenter - expHalfU - expHalfV;
    assert(nearV(c0, expC0, 1e-3f),
        format("T-P2 corner0: expected %s, got %s", fmtV(expC0), fmtV(c0)));
}

unittest {
    import std.format : format;
    ItemXform x;
    struct Row { string tok; Vec3 halfU, halfV; }
    immutable Row[6] rows = [
        Row("top",    Vec3( 2.56f, 0, 0),      Vec3(0, 0, -1.28f)),
        Row("bottom", Vec3( 2.56f, 0, 0),      Vec3(0, 0,  1.28f)),
        Row("front",  Vec3( 2.56f, 0, 0),      Vec3(0, 1.28f, 0)),
        Row("back",   Vec3(-2.56f, 0, 0),      Vec3(0, 1.28f, 0)),
        Row("left",   Vec3(0, 0,  2.56f),      Vec3(0, 1.28f, 0)),
        Row("right",  Vec3(0, 0, -2.56f),      Vec3(0, 1.28f, 0)),
    ];
    Vec3[] seenU, seenV;
    foreach (row; rows) {
        auto r = place(planeData(row.tok), 512, 256, x);
        assert(nearV(r.halfU, row.halfU),
            format("T-P3 %s halfU: expected %s, got %s",
                   row.tok, fmtV(row.halfU), fmtV(r.halfU)));
        assert(nearV(r.halfV, row.halfV),
            format("T-P3 %s halfV: expected %s, got %s",
                   row.tok, fmtV(row.halfV), fmtV(r.halfV)));
        foreach (i; 0 .. seenU.length)
            assert(!(nearV(seenU[i], r.halfU) && nearV(seenV[i], r.halfV)),
                format("T-P3 %s: its (halfU, halfV) pair repeats an earlier "
                       ~ "projection's — two axes that draw the same quad", row.tok));
        seenU ~= r.halfU; seenV ~= r.halfV;
    }
}

unittest {
    import std.format : format;
    ItemXform x;
    auto plain   = place(planeData(), 512, 256, x);
    auto flipped = { auto p = planeData(); p.flipHorizontal = true;
                     return place(p, 512, 256, x); }();

    assert(!plain.flipU && flipped.flipU,
        format("T-P4 flipU: expected false then true, got %s then %s",
               plain.flipU, flipped.flipU));
    assert(flipped.halfU == plain.halfU,
        format("T-P4 halfU must be BYTE-IDENTICAL under a flip: %s vs %s",
               fmtV(plain.halfU), fmtV(flipped.halfU)));
    assert(flipped.halfV == plain.halfV && flipped.center == plain.center,
        "T-P4: a flip changes no other placement field");
}

unittest {
    import std.format : format;
    ItemXform x;
    foreach (bad; [ImagePlaneSource.Unbound, ImagePlaneSource.Dangling,
                   ImagePlaneSource.Missing]) {
        auto r = place(planeData(), 512, 256, x, ViewPreset.Front, true, true, bad);
        assert(!r.drawn, format("T-P5 %s must not draw", sourceToken(bad)));
        assert(r.source == bad,
            format("T-P5: the source state must survive to the caller — expected "
                   ~ "%s, got %s", sourceToken(bad), sourceToken(r.source)));
        assert(r.sourcePath.length == 0,
            "T-P5: a non-Ready placement carries no path for the draw to look up");
    }
    auto hidden = place(planeData(), 512, 256, x, ViewPreset.Front, true,
                        /*visible*/ false, ImagePlaneSource.Ready);
    assert(!hidden.drawn, "T-P5 Hidden: an invisible layer does not draw");
    assert(hidden.source == ImagePlaneSource.Ready,
        format("T-P5 Hidden: source must stay 'ready' (hiding is not a source "
               ~ "problem, and the texture stays resident) — got %s",
               sourceToken(hidden.source)));
}

unittest {
    import std.format : format;
    struct Row {
        string label; int w, h; float p, sx, sy, sz; bool keepAspect;
        float extU, extV;
    }
    immutable Row[] table = [
        //     label     W    H     p      sx    sy    sz   keep    extU     extV
        Row("V",   512, 256, 0.010f, 1.0f, 1.0f, 1.0f, false,  2.56f,  2.56f),
        Row("A",   512, 256, 0.020f, 1.0f, 1.0f, 1.0f, false,  5.12f,  5.12f),
        Row("E",   512, 256, 0.005f, 1.0f, 1.0f, 1.0f, false,  1.28f,  1.28f),
        Row("F1",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, false,  2.56f,  2.56f),
        Row("B",   512, 256, 0.010f, 1.0f, 2.0f, 1.0f, false,  2.56f,  5.12f),
        Row("C",   512, 256, 0.010f, 3.0f, 2.0f, 1.0f, false,  7.68f,  5.12f),
        Row("D",   512, 256, 0.010f, 3.0f, 2.0f, 1.0f, true,  10.24f,  5.12f),
        Row("W1",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, true,   5.12f,  2.56f),
        Row("W2",  512, 256, 0.010f, 3.0f, 1.0f, 1.0f, true,   5.12f,  2.56f),
        Row("W3",  512, 256, 0.010f, 1.0f, 3.0f, 1.0f, true,   5.12f,  2.56f),
        Row("W4",  512, 256, 0.010f, 2.0f, 3.0f, 1.0f, true,  10.24f,  5.12f),
        Row("W5",  512, 256, 0.010f, 1.0f, 1.0f, 3.0f, true,   5.12f,  2.56f),
        Row("W7",  512, 256, 0.020f, 1.0f, 1.0f, 1.0f, true,  10.24f,  5.12f),
        Row("W8",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, false,  2.56f,  2.56f),
        Row("T1",  256, 512, 0.010f, 1.0f, 1.0f, 1.0f, true,   2.56f,  5.12f),
        Row("T2",  256, 512, 0.010f, 1.0f, 1.0f, 1.0f, false,  5.12f,  5.12f),
        Row("T3",  256, 512, 0.010f, 3.0f, 1.0f, 1.0f, true,   2.56f,  5.12f),
        Row("T4",  256, 512, 0.010f, 1.0f, 3.0f, 1.0f, true,   2.56f,  5.12f),
        Row("Y0",  512, 256, 0.010f, 1.0f, 1.0f, 1.0f, true,   5.12f,  2.56f),
        Row("X1",  512, 256, 0.010f, 0.5f, 4.0f, 1.0f, true,   2.56f,  1.28f),
        Row("X2",  512, 256, 0.010f, 4.0f, 0.5f, 1.0f, true,   2.56f,  1.28f),
        Row("X3",  512, 256, 0.010f, 1.5f, 2.5f, 1.0f, true,   7.68f,  3.84f),
        Row("X4",  512, 256, 0.010f, 2.0f, 2.0f, 1.0f, true,  10.24f,  5.12f),
        Row("X5",  512, 256, 0.010f, 0.5f, 4.0f, 1.0f, false,  1.28f, 10.24f),
    ];
    foreach (row; table) {
        auto p = planeData();
        p.pixelSize  = row.p;
        p.keepAspect = row.keepAspect;
        ItemXform x;
        x.scl = Vec3(row.sx, row.sy, row.sz);
        auto r = place(p, row.w, row.h, x);
        immutable float gotU = 2 * r.halfU.length, gotV = 2 * r.halfV.length;
        assert(near(gotU, row.extU, 1e-3f) && near(gotV, row.extV, 1e-3f),
            format("T-P7 row %s (%dx%d px, p=%.3f, scl=(%.1f,%.1f,%.1f), keepAspect=%s): "
                   ~ "expected %.6f x %.6f m, got %.6f x %.6f m",
                   row.label, row.w, row.h, row.p, row.sx, row.sy, row.sz,
                   row.keepAspect, row.extU, row.extV, gotU, gotV));
    }
}

unittest {
    import std.format : format;
    auto p = planeData();
    ItemXform unit;
    auto base = place(p, 512, 256, unit);

    foreach (scl; [Vec3(3, 1, 1), Vec3(1, 3, 1)]) {
        ItemXform x; x.scl = scl;
        auto r = place(p, 512, 256, x);
        assert(r.halfU == base.halfU && r.halfV == base.halfV,
            format("T-P8 scl=(%.0f,%.0f,%.0f): the extent must be BYTE-IDENTICAL "
                   ~ "to the unit-scale one (%.6f x %.6f m) — got %.6f x %.6f m. "
                   ~ "If this went red because one axis now enlarges the plane, "
                   ~ "that is not a fix: it is the measured `min(sx, sy)` collapse "
                   ~ "being removed.",
                   scl.x, scl.y, scl.z,
                   2 * base.halfU.length, 2 * base.halfV.length,
                   2 * r.halfU.length,    2 * r.halfV.length));
    }
}

unittest {
    import std.format : format;
    auto p = planeData();
    p.pixelSize = float.nan;
    ItemXform x;
    auto r = place(p, 512, 256, x);
    assert(r.halfU == Vec3(0, 0, 0) && r.halfV == Vec3(0, 0, 0),
        format("a non-finite pixelSize must produce an EMPTY extent, got %s / %s",
               fmtV(r.halfU), fmtV(r.halfV)));
    assert(!r.drawn, "and a plane with no finite size is not drawable");
    assert(r.source == ImagePlaneSource.Ready,
        "but the SOURCE is still fine — a bad number is not a bad file");

    // …and the other door: a non-finite ROTATION reaches the rigid matrix, not
    // the extent formula, so an extents-only gate lets a NaN quad through with
    // perfectly finite half-extents and a NaN centre.
    auto q = planeData();
    ItemXform bad;
    bad.rot = Vec3(0, float.nan, 0);
    auto rr = place(q, 512, 256, bad);
    assert(rr.center == Vec3(0, 0, 0) && rr.halfU == Vec3(0, 0, 0),
        format("a non-finite ROTATION must produce an empty placement, got "
               ~ "center %s halfU %s", fmtV(rr.center), fmtV(rr.halfU)));
    assert(!rr.drawn, "and it is not drawable either");
}

unittest {
    import std.format : format;
    auto p = planeData("right");
    ItemXform x;
    x.scl = Vec3(4, 1, 0.5f);          // the P0-d case
    auto r = place(p, 512, 256, x, ViewPreset.Right);
    // Spanning axes: min(scl.z, scl.y) = min(0.5, 1) = 0.5 -> half size.
    assert(near(2 * r.halfU.length, 2.56f, 1e-3f),
        format("P0-d INTERIM (spanning axes): expected a 2.560000 m u-extent "
               ~ "(min(sz,sy)=0.5), got %.6f. The item-local reading "
               ~ "(min(sx,sy)=1) would read 5.120000.", 2 * r.halfU.length));
}

unittest {
    import std.format : format;
    ItemXform x;
    struct Row { ViewPreset cell; bool ortho; bool drawn; string why; }
    immutable Row[] rows = [
        Row(ViewPreset.Front, true,  true,  "its own cell"),
        Row(ViewPreset.Back,  true,  false, "NOT mirrored into the opposite view"),
        Row(ViewPreset.Top,   true,  false, "not every ortho cell"),
        Row(ViewPreset.Perspective, false, true,  "shown in perspective by default"),
        Row(ViewPreset.Perspective, true,  false, "a free-orbit ORTHO cell matches no axis"),
    ];
    foreach (row; rows) {
        auto r = place(planeData(), 512, 256, x, row.cell, row.ortho);
        assert(r.drawn == row.drawn,
            format("viewport match: a `front` plane in cell %s (ortho=%s) should "
                   ~ "be drawn=%s (%s), got drawn=%s",
                   row.cell, row.ortho, row.drawn, row.why, r.drawn));
    }
    // …and the opt-out is a channel, not a constant.
    auto noPersp = planeData(); noPersp.showInPerspective = false;
    auto rp = place(noPersp, 512, 256, x, ViewPreset.Perspective, false);
    auto rf = place(noPersp, 512, 256, x, ViewPreset.Front, true);
    assert(!rp.drawn, "showInPerspective=false hides it in the perspective cell");
    assert(rf.drawn,  "…and ONLY there — the Front cell still draws it");
}

unittest {
    import std.format : format;
    Layer plane, target;
    auto doc = planeFixture(plane, target);

    ulong epoch = 0;
    ulong h = imagePlaneDigest(doc, epoch);
    void step(string what, void delegate() mutate) {
        mutate();
        immutable ulong now = imagePlaneDigest(doc, epoch);
        assert(now != h,
            format("digest: %s must move the reference-image dirty-key term — "
                   ~ "it stayed 0x%016X, so a cell holding a cached image would "
                   ~ "not repaint", what, h));
        h = now;
    }

    step("binding the clip",        { plane.setLink(kImageLinkSlot, target); });
    step("a pixelSize edit",        { plane.imagePlaneRef().pixelSize = 0.02f; });
    step("a keepAspect toggle",     { plane.imagePlaneRef().keepAspect = false; });
    step("a projection change",     { plane.imagePlaneRef().projection = "right"; });
    step("a showInPerspective toggle",
                                    { plane.imagePlaneRef().showInPerspective = false; });
    step("a brightness edit",       { plane.imagePlaneRef().brightness = 0.25f; });
    step("a contrast edit",         { plane.imagePlaneRef().contrast = -0.5f; });
    step("a transparency edit",     { plane.imagePlaneRef().transparency = 0.5f; });
    step("an invert toggle",        { plane.imagePlaneRef().invert = true; });
    step("a flipHorizontal toggle", { plane.imagePlaneRef().flipHorizontal = true; });
    step("a smooth toggle",         { plane.imagePlaneRef().smooth = true; });
    step("a move",                  { plane.xform.pos   = Vec3(1, 0, 0); });
    step("a rotation",              { plane.xform.rot   = Vec3(0, 0, 15); });
    step("a scale",                 { plane.xform.scl   = Vec3(2, 2, 1); });
    step("a pivot move",            { plane.xform.pivot = Vec3(0.5f, 0, 0); });
    step("hiding the item",         { plane.visible = false; });
    step("a clip resize on disk",   { target.imageRef().width = 99; });
    step("the file going missing",  { target.imageRef().missing = true; });
    step("a texture upload",        { ++epoch; });
    step("clearing the link",       { plane.setLink(kImageLinkSlot, null); });

    // …and the converse: reading it twice with nothing touched must give the
    // same number, or every cell would re-render every frame and the dirty
    // gate would be decoration.
    assert(imagePlaneDigest(doc, epoch) == h,
        "digest: an unchanged document must digest identically — otherwise the "
        ~ "dirty gate never fires and every cell re-renders every frame");
}
