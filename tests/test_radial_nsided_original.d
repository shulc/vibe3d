// Task 20261040: both registered product doors, full original mesh.
import forms : loadForms, RowKind, parseBinding, substituteQuery;
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
unittest { // Fresh registered tool door, actual inverse and closed-tool forward replay.
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
        assert(getJson("/api/tool/state").object.length == 0, "closed tool state absent");
        cmd("history.redo"); score(f,before,c,"closed-tool-redo");
        assert(getJson("/api/tool/state").object.length == 0, "closed Redo must not rearm");
        assert(getJson("/api/history")["undo"].array.length==2, "closed Redo adds no row");
        cmd("history.undo"); restored(before);
    }
}

private void attrs(JSONValue cell) {
    cmd("tool.attr xfrm.radialAlignTool mode nside");
    cmd("tool.attr xfrm.radialAlignTool weight 1");
    cmd(format("tool.attr xfrm.radialAlignTool side %s",cell["side"].integer));
    cmd(format("tool.attr xfrm.radialAlignTool rotate %s",cell["rotate"].integer));
    cmd(format("tool.attr xfrm.radialAlignTool angle %s",cell["angle"].integer));
    foreach(key;["side","rotate","angle"]) {
        auto query=postJson("/api/command","tool.attr xfrm.radialAlignTool "~key~" ?");
        assert(query["status"].str=="ok" && number(query["value"])==number(cell[key]),
            "same-arm accepted attrs "~key);
    }
}
unittest { // Four independent goldens, one arm and retained ORIGINAL evaluation input.
    auto f=parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    auto before=loadOriginal(f);
    cmd("tool.set xfrm.radialAlignTool on");
    const token=getJson("/api/tool/state")["session"]["token"].integer;
    assert(token>0,"same-arm nonempty identity");
    foreach(c;0..4) {
        attrs(f["cells"][c]);
        assert(getJson("/api/tool/state")["session"]["token"].integer==token,
            "same armed instance token before scoring reapply");
        if(c>0) score(f,before,c-1,"attrs-inert");
        else restored(before);
        assert(getJson("/api/history")["undo"].array.length==c+1,
            "same arm has one activation and one row per accepted apply");
        if(c==1) {
            cmd("tool.attr xfrm.radialAlignTool weight 0");
            auto refusal=postJson("/api/command","tool.doApply");
            assert(refusal["status"].str=="error","radial zero-write reapply must refuse");
            score(f,before,0,"refusal-inverse");
            assert(getJson("/api/history")["undo"].array.length==2,
                "refused radial reapply publishes no row");
            cmd("tool.attr xfrm.radialAlignTool weight 1");
        }
        cmd("tool.doApply");
        score(f,before,c,"tool");
    }
    // Each command's immediate inverse is the previous visible result.
    foreach_reverse(c;0..4) {
        cmd("history.undo");
        if(c>0) score(f,before,c-1,"immediate-inverse"); else restored(before);
    }
    foreach(c;0..4) { cmd("history.redo"); score(f,before,c,"same-arm-redo"); }
    cmd("tool.set xfrm.radialAlignTool off");
}
unittest { // History panel jump reader walks the same owned closed payload.
    auto f=parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    auto before=loadOriginal(f);
    cmd("tool.set xfrm.radialAlignTool on"); attrs(f["cells"][0]);
    cmd("tool.doApply"); score(f,before,0,"jump-control");
    cmd("tool.set xfrm.radialAlignTool off");
    auto r=postJson("/api/history/jump",`{"target":1}`);
    assert(r["status"].str=="ok","closed panel jump Undo"); restored(before);
    r=postJson("/api/history/jump",`{"target":2}`);
    assert(r["status"].str=="ok","closed panel jump Redo"); score(f,before,0,"jump-redo");
    assert(getJson("/api/tool/state").object.length==0,"panel replay must keep tool absent");
}

unittest { // Actual reset and mesh-rebuild doors end the original operation window.
    auto f=parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    foreach(reset;[true,false]) {
        auto before=loadOriginal(f);
        cmd("tool.set xfrm.radialAlignTool on"); attrs(f["cells"][0]);
        cmd("tool.doApply"); score(f,before,0,"reset-control");
        if(reset) {
            cmd("tool.reset");
            cmd("tool.set xfrm.radialAlignTool off");
        }
        // Reload the original through the real geometry-rebuild/reset owner.
        before=loadOriginal(f);
        cmd("tool.set xfrm.radialAlignTool on"); attrs(f["cells"][1]);
        cmd("tool.doApply"); score(f,before,1,"reset-new-source");
        cmd("tool.set xfrm.radialAlignTool off");
    }
}

unittest { // A warm zero-weight member keeps the visible result, not the retained input.
    auto f=parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    auto before=loadOriginal(f);
    cmd("tool.set xfrm.radialAlignTool on"); attrs(f["cells"][0]);
    cmd("tool.doApply"); score(f,before,0,"mixed-weight-control");
    auto first=model();
    assert(bits(first["vertices"][76][0])!=bits(before["vertices"][76][0]),
        "mixed-weight zero member must distinguish visible and source positions");
    attrs(f["cells"][1]);
    cmd("tool.pipe.attr falloff type linear");
    cmd("tool.pipe.attr falloff start \"0,0,0\"");
    cmd("tool.pipe.attr falloff end \"-0.01,0,0\"");
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.doApply");
    auto after=model();
    assert(bits(after["vertices"][86][0])!=bits(first["vertices"][86][0]),
        "mixed-weight positive member must actually apply");
    foreach(a;0..3)
        assert(bits(after["vertices"][76][a])==bits(first["vertices"][76][a]),
            "warm zero-weight member keeps immediate visible result");
    cmd("tool.set xfrm.radialAlignTool off");
}

// Task 20261200: read the shipped panel, then execute its actual Apply route.
unittest {
    auto panels = loadForms("config/forms/radial_align.yaml");
    assert(panels.length == 1, "radial panel population");
    auto panel = panels[0];
    assert(panel.matchesTool("xfrm.radialAlignTool"), "radial panel matches toolbar activation");
    string apply;
    size_t controls;
    foreach (row; panel.rows) {
        if (row.kind == RowKind.cmd) {
            assert(apply.length == 0, "one radial panel action");
            apply = row.command;
        } else if (row.kind == RowKind.control) ++controls;
    }
    assert(controls == 5, "radial panel exposes all five live attributes");
    assert(apply == "tool.doApply", "radial panel exposes the real Apply door");
    auto f = parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    auto before = loadOriginal(f);
    cmd("tool.set xfrm.radialAlignTool on");
    foreach (c; 0..2) {
        foreach (row; panel.rows) if (row.kind == RowKind.control) {
            auto binding = parseBinding(row.command);
            auto key = binding.attr;
            auto value = key == "mode" ? "nside" : key == "weight" ? "1" :
                format("%s", f["cells"][c][key].integer);
            cmd(substituteQuery(binding, key == "mode" ? JSONValue(value) : parseJSON(value)));
        }
        auto response = postJson("/api/command?origin=ui", apply);
        assert(response["status"].str == "ok", "radial panel UI Apply accepted");
        score(f, before, c, "panel-apply");
    }
    cmd("tool.set xfrm.radialAlignTool off");
}
