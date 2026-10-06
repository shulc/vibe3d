// Task 20261040: both registered product doors, full original mesh.
import http_client : getJson, postJson, testBaseUrl;
import std.net.curl : get;
import std.array : replace;
import http_command_helpers : commandBody;
import std.file : readText;
import std.json : JSONValue, JSONType, parseJSON;
import std.format : format;

void main() {}
private double number(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}
private uint bits(JSONValue v) {
    union B {float value; uint raw;}
    B b; b.value=cast(float)number(v); return b.raw;
}
private void cmd(string s) {
    auto j=postJson("/api/command",s);
    assert(j["status"].str=="ok",s~": "~j.toString);
}
private JSONValue model() {
    auto m=getJson("/api/model");
    // Plane dump uses nine digits. Preserve its signed zero before JSON parses
    // the integer token -0; all finite floats can then be scored by their bits.
    auto raw=cast(string)get(testBaseUrl()~"/api/mesh/planes");
    auto planes=parseJSON(raw.replace("-0,","-0.0,").replace("-0]","-0.0]"));
    m["vertices"]=planes["vertices"];
    return m;
}
private JSONValue loadOriginal(JSONValue f) {
    cmd(commandBody("scene.reset",`{"empty":true}`));
    cmd(commandBody("scene.loadMesh",`{"vertices":`~f["model"]["vertices"].toString~
        `,"faces":`~f["model"]["faces"].toString~`}`));
    cmd("select.typeFrom polygon");
    cmd(commandBody("mesh.select",`{"mode":"polygons","indices":[19]}`));
    cmd("history.clear");
    auto before=model();
    assert(before["vertexCount"].integer==90 && before["edgeCount"].integer==162 &&
        before["faceCount"].integer==74,"full original product population");
    foreach(i,v;before["vertices"].array) foreach(a;0..3)
        assert(bits(v[a])==bits(f["model"]["vertices"][i][a]),format("original product input vertex%s.%s expected=%08x actual=%08x",i,"xyz"[a],bits(f["model"]["vertices"][i][a]),bits(v[a])));
    foreach(k;["faces","isSubpatch","faceHidden","vertexHidden","edgeHidden",
            "surfaces","faceMaterial","facePart","selectionSets"])
        assert(before[k]==f["model"][k],"original represented metadata "~k);
    assert(getJson("/api/selection")["selectedFaces"]==f["selection"]["selectedFaces"],
        "original polygon selection");
    assert(getJson("/api/history")["undo"].array.length==0,"history headroom");
    return before;
}
private void score(JSONValue f, JSONValue before, size_t cellIndex, string door) {
    auto cell=f["cells"][cellIndex], got=model();
    assert(cell["weighted"].array.length==18 && got["vertices"].array.length==90,
        "product ring and complement population");
    assert(bits(got["vertices"][73][0])==bits(cell["weighted"][1][0]),
        format("product-%s N%s/%s/%s index1.x",door,cell["side"].integer,
            cell["rotate"].integer,cell["angle"].integer));
    foreach(i;0..90) foreach(a;0..3) {
        auto expected=i<72 ? before["vertices"][i][a] : cell["weighted"][i-72][a];
        assert(bits(got["vertices"][i][a])==bits(expected),
            format("product-%s cell%s vertex%s.%s",door,cellIndex,i,"xyz"[a]));
    }
    foreach(k;["vertexCount","edgeCount","faceCount","faces","edges","isSubpatch",
        "faceHidden","vertexHidden","edgeHidden","surfaces","faceMaterial",
        "facePart","selectionSets"])
        assert(got[k]==before[k],"position edit preserves "~k);
    assert(getJson("/api/selection")["selectedFaces"]==f["selection"]["selectedFaces"],
        "position edit preserves polygon selection");
}
private void restored(JSONValue before) {
    auto got=model();
    assert(got["vertices"].array.length==90,"Undo full vertex population");
    foreach(i,v;got["vertices"].array) foreach(a;0..3)
        assert(bits(v[a])==bits(before["vertices"][i][a]),"actual Undo restores input bits");
    foreach(k;["faces","edges","faceHidden","vertexHidden","edgeHidden",
            "isSubpatch","surfaces","faceMaterial","facePart","selectionSets"])
        assert(got[k]==before[k],"actual Undo restores full input "~k);
    assert(getJson("/api/selection")["selectedFaces"].array.length==1 &&
        getJson("/api/selection")["selectedFaces"][0].integer==19,"Undo selection");
}
private void schema(bool tool) {
    auto reg=getJson("/api/registry?params=1");
    auto ps=reg[tool?"toolParams":"commandParams"][tool?"xfrm.radialAlignTool":"mesh.radial_align"];
    size_t found;
    foreach(p;ps.array) if(p["name"].str=="rotate") {
        ++found;
        assert(p["kind"].str=="Int" && p["value"].type==JSONType.integer,
            tool?"tool Rotate actual schema Int":"command Rotate actual schema Int");
    }
    assert(found==1,"one Rotate schema");
}
unittest { // Command factory, each tuple from fresh original source, Undo/Redo.
    schema(false);
    auto f=parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    assert(f["cells"].array.length==4,"four frozen product cells");
    foreach(c;0..4) {
        auto before=loadOriginal(f), cell=f["cells"][c];
        cmd(format("mesh.radial_align mode:nside side:%s rotate:%s angle:%s weight:1",
            cell["side"].integer,cell["rotate"].integer,cell["angle"].integer));
        score(f,before,c,"command");
        auto h=getJson("/api/history");
        assert(h["undo"].array.length==1,"command recorded position history");
        if(c==3) {
            auto entry=h["undo"][0];
            import std.string : indexOf;
            assert(entry["args"].str.indexOf("rotate:1")>=0 &&
                entry["args"].str.indexOf("angle:23")>=0,"typed command serialized replay");
            auto replayLine=entry["command"].str~" "~entry["args"].str;
            auto replayBefore=loadOriginal(f);
            cmd(replayLine); score(f,replayBefore,3,"command-replay");
        }
        cmd("history.undo"); restored(before);
        cmd("history.redo"); score(f,before,c,"command-redo");
    }
}
unittest { // Fresh registered tool door and Undo; reapply/closed-tool Redo remain findings.
    schema(true);
    auto f=parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    foreach(c;0..4) {
        auto before=loadOriginal(f), cell=f["cells"][c];
        cmd("tool.set xfrm.radialAlignTool on");
        cmd("tool.attr xfrm.radialAlignTool mode nside");
        cmd("tool.attr xfrm.radialAlignTool weight 1");
        cmd(format("tool.attr xfrm.radialAlignTool side %s",cell["side"].integer));
        cmd(format("tool.attr xfrm.radialAlignTool rotate %s",cell["rotate"].integer));
        cmd(format("tool.attr xfrm.radialAlignTool angle %s",cell["angle"].integer));
        auto query=postJson("/api/command","tool.attr xfrm.radialAlignTool rotate ?");
        assert(query["status"].str=="ok" && query["value"].type==JSONType.integer &&
            query["value"].integer==cell["rotate"].integer,
            "tool integer Rotate survived typed attr path");
        cmd("tool.doApply"); score(f,before,c,"tool");
        cmd("tool.set xfrm.radialAlignTool off");
        auto h=getJson("/api/history");
        assert(h["undo"].array.length==2,"tool arm and apply history");
        cmd("history.undo"); restored(before);
        // Closed-tool Redo is retained as a measured open product finding.
    }
}
