// A suite driver reads a FRAME-PUBLISHED `/api/changes` counter only after a
// frame fence (task 9526).
//
// `/api/changes` is answered on the HTTP thread. The document-level channels
// (layer kinds, item selection, current type) are counted at the frame flush,
// the missed-publisher check runs in the same block, and background uploads
// are counted by the draw; all of them run AFTER `/api/command` has answered.
// A bare read can therefore precede the flush of the frame that served the
// last command: as a baseline it counts that command's event inside the next
// window (task 9521's flake, `active N->N+2`), as an after-read it misses it.
// The fence is `http_client.settledChanges` (frameFence, then read).
//
// THE RULE: a `tests/*.d` file that names a frame-published key (as a quoted
// literal, outside comments) holds no raw `"/api/changes"` read; it reads
// through `settledChanges`. The key set is DERIVED from source: the fields the
// bus's `flush` writes, the `changeBus.<f>++` writes of `app.d`'s frame loop,
// and the draw's `g_bgGpuUploads`, intersected with the route's keys.
//
// KNOWN LIMIT: per file. A helper module that returns the raw JSON to a reader
// elsewhere is invisible to the needle, so the raw-read helper modules are
// pinned by name below; a new one reddens and is reviewed.
//
// Evidence and the stall rig: doc/tasks (9526).
module tests.unit.frame_fence_census_test;

import std.algorithm : canFind, sort;
import std.array     : array;
import std.file      : dirEntries, SpanMode, readText;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.regex     : ctRegex, matchAll;
import std.string    : indexOf;

import tests.unit.census_symbols : balancedSpan, blankNonCode, countOccurrences;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// Comments blanked, string literals kept (byte offsets unchanged).
private string blankComments(string raw)
{
    const codeOnly = blankNonCode(raw);
    const withComments = blankNonCode(raw, true);
    assert(codeOnly.length == raw.length && withComments.length == raw.length,
        "9526 scanner control: lexer projections changed source byte length");
    auto result = raw.dup;
    foreach (i; 0 .. result.length)
        if (codeOnly[i] != withComments[i])
            result[i] = ' ';
    return result.idup;
}

/// The `{...}` body following the first `marker` in `raw`, braces matched on
/// the code view; "" when absent.
private string bodyAfter(string raw, string marker)
{
    const code = blankNonCode(raw);
    const at = code.indexOf(marker);
    if (at < 0) return "";
    const rel = code[cast(size_t) at .. $].indexOf('{');
    if (rel < 0) return "";
    const open = cast(size_t) at + cast(size_t) rel;
    const span = balancedSpan(code, open, '{', '}');
    return span.length ? raw[open .. open + span.length] : "";
}

private string[] uniqSorted(string[] xs)
{
    string[] r;
    foreach (x; xs) if (!r.canFind(x)) r ~= x;
    sort(r);
    return r;
}

/// The frame-published keys of `/api/changes`, derived from source.
private string[] frameFlushedKeys()
{
    const bus = readText(buildPath(repoRoot, "source", "change_bus.d"));
    const flushBody = blankComments(bodyAfter(bus, "void flush(uint itemSelDomains"));
    assert(flushBody.length > 0, "9526 floor: ChangeBus.flush body not found");
    string[] written;
    foreach (m; matchAll(flushBody, ctRegex!`\+\+\s*([A-Za-z_]\w*)`)) written ~= m[1];
    foreach (m; matchAll(flushBody, ctRegex!`([A-Za-z_]\w*)\s*=[^=]`)) written ~= m[1];

    const app = blankComments(readText(buildPath(repoRoot, "source", "app.d")));
    foreach (m; matchAll(app, ctRegex!`changeBus\.([A-Za-z_]\w*)\s*\+\+`)) written ~= m[1];

    // The draw-time counter: written by the frame loop's background-layer
    // reconcile, served under its own key.
    const bg = blankComments(readText(buildPath(repoRoot, "source", "bg_gpu_cache.d")));
    assert(bg.indexOf("++g_bgGpuUploads") >= 0,
        "9526 floor: the background-upload counter's frame-loop writer moved");
    written ~= "bgGpuUploads";

    const server = readText(buildPath(repoRoot, "source", "http_server.d"));
    const route = bodyAfter(server, "private void route_apiChanges(");
    assert(route.length > 0, "9526 floor: route_apiChanges body not found");
    string[] keys;
    foreach (m; matchAll(route, ctRegex!`"([A-Za-z_]\w*)":`)) keys ~= m[1];
    assert(keys.length >= 40,
        format("9526 floor: route_apiChanges serialises %s keys, expected >= 40", keys.length));

    string[] result;
    foreach (w; uniqSorted(written)) if (keys.canFind(w)) result ~= w;
    return result;
}

private struct FileVerdict
{
    bool reader;      // names a frame-published key in code
    size_t rawReads;  // raw "/api/changes" reads in code
}

private FileVerdict classify(string raw, const string[] flushed)
{
    const lit = blankComments(raw);
    FileVerdict v;
    foreach (k; flushed)
        if (lit.indexOf(`"` ~ k ~ `"`) >= 0) { v.reader = true; break; }
    v.rawReads = countOccurrences(lit, `"/api/changes"`)
               + countOccurrences(lit, `"/api/changes?`);
    return v;
}

unittest
{
    // ---- 1. floor + pin: the derived key set ----------------------------
    const flushed = frameFlushedKeys();
    assert(flushed == [
            "bgGpuUploads", "currentTypeChanged", "flushCount",
            "lastCurrentType", "lastLayerKinds", "lastSelDomains",
            "missedPublishers", "totalLayerActive", "totalLayerAdded",
            "totalLayerRemoved", "totalLayerRenamed", "totalLayerReordered",
            "totalLayerVisible", "totalSelItem",
        ],
        format("9526 pin: the frame-published /api/changes keys changed: %s", flushed));

    // ---- 2. positive control: the classifier flips ----------------------
    const offender = classify(
        "auto j = getJson(\"/api/changes\");\nauto a = j[\"totalLayerActive\"];\n", flushed);
    assert(offender.reader && offender.rawReads == 1,
        "9526 control: a raw read of a frame-published key must be an offence");
    const fenced = classify("auto a = settledChanges()[\"totalLayerActive\"];\n", flushed);
    assert(fenced.reader && fenced.rawReads == 0,
        "9526 control: a settled read must be clean");
    const commented = classify(
        "// getJson(\"/api/changes\")[\"totalLayerActive\"]\nint x;\n", flushed);
    assert(!commented.reader && commented.rawReads == 0,
        "9526 control: a comment is not a read");
    const syncOnly = classify(
        "auto d = getJson(\"/api/changes\")[\"deliveryCount\"];\n", flushed);
    assert(!syncOnly.reader && syncOnly.rawReads == 1,
        "9526 control: a synchronous-only key is not a frame-published read");
    const query = classify("auto j = getJson(\"/api/changes?x=1\");\n", flushed);
    assert(query.rawReads == 1, "9526 control: a query-string read is a raw read");

    // ---- 3. the needle over tests/*.d -----------------------------------
    string[] readers, offenders, rawFiles, rawHelpers;
    foreach (e; dirEntries(buildPath(repoRoot, "tests"), "*.d", SpanMode.shallow))
    {
        const name = baseName(e.name);
        if (name == "http_client.d") continue;
        const v = classify(readText(e.name), flushed);
        if (v.reader) readers ~= name;
        if (v.rawReads) rawFiles ~= name;
        if (v.reader && v.rawReads)
            offenders ~= format("%s (%s raw read(s))", name, v.rawReads);
        if (v.rawReads && name.indexOf("test_") != 0) rawHelpers ~= name;
    }
    sort(readers); sort(offenders); sort(rawHelpers);

    assert(readers.length == 15,
        format("9526 floor: %s suite files read a frame-published key, expected 15: %s",
            readers.length, readers));
    assert(readers == [
        "test_axis_slice.d",
        "test_bus_layer_scale_rebuild_rate.d",
        "test_change_bus.d",
        "test_edge_slice_symmetry.d",
        "test_fix_orientation.d",
        "test_item_sel_undo.d",
        "test_item_switch_hook_counters.d",
        "test_item_switch_hook_effects.d",
        "test_map_delta_counters.d",
        "test_mesh_cleanup.d",
        "test_nonmesh_items.d",
        "test_position_delta_seam_counters.d",
        "test_reduce.d",
        "test_retopology_lines_dots.d",
        "test_seltype_order.d",
    ], format("9526 reader inventory changed: %s", readers));
    assert(rawFiles.length >= 30,
        format("9526 floor: only %s files read /api/changes raw; the needle desynced?",
            rawFiles.length));
    assert(offenders.length == 0,
        format("9526: a file that reads a frame-published /api/changes key must read "
            ~ "it through http_client.settledChanges (frame fence first), not a raw "
            ~ "read: %s", offenders));
    assert(rawHelpers == ["composite_sampling_characterization_helpers.d"],
        format("9526: the raw-read helper modules changed: %s; a helper that hands "
            ~ "raw /api/changes JSON to a frame-published reader evades the needle",
            rawHelpers));

    // ---- 4. structural: the helper fences before it reads ---------------
    const client = readText(buildPath(repoRoot, "tests", "http_client.d"));
    const helper = blankComments(bodyAfter(client, "JSONValue settledChanges("));
    const fenceAt = helper.indexOf("frameFence(");
    const readAt = helper.indexOf(`"/api/changes"`);
    assert(fenceAt >= 0 && readAt > fenceAt,
        "9526: settledChanges must run frameFence before it reads /api/changes");
}
