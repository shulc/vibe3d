// SP2 (wave plan SP, task 9140): the per-cell GPU segment timer reports a
// section that did not run as ABSENT (0 samples) and one that ran as present,
// read from `/api/viewport/display` `"gpuTiming"` around a window of rendered
// frames. `--test` arms the timer. No time threshold anywhere (owner budgets);
// the one ns cell is "> 0" on a heavy face pass, kept by the P0 measurement.

import http_client : testBaseUrl, getJson, postRaw, frameFence;
import http_command_helpers : commandBody;
import std.json;
import std.exception : enforce;
import std.format : format;
import std.stdio : writefln;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow, playAndWait,
                     CameraState, Vec3;

void main() {}

void cmd(string id, string params = null) {
    auto r = parseJSON(postRaw("/api/command", commandBody(id, params)));
    enforce("status" !in r || r["status"].str != "error",
            format("command %s %s failed: %s", id, params, r.toString));
}

bool jb(JSONValue v) {
    enforce(v.type == JSONType.TRUE || v.type == JSONType.FALSE, "not a bool: " ~ v.toString);
    return v.type == JSONType.TRUE;
}

JSONValue[] cells() { return getJson("/api/viewport/display")["cells"].array; }

// Settle past the ring (its depth is read from the dump): no frame of the
// previous configuration can still be harvested inside the window that follows.
enum uint kWindowFrames = 16;
uint settleFrames() {
    return cast(uint) getJson("/api/viewport/display")["cells"].array[0]["gpuTiming"]
        ["ringFrames"].integer + 4;
}

struct Delta {
    long[string] samples;
    long[string] sumNs;
    long harvested;
    long dropped;
}

Delta[] window() {
    frameFence(null, settleFrames());
    auto a = cells();
    frameFence(null, kWindowFrames);
    auto b = cells();
    enforce(a.length == b.length, "cell count changed inside the window");
    Delta[] r;
    foreach (i; 0 .. b.length) {
        auto ga = a[i]["gpuTiming"], gb = b[i]["gpuTiming"];
        Delta d;
        foreach (k, v; gb["segments"].object) {
            d.samples[k] = v["samples"].integer - ga["segments"][k]["samples"].integer;
            d.sumNs[k]   = v["sumNs"].integer - ga["segments"][k]["sumNs"].integer;
        }
        d.harvested = gb["framesHarvested"].integer - ga["framesHarvested"].integer;
        d.dropped   = gb["framesDropped"].integer - ga["framesDropped"].integer;
        r ~= d;
    }
    return r;
}

JSONValue plan(string side) { return cells()[0]["plan"][side]; }

void resetSingle() {
    cmd("scene.reset");
    cmd("viewport.layout", `"Single"`);
    cmd("viewport.retopology", `{"value":"off"}`);
    cmd("viewport.wireOverlay", `"uniform"`);
    cmd("viewport.backdropStyle", `{"value":"same"}`);
}

unittest { // premise: the timer is armed under --test and available on this host
    resetSingle();
    frameFence(null, settleFrames());
    auto g = cells()[0]["gpuTiming"];
    writefln("  P0 host: armed=%s available=%s bits=%d reason='%s' ringFrames=%d maxHarvestLag=%d",
             g["armed"], g["available"], g["bits"].integer, g["reason"].str,
             g["ringFrames"].integer, g["maxHarvestLag"].integer);
    enforce(jb(g["armed"]), "premise: --test must arm the GPU timer: " ~ g.toString);
    enforce(jb(g["available"]),
        "premise: GL_TIME_ELAPSED timer queries must be available on this gate host "
        ~ "(GL 3.3 core, counter bits > 0): " ~ g.toString);
}

unittest { // (i) Shaded: the face section is present every frame; (ii) Wireframe: absent
    resetSingle();
    cmd("scene.reset", `{"type":"grid","n":64}`);
    cmd("viewport.displayStyle", `"shaded"`);
    auto s = window()[0];
    writefln("  (i) shaded: harvested=%d faces=%d edges=%d", s.harvested,
             s.samples["faces"], s.samples["edges"]);
    assert(s.harvested >= 8, format("(i) floor: %d frames harvested in the window", s.harvested));
    assert(s.samples["faces"] >= 8, format("(i) shaded faces samples %d < 8", s.samples["faces"]));

    cmd("viewport.displayStyle", `"wireframe"`);
    enforce(!jb(plan("active")["drawFaces"]), "(ii) premise: wireframe draws no faces");
    auto w = window()[0];
    writefln("  (ii) wireframe: harvested=%d faces=%d edges=%d", w.harvested,
             w.samples["faces"], w.samples["edges"]);
    assert(w.harvested >= 8 && w.samples["edges"] >= 8,
        format("(ii) positive control: harvested=%d edges=%d (the timer runs)",
               w.harvested, w.samples["edges"]));
    assert(w.samples["faces"] == 0,
        format("(ii) wireframe: the face section must read ABSENT, got %d samples",
               w.samples["faces"]));
    cmd("viewport.displayStyle", `"shaded"`);
}

unittest { // (iii) backdrop faces absent under Solid, present under Shaded; SP2-bw
    resetSingle();
    cmd("layer.add");                       // empty primary; the cube is the backdrop
    cmd("viewport.displayStyle", `"solid"`);
    frameFence(null, 2);
    enforce(!jb(plan("backdrop")["drawFaces"]) && jb(plan("backdrop")["drawWire"]),
        "(iii) premise: a same-as-active backdrop under Solid draws wire, no faces: "
        ~ plan("backdrop").toString);
    auto so = window()[0];
    writefln("  (iii) solid: harvested=%d backdropFaces=%d backdropWire=%d", so.harvested,
             so.samples["backdropFaces"], so.samples["backdropWire"]);
    assert(so.samples["backdropWire"] >= 8,
        format("(iii) positive control: backdrop wire samples %d", so.samples["backdropWire"]));
    assert(so.samples["backdropFaces"] == 0,
        format("(iii) Solid: backdrop faces must read ABSENT, got %d", so.samples["backdropFaces"]));

    cmd("viewport.displayStyle", `"shaded"`);
    frameFence(null, 2);
    enforce(jb(plan("backdrop")["drawFaces"]), "(iii) premise: shaded backdrop draws faces");
    auto sh = window()[0];
    assert(sh.samples["backdropFaces"] >= 8,
        format("(iii) Shaded: backdrop faces samples %d < 8", sh.samples["backdropFaces"]));

    // SP2-bw: backdrop wire off, backdrop faces on.
    cmd("viewport.wireOverlay", `"none"`);
    frameFence(null, 2);
    enforce(jb(plan("backdrop")["drawFaces"]) && !jb(plan("backdrop")["drawWire"]),
        "(bw) premise: backdrop faces on, wire off: " ~ plan("backdrop").toString);
    auto bw = window()[0];
    writefln("  (bw) harvested=%d backdropFaces=%d backdropWire=%d", bw.harvested,
             bw.samples["backdropFaces"], bw.samples["backdropWire"]);
    assert(bw.samples["backdropFaces"] >= 8,
        format("(bw) positive control: backdrop faces samples %d", bw.samples["backdropFaces"]));
    assert(bw.samples["backdropWire"] == 0,
        format("(bw) the backdrop wire section must read ABSENT, got %d", bw.samples["backdropWire"]));
    cmd("viewport.wireOverlay", `"uniform"`);
}

unittest { // per-item: under the retopology item sequence each item's sections are samples
    // Measured per-frame counts (2026-10-02, this rig: the primary quad + the
    // joined same-as-active cube; the active plan under the mode draws faces
    // and wire whatever the style, the backdrop plan follows style/overlay).
    resetSingle();
    cmd("layer.add");
    cmd("scene.loadMesh",
        `{"vertices":[[-1,-1,2],[1,-1,2],[1,1,2],[-1,1,2]],"faces":[[0,1,2,3]]}`);
    cmd("viewport.displayStyle", `"shaded"`);
    cmd("viewport.retopology", `{"value":"on"}`);
    scope (exit) {
        cmd("viewport.retopology", `{"value":"off"}`);
        cmd("viewport.wireOverlay", `"uniform"`);
        cmd("viewport.displayStyle", `"shaded"`);
    }
    frameFence(null, 2);
    enforce(jb(plan("active")["clearDepthFirst"]) && jb(plan("backdrop")["joinsItemSequence"])
            && jb(plan("backdrop")["drawFaces"]) && jb(plan("backdrop")["drawWire"]),
        "(item-a) premise: the mode clears per item; the same-as-active backdrop joins "
        ~ "and draws faces and wire: " ~ plan("backdrop").toString);
    auto d = window()[0];
    writefln("  (item-a) harvested=%d faces=%d edges=%d backdropFaces=%d", d.harvested,
             d.samples["faces"], d.samples["edges"], d.samples["backdropFaces"]);
    assert(d.harvested >= 8, format("(item-a) floor: %d harvested", d.harvested));
    assert(d.samples["faces"] == 2 * d.harvested,
        format("(item-a) two items (primary + the joined cube) = two face samples per "
             ~ "frame: faces=%d harvested=%d", d.samples["faces"], d.harvested));
    assert(d.samples["edges"] == 2 * d.harvested,
        format("(item-a) two item wire passes per frame: edges=%d harvested=%d",
               d.samples["edges"], d.harvested));
    assert(d.samples["backdropFaces"] == 0,
        format("(item-a) the joined layer is drawn by the sequence, not the backdrop pass: %d",
               d.samples["backdropFaces"]));
    assert(d.samples["verts"] == 1 * d.harvested,
        format("(item-a) no item draws dots (only the vertex feedback pass, measured 1 per "
             ~ "frame): verts=%d harvested=%d", d.samples["verts"], d.harvested));
    cmd("viewport.showVertices", `{"value":"on"}`);
    frameFence(null, 2);
    enforce(jb(plan("active")["drawVerts"]) && jb(plan("backdrop")["drawVerts"]),
        "(item-dots) premise: both plans draw dots: " ~ plan("backdrop").toString);
    auto dv = window()[0];
    cmd("viewport.showVertices", `{"value":"off"}`);
    writefln("  (item-dots) harvested=%d verts=%d", dv.harvested, dv.samples["verts"]);
    assert(dv.harvested >= 8 && dv.samples["verts"] == 3 * dv.harvested,
        format("(item-dots) primary bracket + joined item + feedback pass = 3 dot samples "
             ~ "per frame (measured): verts=%d harvested=%d", dv.samples["verts"], dv.harvested));

    // (item-b) the joined item draws no wire: its edges section is absent.
    cmd("viewport.wireOverlay", `"none"`);
    frameFence(null, 2);
    enforce(jb(plan("backdrop")["drawFaces"]) && !jb(plan("backdrop")["drawWire"]),
        "(item-b) premise: joined item faces on, wire off: " ~ plan("backdrop").toString);
    auto w = window()[0];
    writefln("  (item-b) harvested=%d faces=%d edges=%d", w.harvested,
             w.samples["faces"], w.samples["edges"]);
    assert(w.harvested >= 8 && w.samples["faces"] == 2 * w.harvested,
        format("(item-b) positive control: faces=%d harvested=%d", w.samples["faces"], w.harvested));
    assert(w.samples["edges"] == 1 * w.harvested,
        format("(item-b) only the primary's wire is a sample (measured 1 per frame), got "
             ~ "edges=%d harvested=%d", w.samples["edges"], w.harvested));

    // (item-c) the joined item draws no faces: one face sample per frame.
    cmd("viewport.wireOverlay", `"uniform"`);
    cmd("viewport.displayStyle", `"wireframe"`);
    frameFence(null, 2);
    enforce(jb(plan("active")["clearDepthFirst"]) && !jb(plan("backdrop")["drawFaces"]),
        "(item-c) premise: joined item draws no faces: " ~ plan("backdrop").toString);
    auto f = window()[0];
    writefln("  (item-c) harvested=%d faces=%d edges=%d", f.harvested,
             f.samples["faces"], f.samples["edges"]);
    assert(f.harvested >= 8 && f.samples["edges"] == 2 * f.harvested,
        format("(item-c) positive control: edges=%d harvested=%d", f.samples["edges"], f.harvested));
    assert(f.samples["faces"] == 1 * f.harvested,
        format("(item-c) only the primary's faces are a sample (measured 1 per frame), got "
             ~ "faces=%d harvested=%d", f.samples["faces"], f.harvested));
}

unittest { // (iv) a heavy face pass has a nonzero GPU time (kept by P0 on both gate hosts)
    resetSingle();
    cmd("scene.reset", `{"type":"grid","n":316}`);
    cmd("viewport.displayStyle", `"shaded"`);
    auto d = window()[0];
    writefln("  (iv) grid316 shaded: harvested=%d faces samples=%d sumNs=%d dropped=%d",
             d.harvested, d.samples["faces"], d.sumNs["faces"], d.dropped);
    assert(d.samples["faces"] >= 8, format("(iv) floor: faces samples %d", d.samples["faces"]));
    assert(d.sumNs["faces"] > 0, "(iv) the face section of a 200 K-triangle grid timed 0 ns");
    cmd("scene.reset");
}

unittest { // (v) Quad: every rendering cell harvests
    resetSingle();
    cmd("viewport.layout", `"Quad"`);
    scope (exit) cmd("viewport.layout", `"Single"`);
    frameFence(null, 2);
    auto cs = cells();
    auto ds = window();
    size_t rendering;
    foreach (i, c; cs) {
        if (!jb(c["renders"])) continue;
        ++rendering;
        assert(ds[i].harvested >= 8,
            format("(v) cell %d renders but harvested %d frames", i, ds[i].harvested));
    }
    assert(rendering == 4, format("(v) population floor: %d rendering cells, expected 4", rendering));
}

unittest { // (vi) selection-feedback and overlay sections: each present only where it draws
    resetSingle();
    postRaw("/api/command", "select.typeFrom vertex");
    cmd("viewport.displayStyle", `"shaded"`);
    auto v = window()[0];
    writefln("  (vi-vertex) harvested=%d verts=%d overlays=%d imagePlanes=%d", v.harvested,
             v.samples["verts"], v.samples["overlays"], v.samples["imagePlanes"]);
    assert(v.harvested >= 8 && v.samples["verts"] >= 8,
        format("(vi-vertex) positive control: verts=%d harvested=%d", v.samples["verts"], v.harvested));
    assert(v.samples["overlays"] == 0 && v.samples["imagePlanes"] == 0,
        format("(vi-vertex) no tool, no item type, no image plane: overlays=%d imagePlanes=%d "
             ~ "must read absent", v.samples["overlays"], v.samples["imagePlanes"]));

    postRaw("/api/command", "select.typeFrom polygon");
    cmd("viewport.displayStyle", `"wireframe"`);
    auto pn = window()[0];
    writefln("  (vi-poly) harvested=%d faces=%d edges=%d", pn.harvested,
             pn.samples["faces"], pn.samples["edges"]);
    assert(pn.harvested >= 8 && pn.samples["edges"] >= 8,
        format("(vi-poly) the polygon edge arm is a sample: edges=%d", pn.samples["edges"]));
    assert(pn.samples["faces"] == 0,
        format("(vi-poly) no face selected: the checker fill must read absent, got %d",
               pn.samples["faces"]));
    cmd("mesh.select", `{"mode":"polygons","indices":[0]}`);
    auto ps = window()[0];
    writefln("  (vi-poly-sel) harvested=%d faces=%d", ps.harvested, ps.samples["faces"]);
    assert(ps.samples["faces"] >= 8,
        format("(vi-poly-sel) the checker fill of a selected face is a faces sample, got %d",
               ps.samples["faces"]));
    cmd("mesh.select", `{"mode":"polygons","indices":[]}`);

    postRaw("/api/command", "select.typeFrom edge");
    auto e = window()[0];
    writefln("  (vi-edge) harvested=%d edges=%d", e.harvested, e.samples["edges"]);
    assert(e.harvested >= 8 && e.samples["edges"] >= 8,
        format("(vi-edge) the edge arm is a sample: edges=%d", e.samples["edges"]));

    postRaw("/api/command", "select.typeFrom vertex");
    cmd("viewport.displayStyle", `"shaded"`);
    postRaw("/api/command", "tool.set move on");
    auto t = window()[0];
    postRaw("/api/command", "tool.set move off");
    writefln("  (vi-tool) harvested=%d overlays=%d overlayMode=%s", t.harvested,
             t.samples["overlays"], cells()[0]["overlayMode"].str);
    assert(t.harvested >= 8 && t.samples["overlays"] >= 8,
        format("(vi-tool) an active tool's overlays are a sample: %d", t.samples["overlays"]));

    postRaw("/api/command", "select.typeFrom item");
    auto it = window()[0];
    postRaw("/api/command", "select.typeFrom vertex");
    writefln("  (vi-item) harvested=%d overlays=%d verts=%d", it.harvested,
             it.samples["overlays"], it.samples["verts"]);
    assert(it.harvested >= 8 && it.samples["overlays"] >= 8,
        format("(vi-item) the item-highlight pass is a sample: %d", it.samples["overlays"]));
    assert(it.samples["verts"] == 0,
        format("(vi-item) under the item type no vertex feedback draws: verts=%d", it.samples["verts"]));
}

// 5 stationary motion events (no button) at window pixel (x, y): a cursor HOVER.
void hoverAt(CameraState cam, int x, int y) {
    string log = format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n", cam.vpX, cam.vpY, cam.width, cam.height);
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
            ~ `"state":0,"mod":0}` ~ "\n", 50.0 + i * 20.0, x, y);
    playAndWait(log);
}

unittest { // (vii) the hover-only edge and vertex arms: a sample only while an element is hovered
    resetSingle();
    cmd("viewport.displayStyle", `"shaded"`);
    cmd("viewport.wireOverlay", `"none"`);      // no base wire: the edge section is the hover alone
    scope (exit) { postRaw("/api/command", "tool.set mesh.loopSliceTool off");
                   postRaw("/api/command", "tool.set xfrm.elementMove off"); }
    auto cam = fetchCamera();
    auto vp = viewportFromCamera(cam);
    float sx, sy;

    // Edge hover under the vertex type: Loop Slice hovers edges in any type.
    postRaw("/api/command", "select.typeFrom vertex");
    postRaw("/api/command", "tool.set mesh.loopSliceTool on");
    hoverAt(cam, cam.vpX + 4, cam.vpY + 4);     // empty corner: nothing hovered
    auto e0 = window()[0];
    assert(projectToWindow(Vec3(0.5f, 0.0f, 0.5f), vp, sx, sy), "(vii) edge midpoint on camera");
    hoverAt(cam, cast(int) sx, cast(int) sy);
    auto e1 = window()[0];
    writefln("  (vii-edge) off: harvested=%d edges=%d; on: harvested=%d edges=%d",
             e0.harvested, e0.samples["edges"], e1.harvested, e1.samples["edges"]);
    assert(e0.harvested >= 8 && e0.samples["edges"] == 0,
        format("(vii-edge) with no wire and nothing hovered, edges must read absent: %d",
               e0.samples["edges"]));
    assert(e1.harvested >= 8 && e1.samples["edges"] >= 8,
        format("(vii-edge) a hovered edge is an edges sample: %d", e1.samples["edges"]));
    postRaw("/api/command", "tool.set mesh.loopSliceTool off");

    // Vertex hover under the polygon type: an element-falloff move hovers vertices.
    postRaw("/api/command", "select.typeFrom polygon");
    postRaw("/api/script", "tool.set xfrm.elementMove on");
    postRaw("/api/command", "tool.pipe.attr falloff mode vertex");
    hoverAt(cam, cam.vpX + 4, cam.vpY + 4);
    auto v0 = window()[0];
    assert(projectToWindow(Vec3(0.5f, 0.5f, 0.5f), vp, sx, sy), "(vii) cube corner on camera");
    hoverAt(cam, cast(int) sx, cast(int) sy);
    auto v1 = window()[0];
    writefln("  (vii-vert) off: harvested=%d verts=%d; on: harvested=%d verts=%d",
             v0.harvested, v0.samples["verts"], v1.harvested, v1.samples["verts"]);
    assert(v0.harvested >= 8 && v0.samples["verts"] == 0,
        format("(vii-vert) under the polygon type with nothing hovered, verts must read absent: %d",
               v0.samples["verts"]));
    assert(v1.harvested >= 8 && v1.samples["verts"] >= 8,
        format("(vii-vert) a hovered vertex is a verts sample: %d", v1.samples["verts"]));
    hoverAt(cam, cam.vpX + 4, cam.vpY + 4);
}

unittest { // diagnostic (no assert): the instance-lifetime harvest lag that sized the ring
    auto g = cells()[0]["gpuTiming"];
    writefln("  P0 ring: maxHarvestLag=%d framesDropped=%d framesHarvested=%d ringFrames=%d",
             g["maxHarvestLag"].integer, g["framesDropped"].integer,
             g["framesHarvested"].integer, g["ringFrames"].integer);
}
