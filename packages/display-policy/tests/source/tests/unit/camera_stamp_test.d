// `CameraStamp` — the compare itself, at the granularity the HTTP witness
// cannot reach (task 1930 stage 2).
//
// WHY THIS FILE EXISTS ALONGSIDE `tests/test_gpu_select_slot_camera_key.d`.
// That suite test drives the real picker and is the one that proves the stamp
// is WIRED — but its gesture is `azimuth += PI/2`, an orbit, which moves `view`
// and leaves `proj` untouched. So it pins HALF the stamp: delete the `proj`
// comparison and the suite test stays green. The cells below are the other
// half, plus the per-element granularity a matrix-valued compare needs — a
// `changed` that looked only at element 0 would satisfy any test that varies
// the whole matrix at once.
//
// MUTATIONS THIS FILE IS BUILT TO CATCH (measured 2026-08-26, see the card):
//   * `changed` -> `return false;`             — every cell below
//   * `changed` compares only `view`           — ONLY this file; the suite test
//                                                stays green
//   * `changed` compares only element 0        — the per-index loops
//   * `update` copies only `view`              — `updateThenUnchanged`
//   * `CameraStamp.view` loses its `= 0`       — `twoFreshStampsAgree`
module tests.unit.camera_stamp_test;

import std.format : format;

import camera_stamp : CameraStamp;

/// A matrix whose 16 entries are all distinct, so "compares element i" is
/// separable from "compares element j" for every pair.
float[16] ramp(float base) {
    float[16] m;
    foreach (i; 0 .. 16) m[i] = base + i;
    return m;
}

// ---------------------------------------------------------------------------
// A difference in ONE element of `view` — at EVERY index — is a change.
// ---------------------------------------------------------------------------
unittest {
    const float[16] v = ramp(1.0f);
    const float[16] p = ramp(100.0f);

    CameraStamp s;
    s.update(v, p);

    foreach (i; 0 .. 16) {
        float[16] v2 = v;
        v2[i] += 1.0f;
        assert(s.changed(v2, p),
            format("CameraStamp.changed missed a difference at view[%d] — a "
                 ~ "compare that skips one element of the view matrix lets a "
                 ~ "camera move past the key that is supposed to notice it", i));
    }
}

// ---------------------------------------------------------------------------
// A difference in ONE element of `proj` — at EVERY index — is a change.
//
// This is the half the HTTP witness cannot see: an orbit moves `view` only.
// ---------------------------------------------------------------------------
unittest {
    const float[16] v = ramp(1.0f);
    const float[16] p = ramp(100.0f);

    CameraStamp s;
    s.update(v, p);

    foreach (i; 0 .. 16) {
        float[16] p2 = p;
        p2[i] += 1.0f;
        assert(s.changed(v, p2),
            format("CameraStamp.changed missed a difference at proj[%d]. No "
                 ~ "orbit-driven test can catch this: orbiting moves `view` "
                 ~ "and leaves `proj` alone, so a stamp that compared only "
                 ~ "`view` would pass the whole suite", i));
    }
}

// ---------------------------------------------------------------------------
// Identical CONTENT, held in different arrays, is not a change — and the
// stamp answers `false` only after `update` actually copied both halves.
// ---------------------------------------------------------------------------
unittest {
    const float[16] v = ramp(1.0f);
    const float[16] p = ramp(100.0f);

    CameraStamp s;
    assert(s.changed(v, p),
        "a fresh stamp must report a change against a real pose — otherwise "
      ~ "the first render would be skipped and the FBO read before it was "
      ~ "ever rasterised");

    s.update(v, p);

    // Distinct storage, same numbers: this is what the consumer actually does
    // every frame — it rebuilds `mv` from scratch and compares against the
    // stamp.
    float[16] vSame = ramp(1.0f);
    float[16] pSame = ramp(100.0f);
    assert(!s.changed(vSame, pSame),
        "CameraStamp.changed reported a change for a pose identical to the "
      ~ "stamped one. A still camera would re-rasterise the ID buffer every "
      ~ "frame — the cache would be a cache in name only");

    // …and `update` must have copied BOTH halves, not just `view`.
    float[16] pMoved = ramp(100.0f);
    pMoved[9] = -7.0f;
    assert(s.changed(vSame, pMoved),
        "after `update`, a moved `proj` no longer registers — `update` did "
      ~ "not record the projection half");
}

// ---------------------------------------------------------------------------
// Two FRESH stamps agree — and this cell is the one that depends on
// `float[16] view = 0;` rather than D's default NaN.
//
// `NaN != NaN` is true, so under bare `float[16]` (which is what
// `GpuSelectBuffer.Slot` used to declare) two default stamps would compare as
// CHANGED. That difference is unobservable at the live consumer, because
// `slot.valid &&` short-circuits the compare until the first render
// (`gpu_select.d:482`) — an argument, not an identity, which is exactly why it
// is asserted here instead of being left as prose.
// ---------------------------------------------------------------------------
unittest {
    CameraStamp a;
    CameraStamp b;   // two separate defaults, NOT `a` compared with itself:
                     // `a.changed(a.view, a.proj)` is an arithmetic identity
                     // and would be false even under NaN initialisation.
    assert(!a.changed(b.view, b.proj),
        "two default-constructed CameraStamps disagree — `view`/`proj` lost "
      ~ "their `= 0` initialiser and fell back to D's NaN, where `NaN != NaN` "
      ~ "makes every fresh stamp differ from every other");
}
