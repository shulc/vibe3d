// handler.d — compatibility facade (task 0423, campaign 0407 §V5).
//
// The god-node this module used to be (GL primitives, the Handler shape
// hierarchy, and the ToolHandles arbiter + AI hooks) has been split into
// source/handles/{gl_util,shapes,arbiter}.d. This file re-exports all three
// via `public import` so every existing `import handler;` / `import handler
// : Symbol;` call site keeps resolving unchanged — see the 34-importer
// inventory in doc/tasks/{work,done}/0423-handler-module-split.md.
//
// DO NOT DELETE: this facade is load-bearing, not dead weight. Collapsing
// it (renaming all importers to `import handles.*` directly) is a possible
// future cleanup, tracked separately — not a reason to remove it here.
module handler;

public import handles.gl_util;
public import handles.shapes;
public import handles.arbiter;
