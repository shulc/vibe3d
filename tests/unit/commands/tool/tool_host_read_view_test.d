module tests.unit.commands.tool.tool_host_read_view_test;

import commands.tool.host : ToolHost, ToolHostReadView;
import core.exception : AssertError;
import std.algorithm : count, sort;
import std.array : join;
import std.exception : assertThrown;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;
import std.traits : hasFunctionAttributes, ReturnType;
import tests.unit.census_symbols : blankNonCode, isIdentChar, LedgerHit,
    LedgerRow, reconcile, symbolTokenHits;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
    "..", "..", "..", "..");

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

private size_t identifierCount(string code, string ident) {
    size_t result, from;
    while (from + ident.length <= code.length) {
        const rel = code[from .. $].indexOf(ident);
        if (rel < 0) break;
        const pos = from + cast(size_t)rel;
        const before = pos > 0 && isIdentChar(code[pos - 1]);
        const after = pos + ident.length < code.length
            && isIdentChar(code[pos + ident.length]);
        if (!before && !after) ++result;
        from = pos + ident.length;
    }
    return result;
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
        "6350 V1 CONTROL implicit address conversion is not alias-shaped");
    static assert(pointerParam!PointerAliasMirror,
        "6350 V1 CONTROL address parameter conversion is not alias-shaped");
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

unittest { // V5: the owner address is confined to ToolHostReadView
    string[] paths;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d",
                               SpanMode.depth))
        paths ~= entry.name;
    paths.sort();
    assert(paths.length >= 500, format(
        "6350 V5 source population is implausibly small: %s files",
        paths.length));

    string[] retiredChannelFiles;
    LedgerHit[] addressShapeHits;
    LedgerHit[] constructorHits;
    LedgerHit[] ownerAddressHits;
    string[] namingFiles;
    string hostCode;
    size_t fieldReads;
    size_t reflectionHits;
    string[] bypassFiles;
    foreach (path; paths) {
        const code = blankNonCode(readText(path));
        const relative = path[repoRoot.length + 1 .. $];
        if (identifierCount(code, "toolHostPtr") != 0)
            retiredChannelFiles ~= relative;
        foreach (needle; ["ToolHost*", "ToolHost *", "ToolHost)*"])
            addressShapeHits ~= symbolTokenHits(code, relative, needle);
        constructorHits ~= symbolTokenHits(
            code, relative, "ToolHostReadView(");
        ownerAddressHits ~= symbolTokenHits(code, relative, "&toolHost");
        fieldReads += code.count("toolHostView.read");
        if (code.indexOf("ToolHostReadView") >= 0
                || code.indexOf("toolHostView") >= 0) {
            namingFiles ~= relative;
            const bypass = code.count("tupleof") + code.count("getMember")
                + identifierCount(code, "mixin");
            if (bypass > 0) bypassFiles ~= relative;
            reflectionHits += bypass;
        }
        if (relative == "source/commands/tool/host.d") hostCode = code;
    }

    assert(retiredChannelFiles.length == 0,
        "6350 V5 the retired ToolHost address channel reappeared: "
        ~ retiredChannelFiles.join(", "));
    const addressDrift = reconcile([
        LedgerRow("ToolHostReadView", 2,
                  "the private backing field and the binding constructor's parameter"),
    ], addressShapeHits);
    assert(addressDrift.length == 0,
        "6350 V5 a ToolHost address escaped ToolHostReadView:" ~ addressDrift);
    const constructorDrift = reconcile([
        LedgerRow("main", 1, "the single binding of main()'s ToolHost"),
    ], constructorHits);
    assert(constructorDrift.length == 0,
        "6350 V5 ToolHostReadView binding census changed:" ~ constructorDrift);
    const ownerAddressDrift = reconcile([
        LedgerRow("main", 1, "the view binding is the only address taken"),
    ], ownerAddressHits);
    assert(ownerAddressDrift.length == 0,
        "6350 V5 ToolHost address-taking census changed:" ~ ownerAddressDrift);
    assert(identifierCount(hostCode, "host_") == 4, format(
        "6350 V5 ToolHostReadView backing-token population: expected 4, got %s",
        identifierCount(hostCode, "host_")));
    assert(fieldReads == 0,
        "6350 V5 EditorApp.toolHostView gained a direct read outside registrars");

    immutable expectedNamingFiles = [
        "source/app.d",
        "source/commands/tool/host.d",
        "source/editor_app.d",
        "source/pipe_command_registration.d",
        "source/registration.d",
        "source/tool_lifecycle_registration.d",
    ];
    assert(namingFiles == expectedNamingFiles, format(
        "6350 V5 ToolHostReadView naming set changed: %s", namingFiles));
    assert(reflectionHits == 0,
        "6350 V5 reflection or a mixin can bypass the private backing in "
        ~ bypassFiles.join(", "));
    // A string mixin hides an accessor from the token counts above, so the
    // module's own member set is pinned by the compiler, not by the text.
    static import commands.tool.host;
    static assert([__traits(allMembers, commands.tool.host)]
        == ["object", "ToolHost", "ToolHostReadView"],
        "6350 V5 commands.tool.host gained a member beside the view");
}

unittest { // V4b: a default-constructed view rejects its first read
    assertThrown!AssertError(ToolHostReadView.init.read(),
        "6350 V4b an unbound read did not assert");
}
