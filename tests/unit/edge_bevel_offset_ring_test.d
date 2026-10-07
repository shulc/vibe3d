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
    if (boundaryCount != size_t.max) assert(actualBoundary==boundaryCount,format("%s: boundary count %s vs %s",witness,actualBoundary,boundaryCount));
    foreach(u;used) assert(u,witness~": no orphan points");
}
private void compareGeometry(ref Mesh m, JSONValue expected, string witness,
                             JSONValue knownWidthGap=JSONValue.init, size_t retainedPrefix=0) {
    assert(m.vertices.length==expected["vertices"].array.length,witness~": full point population");
    assert(m.faces.length==expected["faces"].array.length,witness~": full polygon population");
    uint[] ids=new uint[](m.vertices.length);
    bool[] used=new bool[](ids.length);
    const widthGaps = knownWidthGap.type == JSONType.object ? [knownWidthGap]
        : knownWidthGap.type == JSONType.array ? knownWidthGap.array : null;
    size_t gapCount;
    foreach(i,v;m.vertices) {
        size_t match=size_t.max;
        foreach(j,row;expected["vertices"].array) {
            if (used[j] || (i < retainedPrefix && i != j)) continue;
            auto q=Vec3(scalar(row[0]),scalar(row[1]),scalar(row[2]));
            if((v-q).length<2e-6f) {
                assert(match==size_t.max,witness~": unique point match");match=j;
            }
        }
        if (match == size_t.max) foreach (gap; widthGaps) {
            const uint refIndex = cast(uint)gap["referencePointIndex"].integer;
            auto old = gap["existingPosition"], refPosition = gap["referencePosition"];
            auto oldPoint=Vec3(scalar(old[0]),scalar(old[1]),scalar(old[2]));
            auto expectedPoint=Vec3(scalar(refPosition[0]),scalar(refPosition[1]),scalar(refPosition[2]));
            auto row=expected["vertices"][refIndex];
            auto actualExpected=Vec3(scalar(row[0]),scalar(row[1]),scalar(row[2]));
            assert((actualExpected-expectedPoint).length<1e-7f,witness~": known width gap reference stays frozen");
            if((v-oldPoint).length<1e-7f) { match=refIndex;++gapCount;break; }
        }
        assert(match!=size_t.max,format("%s: unmatched point %s %s",witness,i,v));
        assert(!used[match],witness~": bijective point identity");
        used[match]=true;ids[i]=cast(uint)match;
    }
    assert(gapCount == widthGaps.length,
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

unittest {
    auto fixture = parseJSON(readText("tests/fixtures/edge_bevel/rounded_offset_stations.json"));
    assert(fixture["cases"].array.length == 6, "ROUNDED OFFSET: independent station captures");
    foreach (cell; fixture["cases"].array) {
        // Preserve the independently captured width-only hub profile gap
        // (20261420). The positive result adds its three derived station gaps;
        // every other point and every oriented polygon must match the capture.
        if (cell["widthMode"].boolean)
            assert(cell["knownWidthGaps"].array.length == (scalar(cell["offset"]) == 0 ? 4 : 7),
                "ROUNDED OFFSET: exact inherited width profile discrepancy population");
        auto m = sourceMesh(cell.object.get("source", fixture["source"]));
        auto mask = selected(m, cell["selection"]);
        auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
        assert(ed.bevelEdgesByMask(mask, scalar(cell["width"]),
            cast(int)cell["roundLevel"].integer, cell["widthMode"].boolean,
            scalar(cell["offset"])) == cell["selection"]["edges"].array.length,
            "ROUNDED OFFSET: every selected span consumed");
        ed.close();
        const witness = "ROUNDED OFFSET " ~ cell["name"].str;
        compareGeometry(m, cell["expected"], witness,
            cell.object.get("knownWidthGaps", JSONValue.init));
        closedGraph(m, witness);
    }
}

private Mesh corpusMesh(int layout) {
    import mesh : makeCube;
    auto m = makeCube();
    if (layout >= 6) {
        m.faces.length = m.faces.length - 1;
        m.rebuildEdges(); m.buildLoops();
    }
    return m;
}
private bool[] corpusSelection(ref Mesh m, int layout) {
    auto mask = new bool[](m.edges.length);
    foreach (i, e; m.edges) {
        switch (layout) {
            case 0: mask[i] = edgeKey(e[0], e[1]) == edgeKey(6, 7); break;
            case 1: mask[i] = (e[0] == 6 || e[1] == 6) && !(e[0] == 2 || e[1] == 2); break;
            case 2: mask[i] = e[0] == 6 || e[1] == 6; break;
            case 3: mask[i] = e[0] >= 4 && e[1] >= 4; break;
            case 4: mask[i] = true; break;
            case 5: mask[i] = e[0] == 6 || e[1] == 6 || e[0] == 0 || e[1] == 0; break;
            case 6: mask[i] = e[0] >= 4 && e[1] >= 4; break;
            case 7: mask[i] = true; break;
            default: assert(0);
        }
    }
    return mask;
}

unittest {
    import std.stdio : writeln;
    uint cells, failed;
    foreach (layout; 0 .. 8) foreach (config; 0 .. 6) {
        auto m = corpusMesh(layout);
        auto mask = corpusSelection(m, layout);
        const float width = config == 0 ? 0 : .06f;
        const float offset = config == 1 ? 0 : .222f;
        const int level = config >= 4 ? 1 : 0;
        const bool widthMode = config == 3 || config == 5;
        auto oldV = m.vertices.dup;
        uint[][] oldF;
        foreach (f; m.faces) oldF ~= f.dup;
        const id = format("OFFSET CORPUS layout%s config%s width%s offset%s round%s mode%s",
            layout, config, width, offset, level, widthMode);
        if (layout < 6 && width > 0 && offset > 0) {
            auto control = corpusMesh(layout);
            auto cm = corpusSelection(control, layout);
            auto ce = MeshEditBatch.unrecorded(control, kEdgeBevelEditScope);
            assert(ce.bevelEdgesByMask(cm, width, level, widthMode, 0) > 0);
            ce.close();
            closedGraph(control, id ~ " WIDTH-ONLY CONTROL");
        }
        try {
            auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
            auto n = ed.bevelEdgesByMask(mask, width, level, widthMode, offset);
            ed.close();
            if (n == 0) assert(m.vertices == oldV && m.faces == oldF, id ~ ": atomic refusal");
            else closedGraph(m, id, layout >= 6 ? size_t.max : 0);
        } catch (Throwable e) {
            ++failed;
            writeln(id, " FAIL ", e.msg);
        }
        ++cells;
    }
    assert(cells == 48, "OFFSET CORPUS: independent population");
    writeln("OFFSET-CORPUS cells=", cells, " failed=", failed);
    assert(failed == 0, "Independent geometry corpus failed");
}

unittest {
    foreach (layout; [2, 4, 5]) foreach (widthMode; [false, true]) {
        auto m = corpusMesh(layout);
        auto mask = corpusSelection(m, layout);
        auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
        assert(ed.bevelEdgesByMask(mask, .06f, 2, widthMode, .222f) > 0,
            "ROUNDED OFFSET L2: selected spans consumed");
        ed.close();
        closedGraph(m, format("ROUNDED OFFSET L2 layout%s mode%s", layout, widthMode));
    }
}

unittest {
    import std.stdio : writeln;
    auto fixture = parseJSON(readText("tests/fixtures/edge_bevel/zero_width_ring.json"));
    assert(fixture["cases"].array.length == 17, "ZERO WIDTH CORPUS: seventeen independent captures");
    uint cells, failed, existingWidthGap, existingPointGap;
    foreach (cell; fixture["cases"].array) {
        const witness = "ZERO WIDTH CORPUS " ~ cell["name"].str;
        try {
            auto m = sourceMesh(cell.object.get("source", fixture["source"]));
            auto mask = selected(m, cell.object.get("selection", fixture["selection"]));
            const sourceCount = m.vertices.length;
            const width = scalar(cell["width"]), offset = scalar(cell["offset"]);
            const selectionCount = cell.object.get("selection", fixture["selection"])["edges"].array.length;
            auto ed = MeshEditBatch.unrecorded(m, kEdgeBevelEditScope);
            const n = ed.bevelEdgesByMask(mask, width, cast(int)cell["roundLevel"].integer, cell["widthMode"].boolean, offset);
            ed.close();
            assert(n == (width == 0 && offset == 0 ? 0 : selectionCount),
                witness ~ ": positive offset consumes every selected span");
            if (auto baseline = "existingWidthGeometry" in cell.object) {
                assert(cell["knownGapTask"].integer == 20261471, witness ~ ": recorded width gap task");
                bool differs;
                try { compareGeometry(m, cell["expected"], witness); }
                catch (Throwable error) { differs = true; }
                assert(differs, witness ~ ": inherited width geometry must differ from native");
                compareGeometry(m, *baseline, witness ~ " EXISTING WIDTH XFAIL");
                ++existingWidthGap;
                writeln(witness, " EXISTING-WIDTH-XFAIL task=20261471");
            } else {
                compareGeometry(m, cell["expected"], witness,
                    cell.object.get("knownWidthGap", JSONValue.init), width == 0 ? sourceCount : 0);
                if ("knownWidthGap" in cell.object) {
                    ++existingPointGap;
                    writeln(witness, " EXISTING-POINT-XFAIL task=20261381");
                } else writeln(witness, " NATIVE-EXACT ", m.vertices.length, "V", m.edges.length, "E", m.faces.length, "F");
            }
            closedGraph(m, witness, cell.object.get("boundaryCount", JSONValue(0)).integer);
        } catch (Throwable error) {
            ++failed; writeln(witness, " FAIL ", error.msg);
        }
        ++cells;
    }
    assert(cells == 17, "ZERO WIDTH CORPUS: measured population floor");
    assert(existingWidthGap == 1, "ZERO WIDTH CORPUS: exactly one independently observed whole-width XFAIL");
    assert(existingPointGap == 1, "ZERO WIDTH CORPUS: exactly one inherited support-point XFAIL");
    writeln("ZERO-WIDTH-CORPUS cells=", cells, " existingWidthXfail=", existingWidthGap,
        " existingPointXfail=", existingPointGap, " failed=", failed);
    assert(failed == 0, "ZERO WIDTH CORPUS: complete native geometry required");
}
