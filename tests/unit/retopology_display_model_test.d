// The retopology display mode as DATA: the per-cell flag, the plan fields it
// owns, the single override `applyRetopology` applied after the style switch,
// `DrawPlan.styleFills` for picking, and the frozen record the constants come
// from (`tests/fixtures/retopology_display.json`). Nothing here draws; the
// renderer does not read the new fields yet, so no assertion below is about
// pixels.
//
// Cells run in this order, and the order is part of the design: a mutation
// meant for a later cell must first clear every earlier one, so each red
// line also certifies the cells above it.
//   1a  fixture reader — every constant equals its record, and every frozen
//       pixel cell satisfies its blend identity (a mistyped cell reddens);
//   1b  style irrelevance under the mode (4 styles x 2 overlays);
//   1c  mode-off neutrality against LITERALS (not `DrawPlan.init`, which
//       would move with the defaults it is meant to judge);
//   1d  the backdrop plan under the mode = mode-off plus the light gain;
//   1e  under the mode `drawVerts` follows show-vertices, not the style;
//   1f  picking occlusion follows the STYLE under the mode (captured runs);
//   1g  the mode's own values, field by field, against literals.
//
// LANE: `dub test --config=tests`.
module tests.unit.retopology_display_model_test;

import std.conv      : to;
import std.file      : readText;
import std.format    : format;
import std.json      : JSONType, JSONValue, parseJSON;
import std.math      : abs;
import std.path      : buildPath, dirName;
import std.string    : split;

import display_state : BackdropStyle, DisplayStyle, DrawPlan, SurfaceShading,
                       ViewportDisplay, WireOverlay, applyRetopology,
                       resolveDrawPlan;
import select_visibility : SelectVisibility, resolveSelectVisibility;
import viewport_scheme : SchemeColor, schemeColor, kBasePointSize,
                         kRetopologyFillTransparency, kRetopologyLineAlpha,
                         kRetopologyLightGain, kRetopologyVertexCulling,
                         kRetopologyPresetPointSize;

private enum string kFixturePath =
    buildPath(dirName(dirName(__FILE_FULL_PATH__)), "fixtures",
              "retopology_display.json");

private JSONValue fixture()
{
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) { cached = parseJSON(readText(kFixturePath)); loaded = true; }
    return cached;
}

private double num(JSONValue v)
{
    switch (v.type)
    {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private double[3] triple(JSONValue v)
{
    assert(v.type == JSONType.array && v.array.length == 3,
        "fixture: expected a 3-element array, got " ~ v.toString);
    return [num(v.array[0]), num(v.array[1]), num(v.array[2])];
}

private static immutable DisplayStyle[4] kStyles = [
    DisplayStyle.Wireframe, DisplayStyle.Solid,
    DisplayStyle.Shaded,    DisplayStyle.Weight,
];
private static immutable WireOverlay[2] kOverlays = [
    WireOverlay.None, WireOverlay.Uniform,
];
private static immutable BackdropStyle[4] kBackdrops = [
    BackdropStyle.SameAsActive, BackdropStyle.Wireframe,
    BackdropStyle.Flat,         BackdropStyle.Hidden,
];

// Float equality for a value that went through the same float expression on
// both sides (a literal vs a constant): exact up to float rounding.
private bool feq(double a, double b) { return abs(a - b) <= 1e-6; }

// ---------------------------------------------------------------------------
// 1a. The fixture reader.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    assert(fx["name"].str == "retopology_display", "wrong fixture loaded");

    int n = 0;   // constant rows compared

    void colourRow(string key, SchemeColor role) {
        immutable want = triple(fx[key]["colour"]);
        immutable got  = schemeColor(role);
        assert(feq(got.x, want[0]) && feq(got.y, want[1]) && feq(got.z, want[2]),
            format("1a: SchemeColor.%s = (%s,%s,%s) but the record says %s",
                   role, got.x, got.y, got.z, want));
        ++n;
    }
    colourRow("face",   SchemeColor.retopologyFace);
    colourRow("edge",   SchemeColor.retopologyEdge);
    colourRow("vertex", SchemeColor.retopologyVertex);

    assert(feq(kRetopologyFillTransparency, num(fx["face"]["fill_transparency"])),
        format("1a: kRetopologyFillTransparency = %s, record %s",
               kRetopologyFillTransparency, fx["face"]["fill_transparency"]));
    ++n;

    // ONE literal for the edges and the dots: both records must equal it.
    assert(feq(kRetopologyLineAlpha, num(fx["edge"]["alpha"]))
        && feq(kRetopologyLineAlpha, num(fx["vertex"]["alpha"])),
        format("1a: kRetopologyLineAlpha = %s, record edge %s / vertex %s",
               kRetopologyLineAlpha, fx["edge"]["alpha"], fx["vertex"]["alpha"]));
    ++n;

    {
        auto parts = fx["light_gain"]["value"].str.split("/");
        assert(parts.length == 2, "1a: light_gain.value must be 'a/b'");
        immutable double g = parts[0].to!double / parts[1].to!double;
        assert(feq(kRetopologyLightGain, g),
            format("1a: kRetopologyLightGain = %.9g, record %s = %.9g",
                   kRetopologyLightGain, fx["light_gain"]["value"].str, g));
        ++n;
    }

    assert(kRetopologyVertexCulling == (fx["vertex"]["culling"].type == JSONType.true_),
        "1a: kRetopologyVertexCulling disagrees with vertex.culling");
    ++n;

    assert(feq(kRetopologyPresetPointSize, num(fx["vertex"]["preset_point_size"])),
        format("1a: kRetopologyPresetPointSize = %s, record %s",
               kRetopologyPresetPointSize, fx["vertex"]["preset_point_size"]));
    ++n;

    assert(feq(kBasePointSize, num(fx["vertex"]["point_size"])),
        format("1a: kBasePointSize = %s, record vertex.point_size %s",
               kBasePointSize, fx["vertex"]["point_size"]));
    ++n;

    assert(n == 9, format("1a: compared %s constant rows, expected 9", n));

    // Blend identities of the frozen cells: out = a*c + (1-a)*under, per
    // channel. TOLERANCE, derived: `out` is an 8-bit read (+-0.5), `under`
    // is too and enters scaled by (1-a) <= 0.8 (+-0.4); the unblended `c` is
    // recorded to half an LSB and enters scaled by a <= 0.4 in the widest
    // case (+-0.1). Sum 1.0. This checks the RECORD's arithmetic, so a
    // mistyped cell or a wrong alpha law reddens here.
    enum double tol = 0.5 + 0.8 * 0.5 + 0.4 * 0.25;
    int channels = 0;
    void blend(string what, double a, double[3] c, JSONValue cell) {
        immutable u = triple(cell["under"]);
        immutable o = triple(cell["out"]);
        foreach (k; 0 .. 3) {
            immutable double pred = a * c[k] + (1.0 - a) * u[k];
            assert(abs(pred - o[k]) <= tol,
                format("1a: %s cell %s channel %s: predicted %.2f from a=%s, "
                       ~ "read %s (tolerance %.2f)", what, cell, k, pred, a,
                       o[k], tol));
            ++channels;
        }
    }
    {
        immutable double c = num(fx["face"]["unblended_front_facing"]);
        foreach (cell; fx["face"]["cells_alpha"].array)
            blend("face", 1.0 - num(cell["fill_transparency"]), [c, c, c], cell);
    }
    foreach (cell; fx["edge"]["cells"].array)
        blend("edge", kRetopologyLineAlpha,
              triple(fx["edge"]["unblended_front_view"]), cell);
    foreach (cell; fx["vertex"]["cells"].array)
        blend("vertex", kRetopologyLineAlpha,
              triple(fx["vertex"]["unblended_front_view"]), cell);
    foreach (cell; fx["selection"]["cells"].array)
        blend("occluded selection", num(fx["selection"]["occluded_alpha"]),
              triple(fx["selection"]["colour"]), cell);
    // 5 face + 3 edge + 3 vertex + 2 selection cells, three channels each.
    assert(channels == 39,
        format("1a: blend identities checked %s channels, expected 39", channels));
}

// ---------------------------------------------------------------------------
// 1b. Style irrelevance: under the mode the active plan is the same for every
//     style and overlay — except `styleFills`, which is DEFINED as the
//     style's answer (1f); it is compared separately and masked here.
// ---------------------------------------------------------------------------
unittest {
    DrawPlan first;
    bool have = false;
    int k = 0;
    foreach (s; kStyles) foreach (w; kOverlays) {
        ViewportDisplay d;
        d.retopology   = true;
        d.active.style = s;
        d.active.wire  = w;
        DrawPlan p = resolveDrawPlan(d, false);
        assert(p.styleFills == (s != DisplayStyle.Wireframe),
            format("1b: styleFills under the mode must stay the style's (%s)", s));
        p.styleFills = true;
        if (!have) { first = p; have = true; }
        assert(p == first,
            format("1b: under the mode the active plan for %s/%s differs from "
                   ~ "%s/%s:\n  %s\n  %s", s, w, kStyles[0], kOverlays[0], p, first));
        ++k;
    }
    assert(k == 8, format("1b: compared %s style/overlay rows, expected 8", k));
}

// ---------------------------------------------------------------------------
// 1c. Mode-off neutrality, against literals.
// ---------------------------------------------------------------------------
unittest {
    // 20 stored fields (plus the derived `facesLit`): the endpoint dump and
    // `tests/test_viewport_display.d` B2 list exactly these, so a field added
    // without joining them fails here first.
    static assert(DrawPlan.tupleof.length == 20,
        "DrawPlan field count changed: extend 1c, the plan dump and B2");
    ViewportDisplay d;
    assert(!d.retopology, "1c: the mode must be off by default");
    assert(!d.active.showVertices && d.active.pointSize == 0.0f,
        "1c: show-vertices off and point size 'default' (0) by default");

    int checkCommon(in DrawPlan p, string side) {
        int k = 0;
        assert(p.faceAlpha == 1.0f,       side ~ ": faceAlpha must be 1.0");        ++k;
        assert(p.cullBackFaces == false,  side ~ ": cullBackFaces must be false");  ++k;
        assert(p.clearDepthFirst == false, side ~ ": clearDepthFirst must be false"); ++k;
        assert(p.lightGain == 1.0f,       side ~ ": lightGain must be 1.0");        ++k;
        assert(p.vertAlpha == 1.0f,       side ~ ": vertAlpha must be 1.0");        ++k;
        assert(p.pointSize == 3.0f,       side ~ ": pointSize must be 3.0");        ++k;
        assert(p.cullHiddenVerts == false, side ~ ": cullHiddenVerts must be false"); ++k;
        assert(p.vertColor == [0.72f, 0.72f, 0.72f],
            format("%s: vertColor must be the wireframe row [0.72,0.72,0.72], got %s",
                   side, p.vertColor));                                              ++k;
        assert(p.shadeLinesByItem == false, side ~ ": shadeLinesByItem must be false"); ++k;
        assert(p.baseDotsBySelection == true, side ~ ": baseDotsBySelection must be true"); ++k;
        assert(p.joinsItemSequence == false, side ~ ": joinsItemSequence must be false"); ++k;
        return k;
    }

    immutable DrawPlan a = resolveDrawPlan(d, false);
    immutable int ka = checkCommon(a, "1c active");
    assert(ka == 11, format("1c: asserted %s active fields, expected 11", ka));

    immutable DrawPlan b = resolveDrawPlan(d, true);
    int kb = checkCommon(b, "1c backdrop");
    assert(b.dim == 0.45f, format("1c backdrop: dim must be 0.45, got %s", b.dim));
    ++kb;
    assert(kb == 12, format("1c: asserted %s backdrop fields, expected 12", kb));
}

// ---------------------------------------------------------------------------
// 1d. The backdrop under the mode: exactly the mode-off plan plus the gain,
//     for every coarse backdrop setting and every active style.
// ---------------------------------------------------------------------------
unittest {
    int k = 0;
    foreach (bs; kBackdrops) foreach (s; kStyles) {
        ViewportDisplay off;
        off.backdropStyle = bs;
        off.active.style  = s;
        ViewportDisplay on = off;
        on.retopology = true;

        DrawPlan want = resolveDrawPlan(off, true);
        want.lightGain = 5.0f / 3.0f;
        immutable DrawPlan got = resolveDrawPlan(on, true);
        assert(got == want,
            format("1d: backdrop %s / style %s under the mode must be the "
                   ~ "mode-off plan with lightGain 5/3:\n  got  %s\n  want %s",
                   bs, s, got, want));
        ++k;
    }
    assert(k == 16, format("1d: compared %s backdrop rows, expected 16", k));
}

// ---------------------------------------------------------------------------
// 1e. Under the mode vertex dots follow show-vertices and NOT the style.
//     Mode off, the wireframe style forces them — which is what makes the
//     mode-on rows discriminate.
// ---------------------------------------------------------------------------
unittest {
    {
        ViewportDisplay d;
        d.active.style = DisplayStyle.Wireframe;
        assert(resolveDrawPlan(d, false).drawVerts,
            "1e control: mode off, the wireframe style forces the dots");
    }
    int k = 0;
    foreach (s; kStyles) foreach (sv; [false, true]) {
        ViewportDisplay d;
        d.retopology          = true;
        d.active.style        = s;
        d.active.showVertices = sv;
        immutable p = resolveDrawPlan(d, false);
        assert(p.drawVerts == sv,
            format("1e: under the mode, style %s with showVertices=%s must "
                   ~ "give drawVerts=%s, got %s", s, sv, sv, p.drawVerts));
        ++k;
    }
    assert(k == 8, format("1e: compared %s rows, expected 8", k));
}

// ---------------------------------------------------------------------------
// 1f. Picking under the mode: the four captured runs. Occlusion (the vertex
//     behind the item's own face is NOT picked) follows the active style,
//     mode on or off — although the mode fills faces in every style, so a
//     resolver reading `drawFaces` would occlude the wireframe run.
// ---------------------------------------------------------------------------
unittest {
    auto runs = fixture()["picking_runs"].array;
    int k = 0;
    foreach (r; runs) {
        ViewportDisplay d;
        d.retopology = r["mode"].type == JSONType.true_;
        immutable string st = r["style"].str;
        assert(st == "wireframe" || st == "shaded", "1f: unknown style " ~ st);
        d.active.style = st == "wireframe" ? DisplayStyle.Wireframe
                                           : DisplayStyle.Shaded;
        immutable bool picked = r["picked_behind_own_face"].type == JSONType.true_;
        immutable p = resolveDrawPlan(d, false);
        immutable t = resolveSelectVisibility(SelectVisibility.StyleAware, p);
        assert(t.occlusionTerm == !picked,
            format("1f: mode=%s style=%s: captured picked=%s, so occlusion "
                   ~ "must be %s; got %s (drawFaces=%s styleFills=%s)",
                   d.retopology, st, picked, !picked, t.occlusionTerm,
                   p.drawFaces, p.styleFills));
        ++k;
    }
    assert(k == 4, format("1f: replayed %s picking runs, expected 4", k));
}

// ---------------------------------------------------------------------------
// 1g. The mode's own representation, field by field, against literals.
// ---------------------------------------------------------------------------
unittest {
    ViewportDisplay d;
    d.retopology = true;
    immutable DrawPlan p = resolveDrawPlan(d, false);
    int k = 0;
    assert(p.drawFaces,                                  "1g: drawFaces");       ++k;
    assert(p.shading == SurfaceShading.Retopology,       "1g: shading");         ++k;
    assert(p.fillColor == [0.2f, 0.2f, 0.2f],
        format("1g: fillColor %s", p.fillColor));                                ++k;
    assert(p.faceAlpha == 0.5f, format("1g: faceAlpha %s", p.faceAlpha));        ++k;
    assert(p.cullBackFaces,                              "1g: cullBackFaces");   ++k;
    assert(p.clearDepthFirst,                            "1g: clearDepthFirst"); ++k;
    assert(p.lightGain == 5.0f / 3.0f, format("1g: lightGain %s", p.lightGain)); ++k;
    assert(p.drawWire,                                   "1g: drawWire");        ++k;
    assert(p.wireColor == [0.11f, 0.25f, 0.41f],
        format("1g: wireColor %s (the UNSHADED edge palette)", p.wireColor));    ++k;
    assert(p.wireAlpha == 0.4f, format("1g: wireAlpha %s", p.wireAlpha));        ++k;
    assert(p.vertColor == [0.38f, 0.62f, 0.92f],
        format("1g: vertColor %s (the UNSHADED vertex palette)", p.vertColor));  ++k;
    assert(p.vertAlpha == 0.4f, format("1g: vertAlpha %s", p.vertAlpha));        ++k;
    assert(p.pointSize == 3.0f, format("1g: pointSize %s", p.pointSize));        ++k;
    assert(p.cullHiddenVerts,                            "1g: cullHiddenVerts"); ++k;
    assert(p.shadeLinesByItem,                           "1g: shadeLinesByItem"); ++k;
    assert(!p.baseDotsBySelection,                    "1g: baseDotsBySelection"); ++k;
    assert(!p.joinsItemSequence,                     "1g: joinsItemSequence");  ++k;
    assert(!p.facesLit,
        "1g: facesLit must stay false — the retopology arm is not the material arm"); ++k;
    assert(p.dim == 1.0f, format("1g: dim %s", p.dim));                          ++k;
    assert(k == 19, format("1g: asserted %s fields, expected 19", k));

    // A set point size resolves through, under the mode as outside it; a
    // non-positive or non-finite one falls back to the base size.
    foreach (ps; [6.0f, 0.0f, -2.0f, float.nan, float.infinity]) {
        ViewportDisplay e;
        e.retopology       = true;
        e.active.pointSize = ps;
        immutable float want = (ps == 6.0f) ? 6.0f : 3.0f;
        assert(resolveDrawPlan(e, false).pointSize == want,
            format("1g: pointSize %s must resolve to %s", ps, want));
    }

    // Off: a no-op, whatever the plan it is handed.
    DrawPlan q;
    q.lightGain = 0.25f;
    applyRetopology(q, ViewportDisplay.init, false);
    assert(q.lightGain == 0.25f && q.shading == SurfaceShading.Material,
        "1g: applyRetopology with the mode off must leave the plan untouched");
}
