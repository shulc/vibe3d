// selftest_fault.d — `selftest.fault kind:<...>`, the deliberate-defect
// injector for the instrumented nightly lane (task 1410).
//
// WHY IT EXISTS
// -------------
// An oracle nobody has ever seen fire is a claim, not a check. Every finding
// class the nightly lane advertises — an ASan report, an assert that becomes a
// crash instead of a wedged process, a hang, a runaway command, a corrupted
// mesh — is only believable once something KNOWN-bad has produced it end to
// end, through the real HTTP path, on the real instrumented binary. This
// command is that something. Its kinds map one-to-one onto the mutation table
// in doc/tasks/*/1410-sanitizer-fuzz-nightly.md.
//
// WHY IT CANNOT REACH THE SHIPPED BINARY
// --------------------------------------
// The whole module is behind `version (SanitizerSelfTest)`, which is declared
// only by the four instrumented buildTypes in dub.json (check, check-unit,
// check-release, sanitize). `--build=release` declares no such version, so
// this module compiles to nothing there and `selftest.fault` is not a
// registered id — `POST /api/command {"id":"selftest.fault"}` answers
// `status:error, unknown command id`. That is asserted two ways by the
// nightly preflight: `dub describe --build=release` must not mention the
// version, and `strings ./vibe3d-release` must not contain the literal
// `selftest.fault` (the strictly stronger, behavioural check — `dub describe`
// with no --compiler defaults to dmd and DROPS every dflags-ldc entry, so a
// describe-only check passes vacuously).
//
// WHY NO NUMERIC PARAM
// --------------------
// `kind` is an Enum and there is deliberately not a single Int/Float here.
// tests/test_param_bounds.d Block A sweeps the WHOLE registry for count-like
// numeric params and requires `.enforceBounds()` + a finite `.max()` on each;
// a `count`- or `iterations`-shaped param on a fault injector would make the
// instrumented build fail on its own instrument. The two-layer clamp the house
// rules mandate (kernel `enum MAX_…` + `.enforceBounds()`) is therefore
// inapplicable here by construction rather than forgotten.
//
// WHY A COMMAND AND NOT A ROUTE
// -----------------------------
// A new HTTP route would mean editing `kRoutes` in http_server.d and
// satisfying its duplicate/orphan `static assert`s. A command rides the
// existing `POST /api/command` dispatcher with no route-table change at all.
//
// THE ONE WAY TO GET THIS WRONG
// -----------------------------
// `Registry.cacheSupportedModes()` (registry.d) constructs EVERY registered
// factory at startup and throws if `cmd.name()` is not itself a registered
// key. Getting `name()` wrong here does not fail this command — it aborts the
// editor's startup, so every HTTP test in the night fails at once and reads
// like a sanitizer catastrophe. `name()` below returns exactly the key
// registration.d registers. The nightly lane asserts a clean boot before it
// asserts anything else, for this reason.
module selftest_fault;

version (SanitizerSelfTest):

import core.stdc.stdlib : malloc, free;
import core.thread      : Thread;
import core.time        : msecs, seconds;

import command;
import mesh;
import view;
import editmode;
import params : Param;
import log    : logWarn;

// Sinks. Every fault below writes through a `__gshared` so the optimiser
// cannot prove the effect dead and delete the defect we are trying to inject
// (check-release is an -O3 -inline build; a local-only overrun there would
// simply vanish).
__gshared int  g_selfTestSink;
__gshared long g_selfTestSlowSink;

// ---------------------------------------------------------------------------
// The ThreadSanitizer lane's synthetic positive control (task 1411).
//
// WHY IT IS SYNTHETIC AND NOT ONE OF THE REAL RACES
// -------------------------------------------------
// The lane runs under --DRT-gcopt=gc:manual, without which TSan either
// deadlocks the process outright or drowns the log in GC memory-REUSE false
// positives. Under that flag a healthy night is QUIET -- and a quiet lane is
// exactly what a dead instrument produces too. So the arming proof cannot be
// one of the real races: those depend on the scheduler, and some of them are
// ordered away by the main-thread bridge's seq-cst atomics (which ARE
// instrumented, being core.atomic templates instantiated in our own modules).
// This one depends on nothing: two threads, one __gshared int, no
// synchronisation whatsoever.
//
// WHY ONE WORKER FUNCTION AND NOT TWO
// -----------------------------------
// Both threads run THIS function, so there is exactly one distinct stack pair,
// and TSan's default suppress_equal_stacks / suppress_equal_addresses collapse
// the whole storm into exactly ONE report -- which is what `lane.d
// tsan-selfcheck` requires: not "at least one", exactly one. Two different
// bodies could be reported in either order and would make the count flap.
//
// WHY A BARE STORE AND NOT AN INCREMENT
// -------------------------------------
// `cell = cell + 1` is a read AND a write, potentially at two different source
// lines, i.e. two stacks and possibly two reports. A single store is one line,
// one stack, one report.
//
// The iteration count is an `enum`, NOT a Param: see WHY NO NUMERIC PARAM
// above -- a count-shaped param on this command would fail the registry-wide
// bounds sweep that the instrumented build runs on itself.
private enum int kSelfTestRaceIters = 1_000_000;
__gshared int g_selfTestRaceCell;

void selfTestRaceWorker() {
    foreach (int i; 0 .. kSelfTestRaceIters) g_selfTestRaceCell = i;
}

/// `selftest.fault kind:<heapoverflow|uaf|assertfail|hang|slow|invariant|race>`
final class SelfTestFaultCommand : Command {
    private string kind_ = "assertfail";

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "selftest.fault"; }
    override string label() const { return "Self-test fault injector"; }

    // SideEffect: never on the undo stack. UndoSuppress on top of it because
    // `invariant` DOES mutate the mesh, and an undo entry for a deliberate
    // corruption would let a later Ctrl+Z quietly repair the thing the oracle
    // is supposed to report.
    override CmdFlags cmdFlags() const {
        return CmdFlags.SideEffect | CmdFlags.UndoSuppress;
    }

    override Param[] params() {
        return [
            Param.enum_("kind", "Kind", &kind_, [
                ["heapoverflow", "C heap-buffer-overflow (ASan CATCHES)"],
                ["gcoverflow",   "D GC-heap overrun (ASan is BLIND — negative control)"],
                ["uaf",          "C heap-use-after-free (ASan CATCHES)"],
                ["assertfail",   "failed assert (checkaction)"],
                ["hang",         "wedge the main thread"],
                ["slow",         "runaway-but-finite command (DoS oracle)"],
                ["invariant",    "corrupt a face index (mesh oracle)"],
                ["race",         "unsynchronised __gshared int, 2 threads (TSan CATCHES)"],
            ], "assertfail"),
        ];
    }

    override bool apply() {
        switch (kind_) {

        // ------------------------------------------------------------------
        // ASan POSITIVE control #1 — an overrun of a C-heap block. Caught:
        // `heap-buffer-overflow`, process dies. This is the shape that
        // actually bites this project: eight of twelve dependencies are
        // wrappers over C/C++, and all three recorded real crashes were on
        // that seam or past it.
        // ------------------------------------------------------------------
        case "heapoverflow": {
            auto p = cast(int*) malloc(4 * int.sizeof);
            if (p is null) return false;
            const idx = 4 + (g_selfTestSink & 3) + 3;   // 7..10, opaque to -O3
            p[idx] = 0xBAD;                             // 3+ ints past the end
            g_selfTestSink = p[idx];
            free(p);
            return true;
        }

        // ------------------------------------------------------------------
        // ASan NEGATIVE control — and the single most important limit of this
        // whole lane, which is why it is a first-class kind rather than a
        // sentence in a comment.
        //
        // ASAN IS BLIND TO THE D GC HEAP. Measured, standalone and in-process:
        // a write 3 ints past a `new int[](4)` is accepted silently; so is one
        // 400 KB past it (`a.ptr[100000]`); only at ~400 MB does the process
        // SEGV, and ASan then reports SIGSEGV rather than heap-buffer-overflow.
        // The reason is structural: druntime's conservative GC takes large
        // pools from the OS and sub-allocates D objects inside them, so ASan's
        // redzones sit around the POOL, not around anything a D program calls
        // an object. Nothing about the run configuration changes this.
        //
        // So this kind is expected to be SILENT, and the lane asserts that it
        // is. If it ever starts reporting, druntime grew ASan-aware allocation
        // and the scope paragraph in the task file is out of date — which is a
        // finding of its own.
        //
        // The consequence for the plan: `sanitize` earns its place for the
        // C/C++ seam and for alloc/free discipline, NOT for our own D data
        // structures. Bounds errors in D arrays are caught by
        // --boundscheck=on in `check-release`, which is a different mechanism
        // in a different buildType.
        // ------------------------------------------------------------------
        case "gcoverflow": {
            auto a = new int[](4);
            const idx = 4 + (g_selfTestSink & 3) + 3;
            a.ptr[idx] = 0xBAD;
            g_selfTestSink = a.ptr[idx];
            return true;
        }

        // ------------------------------------------------------------------
        // ASan positive control #2 — use-after-free, on the C heap for the
        // same reason as above: a "freed" GC block is still mapped and quiet,
        // and ASan cannot see it.
        // ------------------------------------------------------------------
        case "uaf": {
            auto p = cast(int*) malloc(16);
            if (p is null) return false;
            p[0] = 1;
            free(p);
            g_selfTestSink = p[0];          // read of freed memory
            return true;
        }

        // ------------------------------------------------------------------
        // The checkaction control, and the reason `check` carries
        // --checkaction=C at all.
        //
        //   built with -C : SIGABRT here, immediately, before any unwinding —
        //                   the crash oracle sees a signal and a core.
        //   built with -D : AssertError unwinds out through the command
        //                   dispatcher and kills the MAIN thread. The process
        //                   does not die: app.d's shutdown scope(exit) calls
        //                   HttpServer.stop(), and every request that arrives
        //                   in the meantime spins the command bridge for its
        //                   full 120 s budget (kCommandBridgeMaxIters=60_000
        //                   x 2 ms) before answering HTTP 200 with
        //                   `timeout waiting for main thread`. So the TEST
        //                   hangs while the PROCESS is alive and answering —
        //                   which is why the lane needs a per-test timeout
        //                   (task 1420) as well as this flag. They fix
        //                   different halves of the same failure.
        //
        //   Under check-release, `-release` compiles asserts out entirely and
        //   this kind is a NO-OP that returns true. That is stated rather than
        //   hidden: the release-shaped lane cannot exercise the assert oracle,
        //   and a green here proves nothing about it.
        // ------------------------------------------------------------------
        case "assertfail":
            assert(g_selfTestSink == 0x7FFFFFFF,
                   "selftest.fault: deliberate assert failure");
            return true;

        // ------------------------------------------------------------------
        // The hang oracle's control. Runs on the MAIN thread (every
        // /api/command body does), so this reproduces the real wedge exactly:
        // main thread gone, HTTP thread alive, requests answered 200 with a
        // timeout body after 120 s each. A lane without a per-test budget
        // waits here forever.
        // ------------------------------------------------------------------
        case "hang":
            logWarn("selftest", "selftest.fault kind:hang — wedging the main "
                              ~ "thread on purpose; this instance must be killed");
            for (;;) Thread.sleep(60.seconds);

        // ------------------------------------------------------------------
        // The denial-of-service oracle's control: finite, but far outside any
        // sane multiple of a calibration command. Bounded on purpose — an
        // UNbounded one would be indistinguishable from `hang` and would tell
        // the two oracles apart by luck. ~2e9 iterations of dependent
        // arithmetic the optimiser cannot hoist: tens of seconds even at -O3.
        // ------------------------------------------------------------------
        case "slow": {
            long acc = g_selfTestSlowSink;
            foreach (i; 0 .. 2_000_000_000L) acc = acc * 6364136223846793005L + i;
            g_selfTestSlowSink = acc;
            return true;
        }

        // ------------------------------------------------------------------
        // The mesh-invariant oracle's control: structural corruption that does
        // NOT crash on the spot. A face now names a vertex that does not
        // exist; /api/model still serialises, the editor still draws, and only
        // an invariant check notices. Written straight into the face store
        // with no commit, deliberately — going through a mutator would trip
        // the validity asserts and turn this into a crash, which is the OTHER
        // oracle's job.
        // ------------------------------------------------------------------
        case "invariant": {
            if (mesh is null) return false;
            if (mesh.faces.length == 0 || mesh.faces[0].length == 0) return false;
            mesh.faces[0][0] = cast(uint)(mesh.vertices.length + 1000);
            return true;
        }

        // ------------------------------------------------------------------
        // The ThreadSanitizer lane's positive control -- the ONE check that
        // separates "the night was clean" from "the instrument was dead".
        // Exactly one report is expected, naming selfTestRaceWorker above; see
        // its header for why the shape is what it is. This returns TRUE: the
        // command succeeds and the finding is in the TSan report file, not in
        // the HTTP reply, so a lane that reads only the reply sees nothing.
        //
        // Built without --fsanitize=thread this kind is silent and harmless,
        // which is the mutation `lane.d tsan-selfcheck` is required to redden
        // on.
        // ------------------------------------------------------------------
        case "race": {
            g_selfTestRaceCell = 0;
            auto a = new Thread(&selfTestRaceWorker);
            auto b = new Thread(&selfTestRaceWorker);
            a.start();
            b.start();
            a.join();
            b.join();
            g_selfTestSink = g_selfTestRaceCell;
            return true;
        }

        default:
            return false;
        }
    }
}
