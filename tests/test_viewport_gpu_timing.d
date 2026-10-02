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

// Settle past the ring (8 frame slots): no frame of the previous configuration
// can still be harvested inside the window that follows.
enum uint kSettleFrames = 12;
enum uint kWindowFrames = 16;

struct Delta {
    long[string] samples;
    long[string] sumNs;
    long harvested;
    long dropped;
}

Delta[] window() {
    frameFence(null, kSettleFrames);
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
    frameFence(null, kSettleFrames);
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

unittest { // diagnostic (no assert): the instance-lifetime harvest lag that sized the ring
    auto g = cells()[0]["gpuTiming"];
    writefln("  P0 ring: maxHarvestLag=%d framesDropped=%d framesHarvested=%d ringFrames=%d",
             g["maxHarvestLag"].integer, g["framesDropped"].integer,
             g["framesHarvested"].integer, g["ringFrames"].integer);
}
