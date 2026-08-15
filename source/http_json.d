// ---------------------------------------------------------------------------
// http_json — the JSON bodies the HTTP layer hands back, and the escaper they
// are assembled with.
//
// Split out of http_server.d by task 0720 (audit №4, D5). The routing table
// and the socket plumbing are one concern; turning a Mesh into the bytes
// `/api/model` returns is another, and it is the half that is worth reading on
// its own — `meshToJsonDetailed` alone is the wire contract of the most-asserted
// endpoint in the suite.
//
// One visibility note, because the rule is "do not widen to make a split
// possible": `jsonEsc` WAS module-private in http_server.d and is public here.
// It had to travel — `meshToJsonDetailed` escapes surface names with it — and
// leaving a second copy behind would have re-created exactly the duplication
// wave 1 removed. It is the escaper of the module named for JSON; that is the
// one place it can live without a copy.
// ---------------------------------------------------------------------------
module http_json;

import std.datetime : Clock;
import std.json;

import mesh : Mesh, Surface;

// ---------------------------------------------------------------------------
// jsonEsc — escape `s` for embedding BETWEEN the quotes of a JSON string
// literal in a hand-assembled response body.
//
// The HTTP layer builds most of its error bodies by concatenation, and it used
// to escape them by hand: 45 of the 49 escape sites replaced the double-quote
// and NOTHING else (audit №4, D11). That is not a style problem. Exception
// messages there interpolate caller-controlled text verbatim —
// `unknown layer kind 'X'`, `unknown command id 'X'`, file paths from a failed
// load — so a single backslash in X emitted a body that is not JSON at all
// (`\z` is a hard parse error, `\b` parses as a BACKSPACE and silently
// changes the message), and a newline in a message broke it outright.
//
// std.json does the escaping, because it is the same escaper the correct
// sites in this tree already reach for and it covers control characters, not
// just the two everyone remembers. It returns a QUOTED literal; the slice
// drops the quotes so this stays a drop-in for the `.replace` it replaced —
// call sites keep supplying their own quotes.
// ---------------------------------------------------------------------------
string jsonEsc(string s) {
    auto lit = JSONValue(s).toString();
    return lit.length >= 2 ? lit[1 .. $ - 1] : "";
}

/**
 * Convert mesh data to JSON string
 */
string meshToJson(size_t vertexCount, size_t edgeCount, size_t faceCount) {
    import std.format : format;
    string res = format("{\"vertexCount\": %d, \"edgeCount\": %d, \"faceCount\": %d, \"timestamp\": \"%s\"}",
                  vertexCount, edgeCount, faceCount, Clock.currTime.toISOExtString());
    return res;
}

/**
 * Convert detailed mesh data to JSON string
 *
 * Reads the mesh DIRECTLY — it used to take ten pre-built arrays, and every
 * caller had to manufacture all ten. Three of those were pure copies
 * (`m.edges`, a per-face `.dup` of every face, `m.surfaces.dup`) and are
 * simply gone; the per-face `.dup` was the worst of them, one small GC
 * allocation per face, i.e. half a million of them at this project's 500k-face
 * ceiling, for bytes this function only ever reads.
 *
 * The other three were NOT copies but PADDING, and that behaviour is
 * load-bearing, so it moved in here rather than being deleted — see the three
 * per-face loops below. `isSubpatch` / `faceMaterial` / `facePart` are all
 * lazily grown (the commands that write them resize on first write), so any of
 * them can legitimately be SHORTER than `faces.length` — a default cube has
 * `facePart.length == 0` and still reports six zeros. Every one of the three
 * therefore runs to `faces.length` and defaults out-of-range entries, which
 * also truncates should an array ever run long.
 *
 * Taking `ref const(Mesh)` (not slices) is what lets the subpatch flags read
 * through `isFaceSubpatch(fi)`: `Mesh.isSubpatch` is an `@property` that
 * materialises a fresh `bool[]` per call, so a slice-taking signature would
 * still have forced one allocation here. `isFaceSubpatch(fi)` is bounds-
 * checked internally and returns false when out of range — exactly the
 * padding rule, without the array.
 *
 * MUST run on the main thread. It walks the live mesh with no copy standing
 * between it and a concurrent edit; `/api/model` marshals it there through
 * `modelBridge` (see the routing at "/api/model"), which is the whole reason
 * dropping the copies is safe.
 */
string meshToJsonDetailed(ref const(Mesh) m) {
    import std.format : format;
    import std.array : appender;

    auto json = appender!string();
    json ~= "{";
    json ~= format("\"vertexCount\": %d, ", m.vertices.length);
    json ~= format("\"edgeCount\": %d, ", m.edges.length);
    json ~= format("\"faceCount\": %d, ", m.faces.length);
    json ~= format("\"timestamp\": \"%s\", ", Clock.currTime.toISOExtString());

    // Add vertices array
    json ~= "\"vertices\": [";
    for (size_t i = 0; i < m.vertices.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("[%f, %f, %f]",
                       m.vertices[i].x, m.vertices[i].y, m.vertices[i].z);
    }
    json ~= "], ";

    // Add edges array (each edge as a 2-element [a, b] vertex-index pair)
    json ~= "\"edges\": [";
    for (size_t i = 0; i < m.edges.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("[%d, %d]", m.edges[i][0], m.edges[i][1]);
    }
    json ~= "], ";

    // Add faces array
    json ~= "\"faces\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= "[";
        auto f = m.faces[i];
        for (size_t j = 0; j < f.length; ++j) {
            if (j > 0) json ~= ", ";
            json ~= format("%d", f[j]);
        }
        json ~= "]";
    }
    json ~= "], ";

    // Add per-face subpatch flags (parallel to faces[]).
    // PADDING RULE (was the caller's `subCopy`): one entry per FACE, false
    // where the marks array has not caught up with a face add.
    json ~= "\"isSubpatch\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isFaceSubpatch(i) ? "true" : "false";
    }
    json ~= "], ";

    // Per-element hide flags (task 0613 Stage 2) — the test observable for
    // every later hide-geometry stage. faceHidden is the AUTHORITATIVE
    // plane; vertexHidden/edgeHidden are DERIVED (§1.2 of
    // doc/hide_geometry_plan.md) but exposed the same way so a test can read
    // any of the three without knowing which plane is the source of truth.
    // Same non-allocating, bounds-checked accessor + padding-rule shape as
    // isSubpatch above.
    json ~= "\"faceHidden\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isFaceHidden(i) ? "true" : "false";
    }
    json ~= "], ";
    json ~= "\"vertexHidden\": [";
    for (size_t i = 0; i < m.vertices.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isVertexHidden(i) ? "true" : "false";
    }
    json ~= "], ";
    json ~= "\"edgeHidden\": [";
    for (size_t i = 0; i < m.edges.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= m.isEdgeHidden(i) ? "true" : "false";
    }
    json ~= "], ";

    // Material Groups (MG2): the per-mesh surface registry and per-face
    // material indices into it. Exposed so render_diff and the LWO
    // surface-loader tests can verify what the parser produced.
    json ~= "\"surfaces\": [";
    for (size_t i = 0; i < m.surfaces.length; ++i) {
        if (i > 0) json ~= ", ";
        const s = m.surfaces[i];
        // Bind the name to a plain `string` first: reached through a
        // `const(Mesh)` it arrives as `const(string)`, which `replace` will
        // not deduce a template argument from.
        string name = s.name;
        json ~= format(
            "{\"name\":\"%s\",\"baseColor\":[%f,%f,%f],\"diffuseAmount\":%f," ~
            "\"specularAmount\":%f,\"glossiness\":%f,\"opacity\":%f}",
            jsonEsc(name),
            s.baseColor.x, s.baseColor.y, s.baseColor.z,
            s.diffuseAmount, s.specularAmount, s.glossiness, s.opacity);
    }
    json ~= "], ";
    // PADDING RULE (was the caller's `matCopy`): one entry per FACE, 0 where
    // faceMaterial has not caught up. Same for facePart / `partCopy` below.
    json ~= "\"faceMaterial\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("%d", i < m.faceMaterial.length ? m.faceMaterial[i] : 0u);
    }
    json ~= "], ";
    json ~= "\"facePart\": [";
    for (size_t i = 0; i < m.faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("%d", i < m.facePart.length ? m.facePart[i] : 0u);
    }
    json ~= "]";
    json ~= "}";

    return json.data;
}
