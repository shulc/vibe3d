// Proof-of-wiring probe for the `tests` dub configuration (task 0706).
//
// This module exists for one reason: it is the only thing that can tell the
// difference between "the tests configuration is wired" and "the gate is green
// because it never compiled tests/unit/ at all". Every extraction that follows
// rests on that difference, so it is asserted rather than assumed.
//
// The proof is a MUTATION, not a green run: flipping the assert below to a
// falsehood must turn `dub test --config=tests` RED and name this file. If it
// stays green, tests/unit/ is not in the build and everything extracted into
// it has silently stopped running.
//
// Recorded 2026-08-14 with the assert inverted, on dub 1.41 / dmd:
//     Linking vibe3d-test-tests
//     Running vibe3d-test-tests
//     core.exception.AssertError@tests/unit/config_probe.d(17): ...
//     1/142 modules FAILED unittests        (exit 2, in 24s, no process left)
module tests.unit.config_probe;

unittest
{
    // Deliberately trivial. The assertion is not about the value; it is about
    // this file being reachable by the compiler at all.
    assert(1 + 1 == 2, "tests/unit/ is compiled by the `tests` configuration");
}
