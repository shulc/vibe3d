#!/usr/bin/env rdmd
// Densifier for event-playback logs. Reads a log on stdin, writes one with
// extra interpolated SDL_MOUSEMOTION events between each pair of motion
// events (only when both have the same `state` flag, so we don't smear across
// mouseDown/Up boundaries). Cuts the per-step pixel delta roughly in half so
// drag-selection picks reliably hit small (4-8px) edge/vert pick zones.
//
// Usage:  rdmd densify.d < input.log > output.log
module densify;

import std.array  : split;
import std.conv   : to;
import std.format : format;
import std.json   : parseJSON, JSONValue, JSONType;
import std.stdio  : File, stdin, writeln, writefln;
import std.string : strip, indexOf, startsWith;

// Hand-rendered numeric writer to avoid scientific notation and extra
// trailing zeros from JSONValue's default formatter.
string fmtTime(double t) {
    return format("%.3f", t);
}

void writeMotion(double t, int x, int y, int xrel, int yrel, int state, int mod) {
    writefln(`{"t":%s,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%d,"mod":%d}`,
        fmtTime(t), x, y, xrel, yrel, state, mod);
}

struct Motion { double t; int x, y, xrel, yrel, state, mod; bool valid; }

Motion parseMotion(string line) {
    auto j = parseJSON(line);
    if (j["type"].str != "SDL_MOUSEMOTION") return Motion(0, 0, 0, 0, 0, 0, 0, false);
    Motion m;
    m.valid = true;
    m.t     = j["t"].type == JSONType.float_ ? j["t"].floating : cast(double)j["t"].integer;
    m.x     = cast(int)j["x"].integer;
    m.y     = cast(int)j["y"].integer;
    m.xrel  = cast(int)(("xrel" in j) ? j["xrel"].integer : 0);
    m.yrel  = cast(int)(("yrel" in j) ? j["yrel"].integer : 0);
    m.state = cast(int)(("state" in j) ? j["state"].integer : 0);
    m.mod   = cast(int)(("mod" in j) ? j["mod"].integer : 0);
    return m;
}

void main() {
    string[] lines;
    string ln;
    while (!stdin.eof) {
        ln = stdin.readln();
        if (ln.length == 0) break;
        lines ~= ln.strip();
    }

    Motion prev;
    foreach (i, line; lines) {
        if (line.length == 0) { writeln(line); continue; }
        Motion cur = parseMotion(line);
        if (cur.valid && prev.valid && cur.state == prev.state && cur.mod == prev.mod) {
            // Insert one interpolated midpoint between prev and cur.
            int midX = (prev.x + cur.x) / 2;
            int midY = (prev.y + cur.y) / 2;
            double midT = (prev.t + cur.t) / 2.0;
            int dxA = midX - prev.x, dyA = midY - prev.y;
            writeMotion(midT, midX, midY, dxA, dyA, cur.state, cur.mod);
            // Adjust cur's xrel/yrel to be relative to the midpoint.
            int dxB = cur.x - midX, dyB = cur.y - midY;
            writeMotion(cur.t, cur.x, cur.y, dxB, dyB, cur.state, cur.mod);
        } else {
            writeln(line);
        }
        if (cur.valid) prev = cur;
        else if (line.indexOf("MOUSEBUTTON") < 0) {
            // Non-motion non-button line: keep prev for the next motion to chain
            // off — but we DO want chains to break across MOUSEBUTTONDOWN/UP so
            // we don't densify pre-drag movement into the drag.
        } else {
            prev.valid = false;
        }
    }
}
