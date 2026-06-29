module commands.path.define;

import command;
import mesh;
import view;
import editmode;

import toolpipe.pipeline    : g_pipeCtx;
import toolpipe.stages.path : PathStage;
import toolpipe.stage       : TaskCode;
import path                 : PathSource;

// ---------------------------------------------------------------------------
// `path.define <csv-verts> [closed]`
//
// Injects a PathSource (vertex-index list) into the PATH stage's source
// table, replacing entry 0 or appending when the table is empty. Multiple
// path sources are addressable by index via `tool.pipe.attr path index N`.
//
// Positional args (delivered by injectToolCommandPositional in app.d):
//   positional[0] = CSV of uint vertex indices, e.g. "0,1,2"
//   positional[1] = optional "true" / "false" for the closed flag
//
// CmdFlags.SideEffect — pipe configuration, not a mesh edit; not undoable.
// ---------------------------------------------------------------------------
class PathDefineCommand : Command {
private:
    uint[] verts_;
    bool   closed_ = false;

public:
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string   name()     const { return "path.define"; }
    override string   label()    const { return "Define Path Source"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    /// Parse a comma-separated list of uint vertex indices.
    void setVertsCsv(string csv) {
        import std.string : split, strip;
        import std.conv   : to;
        verts_.length = 0;
        foreach (tok; csv.split(",")) {
            auto t = tok.strip;
            if (t.length == 0) continue;
            try { verts_ ~= t.to!uint; } catch (Exception) {}
        }
    }

    void setClosed(bool c) { closed_ = c; }

    override bool apply() {
        import std.conv : to;
        if (g_pipeCtx is null)
            throw new Exception("path.define: pipeline not initialised");
        auto ps = cast(PathStage)
                  g_pipeCtx.pipeline.findByTask(TaskCode.Path);
        if (ps is null)
            throw new Exception("path.define: PATH stage not registered");
        if (verts_.length < 2)
            throw new Exception(
                "path.define: need at least 2 vertex indices, got "
                ~ verts_.length.to!string);
        PathSource src;
        src.verts  = verts_.dup;
        src.closed = closed_;
        if (ps.sources.length == 0)
            ps.sources ~= src;
        else
            ps.sources[0] = src;
        return true;
    }

    override bool revert() { return false; }
}
