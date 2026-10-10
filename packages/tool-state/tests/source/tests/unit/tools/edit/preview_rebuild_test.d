module tests.unit.tools.edit.preview_rebuild_test;
import mesh : Mesh, makeCube;
import math : Vec3;
import snapshot : MeshSnapshot;
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
    Mesh m=makeCube();auto before=MeshSnapshot.capture(m);PreviewRebuild r;
    size_t kernel(ref Mesh c) {c.vertices[0]=Vec3(1,2,3);return 4;}
    r.run(m,before,(ref Mesh c) => key(c),&kernel);PreparedPreviewRebuildImage image;r.prepareImage(image);
    assert(r.matchesImage(image),"PR-image captured live cache matches");
    image.valid=false;assert(!r.matchesImage(image),"PR-image invalid image refuses");image.valid=true;
    r.reset();assert(!r.matchesImage(image),"PR-reset stale expected cache refuses");
    PreparedPreviewRebuildImage reset;r.prepareImage(reset);
    assert(!reset.expectedHasLast && reset.expectedLast==PreviewTopologyKey.init && reset.expectedLastTopology==0 && reset.expectedCage.vertices.length==0,
        "PR-reset releases cache/scratch");
    assert(r.counts()==PreviewRebuildCounts(1,0,0),"PR-reset keeps diagnostic counters");
    r.run(m,before,(ref Mesh c) => key(c),&kernel);assert(r.counts()==PreviewRebuildCounts(2,0,0),"PR-reset next sample rebuilds");
}
