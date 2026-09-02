import std.json : JSONValue, JSONType, parseJSON;
import std.file : readText;
import std.net.curl : get, post;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.string : format, split;
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
long lifecycleCount(){return getJson("/api/undo/status")["toolLifecycleCount"].integer;}
JSONValue vertices(){return getJson("/api/model")["vertices"];}
bool geomEq(JSONValue a,JSONValue b){if(a.array.length!=b.array.length)return false;foreach(i,row;a.array){foreach(k,v;row.array)if(abs(v.floating-b.array[i].array[k].floating)>1e-8)return false;}return true;}
JSONValue sel(){auto s=getJson("/api/selection");JSONValue[] ids;foreach(v;s["selectedVertices"].array)ids~=v;JSONValue[string] o;o["mode"]="vertices";o["indices"]=JSONValue(ids);return JSONValue(o);}
JSONValue walkPoint(string at,string g){JSONValue[string] o;o["at"]=at;o["geometry"]=g;o["selection"]=sel();return JSONValue(o);}
void play(string path){auto r=postJson("/api/play-events",readText(path));assert(r["status"].str=="success",r.toString);foreach(_;0..400){auto s=getJson("/api/play-events/status");if(s["finished"].type==JSONType.true_){settle();return;}Thread.sleep(20.msecs);}assert(0,"playback timeout");}
JSONValue law(JSONValue fx,string id){foreach(v;fx["laws"].array)if(v["id"].str==id)return v;assert(0,id~": missing law");}
struct RivalResult { JSONValue trajectory; string[] paths; }
JSONValue pathValue(JSONValue trajectory,string path){auto p=path.split(".");assert(p.length==2,"invalid rival path: "~path);return trajectory.array[p[0].to!size_t][p[1]];}
void assertRivalLive(JSONValue reference,JSONValue mutated,string[] paths){foreach(path;paths)assert(pathValue(mutated,path)!=pathValue(reference,path),"inert rival path: "~path);}
string selectionToken(JSONValue symbols,JSONValue literal,string id,string at,string side){assert(literal["mode"].str=="vertices",format("%s %s %s: expected vertex selection literal",id,at,side));foreach(token,indices;symbols.object)if(literal["indices"]==indices)return token;assert(0,format("%s %s %s: selection literal resolves to no symbol",id,at,side));}
JSONValue fixtureTrajectory(JSONValue l,string side){auto a=parseJSON(l[side].toString).array;auto symbolSide=side=="vibe3d_current"?"vibe3d":side;foreach(ref row;a){auto token=row["selection"].str;auto resolved=selectionToken(l["symbols"][symbolSide],row["selection_literal"],l["id"].str,row["at"].str,symbolSide);assert(resolved==token,format("%s %s %s: selection literal resolves to %s, expected %s",l["id"].str,row["at"].str,symbolSide,resolved,token));row.object.remove("selection_literal");}return JSONValue(a);}
JSONValue observedTrajectory(JSONValue l,JSONValue observed){if(!("symbols" in l.object))return observed;auto a=parseJSON(observed.toString).array;foreach(ref row;a)row["selection"]=selectionToken(l["symbols"]["vibe3d"],row["selection"],l["id"].str,row["at"].str,"vibe3d");return JSONValue(a);}
RivalResult rival(string id,JSONValue reference){
 auto a=parseJSON(reference.toString).array;string[] paths;
 if(id=="arm_owns_record"){a[0]["record"]="none";paths~="0.record";a[1]["record"]="new";paths~="1.record";}
 else if(id=="move_arm_undo_redo"){a[2]["move_family_active"]=true;paths~="2.move_family_active";}
 else if(id=="cutting_arm_undo_redo"){a[2]["cutting_family_active"]=false;paths~="2.cutting_family_active";}
 else if(id=="swap_undo_previous_family"){a[2]["tool"]="none";paths~="2.tool";}
 else if(id=="swap_redo_unavailable"){a[1]["result"]="accepted";paths~="1.result";a[1]["tool"]="cutting";paths~="1.tool";}
 else if(id=="same_family_on_records_again"){a[1]["record"]="none";paths~="1.record";}
 else if(id=="explicit_off_on_records_on"){a[0]["record"]="new";paths~="0.record";a[1]["record"]="none";paths~="1.record";}
 else if(id=="cutting_arm_owns_record"){a[0]["record"]="none";paths~="0.record";a[1]["record"]="new";paths~="1.record";}
 else if(id=="scripted_selection_undo_redo"){a[3]["selection"]=a[2]["selection"];paths~="3.selection";a[4]["geometry"]="g1";paths~="4.geometry";}
 else if(id=="viewport_selection_undo_redo"){
  // redo_b restores B under both laws, so row 6 is not a rival discriminator.
  foreach(i;3..a.length-1){a[i]["selection"]=a[2]["selection"];paths~=format("%s.selection",i);}
  a[3]["geometry"]="g0";paths~="3.geometry";a[4]["geometry"]="g1";paths~="4.geometry";
 }
 return RivalResult(JSONValue(a),paths);
}
void retirement(JSONValue l,JSONValue observed){
 auto id=l["id"].str,status=l["status"].str;
 auto reference="symbols" in l.object?fixtureTrajectory(l,"reference"):l["reference"];
 auto current="vibe3d_current" in l.object?("symbols" in l.object?fixtureTrajectory(l,"vibe3d_current"):l["vibe3d_current"]):reference;
 auto alternative=rival(id,reference);assertRivalLive(reference,alternative.trajectory,alternative.paths);
 bool mut=environment.get("ARM_RECORD_MUTATION","")==id;assert(status=="open"||status=="closed",id~": invalid status");
 observed=mut?alternative.trajectory:observedTrajectory(l,observed);
 auto target=mut?reference:(status=="open"?current:reference);
 assert(observed==target,id~": observed="~observed.toString~" target="~target.toString~" literal_delta="~l["rival_mutation"].str);
 if(!mut&&status=="open")assert(observed!=reference,id~": XPASS — divergence closed unexpectedly");
}
void retirementFull(JSONValue l,JSONValue observed){retirement(l,observed);}
JSONValue point(string at,string t,string record=""){settle();JSONValue[string] o;o["at"]=at;o["tool"]=t;o["geometry"]=geomEq(vertices(),toolGeometryBaseline)?"g0":"changed";o["selection"]=sel();if(record.length)o["record"]=record;return JSONValue(o);}
JSONValue evidencePoint(string at,string record=""){auto p=point(at,tool(),record);p.object.remove("tool");return p;}

unittest {
 auto fx=parseJSON(import("fixtures/tool_arm_undo_trajectory.json"));auto cp=parseJSON(fixtureConsumerProvenance);assert(cp["reference_token"].str==fx["reference_token"].str);
 toolBaseline();auto a0=lifecycleCount();cmd("tool.set move on");auto a=evidencePoint("arm",lifecycleCount()==a0+1?"new":"none");auto d0=lifecycleCount();cmd("tool.set move off");auto d=evidencePoint("drop",lifecycleCount()!=d0?"lifecycle":"none");postJson("/api/undo","");settle();auto u=evidencePoint("undo");u["move_family_active"]=(tool()=="move");retirement(law(fx,"arm_owns_record"),JSONValue([a,d,u]));
 toolBaseline();auto ra0=lifecycleCount();cmd("tool.set move on");auto ra=evidencePoint("arm",lifecycleCount()==ra0+1?"new":"none");postJson("/api/undo","");settle();auto rau=evidencePoint("undo");postJson("/api/redo","");settle();auto rar=evidencePoint("redo");rar["move_family_active"]=(tool()=="move");retirement(law(fx,"move_arm_undo_redo"),JSONValue([ra,rau,rar]));
 toolBaseline();auto rk0=lifecycleCount();cmd("tool.set mesh.sliceTool on");auto rk=evidencePoint("arm",lifecycleCount()==rk0+1?"new":"none");postJson("/api/undo","");settle();auto rku=evidencePoint("undo");postJson("/api/redo","");settle();auto rkr=evidencePoint("redo");rkr["cutting_family_active"]=(tool()=="cutting");retirement(law(fx,"cutting_arm_undo_redo"),JSONValue([rk,rku,rkr]));
 toolBaseline();cmd("tool.set move on");auto m=point("move",tool());cmd("tool.set mesh.sliceTool on");auto k=point("cutting",tool());auto swapUndo=postJson("/api/undo","");assert(swapUndo["status"].str=="ok",swapUndo.toString);settle();auto su=point("undo",tool());retirement(law(fx,"swap_undo_previous_family"),JSONValue([m,k,su]));
 auto ru=point("undo",tool());auto rr=postJson("/api/redo","");settle();auto rpj=point("redo",tool());rpj["result"]=(rr["status"].str=="ok"?"accepted":"unavailable");retirement(law(fx,"swap_redo_unavailable"),JSONValue([ru,rpj]));
 toolBaseline();cmd("tool.set move on");auto x1a=point("first_on",tool());auto h0=lifecycleCount();cmd("tool.set move on");auto x1b=point("second_on",tool(),lifecycleCount()==h0+1?"new":"none");retirement(law(fx,"same_family_on_records_again"),JSONValue([x1a,x1b]));
 toolBaseline();cmd("tool.set move on");auto q0=lifecycleCount();cmd("tool.set move off");auto xo=point("off",tool(),lifecycleCount()!=q0?"lifecycle":"none");auto q1=lifecycleCount();cmd("tool.set move on");auto xn=point("on",tool(),lifecycleCount()==q1+1?"new":"none");retirement(law(fx,"explicit_off_on_records_on"),JSONValue([xo,xn]));
 toolBaseline();auto c0=lifecycleCount();cmd("tool.set mesh.sliceTool on");auto ca=evidencePoint("arm",lifecycleCount()==c0+1?"new":"none");auto c1=lifecycleCount();cmd("tool.set mesh.sliceTool off");auto cd=evidencePoint("drop",lifecycleCount()!=c1?"new":"none");retirement(law(fx,"cutting_arm_owns_record"),JSONValue([ca,cd]));
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
