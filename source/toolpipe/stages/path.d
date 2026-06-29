module toolpipe.stages.path;

import toolpipe.stage   : Stage, TaskCode, ordPath;
import toolpipe.packets : PathPacket;
import operator         : Operator, Task, VectorStack, PacketKind;
import params           : Param;
import path             : PathSource, resolveKnots;
import mesh             : Mesh;

// ---------------------------------------------------------------------------
// PathStage — PATH pipe slot publisher.
// Ordinal 0x80; evaluates between AXIS (0x70) and WGHT (0x90).
//
// Holds a table of PathSource entries (vertex-index lists). At evaluate()
// time the active source (indexed by `index`) is resolved to world-space
// knots via the mesh accessor delegate and published as a PathPacket on
// the VectorStack for downstream consumer stages to read.
//
// vibe3d-divergence: the reference editor stores paths as curve-polygon
// geometry; vibe3d has no curve type, so the source is held on the stage.
// No consumer actor tool exists yet — this stage is the deliverable for
// the foundation task; a sweep/clone consumer is a separate follow-up.
//
// The stage-held source means zero .v3d/snapshot/undo blast radius.
// ---------------------------------------------------------------------------

class PathStage : Stage, Operator {
private:
    Mesh* delegate() meshSrc_;
    PathPacket _publishedPacket;

public:
    // ----- Stage / Operator identity ----------------------------------------

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Path; }
    override string   id()       const                          { return "path"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordPath; }

    Task         task()             const { return Task.Path; }
    PacketKind[] requiredPackets()  const { return [PacketKind.Subject]; }

    // ----- User-facing fields -----------------------------------------------

    /// Index into the sources table to evaluate.
    int   index   = 0;
    /// Active sub-range start (arc-length normalised, capture-gated).
    float start   = 0.0f;
    /// Active sub-range end (arc-length normalised, capture-gated).
    float end     = 1.0f;
    /// Phase offset applied after clamping (capture-gated).
    float slide   = 0.0f;

    // Pen-variant attrs — carried as documented stubs; inert in the
    // foundation (no consumer reads them yet).
    bool  align_  = false;
    bool  orient_ = false;
    bool  local_  = false;
    float corner  = 0.0f;

    // ----- Source table (injected by path.define) ----------------------------

    PathSource[] sources;

    // ----- Construction -----------------------------------------------------

    this(Mesh* delegate() meshSrc) {
        meshSrc_ = meshSrc;
        this.enabled = false;
    }

    // ----- Evaluation -------------------------------------------------------

    bool evaluate(ref VectorStack vts) {
        if (!this.enabled) return false;
        if (sources.length == 0
            || index < 0
            || cast(size_t)index >= sources.length) {
            // No source or out-of-range index — publish a disabled packet so
            // consumers can null-check presence without crashing.
            _publishedPacket = PathPacket.init;
            vts.put(&_publishedPacket);
            return false;
        }
        auto knots = resolveKnots(sources[index], meshSrc_());
        if (knots is null) {
            _publishedPacket = PathPacket.init;
            vts.put(&_publishedPacket);
            return false;
        }
        _publishedPacket.enabled = true;
        _publishedPacket.knots   = knots;
        _publishedPacket.closed  = sources[index].closed;
        _publishedPacket.start   = start;
        _publishedPacket.end     = end;
        _publishedPacket.slide   = slide;
        vts.put(&_publishedPacket);
        return true;
    }

    // ----- Reset (clears ALL fields — prevents -j8 cross-test bleed) --------

    override void reset() {
        enabled  = false;
        index    = 0;
        start    = 0.0f;
        end      = 1.0f;
        slide    = 0.0f;
        align_   = false;
        orient_  = false;
        local_   = false;
        corner   = 0.0f;
        sources  = null;
        _publishedPacket = PathPacket.init;
    }

    // ----- Param schema (drives the schema-based setAttr / listAttrs) -------

    override Param[] params() {
        return [
            Param.bool_ ("enabled", "Enabled", &enabled, false),
            Param.int_  ("index",   "Source",  &index,   0),
            Param.float_("start",   "Start",   &start,   0.0f),
            Param.float_("end",     "End",     &end,     1.0f),
            Param.float_("slide",   "Slide",   &slide,   0.0f),
        ];
    }
}
