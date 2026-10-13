module tools.edit.haul_axis_latch;

import std.math : abs;

// A free haul captures Ctrl at the press and elects its screen channel from
// the first nonzero delivered motion; ties are vertical (task 9449,
// doc/tasks/work/9449-haul-ctrl-lock-latch.md). Later events cannot re-elect.
enum HaulAxis { undecided, horizontal, vertical }

struct HaulAxisLatch {
    bool pressedCtrl;
    HaulAxis axis;

    void begin(bool ctrl) nothrow @nogc {
        pressedCtrl = ctrl;
        axis = HaulAxis.undecided;
    }

    void motion(int dx, int dy) nothrow @nogc {
        if (!pressedCtrl || axis != HaulAxis.undecided || (dx == 0 && dy == 0))
            return;
        axis = abs(dy) >= abs(dx) ? HaulAxis.vertical : HaulAxis.horizontal;
    }

    bool allows(HaulAxis channel) const nothrow @nogc {
        return !pressedCtrl || axis == channel;
    }
}
