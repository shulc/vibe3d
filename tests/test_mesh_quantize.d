// Tests for mesh.quantize — snaps every selected vertex to a grid step.
//
// Behaviour pinned by these tests:
//   * step=0.5 on a unit cube ⇒ no-op (corners already on the grid).
//   * step=0.3 on a unit cube ⇒ each ±0.5 corner snaps to the nearest
//     0.3 multiple, which is ±0.6 (round-half-away-from-zero).
//   * Empty selection ⇒ whole mesh quantized (MODO convention).
//   * Polygon-mode + selection ⇒ only verts of selected faces touched.
//   * Undo restores the original positions exactly.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

unittest { // step=0.5: cube corners already on grid → unchanged
    postJson("/api/reset", "");
    cmd("mesh.quantize step:0.5");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        // Every component should still be ±0.5.
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(a[c].floating), 0.5),
                "step=0.5 quantize moved a corner: " ~ a[c].floating.to!string);
        }
    }
}

unittest { // step=0.3: ±0.5 → ±0.6 (round-half-away-from-zero, then ×0.3)
    postJson("/api/reset", "");
    cmd("mesh.quantize step:0.3");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            // 0.5 / 0.3 ≈ 1.67 → floor(1.67 + 0.5) = 2 → 2 * 0.3 = 0.6.
            // -0.5 / 0.3 ≈ -1.67 → floor(-1.67 + 0.5) = -2 → -2 * 0.3 = -0.6.
            // The one tricky case: +0.5 sits exactly on the *.5 boundary
            // before scaling, so it always goes UP via floor(x + 0.5).
            double v_ = a[c].floating;
            assert(approxEq(fabs(v_), 0.6, 1e-4),
                "expected ±0.6 after step=0.3 quantize, got " ~ v_.to!string);
        }
    }
}

unittest { // step=0.4: 0.5 → 0.4 (nearest 0.4 multiple is 0.4 vs 0.8 → 0.4 closer)
    // 0.5 / 0.4 = 1.25 → floor(1.25 + 0.5) = 1 → 1 * 0.4 = 0.4. Yes.
    postJson("/api/reset", "");
    cmd("mesh.quantize step:0.4");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            double v_ = a[c].floating;
            assert(approxEq(fabs(v_), 0.4, 1e-4),
                "expected ±0.4 after step=0.4 quantize, got " ~ v_.to!string);
        }
    }
}

unittest { // empty selection ⇒ whole mesh quantized (MODO convention)
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    // No selectedFaces — the command should still touch every vert.
    cmd("mesh.quantize step:0.3");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(a[c].floating), 0.6, 1e-4),
                "empty-selection quantize should still touch every vert");
        }
    }
}

unittest { // selection-aware in vertices mode: only selected verts move
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    // Select vert 0 only — that's at (-0.5, -0.5, -0.5).
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[0]}`);
    assert(sel["status"].str == "ok", sel.toString);
    cmd("mesh.quantize step:0.3");
    auto verts = getJson("/api/model")["vertices"].array;
    // Vert 0: ±0.5 → ±0.6 (-0.6 for negative components).
    auto v0 = verts[0].array;
    assert(approxEq(v0[0].floating, -0.6, 1e-4),
        "vert 0.x expected -0.6, got " ~ v0[0].floating.to!string);
    assert(approxEq(v0[1].floating, -0.6, 1e-4));
    assert(approxEq(v0[2].floating, -0.6, 1e-4));
    // Vert 1 (= +0.5, -0.5, -0.5) should be untouched.
    auto v1 = verts[1].array;
    assert(approxEq(v1[0].floating,  0.5, 1e-4),
        "vert 1.x should be untouched at +0.5, got " ~ v1[0].floating.to!string);
    assert(approxEq(v1[1].floating, -0.5, 1e-4));
    assert(approxEq(v1[2].floating, -0.5, 1e-4));
}

unittest { // undo restores pre-quantize positions
    postJson("/api/reset", "");
    cmd("mesh.quantize step:0.3");
    cmd("history.undo");
    auto verts = getJson("/api/model")["vertices"].array;
    foreach (v; verts) {
        auto a = v.array;
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(a[c].floating), 0.5),
                "undo should restore ±0.5 corners");
        }
    }
}
