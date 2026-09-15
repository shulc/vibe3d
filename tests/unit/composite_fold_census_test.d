module tests.unit.composite_fold_census_test;

import std.algorithm : count;
import std.array : join;
import std.file : readText;
import std.path : buildPath, dirName;
import std.string : split;
import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string codeAt(string leaf)
{
    return blankNonCode(readText(buildPath(repoRoot, "source", "tools",
                                           "transform", leaf)));
}

private string compact(string code)
{
    return code.split.join;
}

unittest // The composite fold has one production door and one shared frame rule.
{
    const apply = codeAt("xfrm_apply.d");
    const host = codeAt("xfrm_transform.d");
    const itemCaller = codeAt("xfrm_item.d");
    const itemKernel = codeAt("item_xform_kernels.d");
    assert(apply.length > 10_000 && host.length > 10_000,
        "6207 census inputs must be production-sized sources");
    assert(host.count("applyTRS(") == 12,
        "6207 applyTRS call population changed");
    assert(apply.count("composeFor(") == 3
        && apply.count("composeRunMatrix(") == 1,
        "6207 composed fold must keep one matrix door");
    assert(apply.count("tdX") == 0
        && apply.count("translationMatrix(") == 3,
        "6207 superseded translate-axis rewrite returned");

    const applyFlat = compact(apply);
    const hostFlat = compact(host);
    assert(applyFlat.count("immutableboolcompositeRun=flagT&&(flagR||flagS)&&runBaselineValid&&!headlessApplyActive_;") == 1,
        "6207 composite interactive gate changed");
    assert(applyFlat.count("if(compositeRun)samplePipeFromBaseline=true;") == 1,
        "6207 composite run must sample its baseline");
    assert(applyFlat.count("if(compositeRun&&runFrameValid)pivot=runFrameOrigin;") == 1,
        "6207 composite run must pivot on its frozen centre");
    assert(hostFlat.count("headlessApplyActive_=true;scope(exit)headlessApplyActive_=false;returnapplyTRS(mesh.vertices.dup);") == 1,
        "6207 headless apply exclusion tail changed");

    assert(host.count("tInRunFrame") == 3,
        "6207 T re-expression and handle following must share one decision");
    assert(hostFlat.count("immutablebooltInRunFrame=flagR&&!runRotIsIdentity()&&runFrameValid&&!(queryClusterPivots(vts).active&&queryClusterAxes(vts).active);") == 1,
        "6207 T run-frame predicate changed");
    assert(hostFlat.count("immutableVec3decomposed=pending;if(tInRunFrame){") == 1,
        "6207 move scalar must be re-expressed when the shared decision is true");
    assert(hostFlat.count("elseif(tInRunFrame){eX=moveSub.inAxisX();eY=moveSub.inAxisY();eZ=moveSub.inAxisZ();}") == 1,
        "6207 handle following must use the move input axes under the shared decision");
    assert(hostFlat.count("if(runBaselineValid)runFrameValid=false;") == 1,
        "6207 local rebake must invalidate the frozen frame once");
    assert(apply.count("runScaleAxes(frame.valid,") == 1
        && apply.count("if (frame.valid)") == 0,
        "6207 scale axes must pass through the one shared branch rule");
    assert(itemCaller.count("applyGestureToItems(") == 1
        && itemKernel.count("applyGestureToItems(") >= 2,
        "6207 item composition must keep one production caller");
}
