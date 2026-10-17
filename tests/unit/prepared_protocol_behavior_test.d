// Exercise the real arm transaction instead of freezing its implementation text.
module tests.unit.prepared_protocol_behavior_test;

import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.editing.commands.runtime.record_observer_hub : RecordObserverHub;
import vibe3d.documents.model.document : Layer;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.params.params : Param;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : Pipeline, g_pipeCtx;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter : ActionCenterStage;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.axis : AxisStage;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.constrain : ConstrainStage;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.falloff : FalloffStage;
import vibe3d.editing.tools.interactive.pipe_gizmo_host : PipeGizmoHost;
import vibe3d.editing.tools.interactive.prepared_record_context : PreparedRecordContext,
    PreparedToolDoorClient, PreparedToolParamDoorClient, PreparedToolPoseDoorClient;
import vibe3d.editing.tools.interactive.prepared_tool_transition : prepareArm, commitPreparedArm;
import vibe3d.editing.tools.interactive.registry : PreparedPipeAttrs, ToolFactory;
import vibe3d.editing.tools.interactive.tool : Tool;
import vibe3d.mesh.core.mesh : makeCube;
import vibe3d.viewport.camera.view : View;
import std.json : JSONValue;

private struct Witness {
    Tool active, candidate;
    string id;
    int refusal;
    int[8] trace;
    size_t used;
    bool disposedAfterPublication;
    void note(int phase) { trace[used++] = phase; }
}

private class Probe : Tool, PreparedToolDoorClient,
        PreparedToolParamDoorClient, PreparedToolPoseDoorClient {
    Witness* witness;
    bool predecessor;
    float value;
    this(Witness* witness, bool predecessor) {
        this.witness = witness;
        this.predecessor = predecessor;
        value = predecessor ? 1 : 0;
    }
    ~this() nothrow {
        if (predecessor && witness !is null)
            witness.disposedAfterPublication = witness.active is witness.candidate
                && witness.id == "test.probe";
    }
    override Param[] params() { return [Param.float_("value", "Value", &value, 0)]; }
    override bool prepareDoorDeactivate(PreparedRecordContext c, Layer, ulong, ulong) {
        witness.note(10);
        assert(witness.active is this && witness.id == "old");
        return c.markNoHistoryInstall();
    }
    override bool prepareDoorActivate(PreparedRecordContext c, Layer, ulong, ulong) {
        witness.note(20);
        assert(witness.active !is this && witness.id == "old");
        return c.markNoHistoryInstall();
    }
    override bool prepareDoorParamChanged(string name, PreparedRecordContext, Layer, ulong, ulong) {
        witness.note(30);
        assert(!predecessor && witness.active !is this && witness.id == "old",
            "parameter door must run on the fresh unpublished candidate");
        assert(name == "value" && value == 2, "parameter door must see the injected value");
        return witness.refusal != 1;
    }
    override bool prepareDoorInitialPose(ref VectorStack, PreparedRecordContext c, Layer, ulong, ulong) {
        witness.note(40);
        assert(witness.active !is this && witness.id == "old");
        return witness.refusal != 2 && c.markNoHistoryInstall();
    }
}

unittest {
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    g_pipeCtx = null;
    foreach (refusal; [0, 1, 2]) {
        Witness w;
        w.refusal = refusal;
        auto outgoing = new Probe(&w, true);
        scope(exit) outgoing.predecessor = false; // GC must not retain the stack witness.
        w.active = outgoing;
        w.id = "old";
        Probe incoming;
        ToolFactory factory = () {
            incoming = new Probe(&w, false);
            w.candidate = incoming;
            return incoming;
        };
        auto layer = new Layer;
        layer.meshRef() = makeCube();
        const versionBefore = layer.meshRef().mutationVersion;
        auto history = new CommandHistory;
        auto observers = new RecordObserverHub;
        EditMode mode = EditMode.Polygons;
        Pipeline pipeline;
        pipeline.add(new ActionCenterStage(() => &layer.meshRef(), &mode));
        pipeline.add(new AxisStage);
        pipeline.add(new ConstrainStage);
        pipeline.add(new FalloffStage(() => &layer.meshRef(), &mode));
        PreparedPipeAttrs attrs;
        VectorStack pose;
        auto view = new View(0, 0, 800, 600);
        JSONValue args = JSONValue(["value": JSONValue(2)]);
        bool refused;
        try {
            auto arm = prepareArm(factory, "test.probe", outgoing, history, observers,
                layer, pipeline, attrs, new PipeGizmoHost, args, pose, 17, 23,
                &layer.meshRef(), view, mode, w.id, null, null);
            assert(refusal == 0, "the refusing door was ignored");
            assert(w.trace[0 .. w.used] == [10, 20, 30, 40]);
            assert(w.active is outgoing && w.id == "old" && outgoing.value == 1);
            assert(!w.disposedAfterPublication, "preparation disposed the predecessor");
            assert(commitPreparedArm(w.active, w.id, arm));
            assert(w.active is incoming && w.id == "test.probe" && incoming.value == 2);
            assert(w.disposedAfterPublication, "predecessor disposal preceded publication/id");
            assert(!commitPreparedArm(w.active, w.id, arm), "arm was consumed twice");
        } catch (Exception) { refused = true; }
        assert(refused == (refusal != 0));
        if (refused) {
            assert(w.active is outgoing && w.id == "old" && outgoing.value == 1);
            assert(!w.disposedAfterPublication);
            assert(w.trace[0 .. w.used] == (refusal == 1 ? [10, 20, 30] : [10, 20, 30, 40]));
        }
        assert(layer.meshRef().mutationVersion == versionBefore);
        assert(history.undoEntriesVisible().length == 0, "no-history arm changed history");
    }
}
