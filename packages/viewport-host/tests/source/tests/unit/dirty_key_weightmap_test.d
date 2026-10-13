// The viewport dirty key's weight-map term (task 1090).
//
// READ THIS BEFORE TRYING TO STRENGTHEN THE FILE. The term's LIVE effect — "a
// non-active cell re-renders when the current weight map changes" — is NOT
// verifiable from the HTTP suite, and no cleverer case will make it so.
// `source/app.d`'s per-cell loop reads
//
//     if (testMode) { needRender = (k == vpm.activeId); }
//     else          { /* the dirty-key compare */ }
//
// and every test in this tree forces `--test`. So the compare this field
// participates in is unreachable there, exactly as `source/viewport.d` says of
// six sibling terms. What CAN be checked is that the field discriminates and
// that the digest feeding it is a real function of the name — which is what
// this file checks, and which is why the digest was given a name in
// `weightmap_view` instead of being written inline at the stamping site.
module tests.unit.dirty_key_weightmap_test;

import viewport        : DirtyKey;
import weightmap_view  : weightMapKeyFor, currentWeightMapKey,
                         setCurrentWeightMap, currentWeightMapName;

/// Two keys differing only in the weight-map term must compare unequal.
unittest {
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    a.weightMapKey = weightMapKeyFor("wmA");
    b.weightMapKey = weightMapKeyFor("wmB");
    assert(a.weightMapKey != b.weightMapKey,
        "sanity: the two names must digest differently, or the assertion "
        ~ "below would pass on a constant hash");
    assert(a != b,
        "keys differing only in the current weight map must compare unequal "
        ~ "— the map selection is a render input like any other, and it moves "
        ~ "no mesh version, no selection epoch and no upload version, so "
        ~ "nothing else on this struct can carry it");

    // The same name must produce the same key, or an idle cell would re-render
    // every frame — the opposite failure, and just as real.
    b.weightMapKey = weightMapKeyFor("wmA");
    assert(a == b,
        "the same map name must digest to the same key; a key that moved on "
        ~ "its own would defeat the whole dirty-key gate");
}

/// The digest is a function of the NAME, and the empty name is not a special
/// case that collides with something.
unittest {
    static immutable string[] names = [
        "", "a", "b", "wmA", "wmB", "Awm", "wm", "wmAA", "weight", "Weight",
    ];
    foreach (i, n; names)
        foreach (j, m; names)
            if (i != j)
                assert(weightMapKeyFor(n) != weightMapKeyFor(m),
                    "two distinct map names collided in the dirty-key digest: '"
                    ~ n ~ "' and '" ~ m ~ "'");

    // Case-sensitive: the map registry is, so the key must be.
    assert(weightMapKeyFor("wmA") != weightMapKeyFor("wma"),
        "map names are case-sensitive on the mesh; the key must not fold case");

    // Deterministic across calls.
    assert(weightMapKeyFor("wmA") == weightMapKeyFor("wmA"));
}

/// `currentWeightMapKey` reads the SAME state the render pass reads.
///
/// This is the join the stamping site depends on: if it drifted onto a
/// separate copy of the name, the key could say "unchanged" while the pass
/// drew a different map.
unittest {
    string saved = currentWeightMapName();
    scope(exit) setCurrentWeightMap(saved);

    setCurrentWeightMap("wmA");
    assert(currentWeightMapKey() == weightMapKeyFor("wmA"),
        "the key must be the digest of the CURRENT name");

    setCurrentWeightMap("wmB");
    assert(currentWeightMapKey() == weightMapKeyFor("wmB"),
        "selecting another map must move the key");

    setCurrentWeightMap("");
    assert(currentWeightMapKey() == weightMapKeyFor(""),
        "deselecting must move it back to the empty name's digest, not leave "
        ~ "the previous map's");
}
