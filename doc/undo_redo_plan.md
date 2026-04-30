# Undo / Redo design plan

Detailed implementation plan for Tier 0 of `feature_roadmap.md`.

## What we're modeling

MODO's behavior (from `Modo902/help/pages/modo_interface/standard_tool_controls.html`
and `modo_interface/viewports/list_info/command_history.html`):

- **Command history**: every user-visible action (`tool.attr poly.bevel
  inset 0.15`, `select.element`, `mesh.subdivide`, etc.) is logged as
  an atomic entry visible in the Command History viewport.
- **Undo navigation**: Ctrl+Z / Ctrl+Shift+Z. "All commands that
  change model state can be undone."
- **Tool sessions**: while a tool is active, Tool Properties edits
  and viewport hauls each fire a `tool.attr` (or implicit haul)
  command. Dropping the tool (Q / Space / select another) doesn't
  itself commit anything — the tool just deactivates.
- **Apply button** (on Tool Properties): runs the tool's pipe and
  drops it without keeping it active. Equivalent to "tool drop
  with apply".
- **Reset Tool Attributes** (Ctrl+D): zeroes the tool's params.

Translated to vibe3d:

- Every mutation = one atomic command on the undo stack.
- Each Tool Properties slider change OR each completed drag cycle
  produces ONE command (= one undo entry).
- Modeling ops (`mesh.bevel`, `mesh.poly_bevel`, future
  `mesh.delete`, etc.) are atomic from the user's standpoint and
  go on the stack as one entry each.
- Selection / edit-mode changes — separate path with their own
  small snapshot (lighter than mesh snapshot).

## Architecture

### Command lifecycle (extended)

Today `Command` has only `apply()`. Extend with three optional
hooks:

```d
abstract class Command {
    // Existing — runs the operation, returns true on success.
    abstract bool apply();

    // NEW — restore the pre-apply state. Default: no-op (used by
    // commands that don't need undo, e.g. read-only queries). Mesh-
    // mutating commands MUST override this.
    bool revert() { return false; }

    // NEW — true iff this command should be appended to the undo
    // history when apply() returns true. Default true. Override
    // false for read-only commands or non-undoable side effects.
    bool isUndoable() const { return true; }

    // NEW — short human-readable label for the Edit menu and the
    // history viewer ("Bevel edges", "Move 3 verts", "Inset polygons").
    string label() const { return name(); }
}
```

Each mutating command keeps its pre-apply snapshot in instance
fields. Pattern already used by `BevelOp.faceSnaps` / `origVertices`
(in `source/bevel.d`) and `PolyBevelOp.origEdges` / `sharedCorners`
(in `source/poly_bevel.d`). Generalize into a per-command struct;
revert reads it back. The Command instance is OWNED by the history
stack after apply (it's the single source of truth for revert).

### History stack

```d
class CommandHistory {
    private Command[] undoStack;
    private Command[] redoStack;
    private size_t    maxDepth = 200;   // configurable, hard cap to bound RAM

    // Called by app.d's central command dispatcher for every
    // command that comes back from cmd.apply() == true.
    void record(Command cmd) {
        if (!cmd.isUndoable) return;
        undoStack ~= cmd;
        if (undoStack.length > maxDepth) {
            undoStack = undoStack[$ - maxDepth .. $];
        }
        // Any new action invalidates the redo timeline.
        redoStack.length = 0;
    }

    bool undo() {
        if (undoStack.length == 0) return false;
        auto cmd = undoStack[$ - 1];
        undoStack.length -= 1;
        if (cmd.revert()) {
            redoStack ~= cmd;
            return true;
        }
        return false;
    }

    bool redo() {
        if (redoStack.length == 0) return false;
        auto cmd = redoStack[$ - 1];
        redoStack.length -= 1;
        if (cmd.apply()) {
            undoStack ~= cmd;
            return true;
        }
        return false;
    }
}
```

Owned by `app.d` alongside the command registry.

### Tool integration (the tricky part)

Tools have a "session" model: while active, the user adjusts state
(via gizmo drag or Tool Properties); on commit (drag end OR tool
drop OR Apply), the change is finalized as ONE undo entry.

Naive approach: each `applyEdgeBevelTopology()` / `revert+reapply`
cycle inside the tool fires a command. For a slider drag that's 60
entries per second — stack explodes.

**Coalescing model**:

A tool keeps a **live command** during a session — a `Command`
instance whose `apply()` is run on first interaction (snapshot
taken), and whose params are mutated on each subsequent change.
The mesh shows the latest state continuously. The command is NOT
on the history stack while live.

The live command commits to the history stack on:

1. **Mouse button up** of a drag handle (one command per drag
   cycle).
2. **Slider release** in Tool Properties (`ImGui.IsItemDeactivatedAfterEdit()`
   returns true the frame after the drag ends).
3. **Tool deactivation** (Q / Space / select another tool / Apply
   button / edit-mode change).

Within a session, user actions of the SAME KIND coalesce:

- Dragging the Width slider with the mouse → one entry per
  release.
- Then dragging Inset → another entry.
- Then dragging Width again → another entry (separate from the
  first).

Different SESSIONS never coalesce (each tool activation cycle is
its own boundary).

Concrete API on `Tool`:

```d
abstract class Tool {
    // ... existing
    
    // NEW — for tools that produce undoable state changes. Tools
    // like SelectTool that don't produce mesh state may return
    // null. The returned Command is owned by the tool while live;
    // ownership transfers to CommandHistory on commit.
    Command activeLiveCommand() { return null; }
    
    // NEW — called by the host when the live command should be
    // finalized (drag end, tool drop, mode switch). Default impl:
    // no-op.
    void commitLiveCommand() {}
}
```

BevelTool's implementation:

```d
class BevelTool : Tool {
    private MeshBevel liveBevelCmd;       // or MeshPolyBevel
    
    // On first edit:
    if (liveBevelCmd is null) {
        liveBevelCmd = new MeshBevel(...);
        liveBevelCmd.setWidth(ebWidth);
        liveBevelCmd.apply();             // snapshot taken inside
    }
    
    // On parameter change (in onMouseMotion or drawProperties):
    liveBevelCmd.setWidth(ebWidth);
    liveBevelCmd.revertAndReapply();      // mesh updated, no stack push
    
    // On commit boundary:
    history.record(liveBevelCmd);
    liveBevelCmd = null;
}
```

The `revertAndReapply` helper is internal — it restores the
pre-apply snapshot, then re-runs apply with the new params. The
snapshot is taken ONCE (at the first apply); each
revert+reapply rolls back to the SAME snapshot and applies the
NEW params. So at commit time, the command's snapshot is the
"start of session" and its current params are the "end of
session" — perfect for one undo entry.

### Tool Properties: per-edit granularity

User concern: "при изменении настроек в Tool Properties создается
отдельная команда". With the coalescing model above, EACH separate
slider edit (= one drag, ending in a release) becomes its own
undo entry. Confirmed by ImGui semantics:

```d
ImGui.DragFloat("Width", &ebWidth, 0.005f, 0.0f, 0.0f, "%.4f");
if (ImGui.IsItemDeactivatedAfterEdit()) {
    history.record(liveBevelCmd);
    liveBevelCmd = startNewCmd();   // restart session with current state
}
```

After this commit, the next drag of the SAME slider starts a fresh
command (so it's a separate undo entry).

If user Ctrl+Z after editing Width → Inset → Shift in succession:

| Stack | Entry |
|---|---|
| [3] | Set Shift 0 → 0.15 |
| [2] | Set Inset 0 → 0.10 |
| [1] | Set Width 0 → 0.20 |
| [0] | (initial bevel apply, e.g. Width=0 default) |

Three Ctrl+Z presses revert each property change in reverse order;
fourth Ctrl+Z reverts the initial bevel itself.

### Selection / edit-mode undo

Lightweight: a `SelectionSnapshot` struct captures `editMode`,
`selectedVertices/Edges/Faces` arrays + counters. A
`SelectCommand` wraps any selection mutation and uses the snapshot
for revert.

Coalescing: consecutive selection ops in the same edit mode merge
into one entry. So clicking 5 verts to add to selection produces
ONE undo entry (not 5). Implementation: when recording a new
SelectCommand, if the previous undo entry is a SelectCommand and
the editMode matches AND it was recorded < 1000ms ago, REPLACE its
"after" state instead of pushing a new entry.

Tunable: 1000ms is a heuristic for "active edit". Switch tools or
change edit mode → coalescing window closes.

### HTTP path

For non-interactive `mesh.bevel` etc. via HTTP:

- Each `apply()` returns success → `history.record(cmd)` is called
  by the dispatcher in `setCommandHandler` (`source/app.d`).
- No coalescing — each HTTP call is its own entry.
- Tests can assert undo round-trips by calling `mesh.bevel`, then
  `/api/undo`, then `/api/model` — and getting the original cube
  back.

NEW endpoints:

- `POST /api/undo` → `history.undo()`.
- `POST /api/redo` → `history.redo()`.
- `GET /api/history` → list of (label, timestamp) for current undo
  stack. Useful for tests + Edit menu rendering.

### Memory & performance

Concerns:

1. **Mesh snapshot size**: BevelOp already snapshots
   `origVertices` (Vec3[]) + `origEdges` (uint[2][]) +
   `origSelectedEdges` (bool[]) + `origEdgeOrder` (int[]) +
   `faceSnaps` (only modified faces, not all). Cube = trivial; a
   100k-vert mesh = ~3MB per command. With max stack depth 200
   that's 600MB worst case. **Action**: cap max-depth to ~50
   or compress snapshots (e.g. only diff-store in production
   builds). Keep verbose for dev builds.

2. **Selection snapshot**: bool[] arrays sized to mesh — couple
   of MB per snapshot for 100k-vert meshes. Coalesce aggressively
   (see above) and cap depth.

3. **Coalescing correctness**: the "in-progress live command"
   isn't on the stack yet — it's owned by the tool. If something
   throws between revert+reapply cycles and commit, mesh state
   could leak. Add a `scope(failure)` in tool code that commits
   any live command before propagating exceptions.

## Implementation order

1. **Phase A — `Command.revert()` virtual + history stack.** Add
   the new methods on Command; implement CommandHistory; wire
   Ctrl+Z / Ctrl+Y in app.d. NO tool integration yet — only the
   HTTP path triggers history records. Add `/api/undo`, `/api/redo`,
   `/api/history`.

   Test: `tests/test_undo_http.d` — runs `mesh.subdivide` (cheap)
   via HTTP, undoes, asserts mesh count back to 8/12. Adds basic
   round-trip coverage.

   Effort: 2 days. Touches `source/command.d` (virtual), each
   `commands/mesh/*.d` and `commands/select/*.d` (override
   `revert()`), `source/app.d` (dispatcher + key bindings),
   `source/http_server.d` (3 endpoints).

2. **Phase B — Per-command snapshot/revert audit.** Walk every
   existing command:

   - `mesh.bevel` (`MeshBevel`): snapshot is BevelOp; revert calls
     `revertEdgeBevelTopology(mesh, op)`.
   - `mesh.poly_bevel`: PolyBevelOp + `revertPolyBevel(mesh, op)`.
   - `mesh.subdivide`, `mesh.subdivide_faceted`: snapshot ALL
     (verts/edges/faces/selection) — these are global rebuilds.
   - `mesh.subpatch_toggle`: snapshot `isSubpatch[]`.
   - `mesh.split_edge`: snapshot affected face's vert list +
     edge list around that vert.
   - `mesh.move_vertex`: snapshot the moved vert's old position.
   - `select.*`: SelectionSnapshot.
   - `viewport.fit*`, `file.load`, `file.save`: not undoable
     (`isUndoable` returns false). file.load is a special case —
     replaces the whole mesh; could be undoable if we snapshot
     the whole pre-load state.

   Effort: 3 days. Each command is small but every one needs a
   focused diff + a unit test.

3. **Phase C — Tool live-command integration.** Extend the
   `Tool` base class with `activeLiveCommand` / `commitLiveCommand`.
   Refactor BevelTool first (most complex, sets the pattern).

   - On first user input that triggers `applyEdgeBevelTopology`:
     create the live command, capture snapshot.
   - On parameter changes: revert-snapshot + reapply with new
     params (no stack interaction).
   - On commit boundaries: history.record(liveCmd) + clear.

   Effort: 3 days for BevelTool; 1 day each for Move/Rotate/Scale
   /Box (simpler).

4. **Phase D — Selection coalescing.** Implement the SelectCommand
   pattern for `select.*` commands and the picking path
   (click-to-select). Handle the 1000ms-coalesce window.

   Effort: 2 days.

5. **Phase E — UI + UX polish.** Edit menu (Undo / Redo / Reset
   Tool Attributes). Optional: Command History panel showing the
   stack. ImGui integration. Keyboard shortcuts.

   Effort: 2 days.

**Total: ~2 weeks**, dominated by per-command audit + tool
refactor.

## Test strategy

Adds a new test file template `tests/test_undo_<cmd>.d` for each
mutating command. Each test:

```d
unittest {
    resetCube();              // 8V/6F
    selectFace(0);
    runCommand("mesh.poly_bevel", {insert:0.15, shift:0});
    auto m1 = getModel();     // 12V/10F (or whatever)
    
    runCommand("undo");
    auto m2 = getModel();
    assert(m2.vertices == initialCube.vertices);  // bit-for-bit
    
    runCommand("redo");
    auto m3 = getModel();
    assert(m3.vertices == m1.vertices);           // bit-for-bit
}
```

Plus an integration test that runs a long sequence of mixed
ops with random Ctrl+Z / Ctrl+Y interleaving — fuzzes the
snapshot/revert correctness across the whole command set.

Existing comparisons (blender_diff / modo_diff) don't need to
change: they apply commands fresh on each case and don't
interact with undo. But we add a new flag in the
`run.d` orchestrators for an optional "round-trip via undo"
mode that applies + undoes + asserts equality with the pre-apply
state. Catches commands that forgot to snapshot something.

## Open questions

1. **Live command ownership during exceptions**: if a tool crashes
   mid-edit, the live command's snapshot is lost. Should we
   `scope(failure) commitLiveCommand();` to at least preserve
   what's there, or `scope(failure) liveCmd.revert();` to bail
   to safe state? Lean toward revert for safety; commit if user
   manually re-activates the same tool.

2. **Persistent history across Save/Load**: out of scope for this
   plan. Tier 0.3 in `feature_roadmap.md`.

3. **Linear vs branched history**: linear (any new action wipes
   redo stack) is simpler and matches MODO. Branched ("undo tree")
   is power-user but a separate project. Default: linear.

4. **Memory cap policy**: 50 entries default cap, configurable
   via preferences. With 100k-vert meshes and ~3MB per snapshot
   that's 150MB — acceptable. Larger caps or compressed snapshots
   are a follow-up.

5. **What about `mesh.weldCoincidentVertices`** (called inside
   bevel command after-effect)? It mutates state but is part of a
   parent command's apply. The parent command's snapshot covers
   it. Don't expose `weldCoincidentVertices` as its own undoable
   command unless we make a user-facing `mesh.merge_verts`
   wrapper (which Tier 1.2 will).
