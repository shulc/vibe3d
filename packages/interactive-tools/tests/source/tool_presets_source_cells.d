module tool_presets_source_cells;

import std.format : format;
import tools.transform.scale_input;
import std.json : JSONValue;
import command_history : RunCloseMode, RecordedRunBoundaryMode, RunCloseScope;
import registry         : Registry, ToolFactory, typedToolFactory;
import tool             : Tool, ToolFlag, DropUndoPolicy, DropUndoExtent, DropRedoPopulation, DropUndoResidualPopulation;
import tools.transform.xfrm_transform : XfrmTransformTool;
import tools.transform.rotate : OffGizmoRotateInput;
import tools.deform.push : PushTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.edit.topology_pen.tool : TopologyPenTool;
import toolpipe.pipeline : g_pipeCtx;
import vibe3d.editing.params.params : Param, ParamProvider, injectParamsInto, parseInto;
import toolpipe.attr_cache : NodeAttrs, recallNodeAttrs;
import tool_presets;

version (unittest) {
    // Tiny ParamProvider fake — one float param — so the restore mechanism
    // is testable without a GL-heavy real Tool. Records the names
    // `onParamChanged` fired for, so the test can prove the restore path
    // (not just the pointer write) actually ran.
    private final class FakeStickyProvider : ParamProvider {
        float width = 1.0f;
        string label = "initial";
        string[] changedNames;
        Param[] params() { return [
            Param.float_("width", "Width", &width, 1.0f),
            Param.string_("label", "Label", &label, "initial")
        ]; }
        bool paramEnabled(string name) const { return true; }
        void onParamChanged(string name) { changedNames ~= name; }
    }
}

unittest {
    import toolpipe.attr_cache : PipelineAttrCache, kToolNode;
    PipelineAttrCache cache;
    char[] producerName = "label".dup;
    char[] producerValue = "owned-value".dup;
    cache.store("fake", kToolNode,
        [cast(string)producerName: cast(string)producerValue]);
    auto fake = new FakeStickyProvider();
    auto prepared = prepareStickyToolDefaults(fake, cache.lookup("fake", kToolNode));
    assert(fake.label == "owned-value" && prepared.changedNames == ["label"]);
    assert(fake.changedNames.length == 0,
           "prepared sticky values invoked a live hook during preparation");
    producerName[] = 'x';
    producerValue[] = 'y';
    cache.clear();
    assert(fake.label == "owned-value" && prepared.changedNames == ["label"],
           "prepared sticky values borrowed cache storage");
}
