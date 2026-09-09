module composite_sampling_characterization_helpers;

import core.thread : Thread;
import core.time : msecs;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.math : fabs, sqrt, cos, sin, PI;
import std.stdio : writefln;
import std.string : format;

import drag_helpers : buildDragLog, fetchCamera, fetchHandlePart,
    gizmoSize, playAndWait, projectToWindow, viewportFromCamera, Vec3;

private enum double kBroadSize = 12.0;
private enum double kTargetSize = 3.2;
private immutable D3 kFalloffCenter = D3(-1.2, -0.7, -0.4);

struct D3 {
    double x;
    double y;
    double z;

    D3 opBinary(string op)(D3 rhs) const {
        static if (op == "+") return D3(x + rhs.x, y + rhs.y, z + rhs.z);
        else static if (op == "-") return D3(x - rhs.x, y - rhs.y, z - rhs.z);
        else static assert(false, "unsupported D3 operator");
    }

    D3 opBinary(string op)(double rhs) const {
        static if (op == "*") return D3(x * rhs, y * rhs, z * rhs);
        else static if (op == "/") return D3(x / rhs, y / rhs, z / rhs);
        else static assert(false, "unsupported D3 scalar operator");
    }
}

private double dot(D3 a, D3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

private D3 cross(D3 a, D3 b) {
    return D3(a.y * b.z - a.z * b.y,
              a.z * b.x - a.x * b.z,
              a.x * b.y - a.y * b.x);
}

private double norm(D3 v) {
    return sqrt(dot(v, v));
}

private double number(JSONValue v) {
    final switch (v.type) {
    case JSONType.float_: return v.floating;
    case JSONType.integer: return cast(double)v.integer;
    case JSONType.uinteger: return cast(double)v.uinteger;
    case JSONType.null_, JSONType.string, JSONType.array, JSONType.object,
         JSONType.true_, JSONType.false_:
        assert(false, "expected a numeric JSON value, got " ~ v.toString);
    }
}

private D3 readD3(JSONValue v) {
    auto a = v.array;
    assert(a.length == 3, "expected a three-component vector: " ~ v.toString);
    return D3(number(a[0]), number(a[1]), number(a[2]));
}

private D3[] vertices() {
    D3[] result;
    foreach (v; getJson("/api/model")["vertices"].array)
        result ~= readD3(v);
    return result;
}

private D3 boundingBoxCenter(const(D3)[] points) {
    assert(points.length > 0, "Action Center stand must be populated");
    D3 low = points[0];
    D3 high = points[0];
    foreach (p; points[1 .. $]) {
        if (p.x < low.x) low.x = p.x;
        if (p.y < low.y) low.y = p.y;
        if (p.z < low.z) low.z = p.z;
        if (p.x > high.x) high.x = p.x;
        if (p.y > high.y) high.y = p.y;
        if (p.z > high.z) high.z = p.z;
    }
    return (low + high) * 0.5;
}

private double maxDiff(const(D3)[] a, const(D3)[] b,
                       out size_t worstVertex, out string worstComponent) {
    assert(a.length == b.length, "position arrays must have equal lengths");
    double worst = 0.0;
    foreach (i; 0 .. a.length) {
        foreach (component, d; [fabs(a[i].x - b[i].x),
                                fabs(a[i].y - b[i].y),
                                fabs(a[i].z - b[i].z)]) {
            if (d > worst) {
                worst = d;
                worstVertex = i;
                worstComponent = component == 0 ? "x" : component == 1 ? "y" : "z";
            }
        }
    }
    return worst;
}

private void cmd(string line) {
    auto response = postJson("/api/command", line);
    assert(response["status"].str == "ok",
        "command failed: " ~ line ~ " => " ~ response.toString);
}

private void settle() {
    Thread.sleep(180.msecs);
}

private long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

private long meshMutationVersion() {
    return getJson("/api/layers")["layers"].array[0]["mutationVersion"].integer;
}

private long armedChecks() {
    return getJson("/api/changes")["regradeCensusArmedChecks"].integer;
}

private long disagreements() {
    return getJson("/api/changes")["regradeCensusDisagreements"].integer;
}

private D3 evaluatedPivot() {
    return readD3(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
}

private HeldState heldState() {
    auto transform = getJson("/api/toolpipe/eval")["transform"];
    return HeldState(readD3(transform["translate"]),
                     readD3(transform["rotate"]),
                     readD3(transform["scale"]));
}

private struct HeldState {
    D3 translate;
    D3 rotate;
    D3 scale;
}

private double heldDelta(string bank, HeldState before, HeldState after) {
    switch (bank) {
    case "move": return norm(after.translate - before.translate);
    case "rotate": return norm(after.rotate - before.rotate);
    case "scale": return norm(after.scale - before.scale);
    default: assert(false, "unknown transform bank: " ~ bank);
    }
}

private void drivePart(string bank, int part, long wantedUndo,
                       int dx, int dy) {
    auto before = heldState();
    settle();
    double x0, y0;
    bool found;
    fetchHandlePart(part, x0, y0, found);
    assert(found, format("%s characterization: handle part %d is absent", bank, part));
    auto camera = fetchCamera();
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             cast(int)(x0 + 0.5), cast(int)(y0 + 0.5),
                             cast(int)(x0 + 0.5) + dx,
                             cast(int)(y0 + 0.5) + dy, 14));
    settle();
    auto after = heldState();
    assert(undoCount() == wantedUndo,
        format("%s characterization gesture did not open its expected history step: "
             ~ "undo=%d expected=%d", bank, undoCount(), wantedUndo));
    assert(heldDelta(bank, before, after) > 1e-3,
        format("%s characterization gesture hit no %s input: before=%s after=%s",
               bank, bank, before.to!string, after.to!string));
}

private void driveMove(long wantedUndo) {
    // Global part 3 is the compact Transform Move centre box. Its free-plane
    // drag keeps the live-drag fold identical to the later idle fold even with
    // a held rotation (the axis-arrow path has a drag-only de-rotation term).
    drivePart("move", 3, wantedUndo, 52, -31);
}

private void driveRotate(long wantedUndo) {
    // Use an interior point of the visible X-ring semicircle. The generic
    // screen anchor is also a legal point on the arc, but can overlap a compact
    // Move arrow; this geometry stays clear of the sibling-bank handles.
    auto camera = fetchCamera();
    auto viewport = viewportFromCamera(camera);
    auto pivot = evaluatedPivot();
    float size = gizmoSize(Vec3(cast(float)pivot.x, cast(float)pivot.y,
                                cast(float)pivot.z), viewport);
    float angle = 110.0f * cast(float)PI / 180.0f;
    Vec3 point = Vec3(cast(float)pivot.x,
                      cast(float)pivot.y + cos(angle) * size,
                      cast(float)pivot.z + sin(angle) * size);
    float x, y;
    assert(projectToWindow(point, viewport, x, y),
        "rotate characterization: X ring is off-camera");

    auto before = heldState();
    playAndWait(buildDragLog(camera.vpX, camera.vpY,
                             camera.width, camera.height,
                             cast(int)x, cast(int)y,
                             cast(int)x + 37, cast(int)y + 29, 14));
    settle();
    auto after = heldState();
    assert(undoCount() == wantedUndo,
        format("rotate characterization gesture did not open its expected "
             ~ "history step: undo=%d expected=%d", undoCount(), wantedUndo));
    assert(norm(after.rotate - before.rotate) > 1e-3,
        format("rotate characterization gesture hit no rotate input: "
             ~ "before=%s after=%s", before.to!string, after.to!string));
}

private void driveScale(long wantedUndo) {
    settle();
    double hx, hy;
    bool found;
    fetchHandlePart(20, hx, hy, found);
    assert(found, "scale characterization: compact Transform X box is absent");

    auto camera = fetchCamera();
    auto viewport = viewportFromCamera(camera);
    auto pivot = evaluatedPivot();
    float px, py;
    assert(projectToWindow(Vec3(cast(float)pivot.x, cast(float)pivot.y,
                                cast(float)pivot.z), viewport, px, py),
        "scale characterization: pivot is off-camera");
    double vx = hx - px, vy = hy - py;
    double vl = sqrt(vx * vx + vy * vy);
    assert(vl > 10.0, "scale characterization: X box collapsed onto the pivot");
    drivePart("scale", 20, wantedUndo,
              cast(int)(82.0 * vx / vl), cast(int)(82.0 * vy / vl));
}

private void establishAsymmetricStand() {
    postJson("/api/script", "tool.set Transform off\n");
    auto loaded = postJson("/api/command", commandBody("scene.loadMesh",
        `{"vertices":[[-1.2,-0.7,-0.4],[1.6,-0.5,-0.2],[0.9,1.1,0.1],`
      ~ `[-0.8,0.6,0.35],[0.15,0.2,1.7]],`
      ~ `"faces":[[0,1,2,3],[0,4,1],[1,4,2],[2,4,3],[3,4,0]]}`));
    assert(loaded["status"].str == "ok",
        "asymmetric mesh load failed: " ~ loaded.toString);
    auto selected = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"vertices","indices":[0,1,2,3,4]}`));
    assert(selected["status"].str == "ok",
        "asymmetric vertex selection failed: " ~ selected.toString);
    cmd("history.clear");
    cmd("tool.set Transform");
    cmd("tool.pipe.attr actionCenter mode auto");
    cmd("tool.pipe.attr axis mode world");
    cmd("tool.pipe.attr symmetry enabled false");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "-1.2,-0.7,-0.4"`);
    cmd(`tool.pipe.attr falloff size "12,12,12"`);
    settle();
}

void teardownCompositeCharacterization() {
    // The runner reuses one application per worker. Scene reset does not reset
    // either the active tool or Action Center mode, so restore both explicitly.
    postJson("/api/script", "tool.set Transform off\n");
    postJson("/api/command", "tool.pipe.attr falloff type none");
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
    settle();
}

private double radialWeight(D3 point, double size) {
    D3 delta = point - kFalloffCenter;
    double t = norm(delta) / size;
    if (t <= 0.0) return 1.0;
    if (t >= 1.0) return 0.0;
    return 1.0 - t;
}

private struct LinearMap {
    D3 b0;
    D3 b1;
    D3 b2;
    D3 q0;
    D3 q1;
    D3 q2;
    double determinant;

    D3 apply(D3 value) const {
        double c0 = dot(value, cross(b1, b2)) / determinant;
        double c1 = dot(b0, cross(value, b2)) / determinant;
        double c2 = dot(b0, cross(b1, value)) / determinant;
        return q0 * c0 + q1 * c1 + q2 * c2;
    }
}

private LinearMap recoverLinearMap(const(D3)[] baseline,
                                   const(D3)[] unweighted) {
    // 0/1/2/4 form a non-coplanar tetrahedron on this stand. Difference
    // vectors remove the affine translation and leave the fold's linear part.
    LinearMap result;
    result.b0 = baseline[1] - baseline[0];
    result.b1 = baseline[2] - baseline[0];
    result.b2 = baseline[4] - baseline[0];
    result.q0 = unweighted[1] - unweighted[0];
    result.q1 = unweighted[2] - unweighted[0];
    result.q2 = unweighted[4] - unweighted[0];
    result.determinant = dot(result.b0, cross(result.b1, result.b2));
    assert(fabs(result.determinant) > 0.1,
        "characterization tetrahedron is degenerate");
    return result;
}

private D3[] candidatePositions(const(D3)[] baseline, LinearMap linear,
                                D3 translation, D3 pivot) {
    D3[] result;
    result.length = baseline.length;
    foreach (i, point; baseline) {
        D3 full = pivot + linear.apply(point - pivot) + translation;
        double weight = radialWeight(point, kTargetSize);
        result[i] = point + (full - point) * weight;
    }
    return result;
}

struct CharacterizationResult {
    double candidateGap;
    double liveError;
    double baselineError;
    D3 baselinePivot;
    D3 livePivot;
    size_t gapVertex;
    string gapComponent;
    size_t liveErrorVertex;
    string liveErrorComponent;
    size_t baselineErrorVertex;
    string baselineErrorComponent;
}

CharacterizationResult characterizeCompositeSampling(string finalBank) {
    establishAsymmetricStand();
    auto baseline = vertices();
    assert(baseline.length == 5,
        "composite sampling stand must retain all five vertices");
    D3 baselinePivot = boundingBoxCenter(baseline);
    assert(norm(evaluatedPivot() - baselinePivot) < 1e-5,
        "baseline Action Center must equal the independently computed bbox center");

    string[] sequence;
    switch (finalBank) {
    case "move": sequence = ["rotate", "scale", "move"]; break;
    case "rotate": sequence = ["move", "scale", "rotate"]; break;
    case "scale": sequence = ["move", "rotate", "scale"]; break;
    default: assert(false, "unknown final characterization bank: " ~ finalBank);
    }

    long expectedUndo = undoCount();
    D3 finalGesturePivot;
    foreach (bank; sequence) {
        ++expectedUndo;
        if (bank == finalBank) finalGesturePivot = evaluatedPivot();
        if (bank == "move") driveMove(expectedUndo);
        else if (bank == "rotate") driveRotate(expectedUndo);
        else driveScale(expectedUndo);
    }

    auto held = heldState();
    auto postGesture = vertices();

    // Remove only the display soft pin. This command is test-mode-only and
    // deliberately leaves the committed gesture, geometry run, and stamp live.
    cmd("tool.clearSoftPinForTest");
    settle();
    D3 livePivot = boundingBoxCenter(postGesture);
    assert(norm(evaluatedPivot() - livePivot) < 2e-4,
        "live Action Center must equal the independently computed post-gesture bbox center");
    assert(norm(livePivot - baselinePivot) > 1e-3,
        "the asymmetric stand must move its bbox center before sampling is characterized");

    // Undo the broad falloff blend arithmetically, producing the full-weight
    // image of the held affine fold without consulting the idle re-grade output.
    D3[] unweighted;
    unweighted.length = baseline.length;
    foreach (i; 0 .. baseline.length) {
        double weight = radialWeight(baseline[i], kBroadSize);
        assert(weight > 0.75,
            format("broad characterization weight at v%d is too small: %g", i, weight));
        unweighted[i] = baseline[i]
            + (postGesture[i] - baseline[i]) / weight;
    }

    auto linear = recoverLinearMap(baseline, unweighted);
    D3 translation = unweighted[0] - finalGesturePivot
                   - linear.apply(baseline[0] - finalGesturePivot);

    // All five recovered full-weight points must lie on the independently fit
    // affine map; otherwise the oracle would be fitting the wrong live path.
    auto recoveredAtGesturePivot = candidatePositions(
        baseline, linear, translation, finalGesturePivot);
    D3[] expectedBroad;
    expectedBroad.length = baseline.length;
    foreach (i, point; baseline)
        expectedBroad[i] = point + (unweighted[i] - point)
            * radialWeight(point, kTargetSize);
    size_t fitVertex;
    string fitComponent;
    double fitError = maxDiff(recoveredAtGesturePivot, expectedBroad,
                              fitVertex, fitComponent);
    assert(fitError < 2e-3,
        format("independent affine recovery does not reproduce the held fold: "
             ~ "worst=%g at v%d.%s", fitError, fitVertex, fitComponent));

    auto baselineCandidate = candidatePositions(
        baseline, linear, translation, baselinePivot);
    auto liveCandidate = candidatePositions(
        baseline, linear, translation, livePivot);

    CharacterizationResult result;
    result.baselinePivot = baselinePivot;
    result.livePivot = livePivot;
    result.candidateGap = maxDiff(baselineCandidate, liveCandidate,
                                  result.gapVertex, result.gapComponent);
    // This assertion MUST precede the characterization assertion in each test:
    // a geometry on which both candidates agree proves no sampling policy.
    assert(result.candidateGap > 1e-3,
        format("%s composite stand does not separate baseline/live candidates: "
             ~ "worst=%g at v%d.%s", finalBank, result.candidateGap,
               result.gapVertex, result.gapComponent));

    long mutationBefore = meshMutationVersion();
    long armedBefore = armedChecks();
    long disagreementsBefore = disagreements();
    cmd(`tool.pipe.attr falloff size "3.2,3.2,3.2"`);
    settle();
    auto actual = vertices();

    // State proof for ARM-2, before any final geometry characterization.
    auto toolState = getJson("/api/tool/state");
    assert(toolState["dragging"].type == JSONType.false_
        && toolState["activeBank"].str == "none",
        finalBank ~ " characterization reached the oracle with activeDrag non-null");
    assert(toolState["editOpen"].type == JSONType.false_,
        finalBank ~ " characterization reached ARM-1 instead of closed-edit ARM-2");

    auto history = getJson("/api/history")["undo"].array;
    assert(history.length > 0
        && history[$ - 1]["inSession"].boolean
        && history[$ - 1]["refire"].boolean
        && history[$ - 1]["runId"].integer > 0,
        finalBank ~ " characterization did not retain an open re-grade run");

    double tMag = norm(held.translate);
    double rMag = norm(held.rotate);
    double sMag = norm(held.scale - D3(1, 1, 1));
    switch (finalBank) {
    case "move":
        assert(rMag > 1e-3 && sMag > 1e-3,
            "Move characterization requires held non-identity R and S neighbours");
        break;
    case "rotate":
        assert(tMag > 1e-3 && sMag > 1e-3,
            "Rotate characterization requires held non-identity T and S neighbours");
        break;
    case "scale":
        assert(tMag > 1e-3 && rMag > 1e-3,
            "Scale characterization requires held non-identity T and R neighbours");
        break;
    default: assert(false);
    }

    long armedDelta = armedChecks() - armedBefore;
    long disagreementDelta = disagreements() - disagreementsBefore;
    assert(meshMutationVersion() == mutationBefore
        && armedDelta > 0 && disagreementDelta == 0,
        format("%s characterization reached the oracle without a current armed "
             ~ "stamp: mutation %d->%d armedDelta=%d disagreementDelta=%d",
               finalBank, mutationBefore, meshMutationVersion(), armedDelta,
               disagreementDelta));

    result.liveError = maxDiff(actual, liveCandidate,
                               result.liveErrorVertex,
                               result.liveErrorComponent);
    result.baselineError = maxDiff(actual, baselineCandidate,
                                   result.baselineErrorVertex,
                                   result.baselineErrorComponent);
    writefln("[composite %s] baselinePivot=%s livePivot=%s gap=%g at v%d.%s "
           ~ "liveError=%g baselineError=%g baselinePositions=%s livePositions=%s",
             finalBank, baselinePivot, livePivot, result.candidateGap,
             result.gapVertex, result.gapComponent, result.liveError,
             result.baselineError, baselineCandidate, liveCandidate);
    return result;
}
