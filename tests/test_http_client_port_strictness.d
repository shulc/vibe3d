// tests/http_client.d resolves VIBE3D_TEST_PORT STRICTLY — the witness.
//
// WHY THIS EXISTS. The whole point of task 4055 is that a suite driver can no
// longer end up talking to a NEIGHBOURING worker's `vibe3d --test`. The first
// worker's port is the historical default 8080, so any path that quietly
// answers "8080" when the environment did not actually say so re-opens that
// hole in its worst form: worker 3's test drives worker 0's app, reads worker
// 0's state and passes GREEN. An empty variable — a spawner that built the
// environment with a hole in it — was exactly such a path until the review.
//
// So the contract is: a variable that is SET must parse, or the transport
// refuses; only a variable nobody set at all falls back, and it says so once
// on stderr. This file is where that is asserted, because http_client.d itself
// is compiled into EVERY test binary and may carry no unittest block of its
// own (run_test.d's liveness barrier, rule (a)).
//
// No HTTP is performed here: the subject is the parse, not a connection.
//
// MUTATION: in tests/http_client.d, make the empty case return kDefaultPort
// instead of throwing — cell C2 reddens with "an EMPTY … was accepted".
// Runner: ./run_test.d test_http_client_port_strictness
module test_http_client_port_strictness;

import http_client : kDefaultPort, kPortEnv, testBaseUrl, testPort;
import std.algorithm : canFind;
import std.conv      : to;
import std.process   : environment;

void main() {}

// A port that is NOT the default, so "it fell back" and "it read the variable"
// cannot produce the same answer. Written as a number, never inside a URL
// literal: tests/unit/http_endpoint_census_test.d refuses host-and-port
// literals in this directory, and this file is not the exception.
private enum ushort kProbePort = 8811;

unittest
{
    static assert(kProbePort != kDefaultPort,
        "the probe port must differ from the default or every cell below is "
      ~ "satisfied by both the right and the wrong behaviour");

    const bool hadVar = cast(bool)(kPortEnv in environment);
    const string saved = hadVar ? environment[kPortEnv] : null;
    scope (exit)
    {
        if (hadVar) environment[kPortEnv] = saved;
        else        environment.remove(kPortEnv);
    }

    // --- C1: a set, well-formed value is what the transport uses. Green in
    // both the fixed and the broken build; it sits FIRST so a run that reddens
    // below has already shown the ordinary path works.
    environment[kPortEnv] = kProbePort.to!string;
    assert(testPort == kProbePort,
        "VIBE3D_TEST_PORT was set to " ~ kProbePort.to!string
      ~ " and testPort answered " ~ testPort.to!string);
    assert(testBaseUrl.canFind(":" ~ kProbePort.to!string),
        "testBaseUrl did not carry the port the environment named: " ~ testBaseUrl);

    // --- C2: SET BUT EMPTY is a refusal, not a request for the default.
    environment[kPortEnv] = "";
    bool refusedEmpty = false;
    try
        cast(void)testPort;
    catch (Exception e)
    {
        refusedEmpty = true;
        assert(e.msg.canFind(kPortEnv),
            "the refusal must name the variable so a spawner bug is findable: "
          ~ e.msg);
    }
    assert(refusedEmpty,
        "an EMPTY " ~ kPortEnv ~ " was accepted. Falling back to "
      ~ kDefaultPort.to!string ~ " here is the cross-worker bleed this task "
      ~ "removed: under -j the default port belongs to worker 0's instance, so "
      ~ "the test would pass green against another worker's state.");

    // --- C3: a non-numeric value is a refusal too.
    environment[kPortEnv] = "not-a-port";
    bool refusedGarbage = false;
    try
        cast(void)testPort;
    catch (Exception)
        refusedGarbage = true;
    assert(refusedGarbage,
        "a non-numeric " ~ kPortEnv ~ " was accepted");

    // --- C4: and ONLY a variable nobody set at all falls back.
    environment.remove(kPortEnv);
    assert(testPort == kDefaultPort,
        "an unset " ~ kPortEnv ~ " must resolve to the hand-run default "
      ~ kDefaultPort.to!string ~ ", got " ~ testPort.to!string);
}
