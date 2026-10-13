// The viewport dirty key's camera-pose term (task 1970).
//
// `DirtyKey` used to carry its own `float[16] view` / `float[16] proj` pair;
// this file pins that folding them into `CameraStamp cam` did not change the
// WHOLE-STRUCT comparison `app.d` performs (`_newKey != _cv.lastKey`, its
// only compare site — see the grep in the task card): two keys differing only
// in the camera pose must still compare unequal, and identical poses must
// still compare equal.
//
// THE TRAP THIS FILE GUARDS AGAINST IS NOT "does it discriminate". A bare
// `float[16]` pair discriminates trivially and so does `CameraStamp` — a test
// that only checked that would pass before this refactor, after it, and again
// if the refactor were reverted, which is exactly the vacuous shape this
// project's CLAUDE.md warns about. The property only THIS shape can violate
// is `camera_stamp.d`'s own rule: `CameraStamp` must never grow an `opEquals`
// or a mutable memo field, because a bare `float[16]` field never could —
// static arrays have no user-definable equality, so this failure mode did not
// exist before task 1970 introduced the struct. The mutation that proves it:
// give `CameraStamp` a vacuous `opEquals` (`return true;`) and the first
// unittest below reddens on its "must compare unequal" assert — a hand-
// written `view`/`proj` pair could never have been made to fail that way,
// because there is no `opEquals` to give an array. Run and reverted for this
// card; see doc/tasks/work/1970-dirtykey-camera-stamp.md's "Мутация" section
// for the verbatim message.
module tests.unit.dirty_key_camera_stamp_test;

import viewport      : DirtyKey;
import camera_stamp  : CameraStamp;

/// Two keys differing only in the camera VIEW matrix must compare unequal.
unittest {
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.cam.view[0] = 1.0f;
    assert(a != b,
        "keys differing only in the camera VIEW matrix must compare unequal "
        ~ "— the camera pose is a render input like any other, and DirtyKey "
        ~ "compares it through the WHOLE-struct ==, not field by field");

    // Restoring the matched pose must restore equality, or a camera that
    // returned to its previous frame would be read as perpetually dirty.
    b.cam.view[0] = 0.0f;
    assert(a == b, "restoring the matched view must restore equality");
}

/// Two keys differing only in the camera PROJECTION matrix must compare
/// unequal — a separate field inside `CameraStamp` from `view`, so it needs
/// its own witness (camera_stamp.d's `changed()`/`==` check both halves).
unittest {
    DirtyKey a, b;
    a.fboW = 640; b.fboW = 640;
    a.fboH = 480; b.fboH = 480;
    assert(a == b, "sanity: identical keys must compare equal");

    b.cam.proj[5] = 2.0f;
    assert(a != b,
        "keys differing only in the camera PROJECTION matrix must compare "
        ~ "unequal");
}

/// `DirtyKey.cam`'s default matches `CameraStamp`'s own `= 0` default (task
/// 1930 chose `= 0` on `CameraStamp` partly so this fold would be a pure
/// representation change) — two fresh keys must compare equal on the camera
/// term alone, with every other field also at its default.
unittest {
    DirtyKey a, b;
    assert(a == b, "two fresh DirtyKeys must compare equal");
    assert(a.cam == CameraStamp.init,
        "DirtyKey.cam's default must be CameraStamp's own default");
}
