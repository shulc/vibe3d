module toolpipe;

// Public re-exports for the Tool Pipe package. Importers normally just
// `import toolpipe;` and pull the whole surface area.
public import toolpipe.stage;
public import toolpipe.packets;
public import toolpipe.guide;
public import toolpipe.pipeline;
public import toolpipe.stages.workplane;

// `toolpipe.subject` (task 1904, doc/subject_stage_plan.md) is deliberately
// NOT re-exported here yet: every migrated call site so far imports it
// directly (`import toolpipe.subject : SubjectSource, evaluateSubject;`),
// and the plan does not ask for a `toolpipe;` wildcard import anywhere.
// Deferred, not forgotten -- recorded in the task's Лог.
