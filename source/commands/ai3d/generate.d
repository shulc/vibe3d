module commands.ai3d.generate;

import std.array : appender;
import std.conv : to;
import std.digest.sha : sha256Of, toHexString;
import std.file : read, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.net.curl : HTTP;
import std.path : buildPath, extension;
import std.string : startsWith, toLower;
import std.uuid : randomUUID;
import core.thread : Thread;
import core.time : msecs;

import command;
import commands.ai3d.import_result : Ai3dImportResult;
import document : Document;
import editmode;
import mesh;
import params : Param;
import view;
import viewcache;

final class Ai3dGenerate : Command {
    private Document* doc;
    private GpuMesh* gpu;
    private VertexCache* vc;
    private EdgeCache* ec;
    private FaceBoundsCache* fc;
    private void delegate(size_t prev, size_t next) onSwitch;

    private string imageArg;
    private string workerUrlArg = "http://127.0.0.1:47831";
    private string nameArg;
    private int timeoutMsArg = 120_000;
    private Ai3dImportResult importer;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode);
        this.doc = doc;
        this.gpu = gpu;
        this.vc = vc;
        this.ec = ec;
        this.fc = fc;
        this.onSwitch = onSwitch;
    }

    override string name() const { return "ai3d.generate"; }
    override string label() const { return "Generate AI 3D"; }

    override Param[] params() {
        return [
            Param.string_("image", "Image", &imageArg, ""),
            Param.string_("workerUrl", "Worker URL", &workerUrlArg, "http://127.0.0.1:47831"),
            Param.string_("name", "Name", &nameArg, ""),
            Param.int_("timeoutMs", "Timeout (ms)", &timeoutMsArg, 120_000),
        ];
    }

    override bool apply() {
        if (imageArg.length == 0) return false;
        const baseUrl = normalizeLocalWorkerUrl(workerUrlArg);
        if (baseUrl.length == 0) return false;

        try {
            auto artifactPath = requestArtifact(baseUrl, imageArg, timeoutMsArg);
            importer = new Ai3dImportResult(mesh, view, editMode, doc, gpu, vc, ec, fc, onSwitch);
            importer.setInput(artifactPath, nameArg);
            return importer.apply();
        } catch (Exception) {
            return false;
        }
    }

    override bool revert() {
        if (importer is null) return false;
        return importer.revert();
    }
}

private string normalizeLocalWorkerUrl(string raw) {
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

private string requestArtifact(string baseUrl, string imagePath, int timeoutMs) {
    healthCheck(baseUrl);
    auto created = createJob(baseUrl, imagePath);
    const jobId = created["jobId"].str;
    const generation = created["generation"].integer.to!long;

    JSONValue status;
    int waited;
    while (waited <= timeoutMs) {
        status = getJson(baseUrl ~ "/v1/jobs/" ~ jobId,
            [Header("X-Vibe3D-AI3D-Protocol", "1")]);
        const state = status["state"].str;
        if (state == "succeeded")
            break;
        if (state == "failed" || state == "cancelled")
            throw new Exception("AI3D job did not succeed");
        Thread.sleep(250.msecs);
        waited += 250;
    }
    if (waited > timeoutMs)
        throw new Exception("AI3D job timed out");

    const artifact = status["artifact"];
    if (artifact["generation"].integer.to!long != generation)
        throw new Exception("AI3D generation mismatch");
    const bytesExpected = artifact["bytes"].integer.to!ulong;
    const shaExpected = artifact["sha256"].str;
    const artifactUrl = sameOriginArtifactUrl(baseUrl, artifact["url"].str);
    auto data = getBytes(artifactUrl, [
        Header("X-Vibe3D-AI3D-Protocol", "1"),
        Header("X-Vibe3D-AI3D-Expected-Generation", generation.to!string),
    ]);
    if (data.length != bytesExpected)
        throw new Exception("AI3D artifact byte length mismatch");
    const gotSha = sha256Of(data).toHexString().idup.toLower;
    if (gotSha != shaExpected.toLower)
        throw new Exception("AI3D artifact sha256 mismatch");

    const outPath = buildPath(tempRoot(), "vibe3d-ai3d-" ~ jobId ~ ".obj");
    write(outPath, data);
    return outPath;
}

private void healthCheck(string baseUrl) {
    auto health = getJson(baseUrl ~ "/v1/health", null);
    if (health["protocol"].integer != 1)
        throw new Exception("AI3D protocol mismatch");
    if (health["ready"].type != JSONType.true_)
        throw new Exception("AI3D worker is not ready");
}

private JSONValue createJob(string baseUrl, string imagePath) {
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
    appendAscii(body, `{"protocol":1,"output":"obj","maxFaces":50000}`);
    appendAscii(body, "\r\n--" ~ boundary ~ "--\r\n");

    return postBytesJson(baseUrl ~ "/v1/jobs", body.data, [
        Header("X-Vibe3D-AI3D-Protocol", "1"),
        Header("Content-Type", "multipart/form-data; boundary=" ~ boundary),
    ]);
}

private string imageMediaType(string path) {
    const ext = extension(path).toLower;
    if (ext == ".png") return "image/png";
    if (ext == ".jpg" || ext == ".jpeg") return "image/jpeg";
    if (ext == ".webp") return "image/webp";
    return null;
}

private struct Header {
    string name;
    string value;
}

private JSONValue getJson(string url, Header[] headers) {
    auto data = getBytes(url, headers);
    return parseJSON(cast(string) data);
}

private JSONValue postBytesJson(string url, const(ubyte)[] body, Header[] headers) {
    auto http = HTTP(url);
    http.method = HTTP.Method.post;
    foreach (h; headers)
        http.addRequestHeader(h.name, h.value);
    http.postData = cast(string) body;
    auto sink = appender!(ubyte[])();
    http.onReceive = (ubyte[] data) {
        sink.put(data);
        return data.length;
    };
    http.perform();
    return parseJSON(cast(string) sink.data);
}

private ubyte[] getBytes(string url, Header[] headers) {
    auto http = HTTP(url);
    http.method = HTTP.Method.get;
    if (headers !is null)
        foreach (h; headers)
            http.addRequestHeader(h.name, h.value);
    auto sink = appender!(ubyte[])();
    http.onReceive = (ubyte[] data) {
        sink.put(data);
        return data.length;
    };
    http.perform();
    return sink.data;
}

private void appendAscii(ref typeof(appender!(ubyte[])()) body, string text) {
    foreach (ubyte b; cast(ubyte[]) text)
        body.put(b);
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
