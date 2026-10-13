// The Topology Pen is a PACKAGE, not a lone module. This file is its facade:
// it holds no code, only the public re-export, so every existing
// `import tools.edit.topology_pen;` keeps naming the same thing it always did.
//
// The package exists for one reason -- visibility granularity. Inside it,
// `package` means "the pen's own modules": the implementation modules listed
// below and the white-box unittest modules under
// `tests/unit/tools/edit/topology_pen/`, which are named into this package for
// exactly that reason. The compiler REFUSES a `package` member to everything
// else, the sibling tools in `tools/edit/` included; had the tool stayed a
// lone module, the same keyword would have handed its internals to all of
// `tools.edit` and, transitively, to every sub-package under it. Members that
// no other module in the package needs stay `private` and remain unreachable
// even from here (all three properties measured on dmd 2.112 and ldc 1.42,
// task 0718).
module tools.edit.topology_pen;

public import tools.edit.topology_pen.tool;
public import tools.edit.topology_pen.defs;   // the gesture vocabulary the tool is written in
public import tools.edit.topology_pen.snap_guide;   // border classification + the gesture-lifetime guide
