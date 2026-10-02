// The face VBO's layout census (task 9070, model M3): every file that names a
// face VBO AND binds a buffer for data access depends on the layout, so it must
// read `mesh_gpu.kFaceStride` and spell no other stride. The files are found
// from the RULE at test time, never from a list:
//   a call `glBindBuffer(` whose first argument token is `GL_ARRAY_BUFFER` and
//   whose second argument's last identifier ends in `faceVbo`/`FaceVbo`, or a
//   call `glBindBufferBase(` whose first argument token is
//   `GL_TRANSFORM_FEEDBACK_BUFFER` (arguments split at top-level commas).
// Shell equivalent, measured 2026-10-02 on the base:
//   grep -rln "faceVbo" source --include=*.d | xargs grep -ln \
//     "glBindBuffer\s*(\s*GL_ARRAY_BUFFER\s*,\s*[A-Za-z_.]*faceVbo\|GL_TRANSFORM_FEEDBACK_BUFFER"
//   -> gpu_select.d http_providers.d mesh_gpu.d subpatch_osd.d (4 files)
// Order per block: floor -> needles -> structure, each with a positive control.
module tests.unit.face_stride_census_test;

import std.algorithm : sort, endsWith;
import std.array     : array, replace;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : ctRegex, matchAll, matchFirst;
import std.string    : indexOf, strip;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countOccurrences,
    isIdentChar;

private enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string codeOf(string rel) {
    return blankUnittestBodies(blankNonCode(readText(buildPath(root, "source", rel))));
}

/// The argument list of every call to `fn(` in `code` (whole identifier),
/// split at top-level commas and stripped.
private string[][] callArgs(string code, string fn) {
    string[][] out_;
    size_t from = 0;
    while (true) {
        immutable ptrdiff_t at = code[from .. $].indexOf(fn ~ "(");
        if (at < 0) break;
        immutable size_t s = from + cast(size_t)at;
        from = s + fn.length;
        if (s > 0 && isIdentChar(code[s - 1])) continue;   // whole identifier only
        size_t i = s + fn.length + 1, depth = 1, argStart = i;
        string[] args;
        for (; i < code.length && depth > 0; ++i) {
            immutable char c = code[i];
            if (c == '(' || c == '[') ++depth;
            else if (c == ')' || c == ']') {
                if (--depth == 0) args ~= code[argStart .. i].strip;
            } else if (c == ',' && depth == 1) {
                args ~= code[argStart .. i].strip;
                argStart = i + 1;
            }
        }
        out_ ~= args;
    }
    return out_;
}

/// The layout rule: does `code` bind a face VBO for data access?
private bool bindsFaceVbo(string code) {
    foreach (a; callArgs(code, "glBindBuffer")) {
        if (a.length < 2 || a[0] != "GL_ARRAY_BUFFER") continue;
        auto m = matchFirst(a[1], ctRegex!(`([A-Za-z_][A-Za-z0-9_]*)$`));
        if (!m.empty && (m[1].endsWith("faceVbo") || m[1].endsWith("FaceVbo"))) return true;
    }
    foreach (a; callArgs(code, "glBindBufferBase"))
        if (a.length >= 1 && a[0] == "GL_TRANSFORM_FEEDBACK_BUFFER") return true;
    return false;
}

private enum strideRe   = ctRegex!(`\bFACE_STRIDE\b`);
private enum sixSizeRe  = ctRegex!(`\b6\s*\*\s*float\s*\.\s*sizeof`);
private enum sixIndexRe = ctRegex!(`\*\s*6\s*[+\]]`);
private enum kStrideRe  = ctRegex!(`\bkFaceStride\b`);
private enum baseVertRe = ctRegex!(`\bmesh\s*\.\s*vertices\s*\[`);

private size_t hits(R)(string code, R re) {
    size_t n;
    foreach (_; matchAll(code, re)) ++n;
    return n;
}

/// `{ … }` body of the first declaration starting with `head`.
private string bodyAt(string code, string head) {
    immutable ptrdiff_t at = code.indexOf(head);
    assert(at >= 0, "census: missing declaration `" ~ head ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    immutable size_t begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "census: unterminated body after `" ~ head ~ "`");
}

private string squash(string s) {   // collapse whitespace runs to one space
    import std.regex : replaceAll;
    return replaceAll(s, ctRegex!(`\s+`), " ");
}

unittest { // the rule's own controls [E5]: the app.d shape is rejected, a real face bind accepted
    assert(!bindsFaceVbo("glBindBuffer(GL_ARRAY_BUFFER, gridVbo); faceVbo: gpu.faceVbo"),
        "control: a non-face bind beside a faceVbo mention must NOT qualify");
    assert(bindsFaceVbo("glBindBuffer(GL_ARRAY_BUFFER, gpu.faceVbo);"),
        "control: a GL_ARRAY_BUFFER bind of gpu.faceVbo must qualify");
    assert(bindsFaceVbo("glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, targetFaceVbo);"),
        "control: a transform-feedback target bind must qualify");
    assert(!bindsFaceVbo("glBindBufferBase(GL_UNIFORM_BUFFER, 0, faceVbo);"),
        "control: a uniform-buffer base bind must NOT qualify");
    // The stride needles find today's (pre-S1a) spellings.
    enum oldSubmit = "enum FACE_STRIDE = 6; glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, "
                   ~ "FACE_STRIDE * float.sizeof, cast(void*)0);";
    assert(hits(oldSubmit, strideRe) == 2, "control: the FACE_STRIDE needle misses the old submitUploadGl");
    assert(hits("glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * float.sizeof, cast(void*)0);",
                sixSizeRe) == 1, "control: the `6 * float.sizeof` needle misses the old gpu_select spelling");
    assert(hits("jsonNum(data[i * 6 + 0]); float[] d = new float[](n * 6]", sixIndexRe) == 2,
        "control: the `* 6 +` / `* 6]` needle misses the old face-vbo endpoint spelling");
}

unittest { // the layout census: four files, one stride constant, no other spelling
    string[] files;
    foreach (de; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth)) {
        immutable rel = de.name[buildPath(root, "source").length + 1 .. $].replace("\\", "/");
        if (bindsFaceVbo(codeOf(rel))) files ~= rel;
    }
    files.sort();
    // Floor first [E4]: the rule's population (names printed).
    assert(files.length == 4,
        format("census: the face-VBO layout rule selects %d files, expected 4: %s", files.length, files));
    foreach (f; files) {
        immutable code = codeOf(f);
        assert(hits(code, strideRe) == 0, format("census: %s still spells FACE_STRIDE", f));
        assert(hits(code, sixSizeRe) == 0, format("census: %s still spells `6 * float.sizeof`", f));
        assert(hits(code, sixIndexRe) == 0,
            format("census: %s still indexes the face VBO with `* 6 +` / `* 6]`", f));
        assert(hits(code, kStrideRe) >= 1,
            format("census: %s binds the face VBO but never reads kFaceStride", f));
    }
    assert(hits(codeOf("subpatch_osd.d"), ctRegex!(`kFanOutStride\s*!=\s*kFaceStride`)) == 1,
        "census: the GPU fan-out's park (`kFanOutStride != kFaceStride`) is gone from subpatch_osd.d");
}

unittest { // ONE fan writer behind ONE CPU refresh, called by exactly the three face-VBO writers [E3, E14]
    immutable code = codeOf("mesh_gpu.d");
    assert(hits(code, ctRegex!(`\bsize_t\s+writeFaceCorners\s*\(`)) == 1,
        "census: writeFaceCorners must be defined exactly once in mesh_gpu.d");
    // The fan writer has one caller: the incremental CPU refresh.
    immutable refresh = bodyAt(code, "const(float)[] refreshFaceDataCpu(");
    assert(refresh.length > 300, "census: refreshFaceDataCpu's body vanished");
    assert(countOccurrences(refresh, "writeFaceCorners(") == 1 &&
           countOccurrences(code, "writeFaceCorners(") == 2,
        format("census: writeFaceCorners is called %d time(s) in mesh_gpu.d, %d in refreshFaceDataCpu; "
             ~ "expected exactly one call, there", countOccurrences(code, "writeFaceCorners(") - 1,
               countOccurrences(refresh, "writeFaceCorners(")));
    // The refresh reads the incremental smooth kernel (the derived dirty set).
    assert(countOccurrences(refresh, "updateCornerSmooth(") == 1,
        "census: refreshFaceDataCpu no longer goes through updateCornerSmooth");
    immutable string[3] writers = ["buildUploadCpu", "refreshPositions", "uploadSelectedVertices"];
    string[] callers;
    size_t calls;
    foreach (w; writers) {
        immutable n = countOccurrences(bodyAt(code, "void " ~ w ~ "("), "refreshFaceDataCpu(");
        calls += n;
        if (n == 1) callers ~= w;
    }
    // Polarity: true after the incremental refresh only. A writer that
    // inlines its own fan loop (or full recompute) again drops out of this list.
    assert(callers == writers[],
        format("census: the face-VBO writers calling refreshFaceDataCpu once each are %s, expected %s",
               callers, writers));
    assert(countOccurrences(code, "refreshFaceDataCpu(") == calls + 1,
        "census: refreshFaceDataCpu is called outside the three writers");
}

unittest { // the prepared-upload helpers carry the smooth stream's inputs
    immutable code = codeOf("mesh_gpu.d");
    immutable clone   = squash(bodyAt(code, "private GpuMesh cloneUploadState("));
    immutable install = squash(bodyAt(code, "private void installUploadState("));
    immutable empty   = squash(bodyAt(code, "private bool isDefaultEmptyGpuMesh("));
    // Floor: the three bodies were found and are non-trivial.
    assert(clone.length > 200 && install.length > 200 && empty.length > 200,
        "census: a prepared-upload helper body vanished");
    foreach (stmt; ["dst.faceAdj.offsets = src.faceAdj.offsets.dup",
                    "dst.faceAdj.faces = src.faceAdj.faces.dup",
                    "dst.faceAdjGen = src.faceAdjGen",
                    "dst.scratchCornerSmooth = src.scratchCornerSmooth.dup",
                    "dst.scratchFaceNormal = src.scratchFaceNormal.dup",
                    "dst.smoothCache = SmoothNormalCache.init"])
        assert(clone.indexOf(stmt) >= 0, "census: cloneUploadState no longer copies `" ~ stmt ~ "`");
    foreach (stmt; ["dst.faceAdj = src.faceAdj", "dst.faceAdjGen = src.faceAdjGen",
                    "dst.scratchCornerSmooth = src.scratchCornerSmooth",
                    "dst.scratchFaceNormal = src.scratchFaceNormal",
                    "dst.smoothCache = src.smoothCache",
                    "src.faceAdj = FaceAdjacency.init",
                    "src.smoothCache = SmoothNormalCache.init"])
        assert(install.indexOf(stmt) >= 0, "census: installUploadState no longer moves `" ~ stmt ~ "`");
    foreach (stmt; ["gpu.faceAdj.offsets.length == 0", "gpu.faceAdj.faces.length == 0",
                    "gpu.faceAdjGen == 0", "gpu.scratchCornerSmooth.length == 0",
                    "gpu.scratchFaceNormal.length == 0", "gpu.smoothCache.isEmpty"])
        assert(empty.indexOf(stmt) >= 0, "census: isDefaultEmptyGpuMesh no longer requires `" ~ stmt ~ "`");
}

unittest { // the smoothing policy (S1e) travels, moves, empties and resets with the adjacency
    // No pixel can see a policy that failed to move or reset (the self-heal
    // rebuild repaints it); this census IS the witness. One assert per helper.
    immutable code = codeOf("mesh_gpu.d");
    immutable string[4] heads = ["private GpuMesh cloneUploadState(",
        "private void installUploadState(", "private bool isDefaultEmptyGpuMesh(",
        "private GpuMeshNames takeGpuMeshNames("];
    foreach (h; heads) {
        immutable b = bodyAt(code, h);
        assert(b.length > 200, "census: the helper body `" ~ h ~ "` vanished");   // floor
        assert(countOccurrences(b, "smoothPolicy") >= 1,
            "census: `" ~ h ~ "` no longer mentions smoothPolicy — the smoothing policy is dropped there");
    }
    // The exact statements, per helper (each a term a mutation can drop alone).
    immutable clone = squash(bodyAt(code, heads[0])), install = squash(bodyAt(code, heads[1])),
              empty = squash(bodyAt(code, heads[2])), take = squash(bodyAt(code, heads[3]));
    foreach (stmt; ["dst.smoothPolicy.faceSlot = src.smoothPolicy.faceSlot.dup",
                    "dst.smoothPolicy.slotCos = src.smoothPolicy.slotCos"])
        assert(clone.indexOf(stmt) >= 0, "census: cloneUploadState no longer copies `" ~ stmt ~ "`");
    foreach (stmt; ["dst.smoothPolicy = src.smoothPolicy", "src.smoothPolicy = SmoothPolicy.init"])
        assert(install.indexOf(stmt) >= 0, "census: installUploadState no longer moves `" ~ stmt ~ "`");
    foreach (stmt; ["gpu.smoothPolicy.faceSlot.length == 0",
                    "gpu.smoothPolicy.slotCos == SmoothPolicy.init.slotCos"])
        assert(empty.indexOf(stmt) >= 0, "census: isDefaultEmptyGpuMesh no longer requires `" ~ stmt ~ "`");
    assert(take.indexOf("gpu.smoothPolicy = SmoothPolicy.init") >= 0,
        "census: takeGpuMeshNames no longer resets smoothPolicy");
}

unittest { // the selected-vertex path reads the DRAWN positions only (task 1069 law)
    // Positive control [E5]: the needle finds the pre-S1a edge walk.
    assert(hits("Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];", baseVertRe) == 2,
        "control: the `mesh.vertices[` needle misses the old edge walk");
    immutable body_ = bodyAt(codeOf("mesh_gpu.d"), "void uploadSelectedVertices(");
    assert(body_.length > 500, "census: uploadSelectedVertices' body vanished");
    // Polarity: FALSE before S1a (the face fan and the edge walk read the
    // base), TRUE after. A hit here is a VBO walk that went back to base
    // positions and un-morphs a displayed morph mid-drag.
    assert(hits(body_, baseVertRe) == 0,
        format("census: uploadSelectedVertices reads mesh.vertices[ %d time(s) — a VBO walk went "
             ~ "back to base positions instead of the drawn ones", hits(body_, baseVertRe)));
}
