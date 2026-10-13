// The tool-private preview term on viewport.DirtyKey (task 5340).
//
// This is the structural discrimination tier. The HTTP suite cannot execute
// the interactive dirty-key comparison because --test deliberately renders
// its selected cell set directly; the suite instead observes the pre-skip
// stamp, and the live rig observes the comparison itself.
module tests.unit.dirty_key_tool_preview_test;

import viewport : DirtyKey;

unittest {
    DirtyKey k0, k1;
    assert(k0 == k1,
        "population floor: two identical preview states must produce equal "
        ~ "dirty keys, or inequality below would distinguish nothing");

    DirtyKey a, b;
    static if (__traits(hasMember, DirtyKey, "toolPreviewKey"))
        __traits(getMember, b, "toolPreviewKey") = 1;

    assert(a != b,
        "keys differing only in toolPreviewKey must compare unequal");
}
