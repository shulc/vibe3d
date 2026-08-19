// One pointer compare that turns "a GL object was constructed on a thread with
// no GL context" into a message naming the funnel, instead of a SIGSEGV inside
// a driver dispatch slot.
//
// WHY. `/api/registry?params=1` used to answer by instantiating every
// registered tool factory to read its Param schema (task 0579). A Tool builds
// its gizmo banks in its own constructor, every gizmo shape allocates a VAO,
// and the HTTP thread has no context — so the request died with a stack that
// named neither the endpoint, nor the factory, nor the GL call. Task 0584 then
// swept every other request-to-GL route and found none, so the 0579 fix was
// complete; this guard is not a second fix but an instrument, so that the next
// one is one line of stderr rather than a bisection.
//
// SCOPE — THE TWO CONSTRUCTOR FUNNELS, AND DELIBERATELY NOTHING ELSE.
// The 0584 sweep's finding was that the whole crash class funnels into exactly
// two places: `handles.gl_util.buildVao3f` (every Handler shape's geometry) and
// `shader.compileShader` (every program, including `createProgram`,
// `createProgramWithGeom` and gpu_select's own). Guarding those two covers
// every tool, every gizmo and every shader, because construction is where the
// allocation happens.
//
// NOT COVERED, on purpose: the per-frame draw and upload funnels — GpuMesh
// upload, GpuSelectBuffer, ViewportFbo.ensure, OsdAccel.buildPreview, the lazy
// VAOs in `drawWorldSegment`/`drawWorldQuad`. That is ~30 more sites, no crash
// has ever come from one of them, and they sit on the frame path where this
// check would be paid every frame instead of once per object. If a violation
// ever does come from there, the guard to add is the same call, not a
// different mechanism.
//
// A THIRD FUNNEL, AND IT IS NOT ABOUT GL (task 0635): `imageRowText`, the
// three clip-row memo writers in `ui/image_rows.d` + `io/image_path.d`. What
// this guard actually asserts is "the thread that owns the frame", and GL was
// simply the first thing that cared; a per-item cache filled from the draw
// path cares for the same reason, since a second writer would tear a `string`
// field rather than a driver call. It is on the frame PATH but not paid per
// frame — the call sits inside the cache-miss branch, so it is once per input
// change, which is the same "once per object" shape as the two above.
//
// COST. One relaxed atomic load of a pointer plus one TLS read, on paths that
// are already making a driver round-trip. Left always-on rather than under
// `debug`: the fault it converts is just as fatal in a release build, and
// there is nothing to save.
module gl_thread_guard;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.thread : Thread;

/// Thrown by `glThreadGuard`. An `Error`, not an `Exception`, on purpose: the
/// HTTP server's request loop catches `Exception` per request and would
/// otherwise turn a context violation into a 500 that nobody reads.
class GlThreadError : Error
{
    this(string msg) nothrow @safe pure { super(msg); }
}

// Identity of the thread that owns the GL context, as a bare pointer so the
// comparison is a load and a compare. Null until `markMainThread` runs, which
// makes the guard inert under `dub test` (no app `main`) — the documented
// no-op state, not an oversight.
private shared void* g_glThread;

// Suppresses the stderr line only; the throw is unconditional. Set by this
// module's unittest, which trips the guard deliberately.
private shared bool g_mute;

/// Record the calling thread as the GL owner. Called once, first thing in
/// `main()`, before any subsystem can build a shader or a handle.
void markMainThread() nothrow @nogc
{
    atomicStore!(MemoryOrder.rel)(g_glThread, cast(shared(void*)) cast(void*) Thread.getThis());
}

/// Fail, naming `funnel` and the offending thread, if this is not the thread
/// that owns the GL context. No-op before `markMainThread`.
void glThreadGuard(string funnel)
{
    const owner = atomicLoad!(MemoryOrder.acq)(g_glThread);
    if (owner is null) return;                       // unmarked: inert
    auto self = cast(void*) Thread.getThis();        // null for a raw pthread
    if (self is cast(void*) owner) return;           // the common case ends here

    // A thread with no druntime `Thread` returns null above and lands here,
    // which is the safe direction: it is certainly not the GL owner.
    const string msg = "GL-OFF-MAIN-THREAD funnel=" ~ funnel
                     ~ " thread=" ~ describeThread(cast(Thread) self);
    // stderr FIRST and flushed: the HTTP request loop lets an Error escape the
    // whole server thread rather than reporting it, so this line is the
    // artifact that actually reaches whoever is debugging.
    //
    // Muted only by this module's own unittest, which trips the guard on
    // purpose. A green `dub test` printing GL-OFF-MAIN-THREAD would teach
    // everyone to scroll past the one line that matters.
    if (!atomicLoad(g_mute)) {
        try {
            import std.stdio : stderr;
            stderr.writeln(msg);
            stderr.flush();
        } catch (Exception) { /* diagnostics must not mask the throw below */ }
    }
    throw new GlThreadError(msg);
}

// ---------------------------------------------------------------------------
// Test hooks (task 1500). Both were already needed by this module's OWN
// unittest, which reached the two `shared` globals directly because it lives
// here. Task 1500 puts a second witness in tests/unit/subpatch_osd_test.d —
// that the subpatch build's pure half runs clean off the GL thread while its
// GL half does not — and that one is in a different module, so the two
// levers become a two-line public surface instead of a copied global.
version (unittest) {
    /// Un-mark the GL owner, returning the guard to its inert state.
    void clearMainThreadForTest() nothrow @nogc
    {
        atomicStore!(MemoryOrder.rel)(g_glThread, cast(shared(void*)) null);
    }

    /// Silence the stderr line for a violation a test trips ON PURPOSE. A
    /// green `dub test` printing GL-OFF-MAIN-THREAD teaches everyone to
    /// scroll past the one line that matters.
    void muteGlThreadGuardForTest(bool m) nothrow @nogc
    {
        atomicStore(g_mute, m);
    }
}

private string describeThread(Thread t) nothrow
{
    if (t is null) return "non-druntime-thread";
    try {
        const n = t.name;
        return n.length ? n : "unnamed-D-thread";
    } catch (Exception) {
        return "unnamed-D-thread";
    }
}

// ---------------------------------------------------------------------------
// Unittests. These exercise the guard's own logic; the guard's behaviour in
// the live binary was verified separately by restoring the 0579 shape (a
// `reg.toolFactories["move"]()` inside the registry closure) and observing it
// fire — see the task log. A guard that has only ever been reasoned about is
// worth nothing.
// ---------------------------------------------------------------------------
unittest
{
    // Unmarked is inert. This is the state every `dub test` module runs in, so
    // asserting it keeps the gate honest about what it is NOT covering.
    assert(atomicLoad(g_glThread) is null,
           "no app main() under unittest, so the guard must start inert");
    glThreadGuard("buildVao3f");   // must not throw

    scope(exit) {
        atomicStore(g_glThread, cast(shared(void*)) null);
        atomicStore(g_mute, false);
    }
    atomicStore(g_mute, true);   // the violation below is deliberate; do not shout
    markMainThread();

    // The marking thread passes.
    glThreadGuard("buildVao3f");

    // Any other thread fails, by name, at the call — not later and not silently.
    string caught;
    auto other = new Thread({
        try { glThreadGuard("compileShader"); }
        catch (GlThreadError e) { caught = e.msg; }
    });
    other.start();
    other.join();

    import std.algorithm : canFind;
    assert(caught.length, "a non-GL thread must not pass the guard");
    assert(caught.canFind("funnel=compileShader"),
           "the failure must name the funnel that was entered: " ~ caught);
    assert(caught.canFind("thread="),
           "the failure must name the offending thread: " ~ caught);
}
