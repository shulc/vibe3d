module tests.unit.commands.tool.tool_host_read_view_test;

import commands.tool.host : ToolHost, ToolHostReadView;
import core.exception : AssertError;
import std.exception : assertThrown;
import std.traits : hasFunctionAttributes, ReturnType;

private struct RefReadMirror {
    ToolHost* host_;
    ref ToolHost read() return { return *host_; }
}

private struct PublicFieldMirror {
    ToolHost* host_;
    ToolHost read() { return *host_; }
}

private struct PointerAliasMirror {
    ToolHost* host_;
    ToolHost read() { return *host_; }
    alias host_ this;
}

private struct RefAliasMirror {
private:
    ToolHost* host_;

public:
    ToolHost read() { return *host_; }
    ref ToolHost backing() return { return *host_; }
    alias backing this;
}

private void bindRef(ref ToolHost) {}
private void bindPointer(ToolHost*) {}

private enum readsHost(T) = __traits(compiles, (ref T v) {
    ToolHost h = v.read();
});
private enum readAssign(T) = __traits(compiles, (ref T v, ToolHost h) {
    v.read() = h;
});
private enum readRefBind(T) = __traits(compiles, (ref T v) {
    bindRef(v.read());
});
private enum withReadAssign(T) = __traits(compiles, (ref T v, ToolHost h) {
    with (v) read() = h;
});
private enum addressOfRead(T) = __traits(compiles, (ref T v) {
    ToolHost* p = &v.read();
});
private enum fieldAssign(T) = __traits(compiles, (ref T v, ToolHost* p) {
    v.host_ = p;
});
private enum fieldDeref(T) = __traits(compiles, (ref T v, ToolHost h) {
    *v.host_ = h;
});
private enum implicitPointer(T) = __traits(compiles, (ref T v) {
    ToolHost* p = v;
});
private enum pointerParam(T) = __traits(compiles, (ref T v) {
    bindPointer(v);
});
private enum viewRefBind(T) = __traits(compiles, (ref T v) {
    bindRef(v);
});
private enum forwardedAssign(T) = __traits(compiles,
        (ref T v, bool delegate(string) d) {
    v.resetActiveTool = d;
});

private string[] publicMembers(T)() {
    string[] names;
    foreach (m; __traits(allMembers, T))
        static if (__traits(getVisibility,
                           __traits(getMember, T, m)) != "private")
            names ~= m;
    return names;
}

unittest { // V1: the only public read is by value
    static assert(readsHost!ToolHostReadView,
        "6350 V1 control: read() no longer yields a ToolHost value");
    static assert(readAssign!RefReadMirror,
        "6350 V1 CONTROL readAssign is not ref-shaped");
    static assert(readRefBind!RefReadMirror,
        "6350 V1 CONTROL readRefBind is not ref-shaped");
    static assert(withReadAssign!RefReadMirror,
        "6350 V1 CONTROL withReadAssign is not ref-shaped");
    static assert(addressOfRead!RefReadMirror,
        "6350 V1 CONTROL addressOfRead is not ref-shaped");
    static assert(fieldAssign!PublicFieldMirror,
        "6350 V1 CONTROL fieldAssign is not public-field-shaped");
    static assert(fieldDeref!PublicFieldMirror,
        "6350 V1 CONTROL fieldDeref is not public-field-shaped");
    static assert(implicitPointer!PointerAliasMirror,
        "6350 V1 CONTROL implicitPointer is not pointer-alias-shaped");
    static assert(pointerParam!PointerAliasMirror,
        "6350 V1 CONTROL pointerParam is not pointer-alias-shaped");
    static assert(viewRefBind!RefAliasMirror,
        "6350 V1 CONTROL viewRefBind is not ref-alias-shaped");
    static assert(forwardedAssign!RefAliasMirror,
        "6350 V1 CONTROL forwardedAssign is not ref-alias-shaped");

    static assert(__traits(hasMember, ToolHostReadView, "host_"),
        "6350 V1 field negatives would be vacuous: the private backing is no longer named host_");
    static assert(!readAssign!ToolHostReadView,
        "6350 V1 read() result is assignable: read returns ref again");
    static assert(!readRefBind!ToolHostReadView,
        "6350 V1 read() binds to ref: read returns ref again");
    static assert(!withReadAssign!ToolHostReadView,
        "6350 V1 with-read result is assignable: read returns ref again");
    static assert(!addressOfRead!ToolHostReadView,
        "6350 V1 read() address can be taken: read returns ref again");
    static assert(!fieldAssign!ToolHostReadView,
        "6350 V1 backing address is writable outside host.d: it is no longer private");
    static assert(!fieldDeref!ToolHostReadView,
        "6350 V1 backing address is writable outside host.d: it is no longer private");
    static assert(!implicitPointer!ToolHostReadView,
        "6350 V1 view exposes the ToolHost address through alias this");
    static assert(!pointerParam!ToolHostReadView,
        "6350 V1 view exposes the ToolHost address through alias this");
    static assert(!viewRefBind!ToolHostReadView,
        "6350 V1 view binds as ref ToolHost: alias this to a ref accessor");
    static assert(!forwardedAssign!ToolHostReadView,
        "6350 V1 view binds as ref ToolHost: alias this to a ref accessor");

    static assert(publicMembers!ToolHostReadView() == ["__ctor", "read"],
        "6350 V1 declaration census: the public surface is exactly the binding constructor and read()");
    static assert(__traits(getOverloads, ToolHostReadView, "read").length == 1,
        "6350 V1 declaration census: read overload count changed");
    static assert(is(ReturnType!(ToolHostReadView.read) == ToolHost),
        "6350 V1 declaration census: read does not return ToolHost by value");
    static assert(!hasFunctionAttributes!(ToolHostReadView.read, "ref"),
        "6350 V1 declaration census: read returns ref");
    static assert(__traits(getAliasThis, ToolHostReadView).length == 0,
        "6350 V1 declaration census: alias this");
}

unittest { // V2: a late member write is observed without a previous read
    ToolHost backing;
    size_t stale, live;
    backing.resetActiveTool = (string) { ++stale; return true; };
    assert(backing.resetActiveTool("") && stale == 1,
        "6350 V2 control: the construction-time delegate is not countable");
    auto view = ToolHostReadView(&backing);
    backing.resetActiveTool = (string) { ++live; return true; };
    assert(view.read().resetActiveTool(""),
        "6350 V2 late read call returned false");
    assert(live == 1 && stale == 1,
        "6350 V2 read after a late member write reached the construction-time delegate");
}

unittest { // V3: a whole-host reassignment is observed by the next read
    ToolHost backing;
    size_t first, second;
    backing.resetActiveTool = (string) { ++first; return true; };
    auto view = ToolHostReadView(&backing);
    assert(view.read().resetActiveTool("") && first == 1,
        "6350 V3 population: the first read did not reach the first host");
    ToolHost replacement;
    replacement.resetActiveTool = (string) { ++second; return false; };
    backing = replacement;
    assert(!view.read().resetActiveTool(""),
        "6350 V3 a whole-host reassignment was not seen by the next read");
    assert(second == 1 && first == 1,
        "6350 V3 the second read reused the first read");
}

unittest { // V4a: a null binding is rejected
    assertThrown!AssertError(ToolHostReadView(null),
        "6350 V4 a null binding was accepted");
}

unittest { // V4b: a default-constructed view rejects its first read
    assertThrown!AssertError(ToolHostReadView.init.read(),
        "6350 V4b an unbound read did not assert");
}
