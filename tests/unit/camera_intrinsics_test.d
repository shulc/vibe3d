module tests.unit.camera_intrinsics_test;

import view : View, ProjKind, ViewPreset;
import viewport : ViewportManager, LayoutPreset, applyCellViewPreset;
import math : Vec3, Orientation, perspectiveMatrix, projectToWindowFull;
import drag : preparePlaneDrag, HandleDrag, DragFrame, DragKind;
import std.math : PI, tan, abs, isFinite;
import std.json : parseJSON;
import std.exception : assertThrown;
import std.stdio : writefln;

private uint bits(float v) { return *cast(uint*)&v; }
private enum double capturedLens = 0.9026584025557545;
private View capturedCamera() {
    auto c = new View(150,28,1152,974);
    c.distance=4;
    c.setOrientation(Orientation.fromBasis(
        Vec3(.2004414573445789f,.5011036433614473f,-.8418541208472314f),
        Vec3(-.9284766908852593f,.37139067635410367f,0),
        Vec3(.3126567713329426f,.7816419283323567f,.5397051409913891f)));
    c.setFovY(capturedLens);
    return c;
}

unittest {
    auto c = new View(0,0,650,544);
    const old = perspectiveMatrix(45.0f*PI/180.0f,650.0f/544,.001f,100);
    assert(c.viewport().proj == old,"LENS_DEFAULT_EXACT");
    const before = c.viewport(); c.setFovY(c.fovY);
    assert(c.viewport().proj == before.proj,"LENS_SAME_VALUE_EXACT");
    c.setFovY(capturedLens);
    const snap = c.viewport();
    const encoded = parseJSON(c.toJson())["fovY"].floating;
    assert(bits(c.fovY)==bits(cast(float)encoded),"LENS_CODEC_BIT_EXACT");
    auto twin = new View(0,0,650,544); twin.setFovY(encoded);
    assert(twin.viewport().proj == snap.proj,"LENS_CODEC_PROJECTION");
    c.setFovY(1.123456789);
    assert(snap.proj != c.viewport().proj,"LENS_SNAPSHOT_A_RETAINS");
    c.reset(); assert(bits(c.fovY)==bits(View.defaultFovY),"LENS_RESET");
    foreach(bad;[0.0,-1.0,PI,PI+1, double.nan,double.infinity,-double.infinity,1e-300,1e-100]) {
        auto prior = c.toJson(); assertThrown(c.setFovY(bad));
        assert(c.toJson()==prior,"LENS_INVALID_NO_WRITE");
    }
    c.projKind=ProjKind.Ortho;
    const ortho=c.viewport().proj;
    Vec3 f1,f2; float d1,d2;
    c.computeFrame([Vec3(-1,-2,-3),Vec3(1,2,3)],f1,d1);
    c.setFovY(capturedLens);
    assert(c.viewport().proj==ortho,"LENS_ORTHO_EXACT");
    c.computeFrame([Vec3(-1,-2,-3),Vec3(1,2,3)],f2,d2);
    assert(d1==d2 && f1==f2,"LENS_ORTHO_FRAME_EXACT");
    c.projKind=ProjKind.Perspective;
    assert(c.viewport().proj!=old,"LENS_RETURN_PERSPECTIVE_RETAINS");
}

unittest {
    auto c=new View(0,0,100,100);c.setFovY(capturedLens);
    foreach(candidate;[1e-38,1e-29]) {
        const n=cast(float)candidate;
        const float t=tan(n*.5f), f=1.0f/t;
        assert(n>0 && cast(double)n<PI && isFinite(t) && t>0 && isFinite(f) && f>0,
               "LENS_OVERFLOW_REACHED_SCALAR");
        const square=perspectiveMatrix(n,1,.001f,100)[0];
        const tall=perspectiveMatrix(n,.5f,.001f,100)[0];
        if(candidate==1e-29) assert(isFinite(square)&&isFinite(tall),"LENS_CURRENT_ASPECT_POSITIVE");
        const extreme=perspectiveMatrix(n,cast(float)1/cast(float)int.max,.001f,100)[0];
        assert(!isFinite(extreme),"LENS_ENDPOINT_OVERFLOW_PREMISE");
        if(candidate==1e-38) assert(!isFinite(tall),"LENS_HALF_ASPECT_OVERFLOW_PREMISE");
        writefln("LENS-DOMAIN supplied=%.9g bits=%x tangent=%.9g f=%.9g square=%.9g half=%.9g endpoint=%.9g",candidate,bits(n),t,f,square,tall,extreme);
        foreach(kind;[ProjKind.Perspective,ProjKind.Ortho]) {
            c.projKind=kind;
            assertThrown(c.setFovY(candidate),"LENS_ALL_ASPECTS_REFUSED");
            assert(bits(c.fovY)==bits(cast(float)capturedLens),"LENS_ALL_ASPECTS_REFUSED");
        }
    }
    c.setFovY(1e-28);
    writefln("LENS-ACCEPTED bits=%x f=%.9g min=%.9g max=%.9g",bits(c.fovY),1.0f/tan(c.fovY*.5f),
        perspectiveMatrix(c.fovY,cast(float)1/cast(float)int.max,.001f,100)[0],
        perspectiveMatrix(c.fovY,cast(float)int.max,.001f,100)[0]);
    c.projKind=ProjKind.Perspective;const saved=bits(c.fovY);
    int[2][] sizes=[[1,int.max],[int.max,1],[100,200],[200,100],[1152,974],[100,100]];
    foreach(s;sizes) {
        c.setSize(s[0],s[1]);const p=c.viewport().proj;
        assert(c.width==s[0]&&c.height==s[1]&&bits(c.fovY)==saved,"LENS_SIZE_RETAINED");
        assert(p[0]>0&&p[5]>0,"LENS_COEFFICIENTS_POSITIVE");
        foreach(v;p) assert(isFinite(v),"LENS_RETAINED_PROJECTION_FINITE");
    }
    c.setSize(0,-2);assert(c.width==0&&c.height==-2&&bits(c.fovY)==saved,"LENS_COLLAPSED_LEGACY");
    c.setSize(1152,974);assert(isFinite(c.viewport().proj[0]),"LENS_COLLAPSED_RESTORED");
}

unittest { // order isolates a current-aspect-only mutation at the transition
    auto c=new View(0,0,100,100);c.setFovY(capturedLens);
    bool refused; try c.setFovY(1e-29);catch(Exception){refused=true;}
    c.setSize(1,int.max);
    assert(isFinite(c.viewport().proj[0]),"LENS_RETAINED_PROJECTION_FINITE");
    assert(refused,"LENS_TRANSITION_REFUSED");
}

unittest {
    auto vpm=new ViewportManager(150,28,1152,974);
    float[4] lenses=[View.defaultFovY,cast(float)capturedLens,1.1f,.7f];
    foreach(i,c;vpm.views)c.camera.setFovY(lenses[i]);
    foreach(layout;[LayoutPreset.Single,LayoutPreset.SplitH,LayoutPreset.SplitV,LayoutPreset.Quad]) {
        vpm.applyLayout(layout);
        foreach(i,c;vpm.views) {
            assert(bits(c.camera.fovY)==bits(lenses[i]),"LENS_LAYOUT_RETAINED");
            foreach(p;__traits(allMembers,ViewPreset)) {
                applyCellViewPreset(c,mixin("ViewPreset."~p));
                assert(bits(c.camera.fovY)==bits(lenses[i]),"LENS_PRESET_RETAINED");
            }
        }
    }
    vpm.applyLayout(LayoutPreset.Quad);
    foreach(i,c;vpm.views) {
        applyCellViewPreset(c,ViewPreset.Perspective);
        auto vp=vpm.resolvedSnapshot(cast(int)i);
        assert(vp.proj[5]==perspectiveMatrix(lenses[i],1,.001f,100)[5],"LENS_FOLLOW_OWN_CELL");
        c.winW=1;c.winH=int.max;
        assert(isFinite(vpm.resolvedSnapshot(cast(int)i).proj[0]),"LENS_FORWARDING_FINITE");
        c.winH=1;c.winW=int.max;
        assert(isFinite(vpm.resolvedSnapshot(cast(int)i).proj[0]),"LENS_FORWARDING_REVERSE_FINITE");
    }
    vpm.resetToDefault();
    foreach(c;vpm.views)assert(bits(c.camera.fovY)==bits(View.defaultFovY),"LENS_FOUR_CELL_RESET");
}

unittest {
    auto c=capturedCamera();const vp=c.viewport();
    const h=Vec3(-.10000000149011612f,.30000001192092896f,.94868332147598267f);
    assert(vp.width==1152&&vp.height==974&&vp.x==150&&vp.y==28,"ORBIT_PANE");
    assert((vp.eye-Vec3(1.2506270853f,3.1265677133f,2.158820564f)).length<1e-6,"ORBIT_FULL_BASIS_EYE");
    // Binary32 gamma(12), max input rounding 6e-8 and depth>3 bound pixel
    // propagation below .002px; frozen focal/basis independently precede map.
    float x,y,z;assert(projectToWindowFull(h,vp,x,y,z));
    assert(abs(x-521.5579634664997)<.002&&abs(y-452.5187742230622)<.002,"ORBIT_INTRINSIC_FIRST_SEAM");
    const map=preparePlaneDrag(h,3,vp);
    assert(map.valid&&map.jacobian.axisU==Vec3(0,0,1)&&map.jacobian.axisV==Vec3(1,0,0),"ORBIT_MAP_ZX");
    assert(abs(map.jacobian.i00+.00343550649)<2e-8&&abs(map.jacobian.i01-.000517097244)<2e-8&&
           abs(map.jacobian.i10+.000127120846)<2e-8&&abs(map.jacobian.i11-.00360459881)<2e-8,"ORBIT_MAP_INVERSE");
    HandleDrag g;g.press(h,522,452);bool skip;
    const dq=g.client(592,452,DragFrame(DragKind.viewPlane),vp,skip)-h;
    assert((dq-Vec3(-.01f,0,-.24f)).length<1e-6,"ORBIT_NO_GUIDE_DQ");
}
