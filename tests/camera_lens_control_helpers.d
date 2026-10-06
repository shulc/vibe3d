module camera_lens_control_helpers;
import http_client : getJson,postJson,testBaseUrl;
import std.format : format;
import std.json : JSONType;
import core.thread : Thread;
import core.time : msecs;
import std.math : PI;
enum float defaultLensControl=45.0f*PI/180.0f;
enum float explicitLensControl=.902658403f;
void applyLensControl(float lens,string base=testBaseUrl()) {
    assert(postJson("/api/camera",format(`{"fovY":%.9g}`,lens),base)["status"].str=="ok","FAMILY_LENS_ACCEPTED");
    const n=getJson("/api/camera",base)["fovY"];
    const actual=n.type==JSONType.float_?cast(float)n.floating:cast(float)n.integer;
    assert(actual==lens,"FAMILY_LENS_EXACT");
    currentLens=lens;
    Thread.sleep(150.msecs);
}
private float currentLens=defaultLensControl;
string matchedLensMetadata(string log) {
    import std.regex : regex,replaceAll;
    return replaceAll(log,regex(`"fovY"\s*:\s*[0-9.eE+\-]+`),format(`"fovY":%.9g`,currentLens));
}
void playAndWaitLensControl(string log,string base=testBaseUrl()) {
    import drag_helpers : playAndWait;
    playAndWait(matchedLensMetadata(log),base);
}

void reapplyLensControl(string base=testBaseUrl()) { applyLensControl(currentLens,base); }
