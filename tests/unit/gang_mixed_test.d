// Task 1880 — the GANG-EDIT COLLAPSE: when several selected items are edited
// through one properties form, which rows report a mixed value.
//
// ---------------------------------------------------------------------------
// Why this is a unit test and not a suite test
// ---------------------------------------------------------------------------
// The collapse is a pure question over the subjects' values — "do they agree on
// this channel" — and `LayerPropsProvider` answers it with no ImGui, no
// document globals and no HTTP. Asserting it here is asserting the DECISION.
// What is deliberately NOT claimed by this file is the rendering: that a mixed
// row draws the placeholder lives inside an ImGui widget call, and this
// repository has shipped a panel whose declared contents were rendered nowhere
// while the test asserting the declaration passed throughout.
//
// ---------------------------------------------------------------------------
// The mechanism being pinned, which was READ rather than designed
// ---------------------------------------------------------------------------
// In the reference, a command's argument query does not return a value — it
// fills an ARRAY, one entry per element of the selection, and the array type
// carries a first-differing probe. The command has no notion of "mixed" at all.
// So the collapse belongs to the UI layer, which is why it is the PROVIDER that
// answers here and the command that stays ignorant.
//
// ---------------------------------------------------------------------------
// The assertion that would be worth nothing
// ---------------------------------------------------------------------------
// "two different layers report mixed" is satisfied by a provider that reports
// mixed whenever it has more than one subject — which is the likeliest wrong
// implementation, and an attractive one, since every screenshot of a
// multi-selection would look plausible. So every row below pins a channel that
// AGREES right next to one that differs, in the same call, on the same pair.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION (verbatim red in the task file's Мутация section):
//   * `paramMixed` returns `gangSnapshots_.length > 0`
//       -> G2 "pos.y agrees across the gang and must NOT report mixed".
//   * the kind/exposure guard dropped, so an absent channel counts as differing
//       -> G4 "a target that does not expose the channel counts as agreeing".
//   * `setGangTargets` keeps a stale snapshot instead of rebuilding
//       -> G3 "rebinding the gang to a layer that now agrees must clear it".
// ---------------------------------------------------------------------------
module tests.unit.gang_mixed_test;

import std.format : format;

import document     : Layer, ItemKind;
import layer_params : LayerPropsProvider;
import params       : kMixedPlaceholder;

/// A mesh layer at a given x, with a name.
private Layer meshAt(string name, float x) {
    auto l = new Layer;
    l.kind = ItemKind.Mesh;
    l.name = name;
    l.xform.pos.x = x;
    return l;
}

unittest {  // G1 — the placeholder is one literal, and it is the one shipped
    // Pinned because two places have to agree on it: the widget that renders it
    // and anything that reads a panel back. A test that spelled it out again
    // would just be a third copy free to drift.
    assert(kMixedPlaceholder == "(mixed)",
        "the mixed placeholder is `(mixed)` — got " ~ kMixedPlaceholder);
}

unittest {  // G2 — differing and AGREEING channels, on the same pair
    auto a = meshAt("A", 1.0f);
    auto b = meshAt("B", 5.0f);          // differs on pos.x, agrees on pos.y

    auto prov = new LayerPropsProvider(a);
    prov.setGangTargets([b]);

    assert(prov.paramMixed("pos.x"),
        "pos.x differs across the gang (1 vs 5) and must report mixed");
    assert(!prov.paramMixed("pos.y"),
        "pos.y agrees across the gang (both 0) and must NOT report mixed — a "
        ~ "provider that reports mixed whenever it has more than one subject "
        ~ "passes the row above and fails here");
    assert(prov.paramMixed("name"),
        "the names differ (A vs B) and must report mixed");
}

unittest {  // G3 — no gang, and a gang that agrees
    auto a = meshAt("A", 1.0f);
    auto prov = new LayerPropsProvider(a);

    assert(!prov.paramMixed("pos.x"),
        "a provider with no gang stands for ONE subject and can never be "
        ~ "mixed — this is the pre-1880 behaviour every tool and stage keeps");

    auto same = meshAt("A", 1.0f);
    prov.setGangTargets([same]);
    assert(!prov.paramMixed("pos.x") && !prov.paramMixed("name"),
        "a gang whose members agree is not mixed on any channel");

    auto other = meshAt("Z", 9.0f);
    prov.setGangTargets([other]);
    assert(prov.paramMixed("pos.x"),
        "rebinding the gang to a layer that differs must be seen — a cached "
        ~ "snapshot that is not rebuilt answers the previous gang forever");

    prov.setGangTargets([]);
    assert(!prov.paramMixed("pos.x"),
        "rebinding the gang to a layer that now agrees must clear it — an "
        ~ "empty gang is single-subject again");
}

unittest {  // G4 — a target that does not EXPOSE the channel is not a conflict
    // An image resource has no transform at all (`hasXform` false), so it
    // exposes none of the twelve components. The row is only drawn because the
    // FOCUS exposes it, and a subject with no value cannot disagree with one —
    // reporting mixed there would put a placeholder on a row whose only real
    // subject is the focus.
    //
    // This pairing is not something the panel produces (it filters the gang to
    // the focus's kind), which is exactly why the guard needs its own test: no
    // other case can reach it.
    auto a = meshAt("A", 1.0f);
    auto img = new Layer;
    img.kind = ItemKind.Image;
    img.name = "A";                      // agrees on the one channel it has

    auto probe = new LayerPropsProvider(img);
    bool exposes = false;
    foreach (ref p; probe.params()) if (p.name == "pos.x") exposes = true;
    assert(!exposes,
        "rig premise: the image kind must NOT expose pos.x, or this case "
        ~ "cannot exercise the absent-channel guard at all");

    auto prov = new LayerPropsProvider(a);
    prov.setGangTargets([img]);
    assert(!prov.paramMixed("pos.x"),
        "a target that does not expose the channel counts as agreeing");
}

unittest {  // G5 — an unknown channel is never mixed
    auto a = meshAt("A", 1.0f);
    auto b = meshAt("B", 5.0f);
    auto prov = new LayerPropsProvider(a);
    prov.setGangTargets([b]);
    assert(!prov.paramMixed("no.such.channel"),
        "a name no subject exposes has nothing to disagree about, and must "
        ~ "answer false rather than assert or report mixed");
}

unittest {  // G6 — the gang is not limited to one other subject
    auto a = meshAt("A", 1.0f);
    auto b = meshAt("A", 1.0f);
    auto c = meshAt("A", 1.0f);
    auto d = meshAt("A", 2.0f);          // the ONLY dissenter, and it is last

    auto prov = new LayerPropsProvider(a);
    prov.setGangTargets([b, c, d]);
    assert(prov.paramMixed("pos.x"),
        format("one dissenter in a gang of four must report mixed even when "
               ~ "it is the LAST member — a scan that stops at the first "
               ~ "agreeing target answers false here"));
    assert(!prov.paramMixed("name"),
        "and the channel they all agree on is still not mixed");
}
