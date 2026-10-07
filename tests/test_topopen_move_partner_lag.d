// 9504: measured lagged-partner fidelity. Prefixes are indexed by the retained
// GDB DWS query chain; screenshot labels are one evaluation late.
import drag_helpers : Vec3, fetchCamera, playAndWait, buildDragDownLog, buildDragMotionLog, buildDragUpLog;
import pen_rig_helpers : penSceneEmpty, penCommand, penCameraAt, worldPixel, readVerts;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.math : abs;
import std.format : format;
import std.process : environment;
void main() {}
private void cell(string name,string body,int stride,int onset,int held,int free,int total,float tx,float ty,float partner) {
    if(environment.get("VIBE3D_CELL","all")!="all" && environment.get("VIBE3D_CELL","all")!=name) return;
    foreach(prefix;[onset,held,free,total]) {
        penSceneEmpty("Front");
        assert(postJson("/api/command",commandBody("scene.loadMesh",body))["status"].str=="ok");
        penCommand("viewport.view Front"); penCameraAt(Vec3(0,0,0),100);
        penCommand("tool.set mesh.topoPen on");
        penCommand("tool.attr mesh.topoPen mode move"); penCommand("tool.attr mesh.topoPen backFace true");
        penCommand("tool.pipe.attr snap types \"\"");
        penCommand("tool.pipe.attr symmetry axis x"); penCommand("tool.pipe.attr symmetry enabled true");
        assert(readVerts().length==11 && getJson("/api/model")["faces"].array.length==3,"partner fixture population");
        auto from=worldPixel(Vec3(.4,0,0)); auto cam=fetchCamera();
        playAndWait(buildDragDownLog(cam.vpX,cam.vpY,cam.width,cam.height,from[0],from[1]));
        playAndWait(buildDragMotionLog(cam.vpX,cam.vpY,cam.width,cam.height,from[0],from[1],from[0]+prefix*stride,from[1],prefix));
        auto vs=readVerts();
        const snapped=prefix==onset || prefix==held;
        if(snapped) {
            assert(vs.length==10,"held vertex absorption population");
            assert(abs(vs[5].x-partner)<1e-5 && abs(vs[5].y-ty)<1e-5,
                format("%s prefix=%s: captured lagged partner expected (%s,%s) got %s",name,prefix,partner,ty,vs[5]));
            assert(abs(vs[7].x-tx)<1e-5 && abs(vs[7].y-ty)<1e-5,"target survivor retains exact captured endpoint");
        } else {
            const x=.4f+prefix*stride/100.0f;
            assert(vs.length==11,"released raw frame restores original population");
            assert(abs(vs[1].x-x)<1e-5 && abs(vs[1].y)<1e-5 && abs(vs[6].x+x)<1e-5 && abs(vs[6].y)<1e-5,
                format("%s prefix=%s: raw source and reciprocal partner, got %s / %s",name,prefix,vs[1],vs[6]));
        }
        playAndWait(buildDragUpLog(cam.vpX,cam.vpY,cam.width,cam.height,from[0]+prefix*stride,from[1]));
        assert(readVerts()==vs,"release retains the last evaluated vertex frame");
    }
}
unittest { cell("W2c_O",`{"vertices":[[0.1,0.0,0.0],[0.4,0.0,0.0],[0.4,0.4,0.0],[0.1,0.4,0.0],[-0.1,0.4,0.0],[-0.4,0.4,0.0],[-0.4,0.0,0.0],[-0.1,0.0,0.0],[0.72,-0.06,0.0],[0.6,-0.4,0.0],[0.84,-0.4,0.0]],"faces":[[0,1,2,3],[4,5,6,7],[8,9,10]]}`,4,3,11,14,20,0.720f,-0.060f,-0.800f); }
unittest { cell("W2c_O2",`{"vertices":[[0.1,0.0,0.0],[0.4,0.0,0.0],[0.4,0.4,0.0],[0.1,0.4,0.0],[-0.1,0.4,0.0],[-0.4,0.4,0.0],[-0.4,0.0,0.0],[-0.1,0.0,0.0],[0.7,-0.06,0.0],[0.58,-0.4,0.0],[0.82,-0.4,0.0]],"faces":[[0,1,2,3],[4,5,6,7],[8,9,10]]}`,10,1,5,6,8,0.700f,-0.060f,-0.700f); }
unittest { cell("W2c_O4",`{"vertices":[[0.1,0.0,0.0],[0.4,0.0,0.0],[0.4,0.4,0.0],[0.1,0.4,0.0],[-0.1,0.4,0.0],[-0.4,0.4,0.0],[-0.4,0.0,0.0],[-0.1,0.0,0.0],[0.72,-0.14,0.0],[0.6,-0.4,0.0],[0.84,-0.4,0.0]],"faces":[[0,1,2,3],[4,5,6,7],[8,9,10]]}`,4,4,12,13,20,0.720f,-0.140f,-0.840f); }
