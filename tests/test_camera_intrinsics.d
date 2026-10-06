module test_camera_intrinsics;
import perspective_camera_rig_helpers : PerspectiveCameraRig;
import http_client : getJson,postJson,keepAliveGet;
import drag_helpers : fetchCamera,viewportFromCamera,viewportFromCameraMatrices,projectToWindow,Vec3,
    playAndWait,kPaceLine;
import std.json : JSONValue,JSONType,parseJSON;
import std.math : abs,isFinite,PI,tan,sqrt;
import std.string : splitLines;
import std.path : buildPath,dirName;
import http_command_helpers : commandBody;
import std.format : format;
import core.thread : Thread;
import core.time : msecs;

void main() {}
private bool selected(string cell) { import std.process:environment;const requested=environment.get("VIBE3D_LENS_CELL","all");return requested=="all"||requested==cell; }
private double num(JSONValue j) {
    return j.type==JSONType.integer?cast(double)j.integer:j.type==JSONType.uinteger?cast(double)j.uinteger:j.floating;
}
private void settle(){Thread.sleep(160.msecs);}
private enum string pose=`"orientation":[0.2004414573445789,0.5011036433614473,-0.8418541208472314,-0.9284766908852593,0.37139067635410367,0,0.3126567713329426,0.7816419283323567,0.5397051409913891],"focus":{"x":0,"y":0,"z":0},"distance":4`;

unittest {
    if(!selected("original"))return;
    auto rig=PerspectiveCameraRig.launch();scope(exit)rig.stop();
    const base=rig.base;
    auto post(string body){return postJson("/api/camera",body,base);}
    auto camera(){return getJson("/api/camera",base);}
    const defaultCam=camera();
    assert(cast(float)num(defaultCam["fovY"])==cast(float)(45.0f*PI/180.0f),"HTTP_LENS_DEFAULT");
    assert(post("{"~pose~`,"fovY":0.9026584025557545}`).toString.length>0);
    auto c=camera();
    assert(abs(num(c["fovY"])-.9026584025557545)<3e-8,"HTTP_LENS_APPLIED");
    assert(c["width"].integer==1152&&c["height"].integer==974&&c["vpX"].integer==150&&c["vpY"].integer==28,"HTTP_REAL_MATCHED_PANE");
    assert(c["viewMatrix"].array.length==16&&c["projMatrix"].array.length==16&&c["orientation"].array.length==9,"HTTP_FULL_CAMERA_POPULATION");
    // Bounds: gamma(12) binary32 arithmetic, 6e-8 input rounding, depth>3.
    // .002px also covers six-decimal fixture position inputs; no result fitting.
    const h=Vec3(-.10000000149011612f,.30000001192092896f,.94868332147598267f);
    auto vp=viewportFromCameraMatrices(base);float x,y;
    assert(projectToWindow(h,vp,x,y));
    assert(abs(x-521.5579634664997)<.002&&abs(y-452.5187742230622)<.002,"HTTP_ORBIT_INTRINSIC_FIRST_SEAM");
    const fetched=fetchCamera(base);
    assert(fetched.fovY==cast(float)num(c["fovY"]),"HTTP_HELPER_LENS_TRANSPORT");
    auto transported=viewportFromCamera(fetched);
    assert(transported.view==vp.view&&transported.proj==vp.proj,"HTTP_HELPER_FULL_MATRIX_TRANSPORT");
    // Independent focal/basis projection precedes the finite-difference map.
    const double[3] right=[.2004414573445789,.5011036433614473,-.8418541208472314];
    const double[3] up=[-.9284766908852593,.37139067635410367,0];
    const double[3] back=[.3126567713329426,.7816419283323567,.5397051409913891];
    const double[3][6] landmarks=[ [.1,.1,.9899494647979736],[.3,.1,.9486833214759827],
        [-.3,.3,.9055384993553162],[-.1,.3,.9486833214759827],[.1,.3,.9486833214759827],[.3,.3,.9055384993553162] ];
    foreach(p;landmarks) {
        double r=0,u=0,b=0;
        foreach(i;0..3){const w=p[i]-4*back[i];r+=right[i]*w;u+=up[i]*w;b+=back[i]*w;}
        assert(-b>3,"HTTP_LANDMARK_DEPTH_FLOOR");
        const ox=726+1004.7545731629976*r/-b,oy=515-1004.7545731629976*u/-b;
        float sx,sy;assert(projectToWindow(Vec3(cast(float)p[0],cast(float)p[1],cast(float)p[2]),transported,sx,sy));
        assert(abs(sx-ox)<.002&&abs(sy-oy)<.002,"HTTP_INDEPENDENT_SIX_LANDMARKS");
    }
    const before=c.toString;
    const history=getJson("/api/history",base);
    const selection=getJson("/api/selection",base);
    const vertices=getJson("/api/model",base)["vertices"];
    assert(post(`{}`).toString.length>0);
    assert(camera().toString==before,"HTTP_MISSING_LENS_RETAINS");
    assert(post(format(`{"fovY":%.9g}`,num(c["fovY"])))["status"].str=="ok");
    assert(camera().toString==before,"HTTP_SAME_LENS_NO_WRITE");
    foreach(bad;["0","-1","3.141592653589793","1e-38","1e-29","1e-100","null","true","[]",`"no"`]) {
        auto r=post(`{"fovY":`~bad~`,"distance":9,"focus":{"x":2,"y":3,"z":4},"orientation":[1,0,0,0,1,0,0,0,1],"width":500,"height":1000}`);
        assert(r["status"].str=="error","HTTP_LENS_REFUSED "~bad);
        assert(camera().toString==before,"HTTP_LENS_INVALID_ATOMIC "~bad);
        assert(getJson("/api/history",base)==history&&getJson("/api/selection",base)==selection&&
               getJson("/api/model",base)["vertices"]==vertices,"HTTP_LENS_INVALID_MODEL_HISTORY_SELECTION "~bad);
    }
    foreach(lens;["1","2","0.9026584025557545","1e-28"]) {
        assert(post(`{"fovY":`~lens~`}`)["status"].str=="ok","HTTP_NUMERIC_LENS");
        const kept=camera()["fovY"];
        foreach(size;[[500,1000],[1000,500],[1152,974]]) {
            assert(post(format(`{"width":%d,"height":%d}`,size[0],size[1]))["status"].str=="ok");
            auto now=camera();assert(now["fovY"]==kept,"HTTP_SIZE_ONLY_RETAINS");
            foreach(v;now["projMatrix"].array)assert(isFinite(num(v)),"HTTP_RETAINED_PROJECTION_FINITE");
        }
    }
    // Fresh player: no VIEWPORT-bearing preparation before the authored route.
    assert(post("{"~pose~`,"fovY":0.9026584025557545}`)["status"].str=="ok");
    rig.command("scene.reset");
    const path=buildPath(dirName(__FILE_FULL_PATH__),"fixtures/topology_pen_session_rig.v3d");
    assert(postJson("/api/command",commandBody("file.load",format(`{"path":%s}`,JSONValue(path).toString)),base)["status"].str=="ok");
    rig.command("history.clear");rig.command("tool.set mesh.topoPen on");
    rig.command("tool.attr mesh.topoPen mode move");
    assert(post("{"~pose~`,"fovY":0.9026584025557545}`)["status"].str=="ok");
    const mesh=getJson("/api/model",base);
    assert(mesh["vertexCount"].integer==16&&mesh["faceCount"].integer==9&&mesh["edgeCount"].integer==24,"HTTP_ORIGINAL_FG_FLOOR");
    const layers=getJson("/api/layers",base)["layers"].array;
    assert(layers.length==2&&layers[1]["vertexCount"].integer==482&&layers[1]["faceCount"].integer==512,"HTTP_ORIGINAL_BG_FLOOR");
    string log=kPaceLine~`{"t":0,"type":"SDL_KEYDOWN","sym":1073741882,"mod":0,"repeat":0}`~"\n"~`{"t":1,"type":"SDL_KEYDOWN","sym":1073742048,"mod":64,"repeat":0}`~"\n"~
        `{"t":2,"type":"SDL_MOUSEBUTTONDOWN","button":1,"x":522,"y":452,"mod":64}`~"\n";
    foreach(i;0..35)log~=format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":452,"xrel":2,"yrel":0,"state":1,"mod":64}`~"\n",i+3,524+2*i);
    log~=`{"t":38,"type":"SDL_MOUSEBUTTONUP","button":1,"x":592,"y":452,"mod":64}`~"\n"~
        `{"t":39,"type":"SDL_KEYUP","sym":1073742048,"mod":0,"repeat":0}`~"\n"~
        `{"t":40,"type":"SDL_KEYDOWN","sym":1073741883,"mod":0,"repeat":0}`~"\n";
    playAndWait(log,base);
    auto input=getJson("/api/input/context",base);
    assert(input["cursorX"].integer==592&&input["cursorY"].integer==452,"HTTP_AUTHORED_ROUTE_DELIVERED");
    const recording=cast(string)keepAliveGet(base~"/api/recorded-events");
    size_t motions,presses,metas;long dx;
    foreach(line;recording.splitLines) {
        auto e=parseJSON(line);
        if(e["type"].str=="VIEWPORT") {
            ++metas;assert(abs(num(e["fovY"])-.9026584025557545)<3e-8,"HTTP_RECORDING_LENS");
        }
        if(e["type"].str=="SDL_MOUSEBUTTONDOWN") {
            ++presses;assert(e["x"].integer==522&&e["y"].integer==452,"HTTP_AUTHORED_PRESS");
        }
        if(e["type"].str=="SDL_MOUSEMOTION") {
            assert(e["x"].integer==524+2*motions&&e["y"].integer==452&&e["xrel"].integer==2&&e["yrel"].integer==0,"HTTP_DELIVERED_MOTION");
            ++motions;dx+=e["xrel"].integer;
        }
    }
    assert(motions==35&&dx==70&&presses==1&&metas==1,"HTTP_AUTHORED_DELIVERY_POPULATION");
    assert(getJson("/api/tool/state",base)["stepVerts"].array==[JSONValue(13)],"HTTP_ORIGINAL_V13_ROUTE");
    import std.process : environment;
    import std.file : mkdirRecurse,write;
    const evidenceDir=environment.get("VIBE3D_LENS_EVIDENCE_DIR","");
    if(evidenceDir.length) {
        mkdirRecurse(evidenceDir);
        write(buildPath(evidenceDir,"authored.jsonl"),log);
        write(buildPath(evidenceDir,"recorded.jsonl"),recording);
        write(buildPath(evidenceDir,"camera.json"),camera().toString~"\n");
        write(buildPath(evidenceDir,"model-before.json"),mesh.toString~"\n");
        write(buildPath(evidenceDir,"model-after.json"),getJson("/api/model",base).toString~"\n");
        write(buildPath(evidenceDir,"player-status.json"),getJson("/api/play-events/status",base).toString~"\n");
    }

}

unittest {
    if(!selected("fbo"))return;
    auto rig=PerspectiveCameraRig.launch();scope(exit)rig.stop();const base=rig.base;
    settle();const a=getJson("/api/frames/counts",base)["totals"];
    settle();const b=getJson("/api/frames/counts",base)["totals"];
    const considered=num(b["cellsConsidered"])-num(a["cellsConsidered"]);
    const rendered=num(b["cellsRendered"])-num(a["cellsRendered"]);
    assert(considered>=3&&rendered<considered,"FBO_DIRTY_KEY_ACTUAL_COMPARE");
    auto initial=getJson("/api/viewport/probe?cell=0&hash=1",base);
    assert(postJson("/api/camera",`{"fovY":1.2}`,base)["status"].str=="ok");settle();
    auto changed=getJson("/api/viewport/probe?cell=0&hash=1",base);
    assert(initial["renders"].boolean&&initial["w"].integer==1152&&initial["h"].integer==974&&initial["hash"].str.length==16,"FBO_POPULATED_CELL");
    assert(initial["hash"]!=changed["hash"],"FBO_LENS_ONLY_REFRESH");
    assert(postJson("/api/camera",`{"fovY":1.2}`,base)["status"].str=="ok");settle();
    assert(getJson("/api/viewport/probe?cell=0&hash=1",base)==changed,"FBO_LENS_SETTLED");
}

unittest {
    if(!selected("gpu"))return;
    auto rig=PerspectiveCameraRig.launch();scope(exit)rig.stop();const base=rig.base;
    rig.command("scene.reset");rig.command("select.typeFrom vertex");
    const fa=487.0/tan(cast(double)cast(float)(45.0f*PI/180.0f)*.5),fb=1004.7545731629976;
    const xa=400/fa,xb=400/fb;
    const body=format(`{"vertices":[[%.9g,0.002,0],[%.9g,-0.03,0],[%.9g,-0.03,0],[%.9g,0.002,0],[%.9g,-0.03,0],[%.9g,-0.03,0]],"faces":[[0,1,2],[3,4,5]]}`,
        xa,xa-.03,xa+.03,xb,xb-.03,xb+.03);
    assert(postJson("/api/command",commandBody("scene.loadMesh",body),base)["status"].str=="ok");
    assert(postJson("/api/camera",`{"orientation":[1,0,0,0,1,0,0,0,1],"focus":{"x":0,"y":0,"z":0},"distance":4}`,base)["status"].str=="ok");
    // loadMesh resets the camera. Seed its final pose before the counted
    // baseline, then a reversible geometry write refreshes the upload key.
    // There are no mesh writes between the lens-only A/B/A observations.
    foreach(dz;[0.01,-0.01])
        assert(postJson("/api/command",commandBody("mesh.transform",format(`{"kind":"translate","delta":[0,0,%.9g]}`,dz)),base)["status"].str=="ok");
    const model=getJson("/api/model",base);
    assert(model["vertexCount"].integer==6&&model["faceCount"].integer==2,"GPU_LENS_POPULATED_TRIANGLES");
    int row;
    foreach(lens;[cast(float)(45.0f*PI/180.0f),.902658403f,cast(float)(45.0f*PI/180.0f)]) {
        assert(postJson("/api/camera",format(`{"fovY":%.9g}`,lens),base)["status"].str=="ok");
        playAndWait(kPaceLine~`{"t":1,"type":"SDL_MOUSEMOTION","x":826,"y":515,"xrel":0,"yrel":0,"state":0,"mod":0}`~"\n",base);settle();
        const expected=row==1?3:0;
        const vp=viewportFromCamera(fetchCamera(base));
        float closest=1e6,second=1e6;int nearest=-1;
        foreach(i,a;model["vertices"].array) {
            float px,py;assert(projectToWindow(Vec3(cast(float)num(a[0]),cast(float)num(a[1]),cast(float)num(a[2])),vp,px,py));
            const d=sqrt((px-826)*(px-826)+(py-515)*(py-515));
            if(d<closest){second=closest;closest=d;nearest=cast(int)i;}else if(d<second)second=d;
        }
        assert(nearest==expected&&closest<1&&second>4,"GPU_LENS_ADMITTED_CANDIDATE_MARGIN");
        const cpu=getJson("/api/pick?x=826&y=515&engine=bvh",base)["faceIndex"].integer;
        assert(cpu==expected/3,"GPU_LENS_CPU_FACE_CONTROL");
        assert(getJson("/api/toolpipe/eval",base)["hover"]["vertex"].integer==expected,"GPU_LENS_ACTUAL_CACHED_ID");
        assert(getJson("/api/pick?x=826&y=515&engine=gpu",base)["faceIndex"].integer==cpu,"GPU_LENS_CPU_GPU_AGREE");
        ++row;
    }
}

unittest { // SIZE_CHANGED reaches current metadata; journal header stays at start
    if(!selected("resize"))return;
    auto rig=PerspectiveCameraRig.launch();scope(exit)rig.stop();const base=rig.base;
    playAndWait(kPaceLine~`{"t":1,"type":"SDL_KEYDOWN","sym":1073741882,"mod":0,"repeat":0}`~"\n",base);
    assert(postJson("/api/camera",`{"fovY":0.9026584025557545}`,base)["status"].str=="ok");
    playAndWait(kPaceLine~`{"t":1,"type":"SDL_WINDOWEVENT","sub":6,"w":1302,"h":1030}`~"\n"~
        `{"t":2,"type":"SDL_KEYDOWN","sym":1073741883,"mod":0,"repeat":0}`~"\n",base);
    size_t metas;double lens;
    foreach(line;(cast(string)keepAliveGet(base~"/api/recorded-events")).splitLines) {
        const e=parseJSON(line);if(e["type"].str=="VIEWPORT"){++metas;lens=num(e["fovY"]);}
    }
    assert(metas==1&&cast(float)lens==cast(float)(45.0f*PI/180.0f),"HTTP_RESIZE_RECORDING_START_HEADER_RETAINED");
    const c=getJson("/api/camera",base);
    assert(c["width"].integer==1152&&c["height"].integer==974&&abs(num(c["fovY"])-.9026584025557545)<3e-8,"HTTP_SIZE_EVENT_ACTUAL_PANE_LENS_RETAINED");
}

unittest { // an ortho recording keeps the historical projection-kind placeholder
    if(!selected("ortho"))return;
    auto rig=PerspectiveCameraRig.launch();scope(exit)rig.stop();const base=rig.base;
    assert(postJson("/api/camera",`{"fovY":0.9026584025557545}`,base)["status"].str=="ok");
    rig.command("viewport.view Top");
    const c=getJson("/api/camera",base);
    assert(c["projKind"].str=="Ortho"&&abs(num(c["fovY"])-.9026584025557545)<3e-8,"HTTP_RECORDING_ORTHO_RETAINED_LENS");
    playAndWait(kPaceLine~`{"t":1,"type":"SDL_KEYDOWN","sym":1073741882,"mod":0,"repeat":0}`~"\n"~
        `{"t":2,"type":"SDL_KEYDOWN","sym":1073741883,"mod":0,"repeat":0}`~"\n",base);
    size_t metas;
    foreach(line;(cast(string)keepAliveGet(base~"/api/recorded-events")).splitLines) {
        const e=parseJSON(line);if(e["type"].str=="VIEWPORT") {
            ++metas;assert(cast(float)num(e["fovY"])==cast(float)(45.0f*PI/180.0f),"HTTP_RECORDING_ORTHO_PLACEHOLDER");
        }
    }
    assert(metas==1,"HTTP_RECORDING_ORTHO_HEADER_POPULATION");
}
