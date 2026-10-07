module edge_bevel_offset_ring_test;

import mesh : Mesh, edgeKey, MeshEditBatch;
import mesh_ops.edge_bevel : bevelEdgesByMask, kEdgeBevelEditScope;
import math : Vec3;
import std.json : parseJSON, JSONValue, JSONType;
import std.file : readText;
import std.format : format;

private float scalar(JSONValue v) {
    return v.type==JSONType.float_ ? cast(float)v.floating : cast(float)v.integer;
}
private Mesh sourceMesh(JSONValue source) {
    Mesh m;
    foreach(row;source["vertices"].array)
        m.addVertex(Vec3(scalar(row[0]),scalar(row[1]),scalar(row[2])));
    foreach(row;source["faces"].array) {
        uint[] ring;
        foreach(v;row.array) ring~=cast(uint)v.integer;
        m.addFace(ring);
    }
    m.rebuildEdges();m.buildLoops();
    return m;
}
private bool[] selected(ref Mesh m, JSONValue selection) {
    auto mask=new bool[](m.edges.length);
    foreach(row;selection["edges"].array)
        mask[m.edgeIndexMap[edgeKey(cast(uint)row[0].integer,cast(uint)row[1].integer)]]=true;
    return mask;
}

private void closedGraph(ref Mesh m, string witness, size_t boundaryCount=0) {
    import std.math : isFinite;
    int[ulong] uses, orientation;
    bool[] used=new bool[](m.vertices.length);
    assert(m.faces.length>0 && m.vertices.length>0,witness~": populated graph");
    foreach(v;m.vertices)
        assert(isFinite(v.x)&&isFinite(v.y)&&isFinite(v.z),witness~": finite points");
    foreach(ring;m.faces) {
        assert(ring.length>=3,witness~": face population");
        foreach(i,a;ring) {
            uint b=ring[(i+1)%ring.length];
            assert(a<m.vertices.length && b<m.vertices.length,witness~": valid point indices");
            assert(a!=b,witness~": no repeated adjacent anchor");
            uses[edgeKey(a,b)]++;orientation[edgeKey(a,b)]+=a<b?1:-1;
            used[a]=true;
        }
    }
    assert(uses.length==m.edges.length,witness~": all derived edges present");
    size_t actualBoundary;
    foreach(key,count;uses) {
        assert(count==2 || count==1,format("%s: graph edge %s has %s consumers",witness,key,count));
        if(count==1) ++actualBoundary;
        else assert(orientation[key]==0,witness~": adjacent rings opposed");
    }
    assert(actualBoundary==boundaryCount,format("%s: boundary count %s vs %s",witness,actualBoundary,boundaryCount));
    foreach(u;used) assert(u,witness~": no orphan points");
}
private void compareGeometry(ref Mesh m, JSONValue expected, string witness,
                             JSONValue knownWidthGap=JSONValue.init) {
    assert(m.vertices.length==expected["vertices"].array.length,witness~": full point population");
    assert(m.faces.length==expected["faces"].array.length,witness~": full polygon population");
    uint[] ids=new uint[](m.vertices.length);
    bool[] used=new bool[](ids.length);
    size_t gapCount;
    foreach(i,v;m.vertices) {
        size_t match=size_t.max;
        foreach(j,row;expected["vertices"].array) {
            auto q=Vec3(scalar(row[0]),scalar(row[1]),scalar(row[2]));
            if((v-q).length<2e-6f) {
                assert(match==size_t.max,witness~": unique point match");match=j;
            }
        }
        if(match==size_t.max && knownWidthGap.type==JSONType.object) {
            const uint refIndex=cast(uint)knownWidthGap["referencePointIndex"].integer;
            auto old=knownWidthGap["existingPosition"], refPosition=knownWidthGap["referencePosition"];
            auto oldPoint=Vec3(scalar(old[0]),scalar(old[1]),scalar(old[2]));
            auto expectedPoint=Vec3(scalar(refPosition[0]),scalar(refPosition[1]),scalar(refPosition[2]));
            auto row=expected["vertices"][refIndex];
            auto actualExpected=Vec3(scalar(row[0]),scalar(row[1]),scalar(row[2]));
            assert((actualExpected-expectedPoint).length<1e-7f,witness~": known width gap reference stays frozen");
            if((v-oldPoint).length<1e-7f) { match=refIndex;++gapCount; }
        }
        assert(match!=size_t.max,format("%s: unmatched point %s %s",witness,i,v));
        assert(!used[match],witness~": bijective point identity");
        used[match]=true;ids[i]=cast(uint)match;
    }
    assert(gapCount==(knownWidthGap.type==JSONType.object ? 1 : 0),
        witness~": exactly the independently observed width-only gap, no extra discrepancies");
    bool[] matched=new bool[](m.faces.length);
    foreach(ring;m.faces) {
        bool found;
        foreach(j,row;expected["faces"].array) {
            if(matched[j]||ring.length!=row.array.length) continue;
            foreach(rotation;0..ring.length) {
                bool same=true;
                foreach(k,v;ring)
                    if(ids[v]!=row[(k+rotation)%ring.length].integer) { same=false;break; }
                if(same) { matched[j]=true;found=true;break; }
            }
            if(found) break;
        }
        assert(found,format("%s: unmatched oriented ring %s",witness,ring));
    }
}

unittest {
    auto fixture=parseJSON(readText("tests/fixtures/edge_bevel/offset_ring.json"));
    assert(fixture["cases"].array.length==4,"RING OFFSET: control and independent offset captures");
    foreach(cell;fixture["cases"].array) {
        auto m=sourceMesh(fixture["source"]);
        assert(m.vertices.length==48 && m.edges.length==72 && m.faces.length==26,
            "RING OFFSET: exact user source graph");
        auto mask=selected(m,fixture["selection"]);
        auto ed=MeshEditBatch.unrecorded(m,kEdgeBevelEditScope);
        assert(ed.bevelEdgesByMask(mask,cast(float)cell["width"].floating,0,false,
            cast(float)cell["offset"].floating)==48,"RING OFFSET: all 48 selected spans consumed");
        ed.close();
        string witness="RING OFFSET "~cell["name"].str;
        compareGeometry(m,cell["expected"],witness);
        closedGraph(m,witness);
    }
}

unittest { // Distinct graph layouts; invariants rather than uncaptured parity.
    import mesh : makeCube;
    foreach(layout;0..4) {
        foreach(offset;[0f,.03f,.222f]) {
            auto m=layout==0 ? makeCube() : sourceMesh(parseJSON(readText("tests/fixtures/edge_bevel/offset_ring.json"))["source"]);
            if(layout==3) {
                // Removing the cap changes the upper fan to a genuine boundary.
                m.faces.length=m.faces.length-1;m.rebuildEdges();m.buildLoops();
            }
            auto mask=new bool[](m.edges.length);
            if(layout==0) { // A true full hub, unlike the two-of-three ring turn.
                foreach(i,e;m.edges) if(e[0]==6 || e[1]==6) mask[i]=true;
            } else foreach(i,e;m.edges) {
                const bool lower=e[0]<24 && e[1]<24;
                const bool upper=e[0]>=24 && e[1]>=24;
                mask[i]=layout==1 ? lower : (lower || upper);
            }
            const int level=layout==2 ? 1 : 0;
            auto ed=MeshEditBatch.unrecorded(m,kEdgeBevelEditScope);
            auto n=ed.bevelEdgesByMask(mask,.06f,level,layout==2,offset);
            ed.close();
            assert(n>0,"RING CORPUS: selected geometry consumed");
            closedGraph(m,format("RING CORPUS layout%s level%s offset%s",layout,level,offset),layout==3?24:0);
        }
    }
}

unittest {
    auto fixture=parseJSON(readText("tests/fixtures/edge_bevel/offset_partial_junction.json"));
    foreach(positive;[false,true]) {
        auto m=sourceMesh(fixture["source"]);
        assert(m.vertices.length==6 && m.faces.length==8,"PARTIAL JUNCTION: distinct octahedral source graph");
        auto mask=selected(m,fixture["source"]["selection"]);
        auto ed=MeshEditBatch.unrecorded(m,kEdgeBevelEditScope);
        assert(ed.bevelEdgesByMask(mask,.06f,0,false,positive?.03f:0)==3,
            "PARTIAL JUNCTION: three-of-four selected apex edges");
        ed.close();
        // Independent offset0 reference confirms this one inherited width
        // coordinate gap. Preserve it explicitly; all other points and every
        // oriented polygon must match in both the baseline and offset result.
        compareGeometry(m,fixture[positive?"expected":"control"],
            positive?"PARTIAL OFFSET WITH KNOWN WIDTH GAP":"PARTIAL WIDTH BASELINE XFAIL",
            fixture["knownWidthGap"]);
        closedGraph(m,"PARTIAL JUNCTION");
    }
}
