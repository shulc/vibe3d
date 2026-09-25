// Transform handle-pose law through real mouse gestures. The handle oracle is
// always the move-X endpoint published by /api/tool/handles after release; the
// transform endpoint supplies channels, never the observed handle position.

import core.thread : Thread;
import core.time : msecs;
import drag_helpers : CameraState, Vec3, fetchCamera, playAndWait,
    projectToWindow, viewportFromCamera;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : fabs, sqrt;

void main() {}
private alias V3 = double[3];

private double number(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}
private V3 vector(JSONValue v) {
    auto a = v.array; return [number(a[0]), number(a[1]), number(a[2])];
}
private V3 add(V3 a, V3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }
private V3 sub(V3 a, V3 b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
private V3 scale(V3 a, double s) { return [a[0]*s, a[1]*s, a[2]*s]; }
private double distance(V3 a, V3 b) {
    const d = sub(a,b); return sqrt(d[0]*d[0]+d[1]*d[1]+d[2]*d[2]);
}
private double distance2(double[2] a, double[2] b) {
    return sqrt((a[0]-b[0])^^2 + (a[1]-b[1])^^2);
}
private void command(string s) {
    auto r = postJson("/api/command", s);
    assert(r["status"].str == "ok", "command `"~s~"` failed: "~r.toString);
}
private void settle() { quiesce(); }

private string viewportLine(CameraState c) {
    return format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`~"\n",
                  c.vpX,c.vpY,c.width,c.height);
}
private void hover(CameraState c, int x, int y) {
    string log = viewportLine(c);
    foreach (i; 0..5) log ~= format(
        `{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`~"\n",
        30+i*20,x,y);
    playAndWait(log); settle();
}
private double[2] handleScreen(int wanted=3) {
    const h = getJson("/api/tool/handles")["handles"];
    foreach (p; h["parts"].array) {
        if (cast(int)p["part"].integer != wanted || p["screen"].type == JSONType.null_) continue;
        auto s=p["screen"].array; return [number(s[0]),number(s[1])];
    }
    assert(false, format("6207 handle part %s missing: %s", wanted, h));
}
private double[2] projected(CameraState c, V3 p) {
    auto vp=viewportFromCamera(c); float x,y;
    assert(projectToWindow(Vec3(cast(float)p[0],cast(float)p[1],cast(float)p[2]),vp,x,y),
           "6207 expected handle must project");
    return [x,y];
}
private void assertHandleShift(CameraState c, double[2] anchorScreen,
                               V3 anchorWorld, V3 expectedWorld, string cell) {
    const p0=projected(c,anchorWorld), p1=projected(c,expectedWorld);
    immutable double[2] expected=[anchorScreen[0]+p1[0]-p0[0],
                                  anchorScreen[1]+p1[1]-p0[1]];
    const observed=handleScreen(); // post-release /api/tool/handles read
    assert(distance2(observed,expected)<=1.5,
        format("6207 %s handle must publish c+M*T after release: %s vs %s",cell,observed,expected));
}
private JSONValue transformEval() { return getJson("/api/toolpipe/eval")["transform"]; }
private V3 worldTranslation(JSONValue t) {
    const local=vector(t["translate"]); V3 result=[0.0,0.0,0.0];
    foreach (axis,key; ["runFrameRight","runFrameUp","runFrameFwd"])
        result=add(result,scale(vector(t[key]),local[axis]));
    return result;
}
private V3 vertex(int i) { return vector(getJson("/api/model")["vertices"].array[i]); }

private void establish(string tool, string mode) {
    postJson("/api/command",commandBody("scene.reset"));
    command("tool.pipe.attr snap enabled false");
    command("tool.pipe.attr symmetry enabled false");
    command("tool.set "~tool~" on");
    if (mode.length) command("actr."~mode);
    settle();
}
private void establishElement() {
    postJson("/api/command",commandBody("scene.reset"));
    command("tool.pipe.attr snap enabled false");
    command("tool.pipe.attr symmetry enabled false");
    command("tool.set xfrm.elementMove on");
    command("tool.pipe.attr falloff mode vertex");
    command("tool.pipe.attr falloff dist 4"); settle();
}

private struct DragObservation { double[2] anchorHandle, midHandle, releasedHandle; }
private DragObservation dragAt(CameraState c,int x0,int y0,int dx,int dy,int steps=16) {
    DragObservation o; hover(c,x0,y0);
    playAndWait(viewportLine(c)~format(
        `{"t":30,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",x0,y0));
    settle(); o.anchorHandle=handleScreen();
    string motion=viewportLine(c); int px=x0,py=y0;
    foreach(i;1..steps+1) {
        immutable x=x0+cast(int)(cast(double)dx*i/steps+0.5);
        immutable y=y0+cast(int)(cast(double)dy*i/steps+0.5);
        motion~=format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}`~"\n",
                       50+i*30,x,y,x-px,y-py); px=x;py=y;
    }
    playAndWait(motion); settle(); o.midHandle=handleScreen();
    playAndWait(viewportLine(c)~format(
        `{"t":30,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`~"\n",x0+dx,y0+dy));
    settle(); o.releasedHandle=handleScreen(); return o;
}
private DragObservation dragArrow(CameraState c,int dx) {
    const p=handleScreen(0), centre=handleScreen(3);
    immutable length=sqrt((p[0]-centre[0])^^2+(p[1]-centre[1])^^2);
    immutable sx=cast(int)(dx*(p[0]-centre[0])/length+0.5);
    immutable sy=cast(int)(dx*(p[1]-centre[1])/length+0.5);
    return dragAt(c,cast(int)(p[0]+0.5),cast(int)(p[1]+0.5),sx,sy);
}
private DragObservation dragWorld(CameraState c,V3 p,int dx,int dy,int steps=16) {
    const s=projected(c,p); return dragAt(c,cast(int)(s[0]+0.5),cast(int)(s[1]+0.5),dx,dy,steps);
}
private void pressUndo(CameraState c) {
    playAndWait(viewportLine(c)
      ~`{"t":30,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}`~"\n"
      ~`{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}`~"\n");
    foreach(_;0..4) settle();
}

private void runPinnedCell(string mode) {
    establish("TransformMove",mode); const camera=fetchCamera();
    immutable V3 centre=[0.0,0.0,0.0]; const initial=handleScreen();
    const first=dragArrow(camera,120); const t1=transformEval();
    assert(distance(vector(t1["runFrameOrigin"]),centre)<=1e-5,
           "6207 G-"~mode~" run centre must come from the authored rig");
    const h1=add(centre,worldTranslation(t1));
    assert(distance(h1,centre)>0.2,format(
        "6207 G-%s needs a visible gesture: transform=%s state=%s",
        mode,t1,getJson("/api/tool/state")));
    const checkedH1 = h1;
    const p0=projected(camera,centre), p1=projected(camera,checkedH1);
    const expectedScreen=cast(double[2])[initial[0]+p1[0]-p0[0],initial[1]+p1[1]-p0[1]];
    assert(distance2(handleScreen(),expectedScreen)<=1.5,format(
        "6207 G-%s handle must publish c+M*T: t=%s world=%s transform=%s observed=%s expected=%s",
        mode,vector(t1["translate"]),worldTranslation(t1),t1,handleScreen(),expectedScreen));
    const second=dragArrow(camera,13); const h2=add(centre,worldTranslation(transformEval()));
    assertHandleShift(camera,first.releasedHandle,h1,h2,"G-"~mode~" second gesture");
    assert(distance2(second.midHandle,second.releasedHandle)<=1.5,
           "6207 G-"~mode~" second release must not jump");
    command("tool.set TransformMove off");
}

private void runOffGizmoPreset(string tool) {
    establish(tool,"origin"); const camera=fetchCamera();
    immutable V3 centre=[0.0,0.0,0.0]; const initial=handleScreen();
    dragArrow(camera,120); const before=vertex(6);
    const haul=dragWorld(camera,[1.5,0.0,-1.5],13,0);
    const expected=add(centre,worldTranslation(transformEval()));
    assert(distance(vertex(6),before)>0.01,
           "6207 "~tool~" off-gizmo witness must perform a real haul");
    assertHandleShift(camera,initial,centre,expected,tool~" off-gizmo restarted haul");
    assert(distance2(haul.midHandle,haul.releasedHandle)<=1.5,
           "6207 "~tool~" off-gizmo release must not expose the stale prior-run pose");
    command("tool.set "~tool~" off");
}

unittest { // A: Element press-motion-release leaves the handle at c+M*T.
    establishElement(); const camera=fetchCamera(); const centre=vertex(6);
    const drag=dragWorld(camera,centre,120,0); const moved=vertex(6);
    assert(distance(moved,centre)>0.2,format(
        "6207 A needs a real ElementMove gesture: c=%s moved=%s state=%s",
        centre,moved,getJson("/api/tool/state")));
    assertHandleShift(camera,drag.anchorHandle,centre,moved,"A");
    assert(distance2(drag.midHandle,drag.releasedHandle)<=1.5,"6207 A release must not jump");
    Thread.sleep(1000.msecs); assertHandleShift(camera,drag.anchorHandle,centre,moved,"A idle");
    const second=dragArrow(camera,13); const moved2=vertex(6);
    assert(distance(moved2,moved)>0.02,"6207 A second arrow must extend the run");
    assertHandleShift(camera,drag.releasedHandle,moved,moved2,"A second gesture");
    assert(distance2(second.midHandle,second.releasedHandle)<=1.5,"6207 A second release must not jump");
    command("tool.set xfrm.elementMove off");
}

unittest { // G-origin
    runPinnedCell("origin");
}
unittest { // G-pivot
    runPinnedCell("pivot");
}

unittest { // Q: stationary empty Element press restarts the run at H=c.
    establishElement(); const camera=fetchCamera(); const centre=vertex(6);
    const first=dragWorld(camera,centre,120,0); const moved=vertex(6);
    assert(distance(moved,centre)>0.2,"6207 Q needs a visible first run");
    dragWorld(camera,[1.5,0.0,-1.5],0,0,1);
    assert(distance(worldTranslation(transformEval()),[0.0,0.0,0.0])<=1e-5,
           "6207 Q empty press must reset T");
    assertHandleShift(camera,first.anchorHandle,centre,centre,"Q restart");
    assert(distance(vertex(6),centre)>0.2,"6207 Q restart must retain committed geometry");
    const second=dragArrow(camera,13);
    assert(distance2(second.midHandle,second.releasedHandle)<=1.5,"6207 Q post-restart release must not jump");
    command("tool.set xfrm.elementMove off");
}

unittest { // U: Phase 3 undo rewrites the run and leaves it live.
    establish("TransformMove","origin"); const camera=fetchCamera();
    immutable V3 centre=[0.0,0.0,0.0]; const initial=handleScreen();
    dragArrow(camera,120); dragArrow(camera,13);
    assert(distance(worldTranslation(transformEval()),centre)>0.2,"6207 U needs a visible run");
    pressUndo(camera); const undone=transformEval();
    assert(undone["runFrameValid"].type==JSONType.true_,
           "6207 U undo must keep the frozen run frame live");
    const undoneHandle=add(centre,worldTranslation(undone));
    assert(distance(undoneHandle,centre)>0.2,
           "6207 U undo must restore the prior nonzero run total");
    assertHandleShift(camera,initial,centre,undoneHandle,"U undo");
    const after=dragArrow(camera,13);
    assert(distance(worldTranslation(transformEval()),worldTranslation(undone))>0.02,
           "6207 U post-undo arrow must continue the rewritten run");
    assert(distance2(after.midHandle,after.releasedHandle)<=1.5,"6207 U post-undo release must not jump");
    command("tool.set TransformMove off");
}

unittest { // R1: numeric re-grade after a real Element gesture keeps H on v6.
    establishElement(); const camera=fetchCamera(); const centre=vertex(6);
    const drag=dragWorld(camera,centre,60,0);
    assert(distance(vertex(6),centre)>0.1,"6207 R1 setup must be a real gesture");
    command("tool.attr xfrm.elementMove TX 0.8"); settle(); const t=transformEval();
    assert(fabs(number(t["translate"].array[0])-0.8)<=1e-6,"6207 R1 must publish TX=0.8");
    assertHandleShift(camera,drag.anchorHandle,centre,vertex(6),"R1");
    command("tool.set xfrm.elementMove off");
}

unittest { // Off-gizmo haul: reset precedes arm, so release cannot expose stale c+T.
    runOffGizmoPreset("TransformMove");
    runOffGizmoPreset("Transform");

    establishElement(); const camera=fetchCamera();
    dragArrow(camera,120); const centre=vertex(6);
    // The capture does not pin handle pose at press/motion for this direct-haul
    // cell. Only the specified release invariant is asserted here.
    const haul=dragWorld(camera,centre,13,0); const moved=vertex(6);
    assert(distance(moved,centre)>0.01,"6207 Element re-pick must perform a real haul");
    assertHandleShift(camera,haul.anchorHandle,centre,moved,"Element re-pick haul");
    assert(distance2(haul.midHandle,haul.releasedHandle)<=1.5,
           "6207 Element re-pick release must not expose the stale prior-run pose");
    command("tool.set xfrm.elementMove off");
}
