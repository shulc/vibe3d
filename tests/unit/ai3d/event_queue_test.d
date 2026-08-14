// Module unittests for `ai3d.event_queue`, moved verbatim out of source/ai3d/event_queue.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai3d.event_queue_test;

import core.sync.mutex : Mutex;
import ai3d.job_events : Ai3dEvent, Ai3dEventKind;
import ai3d.event_queue;

unittest {
    // Overflow: pushing more than the cap of non-coalescable events collapses
    // the whole pending queue to ONE synthetic terminal failure — never
    // unbounded memory, never a silent partial stream.
    auto q = new Ai3dEventQueue();
    foreach (i; 0 .. Ai3dMaxControllerEvents + 10) {
        Ai3dEvent e;
        e.kind = Ai3dEventKind.submitted; // distinct kind so nothing coalesces
        e.jobId = "job1";
        q.push(e);
    }
    Ai3dEvent[] seen;
    q.drain((ref const Ai3dEvent e) { seen ~= e; });
    assert(seen.length == 1);
    assert(seen[0].kind == Ai3dEventKind.terminal);
    assert(seen[0].code == "queue_overflow");
}
