module tests.unit.tools.edit.preview_rebuild_test;
import vibe3d.mesh.core.mesh : Mesh, makeCube;
import math : Vec3;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import tools.edit.preview_rebuild;

private PreviewTopologyKey key(ref Mesh m) {
    return PreviewTopologyKey.make([true,false], false, 1);
}
unittest { // PR-empty
    Mesh m = makeCube(); MeshSnapshot empty; PreviewRebuild r; uint calls;
    const digest = topologyDigest(m);
    assert(r.run(m, empty, (ref Mesh c) { ++calls; return key(c); },
        (ref Mesh c) { ++calls; return 99; }) == 0);
    assert(calls == 0 && topologyDigest(m) == digest && r.counts() == PreviewRebuildCounts.init,
        "PR-empty must not invoke delegates or change live/counters");
}
unittest { // PR-placement
    Mesh m = makeCube(); auto before = MeshSnapshot.capture(m); PreviewRebuild r; float distance=1;
    size_t kernel(ref Mesh c) { auto i=c.addVertex(Vec3(distance,2,3)); c.addFace([0u,1,i]); c.vertices[0]=Vec3(distance,-2,4); return 7; }
    assert(r.run(m,before,(ref Mesh c) => key(c),&kernel)==7 && m.vertices.length==9 && m.faces.length==7);
    const tv=m.topologyVersion; const digest=topologyDigest(m); const old=m.vertices[0]; distance=3;
    assert(r.run(m,before,(ref Mesh c) => key(c),&kernel)==7);
    assert(m.vertices[0] == Vec3(3,-2,4) && m.vertices[0] != old,
        "PR-placement installs nonzero rebuilt positions");
    assert(m.topologyVersion==tv && topologyDigest(m)==digest && m.vertices.length==9 && m.faces.length==7,
        "PR-placement preserves live topology and restores clean operand before kernel");
    assert(r.counts()==PreviewRebuildCounts(1,1,0),"PR-placement counters 1/1/0");
}
unittest { // PR-ring-miss: same counts, different face ring
    Mesh m=makeCube(); auto before=MeshSnapshot.capture(m); PreviewRebuild r; bool other;
    size_t kernel(ref Mesh c) { auto i=c.addVertex(Vec3(1,2,3)); c.addFace([0u,other ? 2u : 1u,i]);return 7; }
    r.run(m,before,(ref Mesh c) => key(c),&kernel); const digest=topologyDigest(m); const nv=m.vertices.length;const nf=m.faces.length;other=true;
    assert(r.run(m,before,(ref Mesh c) => key(c),&kernel)==7);
    assert(m.vertices.length==nv && m.faces.length==nf && topologyDigest(m)!=digest && m.faces[$-1]==[0u,2,8],
        "PR-ring-miss installs rebuilt connectivity at unchanged counts");
    assert(r.counts()==PreviewRebuildCounts(2,0,1),"PR-ring-miss falls back and counts key miss");
}
unittest { // PR-key-change
    Mesh m=makeCube();auto before=MeshSnapshot.capture(m);PreviewRebuild r;long count=1;
    PreviewTopologyKey declared(ref Mesh c) {return PreviewTopologyKey.make([true,false],false,count);}
    size_t kernel(ref Mesh c) {c.vertices[0]=Vec3(1,2,3);return 4;}
    r.run(m,before,&declared,&kernel);count=2;r.run(m,before,&declared,&kernel);
    assert(r.counts()==PreviewRebuildCounts(2,0,0),"PR-key-change rebuilds for a declared count change");
}
unittest { // PR-image-reset
    Mesh m = makeCube();
    auto before = MeshSnapshot.capture(m);
    PreviewRebuild r;
    float distance = 1;
    bool other;
    size_t kernel(ref Mesh c) {
        auto i = c.addVertex(Vec3(distance,2,3));
        c.addFace([0u,other ? 2u : 1u,i]);
        c.vertices[0] = Vec3(distance,-2,4);
        return 7;
    }
    assert(r.run(m,before,(ref Mesh c) => key(c),&kernel) == 7 &&
        m.vertices.length == 9 && m.faces.length == 7,
        "PR-image first sample builds fixed population");
    assert(r.counts() == PreviewRebuildCounts(1,0,0),
        "PR-image first sample counters 1/0/0");
    const tv = m.topologyVersion;
    const digest = topologyDigest(m);
    const old = m.vertices[0];
    distance = 3;
    assert(r.run(m,before,(ref Mesh c) => key(c),&kernel) == 7,
        "PR-image placement returns kernel result");
    assert(m.vertices[0] == Vec3(3,-2,4) && m.vertices[0] != old,
        "PR-image placement installs changed nonzero position");
    assert(m.topologyVersion == tv && topologyDigest(m) == digest &&
        m.vertices.length == 9 && m.faces.length == 7,
        "PR-image placement preserves live topology");
    assert(r.counts() == PreviewRebuildCounts(1,1,0),
        "PR-image placement counters 1/1/0");
    other = true;
    assert(r.run(m,before,(ref Mesh c) => key(c),&kernel) == 7,
        "PR-image ring miss returns kernel result");
    assert(m.vertices.length == 9 && m.faces.length == 7 &&
        m.faces[$-1] == [0u,2,8] && topologyDigest(m) != digest,
        "PR-image ring miss changes topology at fixed population");
    assert(r.counts() == PreviewRebuildCounts(2,1,1),
        "PR-image ring miss counters 2/1/1");

    PreparedPreviewRebuildImage image;
    r.prepareImage(image);
    assert(image.expectedFullRebuilds == 2,"PR-image captures full diagnostic 2");
    assert(image.expectedPlacements == 1,"PR-image captures placement diagnostic 1");
    assert(image.expectedKeyMisses == 1,"PR-image captures miss diagnostic 1");
    assert(image.valid,"PR-image captures validity");
    assert(image.expectedHasLast,"PR-image captures key presence");
    assert(image.expectedLast == key(m),"PR-image captures declared key");
    assert(image.expectedLastTopology == topologyDigest(m) && image.expectedLastTopology != 0,
        "PR-image captures nonzero live topology");
    assert(image.expectedCage.filled && image.expectedCage.vertices.length == 9 &&
        image.expectedCage.faces.length == 7 && image.expectedCage.faces[$-1] == [0u,2,8] &&
        image.expectedCage.vertices[0] == Vec3(3,-2,4),
        "PR-image captures filled changed cage");
    assert(r.matchesImage(image),"PR-image captured live cache matches");

    PreparedPreviewRebuildImage imageValidity;
    r.prepareImage(imageValidity);
    assert(r.matchesImage(imageValidity),"PR-image validity fresh capture matches");
    imageValidity.valid = false;
    assert(!r.matchesImage(imageValidity),"PR-image validity mismatch refuses");

    PreparedPreviewRebuildImage imageFull;
    r.prepareImage(imageFull);
    assert(r.matchesImage(imageFull),"PR-image full fresh capture matches");
    ++imageFull.expectedFullRebuilds;
    assert(!r.matchesImage(imageFull),"PR-image full mismatch refuses");

    PreparedPreviewRebuildImage imagePlacement;
    r.prepareImage(imagePlacement);
    assert(r.matchesImage(imagePlacement),"PR-image placement fresh capture matches");
    ++imagePlacement.expectedPlacements;
    assert(!r.matchesImage(imagePlacement),"PR-image placement mismatch refuses");

    PreparedPreviewRebuildImage imageMiss;
    r.prepareImage(imageMiss);
    assert(r.matchesImage(imageMiss),"PR-image miss fresh capture matches");
    ++imageMiss.expectedKeyMisses;
    assert(!r.matchesImage(imageMiss),"PR-image miss mismatch refuses");

    PreparedPreviewRebuildImage imagePresence;
    r.prepareImage(imagePresence);
    assert(r.matchesImage(imagePresence),"PR-image presence fresh capture matches");
    imagePresence.expectedHasLast = !imagePresence.expectedHasLast;
    assert(!r.matchesImage(imagePresence),"PR-image presence mismatch refuses");

    PreparedPreviewRebuildImage imageKey;
    r.prepareImage(imageKey);
    assert(r.matchesImage(imageKey),"PR-image key fresh capture matches");
    ++imageKey.expectedLast.counts[0];
    assert(!r.matchesImage(imageKey),"PR-image key mismatch refuses");

    PreparedPreviewRebuildImage imageTopology;
    r.prepareImage(imageTopology);
    assert(r.matchesImage(imageTopology),"PR-image topology fresh capture matches");
    imageTopology.expectedLastTopology ^= 1;
    assert(!r.matchesImage(imageTopology),"PR-image topology mismatch refuses");

    PreparedPreviewRebuildImage imageCage;
    r.prepareImage(imageCage);
    assert(r.matchesImage(imageCage),"PR-image cage fresh capture matches");
    imageCage.expectedCage.vertices[0].x += 1;
    assert(!r.matchesImage(imageCage),"PR-image cage mismatch refuses");

    PreparedPreviewRebuildImage stale;
    r.prepareImage(stale);
    assert(r.matchesImage(stale),"PR-reset fresh expected cache matches");
    r.reset();
    assert(!r.matchesImage(stale),"PR-reset stale expected cache refuses");
    assert(r.counts() == PreviewRebuildCounts(2,1,1),"PR-reset keeps diagnostic counters 2/1/1");
    PreparedPreviewRebuildImage reset;
    r.prepareImage(reset);
    assert(!reset.expectedHasLast,"PR-reset clears last-key presence");
    assert(reset.expectedLast == PreviewTopologyKey.init,"PR-reset clears last key");
    assert(reset.expectedLastTopology == 0,"PR-reset clears last topology");
    Mesh empty;
    assert(reset.expectedCage.vertices.length == 0 && reset.expectedCage.matches(empty),
        "PR-reset releases complete scratch");
    assert(r.matchesImage(reset),"PR-reset fresh reset image matches");
    assert(r.run(m,before,(ref Mesh c) => key(c),&kernel) == 7,
        "PR-reset next sample returns kernel result");
    assert(r.counts() == PreviewRebuildCounts(3,1,1),"PR-reset next sample rebuilds 3/1/1");
}
