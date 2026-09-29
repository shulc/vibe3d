// Module unittests for `tool_presets`, moved verbatim out of source/tool_presets.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tool_presets_test;

import std.format : format;
import std.json : JSONValue;
import registry         : Registry;
import tool             : Tool, ToolFlag;
import toolpipe.pipeline : g_pipeCtx;
import params : Param, ParamProvider, injectParamsInto, parseInto;
import prefs  : g_prefs, Prefs;
import tool_presets;

// Guards the alias mechanism's byte-stability claim: `ElementMove` is an
// `alias:` entry pointing at `xfrm.elementMove`; the two must resolve to
// field-identical presets (same base / pipeAttrs / toolAttrs / flags) so both
// factory ids keep behaving exactly as if each still had its own hand-written
// YAML block.
unittest {
    auto presets = loadToolPresets("config/tool_presets.yaml");
    const(ToolPreset)* canonical = null;
    const(ToolPreset)* aliased   = null;
    foreach (ref p; presets) {
        if (p.id == "xfrm.elementMove") canonical = &p;
        if (p.id == "ElementMove")      aliased   = &p;
    }
    assert(canonical !is null, "xfrm.elementMove preset missing");
    assert(aliased   !is null, "ElementMove alias preset missing");
    assert(aliased.base == canonical.base);
    assert(aliased.flags == canonical.flags);
    assert(aliased.toolAttrs == canonical.toolAttrs);
    assert(aliased.pipeAttrs == canonical.pipeAttrs);
}

// Magnet's ID must remain a radial Move composition. A plain Move
// factory loses the explicit T-only xfrm.transform profile.
unittest {
    auto presets = loadToolPresets("config/tool_presets.yaml");
    const(ToolPreset)* magnet = null;
    foreach (ref p; presets)
        if (p.id == "xfrm.magnet") magnet = &p;
    assert(magnet !is null, "xfrm.magnet preset missing");
    assert(magnet.base == "xfrm.transform");
    assert(magnet.toolAttrs["T"] == "true");
    assert(magnet.toolAttrs["R"] == "false");
    assert(magnet.toolAttrs["S"] == "false");
    assert(magnet.pipeAttrs["falloff"]["type"] == "radial");
}
