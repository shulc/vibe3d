module main;

import command_invocation : CommandInvocationOutcome;
import vibe3d.documents.model.document : Document;
import vibe3d.util.log.log : g_stderrMinLevel, LogLevel;
import io.native : readV3d, writeV3d, lastV3dRejectReason;
import standalone_application : StandaloneApplication;
import std.conv : to;
import std.file : readText, exists, remove, rename, getcwd;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildPath, dirName, baseName;
import std.string : toStringz, fromStringz;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.stat : stat, stat_t;
import core.stdc.stdlib : free;
import std.process : thisProcessID;
import std.stdio : File, stdout, stderr;
import std.string : split, strip;

private struct Options { string input, commands, output, stateOutput; }

private string resolvedPath(string value) {
    auto spelling = absolutePath(value);
    auto resolved = realpath(spelling.toStringz, null);
    if (resolved !is null) {
        scope(exit) free(resolved);
        return resolved.fromStringz.idup;
    }
    auto parent = realpath(dirName(spelling).toStringz, null);
    if (parent is null) return spelling;
    scope(exit) free(parent);
    return buildPath(parent.fromStringz.idup, baseName(spelling));
}

private bool sameFile(string first, string second) {
    if (first == second) return true;
    stat_t a, b;
    return stat(first.toStringz, &a) == 0 && stat(second.toStringz, &b) == 0
        && a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

private Options options(string[] args) {
    if (args.length < 2 || args[1] != "run")
        throw new Exception("usage: vibe3d-cli run --input FILE --commands FILE --output FILE [--state-output FILE]");
    Options result;
    bool[string] seen;
    for (size_t i = 2; i < args.length; i += 2) {
        if (i + 1 == args.length || args[i + 1].length == 0 || args[i] in seen)
            throw new Exception("missing or duplicate option: " ~ args[i]);
        seen[args[i]] = true;
        switch (args[i]) {
            case "--input": result.input = resolvedPath(args[i + 1]); break;
            case "--commands": result.commands = resolvedPath(args[i + 1]); break;
            case "--output": result.output = resolvedPath(args[i + 1]); break;
            case "--state-output": result.stateOutput = resolvedPath(args[i + 1]); break;
            default: throw new Exception("unknown option: " ~ args[i]);
        }
    }
    if (!result.input.length || !result.commands.length || !result.output.length)
        throw new Exception("input, commands and output are required");
    if (result.stateOutput.length && (sameFile(result.stateOutput, result.input)
        || sameFile(result.stateOutput, result.commands) || sameFile(result.stateOutput, result.output)))
        throw new Exception("state-output must differ from input, commands and output");
    return result;
}

private void snapshot(ref File diagnostic, StandaloneApplication host,
        string phase, JSONValue line, JSONValue id, JSONValue outcome) {
    if (!diagnostic.isOpen) return;
    JSONValue row;
    row["phase"] = phase; row["line"] = line; row["id"] = id;
    row["outcome"] = outcome; row["state"] = host.state();
    diagnostic.writeln(row.toString());
    diagnostic.flush();
}

private void save(StandaloneApplication host, string output) {
    auto temporary = buildPath(dirName(output), "." ~ baseName(output)
        ~ ".vibe3d-cli-" ~ thisProcessID.to!string ~ ".tmp");
    if (exists(temporary)) throw new Exception("temporary output already exists");
    scope(exit) if (exists(temporary)) remove(temporary);
    if (!writeV3d(host.document, temporary)) throw new Exception("native writer refused output");
    Document reopened;
    if (!readV3d(temporary, reopened))
        throw new Exception("native output reopen failed: " ~ lastV3dRejectReason());
    rename(temporary, output);
}

int main(string[] args) {
    g_stderrMinLevel = LogLevel.Error;
    string stage = "arguments";
    JSONValue line, id;
    StandaloneApplication host;
    File diagnostic;
    scope(exit) if (host !is null) host.close();
    try {
        auto flags = options(args);
        stage = "load";
        Document loaded;
        if (!readV3d(flags.input, loaded))
            throw new Exception("native input rejected: " ~ lastV3dRejectReason());
        host = new StandaloneApplication(loaded);
        stage = "diagnostics";
        if (flags.stateOutput.length) diagnostic = File(flags.stateOutput, "w");
        snapshot(diagnostic, host, "loaded", JSONValue(0), JSONValue.init, JSONValue.init);
        stage = "script";
        auto script = readText(flags.commands);
        foreach (offset, physical; script.split("\n")) {
            if (!physical.strip.length) continue;
            line = JSONValue(offset + 1); id = JSONValue.init;
            JSONValue command;
            try {
                command = parseJSON(physical);
                if (command.type != JSONType.object || "id" !in command.object
                    || command["id"].type != JSONType.string)
                    throw new Exception("script row requires an object with string id");
                id = command["id"];
                stage = "command";
                auto params = "params" in command.object;
                auto result = host.invoke(id.str, params is null ? "" : params.toString());
                auto outcome = result.outcome.to!string;
                snapshot(diagnostic, host, "command", line, id, JSONValue(outcome));
                JSONValue row;
                row["line"] = line; row["id"] = id; row["outcome"] = outcome;
                stdout.writeln(row.toString()); stdout.flush();
                if (result.outcome == CommandInvocationOutcome.refused) {
                    stage = "refused";
                    throw new Exception(result.command.refusalReason().length
                        ? result.command.refusalReason() : "command refused");
                }
            } catch (Exception error) {
                if (stage != "refused") snapshot(diagnostic, host, "error", line, id, JSONValue.init);
                throw error;
            }
            stage = "script";
        }
        line = JSONValue.init; id = JSONValue.init;
        stage = "diagnostics";
        snapshot(diagnostic, host, "pre-save", line, id, JSONValue.init);
        stage = "save";
        save(host, flags.output);
        return 0;
    } catch (Exception error) {
        JSONValue row;
        row["error"] = error.msg; row["stage"] = stage;
        row["line"] = line; row["id"] = id;
        stderr.writeln(row.toString()); stderr.flush();
        return 1;
    }
}
