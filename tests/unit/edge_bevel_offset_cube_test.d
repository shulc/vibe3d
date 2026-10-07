module edge_bevel_offset_cube_test;
import mesh : Mesh,edgeKey,MeshEditBatch;
import mesh_ops.edge_bevel : bevelEdgesByMask,kEdgeBevelEditScope;
import math : Vec3;
import std.json : parseJSON,JSONValue,JSONType;
import std.file : readText;
import std.format : format;

unittest {
    auto fixture=parseJSON(readText("tests/fixtures/edge_bevel/offset_cube.json"));
    assert(fixture["cases"].array.length==4,"OFFSET CUBE: four independent native captures");
    foreach(cell;fixture["cases"].array) {
        Mesh m;
        foreach(row;fixture["source"]["vertices"].array)
            m.addVertex(Vec3(cast(float)row[0].floating,cast(float)row[1].floating,cast(float)row[2].floating));
        foreach(row;fixture["source"]["faces"].array) {
            uint[] ring; foreach(v;row.array) ring~=cast(uint)v.integer;
            m.addFace(ring);
        }
        m.rebuildEdges();m.buildLoops();
        auto mask=new bool[](m.edges.length);mask[m.edgeIndexMap[edgeKey(6,7)]]=true;
        auto ed=MeshEditBatch.unrecorded(m,kEdgeBevelEditScope);
        auto n=ed.bevelEdgesByMask(mask,cast(float)cell["width"].floating,
            cast(int)cell["roundLevel"].integer,cell["widthMode"].type==JSONType.true_,
            cast(float)cell["offset"].floating);
        ed.close();
        string witness="OFFSET CUBE "~cell["name"].str;
        assert(n==1,witness~": actual selected edge consumed");
        auto expected=cell["expected"];
        assert(m.vertices.length==expected["vertices"].array.length,
            format("%s: complete point population %s vs%s",witness,m.vertices.length,expected["vertices"].array.length));
        assert(m.faces.length==expected["faces"].array.length,
            format("%s: complete polygon population %s vs%s",witness,m.faces.length,expected["faces"].array.length));
        uint[] ids=new uint[](m.vertices.length);bool[] used=new bool[](ids.length);
        foreach(i,v;m.vertices) {
            size_t match=size_t.max;
            foreach(j,row;expected["vertices"].array) {
                auto refV=Vec3(cast(float)row[0].floating,cast(float)row[1].floating,cast(float)row[2].floating);
                if((v-refV).length<2e-6f) {
                    assert(match==size_t.max,witness~": unique point match");match=j;
                }
            }
            assert(match!=size_t.max,format("%s: unmatched point%s %s",witness,i,v));
            assert(!used[match],witness~": distinct point identity");used[match]=true;ids[i]=cast(uint)match;
        }
        bool[] matched=new bool[](m.faces.length);
        foreach(ring;m.faces) {
            bool found;
            foreach(j,row;expected["faces"].array) {
                if(matched[j]||ring.length!=row.array.length) continue;
                foreach(rotation;0..ring.length) {
                    bool same=true;
                    foreach(k,v;ring) if(ids[v]!=row[(k+rotation)%ring.length].integer) { same=false;break; }
                    if(same) { matched[j]=true;found=true;break; }
                }
                if(found) break;
            }
            assert(found,format("%s: unmatched oriented ring%s",witness,ring));
        }
    }
}
