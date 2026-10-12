module tests.unit.io.file_model_test;

import std.file : exists;

import io.file_model : browserFileModel, selectBrowserBackendForTest;
static import io.file_dialog;
import std.algorithm : canFind, startsWith;
import std.array : join;
import std.file : dirEntries, readText, SpanMode;
import std.exception : assertThrown;
import core.exception : AssertError;
import std.path : dirName, buildPath;
import std.regex : matchAll, regex;
import std.string : split;
import tests.unit.census_symbols : blankNonCode, countIdent, balancedSpan;

private enum root = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));

private string compactCode(string relative) {
    return blankNonCode(readText(buildPath(root, relative))).split.join("");
}

private string sourceBody(string code, string type, string name, string parameters) {
    size_t[] declarations;
    foreach (m; matchAll(code, regex("\\b" ~ type ~ "\\s+" ~ name ~ "\\s*\\(")))
        declarations ~= m.pre.length;
    assert(declarations.length == 1, "file model unique production declaration: " ~ name);
    const at = declarations[0];
    int depth;
    foreach (c; code[0 .. at]) {
        if (c == '{') ++depth;
        else if (c == '}') --depth;
    }
    assert(depth == 0, "file model top-level production declaration: " ~ name);
    const head = matchAll(code[at .. $], regex("^" ~ type ~ "\\s+" ~ name ~ "\\s*\\("));
    auto open = at + head.front[0].length - 1;
    const group = balancedSpan(code, open, '(', ')');
    assert(group.split.join("") == "(" ~ parameters ~ ")",
        "file model production parameters: " ~ name);
    open += group.length;
    while (open < code.length && (code[open] == ' ' || code[open] == '\t' || code[open] == '\n' || code[open] == '\r'))
        ++open;
    const body = balancedSpan(code, open, '{', '}');
    assert(body.length > 0, "file model immediate balanced body: " ~ name);
    return body.split.join("");
}

private void requireChooser(string code, string call) {
    const arguments = call == "Open" ? "fs,startDir" : "fs,defaultName,startDir";
    const parameters = call == "Open" ? "FilterSpec[]fs,stringstartDir=null" :
        "FilterSpec[]fs,stringdefaultName,stringstartDir=null";
    const body = sourceBody(code, "PickResult", "pick" ~ call ~ "Path", parameters);
    assert(body.startsWith("{version(web){returnclassifyBrowser(browserPick" ~ call ~ "Path(" ~ arguments
        ~ "));}else{version(unittest){if(browserFileModel())returnclassifyBrowser(browserPick"
        ~ call ~ "Path(" ~ arguments ~ "));}importcommand:g_testMode;"),
        "file model chooser getter and branch order: " ~ call);
}

// Compatibility imports name the same functions and therefore the same storage.
static assert(__traits(isSame, browserFileModel, io.file_dialog.browserFileModel));
static assert(__traits(isSame, selectBrowserBackendForTest,
                       io.file_dialog.selectBrowserBackendForTest));

unittest {
    scope (exit) selectBrowserBackendForTest(false);
    io.file_dialog.selectBrowserBackendForTest(false);
    assert(!browserFileModel(), "file model desktop mode");
    io.file_dialog.selectBrowserBackendForTest(true);
    assert(browserFileModel(), "file model compatibility setter shares storage");
    selectBrowserBackendForTest(false);
    assert(!io.file_dialog.browserFileModel(), "file model lower setter shares storage");
}

unittest {
    const lower = compactCode("packages/common/source/io/file_model.d");
    assert(lower.canFind("version(unittest){privateboolg_browserBackendForTest;"
        ~ "voidselectBrowserBackendForTest(boolenabled){g_browserBackendForTest=enabled;}"),
        "file model sole lower unittest storage and setter");
    assert(countIdent(blankNonCode(readText(buildPath(root, "packages/common/source/io/file_model.d"))),
                     "g_browserBackendForTest") == 3,
        "file model exactly one switch definition/write/read");
    assert(sourceBody(blankNonCode(readText(buildPath(root, "packages/common/source/io/file_model.d"))),
        "bool", "browserFileModel", "") ==
        "{version(web){returntrue;}else{version(unittest){returng_browserBackendForTest;}else{returnfalse;}}}",
        "file model lower getter branch order and storage");
    const chooser = compactCode("source/io/file_dialog.d");
    assert(chooser.canFind("publicimportio.file_model:browserFileModel;") &&
           chooser.canFind("version(unittest)publicimportio.file_model:selectBrowserBackendForTest;"),
        "file model chooser public compatibility aliases");
    foreach (call; ["Open", "Save"])
        requireChooser(blankNonCode(readText(buildPath(root, "source/io/file_dialog.d"))), call);
    assert(compactCode("packages/common/source/io/image_path.d").canFind("importio.file_model:browserFileModel;") &&
           !compactCode("packages/common/source/io/image_path.d").canFind("io.file_dialog"),
        "file model image paths import lower owner directly");
    size_t sourceFiles;
    foreach (scanSourceRoot; [buildPath(root, "source"), buildPath(root, "packages/common/source"), buildPath(root, "packages/document-model/source"), buildPath(root, "packages/param-schema/source"), buildPath(root, "packages/pipe-runtime/source"), buildPath(root, "packages/mesh-ops/source"), buildPath(root, "packages/interchange/source"), buildPath(root, "packages/interaction-query/source"), buildPath(root, "packages/pipe-evaluation/source"), buildPath(root, "packages/tool-state/source"), buildPath(root, "packages/transform-ops/source"), buildPath(root, "packages/creation-ops/source"), buildPath(root, "packages/alignment-ops/source"), buildPath(root, "packages/input-events/source"), buildPath(root, "packages/display-policy/source"), buildPath(root, "packages/viewport-gpu/source"), buildPath(root, "packages/subpatch-preview/source"), buildPath(root, "packages/edit-contracts/source"), buildPath(root, "packages/mesh-change/source"), buildPath(root, "packages/mesh-contracts/source"), buildPath(root, "packages/mesh-edit-log/source"), buildPath(root, "packages/mesh-edit-replay/source"), buildPath(root, "packages/mesh-snapshot/source"), buildPath(root, "packages/mesh-topology/source"), buildPath(root, "packages/mesh/source"), buildPath(root, "packages/profiling/source"), buildPath(root, "packages/spatial/source"), buildPath(root, "util/log/source"), buildPath(root, "util/math/source"), buildPath(root, "util/parallel/source"), buildPath(root, "util/plane-bytes/source"), buildPath(root, "util/screen-buckets/source"), buildPath(root, "packages/pipe-contracts/source"), buildPath(root, "packages/mesh-preview/source"), buildPath(root, "util/json-number/source")])

    foreach (file; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) {
        ++sourceFiles;
        if (file.name == buildPath(root, "packages/common/source/io/file_model.d")) continue;
        const code = blankNonCode(readText(file.name));
        assert(countIdent(code, "g_browserBackendForTest") == 0,
            "file model switch has only its lower production owner: " ~ file.name);
        assert(!code.split.join("").canFind("voidselectBrowserBackendForTest("),
            "file model setter has only its lower production owner: " ~ file.name);
    }
    // Wave9 fixed owner map: desktop436 + thirty-one libraries172 =608.
    assert(sourceFiles == 608, "file model production source population");
}

unittest {
    import std.string : replace;
    const production = blankNonCode(readText(buildPath(root, "source/io/file_dialog.d")));
    foreach (call; ["Open", "Save"]) {
        const parameters = call == "Open" ? "FilterSpec[]fs,string startDir=null" :
            "FilterSpec[]fs,string defaultName,string startDir=null";
        const body = sourceBody(production, "PickResult", "pick" ~ call ~ "Path", parameters.split.join(""));
        const header = "PickResult pick" ~ call ~ "Path(" ~ parameters ~ ")";
        const valid = header ~ body;
        const wrong = valid.replace("if(browserFileModel())", "if(false)");
        requireChooser(valid, call);
        foreach (decoy; [valid ~ wrong, "void nested(){" ~ valid ~ "}" ~ wrong,
                         "version(disabled){" ~ valid ~ "}" ~ wrong,
                         valid.replace(" pick", " prefixpick") ~ wrong,
                         valid.replace("PickResult", "PrefixPickResult") ~ wrong,
                         header ~ ";" ~ wrong, header ~ ";"])
            assertThrown!AssertError(requireChooser(decoy, call));
        assertThrown!AssertError(requireChooser("void nested(){" ~ valid ~ "}", call));
        assertThrown!AssertError(requireChooser(header ~ "{", call));
        assertThrown!AssertError(requireChooser(valid[0 .. $ - 1], call));
        assertThrown!AssertError(requireChooser(valid.replace("FilterSpec[]", "OtherSpec[]"), call));
        assertThrown!AssertError(requireChooser(header ~ "{if(false)" ~ body ~ "return desktop;}", call));
    }
}
