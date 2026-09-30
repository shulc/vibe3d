module retopology_order;

import document : Document, Layer, LayerRole, kindInfo;

// The item draw sequence of the retopology display (task 8610, plan §10.3 /
// §10.4). Captured: the foreground items draw in REVERSE layer order,
// independent of which one is the edit target, and a same-as-active
// background joins that same sequence as an ordinary item. So the sequence is
// every visible geometry layer but the primary, highest index first, split
// around the primary's own index: higher indices draw before it, lower ones
// after it; with no primary everything is "before". Background-role layers
// enter only when the backdrop joins; the rest stay in the backdrop pass.

/// One entry of the sequence: the layer's index in `Document.layers`, and
/// whether it draws with the ACTIVE plan (a foreground item) or the backdrop's.
struct SeqEntry {
    size_t layerIndex;
    bool   foreground;
}

/// Whether layer `i` of `doc` is drawn by the item sequence rather than by the
/// backdrop pass: a visible, geometry-drawing, non-primary layer that is
/// foreground-role, or background-role while the backdrop joins.
bool entersItemSequence(const ref Document doc, size_t i, bool backdropJoins)
{
    if (i >= doc.layers.length) return false;
    const(Layer) l = doc.layers[i];
    if (l is null || !l.visible || doc.isPrimary(l)) return false;
    if (!kindInfo(l.kind).drawsGeometry) return false;
    immutable LayerRole role = doc.roleOf(l);
    if (role == LayerRole.Foreground) return true;
    return role == LayerRole.Background && backdropJoins;
}

/// Fill `before` / `after` (both emptied first, their storage reused) with the
/// sequence entries of `doc`, each in draw order.
void retopologyDrawSequence(const ref Document doc, bool backdropJoins,
                            ref SeqEntry[] before, ref SeqEntry[] after)
{
    before.length = 0;
    after.length = 0;
    before.assumeSafeAppend();
    after.assumeSafeAppend();
    immutable bool hasPrimary = doc.hasEditTarget();
    immutable size_t primaryIndex = hasPrimary ? doc.activeIndex() : 0;
    foreach_reverse (i; 0 .. doc.layers.length) {
        if (!entersItemSequence(doc, i, backdropJoins)) continue;
        immutable SeqEntry e = SeqEntry(i,
            doc.roleOf(doc.layers[i]) == LayerRole.Foreground);
        if (!hasPrimary || i > primaryIndex) before ~= e;
        else after ~= e;
    }
}
