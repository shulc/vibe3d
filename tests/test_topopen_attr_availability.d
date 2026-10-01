// Topology pen — attribute availability by mode (wave plan 8640 slice 8690,
// M-I / D16; captured law L16 and the earlier Fill capture quoted at the pen's
// `kFillRangeDefault` comment). Strength is writable only in Smoothing, Range
// and Quads Only only in Fill. A `tool.attr` write in another mode is REFUSED
// through both doors: the script door (`/api/command`) and the interactive
// door (`/api/script?interactive=true`) answer `status:error`, the value reads
// back unchanged and the history gains no row — the command no-op contract's
// refusal arm. A query (`… ?`) is never refused.
//
// Every attribute is driven positive half FIRST (the enabled mode writes:
// script door +0 rows, interactive door +1 row, L14), then the refusal, so one
// run proves the door is open before it proves it is shut.
// Rig and transport: tests/topology_pen_session_helpers.d.
//
// Run via: ./run_test.d test_topopen_attr_availability

import topology_pen_session_helpers;
import std.format : format;
import std.json;
import std.math : abs;
import std.path : buildPath, dirName;
import std.stdio : writeln;

void main() {}

PenRig rig() {
    return penRigLoad(buildPath(dirName(__FILE_FULL_PATH__), "fixtures",
                                "topology_pen_session_rig.v3d"));
}

/// One `tool.attr` line through a door; the whole response.
JSONValue attrWrite(string door, string attr, string value) {
    const path = door == "script" ? "/api/command" : "/api/script?interactive=true";
    return penPost(path, "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " " ~ value);
}

/// The attribute's current value through the query (which must answer).
JSONValue attrRead(string attr) {
    auto r = penPost("/api/command", "tool.attr " ~ kPenToolId ~ " " ~ attr ~ " ?");
    assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
    return r["value"];
}

double num(JSONValue v) {
    if (v.type == JSONType.float_)   return v.floating;
    if (v.type == JSONType.integer)  return cast(double) v.integer;
    if (v.type == JSONType.uinteger) return cast(double) v.uinteger;
    assert(false, "not a number: " ~ v.toString);
}

void setMode(string mode) {
    auto r = attrWrite("script", "mode", mode);
    assert(r["status"].str == "ok", "mode " ~ mode ~ " refused: " ~ r.toString);
}

/// A write that must land: value read back, history delta per door.
void expectLands(string what, string door, string attr, string value, string readBack,
                 long rows) {
    const h0 = penHistoryLen();
    auto r = attrWrite(door, attr, value);
    assert(r["status"].str == "ok",
           format("%s: the %s-door write %s %s was refused: %s", what, door, attr, value,
                  r.toString));
    assert(attrRead(attr).toString == readBack,
           format("%s: %s reads %s after the %s-door write, expected %s", what, attr,
                  attrRead(attr).toString, door, readBack));
    assert(penHistoryLen() == h0 + rows,
           format("%s: the %s-door write added %d rows, expected %d: %s", what, door,
                  penHistoryLen() - h0, rows, penHistoryLabels()));
}

/// A write that must be refused: status:error, value unchanged, no row.
void expectRefused(string what, string door, string attr, string value) {
    const before = attrRead(attr).toString;
    const h0 = penHistoryLen();
    auto r = attrWrite(door, attr, value);
    assert(attrRead(attr).toString == before,
           format("%s: the %s-door write changed %s to %s (was %s)", what, door, attr,
                  attrRead(attr).toString, before));
    assert(r["status"].str == "error",
           format("%s: the %s-door write %s %s answered %s, expected status:error", what,
                  door, attr, value, r.toString));
    assert(penHistoryLen() == h0,
           format("%s: the refused %s-door write added %d rows: %s", what, door,
                  penHistoryLen() - h0, penHistoryLabels()));
    assert(penArmed(), what ~ ": the refusal dropped the pen");
}

// ---------------------------------------------------------------------------
// strength-smooth, then strength-move and query-disabled (L16)
// ---------------------------------------------------------------------------
unittest {
    const r = rig();
    penArmUi(r);
    assert(penHistoryLen() == r.hp + 1, "strength rig: the arm is not one row");
    setMode("smooth");
    expectLands("strength-smooth", "script", "smoothStrength", "2", "2.0", 0);
    expectLands("strength-smooth", "interactive", "smoothStrength", "3", "3.0", 1);
    expectLands("strength-smooth", "script", "smoothStrength", "1", "1.0", 0);

    setMode("move");
    expectRefused("strength-move", "script", "smoothStrength", "2");
    expectRefused("strength-move", "interactive", "smoothStrength", "2");
    // query-disabled: a read in a mode that disables the row still answers.
    assert(abs(num(attrRead("smoothStrength")) - 1.0) < 1e-6,
           "query-disabled: Strength in Move answers " ~ attrRead("smoothStrength").toString);
    writeln("PASS strength-smooth / strength-move / query-disabled");
}

// ---------------------------------------------------------------------------
// range-fill / quadOnly-fill, then range-move / quadOnly-move
// ---------------------------------------------------------------------------
unittest {
    const r = rig();
    penArmUi(r);
    setMode("fill");
    expectLands("range-fill", "script", "range", "2.5", "2.5", 0);
    expectLands("range-fill", "interactive", "range", "1.5", "1.5", 1);
    expectLands("quadOnly-fill", "script", "quadOnly", "false", "false", 0);
    expectLands("quadOnly-fill", "interactive", "quadOnly", "true", "true", 1);

    setMode("move");
    expectRefused("range-move", "script", "range", "2.5");
    expectRefused("range-move", "interactive", "range", "2.5");
    expectRefused("quadOnly-move", "script", "quadOnly", "false");
    expectRefused("quadOnly-move", "interactive", "quadOnly", "false");
    // The modes that enable the OTHER attribute do not enable these.
    setMode("smooth");
    expectRefused("range-smooth", "script", "range", "2.5");
    setMode("move");
    writeln("PASS range-fill / range-move");
}
