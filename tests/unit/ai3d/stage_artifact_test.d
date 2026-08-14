// Module unittests for `ai3d.stage_artifact`, moved verbatim out of source/ai3d/stage_artifact.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai3d.stage_artifact_test;

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
import ai3d.stage_artifact;

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
