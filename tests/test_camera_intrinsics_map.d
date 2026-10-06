module test_camera_intrinsics_map;
import perspective_camera_rig_helpers : PerspectiveCameraRig;
import http_client : postJson;
import drag_helpers : fetchCamera,viewportFromCamera,Vec3;
import math : ProductionViewport=Viewport, ProductionVec3=Vec3;
import drag : preparePlaneDrag,HandleDrag,DragFrame,DragKind,viewWorldPerPixel;
import viewgrid : viewVectorQuantum,g_viewGrid,ViewGridPrefs;
import std.math : abs;
void main() {}
unittest {
    auto rig=PerspectiveCameraRig.launch();scope(exit)rig.stop();const base=rig.base;
    assert(postJson("/api/camera",`{"orientation":[0.2004414573445789,0.5011036433614473,-0.8418541208472314,-0.9284766908852593,0.37139067635410367,0,0.3126567713329426,0.7816419283323567,0.5397051409913891],"focus":{"x":0,"y":0,"z":0},"distance":4,"fovY":0.9026584025557545}`,base)["status"].str=="ok");
    const transported=viewportFromCamera(fetchCamera(base));
    const h=Vec3(-.10000000149011612f,.30000001192092896f,.94868332147598267f);
    // Source-backed imports can execute unrelated arithmetic units first.
    // Use the same shipped grid defaults as the fresh owned editor.
    const oldGrid=g_viewGrid;scope(exit)g_viewGrid=oldGrid;g_viewGrid=ViewGridPrefs.init;
    ProductionViewport eventVp;
    eventVp.view=transported.view;eventVp.proj=transported.proj;
    eventVp.width=1152;eventVp.height=974;eventVp.x=150;eventVp.y=28;
    eventVp.eye=ProductionVec3(transported.eye.x,transported.eye.y,transported.eye.z);
    eventVp.focus=ProductionVec3(0,0,0);
    const anchor=ProductionVec3(h.x,h.y,h.z);
    const prepared=preparePlaneDrag(anchor,3,eventVp);
    assert(prepared.valid&&prepared.jacobian.axisU==ProductionVec3(0,0,1)&&prepared.jacobian.axisV==ProductionVec3(1,0,0),"HTTP_EVENT_MAP_ZX");
    assert(abs(prepared.jacobian.i00+.00343550649)<2e-8&&abs(prepared.jacobian.i01-.000517097244)<2e-8&&
           abs(prepared.jacobian.i10+.000127120846)<2e-8&&abs(prepared.jacobian.i11-.00360459881)<2e-8,"HTTP_EVENT_MAP_INVERSE");
    assert(abs(viewWorldPerPixel(eventVp)-.8*4/1004.7545731629976)<2e-9,"HTTP_EVENT_MAP_PIXEL_K");
    assert(viewVectorQuantum(eventVp)==.005f,"HTTP_EVENT_MAP_QUANTUM");
    HandleDrag translator;translator.press(anchor,522,452);bool skip;
    const travel=prepared.apply(592,452,522,452);
    assert(abs(travel.x+.00889845922)<2e-6&&abs(travel.z+.2404854543)<2e-6,"HTTP_EVENT_MAP_T");
    const point=translator.client(592,452,DragFrame(DragKind.viewPlane),eventVp,skip);
    assert((point-anchor-ProductionVec3(-.01f,0,-.24f)).length<1e-6,"HTTP_EVENT_NO_GUIDE_DQ");
}
