// Pure Local normal-arrow drag and independent numeric parity.
// Historical screen-plane observations: task20261570 amendment evidence.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs, sqrt;
import std.conv   : to;
import std.string : strip;
import std.file   : readText;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers : Vec3, dot, normalize, fetchCamera, viewportFromCamera, gizmoSize, projectToWindow, buildDragLog;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void playAndWait(string log) {
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success",
        "play-events failed: " ~ r.toString);
    // Captured drag's t-stamps span ~32 s of real time (manual idle
    // before the click), so the player needs that much wall-clock to
    // drain. 900 × 100ms = 90s headroom.
    foreach (i; 0 .. 900) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.TRUE) return;
        Thread.sleep(dur!"msecs"(100));
    }
    assert(false, "play-events did not finish within 90s");
}

Vec3[] dumpVerts() {
    auto verts = getJson("/api/model")["vertices"].array;
    Vec3[] out_;
    out_.length = verts.length;
    foreach (i, v; verts) {
        auto a = v.array;
        out_[i] = Vec3(cast(float)a[0].floating,
                       cast(float)a[1].floating,
                       cast(float)a[2].floating);
    }
    return out_;
}

struct ClusterInfo {
    Vec3[] centers;        // ACEN.clusterCenters (per cluster)
    Vec3[] fwd, right, up; // All signed component axes
    Vec3   sharedRight;    // AXIS.right (shared basis from non-cluster path)
    Vec3   sharedUp;
    Vec3   sharedFwd;
    int[]  clusterOf;      // per-vertex cluster id (-1 = unassigned)
}

ClusterInfo readClusters() {
    auto j = postJson("/api/toolpipe/eval", "");
    ClusterInfo ci;
    foreach (c; j["actionCenter"]["clusterCenters"].array) {
        auto a = c.array;
        ci.centers ~= Vec3(cast(float)a[0].floating,
                           cast(float)a[1].floating,
                           cast(float)a[2].floating);
    }
    foreach (c; j["actionCenter"]["clusterOf"].array)
        ci.clusterOf ~= cast(int)c.integer;
    foreach (f; j["axis"]["clusterFwd"].array) {
        auto a = f.array;
        ci.fwd ~= Vec3(cast(float)a[0].floating,
                       cast(float)a[1].floating,
                       cast(float)a[2].floating);
    }
    foreach (key; ["clusterRight", "clusterUp"]) {
        Vec3[] values;
        foreach (v; j["axis"][key].array) values ~= vector(v);
        if (key == "clusterRight") ci.right = values; else ci.up = values;
    }
    auto r = j["axis"]["right"].array;
    auto u = j["axis"]["up"].array;
    auto f = j["axis"]["fwd"].array;
    ci.sharedRight = Vec3(cast(float)r[0].floating,
                          cast(float)r[1].floating,
                          cast(float)r[2].floating);
    ci.sharedUp    = Vec3(cast(float)u[0].floating,
                          cast(float)u[1].floating,
                          cast(float)u[2].floating);
    ci.sharedFwd   = Vec3(cast(float)f[0].floating,
                          cast(float)f[1].floating,
                          cast(float)f[2].floating);
    return ci;
}

// Lock the camera explicitly so the captured drag's screen pixels
// project onto the same gizmo + workplane regardless of any future
// default-orbit/elevation/distance drift. The captured event log was
// taken with the standard vibe3d test-mode defaults (azimuth=0.5,
// elevation=0.4, distance=3.0, focus at origin). The VIEWPORT line in
// the log handles size remapping separately.
void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok",
        "camera lock failed: " ~ r.toString);
}

void setupScene() {
    // Empty reset → cube segments-2 → asymmetric 3-poly selection →
    // tool.set move on → actr.local. Order matters: actr.local needs
    // ACEN + AXIS stages registered by the active tool's preset, so
    // the tool must come on before the preset switch.
    postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    lockCamera();
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
      ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":[11,12,13]}`));
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    cmd("tool.set move on");
    cmd("actr.local");
    cmd("history.clear");
    settle();
}


void settle() { Thread.sleep(dur!"msecs"(150)); }
Vec3 vector(JSONValue j) {
    auto a = j.array;
    return Vec3(cast(float)a[0].floating, cast(float)a[1].floating, cast(float)a[2].floating);
}
long undoCount() { return getJson("/api/history")["undo"].array.length; }

// task20261570 amendment: historical pixels grabbed a screen plane, with TY=.03.
// Project the current prepared normal shaft and witness the real held latch.
void normalArrowGesture() {
    import std.string : splitLines;
    settle();
    auto e = getJson("/api/toolpipe/eval"); auto t = e["transform"];
    foreach (key; ["right", "up", "fwd"]) {
        auto d = vector(t["moveRenderFrame"][key]) - vector(e["axis"][key]);
        assert(sqrt(dot(d,d)) < .005, "normal-arrow prepared/display frame agrees with shared producer");
    }
    auto c = vector(t["gizmoCenter"]); auto f = vector(t["moveRenderFrame"]["fwd"]);
    auto cam = fetchCamera(); auto vp = viewportFromCamera(cam);
    float size = gizmoSize(c,vp), x0,y0,x1,y1;
    projectToWindow(c+f*(size/5),vp,x0,y0); projectToWindow(c+f*size,vp,x1,y1);
    double dx=x1-x0,dy=y1-y0,len=sqrt(dx*dx+dy*dy);
    assert(len>10,"normal arrow screen population");
    int x=cast(int)(x0+.7f*dx),y=cast(int)(y0+.7f*dy);
    auto log=buildDragLog(cam.vpX,cam.vpY,cam.width,cam.height,x,y,
        x+cast(int)(40*dx/len),y+cast(int)(40*dy/len),12);
    string held, release, viewport;
    foreach(line;log.splitLines) {
        auto v=parseJSON(line);
        if(v["type"].str=="VIEWPORT") viewport=line~"\n";
        if(v["type"].str=="SDL_MOUSEBUTTONUP") release=line~"\n";
        else held~=line~"\n";
    }
    const floor=undoCount(); assert(floor<48,"normal-arrow history headroom");
    {
        scope(exit) { playAndWait(viewport~release); settle(); }
        playAndWait(held); settle();
        auto latched=getJson("/api/toolpipe/eval")["transform"]["moveDragAxis"].integer;
        assert(latched==2,"normal-arrow gesture grabbed production Move normal part");
    }
    assert(undoCount()==floor+1,"normal-arrow gesture records exactly one entry");
}

float[] perClusterFwdScalars(Vec3[] pre, Vec3[] post_, ClusterInfo ci) {
    assert(pre.length==26&&post_.length==26&&ci.centers.length==2,"old rig 26 vertices / two groups");
    assert(getJson("/api/model")["faces"].array.length==24,"old rig 24 faces");
    assert(ci.right.length==2&&ci.up.length==2&&ci.fwd.length==2,"complete signed component frames");
    float[] scalars;
    int untouched;
    foreach(c;0..2) {
        Vec3 mean; int count;
        foreach(vi,cid;ci.clusterOf) if(cid==c) { mean=mean+(post_[vi]-pre[vi]);++count; }
        assert(count==(c==0?6:4),"old rig selected member floors 6/4");
        mean=mean/cast(float)count;
        float tx=dot(mean,ci.right[c]),ty=dot(mean,ci.up[c]),tz=dot(mean,ci.fwd[c]);
        assert(fabs(tx)<.005&&fabs(ty)<.005,"normal-arrow geometry has zero off-axis channels");
        foreach(vi,cid;ci.clusterOf) if(cid==c) {
            auto d=post_[vi]-pre[vi]-(ci.right[c]*tx+ci.up[c]*ty+ci.fwd[c]*tz);
            assert(sqrt(dot(d,d))<.005,"normal-arrow full component reconstruction");
        }
        scalars~=tz;
    }
    foreach(vi,cid;ci.clusterOf) if(cid<0) {
        ++untouched;auto d=post_[vi]-pre[vi];
        assert(sqrt(dot(d,d))<.005,"normal-arrow untouched vertex");
    }
    assert(untouched==16,"old rig untouched population 16");
    return scalars;
}

unittest {
    setupScene(); auto ci=readClusters(); auto pre=dumpVerts();
    normalArrowGesture(); auto post_=dumpVerts();
    auto scalars=perClusterFwdScalars(pre,post_,ci);
    assert(scalars[0]>.05,"normal-arrow nonzero signed motion");
    foreach(s;scalars) assert(fabs(s-scalars[0])<.005,"Per-cluster signed-fwd scalar divergence (Phase 3 bug)");
}

unittest {
    setupScene(); auto ci=readClusters(); auto preD=dumpVerts();
    normalArrowGesture(); auto postD=dumpVerts();
    float s=perClusterFwdScalars(preD,postD,ci)[0];
    assert(s>.05,"drag/numeric comparison has nonzero pure TZ");
    setupScene(); auto preN=dumpVerts();
    cmd("tool.attr move TX 0.0"); cmd("tool.attr move TY 0.0");
    cmd(format("tool.attr move TZ %.6f",s)); cmd("tool.doApply");
    auto postN=dumpVerts(); assert(postD.length==postN.length,"drag/numeric vertex count");
    float maxDiff=0;int worstVi=-1;
    foreach(vi;0..preD.length) {
        auto d=(postD[vi]-preD[vi])-(postN[vi]-preN[vi]);auto m=sqrt(dot(d,d));
        if(m>maxDiff) { maxDiff=m;worstVi=cast(int)vi; }
    }
    assert(maxDiff<.005,"Drag vs numeric divergence (the bug Phase 3 fixes): max per-vert drift = "~maxDiff.to!string~" at vertex "~worstVi.to!string);
}
