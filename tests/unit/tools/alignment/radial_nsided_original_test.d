module tests.unit.tools.alignment.radial_nsided_original_test;

import std.file : readText;
import std.json : JSONValue, JSONType, parseJSON;
import std.format : format;
import math : Vec3;
import mesh : Mesh;
import editmode : EditMode;
import tools.alignment.align_kernels : radialAlignTargets, extractAlignChain;
import falloff : weightedLerp;

private double number(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}
private Vec3 vector(JSONValue v) {
    return Vec3(cast(float)number(v[0]), cast(float)number(v[1]), cast(float)number(v[2]));
}
private uint bits(float v) {
    union FloatBits { float value; uint raw; }
    FloatBits b; b.value = v; return b.raw;
}
private JSONValue fixture() {
    return parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
}
private Mesh original(JSONValue f) {
    Mesh m;
    foreach (v; f["model"]["vertices"].array) m.vertices ~= vector(v);
    foreach (face; f["model"]["faces"].array) {
        uint[] ids;
        foreach (v; face.array) ids ~= cast(uint)v.integer;
        m.addFace(ids);
    }
    m.buildLoops(); m.syncSelection(); m.selectFace(19);
    assert(m.vertices.length == 90 && m.edges.length == 162 && m.faces.length == 74,
        "original full mesh population 90/162/74");
    return m;
}
private Vec3[] source(JSONValue f, ref Mesh m) {
    auto chain = extractAlignChain(&m, EditMode.Polygons);
    assert(f["cells"].array.length == 4 && f["orderedIds"].array.length == 18,
        "four captured cells and eighteen ordered IDs");
    assert(chain.verts.length == 18 && m.vertices.length - chain.verts.length == 72,
        "eighteen moving vertices and nonempty seventy-two vertex complement");
    Vec3[] src;
    foreach (k, vi; chain.verts) {
        assert(vi == 72 + k && f["orderedIds"][k].integer == vi,
            "original chain mapping 72+k");
        const s = m.vertices[vi];
        foreach (cell; f["cells"].array) {
            assert(cell["source"].array.length == 18 && cell["target"].array.length == 18 &&
                cell["castBits"].array.length == 18 && cell["weighted"].array.length == 18 &&
                cell["sdk"].array.length == 18, "captured triple population");
            const saved = vector(cell["source"][k]);
            assert(s == saved, "captured source maps to original mesh");
            foreach (other; 0 .. k)
                assert(saved != vector(cell["source"][other]), "unique original source mapping");
        }
        src ~= s;
    }
    return src;
}
private void score(size_t cellIndex, size_t witness, size_t axis, string label) {
    auto f = fixture(); auto m = original(f); auto src = source(f, m);
    auto cell = f["cells"][cellIndex];
    const side = cast(int)cell["side"].integer;
    const rotate = cast(int)cell["rotate"].integer;
    const angle = cast(float)cell["angle"].integer;
    auto target = radialAlignTargets(src, true, side, angle, rotate);
    assert(target.length == 18, "shipping target population eighteen");
    float component(Vec3 v, size_t a) { return a == 0 ? v.x : a == 1 ? v.y : v.z; }
    const expected = cast(uint)cell["castBits"][witness][axis].integer;
    const actual = bits(component(target[witness], axis));
    assert(actual == expected, format("%s expected=%08x actual=%08x", label, expected, actual));
    foreach (i, v; target) foreach (a; 0 .. 3) {
        const want = cast(uint)cell["castBits"][i][a].integer;
        assert(bits(component(v, a)) == want,
            format("cast-target N%s/%s/%s index%s.%s expected=%08x actual=%08x",
                side, rotate, angle, i, "xyz"[a], want, bits(component(v, a))));
        const weighted = weightedLerp(src[i], target[i], 1);
        assert(bits(component(weighted, a)) == bits(component(vector(cell["weighted"][i]), a)) &&
            bits(component(weighted, a)) == bits(component(vector(cell["sdk"][i]), a)),
            "separate frozen weighted postimage equals independent mesh readback");
    }
}

// The mutation selectors isolate the named witness before exhaustive scoring.
unittest {
    version (RadialOrdinary) {}
    else version (RadialNegative) score(0, 9, 0, "cast-target N6/0/0 negative residual index9.x");
    else version (RadialFiveResidual) score(1, 0, 0, "cast-target N5/0/0 positive residual index0.x");
    else version (RadialInterior) score(0, 1, 0, "cast-target N6/0/0 index1.x");
    else version (RadialEarlyCast) score(1, 3, 0, "cast-target N5/0/0 index3.x");
    else version (RadialKnots) score(1, 4, 0, "cast-target N5/0/0 knot4.x");
    else version (RadialRemainder) score(1, 1, 0, "cast-target N5/0/0 index1.x");
    else version (RadialClosing) score(2, 0, 0, "cast-target N5/1/0 index0.x");
    else version (RadialRotate) score(2, 1, 0, "cast-target N5/1/0 index1.x");
    else version (RadialAngle) score(3, 1, 0, "cast-target N5/1/23 index1.x");
    else version (RadialFrame) score(0, 0, 2, "cast-target N6/0/0 index0.z");
    else {
        score(0, 0, 0, "cast-target N6/0/0 positive residual index0.x");
        score(0, 9, 0, "cast-target N6/0/0 negative residual index9.x");
        score(1, 0, 0, "cast-target N5/0/0 positive residual index0.x");
        score(1, 3, 0, "cast-target N5/0/0 index3.x");
        score(0, 1, 0, "cast-target N6/0/0 index1.x");
        score(1, 1, 0, "cast-target N5/0/0 index1.x");
        score(2, 0, 0, "cast-target N5/1/0 index0.x");
        score(2, 1, 0, "cast-target N5/1/0 index1.x");
        score(3, 1, 0, "cast-target N5/1/23 index1.x");
    }
}

unittest { // OUR ordinary arithmetic, independent direct C declarations.
    import core.stdc.math : cSin = sin, cCos = cos;
    import std.math : PI, atan, sqrt, abs;
    enum double pi = cast(double)PI;
    double angleOf(double x, double y) {
        if (x == 0) return y > 0 ? pi/2.0 : -pi/2.0;
        const double a = atan(y/x);
        return x > 0 ? a : y < 0 ? a-pi : a+pi;
    }
    Vec3[] src = [Vec3(0,.25,-1),Vec3(-.75,.25,-.75),Vec3(-1,.25,0),
        Vec3(-.75,.25,.75),Vec3(0,.25,1),Vec3(.75,.25,.75),
        Vec3(1,.25,0),Vec3(.75,.25,-.75)];
    double[3] center=0;
    foreach (v; src) {center[0]+=v.x;center[1]+=v.y;center[2]+=v.z;}
    foreach (ref c; center) c *= 1.0/src.length;
    double radius=0;
    foreach (v; src) {
        const double x=v.x-center[0], y=v.y-center[1], z=v.z-center[2];
        radius += sqrt((x*x+y*y)+z*z);
    }
    radius /= src.length;
    // Symmetric axis input has equal zero keys; first stays index0.
    assert(src.length == 8 && center == [0.0,.25,0.0] && radius > 1,
        "ordinary input fit and positive winding population");
    foreach (degrees; [23.0f,-23.0f]) {
        enum size_t a=1, count=5, q=1, remainder=3;
        const double nominalArg=((2.0*pi)/cast(double)src.length)*a;
        const double beta=angleOf(src[a].z-center[2],src[a].x-center[0]);
        const double correction=beta-angleOf(cCos(nominalArg),cSin(nominalArg));
        const double alpha=cast(double)degrees*(pi/180.0)+correction;
        double[3][] corners;
        size_t[] knots;
        size_t nonAxis;
        foreach (j;0..count) {
            const double phi=alpha+cast(double)j*((2.0*pi)/count);
            assert(phi != 0 && abs(cSin(phi)) > .01 && abs(cCos(phi)) > .01,
                "ordinary nonzero non-axis arguments");
            ++nonAxis;
            corners ~= [center[0]+radius*cSin(phi),center[1],center[2]+radius*cCos(phi)];
            knots ~= (a+j*q+(j<remainder?j:remainder))%src.length;
        }
        assert(nonAxis==5 && (degrees>0 ? corners[0][0]<0 : corners[0][0]>0) && corners[0][2]<0,
            "ordinary argument and signed output population");
        auto target=radialAlignTargets(src,true,5,degrees,1);
        assert(target.length==8,"ordinary shipping target population");
        double[3][8] want;
        foreach(j;0..count) {
            want[knots[j]]=corners[j];
            const gap=q+(j<remainder?1:0);
            foreach(t;1..gap) foreach(axis;0..3)
                want[(knots[j]+t)%8][axis]=corners[j][axis]+
                    (corners[(j+1)%count][axis]-corners[j][axis])*(cast(double)t/gap);
        }
        foreach(i,v;target) foreach(axis,actual;[v.x,v.y,v.z])
            assert(bits(actual)==bits(cast(float)want[i][axis]),
                format("ordinary C-double %s index%s.%s",degrees,i,"xyz"[axis]));
    }
}

unittest { // Instruction-derived allocation clamp and cyclic integer control.
    Vec3[] tri=[Vec3(0,.25,-1),Vec3(-1,.25,.5),Vec3(1,.25,.5)];
    auto clamped=radialAlignTargets(tri,true,5,0,0);
    auto three=radialAlignTargets(tri,true,3,0,0);
    assert(clamped.length==3 && three.length==3,"three-point shipping population");
    foreach(i,v;clamped) foreach(a,actual;[v.x,v.y,v.z]) {
        const want=[three[i].x,three[i].y,three[i].z][a];
        assert(bits(actual)==bits(want),"instruction-derived m3/N5 clamp");
    }
    auto f=fixture();auto m=original(f);auto src=source(f,m);
    auto positive=radialAlignTargets(src,true,5,23,1);
    foreach(rotate;[-17,19]) {
        auto wrapped=radialAlignTargets(src,true,5,23,rotate);
        assert(wrapped.length==18,"cyclic integer shipping population");
        foreach(i,v;wrapped) foreach(a,actual;[v.x,v.y,v.z]) {
            const want=[positive[i].x,positive[i].y,positive[i].z][a];
            assert(bits(actual)==bits(want),"integer Rotate negative/positive modulo");
        }
    }
}

unittest { // N-sided bypasses outside search, with a flipping Circle control.
    Vec3[] src=[Vec3(-.5,-.5,-.5),Vec3(.707106769f,-.5,0),
        Vec3(.5,-.5,.5),Vec3(-.5,-.5,.5)];
    Vec3[][] outside=[[Vec3(-.5,.5,-.5)],[Vec3(.5,.5,-.5)],
        [Vec3(.5,.5,.5)],[Vec3(-.5,.5,.5)]];
    auto circle=radialAlignTargets(src,false,4,0,0);
    auto searched=radialAlignTargets(src,false,4,0,0,outside);
    assert(bits(circle[0].x)!=bits(searched[0].x),"Circle outside control flips");
    auto plain=radialAlignTargets(src,true,3,0,1);
    auto held=radialAlignTargets(src,true,3,0,1,outside);
    assert(plain.length==4 && held.length==4,"outside control shipping population");
    foreach(i,v;held) foreach(a,actual;[v.x,v.y,v.z]) {
        const want=[plain[i].x,plain[i].y,plain[i].z][a];
        assert(bits(actual)==bits(want),"N-sided outside invariant");
    }
}
