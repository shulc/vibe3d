#!/usr/bin/env rdmd
// Interactive-tool perf benchmark runner (Phase 3+4 of
// doc/perf_harness_plan.md).
//
// Builds the optimized `perf` buildType, launches vibe3d in --perf mode,
// then for each matrix case:
//   1. reset + build a dense mesh   (/api/reset?type=grid&n=<N>)
//   2. select a deterministic vertex set (/api/select)
//   3. set the tool                  (/api/script tool.set move|rotate|scale)
//   4. configure the pipe            (/api/script tool.pipe.attr ...)
//   5. zero the perf counters        (/api/perf/reset)
//   6. synthesize + replay a gizmo drag (live camera + handle projection)
//   7. read the perf breakdown       (/api/perf)
//
// The drag is SYNTHESIZED at runtime (fetch the live camera, project the
// gizmo handle to pixels, build a JSON-Lines drag log) — never a frozen
// .log, which is camera-fragile. The projection/vec/matrix helpers live in
// lib/drag.d — a small self-contained copy of tests/drag_helpers.d (the
// test module declares `module drag_helpers;` and lives in a SEPARATE
// compilation universe from this rdmd unit; see doc/
// perf_tooling_consolidation_plan.md design decision D1 for why this stays
// its own copy rather than a shared import with tests/).
//
// HTTP plumbing, vibe3d process lifecycle, stats/JSON-shaping helpers, and
// the baseline/header shapes live in lib/http.d, lib/lifecycle.d,
// lib/stats.d, lib/baseline.d respectively (task 0197 — perf tooling
// consolidation). The invariant checkers and the case tables below stay
// here: they are this harness's policy, not shared plumbing.
//
// Output: a median/p95 table to stdout + tools/perf/results.json.
//
// This runner runs vibe3d SINGLE-THREADED on purpose — there is no -j.
// A perf measurement must not contend for CPU with a sibling instance, so
// one vibe3d at a time is the only correct configuration.
//
// Usage:
//   ./run.d                          # full matrix on the default mesh
//   ./run.d --no-build               # skip the dub build
//   ./run.d --keep                   # leave vibe3d running after the run
//   ./run.d --n 64                   # smaller grid (faster smoke run)
//   ./run.d --mesh-size 316          # alias for --n
//   ./run.d --subdivcube 7           # use subdivideCube(levels) instead of grid
//   ./run.d --repeats 5              # R measured drags per case (default 5)
//   ./run.d move rotate              # subset: only cases whose name contains a token
//   ./run.d --http-port 8090         # custom port (default 8088)
//   ./run.d --viewport 1280x960      # fixed viewport (default 1280x960)

import std.algorithm : sort, canFind, map, sum, min, max;
import std.array     : array, appender, join, split;
import std.conv      : to;
static import std.file;
import std.file      : exists, mkdirRecurse;
import std.format    : format;
import std.getopt    : getopt, config;
import std.json      : parseJSON, JSONValue, JSONType;
import std.math      : sqrt, sin, cos, tan, PI, fabs;
import std.net.curl  : get, post, HTTP, CurlException;
import std.path      : absolutePath, buildPath, buildNormalizedPath, dirName;
import std.process   : execute, executeShell, spawnProcess, Config, Pid,
                       environment, ProcessException;
import std.range     : enumerate, iota;
import std.socket    : Socket;
import std.stdio     : writeln, writefln, write, stdout, stderr, File, stdin;
import std.string    : strip, startsWith;

import core.thread        : Thread;
import core.time          : msecs, dur;
import core.stdc.stdlib   : exit;
import core.sys.posix.signal : signal, SIGINT, SIGTERM;
import core.sys.posix.signal : kill;

import lib.http;
import lib.drag;
import lib.lifecycle;
import lib.stats;
import lib.baseline;
import lib.history;
import lib.flame;

// ---------------------------------------------------------------------------
// Selection-index builders (the grid-index math itself — gridIdx/gridFace —
// now lives in lib.drag; these builders are matrix "policy": WHICH verts/
// faces make up each named selection, kept alongside casesForTool/
// cmdIndices below rather than moved).
// ---------------------------------------------------------------------------

// One vertex near the grid centre.
int[] selSingle(int n) {
    int c = n / 2;
    return [gridIdx(n, c, c)];
}

// A full row (a "loop"/ring across the plane): the centre Z-row.
int[] selRing(int n) {
    int i = n / 2;
    int[] r;
    foreach (j; 0 .. n + 1) r ~= gridIdx(n, i, j);
    return r;
}

// Half the verts: every vertex with i < (N+1)/2 (the lower-Z half).
int[] selHalf(int n) {
    int side = n + 1;
    int[] r;
    foreach (i; 0 .. side / 2)
        foreach (j; 0 .. side)
            r ~= gridIdx(n, i, j);
    return r;
}

// "whole" — empty selection ⇒ the whole mesh moves (universal transform
// rule, CLAUDE.md). We model it as NO selection call; the caller skips
// /api/select for whole.

// Faces in the lower-Z half: rows i < n/2, all columns j in 0..n.
int[] faceHalf(int n) {
    int[] r;
    foreach (i; 0 .. n / 2)
        foreach (j; 0 .. n)
            r ~= gridFace(n, i, j);
    return r;
}

// ---------------------------------------------------------------------------
// Matrix definition
// ---------------------------------------------------------------------------

enum Tool { move, rotate, scale }

struct PipeAttr { string stage, name, value; }

struct Case {
    string  name;       // e.g. "move/baseline", "rotate/falloff=radial"
    Tool    tool;
    string  selection;  // "whole" | "single" | "ring" | "half"
    PipeAttr[] attrs;   // pipe configuration applied on top of a clean reset
    string  note;       // human-readable axis varied
}

// Build the baseline + one-axis-at-a-time cases for a tool. The radius/size
// for linear & radial falloff is set RELATIVE to the [-1,1] mesh extent so
// the falloff weight actually varies across the selected verts (a radius far
// larger than the mesh, or zero, makes falloff a no-op and defeats the
// benchmark). The grid spans [-2 units] across; a radius/size of ~1.0 puts
// the falloff boundary mid-plane.
Case[] casesForTool(Tool t) {
    string tname = t.to!string;
    Case[] cs;

    // Baseline: falloff none, symmetry off, acen auto, snap off, whole mesh.
    cs ~= Case(tname ~ "/baseline", t, "whole", [], "baseline");

    // Falloff variations. linear/radial get an explicit size relative to the
    // mesh extent; element/screen auto-size to the selection on type switch.
    // Falloff with the WHOLE mesh + a mid-plane radius makes weights vary.
    cs ~= Case(tname ~ "/falloff=linear", t, "whole",
        [PipeAttr("falloff", "type", "linear"),
         PipeAttr("falloff", "start", "0,0,-1"),
         PipeAttr("falloff", "end",   "0,0,1")],
        "falloff=linear (start/end span the plane)");
    cs ~= Case(tname ~ "/falloff=radial", t, "whole",
        [PipeAttr("falloff", "type", "radial"),
         PipeAttr("falloff", "center", "0,0,0"),
         PipeAttr("falloff", "size",   "1,1,1")],
        "falloff=radial (r=1 mid-plane)");
    cs ~= Case(tname ~ "/falloff=element", t, "single",
        [PipeAttr("falloff", "type", "element"),
         PipeAttr("falloff", "dist", "1.0")],
        "falloff=element (range 1.0, single-vert anchor)");
    cs ~= Case(tname ~ "/falloff=screen", t, "whole",
        [PipeAttr("falloff", "type", "screen"),
         PipeAttr("falloff", "screenSize", "300")],
        "falloff=screen (300px)");
    cs ~= Case(tname ~ "/falloff=cylinder", t, "whole",
        [PipeAttr("falloff", "type", "cylinder"),
         PipeAttr("falloff", "center", "0,0,0"),
         PipeAttr("falloff", "size",   "1,1,1"),
         PipeAttr("falloff", "axis",   "0,1,0")],
        "falloff=cylinder (r=1 about Y)");
    // Selection falloff: selected=1, unselected decays by BFS hop distance
    // over mesh edges — needs an actual selection (whole-mesh ⇒ all weight 1,
    // trivial), so use the half selection. `dist` is the BFS step count.
    cs ~= Case(tname ~ "/falloff=selection", t, "half",
        [PipeAttr("falloff", "type", "selection"),
         PipeAttr("falloff", "dist", "4")],
        "falloff=selection (BFS 4 hops, half sel)");
    // falloff=lasso is intentionally NOT benched: the lasso polygon is painted
    // by an interactive gesture and has NO numeric setAttr (no `lassoPoly`
    // key), so a headless lasso has <3 points and lassoWeight early-returns 1.0
    // — a hollow case measuring nothing. Add it when a lassoPoly attr exists.

    // Symmetry X.
    cs ~= Case(tname ~ "/symmetry=X", t, "whole",
        [PipeAttr("symmetry", "enabled", "true"),
         PipeAttr("symmetry", "axis", "x")],
        "symmetry=X");

    // ACEN variations (selection / local). The whole-mesh baseline uses Auto;
    // selection/local need an actual selection so the centre differs.
    cs ~= Case(tname ~ "/acen=selection", t, "half",
        [PipeAttr("actionCenter", "mode", "select")],
        "acen=selection (half sel)");
    cs ~= Case(tname ~ "/acen=local", t, "half",
        [PipeAttr("actionCenter", "mode", "local")],
        "acen=local (half sel)");

    // Snap cases — MOVE ONLY. Cursor snap (grid/vertex via SnapPacket +
    // snap.snapCursor) is only consulted by MoveTool.applySnapToDelta during a
    // drag. RotateTool/ScaleTool never call snapCursor — they have their own
    // angle/scale-increment snapping (rotate.d lastSnappedAngle), a separate
    // path not driven by the SnapStage. Enabling SnapStage on rotate/scale is a
    // no-op, so generating snap cases there would test nothing. KNOWN SCOPE
    // LIMITATION: this matrix does not cover rotate/scale increment snapping.
    if (t == Tool.move) {
        // Snap to grid (pure arithmetic quantization — legitimately sub-µs).
        cs ~= Case(tname ~ "/snap=grid", t, "whole",
            [PipeAttr("snap", "enabled", "true"),
             PipeAttr("snap", "types", "grid")],
            "snap=grid");

        // Snap to vertex (element). Exercises the per-vertex candidate walk
        // over the whole mesh (the most expensive snap query — O(verts) every
        // drag frame). Token "vertex" per SnapStage's setAttr("types", ...).
        cs ~= Case(tname ~ "/snap=vertex", t, "whole",
            [PipeAttr("snap", "enabled", "true"),
             PipeAttr("snap", "types", "vertex")],
            "snap=vertex (per-vertex candidate walk)");

        // Remaining snap types, isolated, to measure each candidate walk.
        // edge/edgeCenter scan all edges; polygon/polyCenter scan all faces;
        // workplane is O(1) arithmetic (like grid). Each is set as the SOLE
        // enabled type so snapQuery attributes only that type's cost.
        foreach (snapType; ["edge", "edgeCenter", "polygon",
                            "polyCenter", "workplane"]) {
            cs ~= Case(tname ~ "/snap=" ~ snapType, t, "whole",
                [PipeAttr("snap", "enabled", "true"),
                 PipeAttr("snap", "types", snapType)],
                "snap=" ~ snapType);
        }
    }

    // Selection variations off the baseline config.
    cs ~= Case(tname ~ "/selection=single", t, "single", [], "selection=single");
    cs ~= Case(tname ~ "/selection=ring",   t, "ring",   [], "selection=ring");
    cs ~= Case(tname ~ "/selection=half",   t, "half",   [], "selection=half");

    return cs;
}

// ---------------------------------------------------------------------------
// Drag synthesis per tool (handle-projection recipe matching the drag tests)
// ---------------------------------------------------------------------------

struct Drag { int x0, y0, x1, y1; }

// Build the mouse-down + drag-end pixels for grabbing the right handle of
// each tool's gizmo, pivoted at `pivot`. Mirrors the recipes pinned by
// tests/test_tool_{move_plane,rotate_view_wholemesh,scale}_drag.d.
Drag dragFor(Tool t, Vec3 pivot, const ref Viewport vp) {
    final switch (t) {
        case Tool.move: {
            // XY plane circle: center + axisX*0.75*size + axisY*0.75*size,
            // normal Z (handler.d MoveHandler). Drag screen-down 60px.
            float size = gizmoSize(pivot, vp);
            Vec3 circle = Vec3(pivot.x + size * 0.75f, pivot.y + size * 0.75f, pivot.z);
            float cx, cy;
            if (!projectToWindow(circle, vp, cx, cy)) return Drag(0,0,0,0);
            return Drag(cast(int)cx, cast(int)cy, cast(int)cx, cast(int)cy + 60);
        }
        case Tool.rotate: {
            // View ring ~99px around the gizmo center; grab at +95px,
            // drag tangentially -70px (test_tool_rotate_view_wholemesh).
            float cx, cy;
            if (!projectToWindow(pivot, vp, cx, cy)) return Drag(0,0,0,0);
            int x0 = cast(int)(cx + 95);
            int y0 = cast(int)cy;
            return Drag(x0, y0, x0, y0 - 70);
        }
        case Tool.scale: {
            // X-arrow shaft: center+axisX*(size/7) → center+axisX*size.
            // Grab 70% along, drag ~80px in projected +X (test_tool_scale).
            float size = gizmoSize(pivot, vp);
            Vec3 start = Vec3(pivot.x + size / 7.0f, pivot.y, pivot.z);
            Vec3 end   = Vec3(pivot.x + size,        pivot.y, pivot.z);
            float sx1, sy1, sx2, sy2;
            if (!projectToWindow(start, vp, sx1, sy1)) return Drag(0,0,0,0);
            if (!projectToWindow(end,   vp, sx2, sy2)) return Drag(0,0,0,0);
            int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
            int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
            double sdx = sx2 - sx1, sdy = sy2 - sy1;
            double sLen = sqrt(sdx*sdx + sdy*sdy);
            if (sLen < 1.0) return Drag(0,0,0,0);
            int x1 = x0 + cast(int)(80.0 * sdx / sLen);
            int y1 = y0 + cast(int)(80.0 * sdy / sLen);
            return Drag(x0, y0, x1, y1);
        }
    }
}

// ---------------------------------------------------------------------------
// Per-case execution
// ---------------------------------------------------------------------------

enum CaseStatus { OK, SKIP, ERROR }

struct CaseResult {
    string     name;
    string     note;
    CaseStatus status;
    string     detail;
    // medians/p95 across R repeats, in microseconds.
    double     kernelMedianUs, kernelP95Us;
    double     pipeMedianUs;
    double     pipeSymmetryMedianUs;   // pipe.symmetry stage cost (for I2)
    double     snapQueryMedianUs;      // snap.d:snapCursor cost (informational)
    double     snapQuerySumUs;         // last-repeat snapQuery sum (informational)
    long       snapQueryCount;         // last-repeat snapCursor call count (for I5)
    string     dominantStage;
    long       vertsTouched;     // sum from the last repeat
    long       kernelInternalP95Ns;  // /api/perf's own per-sample p95
    JSONValue  lastBreakdown;    // full /api/perf from the last repeat
    bool       isCommand;        // true for delete/remove command cases
    long       commandApplyCount;// commandApply.count from last repeat (for I6)
}

// Apply the selection (or clear it for "whole").
bool applySelection(ref Case c, int n) {
    if (c.selection == "whole") {
        // Empty selection ⇒ whole mesh. Clear any prior selection.
        return selectVertices([]);
    }
    int[] idx;
    if      (c.selection == "single") idx = selSingle(n);
    else if (c.selection == "ring")   idx = selRing(n);
    else if (c.selection == "half")   idx = selHalf(n);
    else return false;
    return selectVertices(idx);
}

// Run ONE drag, return the /api/perf breakdown after it. Throws on a
// play-events failure. Re-fetches the LIVE action-centre pivot immediately
// before building the drag, so a prior drag that relocated the pivot
// (ACEN select/local click-away-relocate) doesn't leave subsequent drags
// projecting onto a stale gizmo position.
JSONValue runOneDrag(Tool t, const ref Viewport vp, CameraState cam) {
    Vec3 pivot = fetchActionCenter();
    Drag d = dragFor(t, pivot, vp);
    if (d.x0 == 0 && d.y0 == 0 && d.x1 == 0 && d.y1 == 0)
        throw new Exception("handle projected off-camera");
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              d.x0, d.y0, d.x1, d.y1, 20);
    perfReset();
    playAndWait(log);
    return perfRead();
}

// medianOf/p95Of now live in lib.stats.

// From a /api/perf breakdown, the dominant pipeline stage by sum_ns.
string dominantStage(JSONValue perf) {
    static immutable string[] stages = [
        "pipeSymmetry", "pipeSnap", "pipeAcen", "pipeAxis", "pipeFalloff",
        "kernelApply", "symmetryMirror", "cacheInvalidate", "gpuUpload",
        "snapQuery",
    ];
    string best = "-";
    long bestNs = -1;
    foreach (s; stages) {
        if (s !in perf) continue;
        long ns = perf[s]["sum_ns"].integer;
        if (ns > bestNs) { bestNs = ns; best = s; }
    }
    return best;
}

long sumNs(JSONValue perf, string cat) {
    return (cat in perf) ? perf[cat]["sum_ns"].integer : 0;
}

CaseResult runCase(ref Case c, int n, string meshType, int repeats) {
    CaseResult res;
    res.name = c.name;
    res.note = c.note;

    // 1. fresh mesh
    resetMesh(meshType, n);

    // 2. selection
    if (!applySelection(c, n)) {
        res.status = CaseStatus.ERROR;
        res.detail = "selection failed";
        return res;
    }

    // 3. tool
    if (!script("tool.set " ~ c.tool.to!string)) {
        res.status = CaseStatus.ERROR;
        res.detail = "tool.set failed";
        return res;
    }

    // 4. pipe config. The argstring parser the /api/script command bridge
    // uses rejects bare commas (vec3 values like "0,0,0"), so the value is
    // always double-quoted — harmless for scalar values (radial/true/grid).
    foreach (a; c.attrs) {
        if (!script(format(`tool.pipe.attr %s %s "%s"`, a.stage, a.name, a.value))) {
            res.status = CaseStatus.SKIP;
            res.detail = format("pipe attr rejected: %s %s %s",
                                a.stage, a.name, a.value);
            return res;
        }
    }

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Warmup drag (discarded). Verify geometry actually moves. runOneDrag
    // re-fetches the live evaluated gizmo pivot (authoritative under any
    // ACEN mode) so the handle projection lands on the gizmo.
    Vec3 probeBefore = vertexPos(0);
    try {
        runOneDrag(c.tool, vp, cam);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "warmup drag: " ~ e.msg;
        return res;
    }
    Vec3 probeAfter = vertexPos(0);
    // For a partial selection v0 may legitimately not move; check ANY motion
    // via the perf vertsTouched counter from the warmup instead.
    auto warmupPerf = perfRead();
    long warmTouched = ("vertsTouched" in warmupPerf)
        ? warmupPerf["vertsTouched"]["sum"].integer : 0;
    bool moved = warmTouched > 0;
    if (!moved) {
        // Fall back to a position check on a vertex inside the selection.
        Vec3 d = probeAfter - probeBefore;
        moved = sqrt(dot(d, d)) > 1e-5f;
    }
    // FAIL-FAST on an uninstrumented binary: geometry moved but the PerfProbe
    // counters saw nothing → ./vibe3d was not built with --build=perf (only
    // that buildType defines versions=["PerfProbe"]; every other build
    // compiles the g_perf calls to no-ops). Every later case + invariant
    // would emit meaningless zeros (the historical `run_all --no-build`
    // failure mode), so abort the whole run naming the actual cause.
    if (moved && warmTouched == 0 && sumNs(warmupPerf, "kernelApply") == 0)
        throw new Exception(
            "./vibe3d lacks PerfProbe instrumentation (counters stayed 0 "
            ~ "through a real warmup drag) — it was not built with "
            ~ "--build=perf. Re-run without --no-build so the runner builds "
            ~ "the perf binary, or build it yourself: dub build --build=perf "
            ~ "--compiler=" ~ LDC2);
    if (!moved) {
        res.status = CaseStatus.ERROR;
        res.detail = "drag moved no geometry (vertsTouched=0) — handle miss?";
        return res;
    }

    // R measured repeats.
    double[] kernelTot;   // total kernelApply ns per drag (sum across frames)
    double[] pipeTot;     // total pipeTotal ns per drag
    double[] pipeSymTot;  // total pipeSymmetry ns per drag
    double[] snapQTot;    // total snapQuery ns per drag (for I5)
    JSONValue last;
    foreach (r; 0 .. repeats) {
        JSONValue perf;
        try {
            perf = runOneDrag(c.tool, vp, cam);
        } catch (Exception e) {
            res.status = CaseStatus.ERROR;
            res.detail = format("repeat %d drag: %s", r, e.msg);
            return res;
        }
        kernelTot  ~= cast(double)sumNs(perf, "kernelApply")  / 1000.0;
        pipeTot    ~= cast(double)sumNs(perf, "pipeTotal")    / 1000.0;
        pipeSymTot ~= cast(double)sumNs(perf, "pipeSymmetry") / 1000.0;
        snapQTot   ~= cast(double)sumNs(perf, "snapQuery")    / 1000.0;
        last = perf;
    }

    res.status = CaseStatus.OK;
    res.kernelMedianUs       = medianOf(kernelTot);
    res.kernelP95Us          = p95Of(kernelTot);
    res.pipeMedianUs         = medianOf(pipeTot);
    res.pipeSymmetryMedianUs = medianOf(pipeSymTot);
    res.snapQueryMedianUs    = medianOf(snapQTot);
    res.snapQuerySumUs       = cast(double)sumNs(last, "snapQuery") / 1000.0;
    res.snapQueryCount       = ("snapQuery" in last)
        ? last["snapQuery"]["count"].integer : 0;
    res.dominantStage  = dominantStage(last);
    res.vertsTouched   = ("vertsTouched" in last)
        ? last["vertsTouched"]["sum"].integer : 0;
    res.kernelInternalP95Ns = ("kernelApply" in last)
        ? last["kernelApply"]["p95_ns"].integer : 0;
    res.lastBreakdown = last;
    return res;
}

// ---------------------------------------------------------------------------
// One-shot command cases (mesh.delete / mesh.remove)
//
// Unlike the drag cases, these are discrete destructive /api/command calls.
// Their whole cost lands in the new commandApply category (count==1 per
// command); they never touch kernelApply. Because delete is destructive the
// mesh is rebuilt every repeat, and the selection + perfReset happen OUTSIDE
// the measured window (perfReset zeroes commandApply right before the single
// command POST).
// ---------------------------------------------------------------------------

struct CmdCase {
    string name;       // "delete/polygons/whole"
    string commandId;  // "mesh.delete" | "mesh.remove"
    string mode;       // "vertices" | "edges" | "polygons"
    string selection;  // "whole" | "half"
}

// Selection indices for a command case. "whole" ⇒ empty (whole mesh).
// "half" ⇒ selHalf for vertices, faceHalf for polygons. Edges only ever
// use "whole" (no edge-index selection helper).
int[] cmdIndices(ref CmdCase c, int n) {
    if (c.selection == "whole") return [];
    if (c.mode == "vertices")   return selHalf(n);
    if (c.mode == "polygons")   return faceHalf(n);
    return [];   // edges/half — unused (edges only uses whole)
}

// Matrix: for each of mesh.delete / mesh.remove, exercise vertices(whole,
// half) / edges(whole) / polygons(whole, half) ⇒ 10 cases. Names use the
// SHORT verb, e.g. "delete/vertices/whole".
CmdCase[] commandCases() {
    CmdCase[] cs;
    struct Spec { string id, verb; }
    foreach (s; [Spec("mesh.delete", "delete"), Spec("mesh.remove", "remove")]) {
        cs ~= CmdCase(s.verb ~ "/vertices/whole", s.id, "vertices", "whole");
        cs ~= CmdCase(s.verb ~ "/vertices/half",  s.id, "vertices", "half");
        cs ~= CmdCase(s.verb ~ "/edges/whole",    s.id, "edges",    "whole");
        cs ~= CmdCase(s.verb ~ "/polygons/whole", s.id, "polygons", "whole");
        cs ~= CmdCase(s.verb ~ "/polygons/half",  s.id, "polygons", "half");
    }
    return cs;
}

CaseResult runCommandCase(ref CmdCase c, int n, string meshType, int repeats) {
    CaseResult res;
    res.name = c.name;
    res.isCommand = true;
    res.note = c.mode ~ " " ~ c.selection;

    double[] applyUs;
    JSONValue last;
    long lastCount = 0;
    long beforeFaces = 0, afterFaces = 0;
    long beforeVerts = 0, afterVerts = 0;

    foreach (r; 0 .. repeats) {
        // Rebuild the cage every repeat — delete is destructive.
        resetMesh(meshType, n);
        // Selection (+ edit mode side effect) is OUTSIDE the measured window.
        if (!selectMode(c.mode, cmdIndices(c, n))) {
            res.status = CaseStatus.ERROR;
            res.detail = "selection failed";
            return res;
        }
        auto mb = modelInfo();
        beforeFaces = mb.faceCount;
        beforeVerts = mb.vertexCount;
        perfReset();
        if (!postCommand(c.commandId)) {
            res.status = CaseStatus.ERROR;
            res.detail = "command failed";
            return res;
        }
        auto perf = perfRead();
        applyUs ~= cast(double)sumNs(perf, "commandApply") / 1000.0;
        lastCount = ("commandApply" in perf)
            ? perf["commandApply"]["count"].integer : 0;
        auto ma = modelInfo();
        afterFaces = ma.faceCount;
        afterVerts = ma.vertexCount;
        last = perf;
    }

    // Topology-change sanity: a delete/remove must actually alter the cage.
    // Vertices/Polygons modes drop faces; whole-mesh Edges dissolve merges
    // adjacent faces and cleans up degree-2 verts WITHOUT reducing the face
    // count (the boundary walk reconstructs the same perimeter, only the 4
    // corner verts dissolve). So accept a change in EITHER face OR vertex
    // count, not a strict face reduction.
    bool changed = beforeFaces > 0 &&
                   (afterFaces < beforeFaces || afterVerts != beforeVerts);
    if (!changed) {
        res.status = CaseStatus.ERROR;
        res.detail = format("no geometry changed (faces %d→%d, verts %d→%d)",
                            beforeFaces, afterFaces, beforeVerts, afterVerts);
        return res;
    }

    res.status = CaseStatus.OK;
    // Reuse the kernel median/p95 fields to carry the commandApply cost so
    // the existing table / results / baseline / absolute-compare code works
    // unchanged.
    res.kernelMedianUs    = medianOf(applyUs);
    res.kernelP95Us       = p95Of(applyUs);
    res.dominantStage     = "commandApply";
    res.commandApplyCount = lastCount;
    res.lastBreakdown     = last;
    return res;
}

// ---------------------------------------------------------------------------
// `frames` subcommand — FrameProbe scenarios (task 0195,
// doc/frame_probe_scenarios_plan.md Phase 4; extended to 6 scenarios in
// task 0200, doc/frame_scenarios_ci_plan.md). Each scenario exercises the
// main-loop phase timers end to end through a real `--build=perf`/
// `--build=perf-count` binary; each resets the frame ring right before its
// measured window so the reported window is exactly that scenario's frames.
// ---------------------------------------------------------------------------

struct FrameScenarioResult {
    string     name;
    CaseStatus status;
    string     detail;
    FrameStats stats;
    // Deterministic, build-independent counters for the task 0200
    // scenarios — -1 means "not applicable to this scenario".
    long       subpatchRebuilds = -1;  // subpatchPreview.count (tab-subpatch, F-I5)
    long       lassoSelected    = -1;  // selected polygon count (lasso-dense, F-I6b)
    long       undoApplies      = -1;  // undoApply counter (undo-spam, F-I7)
}

// Number of per-gesture move-drag undo entries `undo-spam` builds before
// firing `N` undos. Referenced by both `runUndoSpam` (drives the gestures
// + undos) and `checkFramesInvariants` (F-I7's exact-N assertion).
enum int kUndoSpamN = 8;

// F-I5's bound on `subpatchPreview.count` while the preview is held with no
// further toggle. Expected value is 1 (one rebuild at Tab-on); K=2 leaves a
// small margin without hiding a real per-frame rebuild storm (which would
// scale with frameCount, not sit at a small constant).
enum long K_SUBPATCH_REBUILD = 2;

FrameScenarioResult* findFrameScenario(FrameScenarioResult[] results, string name) {
    foreach (ref r; results)
        if (r.name == name) return &r;
    return null;
}

// settleAfterPlay/settleAfterReset now live in lib.http.

// orbit-dense — Alt+LMB orbit around a dense mesh, no selection, no tool.
// Exercises the draw path; F-I1 target is 0 mesh-cache rebuilds (camera-only
// invalidation must never touch mesh caches / trigger a GPU upload).
FrameScenarioResult runOrbitDense(int n, string meshType) {
    FrameScenarioResult res;
    res.name = "orbit-dense";

    resetMesh(meshType, n);
    selectVertices([]);   // no stale selection from a prior scenario

    auto cam = fetchCamera();
    int x0 = cam.vpX + cast(int)(cam.width  * 0.20);
    int y0 = cam.vpY + cast(int)(cam.height * 0.55);
    int x1 = cam.vpX + cast(int)(cam.width  * 0.80);
    int y1 = cam.vpY + cast(int)(cam.height * 0.20);
    string log = buildOrbitLog(cam.vpX, cam.vpY, cam.width, cam.height,
                               x0, y0, x1, y1, 60);

    settleAfterReset();
    framesReset();
    try {
        playAndWait(log);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "orbit drag: " ~ e.msg;
        return res;
    }
    settleAfterPlay();

    res.stats = fetchFrames();
    if (res.stats.empty) {
        res.status = CaseStatus.ERROR;
        res.detail = "no frames recorded — vibe3d not built with --build=perf?";
        return res;
    }
    res.status = CaseStatus.OK;
    return res;
}

// hover-sweep — plain mouse sweep across a dense mesh (no button), default
// edit mode. Exercises per-frame pickVertices/pickEdges/pickFaces.
FrameScenarioResult runHoverSweep(int n, string meshType) {
    FrameScenarioResult res;
    res.name = "hover-sweep";

    resetMesh(meshType, n);
    selectVertices([]);

    auto cam = fetchCamera();
    int x0 = cam.vpX + cast(int)(cam.width  * 0.15);
    int y0 = cam.vpY + cast(int)(cam.height * 0.50);
    int x1 = cam.vpX + cast(int)(cam.width  * 0.85);
    int y1 = cam.vpY + cast(int)(cam.height * 0.50);
    string log = buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                               x0, y0, x1, y1, 80);

    settleAfterReset();
    framesReset();
    try {
        playAndWait(log);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "hover sweep: " ~ e.msg;
        return res;
    }
    settleAfterPlay();

    res.stats = fetchFrames();
    if (res.stats.empty) {
        res.status = CaseStatus.ERROR;
        res.detail = "no frames recorded — vibe3d not built with --build=perf?";
        return res;
    }
    res.status = CaseStatus.OK;
    return res;
}

// drag-falloff — whole-mesh move drag with a radial falloff configured.
// Exercises the tool/events phases with per-vertex falloff evaluation every
// motion event; F-I2 (steady-state alloc/frame) is read off this scenario.
FrameScenarioResult runDragFalloff(int n, string meshType) {
    FrameScenarioResult res;
    res.name = "drag-falloff";

    resetMesh(meshType, n);
    if (!selectVertices([])) {   // whole mesh
        res.status = CaseStatus.ERROR;
        res.detail = "selection failed";
        return res;
    }
    if (!script("tool.set move")) {
        res.status = CaseStatus.ERROR;
        res.detail = "tool.set move failed";
        return res;
    }
    // Radial falloff, mid-plane radius — same recipe as the ops matrix's
    // move/falloff=radial case (casesForTool above).
    foreach (a; [PipeAttr("falloff", "type",   "radial"),
                PipeAttr("falloff", "center", "0,0,0"),
                PipeAttr("falloff", "size",   "1,1,1")]) {
        if (!script(format(`tool.pipe.attr %s %s "%s"`, a.stage, a.name, a.value))) {
            res.status = CaseStatus.SKIP;
            res.detail = format("pipe attr rejected: %s %s %s", a.stage, a.name, a.value);
            return res;
        }
    }

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Builds a fresh drag log targeting the CURRENT live gizmo pivot — like
    // `runOneDrag` above, re-fetched immediately before each drag so a prior
    // drag relocating the pivot (the whole mesh translated) doesn't leave a
    // later drag projecting onto a stale gizmo position.
    Drag delegate() liveDrag = () {
        Vec3 pivot = fetchActionCenter();
        return dragFor(Tool.move, pivot, vp);
    };

    Drag d0 = liveDrag();
    if (d0.x0 == 0 && d0.y0 == 0 && d0.x1 == 0 && d0.y1 == 0) {
        res.status = CaseStatus.ERROR;
        res.detail = "handle projected off-camera";
        return res;
    }
    // Step count matches the ops matrix's own runOneDrag default (20) —
    // no need to diverge from that established convention.
    string warmupLog = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                    d0.x0, d0.y0, d0.x1, d0.y1, 20);

    // Warmup drag (discarded) — mirrors the ops matrix's runCase: the FIRST
    // falloff drag over a fresh dense mesh pays one-time setup costs
    // (symmetry/snap/falloff pipeline first-evaluate, cache first-resize)
    // that would otherwise land in the measured window and false-trip F-I4.
    try {
        playAndWait(warmupLog);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "warmup drag: " ~ e.msg;
        return res;
    }
    settleAfterReset();

    Drag d1 = liveDrag();
    if (d1.x0 == 0 && d1.y0 == 0 && d1.x1 == 0 && d1.y1 == 0) {
        res.status = CaseStatus.ERROR;
        res.detail = "handle projected off-camera after warmup";
        return res;
    }
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              d1.x0, d1.y0, d1.x1, d1.y1, 20);

    framesReset();
    try {
        playAndWait(log);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "falloff drag: " ~ e.msg;
        return res;
    }
    settleAfterPlay();

    res.stats = fetchFrames();
    if (res.stats.empty) {
        res.status = CaseStatus.ERROR;
        res.detail = "no frames recorded — vibe3d not built with --build=perf?";
        return res;
    }
    res.status = CaseStatus.OK;
    return res;
}

// tab-subpatch — Tab-toggle subpatch preview ON over the WHOLE cage (empty
// Polygons selection ⇒ mesh.subpatch_toggle flips every face, per
// subpatch_toggle.d), then HOLD across a no-op hover sweep with no further
// toggle. `SubpatchPreview.rebuildIfStale` (mesh.d) rebuilds the OSD preview
// exactly once — at activation — then short-circuits on its up-to-date
// guard (`sourceMeshAddr`/`sourceVersion`/`depth` unchanged) for every
// subsequent frame while held; F-I5 asserts `subpatchPreview.count` stays a
// small bounded constant (expected 1), catching a per-frame rebuild storm
// (sibling of the O(F²) `isSubpatch` regression).
FrameScenarioResult runTabSubpatch(int n, string meshType) {
    FrameScenarioResult res;
    res.name = "tab-subpatch";

    resetMesh(meshType, n);
    if (!selectMode("polygons", [])) {
        res.status = CaseStatus.ERROR;
        res.detail = "selectMode polygons failed";
        return res;
    }
    settleAfterReset();
    framesReset();
    perfReset();

    if (!postCommand("mesh.subpatch_toggle")) {
        res.status = CaseStatus.ERROR;
        res.detail = "mesh.subpatch_toggle failed";
        return res;
    }

    auto cam = fetchCamera();
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    // No-op-ish hover sweep — holds the preview across many frames without
    // touching mesh/selection state (no further toggle, no button).
    string log = buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                               cx - 20, cy, cx + 20, cy, 60);
    try {
        playAndWait(log);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "hold sweep: " ~ e.msg;
        return res;
    }
    settleAfterPlay();

    res.stats = fetchFrames();
    if (res.stats.empty) {
        res.status = CaseStatus.ERROR;
        res.detail = "no frames recorded — vibe3d not built with --build=perf?";
        return res;
    }

    auto perf = perfRead();
    res.subpatchRebuilds = ("subpatchPreview" in perf)
        ? perf["subpatchPreview"]["count"].integer : 0;

    res.status = CaseStatus.OK;
    return res;
}

// lasso-dense — Polygons-mode RMB lasso covering the central 60% of the
// viewport over a dense grid. Selection is Marks-class (change_bus.d), NOT
// Geometry/Position, so it must not trigger a mesh-cache rebuild / GPU
// re-upload (F-I6a); F-I6b confirms the lasso actually engaged (selected
// polygon count > 0) — the retired `test_perf_picking_lasso` signal,
// exercising the GPU-pick-buffer-driven visibility + strict "all face verts
// inside polygon" hit-test (app.d ~5899).
FrameScenarioResult runLassoDense(int n, string meshType) {
    FrameScenarioResult res;
    res.name = "lasso-dense";

    resetMesh(meshType, n);
    if (!selectMode("polygons", [])) {
        res.status = CaseStatus.ERROR;
        res.detail = "selectMode polygons failed";
        return res;
    }
    // Look at the grid from BELOW (see lib.http.setCameraElevation's doc
    // comment): the default above-plane camera trips app.d's Polygons-lasso
    // CPU backface pre-check against `grid`'s actual (Newell-method) face
    // winding, selecting zero faces regardless of lasso size — a scenario
    // camera-setup quirk, not a mesh/winding bug this task fixes.
    setCameraElevation(-0.4);

    auto cam = fetchCamera();
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    int halfW = cast(int)(cam.width  * 0.30);
    int halfH = cast(int)(cam.height * 0.30);
    string log = buildLassoLog(cam.vpX, cam.vpY, cam.width, cam.height,
                               cx, cy, halfW, halfH, 20);

    settleAfterReset();
    framesReset();
    try {
        playAndWait(log);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "lasso drag: " ~ e.msg;
        return res;
    }
    settleAfterPlay();

    res.stats = fetchFrames();
    if (res.stats.empty) {
        res.status = CaseStatus.ERROR;
        res.detail = "no frames recorded — vibe3d not built with --build=perf?";
        return res;
    }

    res.lassoSelected = fetchSelectedFaceCount();

    res.status = CaseStatus.OK;
    return res;
}

// undo-spam — `kUndoSpamN` small whole-mesh `move` gestures (each a
// per-gesture undo entry, outside the measured window), then `kUndoSpamN`
// paced `POST /api/undo` calls inside the measured window. All N undos land
// on Case A (Model-class entry found from the tail — see
// doc/frame_scenarios_ci_plan.md's design note), so `Cat.undoApply`
// (bumped once per successful `undo()`, command_history.d:1090) gives an
// exact count immune to main-loop frame batching (F-I7), unlike
// `meshCacheRebuilds` which only bounds `[1, N]` when multiple undos land
// in one batch.
FrameScenarioResult runUndoSpam(int n, string meshType) {
    FrameScenarioResult res;
    res.name = "undo-spam";

    resetMesh(meshType, n);
    if (!selectVertices([])) {   // whole mesh
        res.status = CaseStatus.ERROR;
        res.detail = "selection failed";
        return res;
    }
    if (!script("tool.set move")) {
        res.status = CaseStatus.ERROR;
        res.detail = "tool.set move failed";
        return res;
    }

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // N per-gesture move drags — OUTSIDE the measured window. Each is a
    // separate mouse-down/motion/up gesture, so each commits its own
    // undo-able Model-class entry (per-gesture commit granularity).
    foreach (i; 0 .. kUndoSpamN) {
        try {
            runOneDrag(Tool.move, vp, cam);
        } catch (Exception e) {
            res.status = CaseStatus.ERROR;
            res.detail = format("gesture %d: %s", i, e.msg);
            return res;
        }
    }
    settleAfterReset();
    framesReset();
    perfReset();

    foreach (i; 0 .. kUndoSpamN) {
        postUndo();
        Thread.sleep(30.msecs);   // pace so each undo lands in its own frame
    }
    settleAfterPlay();

    res.stats = fetchFrames();
    if (res.stats.empty) {
        res.status = CaseStatus.ERROR;
        res.detail = "no frames recorded — vibe3d not built with --build=perf?";
        return res;
    }

    auto perf = perfRead();
    res.undoApplies = ("undoApply" in perf) ? perf["undoApply"]["count"].integer : 0;

    res.status = CaseStatus.OK;
    return res;
}

// msFromNs now lives in lib.stats.

void printFramesTable(FrameScenarioResult[] results) {
    writeln();
    writeln("=== frame scenario results ===");
    writefln("%-16s %10s %10s %10s %10s %8s %8s %8s %10s %8s %8s %8s",
             "scenario", "p50 (ms)", "p95 (ms)", "p99 (ms)", "max (ms)",
             "hitch16", "hitch33", "rebuild", "gcAlloc(B)",
             "subRbld", "lassoSel", "undoApp");
    writeln("".replicate(96 + 30));
    foreach (r; results) {
        final switch (r.status) {
            case CaseStatus.OK:
                writefln("%-16s %10.3f %10.3f %10.3f %10.3f %8d %8d %8d %10d %8s %8s %8s",
                         r.name, msFromNs(r.stats.p50Ns), msFromNs(r.stats.p95Ns),
                         msFromNs(r.stats.p99Ns), msFromNs(r.stats.maxNs),
                         r.stats.hitch16, r.stats.hitch33,
                         r.stats.meshCacheRebuilds, r.stats.gcAllocBytes,
                         r.subpatchRebuilds >= 0 ? r.subpatchRebuilds.to!string : "-",
                         r.lassoSelected    >= 0 ? r.lassoSelected.to!string    : "-",
                         r.undoApplies      >= 0 ? r.undoApplies.to!string      : "-");
                break;
            case CaseStatus.SKIP:
                writefln("%-16s  SKIP  %s", r.name, r.detail);
                break;
            case CaseStatus.ERROR:
                writefln("%-16s  ERROR %s", r.name, r.detail);
                break;
        }
    }
    writeln("".replicate(96));
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        writefln("  %-16s worst-frame breakdown: total=%.3fms events=%.3fms tool=%.3fms" ~
                 " cache=%.3fms draw=%.3fms upload=%.3fms ui=%.3fms gcAlloc=%dB gcColl=%d",
                 r.name, msFromNs(r.stats.worst.totalNs), msFromNs(r.stats.worst.eventNs),
                 msFromNs(r.stats.worst.toolNs), msFromNs(r.stats.worst.cacheNs),
                 msFromNs(r.stats.worst.drawNs), msFromNs(r.stats.worst.uploadNs),
                 msFromNs(r.stats.worst.uiNs), r.stats.worst.gcAllocBytes,
                 r.stats.worst.gcCollections);
        writefln("  %-16s F-I2 steady-state alloc/frame (whole-frame, main-thread, " ~
                 "post-warmup): %d B", r.name, r.stats.steadyMaxAllocBytes);
    }
}

void writeFramesResultsJson(string path, string meshType, int n, long faceCount,
                            string viewport, FrameScenarioResult[] results) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "perf",` ~ "\n"));
    a.put(format(`  "compiler": "ldc2 1.42.0",` ~ "\n"));
    a.put(format(`  "host": "%s",` ~ "\n", Socket.hostName));
    a.put(format(`  "meshType": "%s",` ~ "\n", meshType));
    a.put(format(`  "n": %d,` ~ "\n", n));
    a.put(format(`  "faceCount": %d,` ~ "\n", faceCount));
    a.put(format(`  "viewport": "%s",` ~ "\n", viewport));
    a.put(`  "scenarios": [` ~ "\n");
    foreach (i, r; results) {
        a.put("    {\n");
        a.put(format(`      "name": "%s",` ~ "\n", r.name));
        a.put(format(`      "status": "%s",` ~ "\n", r.status.to!string));
        if (r.status == CaseStatus.OK) {
            a.put(format(`      "frameCount": %d,` ~ "\n", r.stats.frameCount));
            a.put(format(`      "p50Ns": %d,` ~ "\n", r.stats.p50Ns));
            a.put(format(`      "p95Ns": %d,` ~ "\n", r.stats.p95Ns));
            a.put(format(`      "p99Ns": %d,` ~ "\n", r.stats.p99Ns));
            a.put(format(`      "maxNs": %d,` ~ "\n", r.stats.maxNs));
            a.put(format(`      "hitch16": %d,` ~ "\n", r.stats.hitch16));
            a.put(format(`      "hitch33": %d,` ~ "\n", r.stats.hitch33));
            a.put(format(`      "meshCacheRebuilds": %d,` ~ "\n", r.stats.meshCacheRebuilds));
            a.put(format(`      "gcAllocBytes": %d,` ~ "\n", r.stats.gcAllocBytes));
            a.put(format(`      "gcCollections": %d,` ~ "\n", r.stats.gcCollections));
            if (r.subpatchRebuilds >= 0)
                a.put(format(`      "subpatchRebuilds": %d,` ~ "\n", r.subpatchRebuilds));
            if (r.lassoSelected >= 0)
                a.put(format(`      "lassoSelected": %d,` ~ "\n", r.lassoSelected));
            if (r.undoApplies >= 0)
                a.put(format(`      "undoApplies": %d,` ~ "\n", r.undoApplies));
            a.put(format(`      "steadyMaxAllocBytes": %d` ~ "\n", r.stats.steadyMaxAllocBytes));
        } else {
            a.put(format(`      "detail": "%s"` ~ "\n", r.detail.replaceQuotes));
        }
        a.put(i + 1 < results.length ? "    },\n" : "    }\n");
    }
    a.put("  ]\n}\n");
    std.file.write(path, a.data);
}

// Build & launch (LDC2/g_repoRoot/dubBuildPerf/killStaleVibe/launchVibe) now
// live in lib.lifecycle.

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

void printTable(CaseResult[] results) {
    writeln();
    writeln("=== perf results ===");
    writefln("%-28s %12s %12s %12s %10s %-16s %10s",
             "case", "kApply med", "kApply p95", "pipe med", "snapQ med",
             "dominant", "verts");
    writefln("%-28s %12s %12s %12s %10s %-16s %10s",
             "", "(us)", "(us)", "(us)", "(us)", "stage", "touched");
    writeln("".replicate(108));
    foreach (r; results) {
        final switch (r.status) {
            case CaseStatus.OK:
                writefln("%-28s %12.2f %12.2f %12.2f %10.2f %-16s %10d",
                         r.name, r.kernelMedianUs, r.kernelP95Us,
                         r.pipeMedianUs, r.snapQueryMedianUs,
                         r.dominantStage, r.vertsTouched);
                break;
            case CaseStatus.SKIP:
                writefln("%-28s  SKIP  %s", r.name, r.detail);
                break;
            case CaseStatus.ERROR:
                writefln("%-28s  ERROR %s", r.name, r.detail);
                break;
        }
    }
    int ok = 0, skip = 0, err = 0;
    foreach (r; results) final switch (r.status) {
        case CaseStatus.OK:    ok++;   break;
        case CaseStatus.SKIP:  skip++; break;
        case CaseStatus.ERROR: err++;  break;
    }
    writeln("".replicate(108));
    writefln("Totals: OK=%d  SKIP=%d  ERROR=%d  (of %d cases)",
             ok, skip, err, results.length);
}

// jsonNum/replicate now live in lib.stats.

void writeResultsJson(string path, string meshType, int n, long faceCount,
                      string viewport, int repeats, CaseResult[] results) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "perf",` ~ "\n"));
    a.put(format(`  "compiler": "ldc2 1.42.0",` ~ "\n"));
    a.put(format(`  "host": "%s",` ~ "\n", Socket.hostName));
    a.put(format(`  "meshType": "%s",` ~ "\n", meshType));
    a.put(format(`  "n": %d,` ~ "\n", n));
    a.put(format(`  "faceCount": %d,` ~ "\n", faceCount));
    a.put(format(`  "viewport": "%s",` ~ "\n", viewport));
    a.put(format(`  "repeats": %d,` ~ "\n", repeats));
    // Optional reproducibility stamp from the environment (no wall-clock
    // from inside D, per the plan — determinism).
    a.put(format(`  "stamp": "%s",` ~ "\n",
                 environment.get("VIBE3D_PERF_STAMP", "")));
    a.put(`  "cases": [` ~ "\n");
    foreach (i, r; results) {
        a.put("    {\n");
        a.put(format(`      "name": "%s",` ~ "\n", r.name));
        a.put(format(`      "note": "%s",` ~ "\n", r.note));
        a.put(format(`      "status": "%s",` ~ "\n", r.status.to!string));
        if (r.status == CaseStatus.OK) {
            a.put(format(`      "kernelMedianUs": %s,` ~ "\n", jsonNum(r.kernelMedianUs)));
            a.put(format(`      "kernelP95Us": %s,` ~ "\n", jsonNum(r.kernelP95Us)));
            a.put(format(`      "pipeMedianUs": %s,` ~ "\n", jsonNum(r.pipeMedianUs)));
            a.put(format(`      "dominantStage": "%s",` ~ "\n", r.dominantStage));
            a.put(format(`      "vertsTouched": %d,` ~ "\n", r.vertsTouched));
            a.put(format(`      "kernelInternalP95Ns": %d,` ~ "\n",
                         r.kernelInternalP95Ns));
            a.put(`      "breakdown": ` ~ r.lastBreakdown.toString() ~ "\n");
        } else {
            a.put(format(`      "detail": "%s"` ~ "\n",
                         r.detail.replaceQuotes));
        }
        a.put(i + 1 < results.length ? "    },\n" : "    }\n");
    }
    a.put("  ]\n}\n");
    std.file.write(path, a.data);
}

string replaceQuotes(string s) {
    auto a = appender!string();
    foreach (ch; s) {
        if (ch == '"') a.put("\\\"");
        else a.put(ch);
    }
    return a.data;
}

// ---------------------------------------------------------------------------
// Phase 5 — regression detection (two levels: absolute baseline + relative
// invariants). See doc/perf_harness_plan.md §7.
//
//   * ABSOLUTE  — compare each case's kernelApply/pipeTotal median against a
//                 captured baseline.json. Machine-bound, so it is GATED by a
//                 build/mesh/viewport-match guard: a baseline captured on a
//                 different config is NOT compared (warn + skip), falling back
//                 to relative invariants only.
//   * RELATIVE  — same-run ratios that do not drift with hardware. These run
//                 ALWAYS (no baseline / mismatched machine included). Generous
//                 thresholds: gross-regression guards, not tight benchmarks.
// ---------------------------------------------------------------------------

// RunHeader/currentHeader/headerMismatch and the BaselineCase/Baseline
// reader-writer pair now live in lib.baseline. writeBaselineJson here is a
// thin CaseResult[]→lib.baseline.BaselineCase[] row mapper (lib.baseline
// cannot depend on run.d's CaseResult — that's this harness's own case-table
// policy type — so the boundary is this small adapter, not a re-derivation
// of the JSON writer itself).
void writeBaselineJson(string path, RunHeader h, CaseResult[] results) {
    lib.baseline.BaselineCase[] rows;
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;  // only OK cases are baselined
        rows ~= lib.baseline.BaselineCase(r.name, r.kernelMedianUs, r.kernelP95Us,
                                          r.pipeMedianUs, r.dominantStage,
                                          r.vertsTouched);
    }
    lib.baseline.writeBaselineJson(path, h, rows);
}

// Find an OK case result by exact name.
CaseResult* findCase(CaseResult[] results, string name) {
    foreach (ref r; results)
        if (r.name == name && r.status == CaseStatus.OK) return &r;
    return null;
}

// ----- Relative invariant thresholds -----------------------------------
//
// K1_FALLOFF/K2_SYM_OFF_US/K3_SYMMETRY/K4_PIPE_OVERHEAD now live in
// lib.baseline (tuned from observed n=64 ratios with generous margin — see
// that module for the derivation notes).
//
// I5 — snap is actually engaged: when a snap=* case is active, snapCursor
// must have been CALLED during the drag (count > 0). We check the call
// COUNT, not its time, because grid snap is legitimately near-free (pure
// arithmetic quantization, sub-µs) while vertex/element snap does an
// O(verts) candidate walk — a time threshold would false-fail healthy grid
// snap. count==0 with snap enabled means the hot query got bypassed (the
// exact gap snapQuery was added to catch).

struct Invariant {
    string id;        // "I1", "I2", ...
    string desc;      // human-readable
    bool   pass;
    string detail;    // actual ratio vs threshold
}

// Run the relative invariants over the results. Per-tool where applicable.
Invariant[] checkInvariants(CaseResult[] results) {
    Invariant[] inv;

    // I1 — falloff loop bounded: radial kernelApply ≤ K1 × baseline (per tool).
    foreach (tool; ["move", "rotate", "scale"]) {
        auto base = findCase(results, tool ~ "/baseline");
        auto rad  = findCase(results, tool ~ "/falloff=radial");
        if (base is null || rad is null || base.kernelMedianUs <= 0) continue;
        double ratio = rad.kernelMedianUs / base.kernelMedianUs;
        bool ok = ratio <= K1_FALLOFF;
        inv ~= Invariant("I1", format("%s falloff=radial kernelApply ≤ %.1f× baseline",
                                      tool, K1_FALLOFF), ok,
                         format("ratio=%.2f× (%.1f/%.1f µs) threshold %.1f×",
                                ratio, rad.kernelMedianUs, base.kernelMedianUs,
                                K1_FALLOFF));
    }

    // I2 — symmetry disabled is free: pipeSymmetry sum ≈ 0 in every case whose
    // name is NOT symmetry=X (i.e. symmetry OFF). Catches the SymmetryStage
    // running/allocating (rebuildPairing O(n log n)) when disabled.
    {
        double worst = 0;
        string worstCase = "-";
        foreach (r; results) {
            if (r.status != CaseStatus.OK) continue;
            if (r.name.canFind("symmetry=X")) continue;   // symmetry ON
            if (r.pipeSymmetryMedianUs > worst) {
                worst = r.pipeSymmetryMedianUs;
                worstCase = r.name;
            }
        }
        bool ok = worst <= K2_SYM_OFF_US;
        inv ~= Invariant("I2",
            format("symmetry OFF ⇒ pipeSymmetry ≤ %.0f µs", K2_SYM_OFF_US), ok,
            format("worst=%.2f µs (%s) threshold %.0f µs",
                   worst, worstCase, K2_SYM_OFF_US));
    }

    // I3 — symmetry mirror bounded: symmetry=X kernelApply ≤ K3 × baseline
    // (per tool). Mirroring at most ~doubles the moving set.
    foreach (tool; ["move", "rotate", "scale"]) {
        auto base = findCase(results, tool ~ "/baseline");
        auto sym  = findCase(results, tool ~ "/symmetry=X");
        if (base is null || sym is null || base.kernelMedianUs <= 0) continue;
        double ratio = sym.kernelMedianUs / base.kernelMedianUs;
        bool ok = ratio <= K3_SYMMETRY;
        inv ~= Invariant("I3", format("%s symmetry=X kernelApply ≤ %.1f× baseline",
                                      tool, K3_SYMMETRY), ok,
                         format("ratio=%.2f× (%.1f/%.1f µs) threshold %.1f×",
                                ratio, sym.kernelMedianUs, base.kernelMedianUs,
                                K3_SYMMETRY));
    }

    // I4 — pipeline overhead bounded: baseline pipeTotal ≤ K4 × kernelApply
    // (per tool). Catches per-frame pipeline cost dominating the transform.
    foreach (tool; ["move", "rotate", "scale"]) {
        auto base = findCase(results, tool ~ "/baseline");
        if (base is null || base.kernelMedianUs <= 0) continue;
        double ratio = base.pipeMedianUs / base.kernelMedianUs;
        bool ok = ratio <= K4_PIPE_OVERHEAD;
        inv ~= Invariant("I4", format("%s baseline pipeTotal ≤ %.1f× kernelApply",
                                      tool, K4_PIPE_OVERHEAD), ok,
                         format("ratio=%.2f× (%.1f/%.1f µs) threshold %.1f×",
                                ratio, base.pipeMedianUs, base.kernelMedianUs,
                                K4_PIPE_OVERHEAD));
    }

    // I5 — snap is engaged: for every snap=* case present, snapCursor must
    // have been called during the drag (count > 0). This pins the gap that
    // motivated the snapQuery category: pipeSnap only times the config-packet
    // SnapStage (~0), so snap silently doing no per-frame work would pass
    // every other invariant. Checks call COUNT not time — grid snap is
    // legitimately sub-µs. Per snap case (per tool).
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        if (!r.name.canFind("snap=")) continue;
        bool ok = r.snapQueryCount > 0;
        inv ~= Invariant("I5",
            format("%s snapQuery engaged (snapCursor called)", r.name),
            ok,
            format("snapQuery count=%d, sum=%.2f µs (median %.2f µs)",
                   r.snapQueryCount, r.snapQuerySumUs, r.snapQueryMedianUs));
    }

    // I6 — command apply is timed: for every one-shot command case
    // (mesh.delete / mesh.remove), commandApply must have been recorded
    // (count > 0). Analogous to I5's "snap engaged" count check — pins that
    // the dispatch-site scope timer actually fired for the discrete command.
    foreach (r; results) {
        if (r.status != CaseStatus.OK || !r.isCommand) continue;
        bool ok = r.commandApplyCount > 0;
        inv ~= Invariant("I6", format("%s commandApply timed", r.name), ok,
            format("commandApply count=%d, median=%.1f µs",
                   r.commandApplyCount, r.kernelMedianUs));
    }

    return inv;
}

// ---------------------------------------------------------------------------
// Counter invariants F-I1 / F-I2 / F-I4 / F-I5 / F-I6 / F-I7 for the
// `frames` subcommand (task 0195 Phase 5; F-I5/6/7 + `ciMode` added task
// 0200). Reuses the SAME `Invariant` struct as `checkInvariants` above — no
// separate type. ALWAYS run (no header/host gate): every F-Ix here is a
// machine-stable, build-independent control-flow count. F-I1/F-I5/F-I6/F-I7
// GATE the exit code; F-I2 is always RECORDED, NON-GATING (see the plan's
// Risks section — a nonzero whole-frame alloc floor is expected from ImGui
// chrome rebuilding every frame). F-I4 GATES on orbit-dense/hover-sweep in
// DEV runs (drag-falloff is always RECORDED there too — it legitimately
// trips a collection), but when `ciMode` is true F-I4 is RECORDED/
// NON-GATING for EVERY scenario: it false-positives on the CI host (0195/
// 0197 evidence) and hardening it is task 0202's job, not this one's —
// `--ci` routes around it rather than fixing it.
// ---------------------------------------------------------------------------

Invariant[] checkFramesInvariants(FrameScenarioResult[] results, bool ciMode) {
    Invariant[] inv;

    // F-I1 — GATING. orbit-dense must trigger ZERO mesh-cache rebuilds: the
    // camera-reprojection branch (vertexCache.needsUpdate(vp)) is gated
    // `!doingCameraDrag` and is SKIPPED ENTIRELY during an orbit, so only
    // the two genuinely mesh-driven branches (Geometry/Position) would ever
    // bump the counter — and neither fires on a pure camera drag.
    {
        auto r = findFrameScenario(results, "orbit-dense");
        if (r !is null && r.status == CaseStatus.OK) {
            bool ok = r.stats.meshCacheRebuilds == 0;
            inv ~= Invariant("F-I1", "orbit-dense: 0 mesh-cache rebuilds", ok,
                format("meshCacheRebuilds=%d", r.stats.meshCacheRebuilds));
        }
    }

    // F-I4 — GATING for orbit-dense / hover-sweep in DEV runs; RECORDED/
    // NON-GATING for EVERY scenario when `ciMode` (host-flaky GC metric,
    // task 0202 will stabilize it). Neither orbit-dense nor hover-sweep
    // touches per-vertex mesh work (camera-only reprojection / handle
    // hit-testing), so 0 GC collections during the measured window is a
    // real invariant there in dev. drag-falloff is RECORDED, NON-GATING
    // even outside `--ci`: it legitimately trips a collection (the
    // falloff/drag hot path allocates enough to cross a GC pool threshold)
    // — a real product finding, not a harness bug. `pass` is unconditionally
    // true whenever non-gating so this entry can never flip the run's exit
    // code, but the count is still reported so the regression stays
    // visible; the drag-path allocation follow-up (task 0202) will chase it
    // to a stable floor. Counts, not times, so this is hardware-independent;
    // a nonzero count means a stop-the-world collection stalled the main
    // loop (triggered by ANY thread — see the GC-metric-asymmetry note in
    // perf_probe.d).
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        bool gating = !ciMode && r.name != "drag-falloff";
        bool ok = gating ? r.stats.gcCollections == 0 : true;
        string label = gating
            ? format("%s: 0 GC collections", r.name)
            : format("%s: GC collections (RECORDED, non-gating%s)", r.name,
                     ciMode ? " — --ci" : "");
        inv ~= Invariant("F-I4", label, ok,
            format("gcCollections=%d", r.stats.gcCollections));
    }

    // F-I2 — RECORDED, NON-GATING. drag-falloff's steady-state whole-frame
    // main-thread alloc/frame (post-warmup, from FrameProbe.toJson's
    // `steadyMaxAllocBytes`). `pass` is unconditionally true so this entry
    // can never flip the run's exit code — it is a measurement to watch,
    // not a regression gate, until the ImGui-chrome alloc floor is chased
    // to a stable number in a follow-up task.
    {
        auto r = findFrameScenario(results, "drag-falloff");
        if (r !is null && r.status == CaseStatus.OK) {
            inv ~= Invariant("F-I2",
                "drag-falloff: steady-state alloc/frame (RECORDED, non-gating)",
                true,
                format("steadyMaxAllocBytes=%d B (whole-frame main-thread alloc, " ~
                       "NOT drag-only — see the plan's Risks section)",
                       r.stats.steadyMaxAllocBytes));
        }
    }

    // F-I5 — GATING. tab-subpatch: subpatchPreview.count is bounded
    // 1..K_SUBPATCH_REBUILD while the preview is held with no further
    // toggle — NOT proportional to frameCount. Catches a per-frame rebuild
    // storm (sibling of the O(F²) `isSubpatch` regression).
    {
        auto r = findFrameScenario(results, "tab-subpatch");
        if (r !is null && r.status == CaseStatus.OK) {
            bool ok = r.subpatchRebuilds >= 1 && r.subpatchRebuilds <= K_SUBPATCH_REBUILD;
            inv ~= Invariant("F-I5",
                format("tab-subpatch: subpatchPreview rebuilds bounded (1..%d)",
                       K_SUBPATCH_REBUILD),
                ok, format("subpatchPreview.count=%d", r.subpatchRebuilds));
        }
    }

    // F-I6a — GATING. lasso-dense: a selection change publishes
    // MeshEditScope.Marks (change_bus.d), not Geometry/Position, so it must
    // trigger ZERO mesh-cache rebuilds / GPU re-uploads. Empirically
    // confirmed on first run (see the task's Risks note); would fall back
    // to a loose `<= K` bound if a small nonzero constant ever showed up.
    // F-I6b — GATING. lasso-dense actually engaged: selected polygon
    // count > 0 (a viewport-covering lasso over a dense grid always selects
    // hundreds of faces, on any rasterizer — no exact count asserted, GPU
    // pick-buffer rasterization is not portable across GPUs).
    {
        auto r = findFrameScenario(results, "lasso-dense");
        if (r !is null && r.status == CaseStatus.OK) {
            bool ok6a = r.stats.meshCacheRebuilds == 0;
            inv ~= Invariant("F-I6a",
                "lasso-dense: 0 mesh-cache rebuilds (Marks-class selection)",
                ok6a, format("meshCacheRebuilds=%d", r.stats.meshCacheRebuilds));

            bool ok6b = r.lassoSelected > 0;
            inv ~= Invariant("F-I6b", "lasso-dense: lasso engaged (selected polygons > 0)",
                ok6b, format("selectedFaces=%d", r.lassoSelected));
        }
    }

    // F-I7 — GATING. undo-spam: undoApply counter == kUndoSpamN exactly.
    // Immune to main-loop frame batching (unlike meshCacheRebuilds, which
    // only bounds [1, N] when multiple undos land in one batch).
    {
        auto r = findFrameScenario(results, "undo-spam");
        if (r !is null && r.status == CaseStatus.OK) {
            bool ok = r.undoApplies == kUndoSpamN;
            inv ~= Invariant("F-I7", format("undo-spam: undoApply count == %d", kUndoSpamN),
                ok, format("undoApply=%d", r.undoApplies));
        }
    }

    return inv;
}

struct AbsRegression {
    string name;
    string metric;     // "kernelApply" | "pipeTotal"
    double baseUs, curUs, growth;   // growth = cur/base - 1
}

// ABS_NOISE_FLOOR_US now lives in lib.baseline (below this baseline median
// (µs), a metric is in the timing noise floor and a percentage-growth
// comparison is meaningless).

// Compare current results to a baseline. Flags a regression when the
// kernelApply median grows by more than `tolerance` (e.g. 0.30 ⇒ +30%).
//
// kernelApply is the only metric compared absolutely: it is the actual
// transform cost and is stable run-to-run (observed full-matrix spread on the
// heavy cases ~1.02–1.06×, well under +30%). pipeTotal is deliberately NOT
// compared absolutely — it is dominated by the per-frame ActionCenter pivot
// recompute (pipeAcen) which jitters 40–90% run-to-run and is not a transform
// regression; pipeline overhead is instead watched RELATIVELY by invariant I4
// (pipeTotal / kernelApply ratio), which is hardware-stable.
//
// Cases whose baseline kernelApply is below ABS_NOISE_FLOOR_US are skipped:
// they touch a handful of verts (selection=single/falloff=element ⇒ ~0.1µs)
// and a percentage comparison there is pure timer granularity. The slow
// acen=local case is kernelApply-cheap (its cost is pipeAcen, not compared) so
// it never trips an invariant; it still appears in results/baseline as-is.
AbsRegression[] checkAbsolute(CaseResult[] results, Baseline base,
                              double tolerance) {
    AbsRegression[] regs;
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        // snap cases recompute WHICH verts land on grid points each run, so
        // their moving-set size (and thus kernelApply) varies run-to-run and is
        // not a stable absolute metric — skip them (snap is still in the table).
        if (r.name.canFind("snap=")) continue;
        auto p = r.name in base.byName;
        if (p is null) continue;   // new case absent from baseline — not a regression
        if (p.kernelMedianUs < ABS_NOISE_FLOOR_US) continue;  // noise floor
        double g = r.kernelMedianUs / p.kernelMedianUs - 1.0;
        if (g > tolerance)
            regs ~= AbsRegression(r.name, "kernelApply",
                                  p.kernelMedianUs, r.kernelMedianUs, g);
    }
    return regs;
}

// ---------------------------------------------------------------------------
// Absolute p99/hitch budgets for `frames` (task 0195 Phase 6) — same
// baseline-host header-guard pattern as the ops matrix's absolute lane
// above, but stored in a SEPARATE `frames_baseline.json` (shares the
// `RunHeader` shape) so it never collides with the ops `baseline.json`.
// Generous FIXED ceilings (not baseline-relative growth, unlike the ops
// lane) — a gross-smoothness regression guard, not a tight benchmark.
// ---------------------------------------------------------------------------

// K_FRAMES_P99_MS/K_FRAMES_HITCH33 and the FramesBaselineCase/FramesBaseline
// reader-writer pair now live in lib.baseline. writeFramesBaselineJson here
// is a thin FrameScenarioResult[]→lib.baseline.FramesBaselineCase[] row
// mapper (same seam-adapter rationale as writeBaselineJson above).
void writeFramesBaselineJson(string path, RunHeader h, FrameScenarioResult[] results) {
    lib.baseline.FramesBaselineCase[] rows;
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        rows ~= lib.baseline.FramesBaselineCase(r.name, r.stats.p99Ns,
                                                 r.stats.hitch16, r.stats.hitch33);
    }
    lib.baseline.writeFramesBaselineJson(path, h, rows);
}

struct FramesAbsRegression {
    string name;
    string metric;   // "p99" | "hitch33"
    double budget;
    double actual;
}

// Fixed generous ceilings, checked against the CURRENT run only (the stored
// baseline's role is the header-match guard + a captured reference point
// for humans reading frames_baseline.json — the pass/fail line itself is
// against K_FRAMES_P99_MS / K_FRAMES_HITCH33, not baseline-relative growth,
// per the plan's "start at 33ms p99, hitch ≤ K" design).
FramesAbsRegression[] checkFramesAbsolute(FrameScenarioResult[] results) {
    FramesAbsRegression[] regs;
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        double p99Ms = msFromNs(r.stats.p99Ns);
        if (p99Ms > K_FRAMES_P99_MS)
            regs ~= FramesAbsRegression(r.name, "p99", K_FRAMES_P99_MS, p99Ms);
        if (r.stats.hitch33 > K_FRAMES_HITCH33)
            regs ~= FramesAbsRegression(r.name, "hitch33",
                                        cast(double)K_FRAMES_HITCH33,
                                        cast(double)r.stats.hitch33);
    }
    return regs;
}

// ---------------------------------------------------------------------------
// `frames` subcommand entry point (task 0195 Phase 4-6). Launches vibe3d
// exactly like the ops matrix (shares killStaleVibe/launchVibe/resetMesh),
// runs the three scenarios (or a requested-substring subset), prints the
// table + worst-frame breakdowns, writes frames_results.json, then runs the
// counter invariants (always) + absolute p99/hitch budgets (header-guarded).
// ---------------------------------------------------------------------------

int runFramesSubcommand(string meshType, int meshParam, string viewport, ushort port,
                        string[] requested, bool updateFramesBaseline, bool noAbsolute,
                        bool noBuild, bool ciMode) {
    killStaleVibe();
    string logPath = "/tmp/vibe3d_perf_frames.log";
    writefln("Launching vibe3d --test --perf --http-port %d --viewport %s ...",
             port, viewport);
    if (!launchVibe(port, viewport, logPath)) return 1;
    writeln("  vibe3d is up");

    resetMesh(meshType, meshParam);
    auto mi = modelInfo();
    writefln("Mesh: %s param=%d → %d verts, %d faces",
             meshType, meshParam, mi.vertexCount, mi.faceCount);

    alias ScenarioFn = FrameScenarioResult function(int, string);
    struct ScenarioSpec { string name; ScenarioFn run; }
    ScenarioSpec[] allScenarios = [
        ScenarioSpec("orbit-dense",  &runOrbitDense),
        ScenarioSpec("hover-sweep",  &runHoverSweep),
        ScenarioSpec("drag-falloff", &runDragFalloff),
        ScenarioSpec("tab-subpatch", &runTabSubpatch),
        ScenarioSpec("lasso-dense",  &runLassoDense),
        ScenarioSpec("undo-spam",    &runUndoSpam),
    ];

    ScenarioSpec[] scenarios;
    foreach (sc; allScenarios) {
        bool keepIt = requested.length == 0;
        foreach (req; requested) if (sc.name.canFind(req)) keepIt = true;
        if (keepIt) scenarios ~= sc;
    }
    if (scenarios.length == 0) {
        writeln("no frame scenarios matched");
        return 0;
    }

    FrameScenarioResult[] results;
    foreach (sc; scenarios) {
        write("  running ", sc.name, " ... ");
        stdout.flush();
        auto r = sc.run(meshParam, meshType);
        final switch (r.status) {
            case CaseStatus.OK:    writeln("OK");                  break;
            case CaseStatus.SKIP:  writeln("SKIP (", r.detail, ")"); break;
            case CaseStatus.ERROR: writeln("ERROR (", r.detail, ")"); break;
        }
        results ~= r;
    }

    printFramesTable(results);

    string outPath = buildPath(g_repoRoot, "tools", "perf", "frames_results.json");
    writeFramesResultsJson(outPath, meshType, meshParam, mi.faceCount, viewport, results);
    writeln("\nWrote ", outPath);

    // Header shares the ops RunHeader shape; `repeats` is not meaningful for
    // `frames` (each scenario runs once) and is NOT compared by
    // headerMismatch, so any placeholder value is harmless.
    auto curHeader = currentHeader(meshType, meshParam, mi.faceCount, viewport, 1);
    string baselinePath = buildPath(g_repoRoot, "tools", "perf", "frames_baseline.json");

    if (updateFramesBaseline) {
        writeFramesBaselineJson(baselinePath, curHeader, results);
        writeln("Wrote ", baselinePath, " (frames baseline updated from this run)");
        noAbsolute = true;
    }

    int failures = 0;

    // 1. Counter invariants — ALWAYS run (machine-stable). F-I1/F-I5/F-I6/
    // F-I7 gate (F-I4 too, in dev); F-I2 is always recorded, non-gating; in
    // `--ci` mode F-I4 is recorded, non-gating for every scenario (see
    // checkFramesInvariants).
    writeln();
    writeln("=== frame counter invariants (machine-stable) ===");
    if (ciMode)
        writeln("  (--ci: GATING = F-I1/F-I5/F-I6/F-I7 only; F-I2/F-I4 RECORDED)");
    auto invs = checkFramesInvariants(results, ciMode);
    int invFail = 0;
    foreach (iv; invs) {
        writefln("  [%s] %-4s %-52s  %s",
                 iv.pass ? "PASS" : "FAIL", iv.id, iv.desc, iv.detail);
        if (!iv.pass) { invFail++; failures++; }
    }
    if (invs.length == 0)
        writeln("  (no invariants applicable — no OK scenario results)");

    // 2. Absolute p99/hitch budgets — gated by the build-match guard.
    writeln();
    writeln("=== absolute p99/hitch budgets (baseline-host only) ===");
    int absFail = 0;
    if (noAbsolute && !updateFramesBaseline) {
        writeln("  skipped (--no-absolute)");
    } else if (updateFramesBaseline) {
        writeln("  skipped (baseline was just written by --update-frames-baseline)");
    } else if (!exists(baselinePath)) {
        writeln("  no baseline (", baselinePath, " absent) — run with",
                " --update-frames-baseline to capture one");
    } else {
        auto base = loadFramesBaseline(baselinePath);
        string mismatch = headerMismatch(base.header, curHeader);
        if (mismatch.length > 0) {
            writefln("  build mismatch — skipping absolute comparison: %s", mismatch);
            writeln("  relative counter invariants only.");
        } else {
            auto regs = checkFramesAbsolute(results);
            if (regs.length == 0) {
                writefln("  no regressions (p99 <= %.0fms, hitch33 <= %d)",
                         K_FRAMES_P99_MS, K_FRAMES_HITCH33);
            } else {
                foreach (rg; regs) {
                    writefln("  [FAIL] %-16s %-8s budget=%.2f actual=%.2f",
                             rg.name, rg.metric, rg.budget, rg.actual);
                    absFail++;
                    failures++;
                }
            }
        }
    }

    // 3. Final verdict.
    writeln();
    writeln("=== verdict ===");
    writefln("  counter invariants: %d/%d passed", invs.length - invFail, invs.length);
    if (absFail > 0)
        writefln("  absolute regressions: %d", absFail);
    writeln(failures == 0 ? "  OVERALL: PASS" : "  OVERALL: FAIL");

    // History (task 0197 Phase 4) — one line per `frames` run, {scenario:
    // p99Ms}. Best-effort: a history-append failure must never fail the run.
    try {
        double[string] p99ByScenario;
        foreach (r; results)
            if (r.status == CaseStatus.OK)
                p99ByScenario[r.name] = msFromNs(r.stats.p99Ns);
        lib.history.appendHistory(g_repoRoot, curHeader, p99ByScenario);
    } catch (Exception e) {
        stderr.writeln("warning: history append failed: ", e.msg);
    }

    if (!noBuild)
        writeln("\nNOTE: ./vibe3d is now the perf buildType binary — run "
                ~ "`dub build` to restore the modeling debug binary before "
                ~ "reusing it with --no-build test runs.");

    return failures == 0 ? 0 : failures;
}

// ---------------------------------------------------------------------------
// `flame` subcommand (task 0197 Phase 3) — absorbs tools/perf_subpatch/
// run.d's perf-record-attach logic, generalized to any CURRENT ops case
// (drag or one-shot command) or `frames` scenario. Drives the target
// through the SAME synthesis the `ops`/`frames` runners use (reuses
// casesForTool/commandCases/applySelection/dragFor/buildDragLog/
// buildOrbitLog/buildHoverLog) so the profiled workload matches the
// measured one. Builds+launches its OWN profile-fp binary (lib.flame.
// dubBuildProfileFp) rather than the PerfProbe `perf` buildType — see
// lib.flame's header comment for why. tab-subpatch coverage (the scenario
// perf_subpatch originally targeted) lands once `frames tab-subpatch`
// exists (task 0200/F6); today `flame` covers any case/scenario this file
// already knows about.
// ---------------------------------------------------------------------------

int runFlameSubcommand(string target, string meshType, int meshParam,
                       string viewport, ushort port, int freq, int captureSecs,
                       bool noBuild) {
    if (target.length == 0) {
        stderr.writeln("flame: missing <case-or-scenario-name> argument "
                       ~ "(e.g. `./run.d flame move/baseline` or "
                       ~ "`./run.d flame orbit-dense`)");
        return 1;
    }

    // Match `target` against an ops drag case, an ops command case, or a
    // frames scenario name — whichever matches, generalized (Phase 3 §2).
    // Validated BEFORE any build/launch so a typo fails fast.
    Case[] allCases;
    foreach (t; [Tool.move, Tool.rotate, Tool.scale])
        allCases ~= casesForTool(t);
    Case* dragCase = null;
    foreach (ref c; allCases) if (c.name == target) { dragCase = &c; break; }

    CmdCase[] allCmds = commandCases();
    CmdCase* cmdCase = null;
    foreach (ref cc; allCmds) if (cc.name == target) { cmdCase = &cc; break; }

    // task 0200's 3 new `frames` scenarios (tab-subpatch/lasso-dense/
    // undo-spam) are deliberately NOT wired into `flame` yet — the capture
    // loop below only knows how to replay orbit-dense/hover-sweep/
    // drag-falloff, so adding their names here without a matching branch
    // would silently no-op the capture window (worse than the explicit
    // "did not match" error below). Deferred; see doc/frame_scenarios_ci_plan.md
    // Phase 5 note.
    static immutable string[] frameScenarios =
        ["orbit-dense", "hover-sweep", "drag-falloff"];
    bool isScenario = frameScenarios.canFind(target);

    if (dragCase is null && cmdCase is null && !isScenario) {
        stderr.writefln("flame: %s did not match any ops case or frames "
                        ~ "scenario", target);
        stderr.writeln("  ops cases: run `./run.d --help` or see "
                       ~ "casesForTool()/commandCases() in this file.");
        stderr.writefln("  frames scenarios: %-(%s, %)", frameScenarios);
        return 1;
    }

    if (!lib.flame.perfAvailable()) {
        stderr.writeln("flame: `perf` not found in PATH "
                       ~ "(install linux-perf / perf userspace tools)");
        return 1;
    }

    // R3: flame builds its OWN profile-fp binary — NOT dubBuildPerf (the
    // PerfProbe binary `ops`/`frames` use). A following `--no-build`
    // ops/perf-abs run would silently reuse whatever `./vibe3d` currently
    // is, so a mismatched binary is always explicitly labeled (never
    // silent) — the pre-build skip note and the post-run NOTE below both
    // name the buildType `./vibe3d` now is.
    if (!noBuild) {
        if (!lib.flame.dubBuildProfileFp(g_repoRoot)) return 1;
    } else {
        writeln("--no-build: reusing the existing ./vibe3d as-is — if it is "
               ~ "not the profile-fp buildType, the flamegraph will localize "
               ~ "to the wrong (uninstrumented-noise or debug-noise) frames.");
    }

    killStaleVibe();
    string logPath = "/tmp/vibe3d_perf_flame.log";
    writefln("Launching vibe3d --test --perf --http-port %d --viewport %s ...",
             port, viewport);
    if (!launchVibe(port, viewport, logPath)) return 1;
    writeln("  vibe3d is up");

    resetMesh(meshType, meshParam);
    auto mi = modelInfo();
    writefln("Mesh: %s param=%d → %d verts, %d faces",
             meshType, meshParam, mi.vertexCount, mi.faceCount);

    string outDir = buildPath(g_repoRoot, "tools", "perf", "flame", "out");
    mkdirRecurse(outDir);
    string perfData = buildPath(outDir, "perf.data");
    string perfTxt  = buildPath(outDir, "perf.txt");
    string foldTxt  = buildPath(outDir, "folded.txt");

    // Configure the pipe / warm up exactly like the case would under `ops`/
    // `frames`, so the profiled workload matches the measured one.
    CameraState cam;
    Viewport vp;
    if (dragCase !is null) {
        if (!applySelection(*dragCase, meshParam)) {
            stderr.writeln("flame: selection failed");
            return 1;
        }
        if (!script("tool.set " ~ dragCase.tool.to!string)) {
            stderr.writeln("flame: tool.set failed");
            return 1;
        }
        foreach (a; dragCase.attrs)
            script(format(`tool.pipe.attr %s %s "%s"`, a.stage, a.name, a.value));
        cam = fetchCamera();
        vp  = viewportFromCamera(cam);
        // Warmup drag (untimed) — pays cache/pipeline first-evaluate cost
        // OUTSIDE the perf-record window, mirroring runCase's warmup.
        try runOneDrag(dragCase.tool, vp, cam); catch (Exception e) {
            stderr.writeln("flame: warmup drag failed: ", e.msg);
            return 1;
        }
    } else if (isScenario) {
        selectVertices([]);
        if (target == "drag-falloff") {
            if (!script("tool.set move")) {
                stderr.writeln("flame: tool.set move failed");
                return 1;
            }
            foreach (a; [PipeAttr("falloff", "type",   "radial"),
                        PipeAttr("falloff", "center", "0,0,0"),
                        PipeAttr("falloff", "size",   "1,1,1")])
                script(format(`tool.pipe.attr %s %s "%s"`, a.stage, a.name, a.value));
        }
        cam = fetchCamera();
        vp  = viewportFromCamera(cam);
    }

    // Attach perf, then drive the target repeatedly for `captureSecs` wall-
    // clock seconds so the sampled window holds substantial hot-path work
    // (mirrors perf_subpatch's "toggle N times" amplification — a single
    // drag/command is too brief at -F%d to be visible in the profile).
    auto perfPid = lib.flame.startPerfRecord(perfData, g_vibePid, freq, g_repoRoot);

    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto sw = StopWatch(AutoStart.yes);
    int reps = 0, resets = 0;
    writefln("[flame] capturing %s for %ds ...", target, captureSecs);
    while (sw.peek.total!"seconds" < captureSecs) {
        try {
            if (dragCase !is null) {
                runOneDrag(dragCase.tool, vp, cam);
            } else if (cmdCase !is null) {
                resetMesh(meshType, meshParam);
                selectMode(cmdCase.mode, cmdIndices(*cmdCase, meshParam));
                postCommand(cmdCase.commandId);
            } else if (target == "orbit-dense") {
                int x0 = cam.vpX + cast(int)(cam.width  * 0.20);
                int y0 = cam.vpY + cast(int)(cam.height * 0.55);
                int x1 = cam.vpX + cast(int)(cam.width  * 0.80);
                int y1 = cam.vpY + cast(int)(cam.height * 0.20);
                playAndWait(buildOrbitLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                          x0, y0, x1, y1, 60));
            } else if (target == "hover-sweep") {
                int x0 = cam.vpX + cast(int)(cam.width  * 0.15);
                int y0 = cam.vpY + cast(int)(cam.height * 0.50);
                int x1 = cam.vpX + cast(int)(cam.width  * 0.85);
                int y1 = cam.vpY + cast(int)(cam.height * 0.50);
                playAndWait(buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                          x0, y0, x1, y1, 80));
            } else if (target == "drag-falloff") {
                Vec3 pivot = fetchActionCenter();
                Drag d = dragFor(Tool.move, pivot, vp);
                if (!(d.x0 == 0 && d.y0 == 0 && d.x1 == 0 && d.y1 == 0))
                    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                             d.x0, d.y0, d.x1, d.y1, 20));
            }
            reps++;
        } catch (Exception e) {
            // A `move`/`drag-falloff` case cumulatively translates the mesh
            // (unlike the ops matrix's bounded 5-repeat window) — over a
            // multi-second capture the gizmo/mesh eventually drifts
            // off-camera ("handle projected off-camera"). Re-apply the same
            // configuration on a fresh mesh and keep sampling for the rest
            // of the window rather than aborting the capture.
            resetMesh(meshType, meshParam);
            if (dragCase !is null) {
                applySelection(*dragCase, meshParam);
                script("tool.set " ~ dragCase.tool.to!string);
                foreach (a; dragCase.attrs)
                    script(format(`tool.pipe.attr %s %s "%s"`, a.stage, a.name, a.value));
            } else {
                selectVertices([]);
                if (target == "drag-falloff") {
                    script("tool.set move");
                    foreach (a; [PipeAttr("falloff", "type",   "radial"),
                                PipeAttr("falloff", "center", "0,0,0"),
                                PipeAttr("falloff", "size",   "1,1,1")])
                        script(format(`tool.pipe.attr %s %s "%s"`, a.stage, a.name, a.value));
                }
            }
            resets++;
        }
    }
    writefln("[flame] %d repetitions captured (%d mid-capture resets)", reps, resets);

    lib.flame.stopPerfRecord(perfPid);
    writeln("[flame] generating reports");
    lib.flame.generateReports(perfData, perfTxt, foldTxt);

    writefln("[flame] DONE.\n"
            ~ "  target             : %s\n"
            ~ "  repetitions        : %d\n"
            ~ "  raw capture        : %s\n"
            ~ "  text summary       : %s\n"
            ~ "  folded/script      : %s",
            target, reps, perfData, perfTxt, foldTxt);

    // R3: after a `flame` run that (re)built, ./vibe3d is the profile-fp
    // binary — NOT the PerfProbe `perf` binary a following `--no-build`
    // ops/frames/perf-abs lane expects. Inverted NOTE from dubBuildPerf's
    // (never leave a mismatched binary unlabeled). With --no-build this
    // run never touched ./vibe3d, so there is nothing new to label.
    if (!noBuild)
        writeln("\nNOTE: ./vibe3d is now the profile-fp buildType binary "
               ~ "(optimized, no PerfProbe) — a following `ops`/`frames` "
               ~ "`--no-build` run will silently reuse it and read all-zero "
               ~ "PerfProbe counters; run `./run.d [ops|frames]` WITHOUT "
               ~ "--no-build (or `dub build`) first to rebuild the right binary.");

    return 0;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(string[] args) {
    g_repoRoot = buildNormalizedPath(
        absolutePath(buildPath(__FILE_FULL_PATH__.dirName, "..", "..")));

    bool noBuild = false;
    bool keep    = false;
    int  n       = 316;        // ~99856 faces
    int  meshSizeAlias = -1;
    int  subdivLevels  = -1;
    int  repeats = 5;
    ushort port  = 8088;
    string viewport = "1280x960";
    bool   updateBaseline = false;
    bool   noAbsolute     = false;   // skip absolute comparison (invariants only)
    double tolerance      = 0.30;    // absolute regression threshold (+30%)
    bool   updateFramesBaseline = false;
    bool   trend = false;
    int    trendLast = 20;
    int    flameFreq = 999;
    int    flameCapture = 8;
    bool   ciMode = false;

    auto helpInfo = getopt(args,
        config.passThrough,
        "no-build",  "skip the dub build",                 &noBuild,
        "keep",      "leave vibe3d running after the run",  &keep,
        "n",         "grid resolution N (default 316 → ~100K faces)", &n,
        "mesh-size", "alias for --n",                        &meshSizeAlias,
        "subdivcube","use subdivideCube(levels) instead of grid", &subdivLevels,
        "repeats",   "measured drags per case (default 5)",  &repeats,
        "http-port", "HTTP port (default 8088)",             &port,
        "viewport",  "fixed viewport WxH (default 1280x960)", &viewport,
        "update-baseline", "write tools/perf/baseline.json from this run", &updateBaseline,
        "no-absolute",     "skip absolute baseline comparison (relative invariants only)", &noAbsolute,
        "tolerance",       "absolute-regression threshold as a fraction (default 0.30 = +30%)", &tolerance,
        "update-frames-baseline", "write tools/perf/frames_baseline.json from this `frames` run", &updateFramesBaseline,
        "trend",     "print per-case median drift from tools/perf/history/<host>.jsonl and exit", &trend,
        "last",      "`--trend` window size (default 20 runs)", &trendLast,
        "freq",      "`flame` perf sampling frequency Hz (default 999)", &flameFreq,
        "capture",   "`flame` idle-capture seconds after the drag/scenario (default 8)", &flameCapture,
        "ci",        "`frames` CI mode: F-I4 (GC) becomes RECORDED/non-gating for every " ~
                     "scenario (host-flaky); implies --no-absolute", &ciMode);

    if (helpInfo.helpWanted) {
        writeln("usage: ./run.d [ops] [options] [case-name-substring...]");
        writeln("       ./run.d frames [options] [scenario-name-substring...]");
        writeln("       ./run.d flame <case-or-scenario-name> [options]");
        writeln("       ./run.d --trend [--last N]");
        writeln("  bare invocation == `ops` (the per-tool matrix).");
        foreach (o; helpInfo.options)
            writefln("  %-14s %s", o.optLong, o.help);
        return 0;
    }

    if (meshSizeAlias >= 0) n = meshSizeAlias;
    string meshType = "grid";
    int meshParam = n;
    if (subdivLevels >= 0) { meshType = "subdivcube"; meshParam = subdivLevels; }

    // `--ci` implies `--no-absolute` — the absolute p99/hitch budgets are
    // hardware-bound (baseline-host header guard), meaningless on a CI
    // runner that isn't the baseline host.
    if (ciMode) noAbsolute = true;

    string[] requested = args[1 .. $];

    // Subcommand dispatch: the first non-flag token selects the mode. Bare
    // (no matching token) ⇔ `ops` (design: bare run == `ops`, unchanged
    // since task 0195's `frames` addition) — this SUBSUMES the old ad-hoc
    // framesMode check, it does not fork a second dispatch path (R6). The
    // token is consumed so the remaining args stay a name-substring filter,
    // exactly as before.
    string subcommand = "ops";
    if (requested.length > 0 &&
        (requested[0] == "ops" || requested[0] == "frames" || requested[0] == "flame")) {
        subcommand = requested[0];
        requested = requested[1 .. $];
    }

    g_keep = keep;
    g_baseUrl = format("http://localhost:%d", port);

    // `--trend` needs no vibe3d (pure history-file read) and short-circuits
    // before killStaleVibe/launchVibe/dubBuildPerf (task 0197 Phase 4).
    if (trend) {
        auto path = lib.history.historyPath(g_repoRoot, Socket.hostName);
        auto entries = lib.history.loadHistory(path);
        lib.history.printTrend(entries, trendLast);
        return 0;
    }

    signal(SIGINT,  &onSignal);
    signal(SIGTERM, &onSignal);
    scope(exit) teardown();

    // `flame` builds its OWN profile-fp binary (lib.flame.dubBuildProfileFp)
    // — dispatch BEFORE the shared `dubBuildPerf()` call below so a `flame`
    // run never wastefully builds the PerfProbe binary first only to
    // immediately overwrite it.
    if (subcommand == "flame") {
        string target = requested.length > 0 ? requested[0] : "";
        return runFlameSubcommand(target, meshType, meshParam, viewport, port,
                                  flameFreq, flameCapture, noBuild);
    }

    if (!noBuild && !dubBuildPerf()) return 1;

    if (subcommand == "frames")
        return runFramesSubcommand(meshType, meshParam, viewport, port, requested,
                                   updateFramesBaseline, noAbsolute, noBuild, ciMode);

    // Build the matrix.
    Case[] allCases;
    foreach (t; [Tool.move, Tool.rotate, Tool.scale])
        allCases ~= casesForTool(t);

    Case[] cases;
    foreach (c; allCases) {
        bool keepIt = requested.length == 0;
        foreach (req; requested) if (c.name.canFind(req)) keepIt = true;
        if (keepIt) cases ~= c;
    }

    // Filter the one-shot command cases with the SAME requested-substring
    // logic, up front, so the "no cases matched" guard accounts for them too
    // (the drag tokens "delete"/"remove" match no drag case but should still
    // run the command cases).
    CmdCase[] cmdCases;
    foreach (cc; commandCases()) {
        bool keepIt = requested.length == 0;
        foreach (req; requested) if (cc.name.canFind(req)) keepIt = true;
        if (keepIt) cmdCases ~= cc;
    }

    if (cases.length == 0 && cmdCases.length == 0) {
        writeln("no cases matched");
        return 0;
    }

    killStaleVibe();
    string logPath = "/tmp/vibe3d_perf.log";
    writefln("Launching vibe3d --test --perf --http-port %d --viewport %s ...",
             port, viewport);
    if (!launchVibe(port, viewport, logPath)) return 1;
    writeln("  vibe3d is up");

    // Confirm the mesh builds + report face count.
    resetMesh(meshType, meshParam);
    auto mi = modelInfo();
    writefln("Mesh: %s param=%d → %d verts, %d faces",
             meshType, meshParam, mi.vertexCount, mi.faceCount);
    writefln("Repeats per case: %d (+1 warmup, discarded)", repeats);

    CaseResult[] results;
    foreach (c; cases) {
        write("  running ", c.name, " ... ");
        stdout.flush();
        auto r = runCase(c, meshParam, meshType, repeats);
        final switch (r.status) {
            case CaseStatus.OK:    writeln("OK");                  break;
            case CaseStatus.SKIP:  writeln("SKIP (", r.detail, ")"); break;
            case CaseStatus.ERROR: writeln("ERROR (", r.detail, ")"); break;
        }
        results ~= r;
    }

    // One-shot command cases (mesh.delete / mesh.remove) — already filtered
    // above with the same requested-substring logic as the drag cases.
    foreach (cc; cmdCases) {
        write("  running ", cc.name, " ... ");
        stdout.flush();
        auto r = runCommandCase(cc, meshParam, meshType, repeats);
        final switch (r.status) {
            case CaseStatus.OK:    writeln("OK");                  break;
            case CaseStatus.SKIP:  writeln("SKIP (", r.detail, ")"); break;
            case CaseStatus.ERROR: writeln("ERROR (", r.detail, ")"); break;
        }
        results ~= r;
    }

    printTable(results);

    string outPath = buildPath(g_repoRoot, "tools", "perf", "results.json");
    writeResultsJson(outPath, meshType, meshParam, mi.faceCount,
                     viewport, repeats, results);
    writeln("\nWrote ", outPath);

    // -------------------------------------------------------------------
    // Phase 5 — regression detection.
    // -------------------------------------------------------------------
    auto curHeader = currentHeader(meshType, meshParam, mi.faceCount,
                                   viewport, repeats);
    string baselinePath = buildPath(g_repoRoot, "tools", "perf", "baseline.json");

    if (updateBaseline) {
        writeBaselineJson(baselinePath, curHeader, results);
        writeln("Wrote ", baselinePath, " (baseline updated from this run)");
        // An --update-baseline run still reports invariants below but does
        // not perform an absolute comparison against the freshly-written file.
        noAbsolute = true;
    }

    int failures = 0;

    // 1. Relative invariants — ALWAYS run (machine-stable).
    writeln();
    writeln("=== relative invariants (machine-stable) ===");
    auto invs = checkInvariants(results);
    int invFail = 0;
    foreach (iv; invs) {
        writefln("  [%s] %-4s %-52s  %s",
                 iv.pass ? "PASS" : "FAIL", iv.id, iv.desc, iv.detail);
        if (!iv.pass) { invFail++; failures++; }
    }
    if (invs.length == 0)
        writeln("  (no invariants applicable — no OK baseline cases)");

    // 2. Absolute baseline comparison — gated by build-match guard.
    writeln();
    writeln("=== absolute baseline comparison ===");
    int absFail = 0;
    if (noAbsolute && !updateBaseline) {
        writeln("  skipped (--no-absolute)");
    } else if (updateBaseline) {
        writeln("  skipped (baseline was just written by --update-baseline)");
    } else if (!exists(baselinePath)) {
        writeln("  no baseline (", baselinePath, " absent) — run with",
                " --update-baseline to capture one");
    } else {
        auto base = loadBaseline(baselinePath);
        string mismatch = headerMismatch(base.header, curHeader);
        if (mismatch.length > 0) {
            writefln("  build mismatch — skipping absolute comparison: %s",
                     mismatch);
            writefln("  baseline was captured on {buildType=%s, compiler=%s," ~
                     " meshType=%s, n=%d, viewport=%s}; current run is" ~
                     " {buildType=%s, compiler=%s, meshType=%s, n=%d," ~
                     " viewport=%s} — relative invariants only.",
                     base.header.buildType, base.header.compiler,
                     base.header.meshType, base.header.n, base.header.viewport,
                     curHeader.buildType, curHeader.compiler,
                     curHeader.meshType, curHeader.n, curHeader.viewport);
        } else {
            auto regs = checkAbsolute(results, base, tolerance);
            if (regs.length == 0) {
                writefln("  no regressions (tolerance +%.0f%%, %d cases" ~
                         " compared)", tolerance * 100, base.byName.length);
            } else {
                foreach (rg; regs) {
                    writefln("  [FAIL] %-28s %-12s %+.0f%%  (%.1f → %.1f µs)",
                             rg.name, rg.metric, rg.growth * 100,
                             rg.baseUs, rg.curUs);
                    absFail++;
                    failures++;
                }
            }
        }
    }

    // 3. Final verdict.
    writeln();
    writeln("=== verdict ===");
    writefln("  relative invariants: %d/%d passed", invs.length - invFail,
             invs.length);
    if (absFail > 0)
        writefln("  absolute regressions: %d", absFail);
    writeln(failures == 0 ? "  OVERALL: PASS" : "  OVERALL: FAIL");

    // History (task 0197 Phase 4) — one line per `ops` run, {caseName:
    // kernelApplyMedianUs}. Best-effort: a history-append failure must never
    // fail the run.
    try {
        double[string] kernelMedianByCase;
        foreach (r; results)
            if (r.status == CaseStatus.OK)
                kernelMedianByCase[r.name] = r.kernelMedianUs;
        lib.history.appendHistory(g_repoRoot, curHeader, kernelMedianByCase);
    } catch (Exception e) {
        stderr.writeln("warning: history append failed: ", e.msg);
    }

    // The perf build replaced ./vibe3d with the ldc-release perf binary; a
    // later `./run_test.d --no-build` would silently reuse it. Remind.
    if (!noBuild)
        writeln("\nNOTE: ./vibe3d is now the perf buildType binary — run "
                ~ "`dub build` to restore the modeling debug binary before "
                ~ "reusing it with --no-build test runs.");

    return failures == 0 ? 0 : failures;
}
