#!/usr/bin/env rdmd
// Cross-backend image parity for the vibe3d render layer.
//
// Usage:
//   ./run.d                                 # all cases under cases/
//   ./run.d cube_red_sun                    # one case by stem
//   ./run.d cube_red_sun another_case       # subset
//   ./run.d --no-build                      # skip dub build
//   ./run.d --keep                          # leave the per-case PPMs in /tmp
//
// For each cases/<name>.json:
//   1. dub build --config=with-render (once, unless --no-build).
//   2. Run ./vibe3d --render-diff <case> --render-backend cycles → /tmp/<name>.cycles.ppm
//   3. Run ./vibe3d --render-diff <case> --render-backend rpr    → /tmp/<name>.rpr.ppm
//   4. Compute per-pixel mean squared error normalised to [0,1] and
//      compare to the case's `tolerance` field.
//
// Exit code: number of FAIL cases (after subtracting expected ones).

import std.algorithm : sort, canFind;
import std.array     : array, split;
import std.conv      : to;
import std.exception : enforce;
import std.file      : dirEntries, exists, mkdir, readText, SpanMode, write;
import std.format    : format;
import std.json      : parseJSON, JSONType;
import std.math      : sqrt;
import std.path      : absolutePath, baseName, buildPath, dirName, stripExtension;
import std.process   : execute, spawnProcess, wait;
import std.stdio     : File, writeln, writefln;
import std.string    : strip, splitLines, startsWith;
import std.range     : enumerate;

string repoRoot;
string toolDir;
string casesDir;
string outDir;

void log(string msg) { writeln("[run] ", msg); }

enum Status { PASS, FAIL, ERROR }

struct CaseResult
{
    string name;
    Status status;
    float  mse;        // mean squared error, normalised to [0,1]
    float  rms;        // sqrt of MSE; same units
    float  tolerance;
    string detail;
}

void main(string[] args)
{
    repoRoot = absolutePath(buildPath(__FILE_FULL_PATH__.dirName, "..", ".."));
    toolDir  = buildPath(repoRoot, "tools", "render_diff");
    casesDir = buildPath(toolDir, "cases");
    outDir   = "/tmp/vibe3d_render_diff";
    if (!exists(outDir)) mkdir(outDir);

    bool build = true;
    bool keep  = false;
    string[] requested;
    foreach (a; args[1 .. $]) {
        if (a == "--no-build") build = false;
        else if (a == "--keep")  keep  = true;
        else requested ~= a;
    }

    if (build) {
        log("dub build --config=with-render");
        auto r = execute(["dub", "build", "--config=with-render", "--root", repoRoot]);
        if (r.status != 0) {
            writeln(r.output);
            writefln("[run] dub build FAILED (exit %d)", r.status);
            import core.stdc.stdlib : exit;
            exit(1);
        }
    }

    string[] cases;
    foreach (e; dirEntries(casesDir, "*.json", SpanMode.shallow)) {
        const stem = e.name.baseName.stripExtension;
        if (requested.length == 0 || requested.canFind(stem))
            cases ~= e.name;
    }
    sort(cases);

    if (cases.length == 0) {
        log("no cases matched");
        return;
    }

    CaseResult[] results;
    foreach (casePath; cases) {
        results ~= runOne(casePath);
        if (!keep) {
            const stem = casePath.baseName.stripExtension;
            foreach (suffix; ["cycles.ppm", "rpr.ppm"]) {
                const p = buildPath(outDir, stem ~ "." ~ suffix);
                try { import std.file : remove; remove(p); } catch (Exception) {}
            }
        }
    }

    writeln("");
    writeln("=== render_diff summary ===");
    int passCount = 0, failCount = 0, errorCount = 0;
    foreach (r; results) {
        final switch (r.status) {
            case Status.PASS:  passCount++;  break;
            case Status.FAIL:  failCount++;  break;
            case Status.ERROR: errorCount++; break;
        }
        writefln("  %-40s  %-5s  rms=%.4f  (tol=%.4f)  %s",
                 r.name, r.status.to!string, r.rms, r.tolerance, r.detail);
    }
    writefln("Totals: PASS=%d  FAIL=%d  ERROR=%d  (of %d cases)",
             passCount, failCount, errorCount, results.length);

    import core.stdc.stdlib : exit;
    exit(failCount + errorCount);
}

CaseResult runOne(string casePath)
{
    const stem = casePath.baseName.stripExtension;
    CaseResult res;
    res.name = stem;
    res.tolerance = 0.05f;
    try {
        auto json = parseJSON(readText(casePath));
        if ("tolerance" in json) {
            auto t = json["tolerance"];
            res.tolerance = (t.type == JSONType.float_)
                ? cast(float)t.floating
                : cast(float)t.integer;
        }
    } catch (Exception e) {
        res.status = Status.ERROR;
        res.detail = "case parse: " ~ e.msg;
        return res;
    }

    const cyclesPpm = buildPath(outDir, stem ~ ".cycles.ppm");
    const rprPpm    = buildPath(outDir, stem ~ ".rpr.ppm");
    const vibe3dBin = buildPath(repoRoot, "vibe3d");

    foreach (pair; [["cycles", cyclesPpm], ["rpr", rprPpm]]) {
        log(format("%s: rendering with %s", stem, pair[0]));
        auto pid = spawnProcess([
            vibe3dBin,
            "--render-diff",   casePath,
            "--render-backend", pair[0],
            "--render-output",  pair[1],
        ]);
        const status = pid.wait();
        if (status != 0) {
            res.status = Status.ERROR;
            res.detail = format("%s exited %d", pair[0], status);
            return res;
        }
    }

    float mse;
    string diffErr;
    if (!comparePpm(cyclesPpm, rprPpm, mse, diffErr)) {
        res.status = Status.ERROR;
        res.detail = "diff: " ~ diffErr;
        return res;
    }
    res.mse = mse;
    res.rms = sqrt(mse);
    res.status = (res.rms <= res.tolerance) ? Status.PASS : Status.FAIL;
    return res;
}

/// Read two P6 PPMs and compute per-pixel mean squared error normalised
/// to [0,1]. Returns false on size mismatch or parse error.
bool comparePpm(string aPath, string bPath, out float mse, out string err)
{
    ubyte[] aPx; int aw, ah;
    ubyte[] bPx; int bw, bh;
    if (!readPpm(aPath, aPx, aw, ah, err)) return false;
    if (!readPpm(bPath, bPx, bw, bh, err)) return false;
    if (aw != bw || ah != bh) {
        err = format("size mismatch: %dx%d vs %dx%d", aw, ah, bw, bh);
        return false;
    }
    const size_t n = aPx.length;
    double sum = 0.0;
    foreach (i; 0 .. n) {
        const double diff = (cast(double)aPx[i] - cast(double)bPx[i]) / 255.0;
        sum += diff * diff;
    }
    mse = cast(float)(sum / n);
    return true;
}

bool readPpm(string path, out ubyte[] pixels, out int w, out int h, out string err)
{
    File f;
    try { f = File(path, "rb"); }
    catch (Exception e) { err = e.msg; return false; }

    // Header: "P6\n<W> <H>\n255\n". Whitespace is fairly forgiving.
    ubyte[1] one;
    string acc;
    int hdrTokens = 0;
    int wParsed = 0, hParsed = 0, maxParsed = 0;
    string buf;
    void flushToken() {
        if (buf.length == 0) return;
        if (hdrTokens == 0 && buf == "P6") {}
        else if (hdrTokens == 1) wParsed = buf.to!int;
        else if (hdrTokens == 2) hParsed = buf.to!int;
        else if (hdrTokens == 3) maxParsed = buf.to!int;
        hdrTokens++;
        buf = "";
    }
    while (hdrTokens < 4) {
        if (f.rawRead(one[]).length == 0) { err = "PPM header truncated"; return false; }
        char c = cast(char)one[0];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            flushToken();
        } else if (c == '#') {
            // skip comment to EOL
            while (f.rawRead(one[]).length > 0 && one[0] != '\n') { }
        } else {
            buf ~= c;
        }
    }
    if (maxParsed != 255) { err = format("PPM maxval=%d (expected 255)", maxParsed); return false; }
    w = wParsed;
    h = hParsed;
    const size_t need = cast(size_t)w * h * 3;
    pixels = new ubyte[need];
    auto got = f.rawRead(pixels);
    if (got.length != need) {
        err = format("PPM body truncated: got %d of %d bytes", got.length, need);
        return false;
    }
    return true;
}
