import std.json : JSONValue, JSONType, parseJSON;
import std.file : readText;
import std.net.curl : get, post;
import core.thread : Thread;
import core.time : msecs;
import std.string : format;
import std.math : abs;
import std.process : environment;

void main() {}
enum string BASE = "http://localhost:8080";
enum string fixtureConsumerProvenance = `{"schema":1,"source":"live-capture","reference_token":"ref-editor@11.2v3","method":"debug-live","captured_utc":"2026-08-31","task":"3690"}`;
JSONValue getJson(string p){return parseJSON(cast(string)get(BASE~p));}
JSONValue postJson(string p,string b){return parseJSON(cast(string)post(BASE~p,b));}
void settle(){Thread.sleep(150.msecs);}
void cmd(string s){auto r=postJson("/api/command",s);assert(r["status"].str=="ok",r.toString);settle();}
void baseline(){postJson("/api/script","tool.set move off");settle();postJson("/api/reset","");cmd("history.clear");}
JSONValue toolGeometryBaseline;
void toolBaseline(){baseline();cmd("mesh.subdivide");cmd("select.element vertex set 9 11 13 15");cmd("history.clear");settle();toolGeometryBaseline=vertices();}
string tool(){auto s=getJson("/api/tool/state");if(!("tool" in s.object))return "none";auto t=s["tool"].str;return t=="xfrm"?"move":t=="slice"?"cutting":t;}
bool canUndo(){return getJson("/api/undo/status")["canUndo"].boolean;}
JSONValue vertices(){return getJson("/api/model")["vertices"];}
bool geomEq(JSONValue a,JSONValue b){if(a.array.length!=b.array.length)return false;foreach(i,row;a.array){foreach(k,v;row.array)if(abs(v.floating-b.array[i].array[k].floating)>1e-8)return false;}return true;}
JSONValue sel(){auto s=getJson("/api/selection");JSONValue[] ids;foreach(v;s["selectedVertices"].array)ids~=v;JSONValue[string] o;o["mode"]="vertices";o["indices"]=JSONValue(ids);return JSONValue(o);}
JSONValue walkPoint(string at,string g){JSONValue[string] o;o["at"]=at;o["geometry"]=g;o["selection"]=sel();return JSONValue(o);}
void play(string path){auto r=postJson("/api/play-events",readText(path));assert(r["status"].str=="success",r.toString);foreach(_;0..400){auto s=getJson("/api/play-events/status");if(s["finished"].type==JSONType.true_){settle();return;}Thread.sleep(20.msecs);}assert(0,"playback timeout");}
JSONValue law(JSONValue fx,string id){foreach(v;fx["laws"].array)if(v["id"].str==id)return v;assert(0,id~": missing law");}
JSONValue rival(string id,JSONValue reference){auto a=parseJSON(reference.toString).array;if(id=="arm_owns_record"){a[0]["record"]="none";a[1]["record"]="new";}else if(id=="move_arm_undo_redo")a[2]["move_family_active"]=true;else if(id=="cutting_arm_undo_redo")a[2]["cutting_family_active"]=false;else if(id=="swap_undo_previous_family")a[2]["tool"]="none";else if(id=="swap_redo_unavailable"){a[1]["result"]="accepted";a[1]["tool"]="cutting";}else if(id=="same_family_on_records_again")a[1]["record"]="none";else if(id=="explicit_off_on_records_on"){a[0]["record"]="new";a[1]["record"]="none";}else if(id=="cutting_arm_owns_record"){a[0]["record"]="none";a[1]["record"]="new";}else if(id=="scripted_selection_undo_redo")a[3]["selection"]=a[2]["selection"];else if(id=="viewport_selection_undo_redo"){foreach(i;3..a.length)a[i]["selection"]=a[2]["selection"];a[3]["geometry"]="g0";a[4]["geometry"]="g0";}return JSONValue(a);}
void retirement(JSONValue l,JSONValue observed){auto id=l["id"].str,status=l["status"].str;bool mut=environment.get("ARM_RECORD_MUTATION","")==id;assert(status=="open"||status=="closed",id~": invalid status");if(mut)observed=rival(id,l["reference"]);auto target=mut?l["reference"]:(status=="open"?l["vibe3d_current"]:l["reference"]);assert(observed==target,id~": mutation mode=reference-shaped target=reference literal_delta="~l["rival_mutation"].str);if(!mut&&status=="open")assert(observed!=l["reference"],id~": XPASS — divergence closed unexpectedly");}
void retirementFull(JSONValue l,JSONValue observed){retirement(l,observed);}
JSONValue point(string at,string t,string record=""){settle();JSONValue[string] o;o["at"]=at;o["tool"]=t;o["geometry"]=geomEq(vertices(),toolGeometryBaseline)?"g0":"changed";o["selection"]=sel();if(record.length)o["record"]=record;return JSONValue(o);}
JSONValue evidencePoint(string at,string record=""){auto p=point(at,tool(),record);p.object.remove("tool");return p;}

unittest {
 auto fx=parseJSON(import("fixtures/tool_arm_undo_trajectory.json"));auto cp=parseJSON(fixtureConsumerProvenance);assert(cp["reference_token"].str==fx["reference_token"].str);
 toolBaseline();bool a0=canUndo();cmd("tool.set move on");auto a=evidencePoint("arm",canUndo()!=a0?"new":"none");bool d0=canUndo();cmd("tool.set move off");auto d=evidencePoint("drop",canUndo()!=d0?"lifecycle":"none");postJson("/api/undo","");settle();auto u=evidencePoint("undo");u["move_family_active"]=(tool()=="move");retirement(law(fx,"arm_owns_record"),JSONValue([a,d,u]));
 toolBaseline();bool ra0=canUndo();cmd("tool.set move on");auto ra=evidencePoint("arm",canUndo()!=ra0?"new":"none");postJson("/api/undo","");settle();auto rau=evidencePoint("undo");postJson("/api/redo","");settle();auto rar=evidencePoint("redo");rar["move_family_active"]=(tool()=="move");retirement(law(fx,"move_arm_undo_redo"),JSONValue([ra,rau,rar]));
 toolBaseline();bool rk0=canUndo();cmd("tool.set mesh.sliceTool on");auto rk=evidencePoint("arm",canUndo()!=rk0?"new":"none");postJson("/api/undo","");settle();auto rku=evidencePoint("undo");postJson("/api/redo","");settle();auto rkr=evidencePoint("redo");rkr["cutting_family_active"]=(tool()=="cutting");retirement(law(fx,"cutting_arm_undo_redo"),JSONValue([rk,rku,rkr]));
 toolBaseline();cmd("tool.set move on");auto m=point("move",tool());cmd("tool.set mesh.sliceTool on");auto k=point("cutting",tool());postJson("/api/undo","");settle();auto su=point("undo",tool());retirement(law(fx,"swap_undo_previous_family"),JSONValue([m,k,su]));
 auto ru=point("undo",tool());auto rr=postJson("/api/redo","");settle();auto rpj=point("redo",tool());rpj["result"]=(rr["status"].str=="ok"?"accepted":"unavailable");retirement(law(fx,"swap_redo_unavailable"),JSONValue([ru,rpj]));
 toolBaseline();cmd("tool.set move on");auto x1a=point("first_on",tool());bool h0=canUndo();cmd("tool.set move on");auto x1b=point("second_on",tool(),canUndo()!=h0?"new":"none");retirement(law(fx,"same_family_on_records_again"),JSONValue([x1a,x1b]));
 toolBaseline();cmd("tool.set move on");bool q0=canUndo();cmd("tool.set move off");auto xo=point("off",tool(),canUndo()!=q0?"lifecycle":"none");bool q1=canUndo();cmd("tool.set move on");auto xn=point("on",tool(),canUndo()!=q1?"new":"none");retirement(law(fx,"explicit_off_on_records_on"),JSONValue([xo,xn]));
 toolBaseline();bool c0=canUndo();cmd("tool.set mesh.sliceTool on");auto ca=evidencePoint("arm",canUndo()!=c0?"new":"none");bool c1=canUndo();cmd("tool.set mesh.sliceTool off");auto cd=evidencePoint("drop",canUndo()!=c1?"new":"none");retirement(law(fx,"cutting_arm_owns_record"),JSONValue([ca,cd]));
 assert(fx["parity_positive_control"]["reference"]==fx["parity_positive_control"]["vibe3d_current"],"tool parity positive control diverged");
}

unittest {
 auto fx=parseJSON(import("fixtures/undo_walk_trajectory.json"));baseline();cmd("select.element vertex set 0");auto g0=vertices();JSONValue[] obs;obs~=walkPoint("selected_a","g0");
 cmd("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{-0.25,-0.5,-0.5}");auto g1=vertices();obs~=walkPoint("edited","g1");play("tests/events/selection_points.log");obs~=walkPoint("selected_b","g1");
 postJson("/api/undo","");settle();obs~=walkPoint("undo_b",geomEq(vertices(),g1)?"g1":geomEq(vertices(),g0)?"g0":"unexpected");postJson("/api/undo","");settle();obs~=walkPoint("undo_edit",geomEq(vertices(),g0)?"g0":geomEq(vertices(),g1)?"g1":"unexpected");postJson("/api/redo","");settle();obs~=walkPoint("redo_edit",geomEq(vertices(),g1)?"g1":"unexpected");postJson("/api/redo","");settle();obs~=walkPoint("redo_b",geomEq(vertices(),g1)?"g1":"unexpected");retirementFull(law(fx,"viewport_selection_undo_redo"),JSONValue(obs));
}

unittest {
 auto fx=parseJSON(import("fixtures/undo_walk_trajectory.json"));baseline();cmd("mesh.subdivide");cmd("history.clear");
 cmd("select.element vertex set 17 19 21 23");auto g0=vertices();JSONValue[] obs;obs~=walkPoint("selected_a","g0");
 auto v=g0.array[17].array;cmd(format("mesh.move_vertex from:{%g,%g,%g} to:{%g,%g,%g}",v[0].floating,v[1].floating,v[2].floating,v[0].floating+0.25,v[1].floating,v[2].floating));auto g1=vertices();assert(g1!=g0,"undo-walk edit did not change geometry");obs~=walkPoint("edited","g1");
 cmd("select.element vertex set 9 11 13 15");obs~=walkPoint("selected_b","g1");
 postJson("/api/undo","");settle();obs~=walkPoint("undo_b",geomEq(vertices(),g1)?"g1":geomEq(vertices(),g0)?"g0":"unexpected");
 postJson("/api/undo","");settle();obs~=walkPoint("undo_edit",geomEq(vertices(),g0)?"g0":geomEq(vertices(),g1)?"g1":"unexpected");
 postJson("/api/redo","");settle();obs~=walkPoint("redo_edit",geomEq(vertices(),g1)?"g1":"unexpected");
 postJson("/api/redo","");settle();obs~=walkPoint("redo_b",geomEq(vertices(),g1)?"g1":"unexpected");
 retirementFull(law(fx,"scripted_selection_undo_redo"),JSONValue(obs));
 assert(fx["parity_positive_control"]["reference"]==fx["parity_positive_control"]["vibe3d_current"],"undo parity positive control diverged");
}
