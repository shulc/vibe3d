// Tests for mesh.jitter — random per-vertex displacement with a
// deterministic Mt19937 seed so a given (seed, scale*) pair always
// produces the same output.
//
// MODO has no `vert.jitter` for positions (only `vertMap.jitter` for
// vertex maps), so this is a vibe3d-original deformer with no
// cross-engine reference. Tests focus on:
//   * determinism: same seed ⇒ same output (twice)
//   * different seed ⇒ different output
//   * scl=0 ⇒ no-op
//   * displacement bounded by scl per axis
//   * empty selection ⇒ whole mesh
//   * undo restores

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

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

unittest { // determinism — same seed twice ⇒ identical positions
    postJson("/api/reset", "");
    cmd("mesh.jitter sclX:0.1 sclY:0.1 sclZ:0.1 seed:42");
    auto first = dumpVerts();
    postJson("/api/reset", "");
    cmd("mesh.jitter sclX:0.1 sclY:0.1 sclZ:0.1 seed:42");
    auto second = dumpVerts();
    assert(first.length == second.length);
    foreach (i; 0 .. first.length)
        foreach (c; 0 .. 3)
            assert(approxEq(first[i][c], second[i][c]),
                "vert " ~ i.to!string ~ " axis " ~ c.to!string
                ~ ": same seed gave different positions ("
                ~ first[i][c].to!string ~ " vs "
                ~ second[i][c].to!string ~ ")");
}

unittest { // different seed ⇒ different output (with overwhelming probability)
    postJson("/api/reset", "");
    cmd("mesh.jitter sclX:0.1 sclY:0.1 sclZ:0.1 seed:42");
    auto a = dumpVerts();
    postJson("/api/reset", "");
    cmd("mesh.jitter sclX:0.1 sclY:0.1 sclZ:0.1 seed:7");
    auto b = dumpVerts();
    bool anyDifferent = false;
    foreach (i; 0 .. a.length)
        foreach (c; 0 .. 3)
            if (!approxEq(a[i][c], b[i][c])) anyDifferent = true;
    assert(anyDifferent,
        "two different seeds (42 vs 7) produced identical jitter — "
        ~ "Mt19937 sequences should diverge");
}

unittest { // scl=0 on every axis ⇒ no-op
    postJson("/api/reset", "");
    cmd("mesh.jitter sclX:0 sclY:0 sclZ:0 seed:42");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3) {
            // Cube corners stay at ±0.5 — no displacement.
            assert(approxEq(fabs(v[c]), 0.5),
                "scl=0 jitter shouldn't move verts off ±0.5, got "
                ~ v[c].to!string);
        }
    }
}

unittest { // displacement bounded by scl per axis
    postJson("/api/reset", "");
    cmd("mesh.jitter sclX:0.2 sclY:0.05 sclZ:0.0 seed:1");
    auto verts = dumpVerts();
    foreach (v; verts) {
        // X displacement bounded by 0.2 (so X ∈ [±0.5 ± 0.2] = [-0.7, +0.7]).
        assert(fabs(v[0]) <= 0.5 + 0.2 + 1e-5,
            "X out of bounds for sclX=0.2: " ~ v[0].to!string);
        // Y displacement bounded by 0.05.
        assert(fabs(v[1]) <= 0.5 + 0.05 + 1e-5,
            "Y out of bounds for sclY=0.05: " ~ v[1].to!string);
        // Z displacement = 0 (sclZ=0) — Z must remain ±0.5.
        assert(approxEq(fabs(v[2]), 0.5),
            "Z should be untouched at ±0.5, got " ~ v[2].to!string);
    }
}

unittest { // selection-aware: vertex mode + 1 selected vert ⇒ only that vert moves
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[3]}`);
    assert(sel["status"].str == "ok");
    cmd("mesh.jitter sclX:0.1 sclY:0.1 sclZ:0.1 seed:1");
    auto verts = dumpVerts();
    int moved = 0;
    foreach (i, v; verts) {
        // Original cube corners are at ±0.5; any drift means jitter
        // touched this vert.
        bool drifted = !approxEq(fabs(v[0]), 0.5)
                    || !approxEq(fabs(v[1]), 0.5)
                    || !approxEq(fabs(v[2]), 0.5);
        if (drifted) moved++;
    }
    // Drained-roll determinism: only the selected vert (index 3) should
    // have actually been displaced, even though the RNG advances for all.
    assert(moved == 1,
        "expected exactly 1 vert displaced by selection-aware jitter, got "
        ~ moved.to!string);
}

unittest { // undo restores pre-jitter positions
    postJson("/api/reset", "");
    cmd("mesh.jitter sclX:0.1 sclY:0.1 sclZ:0.1 seed:1");
    cmd("history.undo");
    auto verts = dumpVerts();
    foreach (v; verts) {
        foreach (c; 0 .. 3) {
            assert(approxEq(fabs(v[c]), 0.5),
                "undo should restore ±0.5 corner, got " ~ v[c].to!string);
        }
    }
}
