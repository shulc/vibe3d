// test_retopology_backdrop.d — the backdrop representation control, the
// retopology display mode's light gain on the backdrop and its face arm,
// driven through the per-cell commands and read back as pixels.
//
// What is pinned, and why each rig can tell the candidates apart:
//   * the backdrop control is a WRITER of the backdrop display slot and the
//     renderer reads the slot (frozen record
//     `tests/fixtures/backdrop_display_slots.json`, `coarse_control`), so the
//     slot is written the OTHER way first and the control must overwrite it;
//   * `Flat` is a LIT faceted surface and is not dimmed: three tiles with
//     three normals give three values, and the +Z tile equals itself drawn as
//     the primary (no dim), with the dimmed same-as-active control below;
//   * the gain multiplies only what is above ambient: `on = A + g(off - A)`
//     with `A = ambient * base * 255` — affine, so a gain on ambient too
//     misses it;
//   * the retopology face arm is LIT by the same function as the backdrop:
//     `fg / face = tile / base` for two +Z polygons, not the weight neutral.
//
// Rig: OPEN quads, no cube. Layer 0 (background) carries three tiles — +Z,
// rotX -30 deg, rotY +30 deg — and layer 1 (the primary) one small +Z quad
// away from them. Front orthographic camera in a single cell. Every "under"
// value is PROBED with the background layer hidden, never typed.
//
// TOLERANCES are derived from 8-bit quantisation (+-0.5 LSB per read value,
// propagated through each formula) and printed beside the reading.
module test_retopology_backdrop;

import http_client : getJson, postJson, quiesce, frameFence;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, projectToWindow,
                      Viewport, DHVec3 = Vec3;
import http_client : waitPlaybackProcessed;
import std.json;
import std.format : format;
import std.math : abs, round, cos, sin, sqrt, pow, PI;
import std.algorithm : max;
import std.stdio : writeln, writefln;

void main() {}

// ---------------------------------------------------------------------------
// The light rig's ambient, typed ONCE (source/light_rig.d, task 9130: global
// ambient 0.15 × Kd, not scaled by the gain). Neither lit arm this rig draws
// carries a specular term — the Retopology arm has none and the default
// material's specular amount is 0 — so every relation below is spec-free.
// The gain law is a relation evaluated on our rig.
// ---------------------------------------------------------------------------
private enum double kAmbient  = 0.15;
/// The measured gain (fixture `retopology_display.json` light_gain 5/3).
private enum double kGain = 5.0 / 3.0;
/// The retopology face colour (scheme row; fixture face.colour 0.2).
private enum double kFace = 0.2;

private void settle() { quiesce(); frameFence(null, 2); }

private JSONValue cmdRaw(string body) { return postJson("/api/command", body); }

private void cmdOk(string body) {
    auto r = cmdRaw(body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ body ~ " -> " ~ r.toString);
}

private void cmdRefused(string body, string why) {
    auto r = cmdRaw(body);
    assert(r["status"].str == "error",
        "command must be refused (" ~ why ~ "): " ~ body ~ " -> " ~ r.toString);
}

private void cmd(string id, string params) { cmdOk(commandBody(id, params)); settle(); }

private JSONValue cell0() { return getJson("/api/viewport/display")["cells"].array[0]; }

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "expected a number, got " ~ v.toString);
    }
}

private bool jb(JSONValue v) {
    assert(v.type == JSONType.true_ || v.type == JSONType.false_,
        "expected a bool, got " ~ v.toString);
    return v.type == JSONType.true_;
}

// ---------------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------------
private enum double kHalf = 0.6;          // tile half-size (world units)
private immutable double[3][3] kTileCentre = [[-2.3, 0.7, 0], [0.3, 0.7, 0], [2.3, 0.7, 0]];
private immutable double[3] kFgCentre = [0.3, -1.6, 0];
private enum double kFgHalf = 0.35;

// Rotation of a local point about its tile centre: 0 identity, 1 rotX -30,
// 2 rotY +30 (degrees). The normals are then (0,0,1), (0,0.5,0.866) and
// (0.5,0,0.866).
private double[3] rot(int kind, double[3] p) {
    immutable a = 30.0 * PI / 180.0;
    if (kind == 1) {        // rotX(-30)
        immutable c = cos(-a), s = sin(-a);
        return [p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c];
    }
    if (kind == 2) {        // rotY(+30)
        immutable c = cos(a), s = sin(a);
        return [p[0] * c + p[2] * s, p[1], -p[0] * s + p[2] * c];
    }
    return p;
}

private double[3] tileNormal(int kind) { return rot(kind, [0.0, 0.0, 1.0]); }

private JSONValue quadMesh(double[3][] centres, int[] kinds, double half) {
    JSONValue[] verts, faces;
    foreach (i, c; centres) {
        immutable double[2][4] corners = [[-half, -half], [half, -half],
                                          [half, half], [-half, half]];
        long[] f;
        foreach (k; corners) {
            auto p = rot(kinds[i], [k[0], k[1], 0.0]);
            verts ~= JSONValue([p[0] + c[0], p[1] + c[1], p[2] + c[2]]);
            f ~= cast(long)(verts.length - 1);
        }
        faces ~= JSONValue(f);
    }
    return JSONValue(["vertices": JSONValue(verts), "faces": JSONValue(faces)]);
}

private struct Rig {
    int[2][3] tilePx;
    int[2]    fgPx;
    double    base;          // layer 0's material base (grey)
    double[3] eye;
    Viewport  vp;            // the cell's render viewport (window offsets)
}

private int[2] toPx(double[3] w, ref Viewport vp) {
    float px, py;
    assert(projectToWindow(DHVec3(cast(float) w[0], cast(float) w[1], cast(float) w[2]),
                           vp, px, py), "rig point projects behind the camera");
    return [cast(int) round(px) - vp.x, cast(int) round(py) - vp.y];
}

private Rig buildRig() {
    cmdOk(commandBody("scene.reset"));
    cmdOk(`{"id":"history.clear"}`);
    cmdOk(commandBody("viewport.layout", `"Single"`));

    double[3][] tiles = [kTileCentre[0], kTileCentre[1], kTileCentre[2]];
    cmdOk(commandBody("scene.loadMesh", quadMesh(tiles, [0, 1, 2], kHalf).toString));
    cmdOk(`{"id":"layer.add"}`);
    cmdOk(commandBody("scene.loadMesh", quadMesh([kFgCentre], [0], kFgHalf).toString));
    // The camera AFTER the loads: a raw mesh load re-frames the view.
    cmdOk("viewport.view Front");
    settle();
    auto cr = postJson("/api/camera?viewport=0",
        `{"focus":{"x":0,"y":0,"z":0},"distance":9}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    cmd("viewport.displayStyle", `{"value":"shaded"}`);
    settle();

    auto L = getJson("/api/layers");
    auto layers = L["layers"].array;
    assert(layers.length == 2, "rig: expected two layers, got " ~ L.toString);
    assert(L["active"].integer == 1, "rig: layer 1 must be the primary: " ~ L.toString);
    assert(jb(layers[0]["visible"]) && !jb(layers[0]["primary"]),
        "rig: layer 0 must be a visible background layer: " ~ L.toString);

    Rig r;
    // The base the backdrop's face pass reads: slot 0 of the layer's surfaces,
    // or the lit program's own 0.8 fallback for an empty list.
    auto s0 = getJson("/api/model?layer=0")["surfaces"].array;
    if (s0.length == 0) r.base = 0.8;
    else {
        auto bc = s0[0]["baseColor"].array;
        assert(num(bc[0]) == num(bc[1]) && num(bc[1]) == num(bc[2]),
            "rig: expected a grey base colour, got " ~ s0[0].toString);
        r.base = num(bc[0]);
    }

    auto cam = getJson("/api/camera?viewport=0");
    assert(cam["projKind"].str != "Perspective" && cam["viewPreset"].str == "Front",
        "rig: the cell must be in the orthographic Front view: " ~ cam.toString);
    auto vp = viewportFromCameraMatrices();
    assert(vp.proj[15] != 0.0f, "rig: the Front view must be orthographic: " ~ cam.toString);
    r.eye = [vp.eye.x, vp.eye.y, vp.eye.z];
    r.vp  = vp;
    foreach (i; 0 .. 3) r.tilePx[i] = toPx(kTileCentre[i], vp);
    r.fgPx = toPx(kFgCentre, vp);
    // The probed pixel must be well inside each polygon: measure the
    // projected half-extent of the smaller (foreground) quad.
    auto edgePx = toPx([kFgCentre[0] + kFgHalf, kFgCentre[1], 0.0], vp);
    immutable int halfPx = abs(edgePx[0] - r.fgPx[0]);
    assert(halfPx >= 8, format("rig: the foreground quad is only %d px across "
        ~ "its half; the centre probe would touch its edges", halfPx));
    return r;
}

private struct Px { int[3] c; }

private Px[] probe(int[2][] pts) {
    string q = "/api/viewport/probe?cell=0&points=";
    foreach (k, p; pts) q ~= format("%s%d,%d", k ? ";" : "", p[0], p[1]);
    auto j = getJson(q);
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(jb(j["renders"]), "the probed cell is not rendered; every reading is void");
    Px[] o;
    foreach (e; j["points"].array) {
        assert("error" !in e, "probe point unreadable: " ~ e.toString);
        o ~= Px([cast(int) e["r"].integer, cast(int) e["g"].integer,
                 cast(int) e["b"].integer]);
    }
    assert(o.length == pts.length);
    return o;
}

private Px[] tiles(ref Rig r) { return probe([r.tilePx[0], r.tilePx[1], r.tilePx[2]]); }

private int maxDiff(Px a, Px b) {
    int m = 0;
    foreach (k; 0 .. 3) m = max(m, abs(a.c[k] - b.c[k]));
    return m;
}

// ---------------------------------------------------------------------------
// The whole flow. One block because every cell reads the rig the one before
// it left; each step names the cell it is.
// ---------------------------------------------------------------------------
unittest {
    auto r = buildRig();
    scope (exit) {
        cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
        cmdRaw(commandBody("viewport.backdropStyle", `{"value":"same"}`));
        cmdRaw(commandBody("viewport.displayStyle", `{"value":"shaded","slot":1}`));
        cmdRaw("viewport.view Perspective");
    }

    // ---- under values: the background layer hidden ------------------------
    cmd("layer.setVisible", `{"index":0,"value":false}`);
    auto under = tiles(r);
    cmd("layer.setVisible", `{"index":0,"value":true}`);

    // ---- E: the first mode-on endpoint cell (all thirteen new plan keys) ---
    // Wireframe + mode ON is the one state where `styleFills` (false: the
    // style) and `drawFaces` (true: the mode) differ, so a dump that printed
    // one for the other reddens here.
    cmd("viewport.displayStyle", `{"value":"wireframe"}`);
    cmd("viewport.retopology", `{"value":"on"}`);
    {
        auto c = cell0();
        assert(jb(c["state"]["retopology"]), "E: state.retopology must be true");
        auto a = c["plan"]["active"];
        int k = 0;
        assert(jb(a["drawFaces"]), "E: the mode draws faces in every style");
        assert(!jb(a["styleFills"]),
            "E: styleFills must stay the WIREFRAME style's false: " ~ a.toString);   ++k;
        assert(num(a["faceAlpha"]) == 0.5, "E: faceAlpha " ~ a.toString);           ++k;
        assert(jb(a["cullBackFaces"]), "E: cullBackFaces");                         ++k;
        assert(jb(a["reverseFaceOrder"]), "E: reverseFaceOrder");                   ++k;
        assert(jb(a["clearDepthFirst"]), "E: clearDepthFirst");                     ++k;
        assert(abs(num(a["lightGain"]) - kGain) < 1e-6, "E: lightGain " ~ a.toString); ++k;
        {
            auto vc = a["vertColor"].array;
            assert(abs(num(vc[0]) - 0.38) < 1e-6 && abs(num(vc[1]) - 0.62) < 1e-6
                && abs(num(vc[2]) - 0.92) < 1e-6, "E: vertColor " ~ a.toString);
        }                                                                            ++k;
        assert(num(a["vertAlpha"]) == 0.4 || abs(num(a["vertAlpha"]) - 0.4) < 1e-6,
            "E: vertAlpha " ~ a.toString);                                           ++k;
        assert(num(a["pointSize"]) == 3.0, "E: pointSize " ~ a.toString);           ++k;
        assert(jb(a["cullHiddenVerts"]), "E: cullHiddenVerts");                     ++k;
        assert(jb(a["shadeLinesByItem"]), "E: shadeLinesByItem");                   ++k;
        assert(!jb(a["baseDotsBySelection"]), "E: baseDotsBySelection");            ++k;
        assert(!jb(a["joinsItemSequence"]), "E: the active plan joins nothing");    ++k;
        assert(k == 13, format("E: asserted %s new plan keys, expected 13", k));

        auto b = c["plan"]["backdrop"];
        assert(jb(b["joinsItemSequence"]),
            "E: mode on + same-as-active: the backdrop joins the item sequence");
        assert(num(b["dim"]) == 1.0, "E: D6 — the joined backdrop is undimmed: " ~ b.toString);
        assert(!jb(b["clearDepthFirst"]), "E: the joined backdrop has no clear of its own");
        assert(abs(num(b["lightGain"]) - kGain) < 1e-6, "E: backdrop gain " ~ b.toString);
    }
    cmd("viewport.retopology", `{"value":"off"}`);
    {
        auto c = cell0();
        assert(!jb(c["state"]["retopology"]), "E: 'off' must clear the mode");
        assert(abs(num(c["plan"]["backdrop"]["dim"]) - 0.45) < 1e-6,
            "E: D6 — mode off keeps the 0.45 same-as-active dim");
    }
    cmd("viewport.displayStyle", `{"value":"shaded"}`);

    // ---- A1: the Flat control writes a SHADED slot — lit, three values -----
    // The slot is set to wireframe FIRST, so a control that forgot to write
    // it would leave the tiles unfilled.
    cmd("viewport.displayStyle", `{"value":"wireframe","slot":1}`);
    assert(cell0()["state"]["backdrop"]["style"].str == "Wireframe",
        "A1: displayStyle slot=1 must write the backdrop slot");
    assert(cell0()["state"]["active"]["style"].str == "Shaded",
        "A1: displayStyle slot=1 must leave the active slot alone");
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    {
        auto c = cell0();
        assert(c["state"]["backdropStyle"].str == "Flat", "A1: backdropStyle " ~ c.toString);
        assert(c["state"]["backdrop"]["style"].str == "Shaded",
            "A1: 'flat' must write Shaded into the backdrop slot");
    }
    auto flatOff = tiles(r);
    writefln("  A1 flat tiles %s %s %s (under %s %s %s)",
        flatOff[0].c, flatOff[1].c, flatOff[2].c, under[0].c, under[1].c, under[2].c);
    {
        // A flat (unlit) fill gives identical integers on all three; a lit
        // surface gives three values. 3 LSB is more than two roundings can
        // separate identical inputs by (1 LSB).
        int pairs = 0;
        foreach (i; 0 .. 3) foreach (j; i + 1 .. 3) {
            assert(maxDiff(flatOff[i], flatOff[j]) >= 3,
                format("A1: tiles %d and %d read %s / %s — a lit faceted backdrop "
                       ~ "gives each normal its own value", i, j,
                       flatOff[i].c, flatOff[j].c));
            ++pairs;
        }
        assert(pairs == 3);
        foreach (i; 0 .. 3)
            assert(maxDiff(flatOff[i], under[i]) >= 3,
                format("A1: tile %d reads its under value %s — nothing was drawn",
                       i, under[i].c));
    }

    // ---- A2: the renderer reads the slot: solid slot = unlit fill 153 ------
    cmd("viewport.displayStyle", `{"value":"solid","slot":1}`);
    {
        auto t = tiles(r);
        // round(255 * 0.6) = 153 exactly; one rounding of the fill, +-1.
        foreach (i; 0 .. 3) foreach (k; 0 .. 3)
            assert(abs(t[i].c[k] - 153) <= 1,
                format("A2: tile %d channel %d reads %d; a Solid slot under Flat is "
                       ~ "the unlit 0.6 fill (153 +-1)", i, k, t[i].c[k]));
        assert(t[0] == t[1] && t[1] == t[2],
            format("A2: an unlit fill has no per-tile term, got %s %s %s",
                   t[0].c, t[1].c, t[2].c));
    }

    // ---- A1w: the Wireframe control writes the slot — lines only ----------
    cmd("viewport.displayStyle", `{"value":"shaded","slot":1}`);
    cmd("viewport.backdropStyle", `{"value":"wireframe"}`);
    assert(cell0()["state"]["backdrop"]["style"].str == "Wireframe",
        "A1w: 'wireframe' must write Wireframe into the backdrop slot");
    {
        auto t = tiles(r);
        // Same pixel, same draws as the hidden-layer read: +-1.
        foreach (i; 0 .. 3)
            assert(maxDiff(t[i], under[i]) <= 1,
                format("A1w: tile %d interior reads %s, under %s — a wireframe "
                       ~ "backdrop draws no fill", i, t[i].c, under[i].c));
    }

    // ---- Hidden: nothing drawn ---------------------------------------------
    cmd("viewport.backdropStyle", `{"value":"hidden"}`);
    assert(cell0()["state"]["backdropStyle"].str == "Hidden");
    {
        auto t = tiles(r);
        foreach (i; 0 .. 3)
            assert(maxDiff(t[i], under[i]) <= 1,
                format("Hidden: tile %d reads %s, under %s", i, t[i].c, under[i].c));
    }

    // ---- A3: Flat is undimmed — equal to the same tile as the primary ------
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    auto flat2 = tiles(r);
    cmd("layer.select", `{"index":0,"mode":"set"}`);
    assert(getJson("/api/layers")["active"].integer == 0, "A3: layer 0 must be primary");
    immutable Px asPrimary = tiles(r)[0];
    cmd("layer.select", `{"index":1,"mode":"set"}`);
    assert(getJson("/api/layers")["active"].integer == 1, "A3: layer 1 must be primary again");
    // Same shader, same inputs: +-1 covers only rounding.
    assert(maxDiff(flat2[0], asPrimary) <= 1,
        format("A3: the +Z tile reads %s under Flat and %s as the primary — a "
               ~ "Flat backdrop is not dimmed", flat2[0].c, asPrimary.c));
    // Control, ordered below: same-as-active is dimmed by 0.45. The dim scales
    // a value that was itself rounded (+-0.5 * 0.45) and is rounded again
    // (+-0.5): 0.725, so +-1.
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    {
        immutable Px d = tiles(r)[0];
        foreach (k; 0 .. 3)
            assert(abs(d.c[k] - round(0.45 * asPrimary.c[k])) <= 1,
                format("A3 control: same-as-active reads %s, predicted 0.45 x %s",
                       d.c, asPrimary.c));
    }

    // ---- A4: the gain multiplies only what is above ambient ----------------
    cmd("viewport.backdropStyle", `{"value":"flat"}`);
    auto off = tiles(r);
    cmd("viewport.retopology", `{"value":"on"}`);
    auto on = tiles(r);
    {
        immutable double A = kAmbient * r.base * 255.0;
        // on is read (+-0.5), off enters scaled by g (+-0.5 g): 1.34 -> 1.5.
        enum double tol = 0.5 + kGain * 0.5;
        int n = 0, sat = 0;
        foreach (i; 0 .. 3) foreach (k; 0 .. 3) {
            immutable double pred = A + kGain * (off[i].c[k] - A);
            if (pred > 254) { ++sat; continue; }
            assert(abs(on[i].c[k] - pred) <= tol,
                format("A4: tile %d channel %d: off %d, on %d, predicted %.2f = "
                       ~ "A + (5/3)(off - A) with A = %.2f (tolerance %.2f)",
                       i, k, off[i].c[k], on[i].c[k], pred, A, tol));
            // Refuting control: gain 1 gives on == off.
            assert(on[i].c[k] - off[i].c[k] >= 3,
                format("A4 control: tile %d channel %d did not brighten (%d -> %d)",
                       i, k, off[i].c[k], on[i].c[k]));
            ++n;
        }
        writefln("  A4 base %.3f A %.2f: %d channels checked, %d saturated", r.base, A, n, sat);
        assert(n + sat == 9 && n >= 6,
            format("A4: %d non-saturated channels of %d checked, need 6 of 9", n, n + sat));
    }

    // ---- A7: the retopology face arm exists and is lit ---------------------
    // Since the face pass honours the plan's faceAlpha (0.5) the fill BLENDS
    // over the empty view: unblend with the pixel read with the layer moved
    // out of the view (a hidden primary is still drawn): c = (out - (1-a)u)/a,
    // carrying (0.5 + (1-a)*0.5)/a extra LSB.
    {
        immutable double a = num(cell0()["plan"]["active"]["faceAlpha"]);
        assert(a > 0.0 && a <= 1.0, format("A7: faceAlpha %s", a));
        cmdOk("layer.attr 1 pos.x 1000");
        settle();
        immutable Px bgPx = probe([r.fgPx])[0];
        cmdOk("layer.attr 1 pos.x 0");
        settle();
        immutable Px raw = probe([r.fgPx])[0];
        assert(maxDiff(raw, bgPx) >= 3, format("A7: no fill drawn (%s)", raw.c));
        Px fg;
        foreach (k; 0 .. 3)
            fg.c[k] = cast(int) round((raw.c[k] - (1.0 - a) * bgPx.c[k]) / a);
        immutable Px[] w = [Px([127, 140, 127])];
        assert(maxDiff(fg, w[0]) >= 3,
            format("A7: the primary reads the weight neutral %s", fg.c));
        // Two +Z polygons lit by the same function with the same gain:
        // fg = face*K + S and tile = base*K + S, S the unscaled specular —
        // zero on this rig (see the constants above).
        immutable double S = 0.0;
        immutable double ratio = kFace / r.base;
        // + 0.5 for rounding the unblended value to an integer above.
        immutable double tol = 0.5 + 0.5 * ratio + abs(S) * (1.0 - ratio)
                             + (0.5 + (1.0 - a) * 0.5) / a + 0.5;
        foreach (k; 0 .. 3) {
            immutable double pred = ratio * (on[0].c[k] - S) + S;
            assert(abs(fg.c[k] - pred) <= tol,
                format("A7: primary channel %d reads %d, predicted %.2f = "
                       ~ "(face/base) x the +Z tile %d (spec %.2f, tolerance %.2f)",
                       k, fg.c[k], pred, on[0].c[k], S, tol));
        }
        writefln("  A7 fg %s predicted from tile %s (S %.3f)", fg.c, on[0].c, S);
    }

    // ---- A6: mode on + same-as-active — predicted from the RESOLVED dim ----
    cmd("viewport.backdropStyle", `{"value":"same"}`);
    {
        auto b = cell0()["plan"]["backdrop"];
        assert(jb(b["joinsItemSequence"]), "A6: the plan must say the backdrop joins");
        immutable double dim = num(b["dim"]);
        auto t = tiles(r);
        foreach (i; 0 .. 3) foreach (k; 0 .. 3) {
            immutable double pred = dim == 1.0 ? on[i].c[k] : round(dim * on[i].c[k]);
            assert(abs(t[i].c[k] - pred) <= 1,
                format("A6: tile %d channel %d reads %d, predicted %.0f from the "
                       ~ "flat-under-mode value %d at the resolved dim %.2f",
                       i, k, t[i].c[k], pred, on[i].c[k], dim));
        }
    }

    // ---- Refusals and the cell selector -------------------------------------
    cmdRefused(commandBody("viewport.displayStyle", `{"value":"solid","slot":2}`),
        "slot 2 does not exist");
    cmdRefused(commandBody("viewport.displayStyle", `{"value":"solid","slot":-1}`),
        "slot -1 does not exist");
    cmdRefused(commandBody("viewport.backdropStyle", `{"value":"bogus"}`),
        "unknown backdrop value");
    cmdRefused(commandBody("viewport.retopology", `{"value":"maybe"}`),
        "unknown mode value");
    cmdRefused(commandBody("viewport.retopology", `{"value":"on","viewport":7}`),
        "out-of-range cell");
    cmdRefused(commandBody("viewport.backdropStyle", `{"value":"flat","viewport":7}`),
        "out-of-range cell");
    settle();
    {
        auto c = cell0();
        assert(c["state"]["backdrop"]["style"].str == "Shaded"
            && c["state"]["backdropStyle"].str == "SameAsActive"
            && jb(c["state"]["retopology"]),
            "refusals must change nothing: " ~ c["state"].toString);
    }
    cmd("viewport.layout", `"Quad"`);
    // Neither command writes a template field, so neither may mark the cell
    // as user-configured: read on cells nobody has written yet (plan §10.13).
    bool userSet(int k) {
        return jb(getJson("/api/viewport/display")["cells"].array[k]["userSet"]);
    }
    assert(!userSet(2) && !userSet(3), "cell selector: cells 2 and 3 start untouched");
    cmd("viewport.retopology", `{"value":"on","viewport":2}`);
    assert(!userSet(2), "viewport.retopology: a non-template writer must not claim the template");
    cmd("viewport.backdropStyle", `{"value":"same","viewport":3}`);
    assert(!userSet(3), "viewport.backdropStyle: a non-template writer must not claim the template");
    cmd("viewport.backdropStyle", `{"value":"hidden","viewport":2}`);
    {
        auto cells = getJson("/api/viewport/display")["cells"].array;
        assert(cells.length == 4, "Quad: expected four cells");
        int k = 0;
        foreach (i, c; cells) {
            if (i == 2) {
                assert(jb(c["state"]["retopology"])
                    && c["state"]["backdropStyle"].str == "Hidden",
                    "cell selector: cell 2 must carry both writes: " ~ c["state"].toString);
            } else if (i != 0) {
                assert(!jb(c["state"]["retopology"])
                    && c["state"]["backdropStyle"].str == "SameAsActive",
                    format("cell selector: cell %d must be untouched: %s", i,
                           c["state"].toString));
            }
            ++k;
        }
        assert(k == 4);
    }
    // A reset restores the WHOLE cell display — these fields have commands
    // and no template, so without it one test's mode would bleed into the
    // next in the shared instance.
    cmd("viewport.displayStyle", `{"value":"solid","slot":1,"viewport":2}`);
    cmdOk(commandBody("scene.reset"));
    settle();
    cmd("viewport.layout", `"Quad"`);
    {
        auto c2 = getJson("/api/viewport/display")["cells"].array[2];
        assert(!jb(c2["state"]["retopology"])
            && c2["state"]["backdropStyle"].str == "SameAsActive"
            && c2["state"]["backdrop"]["style"].str == "Shaded",
            "reset: cell 2's display must be back to its defaults: "
            ~ c2["state"].toString);
    }

    // ---- L: a non-template write must not freeze the template ----------------
    // Single (perspective, template Shaded) -> Quad (cell 0 becomes Top ortho,
    // template Wireframe): the one direction where the layout switch itself
    // moves cell 0's template. Each cycle writes cell 0 in Single, switches to
    // Quad and reads cell 0. L0 (no write) is first: it proves the rig
    // re-seeds; L4 (a slot-0 style choice) is the positive control. Quad ->
    // Single cannot discriminate — `applyLayout` writes cameras only for Quad.
    // Plan §10.13 block L.
    int cycles = 0;
    void cycle(string label, void delegate() write, string wantStyle,
               bool wantUserSet, void delegate(JSONValue) extra) {
        cmdOk(commandBody("scene.reset"));
        settle();
        {
            auto c = cell0();
            assert(!jb(c["ortho"]) && c["state"]["active"]["style"].str == "Shaded"
                && !jb(c["userSet"]),
                label ~ " precondition: cell 0 perspective, Shaded, unchosen: "
                ~ c.toString);
        }
        if (write !is null) write();
        cmd("viewport.layout", `"Quad"`);
        auto c = cell0();
        assert(jb(c["ortho"]), label ~ ": Quad cell 0 must be orthographic: " ~ c.toString);
        assert(c["state"]["active"]["style"].str == wantStyle
            && jb(c["userSet"]) == wantUserSet,
            format("%s: cell 0 after Quad must be style %s, userSet %s: %s",
                   label, wantStyle, wantUserSet, c.toString));
        if (extra !is null) extra(c);
        ++cycles;
    }
    cycle("L0 no write", null, "Wireframe", false, null);
    cycle("L1 retopology on",
        () { cmd("viewport.retopology", `{"value":"on"}`); },
        "Wireframe", false,
        (JSONValue c) { assert(jb(c["state"]["retopology"]),
            "L1: the retopology write must have happened: " ~ c.toString); });
    cycle("L2 backdropStyle flat",
        () { cmd("viewport.backdropStyle", `{"value":"flat"}`); },
        "Wireframe", false,
        (JSONValue c) { assert(c["state"]["backdropStyle"].str == "Flat",
            "L2: the backdropStyle write must have happened: " ~ c.toString); });
    cycle("L3 displayStyle solid slot 1",
        () { cmd("viewport.displayStyle", `{"value":"solid","slot":1}`); },
        "Wireframe", false,
        (JSONValue c) { assert(c["state"]["backdrop"]["style"].str == "Solid",
            "L3: the slot-1 write must have happened: " ~ c.toString); });
    cycle("L4 displayStyle solid slot 0",
        () { cmd("viewport.displayStyle", `{"value":"solid"}`); },
        "Solid", true, null);
    assert(cycles == 5, "L: expected five cycles");
    cmdOk(commandBody("scene.reset"));
    settle();
    cmd("viewport.layout", `"Single"`);
    writeln("  test_retopology_backdrop: all cells passed");
}

// ---------------------------------------------------------------------------
// A8: the lit program's gain is RESTORED after the scene's face passes.
// The pen's filled preview seeds its uniforms by hand and never sets a gain,
// so it reads whatever the last scene pass left: under the mode that pass
// set 5/3. Its fill must read the same with the mode on as with it off
// (same click pixels, same rig). Positive half, ordered first: the preview
// is lit above ambient, so a gain WOULD show.
// ---------------------------------------------------------------------------
private int[3] penPreviewFill(bool modeOn, out double ambientLsb) {
    auto r = buildRig();
    ambientLsb = kAmbient * 0.8 * 255.0;   // the preview mesh has no surfaces
    if (modeOn) cmd("viewport.retopology", `{"value":"on"}`);
    // A triangle in the empty lower-left region, clear of both layers,
    // counter-clockwise on screen; the probe is its centroid.
    immutable int[2] c = toPx([-2.3, -1.6, 0.0], r.vp);
    immutable int[2][3] tri = [[c[0] - 30, c[1] + 20], [c[0] + 30, c[1] + 20],
                               [c[0], c[1] - 30]];
    int[2][] win;
    foreach (t; tri) win ~= [t[0] + r.vp.x, t[1] + r.vp.y];
    immutable int[2] centroid0 = [(tri[0][0] + tri[1][0] + tri[2][0]) / 3,
                                  (tri[0][1] + tri[1][1] + tri[2][1]) / 3];
    immutable Px emptyPx = probe([centroid0])[0];   // probed, not typed
    cmdOk(`tool.set "pen" on 0`);
    string log = format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}`, r.vp.x, r.vp.y, r.vp.width, r.vp.height) ~ "\n";
    double t = 100.0;
    foreach (w; win) {
        log ~= format(`{"t":%g,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
                      ~ `"state":0,"mod":0}`, t, w[0], w[1]) ~ "\n"
             ~ format(`{"t":%g,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,`
                      ~ `"clicks":1,"mod":0}`, t + 5, w[0], w[1]) ~ "\n"
             ~ format(`{"t":%g,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,`
                      ~ `"clicks":1,"mod":0}`, t + 10, w[0], w[1]) ~ "\n";
        t += 100.0;
    }
    auto pr = postJson("/api/play-events", log);
    assert(pr["status"].str == "success", "A8: /api/play-events failed: " ~ pr.toString);
    waitPlaybackProcessed();
    settle();
    immutable int[2] centroid = [(tri[0][0] + tri[1][0] + tri[2][0]) / 3,
                                 (tri[0][1] + tri[1][1] + tri[2][1]) / 3];
    auto px = probe([centroid])[0];
    assert(maxDiff(px, emptyPx) >= 3,
        format("A8 premise: no preview fill was drawn (read %s, empty %s)",
               px.c, emptyPx.c));
    cmdRaw(`tool.set "pen" off 0`);
    cmdRaw(commandBody("viewport.retopology", `{"value":"off"}`));
    settle();
    return px.c;
}

unittest {
    double amb;
    immutable int[3] offFill = penPreviewFill(false, amb);
    immutable int[3] onFill  = penPreviewFill(true, amb);
    writefln("  A8 pen preview fill: mode off %s, mode on %s (ambient %.1f)",
             offFill, onFill, amb);
    foreach (k; 0 .. 3)
        assert(offFill[k] - amb >= 3,
            format("A8 premise: the preview fill %s is not lit above ambient %.1f, "
                   ~ "so a leaked gain could not show", offFill, amb));
    // Same pixels, same inputs: +-1 is rounding only.
    foreach (k; 0 .. 3)
        assert(abs(onFill[k] - offFill[k]) <= 1,
            format("A8: the pen preview reads %s with the mode on and %s off — the "
                   ~ "scene pass left its light gain on the shared lit program",
                   onFill, offFill));
}
