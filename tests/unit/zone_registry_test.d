// Module unittests for the per-frame zone registry (task 1810).
//
// `zoneAt` answers "what is the cursor over", and every scoped binding hangs
// off that answer. The rule under test is LAST PUBLISHED WINS — publication
// order is draw order and draw order is z-order, so the rectangle drawn on top
// is the one the eye sees and the one a chord is aimed at.
module tests.unit.zone_registry_test;

import input_zones;

unittest {  // the plain case: disjoint rectangles, and a miss
    clearZones();
    beginZoneFrame();
    publishZone("viewport3d", 150, 28, 650, 544);
    publishZone("sidePanel",    3,  3, 130, 594);
    endZoneFrame();

    assert(zoneAt(400, 300) == "viewport3d");
    assert(zoneAt( 50, 300) == "sidePanel");
    assert(zoneAt(900, 300) == "",  "outside every rect is not a zone");
    assert(zoneAt(400,   5) == "",  "above the viewport, below no panel");
}

unittest {  // overlap: the LAST published wins, which is the one on top
    clearZones();
    beginZoneFrame();
    publishZone("viewport3d", 150, 28, 650, 544);
    publishZone("layerList",   11, 11, 778, 578);   // a floating panel over it
    endZoneFrame();

    assert(zoneAt(400, 300) == "layerList",
           "a floating panel covering the viewport owns the pixel — first-wins "
           ~ "would answer viewport3d and put the chord in the wrong menu");

    // ...and publishing them the other way round genuinely changes the answer,
    // so this test is measuring the ORDER rule and not just an overlap.
    clearZones();
    beginZoneFrame();
    publishZone("layerList",   11, 11, 778, 578);
    publishZone("viewport3d", 150, 28, 650, 544);
    endZoneFrame();
    assert(zoneAt(400, 300) == "viewport3d");
}

unittest {  // edges are half-open: [x, x+w), so adjacent panels never both win
    clearZones();
    beginZoneFrame();
    publishZone("sidePanel",    0, 0, 100, 100);
    publishZone("viewport3d", 100, 0, 100, 100);
    endZoneFrame();

    assert(zoneAt( 99, 50) == "sidePanel");
    assert(zoneAt(100, 50) == "viewport3d", "the shared edge belongs to exactly one");
    assert(zoneAt(199, 50) == "viewport3d");
    assert(zoneAt(200, 50) == "", "one past the right edge is outside");
}

unittest {  // a collapsed panel publishes nothing rather than a zero-area entry
    clearZones();
    beginZoneFrame();
    publishZone("viewport3d", 150, 28, 650, 544);
    publishZone("toolProps",  400, 300,  0, 200);   // collapsed to no width
    publishZone("history",    400, 300, 200,  0);   // ...and to no height
    endZoneFrame();

    assert(zoneAt(400, 300) == "viewport3d",
           "a zero-area panel must not take the pixel — otherwise last-wins "
           ~ "would hand it to something invisible");
    assert(publishedZones().length == 1);
}

unittest {  // a frame replaces the previous one wholesale
    clearZones();
    beginZoneFrame();
    publishZone("layerList", 0, 0, 500, 500);
    endZoneFrame();
    assert(zoneAt(100, 100) == "layerList");

    beginZoneFrame();                       // the panel was closed this frame
    publishZone("viewport3d", 0, 0, 500, 500);
    endZoneFrame();
    assert(zoneAt(100, 100) == "viewport3d",
           "a panel that stopped drawing must stop owning pixels");
}

unittest {  // the frame is not visible until it is closed
    clearZones();
    beginZoneFrame();
    publishZone("viewport3d", 0, 0, 500, 500);
    endZoneFrame();

    beginZoneFrame();                       // a new frame starts building...
    publishZone("layerList", 0, 0, 500, 500);
    assert(zoneAt(100, 100) == "viewport3d",
           "mid-frame, a reader must still see the LAST COMPLETE layout — the "
           ~ "event pump runs while this frame is only half assembled");
    endZoneFrame();
    assert(zoneAt(100, 100) == "layerList");
}

unittest {  // every name a binding may use is a name something can publish
    foreach (n; kKnownZones)
        assert(isKnownZone(n));
    assert(!isKnownZone("layerlist"), "the check is case-sensitive on purpose — "
                                    ~ "a near-miss is exactly the typo it catches");
    assert(!isKnownZone(""));
    assert(!isKnownZone("nosuchpanel"));
}
