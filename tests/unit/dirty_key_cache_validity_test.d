// Retained image certification and production bypass wiring (20261690).
module tests.unit.dirty_key_cache_validity_test;

import tests.unit.census_symbols : wave19MathPhysicalPath;

import vibe3d.viewport.host.viewport : Viewport3D, DirtyKey;
import tests.unit.census_symbols : blankNonCode, balancedSpan, countOccurrences;
import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    auto first = new Viewport3D(0, 0, 0, 640, 480);
    auto second = new Viewport3D(1, 640, 0, 640, 480);
    DirtyKey current;
    assert(current == first.lastKey, "CACHE_DEFAULT_EQUAL: default key is a legitimate equal value");
    assert(!first.lastKeyValid && !second.lastKeyValid, "CACHE_INITIAL_INVALID: no retained image is certified");
    assert(first.updateRenderKey(current), "CACHE_DEFAULT_DRAW: invalid default-equal key renders");
    assert(first.lastKey == current, "CACHE_KEY_STORED: keyed draw stores its current key");
    assert(!first.updateRenderKey(current), "CACHE_EQUAL_SKIP: next equal key skips");
    current.selEpoch = 1;
    assert(first.updateRenderKey(current), "CACHE_CHANGED_DRAW: changed key renders");
    assert(!first.updateRenderKey(current), "CACHE_CHANGED_SKIP: changed key was stored");
    assert(!second.lastKeyValid && second.lastKey == DirtyKey.init,
           "CACHE_INDEPENDENT: first cell cannot certify second cell");
    assert(second.updateRenderKey(current) && !second.updateRenderKey(current),
           "CACHE_SECOND_DRAW_SKIP: second cell owns its certificate");
    first.lastKeyValid = false;
    assert(first.lastKey == current && second.lastKeyValid,
           "CACHE_INVALIDATE_CONTROL: invalidation preserves key and other cell");
    assert(first.updateRenderKey(current), "CACHE_INVALIDATED_DRAW: equal key after bypass renders");
    assert(!first.updateRenderKey(current) && !second.updateRenderKey(current),
           "CACHE_RESTORED_SKIP: both settled cells skip");
}

private string branch(string code, string header) {
    assert(countOccurrences(code, header) == 1, "CACHE_WIRING_POPULATION: unique branch " ~ header);
    const at = code.indexOf(header);
    const open = code[cast(size_t)at + header.length .. $].indexOf('{');
    assert(open >= 0, "CACHE_WIRING_BODY: branch body missing");
    auto body = balancedSpan(code, cast(size_t)at + header.length + cast(size_t)open, '{', '}');
    assert(body.length > 2, "CACHE_WIRING_BALANCED: complete branch body");
    return body;
}

unittest {
    const code = blankNonCode(readText(wave19MathPhysicalPath(buildPath(repoRoot, "source", "app.d"))));
    const forced = branch(code, "if (forceActive && k == overlayOwner)");
    const unconditional = branch(code, "if (testMode && !testDirtyKeyGate)");
    enum invalidate = "_cv.lastKeyValid = false;";
    assert(countOccurrences(forced, invalidate) == 1 &&
           forced.indexOf(invalidate) < forced.indexOf("needRender = true;"),
           "CACHE_FORCED_WIRING: owner bypass invalidates before scheduling draw");
    assert(countOccurrences(unconditional, invalidate) == 1 &&
           unconditional.indexOf(invalidate) < unconditional.indexOf("needRender = testRendersCell("),
           "CACHE_TEST_WIRING: unconditional test bypass invalidates before scheduling draw");
    assert(countOccurrences(code, invalidate) == 2,
           "CACHE_INVALIDATE_POPULATION: exactly both production bypass sites");
    assert(countOccurrences(code, "needRender = _cv.updateRenderKey(_newKey);") == 1 &&
           countOccurrences(forced, "updateRenderKey(") == 0 &&
           countOccurrences(unconditional, "updateRenderKey(") == 0,
           "CACHE_KEYED_WIRING: ordinary builder uses real certificate method once");
}
