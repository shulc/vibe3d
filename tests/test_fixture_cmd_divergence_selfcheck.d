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
    enum string spinJson = import("fixtures/spin_gate_narrower.json");
    enum string selJson  = import("fixtures/cmd_selection_product.json");

    // The unmutated case must PASS -- otherwise every "rejected" below could
    // be an artefact of the extraction rather than of the mutation.
    {
        auto fx = oneCase(spinJson, 0);
        runCommandDivergenceSuite(fx.toString);
    }

    // 1. drop a declared divergence entry: the recomputed gap now exceeds the
    //    declaration, which is what a QUIETLY WIDENED divergence looks like.
    {
        auto fx = oneCase(spinJson, 0);
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
        auto fx = oneCase(spinJson, 0);
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
        auto fx = oneCase(spinJson, 0);
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
        auto fx = oneCase(spinJson, 0);
        fx["cases"].array[0].object["control"] = JSONValue(true);
        assert(rejected(fx),
            "a divergent case marked `control: true` was ACCEPTED — the "
            ~ "control guard is inert");
    }

    // 4b. the SCOPED control, on the real control case: name a dimension that
    //     genuinely disagrees there (the selection) and it must be rejected,
    //     while its declared geometry control keeps passing.
    {
        auto fx = oneCase(selJson, 1);          // spin_reselect_is_the_control
        assert("control" in fx["cases"].array[0],
            "case 1 of cmd_selection_product is expected to be the control");
        runCommandDivergenceSuite(fx.toString); // as authored: passes
        fx["cases"].array[0]["control"] =
            JSONValue([JSONValue("sel_edges"), JSONValue("counts")]);
        assert(rejected(fx),
            "declaring the SELECTION a control on the geometry-control case "
            ~ "was ACCEPTED — scoped controls are inert");
    }

    // 5. anti-vacuity: make the reference agree with us in every dimension and
    //    declare no gap. Nothing is wrong per-dimension; what is wrong is that
    //    the case now asserts nothing about any disagreement.
    {
        auto fx = oneCase(spinJson, 0);
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
    //    than no control, because it reads like evidence.
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
        auto fx = oneCase(spinJson, 0);
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
        auto fx = oneCase(spinJson, 0);
        auto cs = fx["cases"].array[0];
        auto r = cs["reference"], v = cs["vibe3d_current"];
        cs["reference"] = v;
        cs["vibe3d_current"] = r;
        fx["cases"].array[0] = cs;
        assert(rejected(fx),
            "a case passed with the two engines' recorded halves SWAPPED — it "
            ~ "does not pin which side does what");
    }

    // 6. provenance: an unstamped fixture must not be trusted at all.
    {
        auto fx = oneCase(spinJson, 0);
        fx.object.remove("provenance");
        assert(rejected(fx),
            "a fixture with no provenance block was ACCEPTED");
    }
}
