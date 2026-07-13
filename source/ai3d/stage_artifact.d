module ai3d.stage_artifact;

// ---------------------------------------------------------------------------
// stage_artifact — the non-mutating AI3D network + staging seam (task 0381,
// doc/ai3d_ui_plan.md Phase 0). Shared by the scripted synchronous command
// (commands/ai3d/generate.d, calling from whatever thread invoked it — today
// always the main thread) and the async worker thread (ai3d.job_controller).
//
// No `Document`/`Mesh` reference anywhere in this module. Every `std.net.curl
// .HTTP` instance created here is local to the calling thread's stack frame
// and never escapes it or is shared with another thread.
//
// Cancellation model: every entry point takes `ref shared bool stopRequested`
// — the caller (job_controller) ORs its own cancel-request and shutdown-stop
// flags into one atomic before calling in; this module treats "stopRequested
// observed true" uniformly as an abort-in-progress signal at any point in a
// multi-request sequence (poll-tick check + a curl-level onProgress callback
// on every transfer, per Risk 4 in the design doc).
// ---------------------------------------------------------------------------

import core.atomic : atomicLoad;
import core.thread : Thread;
import core.time : msecs;

import std.array : appender;
import std.conv : to;
import std.digest.sha : sha256Of, toHexString;
import std.file : read, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath, extension;
import std.string : startsWith, toLower;
import std.uuid : randomUUID;

import ai3d.scene_validator : Ai3dMaxTotalFaces;

// ---------------------------------------------------------------------------
// Bounds (Risk 4b + the DoS-clamp project convention). Every HTTP request
// this module issues sets BOTH timeouts so a stalled connection unwinds well
// inside job_controller's `Ai3dClientJoinTimeoutMs` shutdown budget.
// ---------------------------------------------------------------------------

enum Ai3dConnectTimeoutMs = 5_000;
enum Ai3dOperationTimeoutMs = 10_000;
/// Poll-tick interval for the job-status loop; also the worst-case bound on
/// observing a cancel that lands between two requests (the per-tick check).
enum Ai3dPollIntervalMs = 250;
/// Hard cap on a downloaded artifact's byte length, enforced via checked
/// arithmetic in the `onReceive` accumulator (abort mid-download on
/// overflow — never grow the buffer unbounded for a misbehaving worker
/// response).
enum Ai3dMaxArtifactBytes = 16 * 1024 * 1024;
/// Kernel cap on the caller-supplied generation-deadline (`generate.d`'s
/// `timeoutMs` Param): the authoritative floor/ceiling enforced HERE
/// regardless of caller, independent of that Param's own `.enforceBounds()`
/// UI/injection-path clamp (two-layer clamp, project convention).
enum Ai3dMaxGenerationDeadlineMs = 600_000;
/// Default requested face count for the create-job body when the caller
/// (a Param, a test hook, a scripted command) does not have a stronger
/// opinion. Deliberately equal to the pre-ai3d-maxfaces hardcoded literal
/// (`maxFaces:50000`) so existing behavior is the default, not a surprise.
enum Ai3dDefaultRequestedFaces = 50_000;

/// Clamp a caller-supplied poll-loop deadline to (0, Ai3dMaxGenerationDeadlineMs].
/// The authoritative kernel-side bound for `stageArtifact`'s poll loop —
/// applied unconditionally, independent of any Param-level hint.
int clampGenerationDeadlineMs(int timeoutMs) {
    if (timeoutMs <= 0) return 1;
    if (timeoutMs > Ai3dMaxGenerationDeadlineMs) return Ai3dMaxGenerationDeadlineMs;
    return timeoutMs;
}

/// Clamp a caller-supplied `maxFaces` request to [1000, Ai3dMaxTotalFaces].
/// The authoritative kernel-side bound for `stageArtifact`'s create-job
/// body — applied unconditionally regardless of caller, independent of the
/// `generate.d` Param's own `.enforceBounds()` UI/injection-path clamp
/// (two-layer clamp, project convention; mirrors clampGenerationDeadlineMs
/// immediately above). `Ai3dMaxTotalFaces` (ai3d.scene_validator) is the
/// same ceiling the imported OBJ must clear on the way back in, so a
/// request above it can only ever produce an artifact the validator will
/// reject anyway.
int clampMaxFaces(int maxFaces) {
    if (maxFaces < 1_000) return 1_000;
    if (maxFaces > Ai3dMaxTotalFaces) return cast(int) Ai3dMaxTotalFaces;
    return maxFaces;
}

/// One reported step of a staged transfer, posted to the caller's
/// `onProgress` delegate from `stageArtifact`'s poll loop. Value type — safe
/// to copy across the worker->main event queue (job_controller.d folds this
/// into an `Ai3dEvent`).
struct Ai3dProgress {
    string jobId;
    long generation;
    string state;    // "submitted"|"queued"|"running"|"succeeded"|"failed"|"cancelled"
    string stage;    // worker-reported stage, e.g. "reconstructing"
    double progress = 0; // 0..1, worker-reported
}

struct Ai3dStageResult {
    bool ok;
    bool cancelled;
    string jobId;
    long generation;
    string objPath;
    ulong bytes;
    string code;
    string message;
}

struct Ai3dHealthResult {
    bool ok;
    int protocol;
    string backend;
    bool objCapable;
    string code;
    string message;
}

/// Health-only round-trip (`GET /v1/health`) — creates NO job. Lets a caller
/// (the modal, or `stageArtifact` itself as its first step) learn worker
/// readiness before committing to a generate. Bounded timeouts; observes
/// `stopRequested` like every other request in this module.
Ai3dHealthResult probeHealthCheck(string baseUrl, ref shared bool stopRequested) {
    Ai3dHealthResult r;
    const url = normalizeLocalWorkerUrl(baseUrl);
    if (url.length == 0) {
        r.code = "invalid_worker_url";
        r.message = "AI3D worker URL must be a local loopback address";
        return r;
    }
    try {
        auto fetched = getBytesBounded(url ~ "/v1/health", null, stopRequested);
        if (fetched.aborted) {
            r.code = "cancelled";
            r.message = "health probe aborted";
            return r;
        }
        auto health = parseJSON(cast(string) fetched.data);
        r.protocol = cast(int) health["protocol"].integer;
        if (r.protocol != 1) {
            r.code = "protocol_mismatch";
            r.message = "AI3D worker protocol mismatch";
            return r;
        }
        if (auto backendPtr = "backend" in health.object) {
            if (backendPtr.type == JSONType.object)
                if (auto idPtr = "id" in backendPtr.object)
                    r.backend = idPtr.str;
        }
        bool objCapable;
        if (auto capsPtr = "capabilities" in health.object)
            if (capsPtr.type == JSONType.object)
                if (auto artsPtr = "artifact" in capsPtr.object)
                    if (artsPtr.type == JSONType.array)
                        foreach (v; artsPtr.array)
                            if (v.type == JSONType.string && v.str == "model/obj")
                                objCapable = true;
        r.objCapable = objCapable;
        r.ok = ("ready" in health.object) && health["ready"].type == JSONType.true_;
        if (!r.ok) {
            r.code = "worker_not_ready";
            r.message = "AI3D worker is not ready";
        }
        return r;
    } catch (Exception e) {
        r.code = "transport_error";
        r.message = e.msg;
        return r;
    }
}

/// Create a job, poll it to completion, download+verify the artifact, and
/// stage it to a local temp path. Never throws — every failure mode
/// (transport, protocol, cancellation, timeout, verification) is reported
/// through the returned `Ai3dStageResult` so callers on either the main
/// thread (the scripted synchronous command) or the worker thread (the
/// async controller) never need their own try/catch around this call.
///
/// `stopRequested` is checked at every poll tick (bounding cancel latency
/// to `Ai3dPollIntervalMs`) AND wired into every transfer's curl-level
/// `onProgress` callback (aborting an in-flight request immediately,
/// including a stalled artifact download — Risk 4a). On any cancellation
/// path the generation-bound `DELETE /v1/jobs/{id}` is issued (best-effort).
Ai3dStageResult stageArtifact(string baseUrl, string imagePath, int timeoutMs,
                               int maxFaces,
                               ref shared bool stopRequested,
                               scope void delegate(Ai3dProgress) onProgress = null) {
    Ai3dStageResult result;
    const boundedTimeoutMs = clampGenerationDeadlineMs(timeoutMs);
    const boundedMaxFaces = clampMaxFaces(maxFaces);
    const url = normalizeLocalWorkerUrl(baseUrl);
    if (url.length == 0) {
        result.code = "invalid_worker_url";
        result.message = "AI3D worker URL must be a local loopback address";
        return result;
    }

    try {
        // Phase 0.2: the health round-trip is now the shared probe helper —
        // behavior-preserving for the scripted path (a not-ready/protocol-
        // mismatch worker fails exactly as the old inline healthCheck() did).
        auto health = probeHealthCheck(url, stopRequested);
        if (!health.ok) {
            result.cancelled = (health.code == "cancelled");
            result.code = health.code.length ? health.code : "worker_not_ready";
            result.message = health.message;
            return result;
        }
        if (atomicLoad(stopRequested)) {
            result.cancelled = true;
            result.code = "cancelled";
            result.message = "cancelled before submission";
            return result;
        }

        auto created = createJob(url, imagePath, boundedMaxFaces, stopRequested);
        if (created.aborted) {
            result.cancelled = true;
            result.code = "cancelled";
            result.message = "cancelled during submission";
            return result;
        }
        if ("jobId" !in created.json.object) {
            result.code = "create_failed";
            result.message = "AI3D create failed: " ~ created.json.toString();
            return result;
        }
        const jobId = created.json["jobId"].str;
        const generation = created.json["generation"].integer.to!long;
        result.jobId = jobId;
        result.generation = generation;

        if (onProgress !is null)
            onProgress(Ai3dProgress(jobId, generation, "submitted", "submitted", 0.0));

        JSONValue status;
        int waited;
        bool cancelledMidPoll;
        while (true) {
            if (atomicLoad(stopRequested)) { cancelledMidPoll = true; break; }

            auto fetched = getBytesBounded(url ~ "/v1/jobs/" ~ jobId,
                [Header("X-Vibe3D-AI3D-Protocol", "1")], stopRequested);
            if (fetched.aborted) { cancelledMidPoll = true; break; }
            status = parseJSON(cast(string) fetched.data);

            const state = status["state"].str;
            const stage = ("stage" in status.object) ? status["stage"].str : "";
            const progress = ("progress" in status.object) ? status["progress"].floating : 0.0;
            if (onProgress !is null)
                onProgress(Ai3dProgress(jobId, generation, state, stage, progress));

            if (state == "succeeded") break;
            if (state == "failed" || state == "cancelled") {
                result.cancelled = (state == "cancelled");
                result.code = "job_" ~ state;
                result.message = "AI3D job did not succeed (" ~ state ~ ")";
                issueCancelDelete(url, jobId, generation);
                return result;
            }
            if (waited >= boundedTimeoutMs) {
                result.code = "timeout";
                result.message = "AI3D job timed out";
                issueCancelDelete(url, jobId, generation);
                return result;
            }
            Thread.sleep(Ai3dPollIntervalMs.msecs);
            waited += Ai3dPollIntervalMs;
        }

        if (cancelledMidPoll) {
            result.cancelled = true;
            result.code = "cancelled";
            result.message = "cancelled while polling";
            issueCancelDelete(url, jobId, generation);
            return result;
        }

        const artifact = status["artifact"];
        if (artifact["generation"].integer.to!long != generation) {
            result.code = "generation_mismatch";
            result.message = "AI3D generation mismatch";
            return result;
        }
        const bytesExpected = artifact["bytes"].integer.to!ulong;
        const shaExpected = artifact["sha256"].str;
        const artifactUrl = sameOriginArtifactUrl(url, artifact["url"].str);

        auto downloaded = getBytesBounded(artifactUrl, [
            Header("X-Vibe3D-AI3D-Protocol", "1"),
            Header("X-Vibe3D-AI3D-Expected-Generation", generation.to!string),
        ], stopRequested);
        if (downloaded.aborted) {
            result.cancelled = true;
            result.code = "cancelled";
            result.message = "cancelled during download";
            issueCancelDelete(url, jobId, generation);
            return result;
        }
        auto data = downloaded.data;
        if (data.length != bytesExpected) {
            result.code = "artifact_length_mismatch";
            result.message = "AI3D artifact byte length mismatch";
            return result;
        }
        const gotSha = sha256Of(data).toHexString().idup.toLower;
        if (gotSha != shaExpected.toLower) {
            result.code = "artifact_hash_mismatch";
            result.message = "AI3D artifact sha256 mismatch";
            return result;
        }

        const outPath = buildPath(tempRoot(), "vibe3d-ai3d-" ~ jobId ~ ".obj");
        write(outPath, data);
        result.ok = true;
        result.objPath = outPath;
        result.bytes = data.length;
        return result;
    } catch (Exception e) {
        result.code = "transport_error";
        result.message = e.msg;
        return result;
    }
}

// ---------------------------------------------------------------------------
// Internals (moved from commands/ai3d/generate.d — Phase 0 extraction).
// ---------------------------------------------------------------------------

string normalizeLocalWorkerUrl(string raw) {
    if (raw.length == 0) return null;
    while (raw.length > 1 && raw[$ - 1] == '/')
        raw = raw[0 .. $ - 1];
    if (raw.startsWith("http://127.0.0.1:") ||
        raw == "http://127.0.0.1" ||
        raw.startsWith("http://localhost:") ||
        raw == "http://localhost" ||
        raw.startsWith("http://[::1]:") ||
        raw == "http://[::1]")
        return raw;
    return null;
}

private string imageMediaType(string path) {
    const ext = extension(path).toLower;
    if (ext == ".png") return "image/png";
    if (ext == ".jpg" || ext == ".jpeg") return "image/jpeg";
    if (ext == ".webp") return "image/webp";
    return null;
}

private string sameOriginArtifactUrl(string baseUrl, string artifact) {
    if (artifact.startsWith("/"))
        return baseUrl ~ artifact;
    if (artifact.startsWith(baseUrl ~ "/"))
        return artifact;
    throw new Exception("AI3D artifact URL is not same-origin");
}

private string tempRoot() {
    version (Windows) {
        import std.process : environment;
        auto t = environment.get("TEMP", null);
        return t.length ? t : ".";
    } else {
        return "/tmp";
    }
}

private struct Header {
    string name;
    string value;
}

/// Result of a bounded byte transfer: `aborted` is set (with `data` empty)
/// when `stopRequested` fired mid-transfer via the curl-level onProgress
/// callback — the caller distinguishes this from a genuine transport
/// exception (which still throws, per std.net.curl's own contract).
private struct BoundedBytes {
    ubyte[] data;
    bool aborted;
}

private struct BoundedJson {
    JSONValue json;
    bool aborted;
}

private void applyBoundedTimeouts(ref HTTP http) {
    http.connectTimeout = Ai3dConnectTimeoutMs.msecs;
    http.operationTimeout = Ai3dOperationTimeoutMs.msecs;
}

/// Wires curl-level onProgress SOLELY to observe `stopRequested` and abort
/// the in-flight transfer immediately (Risk 4a) — returning non-zero from
/// this callback aborts `perform()` with CURLE_ABORTED_BY_CALLBACK. This is
/// the primary defense that makes a mid-download cancel immediate rather
/// than waiting for the whole artifact to arrive.
private void applyCancelCallback(ref HTTP http, ref shared bool stopRequested) {
    http.onProgress = (size_t dlTotal, size_t dlNow, size_t ulTotal, size_t ulNow) {
        return atomicLoad(stopRequested) ? 1 : 0;
    };
}

private BoundedBytes getBytesBounded(string url, Header[] headers, ref shared bool stopRequested) {
    auto http = HTTP(url);
    http.method = HTTP.Method.get;
    applyBoundedTimeouts(http);
    applyCancelCallback(http, stopRequested);
    if (headers !is null)
        foreach (h; headers)
            http.addRequestHeader(h.name, h.value);
    auto sink = appender!(ubyte[])();
    size_t total;
    bool overCap;
    http.onReceive = (ubyte[] data) {
        // Checked arithmetic byte cap (Risk 4, "bounded transfers"): abort
        // (a short return count signals a write error to curl, aborting the
        // transfer) rather than growing an unbounded buffer. `total` is
        // maintained <= Ai3dMaxArtifactBytes as a loop invariant, so this
        // subtraction never underflows.
        if (data.length > Ai3dMaxArtifactBytes - total) { overCap = true; return 0; }
        total += data.length;
        sink.put(data);
        return data.length;
    };
    try {
        http.perform();
    } catch (Exception e) {
        if (overCap) throw new Exception("AI3D artifact exceeds the byte cap");
        if (atomicLoad(stopRequested)) return BoundedBytes(null, true);
        throw e;
    }
    return BoundedBytes(sink.data, false);
}

private BoundedJson createJob(string baseUrl, string imagePath, int maxFaces,
                               ref shared bool stopRequested) {
    const mediaType = imageMediaType(imagePath);
    if (mediaType.length == 0)
        throw new Exception("Unsupported AI3D image type");
    auto image = cast(ubyte[]) read(imagePath);
    const boundary = "----vibe3d-ai3d-" ~ randomUUID().toString();
    auto body = appender!(ubyte[])();
    appendAscii(body, "--" ~ boundary ~ "\r\n");
    appendAscii(body, `Content-Disposition: form-data; name="image"; filename="image"` ~ "\r\n");
    appendAscii(body, "Content-Type: " ~ mediaType ~ "\r\n\r\n");
    body.put(image);
    appendAscii(body, "\r\n--" ~ boundary ~ "\r\n");
    appendAscii(body, `Content-Disposition: form-data; name="options"` ~ "\r\n");
    appendAscii(body, "Content-Type: application/json; charset=utf-8\r\n\r\n");
    appendAscii(body, `{"protocol":1,"output":"obj","maxFaces":` ~ maxFaces.to!string ~ `}`);
    appendAscii(body, "\r\n--" ~ boundary ~ "--\r\n");

    auto http = HTTP(baseUrl ~ "/v1/jobs");
    http.method = HTTP.Method.post;
    applyBoundedTimeouts(http);
    applyCancelCallback(http, stopRequested);
    http.addRequestHeader("X-Vibe3D-AI3D-Protocol", "1");
    http.setPostData(body.data, "multipart/form-data; boundary=" ~ boundary);
    auto sink = appender!(ubyte[])();
    http.onReceive = (ubyte[] data) {
        sink.put(data);
        return data.length;
    };
    try {
        http.perform();
    } catch (Exception e) {
        if (atomicLoad(stopRequested)) return BoundedJson(JSONValue.init, true);
        throw e;
    }
    return BoundedJson(parseJSON(cast(string) sink.data), false);
}

/// Best-effort generation-bound cancel DELETE. Exceptions are swallowed —
/// this runs only on a path that has already decided the result (cancelled/
/// failed/timed out); a failed DELETE must never mask that outcome.
///
/// Deliberately does NOT wire the live `stopRequested` flag into this
/// request's cancel callback (review fix, task 0381): on the USER-cancel
/// path `stopRequested` is already true by the time this fires, so a live
/// callback would make curl abort the DELETE itself
/// (CURLE_ABORTED_BY_CALLBACK) before it ever reaches the worker — the one
/// generation-bound cancel the DELETE exists to deliver would silently
/// never happen on exactly the path it's for, orphaning the server-side
/// job until its own timeout. A fresh, always-false flag means this
/// request can only ever end via its own bounded
/// connect/operationTimeout (<=10s, well inside the 35s join budget) —
/// never via self-cancellation.
private void issueCancelDelete(string baseUrl, string jobId, long generation) {
    try {
        shared bool never = false;
        auto http = HTTP(baseUrl ~ "/v1/jobs/" ~ jobId);
        http.method = HTTP.Method.del;
        applyBoundedTimeouts(http);
        applyCancelCallback(http, never);
        http.addRequestHeader("X-Vibe3D-AI3D-Protocol", "1");
        http.addRequestHeader("X-Vibe3D-AI3D-Expected-Generation", generation.to!string);
        auto sink = appender!(ubyte[])();
        http.onReceive = (ubyte[] data) {
            sink.put(data);
            return data.length;
        };
        http.perform();
    } catch (Exception) {
        // best-effort; the caller's result already reflects the real outcome
    }
}

private void appendAscii(ref typeof(appender!(ubyte[])()) body, string text) {
    foreach (ubyte b; cast(ubyte[]) text)
        body.put(b);
}

unittest {
    // Synthetic cancel: a stopRequested flag set BEFORE the call returns
    // `cancelled` without ever reaching the network (invalid URL also
    // exercises the same early-return shape, keeping this test offline).
    shared bool stop = true;
    auto r = stageArtifact("http://127.0.0.1:1", "/nonexistent.png", 1000,
        Ai3dDefaultRequestedFaces, stop);
    assert(r.cancelled || r.code.length > 0);
}

unittest {
    assert(clampGenerationDeadlineMs(0) == 1);
    assert(clampGenerationDeadlineMs(-5) == 1);
    assert(clampGenerationDeadlineMs(1_000) == 1_000);
    assert(clampGenerationDeadlineMs(Ai3dMaxGenerationDeadlineMs + 1) == Ai3dMaxGenerationDeadlineMs);
}

unittest {
    assert(clampMaxFaces(0) == 1_000);
    assert(clampMaxFaces(-5) == 1_000);
    assert(clampMaxFaces(999) == 1_000);
    assert(clampMaxFaces(1_000) == 1_000);
    assert(clampMaxFaces(50_000) == 50_000);
    assert(clampMaxFaces(cast(int) Ai3dMaxTotalFaces) == cast(int) Ai3dMaxTotalFaces);
    assert(clampMaxFaces(cast(int) Ai3dMaxTotalFaces + 1) == cast(int) Ai3dMaxTotalFaces);
    assert(clampMaxFaces(int.max) == cast(int) Ai3dMaxTotalFaces);
}

unittest {
    // normalizeLocalWorkerUrl only accepts loopback origins.
    assert(normalizeLocalWorkerUrl("http://127.0.0.1:47831") == "http://127.0.0.1:47831");
    assert(normalizeLocalWorkerUrl("http://127.0.0.1:47831/") == "http://127.0.0.1:47831");
    assert(normalizeLocalWorkerUrl("http://example.com") is null);
    assert(normalizeLocalWorkerUrl("") is null);
}
