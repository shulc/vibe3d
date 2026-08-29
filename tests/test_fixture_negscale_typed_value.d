// Task 3023 — a TYPED negative scale value while the negative-scale option is
// OFF: what the reference does, and which of our two write paths implements it.
//
// THE LAW, measured 2026-08-29 and frozen in
// tests/fixtures/scale_negative_typed_value.json:
//
//     a numeric ("typed") write of a scale AXIS is ACCEPTED and stores
//     max(0, value) while the negative-scale option is off, and stores the
//     value verbatim while it is on. Non-scale attributes are stored verbatim
//     at either option state.
//
// It is ACCEPTED, not refused: the reference reports success and then keeps
// zero. The prior value in every cell is deliberately 2.5 rather than the 1.0
// default, so "refuses and leaves the previous value" would have read back 2.5
// and is refuted rather than merely unlikely. The reference's own shipped
// documentation states the OPPOSITE on eight pages ("when disabled, you can
// always input negative values in any of the input fields directly"); the
// measurement is what this file pins.
//
// WHY A TYPED VALUE AND NOT A DRAG. A handle drag is clipped on its own layer
// by a separate copy of the same rule, so under a drag every candidate law
// predicts the same geometry and the rig would be measuring its own assumption.
// The typed field is the only input that separates them.
//
// WHY THE FIXTURE'S REFERENCE COLUMN IS A STORED VALUE AND NOT A COORDINATE.
// Two reasons, and both are in the fixture's own provenance notes. (1) One
// refuted candidate — "clamps to the smallest positive representable value" —
// is indistinguishable from the selected one in GEOMETRY at any usable
// tolerance; only a value readback separates them. (2) The reference's numeric
// apply does not commit without a viewport, so no vertex coordinate in that
// file could have been a reference measurement. This test derives the expected
// coordinate from `reference.stored` in one visible line (`expectedX` below),
// which is sound because the option is consumed at the write and the apply path
// provably never reads it.
//
// WHAT THIS FILE ASSERTS, AND HOW EACH HALF CAN REDDEN:
//
//   1. Every case's SESSION path (tool.beginSession, then a numeric attr write)
//      reproduces the reference law. Breaking the floor in the session path —
//      e.g. dropping the `if (!negScale)` guard in applyScaleAbsoluteFromRun —
//      reddens `neg_off_typed_minus3` / `neg_off_typed_minus_075` here.
//   2. Every case's NUMERIC path (a bare attr write plus doApply) reproduces
//      the number recorded in `vibe3d_current.numeric`. That path currently
//      SKIPS the floor, which is a known open gap; the fixture records it per
//      case as `matches_reference: false` and this test checks the gap is still
//      exactly that wide. Closing it — i.e. fixing the numeric path — reddens
//      item 3 with "the declared divergence has closed", which is the signal to
//      re-freeze the fixture rather than a regression.
//   3. The fixture's own frozen numbers obey the stated law. `reference.stored`
//      and every row of `reference_readbacks` are recomputed from
//      `(negScale, typed value, is-this-a-scale-axis)` and must match, so a
//      hand-edit that quietly moves a captured number away from the law it is
//      supposed to embody cannot pass unnoticed.
//   4. Our SHIPPED default for the option is OFF — driven with no option write
//      at all, so a changed default reddens something instead of being prose.
//      The reference's default is ON; that divergence is a decided product
//      choice (task 0332), recorded in the fixture, not asserted here.
//
// No reference-editor name appears in this file; the routine names and
// addresses behind the law live in the private capture card.

import std.net.curl;
import std.json;
import std.math : fabs, isFinite;
import std.conv : to;
import std.format : format;
import fixture_helpers : requireProvenance;

void main() {}

enum baseUrl = "http://localhost:8080";

private JSONValue getJson(string p) { return parseJSON(cast(string) get(baseUrl ~ p)); }
private JSONValue postJson(string p, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ p, body_));
}

private void cmd(string s, string ctx) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        format("%s: command `%s` failed: %s", ctx, s, j.toString));
}

private void reset(string ctx) {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", format("%s: reset failed: %s", ctx, r.toString));
}

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:    return v.floating;
        case JSONType.integer:   return cast(double) v.integer;
        case JSONType.uinteger:  return cast(double) v.uinteger;
        case JSONType.true_:     return 1.0;
        case JSONType.false_:    return 0.0;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

/// x of vertex 0 of the active mesh.
private double vertex0X() {
    auto verts = getJson("/api/model")["vertices"].array;
    assert(verts.length >= 1, "no vertices in /api/model");
    return num(verts[0].array[0]);
}

// The law, as a function, so the fixture's frozen numbers can be checked
// against it (assertion 3) instead of merely being read out.
private double storedByLaw(bool scaleAxis, long negScale, double typed) {
    if (!scaleAxis || negScale != 0) return typed;
    return typed < 0.0 ? 0.0 : typed;
}

// The two write paths, both driving a numeric ("typed") value. `pre` is written
// first and is part of the operation, not the stand: it is what makes "refuses
// and keeps the previous value" a separable candidate.
private double driveNumeric(string tool, string attr, JSONValue negScale,
                            double pre, double typed, string ctx) {
    reset(ctx);
    cmd(format("tool.set %s on", tool), ctx);
    if (!negScale.isNull)
        cmd(format("tool.attr %s negScale %d", tool, negScale.integer), ctx);
    cmd(format("tool.attr %s %s %.9g", tool, attr, pre), ctx);
    cmd(format("tool.attr %s %s %.9g", tool, attr, typed), ctx);
    cmd("tool.doApply", ctx);
    immutable x = vertex0X();
    cmd(format("tool.set %s off", tool), ctx);
    return x;
}

private double driveSession(string tool, string attr, JSONValue negScale,
                            double pre, double typed, string ctx) {
    reset(ctx);
    cmd(format("tool.set %s on", tool), ctx);
    if (!negScale.isNull)
        cmd(format("tool.attr %s negScale %d", tool, negScale.integer), ctx);
    cmd("tool.beginSession", ctx);
    cmd(format("tool.attr %s %s %.9g", tool, attr, pre), ctx);
    cmd(format("tool.attr %s %s %.9g", tool, attr, typed), ctx);
    immutable x = vertex0X();
    cmd(format("tool.set %s off", tool), ctx);
    return x;
}

unittest {
    enum string json = import("fixtures/scale_negative_typed_value.json");
    auto fx = parseJSON(json);
    immutable string suite = fx["name"].str;
    requireProvenance(fx, suite);

    immutable double tol = ("tolerance" in fx) ? num(fx["tolerance"]) : 1e-4;

    // ---- 3. the fixture's own frozen numbers obey the stated law -----------
    // Runs FIRST and needs no server: a fixture whose captured values have
    // drifted away from the law they encode should say so before any driving
    // happens, not after a confusing geometry mismatch.
    size_t lawRows = 0;
    foreach (row; fx["reference_readbacks"].array) {
        immutable string a = row["attr"].str;
        immutable bool scaleAxis = (a == "SX" || a == "SY" || a == "SZ");
        immutable double typed = num(row["typed"]);
        immutable long neg = row["negScale"].integer;
        immutable double want = storedByLaw(scaleAxis, neg, typed);
        immutable double got  = num(row["stored"]);
        assert(fabs(got - want) <= tol, format(
            "%s: reference_readbacks row (attr %s, negScale %d, typed %.9g) records "
            ~ "stored %.9g, but the law this fixture states produces %.9g. Either the "
            ~ "row was edited away from what was measured, or the law statement is "
            ~ "wrong -- both need a re-capture, not a tolerance.",
            suite, a, neg, typed, got, want));
        assert(row["accepted"].boolean, format(
            "%s: reference_readbacks row (attr %s, typed %.9g) records accepted=false; "
            ~ "the measured law is ACCEPT-then-floor, and a refusal is a different law",
            suite, a, typed));
        lawRows++;
    }
    assert(lawRows >= 8, format(
        "%s: only %d reference_readbacks rows -- this check is the one that keeps the "
        ~ "frozen numbers honest and it must not be able to pass over an empty list",
        suite, lawRows));

    // The corpus must actually contain a cell on each side of the option, or
    // items 1 and 2 below are testing one branch and calling it a law.
    size_t negOffNegativeCells = 0, negOnNegativeCells = 0, divergentCells = 0;

    foreach (cs; fx["cases"].array) {
        immutable string cn   = suite ~ "/" ~ cs["name"].str;
        immutable string tool = cs["tool"].str;
        immutable string attr = cs["attr"].str;
        immutable string kind = cs["kind"].str;
        immutable long   neg  = cs["negScale"].integer;
        immutable double pre  = num(cs["pre_value"]);
        immutable double typed= num(cs["typed_value"]);
        immutable double stored = num(cs["reference"]["stored"]);

        assert(cs["reference"]["accepted"].boolean, format(
            "%s: the reference ACCEPTED every write in this capture; a case recording "
            ~ "a refusal belongs to a different law", cn));

        // The one derivation in this file, spelled out: the reference column is
        // a stored attribute value, and this turns it into the coordinate our
        // engine can be asked for. Sound because the option is consumed at the
        // write, never on the apply path.
        reset(cn);
        immutable double baseX = vertex0X();
        immutable double expectedX =
            (kind == "scale") ? baseX * stored : baseX + stored;
        assert(isFinite(expectedX), format("%s: derived expectation is not finite", cn));

        if (typed < 0.0) { if (neg == 0) negOffNegativeCells++; else negOnNegativeCells++; }

        auto negJson = JSONValue(neg);

        foreach (pathName; ["numeric", "session"]) {
            immutable double got = (pathName == "numeric")
                ? driveNumeric(tool, attr, negJson, pre, typed, cn)
                : driveSession(tool, attr, negJson, pre, typed, cn);

            auto rec = cs["vibe3d_current"][pathName];
            immutable double frozen = num(rec["vertex0_x"]);
            immutable bool  matches = rec["matches_reference"].boolean;

            // ---- 2. our current behaviour is pinned exactly ---------------
            assert(fabs(got - frozen) <= tol, format(
                "%s [%s path]: vertex0.x is %.6f, but this build was frozen at %.6f "
                ~ "(tol %.1e). Our own behaviour on this path moved; if that was "
                ~ "deliberate, re-freeze the fixture and say why.",
                cn, pathName, got, frozen, tol));

            if (matches) {
                // ---- 1. the path implements the measured law --------------
                assert(fabs(got - expectedX) <= tol, format(
                    "%s [%s path]: vertex0.x is %.6f, but the reference law "
                    ~ "(negScale=%d, typed %.9g -> stored %.9g, base.x %.6f) requires "
                    ~ "%.6f (tol %.1e). This path is recorded as MATCHING the "
                    ~ "reference, so this is a parity regression.",
                    cn, pathName, got, neg, typed, stored, baseX, expectedX, tol));
            } else {
                // The declared gap must still be exactly a gap. This arm is
                // what reddens when somebody CLOSES the divergence.
                divergentCells++;
                assert(fabs(got - expectedX) > tol, format(
                    "%s [%s path]: vertex0.x is %.6f, which now AGREES with the "
                    ~ "reference law's %.6f -- the divergence this fixture declares "
                    ~ "(vibe3d_current.%s.matches_reference == false) has CLOSED. "
                    ~ "That is good news, not a bug: set matches_reference to true, "
                    ~ "re-freeze vertex0_x, and note the fix.",
                    cn, pathName, got, expectedX, pathName));
            }
        }
    }

    // ---- anti-vacuity: the corpus must span the option -----------------
    assert(negOffNegativeCells >= 2 && negOnNegativeCells >= 1, format(
        "%s: the corpus has %d negative-value cells with the option OFF and %d with it "
        ~ "ON. Without at least one of each, every assertion above is satisfied by a "
        ~ "law that ignores the option entirely.",
        suite, negOffNegativeCells, negOnNegativeCells));
    assert(divergentCells >= 1, format(
        "%s: no case is marked as diverging, so the divergence arm of this test never "
        ~ "ran. If the numeric path has genuinely been fixed everywhere, this file "
        ~ "should become a plain parity fixture and this guard should go with it.",
        suite));

    // ---- 4. our shipped default for the option is OFF ------------------
    // No option value is written at all; the absence is the parameter under
    // test. The session path floors iff the default is OFF.
    {
        auto dc = fx["default_case"];
        immutable string cn = suite ~ "/" ~ dc["name"].str;
        auto none = JSONValue(null);
        immutable double gotS = driveSession(dc["tool"].str, dc["attr"].str, none,
                                             num(dc["pre_value"]), num(dc["typed_value"]), cn);
        immutable double gotN = driveNumeric(dc["tool"].str, dc["attr"].str, none,
                                             num(dc["pre_value"]), num(dc["typed_value"]), cn);
        immutable double wantS = num(dc["vibe3d_current"]["session"]["vertex0_x"]);
        immutable double wantN = num(dc["vibe3d_current"]["numeric"]["vertex0_x"]);
        assert(fabs(gotS - wantS) <= tol, format(
            "%s [session path, no negScale written]: vertex0.x is %.6f, expected %.6f. "
            ~ "The session path floors iff our shipped default for the option is OFF, "
            ~ "so this is where a changed default shows up. The reference ships it ON "
            ~ "(fixture reference_defaults); ours is OFF by the task-0332 decision.",
            cn, gotS, wantS));
        assert(fabs(gotN - wantN) <= tol, format(
            "%s [numeric path, no negScale written]: vertex0.x is %.6f, expected %.6f",
            cn, gotN, wantN));
    }
}
