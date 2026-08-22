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
import std.math      : sqrt, sin, cos, tan, PI, fabs, isNaN, fmin;
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
    // Camera ELEVATION (radians) this case needs, or NaN for "leave the
    // camera alone" (task 1350). `runCase` posts it after the reset and puts
    // the previous value back when the case ends — including on the error
    // paths, because the camera is PROCESS state shared by every later case:
    // a case that left the camera flipped would silently re-fixture the rest
    // of the matrix.
    double  elevation = double.nan;
    // "This case exists to exercise the snap VISIBILITY mask." Cases that
    // declare it are held to invariant I7's non-vacuity clause: the mask must
    // actually be consulted and the query must actually elect something.
    // Without the flag a case that quietly stopped reaching the occlusion path
    // would keep passing as a green line measuring nothing.
    bool    exercisesVisibility = false;
    // A grid resolution THIS CASE needs, overriding the run's `--n`; 0 = use
    // the run's.
    //
    // NO CASE SETS IT ANY MORE, and the history is the reason to keep the
    // field. `move/snap=vertex+partial` pinned n=64 because the snap
    // visibility mask's occlusion pass was O(V x |front faces|): on the matrix
    // mesh (n=316: 100 489 verts, 99 856 faces) one query with the faces
    // actually facing the eye measured SECONDS, the drag blew through the 10 s
    // play-events timeout, the main thread then serviced no HTTP, and every
    // later case in the run failed with "selection failed" (observed
    // 2026-08-18). One hung case poisoned the whole run.
    //
    // Task 1351 removed the quadratic — a screen-space broad phase over the
    // occluders, plus a mask that evaluates only the vertices someone asks
    // about — so the pin is gone and the case runs at the matrix size. Two
    // consequences to keep in view:
    //   * under `--subdivcube` the case no longer SKIPs (the skip below is
    //     conditioned on this field), so it now also runs on a CLOSED body,
    //     where the mask really does reject candidates. On the flat sheet it
    //     rejects none (`snapVisReject == 0`, see I7's clause (b)), so the
    //     subdivcube run is the first fixture where the mask discriminates;
    //   * I7d's absolute budget is therefore declared grid-only.
    // Grid-only — a `--subdivcube` run SKIPs a case that DOES set this rather
    // than reinterpreting the number as a subdivision LEVEL.
    int     meshN = 0;
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

        // Snap to vertex with a PARTIAL moving set, and looking at the plane
        // from BELOW — the only case in this matrix that reaches the snap
        // visibility mask at all (task 1350).
        //
        // Two independent things keep every case above OFF that path, and
        // both had to be undone here:
        //
        //  1. THE MOVING SET. Every other snap case uses `"whole"`, which is
        //     an EMPTY selection, which makes the moving set the whole mesh.
        //     `snap.d`'s `kindExcluded` drops a candidate if ANY incident
        //     vertex is moving, so on a whole-mesh drag every candidate is
        //     dropped before the mask is ever consulted. Those cases measure
        //     the candidate GRID and nothing else.
        //  2. THE CAMERA. `makeGridPlane`'s faces compute a -Y normal, so the
        //     default above-plane camera leaves every face back-facing;
        //     `frontFacingLocal` culls all of them, `front[]` comes out empty
        //     and the mask comes out all-false — every candidate would then be
        //     rejected as invisible and nothing could ever snap. Looking from
        //     below (the same -0.4 rad the `lasso-dense` frame scenario uses,
        //     for the same reason — see `lib.http.setCameraElevation`) makes
        //     the faces face the eye.
        //
        // `single` and not `half`: the gizmo sits at the action centre of the
        // selection, so with `half` the cursor spends the drag deep inside the
        // moving half where every near candidate is excluded anyway. With a
        // one-vertex selection the exclusion set is one vertex and the whole
        // neighbourhood under the cursor stays consultable.
        //
        // The number this case produces is the honest cost of the mask on the
        // partial-selection path. Task 1350 deliberately did NOT optimise it
        // (it removed the mask where nobody consults it); task 1351 did — the
        // per-vertex laziness and the occluder broad phase — which is why the
        // case no longer has to pin its own mesh size. I7d watches the mask's
        // build time here.
        cs ~= Case(tname ~ "/snap=vertex+partial", t, "single",
            [PipeAttr("snap", "enabled", "true"),
             PipeAttr("snap", "types", "vertex")],
            "snap=vertex, partial moving set, camera below the plane",
            -0.4, true, 0);

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
    // The key this row is FILED under — in the run history and in
    // baseline.json — as opposed to `name`, which is what a human reads in
    // the table (task 1373, F1.7).
    //
    // They differ for exactly one class of row: a case that pins its own mesh
    // size (`Case.meshN`) files as `<name>@n<size>`. Before this, the single
    // pinned case (`move/snap=vertex+partial`, meshN=64) filed under its bare
    // name, so a number measured on 4225 verts and a number measured on
    // 100489 verts landed in THE SAME history key and the same baseline row,
    // and `--vs-last` compared them as if they were the same benchmark.
    //
    // Derived from `Case.meshN` — the field of the DECLARATION — and never
    // from `effectiveN` vs the run's `--n`: keying on the observed size would
    // file one case under two different keys depending on what `--n` the run
    // was given, which re-opens the hole from the other side.
    string     historyKey;
    string     note;
    CaseStatus status;
    string     detail;
    // What proved this command case did work, and by how much: e.g.
    // "counts 100489 verts/99856 faces -> 200978/199712" or
    // "positions 40012/100489 verts moved, max 0.0412". Written into
    // results.json so a reader (and `--lane-health`) can see WHICH observable
    // stood behind an OK row rather than trusting the word (task 1373).
    string     witnessDetail;
    // medians/p95 across R repeats, in microseconds.
    double     kernelMedianUs, kernelP95Us;
    double     pipeMedianUs;
    double     pipeSymmetryMedianUs;   // pipe.symmetry stage cost (for I2)
    double     snapQueryMedianUs;      // snap.d:snapCursor cost (informational)
    double     snapQuerySumUs;         // last-repeat snapQuery sum (informational)
    long       snapQueryCount;         // last-repeat snapCursor call count (for I5)
    // Task 1350/1355 — the snap-visibility counters from the last repeat.
    long       snapVisBuildCount;      // Mesh.visibleVertices computations
    long       snapVisConsultCount;    // mask consultations by a candidate
    long       snapVisRejectCount;     // consultations the mask array answered NO
    // Task 1351 — the broad-phase counters plus the mask TIMER.
    long       snapVisVertexProbeCount;  // DISTINCT vertices the mask evaluated
    long       snapVisPairsTestedCount;  // (candidate x occluder) bbox tests
    long       snapVisGridBailCount;     // probe builds with no bucket grid
    long       snapVisPixelOutsideCount; // probes that took the linear arm
    double     snapVisMaskMedianUs;      // median cost of ONE mask build
    long       snapVisMaskCount;         // mask builds in the last repeat
    long       snapHitCount;           // snapCursor calls that elected something
    long       snapHitGeomCount;       // ...where a MASK-GATED candidate won
    bool       exercisesVisibility;    // carried from Case (for I7)
    string     selection;              // carried from Case (for I7a)
    // The mesh FAMILY this case ran on. I7d is an ABSOLUTE time budget, so it
    // is only meaningful against a known fixture — carried per case rather
    // than read from a global, because `checkInvariants` takes results and
    // nothing else, and a global would go stale the moment a second family
    // appeared in one run.
    string     meshKind;
    // The grid resolution this case ACTUALLY ran at, and the mesh it got.
    // Not always the run's `--n`: `Case.meshN` pins a size per case, and a
    // report that prints one row at 64 under a header that says 316 is
    // describing a mesh that never existed (review fix, task 1359).
    int        effectiveN;
    long       effectiveVertexCount;
    long       effectiveFaceCount;
    // Visible BACKGROUND layers at measure time — `snapCursor` runs its walk
    // once for the primary and once more for each of these, so this is what
    // turns "one mask build per walk" into a number the harness can check.
    long       backgroundSources;
    string     dominantStage;
    long       vertsTouched;     // sum from the last repeat
    long       kernelInternalP95Ns;  // /api/perf's own per-sample p95
    JSONValue  lastBreakdown;    // full /api/perf from the last repeat
    bool       isCommand;        // true for delete/remove command cases
    long       commandApplyCount;// commandApply.count from last repeat (for I6)
    // --- `tools` subcommand: one interactive-tool preview rebuild (task 1370)
    bool       isToolPreview;    // true for ToolCase rows
    long       toolPreviewCount;      // rebuildPreview() calls in the window
    long       previewRestoreCount;   // MeshSnapshot.restore calls in the window
    long       previewRefreshCount;   // refreshDisplay calls in the window
    double     toolPreviewSumUs;      // whole-wrapper cost across R repeats
    double     previewRestoreSumUs;   // the restore half
    double     previewRefreshSumUs;   // the upload+cache-resize half
    double     previewKernelUs;       // wrapper - restore - refresh
    double     kernelShare;           // previewKernelUs / toolPreviewSumUs
    bool       geometryChanged;       // I8b: BOTH driven values really moved the mesh
    // V/F counts + vertex-0 position: the pristine mesh, and the mesh after
    // each of the two pre-window writes. Two "after" probes because the
    // measured window ALTERNATES v0/v1 and one probe can only witness one of
    // them (review fix, task 1370 — see runToolCase step 4).
    string     geomBefore, geomAfterV0, geomAfterV1;
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

// The history/baseline key for a drag case (task 1373, F1.7). By
// `c.meshN` — the DECLARED size — so the key is a property of the case
// table and not of the `--n` the run happened to be given.
string historyKeyFor(ref Case c) {
    return c.meshN > 0 ? format("%s@n%d", c.name, c.meshN) : c.name;
}

CaseResult runCase(ref Case c, int n, string meshType, int repeats) {
    CaseResult res;
    res.name = c.name;
    res.historyKey = historyKeyFor(c);
    res.note = c.note;

    // 0. per-case mesh size (see `Case.meshN`). Grid only: under
    // `--subdivcube` the reset parameter means subdivision LEVELS, and
    // silently building 2^64 of them is not a degradation this should
    // improvise through.
    if (c.meshN > 0 && meshType != "grid") {
        res.status = CaseStatus.SKIP;
        res.detail = format("case pins grid n=%d; this run is meshType=%s",
                            c.meshN, meshType);
        return res;
    }
    if (c.meshN > 0) n = c.meshN;
    res.effectiveN = n;

    // 1. fresh mesh
    resetMesh(meshType, n);
    // What that mesh actually IS, when it is not the run's (review fix, task
    // 1359). A row measured at n=64 printed under a header that says n=316
    // describes a mesh that never existed; the numbers below are only
    // interpretable next to the size they were taken at. Read only for the
    // pinned cases — for every other case the run header is already the
    // answer, and this is an extra main-thread round trip per case.
    if (c.meshN > 0) {
        auto mi = modelInfo();
        res.effectiveVertexCount = mi.vertexCount;
        res.effectiveFaceCount   = mi.faceCount;
    }

    // 1b. camera, when the case asks for one (task 1350). Restored on EVERY
    // exit path — the `scope (exit)` is at FUNCTION scope on purpose: written
    // inside the `if` it would fire at the end of that block and put the
    // camera back before the drags ever ran.
    //
    // ORDER MATTERS, and it was wrong here (review fix, task 1358): the
    // restore is registered BEFORE the set it undoes, not after. `setCamera
    // Elevation` returns false on any curl exception — including a READ
    // timeout, which fires after the request reached the server and the
    // server already applied the change. On that path a restore registered
    // after the call is never registered at all: the case returns ERROR, the
    // camera stays at the case's elevation, and every LATER case in the
    // matrix silently runs against a re-aimed camera. The next day-over-day
    // gate then lights up with regressions that are re-fixturing, not code.
    // Registering first costs one redundant POST on the (already failing)
    // error path and cannot lose the restore.
    //
    // (`/api/reset` does put the camera back too — measured, see the task
    // file's finding 1 — but a case must be closed on itself rather than
    // rely on the NEXT case's reset, which `runCase`'s early returns may
    // never reach.)
    double prevElevation = double.nan;
    if (!c.elevation.isNaN) prevElevation = fetchCamera().elevation;
    scope (exit) if (!prevElevation.isNaN) setCameraElevation(prevElevation);
    if (!c.elevation.isNaN && !setCameraElevation(c.elevation)) {
        res.status = CaseStatus.ERROR;
        res.detail = "camera elevation set failed";
        return res;
    }

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

    // Visible background layers — the count `snapCursor` walks IN ADDITION to
    // the primary (see `fetchBackgroundLayerCount`). Read after the reset and
    // the selection, i.e. in the state the measured drags will run in.
    res.backgroundSources = fetchBackgroundLayerCount();

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
    double[] snapMaskTot; // per-BUILD median snapVisMask ns per drag (I7e)
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
        // The MEDIAN sample, not the sum: one sample is ONE mask build, and
        // "what does a mask cost" is the quantity the card's criterion and
        // I7d are about. The sum over a drag is 21 of them and would make the
        // budget a statement about how many mouse events the harness replays.
        snapMaskTot ~= ("snapVisMask" in perf)
            ? cast(double)perf["snapVisMask"]["median_ns"].integer / 1000.0 : 0.0;
        last = perf;
    }

    res.status = CaseStatus.OK;
    res.kernelMedianUs       = medianOf(kernelTot);
    res.kernelP95Us          = p95Of(kernelTot);
    res.pipeMedianUs         = medianOf(pipeTot);
    res.pipeSymmetryMedianUs = medianOf(pipeSymTot);
    res.snapQueryMedianUs    = medianOf(snapQTot);
    res.snapVisMaskMedianUs  = medianOf(snapMaskTot);
    res.snapQuerySumUs       = cast(double)sumNs(last, "snapQuery") / 1000.0;
    res.snapQueryCount       = ("snapQuery" in last)
        ? last["snapQuery"]["count"].integer : 0;
    // Counters emit {count, sum}; every call site adds 1, so either reads the
    // same number — `sum` is taken for symmetry with vertsTouched below.
    long counterSum(string cat) {
        return (cat in last) ? last[cat]["sum"].integer : 0;
    }
    res.snapVisBuildCount    = counterSum("snapVisBuild");
    res.snapVisConsultCount  = counterSum("snapVisConsult");
    res.snapVisRejectCount   = counterSum("snapVisReject");
    res.snapVisVertexProbeCount  = counterSum("snapVisVertexProbe");
    res.snapVisPairsTestedCount  = counterSum("snapVisPairsTested");
    res.snapVisGridBailCount     = counterSum("snapVisGridBail");
    res.snapVisPixelOutsideCount = counterSum("snapVisPixelOutside");
    res.snapVisMaskCount = ("snapVisMask" in last)
        ? last["snapVisMask"]["count"].integer : 0;
    res.snapHitCount         = counterSum("snapHit");
    res.snapHitGeomCount     = counterSum("snapHitGeom");
    res.exercisesVisibility  = c.exercisesVisibility;
    res.selection            = c.selection;
    res.meshKind             = meshType;
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

// PINNING A COMMAND CASE TO ITS OWN MESH SIZE: only on a measurement.
//
// `CmdCase` has no `meshN` and should not grow one on a hunch. The lane's
// hard ceiling is the command bridge's leash (`kCommandBridgeMaxIters =
// 60_000`, about 2 minutes — source/http_server.d:73-79), and the measured
// cost of a case at n=316 is ~5 s, so there is two orders of magnitude of
// room: `mesh.subdivide` already builds 400k faces inside that budget.
//
// If a case ever does need a pin, three things have to arrive WITH it:
//   (a) the measured number that justified it — a case past ~60 s, half the
//       leash, not a case that felt slow;
//   (b) a check that the median at the PINNED size is still above BOTH
//       floors — `--vs-last-floor` (200 us, run.d's default) and
//       `ABS_NOISE_FLOOR_US` (50.0, lib/baseline.d). Shrinking a case under
//       either silently drops it out of the very gates it exists for;
//   (c) the `@n` history key (`historyKeyFor`), so the pinned number never
//       shares a key with the same case at the run's size.
// Worth saying out loud: shrinking hurts MOST on the cases that are worst
// super-linear — which are exactly the ones this lane exists to watch.
//
// WHAT MAKES A COMMAND CASE NON-EMPTY (task 1373).
//
// A perf case whose command silently stops doing work keeps producing a
// number, and the number gets smaller, and a smaller number reads as an
// improvement. So every case declares WHICH OBSERVABLE proves it did work,
// and the case is ERROR — not OK-with-a-small-number — when that observable
// did not move.
//
// The three witnesses are not stylistic variants; they partition the case
// table by what the command is *for*, and each of the other two is blind to
// its class:
//
//   counts    — the vertex/face totals changed. Growing and shrinking
//               commands. Read from /api/layers, which serialises three
//               integers. These cases MUST NOT use a dump-based witness:
//               their result outgrows the main-thread /api/model bridge
//               (mesh.radial_array x6 from the n=316 grid is 599k faces).
//   positions — counts identical, but at least one vertex moved further
//               than 1e-5 from the ORIGINAL grid. Pure deforms. Blind to
//               marks; `counts` is blind to it.
//   marks     — counts identical AND every vertex still where it was, but a
//               hide bit, a face material, or a face's vertex RING changed.
//               hide / hideInvert / setMaterial / flip. The other two are
//               blind to all four of those.
//
// `mutationVersion` is deliberately NOT one of them, and must not be added
// back "to cover the deforms": `Mesh.commitChange` does `++mutationVersion`
// unconditionally (source/mesh.d:1241-1243) and the kernels call it in their
// tail whether or not anything moved (commands/mesh/quantize.d:123,
// commands/mesh/set_material.d:91). It witnesses "a command ran", which
// /api/command's own status already says. The tools lane killed the same
// term on its own side for the same reason (see runToolCase step 4).
enum CmdWitness { counts, positions, marks }

struct CmdCase {
    string name;       // "delete/polygons/whole"
    string commandId;  // full argstring POSTed to /api/command, args included
                       // (e.g. "mesh.bevel inset:0.02 shift:0.02 group:false")
    string mode;       // "vertices" | "edges" | "polygons"
    string selection;  // "whole" | "half" | "edge3"
    CmdWitness witness = CmdWitness.counts;
}

// Selection indices for a command case. "whole" ⇒ empty (whole mesh).
// "half" ⇒ selHalf for vertices, faceHalf for polygons.
// "edge3" ⇒ the first three EDGE indices — the operand mesh.loopSlice /
// mesh.addLoop need: they take a seed edge and derive a whole loop from it,
// so the operand is O(1) while the work is O(mesh) (measured: every one of
// the grid's 4096 face rings is rewritten). Edge indices 0..2 exist for any
// grid resolution, so the selection does not have to be recomputed per n.
int[] cmdIndices(ref CmdCase c, int n) {
    if (c.selection == "edge3")  return [0, 1, 2];
    if (c.selection == "whole")  return [];
    if (c.mode == "vertices")    return selHalf(n);
    if (c.mode == "polygons")    return faceHalf(n);
    return [];   // edges/half — unused (edges only uses whole / edge3)
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
    // The wider one-shot tool set (2026-08-18). Args were picked so every
    // command actually mutates the grid fixture; "whole" == empty selection
    // (the operand falls back to the full mesh). mesh.bevel gets
    // group:false — the per-face bevel (~5x geometry growth); the default
    // group bevel only rings the selection boundary and measures nothing
    // (measured 2026-08-19 on the n=64 grid: the default adds 256 faces to
    // 4096, group:false adds 12033).
    cs ~= CmdCase("bevel/polygons/whole",
                  "mesh.bevel inset:0.02 shift:0.02 group:false", "polygons", "whole");
    cs ~= CmdCase("inset/polygons/whole",         "mesh.poly_inset",   "polygons", "whole");
    cs ~= CmdCase("polyExtrude/polygons/whole",   "poly.extrude distance:0.05", "polygons", "whole");
    cs ~= CmdCase("smoothShift/polygons/whole",   "mesh.smooth_shift", "polygons", "whole");
    cs ~= CmdCase("thicken/polygons/whole",       "mesh.thicken",      "polygons", "whole");
    cs ~= CmdCase("subdivide/polygons/whole",     "mesh.subdivide",    "polygons", "whole");
    cs ~= CmdCase("triple/polygons/whole",        "mesh.triple",       "polygons", "whole");
    cs ~= CmdCase("mirror/polygons/whole",        "mesh.mirror",       "polygons", "whole");
    cs ~= CmdCase("collapse/polygons/half",       "mesh.collapse",     "polygons", "half");
    // Deforms: counts stay put, so `counts` would call every one of these a
    // no-op. They are witnessed by POSITIONS (task 1373) — before 1373 they
    // rode on a mutationVersion bump, which is not evidence of work.
    cs ~= CmdCase("smooth/polygons/whole",        "mesh.smooth",       "polygons", "whole",
                  CmdWitness.positions);
    cs ~= CmdCase("jitter/vertices/whole",        "mesh.jitter",       "vertices", "whole",
                  CmdWitness.positions);
    cs ~= CmdCase("quantize/vertices/whole",      "mesh.quantize",     "vertices", "whole",
                  CmdWitness.positions);
    cs ~= CmdCase("edgeExtend/edges/whole",       "mesh.edge_extend",  "edges",    "whole");
    cs ~= CmdCase("edgeExtrude/edges/whole",      "mesh.edge_extrude", "edges",    "whole");
    cs ~= CmdCase("vertexBevel/vertices/whole",   "mesh.vertexBevel amount:0.02", "vertices", "whole");
    // half, not whole: whole-mesh vertexExtrude on the 100K grid measured
    // 156s of commandApply (2026-08-18) — past even the raised 2-min
    // command-bridge leash. Half the vertex set exercises the same path.
    cs ~= CmdCase("vertexExtrude/vertices/half",
                  "mesh.vertexExtrude shift:0.05 width:0.02", "vertices", "half");

    // -------------------------------------------------------------------
    // Task 1373 — the growing/shrinking commands the 2026-08-18 block left
    // out. Every argstring below was CONFIRMED against the n=64 grid on
    // 2026-08-19 (four operand configurations per command) rather than read
    // off a default: the numbers in the trailing comments are that
    // measurement, and they are what says the case measures work at all.
    //
    // CLAMP RULE for anyone adding a row (mirrors ToolCase's, above the tool
    // table): an integer argument that scales an allocation or a loop bound
    // is written EXPLICITLY and kept at the low end of its documented range,
    // never left implicit. Every count used here has both layers of the
    // task-0365 clamp already — MAX_RADIAL_ARRAY_COUNT (source/mesh.d:5586),
    // MAX_ARRAY_COUNT (mesh.d:5735), MAX_AXIS_SLICE_COUNT
    // (commands/mesh/axis_slice.d:20) — so the check here is only "the value
    // is inside those bounds", which the /api/registry?params=1 schema
    // states: count in [1,256] for all three.
    // -------------------------------------------------------------------
    cs ~= CmdCase("radialArray/polygons/whole",
                  "mesh.radial_array count:6", "polygons", "whole");   // x6 faces
    cs ~= CmdCase("array/polygons/whole",
                  "mesh.array count:2",        "polygons", "whole");   // x2 faces
    cs ~= CmdCase("spikey/polygons/whole",
                  "mesh.spikey amount:0.5",    "polygons", "whole");   // x4 faces
    cs ~= CmdCase("clone/polygons/whole",       "mesh.clone", "polygons", "whole"); // x2
    cs ~= CmdCase("subdivFaceted/polygons/whole",
                  "mesh.subdivide_faceted",    "polygons", "whole");   // x4 faces
    cs ~= CmdCase("detriangulate/polygons/whole",
                  "mesh.detriangulate",        "polygons", "whole");   // 4096 -> 1
    // Reached only through an operand (they refuse the empty selection):
    // measured 2026-08-19 at n=64 in the operand sweep.
    cs ~= CmdCase("duplicate/polygons/half",    "mesh.duplicate",  "polygons", "half"); // +2048 F
    cs ~= CmdCase("mergeFaces/polygons/half",   "mesh.mergeFaces", "polygons", "half"); // -2047 F
    cs ~= CmdCase("vertexSplit/vertices/half",  "mesh.vertexSplit","vertices", "half"); // +5984 V
    // axis:0, not the default axis:1 — the grid is FLAT in Y, so the default
    // Y-axis slice finds a zero span and refuses (axis_slice.d's
    // `span < 1e-6` early-out). count:4, not the default 1, for the same
    // family of reason: a single plane through the exact centre of an
    // even-resolution grid lands ON an existing edge row and splits nothing,
    // so the command restores its snapshot and returns false.
    cs ~= CmdCase("axisSlice/polygons/whole",
                  "mesh.axisSlice axis:0 count:4", "polygons", "whole"); // +256 F
    // Seed-edge operands: O(1) selection, O(mesh) work.
    cs ~= CmdCase("loopSlice/edges/edge3",  "mesh.loopSlice count:3", "edges", "edge3"); // +192 F
    cs ~= CmdCase("addLoop/edges/edge3",    "mesh.addLoop",           "edges", "edge3"); // +64 F

    // Deforming and marking commands (task 1373). These are the classes the
    // `counts` witness cannot see at all.
    cs ~= CmdCase("linearAlign/vertices/half",
                  "mesh.linear_align mode:line weight:1", "vertices", "half",
                  CmdWitness.positions);
    cs ~= CmdCase("radialAlign/vertices/half",
                  "mesh.radial_align mode:circle side:4 weight:1", "vertices", "half",
                  CmdWitness.positions);
    // dist:10, not the default 1: the default's falloff sphere covers only
    // part of the [-1,1] mesh (measured 3196 of 4225 verts moved), and a case
    // that exists to measure work proportional to the mesh should have an
    // operand that covers the mesh. At dist:10 it is 4224 of 4225.
    cs ~= CmdCase("magnet/vertices/whole",
                  "mesh.magnet strength:1 dist:10", "vertices", "whole",
                  CmdWitness.positions);
    cs ~= CmdCase("flip/polygons/whole",     "mesh.flip",     "polygons", "whole",
                  CmdWitness.marks);   // rings only: 4096 rewound, nothing moves
    cs ~= CmdCase("hide/polygons/half",      "mesh.hide",     "polygons", "half",
                  CmdWitness.marks);   // faceHidden 0 -> 2048
    cs ~= CmdCase("hideInvert/polygons/half","mesh.hideInvert","polygons","half",
                  CmdWitness.marks);   // faceHidden 0 -> 4096
    cs ~= CmdCase("setMaterial/polygons/whole",
                  "mesh.setMaterial materialId:1", "polygons", "whole",
                  CmdWitness.marks);   // faceMaterial: 4096 entries change
    // Task 1471. This was an exclusion until the quadratic behind it was
    // fixed: 7072.5 ms for ONE apply at 4096 faces, exponent 1.98, which
    // extrapolated to ~66 MINUTES on this lane's n=316 grid. The spin now
    // pays the derived-structure rebuild once per ROUND rather than once per
    // spun edge; re-measured on the fixed `perf` build 2026-08-20, five reps
    // at n=316 with a fresh reset between them: 0.699 / 0.617 / 0.618 / 0.610
    // / 0.624 s, median 0.618 s.
    //
    // `marks` is not optional here. A spin moves NO vertex and changes NO
    // element count (verified at n=316: 99856 faces / 100489 verts / 200344
    // edges before and after), so `counts` and `positions` would both witness
    // nothing and the case would report "no work witnessed". What does move is
    // the face RINGS — `ringHash` 17319654470044337117 -> 4975600424886181897
    // on that same apply.
    cs ~= CmdCase("spinEdge/polygons/half", "mesh.spinEdge", "polygons", "half",
                  CmdWitness.marks);   // rings rewritten; no counts, no positions
    return cs;
}

// ---------------------------------------------------------------------------
// The other half of coverage: the geometry-domain commands that deliberately
// have NO case, each with the reason (task 1373).
//
// This is DATA, not prose in a task log, because invariant L2 reads it: every
// command the running app reports under /api/registry in the geometry domain
// must appear either in `commandCases()` above or in this table, or the run
// goes red and names it. A command added six months from now is therefore
// forced through one of the two doors instead of quietly never being
// measured — which is the failure this whole task exists to make impossible.
//
// The reasons are of five kinds, and they are not interchangeable:
//   * NOT A MUTATION — the command's own CmdFlags say so (read-only, UiState,
//     UI, SideEffect). A case would measure the HTTP round trip.
//   * O(1) — it does a constant amount of work regardless of mesh size. A
//     perf case on it is a row that cannot regress.
//   * NEEDS A FIXTURE THIS LANE DOES NOT HAVE — it refuses the flat grid in
//     every operand configuration tried (measured, 2026-08-19).
//   * DUPLICATE — another case already drives the same kernel.
//   * MEASURED AND TOO EXPENSIVE TO RUN NIGHTLY — with the number.
// ---------------------------------------------------------------------------
struct CmdExclusion {
    string commandId;
    string reason;
}

CmdExclusion[] excludedCommands() {
    return [
    // --- not a mutation -------------------------------------------------
    CmdExclusion("mesh.copy",             "CmdFlags.None, read-only (commands/mesh/copy.d:49-50)"),
    CmdExclusion("mesh.morph.select",     "CmdFlags.UiState (commands/mesh/morph.d:273)"),
    CmdExclusion("mesh.weightmap.select", "CmdFlags.UI (commands/mesh/weightmap.d:224)"),
    CmdExclusion("mesh.remesh.start",     "CmdFlags.SideEffect: starts a background remesher job; "
                                        ~ "a second repeat throws 'a remesh job is already in flight' "
                                        ~ "(commands/mesh/remesh.d:157,177)"),
    CmdExclusion("mesh.remesh.open",      "CmdFlags.SideEffect: opens a UI panel (remesh.d:219)"),
    CmdExclusion("mesh.select",           "selection state, not geometry; the lane sets selection itself"),
    CmdExclusion("mesh.subpatch_toggle",  "flips a per-face flag; the real cost is the OSD preview "
                                        ~ "rebuild in the FRAME loop, which belongs to the `frames` lane"),
    // --- no-op by construction at its defaults ---------------------------
    CmdExclusion("mesh.vertex_edit",      "defaults indices:[] before:[] after:[] — since task 1552 it "
                                        ~ "REFUSES (\"no vertex edit payload\") rather than running as a "
                                        ~ "no-op; either way there is no work here to time"),
    CmdExclusion("mesh.move_vertex",      "defaults from:(0,0,0) to:(0,0,0) — no-op by construction"),
    CmdExclusion("mesh.quadruple",        "measured 2026-08-19: 4096 -> 4096 faces, 0 verts moved, "
                                        ~ "0 marks changed in all four operand configurations — it "
                                        ~ "reports ok and changes no observable this lane can see"),
    CmdExclusion("uv.project",            "reports ok and changes no observable /api/model publishes; "
                                        ~ "UV coordinates need a UV witness — separate task"),
    // --- O(1) work -------------------------------------------------------
    CmdExclusion("mesh.addVertex",        "adds exactly one vertex; O(1) regardless of mesh size"),
    CmdExclusion("mesh.addPoint",         "same family as addVertex; O(1)"),
    CmdExclusion("mesh.split_edge",       "measured: +1 vertex on one edge; O(1)"),
    CmdExclusion("mesh.makePolygon",      "measured: +1 face from the selected ring; O(operand), and "
                                        ~ "the operand is what the caller chose, not the mesh"),
    CmdExclusion("mesh.tack",             "adds one vertex at a screen position; O(1)"),
    CmdExclusion("mesh.setPosition",      "writes one coordinate per selected vertex; covered by the "
                                        ~ "`magnet`/`linearAlign` position cases at lower cost"),
    CmdExclusion("mesh.centerVertices",   "same kernel family as setPosition; duplicate coverage"),
    // --- duplicate coverage ----------------------------------------------
    CmdExclusion("mesh.hideUnselected",   "same kernel + refreshHiddenDerived path as mesh.hide, "
                                        ~ "which has a case"),
    CmdExclusion("mesh.unhideAll",        "clears hide bits; refuses on a mesh with none hidden, and "
                                        ~ "the derive path is already covered by hide/hideInvert"),
    CmdExclusion("mesh.mirrorTool",       "measured identical to mesh.mirror (dF +4096 on the n=64 "
                                        ~ "grid); the tool id and the command drive one kernel"),
    CmdExclusion("mesh.bridgeTool",       "tool activation; the kernel is mesh.bridge, excluded below"),
    CmdExclusion("mesh.radialSweepTool",  "tool activation; the kernel is mesh.sweep, excluded below"),
    CmdExclusion("mesh.bevel_edit",       "the RECORD of a tool session (MeshSessionEdit): it carries "
                                        ~ "the gesture's before/after snapshots and /api/command has no "
                                        ~ "way to hand it a payload, so since task 1552 it REFUSES with "
                                        ~ "\"no recorded edit session\". Not a perf case — there is no "
                                        ~ "kernel behind this name to time"),
    CmdExclusion("mesh.remesh",           "the remesher kernel; process-isolated third-party solver, "
                                        ~ "and it refuses the flat grid"),
    // --- needs a fixture this lane does not have -------------------------
    // Every one of these was driven on the n=64 grid in four operand
    // configurations (polygons whole/half, edges whole, vertices half) on
    // 2026-08-19 and refused in all four; the ones with an obvious argument
    // to try were retried with it. The grid is a flat, open, uniformly-wound
    // quad sheet; these commands want something else.
    CmdExclusion("mesh.bridge",           "needs two boundary loops"),
    CmdExclusion("mesh.strokeExtrude",    "needs a `path` (screen stroke)"),
    CmdExclusion("mesh.screenSlice",      "needs screen-space cut coordinates"),
    CmdExclusion("mesh.cut",              "clipboard state shared with mesh.paste; a repeat-based "
                                        ~ "case would measure a different thing each repeat"),
    CmdExclusion("mesh.paste",            "needs a prior mesh.cut/copy in the same process"),
    CmdExclusion("mesh.transform",        "requires kind:translate|rotate|scale; the same kernels the "
                                        ~ "drag matrix above measures under a live gizmo"),
    CmdExclusion("mesh.align",            "refuses the flat grid in all four operand configurations"),
    CmdExclusion("mesh.cleanup",          "refuses: nothing degenerate to clean on a fresh grid"),
    CmdExclusion("mesh.fixOrientation",   "refuses: the grid is already uniformly wound"),
    CmdExclusion("mesh.julienne",         "refuses the flat grid on both axis pairs tried (0/2 and "
                                        ~ "the defaults)"),
    CmdExclusion("mesh.symmetrize",       "refuses the flat grid (no topology to mirror onto)"),
    CmdExclusion("mesh.reduce",           "refuses the flat grid at ratio:0.5 with and without an operand"),
    CmdExclusion("mesh.edgeSlice",        "refuses: needs a slice path across selected edges"),
    CmdExclusion("mesh.edgeJoin",         "refuses: needs two boundary edges to join"),
    CmdExclusion("mesh.edge_slide",       "interactive; needs a drag offset"),
    CmdExclusion("mesh.splitFace",        "refuses: needs two vertices on one face"),
    CmdExclusion("mesh.weldVertexPair",   "refuses: needs exactly two vertices"),
    CmdExclusion("mesh.sweep",            "measured: with a 3-edge operand it adds 4 verts / 6 faces "
                                        ~ "— O(operand), not O(mesh); with any larger operand it refuses"),
    CmdExclusion("vert.join",             "measured shrink at vertices/half, but it is mesh.collapse's "
                                        ~ "kernel (identical -1984 F / -2079 V), which has a case"),
    CmdExclusion("vert.merge",            "refuses: the grid has no coincident vertices to merge"),
    CmdExclusion("poly.unify",            "refuses: the grid has no duplicate faces to unify"),
    CmdExclusion("mesh.setPart",          "same shape as setMaterial (a per-face uint), which has a "
                                        ~ "case; and it refuses the empty selection"),
    CmdExclusion("mesh.edgeCrease.set",   "per-edge weight write; needs an edge operand and publishes "
                                        ~ "no observable in /api/model"),
    CmdExclusion("mesh.edgeCrease.clear", "same as edgeCrease.set"),
    CmdExclusion("mesh.morph.apply",      "needs a morph map to exist"),
    CmdExclusion("mesh.morph.clear",      "needs a morph map to exist"),
    CmdExclusion("mesh.morph.create",     "needs a name argument"),
    CmdExclusion("mesh.morph.remove",     "needs a morph map to exist"),
    CmdExclusion("mesh.morph.rename",     "needs a morph map to exist"),
    CmdExclusion("mesh.morph.set",        "needs a morph map to exist"),
    CmdExclusion("mesh.weightmap.create", "needs a name argument"),
    CmdExclusion("mesh.weightmap.remove", "needs a weight map to exist"),
    CmdExclusion("mesh.weightmap.rename", "needs a weight map to exist"),
    CmdExclusion("mesh.weightmap.set",    "needs a weight map to exist"),
    // uv.* — twelve commands that need a UV map and a UV witness. /api/model
    // publishes no UV channel, so a case on any of them would be a row that
    // cannot fail. That witness is its own task.
    CmdExclusion("uv.clear",   "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.copy",    "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.delete",  "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.fit",     "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.flip",    "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.mirror",  "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.pack",    "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.relax",   "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.rename",  "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.rotate",  "needs a UV map; no UV observable in /api/model"),
    CmdExclusion("uv.unwrap",  "needs a UV map; no UV observable in /api/model"),
    ];
}

// The bare command id out of a `CmdCase.commandId` argstring — everything
// before the first space ("mesh.bevel inset:0.02 group:false" -> "mesh.bevel").
string commandIdOf(string argstring) {
    foreach (i, ch; argstring)
        if (ch == ' ') return argstring[0 .. i];
    return argstring;
}

// The geometry domain, stated once. Same prefixes the task's classification
// sweep used, and the same ones doc/command_reference.md groups by.
bool isGeometryDomainCommand(string id) {
    return id.startsWith("mesh.") || id.startsWith("poly.")
        || id.startsWith("edge")  || id.startsWith("vert")
        || id.startsWith("uv.");
}

// Invariant L2's finding: geometry-domain commands the running app reports
// that are in NEITHER the case table nor the exclusion table.
//
// The point is the direction of the check. It does not ask "is every case
// still valid" (which a run answers by itself) but "is every COMMAND still
// accounted for" — so a geometry command added later cannot slip into the
// tree unmeasured and unexplained. Prose in a task log does not do this; a
// list someone maintains by hand does not do this either, because the list
// and the registry drift apart silently. The registry is asked at run time.
string[] computeCoverageGap(string[] registryIds) {
    bool[string] cased, excluded;
    foreach (c; commandCases())     cased[commandIdOf(c.commandId)] = true;
    foreach (e; excludedCommands()) excluded[e.commandId] = true;
    string[] gap;
    foreach (id; registryIds) {
        if (!isGeometryDomainCommand(id)) continue;
        if ((id in cased) !is null || (id in excluded) !is null) continue;
        gap ~= id;
    }
    // Task 1471 — the OTHER way the two tables can disagree, which this
    // function used to be blind to. It merged both into one `accounted` set,
    // so "in neither" was caught and "in BOTH" read as covered. That is not
    // hypothetical: promoting a command out of the exclusion table into a case
    // is exactly the edit that leaves the stale exclusion behind, and its text
    // — here, "~70 MINUTES for one apply" — then sits in the tree beside a
    // sub-second row, saying the opposite of the truth, with the lane green.
    foreach (id; cased.byKey)
        if ((id in excluded) !is null)
            gap ~= id ~ " (BOTH a case and an exclusion — the exclusion's " ~
                        "reason is now stale prose; delete one)";
    gap.sort();
    return gap;
}

// The pristine-fixture probe, taken ONCE per run and shared by every
// `positions`/`marks` case (task 1373).
//
// Two facts make one probe enough. (1) Every command case begins with
// `resetMesh(meshType, n)`, which rebuilds the SAME grid deterministically,
// so the "before" state is identical for all of them. (2) The comparison
// that matters is against the PRISTINE mesh, not against the previous
// repeat: a command whose reset puts the mesh back where it started would
// pass a repeat-to-repeat comparison while doing nothing at all (this is the
// same hole the tools lane closed on its side, run.d's runToolCase step 4).
//
// It is cached because it is not cheap: measured on this host 2026-08-19,
// one /api/model probe at n=316 is 1171 ms of GET plus 884 ms of parseJSON
// plus 13 ms of extraction = 2068 ms. Per-case before+after would be 4.1 s
// each; sharing the before halves it, and the `counts` cases — every growing
// and shrinking command, i.e. most of the table — never take a probe at all.
private MeshProbe g_pristine;
private bool      g_pristineValid = false;
private int       g_pristineN     = -1;
private string    g_pristineType  = "";

MeshProbe pristineProbe(string meshType, int n) {
    if (g_pristineValid && g_pristineN == n && g_pristineType == meshType)
        return g_pristine;
    resetMesh(meshType, n);
    g_pristine      = meshProbe();
    g_pristineValid = true;
    g_pristineN     = n;
    g_pristineType  = meshType;
    return g_pristine;
}

// Compare an after-probe to the pristine fixture and answer BOTH "did this
// case do the work its witness claims" and "what exactly did it see". The
// detail string is the point as much as the boolean: a case that goes red
// has to say which observable stood still, or the next reader re-derives the
// measurement to find out.
private struct WitnessVerdict { bool ok; string detail; }

WitnessVerdict judgeWitness(CmdWitness w, ref MeshProbe before, ref MeshProbe after,
                            long beforeVerts, long beforeFaces,
                            long afterVerts, long afterFaces) {
    final switch (w) {
    case CmdWitness.counts:
        bool ok = beforeFaces > 0
               && (afterFaces != beforeFaces || afterVerts != beforeVerts);
        return WitnessVerdict(ok,
            format("counts %d verts/%d faces -> %d/%d",
                   beforeVerts, beforeFaces, afterVerts, afterFaces));

    case CmdWitness.positions: {
        if (afterVerts != beforeVerts || afterFaces != beforeFaces)
            return WitnessVerdict(false,
                format("positions: a deform changed the COUNTS " ~
                       "(%d/%d -> %d/%d) — wrong witness for this command",
                       beforeVerts, beforeFaces, afterVerts, afterFaces));
        // EVERY vertex, not a sample. A 9-index sample cannot see a local
        // deform (mesh.magnet at a small dist moves a neighbourhood), and
        // under the lane-health gate a false negative reddens the nightly.
        // The comparison is ~100k float triples against an array that is
        // already parsed and resident — 13 ms of the 2068 ms the probe costs.
        size_t nv = before.pos.length < after.pos.length
                  ? before.pos.length : after.pos.length;
        size_t moved = 0;
        double worst = 0;
        for (size_t i = 0; i + 2 < nv; i += 3) {
            double dx = after.pos[i]     - before.pos[i];
            double dy = after.pos[i + 1] - before.pos[i + 1];
            double dz = after.pos[i + 2] - before.pos[i + 2];
            double d  = sqrt(dx * dx + dy * dy + dz * dz);
            if (d > 1e-5) { moved++; if (d > worst) worst = d; }
        }
        return WitnessVerdict(moved > 0,
            format("positions %d/%d verts moved, max %.4f",
                   moved, nv / 3, worst));
    }

    case CmdWitness.marks: {
        if (afterVerts != beforeVerts || afterFaces != beforeFaces)
            return WitnessVerdict(false,
                format("marks: the counts changed (%d/%d -> %d/%d) — wrong " ~
                       "witness for this command",
                       beforeVerts, beforeFaces, afterVerts, afterFaces));
        static size_t diffBool(bool[] a, bool[] b) {
            size_t n = a.length < b.length ? a.length : b.length, d = 0;
            foreach (i; 0 .. n) if (a[i] != b[i]) d++;
            return d;
        }
        size_t fh = diffBool(before.faceHidden,   after.faceHidden);
        size_t vh = diffBool(before.vertexHidden, after.vertexHidden);
        size_t eh = diffBool(before.edgeHidden,   after.edgeHidden);
        size_t mt = 0;
        {
            size_t n = before.faceMaterial.length < after.faceMaterial.length
                     ? before.faceMaterial.length : after.faceMaterial.length;
            foreach (i; 0 .. n)
                if (before.faceMaterial[i] != after.faceMaterial[i]) mt++;
        }
        bool rings = before.ringHash != after.ringHash;
        bool ok = fh > 0 || vh > 0 || eh > 0 || mt > 0 || rings;
        return WitnessVerdict(ok,
            format("marks faceHidden %d, vertexHidden %d, edgeHidden %d, " ~
                   "faceMaterial %d changed; rings %s",
                   fh, vh, eh, mt, rings ? "rewritten" : "identical"));
    }
    }
}

CaseResult runCommandCase(ref CmdCase c, int n, string meshType, int repeats) {
    CaseResult res;
    res.name = c.name;
    res.historyKey = c.name;   // command cases never pin their own size
    res.isCommand = true;
    res.note = c.mode ~ " " ~ c.selection;
    res.effectiveN = n;

    // A dump-based witness must never be pointed at a case that grows the
    // mesh: /api/model is main-thread-serialised and the x5-growth commands
    // reach half a million faces from the n=316 grid. `counts` reads
    // /api/layers instead, which is three integers. This is an assertion
    // about the TABLE, checked here rather than trusted, because the failure
    // mode of getting it wrong is a wedged instance and every later case red.
    immutable bool wantsProbe = c.witness != CmdWitness.counts;

    MeshProbe before;
    if (wantsProbe) before = pristineProbe(meshType, n);

    double[] applyUs;
    JSONValue last;
    long lastCount = 0;
    long beforeFaces = 0, afterFaces = 0;
    long beforeVerts = 0, afterVerts = 0;
    MeshProbe after;

    foreach (r; 0 .. repeats) {
        // Rebuild the cage every repeat — most of these are destructive.
        resetMesh(meshType, n);
        // Selection (+ edit mode side effect) is OUTSIDE the measured window.
        if (!selectMode(c.mode, cmdIndices(c, n))) {
            res.status = CaseStatus.ERROR;
            res.detail = "selection failed";
            return res;
        }
        // activeLayerInfo, NOT modelInfo/meshProbe: the counts are needed on
        // EVERY case including the ones whose result outgrows the dump.
        auto mb = activeLayerInfo();
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
        auto ma = activeLayerInfo();
        afterFaces = ma.faceCount;
        afterVerts = ma.vertexCount;
        last = perf;
        // The dump is taken around repeat 0 only, and OUTSIDE the measured
        // window (perfReset..perfRead already closed above).
        if (wantsProbe && r == 0) after = meshProbe();
    }

    auto v = judgeWitness(c.witness, before, after,
                          beforeVerts, beforeFaces, afterVerts, afterFaces);
    res.witnessDetail = v.detail;
    if (!v.ok) {
        res.status = CaseStatus.ERROR;
        res.detail = format("no work witnessed (%s): %s",
                            c.witness.to!string, v.detail);
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
// `tools` subcommand — the cost of ONE interactive-tool preview rebuild.
//
// SIXTEEN tools (not the 21 the task statement counted — see the exclusion
// table in tools/perf/README.md) rebuild a standing preview on every drag
// frame and on every interactive attribute scrub. Every one of them has the
// same shape:
//
//     before.restore(*mesh);   // MeshSnapshot.restore  → Cat.previewRestore
//     <the tool's own kernel>  // ← what a per-tool case would exist to watch
//     refreshCaches();         // display_sync.refreshDisplay → Cat.previewRefresh
//
// and the whole method is wrapped in Cat.toolPreview.
//
// This lane deliberately ships ONE case, not sixteen, because the number
// that decides whether sixteen are worth writing is the KERNEL SHARE:
//
//     kernel = toolPreview - previewRestore - previewRefresh
//     share  = kernel / toolPreview
//
// If the share is small — i.e. the shared wrapper dominates — then a 2x
// regression in a tool's own kernel moves `toolPreview` by only `+share`.
// Write the rebuild as `k + w` (kernel + wrapper) so `share = k/(k+w)`;
// doubling the kernel takes it to `2k + w`, a ratio of
// `(2k+w)/(k+w) = 1 + share`. At share=0.1 that is +10%: under the harness's
// +30% absolute tolerance and inside the session-to-session drift already
// recorded on this bench. Per-tool cases would then be STRUCTURALLY
// incapable of going red on the thing they exist for, and the deliverable
// is a fix to the wrapper, not fifteen more rows. The share is printed as
// its own column for exactly that decision.
//
// NOT `toolPreview - cacheInvalidate - gpuUpload`: those two categories are
// opened in app.d's MAIN FRAME LOOP, not inside the preview call. Their
// samples come from frames that happened to render near the window, so that
// subtraction mixes two clocks and its SIGN depends on the frame rate.
//
// The metric is "one `rebuildPreview`", NOT "one preview frame". A real drag
// additionally pays the frame loop's own cache invalidation, GPU upload and
// draw; this driver never triggers those between calls, so the number here
// is a strict LOWER bound on a drag frame.
// ---------------------------------------------------------------------------

struct ToolCase {
    string name;       // "polyInset/half"
    string toolId;     // "mesh.polyInsetTool"
    string mode;       // "vertices" | "edges" | "polygons" | "" (no selection)
    string selection;  // "whole" | "half" | "single" | "ring"
    string attr;       // "inset"
    double v0, v1;     // ALTERNATED across repeats — see runToolCase step 6
    int    meshN;      // pinned grid size; 0 = the run's --n
    string note;
}

// Selection indices for a tool case, by mode. Mirrors cmdIndices above.
int[] toolIndices(ref ToolCase c, int n) {
    if (c.selection == "whole")  return [];
    if (c.mode == "vertices")    return c.selection == "half" ? selHalf(n)
                                      : c.selection == "ring" ? selRing(n)
                                      : selSingle(n);
    if (c.mode == "polygons")    return faceHalf(n);
    return [];
}

// The case table. ONE row on purpose (task 1370): see the header comment.
//
// CLAMP RULE for anyone adding a row — the bench is its own DoS. Integer
// attributes that scale an allocation (`array_tool`'s numX, clamped at 64;
// `radial_array_tool`'s count, clamped at 256) must be kept at the LOW end:
// numX=64 on a 4k-face grid is 262k faces produced inside ONE preview
// rebuild. Keep such attrs at 2→3, and pin `meshN` rather than inheriting
// the run's --n.
ToolCase[] toolCases() {
    ToolCase[] cs;
    // polyInset on half the grid's faces. Pinned at TOOLCASE_NMAX — the
    // frozen size from Phase 0b, NOT the run's --n and NOT recomputed per
    // night (recomputing would make the number incomparable night to night).
    cs ~= ToolCase("polyInset/half", "mesh.polyInsetTool", "polygons", "half",
                   "inset", 0.02, 0.04, TOOLCASE_NMAX,
                   "one rebuildPreview (NOT one preview frame)");
    return cs;
}

// Frozen by Phase 0b under `dub build --build=perf` (task 1370, 2026-08-19).
// Debug-build numbers set the SHAPE of the curve; the perf build set the
// threshold. Measured, `mesh.polyInsetTool` on faceHalf, median of one
// rebuildPreview, with the kernel share beside it:
//
//     n=64   4096 faces     30.8 ms   share 93.5%
//     n=96   9216 faces    126.1 ms   share 96.9%   <- TOOLCASE_NMAX
//     n=128 16384 faces    404.8 ms   share 98.1%
//     n=200 40000 faces   2668   ms   share 99.4%
//     n=316 99856 faces  16546   ms   share 99.7%
//
// The ceiling is 200 ms per rebuild, so n=96 is the largest step that fits;
// n=128 is twice past it. NOT recomputed per run — a size chosen fresh each
// night makes the number incomparable night to night, which is the whole
// reason it is a literal here rather than a search.
//
// Read the curve before enlarging it: 4x the faces costs 13x, and 2.4x more
// costs 41x again. That is not the wrapper (whose restore+refresh is 15 ms
// of the 126 at n=96 and 235 ms of the 16546 at n=316) — it is the tool's
// own kernel, super-quadratic in the operand. Raising this literal buys
// timeout risk, not resolution.
enum int TOOLCASE_NMAX = 96;

CaseResult runToolCase(ref ToolCase c, int runN, string meshType, int repeats) {
    CaseResult res;
    res.name        = c.name;
    res.note        = c.note;
    res.isToolPreview = true;

    // 0. Per-case mesh size. A pinned size is grid-only: under --subdivcube
    // the reset parameter means subdivision LEVELS, so the pin is
    // meaningless and the case SKIPs rather than silently measuring a
    // different mesh (same rule as Case.meshN in runCase).
    int n = runN;
    if (c.meshN > 0) {
        if (meshType != "grid") {
            res.status = CaseStatus.SKIP;
            res.detail = format("pinned n=%d is grid-only (run is %s)",
                                c.meshN, meshType);
            return res;
        }
        n = c.meshN;
    }
    res.effectiveN = n;

    resetMesh(meshType, n);
    {
        auto mi = activeLayerInfo();
        res.effectiveVertexCount = mi.vertexCount;
        res.effectiveFaceCount   = mi.faceCount;
    }

    // 1. Operand. Every one of these tools measures a REFUSAL if its operand
    // is wrong (task 1370 Phase 0.2 found `edge.extrude`'s handle moving an
    // attribute while the kernel no-opped), which is why I8b below checks
    // geometry rather than the attribute.
    if (c.mode.length) {
        if (!selectMode(c.mode, toolIndices(c, n))) {
            res.status = CaseStatus.ERROR;
            res.detail = "selection failed";
            return res;
        }
    }

    // 2. Arm the tool. `tool.set ... off` at the end is OUTSIDE the measured
    // window and COMMITS the edit into history (deactivate() → commitEdit),
    // which is why every case starts from its own resetMesh above rather
    // than inheriting the previous case's mesh.
    if (!script(format("tool.set %s on", c.toolId))) {
        res.status = CaseStatus.ERROR;
        res.detail = format("tool.set %s on failed", c.toolId);
        return res;
    }
    scope(exit) script(format("tool.set %s off", c.toolId));

    // Probe helpers. `/api/model` is the heaviest request this file makes and
    // lib/drag.d's `vertexPos` has neither a retry nor a size guard (its own
    // comment warns the endpoint times out past ~500k faces); an exception
    // out of it would escape `runToolCase` UNCAUGHT and abort the whole lane
    // instead of producing the ERROR row L1 counts. Caught here rather than
    // in drag.d, whose ops call sites have their own handling (review fix,
    // task 1370). First failure latches and the rest short-circuit, so one
    // stalled endpoint costs one timeout, not four.
    string probeErr;
    Vec3 probePos(int idx) {
        if (probeErr.length) return Vec3(0, 0, 0);
        try   { return vertexPos(idx); }
        catch (Exception e) { probeErr = "vertexPos: " ~ e.msg; return Vec3(0, 0, 0); }
    }
    LayerInfo probeInfo() {
        if (probeErr.length) return LayerInfo.init;
        try   { return activeLayerInfo(); }
        catch (Exception e) { probeErr = "activeLayerInfo: " ~ e.msg; return LayerInfo.init; }
    }

    auto before = probeInfo();
    Vec3 posBefore = probePos(0);

    // 3. WARM-UP — one interactive attr write, discarded. It has to be
    // separate: the first write is what sets `built` and populates the
    // tool's `before` baseline, so the steady-state rebuild only starts with
    // the second.
    if (!scriptInteractive(format("tool.attr %s %s %s", c.toolId, c.attr, c.v0))) {
        res.status = CaseStatus.ERROR;
        res.detail = format("warmup tool.attr %s %s failed", c.attr, c.v0);
        return res;
    }
    auto afterV0 = probeInfo();
    Vec3 posAfterV0 = probePos(0);

    // 3b. A SECOND pre-window write, at `v1` — because the measured window
    // ALTERNATES the two values and one probe can only witness one of them.
    // Without this, `v1` runs on 3 of 5 repeats completely unwitnessed, and
    // a row whose `v1` lands on a tool's refusal branch (`edge_bevel.d`'s
    // `if (width_ == 0.0f) { restore; refresh; return; }`, and the same
    // `x_ == 0` shape in poly_bevel / poly_extrude / edge_extrude /
    // vertex_bevel / vertex_extrude) keeps every count at `repeats` — I8a,
    // I8b and I8c all green — while 3 of 5 samples are pure wrapper. Since
    // the reported median RANKS those samples, the published median and the
    // published kernel share would then be blends of a real kernel and a
    // refusal (review fix, task 1370; mutation M8).
    if (!scriptInteractive(format("tool.attr %s %s %s", c.toolId, c.attr, c.v1))) {
        res.status = CaseStatus.ERROR;
        res.detail = format("probe tool.attr %s %s failed", c.attr, c.v1);
        return res;
    }
    auto afterV1 = probeInfo();
    Vec3 posAfterV1 = probePos(0);

    if (probeErr.length) {
        res.status = CaseStatus.ERROR;
        res.detail = "geometry probe failed: " ~ probeErr;
        return res;
    }

    // 4. I8b's evidence, collected BEFORE the measured window so the probes'
    // own HTTP round trips cannot land samples in it.
    //
    // WHAT IS NOT EVIDENCE HERE, and why it is spelled out: `mutationVersion`.
    // The command lane's sanity check (runCommandCase) uses it to cover pure
    // deforms, and copying that here produced an invariant that COULD NOT
    // FAIL — verified by mutation, task 1370: driving `edge.extrude`'s
    // `extrude` attr (whose kernel no-ops below `width < 1e-6`) left
    // 9409/9216 verts/faces untouched and still bumped the version 27841 →
    // 27842, and I8b passed. The bump is `MeshSnapshot.restore`'s own
    // `commitChange(MeshChangeAll)`, which every rebuildPreview performs
    // BEFORE the kernel runs. So the version moves once per rebuild whether
    // or not the tool did anything, and reading it here is reading the
    // wrapper, not the tool.
    //
    // What is left is COUNTS plus one vertex POSITION. Its limit, stated so
    // nobody re-adds the version term to "cover" it: a preview that changes
    // no count AND leaves vertex 0 where it was is invisible to this clause.
    // No case in the table is of that shape (every attr-reachable family-1
    // tool changes counts), and a future one must extend this probe rather
    // than reach for a version number that always moves.
    //
    // BOTH driven values are checked, and BOTH against the PRISTINE mesh —
    // never against each other. A refusing rebuild still runs the wrapper's
    // `before.restore(*mesh)` first, so it leaves the mesh exactly pristine;
    // comparing `v1`'s result against `v0`'s would read that restore as
    // movement and pass on the refusal it exists to catch.
    static string fmtGeom(LayerInfo li, Vec3 p) {
        return format("%d/%d @(%.4f,%.4f,%.4f)", li.vertexCount, li.faceCount,
                      p.x, p.y, p.z);
    }
    bool movedFromPristine(LayerInfo a, Vec3 p) {
        auto d = p - posBefore;
        immutable double posDelta = sqrt(cast(double)dot(d, d));
        return before.faceCount > 0 &&
            (a.faceCount != before.faceCount
             || a.vertexCount != before.vertexCount
             || posDelta > 1e-5);
    }
    res.geomBefore  = fmtGeom(before,  posBefore);
    res.geomAfterV0 = fmtGeom(afterV0, posAfterV0);
    res.geomAfterV1 = fmtGeom(afterV1, posAfterV1);
    res.geometryChanged = movedFromPristine(afterV0, posAfterV0)
                       && movedFromPristine(afterV1, posAfterV1);

    // 5. perfReset HERE — after BOTH pre-window writes, before the repeats.
    // Earlier and a pre-window rebuild lands in the window (count ==
    // repeats + 1 per write that leaks in); later and the first repeat is
    // lost (count == repeats - 1). Either way I8a's exact-equality check is
    // what catches the slip, which is why it is stated as `== repeats` and
    // not `> 0`.
    perfReset();

    // 6. R repeats, ALTERNATING v0/v1. Repeating the same value would be a
    // no-op for any tool whose evaluate()/onParamChanged checks dirtiness,
    // and the case would measure zero while counting correctly. The window
    // therefore OPENS on v0 — the last pre-window write was v1 (step 3b), so
    // starting on v1 would make the first repeat the very same-value write
    // this alternation exists to avoid.
    foreach (r; 0 .. repeats) {
        double v = (r % 2 == 0) ? c.v0 : c.v1;
        if (!scriptInteractive(format("tool.attr %s %s %s", c.toolId, c.attr, v))) {
            res.status = CaseStatus.ERROR;
            res.detail = format("repeat %d tool.attr %s %s failed", r, c.attr, v);
            return res;
        }
    }
    auto perf = perfRead();

    long cnt(string cat)  { return (cat in perf) ? perf[cat]["count"].integer : 0; }
    double us(string cat) { return cast(double)sumNs(perf, cat) / 1000.0; }

    res.toolPreviewCount    = cnt("toolPreview");
    res.previewRestoreCount = cnt("previewRestore");
    res.previewRefreshCount = cnt("previewRefresh");
    res.toolPreviewSumUs    = us("toolPreview");
    res.previewRestoreSumUs = us("previewRestore");
    res.previewRefreshSumUs = us("previewRefresh");
    res.previewKernelUs     = res.toolPreviewSumUs
                            - res.previewRestoreSumUs - res.previewRefreshSumUs;
    res.kernelShare = res.toolPreviewSumUs > 0
        ? res.previewKernelUs / res.toolPreviewSumUs : 0.0;

    // FAIL-FAST on an uninstrumented binary — inherited verbatim from
    // runCase: the attr calls demonstrably changed geometry, yet no timer
    // fired, so ./vibe3d was not built with --build=perf and every number
    // below would be a meaningless zero.
    if (res.geometryChanged && res.toolPreviewCount == 0
        && sumNs(perf, "previewRestore") == 0)
        throw new Exception(
            "./vibe3d lacks PerfProbe instrumentation (toolPreview stayed 0 "
            ~ "through a real preview rebuild) — it was not built with "
            ~ "--build=perf. Re-run without --no-build so the runner builds "
            ~ "the perf binary, or build it yourself: dub build --build=perf "
            ~ "--compiler=" ~ LDC2);

    // Carried in the shared fields so the existing table/results plumbing
    // works: the headline cost of ONE rebuild is the probe's own median
    // across the R samples (not a harness-side median of per-repeat sums —
    // one perfReset covers all R repeats, so the ring holds the samples).
    //
    // NAMING, stated because it misleads on sight: `kernelMedianUs` /
    // `kernelP95Us` / `dominantStage` are the OPS lane's field names and in
    // this lane they carry the WHOLE rebuild (`toolPreview` = wrapper +
    // kernel), NOT `previewKernelUs`. Everything that leaves this struct
    // renames them for the reader — the results JSON writes
    // `toolPreviewMedianUs`, the table column says `rebuild`, and the history
    // key is `<case>#previewRebuild` — precisely so no consumer reads a
    // wrapper number under the word "kernel" (review fix, task 1370).
    res.kernelMedianUs = ("toolPreview" in perf)
        ? cast(double)perf["toolPreview"]["median_ns"].integer / 1000.0 : 0.0;
    res.kernelP95Us    = ("toolPreview" in perf)
        ? cast(double)perf["toolPreview"]["p95_ns"].integer / 1000.0 : 0.0;
    res.dominantStage  = "toolPreview";
    res.lastBreakdown  = perf;
    res.status = CaseStatus.OK;
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
    // tab-cold (task 1374, F-I8/F-I9). `subpatchPreview.count` above cannot
    // tell a cold stencil build from an LRU cache hit -- the scope timer opens
    // at the TOP of buildPreview, before the cache lookup -- so a cold-path
    // measurement needs the split counters to be able to assert it measured
    // what it claims. See perf_probe.d's Cat.subpatchTopoMiss.
    long       subpatchTopoMiss = -1;  // Cat.subpatchTopoMiss.count
    long       subpatchTopoHit  = -1;  // Cat.subpatchTopoHit.count
    long       subpatchLevel    = -1;  // Cat.subpatchLevelChosen.sum (== the
                                       // level, given the gated count == 1)
    // ---- Task 1500: the WORK THAT MOVED OFF THE FRAME LOOP ---------------
    // The preview build now runs on a worker thread. `stats` therefore stops
    // seeing its wall time, and `stats.gcAllocBytes` stops seeing its
    // allocation (it is `GC.allocatedInCurrentThread`, main-thread-local).
    // Left there, this lane would report a multi-fold speed-up and a ~2x
    // allocation win for a change that removed no work at all. These three
    // are the window DELTAS that keep both halves of F-I9 measuring the same
    // quantity they measured before, and F-I10 measuring that the work is
    // still being done somewhere.
    long       subpatchWorkerNs         = -1;  // wall ns inside the worker
    long       subpatchWorkerAllocBytes = -1;  // GC bytes allocated there
    long       subpatchPendingFrames    = -1;  // frames drawn while it ran
    // ---- Task 1540: what the `cache` PHASE is actually made of ----------
    // The phase timer (`stats.worst.cacheNs`) spans two unrelated jobs: the
    // viewcache block (`Cat.cacheInvalidate`) and the per-frame hover pick
    // (`Cat.hoverPick`), the latter of which pays a full BVH construction
    // (`Cat.bvhRebuild`) on the frame after the source mesh changed. 1500
    // reported the phase at 87-94 % of the first Tab's worst frame and named
    // the BVH as its bulk WITHOUT splitting it -- these three are the split.
    //
    // They are WINDOW SUMS off /api/perf, not per-frame ring values, so they
    // are comparable to the SUM of `cacheNs` over the window and not to the
    // worst frame alone. `framesReset()` and `perfReset()` are called back to
    // back in runTabCold, so both windows open at the same point.
    long       cacheInvalidateNs = -1;
    long       viewcacheRebuildNs = -1;
    long       hoverPickNs       = -1;
    long       bvhRebuildNs      = -1;
    long       bvhRebuildCount   = -1;
    long       bvhRebuildTris    = -1;
    long       bvhRebuildTrisN   = -1;  // how many rebuilds REACHED the build
    long       bvhRebuildMaxNs   = -1;  // the single most expensive rebuild
    long       worstCacheNs      = -1;  // the worst FRAME's cache phase
    long       bvhAbortFaces     = -1;
    long       bvhAbortVerts     = -1;
    long       bvhAbortN         = -1;
    long       bvhEnterN         = -1;
    // Cage face count at the moment of the measured toggle — F-I11's yardstick
    // for "cage-sized or limit-sized".
    long       cageFacesAtToggle = -1;
    long       hoverPickCount    = -1;
    long       cacheNsWindowSum  = -1;  // sum of the PHASE over the window
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

// --- tab-cold (task 1374) -------------------------------------------------

// Post-build frames, driven as a fixed hover sweep. Two frames in this
// scenario are expensive, not one: the buildPreview frame, and then the GPU
// upload / first draw of the limit surface. A measurement that stops at the
// first misses half the cost of Tab -- and since the main loop is
// event-driven, "stops at the first" is exactly what a bare sleep gives
// (re-measured 2026-08-19 under the review fixes: replacing the sweep with a
// 600 ms sleep leaves the window at frameCount == 1 and gcAllocBytes at
// 7 551 520 B, which the byte bound passes by 13x -- see F-I9).
//
// WHAT THE STEP COUNT DOES, measured rather than assumed: it is NOT what sets
// the window's frame count. Dropping it 30 -> 1 changes the window from ~84 to
// 76 frames, not to a handful. The sweep's job is to WAKE the event-driven main
// loop; once awake it free-runs through the playback and the settle, and the
// count is then a function of host speed, not of this number. So do not reach
// for this constant to move the frame count -- and see K_TAB_COLD_FRAMES_LO/HI
// for what actually bounds it.
enum int kTabColdHoverSteps = 30;

// Give up waiting for the build. Generous: the worst measured cold Tab on the
// bad side of the depth cliff is seconds, and a scenario that times out is
// reported as an ERROR (which fails the run) rather than silently measuring a
// window the build never entered.
enum int kTabColdBuildTimeoutMs = 90_000;

// F-I9's ceiling on the measured window's TOTAL main-thread GC allocation.
//
// Gates the WINDOW SUM (`FrameStats.gcAllocBytes`), deliberately NOT the
// worst-frame figure. There are two expensive frames here and which one is
// slowest can flip after any fix to either -- pinning the worst frame's bytes
// would move the gate's subject without any regression having happened. The
// worst-frame bytes are still REPORTED, in F-I9's detail and in the
// worst-frame breakdown line.
//
// Calibrated in the cold-topology / WARM-BUFFER regime `runTabCold` pins (see
// its header), on the n=316 grid: 5 relaunched repeats measured
// 88.85 / 89.06 / 89.69 / 89.69 / 89.90 MB (2026-08-19, loadavg 1.6-1.9,
// ldc2 1.42 perf build), max + ~15%.
enum long K_TAB_COLD_ALLOC_BYTES = 104_000_000;

// ... and the point it was calibrated ON. Unlike every other F-Ix, F-I9 is a
// BYTE value, so it scales with the cage: the same code allocates 72 MB at
// n=157 and 345 MB at n=306 (measured). Gating it off the calibration point
// would turn `frames --n 400` into a red run with no regression in it, so off
// that point F-I9 is RECORDED, non-gating. CI runs `--n 316` (see
// .github/workflows/perf.yaml), which IS the calibration point.
enum string K_TAB_COLD_CALIB_MESH = "grid";
enum int    K_TAB_COLD_CALIB_N    = 316;

// The refinement level the depth policy picks at that point, and the FIRST
// live witness the policy has (task 1374 review, SF-2). `Cat.
// subpatchLevelChosen` landed reported-but-not-gated: F-I8's verdict read only
// count/miss/hit, and `perfCounterSum` answers 0 for an absent key, so deleting
// the `g_perf.count(Cat.subpatchLevelChosen, ...)` line reddened nothing
// anywhere.
//
// grid n=316 is 99 856 quad cage faces = 399 424 corners; at the app's
// requested depth of 3 the corner projection gives 399 424*16 = 6 390 784 (L3,
// over the ceiling), 399 424*4 = 1 597 696 (L2, over), 399 424 (L1, under) --
// so level 1. The PRE-1374 face projection lands on 1 as well, which is what
// makes this a witness for the counter and the production wiring rather than a
// restatement of the change: a quad cage cannot discriminate the two formulas
// (see tests/unit/subpatch_level_policy_test.d), so this number would not move
// even if the projection were reverted. It pins that the policy is READ and
// REPORTED in the live process, on a production-sized cage.
//
// Gated only at the calibration point, like the byte bound: the chosen level
// is a function of the cage.
enum int K_TAB_COLD_CALIB_LEVEL = 1;

// The window's per-frame ImGui-chrome allocation floor, and F-I9's FRAME-COUNT
// band (task 1374 review, SF-6).
//
// WHAT WAS MEASURED, 2026-08-19, grid n=316, and it is stronger than the
// argument it replaces. The window's allocation is EXACTLY linear in its frame
// count, with a deterministic intercept:
//
//     gcAllocBytes  =  79 137 568 B  +  211 168 B x frameCount
//
// Nine runs across two sessions and both invocations — (97 720 352, 88),
// (97 298 016, 86), (95 186 336, 76), (97 298 016, 86), (96 875 680, 84) from
// the full `--ci` lane; (89 062 464, 47), (89 903 040, 51), (97 505 088, 87)
// solo — all give the same intercept to within 4 096 B (one page). The slope
// is `steadyMaxAllocBytes` for this scenario, 211 168 B, on the nose.
//
// So the frame count is NOT a constant of the scenario, and the claim that it
// was is corrected here and at runTabCold. It is also NOT explained by the
// invocation: solo runs have been measured at 47 and at 87 frames in different
// sessions, so it tracks host conditions, not the scenario list. Every byte of
// the spread is chrome — which is exactly why the count has to be BOUNDED
// rather than assumed: F-I9's subject moves ~9 MB across the observed range,
// and a change that collapsed the window to a handful of frames would take
// ~10 MB of floor out of the bound with nothing red anywhere.
//
// THE BAND'S EDGES ARE DERIVED, not padded:
//   HI = 110 — the chrome floor ALONE reaches K_TAB_COLD_ALLOC_BYTES at 118
//              frames ((104 000 000 - 79 137 568) / 211 168 = 117.7). Past
//              that the byte bound would red on window SHAPE and report it as
//              an allocation regression. HI sits below it, so a window that
//              grows is named by the frame half instead of misattributed.
//   LO =  40 — 15 % under the smallest count ever measured (47, solo). Below
//              it the byte bound has ~16 MB of slack instead of ~6 MB, i.e.
//              it has been silently relaxed, which is the failure SF-6 named.
// Both invocation contexts fit inside; neither edge is reachable by host load
// at the measured spread.
// The "the work did not shrink" floor for F-I10 (task 1500).
//
// Task 1500 moves the preview build off the frame loop and promises that the
// COST IS IDENTICAL — the same stencil table, the same cage, the same level.
// That promise needs a floor, or the change would be indistinguishable from
// one that made the build cheaper by doing less of it.
//
// MEASURED, grid n=316, 2026-08-19: `subpatchWorkerBuildNs` = 186 825 500 ns
// (186.8 ms). ONE measurement, so the floor sits at roughly half of it — the
// job is to catch a build that VANISHED or collapsed, not to gate on host
// jitter, and this host runs several lanes at once.
//
// The number is worth reading twice, because it corrects an assumption task
// 1500 carried in: at this cage the whole preview build is ~0.19 s, NOT the
// ~1-2 s that 1374's "4.45-4.96 us per limit face" suggests. That figure
// describes the whole Tab FRAME, and most of that frame is the screen-space
// cache + face-pick rebuild which FOLLOWS the build — measured on the
// pre-change tree at 1754 ms of a 2002 ms worst frame.
//
// A FLOOR AND NOT A BAND, deliberately: a build that got SLOWER is an
// ordinary timing regression and the timing lane already reports it. A build
// that got much faster, in a task whose whole claim is that no work went
// away, is a claim that has to be looked at.
enum long K_TAB_COLD_MIN_BUILD_NS = 90_000_000;   // 0.09 s; measured 186.8 ms

enum long K_TAB_COLD_CHROME_BYTES = 211_168;
enum int  K_TAB_COLD_FRAMES_LO    = 40;
enum int  K_TAB_COLD_FRAMES_HI    = 110;

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

// ---------------------------------------------------------------------------
// tab-cold — the FIRST Tab on a heavy cage: the user-visible cost that the
// LRU(2) topology cache exists to avoid paying twice, and that `tab-subpatch`
// measures only by accident.
//
// WHY IT IS A SEPARATE SCENARIO AND NOT AN EXTRA ASSERTION ON tab-subpatch.
// `tab-subpatch` today runs after three scenarios that never touch
// buildPreview, so it happens to be the process's first preview build and its
// numbers happen to be cold ones. It cannot PROVE that -- before task 1374
// there was no counter that could tell a cold stencil build from a cache hit
// (`Cat.subpatchPreview`'s scope timer opens at the top of buildPreview,
// above the cache lookup), so its "one rebuild" invariant F-I5 is equally
// green either way. This scenario asserts the coldness instead of inheriting
// it.
//
// THE REGIME, stated because it IS the measurement. "Cold" here means COLD
// TOPOLOGY: the LRU(2) OSD topology cache and the layer-2 reusable-preview key
// (SubpatchPreview.reusablePreviewKey) are both empty when the toggle lands,
// so buildPreview pays the full OSD topology + stencil-table build. It does
// NOT mean a virgin process: `OsdAccel`'s ~dozen `scratch*` buffers keep their
// capacity across `clear()` and are not touched by `destroyCache()` either, so
// nothing reachable from inside a running vibe3d can restore the allocation
// state of a freshly launched one. A user's real first Tab after launch is
// therefore MORE expensive than this scenario reports; measuring that one
// needs a relaunch per repeat, which is a manual measurement, not a gate.
//
// That regime is PINNED here rather than inherited from whatever ran first:
// the warm-up toggle below fills every scratch buffer at this cage's size
// before the measured window opens. Without it, `frames tab-cold` run solo and
// the same scenario inside a full `frames` run would be two different
// measurements under one name -- and F-I9's byte bound would be calibrated for
// whichever the operator happened to run.
FrameScenarioResult runTabCold(int n, string meshType) {
    FrameScenarioResult res;
    res.name = "tab-cold";

    // --- Warm-up: fill the scratch buffers at this cage size. -----------
    resetMesh(meshType, n);
    if (!selectMode("polygons", [])) {
        res.status = CaseStatus.ERROR;
        res.detail = "selectMode polygons failed (warm-up)";
        return res;
    }
    settleAfterReset();
    // Reset the counters BEFORE the warm-up toggle, not just before the
    // measured one: the wait below keys on `subpatchPreview.count >= 1`, and
    // an earlier scenario in the same process (tab-subpatch) leaves that
    // counter at 1 already. Without this the warm-up wait returns instantly
    // and the "warm buffers" this scenario claims to pin are whatever the
    // previous scenario left -- exactly the contamination the warm-up exists
    // to remove.
    perfReset();
    if (!postCommand("mesh.subpatch_toggle")) {
        res.status = CaseStatus.ERROR;
        res.detail = "mesh.subpatch_toggle failed (warm-up)";
        return res;
    }
    // `.length`, not `if (why)`: a string is an array, and `if (arr)` tests the
    // POINTER — `""` is a non-null literal, so the truthiness form would fire
    // on success.
    immutable warmWhy = waitForSubpatchBuild(1);
    if (warmWhy.length) {
        res.status = CaseStatus.ERROR;
        res.detail = "warm-up preview build: " ~ warmWhy;
        return res;
    }
    // Let the warm-up's own upload/draw frame run before the reset, so the
    // limit-side buffers are hot too, not just the cage-side ones.
    Thread.sleep(600.msecs);

    // --- The reset that makes the NEXT toggle a genuine miss. -----------
    // scene.reset's hook (source/registration.d) runs
    // deactivate() -> SubpatchPreview.dropTopologyCache(), which drops
    // both cache layers and leaves the scratch buffers hot. Note that WITHOUT
    // destroyCache() this is not merely weaker, it is wrong: the topology key
    // hashes only the cage's (topology, level, sharpness) tuple, so resetting
    // to the same grid twice reproduces the SAME key and the toggle below
    // would be a cache HIT wearing this scenario's name. F-I8 is what refuses
    // to report that as a cold build.
    resetMesh(meshType, n);
    if (!selectMode("polygons", [])) {
        res.status = CaseStatus.ERROR;
        res.detail = "selectMode polygons failed";
        return res;
    }
    settleAfterReset();

    perfReset();
    // Task 1500: the worker's counters are process-cumulative and
    // `/api/perf/reset` (HTTP thread) deliberately does not reach into
    // SubpatchPreview -- writing main-thread state from the HTTP thread to
    // make a counter resettable would be a race introduced for a reporting
    // convenience. The window's share is a DIFFERENCE instead.
    immutable auto asyncBefore = fetchSubpatchAsync();
    framesReset();      // the window opens HERE -- one call before the toggle

    if (!postCommand("mesh.subpatch_toggle")) {
        res.status = CaseStatus.ERROR;
        res.detail = "mesh.subpatch_toggle failed";
        return res;
    }
    // Wait on the COUNTER, not on a fixed sleep. The build is one frame
    // however long it takes, so this keeps the window's FRAME COUNT (and
    // hence its ImGui-chrome allocation floor) stable across cage sizes --
    // which is the only thing that makes a byte bound on the window sum
    // comparable between points at all.
    immutable coldWhy = waitForSubpatchBuild(1);   // `.length`, see the warm-up
    if (coldWhy.length) {
        res.status = CaseStatus.ERROR;
        res.detail = "cold preview build: " ~ coldWhy;
        return res;
    }

    // A FIXED number of post-build frames, driven by a hover sweep.
    //
    // Not decoration: vibe3d's main loop is event-driven, so a bare sleep here
    // records ZERO further frames (measured: a 600 ms sleep after the build
    // left the window at frameCount == 1) and the window would stop at the
    // buildPreview frame, missing the GPU upload / first draw of the limit
    // surface entirely. Driving a fixed sweep decouples the window from HOW
    // LONG THE BUILD TOOK, which is what a sleep cannot do.
    //
    // It does NOT make the frame count a constant, and an earlier draft of this
    // comment claimed it did. MEASURED at this one cage size: 47, 51, 76, 84,
    // 86, 86, 87, 88 across two sessions and both invocations (and 69/51/59/11
    // over the A'/B/C/D cage-size matrix). Every byte of that spread is
    // per-frame ImGui chrome — the window sum is 79 137 568 B + 211 168 B x
    // frames to within one page across all of them, see
    // K_TAB_COLD_CHROME_BYTES. So the count is BOUNDED by F-I9 rather than
    // assumed, and both of F-I9's halves gate only at the calibration point.
    auto cam = fetchCamera();
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    string log = buildHoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                               cx - 20, cy, cx + 20, cy, kTabColdHoverSteps);
    try {
        playAndWait(log);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "post-build sweep: " ~ e.msg;
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
    res.subpatchRebuilds = perfCounterCount(perf, "subpatchPreview");
    res.subpatchTopoMiss = perfCounterCount(perf, "subpatchTopoMiss");
    res.subpatchTopoHit  = perfCounterCount(perf, "subpatchTopoHit");
    res.subpatchLevel    = perfCounterSum  (perf, "subpatchLevelChosen");
    // Task 1540 -- the `cache` phase, split.
    res.cacheInvalidateNs = perfTimerSumNs (perf, "cacheInvalidate");
    res.hoverPickNs       = perfTimerSumNs (perf, "hoverPick");
    res.hoverPickCount    = perfCounterCount(perf, "hoverPick");
    res.bvhRebuildNs      = perfTimerSumNs (perf, "bvhRebuild");
    res.bvhRebuildCount   = perfCounterCount(perf, "bvhRebuild");
    res.bvhRebuildTris    = perfCounterSum  (perf, "bvhRebuildTris");
    res.bvhRebuildTrisN   = perfCounterCount(perf, "bvhRebuildTris");
    res.bvhRebuildMaxNs   = perfTimerMaxNs  (perf, "bvhRebuild");
    res.bvhAbortFaces     = perfCounterSum  (perf, "bvhAbortFaces");
    res.bvhAbortVerts     = perfCounterSum  (perf, "bvhAbortVerts");
    res.bvhAbortN         = perfCounterCount(perf, "bvhAbortFaces");
    res.bvhEnterN         = perfCounterCount(perf, "bvhRebuildEnter");
    try res.cageFacesAtToggle = activeLayerInfo().faceCount;
    catch (Exception) { res.cageFacesAtToggle = -1; }
    res.worstCacheNs      = res.stats.worst.cacheNs;
    res.viewcacheRebuildNs = perfTimerSumNs(perf, "viewcacheRebuild");
    res.cacheNsWindowSum  = res.stats.sumCacheNs;

    immutable auto asyncAfter = fetchSubpatchAsync();
    if (!asyncAfter.empty && !asyncBefore.empty) {
        res.subpatchWorkerNs =
            asyncAfter.buildNsTotal    - asyncBefore.buildNsTotal;
        res.subpatchWorkerAllocBytes =
            asyncAfter.allocBytesTotal - asyncBefore.allocBytesTotal;
        res.subpatchPendingFrames =
            asyncAfter.pendingFrames   - asyncBefore.pendingFrames;
    }

    res.status = CaseStatus.OK;
    return res;
}

// `count` / `sum` off one /api/perf entry, 0 when the category is absent
// (a non-perf build answers "{}").
long perfCounterCount(JSONValue perf, string key) {
    return (key in perf) ? perf[key]["count"].integer : 0;
}
long perfCounterSum(JSONValue perf, string key) {
    return (key in perf) ? perf[key]["sum"].integer : 0;
}
// A TIMER's accumulated nanoseconds. NOT interchangeable with
// `perfCounterSum`: `PerfProbe.toJson` emits `sum_ns` for a timer and `sum`
// for a counter, so asking a timer for "sum" throws Key not found — which is
// exactly what a first draft of the 1540 split did, and it threw on the
// first run rather than reading a silent zero. Kept as its own function so
// the two halves of the enum stay two functions at the reader's end too.
long perfTimerSumNs(JSONValue perf, string key) {
    return (key in perf) ? perf[key]["sum_ns"].integer : 0;
}
long perfTimerMaxNs(JSONValue perf, string key) {
    return (key in perf) ? perf[key]["max_ns"].integer : 0;
}

// Poll /api/perf until `subpatchPreview.count` reaches `want`. /api/perf is
// answered on the HTTP thread, so polling it does not serialize against the
// frame loop the way a main-thread-bridged route would.
//
// Returns "" on success, otherwise the reason, for the caller's ERROR detail.
// A bool would collapse the two failures that matter into one: /api/perf
// answers a bare "{}" on a NON-PERF build, where `subpatchPreview` is absent
// and `perfCounterCount` reads 0 forever -- so the wrong binary would burn the
// full 90 s timeout and then report a build that "did not land", which is a
// misdiagnosis of something decidable on the FIRST probe. Checked once per
// poll rather than once up front so a mid-scenario relaunch cannot slip past.
string waitForSubpatchBuild(long want) {
    foreach (i; 0 .. kTabColdBuildTimeoutMs / 50) {
        try {
            auto perf = perfRead();
            if (perf.type != JSONType.object || perf.object.length == 0)
                return "/api/perf answered an empty object — vibe3d is not the "
                       ~ "PerfProbe binary (build with --build=perf)";
            if (perfCounterCount(perf, "subpatchPreview") >= want)
                return "";
        } catch (Exception) { /* transient — keep polling */ }
        Thread.sleep(50.msecs);
    }
    return "no preview build within "
           ~ (kTabColdBuildTimeoutMs / 1000).to!string ~ "s";
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
        if (r.subpatchTopoMiss >= 0)
            writefln("  %-16s subpatch topology: miss=%d hit=%d level=%d "
                     ~ "(cold-topology / WARM-BUFFER regime — see runTabCold)",
                     r.name, r.subpatchTopoMiss, r.subpatchTopoHit,
                     r.subpatchLevel);
        if (r.bvhRebuildNs >= 0) {
            immutable long other = r.cacheNsWindowSum
                                 - r.cacheInvalidateNs - r.hoverPickNs;
            writefln("  %-16s CACHE PHASE SPLIT (window sums): phase=%.1fms"
                     ~ " = viewcache %.3fms (of which invalidate %.3fms)"
                     ~ " + hoverPick %.3fms + residual %.3fms",
                     r.name, msFromNs(r.cacheNsWindowSum),
                     msFromNs(r.cacheInvalidateNs),
                     msFromNs(r.viewcacheRebuildNs), msFromNs(r.hoverPickNs),
                     msFromNs(other));
            writefln("  %-16s   hoverPick %.3fms (n=%d) = bvhRebuild %.3fms (n=%d,"
                     ~ " %d tris total) + raycast %.3fms",
                     r.name, msFromNs(r.hoverPickNs), r.hoverPickCount,
                     msFromNs(r.bvhRebuildNs), r.bvhRebuildCount,
                     r.bvhRebuildTris,
                     msFromNs(r.hoverPickNs - r.bvhRebuildNs));
            // The divisor is the TRIS counter's own count, not the timer's:
            // `rebuild()` early-returns on an empty/zero-tri mesh AFTER the
            // timer opens but BEFORE the tri count is recorded, so the two
            // are different populations and dividing one by the other invents
            // a mesh that does not exist. A first draft did exactly that and
            // printed 399 424 tris/rebuild -- a number matching neither the
            // cage nor the limit surface, which is how it was caught.
            if (r.bvhRebuildTrisN > 0)
                writefln("  %-16s   builds that reached dbvh_build: %d of %d;"
                         ~ " %d tris each avg, %.3f us/tri",
                         r.name, r.bvhRebuildTrisN, r.bvhRebuildCount,
                         r.bvhRebuildTris / r.bvhRebuildTrisN,
                         (cast(double)r.bvhRebuildNs / 1000.0) / r.bvhRebuildTris);
            // Does the biggest single rebuild FIT in the frame that is
            // supposed to contain it? The window sums cannot answer that --
            // they are the g_perf window, which is not the g_frames ring.
            writefln("  %-16s   1720 ledger: entries=%d timerOpens=%d"
                     ~ " builds=%d aborts=%d",
                     r.name, r.bvhEnterN, r.bvhRebuildCount,
                     r.bvhRebuildTrisN, r.bvhAbortN);
            if (r.bvhAbortN > 0)
                writefln("  %-16s   ABORTED rebuilds: %d, walked %d faces /"
                         ~ " %d verts total (built nothing)",
                         r.name, r.bvhAbortN, r.bvhAbortFaces, r.bvhAbortVerts);
            writefln("  %-16s   biggest single rebuild %.3fms vs worst frame's"
                     ~ " cache phase %.3fms / whole frame %.3fms",
                     r.name, msFromNs(r.bvhRebuildMaxNs),
                     msFromNs(r.worstCacheNs), msFromNs(r.stats.worst.totalNs));
        }
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
            if (r.subpatchTopoMiss >= 0) {
                a.put(format(`      "subpatchTopoMiss": %d,` ~ "\n", r.subpatchTopoMiss));
                a.put(format(`      "subpatchTopoHit": %d,` ~ "\n", r.subpatchTopoHit));
                a.put(format(`      "subpatchLevel": %d,` ~ "\n", r.subpatchLevel));
            }
            // Task 1500 — the work that moved off the frame loop, reported
            // whether or not F-I9/F-I10 gate on it, so a reader comparing two
            // runs can see the split rather than infer it.
            if (r.subpatchWorkerNs >= 0) {
                a.put(format(`      "subpatchWorkerBuildNs": %d,` ~ "\n", r.subpatchWorkerNs));
                a.put(format(`      "subpatchWorkerAllocBytes": %d,` ~ "\n", r.subpatchWorkerAllocBytes));
                a.put(format(`      "subpatchPendingFrames": %d,` ~ "\n", r.subpatchPendingFrames));
            }
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

void printTable(CaseResult[] results, int runN) {
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
    // Cases that ran at their OWN mesh size (`Case.meshN`). Named here rather
    // than left to the run header, which says one number for the whole table
    // (review fix, task 1359): a row measured on 4225 verts printed under a
    // header that says 100489 is not a small imprecision, it is a different
    // benchmark, and the reader has no other way to see it.
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        if (r.effectiveN == 0 || r.effectiveN == runN) continue;
        writefln("  note: %s ran at its own pinned size n=%d (%d verts / %d "
                 ~ "faces), NOT the run's n=%d — see Case.meshN",
                 r.name, r.effectiveN, r.effectiveVertexCount,
                 r.effectiveFaceCount, runN);
    }
}

// jsonNum/replicate now live in lib.stats.

void writeResultsJson(string path, string meshType, int n, long faceCount,
                      string viewport, int repeats, CaseResult[] results,
                      string[] filter, string[] coverageGap) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "perf",` ~ "\n"));
    // The run's name-substring filter, empty for a full run (task 1373).
    // `--lane-health` needs it: "every declared case is present" is only a
    // fair question of a run that was asked for every declared case.
    a.put(`  "filter": [`);
    foreach (i, f; filter) {
        if (i) a.put(", ");
        a.put(format(`"%s"`, f.replaceQuotes));
    }
    a.put("],\n");
    // Geometry-domain commands that are in neither the case table nor the
    // exclusion table — invariant L2's finding, carried here so the gate step
    // can read it without re-launching the app.
    a.put(`  "coverageGap": [`);
    foreach (i, g; coverageGap) {
        if (i) a.put(", ");
        a.put(format(`"%s"`, g.replaceQuotes));
    }
    a.put("],\n");
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
        if (r.historyKey.length && r.historyKey != r.name)
            a.put(format(`      "historyKey": "%s",` ~ "\n", r.historyKey));
        a.put(format(`      "note": "%s",` ~ "\n", r.note));
        a.put(format(`      "status": "%s",` ~ "\n", r.status.to!string));
        if (r.status == CaseStatus.OK) {
            // What proved this row did work. Emitted on OK rows only — the
            // non-OK branch already carries the same information inside
            // `detail` (task 1373).
            if (r.witnessDetail.length)
                a.put(format(`      "witness": "%s",` ~ "\n",
                             r.witnessDetail.replaceQuotes));
            // The size THIS case ran at (task 1359). Emitted for every OK
            // case, so a consumer never has to decide whether the run
            // header's `n` applies to this row — it applies only when the
            // two agree, and `Case.meshN` makes them disagree.
            a.put(format(`      "n": %d,` ~ "\n", r.effectiveN));
            if (r.effectiveVertexCount > 0)
                a.put(format(`      "vertexCount": %d,` ~ "\n" ~
                             `      "faceCount": %d,` ~ "\n",
                             r.effectiveVertexCount, r.effectiveFaceCount));
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
        // `historyKey`, not `name` — a pinned case must not share a baseline
        // row with the same case measured at the run's size (task 1373 F1.7;
        // without this the hole simply moves from the history to the absolute
        // lane, which is objection O5 of the plan review).
        rows ~= lib.baseline.BaselineCase(r.historyKey, r.kernelMedianUs, r.kernelP95Us,
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
//
// `requestedCases` and `coverageGap` are the two LANE-LEVEL clauses (task
// 1373). Every per-case clause below opens with `if (r.status !=
// CaseStatus.OK) continue;`, and `failures` counts only failed invariants —
// so an ERROR row contributes nothing to the exit code and a case that
// stopped working prints one line and lets the lane pass. That is the exact
// defect this task exists to close, and it cannot be closed from inside a
// per-case loop, only from outside it.
Invariant[] checkInvariants(CaseResult[] results, size_t requestedCases,
                            string[] coverageGap) {
    Invariant[] inv;

    // L1 — LANE-LEVEL: this lane produced the cases it was asked for.
    // Copied in shape from `checkToolInvariants`'s L1 (task 1370), including
    // its hard-won `ok > 0` conjunct: subtracting SKIP from the expected OK
    // count re-opens the hole in the arm nobody mutates, because a run that
    // SKIPs everything then has ok=0, expectOk=0, err=0 and every other
    // conjunct true — a green lane over zero measurements.
    //
    // SKIP is legitimate here for one reason only: a case that pins a grid
    // size (`Case.meshN`) under `--subdivcube`.
    {
        size_t ok = 0, err = 0, skip = 0;
        foreach (r; results) final switch (r.status) {
            case CaseStatus.OK:    ok++;   break;
            case CaseStatus.SKIP:  skip++; break;
            case CaseStatus.ERROR: err++;  break;
        }
        immutable size_t expectOk = requestedCases >= skip ? requestedCases - skip : 0;
        bool pass = err == 0 && ok == expectOk && ok > 0 && requestedCases > 0;
        inv ~= Invariant("L1", "ops lane produced every case it was asked for",
            pass,
            format("requested=%d, OK=%d (expected %d), SKIP=%d, ERROR=%d%s",
                   requestedCases, ok, expectOk, skip, err,
                   ok == 0 ? " — NOTHING was measured" : ""));
    }

    // L2 — COVERAGE: every geometry-domain command the app registers is
    // either measured by a case or explicitly excluded with a reason.
    //
    // The list comes from the running app's /api/registry, not from a table
    // in this file, so the two cannot drift. A command added later has to go
    // through one of the two doors; "the rest are listed in the task log" is
    // prose that nobody executes.
    {
        bool pass = coverageGap.length == 0;
        inv ~= Invariant("L2",
            "every geometry command is covered or explicitly excluded",
            pass,
            pass ? format("%d cases, %d exclusions, 0 unaccounted",
                          commandCases().length, excludedCommands().length)
                 : format("%d unaccounted: %s",
                          coverageGap.length, coverageGap.join(", ")));
    }

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

    // I7 — the snap VISIBILITY mask (task 1350; clauses rebuilt after review,
    // task 1355/1359). THREE clauses, guarding three different failures.
    //
    // (a) THE MASK IS NOT REACHED AT ALL on a whole-mesh drag. The mask is
    //     `Mesh.visibleVertices`: O(V+F) plus ~1.0 MB of fresh arrays on a
    //     100K mesh. It is consulted only for candidates the grid returned
    //     and `kindExcluded` kept, and a whole-mesh drag's moving set is
    //     every vertex, so EVERY candidate is dropped before the mask is
    //     reached: consultations must be exactly zero, and therefore builds
    //     too.
    //
    //     This clause replaces one that could not fail (review, task 1355).
    //     The old test was `(consult > 0 || build == 0) && build <= queries`
    //     — but `snapVisBuild` is incremented INSIDE the accessor that
    //     increments `snapVisConsult`, so `build > 0 ⇒ consult > 0` holds by
    //     construction and the first conjunct is a tautology. It went red
    //     under the eager-mask mutation only because that mutation moved the
    //     build OUTSIDE the accessor. The refactor that silently restores the
    //     46-66 ms regression is smaller than that: hoist `visMask()` to the
    //     top of `walkSource` for readability, and the old clause reads
    //     builds=21, consultations=21, queries=21 — green on both conjuncts.
    //     Against THIS clause the same hoist reads consultations=21 on a case
    //     that must show zero.
    //
    // (b) NON-VACUITY, on cases that declare `exercisesVisibility`.
    //     Consulting the mask and ELECTING something through it are
    //     independent: with the camera on the wrong side of the plane every
    //     face is back-facing, the mask comes out all-false, every candidate
    //     is rejected, and the case measures an empty walk while still
    //     passing I5 and clause (a).
    //
    //     What it counts is `snapHitGeom`, NOT `snapHit` (review fix, task
    //     1355). `SnapResult.snapped` is also true when the grid/workplane
    //     tier or a LINE/PLANE constraint supplied the position, and none of
    //     those consult the mask — so an all-false mask can leave `snapHit`
    //     non-zero while `snapQuery` gets CHEAPER, which `--vs-last` would
    //     then report as an improvement. `snapHitGeom` fires only when the
    //     discrete tier won with a type the mask stood in front of
    //     (`snap.isMaskGatedType`), which is the literal claim "a mask-gated
    //     candidate won".
    //
    //     What this clause does NOT claim, because it was MEASURED and is not
    //     true: that the mask CHANGED the outcome. On `snap=vertex+partial`
    //     the reject count is exactly 0 (2229 consultations, 0 rejections,
    //     2026-08-19) — the fixture is a single grid sheet seen from below, so
    //     nothing occludes anything and every candidate near the cursor is
    //     admitted. The case measures the mask's COST, which is what it exists
    //     for, and elects THROUGH it; it does not demonstrate discrimination.
    //     Asserting `rejections > 0` — the shape the review first proposed —
    //     would therefore be red on the only case that reaches the mask at
    //     all. The count is printed instead, so a reader can see which of the
    //     two the case is showing them; a case that wants to pin
    //     discrimination needs a SELF-OCCLUDING fixture (a closed solid), and
    //     that is a new case, not a stricter predicate on this one.
    //
    // (c) LAZINESS AS A BOUND, on every snap case: at most one build per
    //     SOURCE WALK. A mask rebuilt per consultation instead of per walk
    //     would keep every other invariant green (I5 measures only that
    //     snapCursor was called) while costing multiples of the regression
    //     this task fixed. The bound is `queries x (1 primary + N background
    //     sources)`, not `queries` — `snapCursor` runs `walkSource` once for
    //     the primary and once per visible BACKGROUND layer (snap.d), each
    //     with its own mask. It held at `queries` only because no perf case
    //     has a background layer; stated that way it would have false-failed
    //     the day one was added, which is the wrong direction for a gate to
    //     be wrong in. `backgroundSources` is MEASURED per case from
    //     /api/layers, not declared, so it cannot go stale.
    //
    // All three are stated as COUNTS, not times, for the same reason I5 is:
    // grid and workplane snap legitimately do no geometric work at all.
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        if (!r.name.canFind("snap=")) continue;

        if (r.selection == "whole") {
            bool untouched = r.snapVisConsultCount == 0
                          && r.snapVisBuildCount   == 0;
            inv ~= Invariant("I7a",
                format("%s whole-mesh drag never reaches the snap mask", r.name),
                untouched,
                format("consultations=%d, builds=%d, queries=%d",
                       r.snapVisConsultCount, r.snapVisBuildCount,
                       r.snapQueryCount));
        }

        if (r.exercisesVisibility) {
            bool liveOk = r.snapVisConsultCount > 0 && r.snapHitGeomCount > 0;
            inv ~= Invariant("I7b",
                format("%s exercises the visibility mask (non-vacuous)", r.name),
                liveOk,
                format("consultations=%d (per query %.1f, %d rejected), " ~
                       "mask-gated wins=%d of %d snaps in %d queries",
                       r.snapVisConsultCount,
                       r.snapQueryCount > 0
                           ? cast(double)r.snapVisConsultCount / r.snapQueryCount
                           : 0.0,
                       r.snapVisRejectCount,
                       r.snapHitGeomCount, r.snapHitCount, r.snapQueryCount));
        }

        {
            immutable long walks = (1 + r.backgroundSources) * r.snapQueryCount;
            bool lazyOk = r.snapVisBuildCount <= walks;
            inv ~= Invariant("I7c",
                format("%s snap mask built at most once per source walk", r.name),
                lazyOk,
                format("builds=%d, walks=%d (%d queries x 1 primary + %d " ~
                       "background), consultations=%d",
                       r.snapVisBuildCount, walks, r.snapQueryCount,
                       r.backgroundSources, r.snapVisConsultCount));
        }

        // (d) THE BROAD PHASE IS DOING ITS JOB — as a RATIO, not a time.
        //
        //     I7a/b/c are counting invariants about laziness; none of them
        //     says what the mask COSTS, and cost is the whole reason task 1351
        //     exists. The obvious gate — put a time budget on the mask timer —
        //     WAS WRITTEN FIRST AND MEASURED INERT, which is worth recording
        //     rather than quietly replacing:
        //
        //       `Cat.snapVisMask` brackets the probe CONSTRUCTION (passes 0
        //       and 1). Pass 2 is lazy by design: it runs inside
        //       `VisibilityProbe.visible`, called from the snap gates, i.e.
        //       OUTSIDE that scope. Measured on `move/snap=vertex+partial` at
        //       n=316 with the occluder buckets disabled (their ceiling set to
        //       0, so every probe walks the whole front list):
        //
        //         pairs tested   12 901 121  ->  10 405 205 461   (806x)
        //         snapQuery/drag    404 664 us ->     7 630 029 us  (19x)
        //         snapVisMask median 17 707 us ->        13 006 us  (UNCHANGED)
        //
        //       A time budget on that timer is green through a 19x regression
        //       in the thing it is named after.
        //
        //     So the clause that gates the broad phase is the RATIO
        //     pairs / vertexProbes: "how many occluders did an average
        //     candidate have to look at". It is scale-free (no mesh size, no
        //     host speed, no repeat count in it), and the same measurement
        //     moves it from 124 to 99 854 — which IS |front|, i.e. the whole
        //     list, which is what having no broad phase means.
        if (r.exercisesVisibility && r.snapVisVertexProbeCount > 0) {
            enum double MAX_PAIRS_PER_PROBE = 2000.0;
            immutable double ratio = cast(double)r.snapVisPairsTestedCount
                                   / r.snapVisVertexProbeCount;
            inv ~= Invariant("I7d",
                format("%s snap mask broad phase narrows the occluder walk", r.name),
                ratio <= MAX_PAIRS_PER_PROBE,
                format("%.1f occluders per candidate (limit %.0f) — %d pairs / " ~
                       "%d probes, gridBail=%d, pixelOutside=%d, n=%d",
                       ratio, MAX_PAIRS_PER_PROBE, r.snapVisPairsTestedCount,
                       r.snapVisVertexProbeCount, r.snapVisGridBailCount,
                       r.snapVisPixelOutsideCount, r.effectiveN));
        }

        // (e) THE MASK BUILD'S OWN FLOOR, absolute, and named for what it
        //     actually bounds: passes 0 and 1 — projecting every vertex and
        //     facing-testing every face — which no broad phase touches.
        //
        //     THE CARD'S CRITERION IS NOT MET AND CANNOT BE BY THIS TASK, and
        //     the number here says so rather than hiding it. The card asked
        //     for "single-digit milliseconds per mask at n=316". With every
        //     per-face allocation removed, this floor alone measures 12-13 ms
        //     (standalone probe, ldc -O3 -release) and 11-18 ms in the running
        //     editor. Going below it needs a mask CACHE across mouse events,
        //     which is out of scope for a reason the plan states: the key has
        //     to separate a position change from a topology one, because a
        //     dragged face is an OCCLUDER of geometry that did not move.
        //
        //     Grid-only: under `--subdivcube` the fixture is a different mesh
        //     with a different vertex count, so the same absolute number would
        //     be describing something else.
        if (r.exercisesVisibility && r.meshKind == "grid" && r.snapVisMaskCount > 0) {
            enum double MASK_BUILD_BUDGET_US = 40_000.0;
            inv ~= Invariant("I7e",
                format("%s snap mask BUILD (passes 0+1) stays inside its budget",
                       r.name),
                r.snapVisMaskMedianUs <= MASK_BUILD_BUDGET_US,
                format("build median=%.0f us over %d builds (budget %.0f us); " ~
                       "this bounds the O(V)+O(F) floor ONLY — the occluder " ~
                       "walk is lazy and lands outside this timer, see I7d",
                       r.snapVisMaskMedianUs, r.snapVisMaskCount,
                       MASK_BUILD_BUDGET_US));
        }
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
// 0200; drag-falloff F-I4 re-promoted to gating in task 0202). Reuses the
// SAME `Invariant` struct as `checkInvariants` above — no separate type.
// ALWAYS run (no header/host gate): every F-Ix here is a machine-stable,
// build-independent control-flow count. F-I1/F-I5/F-I6/F-I7 GATE the exit
// code; F-I2 is always RECORDED, NON-GATING (see the plan's Risks section —
// a nonzero whole-frame alloc floor is expected from ImGui chrome rebuilding
// every frame). F-I4 GATES EVERY scenario in DEV runs (drag-falloff included
// since task 0202 removed its per-frame allocation), but when `ciMode` is
// true F-I4 is RECORDED/NON-GATING for every scenario: it can false-positive
// on the CI host (0195/0197 evidence), so `--ci` routes around it.
// ---------------------------------------------------------------------------

// `atCalibrationPoint` — whether this run is the (mesh, n) the two tab-cold
// bounds that scale with the cage were calibrated on. Both F-I8's chosen-level
// assertion and F-I9's byte + frame-count bounds are functions of the cage, so
// off that point they are RECORDED, non-gating; every other invariant here is
// cage-independent and gates everywhere.
Invariant[] checkFramesInvariants(FrameScenarioResult[] results, bool ciMode,
                                  bool atCalibrationPoint = true) {
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
    // real invariant there in dev. drag-falloff ALSO gates in dev now: task
    // 0202 replaced the whole-mesh fold's per-motion-event `new Vec3[]`
    // scratch (~1.2 MB/frame, which used to cross a GC pool threshold) with a
    // tool-owned reusable buffer (`XfrmTransformTool.foldSrc_`), so it holds
    // 0 GC at the ImGui-chrome alloc floor — the 0195 carve-out is gone. When
    // `ciMode` is true F-I4 is RECORDED/NON-GATING for EVERY scenario: the GC
    // metric can still false-positive under CI-host load (0195/0197 evidence),
    // so `--ci` routes around it rather than risk a flaky gate. `pass` is
    // unconditionally true whenever non-gating, but the count is still
    // reported. Counts, not times, so this is hardware-independent;
    // a nonzero count means a stop-the-world collection stalled the main
    // loop (triggered by ANY thread — see the GC-metric-asymmetry note in
    // perf_probe.d).
    //
    // `tab-cold` (task 1374) is carved out in DEV runs too, and unlike the old
    // drag-falloff carve-out this one is not a stopgap: a cold preview build
    // allocates a ~200 MB one-shot working set inside a single frame, so it
    // CROSSES a GC pool threshold by construction. Zero collections there
    // would mean the build did not happen. Recorded, never gated -- if that
    // count is ever to become a gate it needs its own bound, not this one.
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        bool gating = !ciMode && r.name != "tab-cold";
        bool ok = gating ? r.stats.gcCollections == 0 : true;
        string why = ciMode ? " — --ci"
                            : (r.name == "tab-cold"
                               ? " — cold build's one-shot working set" : "");
        string label = gating
            ? format("%s: 0 GC collections", r.name)
            : format("%s: GC collections (RECORDED, non-gating%s)", r.name, why);
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

    // F-I8 — GATING. tab-cold: the measured build was a genuine COLD one.
    //
    // Three counts, and all three are needed, because each covers a way the
    // measurement can be a lie:
    //   count == 1  — buildPreview ran exactly once in the window (a rebuild
    //                 storm would inflate the byte bound's subject too).
    //   miss  == 1  — that run BUILT a fresh OSD topology. This is the one
    //                 assertion that could not exist before task 1374: the
    //                 `subpatchPreview` timer opens above the cache lookup, so
    //                 count == 1 is equally true of a 77 ms cache hit.
    //   hit   == 0  — and it did not additionally reuse one.
    //
    // The layer-2 cache is covered by count, not by hit: a
    // reusablePreviewKey/Ready reuse short-circuits in mesh.d BEFORE
    // buildPreview is entered at all, so it shows as count == 0 / miss == 0 --
    // which this fails on. `hit == 0` alone would pass it.
    //
    // FOURTH, at the calibration point only: the chosen refinement LEVEL.
    // Without it `Cat.subpatchLevelChosen` has no live witness anywhere --
    // the level is printed in the detail and the JSON, and `perfCounterSum`
    // answers 0 for an absent key, so deleting the counter's call site in
    // subpatch_osd.d reddens nothing. It also makes this lane the first live
    // reading of the depth policy on a production-sized cage. Off the
    // calibration point the level is a function of the cage, so it is reported
    // and not gated (see K_TAB_COLD_CALIB_LEVEL for why a QUAD cage is
    // nonetheless the right place to pin the counter, not the projection).
    {
        auto r = findFrameScenario(results, "tab-cold");
        if (r !is null && r.status == CaseStatus.OK) {
            immutable bool levelOk = !atCalibrationPoint
                                  || r.subpatchLevel == K_TAB_COLD_CALIB_LEVEL;
            bool ok = r.subpatchRebuilds == 1
                   && r.subpatchTopoMiss == 1
                   && r.subpatchTopoHit  == 0
                   && levelOk;
            string label = atCalibrationPoint
                ? format("tab-cold: COLD build (1 rebuild, 1 miss, 0 hits, L%d)",
                         K_TAB_COLD_CALIB_LEVEL)
                : "tab-cold: measured a COLD build (1 rebuild, 1 topo miss, 0 hits)";
            inv ~= Invariant("F-I8", label,
                ok, format("subpatchPreview.count=%d topoMiss=%d topoHit=%d "
                           ~ "chosenLevel=%d%s%s",
                           r.subpatchRebuilds, r.subpatchTopoMiss,
                           r.subpatchTopoHit, r.subpatchLevel,
                           atCalibrationPoint ? "" : " (level RECORDED — off "
                                                     ~ "the calibration point)",
                           ok ? ""
                              : (levelOk
                                 ? "  <-- measured a cache HIT (or no build at "
                                   ~ "all), NOT a cold build"
                                 : format("  <-- the depth policy chose L%d, "
                                          ~ "not L%d", r.subpatchLevel,
                                          K_TAB_COLD_CALIB_LEVEL))));
        }
    }

    // F-I9 — GATING. tab-cold: total main-thread GC allocation over the
    // measured window.
    //
    // The WINDOW SUM, not the worst frame. Two frames here are expensive (the
    // stencil build, then the GPU upload / first draw of the limit surface)
    // and which of them is slowest can flip after a fix to either -- a bound
    // pinned to "the worst frame" would then be describing a different frame
    // than the one it was calibrated on, with no regression having occurred.
    // The worst frame's bytes are reported in the detail, non-gating.
    //
    // Bytes, not milliseconds: machine-stable, like every other F-Ix here.
    //
    // AND the window's FRAME COUNT, in a band, because the byte bound alone is
    // one-sided and can only get easier. The window's ImGui-chrome allocation
    // is roughly linear in its frame count, so a change that collapsed the
    // post-build sweep from ~50 frames to a handful would drop the sum by
    // ~44 frames' worth of chrome and permanently relax this gate with nothing
    // red anywhere. `runTabCold` ARGUES the count is a constant of the
    // scenario (a fixed hover log, not a sleep); this is that argument
    // asserted. Both halves share the calibration-point condition: the byte
    // bound scales with the cage and, measured, so does the frame count
    // (69/51/59/11 across the A'/B/C/D matrix).
    {
        auto r = findFrameScenario(results, "tab-cold");
        if (r !is null && r.status == CaseStatus.OK) {
            // ---- Task 1500: BOTH HALVES ARE RE-AIMED, NOT RE-CALIBRATED ---
            //
            // BYTES. `stats.gcAllocBytes` is `GC.allocatedInCurrentThread`
            // and is MAIN-THREAD-ONLY (perf_probe.d). Moving the build to a
            // worker takes its allocation out from under this bound — so
            // "re-calibrate the threshold to the new number" would lower the
            // gate to a post-move value and blind it to the build's
            // allocation FOREVER, which is exactly the instrument-stopped-
            // seeing-the-work failure this lane keeps catching. The gate goes
            // on the SUM main+worker instead, and the CONSTANT DOES NOT MOVE.
            //
            // FRAMES. The window opens before the toggle and closes after the
            // hover sweep, so under asynchrony it now CONTAINS the frames
            // drawn while the build ran — which is the whole point of the
            // task, and which makes the raw count proportional to build
            // duration. The band's meaning (chrome frames, decoupled from
            // build time) is restored by SUBTRACTING `pendingFrames`, so the
            // 40/110 edges keep the meaning they were derived with. The
            // subtrahend is reported separately, so it can hide nothing.
            immutable long workerBytes = r.subpatchWorkerAllocBytes > 0
                                       ? r.subpatchWorkerAllocBytes : 0;
            immutable long pendFrames  = r.subpatchPendingFrames > 0
                                       ? r.subpatchPendingFrames : 0;
            immutable long totalBytes  = r.stats.gcAllocBytes + workerBytes;
            immutable long chromeFrames = r.stats.frameCount - pendFrames;
            immutable bool byteOk  = totalBytes <= K_TAB_COLD_ALLOC_BYTES;
            immutable bool frameOk = chromeFrames >= K_TAB_COLD_FRAMES_LO
                                  && chromeFrames <= K_TAB_COLD_FRAMES_HI;
            bool ok = atCalibrationPoint ? (byteOk && frameOk) : true;
            string label = atCalibrationPoint
                ? format("tab-cold: window GC alloc (main+worker) <= %d B, "
                         ~ "%d..%d non-pending frames",
                         K_TAB_COLD_ALLOC_BYTES,
                         K_TAB_COLD_FRAMES_LO, K_TAB_COLD_FRAMES_HI)
                : format("tab-cold: window GC alloc + frames (RECORDED, "
                         ~ "non-gating — off the %s n=%d calibration point)",
                         K_TAB_COLD_CALIB_MESH, K_TAB_COLD_CALIB_N);
            // The chrome-free residual, RECORDED and never gated. It is the
            // part of the window sum that is NOT the per-frame ImGui floor,
            // and it is deterministic to the byte across every measurement so
            // far (79 137 568 B; see K_TAB_COLD_CHROME_BYTES). Printed because
            // it is what makes the gated number interpretable — a reader
            // comparing two runs with different frame counts should compare
            // THIS. Deliberately not the gate: swapping F-I9's subject is a
            // change of what the lane promises, and belongs to whoever owns
            // that promise, not to a review fix.
            immutable long residual = totalBytes
                                    - chromeFrames * K_TAB_COLD_CHROME_BYTES;
            inv ~= Invariant("F-I9", label,
                ok, format("gcAllocBytes=%d B main + %d B worker = %d B over "
                           ~ "%d frames (%d pending, %d chrome; chrome-free "
                           ~ "%d B, worst frame %d B — both RECORDED "
                           ~ "non-gating)%s%s",
                           r.stats.gcAllocBytes, workerBytes, totalBytes,
                           r.stats.frameCount, pendFrames, chromeFrames,
                           residual, r.stats.worst.gcAllocBytes,
                           (ok || byteOk) ? "" : "  <-- OVER the byte bound",
                           (ok || frameOk) ? ""
                              : format("  <-- non-pending frame count outside "
                                       ~ "%d..%d: the measured WINDOW is not "
                                       ~ "the one this byte bound was "
                                       ~ "calibrated on",
                                       K_TAB_COLD_FRAMES_LO,
                                       K_TAB_COLD_FRAMES_HI)));
        }
    }

    // F-I10 — GATING at the calibration point. tab-cold: the build still
    // HAPPENS, and it happens OFF the frame loop (task 1500).
    //
    // THIS IS THE INVARIANT THAT REFUSES TO CELEBRATE THE CHANGE. Moving the
    // stencil build to a worker collapses `tab-cold`'s worst frame by design;
    // with nothing else asserted, a later edit that quietly made the build
    // synchronous again — or removed it — would look like a further
    // improvement in every number this lane prints. Two counters, and neither
    // is written at the same site as the other:
    //   workerNs > 0    — the work was DONE, and done on the worker thread.
    //   pendingFrames >= 1 — the main loop drew at least one frame while it
    //                     ran, i.e. the window was not frozen.
    // A silent return to synchronous zeroes BOTH.
    //
    // `K_TAB_COLD_MIN_BUILD_NS` is the "the work did not shrink" floor. It is
    // a FLOOR, not a band: this task promises identical cost, so a large drop
    // is a claim that has to be examined, while a rise is the ordinary
    // regression the timing lane already reports.
    {
        auto r = findFrameScenario(results, "tab-cold");
        if (r !is null && r.status == CaseStatus.OK && r.subpatchWorkerNs >= 0) {
            immutable bool ranOffThread = r.subpatchPendingFrames >= 1;
            immutable bool didWork      = r.subpatchWorkerNs > 0;
            immutable bool notShrunk    = !atCalibrationPoint
                                       || r.subpatchWorkerNs >= K_TAB_COLD_MIN_BUILD_NS;
            bool ok = didWork && ranOffThread && notShrunk;
            inv ~= Invariant("F-I10",
                atCalibrationPoint
                  ? format("tab-cold: build ran off-thread and cost >= %d ns",
                           K_TAB_COLD_MIN_BUILD_NS)
                  : "tab-cold: build ran off-thread (cost floor RECORDED — off "
                    ~ "the calibration point)",
                ok, format("workerBuildNs=%d pendingFrames=%d%s%s%s",
                           r.subpatchWorkerNs, r.subpatchPendingFrames,
                           didWork ? "" : "  <-- ZERO: the build did not run "
                                          ~ "on the worker (synchronous again?)",
                           ranOffThread ? "" : "  <-- no frame was drawn while "
                                               ~ "the build ran",
                           notShrunk ? "" : format("  <-- build cost fell below "
                                       ~ "%d ns; this task promises IDENTICAL "
                                       ~ "work, so a drop is a finding",
                                       K_TAB_COLD_MIN_BUILD_NS)));
        }
    }

    // F-I11 — GATING. tab-cold: NO BVH is constructed over the LIMIT surface.
    //
    // This is the half of task 1540's option C that the HTTP suite cannot
    // reach. `tests/test_subpatch_interactive_pick_engine.d` pins that the
    // interactive pick still answers correct CAGE indices under a live
    // preview — but both engines do, so that file stays green whichever one
    // answered and says so in its own header. Which engine ran is visible
    // ONLY through `Cat.bvhRebuild*`, and those report `{}` outside the perf
    // buildType. So the choice is gated here.
    //
    // The subject is TRIANGLES, not the rebuild count, and that is deliberate.
    // A cage-sized construction in this window is legitimate (the cage tree is
    // what answers a pick before the preview lands) and can even straddle
    // `/api/perf/reset` — measured: a ~385 ms cage build that started before
    // the reset lands its timer sample after it, so a count-based gate would
    // be flaky by construction. Triangle count separates the two subjects
    // cleanly instead: at level 1 the limit surface is 4x the cage in faces
    // and 4x in fan triangles, so anything at or below the cage's own
    // triangle count cannot be a limit build.
    {
        auto r = findFrameScenario(results, "tab-cold");
        if (r !is null && r.status == CaseStatus.OK && r.bvhRebuildTris >= 0) {
            // Four fan triangles per CAGE face. The cage's real count is two
            // per quad; the slack absorbs an n-gon cage without ever reaching
            // the limit surface, which at level 1 is four QUADS per cage face
            // and therefore eight fan triangles per cage face. So the gate
            // separates 2F from 8F with 4F, and no fixture shape moves it.
            immutable long cageTris = r.cageFacesAtToggle > 0
                                    ? r.cageFacesAtToggle * 4 : long.max;
            immutable bool ok = r.bvhRebuildTris <= cageTris;
            inv ~= Invariant("F-I11",
                format("tab-cold: no BVH built over the limit surface "
                       ~ "(<= %d tris, the cage's own fan count)", cageTris),
                ok, format("bvhRebuildTris=%d over %d build(s)%s",
                           r.bvhRebuildTris, r.bvhRebuildTrisN,
                           ok ? "" : "  <-- a LIMIT-sized construction ran on "
                                     ~ "the main thread: option C's engine "
                                     ~ "gate in app.d's pickFaces is not "
                                     ~ "holding"));
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
        // Looked up (and reported) by `historyKey`: baseline.json is written
        // under that key, so a pinned case finds its own row and not the
        // bare-named one (task 1373 F1.7).
        auto p = r.historyKey in base.byName;
        if (p is null) continue;   // new case absent from baseline — not a regression
        if (p.kernelMedianUs < ABS_NOISE_FLOOR_US) continue;  // noise floor
        double g = r.kernelMedianUs / p.kernelMedianUs - 1.0;
        if (g > tolerance)
            regs ~= AbsRegression(r.historyKey, "kernelApply",
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
    killStaleVibe(port);
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
        // tab-cold goes LAST, and the position is load-bearing (task 1374).
        // `tab-subpatch` above is today the process's FIRST buildPreview --
        // the three scenarios before it never call one -- so it already
        // measures a virgin cold build, it just cannot prove it. Insert
        // tab-cold ANYWHERE above it and tab-subpatch silently becomes a
        // warm-buffer build against a populated topology cache: its p99 and
        // its allocation numbers move, its committed baseline entry stops
        // describing the thing it names, and F-I5 (`count == 1`) stays green
        // through all of it. No gate in this file can see that; only this
        // ordering prevents it.
        ScenarioSpec("tab-cold",     &runTabCold),
    ];
    // ... and the ordering is asserted, not just commented. The pollution an
    // accidental reorder causes is invisible to every counter in this file: with
    // `destroyCache()` on the reset hooks a reordered `tab-subpatch` still
    // reports subpatchPreview.count=1 / topoMiss=1, because what it loses is not
    // the topology cache but the SCRATCH BUFFERS -- OsdAccel's ~dozen capacity
    // fields, which nothing observes. F-I5 stays green while the window drops
    // 61 % (measured, mutation M8). This assert is the only thing standing
    // between a one-line edit and a baseline entry that silently stops
    // describing what it names.
    assert(allScenarios[$-1].name == "tab-cold",
        "tab-cold MUST stay last — see the comment above; a reorder is not "
        ~ "observable in any invariant this file emits");

    ScenarioSpec[] scenarios;
    foreach (sc; allScenarios) {
        bool keepIt = requested.length == 0;
        foreach (req; requested) if (sc.name.canFind(req)) keepIt = true;
        if (keepIt) scenarios ~= sc;
    }
    // Same rule as the ops and tools lanes: a filter that matched nothing is
    // a failure, not a quiet zero. This lane is also invoked by name from the
    // nightly workflow (review fix, task 1370).
    if (scenarios.length == 0) {
        stderr.writefln("no frame scenarios matched %s — nothing was measured",
                        requested);
        return 1;
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
        writeln("  (--ci: GATING = F-I1/F-I5/F-I6/F-I7/F-I8/F-I9 only; "
                ~ "F-I2/F-I4 RECORDED)");
    auto invs = checkFramesInvariants(results, ciMode,
        meshType == K_TAB_COLD_CALIB_MESH && meshParam == K_TAB_COLD_CALIB_N);
    // A scenario that ERRORed contributes NO invariants at all — F-I8/F-I9 are
    // emitted only under `status == OK` — so without this a `tab-cold` that
    // timed out, or whose toggle/playback failed, prints ERROR, contributes
    // nothing to `failures`, and the run exits 0 with the CI step green. F-I8
    // exists precisely to refuse an unproven measurement; its silent
    // DISAPPEARANCE is the same lie it was written to catch. Counted here,
    // before the invariant loop, so the verdict below reports it.
    int errored = 0;
    foreach (r; results) {
        if (r.status != CaseStatus.ERROR) continue;
        writefln("  [FAIL] %-4s %-52s  %s", "ERR", r.name ~ ": scenario ERRORed",
                 r.detail);
        errored++;
        failures++;
    }
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
    if (errored > 0)
        writefln("  scenarios that ERRORed (no invariants emitted): %d", errored);
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
        lib.history.appendHistory(g_repoRoot, curHeader, p99ByScenario, "frames");
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
// `tools` subcommand — invariants, table, entry point (task 1370).
//
// The lane exists to produce ONE number: the kernel share of a preview
// rebuild. Everything below is in service of that number being either
// TRUSTWORTHY or LOUDLY ABSENT — never quietly wrong.
// ---------------------------------------------------------------------------

Invariant[] checkToolInvariants(CaseResult[] results, size_t requestedCases) {
    Invariant[] inv;

    // L1 — LANE-LEVEL: this lane produced the cases it was asked for.
    //
    // Why a lane-level clause exists at all, when every per-case clause below
    // already skips non-OK rows: an ERROR row contributes NOTHING to the exit
    // code in the `ops` path (`if (r.status != CaseStatus.OK) continue;` in
    // every invariant loop, and `failures` counts only invariant failures), so
    // a case whose selection or `tool.set` failed prints ERROR and the run
    // still exits 0. `checkToolInvariants` inherits that loop shape, so it
    // would inherit the hole too. L1 closes it from outside: N requested
    // cases must produce N OK rows and zero ERROR rows.
    //
    // This is task 1332's defect in a new dress — a lane that measures
    // nothing must not be green — and the mutation that proves L1 is live is
    // renaming a toolId to garbage: `tool.set` then fails, the row goes
    // ERROR, and the lane must go RED rather than merely print it.
    {
        size_t ok = 0, err = 0, skip = 0;
        foreach (r; results) final switch (r.status) {
            case CaseStatus.OK:    ok++;   break;
            case CaseStatus.SKIP:  skip++; break;
            case CaseStatus.ERROR: err++;  break;
        }
        // SKIP is legitimate (a grid-pinned case under --subdivcube) and is
        // therefore not an error — but it is subtracted from the expected OK
        // count rather than ignored, so a run that skips everything still has
        // to say so out loud instead of passing on an empty table.
        //
        // `ok > 0` is the conjunct that MAKES it say so, and it is separate
        // from `requestedCases > 0` on purpose: subtracting `skip` re-opened,
        // in the arm nobody had mutated, the exact hole the clause was
        // written to close. `rdmd run.d tools --subdivcube 4` SKIPs the one
        // row (its pinned n=96 is grid-only) and leaves ok=0, skip=1, err=0,
        // expectOk=0, requested=1 — every OTHER conjunct true. The per-case
        // loop below skips non-OK rows, so I8a/I8b/I8c emit nothing, and the
        // lane printed `SKIP=1` and exited 0 on zero measured rebuilds.
        // Witnessed by mutation M7 (task 1370).
        immutable size_t expectOk = requestedCases - skip;
        bool pass = err == 0 && ok == expectOk && ok > 0 && requestedCases > 0;
        inv ~= Invariant("L1", "tools lane produced every case it was asked for",
            pass,
            format("requested=%d, OK=%d (expected %d), SKIP=%d, ERROR=%d%s",
                   requestedCases, ok, expectOk, skip, err,
                   ok == 0 ? " — NOTHING was measured" : ""));
    }

    foreach (r; results) {
        if (r.status != CaseStatus.OK || !r.isToolPreview) continue;

        // I8a — the timer fired EXACTLY once per driven rebuild. Not `> 0`:
        // `> 0` passes when the tool rebuilt its preview once on activation
        // and then sat silent through every measured repeat, which is the
        // shape of a driver that stopped working. Exact equality is also what
        // catches a misplaced perfReset (one early ⇒ repeats+1; one late ⇒
        // repeats-1).
        inv ~= Invariant("I8a",
            format("%s toolPreview fired once per repeat", r.name),
            r.toolPreviewCount == g_toolRepeats,
            format("count=%d, expected %d (median %.1f µs)",
                   r.toolPreviewCount, g_toolRepeats, r.kernelMedianUs));

        // I8b — the mesh actually MOVED. The attribute changing is not
        // evidence: `edge.extrude`'s `extrude` attr climbs to 0.9 while its
        // kernel no-ops below `width < 1e-6` (task 1370 Phase 0.2), so a case
        // asserting "the attribute changed" would be green and measuring a
        // refusal. Counts + one vertex position, NOT mutationVersion — see
        // runToolCase step 4 for the mutation that killed the version term.
        //
        // BOTH driven values, each against the pristine mesh: the window
        // alternates them, so a `v1` that lands on a tool's refusal branch
        // would otherwise be 3 of 5 unwitnessed samples inside the published
        // median (runToolCase step 3b).
        inv ~= Invariant("I8b",
            format("%s preview really moved the mesh (both driven values)", r.name),
            r.geometryChanged,
            format("V/F@v0 pristine %s → v0 %s → v1 %s",
                   r.geomBefore, r.geomAfterV0, r.geomAfterV1));

        // I8c — THE DECOMPOSITION IS CLEAN, and this is the clause the whole
        // lane's headline number rests on.
        //
        // `previewRestore` and `previewRefresh` are opened in the two SHARED
        // callees, not at the tool site. That is only a valid decomposition
        // while nothing ELSE restores a snapshot or refreshes the display
        // inside the perfReset-bounded window — an assumption, not a fact, so
        // it is CHECKED rather than asserted in a comment: one restore and
        // one refresh per rebuild, exactly.
        //
        // If it fails, the kernel share printed beside it is subtracting more
        // wrapper than the rebuilds actually paid, i.e. UNDER-reporting the
        // kernel — the direction that would wrongly retire the remaining
        // per-tool cases. Hence gating, not informational.
        bool clean = r.previewRestoreCount == r.toolPreviewCount
                  && r.previewRefreshCount == r.toolPreviewCount;
        inv ~= Invariant("I8c",
            format("%s wrapper decomposition is clean", r.name),
            clean,
            format("toolPreview=%d, previewRestore=%d, previewRefresh=%d",
                   r.toolPreviewCount, r.previewRestoreCount,
                   r.previewRefreshCount));
    }

    return inv;
}

// `repeats` for the tools lane, read by I8a. A module-level global rather
// than a parameter threaded through `Invariant[]` construction, matching how
// the ops lane's thresholds are reached.
int g_toolRepeats = 5;

void printToolsTable(CaseResult[] results, int runN) {
    writeln();
    writeln("=== tool preview results (cost of ONE rebuildPreview) ===");
    // `rebuild` is `toolPreview`'s own median — the WHOLE call. `total` is
    // that same whole call summed over the R repeats; it was labelled
    // `wrapper`, which named the thing it is NOT (wrapper = restore +
    // refresh, the two columns after it). Review fix, task 1370.
    writefln("%-22s %10s %10s %11s %11s %11s %8s %6s",
             "case", "rebuild", "p95", "total", "restore", "refresh",
             "kernel", "share");
    writefln("%-22s %10s %10s %11s %11s %11s %8s %6s",
             "", "med (us)", "(us)", "sum (us)", "sum (us)", "sum (us)",
             "sum (us)", "");
    writeln("-".replicate(100));
    foreach (r; results) {
        final switch (r.status) {
            case CaseStatus.OK:
                writefln("%-22s %10.1f %10.1f %11.1f %11.1f %11.1f %8.1f %5.1f%%",
                         r.name, r.kernelMedianUs, r.kernelP95Us,
                         r.toolPreviewSumUs, r.previewRestoreSumUs,
                         r.previewRefreshSumUs, r.previewKernelUs,
                         r.kernelShare * 100.0);
                break;
            case CaseStatus.SKIP:
                writefln("%-22s  SKIP  %s", r.name, r.detail);
                break;
            case CaseStatus.ERROR:
                writefln("%-22s  ERROR %s", r.name, r.detail);
                break;
        }
    }
    writeln("-".replicate(100));
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        writefln("  %s: n=%d (%d verts / %d faces), %d rebuilds, "
                 ~ "geometry pristine %s → v0 %s → v1 %s",
                 r.name, r.effectiveN, r.effectiveVertexCount,
                 r.effectiveFaceCount, r.toolPreviewCount,
                 r.geomBefore, r.geomAfterV0, r.geomAfterV1);
    }
    // Same debt runCase closed in task 1359: a row measured at its own pinned
    // size printed under a header that says another number is a different
    // benchmark, and the reader has no other way to see it.
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        if (r.effectiveN == 0 || r.effectiveN == runN) continue;
        writefln("  note: %s ran at its own pinned size n=%d, NOT the run's "
                 ~ "n=%d — see ToolCase.meshN / TOOLCASE_NMAX",
                 r.name, r.effectiveN, runN);
    }
    writeln();
    writeln("  'med' is ONE rebuildPreview, NOT one preview frame: a real drag");
    writeln("  additionally pays the frame loop's cache invalidation, GPU upload");
    writeln("  and draw, which this driver never triggers between calls.");
}

void writeToolsResultsJson(string path, string meshType, int n, string viewport,
                           int repeats, CaseResult[] results) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "perf",` ~ "\n"));
    a.put(format(`  "compiler": "ldc2 1.42.0",` ~ "\n"));
    a.put(format(`  "host": "%s",` ~ "\n", Socket.hostName));
    a.put(format(`  "meshType": "%s",` ~ "\n", meshType));
    a.put(format(`  "n": %d,` ~ "\n", n));
    a.put(format(`  "viewport": "%s",` ~ "\n", viewport));
    a.put(format(`  "repeats": %d,` ~ "\n", repeats));
    a.put(`  "cases": [` ~ "\n");
    foreach (i, r; results) {
        a.put("    {\n");
        a.put(format(`      "name": "%s",` ~ "\n", r.name));
        a.put(format(`      "status": "%s",` ~ "\n", r.status.to!string));
        if (r.status == CaseStatus.OK) {
            a.put(format(`      "n": %d,` ~ "\n", r.effectiveN));
            a.put(format(`      "vertexCount": %d,` ~ "\n", r.effectiveVertexCount));
            a.put(format(`      "faceCount": %d,` ~ "\n", r.effectiveFaceCount));
            a.put(format(`      "toolPreviewMedianUs": %s,` ~ "\n", jsonNum(r.kernelMedianUs)));
            a.put(format(`      "toolPreviewP95Us": %s,` ~ "\n", jsonNum(r.kernelP95Us)));
            a.put(format(`      "toolPreviewCount": %d,` ~ "\n", r.toolPreviewCount));
            a.put(format(`      "toolPreviewSumUs": %s,` ~ "\n", jsonNum(r.toolPreviewSumUs)));
            a.put(format(`      "previewRestoreSumUs": %s,` ~ "\n", jsonNum(r.previewRestoreSumUs)));
            a.put(format(`      "previewRefreshSumUs": %s,` ~ "\n", jsonNum(r.previewRefreshSumUs)));
            a.put(format(`      "previewKernelUs": %s,` ~ "\n", jsonNum(r.previewKernelUs)));
            a.put(format(`      "kernelShare": %s,` ~ "\n", jsonNum(r.kernelShare)));
            a.put(format(`      "geometryChanged": %s,` ~ "\n",
                         r.geometryChanged ? "true" : "false"));
            a.put(`      "breakdown": ` ~ r.lastBreakdown.toString() ~ "\n");
        } else {
            a.put(format(`      "detail": "%s"` ~ "\n", r.detail.replaceQuotes));
        }
        a.put(i + 1 < results.length ? "    },\n" : "    }\n");
    }
    a.put("  ]\n}\n");
    std.file.write(path, a.data);
}

int runToolsSubcommand(string meshType, int meshParam, string viewport,
                       ushort port, string[] requested, int repeats,
                       bool noBuild) {
    g_toolRepeats = repeats;

    ToolCase[] cases;
    foreach (tc; toolCases()) {
        bool keepIt = requested.length == 0;
        foreach (req; requested) if (tc.name.canFind(req)) keepIt = true;
        if (keepIt) cases ~= tc;
    }
    // "no cases matched" is a FAILURE here, not a quiet zero: this lane is
    // wired into a scheduled workflow by NAME, so a typo in the filter would
    // otherwise buy a green nightly step with zero coverage — precisely the
    // "lane that measures nothing" defect the L1 invariant exists for,
    // arriving one step earlier.
    //
    // It does NOT cover a typo in the SUBCOMMAND, and cannot: an
    // unrecognised leading token never reaches this lane at all — the
    // dispatch in main() accepts exactly `ops|frames|flame|tools` and leaves
    // anything else as `ops` plus a case-name substring, so `run.d tolls`
    // lands in the ops lane's own no-match guard. That guard is therefore
    // now a failure too (review fix, task 1370).
    if (cases.length == 0) {
        stderr.writefln("no tool cases matched %s — nothing was measured",
                        requested);
        return 1;
    }

    killStaleVibe(port);
    string logPath = "/tmp/vibe3d_perf_tools.log";
    writefln("Launching vibe3d --test --perf --http-port %d --viewport %s ...",
             port, viewport);
    if (!launchVibe(port, viewport, logPath)) return 1;
    writeln("  vibe3d is up");

    CaseResult[] results;
    foreach (tc; cases) {
        write("  running ", tc.name, " ... ");
        stdout.flush();
        auto r = runToolCase(tc, meshParam, meshType, repeats);
        final switch (r.status) {
            case CaseStatus.OK:    writeln("OK");                     break;
            case CaseStatus.SKIP:  writeln("SKIP (", r.detail, ")");  break;
            case CaseStatus.ERROR: writeln("ERROR (", r.detail, ")"); break;
        }
        results ~= r;
    }

    printToolsTable(results, meshParam);

    string outPath = buildPath(g_repoRoot, "tools", "perf", "tools_results.json");
    writeToolsResultsJson(outPath, meshType, meshParam, viewport, repeats, results);
    writeln("\nWrote ", outPath);

    int failures = 0;
    writeln();
    writeln("=== tool preview invariants ===");
    auto invs = checkToolInvariants(results, cases.length);
    int invFail = 0;
    foreach (iv; invs) {
        writefln("  [%s] %-4s %-52s  %s",
                 iv.pass ? "PASS" : "FAIL", iv.id, iv.desc, iv.detail);
        if (!iv.pass) { invFail++; failures++; }
    }

    writeln();
    writeln("=== verdict ===");
    writefln("  invariants: %d/%d passed", invs.length - invFail, invs.length);
    writeln(failures == 0 ? "  OVERALL: PASS" : "  OVERALL: FAIL");

    // History under its OWN kind. `--trend` and `--vs-last` filter by kind,
    // so a `tools` row must never be compared against an `ops` row: the two
    // carry different metrics under different key spaces (kernelApply median
    // vs one preview rebuild), and mixing them would produce a day-over-day
    // "regression" that is a change of subject.
    try {
        // The header describes the mesh that was MEASURED, not the one the
        // run was invoked with. Every ToolCase pins its own `meshN`
        // (TOOLCASE_NMAX), so filing rows under the run's `--n` made a
        // `tools` run without `--n 96` incomparable with the nightly's —
        // `comparableEntries` keys on `header.n` — even though both measured
        // n=96, and the only thing holding the two together was a comment in
        // perf.yaml telling the operator to pass the right flag. Derived
        // here instead (review fix, task 1370). `faceCount` likewise: it was
        // hardcoded 0 while the case knows its real count.
        //
        // Mixed pinned sizes have no single header that describes them, so
        // that case falls back to the run's own parameter rather than filing
        // every row under one row's n. One case ships today; the fallback is
        // for the fifteen that follow.
        int  histN     = meshParam;
        long histFaces = 0;
        {
            bool first = true, agree = true;
            foreach (r; results) {
                if (r.status != CaseStatus.OK) continue;
                if (first) {
                    histN = r.effectiveN;
                    histFaces = r.effectiveFaceCount;
                    first = false;
                } else if (r.effectiveN != histN) {
                    agree = false;
                }
            }
            if (!agree) { histN = meshParam; histFaces = 0; }
        }
        auto curHeader = currentHeader(meshType, histN, histFaces, viewport, repeats);
        double[string] byCase;
        foreach (r; results) {
            if (r.status != CaseStatus.OK) continue;
            // BOTH keys carry the '#'-suffix the ops lane uses for
            // `#snapQuery`. The median goes in as `#previewRebuild` and NOT
            // under the bare case name: bare is the ops lane's key space for
            // a kernelApply median, and a row landing there beside
            // `#kernelShare` reads as this tool's kernel when it is in fact
            // the whole rebuild, wrapper included (review fix, task 1370;
            // the results JSON already named it `toolPreviewMedianUs`).
            byCase[r.name ~ "#previewRebuild"] = r.kernelMedianUs;
            // The share under its own key. It is the number this lane exists
            // to produce, so it belongs in the record.
            //
            // RECORDED, NOT GATED, and the difference is worth stating
            // because the '#snapQuery' precedent gates: `checkVsLast` returns
            // early unless the LATEST history entry is an `ops` run
            // (lib/history.d), so no `tools` row is ever compared day over
            // day. It shows up in `--trend` (which filters by kind and so
            // keeps this table separate from ops' µs table) and nowhere else.
            // Gating it would mean teaching checkVsLast a second kind — a
            // deliberate follow-up, not something to imply here.
            byCase[r.name ~ "#kernelShare"] = r.kernelShare;
        }
        lib.history.appendHistory(g_repoRoot, curHeader, byCase, "tools");
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

    killStaleVibe(port);
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
// `--lane-health` — the narrow gate (task 1373 F1.4).
//
// WHY IT EXISTS. The `ops` step's own exit code gates nothing: the nightly
// runs it under `continue-on-error: true` and the job's `Gate` expression
// aggregates only `vslast`, `tools` and `frames` (.github/workflows/
// perf.yaml). On top of that, a case that errors is dropped from the history
// map before it is written, and `checkVsLast` iterates the keys of the
// CURRENT run — so the direction "this key was here yesterday and is gone
// today" is never walked. A perf case that stops working therefore costs
// nightly runtime, reads as coverage, and reddens nothing. Task 1460 holds
// the general problem; this closes the third of its three holes, narrowly,
// because without it every case this task adds is unmeasurable in the same
// way.
//
// WHY IT CAN BE GATING FROM DAY ONE, unlike the `ops` step it sits next to:
// everything it checks is a machine-stable fact about the COMPOSITION of the
// run — a status string, a set of names, a list of command ids. None of it is
// a hardware-bound budget and none of it has a two-month-stale baseline to be
// wrongly red against. That is the same argument the `tools` lane's step
// comment makes for itself.
//
// It is a PURE FILE READ. No build, no instance, no port — so it cannot kill
// a sibling lane's vibe3d and it costs milliseconds.
int runLaneHealth() {
    string path = buildPath(g_repoRoot, "tools", "perf", "results.json");
    writeln("=== lane health (", path, ") ===");
    if (!exists(path)) {
        writeln("  [FAIL] results.json is absent — the ops run did not finish.");
        writeln("         (`ops` removes the previous file before measuring, so");
        writeln("          an absent file means THIS run produced nothing, not");
        writeln("          that nobody ever ran one.)");
        return 1;
    }

    JSONValue j;
    try {
        j = parseJSON(cast(string)std.file.readText(path));
    } catch (Exception e) {
        writeln("  [FAIL] results.json is not parseable: ", e.msg);
        return 1;
    }

    int failures = 0;

    // The run's own filter. "Every declared case is present" is only a fair
    // question of a run that was asked for all of them.
    string[] filter;
    if ("filter" in j)
        foreach (v; j["filter"].array) filter ~= v.str;
    string meshType = ("meshType" in j) ? j["meshType"].str : "";

    // ---- 1. every row is OK -------------------------------------------
    bool[string] seen;
    size_t ok = 0;
    foreach (c; j["cases"].array) {
        string nm  = c["name"].str;
        string st  = c["status"].str;
        seen[nm] = true;
        if (st == "OK") { ok++; continue; }
        // A SKIP is legitimate for exactly one reason: a case that pins a
        // grid size, under a run that is not on a grid. That is the same
        // distinction runCase itself makes, and it is keyed on the run
        // header rather than on the detail text so it cannot be spoofed by
        // a message.
        if (st == "SKIP" && meshType != "grid") {
            writefln("  [ok]   %-30s SKIP (meshType=%s) — %s",
                     nm, meshType, ("detail" in c) ? c["detail"].str : "");
            continue;
        }
        writefln("  [FAIL] %-30s %s — %s", nm, st,
                 ("detail" in c) ? c["detail"].str : "(no detail)");
        failures++;
    }
    writefln("  %d rows, %d OK", j["cases"].array.length, ok);

    // ---- 2. every case this binary DECLARES is present -----------------
    //
    // The expected list comes from the DECLARATION (casesForTool x3 +
    // commandCases), never from yesterday's run. That is deliberate and it
    // is the difference between this check and the one trap-2 of task 1460
    // warns about: deleting a case on purpose removes the declaration and
    // the row together, so an intentional deletion is silent, while a case
    // that vanishes at RUNTIME — its command renamed away, its selection
    // rejected, the instance wedged before it ran — is loud.
    if (filter.length == 0) {
        string[] declared;
        foreach (t; [Tool.move, Tool.rotate, Tool.scale])
            foreach (c; casesForTool(t)) declared ~= c.name;
        foreach (c; commandCases()) declared ~= c.name;
        size_t missing = 0;
        foreach (nm; declared) {
            if (nm in seen) continue;
            writefln("  [FAIL] declared case never reported a row: %s", nm);
            missing++;
        }
        if (missing == 0)
            writefln("  all %d declared cases present", declared.length);
        failures += cast(int)missing;
    } else {
        writefln("  (declared-coverage check skipped: run was filtered by %s)",
                 filter.join(", "));
    }

    // ---- 3. coverage gap (invariant L2's finding) ----------------------
    if ("coverageGap" in j) {
        auto gap = j["coverageGap"].array;
        if (gap.length == 0) {
            writeln("  coverage: 0 geometry commands unaccounted");
        } else {
            foreach (g; gap)
                writefln("  [FAIL] geometry command neither covered nor " ~
                         "excluded: %s", g.str);
            failures += cast(int)gap.length;
        }
    } else {
        writeln("  [FAIL] results.json carries no `coverageGap` — it was " ~
                "written by a run.d older than task 1373");
        failures++;
    }

    writeln(failures == 0 ? "  LANE HEALTH: PASS" : "  LANE HEALTH: FAIL");
    return failures == 0 ? 0 : 1;
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
    bool   vsLast = false;
    bool   laneHealth = false;
    // NaN = "the operator did not say", which is a different state from "the
    // operator asked for the default value" — the snap threshold below is
    // resolved from it (task 1358).
    double vsLastThreshold     = double.nan;
    double vsLastSnapThreshold = double.nan;
    double vsLastFloorUs       = 200.0;
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
        "lane-health", "read tools/perf/results.json and exit nonzero if any case is not OK, if a case this binary declares is missing from it, or if a geometry command is neither covered nor excluded", &laneHealth,
        "vs-last",   "compare the latest history entry against the previous comparable run and exit nonzero on any regression (the day-over-day gate for scheduled runs)", &vsLast,
        "vs-last-threshold", "`--vs-last` regression threshold as a fraction (default 0.20 = +20%)", &vsLastThreshold,
        "vs-last-snap-threshold", "`--vs-last` threshold for the `#snapQuery` keys, which are measurably noisier (default 0.60 = +60%; lowering --vs-last-threshold below it lowers this too)", &vsLastSnapThreshold,
        "vs-last-floor",     "`--vs-last` ignores cases where both medians sit under this many µs (default 200)", &vsLastFloorUs,
        "last",      "`--trend` window size (default 20 runs)", &trendLast,
        "freq",      "`flame` perf sampling frequency Hz (default 999)", &flameFreq,
        "capture",   "`flame` idle-capture seconds after the drag/scenario (default 8)", &flameCapture,
        "ci",        "`frames` CI mode: F-I4 (GC) becomes RECORDED/non-gating for every " ~
                     "scenario (host-flaky); implies --no-absolute", &ciMode);

    if (helpInfo.helpWanted) {
        writeln("usage: ./run.d [ops] [options] [case-name-substring...]");
        writeln("       ./run.d frames [options] [scenario-name-substring...]");
        writeln("       ./run.d tools  [options] [tool-case-name-substring...]");
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
        (requested[0] == "ops" || requested[0] == "frames"
         || requested[0] == "flame" || requested[0] == "tools")) {
        subcommand = requested[0];
        requested = requested[1 .. $];
    }

    g_keep = keep;
    g_baseUrl = format("http://localhost:%d", port);

    // Keep every localhost HTTP hop (std.net.curl in lib/http.d, the curl
    // probe in lib/lifecycle.d, and any child process) off a configured
    // proxy: a CI runner injects lowercase http_proxy into job envs, and
    // libcurl then tunnels even http://localhost through the proxy host.
    // Merging (not overwriting) no_proxy preserves whatever the host set.
    {
        import std.process : environment;
        foreach (nm; ["no_proxy", "NO_PROXY"]) {
            auto cur = environment.get(nm, "");
            import std.algorithm : canFind;
            if (!cur.canFind("localhost"))
                environment[nm] = cur.length ? cur ~ ",localhost,127.0.0.1"
                                             : "localhost,127.0.0.1";
        }
    }

    // `--lane-health` is a pure file read (task 1373 F1.4) and short-circuits
    // here for the same reason `--trend` does: it must not build, must not
    // kill a sibling lane's instance, and must not launch one.
    if (laneHealth)
        return runLaneHealth();

    // `--trend` needs no vibe3d (pure history-file read) and short-circuits
    // before killStaleVibe/launchVibe/dubBuildPerf (task 0197 Phase 4).
    if (trend) {
        auto path = lib.history.historyPath(g_repoRoot, Socket.hostName);
        auto entries = lib.history.loadHistory(path);
        lib.history.printTrend(entries, trendLast);
        return 0;
    }

    // `--vs-last` is a pure history-file read too: the scheduled lane runs it
    // right after `ops` so a fresh regression fails the run even while the
    // absolute lane is knowingly red against a stale committed baseline.
    if (vsLast) {
        // Resolve the two thresholds (task 1358). The `#snapQuery` keys need a
        // LOOSER default than the rest — their run-to-run step is measured,
        // not assumed (see `kSnapQueryVsLastThreshold`) — but "looser" must
        // not mean "a floor the operator cannot get under": someone hunting a
        // small snap regression with `--vs-last-threshold 0.05` would then
        // get 5% on every key except the ones they are hunting. So:
        //   * `--vs-last-snap-threshold` given → exactly that, always;
        //   * else `--vs-last-threshold` given → min(it, the snap default),
        //     i.e. tightening the general gate tightens this one too, and
        //     loosening it leaves the snap keys where the measurement put
        //     them;
        //   * else → the measured default.
        immutable bool thrGiven     = !vsLastThreshold.isNaN;
        immutable bool snapThrGiven = !vsLastSnapThreshold.isNaN;
        if (!thrGiven) vsLastThreshold = 0.20;
        if (!snapThrGiven)
            vsLastSnapThreshold = thrGiven
                ? fmin(vsLastThreshold, lib.history.kSnapQueryVsLastThreshold)
                : lib.history.kSnapQueryVsLastThreshold;

        auto path = lib.history.historyPath(g_repoRoot, Socket.hostName);
        auto entries = lib.history.loadHistory(path);
        int regressions = lib.history.checkVsLast(entries, vsLastThreshold,
                                                  vsLastSnapThreshold,
                                                  vsLastFloorUs);
        return regressions > 0 ? 1 : 0;
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

    if (subcommand == "tools")
        return runToolsSubcommand(meshType, meshParam, viewport, port, requested,
                                  repeats, noBuild);

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

    // A filter that matched NOTHING is a failure, not a quiet zero — and
    // this guard is where an unrecognised SUBCOMMAND lands, because the
    // dispatch in main() accepts exactly `ops|frames|flame|tools` and turns
    // every other leading token into an ops case-name substring. `run.d
    // tolls --no-build --n 96` used to print one line and exit 0, so a typo
    // in a workflow step that names its lane by hand bought a green run with
    // zero coverage (review fix, task 1370). Bare `run.d` never reaches
    // here: with no filter both tables are non-empty.
    if (cases.length == 0 && cmdCases.length == 0) {
        stderr.writefln("no cases matched %s — nothing was measured", requested);
        return 1;
    }

    // Drop the previous run's results.json BEFORE measuring anything.
    //
    // This is what makes `--lane-health` a gate on THIS run rather than on
    // whatever file happened to be lying around. The two are separate
    // processes in the nightly (`ops` then `lanehealth`), so an `ops` that
    // dies — segfault, wedged instance, killed on the job timeout — would
    // otherwise leave yesterday's green file in place and the health step
    // would certify a run that never happened. With the file removed here,
    // a dead `ops` leaves nothing and `--lane-health` says so.
    {
        string stale = buildPath(g_repoRoot, "tools", "perf", "results.json");
        if (exists(stale)) std.file.remove(stale);
    }

    killStaleVibe(port);
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

    printTable(results, meshParam);

    // Coverage (invariant L2) is asked of the LIVE app — the registry is the
    // same source doc/command_reference.md is generated from — so it has to
    // be computed here, while the instance is still up, and carried into both
    // results.json and the invariant list.
    string[] coverageGap;
    try {
        coverageGap = computeCoverageGap(registryCommands());
    } catch (Exception e) {
        stderr.writeln("warning: /api/registry read failed: ", e.msg);
    }

    string outPath = buildPath(g_repoRoot, "tools", "perf", "results.json");
    writeResultsJson(outPath, meshType, meshParam, mi.faceCount,
                     viewport, repeats, results, requested, coverageGap);
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
    auto invs = checkInvariants(results, cases.length + cmdCases.length,
                                coverageGap);
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
        foreach (r; results) {
            if (r.status != CaseStatus.OK) continue;
            kernelMedianByCase[r.historyKey] = r.kernelMedianUs;
            // Task 1350 — the snap query's own median, under a SECOND key.
            //
            // Why it has to be in history at all: snap cases are excluded from
            // the absolute baseline comparison below (their moving set is not
            // stable enough for a fixed budget), and I5 only asserts that
            // snapCursor was CALLED. So between the two of them nothing ever
            // watched snapQuery's cost, and a 20x regression in it (2026-08-18:
            // 2.4 ms → 56 ms per drag) rode into the tree behind a fully green
            // lane. Writing it here puts it under the EXISTING `--vs-last`
            // day-over-day gate for free: at its +20% threshold a 20x regression
            // reads as +2000%.
            //
            // A separate key rather than a second map: `appendHistory` is
            // metric-agnostic by design ({name: value}), and `checkVsLast`
            // compares by key, so `<case>#snapQuery` gates exactly like a case
            // does with no change to either. The '#' cannot collide with a case
            // name (they are `tool/axis`).
            //
            // KNOWN LIMIT, stated rather than papered over: `checkVsLast`
            // skips a pair where BOTH sides sit under its 200 µs floor, so a
            // regression that stays inside that band is not caught here. Which
            // keys that actually affects, MEASURED rather than assumed (the
            // first version of this comment claimed the whole-mesh snap cases
            // "sit far below" the floor "because they build nothing" — review
            // fix, task 1358; they are 30-55x ABOVE it, and a reader who
            // believed the claim would have deleted the only gate on the 20x
            // regression this key exists for):
            //
            //   move/snap=vertex#snapQuery       6274 µs  — 31x the floor
            //   move/snap=edge#snapQuery        11577 µs  — 58x
            //   move/snap=polygon#snapQuery     10652 µs  — 53x
            //   move/snap=vertex+partial#…     315660 µs  — 1578x
            //   move/snap=grid#snapQuery            6 µs  — BELOW, skipped
            //   move/snap=workplane#snapQuery       6 µs  — BELOW, skipped
            //
            // "Builds nothing" is not "costs nothing": laziness removed the
            // MASK from the whole-mesh cases and left the candidate-grid walk,
            // which is 6-12 ms per drag on the n=316 mesh and is what these
            // keys now watch. Only `grid` and `workplane` — which never had a
            // geometric walk at all — fall in the skipped band.
            if (r.name.canFind("snap=")) {
                kernelMedianByCase[r.historyKey ~ "#snapQuery"] = r.snapQueryMedianUs;
                // Task 1351. `#snapQuery` times the WHOLE walk — candidate
                // grid, election, mask and all — so a mask build that doubles
                // while the walk gets cheaper elsewhere reads as no change.
                // This key is the mask's own O(V)+O(F) BUILD, and it goes in
                // for the same reason and by the same mechanism:
                // `appendHistory` is metric-agnostic, so it gates under
                // `--vs-last` for free.
                //
                // It does NOT watch the occluder walk, which is lazy and lands
                // outside the timer — that is I7d's ratio, and a ratio has no
                // business in a map of microsecond medians whose gate carries a
                // 200 us floor. Two different questions, two different
                // instruments.
                //
                // Task 1373 merge: both sub-keys hang off `historyKey`, not
                // `name`. `historyKey` carries the case's DECLARED `meshN` as
                // an `@nNN` suffix, so a case pinned to one size cannot file
                // under two keys depending on the run's `--n` — the defect
                // 1373's M8 pins. Keying one sub-metric by `name` and the
                // other by `historyKey` would split a single case's history
                // across two rows the moment either lane's pin changed.
                if (r.snapVisMaskCount > 0)
                    kernelMedianByCase[r.historyKey ~ "#snapVisMask"] =
                        r.snapVisMaskMedianUs;
            }
        }
        lib.history.appendHistory(g_repoRoot, curHeader, kernelMedianByCase, "ops");
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
