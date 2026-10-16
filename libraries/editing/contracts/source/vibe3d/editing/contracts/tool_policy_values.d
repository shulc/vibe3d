module vibe3d.editing.contracts.tool_policy_values;

import vibe3d.editing.contracts.editmode : EditMode;

/// How a topology step of the captured model began (topology-redo S2b, model doc §2.2):
/// `opens` began the post mode, `restart` opened an operation inside an open
/// (or navigation-re-begun) post mode, `refire` stayed inside the open
/// operation. `unclassified` (the `.init`) is every row outside the model.
enum StepOrigin : ubyte { unclassified, refire, opens, restart }

/// H7 (tool session model, slice M6): whether the viewport draws the element
/// under the cursor while a tool is armed. It is DATA — the rollover flag of
/// the tool's policy (`ToolSessionPolicy.rollovers`) and of the pipe stages it
/// runs with (`Stage.rollovers`), each from the captured flags table and the
/// C-H7 cells (`toolcards/tool_session_model/`, gap 309/312/380) — read by ONE
/// viewport path (`ui/viewport_render.d : rolloverShown`). WHICH elements are
/// hovered is a separate question, the tool's pick need
/// (`Tool.wantsHoverForType`): a tool that picks no type shows nothing
/// whatever its flag. No tool armed: the selection type decides, as before.
enum Rollover : ubyte {
    /// Nothing is drawn under the armed tool (C-H7: Slice, Edge Extend,
    /// Polygon Bevel, Move, vertex Bevel — 0 px).
    none,
    /// The hovered target outside a drag, live edit or not (Edge Slice keeps
    /// its target edge through a live chain, C-H7: 286 px). A drag hides it:
    /// the picker holds its drag-start index while the preview rebuilds the
    /// edge array under it (the stale-alias rule of the viewport's edge pass).
    target,
    /// Only a hovered VERTEX, in every selection mode: the element falloff's
    /// flag (C-H7-elem: Element Move 36 px on a vertex, 0 on an edge in edge
    /// and polygon mode). A drag keeps it — the element picked at drag start
    /// stays lit, as before the slice (not captured; gap 383).
    vertices,
}

/// The rule of one flag, as a pure function of the frame's facts.
bool rolloverDraws(Rollover r, EditMode type, bool dragging)
        pure nothrow @nogc @safe {
    final switch (r) {
        case Rollover.none:      return false;
        case Rollover.target:    return !dragging;
        case Rollover.vertices:  return type == EditMode.Vertices;
    }
}

/// A tool's ATTRIBUTE IMAGE (slice M3, plan R4.3): the raw bytes of the
/// attributes its policy declares in `imageAttrs`, in that order. An undo of a
/// gesture step restores the image the step started from (H2); the tool's
/// preview is a function of it (`Tool.rebuildPreviewFromAttrs`).
struct AttrImage {
    string[] names;
    immutable(void)[][] raw;

    bool empty() const pure nothrow @nogc { return names.length == 0; }

    /// The image minus `drop`'s names (raw bytes shared, not copied). A pure
    /// filter: the operation context a tool instance must not inherit is cut
    /// here, never by a per-tool branch (wave plan 8640 S7a, M-H).
    AttrImage without(scope const(string)[] drop) const pure nothrow {
        AttrImage r;
        outer: foreach (i, n; names) {
            foreach (d; drop) if (d == n) continue outer;
            r.names ~= n;
            r.raw ~= raw[i];
        }
        return r;
    }

    bool opEquals(const AttrImage o) const pure nothrow @nogc {
        if (names.length != o.names.length) return false;
        foreach (i; 0 .. names.length)
            if (names[i] != o.names[i]
                || cast(const(ubyte)[]) raw[i] != cast(const(ubyte)[]) o.raw[i])
                return false;
        return true;
    }
}

enum DropUndoExtent { none, newestPressBlock, wholeSession }
enum DropRedoPopulation { editRows, discard, selectedSuffix }
enum DropUndoResidualPopulation { removeSuffix, pressMarker }
struct DropUndoPolicy {
    DropUndoExtent extent;
    DropRedoPopulation redo;
    DropUndoResidualPopulation residual;
}

