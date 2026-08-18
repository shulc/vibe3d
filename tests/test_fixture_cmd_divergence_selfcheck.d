// Task 1130 -- does runCommandDivergenceSuite actually BITE?
//
// A divergence fixture is a green test that describes a disagreement. That
// shape has one characteristic failure mode, and it is the expensive one: a
// suite that measures nothing passes forever and reads, to everyone after,
// like evidence. This file removes the doubt by VALUE rather than by
// argument -- it feeds the runner deliberately corrupted copies of the real
// fixtures and asserts that each corruption is REJECTED.
//
// Five mutations, one per guard the runner claims to have:
//
//   1. drop a declared divergence entry      -> "the divergence MOVED"
//   2. flip one recorded `applied` outcome   -> the regression pin on us
//   3. corrupt a recorded vertex of ours     -> the same pin, geometry side
//   4. declare a divergent case a CONTROL    -> the control guard
//   5. make reference == ours, no divergence -> the anti-vacuity guard
//   6. strip the provenance block            -> requireProvenance
//   7. name an UNMEASURED dimension a control -> the inert-control guard
//   8. delete the operation itself           -> a case that passes without
//                                               its own op measures nothing
//   9. swap the two engines' recorded halves -> a case that passes with the
//                                               sides exchanged measures
//                                               nothing either
//  10. widen a CLOSED gap by one element     -> a ported law's EMPTY gap must
//                                               be asserted as strictly as a
//                                               full one
//  11. drop a whole block's `selection`      -> a full-coverage control list
//                                               must catch the dimension going
//                                               UNMEASURED, which is exactly
//                                               what `control: true` cannot
//
// If any mutation ever passes, the corresponding guard has gone inert and the
// fixtures that lean on it are no longer evidence -- which is precisely the
// thing this file exists to detect before someone trusts them.

import fixture_helpers;
import std.json;
import std.format : format;

void main() {}

// Run the suite over `fx` and report whether it REJECTED the input. Assert
// failures arrive as Errors, so Throwable is the correct net here.
private bool rejected(JSONValue fx) {
    try {
        runCommandDivergenceSuite(fx.toString);
        return false;
    } catch (Throwable) {
        return true;
    }
}

// One case, lifted out of a real fixture, so every mutant still runs against
// the live engine exactly as the real suite does.
private JSONValue oneCase(string json, size_t idx) {
    auto fx = parseJSON(json);
    auto cs = fx["cases"].array[idx];
    fx["cases"] = JSONValue([cs]);
    return fx;
}

unittest {
    enum string selJson  = import("fixtures/cmd_selection_product.json");
    enum string joinJson = import("fixtures/vert_join_survivor.json");

    // The carrier for every arm that needs a GENUINELY DIVERGENT case is now
    // SYNTHETIC, and that is the point of this block.
    //
    // It used to borrow a live divergence: first `spin_gate_narrower` case 0,
    // then — when task 1200 ported that gate — `vert_join_survivor` case 0.
    // Task 1210 then ported THAT law too (ledger row 11), and this file went
    // red for the third time. Each re-point also risked something worse than
    // red: an arm whose carrier has quietly closed still PASSES, while no
    // longer proving its guard.
    //
    // The dependency was wrong in principle. This file tests the RUNNER, not
    // any particular parity claim, so borrowing a real gap couples it to
    // porting work that will keep closing gaps — as it should.
    //
    // So: take a real, currently-AGREEING case and manufacture a gap by moving
    // ONE reference vertex to a coordinate the mesh does not contain, then
    // declare exactly that gap. The case is divergent by construction and no
    // future port can close it.
    //
    // The reference block below is therefore NOT a measurement, and must never
    // be read as one. Nothing outside this file consumes it.
    //
    // The unmutated case must PASS — otherwise every "rejected" below could be
    // an artefact of the construction rather than of the mutation.
    enum size_t DIVERGENT = 0;              // vert_join_survivor/forward_order_diverges

    static JSONValue synthDivergent(string json, size_t idx) {
        auto fx = oneCase(json, idx);
        auto cs = fx["cases"].array[0];
        auto rv = cs["reference"]["vertices"].array;
        // A coordinate no case mesh contains, so the gap is unambiguous.
        auto moved = JSONValue([JSONValue(9.0), JSONValue(0.0), JSONValue(9.0)]);
        auto gone  = rv[0];
        rv[0] = moved;
        cs["reference"]["vertices"] = JSONValue(rv);
        cs["divergence"] = JSONValue([
            "vertices_only_in_reference": JSONValue([moved]),
            "vertices_only_in_vibe3d":    JSONValue([gone]),
        ]);
        cs.object.remove("control");   // a declared gap and a whole-case control are exclusive
        fx["cases"] = JSONValue([cs]);
        return fx;
    }
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        runCommandDivergenceSuite(fx.toString);
    }

    // 1. drop a declared divergence entry: the recomputed gap now exceeds the
    //    declaration, which is what a QUIETLY WIDENED divergence looks like.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        auto dv = fx["cases"].array[0]["divergence"];
        string victim;
        foreach (k, _; dv.object) { victim = k; break; }
        assert(victim.length, "fixture case declares no divergence at all");
        dv.object.remove(victim);
        fx["cases"].array[0]["divergence"] = dv;
        assert(rejected(fx),
            format("dropping divergence.%s was ACCEPTED — the gap check is inert",
                   victim));
    }

    // 2. flip a recorded op outcome: the pin on our own behaviour.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        auto cur = fx["cases"].array[0]["vibe3d_current"];
        auto ap  = cur["applied"].array.dup;
        ap[$ - 1] = JSONValue(!(ap[$ - 1].type == JSONType.true_));
        cur["applied"] = JSONValue(ap);
        fx["cases"].array[0]["vibe3d_current"] = cur;
        assert(rejected(fx),
            "flipping a recorded `applied` outcome was ACCEPTED — the "
            ~ "regression pin on our own behaviour is inert");
    }

    // 3. corrupt one of OUR recorded vertices: same pin, geometry side.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        auto cur = fx["cases"].array[0]["vibe3d_current"];
        auto vs  = cur["vertices"].array.dup;
        assert(vs.length, "case records no vertices of ours");
        vs[0] = JSONValue([JSONValue(99.0), JSONValue(99.0), JSONValue(99.0)]);
        cur["vertices"] = JSONValue(vs);
        fx["cases"].array[0]["vibe3d_current"] = cur;
        assert(rejected(fx),
            "a fabricated vertex in `vibe3d_current` was ACCEPTED — our own "
            ~ "output is not being checked");
    }

    // 4. declare a genuinely divergent case a whole-case CONTROL. A control
    //    that has acquired a divergence is a finding, and must be loud.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        fx["cases"].array[0].object["control"] = JSONValue(true);
        assert(rejected(fx),
            "a divergent case marked `control: true` was ACCEPTED — the "
            ~ "control guard is inert");
    }

    // 4b. the SCOPED control, on a case that still has a PARTIAL one: name a
    //     dimension that genuinely disagrees there and it must be rejected,
    //     while its declared geometry control keeps passing.
    //
    //     TASK 1180 re-pointed this arm. It used to run on
    //     cmd_selection_product's control case, whose selection genuinely
    //     disagreed; that law has since been PORTED, so nothing disagrees
    //     there any more and the arm would have gone quietly inert — passing
    //     on the anti-vacuity guard while claiming to prove the control one.
    //     vert_join_survivor case 1 is the same shape and still diverges: a
    //     geometry control beside a live `sel_vertices` gap.
    {
        auto fx = oneCase(joinJson, 1);         // reversed_order_is_the_control
        assert("control" in fx["cases"].array[0],
            "case 1 of vert_join_survivor is expected to be the control");
        runCommandDivergenceSuite(fx.toString); // as authored: passes
        fx["cases"].array[0]["control"] =
            JSONValue([JSONValue("sel_vertices"), JSONValue("counts")]);
        assert(rejected(fx),
            "declaring the SELECTION a control on the geometry-control case "
            ~ "was ACCEPTED — scoped controls are inert");
    }

    // 5. anti-vacuity: make the reference agree with us in every dimension and
    //    declare no gap. Nothing is wrong per-dimension; what is wrong is that
    //    the case now asserts nothing about any disagreement.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        auto cs = fx["cases"].array[0];
        cs["reference"] = cs["vibe3d_current"];
        cs["divergence"] = JSONValue(cast(JSONValue[string]) null);
        fx["cases"].array[0] = cs;
        assert(rejected(fx),
            "a case with no divergence in any dimension was ACCEPTED — the "
            ~ "anti-vacuity guard is inert, and a parity test could ship here "
            ~ "wearing a divergence fixture's name");
    }

    // 7. a control over a dimension NOBODY MEASURES. Nothing disagrees --
    //    nothing is looked at either, and a control that cannot fail is worse
    //    than no control, because it reads like evidence. (Unlike 4b this arm
    //    survives task 1180 untouched: it needs an unmeasured dimension, not a
    //    divergent one, and `materials` is unmeasured whether the case's gap is
    //    open or closed.)
    {
        auto fx = oneCase(selJson, 1);
        fx["cases"].array[0]["control"] = JSONValue([JSONValue("materials")]);
        assert(rejected(fx),
            "a control over a dimension neither block measures was ACCEPTED — "
            ~ "an inert control can be declared and will never fail");
    }

    // 8. delete the OPERATION. If a case still passes with its own command
    //    removed, the command is not what it is measuring.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        auto cs = fx["cases"].array[0];
        JSONValue[] kept;
        foreach (st; cs["op"].array)
            if ("select" in st) kept ~= st;      // keep the setup, drop the command
        assert(kept.length < cs["op"].array.length, "case has no command to drop");
        cs["op"] = JSONValue(kept);
        fx["cases"].array[0] = cs;
        assert(rejected(fx),
            "a case still passed with its own OPERATION removed — whatever it "
            ~ "is measuring, it is not the command");
    }

    // 9. swap the two engines. A case that passes with the sides exchanged is
    //    not describing a direction of disagreement, only the fact of one.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        auto cs = fx["cases"].array[0];
        auto r = cs["reference"], v = cs["vibe3d_current"];
        cs["reference"] = v;
        cs["vibe3d_current"] = r;
        fx["cases"].array[0] = cs;
        assert(rejected(fx),
            "a case passed with the two engines' recorded halves SWAPPED — it "
            ~ "does not pin which side does what");
    }

    // 10. a CLOSED gap must be asserted as strictly as an open one. Task 1180
    //     ported the selection-product law, so every case of
    //     cmd_selection_product now declares an EMPTY gap by naming every
    //     measured dimension a control. Widen one by a single element on the
    //     reference side and the control it lives in has to say so -- otherwise
    //     "we ported it" decays into "nobody is checking any more".
    {
        auto fx = oneCase(selJson, 0);          // spin_twice, the ported case
        runCommandDivergenceSuite(fx.toString); // as authored: passes
        auto rs = fx["cases"].array[0]["reference"]["selection"];
        auto es = rs["edges"].array.dup;
        es ~= parseJSON(`[[9.0,9.0,9.0],[9.0,9.0,8.0]]`);
        rs["edges"] = JSONValue(es);
        fx["cases"].array[0]["reference"]["selection"] = rs;
        assert(rejected(fx),
            "widening a CLOSED gap by one selected edge was ACCEPTED — a "
            ~ "ported law's empty gap is not being asserted, and the port "
            ~ "could regress with this file still green");
    }

    // 11. ...and the reason those cases use a full-coverage control LIST rather
    //     than `control: true`: only the list can tell "the two engines agreed"
    //     from "nobody looked". Drop the whole `selection` block out of our
    //     half and the selection dimensions stop being measured at all; the
    //     list rejects that, and `control: true` -- asserted here, by value --
    //     does not.
    {
        auto fx = oneCase(selJson, 0);
        fx["cases"].array[0]["vibe3d_current"].object.remove("selection");
        assert(rejected(fx),
            "dropping `selection` out of `vibe3d_current` was ACCEPTED — a "
            ~ "control over a dimension nobody measures is green forever");

        auto weak = oneCase(selJson, 0);
        weak["cases"].array[0]["vibe3d_current"].object.remove("selection");
        weak["cases"].array[0]["control"] = JSONValue(true);
        assert(!rejected(weak),
            "`control: true` REJECTED an unmeasured selection — if it has "
            ~ "become as strict as the list form, say so and simplify the "
            ~ "fixtures back; this assertion exists to record that it is not");
    }

    // 12. the same CLOSED-gap check as arm 10, run on a gap task 1200 closed by
    //     REMOVING a refusal rather than by porting a formula. It is here
    //     because "we now do what the reference does" is the easiest empty gap
    //     to let rot: the four make_polygon_gates cases look, from a distance,
    //     like a parity test that could not fail. Widen the reference's face
    //     list by one ring and the full-coverage control has to say so.
    {
        enum string mpJson = import("fixtures/make_polygon_gates.json");
        auto fx = oneCase(mpJson, 3);           // duplicate_over_existing_face
        runCommandDivergenceSuite(fx.toString); // as authored: passes
        auto fs = fx["cases"].array[0]["reference"]["faces"].array.dup;
        fs ~= parseJSON(`[[9.0,9.0,9.0],[9.0,9.0,8.0],[9.0,8.0,8.0]]`);
        fx["cases"].array[0]["reference"]["faces"] = JSONValue(fs);
        assert(rejected(fx),
            "widening a CLOSED gap by one reference face was ACCEPTED on "
            ~ "make_polygon_gates — the refusals task 1200 removed could be "
            ~ "put back with that fixture still green");
    }

    // 6. provenance: an unstamped fixture must not be trusted at all.
    {
        auto fx = synthDivergent(joinJson, DIVERGENT);
        fx.object.remove("provenance");
        assert(rejected(fx),
            "a fixture with no provenance block was ACCEPTED");
    }
}
