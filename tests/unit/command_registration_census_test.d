// Every concrete `Command` subclass under source/commands/ is registered —
// the REVERSE census of `source/registration.d` (task 4066, row 10).
//
// WHAT THE CONTRACT IS. `registration.d` is the one place a wire id is bound
// to a factory (`reg.commandFactories["…"] = () => cast(Command) new X(…)`),
// and the FORWARD direction is already closed: `registerCommands` wraps the
// finished dictionary with the selection-type provider, so a factory cannot
// be registered without it. What nothing closed was the reverse. A
// `class X : Command` under source/commands/ that no factory instantiates
// compiles, links, keeps its unittests green and is reachable by no id at all
// — the shape of a registration row lost when task 0722 sliced the flat
// table into nine "contiguous" families (a row dropped between two slices
// reads exactly like the other hundred and ninety), and the shape of a
// command written and never wired. Neither lane can see it: the HTTP suite
// only drives ids that exist, and `dub test` is happy with a class that
// nobody constructs.
//
// WHAT COUNTS. A declaration `class X : Y` in source/commands/**/*.d — after
// comments, string literals and `unittest { … }` bodies are blanked — where Y
// is `Command` or another class of the set, transitively (four abstract bases
// live there: ByStatBase, ImageCommandBase, LayerCommandBase,
// ViewportCommand), and X is not marked `abstract`. "Registered" means
// `new X` appears in registration.d's CODE, blanked the same way. Four
// concrete classes are built elsewhere on purpose; they are RECORDED below
// with the file that builds them, and each row is checked against that file
// so a row cannot outlive its reason.
//
// WHAT IT DOES NOT SEE, said plainly: a Command subclass declared OUTSIDE
// source/commands/ (registry.d's `_RegTestCmd` family is test-local and lives
// in a unittest; nothing in source/tools/ derives from Command today), a
// class whose base is declared outside the scanned tree, and a registration
// that builds the class through a factory helper that never spells `new X`
// — none of those exist at the time of writing, and the population floor
// below is what says the scanner found the tree it was pointed at.
module tests.unit.command_registration_census_test;

import std.algorithm : canFind, sort;
import std.array     : appender, array;
import std.file      : dirEntries, exists, isFile, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : regex, matchAll;
import std.string    : splitLines, strip;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    enclosingSymbols, symbolAt, LedgerRow, LedgerHit, reconcile;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

private bool isIdentChar(char c) {
    import std.ascii : isAlphaNum;
    return isAlphaNum(c) || c == '_';
}

struct ClassDecl {
    string name;
    string base;       /// the first name after the colon — the base class
    bool   isAbstract;
    string file;
    size_t line;       /// 1-based
}

/// Every `class X : Y` declaration in `src` (a file's raw text).
ClassDecl[] scanClassDecls(string src, string file) {
    const code = blankUnittestBodies(blankNonCode(src));
    auto hits = appender!(ClassDecl[]);
    // Modifiers on the same line (`private abstract final …`), then `class`,
    // the name (an optional template parameter list is tolerated), then the
    // base. Interfaces after the base are not captured — the base is what the
    // census keys on.
    static immutable re = `((?:\w+[ \t]+)*)(?<!\w)class[ \t]+(\w+)(?:\([^)]*\))?[ \t]*:[ \t]*(\w+)`;
    foreach (m; matchAll(code, regex(re))) {
        size_t line = 1;
        foreach (k; 0 .. m.pre.length) if (code[k] == '\n') line++;
        hits.put(ClassDecl(m[2].idup, m[3].idup,
                           m[1].canFind("abstract"), file, line));
    }
    return hits.data;
}

/// The transitive `Command`-derived subset of `decls`, concrete and abstract.
ClassDecl[] commandDerived(const ClassDecl[] decls) {
    bool[string] inSet = ["Command": true];
    bool grew = true;
    while (grew) {
        grew = false;
        foreach (ref d; decls)
            if (d.base in inSet && d.name !in inSet) { inSet[d.name] = true; grew = true; }
    }
    auto outBuf = appender!(ClassDecl[]);
    foreach (ref d; decls) if (d.base in inSet) outBuf.put(d);
    return outBuf.data;
}

/// `new X` at an identifier boundary in already-blanked code.
bool instantiates(string code, string name) {
    return !matchAll(code, regex(`(?<!\w)new[ \t]+` ~ name ~ `(?!\w)`)).empty;
}

private ClassDecl[] scanCommandsTree(string root) {
    auto all = appender!(ClassDecl[]);
    string[] files;
    foreach (de; dirEntries(buildPath(root, "source", "commands"), "*.d", SpanMode.depth))
        files ~= de.name;
    sort(files);
    foreach (f; files)
        all.put(scanClassDecls(readText(f), f[root.length + 1 .. $]));
    return all.data;
}

// ---------------------------------------------------------------------------
// (a) The scanner discriminates — positive and negative controls on samples.
// ---------------------------------------------------------------------------

unittest { // a plain subclass is found with its base and line
    enum sample = "module x;\n\nclass Foo : Command {\n}\n";
    const d = scanClassDecls(sample, "x.d");
    assert(d.length == 1 && d[0].name == "Foo" && d[0].base == "Command"
        && !d[0].isAbstract && d[0].line == 3,
        format("expected Foo : Command at line 3, concrete; got %s", d));
}

unittest { // `private abstract class` is abstract; `final class` is not
    enum sample = "private abstract class B : Command {}\nfinal class C : B {}\n";
    const d = scanClassDecls(sample, "x.d");
    assert(d.length == 2 && d[0].isAbstract && !d[1].isAbstract, format("%s", d));
    const derived = commandDerived(d);
    assert(derived.length == 2, "C : B : Command must be reached transitively");
}

unittest { // a class in a comment, a string, or a unittest body is not a decl
    enum sample = "// class Dead : Command\n"
                ~ "string s = \"class Str : Command\";\n"
                ~ "unittest {\n    class Local : Command {}\n}\n"
                ~ "version (unittest) { class Seam : Command {} }\n";
    const d = scanClassDecls(sample, "x.d");
    assert(d.length == 1 && d[0].name == "Seam",
        format("only the version(unittest) seam is a live declaration; got %s", d));
}

unittest { // `subclass` / `new Xy` boundaries
    assert(scanClassDecls("int subclass : 3;", "x.d").length == 0);
    assert(instantiates("auto c = new Foo(1);", "Foo"));
    assert(!instantiates("auto c = new FooBar(1);", "Foo"));
    assert(!instantiates("renew Foo", "Foo"));
}

// ---------------------------------------------------------------------------
// (b) THE GATE, over the real tree.
// ---------------------------------------------------------------------------

/// Concrete Command subclasses built somewhere OTHER than registration.d, on
/// purpose. Each row names the file that builds it; the gate checks that
/// file still does, so a row whose reason went away turns red instead of
/// quietly exempting a class nobody constructs any more.
private struct BuiltElsewhere { string name; string symbol; string why; }

private static immutable BuiltElsewhere[] kBuiltElsewhere = [
    BuiltElsewhere("LayerXformEdit", "main",
        "the item-transform gizmo-drag undo record: app.d's "
      ~ "`layerXformEditFactory` closure hands it to the tool (task 0614 "
      ~ "Phase 4); it is a gesture's record, not a wire command"),
    BuiltElsewhere("MeshMorphEdit", "main",
        "the routed-gesture morph undo record: app.d's `morphEditFactory` "
      ~ "(task 1069), the same shape as LayerXformEdit"),
    BuiltElsewhere("MeshSelectionEdit", "InputRouter.commitInteractiveSelEdit",
        "the click / paint selection undo record, constructed directly by "
      ~ "the router at the gesture end"),
    BuiltElsewhere("ToolActivationCommand", "prepareArm",
        "the tool lifecycle record the prepared transition builds; never "
      ~ "dispatched by id"),
];

unittest {
    const regPath = buildPath(repoRoot, "source", "registration.d");
    assert(exists(regPath) && isFile(regPath),
        "the census cannot find " ~ regPath ~ " — it is measuring nothing");
    const regCode = blankUnittestBodies(blankNonCode(readText(regPath)));
    assert(regCode.length > 50_000,
        format("registration.d blanked to only %d bytes — wrong file", regCode.length));

    const decls   = scanCommandsTree(repoRoot);
    const derived = commandDerived(decls);

    // POPULATION FLOORS — the scanner found the tree it was pointed at.
    // Measured 2026-09-04: 223 declarations, 223 Command-derived (4 abstract),
    // 215 of the 219 concrete ones instantiated in registration.d.
    assert(decls.length >= 200,
        format("only %d `class X : Y` declarations under source/commands — the "
             ~ "scanner is not seeing the tree (223 measured at task 4066)", decls.length));
    size_t abstractCount;
    bool sawByStatBase;
    foreach (ref d; derived) {
        if (d.isAbstract) abstractCount++;
        if (d.name == "ByStatBase") sawByStatBase = d.isAbstract;
    }
    assert(sawByStatBase,
        "ByStatBase (source/commands/select/by_stat.d, `private abstract class`) "
      ~ "must be seen AND flagged abstract — the positive control for the "
      ~ "modifier capture");
    assert(abstractCount >= 1 && abstractCount <= 8,
        format("%d abstract Command bases — 4 measured at task 4066", abstractCount));

    // Every base named under source/commands resolves inside it. A class whose
    // base lives elsewhere would be silently outside the census; say so.
    bool[string] declared;
    foreach (ref d; decls) declared[d.name] = true;
    foreach (ref d; decls)
        assert(d.base == "Command" || d.base in declared,
            format("%s:%d `class %s : %s` — the base is declared outside "
                 ~ "source/commands, so this census cannot tell whether %s is a "
                 ~ "Command; extend the scanner or record the class",
                   d.file, d.line, d.name, d.base, d.name));

    // THE CENSUS.
    string[] unregistered;
    size_t registered;
    foreach (ref d; derived) {
        if (d.isAbstract) continue;
        if (instantiates(regCode, d.name)) { registered++; continue; }
        bool recorded;
        foreach (ref row; kBuiltElsewhere) if (row.name == d.name) recorded = true;
        if (!recorded) unregistered ~= format("%s (%s:%d)", d.name, d.file, d.line);
    }
    assert(registered >= 190,
        format("only %d concrete Command classes are `new`ed in registration.d "
             ~ "(215 measured at task 4066) — the instantiation match is broken",
               registered));

    // The recorded rows are checked against their owning declaration, and
    // against registration.d, so a row can neither rot nor shadow a real
    // registration. The two merge constructors are part of the closed
    // population too: otherwise a same-file move could hide a displaced
    // external builder by keeping the raw class-name count unchanged.
    static immutable LedgerRow[] builderLedger = [
        LedgerRow("main|LayerXformEdit", 1, "app factory"),
        LedgerRow("LayerXformEdit.mergeRunTail|LayerXformEdit", 1, "merge constructor"),
        LedgerRow("main|MeshMorphEdit", 1, "app factory"),
        LedgerRow("MeshMorphEdit.mergeRunTail|MeshMorphEdit", 1, "merge constructor"),
        LedgerRow("InputRouter.commitInteractiveSelEdit|MeshSelectionEdit", 1, "selection gesture"),
        LedgerRow("prepareArm|ToolActivationCommand", 1, "prepared transition"),
    ];
    LedgerHit[] builderHits;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const code = blankUnittestBodies(blankNonCode(readText(de.name)));
        const symbols = enclosingSymbols(code);
        foreach (li, line; code.splitLines) foreach (ref row; kBuiltElsewhere) {
            if (!instantiates(line, row.name)) continue;
            const symbol = symbolAt(symbols, li);
            builderHits ~= LedgerHit(symbol ~ "|" ~ row.name,
                de.name[repoRoot.length + 1 .. $], li + 1, line.strip);
        }
    }
    const builderProblems = reconcile(builderLedger, builderHits);
    assert(builderProblems.length == 0, format(
        "the closed construction ledger for the four deliberately unregistered "
      ~ "commands changed:\n%s", builderProblems));
    assert(builderHits.length == 6, format(
        "expected exactly 6 construction sites for the four exemptions, found %d",
        builderHits.length));

    foreach (ref row; kBuiltElsewhere) {
        bool declaredHere;
        foreach (ref d; derived) if (d.name == row.name && !d.isAbstract) declaredHere = true;
        assert(declaredHere,
            row.name ~ " is recorded as built elsewhere but is no longer a concrete "
          ~ "Command subclass under source/commands — delete the row");
        assert(!instantiates(regCode, row.name),
            row.name ~ " is recorded as built elsewhere but registration.d now "
          ~ "`new`s it — delete the row, the class is registered");
        bool hasBuilder;
        foreach (ref hit; builderHits)
            if (hit.key == row.symbol ~ "|" ~ row.name) hasBuilder = true;
        assert(hasBuilder, format(
            "%s no longer builds %s, which this census exempts from registration "
          ~ "because of that site (%s). Register it, delete it, or record its "
          ~ "new builder declaration here.", row.symbol, row.name, row.why));
    }

    // THE CANARY, and it is DIFFERENTIAL on purpose: one concrete class
    // appended to a real file's text, scanned the same way, must add exactly
    // one unregistered name to what that file already yields — so the zero
    // below is a measurement of this tree and not a scanner that matches
    // nothing. An absolute `== 1` was tried first and fired FIRST when the
    // gate was genuinely violated in the same file (the mutation drill put
    // the mutant in redo.d and the canary read 2), burying the census line
    // this test exists for under a "the scanner is broken" message that was
    // not true.
    {
        const sampleFile = buildPath(repoRoot, "source", "commands", "history", "redo.d");
        const sampleText = readText(sampleFile);
        size_t unregisteredIn(string text) {
            size_t n;
            foreach (ref d; commandDerived(scanClassDecls(text, "source/commands/history/redo.d")))
                if (!d.isAbstract && !instantiates(regCode, d.name)) n++;
            return n;
        }
        const base = unregisteredIn(sampleText);
        const withCanary = unregisteredIn(
            sampleText ~ "\nfinal class _RegistrationCensusCanary : Command {}\n");
        assert(withCanary == base + 1,
            format("appending one unregistered class to redo.d's text must "
                 ~ "raise that file's unregistered count from %d to %d; the "
                 ~ "scanner saw %d — the census below cannot fail",
                   base, base + 1, withCanary));
    }

    assert(unregistered.length == 0,
        format("%d concrete Command subclass(es) under source/commands are "
             ~ "instantiated by no factory in registration.d and recorded "
             ~ "nowhere: %s. A command nobody constructs is reachable by no id, "
             ~ "and both lanes stay green over it. Register it in the family it "
             ~ "belongs to, delete it, or — if it is a gesture record built by "
             ~ "a tool, like LayerXformEdit — add a `kBuiltElsewhere` row naming "
             ~ "the builder (task 4066, row 10).",
               unregistered.length, unregistered));
}
