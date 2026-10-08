module tests.unit.model_preview_test;

import model_preview;
import tool : Tool;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import tools.edit.bridge_tool : BridgeTool;
import tools.create.cylinder : CylinderParams, buildCylinder;
import tools.create.primitive_create_tool : SizedRadialCreateTool;
import editmode : EditMode;
import math : Vec3;
import std.json : JSONType;

private class Provider : Tool {
    static assert(__traits(isFinalFunction, Tool.modelPreview));
    static assert(!__traits(isVirtualMethod, Tool.modelPreview));
    static assert(__traits(isFinalFunction, bindModelPreview));
    static assert(!__traits(isVirtualMethod, bindModelPreview));
    this() { bindModelPreview(&queryPreview); }

    ModelPreviewView view;
    bool ready = true;
    private bool queryPreview(out ModelPreviewView candidate) {
        assert(candidate == ModelPreviewView.init, "bound query receives cleared view");
        candidate = view;
        return ready;
    }
}

unittest {
    Mesh source, cage;
    GpuMesh sourceGpu, cageGpu;
    auto base = ModelPreviewView(&source, &sourceGpu);
    auto provider = new Provider;
    provider.view = ModelPreviewView(&cage, &cageGpu);
    auto normal = resolveModelPreview(new Tool, base);
    assert(!normal.replacement && normal.view == base, "unbound Tool keeps source pair");
    ModelPreviewView dirty = provider.view;
    auto unbound = new Tool;
    assert(!unbound.modelPreview(dirty) && dirty == ModelPreviewView.init,
           "unbound operation clears borrowed output");
    auto missing = resolveModelPreview(null, base);
    assert(!missing.replacement && missing.view == base, "null Tool keeps source pair");
    auto chosen = resolveModelPreview(provider, base);
    assert(chosen.replacement && chosen.view == provider.view,
           "provider replaces both mesh and GPU");
    assert(chosen.geometryHover(17) == -1 && normal.geometryHover(17) == 17,
           "replacement suppresses source-index geometry hover");
    provider.ready = false;
    assert(resolveModelPreview(provider, base).view == base, "absent preview returns source");
    provider.ready = true;
    assert(resolveModelPreview(provider, base).replacement,
           "bound query reads readiness on every invocation");
    provider.view.mesh = null;
    assert(!resolveModelPreview(provider, base).replacement, "partial mesh pair refused");
    provider.view = ModelPreviewView(&cage, null);
    assert(!resolveModelPreview(provider, base).replacement, "partial GPU pair refused");
}

unittest {
    Mesh cage, otherCage;
    GpuMesh gpu, otherGpu;
    auto provider = new Provider;
    auto other = new Provider;
    provider.view = ModelPreviewView(&cage, &gpu);
    gpu.uploadVersion = 7;
    auto chosen = resolveModelPreview(provider, ModelPreviewView.init);
    auto key = ModelPreviewKey.from(chosen, 2);
    assert(key == ModelPreviewKey.from(chosen, 2), "same upload and depth is a cache hit across cells");
    gpu.uploadVersion++;
    assert(key != ModelPreviewKey.from(chosen, 2), "new upload at same cage address must rebuild");
    gpu.uploadVersion--;
    assert(key != ModelPreviewKey.from(chosen, 3), "depth change must rebuild");
    other.view = provider.view;
    assert(key != ModelPreviewKey.from(resolveModelPreview(other, ModelPreviewView.init), 2),
           "provider change must rebuild even with the same pair");
    chosen.view.mesh = &otherCage;
    assert(key != ModelPreviewKey.from(chosen, 2), "cage address change must rebuild");
    chosen.view.mesh = &cage;
    otherGpu.uploadVersion = gpu.uploadVersion;
    chosen.view.gpu = &otherGpu;
    assert(key != ModelPreviewKey.from(chosen, 2), "GPU address change must rebuild");
}

unittest {
    Mesh source;
    GpuMesh gpu;
    EditMode mode = EditMode.Polygons;
    foreach (p; [Vec3(-1,-1,-1), Vec3(1,-1,-1), Vec3(1,1,-1), Vec3(-1,1,-1),
                 Vec3(-1,-1,1), Vec3(1,-1,1), Vec3(1,1,1), Vec3(-1,1,1)])
        source.addVertex(p);
    source.addFace([0u,3u,2u,1u]); source.addFace([4u,5u,6u,7u]);
    source.buildLoops(); source.faceMarks.length = 2;
    source.faceSelectionOrder.length = 2;
    source.selectFace(0); source.selectFace(1);
    auto tool = new BridgeTool(() nothrow @nogc => &source, &gpu, null, &mode);
    ModelPreviewView view;
    assert(!tool.modelPreview(view), "Bridge without a cached activation has no preview");
    Mesh* selected;
    auto image = tool.buildPreparedActivation(selected);
    assert(image.selectionValid && image.preview.faces.length == 4,
           "fixture resolves two caps into four bridge walls");
    tool.installPreparedActivation(image);
    assert(tool.toolStateJson()["engaged"].type == JSONType.false_ && tool.modelPreview(view), "standing unengaged Bridge supplies replacement");
    assert(view.mesh !is &source && view.gpu !is &gpu && view.mesh.faces.length == 4,
           "Bridge lends its detached complete result");
    source = Mesh.init;
    assert(!tool.modelPreview(view) && view == ModelPreviewView.init,
           "Bridge stale source identity refuses display without publishing borrowed pointers");

    auto invalid = new BridgeTool(() nothrow @nogc => &source, &gpu, null, &mode);
    auto invalidImage = invalid.buildPreparedActivation(selected);
    assert(!invalidImage.selectionValid, "empty selection is invalid");
    invalid.installPreparedActivation(invalidImage);
    assert(!invalid.modelPreview(view), "invalid Bridge selection keeps normal display");
}

private Mesh primitiveSource() {
    import mesh : Surface, MeshMap, MapDomain;
    auto m = makeCube();
    foreach (ref v; m.vertices) v += Vec3(9, 3, -4);
    m.resizeVertexSelection(); m.resizeEdgeSelection(); m.resizeFaceSelection();
    m.faceSelectionOrder.length = m.faces.length;
    m.faceMarks[1] = Mesh.Marks.Subpatch;
    m.vertexMarks[2] = Mesh.Marks.Lock;
    Surface first, second; first.name = "source-default"; first.baseColor = Vec3(.8f,.1f,.2f);
    second.name = "source-other"; second.baseColor = Vec3(.1f,.3f,.9f);
    m.surfaces = [first, second]; m.faceMaterial = [0u,1u,0u,1u,0u,1u];
    m.facePart = [2u,3u,2u,3u,2u,3u];
    MeshMap map; map.name = "weight"; map.dim = 1; map.domain = MapDomain.Point;
    map.data = [1f,2f,3f,4f,5f,6f,7f,8f]; m.meshMaps = [map];
    m.vertexSetNames = ["points"]; m.vertexSetMask = [1UL,0,1,0,0,0,0,0];
    m.polygonSetNames = ["polys"]; m.faceSetMask = [0UL,1,0,0,0,0];
    m.edgeSetNames = ["edges"]; m.edgeSetMask[17] = 1;
    return m;
}

private void drawIdle(Tool tool) {
    import math : Viewport, lookAt, perspectiveMatrix;
    import shader : Shader;
    import display_state : DrawPlan;
    import operator : VectorStack;
    Viewport vp; vp.width = vp.height = 400;
    vp.eye = Vec3(4, 3, 6); vp.focus = Vec3(0,0,0);
    vp.view = lookAt(vp.eye, Vec3(0,0,0), Vec3(0,1,0));
    vp.proj = perspectiveMatrix(.8f, 1f, .1f, 100f);
    Shader shader; DrawPlan plan; VectorStack vts;
    tool.draw(shader, vp, vts, plan);
}

private void baseGesture(Tool tool, bool release = true) {
    import bindbc.sdl : SDL_MouseButtonEvent, SDL_MouseMotionEvent, SDL_BUTTON_LEFT;
    import operator : VectorStack;
    VectorStack vts;
    SDL_MouseButtonEvent press; press.button = SDL_BUTTON_LEFT; press.x = 175; press.y = 175;
    assert(tool.onMouseButtonDown(press, vts), "primitive press reaches drawing stage");
    SDL_MouseMotionEvent move; move.x = 235; move.y = 245;
    assert(tool.onMouseMotion(move, vts), "primitive base motion updates real builder");
    if (release) assert(tool.onMouseButtonUp(press, vts), "primitive release reaches base-set stage");
}

private void assertPrimitivePrefix(ref Mesh source, ModelPreviewView view) {
    assert(source.vertices.length == 8 && source.faces.length == 6 &&
           view.mesh.vertices.length > 8 && view.mesh.faces.length > 6, "nonempty source and generated tail floors");
    assert(view.mesh.vertices[0..8] == source.vertices && view.mesh.faces[0..6] == source.faces,
           "construction frame never transforms or reverses source prefix");
    assert(view.mesh.surfaces == source.surfaces && view.mesh.faceMaterial[0..6] == source.faceMaterial &&
           view.mesh.facePart[0..6] == source.facePart && view.mesh.faceMarks[0..6] == source.faceMarks,
           "complete candidate keeps surfaces, parts, marks and source subpatch");
    assert(view.mesh.meshMaps[0].data[0..8] == source.meshMaps[0].data &&
           view.mesh.vertexSetNames == source.vertexSetNames &&
           view.mesh.vertexSetMask[0..8] == source.vertexSetMask &&
           view.mesh.polygonSetNames == source.polygonSetNames &&
           view.mesh.faceSetMask[0..6] == source.faceSetMask &&
           view.mesh.edgeSetMask == source.edgeSetMask, "complete candidate retains maps and selection sets");
    foreach (fi; 6 .. view.mesh.faces.length)
        assert(Mesh.faceAttrOr(view.mesh.faceMaterial, fi) == 0u,
               "generated faces resolve source default surface slot zero");
    assert(view.mesh.vertices.ptr !is source.vertices.ptr && view.mesh.faces[0].ptr !is source.faces[0].ptr &&
           view.mesh.meshMaps[0].data.ptr !is source.meshMaps[0].data.ptr,
           "candidate source geometry/maps are deeply detached");
}

unittest {
    import tools.create.cylinder : CylinderTool;
    import tools.create.box : BoxTool;
    import snapshot : MeshSnapshot;
    import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
    import toolpipe.stages.workplane : WorkplaneStage;
    import bindbc.sdl : loadSDL, sdlSupport, SDL_GetModState, SDL_SetModState, KMOD_NONE;
    assert(loadSDL() == sdlSupport, "primitive CPU gesture loads SDL");
    auto oldMods = SDL_GetModState(); scope(exit) SDL_SetModState(oldMods); SDL_SetModState(KMOD_NONE);
    auto oldPipe = g_pipeCtx; scope(exit) g_pipeCtx = oldPipe;
    g_pipeCtx = new ToolPipeContext;
    auto workplane = new WorkplaneStage; g_pipeCtx.pipeline.add(workplane);
    workplane.edit(2, -1, 3, 30, 40, 15);
    foreach (box; [false, true]) {
        Mesh source = primitiveSource(); Mesh other;
        Mesh* current = &source;
        GpuMesh gpu; gpu.suppressCageUpload = true;
        Tool tool;
        if (box) {
            auto concrete = new BoxTool(() => current, &gpu, null);
            concrete.preparedPreviewGpu().suppressCageUpload = true; tool = concrete;
        } else {
            auto concrete = new CylinderTool(() => current, &gpu, null);
            concrete.preparedPreviewGpu().suppressCageUpload = true; tool = concrete;
        }
        ModelPreviewView view;
        assert(!tool.modelPreview(view), "primitive idle has no uploaded replacement");
        drawIdle(tool); baseGesture(tool, false);
        auto before = MeshSnapshot.capture(source);
        assert(tool.modelPreview(view), "nonzero flat DrawingBase supplies complete representation before commit");
        assert(view.mesh !is &source && view.gpu !is &gpu, "primitive replacement lends both detached model resources");
        assertPrimitivePrefix(source, view);
        auto stableMesh = view.mesh; auto stableGpu = view.gpu;
        auto candidate = MeshSnapshot.capture(*view.mesh);
        tool.evaluate();
        assert(tool.modelPreview(view), "reevaluation stays ready " ~ tool.name());
        assert(view.mesh is stableMesh && view.gpu is stableGpu, "reevaluation retains existing pair " ~ tool.name());
        assert(candidate.matches(*view.mesh), "reevaluation never accumulates previous primitive " ~ tool.name());
        assert(before.matches(source), "drawing and reevaluation preserve exact source planes");
        if (!box) {
            auto concrete = cast(CylinderTool) tool;
            import bindbc.sdl : SDL_MouseButtonEvent, SDL_BUTTON_LEFT;
            import operator : VectorStack;
            import params : parseInto;
            foreach (p; concrete.params())
                if (p.name == "sizeX" || p.name == "sizeY" || p.name == "sizeZ")
                    assert(parseInto(p, "1.25"), "public parameter image supplies nondegenerate committable radii");
            SDL_MouseButtonEvent up; up.button = SDL_BUTTON_LEFT; VectorStack vts;
            concrete.onMouseButtonUp(up, vts);
            Mesh committed; uint flags, domains;
            auto image = concrete.buildPreparedDeactivateState(committed, flags, domains);
            assert(image.expectedCommitValid, "released base is committable");
            assert(tool.modelPreview(view), "released base remains displayed");
            assert(MeshSnapshot.capture(*view.mesh).matches(committed),
                   "state-aware preview exactly matches prepared committable candidate including metadata");
        }
        before.restore(other);
        current = &other;
        assert(!tool.modelPreview(view) && view == ModelPreviewView.init,
               "different source pointer refuses even identical uploaded source bytes");
        current = &source;
        assert(tool.modelPreview(view), "original source pointer restores readiness");
        auto savedPosition = source.vertices[0]; source.vertices[0].x += .25f;
        assert(!tool.modelPreview(view) && view == ModelPreviewView.init,
               "direct source position write invalidates exact uploaded source receipt");
        source.vertices[0] = savedPosition;
        assert(tool.modelPreview(view), "unchanged exact source becomes ready again");
        source.surfaces[0].baseColor.z += .1f;
        assert(!tool.modelPreview(view), "source metadata write invalidates uploaded source receipt");
        tool.evaluate();
        assert(tool.modelPreview(view) && view.mesh.surfaces == source.surfaces,
               "rebuild refreshes current source receipt and metadata");
        tool.cancelUncommittedEdit();
        assert(!tool.modelPreview(view) && view == ModelPreviewView.init,
               "cancelled primitive refuses retained candidate storage");
    }
}

private class InterruptedCylinder : SizedRadialCreateTool!CylinderParams {
    bool interruptBuild;
    bool displayValid = true;
    this(Mesh* delegate() source, GpuMesh* gpu) {
        super(source, gpu, null);
        import tools.create.create_common : primitivePlacementFrame;
        frame = primitivePlacementFrame();
        seedPreparedRadialActivationForTest();
    }
    protected override string commitLabel() const { return "interrupted fixture"; }
    protected override bool previewValid() const { return displayValid; }
    protected override void buildInto(Mesh* destination) {
        if (interruptBuild) {
            destination.addVertex(Vec3(4,5,6));
            throw new Exception("interrupted primitive builder");
        }
        buildCylinder(destination, params_);
    }
}

unittest {
    import bindbc.sdl : loadSDL, sdlSupport, SDL_GetModState, SDL_SetModState, KMOD_NONE;
    import std.exception : assertThrown;
    import snapshot : MeshSnapshot;
    import toolpipe.pipeline : g_pipeCtx;
    auto oldPipe = g_pipeCtx; scope(exit) g_pipeCtx = oldPipe; g_pipeCtx = null;
    assert(loadSDL() == sdlSupport, "exceptional primitive gesture loads SDL");
    auto oldMods = SDL_GetModState(); scope(exit) SDL_SetModState(oldMods); SDL_SetModState(KMOD_NONE);
    Mesh source = primitiveSource(); GpuMesh gpu; gpu.suppressCageUpload = true;
    auto primitive = new InterruptedCylinder(() => &source, &gpu);
    primitive.preparedPreviewGpu().suppressCageUpload = true;
    primitive.evaluate();
    ModelPreviewView view;
    assert(primitive.modelPreview(view), "exception rig first uploads a real complete candidate");
    auto candidate = MeshSnapshot.capture(*view.mesh);
    primitive.displayValid = false;
    assert(!primitive.modelPreview(view) && view == ModelPreviewView.init,
           "query reads preview eligibility dynamically before lending retained upload");
    primitive.displayValid = true;
    assert(primitive.modelPreview(view), "restored eligibility reads existing uploaded receipt");
    primitive.interruptBuild = true;
    assertThrown!Exception(primitive.evaluate());
    assert(!primitive.modelPreview(view) && view == ModelPreviewView.init,
           "interrupted rebuild cannot lend partially modified retained candidate under old ready receipt");
    primitive.interruptBuild = false; primitive.evaluate();
    assert(primitive.modelPreview(view) && candidate.matches(*view.mesh),
           "successful rebuild publishes receipt only for complete fresh candidate");
}
