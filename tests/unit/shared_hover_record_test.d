module tests.unit.shared_hover_record_test;
import hover_state;
import mesh : Mesh, makeGridPlane;
import math : Vec3, Viewport, ModelSpace, lookAt, orthographicMatrix;
import constraint : resolveHoverTarget, BackgroundSource;
import toolpipe.packets : ConstrainHitPacket, HoverTargetKind, SnapType;
import snap : SnapResult, elementPlaced, kMergeSnappedEdgeEndPx, kMergeAfterSnapPx;

private Viewport viewport() {
    auto vp = Viewport(lookAt(Vec3(0,5,0), Vec3(0,0,0), Vec3(0,0,-1)),
        orthographicMatrix(1.5f,1,.01f,100),600,600,0,0,Vec3(0,5,0));
    vp.focus = Vec3(0,0,0); return vp;
}

unittest {
    auto vp = viewport(); auto lower = makeGridPlane(2);
    Mesh cover;
    cover.vertices = [Vec3(-2,1,-2),Vec3(2,1,-2),Vec3(2,1,2),Vec3(-2,1,2)];
    cover.faces = [cast(uint[])[0,1,2,3]]; cover.buildLoops();
    const sources = [ToolPressSource(&cover, ModelSpace.world(),11),
        ToolPressSource(&lower, ModelSpace.world(),22)];
    const through = hoverRecordAtPixel(300,300,vp,sources,false,false);
    assert(through.kind == kCascadeVertex && through.source == 1 && through.index == 4,
        "hover wire control retains the lower vertex identity");
    const hidden = hoverRecordAtPixel(300,300,vp,sources,true,false);
    assert(hidden.kind == -1, "hover occlusion rejects the covered lower vertex");
    const filled = hoverRecordAtPixel(300,300,vp,sources,true,true);
    assert(filled.kind == kCascadePolygon && filled.owner.layer == 11,
        "hover cover election retains the surface source");
}

unittest {
    auto vp = viewport(); auto down = makeGridPlane(2);
    const sources = [ToolPressSource(&down,ModelSpace.world(),22)];
    assert(toolPressAt(300,300,vp,sources,true,true,true).kind == -1,
        "press control refuses the back-facing interior");
    const hover = hoverRecordAtPixel(300,300,vp,sources,true,true);
    assert(hover.kind == kCascadeVertex && hover.index == 4,
        "hover admission remains independent of press facing and border");
    Mesh loose; loose.vertices = [Vec3(-.5f,0,0),Vec3(.5f,0,0)];
    loose.edges = [cast(uint[2])[0,1]];
    assert(hoverRecordAtPixel(300,300,vp,[ToolPressSource(&loose,ModelSpace.world())],true,false).kind == kCascadeEdge,
        "hover admits loose edge without press support classification");
}

unittest {
    auto vp = viewport(); Mesh point; point.vertices = [Vec3(2,0,0)];
    auto space = ModelSpace.world(); space.isIdentity = false;
    space.m[12] = -2; space.mInv[12] = 2;
    Mesh empty;
    const sources = [ToolPressSource(&empty,ModelSpace.world(),10),ToolPressSource(&point,space,20)];
    const elected = hoverRecordAtPixel(300,300,vp,sources,false,false);
    assert(elected.kind == kCascadeVertex && elected.source == 1 && elected.index == 0 &&
        elected.owner.mesh is &point && elected.owner.layer == 20 && elected.pointWorld == Vec3(0,0,0),
        "hover transformed source election preserves owner and world point");
    assert(hoverRecordAtPixel(300,300,vp,[sources[0]],false,false).kind == -1,
        "hover source removal does not substitute the primary");
    ConstrainHitPacket hit; hit.hit = true; hit.layer = 10;
    const target = resolveHoverTarget(hit,vp,8,[BackgroundSource(&empty,ModelSpace.world(),10),
        BackgroundSource(&point,space,20)],300,300,false);
    assert(target.kind == HoverTargetKind.Vertex && target.vert == 0 && target.layer == 20,
        "background hover elects beyond the hit source and transports ownership");
}

unittest {
    const old = HoverIds(g_hoveredVertex,g_hoveredEdge,g_hoveredFace); const stale = g_hoverIndexSpaceStale;
    scope(exit) { g_hoverIndexSpaceStale = stale; g_hoveredVertex = old.vertex;
        g_hoveredEdge = old.edge; g_hoveredFace = old.face; }
    g_hoveredVertex = 4; g_hoveredEdge = 8; g_hoveredFace = 12;
    g_hoverIndexSpaceStale = true;
    assert(hoverAtPress() == HoverIds.init, "stale press cannot consume held hover indices");
    g_hoverIndexSpaceStale = false;
    assert(hoverAtPress() == HoverIds(4,8,12), "fresh press retains published identities");
}

unittest {
    SnapResult s; s.snapped = true;
    size_t types;
    foreach (type; [SnapType.Vertex,SnapType.Edge,SnapType.EdgeCenter,SnapType.Polygon,SnapType.PolyCenter]) {
        s.targetType = type;
        assert(elementPlaced(s), "shared merge admits each discrete element type"); ++types;
    }
    assert(types == 5, "shared merge covers five discrete element types");
    s.targetType = SnapType.Edge;
    assert(elementPlaced(s), "shared merge admits an edited discrete placement");
    s.targetSource = 1; assert(!elementPlaced(s), "shared merge excludes background placement");
    s.targetSource = 0; s.constraintType = SnapType.Vertex;
    assert(!elementPlaced(s), "shared merge excludes guide placement");
    s.constraintType = SnapType.None; s.snapped = false;
    assert(!elementPlaced(s), "shared merge requires actual placement");
    s.snapped = true; s.targetType = SnapType.None;
    assert(!elementPlaced(s), "shared merge requires a discrete element");
    assert(kMergeSnappedEdgeEndPx == 17.5f && kMergeAfterSnapPx == 2.85f,
        "shared merge retains captured reach values");
}


unittest {
    import std.file : readText;
    import std.path : dirName, buildPath;
    import std.string : indexOf;
    import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent;
    const root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    string code(string file) { return blankUnittestBodies(blankNonCode(readText(buildPath(root,file)))); }
    const pen = code("source/tools/create/pen.d");
    assert(countIdent(pen,"hoverRecordAtPixel") == 2 &&
        pen.indexOf("sources, occlusion, false") >= 0,
        "hover production census: polygon pen must transport edited source and occlusion");
    const topo = code("source/tools/edit/topology_pen/tool.d");
    assert(countIdent(topo,"resolveHoverTarget") == 3 &&
        topo.indexOf("backgroundSourcesFull(), subject.cursorX, subject.cursorY, subject.pickOcclusion") >= 0 &&
        topo.indexOf("subject.cursorX, subject.cursorY, subject.pickOcclusion);") >= 0,
        "hover production census: both topology update doors transport source pixel and admission");
    const readout = code("source/http_providers.d");
    assert(readout.indexOf("backgroundSourcesFull(), x, y, subj.pickOcclusion") >= 0,
        "hover production census: surface readout transports query sources");
}

unittest {
    auto vp = viewport(); Mesh m;
    m.vertices = [Vec3(.0375f,0,0),Vec3(.015f,0,-.5f),Vec3(.015f,0,.15f)];
    m.edges = [cast(uint[2])[1,2]];
    const sources = [ToolPressSource(&m,ModelSpace.world())];
    assert(hoverRecordAtPixel(300,300,vp,sources,false,false).kind == kCascadeVertex,
        "hover comparator prefers the in-reach vertex over a nearer edge");
    assert(hoverRecordAtPixel(300,300,vp,sources,false,false,4).kind == kCascadeEdge,
        "hover reach excludes the vertex beyond four pixels");
    m.vertices[2].z = .5f;
    assert(hoverRecordAtPixel(300,300,vp,sources,false,false).kind == kCascadeEdge,
        "hover edge midpoint veto wins the shared class election");
}

unittest {
    import tools.edit.topology_pen : TopologyPenTool;
    import operator : VectorStack;
    import toolpipe.packets : SubjectPacket, HoverTarget;
    import snap : setBackgroundSnapSources, backgroundSourcesSnapshot,
        backgroundSourcesModelSpaces, backgroundSourceLayerIndices;
    const oldMeshes = backgroundSourcesSnapshot();
    const oldSpaces = backgroundSourcesModelSpaces();
    const oldLayers = backgroundSourceLayerIndices();
    scope(exit) setBackgroundSnapSources(oldMeshes.dup,oldSpaces,oldLayers);
    Mesh primary, first, second; second.vertices = [Vec3(2,0,0)];
    auto space = ModelSpace.world(); space.isIdentity = false;
    space.m[12] = -2; space.mInv[12] = 2;
    setBackgroundSnapSources([&first,&second],[ModelSpace.world(),space],[10,20]);
    SubjectPacket subject; subject.viewport = viewport(); subject.cursorValid = true;
    subject.cursorX = subject.cursorY = 300; subject.pickOcclusion = false;
    ConstrainHitPacket hit; hit.hit = true; hit.layer = 10;
    VectorStack stack; stack.put(&subject); stack.put(&hit);
    const expected = HoverTarget(HoverTargetKind.Vertex,0,-1,20);
    auto ordinary = new TopologyPenTool(() => &primary,null);
    ordinary.update(stack);
    assert(ordinary.preparedUpdateForTest(hit,expected),
        "topology ordinary update consumes common transformed source hover");
    auto prepared = new TopologyPenTool(() => &primary,null);
    auto image = prepared.buildPreparedUpdate(stack);
    assert(image.hasPacket && image.nextTarget == expected,
        "topology prepared update consumes common transformed source hover");
    prepared.installPreparedUpdate(image);
    assert(prepared.preparedUpdateForTest(hit,expected),
        "topology update installs the elected source ownership");
}

unittest {
    // The diagnostic accepts a custom reach; its surface remains a fallback.
    auto vp = viewport(); Mesh m;
    m.vertices = [Vec3(.0975f,0,.0975f),Vec3(.1f,0,-.5f),Vec3(.1f,0,.15f),
        Vec3(-2,0,-2),Vec3(2,0,-2),Vec3(2,0,2),Vec3(-2,0,2)];
    m.edges = [cast(uint[2])[1,2]]; m.faces = [cast(uint[])[3,4,5,6]];
    ConstrainHitPacket hit; hit.hit = true; hit.layer = 20;
    const target = resolveHoverTarget(hit,vp,60,[BackgroundSource(&m,ModelSpace.world(),20)],300,300,false);
    assert(target.kind == HoverTargetKind.Vertex && target.vert == 0,
        "background hover custom reach retains the hit face as fallback");
}
