// Module unittests for `toolpipe.stages.workplane`, moved verbatim out of source/toolpipe/stages/workplane.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.toolpipe.stages.workplane_test;

import std.math : sin, cos, PI, abs;
import std.conv : to;
import std.format : format;
import math : Vec3, Viewport;
import toolpipe.stage    : Stage, TaskCode, ordWork;
import toolpipe.packets  : WorkplanePacket;
import operator          : Operator, Task, VectorStack, PacketKind;
import tools.create.create_common : pickMostFacingPlane;
import popup_state        : setStatePath;
import toolpipe.stages.workplane;

// task 0678 P4 — knownAttrs must mirror applySetAttr's switch: every listed
// name is settable with a canonical sample value.  Before the fix this stage
// had NO attr universe at all, so the forms-engine startup-strict validator
// (forms.d) would throw for the first form bound to "workplane".
unittest {
    import toolpipe.stage : assertRejectsUndeclaredAttrs;
    auto st = new WorkplaneStage();
    auto names = st.knownAttrs();
    assert(names.length > 0, "workplane knownAttrs must not be empty");
    string[string] sample = [
        "auto": "true",
        "cenX": "1.5", "cenY": "1.5", "cenZ": "1.5",
        "rotX": "10",  "rotY": "10",  "rotZ": "10",
        "mode": "auto",
    ];
    foreach (n; names) {
        assert((n in sample) !is null,
               "no sample value for workplane attr '" ~ n ~ "' — extend the test");
        assert(st.setAttr(n, sample[n]),
               "workplane knownAttrs name '" ~ n ~ "' rejected by setAttr");
    }

    // task 0685 T1 — and the COMPLEMENT: the mirror must not be one-way.
    // The loop above proves `knownAttrs ⊆ accepted`; the defect 0678 P4 fixed
    // was the other inclusion (a `case` with no declaration), which every
    // assertion above stays green through. See `assertRejectsUndeclaredAttrs`.
    assertRejectsUndeclaredAttrs(new WorkplaneStage(), "workplane");
}
