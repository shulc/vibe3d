#!/usr/bin/env python3
"""P1.0a source/compile-fail census. No production activation door may call it."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import json
import shutil
import hashlib

from prepared_writer_census import (scan as scan_writer_graph,
    canonical as canonical_writer_graph, _balanced as balanced_source,
    _semantic_digest as semantic_digest)

ROOT = Path(__file__).resolve().parents[1]
DMD_FLAGS_RUN = subprocess.run(
    ["dub", "describe", "--data=import-paths,string-import-paths,versions,debug-versions"],
    cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if DMD_FLAGS_RUN.returncode:
    raise SystemExit("P1.0b.0 cannot obtain D compiler flags")
DMD_FLAGS = DMD_FLAGS_RUN.stdout.split()

def fail(message):
    raise SystemExit(message)

WRITER_MANIFEST_PATH = ROOT / "tools/prepared_writer_manifest.json"

def writer_keys(rows):
    return [(r.get("module", "registration"), r["aggregate"], r["symbol"], r.get("signature", "factory"))
            for r in rows]

def validate_writer_graph(actual, expected):
    for section in ("hooks", "params", "factories", "products", "surfaces"):
        keys = writer_keys(expected[section])
        if len(keys) != len(set(keys)):
            fail(f"P1.0b.0 duplicate {section} manifest row")
        akeys = set(writer_keys(actual[section]))
        ekeys = set(keys)
        if akeys != ekeys:
            fail(f"P1.0b.0 {section} symbol mismatch: missing={sorted(ekeys-akeys)} surplus={sorted(akeys-ekeys)}")
    if actual.get("bypasses") != expected.get("bypasses"):
        fail("P1.0b.0 activation/lifecycle bypass callsite set changed")
    if canonical_writer_graph(actual) != canonical_writer_graph(expected):
        fail("P1.0b.0 direct-body/product census changed with names intact")

WRITER_MANIFEST = json.loads(WRITER_MANIFEST_PATH.read_text())
CURRENT_WRITERS = scan_writer_graph(ROOT)
validate_writer_graph(CURRENT_WRITERS, WRITER_MANIFEST)

# One real compiler-backed ownership/signature gate for every reviewed root and
# params provider. `isSame(parent, Aggregate)` excludes inherited-name matches.
owned_rows = CURRENT_WRITERS["hooks"] + CURRENT_WRITERS["params"]
modules = sorted({row["module"] for row in owned_rows})
modules = sorted(set(modules) | {row["module"] for row in CURRENT_WRITERS["products"]})
module_alias = {module: f"m{i}" for i, module in enumerate(modules)}
# Compiler-measured effective products for Tool's three literal no-op hooks.
# A declaration row is converted only when every product in its corresponding
# set has a closed prepared admission path; this table prevents both the old
# "there is no exact Tool product" false closure and accidental widening.
BASE_TOOL_EFFECTIVE_PRODUCTS = {
    "activate": {"DragWeldTool"},
    "deactivate": {"DragWeldTool"},
    "update": {
        "ArcTool", "ArrayTool", "BendTool", "BoxTool", "BridgeTool",
        "CapsuleTool", "CloneTool", "ConeTool", "CylinderTool",
        "DragWeldTool", "EdgeBevelTool", "EdgeExtrudeTool",
        "EdgeSliceTool", "EdgeSlideTool", "LinearAlignTool",
        "LoopSliceTool", "MagnetTool", "MirrorTool", "PenTool",
        "PolyBevelTool", "PolyExtrudeTool", "PolyInsetTool", "PushTool",
        "RadialAlignTool", "RadialArrayTool", "RadialSweepTool",
        "ReductionTool", "SliceTool", "SmoothShiftTool", "SphereTool",
        "StrokeExtrudeTool", "TackTool", "TorusTool", "TubeTool",
        "VertexBevelTool", "VertexExtrudeTool", "VertexMergeTool",
        "VertexTool", "XfrmJitterTool", "XfrmQuantizeTool",
        "XfrmSmoothTool",
    },
}
with tempfile.TemporaryDirectory(prefix="vibe3d-writer-traits-") as td:
    lines = ["module prepared_writer_traits;",
             "import std.traits : ReturnType, Parameters, ParameterStorageClassTuple, functionAttributes;",
             "import params : Param; import operator : VectorStack;",
             "void expectedVoid() {} void expectedString(string value) {}",
             "void expectedRef(ref VectorStack value) {} Param[] expectedParams() { return null; }"]
    lines += [f"import {alias_} = {module};" for module, alias_ in module_alias.items()]
    for i, row in enumerate(owned_rows):
        owner = f"{module_alias[row['module']]}.{row['aggregate']}"
        expected = {"void()": "expectedVoid", "void(string name)": "expectedString",
                    "void(string pname)": "expectedString",
                    "void(ref VectorStack vts)": "expectedRef",
                    "Param[]()": "expectedParams"}.get(row["signature"])
        if expected is None: fail("P1.0b.0 unreviewed exact signature: " + row["signature"])
        lines += [f'static assert(__traits(hasMember, {owner}, "{row["symbol"]}"));',
                  f'alias writerMember{i} = __traits(getMember, {owner}, "{row["symbol"]}");',
                  f'static assert(__traits(isSame, __traits(parent, writerMember{i}), {owner}));',
                  f'static assert(is(ReturnType!writerMember{i} == ReturnType!{expected}));',
                  f'static assert(is(Parameters!writerMember{i} == Parameters!{expected}));',
                  f'static assert(ParameterStorageClassTuple!writerMember{i} == ParameterStorageClassTuple!{expected});',
                  f'static assert(functionAttributes!writerMember{i} == functionAttributes!{expected});']
    effective_assertions = {}
    product_names = {row["aggregate"] for row in CURRENT_WRITERS["products"]}
    for hook, expected_products in BASE_TOOL_EFFECTIVE_PRODUCTS.items():
        if not expected_products <= product_names:
            fail(f"P1.0b.0 base Tool {hook} product left frozen census")
    for product_i, row in enumerate(CURRENT_WRITERS["products"]):
        product = f"{module_alias[row['module']]}.{row['aggregate']}"
        lines.append(f"static assert(is({product} == class));")
        base_tool = f"{module_alias['tool']}.Tool"
        for hook, expected_products in BASE_TOOL_EFFECTIVE_PRODUCTS.items():
            alias_name = f"effectiveToolHook{product_i}_{hook}"
            condition = (f"__traits(isSame, __traits(parent, {alias_name}), "
                         f"{base_tool})")
            expected = row["aggregate"] in expected_products
            assertion = condition if expected else "!" + condition
            lines += [f'alias {alias_name} = __traits(getMember, {product}, "{hook}");',
                      f"static assert({assertion});"]
            effective_assertions[(hook, row["aggregate"])] = \
                (f"static assert({assertion});",
                 f"static assert({condition if not expected else '!' + condition});")
    path = Path(td) / "prepared_writer_traits.d"
    path.write_text("\n".join(lines))
    compile_traits = subprocess.run(["dmd", "-o-", *DMD_FLAGS, str(path)], cwd=ROOT,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if compile_traits.returncode:
        fail("P1.0b.0 compiler-backed owner/signature census failed:\n" + compile_traits.stdout)
    # Named potency mutations: flip one measured member on each lifecycle axis
    # and require the compiler census itself (not a name table) to redden.
    for hook, aggregate in (("activate", "DragWeldTool"),
                            ("deactivate", "DragWeldTool"),
                            ("update", "ArcTool")):
        original, inverted = effective_assertions[(hook, aggregate)]
        mutant_lines = list(lines)
        index = mutant_lines.index(original)
        mutant_lines[index] = inverted
        mutant_path = Path(td) / f"prepared_writer_traits_{hook}_mutant.d"
        mutant_path.write_text("\n".join(mutant_lines).replace(
            "module prepared_writer_traits;",
            f"module prepared_writer_traits_{hook}_mutant;", 1))
        mutant_run = subprocess.run(["dmd", "-o-", *DMD_FLAGS, str(mutant_path)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if mutant_run.returncode == 0:
            fail(f"P1.0b.0 base Tool {hook} effective-product mutation did not RED")

deactivations = [r for r in CURRENT_WRITERS["hooks"]
                 if r["symbol"] == "deactivate" and r["module"] != "tool"]
param_hooks = [r for r in CURRENT_WRITERS["hooks"]
               if r["symbol"] == "onParamChanged" and r["module"] != "tool"]
relevant_roots = [r for r in CURRENT_WRITERS["hooks"]
                  if r["symbol"] in ("activate", "update", "onParamChanged")]
if (len(deactivations), len(param_hooks), len(relevant_roots)) != (35, 25, 73):
    fail("P1.0b.0 reviewed writer cardinality changed")

# P1.0b.1 exact conversion/defer ledger. The frozen writer rows remain the
# authority; this list is deliberately smaller and bidirectional, so a root
# cannot disappear into an unlabelled middle state.
TOOL_STATE_CONVERTED = {
    ("tools.create.arc", "ArcTool", "activate"),
    ("tools.create.arc", "ArcTool", "deactivate"),
    ("tools.alignment.mirror", "MirrorTool", "onParamChanged"),
    ("tools.edit.bridge_tool", "BridgeTool", "onParamChanged"),
    ("tools.transform.xfrm_transform", "XfrmTransformTool", "onParamChanged"),
    ("tool", "Tool", "onParamChanged"),
    ("tools.common.command_wrapper", "CommandWrapperTool", "onParamChanged"),
    ("tools.create.sphere", "SphereTool", "onParamChanged"),
}
# P1.0b.3d's second axis: implementation is Prepared, while the production
# route remains Legacy until the one P1.0c door cutover. These rows therefore
# leave the deferred implementation set without changing their frozen hook
# bodies or direct-body fingerprints.
B3D_PREPARED_LEGACY = {
    ("tools.alignment.array_tool", "ArrayTool", "deactivate"),
    ("tools.alignment.clone_tool", "CloneTool", "deactivate"),
    ("tools.deform.magnet", "MagnetTool", "deactivate"),
    ("tools.deform.smooth_shift_tool", "SmoothShiftTool", "deactivate"),
    ("tools.deform.stroke_extrude_tool", "StrokeExtrudeTool", "deactivate"),
    ("tools.edit.edge_bevel", "EdgeBevelTool", "deactivate"),
    ("tools.edit.edge_extrude", "EdgeExtrudeTool", "deactivate"),
    ("tools.edit.poly_bevel", "PolyBevelTool", "deactivate"),
    ("tools.edit.poly_extrude", "PolyExtrudeTool", "deactivate"),
    ("tools.edit.poly_inset_tool", "PolyInsetTool", "deactivate"),
    ("tools.edit.reduce", "ReductionTool", "deactivate"),
    ("tools.edit.vert_merge_tool", "VertexMergeTool", "deactivate"),
    ("tools.edit.vertex_bevel_tool", "VertexBevelTool", "deactivate"),
    ("tools.edit.vertex_extrude_tool", "VertexExtrudeTool", "deactivate"),
    ("tools.transform.move", "MoveTool", "deactivate"),
    ("tools.transform.rotate", "RotateTool", "deactivate"),
    ("tools.transform.scale", "ScaleTool", "deactivate"),
    ("tools.transform.xfrm_transform", "XfrmTransformTool", "deactivate"),
    ("tools.create.box", "BoxTool", "onParamChanged"),
}
B4C_PREPARED_LEGACY = {
    ("tools.common.command_wrapper", "CommandWrapperTool", "deactivate"),
    ("tools.edit.tack", "TackTool", "deactivate"),
    ("tools.transform.transform", "TransformTool", "deactivate"),
}
B5B_PREPARED_LEGACY = {
    ("tools.create.vertex_place", "VertexTool", "activate"),
}
B5D_PREPARED_LEGACY = {
    ("tools.create.vertex_place", "VertexTool", "deactivate"),
}
B5F_PREPARED_LEGACY = {
    ("tools.alignment.array_tool", "ArrayTool", "activate"),
    ("tools.alignment.clone_tool", "CloneTool", "activate"),
    ("tools.deform.magnet", "MagnetTool", "activate"),
    ("tools.edit.reduce", "ReductionTool", "activate"),
}
B5I_PREPARED_LEGACY = {
    ("tools.alignment.radial_sweep_tool", "RadialSweepTool", "activate"),
    ("tools.alignment.radial_sweep_tool", "RadialSweepTool", "onParamChanged"),
    ("tools.alignment.radial_sweep_tool", "RadialSweepTool", "deactivate"),
}
B5J_PREPARED_LEGACY = {
    ("tools.alignment.radial_array_tool", "RadialArrayTool", "activate"),
    ("tools.alignment.radial_array_tool", "RadialArrayTool", "deactivate"),
}
B5K_PREPARED_LEGACY = {
    ("tools.alignment.linear_align_tool", "LinearAlignTool", "activate"),
    ("tools.alignment.radial_align_tool", "RadialAlignTool", "activate"),
    ("tools.deform.bend", "BendTool", "activate"),
    ("tools.deform.push", "PushTool", "activate"),
}
B5L_PREPARED_LEGACY = {
    ("tools.transform.move", "MoveTool", "activate"),
    ("tools.transform.rotate", "RotateTool", "activate"),
    ("tools.transform.scale", "ScaleTool", "activate"),
}
B5M_PREPARED_LEGACY = {
    ("tools.transform.move", "MoveTool", "update"),
}
B5N_PREPARED_LEGACY = {
    ("tool", "Tool", "activate"),
    ("tool", "Tool", "deactivate"),
    ("tool", "Tool", "update"),
}
B5O_PREPARED_LEGACY = {
    ("tools.transform.transform", "TransformTool", "activate"),
    ("tools.transform.xfrm_transform", "XfrmTransformTool", "activate"),
}
B5P_PREPARED_LEGACY = {
    ("tools.slice.slice_tool", "SliceTool", "deactivate"),
    ("tools.edit.vertex_extrude_tool", "VertexExtrudeTool", "onParamChanged"),
    ("tools.edit.vertex_bevel_tool", "VertexBevelTool", "onParamChanged"),
    ("tools.edit.vert_merge_tool", "VertexMergeTool", "onParamChanged"),
    ("tools.edit.reduce", "ReductionTool", "onParamChanged"),
    ("tools.edit.poly_inset_tool", "PolyInsetTool", "onParamChanged"),
    ("tools.edit.poly_extrude", "PolyExtrudeTool", "onParamChanged"),
    ("tools.edit.poly_bevel", "PolyBevelTool", "onParamChanged"),
    ("tools.edit.edge_extrude", "EdgeExtrudeTool", "onParamChanged"),
    ("tools.edit.edge_bevel", "EdgeBevelTool", "onParamChanged"),
    ("tools.deform.smooth_shift_tool", "SmoothShiftTool", "onParamChanged"),
    ("tools.deform.magnet", "MagnetTool", "onParamChanged"),
    ("tools.alignment.radial_array_tool", "RadialArrayTool", "onParamChanged"),
    ("tools.alignment.array_tool", "ArrayTool", "onParamChanged"),
    ("tools.create.pen", "PenTool", "onParamChanged"),
    ("tools.alignment.mirror", "MirrorTool", "deactivate"),
    ("tools.create.box", "BoxTool", "deactivate"),
    ("tools.create.pen", "PenTool", "deactivate"),
    ("tools.create.primitive_create_tool", "PrimitiveCreateTool", "deactivate"),
    ("tools.edit.topology_pen.tool", "TopologyPenTool", "update"),
    ("tools.edit.bridge_tool", "BridgeTool", "deactivate"),
    ("tools.edit.topology_pen.tool", "TopologyPenTool", "activate"),
    ("tools.edit.edge_extend", "EdgeExtendTool", "activate"),
    ("tools.alignment.mirror", "MirrorTool", "activate"),
    ("tools.common.command_wrapper", "CommandWrapperTool", "activate"),
    ("tools.edit.bridge_tool", "BridgeTool", "activate"),
    ("tools.create.box", "BoxTool", "activate"),
    ("tools.create.pen", "PenTool", "activate"),
    ("tools.create.primitive_create_tool", "PrimitiveCreateTool", "activate"),
    ("tools.deform.stroke_extrude_tool", "StrokeExtrudeTool", "activate"),
    ("tools.edit.vert_merge_tool", "VertexMergeTool", "activate"),
    ("tools.edit.poly_inset_tool", "PolyInsetTool", "activate"),
    ("tools.edit.poly_extrude", "PolyExtrudeTool", "activate"),
    ("tools.deform.smooth_shift_tool", "SmoothShiftTool", "activate"),
    ("tools.edit.edge_bevel", "EdgeBevelTool", "activate"),
    ("tools.edit.poly_bevel", "PolyBevelTool", "activate"),
    ("tools.edit.vertex_bevel_tool", "VertexBevelTool", "activate"),
    ("tools.edit.vertex_extrude_tool", "VertexExtrudeTool", "activate"),
    ("tools.edit.edge_extrude", "EdgeExtrudeTool", "activate"),
    ("tools.slice.edge_slice_tool", "EdgeSliceTool", "activate"),
    ("tools.slice.loop_slice_tool", "LoopSliceTool", "activate"),
    ("tools.slice.slice_tool", "SliceTool", "activate"),
    ("tools.edit.tack", "TackTool", "activate"),
}
B5Q_PREPARED_LEGACY = {
    ("tools.edit.edge_extend", "EdgeExtendTool", "update"),
    ("tools.transform.rotate", "RotateTool", "update"),
    ("tools.transform.scale", "ScaleTool", "update"),
    ("tools.transform.xfrm_transform", "XfrmTransformTool", "update"),
    ("tools.edit.topology_pen.tool", "TopologyPenTool", "deactivate"),
    ("tools.slice.slice_tool", "SliceTool", "onParamChanged"),
    ("tools.slice.edge_slice_tool", "EdgeSliceTool", "deactivate"),
    ("tools.slice.edge_slice_tool", "EdgeSliceTool", "onParamChanged"),
    ("tools.slice.loop_slice_tool", "LoopSliceTool", "deactivate"),
    ("tools.slice.loop_slice_tool", "LoopSliceTool", "onParamChanged"),
    ("tools.edit.edge_extend", "EdgeExtendTool", "onParamChanged"),
    ("tools.edit.edge_extend", "EdgeExtendTool", "deactivate"),
}
PREPARED_LEGACY = (B3D_PREPARED_LEGACY | B4C_PREPARED_LEGACY |
    B5B_PREPARED_LEGACY | B5D_PREPARED_LEGACY | B5F_PREPARED_LEGACY |
    B5I_PREPARED_LEGACY | B5J_PREPARED_LEGACY | B5K_PREPARED_LEGACY |
    B5L_PREPARED_LEGACY | B5M_PREPARED_LEGACY | B5N_PREPARED_LEGACY |
    B5O_PREPARED_LEGACY | B5P_PREPARED_LEGACY | B5Q_PREPARED_LEGACY)
all_hook_keys = {(r["module"], r["aggregate"], r["symbol"])
                 for r in CURRENT_WRITERS["hooks"]}
if not TOOL_STATE_CONVERTED | PREPARED_LEGACY <= all_hook_keys:
    fail("P1.0b.1 converted tool-state row left the frozen census")
TOOL_STATE_DEFERRED = all_hook_keys - TOOL_STATE_CONVERTED - PREPARED_LEGACY

converted_sources = {
    "source/tool.d": ("prepareBaseParam", "validateBaseParam", "installLegacyPreparedParam"),
    "source/tools/create/arc.d": ("prepareIdleState", "validatePreparedState", "installLegacyPreparedState"),
    "source/tools/alignment/mirror.d": ("prepareParamState", "validatePreparedState", "installLegacyPreparedState"),
    "source/tools/edit/bridge_tool.d": ("prepareParamState", "validatePreparedState", "installLegacyPreparedState"),
    "source/tools/transform/xfrm_transform.d": ("prepareParamState", "validatePreparedState", "installLegacyPreparedState"),
    "source/tools/common/command_wrapper.d": ("prepareParamChange", "validatePreparedParam", "installLegacyPreparedParam"),
    "source/tools/create/sphere.d": ("prepareAxisParam", "validatePreparedParam", "installLegacyPreparedParam"),
}
for relative, methods in converted_sources.items():
    source = (ROOT / relative).read_text()
    for method in methods:
        matches = list(re.finditer(r"\b" + method + r"\s*\([^;{}]*\)[^{;]*\bnothrow\b[^;{}]*\{", source))
        if len(matches) != 1:
            fail(f"P1.0b.1 {relative} {method} is not one exact nothrow seam")
        if method.startswith("installLegacyPrepared"):
            body = source[matches[0].end():balanced_source(source, matches[0].end())-1]
            if re.search(r"\b(?:assert|enforce|throw)\b", body):
                fail(f"P1.0b.1 {relative} installer has a throwable guard")
            if "PreparedToolStateDelta" in body or ".kind" in body or ".owner" in body:
                fail(f"P1.0b.1 {relative} installer decodes an unvalidated carrier")

TOOL_STATE_DEFERRED_ROWS = json.loads(
    (ROOT / "tools/prepared_tool_state_deferred.json").read_text())
TOOL_STATE_DEFERRED_CANONICAL_SHA256 = \
    "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
def validate_deferred_rows(rows, require_canonical=True):
    rows = [r for r in rows if (r["key"]["module"], r["key"]["aggregate"],
            r["key"]["symbol"]) not in PREPARED_LEGACY]
    keys = {(r["key"]["module"], r["key"]["aggregate"],
             r["key"]["symbol"], r["key"]["signature"]) for r in rows}
    expected = {(r["module"], r["aggregate"], r["symbol"], r["signature"])
                for r in CURRENT_WRITERS["hooks"]
                if (r["module"], r["aggregate"], r["symbol"])
                   not in TOOL_STATE_CONVERTED | PREPARED_LEGACY}
    if len(keys) != len(rows) or keys != expected:
        fail("P1.0b.1 checked-in deferred row set mismatch")
    for row in rows:
        if row["batch"] not in {"P1.0b.2", "P1.0b.2+", "P1.0b.3+"} or not row["reason"]:
            fail("P1.0b.1 checked-in deferred batch/reason invalid")
    canonical = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    if require_canonical and hashlib.sha256(canonical).hexdigest() != \
            TOOL_STATE_DEFERRED_CANONICAL_SHA256:
        fail("P1.0b.1 checked-in deferred exact values drifted")
validate_deferred_rows(TOOL_STATE_DEFERRED_ROWS)
for field in (("batch", "reason") if TOOL_STATE_DEFERRED_ROWS else ()):
    mutant = json.loads(json.dumps(TOOL_STATE_DEFERRED_ROWS))
    mutant[0][field] = "" if field == "reason" else "P9.invalid"
    try: validate_deferred_rows(mutant)
    except SystemExit as error:
        if "batch/reason invalid" not in str(error):
            fail("P1.0b.1 deferred-ledger mutation failed for wrong reason")
    else: fail("P1.0b.1 deferred-ledger wrong batch/reason mutation did not RED")

def expect_deferred_exact_drift(mutant, label):
    try: validate_deferred_rows(mutant)
    except SystemExit as error:
        if "deferred exact values drifted" not in str(error):
            fail(f"P1.0b.1 deferred {label} mutation failed for wrong reason")
    else: fail(f"P1.0b.1 deferred {label} mutation did not RED exact drift")

batch_swap = json.loads(json.dumps(TOOL_STATE_DEFERRED_ROWS))
batch_pair = next(((i, j) for i in range(len(batch_swap))
                   for j in range(i + 1, len(batch_swap))
                   if batch_swap[i]["batch"] != batch_swap[j]["batch"]), None)
if not batch_swap:
    pass
elif batch_pair is None:
    # The tail ledger can legitimately become batch-homogeneous. Keep the
    # mutation effective by substituting a different allowed batch value.
    batch_swap[0]["batch"] = "P1.0b.2+"
else:
    batch_swap[batch_pair[0]]["batch"], batch_swap[batch_pair[1]]["batch"] = \
        batch_swap[batch_pair[1]]["batch"], batch_swap[batch_pair[0]]["batch"]
if batch_swap:
    expect_deferred_exact_drift(batch_swap, "allowed-batch swap")

reason_swap = json.loads(json.dumps(TOOL_STATE_DEFERRED_ROWS))
reason_pair = next(((i, j) for i in range(len(reason_swap))
                    for j in range(i + 1, len(reason_swap))
                    if reason_swap[i]["reason"] != reason_swap[j]["reason"]), None)
if not reason_swap:
    pass
elif reason_pair is None:
    reason_swap[0]["reason"] += " (mutated)"
else:
    reason_swap[reason_pair[0]]["reason"], reason_swap[reason_pair[1]]["reason"] = \
        reason_swap[reason_pair[1]]["reason"], reason_swap[reason_pair[0]]["reason"]
if reason_swap:
    expect_deferred_exact_drift(reason_swap, "allowed-reason swap")

reason_replace = json.loads(json.dumps(TOOL_STATE_DEFERRED_ROWS))
if reason_replace:
    reason_replace[0]["reason"] = "different nonempty reviewed-looking reason"
    expect_deferred_exact_drift(reason_replace, "nonempty-reason replacement")

# P1.0b.3d dormant implementation/route axis. All twenty frozen roots stay on
# their exact Legacy bodies; a sibling producer exists and only producer code
# may invoke another producer. No production door constructs the injected
# context or imports the observer owner directly.
b3d_modules = {module for module, _, _ in B3D_PREPARED_LEGACY}
b3d_sources = {module: (ROOT / "source" /
    (module.replace(".", "/") + ".d")).read_text() for module in b3d_modules}
B3D_PRODUCER_DIGESTS = {
    "tools/alignment/array_tool":"abbc9240a3fcfbb03c06b768a75440e39d6baadf000455ab75dd8e5804556ff0",
    "tools/alignment/clone_tool":"3e0d910456a613f77df81476010005d5fc7d229bec4197175a6fe5fe528688d0",
    "tools/alignment/radial_array_tool":"65148a02ac2b032c5ee0fb890f009775feb9d3a96c9c2550bb3dbbba6dcb8a85",
    "tools/deform/magnet":"1191f71bae9f8cb4dc7fed605de2172db7e268f3ba9e9c62c0db2668cdcbdddf",
    "tools/deform/smooth_shift_tool":"5c1c9ace215d2a239f08501c9f7a8a02b8ea27ec1d8a1c3ede1cd5de46ac6c27",
    "tools/deform/stroke_extrude_tool":"48fd9fad9f7c4566468ebf746ab9ba38548cb5d7c2f6d7004d162ffa1a3c7d5f",
    "tools/edit/edge_bevel":"8c47f66199de95b827047be61df795f14fb018e720c32e4cb151bab20d1d547d",
    "tools/edit/edge_extrude":"293c94c99cb663a063dc0dfd59c345dce2a68a141bdf41972b21b9ba58cbcf8a",
    "tools/edit/poly_bevel":"6ee1932c80dcfca11ae55b5e30ca81260eb513ad79176286b4a6df1c6a39818b",
    "tools/edit/poly_extrude":"1645a6f9603d75a3bd03662a7a47db845c018bf38b6b754471f658113ae8f192",
    "tools/edit/poly_inset_tool":"7b39c23988c01f31c8956395c1834b00bfaefde748ed19646cfe40465d320dd4",
    "tools/edit/reduce":"e7df0a7a19f56f8b8f1e29ad3e05974a10dcae535be2e155dd105e69ddb126d4",
    "tools/edit/vert_merge_tool":"9bf5d97f4da62f907be50eb4b72c73b9a01ab816cbbb537714af24667da20eaf",
    "tools/edit/vertex_bevel_tool":"935c400d06133076e34d5c6a5d62d1ba2a93eb7b4eac88a7a1c9bdd42639aabf",
    "tools/edit/vertex_extrude_tool":"5bd4def636ee6e51247ad7c4b11055ffa57985038233cb97c82c86d13200dcca",
    "tools/transform/move":"bbea8820c86c337a470a96ba2fa1791c0c981d6e90235502f34005f74a464260",
    "tools/transform/rotate":"e04de99122832355fb43cb7546a1c99f303aeb6252e0334141ce6e522a31ae50",
    "tools/transform/scale":"02f3b4fcce5380905aba0a2a7c86530a6d386be63b87332c1c12a66bee7a930a",
    "tools/transform/xfrm_transform":"66269524a4698244927959e9bf1b07d13d8e39b0b56c165cf20f5739dcbae844",
    "tools/create/box":"1d507a4771e54f922d240817b5f2d6f5d77b49cb4014605509194675fc1869e3",
}
def validate_b3d_producers(sources, only=None):
    for module, aggregate, hook in B3D_PREPARED_LEGACY:
        if only is not None and module not in only: continue
        source = sources[module]
        producer = "prepareParamChanged" if hook == "onParamChanged" else "prepareDeactivate"
        if len(re.findall(r"\bfinal\s+Prepared(?:Deactivate|BoxParam)Effect\s+" +
                          producer + r"\s*\(", source)) != 1:
            fail(f"P1.0b.3d Prepared+Legacy row lacks exact producer: {module}.{aggregate}.{hook}")
        producer_match = re.search(r"\bfinal\s+Prepared(?:Deactivate|BoxParam)Effect\s+" +
            producer + r"\s*\([^;{}]*\)[^{]*\{", source)
        producer_body = source[producer_match.end():balanced_source(source, producer_match.end())-1]
        if semantic_digest(producer_body) != B3D_PRODUCER_DIGESTS[module.replace(".", "/")]:
            fail(f"P1.0b.3d producer parity drifted: {module}.{producer}")
        match = re.search(r"override\s+void\s+" + hook + r"\s*\([^;{}]*\)\s*\{", source)
        if not match:
            fail(f"P1.0b.3d legacy route body vanished: {module}.{aggregate}.{hook}")
        body = source[match.end():balanced_source(source, match.end())-1]
        if re.search(r"\b(?:prepareDeactivate|prepareParamChanged)\s*\(", body):
            fail(f"P1.0b.3d producer called early from Legacy route: {module}.{aggregate}.{hook}")
validate_b3d_producers(b3d_sources)

def without_unittests(source):
    result = source
    for match in reversed(list(re.finditer(r"\bunittest\s*\{", result))):
        result = result[:match.start()] + result[balanced_source(result, match.end()):]
    return result

prepared_source_texts = {path: path.read_text()
                         for path in (ROOT / "source").rglob("*.d")}
for path, text in prepared_source_texts.items():
    module = str(path.relative_to(ROOT / "source")).removesuffix(".d").replace("/", ".")
    if "import prepared_record_context" in text and module not in b3d_modules | {
            "prepared_record_context", "tools.transform.transform",
            "tools.common.command_wrapper", "tools.edit.tack",
            "tools.create.vertex_place", "tools.create.pen", "tools.create.arc",
            "tools.create.primitive_create_tool",
            "tools.alignment.array_tool",
            "tools.alignment.clone_tool", "tools.deform.magnet",
            "tools.edit.reduce", "prepared_private_state",
            "prepared_selection_profile", "prepared_radial_sweep_transition",
            "prepared_radial_array_transition",
            "prepared_transform_activation",
            "prepared_transform_product_activation",
            "prepared_move_update",
            "prepared_rotate_update",
            "prepared_scale_update",
            "prepared_inherited_noop",
            "prepared_xfrm_activation_session",
            "prepared_xfrm_update_edit_close",
            "prepared_xfrm_move_regrade",
            "prepared_stroke_extrude_activation",
            "prepared_vertex_merge_activation",
            "prepared_poly_inset_activation",
            "prepared_poly_extrude_activation",
            "prepared_smooth_shift_activation",
            "prepared_edge_bevel_activation",
            "prepared_poly_bevel_activation",
            "prepared_vertex_bevel_activation",
            "prepared_vertex_extrude_activation",
            "prepared_edge_extrude_activation",
            "prepared_edge_slice_activation",
            "prepared_loop_slice_activation",
            "prepared_slice_activation",
            "prepared_tack_activation",
            "prepared_command_wrapper_activation",
            "prepared_bridge_activation",
            "prepared_mirror_activation",
            "prepared_edge_extend_tool_activation",
            "prepared_topology_pen_activation",
            "prepared_topology_pen_update",
            "prepared_topology_pen_deactivate",
            "prepared_array_param_update",
            "prepared_magnet_param_update",
            "prepared_smooth_shift_param_update",
            "prepared_edge_bevel_param_update",
            "prepared_edge_extrude_param_update",
            "prepared_poly_bevel_param_update",
            "prepared_poly_extrude_param_update",
            "prepared_poly_inset_param_update",
            "prepared_reduction_param_update",
            "prepared_vertex_merge_param_update",
            "prepared_vertex_bevel_param_update",
            "prepared_vertex_extrude_param_update",
            "prepared_slice_deactivate",
            "prepared_slice_param_update",
            "prepared_edge_slice_deactivate",
            "prepared_edge_slice_param_update",
            "prepared_loop_slice_deactivate",
            "prepared_loop_slice_param_update",
            "prepared_edge_extend_param_update",
            "prepared_edge_extend_deactivate",
            "prepared_box_param",
            "prepared_tool_transition",
            "tools.slice.edge_slice_tool",
            "tools.slice.loop_slice_tool",
            "tools.slice.slice_tool",
            "tools.edit.tack",
            "tools.edit.bridge_tool",
            "tools.alignment.mirror",
            "tools.create.sphere",
            "tools.edit.edge_extend",
            "tools.edit.topology_pen.tool",
            "tools.alignment.radial_sweep_tool",
            "tools.alignment.radial_array_tool",
            "tools.alignment.linear_align_tool",
            "tools.alignment.radial_align_tool",
            "tools.deform.bend", "tools.deform.push",
            "tools.deform.stroke_extrude_tool",
            "tools.edit.vert_merge_tool",
            "tools.edit.poly_inset_tool",
            "tools.edit.poly_extrude"}:
        fail(f"P1.0b.3d PreparedRecordContext gained an unreviewed import: {module}")
    if "new PreparedRecordContext" in text:
        production_text = without_unittests(text)
        if "new PreparedRecordContext" in production_text and module not in (
                "prepared_record_context", "prepared_tool_transition"):
            fail(f"P1.0b.3d PreparedRecordContext gained a production constructor: {module}")

mutation_module = "tools.alignment.array_tool"
mutation_sources = dict(b3d_sources)
mutation_sources[mutation_module] = mutation_sources[mutation_module].replace(
    "final PreparedDeactivateEffect prepareDeactivate(",
    "final PreparedDeactivateEffect missingPrepareDeactivate(", 1)
try: validate_b3d_producers(mutation_sources, {mutation_module})
except SystemExit as error:
    if "lacks exact producer" not in str(error):
        fail("P1.0b.3d missing-producer mutation failed for wrong reason")
else: fail("P1.0b.3d Prepared-without-producer mutation did not RED")

mutation_sources = dict(b3d_sources)
mutation_sources[mutation_module] = mutation_sources[mutation_module].replace(
    "override void deactivate() {", "override void deactivate() { prepareDeactivate(null);", 1)
try: validate_b3d_producers(mutation_sources, {mutation_module})
except SystemExit as error:
    if "called early from Legacy route" not in str(error):
        fail("P1.0b.3d early-route mutation failed for wrong reason")
else: fail("P1.0b.3d early-route mutation did not RED")

mutation_sources = dict(b3d_sources)
mutation_sources[mutation_module] = mutation_sources[mutation_module].replace(
    "cmd.setSnapshots(before, MeshSnapshot.capture(*mesh), \"Array\")",
    "cmd.setSnapshots(MeshSnapshot.capture(*mesh), before, \"Array\")", 1)
try: validate_b3d_producers(mutation_sources, {mutation_module})
except SystemExit as error:
    if "producer parity drifted" not in str(error):
        fail("P1.0b.3d wrong-original mutation failed for wrong reason")
else: fail("P1.0b.3d wrong-original mutation did not RED")

for module, guard, inverted in (
    ("tools.edit.edge_extrude", "(extrude_ != 0.0f || width_ != 0.0f) &&",
     "(extrude_ == 0.0f && width_ == 0.0f) &&"),
    ("tools.edit.poly_bevel", "(inset_ != 0.0f || shift_ != 0.0f) &&",
     "(inset_ == 0.0f && shift_ == 0.0f) &&"),
    ("tools.edit.poly_extrude", "distance_ != 0.0f &&",
     "distance_ == 0.0f &&"),
):
    mutation_sources = dict(b3d_sources)
    if guard not in mutation_sources[module]:
        fail(f"P1.0b.3d identity guard mutation anchor vanished: {module}")
    mutation_sources[module] = "".join(mutation_sources[module].rsplit(guard, 1))
    try: validate_b3d_producers(mutation_sources, {module})
    except SystemExit as error:
        if "producer parity drifted" not in str(error):
            fail(f"P1.0b.3d {module} identity-guard mutation failed wrong")
    else: fail(f"P1.0b.3d {module} identity-guard removal did not RED")
    mutation_sources = dict(b3d_sources)
    mutation_sources[module] = inverted.join(
        mutation_sources[module].rsplit(guard, 1))
    try: validate_b3d_producers(mutation_sources, {module})
    except SystemExit as error:
        if "producer parity drifted" not in str(error):
            fail(f"P1.0b.3d {module} inverted-guard mutation failed wrong")
    else: fail(f"P1.0b.3d {module} identity-guard inversion did not RED")

# P1.0b.3a record-observer owner infrastructure. The exact legacy census stays
# two app assignments until P1.0c; the prepared hub has no production caller.
app_source = (ROOT / "source/app.d").read_text()
def validate_legacy_observer_census(source):
    closure = list(re.finditer(
        r"history\.onRecord\s*=\s*\(string line, uint flags\)\s*\{", source))
    direct = re.findall(
        r"history\.onRecord\s*=\s*&macroRecorder\.onCommandRecorded\s*;", source)
    if len(closure) != 1 or len(direct) != 1:
        fail("P1.0b.3a exact legacy record observer callsite set changed")
    body = source[closure[0].end():balanced_source(source, closure[0].end())-1]
    if semantic_digest(body) != "bf531462a0fd0527b9c7ec37947373c01f509123715713852565432f88e2e2b1":
        fail("P1.0b.3a HTTP macro-then-trace observer order drifted")
validate_legacy_observer_census(app_source)
for label, mutant in (
    ("missing", app_source.replace("history.onRecord = &macroRecorder.onCommandRecorded;", "", 1)),
    ("surplus", app_source + "\nhistory.onRecord = &macroRecorder.onCommandRecorded;\n"),
    ("reorder", app_source.replace(
        "macroRecorder.onCommandRecorded(line, flags);\n            captureStepTrace(line, flags);",
        "captureStepTrace(line, flags);\n            macroRecorder.onCommandRecorded(line, flags);", 1))):
    try: validate_legacy_observer_census(mutant)
    except SystemExit as error:
        expected = "observer order drifted" if label == "reorder" else "observer callsite set changed"
        if expected not in str(error): fail(f"P1.0b.3a {label} observer mutation failed wrong")
    else: fail(f"P1.0b.3a {label} observer mutation did not RED")
observer_source = (ROOT / "source/record_observer_hub.d").read_text()
production_hub_refs = 0
for path, hub_text in prepared_source_texts.items():
    if path.name not in ("record_observer_hub.d", "command_history.d",
                         "prepared_record_context.d"):
        if "RecordObserverHub" in hub_text:
            production_hub_refs += without_unittests(hub_text).count("RecordObserverHub")
macro_source = (ROOT / "source/macro_recorder.d").read_text()
if production_hub_refs != 7 or not all(x in app_source for x in (
        "auto recordObserverHub = new RecordObserverHub();",
        "macroRecorder.bindObserverHub(recordObserverHub);")) or not all(
            x in macro_source for x in (
                "void bindObserverHub(RecordObserverHub hub)",
                "observerHub_.observeLegacy(commandLine, _flags)",
                "observerHub_.macroLines()")):
    fail("P1.0c record observer ownership cutover drift")
install_match = re.search(r"void\s+installPrepared\s*\([^;{}]*\)\s*nothrow\s+@nogc\s*\{",
                          observer_source)
if not install_match:
    fail("P1.0b.3a record observer installer lost nothrow signature")
install_body = observer_source[install_match.end():balanced_source(observer_source, install_match.end())-1]
if re.search(r"\b(?:assert|enforce|throw|dup|idup|onRecord|append)\b", install_body):
    fail("P1.0b.3a record observer installer gained fallible/open work")
RECORD_OBSERVER_PREPARE_SHA256 = "22e1bf3fab5884f39a1b89a792f858c2be272fc418f0fc016c2b4194d526c01e"
RECORD_OBSERVER_EVOLVE_SHA256 = "df8994c02943fc9c4e2fa7517c101d17633c888ba625bcd2c2dfa7f891910991"
def validate_record_observer_prepare(source):
    match = re.search(r"PreparedRecordObserverImage\s+prepareRecord\s*\([^;{}]*\)\s*\{",
                      source)
    if not match:
        fail("P1.0b.3a record observer prepare seam vanished")
    body = source[match.end():balanced_source(source, match.end())-1]
    if semantic_digest(body) != RECORD_OBSERVER_PREPARE_SHA256:
        fail("P1.0b.3a record observer prepare exact behavior drifted")
    evolve = re.search(r"bool\s+evolvePrepared\s*\([^;{}]*\)\s*\{", source)
    if not evolve:
        fail("P1.0b.3a record observer evolve seam vanished")
    evolve_body = source[evolve.end():balanced_source(source, evolve.end())-1]
    if semantic_digest(evolve_body) != RECORD_OBSERVER_EVOLVE_SHA256:
        fail("P1.0b.3a record observer prepare exact behavior drifted")
validate_record_observer_prepare(observer_source)

filter_expression = ("HistoryFlags.InSession | HistoryFlags.Refire |\n"
                     "                       HistoryFlags.ToolLifecycle")
observer_prepare_mutations = (
    ("empty macro line", "if (result.macroActive && line.length)",
     "if (result.macroActive)"),
    ("Refire filter", filter_expression,
     "HistoryFlags.InSession |\n                       HistoryFlags.ToolLifecycle"),
    ("ToolLifecycle filter", filter_expression,
     "HistoryFlags.InSession | HistoryFlags.Refire"),
    ("filter polarity", "!(flags & (", "(flags & ("),
    ("trace cap", "if (result.traceEntries.length > 500)",
     "if (result.traceEntries.length > 501)"),
)
for label, contract, wrong in observer_prepare_mutations:
    mutant = observer_source.replace(contract, wrong, 1)
    if mutant == observer_source:
        fail(f"P1.0b.3a {label} mutation anchor vanished")
    try:
        validate_record_observer_prepare(mutant)
    except SystemExit as error:
        if "record observer prepare exact behavior drifted" not in str(error):
            fail(f"P1.0b.3a {label} mutation failed for wrong reason")
    else:
        fail(f"P1.0b.3a {label} mutation did not RED")

# P1.0b.3b history owner infrastructure remains unreachable from production.
history_source = (ROOT / "source/command_history.d").read_text()
for path in (ROOT / "source").rglob("*.d"):
    if path.name != "command_history.d" and ".prepareRecordBatch(" in path.read_text():
        fail("P1.0b.3b prepared history gained a pre-cutover caller")

def validate_prepared_history(source):
    expected = {
        "prepareRecord": ("PreparedHistoryResult", "b1562eca7f69448b1b5b446824856772bfa3dac0e65f9d4c0b9e8f1a64c7492a"),
        "consolidatePrepared": (r"private\s+static\s+void", "ccaa223f13adc059804536520163db81c16a1343dda172d0c965e4a7b27d70f4"),
        "prepareConsolidate": ("PreparedHistoryResult", "3ad88567f5495afac0c68db6f9d627afb5c407afe9152446d15b3271e12db818"),
        "prepareLifecycle": ("PreparedHistoryResult", "a53797c1a2ae58675b40b96a8567c22931f20ff60a2bb0072c56372a5e306bb2"),
        "installPreparedToken": ("void", "15772113e5f3f97b80bb8f6d403f80297f53d0b97810571c18a3fc2ca67e8603"),
    }
    for name, (returns, digest) in expected.items():
        match = re.search(returns + r"\s+" + name + r"\s*\([^;{}]*\)[^{]*\{", source)
        if not match:
            fail(f"P1.0b.3b {name} seam vanished")
        body = source[match.end():balanced_source(source, match.end())-1]
        if semantic_digest(body) != digest:
            fail(f"P1.0b.3b {name} exact behavior drifted")
validate_prepared_history(history_source)
if not re.search(r"struct\s+PreparedHistoryToken\s*\{\s*private:\s*ulong\s+owner,\s*generation;",
                 history_source):
    fail("P1.0b.3b scalar-only prepared history token changed")
if not re.search(r"private\s+struct\s+PreparedHistoryBatch", history_source):
    fail("P1.0b.3b reference-bearing pending history image escaped owner")
if re.search(r"(?:prepareRecord|prepareConsolidate|prepareLifecycle|installPreparedToken)\s*\([^)]*PreparedHistoryBatch",
             history_source):
    fail("P1.0b.3b pending history image escaped through owner API")

replace_run_tail_calls = []
for path in (ROOT / "source/tools").rglob("*.d"):
    source = path.read_text()
    for match in re.finditer(r"recordGestureEdit\s*\([^;]*GestureRecordMode\.ReplaceRunTail\s*\)\s*;", source):
        replace_run_tail_calls.append((path.relative_to(ROOT).as_posix(), semantic_digest(match.group(0))))
if replace_run_tail_calls != [("source/tools/create/box.d",
        semantic_digest("recordGestureEdit(cmd, GestureRecordMode.ReplaceRunTail);"))]:
    fail("P1.0b.3b exact ReplaceRunTail production reachability changed")

# Coalescing is deliberately outside P1.0b.3: its legacy mergeFrom mutates the
# live top Command object. Freeze its exact doors/providers and forbid that
# open mutation vocabulary from every prepared surface.
coalescing_doors = {
    "source/input_router.d": ("app.history.recordCoalescing(cmd);",),
    "source/app.d": ("case RecordMode.Coalescing: history.recordCoalescing(cmd); break;",),
    "source/http_providers.d": (
        "runUiCommand(cmd, RecordMode.Coalescing, id);",
        "applyOrRefire(cmd, RecordMode.Coalescing)",),
}
for relative, fingerprints in coalescing_doors.items():
    source = (ROOT / relative).read_text()
    for fingerprint in fingerprints:
        if source.count(fingerprint) != 1:
            fail("P1.0b.3b exact legacy coalescing door census changed")
if sum(len(re.findall(r"[\w.]+\.recordCoalescing\(cmd\);", path.read_text()))
       for path in (ROOT / "source").rglob("*.d")
       if path.name != "command_history.d") != 2:
    fail("P1.0b.3b direct legacy coalescing callsite set changed")
coalescing_pairs = (
    "source/commands/mesh/vertex_edit.d",
    "source/commands/mesh/selection_edit.d",
    "source/commands/mesh/morph_edit.d",
    "source/commands/layer/commands.d",
)
for relative in coalescing_pairs:
    source = (ROOT / relative).read_text()
    if len(re.findall(r"override\s+CompareResult\s+compareOp\s*\(", source)) != 1 or \
       len(re.findall(r"override\s+bool\s+mergeFrom\s*\(", source)) != 1:
        fail("P1.0b.3b exact compareOp/mergeFrom provider census changed")
def validate_no_prepared_coalescing(source):
    prepared = re.search(r"PreparedHistoryResult\s+prepareRecord\s*\([^;{}]*\)[^{]*\{", source)
    if not prepared:
        fail("P1.0b.3b prepared history seam vanished")
    prepared_text = source[prepared.end():balanced_source(source, prepared.end())-1]
    if re.search(r"\b(?:recordCoalescing|mergeFrom|CompareResult)\b", prepared_text):
        fail("P1.0b.3b live-top coalescing escaped into prepared history")
validate_no_prepared_coalescing(history_source)
coalescing_mutant = history_source.replace(
    "if (!ownsPrepared(token)) return PreparedHistoryResult.init;",
    "if (!ownsPrepared(token)) return PreparedHistoryResult.init;\n        cmd.mergeFrom(cmd);", 1)
try:
    validate_no_prepared_coalescing(coalescing_mutant)
except SystemExit as error:
    if "live-top coalescing escaped" not in str(error):
        fail("P1.0b.3b live-top merge mutation failed for wrong reason")
else:
    fail("P1.0b.3b live-top merge mutation did not RED")

for path in (ROOT / "source").rglob("*.d"):
    source = path.read_text()
    if not path.as_posix().endswith("command_history.d") and \
       "prepared_tool" in path.name and re.search(
            r"\b(?:recordCoalescing|mergeFrom|CompareResult)\b", source):
        fail("P1.0b.3b coalescing escaped into prepared tool surface")

history_mutations = (
    ("redo invalidation", "batch.history.redoStack = null;",
     "batch.history.redoStack = batch.history.redoStack;"),
    ("same-generation replace", "batch.history.undoStack[$-1].tweakGeneration == batch.history.tweakGeneration",
     "batch.history.undoStack[$-1].tweakGeneration != batch.history.tweakGeneration"),
    ("observer ordering", "installPreparedImage(pendingPrepared_.history);\n        if (pendingPrepared_.hasObserver",
     "if (pendingPrepared_.hasObserver"),
    ("one-shot consume", "preparedPending_ = false;",
     "preparedPending_ = true;"),
    ("block redo preservation", "if (!batch.history.blockDepth) {",
     "if (true) {"),
    ("ReplaceRunTail timestamp", "entry.timestampMs = batch.history.undoStack[start].timestampMs;",
     "entry.timestampMs = nowMs();"),
    ("ReplaceRunTail must-install", "batch.accepted || kind == PreparedHistoryKind.ReplaceRunTail",
     "batch.accepted"),
    ("lifecycle empty args", "HistoryEntry(cmd.label, \"\", cmd.name, cmd, nowMs(),",
     "HistoryEntry(cmd.label, serializeParams(cmd.params()), cmd.name, cmd, nowMs(),"),
    ("observer shadow evolution", "observerHub.evolvePrepared(batch.observer, line,",
     "batch.observer = observerHub.prepareRecord(line,"),
    ("observer owner stability", "batch.hasObserver && observerHub !is batch.observerOwner",
     "false"),
    ("block ordinary observer flags", "observerFlags = historyFlagsFor(cmd);",
     "observerFlags = entry.flags;"),
)
for label, contract, wrong in history_mutations:
    mutant = history_source.replace(contract, wrong, 1)
    if mutant == history_source:
        fail(f"P1.0b.3b {label} mutation anchor vanished")
    try:
        validate_prepared_history(mutant)
    except SystemExit as error:
        if "exact behavior drifted" not in str(error):
            fail(f"P1.0b.3b {label} mutation failed for wrong reason")
    else:
        fail(f"P1.0b.3b {label} mutation did not RED")

# P1.0b.3c Layer-owned whole-Mesh image, still unreachable from production.
mesh_source = (ROOT / "source/mesh.d").read_text()
document_source = (ROOT / "source/document.d").read_text()
for path in (ROOT / "source").rglob("*.d"):
    if path.name != "document.d" and ".beginPreparedMesh(" in path.read_text():
        fail("P1.0b.3c prepared Mesh owner gained a pre-cutover caller")

def validate_prepared_mesh(mesh, document):
    expected = (
        (mesh, "private auto", "preparedDeepCopy", "ad4913145eaf692463c5b37e7a9cd0be0d1b4d50568fc44a777694f8670b8959"),
        (mesh, "Mesh", "detachedPreparedMesh", "40e6ec540487ba78db0302de7be272887c1634a9acfaa41dc282993928309882"),
        (mesh, "bool", "canBeginPreparedMesh", "57a472d638111edbdc17a211158c5e98ccac6377b5dc3e90455300238b8e55f6"),
        (mesh, "void", "installPreparedMeshImage", "490193583f400bf961d9a9531603fb041aaea228d8852276c65b8eda9e79dfb0"),
        (document, "PreparedLayerMeshToken", "beginPreparedMesh", "2669edc10d0c0e543478df6f28665a01b5b46f8754c4c1c0df7570b6abc64e1f"),
        (document, r"private\s+bool", "ownsPrepared", "26eb3a1ef85b9316985a50931d76b8cd72cb0aa4a16c8804691557359fe7c2e0"),
        (document, "bool", "prepareMeshImage", "5478417340fe98e67ae90ad361871b61e91ad7a8b39e7ff9d6285bf9d3c1a7f4"),
        (document, "ValidatedLayerMeshToken", "validatesPreparedMesh", "6dcf05179a8380e6348dd532d428ff3da0b8c5aa8d1e34b1cf15394550166e60"),
        (document, "void", "installPreparedMesh", "371f10ddc89c9203894ef9423476a25c6c3c9cafeb084b0af7161ba7a03f3cce"),
        (document, "void", "discardPreparedMesh", "098e58852a90bf148199700eae4f83d1b7d2799ddfee08a762e44fcbd1db640e"),
    )
    for source, returns, name, digest in expected:
        match = re.search(returns + r"\s+" + name + r"\s*\([^;{}]*\)[^{]*\{", source)
        if not match:
            fail(f"P1.0b.3c {name} seam vanished")
        body = source[match.end():balanced_source(source, match.end())-1]
        if semantic_digest(body) != digest:
            fail(f"P1.0b.3c {name} exact ownership behavior drifted")
validate_prepared_mesh(mesh_source, document_source)
if not re.search(r"struct\s+PreparedLayerMeshToken\s*\{\s*private:\s*ulong\s+birthId,\s*generation;",
                 document_source):
    fail("P1.0b.3c prepared Mesh token stopped being scalar-only")
if "static foreach (i; 0 .. R.tupleof.length)" not in mesh_source or \
   "static assert(Mesh.tupleof.length == 54" not in (ROOT / "source/mesh_planes.d").read_text():
    fail("P1.0b.3c complete Mesh field ownership census changed")
if not re.search(r"void\s+installPreparedMeshImage\s*\([^)]*\)\s*nothrow\s+@nogc", mesh_source) or \
   not re.search(r"void\s+installPreparedMesh\s*\([^)]*\)\s*nothrow\s+@nogc", document_source):
    fail("P1.0b.3c Mesh install lost static nothrow proof")

mesh_mutations = (
    ("field omission", mesh_source.replace("0 .. R.tupleof.length", "0 .. R.tupleof.length - 1", 1), document_source),
    ("shallow copy", mesh_source.replace("return preparedDeepCopy(mutable);", "return mutable;", 1), document_source),
    ("address replacement", mesh_source.replace("target = image;", "target.vertices = image.vertices;", 1), document_source),
    ("owner generation", mesh_source, document_source.replace(
        "token.generation == preparedMeshPending_.generation",
        "token.generation != preparedMeshPending_.generation", 1)),
    ("declared pending corner admission", mesh_source.replace(
        " ||\n        source.pendingCornerProvenance_.declared()", "", 1), document_source),
    ("unsafe replacement candidate admission", mesh_source, document_source.replace(
        " || !canBeginPreparedMesh(image)", "", 1)),
)
for label, mutated_mesh, mutated_document in mesh_mutations:
    try:
        validate_prepared_mesh(mutated_mesh, mutated_document)
    except SystemExit as error:
        if "exact ownership behavior drifted" not in str(error):
            fail(f"P1.0b.3c {label} mutation failed for wrong reason")
    else:
        fail(f"P1.0b.3c {label} mutation did not RED")

# P1.0b.4a dormant GL-resource owner. Raw GLuint sets stay owner-private;
# production doors may carry only scalar identity/generation tokens.
gpu_source = (ROOT / "source/mesh_gpu.d").read_text()
for path in (ROOT / "source").rglob("*.d"):
    if path.name != "mesh_gpu.d" and ".beginPreparedDestroy(" in path.read_text():
        fail("P1.0b.4a prepared GPU owner gained a pre-cutover caller")

gpu_contracts = (
    "private struct GpuMeshNames",
    "struct PreparedGpuResourceToken {\n    private ulong ownerId;\n    private ulong generation;",
    "struct ValidatedGpuResourceToken {\n    @disable this(this);",
    "final class GpuResourceOwner",
    "peekGpuMeshNames(*target) != pendingDestroy",
    "threadIdentity != requiredThread",
    "contextIdentity != requiredContext",
    "void installPrepared(ref ValidatedGpuResourceToken token) nothrow @nogc",
    "void discardPrepared(PreparedGpuResourceToken token) nothrow @nogc",
    "glDeleteVertexArrays(1, &n.faceVao); glDeleteBuffers(1, &n.faceVbo);",
    "glDeleteBuffers(1, &n.weightColorVbo);",
    "gpu.suppressCageUpload = false;",
    "static assert(!__traits(compiles, {\n    void copyValidatedToken",
)
def validate_prepared_gpu(source):
    for contract in gpu_contracts:
        if source.count(contract) != 1:
            fail("P1.0b.4a GPU owner exact contract drifted")
    body_match = re.search(
        r"void\s+installPrepared\s*\([^)]*\)\s*nothrow\s+@nogc\s*\{", source)
    body = source[body_match.end():balanced_source(source, body_match.end())-1]
    if re.search(r"\b(?:throw|assert|enforce)\s*\(", body):
        fail("P1.0b.4a GPU installer gained a throwable path")
    exact_bodies = (
        (r"bool\s+validatePrepared", "e431625354aa80b1012f59836227d249f0d4b6fb624829e1a5e6121dfab0f043"),
        (r"void\s+installPrepared", "7d060cedf3efd7bc2daa26352d0b139ff755d2e8d21f9ddb2cdb85a1ccc570f0"),
        (r"void\s+discardPrepared", "b31cf1d319a934c57aca2deb80e889b62b34a1e46b4093330434c08ad74f5794"),
        (r"private\s+GpuMeshNames\s+takeGpuMeshNames", "35ef20e0db595abe95abf1caf6b80ea0db16892fda525eb59b082a63ee8c530b"),
        (r"private\s+void\s+deleteGpuMeshNames", "725d85a33d229c84da0c0ce8819d3f9390a19a64d03b418a496e34ccac4bc488"),
    )
    for signature, digest in exact_bodies:
        match = re.search(signature + r"\s*\([^;{}]*\)[^{]*\{", source)
        if not match or semantic_digest(
                source[match.end():balanced_source(source, match.end())-1]) != digest:
            fail("P1.0b.4a GPU owner exact behavior drifted")
validate_prepared_gpu(gpu_source)

gpu_mutations = (
    ("wrong owner", "token.ownerId != ownerId", "token.ownerId == ownerId"),
    ("wrong thread", "threadIdentity != requiredThread", "threadIdentity == requiredThread"),
    ("wrong context", "contextIdentity != requiredContext", "contextIdentity == requiredContext"),
    ("resource reorder",
        "glDeleteVertexArrays(1, &n.faceVao); glDeleteBuffers(1, &n.faceVbo);",
        "glDeleteBuffers(1, &n.faceVbo); glDeleteVertexArrays(1, &n.faceVao);"),
    ("drop resource", "glDeleteBuffers(1, &n.weightColorVbo);", ""),
    ("retain upload suppression", "gpu.suppressCageUpload = false;", ""),
    ("double consume", "pending = false;", "pending = true;"),
    ("throw path", "if (!pending || !validated", "assert(pending);\n        if (!pending || !validated"),
)
for label, old, new in gpu_mutations:
    mutant = gpu_source.replace(old, new, 1)
    if mutant == gpu_source:
        fail(f"P1.0b.4a {label} mutation anchor vanished")
    try:
        validate_prepared_gpu(mutant)
    except SystemExit as error:
        if "P1.0b.4a GPU" not in str(error):
            fail(f"P1.0b.4a {label} mutation failed for wrong reason")
    else:
        fail(f"P1.0b.4a {label} mutation did not RED")

# Potency: changing the Arc producer to copy the original Drawing state must
# RED the named producer contract, independently of the hook-body fingerprint.
arc_source = (ROOT / "source/tools/create/arc.d").read_text()
arc_contract = "cast(int) ArcState.Idle"
def validate_arc_reset_contract(source):
    if source.count(arc_contract) != 3: # producer + validator + parity assertion
        fail("P1.0b.1 Arc original-independent reset contract changed")
validate_arc_reset_contract(arc_source)
arc_mutant = arc_source.replace(arc_contract, "cast(int) ArcState.Drawing", 1)
try:
    validate_arc_reset_contract(arc_mutant)
except SystemExit as error:
    if "Arc original-independent reset contract changed" not in str(error):
        fail("P1.0b.1 original-state mutation failed for wrong reason")
else:
    fail("P1.0b.1 original-state mutation did not RED producer parity")

tool_state_value_contracts = (
    ("source/tools/alignment/mirror.d", "PreparedToolStateDelta.boolean(preparedToolStateOwner, true)", "PreparedToolStateDelta.boolean(preparedToolStateOwner, false)"),
    ("source/tools/edit/bridge_tool.d", "PreparedToolStateDelta.boolean(preparedToolStateOwner, true)", "PreparedToolStateDelta.boolean(preparedToolStateOwner, false)"),
    ("source/tools/transform/xfrm_transform.d", "preparedToolStateOwner,\n                                               uniformVal, uniformVal, uniformVal", "preparedToolStateOwner,\n                                               uniformVal, 1.0f, uniformVal"),
)
for relative, contract, wrong in tool_state_value_contracts:
    source = (ROOT / relative).read_text()
    def validate_value_contract(candidate):
        if candidate.count(contract) != 1:
            fail(f"P1.0b.1 {relative} prepared value contract changed")
    validate_value_contract(source)
    mutant = source.replace(contract, wrong, 1)
    try:
        validate_value_contract(mutant)
    except SystemExit as error:
        if "prepared value contract changed" not in str(error):
            fail(f"P1.0b.1 {relative} wrong-value mutation failed for wrong reason")
    else:
        fail(f"P1.0b.1 {relative} wrong-value mutation did not RED")

p1b2_param_contracts = (
    ("source/tool.d", "PreparedParamDelta.none(preparedToolStateOwner)",
     "PreparedParamDelta.dirty(preparedToolStateOwner)", "base no-op"),
    ("source/tools/common/command_wrapper.d",
     "if (refireDriving_) return PreparedParamDelta.none(preparedToolStateOwner);",
     "if (!refireDriving_) return PreparedParamDelta.none(preparedToolStateOwner);",
     "refire suppression"),
    ("source/tools/common/command_wrapper.d",
     "return PreparedParamDelta.dirty(preparedToolStateOwner);",
     "return PreparedParamDelta.none(preparedToolStateOwner);", "dirty value"),
    ("source/tools/create/sphere.d", "axisAtLastSync == 0 ? (i + 1) % 3",
     "params_.axis == 0 ? (i + 1) % 3", "old-axis source"),
    ("source/tools/create/sphere.d", "axisAtLastSync = handle.axis;",
     "axisAtLastSync = params_.axis;", "final axis stamp"),
    ("source/tools/create/sphere.d",
     "if (prepared.intValue < 0 || prepared.intValue > 2) return false;",
     "if (prepared.intValue < 0 || prepared.intValue > 3) return false;",
     "illegal axis refusal"),
)
for relative, contract, wrong, label in p1b2_param_contracts:
    source = (ROOT / relative).read_text()
    def validate_p1b2_contract(candidate):
        if candidate.count(contract) != 1:
            fail(f"P1.0b.2 {label} contract changed")
    validate_p1b2_contract(source)
    mutant = source.replace(contract, wrong, 1)
    try: validate_p1b2_contract(mutant)
    except SystemExit as error:
        if f"P1.0b.2 {label} contract changed" not in str(error):
            fail(f"P1.0b.2 {label} mutation failed for wrong reason")
    else: fail(f"P1.0b.2 {label} mutation did not RED")

# Every adapter is pinned prepare -> validate -> install. Dropping or moving an
# operation changes the already-frozen direct-body fingerprint; these explicit
# controls prove all five converted rows participate in that gate.
converted_rows = [r for r in CURRENT_WRITERS["hooks"]
                  if (r["module"], r["aggregate"], r["symbol"])
                     in TOOL_STATE_CONVERTED]
for row in converted_rows:
    if row["semantic_sha256"] not in {r["semantic_sha256"] for r in WRITER_MANIFEST["hooks"]}:
        fail("P1.0b.1 converted adapter is not fingerprinted")
    path = ROOT / "source" / Path(*row["module"].split("."))
    path = path.with_suffix(".d")
    source = path.read_text()
    match = re.search(r"\b(?:override\s+)?void\s+" + row["symbol"] +
                      r"\s*\([^;{}]*\)\s*\{", source)
    if not match: fail("P1.0b.1 converted adapter body vanished")
    body = source[match.end():balanced_source(source, match.end())-1]
    statements = [part + ";" for part in body.split(";") if part.strip()]
    if len(statements) != 3:
        fail("P1.0b.1 converted adapter is not exact prepare/handle/install shape")
    dropped = "".join(statements[:2])
    reordered = statements[1] + statements[0] + statements[2]
    if semantic_digest(dropped) == row["semantic_sha256"]:
        fail("P1.0b.1 adapter drop mutation did not RED fingerprint")
    if semantic_digest(reordered) == row["semantic_sha256"]:
        fail("P1.0b.1 adapter reorder mutation did not RED fingerprint")

# Mutation tests operate on copied production source and must be rejected by
# the same bidirectional gate. They cover duplicates, new exact symbols in each
# inventory, and a name-preserving newly reachable domain/callee.
def mutation_rejected(edit, expected_message, expected=WRITER_MANIFEST, inspect=None):
    with tempfile.TemporaryDirectory(prefix="vibe3d-writer-mut-") as td:
        mutant_root = Path(td)
        shutil.copytree(ROOT / "source/tools", mutant_root / "source/tools")
        for name in ("tool.d", "registration.d", "tool_presets.d", "prepared_tool_transition.d"):
            shutil.copy2(ROOT / "source" / name, mutant_root / "source" / name)
        shutil.copy2(ROOT / "source/app.d", mutant_root / "source/app.d")
        (mutant_root / "source/commands/tool").mkdir(parents=True)
        shutil.copy2(ROOT / "source/commands/tool/set.d",
                     mutant_root / "source/commands/tool/set.d")
        (mutant_root / "config").mkdir()
        shutil.copy2(ROOT / "config/tool_presets.yaml", mutant_root / "config/tool_presets.yaml")
        edit(mutant_root)
        actual = scan_writer_graph(mutant_root)
        if inspect is not None:
            inspect(actual)
        try:
            validate_writer_graph(actual, expected)
        except SystemExit as error:
            if expected_message not in str(error):
                fail(f"P1.0b.0 mutation failed for wrong reason: {error}")
            return True
    return False

duplicate = json.loads(json.dumps(WRITER_MANIFEST))
duplicate["hooks"].append(duplicate["hooks"][0])
try:
    validate_writer_graph(CURRENT_WRITERS, duplicate)
except SystemExit:
    pass
else:
    fail("P1.0b.0 duplicate-row mutation did not fail")


with tempfile.TemporaryDirectory(prefix="vibe3d-writer-signatures-") as td:
    signature_source = Path(td) / "writer_signature_mutants.d"
    signature_source.write_text(r'''module writer_signature_mutants;
struct Param {}
class Tool {
    void deactivate() {}
    void onParamChanged(string name) {}
    Param[] params() { return []; }
}
class AddedDeactivate : Tool { override void deactivate() {} }
class AddedParamHook : Tool { override void onParamChanged(string name) {} }
class AddedParams : Tool { override Param[] params() { return []; } }
''')
    signature_compile = subprocess.run(["dmd", "-c", str(signature_source)], text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if signature_compile.returncode:
        fail("P1.0b.0 added-symbol mutations are not valid D signatures:\n" + signature_compile.stdout)

def add_reachable_override_set(root):
    p = root / "source/tools/p1_census_mutant.d"
    p.write_text("module tools.p1_census_mutant; import tool : Tool; import params : Param; "
                 "class P1CensusMutant : Tool { "
                 "override void deactivate() {} "
                 "override void onParamChanged(string name) {} "
                 "override Param[] params() { return []; } }")
    registration = root / "source/registration.d"
    registration.write_text(registration.read_text() +
        '\nvoid p1ReachableMutant() { import tools.p1_census_mutant : P1CensusMutant; '
        'reg.toolFactories["p1.reachable"] = typedToolFactory!P1CensusMutant('
        '() { return new P1CensusMutant(); }); }\n')
    compile_fixture = root / "p1_typed_registration_compile.d"
    compile_fixture.write_text("module p1_typed_registration_compile; struct Param {} "
        "class Tool { void deactivate() {} void onParamChanged(string name) {} "
        "Param[] params() { return []; } } alias ToolFactory = Tool delegate(); "
        "ToolFactory typedToolFactory(T : Tool)(T delegate() factory) { return () => factory(); } "
        "class P1CensusMutant : Tool { override void deactivate() {} "
        "override void onParamChanged(string name) {} override Param[] params() { return []; } } "
        "struct Registry { ToolFactory[string] toolFactories; } "
        "void register(ref Registry reg) { reg.toolFactories[\"p1.reachable\"] = "
        "typedToolFactory!P1CensusMutant(() { return new P1CensusMutant(); }); }")
    compiled = subprocess.run(["dmd", "-o-", str(compile_fixture)],
                              cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if compiled.returncode: fail("P1.0b.0 typed production-shape mutation does not compile:\n" + compiled.stdout)

def inspect_reachable_override_set(actual):
    expected = {
        "hooks": {("P1CensusMutant", "deactivate"),
                  ("P1CensusMutant", "onParamChanged")},
        "params": {("P1CensusMutant", "params")},
        "factories": {("<module>", 'toolFactories["p1.reachable"]')},
        "products": {("P1CensusMutant", "factoryProduct")},
    }
    for section, required in expected.items():
        discovered = {(row["aggregate"], row["symbol"]) for row in actual[section]}
        if not required <= discovered:
            fail(f"P1.0b.0 typed production-shape mutation was not discovered in {section}")

if not mutation_rejected(add_reachable_override_set, "hooks symbol mismatch",
                         inspect=inspect_reachable_override_set):
    fail("P1.0b.0 added production factory/override/provider set did not fail")

def change_factory_product(root):
    p = root / "source/registration.d"
    text = p.read_text()
    anchor = 'reg.toolFactories["xfrm.push"] = typedToolFactory!PushTool(() {'
    begin = text.find(anchor)
    product = text.find("new PushTool(", begin)
    if begin < 0 or product < 0: fail("P1.0b.0 factory product mutation anchor vanished")
    p.write_text(text[:product] + "new BendTool(" + text[product + len("new PushTool("):])
    compiled = subprocess.run(["dmd", "-o-", f"-I={root / 'source'}", *DMD_FLAGS, str(p)],
                              cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if compiled.returncode == 0:
        fail("P1.0b.0 wrong concrete return unexpectedly passed typedToolFactory")
if not mutation_rejected(change_factory_product, "direct-body/product census changed"):
    fail("P1.0b.0 factory returned product/descriptor mismatch did not fail")

for label, edit in (
        ("missing", lambda m: m["products"].pop()),
        ("stale", lambda m: m["factories"][0]["product_types"].append("StaleTool"))):
    mutant_descriptor = json.loads(json.dumps(WRITER_MANIFEST))
    edit(mutant_descriptor)
    try:
        validate_writer_graph(CURRENT_WRITERS, mutant_descriptor)
    except SystemExit:
        pass
    else:
        fail(f"P1.0b.0 {label} factory product descriptor mutation did not fail")

def add_domain_without_renaming(root):
    p = root / "source/tools/transform/transform.d"
    text = p.read_text()
    needle = "override void deactivate() {"
    if needle not in text: fail("P1.0b.0 name-only mutation anchor vanished")
    p.write_text(text.replace(needle, needle + " history.p1CensusWrite();", 1))
if not mutation_rejected(add_domain_without_renaming, "direct-body/product census changed"):
    fail("P1.0b.0 name-only/new-domain mutation did not fail")

def add_ref_escape_without_renaming(root):
    p = root / "source/tools/transform/transform.d"
    text = p.read_text()
    needle = "override void deactivate() {"
    if needle not in text: fail("P1.0b.0 ref-escape mutation anchor vanished")
    p.write_text(text.replace(needle, needle + " auto escaped = mesh.vertices[];", 1))
if not mutation_rejected(add_ref_escape_without_renaming, "direct-body/product census changed"):
    fail("P1.0b.0 name-preserving ref escape mutation did not fail")

def add_bypass_callsite(root):
    p = root / "source/prepared_tool_transition.d"
    p.write_text(p.read_text() +
        "\nbool p1Unauthorized(ref Tool active, ref string id, "
        "ref PreparedArm prepared) nothrow { return commitPreparedArm(active, id, prepared); }\n")
    compiled = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(p)], cwd=root, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if compiled.returncode: fail("P1.0b.0 bypass mutation is not valid D:\n" + compiled.stdout)
if not mutation_rejected(add_bypass_callsite, "activation/lifecycle bypass callsite set changed"):
    fail("P1.0b.0 added activation/lifecycle bypass callsite did not fail")

def bypass_gate(text):
    return not re.search(r"\b(?:prepareArm|commitPreparedArm)\s*\(", text)
if bypass_gate("void mutant() { prepareArm(); }"):
    fail("P1.0b.0 direct activation bypass mutation did not fail")

MANIFEST = {
    "prepared_tool_transition.prepareArm",
    "prepared_tool_transition.commitPreparedArm",
}

# P1.0c production form: exactly one shared caller owns both command and
# interactive arms. D's type checker proves the real commit suffix and every
# invoked installer/disposer are nothrow; the ordered-body census prevents a
# second publisher or an imperative tail from hiding behind that signature.
transition = (ROOT / "source/prepared_tool_transition.d").read_text()
found = {
    "prepared_tool_transition." + name
    for name in re.findall(r"^(?:PreparedArm|bool)\s+(prepareArm|commitPreparedArm)\s*\(",
                           transition, re.M)
}
if found != MANIFEST:
    fail(f"prepared protocol manifest mismatch: missing={sorted(MANIFEST-found)} surplus={sorted(found-MANIFEST)}")

expected_callers = [
    {"path": "source/app.d", "line": 3914, "symbol": "prepareArm"},
    {"path": "source/app.d", "line": 3929, "symbol": "commitPreparedArm"},
]
if CURRENT_WRITERS.get("bypasses") != expected_callers:
    fail("P1.0c both public doors no longer share the exact prepared funnel")

commit_start = transition.find("bool commitPreparedArm(")
commit_open = transition.find("{", commit_start) + 1
commit_body = transition[commit_open:balanced_source(transition, commit_open)-1]
commit_order = [
    "prepared.pipe_.install();",
    "prepared.outgoing_.install();",
    "prepared.candidate_.publish(active);",
    "activeId = prepared.id_;",
    "prepared.incoming_.install();",
    "prepared.params_.install();",
    "prepared.pose_.install();",
    "prepared.candidate_.disposeRetained();",
]
positions = [commit_body.find(item) for item in commit_order]
if any(p < 0 for p in positions) or positions != sorted(positions):
    fail("P1.0c prepared commit order drifted")
if any(token in commit_body for token in
       ("throw ", "new ", ".activate(", ".deactivate(", "onParamChanged(")):
    fail("P1.0c prepared commit regained an imperative/throwing tail")
if "bool function(\n    ref Tool, ref string, ref PreparedArm) nothrow" not in transition:
    fail("P1.0c real commit lost its compiler-checked nothrow signature")

prepare_start = transition.find("PreparedArm prepareArm(")
prepare_open = transition.find("{", prepare_start) + 1
prepare_body = transition[prepare_open:balanced_source(transition, prepare_open)-1]
for required in (
        "prepareStickyToolDefaults(candidate, id)",
        "injectPreparedParamsInto(candidate.params(), namedArgs)",
        "preparePipeActivation(pipeline, pipeAttrs, gizmoHost)",
        "outgoingDoor.prepareDoorDeactivate",
        "incomingDoor.prepareDoorActivate",
        "paramDoor.prepareDoorParamChanged",
        "poseDoor.prepareDoorInitialPose"):
    if required not in prepare_body:
        fail("P1.0c prepared arm omitted domain: " + required)
for forbidden in ("resetTransientPipeStages(", "applyStickyToolDefaults(",
                  ".activate(", ".deactivate(", "onParamChanged("):
    if forbidden in prepare_body:
        fail("P1.0c prepareArm contains a legacy live-write bypass: " + forbidden)

# Retained below as the P1.0a historical scanner specimen. Its synthetic
# stubs described the former inert seam and are intentionally not executable
# against the production P1.0c transaction.
r"""

# Exact roots admitted under revision 10's NoLiveMutation arm.  Entries are
# module/symbol/signature, not witness names detached from code.  The scanner
# below walks their calls transitively and rejects every unlisted edge.
NO_LIVE_ROOTS = {
    ("prepared_tool_transition", "prepareArm", "PreparedArm(const(ubyte)[])"):
        {("prepared_tool_effect", "OwnedBytes.copyOf", "OwnedBytes(const(ubyte)[])"),
         ("prepared_tool_transition", "PreparedEffectList.append", "void(PreparedToolEffect)"),
         ("prepared_tool_transition", "PreparedCandidateOwner.prepareFrom", "void(ToolFactory,Tool)"),
         ("prepared_tool_transition", "PreparedCandidateOwner.discardCandidate", "void() nothrow"),
         ("command_history", "CommandHistory.prepareCurrentImage", "PreparedHistoryImage()"),
         ("change_bus", "PreparedDeliveryJournal.prepare", "PreparedDeliveryJournal(const(PreparedDeliverySpec)[])")},
}
NO_LIVE_LEAVES = {
    ("prepared_tool_effect", "OwnedBytes.copyOf", "OwnedBytes(const(ubyte)[])"),
    ("prepared_tool_transition", "PreparedEffectList.append", "void(PreparedToolEffect)")
    ,("prepared_tool_transition", "PreparedCandidateOwner.prepareFrom", "void(ToolFactory,Tool)")
    ,("prepared_tool_transition", "PreparedCandidateOwner.discardCandidate", "void() nothrow")
}

def fail(message):
    raise SystemExit(message)

transition = (ROOT / "source/prepared_tool_transition.d").read_text()
found = {
    "prepared_tool_transition." + name
    for name in re.findall(r"^(?:PreparedArm|bool)\s+(prepareArm|commitPreparedArm)\s*\(", transition, re.M)
}
if found != MANIFEST:
    fail(f"prepared protocol manifest mismatch: missing={sorted(MANIFEST-found)} surplus={sorted(found-MANIFEST)}")

# P1.0a's call-site census is intentionally empty. This detects an early
# behavioral cutover or an unreviewed bypassing caller by exact file/line.
for path in (ROOT / "source").rglob("*.d"):
    if path.name == "prepared_tool_transition.d":
        continue
    text = path.read_text()
    if re.search(r"\b(?:prepareArm|commitPreparedArm)\s*\(", text):
        fail(f"P1.0a activation bypass/cutover: {path.relative_to(ROOT)}")

def body_of(text, symbol):
    match = re.search(r"\b" + re.escape(symbol.split(".")[-1]) + r"\s*\([^;]*?\)\s*\{", text, re.S)
    if not match:
        fail(f"NoLiveMutation root vanished: {symbol}")
    depth, pos = 1, match.end()
    while pos < len(text) and depth:
        depth += (text[pos] == "{") - (text[pos] == "}")
        pos += 1
    if depth:
        fail(f"NoLiveMutation unbalanced AST root: {symbol}")
    return text[match.end():pos-1]

# Scan the compiler-emitted semantic AST (`-vcg-ast`), not comments or a
# parallel witness file. Inputs are copied to a temporary directory because DMD
# writes each `.d.cg` beside its source.
with tempfile.TemporaryDirectory(prefix="vibe3d-prepared-ast-") as td:
    ast_dir = Path(td)
    for name in ("prepared_tool_effect", "prepared_tool_transition"):
        (ast_dir / f"{name}.d").write_text((ROOT / f"source/{name}.d").read_text())
    (ast_dir / "command_history.d").write_text("module command_history; struct PreparedHistoryImage{} class CommandHistory{PreparedHistoryImage prepareCurrentImage(){return PreparedHistoryImage();} void installPreparedImage(ref PreparedHistoryImage) nothrow{}}")
    (ast_dir / "change_bus.d").write_text("module change_bus; struct ChangeBus{} struct PreparedDeliverySpec{} class PreparedDeliveryJournal{static PreparedDeliveryJournal prepare(const(PreparedDeliverySpec)[]){return new PreparedDeliveryJournal();} void replay(ref ChangeBus) nothrow{}}")
    (ast_dir / "tool.d").write_text("module tool; class Tool{}")
    (ast_dir / "registry.d").write_text("module registry; import tool; alias ToolFactory=Tool delegate();")
    ast_run = subprocess.run([
        "dmd", "-c", "-I.", "-vcg-ast", "prepared_tool_effect.d",
        "prepared_tool_transition.d"
    ], cwd=ast_dir, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if ast_run.returncode:
        fail("NoLiveMutation AST emission failed:\n" + ast_run.stdout)
    modules = {
        name: (ast_dir / f"{name}.d.cg").read_text()
        for name in ("prepared_tool_effect", "prepared_tool_transition")
    }
for root, allowed_edges in NO_LIVE_ROOTS.items():
    module, symbol, _ = root
    body = body_of(modules[module], symbol)
    forbidden = re.search(
        r"\b(?:Mesh|Document|Tool|EditSession|ChangeBus|CommandHistory|g_pipeCtx|g_prefs|activeTool)\b|"
        r"\b(?:delegate|function)\s*\(|\bcast\s*\(|\breturn\s+ref\b|\.ptr\b", body)
    if forbidden:
        fail(f"NoLiveMutation {module}.{symbol}: forbidden AST token {forbidden.group(0)!r}")
    # Calls are resolved to the only currently admitted value constructor. An
    # added direct helper call therefore fails at its call edge; adding the
    # helper to the allowlist exposes its own body to the same scan.
    calls = set()
    if re.search(r"\b(?:OwnedBytes\.)?copyOf\s*\(", body):
        calls.add(("prepared_tool_effect", "OwnedBytes.copyOf", "OwnedBytes(const(ubyte)[])") )
    if re.search(r"\b(?:result\.effects\.)?append\s*\(", body):
        calls.add(("prepared_tool_transition", "PreparedEffectList.append", "void(PreparedToolEffect)"))
    if re.search(r"\bresult\.candidate_\.prepareFrom\s*\(", body):
        calls.add(("prepared_tool_transition", "PreparedCandidateOwner.prepareFrom", "void(ToolFactory,Tool)"))
    if re.search(r"\bresult\.candidate_\.discardCandidate\s*\(", body):
        calls.add(("prepared_tool_transition", "PreparedCandidateOwner.discardCandidate", "void() nothrow"))
    if re.search(r"\bhistory\.prepareCurrentImage\s*\(", body):
        calls.add(("command_history", "CommandHistory.prepareCurrentImage", "PreparedHistoryImage()"))
    if re.search(r"\b(?:PreparedDeliveryJournal\.)?prepare\s*\(", body):
        calls.add(("change_bus", "PreparedDeliveryJournal.prepare", "PreparedDeliveryJournal(const(PreparedDeliverySpec)[])"))
    known_syntax = re.sub(r"\b(?:OwnedBytes\.)?copyOf\s*\(", "(", body)
    known_syntax = re.sub(r"\b(?:result\.effects\.)?append\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\bresult\.candidate_\.prepareFrom\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\bresult\.candidate_\.discardCandidate\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\bhistory\.prepareCurrentImage\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\b(?:PreparedDeliveryJournal\.)?prepare\s*\(", "(", known_syntax)
    # Compiler-lowered owned-array growth. This exact druntime allocator is
    # permitted only in prepare, never in the nothrow commit graph.
    known_syntax = re.sub(r"\b_d_arrayappendcTX\s*\(", "(", known_syntax)
    unknown = [c for c in re.findall(r"\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)\s*\(", known_syntax)
               if c not in {"if", "foreach", "switch", "while", "for", "catch"}]
    if unknown:
        fail(f"NoLiveMutation {module}.{symbol}: unknown call edge {unknown[0]}")
    if calls != allowed_edges:
        fail(f"NoLiveMutation {module}.{symbol}: call graph mismatch")
for module, symbol, _ in NO_LIVE_LEAVES:
    body = body_of(modules[module], symbol)
    forbidden_owners = r"\b(?:Mesh|Document|EditSession|ChangeBus|CommandHistory|g_pipeCtx|g_prefs|activeTool)\b"
    if symbol not in {"PreparedCandidateOwner.prepareFrom", "PreparedCandidateOwner.discardCandidate"}:
        forbidden_owners = r"\b(?:Mesh|Document|Tool|EditSession|ChangeBus|CommandHistory|g_pipeCtx|g_prefs|activeTool)\b"
    if re.search(forbidden_owners, body):
        fail(f"NoLiveMutation leaf {module}.{symbol}: live-owner access")
    known = re.sub(r"\b(?:move|dup|factory|prepare|destroy|_d_arrayappendcTX|_d_arraysetlengthT)\s*\(", "(", body)
    unknown = [c for c in re.findall(r"\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)\s*\(", known)
               if c not in {"if", "foreach", "switch", "while", "for", "cast", "immutable"}]
    if unknown:
        fail(f"NoLiveMutation {module}.{symbol}: unknown call edge {unknown[0]}")
"""

fixtures = sorted((ROOT / "tests/compile_fail").glob("prepared_effect_*.d"))
for fixture in fixtures:
    run = subprocess.run([
        "dmd", "-c", "-Isource", str(fixture)
    ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0:
        fail(f"compile-fail fixture unexpectedly compiled: {fixture.name}")
    if "prepared effect field is not owned" not in run.stdout:
        fail(f"wrong diagnostic for {fixture.name}:\n{run.stdout}")

# Potency against the ACTUAL admitted payload, not merely a new rejected type:
# inject a class reference into PreparedScalar while retaining its name/UDA.
with tempfile.TemporaryDirectory(prefix="vibe3d-prepared-carrier-mut-") as td:
    mutant = (ROOT / "source/prepared_tool_effect.d").read_text().replace(
        "@PreparedAggregate struct PreparedScalar { OwnedId owner; ulong value; }",
        "@PreparedAggregate struct PreparedScalar { OwnedId owner; ulong value; Object borrowed; }")
    if "Object borrowed" not in mutant:
        fail("prepared carrier potency mutation no longer matched PreparedScalar")
    path = Path(td) / "prepared_tool_effect.d"
    path.write_text(mutant)
    run = subprocess.run(["dmd", "-c", str(path)], text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or "prepared effect field is not owned" not in run.stdout:
        fail("borrow added to admitted PreparedScalar did not fail recursively:\n" + run.stdout)

copy_fixture = ROOT / "tests/compile_fail/prepared_arm_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)], cwd=ROOT,
                     text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout
                           and not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("PreparedArm copy was not rejected by its disabled copy constructor:\n" + run.stdout)

radial_copy_fixture = ROOT / "tests/compile_fail/prepared_radial_array_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(radial_copy_fixture)],
                     cwd=ROOT, text=True, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
                           not ("copy constructor" in run.stdout and
                                "disabled" in run.stdout)):
    fail("RadialArray prepared/validated token copy was not rejected:\n" + run.stdout)

# P1.0b.4b dormant full-upload owner. Keep production at zero callers until
# P1.0c, and freeze the closed prepare/validate/nothrow-consume boundary plus
# the original-state identity guards that make refusal zero-live.
mesh_gpu = (ROOT / "source/mesh_gpu.d").read_text()
upload_contracts = (
    "bool beginPreparedUpload(ref const Mesh mesh,",
    "bool validatePreparedUpload(ref PreparedGpuUploadToken token,",
    "void installPreparedUpload(ref ValidatedGpuUploadToken token) nothrow @nogc",
    "requiredThread != threadIdentity",
    "requiredContext != contextIdentity",
    "private bool sameGpuUploadVersion(const(GpuMesh)* target, ulong expected)",
    "return target !is null && target.uploadVersion == expected;",
    "peekGpuMeshNames(*target) != baseNames",
    "next.buildUploadCpu(mesh, vpos, edgeOrigin, vertOrigin, faceOrigin)",
    "installUploadState(*target, prepared)",
    "private void submitUploadGl() nothrow @nogc",
)
for contract in upload_contracts:
    if mesh_gpu.count(contract) != 1:
        fail(f"P1.0b.4b upload-owner contract drift: {contract}")
for path in (ROOT / "source").rglob("*.d"):
    if path.name == "mesh_gpu.d" and path.parent == ROOT / "source":
        continue
    if re.search(r"\.beginPreparedUpload\s*\(", path.read_text()):
        fail(f"P1.0b.4b early prepared-upload caller: {path.relative_to(ROOT)}")

def upload_owner_gate(text):
    return all(contract in text for contract in upload_contracts)
for old, new, label in (
    ("return target !is null && target.uploadVersion == expected;", "return true;", "version identity"),
    ("peekGpuMeshNames(*target) != baseNames", "false", "GL-name identity"),
    ("next.buildUploadCpu(mesh, vpos, edgeOrigin, vertOrigin, faceOrigin)",
     "next.buildUploadCpu(mesh, mesh.vertices, edgeOrigin, vertOrigin, faceOrigin)",
     "resolved morph positions"),
    ("installUploadState(*target, prepared)", "", "owned header transfer"),
):
    mutant = mesh_gpu.replace(old, new, 1)
    if mutant == mesh_gpu or upload_owner_gate(mutant):
        fail(f"P1.0b.4b {label} mutation did not fail")

# P1.0b.4c.1 dormant heterogeneous resource journal. Owner references remain
# private to PreparedRecordContext; the journal vocabulary is closed and the
# eventual consumer performs one validation pass before deterministic install.
record_context = (ROOT / "source/prepared_record_context.d").read_text()
handler_shapes = (ROOT / "source/handles/shapes.d").read_text()
resource_contracts = (
    "private enum PreparedResourceKind : ubyte {",
    "GpuUpload, ClickPointDestroy, BoxHandlerBatchDestroy",
    "bool prepareDestroy(GpuResourceOwner owner)",
    "bool prepareUpload(GpuUploadOwner owner, ref const Mesh mesh,",
    "bool prepareDestroy(ClickPointResourceOwner owner)",
    "bool prepareDestroy(BoxHandlerBatchResourceOwner owner)",
    "if (!ok) { invalidateTransaction(); return false; }",
    "if (resources_.length > 0 && !historyMarker_)",
    "void invalidateTransaction() nothrow @nogc",
    "history_.installPreparedToken(validated_); installedHistory = true;",
    "scope(failure) owner.abortEnlisted();",
    "resources_.reserve(resources_.length + 1);",
    "foreach (ref e; resources_) final switch (e.kind)",
)
for contract in resource_contracts:
    expected = (2 if contract == "foreach (ref e; resources_) final switch (e.kind)"
                else 4 if contract == "scope(failure) owner.abortEnlisted();"
                else 7 if contract == "resources_.reserve(resources_.length + 1);"
                else 1)
    if record_context.count(contract) != expected:
        fail(f"P1.0b.4c.1 resource-journal contract drift: {contract}")
click_resource_block = handler_shapes[handler_shapes.find(
    "final class ClickPointResourceOwner"):]
box_handler_resource_block = handler_shapes[handler_shapes.find(
    "final class BoxHandlerBatchResourceOwner"):handler_shapes.find(
    "final class ClickPointResourceOwner")]
for contract in (
    "final class ClickPointResourceOwner",
    "target.vao != vao || target.vbo != vbo || target.built != built",
    "void installEnlisted() nothrow @nogc",
):
    if click_resource_block.count(contract) != 1:
        fail(f"P1.0b.4c.1 click-resource contract drift: {contract}")
for contract in (
    "final class BoxHandlerBatchResourceOwner",
    "target.vao != vaos[i] || target.vbo != vbos[i]",
    "targets = null; vaos = null; vbos = null;",
):
    if box_handler_resource_block.count(contract) != 1:
        fail(f"P1.0b.4c.1 box-handler resource contract drift: {contract}")
for old, new, label in (
    ("if (!ok) { invalidateTransaction(); return false; }", "", "joint refusal"),
    ("history_.installPreparedToken(validated_); installedHistory = true;",
     "installedHistory = true;", "history order"),
    ("resources_.reserve(resources_.length + 1);", "", "reserve-before-begin"),
    ("scope(failure) owner.abortEnlisted();", "", "enlist unwind"),
    ("if (!ok) { invalidateTransaction(); return false; }",
     "if (!ok) return false;", "terminal refusal"),
    ("target.vao != vao || target.vbo != vbo || target.built != built",
     "false", "handler identity"),
):
    context_mutant = record_context.replace(old, new, 1)
    handler_mutant = handler_shapes.replace(old, new, 1)
    if context_mutant == record_context and handler_mutant == handler_shapes:
        fail(f"P1.0b.4c.1 {label} mutation anchor vanished")
    journal_gate = (all(c in context_mutant for c in resource_contracts) and
        context_mutant.count("resources_.reserve(resources_.length + 1);") == 7 and
        context_mutant.count("scope(failure) owner.abortEnlisted();") == 4 and
        "target.vao != vao || target.vbo != vbo || target.built != built" in handler_mutant and
        "target.vao != vaos[i] || target.vbo != vbos[i]" in handler_mutant)
    if journal_gate:
        fail(f"P1.0b.4c.1 {label} mutation did not fail")
for old, new, label in (
    ("target.vao != vaos[i] || target.vbo != vbos[i]", "false",
     "batch handler identity"),
    ("targets = null; vaos = null; vbos = null;", "",
     "batch payload consumption"),
):
    mutant = handler_shapes.replace(old, new, 1)
    block = mutant[mutant.find("final class BoxHandlerBatchResourceOwner"):
        mutant.find("final class ClickPointResourceOwner")]
    if old not in handler_shapes or all(contract in block for contract in (
            "target.vao != vaos[i] || target.vbo != vbos[i]",
            "targets = null; vaos = null; vbos = null;")):
        fail(f"P1.0b.4c.1 {label} mutation did not RED")

# P1.0b.4c.2 dormant producers; legacy override bodies remain covered by the
# frozen 35-row writer fingerprints above. Transform suppression is an exact
# branch-level Deferred result, never a fake prepared upload.
b4c2_contracts = {
    "source/tools/common/command_wrapper.d": (
        "final PreparedDeactivateEffect prepareDeactivate(",
        "context.markHistoryInstall()",
        "clickOwner.owns(clickHandle)",
        "context.prepareDestroy(clickOwner)",
    ),
    "source/tools/edit/tack.d": (
        "final PreparedDeactivateEffect prepareDeactivate(",
        "previewOwner.owns(&previewGpu_)",
        "prepared = context.prepareDestroy(previewOwner);",
        "context.markHistoryInstall()",
    ),
    "source/tools/transform/transform.d": (
        "final PreparedDeactivateEffect prepareDeactivateGpu(",
        "uploadOwner is null || gpu is null || !uploadOwner.owns(gpu)",
        "context.markHistoryInstall() &&",
        "context.prepareUpload(uploadOwner, *mesh)",
    ),
}
b4c2_digests = {
    "source/tools/common/command_wrapper.d": ("prepareDeactivate", "d4dcfc00ed6d5fb72cf188e38ead7c76c5cb58394bb2c590551dc709d34e9606"),
    "source/tools/edit/tack.d": ("prepareDeactivate", "0ea8fcdfa7a225b41d81f255ae8d44f55e7a4c6770c1e718f6066b6511cd0be3"),
    "source/tools/transform/transform.d": ("prepareDeactivateGpu", "50cd6d5c97ea2325bafd53a8b76ec530cee4a9144dc0a1ce79bbcbb6171ec0c5"),
}
for relative, contracts in b4c2_contracts.items():
    producer_source = (ROOT / relative).read_text()
    for contract in contracts:
        if producer_source.count(contract) != 1:
            fail(f"P1.0b.4c.2 producer contract drift: {relative}: {contract}")
    legacy = re.search(r"override\s+void\s+deactivate\s*\([^)]*\)\s*\{", producer_source)
    legacy_body = producer_source[legacy.end():balanced_source(producer_source, legacy.end())-1]
    if re.search(r"\bprepareDeactivate(?:Gpu)?\s*\(", legacy_body):
        fail(f"P1.0b.4c.2 producer called early from legacy hook: {relative}")
    producer, digest = b4c2_digests[relative]
    match = re.search(r"\bfinal\s+PreparedDeactivateEffect\s+" + producer + r"\s*\([^;{}]*\)[^{]*\{", producer_source)
    body = producer_source[match.end():balanced_source(producer_source, match.end())-1]
    if semantic_digest(body) != digest:
        fail(f"P1.0b.4c.2 exact producer behavior drift: {relative}")

def b4c2_digest_accepts(relative, source):
    producer, digest = b4c2_digests[relative]
    match = re.search(r"\bfinal\s+PreparedDeactivateEffect\s+" + producer + r"\s*\([^;{}]*\)[^{]*\{", source)
    if not match: return False
    body = source[match.end():balanced_source(source, match.end())-1]
    return semantic_digest(body) == digest

for relative, old, new, label in (
    ("source/tools/common/command_wrapper.d", "context.markHistoryInstall()", "true", "drop history marker"),
    ("source/tools/common/command_wrapper.d", "context.prepareDestroy(clickOwner)", "true", "drop click destroy"),
    ("source/tools/common/command_wrapper.d", "clickOwner.owns(clickHandle)", "true", "drop click owner identity"),
    ("source/tools/common/command_wrapper.d",
     "if (!context.markHistoryInstall()) {\n            context.discard();",
     "if (!context.markHistoryInstall()) {", "drop terminal discard"),
    ("source/tools/edit/tack.d", "previewOwner.owns(&previewGpu_)", "true", "drop preview owner identity"),
    ("source/tools/edit/tack.d", "prepared = context.prepareDestroy(previewOwner);", "prepared = true;", "drop preview destroy"),
    ("source/tools/edit/tack.d", "if (prepared && !context.markHistoryInstall())", "if (false)", "drop resource-history order"),
    ("source/tools/edit/tack.d",
     "prepared = context.prepareDestroy(previewOwner);\n            if (prepared && !context.markHistoryInstall())",
     "prepared = context.markHistoryInstall();\n            if (prepared && !context.prepareDestroy(previewOwner))",
     "reorder preview resource/history"),
    ("source/tools/transform/transform.d", "context.markHistoryInstall() &&", "", "drop transform history marker"),
    ("source/tools/transform/transform.d",
     "context.markHistoryInstall() &&\n                        context.prepareUpload(uploadOwner, *mesh)",
     "context.prepareUpload(uploadOwner, *mesh) &&\n                        context.markHistoryInstall()",
     "reorder transform history/upload"),
    ("source/tools/transform/transform.d", "context.prepareUpload(uploadOwner, *mesh)", "true", "drop transform upload"),
    ("source/tools/transform/transform.d", "!uploadOwner.owns(gpu)", "false", "drop upload owner identity"),
    ("source/tools/transform/transform.d", "gpu.suppressCageUpload) {", "false) {", "drop suppress refusal"),
    ("source/tools/transform/transform.d", "if (!prepared) context.discard();", "", "drop upload failure discard"),
):
    source = (ROOT / relative).read_text()
    mutant = source.replace(old, new, 1)
    if mutant == source or b4c2_digest_accepts(relative, mutant):
        fail(f"P1.0b.4c.2 named mutation did not RED exact digest: {label}")

# P1.0b.5a stable prepared delivery: scalar tokens are owner-resolved, Mesh
# evolution is intercepted on its detached address, and one context journal
# installs history -> Mesh -> delivery. The dormant Transform producer closes
# both upload and suppress branches without entering a legacy hook.
b5_sources = {
    "effect": (ROOT / "source/prepared_tool_effect.d").read_text(),
    "bus": (ROOT / "source/change_bus.d").read_text(),
    "mesh": (ROOT / "source/mesh.d").read_text(),
    "document": (ROOT / "source/document.d").read_text(),
    "context": record_context,
    "transform": (ROOT / "source/tools/transform/transform.d").read_text(),
}
b5_contracts = {
    "effect": ("struct PreparedSubjectToken", "PreparedSubjectToken subject;"),
    "bus": ("PreparedMeshSubjectOwner owner;", "bool validate() const nothrow @nogc",
            "e.owner.resolve(e.token, address)", "bus.deliverMesh(e.address,"),
    "mesh": ("g_preparedShadowMeshes", "beginPreparedShadow(ref Mesh mesh)",
             "drainPreparedShadowDelivery(ref Mesh mesh",
             "foreach (p; g_preparedShadowMeshes) if (p is m) return false;",
             "mesh.undeliveredChanges_ = 0;"),
    "document": ("new PreparedMeshSubjectOwner(", "beginEnlistedMesh()",
                 "preparedSubjectOwner_.issue()",),
    "context": ("HistoryInstall, MeshInstall, DeliveryInstall,",
                "bool preparePositionCommit(Layer layer)",
                "auto delivery = PreparedDeliveryJournal.prepare([spec]);",
                "layer.abortEnlistedMesh();\n            invalidateTransaction();",
                "e.layerMesh.installEnlistedMesh();", "e.delivery.replay(changeBus);"),
    "transform": ("suppressLayer.ownsMesh(mesh)",
                  "context.preparePositionCommit(suppressLayer)",),
}
def b5_gate(sources):
    return ("OwnedId subject;" not in sources["effect"] and
            sources["bus"].count("e.owner.resolve(e.token, address)") == 2 and
            sources["context"].find("e.layerMesh.installEnlistedMesh();") <
                sources["context"].find("e.delivery.replay(changeBus);") and
            sources["context"].find("auto delivery = PreparedDeliveryJournal.prepare([spec]);") <
                sources["context"].find("resources_ ~= meshEntry;") and
            all(all(c in sources[name] for c in contracts)
                for name, contracts in b5_contracts.items()))
if not b5_gate(b5_sources):
    fail("P1.0b.5a prepared Mesh/delivery owner contract drift")
for name, old, new, label in (
    ("bus", "e.owner.resolve(e.token, address)", "true", "drop stable subject validation"),
    ("mesh", "foreach (p; g_preparedShadowMeshes) if (p is m) return false;",
     "", "mutate/publish original instead of shadow"),
    ("mesh", "mesh.undeliveredChanges_ = 0;", "", "drop delivery drain clear"),
    ("context", "e.layerMesh.installEnlistedMesh();", "", "drop Mesh install"),
    ("context", "e.delivery.replay(changeBus);", "", "drop delivery install"),
    ("context", "layer.abortEnlistedMesh();\n            invalidateTransaction();",
     "layer.abortEnlistedMesh();", "drop prepare failure invalidation"),
    ("context", "auto delivery = PreparedDeliveryJournal.prepare([spec]);", "",
     "drop delivery preparation before context append"),
    ("context",
     "e.layerMesh.installEnlistedMesh();\n            version (unittest) installTrace_[installTraceLength_++] = 3;",
     "e.delivery.replay(changeBus);\n            version (unittest) installTrace_[installTraceLength_++] = 3;",
     "reorder delivery before Mesh"),
    ("transform", "suppressLayer.ownsMesh(mesh)", "true", "drop Layer/Mesh identity"),
    ("transform", "context.preparePositionCommit(suppressLayer)", "true",
     "drop suppress Mesh/delivery enlist"),
):
    mutant = dict(b5_sources)
    mutant[name] = mutant[name].replace(old, new, 1)
    if mutant[name] == b5_sources[name] or b5_gate(mutant):
        fail(f"P1.0b.5a named mutation did not RED: {label}")

# P1.0b.5b create-family slice: Vertex.activate is the sole row whose full
# effect is tool-private value reset. The other eight exact rows retain mixed
# Mesh/GL/history/snap-overlay effects and remain in the deferred ledger.
vertex_source = (ROOT / "source/tools/create/vertex_place.d").read_text()
b5b_contracts = (
    "private struct ValidatedVertexActivate {\n    @disable this(this);",
    "static assert(!__traits(compiles, {\n    ValidatedVertexActivate first;\n    auto copied = first;",
    "final PreparedActivateEffect prepareActivate() const nothrow @nogc",
    "prepared.owner != preparedToolStateOwner",
    "prepared.kind != PreparedActivateKind.Vertex",
    "final void installPreparedActivate(ref ValidatedVertexActivate validated)",
    "validated.consumable = false;\n        lastSnap_ = SnapResult.init;",
)
def b5b_gate(source):
    return all(c in source for c in b5b_contracts)
if not b5b_gate(vertex_source):
    fail("P1.0b.5b Vertex activation owner contract drift")
legacy_activate = re.search(r"override\s+void\s+activate\s*\(\)\s*\{", vertex_source)
legacy_body = vertex_source[legacy_activate.end():balanced_source(vertex_source, legacy_activate.end())-1]
if "prepareActivate(" in legacy_body or "installPreparedActivate(" in legacy_body:
    fail("P1.0b.5b Vertex dormant producer called by production legacy hook")
for old, new, label in (
    ("@disable this(this);", "", "make validated handle copyable"),
    ("prepared.owner != preparedToolStateOwner", "false", "drop owner identity"),
    ("prepared.kind != PreparedActivateKind.Vertex", "false", "drop closed kind"),
    ("validated.consumable = false;\n        lastSnap_ = SnapResult.init;",
     "lastSnap_ = SnapResult.init;", "drop one-shot consumption"),
    ("validated.consumable = false;\n        lastSnap_ = SnapResult.init;",
     "validated.consumable = false;", "drop activation reset"),
):
    mutant = vertex_source.replace(old, new, 1)
    if mutant == vertex_source or b5b_gate(mutant):
        fail(f"P1.0b.5b named mutation did not RED: {label}")

# P1.0b.5c dormant GL-create and snap-overlay owners. Created GL names remain
# owner-private until a scalar-token validation and allocation-free header
# transfer. The complete HTTP-visible snap projection is likewise captured,
# validated, and reset as one closed value. No production tool calls either
# context enlistment seam in this infrastructure-only phase.
b5c_sources = {
    "gpu": (ROOT / "source/mesh_gpu.d").read_text(),
    "snap": (ROOT / "source/snap_render.d").read_text(),
    "context": record_context,
}
b5c_contracts = {
    "gpu": ("struct PreparedGpuCreateToken { @disable this(this);",
            "final class GpuCreateOwner", "GpuMeshNames created;",
            "GpuMeshNames expectedTarget;", "immutable bool replaceLikeInit;",
            "bool validateEnlisted(ulong threadIdentity, ulong contextIdentity) nothrow @nogc",
            "void installEnlisted() nothrow @nogc",
            "else deleteGpuMeshNames(created);",
            "recordFakeCreated();", "deleteFakeCreated();"),
    "snap": ("struct PreparedSnapOverlayToken { @disable this(this);",
             "final class SnapOverlayOwner", "expected = g_lastSnap;",
             "g_lastSnap != expected", "g_lastSnap = SnapResult.init;",
             "void installClear() nothrow @nogc"),
    "context": ("GpuCreate, SnapOverlayClear", "bool prepareCreate(GpuCreateOwner owner)",
                "bool prepareSnapClear(SnapOverlayOwner owner)",
                "scope(failure) { owner.abortEnlisted(); }",
                "e.gpuCreate.installEnlisted();", "e.snapOverlay.installClear();"),
}
def b5c_gate(sources):
    return (all(all(c in sources[name] for c in contracts)
                for name, contracts in b5c_contracts.items()) and
            sources["gpu"].count("peekGpuMeshNames(*target)") == 7 and
            "if (!replaceLikeInit && expectedTarget != GpuMeshNames.init)" in sources["gpu"] and
            "peekGpuMeshNames(*target) != expectedTarget" in sources["gpu"] and
            sources["gpu"].count("!(threadIdentity == requiredThread)") == 1 and
            sources["gpu"].count("!(contextIdentity == requiredContext)") == 1 and
            sources["gpu"].count("else deleteGpuMeshNames(created);") == 2 and
            sources["gpu"].count("created = GpuMeshNames.init; expectedTarget = GpuMeshNames.init;") == 3 and
            sources["snap"].count("g_lastSnap = SnapResult.init; pending = validated = false;") == 1 and
            sources["gpu"].find("glGenVertexArrays(1, &created.faceVao)") <
                sources["gpu"].find("glGenBuffers(1, &created.weightColorVbo)") and
            sources["context"].find("resources_.reserve(1 + resources_.length);") <
                sources["context"].find("if (!owner.beginEnlistedCreate()) return false;"))
if not b5c_gate(b5c_sources):
    fail("P1.0b.5c GL-create/snap owner contract drift")
for name, old, new, label in (
    ("gpu", "peekGpuMeshNames(*target) != expectedTarget", "false",
     "drop captured-target identity/projection check"),
    ("gpu", "if (!replaceLikeInit && expectedTarget != GpuMeshNames.init)",
     "if (false)", "broaden ordinary create over occupied target"),
    ("gpu", "!(threadIdentity == requiredThread)", "false",
     "drop GL thread identity"),
    ("gpu", "!(contextIdentity == requiredContext)", "false",
     "drop GL context identity"),
    ("gpu", "else deleteGpuMeshNames(created);", "else created = GpuMeshNames.init;",
     "drop prepared-name cleanup"),
    ("gpu", "created = GpuMeshNames.init; expectedTarget = GpuMeshNames.init;",
     "expectedTarget = GpuMeshNames.init;", "leave installed names aliased in owner"),
    ("snap", "expected = g_lastSnap;", "expected = SnapResult.init;",
     "read original snap projection after prepare"),
    ("snap", "g_lastSnap != expected", "false", "drop snap projection validation"),
    ("snap", "g_lastSnap = SnapResult.init; pending = validated = false;",
     "pending = validated = false;", "drop snap reset"),
    ("context", "scope(failure) { owner.abortEnlisted(); }", "",
     "drop allocation-failure GL cleanup"),
    ("context", "e.gpuCreate.installEnlisted();", "",
     "drop GL header install"),
    ("context", "e.snapOverlay.installClear();", "",
     "drop snap install"),
):
    mutant = dict(b5c_sources)
    mutant[name] = mutant[name].replace(old, new, 1)
    if mutant[name] == b5c_sources[name] or b5c_gate(mutant):
        fail(f"P1.0b.5c named mutation did not RED: {label}")
for path in (ROOT / "source/tools").rglob("*.d"):
    body = path.read_text()
    if (".prepareCreate(" in body or ".prepareSnapClear(" in body) and \
            path.relative_to(ROOT).as_posix() not in {
                "source/tools/create/vertex_place.d",
                "source/tools/alignment/radial_sweep_tool.d",
                "source/tools/create/box.d",
                "source/tools/create/pen.d",
                "source/tools/create/primitive_create_tool.d",
                "source/tools/edit/tack.d",
                "source/tools/edit/bridge_tool.d"}:
        fail(f"P1.0b.5c dormant owner has production caller: {path.relative_to(ROOT)}")

# P1.0b.5p exact Box activation: private reset, prepared GL-name transfer,
# then NoHistory. The legacy virtual remains frozen until unified cutover.
box_activation = (ROOT / "source/tools/create/box.d").read_text()
def box_activation_gate(box, private, context):
    start = box.find("final PreparedSessionActivateEffect prepareActivate(")
    end = box.find("final GpuMesh* preparedPreviewGpu", start)
    producer = box[start:end] if start >= 0 and end > start else ""
    private_activation = private[:private.find(
        "static PreparedPrivateStateOwner boxDeactivate")]
    box_activation_install = box[box.find(
        "final void installPreparedPrivateActivation"):box.find(
        "final PreparedBoxDeactivateImage buildPreparedDeactivateState")]
    return (
        "final PreparedSessionActivateEffect prepareActivate(" in producer and
        "PreparedPrivateStateOwner.box(this)" in producer and
        "gpuOwner !is null" in producer and
        "gpuOwner.replacesLikeLegacyInit()" in producer and
        "gpuOwner.owns(&previewGpu)" in producer and
        "context.preparePrivateState(stateOwner)" in producer and
        "context.prepareCreate(gpuOwner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.preparePrivateState(stateOwner)") <
            producer.find("context.prepareCreate(gpuOwner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.Box, ok);" in producer and
        "target.classinfo !is BoxTool.classinfo" in private_activation and
        "case PreparedPrivateStateKind.Box: boxTarget.installPreparedPrivateActivation();" in private and
        "state = BoxState.Idle; moverDragAxis = edgeDragIdx = heightHDragIdx = -1;" in box_activation_install and
        "liveRunActive = false; liveUndoDepth = 0;" in box_activation_install and
        "dragBeforeValid = paramBeforeValid = false; toolHandles.clearHaul();" in box_activation_install and
        "e.gpuCreate.installEnlisted();" in context and
        "e.privateState.install();" in context and
        not any(x in producer
                for x in ("context.validate(", "context.install(", "activate();")))
if not box_activation_gate(box_activation,
        (ROOT / "source/prepared_private_state.d").read_text(), record_context):
    fail("Box activation prepared contract drift")
for target, old, new, label in (
    ("box", "gpuOwner.owns(&previewGpu)", "true", "drop preview GPU identity"),
    ("box", "gpuOwner !is null", "true", "drop null GPU guard"),
    ("box", "gpuOwner.replacesLikeLegacyInit()", "true",
     "drop legacy occupied-target mode"),
    ("box", "context.preparePrivateState(stateOwner)", "true", "drop private reset"),
    ("box", "context.prepareCreate(gpuOwner)", "true", "drop GL create"),
    ("box", "context.markNoHistoryInstall()", "true", "drop NoHistory seal"),
    ("box", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("box", "PreparedActivateKind.Box, ok", "PreparedActivateKind.Box, true",
     "forge accepted effect"),
    ("box", "PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.Box, ok)",
     "PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.Box, ok)", "forge effect owner"),
    ("box", "state = BoxState.Idle; moverDragAxis = edgeDragIdx = heightHDragIdx = -1;",
     "state = BoxState.HeightSet; moverDragAxis = edgeDragIdx = heightHDragIdx = -1;",
     "drop idle reset"),
    ("box", "moverDragAxis = edgeDragIdx = heightHDragIdx = -1;",
     "moverDragAxis = -1;", "drop drag-index reset"),
    ("box", "liveRunActive = false; liveUndoDepth = 0;",
     "liveRunActive = false;", "drop live-run reset"),
    ("box", "dragBeforeValid = paramBeforeValid = false;",
     "dragBeforeValid = false;", "drop live-edit validity reset"),
    ("box", "dragBeforeValid = paramBeforeValid = false; toolHandles.clearHaul();",
     "dragBeforeValid = paramBeforeValid = false;", "drop haul reset"),
    ("private", "target.classinfo !is BoxTool.classinfo", "false",
     "broaden Box admission"),
):
    box, private, context = (box_activation,
        (ROOT / "source/prepared_private_state.d").read_text(), record_context)
    if target == "box": box = box.replace(old, new, 1)
    elif target == "private": private = private.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if box_activation_gate(box, private, context):
        fail(f"Box activation mutation did not RED: {label}")

# Exact Pen activation uses the same closed private→legacy-init GPU→NoHistory
# grammar but a distinct fixed private projection.
pen_activation = (ROOT / "source/tools/create/pen.d").read_text()
def pen_activation_gate(pen, private, context):
    start = pen.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pen.find("final GpuMesh* preparedPreviewGpu", start)
    producer = pen[start:end] if start >= 0 and end > start else ""
    install_start = pen.find("final void installPreparedPrivateActivation()")
    install_end = pen.find(
        "final PreparedPenDeactivateImage buildPreparedDeactivateState", install_start)
    installer = pen[install_start:install_end] \
        if install_start >= 0 and install_end > install_start else ""
    return (
        "PreparedPrivateStateOwner.pen(this)" in producer and
        "gpuOwner !is null" in producer and
        "gpuOwner.replacesLikeLegacyInit()" in producer and
        "gpuOwner.owns(&previewGpu)" in producer and
        all(x in producer for x in ("context.preparePrivateState(stateOwner)",
            "context.prepareCreate(gpuOwner)", "context.markNoHistoryInstall()")) and
        producer.find("context.preparePrivateState(stateOwner)") <
            producer.find("context.prepareCreate(gpuOwner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.Pen, ok);" in producer and
        "target.classinfo !is PenTool.classinfo" in private[:private.find(
            "static PreparedPrivateStateOwner penDeactivate")] and
        "case PreparedPrivateStateKind.Pen: penTarget.installPreparedPrivateActivation();" in private and
        "state = PenState.Idle; vertices_.length = 0; params_.currentPoint = -1;" in installer and
        "params_.posX = params_.posY = params_.posZ = 0.0f;" in installer and
        "dragArmed = dragInitiated = false; dragVertIdx = -1;" in installer and
        "e.privateState.install();" in context and "e.gpuCreate.installEnlisted();" in context and
        not any(x in producer for x in ("context.validate(", "context.install(", "activate();")))
if not pen_activation_gate(pen_activation,
        (ROOT / "source/prepared_private_state.d").read_text(), record_context):
    fail("Pen activation prepared contract drift")
for target, old, new, label in (
    ("pen", "gpuOwner !is null", "true", "drop null GPU guard"),
    ("pen", "gpuOwner.replacesLikeLegacyInit()", "true", "drop legacy GPU mode"),
    ("pen", "gpuOwner.owns(&previewGpu)", "true", "drop preview identity"),
    ("pen", "context.preparePrivateState(stateOwner)", "true", "drop private reset"),
    ("pen", "context.prepareCreate(gpuOwner)", "true", "drop GL create"),
    ("pen", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("pen", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("pen", "PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.Pen, ok)",
     "PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.Pen, ok)", "forge effect owner"),
    ("pen", "state = PenState.Idle; vertices_.length = 0; params_.currentPoint = -1;",
     "state = PenState.Idle; params_.currentPoint = -1;", "drop vertices reset"),
    ("pen", "params_.posX = params_.posY = params_.posZ = 0.0f;\n"
     "        dragArmed = dragInitiated = false; dragVertIdx = -1;",
     "params_.posX = 0.0f;\n"
     "        dragArmed = dragInitiated = false; dragVertIdx = -1;",
     "drop position reset"),
    ("pen", "dragArmed = dragInitiated = false; dragVertIdx = -1;",
     "dragArmed = false;", "drop drag reset"),
    ("private", "target.classinfo !is PenTool.classinfo", "false",
     "broaden Pen admission"),
):
    pen, private, context = (pen_activation,
        (ROOT / "source/prepared_private_state.d").read_text(), record_context)
    if target == "pen": pen = pen.replace(old, new, 1)
    elif target == "private": private = private.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if pen_activation_gate(pen, private, context):
        fail(f"Pen activation mutation did not RED: {label}")

# Pen numeric edits preserve the exact legacy branch split while preparing a
# detached CPU/private image and, only for position edits, a preview upload.
def pen_param_gate(pen, private, effect):
    build_start = pen.find("final PreparedPenParamImage buildPreparedParamImage")
    build_end = pen.find("final PreparedPenParamEffect prepareParamChanged", build_start)
    build = pen[build_start:build_end]
    producer_start = pen.find("final PreparedPenParamEffect prepareParamChanged")
    producer_end = pen.find("final void installPreparedPrivateActivation", producer_start)
    producer = pen[producer_start:producer_end]
    factory_start = private.find("static PreparedPrivateStateOwner penParam")
    factory_end = private.find("static PreparedPrivateStateOwner primitive", factory_start)
    factory = private[factory_start:factory_end]
    return (all(x in build for x in (
                "image.expectedVertices = vertices_.dup;",
                "image.nextVertices = vertices_.dup;",
                "handler !is image.expectedHandlers[i]",
                "!sameValueBytes(frame.toWorld, image.expectedToWorld)",
                "!image.expectedPreview.matches(previewMesh)",
                "if (state != PenState.Drawing) return image;",
                'if (name == "currentPoint")',
                'if (name != "posX" && name != "posY" && name != "posZ")',
                "beginPreparedShadow(image.nextPreview)",
                "drainPreparedShadowDelivery(image.nextPreview")) and
            "installPreparedMeshImage(previewMesh, image.nextPreview)" in pen and
            "target.classinfo !is PenTool.classinfo" in factory and
            "target.buildPreparedParamImage(name)" in factory and
            "!penTarget.preparedParamMatches(penParamImage)" in private and
            "penTarget.installPreparedParam(penParamImage);" in private and
            all(x in producer for x in (
                "context.preparePrivateState(stateOwner)",
                "ownsPreparedPreviewUpload(previewUpload)",
                "context.prepareUpload(previewUpload, stateOwner.penParamPreview)",
                "context.markNoHistoryInstall()", "scope(failure) context.discard();",
                "if (!ok) context.discard();")) and
            producer.find("context.preparePrivateState(stateOwner)") <
                producer.find("context.prepareUpload(previewUpload") <
                producer.find("context.markNoHistoryInstall()") and
            "enum PreparedPenParamKind : ubyte { None, Noop, CurrentPoint, Position }" in effect and
            "PreparedPenParamKind kind;" in effect)
pen_param_sources = (pen_activation,
    (ROOT / "source/prepared_private_state.d").read_text(),
    (ROOT / "source/prepared_tool_effect.d").read_text())
if not pen_param_gate(*pen_param_sources):
    fail("Pen onParamChanged prepared contract drift")
for target, old, new, label in (
    ("build", "image.nextVertices = vertices_.dup;", "image.nextVertices = vertices_;", "borrow vertices"),
    ("build", "handler !is image.expectedHandlers[i]", "false", "drop handler identity"),
    ("build", "!sameValueBytes(frame.toWorld, image.expectedToWorld)", "false", "drop frame validation"),
    ("build", "beginPreparedShadow(image.nextPreview)", "beginPreparedShadow(previewMesh)", "drop detached shadow"),
    ("private", "target.classinfo !is PenTool.classinfo", "false", "broaden product"),
    ("private", "!penTarget.preparedParamMatches(penParamImage)", "false", "drop exact validation"),
    ("producer", "ownsPreparedPreviewUpload(previewUpload)", "true", "drop GPU identity"),
    ("producer", "context.prepareUpload(previewUpload, stateOwner.penParamPreview)", "true", "drop preview upload"),
    ("producer", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
):
    p, o, e = pen_param_sources
    if target in ("build", "producer"):
        start = p.find("final PreparedPenParamImage buildPreparedParamImage") if target == "build" else p.find("final PreparedPenParamEffect prepareParamChanged")
        pos = p.find(old, start); p = p[:pos] + new + p[pos + len(old):]
    elif target == "private":
        start = o.find("static PreparedPrivateStateOwner penParam") if "target.classinfo" in old else 0
        pos = o.find(old, start); o = o[:pos] + new + o[pos + len(old):]
    else:
        e = e.replace(old, new, 1)
    if pen_param_gate(p, o, e):
        fail(f"Pen parameter mutation did not RED: {label}")

# Array's interactive parameter hook is a live topology preview: baseline
# restore + kernel + delivery are built under one detached shadow, then the
# layer image, private `built` flag, GPU upload and NoHistory install in order.
array_param_sources = {
    "tool": (ROOT / "source/tools/alignment/array_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_array_param_update.d").read_text(),
    "context": record_context,
    "snapshot": (ROOT / "source/snapshot.d").read_text(),
}
def array_param_gate(s):
    tool, owner, context, snapshot = (s[k] for k in
        ("tool", "owner", "context", "snapshot"))
    start = tool.find("final PreparedArrayParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "image.candidate.arrayFacesGrid(mask, numX_, numY_, numZ_",
                "drainPreparedShadowDelivery(image.candidate",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)",
                "sameFloat(dist, other.dist)")) and
            all(x in owner for x in (
                "target.classinfo !is ArrayTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)",
                "validatedToken_.generation != generation_")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareArrayParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()",
                "scope(failure) context.discard();", "if (!ok) context.discard();")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareArrayParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            "bool prepareArrayParamUpdate(PreparedArrayParamUpdateOwner owner)" in context and
            context.count("case PreparedResourceKind.ArrayParamUpdateState:") == 3 and
            "e.arrayParamUpdate.install();" in context and
            "bool matches(in MeshSnapshot other) const nothrow @nogc" in snapshot)
if not array_param_gate(array_param_sources):
    fail("Array onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop detached shadow"),
    ("tool", "sameFloat(dist, other.dist)", "true", "drop byte-exact float"),
    ("owner", "target.classinfo !is ArrayTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareArrayParamUpdate(owner)", "true", "drop private state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop GPU upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.arrayParamUpdate.install();", "", "drop context install"),
):
    mutant = dict(array_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedArrayParamEffect prepareParamChanged(")
        start = producer_start if old in text[producer_start:] else text.find(
            "struct ArrayParamProjection")
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == array_param_sources[target] or array_param_gate(mutant):
        fail(f"Array parameter mutation did not RED: {label}")

# Magnet's radius hook rebuilds the current drag from its frozen baseline in a
# detached mesh and installs mesh, gesture state, upload, then NoHistory.
magnet_param_sources = {
    "tool": (ROOT / "source/tools/deform/magnet.d").read_text(),
    "owner": (ROOT / "source/prepared_magnet_param_update.d").read_text(),
    "context": record_context,
}
def magnet_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedMagnetParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "image.nextBuilt = applyMagnet(&image.candidate",
                "drainPreparedShadowDelivery(image.candidate",
                "sameSliceBytes(touchedPrev_, image.expectedTouchedPrev)",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is MagnetTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamMatches(image_, *source_)",
                "target_.installPreparedParam(image_)",
                "validatedToken_.generation != generation_")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareMagnetParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()",
                "scope(failure) context.discard();", "if (!ok) context.discard();")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareMagnetParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            "bool prepareMagnetParamUpdate(PreparedMagnetParamUpdateOwner owner)" in context and
            context.count("case PreparedResourceKind.MagnetParamUpdateState:") == 3 and
            "e.magnetParamUpdate.install();" in context)
if not magnet_param_gate(magnet_param_sources):
    fail("Magnet onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop detached shadow"),
    ("tool", "sameSliceBytes(touchedPrev_, image.expectedTouchedPrev)", "true", "drop exact touched witness"),
    ("owner", "target.classinfo !is MagnetTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareMagnetParamUpdate(owner)", "true", "drop private state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop GPU upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.magnetParamUpdate.install();", "", "drop context install"),
):
    mutant = dict(magnet_param_sources)
    if target == "tool":
        text = mutant[target]
        start = text.find("final PreparedMagnetParamEffect prepareParamChanged(") \
            if old in text[text.find("final PreparedMagnetParamEffect prepareParamChanged("):] \
            else 0
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == magnet_param_sources[target] or magnet_param_gate(mutant):
        fail(f"Magnet parameter mutation did not RED: {label}")

smooth_shift_param_sources = {
    "tool": (ROOT / "source/tools/deform/smooth_shift_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_smooth_shift_param_update.d").read_text(),
    "context": record_context,
}
def smooth_shift_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedSmoothShiftParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "ed.smoothShiftFacesByMask(mask, shift_, scale_, thicken_)",
                "drainPreparedShadowDelivery(image.candidate",
                "sameFloat(shift, other.shift)",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is SmoothShiftTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)",
                "validatedToken_.generation != generation_")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareSmoothShiftParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()", "scope(failure) context.discard();",
                "if (!ok) context.discard();")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareSmoothShiftParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            "bool prepareSmoothShiftParamUpdate(PreparedSmoothShiftParamUpdateOwner owner)" in context and
            context.count("case PreparedResourceKind.SmoothShiftParamUpdateState:") == 3 and
            "e.smoothShiftParamUpdate.install();" in context)
if not smooth_shift_param_gate(smooth_shift_param_sources):
    fail("Smooth Shift onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "sameFloat(shift, other.shift)", "true", "drop exact float"),
    ("owner", "target.classinfo !is SmoothShiftTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareSmoothShiftParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.smoothShiftParamUpdate.install();", "", "drop install"),
):
    mutant = dict(smooth_shift_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedSmoothShiftParamEffect prepareParamChanged(")
        start = producer_start if old in text[producer_start:] else 0
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == smooth_shift_param_sources[target] or smooth_shift_param_gate(mutant):
        fail(f"Smooth Shift parameter mutation did not RED: {label}")

edge_bevel_param_sources = {
    "tool": (ROOT / "source/tools/edit/edge_bevel.d").read_text(),
    "owner": (ROOT / "source/prepared_edge_bevel_param_update.d").read_text(),
    "context": record_context,
    "preview": (ROOT / "source/tools/edit/preview_rebuild.d").read_text(),
}
def edge_bevel_param_gate(s):
    tool, owner, context, preview = (s[k] for k in
        ("tool", "owner", "context", "preview"))
    start = tool.find("final PreparedEdgeBevelParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "preview_.prepareImage(image.preview);",
                "preparedPreview.run(image.candidate, before,",
                "ed.bevelEdgesByMask(target.operandEdgeMask(),",
                "preparedPreview.savePreparedNext(image.preview);",
                "preview_.matchesImage(image.preview)",
                "memcmp(&width, &other.width, float.sizeof) == 0")) and
            all(x in preview for x in (
                "struct PreparedPreviewRebuildImage",
                "image.expectedCage = MeshSnapshot.capture(cage_);",
                "image.expectedCage.matches(cage_)",
                "void loadPreparedNext(", "void savePreparedNext(",
                "void installImage(")) and
            all(x in owner for x in (
                "target.classinfo !is EdgeBevelTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareEdgeBevelParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareEdgeBevelParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.EdgeBevelParamUpdateState:") == 3 and
            "e.edgeBevelParamUpdate.install();" in context)
if not edge_bevel_param_gate(edge_bevel_param_sources):
    fail("Edge Bevel onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "preview_.prepareImage(image.preview);", "", "drop preview image"),
    ("preview", "image.expectedCage.matches(cage_)", "true", "drop cage witness"),
    ("tool", "memcmp(&width, &other.width, float.sizeof) == 0", "true", "drop float identity"),
    ("owner", "target.classinfo !is EdgeBevelTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareEdgeBevelParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.edgeBevelParamUpdate.install();", "", "drop install"),
):
    mutant = dict(edge_bevel_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedEdgeBevelParamEffect prepareParamChanged(")
        start = producer_start if old in text[producer_start:] else 0
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == edge_bevel_param_sources[target] or edge_bevel_param_gate(mutant):
        fail(f"Edge Bevel parameter mutation did not RED: {label}")

edge_extrude_param_sources = {
    "tool": (ROOT / "source/tools/edit/edge_extrude.d").read_text(),
    "owner": (ROOT / "source/prepared_edge_extrude_param_update.d").read_text(),
    "context": record_context,
}
def edge_extrude_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedEdgeExtrudeParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(image.candidate);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "ed.extrudeEdgesByMask(mask, extrude_, width_)",
                "drainPreparedShadowDelivery(image.candidate",
                "memcmp(&extrude, &other.extrude, float.sizeof) == 0",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is EdgeExtrudeTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareEdgeExtrudeParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareEdgeExtrudeParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.EdgeExtrudeParamUpdateState:") == 3 and
            "e.edgeExtrudeParamUpdate.install();" in context)
if not edge_extrude_param_gate(edge_extrude_param_sources):
    fail("Edge Extrude onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "memcmp(&extrude, &other.extrude, float.sizeof) == 0", "true", "drop float identity"),
    ("owner", "target.classinfo !is EdgeExtrudeTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareEdgeExtrudeParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.edgeExtrudeParamUpdate.install();", "", "drop install"),
):
    mutant = dict(edge_extrude_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedEdgeExtrudeParamEffect prepareParamChanged(")
        start = producer_start if old in text[producer_start:] else 0
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == edge_extrude_param_sources[target] or edge_extrude_param_gate(mutant):
        fail(f"Edge Extrude parameter mutation did not RED: {label}")

poly_bevel_param_sources = {
    "tool": (ROOT / "source/tools/edit/poly_bevel.d").read_text(),
    "owner": (ROOT / "source/prepared_poly_bevel_param_update.d").read_text(),
    "context": record_context,
    "preview": (ROOT / "source/tools/edit/preview_rebuild.d").read_text(),
}
def poly_bevel_param_gate(s):
    tool, owner, context, preview = (s[k] for k in
        ("tool", "owner", "context", "preview"))
    start = tool.find("final PreparedPolyBevelParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "preview_.prepareImage(image.preview);",
                "preparedPreview.run(image.candidate, before,",
                "ed.bevelFacesByMask(ed.operandFaceMask(), inset_",
                "preparedPreview.savePreparedNext(image.preview);",
                "preview_.matchesImage(image.preview)",
                "memcmp(&inset, &other.inset, float.sizeof) == 0")) and
            all(x in preview for x in ("struct PreparedPreviewRebuildImage",
                "image.expectedCage.matches(cage_)", "void installImage(")) and
            all(x in owner for x in (
                "target.classinfo !is PolyBevelTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.preparePolyBevelParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.preparePolyBevelParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.PolyBevelParamUpdateState:") == 3 and
            "e.polyBevelParamUpdate.install();" in context)
if not poly_bevel_param_gate(poly_bevel_param_sources):
    fail("Poly Bevel onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "preview_.prepareImage(image.preview);", "", "drop preview image"),
    ("preview", "image.expectedCage.matches(cage_)", "true", "drop cage witness"),
    ("tool", "memcmp(&inset, &other.inset, float.sizeof) == 0", "true", "drop float identity"),
    ("owner", "target.classinfo !is PolyBevelTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.preparePolyBevelParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.polyBevelParamUpdate.install();", "", "drop install"),
):
    mutant = dict(poly_bevel_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedPolyBevelParamEffect prepareParamChanged(")
        start = producer_start if old in text[producer_start:] else 0
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == poly_bevel_param_sources[target] or poly_bevel_param_gate(mutant):
        fail(f"Poly Bevel parameter mutation did not RED: {label}")

poly_extrude_param_sources = {
    "tool": (ROOT / "source/tools/edit/poly_extrude.d").read_text(),
    "owner": (ROOT / "source/prepared_poly_extrude_param_update.d").read_text(),
    "context": record_context,
}
def poly_extrude_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedPolyExtrudeParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(image.candidate);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "ed.extrudeFacesByMask(mask, distance_)",
                "drainPreparedShadowDelivery(image.candidate",
                "memcmp(&distance, &other.distance, float.sizeof) == 0",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is PolyExtrudeTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.preparePolyExtrudeParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.preparePolyExtrudeParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.PolyExtrudeParamUpdateState:") == 3 and
            "e.polyExtrudeParamUpdate.install();" in context)
if not poly_extrude_param_gate(poly_extrude_param_sources):
    fail("Poly Extrude onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "memcmp(&distance, &other.distance, float.sizeof) == 0", "true", "drop float identity"),
    ("owner", "target.classinfo !is PolyExtrudeTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.preparePolyExtrudeParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.polyExtrudeParamUpdate.install();", "", "drop install"),
):
    mutant = dict(poly_extrude_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedPolyExtrudeParamEffect prepareParamChanged(")
        start = producer_start if old in text[producer_start:] else 0
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == poly_extrude_param_sources[target] or poly_extrude_param_gate(mutant):
        fail(f"Poly Extrude parameter mutation did not RED: {label}")

poly_inset_param_sources = {
    "tool": (ROOT / "source/tools/edit/poly_inset_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_poly_inset_param_update.d").read_text(),
    "context": record_context,
}
def poly_inset_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedPolyInsetParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (tool.count("ed.insetFacesByMask(mask, inset_)") == 3 and
            all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(image.candidate);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "ed.insetFacesByMask(mask, inset_)",
                "drainPreparedShadowDelivery(image.candidate",
                "memcmp(&inset, &other.inset, float.sizeof) == 0",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is PolyInsetTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.preparePolyInsetParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.preparePolyInsetParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.PolyInsetParamUpdateState:") == 3 and
            "e.polyInsetParamUpdate.install();" in context)
if not poly_inset_param_gate(poly_inset_param_sources):
    fail("Poly Inset onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "memcmp(&inset, &other.inset, float.sizeof) == 0", "true", "drop float identity"),
    ("tool", "ed.insetFacesByMask(mask, inset_)", "cast(size_t)0", "drop zero-value kernel"),
    ("owner", "target.classinfo !is PolyInsetTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.preparePolyInsetParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.polyInsetParamUpdate.install();", "", "drop install"),
):
    mutant = dict(poly_inset_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedPolyInsetParamEffect prepareParamChanged(")
        build_start = text.find("final PreparedPolyInsetParamImage buildPreparedParamUpdate")
        start = producer_start if old in text[producer_start:] else \
            build_start if label == "drop zero-value kernel" else 0
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == poly_inset_param_sources[target] or poly_inset_param_gate(mutant):
        fail(f"Poly Inset parameter mutation did not RED: {label}")

slice_deactivate_sources = {
    "tool": (ROOT / "source/tools/slice/slice_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_slice_deactivate.d").read_text(),
    "context": record_context,
    "effect": (ROOT / "source/prepared_tool_effect.d").read_text(),
}
def slice_deactivate_gate(s):
    tool, owner, context, effect = (s[k] for k in
        ("tool", "owner", "context", "effect"))
    start = tool.find("final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context,")
    end = tool.find("version(unittest) final void seedPreparedDeactivateForTest", start)
    producer = tool[start:end]
    build_start = tool.find(
        "final PreparedSliceDeactivateImage buildPreparedDeactivateState")
    build_end = tool.find("final bool preparedDeactivateStateMatches", build_start)
    builder = tool[build_start:build_end]
    match_start = build_end
    match_end = tool.find("final void installPreparedDeactivateState", match_start)
    matcher = tool[match_start:match_end]
    install_start = tool.find("final void installPreparedDeactivateState(")
    install_end = tool.find("final PreparedDeactivateEffect prepareDeactivate", install_start)
    installer = tool[install_start:install_end]
    return (all(x in builder for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = before_;"))
            and "armedKey_.matches(live)" in builder
            and all(x in matcher for x in (
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before_)")) and
            all(x in installer for x in (
                "active = false", "dragPart_ = DragNone",
                "previewLive_ = false", "haveBefore_ = false",
                "hasLine_ = false", "ctrlAxis_ = -1",
                "armedKey_.addr = size_t.max",
                "armedKey_.mutVer = ulong.max")) and
            all(x in owner for x in (
                "target.classinfo !is SliceTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedDeactivateStateMatches(image_, *source_)",
                "target_.installPreparedDeactivateState(image_)")) and
            all(x in producer for x in (
                "context.prepare(cmd,",
                "PreparedHistoryKind.Plain",
                "context.prepareGestureCarrierMismatch()",
                "context.markHistoryInstall()",
                "context.markNoHistoryInstall()",
                "context.prepareSliceDeactivate(stateOwner)")) and
            producer.find("context.markHistoryInstall()") <
                producer.find("context.prepareSliceDeactivate(stateOwner)") and
            context.count("case PreparedResourceKind.SliceDeactivateState:") == 3 and
            "e.sliceDeactivate.install();" in context and
            "Mirror, Bridge, Box, Pen, Primitive, Slice," in effect)
if not slice_deactivate_gate(slice_deactivate_sources):
    fail("Slice deactivate prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "armedKey_.matches(live)", "true", "drop armed identity"),
    ("tool", "active = false", "active = true", "drop active reset"),
    ("tool", "previewLive_ = false", "previewLive_ = true", "drop preview reset"),
    ("tool", "armedKey_.addr = size_t.max", "armedKey_.addr = 0", "drop key reset"),
    ("owner", "target.classinfo !is SliceTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "context.prepare(cmd,", "context.prepare_DISABLED(cmd,", "drop history"),
    ("tool", "context.prepareGestureCarrierMismatch()", "true", "drop carrier diagnostic"),
    ("tool", "context.prepareSliceDeactivate(stateOwner)", "true", "drop final state"),
    ("context", "e.sliceDeactivate.install();", "", "drop context install"),
    ("effect", "Mirror, Bridge, Box, Pen, Primitive, Slice,",
     "Mirror, Bridge, Box, Pen, Primitive,", "drop closed effect kind"),
):
    mutant = dict(slice_deactivate_sources)
    if target == "tool":
        text = mutant[target]
        prepare_start = text.find("final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context,")
        install_start = text.find("final void installPreparedDeactivateState(")
        build_start = text.find("final PreparedSliceDeactivateImage buildPreparedDeactivateState")
        match_start = text.find("final bool preparedDeactivateStateMatches", build_start)
        if label in ("drop history", "drop carrier diagnostic", "drop final state"):
            start = prepare_start
        elif label in ("drop active reset", "drop preview reset", "drop key reset"):
            start = install_start
        else:
            start = build_start
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == slice_deactivate_sources[target] or slice_deactivate_gate(mutant):
        fail(f"Slice deactivate mutation did not RED: {label}")

edge_slice_deactivate_sources = {
    "tool": (ROOT / "source/tools/slice/edge_slice_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_edge_slice_deactivate.d").read_text(),
    "context": record_context,
    "effect": (ROOT / "source/prepared_tool_effect.d").read_text(),
}
def edge_slice_deactivate_gate(s):
    tool, owner, context, effect = (s[k] for k in
        ("tool", "owner", "context", "effect"))
    start = tool.find("final PreparedEdgeSliceDeactivateImage buildPreparedDeactivateState")
    end = tool.find("private static bool preparedParamRecognized", start)
    product = tool[start:end]
    return "bakeChainInto(ref Mesh work" in tool and all(x in product for x in (
        "image.expectedLive = MeshSnapshot.capture(live);",
        "image.expectedBefore = chainBefore_;", "detachedPreparedMesh(live)",
        "bakeChainInto(image.candidate", "image.expectedLive.matches(live)",
        "image.expectedBefore.matches(chainBefore_)", "uploadOwner.owns(gpu)",
        "handlerDestroy.owns(handles_)",
        "context.prepareStampedMeshImage(layer, owner.candidate",
        "context.prepareUpload(uploadOwner, owner.candidate)",
        "context.prepareEdgeSliceDeactivate(owner)")) and all(x in owner for x in (
        "target.classinfo !is EdgeSliceTool.classinfo", "!target.ownsPreparedLayer(layer)",
        "&layer_.meshRef() !is source_", "prepared_.owner != owner_",
        "prepared_.generation != generation_", "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.installPreparedDeactivateState(image_)")) and \
        context.count("case PreparedResourceKind.EdgeSliceDeactivateState:") == 3 and \
        "e.edgeSliceDeactivate.install();" in context and \
        "Primitive, Slice, EdgeSlice, LoopSlice, EdgeExtend," in effect
if not edge_slice_deactivate_gate(edge_slice_deactivate_sources):
    fail("Edge Slice deactivate prepared contract drift")
for target, old, new, label in (
    ("tool", "bakeChainInto(image.candidate", "bakeChainFrom(", "drop detached kernel"),
    ("tool", "image.expectedLive.matches(live)", "true", "drop live witness"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "handlerDestroy.owns(handles_)", "true", "drop handler identity"),
    ("tool", "context.prepareEdgeSliceDeactivate(owner)", "true", "drop state enlist"),
    ("owner", "target.classinfo !is EdgeSliceTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("context", "e.edgeSliceDeactivate.install();", "", "drop context install"),
    ("effect", "Primitive, Slice, EdgeSlice, LoopSlice, EdgeExtend,",
     "Primitive, Slice, LoopSlice, EdgeExtend,", "drop effect kind"),
):
    mutant = dict(edge_slice_deactivate_sources)
    if target == "tool":
        text = mutant[target]
        start = text.find("final PreparedEdgeSliceDeactivateImage buildPreparedDeactivateState")
        end = text.find("private static bool preparedParamRecognized", start)
        product = text[start:end].replace(old, new, 1)
        mutant[target] = text[:start] + product + text[end:]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == edge_slice_deactivate_sources[target] or \
            edge_slice_deactivate_gate(mutant):
        fail(f"Edge Slice deactivate mutation did not RED: {label}")
copy_fixture = ROOT / "tests/compile_fail/prepared_edge_slice_deactivate_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Edge Slice deactivate token copy was not rejected:\n" + run.stdout)

loop_slice_deactivate_sources = {
    "tool": (ROOT / "source/tools/slice/loop_slice_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_loop_slice_deactivate.d").read_text(),
    "context": record_context,
    "effect": edge_slice_deactivate_sources["effect"],
}
def loop_slice_deactivate_gate(s):
    tool, owner, context, effect = (s[k] for k in
        ("tool", "owner", "context", "effect"))
    start = tool.find("final PreparedLoopSliceDeactivateImage buildPreparedDeactivateState")
    end = tool.find("public override bool hasUncommittedEdit", start)
    product = tool[start:end]
    return all(x in product for x in (
        "image.expectedLive = MeshSnapshot.capture(live);",
        "image.expectedBefore = before_;", "detachedPreparedMesh(live)",
        "image.expectedBefore.restore(image.candidate)",
        "image.expectedLive.matches(live)",
        "image.expectedBefore.matches(before_)", "uploadOwner.owns(gpu)",
        "context.prepareStampedMeshImage(layer, owner.candidate",
        "context.prepareUpload(uploadOwner, owner.candidate)",
        "owner.markHistoryPrepared()",
        "context.prepareGestureCarrierMismatch()",
        "context.prepareLoopSliceDeactivate(owner)")) and all(x in owner for x in (
        "target.classinfo !is LoopSliceTool.classinfo",
        "!target.ownsPreparedLayer(layer)", "&layer_.meshRef() !is source_",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.installPreparedDeactivateState(image_)")) and \
        context.count("case PreparedResourceKind.LoopSliceDeactivateState:") == 3 and \
        "e.loopSliceDeactivate.install();" in context and \
        "Primitive, Slice, EdgeSlice, LoopSlice, EdgeExtend," in effect
if not loop_slice_deactivate_gate(loop_slice_deactivate_sources):
    fail("Loop Slice deactivate prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedBefore.restore(image.candidate)", "true",
     "drop detached cancel"),
    ("tool", "image.expectedLive.matches(live)", "true", "drop live witness"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "owner.markHistoryPrepared()", "true", "drop history state handoff"),
    ("tool", "context.prepareLoopSliceDeactivate(owner)", "true", "drop state enlist"),
    ("owner", "target.classinfo !is LoopSliceTool.classinfo", "false",
     "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("context", "e.loopSliceDeactivate.install();", "", "drop context install"),
    ("effect", "Primitive, Slice, EdgeSlice, LoopSlice, EdgeExtend,",
     "Primitive, Slice, EdgeSlice, EdgeExtend,", "drop effect kind"),
):
    mutant = dict(loop_slice_deactivate_sources)
    if target == "tool":
        text = mutant[target]
        start = text.find("final PreparedLoopSliceDeactivateImage buildPreparedDeactivateState")
        end = text.find("public override bool hasUncommittedEdit", start)
        product = text[start:end].replace(old, new, 1)
        mutant[target] = text[:start] + product + text[end:]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == loop_slice_deactivate_sources[target] or \
            loop_slice_deactivate_gate(mutant):
        fail(f"Loop Slice deactivate mutation did not RED: {label}")
copy_fixture = ROOT / "tests/compile_fail/prepared_loop_slice_deactivate_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Loop Slice deactivate token copy was not rejected:\n" + run.stdout)

edge_slice_param_sources = {
    "tool": edge_slice_deactivate_sources["tool"],
    "owner": (ROOT / "source/prepared_edge_slice_param_update.d").read_text(),
    "context": record_context,
    "history": (ROOT / "source/command_history.d").read_text(),
    "effect": edge_slice_deactivate_sources["effect"],
}
def edge_slice_param_gate(s):
    tool, owner, context, history, effect = (s[k] for k in
        ("tool", "owner", "context", "history", "effect"))
    start = tool.find("final PreparedEdgeSliceParamImage buildPreparedParamUpdate")
    end = tool.find("override void onParamChanged", start)
    product = tool[start:end]
    history_start = history.find("PreparedHistoryResult prepareInvalidateRedo")
    history_end = history.find("ulong prepareNextRun", history_start)
    history_product = history[history_start:history_end]
    return all(x in product for x in (
        "image.expectedLive = MeshSnapshot.capture(live)",
        "image.expectedBefore = chainBefore_", "pointsFromEdgesParamIn(live)",
        "detachedPreparedMesh(live)", "bakeChainInto(image.candidate",
        "image.expectedLive.matches(live)", "image.expectedBefore.matches(chainBefore_)",
        "context.prepareInvalidateRedo()", "redo.mustInstall",
        "uploadOwner.owns(gpu)", "context.prepareStampedMeshImage(layer, owner.candidate",
        "context.prepareUpload(uploadOwner, owner.candidate)",
        "context.prepareEdgeSliceParamUpdate(owner)")) and all(x in owner for x in (
        "target.classinfo !is EdgeSliceTool.classinfo", "!target.ownsPreparedLayer(layer)",
        "&layer_.meshRef() !is source_", "prepared_.owner != owner_",
        "prepared_.generation != generation_", "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.installPreparedParamUpdate(image_)")) and all(x in history_product for x in (
        "PreparedHistoryResult prepareInvalidateRedo", "batch.history.lockout",
        "batch.history.state == UndoState.Active", "batch.history.redoStack = null")) and \
        context.count("case PreparedResourceKind.EdgeSliceParamUpdateState:") == 3 and \
        "e.edgeSliceParamUpdate.install();" in context and \
        "PreparedEdgeSliceParamKind kind;" in effect
if not edge_slice_param_gate(edge_slice_param_sources):
    fail("Edge Slice parameter prepared contract drift")
for target, old, new, label in (
    ("tool", "pointsFromEdgesParamIn(live)", "pointsFromEdgesParam()", "drop explicit target"),
    ("tool", "bakeChainInto(image.candidate", "bakeChainFrom(", "drop detached kernel"),
    ("tool", "image.expectedLive.matches(live)", "true", "drop live witness"),
    ("tool", "context.prepareInvalidateRedo()", "PreparedHistoryResult.init", "drop redo product"),
    ("tool", "redo.mustInstall", "true", "drop guarded history install"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareEdgeSliceParamUpdate(owner)", "true", "drop state enlist"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("history", "batch.history.redoStack = null", "", "drop redo invalidation"),
    ("context", "e.edgeSliceParamUpdate.install();", "", "drop context install"),
):
    mutant = dict(edge_slice_param_sources)
    if target == "tool":
        text = mutant[target]; start = text.find(
            "final PreparedEdgeSliceParamImage buildPreparedParamUpdate")
        end = text.find("override void onParamChanged", start)
        product = text[start:end].replace(old, new, 1)
        mutant[target] = text[:start] + product + text[end:]
    elif target == "history":
        text = mutant[target]
        start = text.find("PreparedHistoryResult prepareInvalidateRedo")
        end = text.find("ulong prepareNextRun", start)
        product = text[start:end].replace(old, new, 1)
        mutant[target] = text[:start] + product + text[end:]
    else: mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == edge_slice_param_sources[target] or edge_slice_param_gate(mutant):
        fail(f"Edge Slice parameter mutation did not RED: {label}")
copy_fixture = ROOT / "tests/compile_fail/prepared_edge_slice_param_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Edge Slice parameter token copy was not rejected:\n" + run.stdout)

loop_slice_param_sources = {
    "tool": (ROOT / "source/tools/slice/loop_slice_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_loop_slice_param_update.d").read_text(),
    "context": record_context,
    "effect": edge_slice_deactivate_sources["effect"],
}
def loop_slice_param_gate(s):
    tool, owner, context, effect = (s[k] for k in
        ("tool", "owner", "context", "effect"))
    start = tool.find("final PreparedLoopSliceParamImage buildPreparedParamUpdate")
    end = tool.find("override void onParamChanged", start)
    product = tool[start:end]
    return all(x in product for x in (
        "image.expectedLive = MeshSnapshot.capture(live)",
        "image.candidate = detachedPreparedMesh(live)",
        "shadowTool.onParamChanged(pname)", "beginPreparedShadow(image.candidate)",
        "shadowTool.preparedRebuildAttempted_",
        "image.expectedLive.matches(live)", "preparedParamStateMatches(image.expected)",
        "context.prepareInvalidateRedo()", "result.mustInstall",
        "uploadOwner.owns(gpu)",
        "context.prepareStampedMeshImage(layer, owner.candidate",
        "context.prepareUpload(uploadOwner, owner.candidate)",
        "context.prepareLoopSliceParamUpdate(owner)")) and all(x in owner for x in (
        "target.classinfo !is LoopSliceTool.classinfo",
        "!target.ownsPreparedLayer(layer)", "&layer_.meshRef() !is source_",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.installPreparedParamUpdate(image_)")) and \
        context.count("case PreparedResourceKind.LoopSliceParamUpdateState:") == 3 and \
        "e.loopSliceParamUpdate.install();" in context and \
        "PreparedLoopSliceParamKind kind;" in effect
if not loop_slice_param_gate(loop_slice_param_sources):
    fail("Loop Slice parameter prepared contract drift")
for target, old, new, label in (
    ("tool", "image.candidate = detachedPreparedMesh(live)",
     "image.candidate = live", "drop detached target"),
    ("tool", "shadowTool.onParamChanged(pname)", "onParamChanged(pname)",
     "run legacy hook on live owner"),
    ("tool", "image.expectedLive.matches(live)", "true", "drop live witness"),
    ("tool", "context.prepareInvalidateRedo()", "PreparedHistoryResult.init",
     "drop redo product"),
    ("tool", "result.mustInstall", "true", "drop guarded history install"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareLoopSliceParamUpdate(owner)", "true",
     "drop state enlist"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("context", "e.loopSliceParamUpdate.install();", "", "drop context install"),
):
    mutant = dict(loop_slice_param_sources)
    if target == "tool":
        text = mutant[target]
        start = text.find("final PreparedLoopSliceParamImage buildPreparedParamUpdate")
        end = text.find("override void onParamChanged", start)
        product = text[start:end].replace(old, new, 1)
        mutant[target] = text[:start] + product + text[end:]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == loop_slice_param_sources[target] or \
            loop_slice_param_gate(mutant):
        fail(f"Loop Slice parameter mutation did not RED: {label}")
copy_fixture = ROOT / "tests/compile_fail/prepared_loop_slice_param_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Loop Slice parameter token copy was not rejected:\n" + run.stdout)

edge_extend_param_sources = {
    "tool": (ROOT / "source/tools/edit/edge_extend.d").read_text(),
    "owner": (ROOT / "source/prepared_edge_extend_param_update.d").read_text(),
    "context": record_context,
    "preview": (ROOT / "source/tools/edit/preview_rebuild.d").read_text(),
    "effect": edge_slice_deactivate_sources["effect"],
}
def edge_extend_param_gate(s):
    tool, owner, context, preview, effect = (s[k] for k in
        ("tool", "owner", "context", "preview", "effect"))
    start = tool.find("final PreparedEdgeExtendParamImage buildPreparedParamUpdate")
    end = tool.find("override void onParamChanged", start)
    product = tool[start:end]
    return all(x in product for x in (
        "image.expectedLive = MeshSnapshot.capture(live)",
        "image.expectedBefore = before", "detachedPreparedMesh(live)",
        "preview_.prepareImage(image.preview)",
        "runner.run(image.candidate, before", "runPreviewKernel(target)",
        "image.expectedLive.matches(live)", "preview_.matchesImage(image.preview)",
        "uploadOwner.owns(gpu)",
        "context.prepareStampedMeshImage(layer, owner.candidate",
        "context.prepareUpload(uploadOwner, owner.candidate)",
        "context.prepareEdgeExtendParamUpdate(owner)")) and all(x in owner for x in (
        "target.classinfo !is EdgeExtendTool.classinfo",
        "!target.ownsPreparedLayer(layer)", "&layer_.meshRef() !is source_",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "moveOwner_.validate()", "rotateOwner_.validate()", "scaleOwner_.validate()",
        "target_.installPreparedParamUpdate(image_)")) and all(x in preview for x in (
        "void prepareImage(ref PreparedPreviewRebuildImage image)",
        "bool matchesImage(in PreparedPreviewRebuildImage image)",
        "void installImage(ref PreparedPreviewRebuildImage image)")) and \
        context.count("case PreparedResourceKind.EdgeExtendParamUpdateState:") == 3 and \
        "e.edgeExtendParamUpdate.install();" in context and \
        "PreparedEdgeExtendParamKind kind;" in effect
if not edge_extend_param_gate(edge_extend_param_sources):
    fail("Edge Extend parameter prepared contract drift")
for target, old, new, label in (
    ("tool", "detachedPreparedMesh(live)", "live", "drop detached target"),
    ("tool", "runner.run(image.candidate, before", "runner.run(live, before",
     "run kernel on live"),
    ("tool", "image.expectedLive.matches(live)", "true", "drop live witness"),
    ("tool", "preview_.matchesImage(image.preview)", "true", "drop preview witness"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareEdgeExtendParamUpdate(owner)", "true",
     "drop state enlist"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("context", "e.edgeExtendParamUpdate.install();", "", "drop context install"),
    ("preview", "void installImage(ref PreparedPreviewRebuildImage image)",
     "void skipImage(ref PreparedPreviewRebuildImage image)", "drop preview install"),
):
    mutant = dict(edge_extend_param_sources)
    if target == "tool":
        text = mutant[target]
        start = text.find("final PreparedEdgeExtendParamImage buildPreparedParamUpdate")
        end = text.find("override void onParamChanged", start)
        product = text[start:end].replace(old, new, 1)
        mutant[target] = text[:start] + product + text[end:]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == edge_extend_param_sources[target] or \
            edge_extend_param_gate(mutant):
        fail(f"Edge Extend parameter mutation did not RED: {label}")
copy_fixture = ROOT / "tests/compile_fail/prepared_edge_extend_param_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Edge Extend parameter token copy was not rejected:\n" + run.stdout)

edge_extend_deactivate_sources = {
    "tool": (ROOT / "source/tools/edit/edge_extend.d").read_text(),
    "owner": (ROOT / "source/prepared_edge_extend_deactivate.d").read_text(),
    "context": record_context,
    "xfrm": (ROOT / "source/tools/transform/xfrm_transform.d").read_text(),
    "transform": (ROOT / "source/tools/transform/transform.d").read_text(),
    "scale": (ROOT / "source/tools/transform/scale.d").read_text(),
    "effect": edge_slice_deactivate_sources["effect"],
}
def edge_extend_deactivate_gate(s):
    tool, owner, context, xfrm, transform, scale, effect = (s[k] for k in
        ("tool", "owner", "context", "xfrm", "transform", "scale", "effect"))
    start = tool.find("final PreparedEdgeExtendDeactivateImage buildPreparedDeactivateState")
    end = tool.find("void commitEdit()", start)
    product = tool[start:end]
    return all(x in product for x in (
        "image.expectedLive = MeshSnapshot.capture(live)",
        "image.expectedBefore = before", "xfrm.buildPreparedEmbeddedDeactivateImage()",
        "preview_.prepareImage(image.preview)",
        "fillCommitCarrier(image.candidate, cmd)",
        "image.expectedLive.matches(live)", "preview_.matchesImage(image.preview)",
        "xfrm.preparedEmbeddedDeactivateMatches(image.xfrm)",
        "xfrm.installPreparedEmbeddedDeactivate(image.xfrm)",
        "uploadOwner.owns(gpu)",
        "context.prepareStampedMeshImage(layer, owner.candidate",
        "context.prepareUpload(uploadOwner, owner.candidate)",
        "context.prepareGestureCarrierMismatch()",
        "context.prepareEdgeExtendDeactivate(owner)")) and all(x in owner for x in (
        "target.classinfo !is EdgeExtendTool.classinfo",
        "!target.ownsPreparedLayer(layer)", "&layer_.meshRef() !is source_",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.installPreparedDeactivateState(image_)")) and all(x in xfrm for x in (
    "buildPreparedEmbeddedDeactivateImage() const nothrow @nogc",
        "history !is null || editIsOpen()", "scaleDragActive || runBaselineValid",
        "preparedEmbeddedDeactivateMatches(",
        "installPreparedEmbeddedDeactivate(")) and all(x in transform for x in (
        "buildPreparedScalarDeactivateImage()", "preparedScalarDeactivateMatches(",
        "installPreparedScalarDeactivate(",
        "!wholeMeshDrag && !propsDragging && !needsGpuUpdate")) and all(x in scale for x in (
        "image.ownsRelative", "SDL_SetRelativeMouseMode(image.preRelative)",
        "ownsRelativeMouse = false")) and \
        context.count("case PreparedResourceKind.EdgeExtendDeactivateState:") == 3 and \
        "e.edgeExtendDeactivate.install();" in context and \
        "LoopSlice, EdgeExtend," in effect
if not edge_extend_deactivate_gate(edge_extend_deactivate_sources):
    fail("Edge Extend deactivate prepared contract drift")
for target, old, new, label in (
    ("tool", "fillCommitCarrier(image.candidate, cmd)",
     "fillCommitCarrier(live, cmd)", "run commit on live"),
    ("tool", "image.expectedLive.matches(live)", "true", "drop live witness"),
    ("tool", "preview_.matchesImage(image.preview)", "true", "drop preview witness"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareEdgeExtendDeactivate(owner)", "true",
     "drop final state enlist"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("xfrm", "history !is null || editIsOpen()", "false || false",
     "drop embedded idle proof"),
    ("transform", "!wholeMeshDrag && !propsDragging && !needsGpuUpdate",
     "true", "drop scalar GPU proof"),
    ("scale", "SDL_SetRelativeMouseMode(image.preRelative)", "cast(void)0",
     "drop relative mouse restore"),
    ("context", "e.edgeExtendDeactivate.install();", "", "drop context install"),
    ("effect", "LoopSlice, EdgeExtend,", "LoopSlice,", "drop effect kind"),
):
    mutant = dict(edge_extend_deactivate_sources)
    if target == "tool":
        text = mutant[target]
        start = text.find("final PreparedEdgeExtendDeactivateImage buildPreparedDeactivateState")
        end = text.find("void commitEdit()", start)
        product = text[start:end].replace(old, new, 1)
        mutant[target] = text[:start] + product + text[end:]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == edge_extend_deactivate_sources[target] or \
            edge_extend_deactivate_gate(mutant):
        fail(f"Edge Extend deactivate mutation did not RED: {label}")
copy_fixture = ROOT / "tests/compile_fail/prepared_edge_extend_deactivate_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Edge Extend deactivate token copy was not rejected:\n" + run.stdout)

vertex_extrude_param_sources = {
    "tool": (ROOT / "source/tools/edit/vertex_extrude_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_vertex_extrude_param_update.d").read_text(),
    "context": record_context,
}
def vertex_extrude_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedVertexExtrudeParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    build_start = tool.find("final PreparedVertexExtrudeParamImage buildPreparedParamUpdate")
    build = tool[build_start:start]
    return (tool.count("ed.extrudeVerticesByMask(mask, shift_, width_)") == 3 and
            all(x in build for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "if (width_ == 0.0f)",
                "ed.extrudeVerticesByMask(mask, shift_, width_)",
                "drainPreparedShadowDelivery(image.candidate",
                "image.deliveryFlags = baselineFlags;")) and
            all(x in tool for x in (
                "sameFloat(shift, other.shift)",
                "sameFloat(width, other.width)",
                "memcmp(&a, &b, float.sizeof) == 0",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is VertexExtrudeTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareVertexExtrudeParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareVertexExtrudeParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.VertexExtrudeParamUpdateState:") == 3 and
            "e.vertexExtrudeParamUpdate.install();" in context)
if not vertex_extrude_param_gate(vertex_extrude_param_sources):
    fail("Vertex Extrude onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "sameFloat(width, other.width)", "true", "drop width identity"),
    ("tool", "if (width_ == 0.0f)", "if (false)", "drop zero-width branch"),
    ("tool", "ed.extrudeVerticesByMask(mask, shift_, width_)", "cast(size_t)0", "drop kernel"),
    ("owner", "target.classinfo !is VertexExtrudeTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareVertexExtrudeParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.vertexExtrudeParamUpdate.install();", "", "drop install"),
):
    mutant = dict(vertex_extrude_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedVertexExtrudeParamEffect prepareParamChanged(")
        build_start = text.find("final PreparedVertexExtrudeParamImage buildPreparedParamUpdate")
        start = build_start if label == "drop zero-width branch" else \
            producer_start if old in text[producer_start:] else build_start
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == vertex_extrude_param_sources[target] or vertex_extrude_param_gate(mutant):
        fail(f"Vertex Extrude parameter mutation did not RED: {label}")

vertex_bevel_param_sources = {
    "tool": (ROOT / "source/tools/edit/vertex_bevel_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_vertex_bevel_param_update.d").read_text(),
    "context": record_context,
}
def vertex_bevel_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedVertexBevelParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    build_start = tool.find("final PreparedVertexBevelParamImage buildPreparedParamUpdate")
    build = tool[build_start:start]
    return (tool.count("ed.bevelVerticesByMask(mask, inset_)") == 3 and
            all(x in build for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "if (inset_ == 0.0f)",
                "ed.bevelVerticesByMask(mask, inset_)",
                "drainPreparedShadowDelivery(image.candidate",
                "image.deliveryFlags = baselineFlags;")) and
            all(x in tool for x in (
                "memcmp(&inset, &other.inset, float.sizeof) == 0",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is VertexBevelTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareVertexBevelParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareVertexBevelParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.VertexBevelParamUpdateState:") == 3 and
            "e.vertexBevelParamUpdate.install();" in context)
if not vertex_bevel_param_gate(vertex_bevel_param_sources):
    fail("Vertex Bevel onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "memcmp(&inset, &other.inset, float.sizeof) == 0", "true", "drop float identity"),
    ("tool", "if (inset_ == 0.0f)", "if (false)", "drop zero reset branch"),
    ("tool", "ed.bevelVerticesByMask(mask, inset_)", "cast(size_t)0", "drop kernel"),
    ("owner", "target.classinfo !is VertexBevelTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareVertexBevelParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.vertexBevelParamUpdate.install();", "", "drop install"),
):
    mutant = dict(vertex_bevel_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedVertexBevelParamEffect prepareParamChanged(")
        build_start = text.find("final PreparedVertexBevelParamImage buildPreparedParamUpdate")
        start = build_start if label == "drop zero reset branch" else \
            producer_start if old in text[producer_start:] else build_start
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == vertex_bevel_param_sources[target] or vertex_bevel_param_gate(mutant):
        fail(f"Vertex Bevel parameter mutation did not RED: {label}")

vertex_merge_param_sources = {
    "tool": (ROOT / "source/tools/edit/vert_merge_tool.d").read_text(),
    "owner": (ROOT / "source/prepared_vertex_merge_param_update.d").read_text(),
    "context": record_context,
}
def vertex_merge_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedVertexMergeParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (tool.count("image.candidate.weldVerticesByMask(") == 1 and
            all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "image.candidate.weldVerticesByMask(",
                "drainPreparedShadowDelivery(image.candidate",
                "memcmp(&dist, &other.dist, float.sizeof) == 0",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is VertexMergeTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareVertexMergeParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareVertexMergeParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.VertexMergeParamUpdateState:") == 3 and
            "e.vertexMergeParamUpdate.install();" in context)
if not vertex_merge_param_gate(vertex_merge_param_sources):
    fail("Vertex Merge onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "memcmp(&dist, &other.dist, float.sizeof) == 0", "true", "drop float identity"),
    ("tool", "image.candidate.weldVerticesByMask(", "image.candidate.hasAnySelectedVertices(", "drop kernel"),
    ("owner", "target.classinfo !is VertexMergeTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareVertexMergeParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.vertexMergeParamUpdate.install();", "", "drop install"),
):
    mutant = dict(vertex_merge_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedVertexMergeParamEffect prepareParamChanged(")
        build_start = text.find("final PreparedVertexMergeParamImage buildPreparedParamUpdate")
        start = producer_start if old in text[producer_start:] else build_start
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == vertex_merge_param_sources[target] or vertex_merge_param_gate(mutant):
        fail(f"Vertex Merge parameter mutation did not RED: {label}")

reduction_param_sources = {
    "tool": (ROOT / "source/tools/edit/reduce.d").read_text(),
    "owner": (ROOT / "source/prepared_reduction_param_update.d").read_text(),
    "context": record_context,
}
def reduction_param_gate(s):
    tool, owner, context = (s[k] for k in ("tool", "owner", "context"))
    start = tool.find("final PreparedReductionParamEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (tool.count("ed.reduceToTarget(target, pb_)") == 3 and
            all(x in tool for x in (
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "ed.reduceToTarget(target, pb_)",
                "drainPreparedShadowDelivery(image.candidate",
                "memcmp(&ratio, &other.ratio, float.sizeof) == 0",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "target.classinfo !is ReductionTool.classinfo",
                "!target.ownsPreparedLayer(layer)",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamUpdateMatches(image_, *source_)",
                "target_.installPreparedParamUpdate(image_)")) and
            all(x in producer for x in (
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, owner.candidate,",
                "context.prepareReductionParamUpdate(owner)",
                "context.prepareUpload(uploadOwner, owner.candidate)",
                "context.markNoHistoryInstall()")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareReductionParamUpdate(owner)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            context.count("case PreparedResourceKind.ReductionParamUpdateState:") == 3 and
            "e.reductionParamUpdate.install();" in context)
if not reduction_param_gate(reduction_param_sources):
    fail("Reduction onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop shadow"),
    ("tool", "memcmp(&ratio, &other.ratio, float.sizeof) == 0", "true", "drop float identity"),
    ("tool", "ed.reduceToTarget(target, pb_)", "cast(size_t)0", "drop kernel"),
    ("owner", "target.classinfo !is ReductionTool.classinfo", "false", "broaden product"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop Layer identity"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareReductionParamUpdate(owner)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, owner.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("context", "e.reductionParamUpdate.install();", "", "drop install"),
):
    mutant = dict(reduction_param_sources)
    if target == "tool":
        text = mutant[target]
        producer_start = text.find("final PreparedReductionParamEffect prepareParamChanged(")
        build_start = text.find("final PreparedReductionParamImage buildPreparedParamUpdate")
        start = producer_start if old in text[producer_start:] else build_start
        pos = text.find(old, start)
        mutant[target] = text[:pos] + new + text[pos + len(old):]
    else:
        mutant[target] = mutant[target].replace(old, new, 1)
    if mutant[target] == reduction_param_sources[target] or reduction_param_gate(mutant):
        fail(f"Reduction parameter mutation did not RED: {label}")

# PrimitiveCreateTool.activate is one inherited declaration with six exact
# products. Its closed projection preserves each leaf's resetSession law and
# installs private state -> legacy-init GL header -> NoHistory atomically.
primitive_activation_sources = {
    "base": (ROOT / "source/tools/create/primitive_create_tool.d").read_text(),
    "private": (ROOT / "source/prepared_private_state.d").read_text(),
    "sphere": (ROOT / "source/tools/create/sphere.d").read_text(),
    "torus": (ROOT / "source/tools/create/torus.d").read_text(),
    "tube": (ROOT / "source/tools/create/tube.d").read_text(),
}
def primitive_activation_gate(s):
    start = s["base"].find("final PreparedSessionActivateEffect prepareActivate(")
    end = s["base"].find("final GpuMesh* preparedPreviewGpu", start)
    producer = s["base"][start:end] if start >= 0 and end > start else ""
    roster = ("SphereTool", "CapsuleTool", "ConeTool", "CylinderTool",
              "TorusTool", "TubeTool")
    return (
        "PreparedPrivateStateOwner.primitiveProduct(this)" in producer and
        all(x in producer for x in ("gpuOwner !is null",
            "gpuOwner.replacesLikeLegacyInit()", "gpuOwner.owns(&previewGpu)",
            "context.preparePrivateState(stateOwner)",
            "context.prepareCreate(gpuOwner)", "context.markNoHistoryInstall()",
            "scope(failure) context.discard();", "if (!ok) context.discard();")) and
        producer.find("context.preparePrivateState(stateOwner)") <
            producer.find("context.prepareCreate(gpuOwner)") <
            producer.find("context.markNoHistoryInstall()") and
        "PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.Primitive, ok)" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "activate();")) and
        all(f"target.classinfo is {name}.classinfo" in s["private"]
            for name in roster) and
        "else return null;" in s["private"] and
        "meshChanged = false; moverDragAxis = -1;" in s["base"] and
        "final void installPreparedPrimitiveActivationPost() nothrow @nogc {\n"
        "        toolHandles.clearHaul();" in s["base"] and
        "final void installPreparedHandledActivationPre() nothrow @nogc {\n"
        "        installPreparedPrimitiveActivationPre();\n        sizeDragIdx = -1;" in s["base"] and
        "installPreparedRadialActivationPre();\n"
        "        installPreparedPrimitiveActivationPost();" in s["base"] and
        "state = RadialState.Idle;\n        installPreparedHandledActivationPre();" in s["base"] and
        "state = RadialState.Idle; dragUniform = false;" not in s["base"] and
        "sphereTarget.installPreparedSphereReset(sphereClearMethod, sphereAxis);" in s["private"] and
        "installPreparedRadialActivationPre();\n"
        "        if (clearMethod) params_.method = 0;\n"
        "        axisAtLastSync = nextAxis;\n"
        "        installPreparedPrimitiveActivationPost();" in s["sphere"] and
        "state = TorusState.Idle;\n        installPreparedHandledActivationPre();\n"
        "        installPreparedPrimitiveActivationPost();" in s["torus"] and
        "state = TubeState.Idle;\n        installPreparedPrimitiveActivationPre();\n"
        "        installPreparedPrimitiveActivationPost();" in s["tube"])
if not primitive_activation_gate(primitive_activation_sources):
    fail("Primitive activation prepared contract drift")
for name, old, new, label in (
    ("base", "gpuOwner !is null", "true", "drop null GPU guard"),
    ("base", "gpuOwner.replacesLikeLegacyInit()", "true", "drop legacy GPU mode"),
    ("base", "gpuOwner.owns(&previewGpu)", "true", "drop preview identity"),
    ("base", "context.preparePrivateState(stateOwner)", "true", "drop private reset"),
    ("base", "context.prepareCreate(gpuOwner)", "true", "drop GL create"),
    ("base", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
    ("base", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("base", "PreparedActivateKind.Primitive, ok", "PreparedActivateKind.Primitive, true", "forge accepted effect"),
    ("base", "PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.Primitive, ok)",
     "PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.Primitive, ok)", "forge effect owner"),
    ("base", "meshChanged = false; moverDragAxis = -1;",
     "moverDragAxis = -1;", "drop meshChanged reset"),
    ("base", "final void installPreparedHandledActivationPre() nothrow @nogc {\n"
     "        installPreparedPrimitiveActivationPre();\n        sizeDragIdx = -1;",
     "final void installPreparedHandledActivationPre() nothrow @nogc {\n"
     "        installPreparedPrimitiveActivationPre();", "drop handled reset"),
    ("base", "state = RadialState.Idle;\n        installPreparedHandledActivationPre();",
     "dragUniform = false;\n        installPreparedHandledActivationPre();", "drop radial idle/preserve drag mode"),
    ("base", "final void installPreparedPrimitiveActivationPost() nothrow @nogc {\n"
     "        toolHandles.clearHaul();",
     "final void installPreparedPrimitiveActivationPost() nothrow @nogc {",
     "drop final haul reset"),
    ("private", "target.classinfo is CapsuleTool.classinfo", "false", "drop Capsule product"),
    ("private", "target.classinfo is ConeTool.classinfo", "false", "drop Cone product"),
    ("private", "target.classinfo is CylinderTool.classinfo", "false", "drop Cylinder product"),
    ("private", "target.classinfo is SphereTool.classinfo", "false", "drop Sphere product"),
    ("private", "target.classinfo is TorusTool.classinfo", "false", "drop Torus product"),
    ("private", "target.classinfo is TubeTool.classinfo", "false", "drop Tube product"),
    ("sphere", "if (clearMethod) params_.method = 0;", "", "drop Sphere method reset"),
    ("sphere", "if (clearMethod) params_.method = 0;", "if (true) params_.method = 0;",
     "clear normal-Sphere method"),
    ("sphere", "axisAtLastSync = nextAxis;\n        installPreparedPrimitiveActivationPost();",
     "installPreparedPrimitiveActivationPost();\n        axisAtLastSync = nextAxis;",
     "move haul clear before Sphere reset"),
    ("torus", "state = TorusState.Idle;", "", "drop Torus idle reset"),
    ("tube", "state = TubeState.Idle;", "", "drop Tube idle reset"),
):
    mutant = dict(primitive_activation_sources)
    mutant[name] = mutant[name].replace(old, new, 1)
    if mutant[name] == primitive_activation_sources[name] or primitive_activation_gate(mutant):
        fail(f"Primitive activation mutation did not RED: {label}")

# Exact StrokeExtrude activation: a deep cage snapshot plus fixed session
# reset, followed by NoHistory. Production activate stays legacy until cutover.
stroke_activation_owner = (ROOT /
    "source/prepared_stroke_extrude_activation.d").read_text()
stroke_activation_tool = (ROOT /
    "source/tools/deform/stroke_extrude_tool.d").read_text()
stroke_activation_snapshot = (ROOT / "source/snapshot.d").read_text()
stroke_snapshot_match_checks = (
    "vertices != mesh.vertices", "edges != mesh.edges",
    "vertexMarks != mesh.vertexMarks", "edgeMarks != mesh.edgeMarks",
    "faceMarks != mesh.faceMarks",
    "vertexSelectionOrder != mesh.vertexSelectionOrder",
    "edgeSelectionOrder != mesh.edgeSelectionOrder",
    "faceSelectionOrder != mesh.faceSelectionOrder",
    "vertexSelectionOrderCounter != mesh.vertexSelectionOrderCounter",
    "edgeSelectionOrderCounter != mesh.edgeSelectionOrderCounter",
    "faceSelectionOrderCounter != mesh.faceSelectionOrderCounter",
    "surfaces != mesh.surfaces", "faceMaterial != mesh.faceMaterial",
    "facePart != mesh.facePart", "meshMaps != mesh.meshMaps",
    "vertexSetNames != mesh.vertexSetNames",
    "vertexSetMask != mesh.vertexSetMask",
    "edgeSetNames != mesh.edgeSetNames", "edgeSetMask != mesh.edgeSetMask",
    "polygonSetNames != mesh.polygonSetNames",
    "faceSetMask != mesh.faceSetMask", "faces.length != mesh.faces.length",
    "face != mesh.faces[i]",
)
def stroke_activation_gate(owner, context, tool, snapshot=stroke_activation_snapshot):
    production_owner = without_unittests(owner)
    production_tool = without_unittests(tool)
    start = production_tool.find(
        "final PreparedSessionActivateEffect prepareActivate(")
    end = production_tool.find("final auto preparedOwnerForTest", start)
    producer = production_tool[start:end] if start >= 0 and end > start else ""
    legacy = re.search(r"override void activate\(\)\s*\{", production_tool)
    legacy_body = production_tool[legacy.end():balanced_source(
        production_tool, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedStrokeExtrudeActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in production_owner for x in
                (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is StrokeExtrudeTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        all(check in snapshot for check in stroke_snapshot_match_checks) and
        "target_.installPreparedActivation(image_);\n        consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "image.before = MeshSnapshot.capture(*source);\n"
        "        image.valid = true;" in tool and
        "active = true; drawing_ = false; built_ = false;\n"
        "        mask_ = null; pathPoints_.length = 0;\n"
        "        image.before.moveInto(before);\n"
        "        image.valid = false;" in tool and
        "PreparedStrokeExtrudeActivationOwner.prepare(this)" in producer and
        "context.prepareStrokeExtrudeActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareStrokeExtrudeActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.StrokeExtrude, ok)" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in
                ("prepareActivate(", "PreparedRecordContext")) and
        "e.strokeExtrudeActivation.validate();" in context and
        "e.strokeExtrudeActivation.install();" in context and
        "e.strokeExtrudeActivation.abort();" in context)
if not stroke_activation_gate(stroke_activation_owner, record_context,
                              stroke_activation_tool, stroke_activation_snapshot):
    fail("StrokeExtrude activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is StrokeExtrudeTool.classinfo", "false",
     "broaden exact product admission"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "",
     "drop detached builder"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false",
     "drop live mesh identity validation"),
    ("owner", "!image_.before.matches(*source_)", "false",
     "drop live mesh content validation"),
    ("owner", "target_.installPreparedActivation(image_);", "",
     "drop fixed installer"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;",
     "retain deep payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "",
     "drop cage snapshot"),
    ("tool", "image.before.moveInto(before);", "before = image.before;",
     "shallow-copy cage snapshot"),
    ("tool", "image.valid = false;", "",
     "retain installed carrier validity"),
    ("tool", "active = true; drawing_ = false; built_ = false;",
     "active = true; drawing_ = false;", "drop built reset"),
    ("tool", "mask_ = null; pathPoints_.length = 0;", "mask_ = null;",
     "drop path reset"),
    ("tool", "scope(failure) context.discard();", "",
     "drop function failure cleanup"),
    ("tool", "context.prepareStrokeExtrudeActivation(owner)", "true",
     "drop context enlist"),
    ("tool", "context.markNoHistoryInstall()", "true",
     "drop NoHistory seal"),
    ("tool", "PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.StrokeExtrude, ok)",
     "PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.StrokeExtrude, ok)",
     "forge effect owner"),
    ("context", "e.strokeExtrudeActivation.validate();", "true;",
     "drop context validation"),
    ("context", "e.strokeExtrudeActivation.install();", "",
     "drop context install"),
    ("context", "e.strokeExtrudeActivation.abort();", "",
     "drop context abort"),
):
    o, c, t = stroke_activation_owner, record_context, stroke_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if (o == stroke_activation_owner and c == record_context and
            t == stroke_activation_tool) or stroke_activation_gate(o, c, t):
        fail(f"StrokeExtrude activation mutation did not RED: {label}")
for check in stroke_snapshot_match_checks:
    mutant = stroke_activation_snapshot.replace(check, check.replace(" != ", " == "), 1)
    if mutant == stroke_activation_snapshot or stroke_activation_gate(
            stroke_activation_owner, record_context, stroke_activation_tool, mutant):
        fail("StrokeExtrude snapshot field mutation did not RED: " + check)

for stroke_activation_copy_fixture in (
    ROOT / "tests/compile_fail/prepared_stroke_extrude_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_stroke_extrude_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS,
        str(stroke_activation_copy_fixture)], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("StrokeExtrude activation token copy was not rejected:\n" + run.stdout)

# Exact VertexMerge activation: full cage baseline plus the four-field legacy
# reset, followed by NoHistory. The production hook remains frozen for cutover.
vertex_merge_activation_owner = (ROOT /
    "source/prepared_vertex_merge_activation.d").read_text()
vertex_merge_activation_tool = (ROOT /
    "source/tools/edit/vert_merge_tool.d").read_text()
def vertex_merge_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("version(unittest) final auto preparedOwnerForTest", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedVertexMergeActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is VertexMergeTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_);\n        consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source);" in tool and
        "active = true; built = false; dragging = false; dist_ = 0.001f;\n"
        "        image.before.moveInto(before);\n        image.valid = false;" in tool and
        "PreparedVertexMergeActivationOwner.prepare(this)" in producer and
        "context.prepareVertexMergeActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareVertexMergeActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.VertexMerge, ok);" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in
                ("prepareActivate(", "PreparedRecordContext")) and
        "e.vertexWeldActivation.validate();" in context and
        "e.vertexWeldActivation.install();" in context and
        "e.vertexWeldActivation.abort();" in context)
if not vertex_merge_activation_gate(vertex_merge_activation_owner,
                                    record_context, vertex_merge_activation_tool):
    fail("VertexMerge activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is VertexMergeTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder/source capture"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop installer"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "active = true; built = false; dragging = false; dist_ = 0.001f;",
     "active = true; built = false; dragging = false;", "drop distance reset"),
    ("tool", "active = true; built = false; dragging = false; dist_ = 0.001f;",
     "built = false; dragging = false; dist_ = 0.001f;", "drop active reset"),
    ("tool", "active = true; built = false; dragging = false; dist_ = 0.001f;",
     "active = true; dragging = false; dist_ = 0.001f;", "drop built reset"),
    ("tool", "active = true; built = false; dragging = false; dist_ = 0.001f;",
     "active = true; built = false; dist_ = 0.001f;", "drop dragging reset"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot copy"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.prepareVertexMergeActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.VertexMerge, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.VertexMerge, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.VertexMerge, ok);",
     "PreparedActivateKind.VertexMerge, true);", "forge effect acceptance"),
    ("context", "e.vertexWeldActivation.validate();", "true;", "drop validation"),
    ("context", "e.vertexWeldActivation.install();", "", "drop context install"),
    ("context", "e.vertexWeldActivation.abort();", "", "drop context abort"),
):
    o, c, t = vertex_merge_activation_owner, record_context, vertex_merge_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == vertex_merge_activation_owner and c == record_context and
         t == vertex_merge_activation_tool) or vertex_merge_activation_gate(o,c,t)):
        fail(f"VertexMerge activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_vertex_merge_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_vertex_merge_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("VertexMerge activation token copy was not rejected:\n" + run.stdout)

# Exact PolyInset activation uses the same deep-baseline atomic grammar, but
# its closed product/reset/effect are independently mutation-proven.
poly_inset_activation_owner = (ROOT /
    "source/prepared_poly_inset_activation.d").read_text()
poly_inset_activation_tool = (ROOT /
    "source/tools/edit/poly_inset_tool.d").read_text()
def poly_inset_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("version(unittest) final auto preparedOwnerForTest", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedPolyInsetActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is PolyInsetTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in tool and
        "active = true; built = false; dragging = false; inset_ = 0.0f;\n"
        "        image.before.moveInto(before); image.valid = false;" in tool and
        "PreparedPolyInsetActivationOwner.prepare(this)" in producer and
        "context.preparePolyInsetActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.preparePolyInsetActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.PolyInset, ok);" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in
                ("prepareActivate(", "PreparedRecordContext")) and
        "e.polyInsetActivation.validate();" in context and
        "e.polyInsetActivation.install();" in context and
        "e.polyInsetActivation.abort();" in context)
if not poly_inset_activation_gate(poly_inset_activation_owner, record_context,
                                  poly_inset_activation_tool):
    fail("PolyInset activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is PolyInsetTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder/source"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "active = true; built = false; dragging = false; inset_ = 0.0f;",
     "built = false; dragging = false; inset_ = 0.0f;", "drop active reset"),
    ("tool", "active = true; built = false; dragging = false; inset_ = 0.0f;",
     "active = true; dragging = false; inset_ = 0.0f;", "drop built reset"),
    ("tool", "active = true; built = false; dragging = false; inset_ = 0.0f;",
     "active = true; built = false; inset_ = 0.0f;", "drop dragging reset"),
    ("tool", "active = true; built = false; dragging = false; inset_ = 0.0f;",
     "active = true; built = false; dragging = false;", "drop inset reset"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.preparePolyInsetActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.PolyInset, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.PolyInset, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.PolyInset, ok);",
     "PreparedActivateKind.PolyInset, true);", "forge acceptance"),
    ("context", "e.polyInsetActivation.validate();", "true;", "drop validation"),
    ("context", "e.polyInsetActivation.install();", "", "drop context install"),
    ("context", "e.polyInsetActivation.abort();", "", "drop context abort"),
):
    o, c, t = poly_inset_activation_owner, record_context, poly_inset_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == poly_inset_activation_owner and c == record_context and
         t == poly_inset_activation_tool) or poly_inset_activation_gate(o,c,t)):
        fail(f"PolyInset activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_poly_inset_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_poly_inset_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("PolyInset activation token copy was not rejected:\n" + run.stdout)

# Exact PolyExtrude activation additionally owns its selection-derived gizmo
# frame. Pin both the atomic snapshot grammar and the shared legacy/prepared
# formula so a cutover cannot silently move the handle or its extrusion axis.
poly_extrude_activation_owner = (ROOT /
    "source/prepared_poly_extrude_activation.d").read_text()
poly_extrude_activation_tool = (ROOT /
    "source/tools/edit/poly_extrude.d").read_text()
def poly_extrude_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("private void reinitSession()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    install_start = pt.find("final void installPreparedActivation(")
    install_end = pt.find("final PreparedSessionActivateEffect prepareActivate(",
                          install_start)
    installer = pt[install_start:install_end] \
        if install_start >= 0 and install_end > install_start else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    formula = pt[pt.find("private static void computePreparedGizmoFrame"):
        pt.find("public:\n    version(unittest)")]
    return (
        "final class PreparedPolyExtrudeActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is PolyExtrudeTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in tool and
        tool.count("image.anchor = anchor; image.baseAnchor = baseAnchor;\n"
                   "        image.extrudeAxis = extrudeAxis;") == 2 and
        "computePreparedGizmoFrame(*source, image);" in tool and
        "active = true; built = false; dragPart = -1; distance_ = 0.0f;" in installer and
        "image.before.moveInto(before);" in installer and
        "gizmoValid = image.gizmoValid; anchor = image.anchor;" in installer and
        "baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;" in installer and
        "gizmoSelHash = image.gizmoSelHash; image.clear();" in installer and
        "source.selectionSignature(EditMode.Polygons)" in formula and
        "auto opFaces = source.operandFaceMask();" in formula and
        "if (!selected) continue;" in formula and
        "centSum = centSum + c;" in formula and
        "++centN;" in formula and
        "normSum = normSum + source.faceNormal(cast(uint)fi);" in formula and
        "image.anchor = Vec3(centSum.x / centN, centSum.y / centN, centSum.z / centN);" in formula and
        "image.baseAnchor = image.anchor;" in formula and
        "nl > 1e-6f" in formula and
        "normSum * (1.0f / nl) : Vec3(0, 1, 0)" in formula and
        "image.gizmoValid = true;" in formula and
        "PreparedPolyExtrudeActivationOwner.prepare(this)" in producer and
        "context.preparePolyExtrudeActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.preparePolyExtrudeActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.PolyExtrude, ok);" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in
                ("prepareActivate(", "PreparedRecordContext")) and
        "e.polyExtrudeActivation.validate();" in context and
        "e.polyExtrudeActivation.install();" in context and
        "e.polyExtrudeActivation.abort();" in context)
if not poly_extrude_activation_gate(poly_extrude_activation_owner,
                                    record_context, poly_extrude_activation_tool):
    fail("PolyExtrude activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is PolyExtrudeTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder/source"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "active = true; built = false; dragPart = -1; distance_ = 0.0f;",
     "built = false; dragPart = -1; distance_ = 0.0f;", "drop active reset"),
    ("tool", "active = true; built = false; dragPart = -1; distance_ = 0.0f;",
     "active = true; dragPart = -1; distance_ = 0.0f;", "drop built reset"),
    ("tool", "active = true; built = false; dragPart = -1; distance_ = 0.0f;",
     "active = true; built = false; distance_ = 0.0f;", "drop drag reset"),
    ("tool", "active = true; built = false; dragPart = -1; distance_ = 0.0f;",
     "active = true; built = false; dragPart = -1;", "drop distance reset"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "image.anchor = anchor; image.baseAnchor = baseAnchor;\n"
     "        image.extrudeAxis = extrudeAxis;", "", "drop invalid-frame preservation"),
    ("tool", "image.before.moveInto(before);\n"
     "        gizmoValid = image.gizmoValid; anchor = image.anchor;",
     "image.before.moveInto(before);\n        anchor = image.anchor;", "drop gizmo validity"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;",
     "gizmoValid = image.gizmoValid;", "drop anchor"),
    ("tool", "image.before.moveInto(before);\n"
     "        gizmoValid = image.gizmoValid; anchor = image.anchor;\n"
     "        baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;",
     "image.before.moveInto(before);\n"
     "        gizmoValid = image.gizmoValid; anchor = image.anchor;\n"
     "        baseAnchor = image.baseAnchor;", "drop axis"),
    ("tool", "baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;",
     "extrudeAxis = image.extrudeAxis;", "drop base anchor"),
    ("tool", "baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;\n"
     "        gizmoSelHash = image.gizmoSelHash; image.clear();",
     "baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;\n"
     "        image.clear();", "drop selection hash"),
    ("tool", "auto opFaces = source.operandFaceMask();", "auto opFaces = source.selectedFaces;", "change operand set"),
    ("tool", "centSum = centSum + c;", "", "drop centroid accumulation"),
    ("tool", "normSum = normSum + source.faceNormal(cast(uint)fi);", "", "drop normal accumulation"),
    ("tool", "++centN;", "", "drop centroid divisor count"),
    ("tool", "if (!selected) continue;", "", "drop operand guard"),
    ("tool", "nl > 1e-6f", "nl >= 0", "drop fallback threshold"),
    ("tool", ": Vec3(0, 1, 0)", ": Vec3(1, 0, 0)", "change fallback axis"),
    ("tool", "image.gizmoValid = true;", "", "drop valid seal"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.preparePolyExtrudeActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.PolyExtrude, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.PolyExtrude, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.PolyExtrude, ok);",
     "PreparedActivateKind.PolyExtrude, true);", "forge effect acceptance"),
    ("context", "e.polyExtrudeActivation.validate();", "true;", "drop validation"),
    ("context", "e.polyExtrudeActivation.install();", "", "drop context install"),
    ("context", "e.polyExtrudeActivation.abort();", "", "drop context abort"),
):
    o, c, t = poly_extrude_activation_owner, record_context, poly_extrude_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else:
        if label == "drop failure cleanup":
            start = t.find("final PreparedSessionActivateEffect prepareActivate(")
            pos = t.find(old, start)
            t = t[:pos] + new + t[pos + len(old):]
        else:
            t = t.replace(old, new, 1)
    if ((o == poly_extrude_activation_owner and c == record_context and
         t == poly_extrude_activation_tool) or poly_extrude_activation_gate(o,c,t)):
        fail(f"PolyExtrude activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_poly_extrude_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_poly_extrude_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("PolyExtrude activation token copy was not rejected:\n" + run.stdout)

# Exact SmoothShift activation owns the cage baseline and its five-vector
# selection frame while preserving all five preset/sticky parameter fields.
smooth_shift_activation_owner = (ROOT /
    "source/prepared_smooth_shift_activation.d").read_text()
smooth_shift_activation_tool = (ROOT /
    "source/tools/deform/smooth_shift_tool.d").read_text()
def smooth_shift_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("private void reinitSession()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    install_start = pt.find("final void installPreparedActivation(")
    install_end = pt.find("final PreparedSessionActivateEffect prepareActivate(",
                          install_start)
    installer = pt[install_start:install_end] \
        if install_start >= 0 and install_end > install_start else ""
    formula_start = pt.find("private static void computePreparedGizmoFrame")
    formula_end = pt.find("void rebuildPreview()", formula_start)
    formula = pt[formula_start:formula_end] \
        if formula_start >= 0 and formula_end > formula_start else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedSmoothShiftActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is SmoothShiftTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in tool and
        tool.count("image.gizmoValid = gizmoValid; image.anchor = anchor;") == 3 and
        tool.count("image.baseAnchor = baseAnchor; image.offsetAxis = offsetAxis;") == 3 and
        tool.count("image.scaleAxis = scaleAxis; image.gizmoSelHash = gizmoSelHash;") == 3 and
        "active = true; built = false; dragPart = -1;" in installer and
        "image.before.moveInto(before);" in installer and
        "gizmoValid = image.gizmoValid; anchor = image.anchor;" in installer and
        "baseAnchor = image.baseAnchor; offsetAxis = image.offsetAxis;" in installer and
        "scaleAxis = image.scaleAxis; gizmoSelHash = image.gizmoSelHash;" in installer and
        "image.clear();" in installer and
        not any(re.search(r"\b" + field + r"\s*=", installer) for field in
                ("shift_", "scale_", "maxAngle_", "thicken_", "sharp_")) and
        "if (source.faces.length == 0) return;" in formula and
        "bool any = source.hasAnySelectedFaces();" in formula and
        "if (any && !source.isFaceSelected(fi)) continue;" in formula and
        "image.anchor = Vec3(0,0,0);" in formula and
        "sum = sum + source.faceNormal(cast(uint)fi);" in formula and
        "image.anchor = image.anchor + source.faceCentroid(cast(uint)fi);" in formula and
        "++cnt;" in formula and "if (cnt == 0) return;" in formula and
        "image.anchor = image.anchor * (1.0f / cast(float)cnt);" in formula and
        "image.offsetAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);" in formula and
        "abs(image.offsetAxis.y) < 0.9f" in formula and
        "image.scaleAxis = (slen > 1e-6f) ?\n"
        "            side * (1.0f/slen) : Vec3(1,0,0);" in formula and
        "image.baseAnchor = image.anchor;" in formula and
        "source.selectionSignature(EditMode.Polygons)" in formula and
        "image.gizmoValid = true;" in formula and
        "PreparedSmoothShiftActivationOwner.prepare(this)" in producer and
        "context.prepareSmoothShiftActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareSmoothShiftActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.SmoothShift, ok);" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in
                ("prepareActivate(", "PreparedRecordContext")) and
        "e.smoothShiftActivation.validate();" in context and
        "e.smoothShiftActivation.install();" in context and
        "e.smoothShiftActivation.abort();" in context)
if not smooth_shift_activation_gate(smooth_shift_activation_owner,
                                    record_context, smooth_shift_activation_tool):
    fail("SmoothShift activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is SmoothShiftTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "image.gizmoValid = gizmoValid; image.anchor = anchor;", "", "drop frame seed"),
    ("tool", "active = true; built = false; dragPart = -1;", "built = false; dragPart = -1;", "drop active reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; dragPart = -1;", "drop built reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; built = false;", "drop drag reset"),
    ("tool", "active = true; built = false; dragPart = -1;",
     "active = true; built = false; dragPart = -1; shift_ = 0;", "reset shift preset"),
    ("tool", "active = true; built = false; dragPart = -1;",
     "active = true; built = false; dragPart = -1; scale_ = 1;", "reset scale preset"),
    ("tool", "active = true; built = false; dragPart = -1;",
     "active = true; built = false; dragPart = -1; maxAngle_ = 89.5f;", "reset angle preset"),
    ("tool", "active = true; built = false; dragPart = -1;",
     "active = true; built = false; dragPart = -1; thicken_ = false;", "reset thicken preset"),
    ("tool", "active = true; built = false; dragPart = -1;",
     "active = true; built = false; dragPart = -1; sharp_ = false;", "reset sharp preset"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "image.before.moveInto(before);\n"
     "        gizmoValid = image.gizmoValid; anchor = image.anchor;",
     "image.before.moveInto(before);\n        anchor = image.anchor;", "drop gizmo validity"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;", "gizmoValid = image.gizmoValid;", "drop anchor"),
    ("tool", "baseAnchor = image.baseAnchor; offsetAxis = image.offsetAxis;", "offsetAxis = image.offsetAxis;", "drop base anchor"),
    ("tool", "baseAnchor = image.baseAnchor; offsetAxis = image.offsetAxis;",
     "baseAnchor = image.baseAnchor;", "drop offset axis"),
    ("tool", "scaleAxis = image.scaleAxis; gizmoSelHash = image.gizmoSelHash;", "gizmoSelHash = image.gizmoSelHash;", "drop scale axis"),
    ("tool", "scaleAxis = image.scaleAxis; gizmoSelHash = image.gizmoSelHash;",
     "scaleAxis = image.scaleAxis;", "drop selection hash"),
    ("tool", "if (source.faces.length == 0) return;", "", "drop empty branch"),
    ("tool", "bool any = source.hasAnySelectedFaces();",
     "bool any = true;", "change empty-selection law"),
    ("tool", "if (any && !source.isFaceSelected(fi)) continue;", "", "drop selection guard"),
    ("tool", "++cnt;", "", "drop divisor count"),
    ("tool", "image.offsetAxis = (len > 1e-6f)",
     "image.offsetAxis = (len >= 0)", "drop normal fallback threshold"),
    ("tool", "abs(image.offsetAxis.y) < 0.9f", "false", "change side reference"),
    ("tool", "image.scaleAxis = (slen > 1e-6f)",
     "image.scaleAxis = (slen >= 0)", "drop side fallback threshold"),
    ("tool", "image.gizmoValid = true;", "", "drop valid seal"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.prepareSmoothShiftActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.SmoothShift, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.SmoothShift, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.SmoothShift, ok);",
     "PreparedActivateKind.SmoothShift, true);", "forge acceptance"),
    ("context", "e.smoothShiftActivation.validate();", "true;", "drop validation"),
    ("context", "e.smoothShiftActivation.install();", "", "drop context install"),
    ("context", "e.smoothShiftActivation.abort();", "", "drop context abort"),
):
    o, c, t = smooth_shift_activation_owner, record_context, smooth_shift_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == smooth_shift_activation_owner and c == record_context and
         t == smooth_shift_activation_tool) or smooth_shift_activation_gate(o,c,t)):
        fail(f"SmoothShift activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_smooth_shift_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_smooth_shift_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("SmoothShift activation token copy was not rejected:\n" + run.stdout)

# Exact EdgeBevel activation also resets its private PreviewRebuild scratch;
# that destructive release belongs only to install, never detached prepare.
edge_bevel_activation_owner = (ROOT /
    "source/prepared_edge_bevel_activation.d").read_text()
edge_bevel_activation_tool = (ROOT /
    "source/tools/edit/edge_bevel.d").read_text()
preview_rebuild_source = (ROOT /
    "source/tools/edit/preview_rebuild.d").read_text()
def edge_bevel_activation_gate(owner, context, tool, preview):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("private void reinitSession()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    bstart = pt.find("final PreparedEdgeBevelActivationImage buildPreparedActivation(")
    bend = pt.find("final Mesh* preparedActivationMesh()", bstart)
    builder = pt[bstart:bend] if bstart >= 0 and bend > bstart else ""
    istart = pt.find("final void installPreparedActivation(")
    iend = pt.find("final PreparedSessionActivateEffect prepareActivate(", istart)
    installer = pt[istart:iend] if istart >= 0 and iend > istart else ""
    fstart = pt.find("private static void computePreparedGizmoFrame")
    fend = pt.find("void rebuildPreview()", fstart)
    formula = pt[fstart:fend] if fstart >= 0 and fend > fstart else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedEdgeBevelActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is EdgeBevelTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in tool and
        "preview_.reset()" not in builder and
        tool.count("image.gizmoValid = gizmoValid; image.anchor = anchor;") == 3 and
        tool.count("image.baseAnchor = baseAnchor; image.widthAxis = widthAxis;") == 3 and
        tool.count("image.gizmoSelHash = gizmoSelHash;") == 3 and
        "active = true; built = false; dragPart = -1; width_ = 0.0f;" in installer and
        "preview_.reset(); image.before.moveInto(before);" in installer and
        "gizmoValid = image.gizmoValid; anchor = image.anchor;" in installer and
        "baseAnchor = image.baseAnchor; widthAxis = image.widthAxis;" in installer and
        "gizmoSelHash = image.gizmoSelHash; image.clear();" in installer and
        not re.search(r"\b(roundLevel_|widthMode_)\s*=", installer) and
        "void reset() nothrow @nogc" in preview and
        "hasLast_      = false;" in preview and
        "last_         = PreviewTopologyKey.init;" in preview and
        "lastTopology_ = 0;" in preview and
        "cage_         = Mesh.init;" in preview and
        "if (source.edges.length == 0) return;" in formula and
        "image.anchor = source.selectionCentroidEdges();" in formula and
        "bool any = source.hasAnySelectedEdges();" in formula and
        "if (!source.isEdgeSelected(ei)) continue;" in formula and
        "if ((a==u&&b==w)||(a==w&&b==u))" in formula and
        "if (adj) sum = sum + source.faceNormal(cast(uint)fi);" in formula and
        "sum = sum + source.faceNormal(cast(uint)fi);" in formula and
        "image.widthAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);" in formula and
        "image.baseAnchor = image.anchor;" in formula and
        "source.selectionSignature(EditMode.Edges)" in formula and
        "image.gizmoValid = true;" in formula and
        "PreparedEdgeBevelActivationOwner.prepare(this)" in producer and
        "context.prepareEdgeBevelActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareEdgeBevelActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.EdgeBevel, ok);" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in
                ("prepareActivate(", "PreparedRecordContext")) and
        "e.edgeBevelActivation.validate();" in context and
        "e.edgeBevelActivation.install();" in context and
        "e.edgeBevelActivation.abort();" in context)
if not edge_bevel_activation_gate(edge_bevel_activation_owner, record_context,
                                  edge_bevel_activation_tool,
                                  preview_rebuild_source):
    fail("EdgeBevel activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is EdgeBevelTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "preview_.reset(); image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "clear preview scratch during prepare"),
    ("tool", "image.gizmoValid = gizmoValid; image.anchor = anchor;", "", "drop frame seed"),
    ("tool", "active = true; built = false; dragPart = -1; width_ = 0.0f;",
     "built = false; dragPart = -1; width_ = 0.0f;", "drop active reset"),
    ("tool", "active = true; built = false; dragPart = -1; width_ = 0.0f;",
     "active = true; dragPart = -1; width_ = 0.0f;", "drop built reset"),
    ("tool", "active = true; built = false; dragPart = -1; width_ = 0.0f;",
     "active = true; built = false; width_ = 0.0f;", "drop drag reset"),
    ("tool", "active = true; built = false; dragPart = -1; width_ = 0.0f;",
     "active = true; built = false; dragPart = -1;", "drop width reset"),
    ("tool", "active = true; built = false; dragPart = -1; width_ = 0.0f;",
     "active = true; built = false; dragPart = -1; width_ = 0.0f; roundLevel_ = 0;", "reset round preset"),
    ("tool", "active = true; built = false; dragPart = -1; width_ = 0.0f;",
     "active = true; built = false; dragPart = -1; width_ = 0.0f; widthMode_ = false;", "reset width mode preset"),
    ("tool", "preview_.reset(); image.before.moveInto(before);",
     "image.before.moveInto(before);", "retain preview scratch"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;",
     "anchor = image.anchor;", "drop gizmo validity"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;",
     "gizmoValid = image.gizmoValid;", "drop anchor"),
    ("tool", "baseAnchor = image.baseAnchor; widthAxis = image.widthAxis;",
     "widthAxis = image.widthAxis;", "drop base anchor"),
    ("tool", "baseAnchor = image.baseAnchor; widthAxis = image.widthAxis;",
     "baseAnchor = image.baseAnchor;", "drop width axis"),
    ("tool", "gizmoSelHash = image.gizmoSelHash; image.clear();",
     "image.clear();", "drop selection hash"),
    ("tool", "bool any = source.hasAnySelectedEdges();", "bool any = false;", "drop selected-edge branch"),
    ("tool", "if (!source.isEdgeSelected(ei)) continue;", "", "drop selected-edge guard"),
    ("tool", "len > 1e-6f", "len >= 0", "drop axis fallback threshold"),
    ("tool", "image.gizmoValid = true;", "", "drop valid seal"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.prepareEdgeBevelActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.EdgeBevel, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.EdgeBevel, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.EdgeBevel, ok);",
     "PreparedActivateKind.EdgeBevel, true);", "forge effect acceptance"),
    ("context", "e.edgeBevelActivation.validate();", "true;", "drop validation"),
    ("context", "e.edgeBevelActivation.install();", "", "drop context install"),
    ("context", "e.edgeBevelActivation.abort();", "", "drop context abort"),
    ("preview", "void reset() nothrow @nogc", "void reset()", "weaken reset attributes"),
    ("preview", "hasLast_      = false;", "", "retain last-key flag"),
    ("preview", "last_         = PreviewTopologyKey.init;", "", "retain last topology key"),
    ("preview", "lastTopology_ = 0;", "", "retain last topology digest"),
    ("preview", "cage_         = Mesh.init;", "", "retain preview cage"),
):
    o, c, t, p = (edge_bevel_activation_owner, record_context,
                  edge_bevel_activation_tool, preview_rebuild_source)
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    elif target == "preview": p = p.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == edge_bevel_activation_owner and c == record_context and
         t == edge_bevel_activation_tool and p == preview_rebuild_source) or
        edge_bevel_activation_gate(o,c,t,p)):
        fail(f"EdgeBevel activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_edge_bevel_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_edge_bevel_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("EdgeBevel activation token copy was not rejected:\n" + run.stdout)

# Exact PolyBevel activation detaches the undo baseline and polygon gizmo
# frame while preserving the user's group/segments/square presets.
poly_bevel_activation_owner = (ROOT /
    "source/prepared_poly_bevel_activation.d").read_text()
poly_bevel_activation_tool = (ROOT /
    "source/tools/edit/poly_bevel.d").read_text()
def poly_bevel_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("private void reinitSession()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    bstart = pt.find("final PreparedPolyBevelActivationImage buildPreparedActivation(")
    bend = pt.find("final Mesh* preparedActivationMesh()", bstart)
    builder = pt[bstart:bend] if bstart >= 0 and bend > bstart else ""
    istart = pt.find("final void installPreparedActivation(")
    iend = pt.find("final PreparedSessionActivateEffect prepareActivate(", istart)
    installer = pt[istart:iend] if istart >= 0 and iend > istart else ""
    fstart = pt.find("private static void computePreparedGizmoFrame")
    fend = pt.find("void rebuildPreview()", fstart)
    formula = pt[fstart:fend] if fstart >= 0 and fend > fstart else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedPolyBevelActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is PolyBevelTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in tool and
        "preview_.reset()" not in builder and
        tool.count("image.gizmoValid = gizmoValid; image.anchor = anchor;") == 3 and
        tool.count("image.baseAnchor = baseAnchor; image.shiftAxis = shiftAxis;") == 3 and
        tool.count("image.insetAxis = insetAxis; image.gizmoSelHash = gizmoSelHash;") == 3 and
        "active = true; built = false; dragPart = -1;" in installer and
        "inset_ = 0.0f; shift_ = 0.0f;" in installer and
        "preview_.reset(); image.before.moveInto(before);" in installer and
        "gizmoValid = image.gizmoValid; anchor = image.anchor;" in installer and
        "baseAnchor = image.baseAnchor; shiftAxis = image.shiftAxis;" in installer and
        "insetAxis = image.insetAxis; gizmoSelHash = image.gizmoSelHash;" in installer and
        "image.clear();" in installer and
        not re.search(r"\b(group_|segments_|square_)\s*=", installer) and
        "image.gizmoValid = false;" in formula and
        "if (source.faces.length == 0) return;" in formula and
        "bool any = source.hasAnySelectedFaces();" in formula and
        "image.anchor = Vec3(0,0,0);" in formula and
        "if (any && !source.isFaceSelected(fi)) continue;" in formula and
        "sum = sum + source.faceNormal(cast(uint)fi);" in formula and
        "image.anchor = image.anchor + source.faceCentroid(cast(uint)fi);" in formula and
        "if (cnt == 0) return;" in formula and
        "image.anchor = image.anchor * (1.0f / cast(float)cnt);" in formula and
        "image.shiftAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);" in formula and
        "Vec3 up = (abs(image.shiftAxis.y) < 0.9f) ? Vec3(0,1,0) : Vec3(1,0,0);" in formula and
        "image.insetAxis = (slen > 1e-6f) ? side * (1.0f/slen) : Vec3(1,0,0);" in formula and
        "image.baseAnchor = image.anchor;" in formula and
        "source.selectionSignature(EditMode.Polygons)" in formula and
        "image.gizmoValid = true;" in formula and
        "PreparedPolyBevelActivationOwner.prepare(this)" in producer and
        "context.preparePolyBevelActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.preparePolyBevelActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.PolyBevel, ok);" in producer and
        not any(x in producer for x in
                ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in
                ("prepareActivate(", "PreparedRecordContext")) and
        "e.polyBevelActivation.validate();" in context and
        "e.polyBevelActivation.install();" in context and
        "e.polyBevelActivation.abort();" in context)
if not poly_bevel_activation_gate(poly_bevel_activation_owner, record_context,
                                  poly_bevel_activation_tool):
    fail("PolyBevel activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is PolyBevelTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "preview_.reset(); image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "clear preview during prepare"),
    ("tool", "image.gizmoValid = gizmoValid; image.anchor = anchor;", "", "drop frame seed"),
    ("tool", "active = true; built = false; dragPart = -1;", "built = false; dragPart = -1;", "drop active reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; dragPart = -1;", "drop built reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; built = false;", "drop drag reset"),
    ("tool", "inset_ = 0.0f; shift_ = 0.0f;", "shift_ = 0.0f;", "drop inset reset"),
    ("tool", "inset_ = 0.0f; shift_ = 0.0f;", "inset_ = 0.0f;", "drop shift reset"),
    ("tool", "inset_ = 0.0f; shift_ = 0.0f;", "inset_ = 0.0f; shift_ = 0.0f; group_ = true;", "reset group preset"),
    ("tool", "inset_ = 0.0f; shift_ = 0.0f;", "inset_ = 0.0f; shift_ = 0.0f; segments_ = 0;", "reset segments preset"),
    ("tool", "inset_ = 0.0f; shift_ = 0.0f;", "inset_ = 0.0f; shift_ = 0.0f; square_ = false;", "reset square preset"),
    ("tool", "preview_.reset(); image.before.moveInto(before);", "image.before.moveInto(before);", "retain preview scratch"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;", "anchor = image.anchor;", "drop validity"),
    ("tool", "baseAnchor = image.baseAnchor; shiftAxis = image.shiftAxis;", "shiftAxis = image.shiftAxis;", "drop base anchor"),
    ("tool", "insetAxis = image.insetAxis; gizmoSelHash = image.gizmoSelHash;", "gizmoSelHash = image.gizmoSelHash;", "drop inset axis"),
    ("tool", "insetAxis = image.insetAxis; gizmoSelHash = image.gizmoSelHash;", "insetAxis = image.insetAxis;", "drop selection hash"),
    ("tool", "bool any = source.hasAnySelectedFaces();", "bool any = false;", "drop selected-face branch"),
    ("tool", "if (any && !source.isFaceSelected(fi)) continue;", "", "drop selected-face guard"),
    ("tool", "if (cnt == 0) return;", "", "drop empty-selection guard"),
    ("tool", "image.shiftAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);",
     "image.shiftAxis = (len >= 0) ? sum * (1.0f/len) : Vec3(0,1,0);",
     "drop normal fallback threshold"),
    ("tool", "Vec3 up = (abs(image.shiftAxis.y) < 0.9f) ? Vec3(0,1,0) : Vec3(1,0,0);",
     "Vec3 up = false ? Vec3(0,1,0) : Vec3(1,0,0);", "drop up-axis threshold"),
    ("tool", "image.insetAxis = (slen > 1e-6f) ? side * (1.0f/slen) : Vec3(1,0,0);",
     "image.insetAxis = (slen >= 0) ? side * (1.0f/slen) : Vec3(1,0,0);",
     "drop side fallback threshold"),
    ("tool", "image.gizmoValid = true;", "", "drop valid seal"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.preparePolyBevelActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.PolyBevel, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.PolyBevel, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.PolyBevel, ok);",
     "PreparedActivateKind.PolyBevel, true);", "forge effect acceptance"),
    ("context", "e.polyBevelActivation.validate();", "true;", "drop validation"),
    ("context", "e.polyBevelActivation.install();", "", "drop context install"),
    ("context", "e.polyBevelActivation.abort();", "", "drop context abort"),
):
    o, c, t = poly_bevel_activation_owner, record_context, poly_bevel_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == poly_bevel_activation_owner and c == record_context and
         t == poly_bevel_activation_tool) or poly_bevel_activation_gate(o,c,t)):
        fail(f"PolyBevel activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_poly_bevel_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_poly_bevel_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("PolyBevel activation token copy was not rejected:\n" + run.stdout)

# Exact VertexBevel activation owns its detached baseline and vertex-normal
# gizmo frame; prepare must not touch any live session field.
vertex_bevel_activation_owner = (ROOT /
    "source/prepared_vertex_bevel_activation.d").read_text()
vertex_bevel_activation_tool = (ROOT /
    "source/tools/edit/vertex_bevel_tool.d").read_text()
def vertex_bevel_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("private void reinitSession()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    bstart = pt.find("final PreparedVertexBevelActivationImage buildPreparedActivation(")
    bend = pt.find("final Mesh* preparedActivationMesh()", bstart)
    builder = pt[bstart:bend] if bstart >= 0 and bend > bstart else ""
    istart = pt.find("final void installPreparedActivation(")
    iend = pt.find("final PreparedSessionActivateEffect prepareActivate(", istart)
    installer = pt[istart:iend] if istart >= 0 and iend > istart else ""
    fstart = pt.find("private static void computePreparedGizmoFrame")
    fend = pt.find("void rebuildPreview()", fstart)
    formula = pt[fstart:fend] if fstart >= 0 and fend > fstart else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedVertexBevelActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is VertexBevelTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in builder and
        not re.search(r"(?<!\.)\b(active|built|dragPart|inset_|gizmoValid|anchor|"
                      r"baseAnchor|insetAxis|gizmoSelHash|dragLastMX|dragLastMY|"
                      r"dragBaseInset|cachedVp)\s*=", builder) and
        tool.count("image.gizmoValid = gizmoValid; image.anchor = anchor;") == 3 and
        tool.count("image.baseAnchor = baseAnchor; image.insetAxis = insetAxis;") == 3 and
        "active = true; built = false; dragPart = -1; inset_ = 0.0f;" in installer and
        "image.before.moveInto(before);" in installer and
        "gizmoValid = image.gizmoValid; anchor = image.anchor;" in installer and
        "baseAnchor = image.baseAnchor; insetAxis = image.insetAxis;" in installer and
        "gizmoSelHash = image.gizmoSelHash; image.clear();" in installer and
        "image.gizmoValid = false;" in formula and
        "if (source.vertices.length == 0) return;" in formula and
        "bool any = source.hasAnySelectedVertices();" in formula and
        "if (any && !source.isVertexSelected(vi)) continue;" in formula and
        "source.facesAroundVertex(cast(uint)vi)" in formula and
        "sum = sum + source.faceNormal(cast(uint)fi);" in formula and
        "image.anchor = source.selectionCentroidVertices();" in formula and
        "image.insetAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);" in formula and
        "image.baseAnchor = image.anchor;" in formula and
        "source.selectionSignature(EditMode.Vertices)" in formula and
        "image.gizmoValid = true;" in formula and
        "PreparedVertexBevelActivationOwner.prepare(this)" in producer and
        "context.prepareVertexBevelActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareVertexBevelActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.VertexBevel, ok);" in producer and
        not any(x in producer for x in ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in ("prepareActivate(", "PreparedRecordContext")) and
        "e.vertexBevelActivation.validate();" in context and
        "e.vertexBevelActivation.install();" in context and
        "e.vertexBevelActivation.abort();" in context)
if not vertex_bevel_activation_gate(vertex_bevel_activation_owner,
                                    record_context, vertex_bevel_activation_tool):
    fail("VertexBevel activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is VertexBevelTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "dragLastMX = 0; image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "write live state during prepare"),
    ("tool", "image.gizmoValid = gizmoValid; image.anchor = anchor;", "", "drop frame seed"),
    ("tool", "active = true; built = false; dragPart = -1; inset_ = 0.0f;",
     "built = false; dragPart = -1; inset_ = 0.0f;", "drop active reset"),
    ("tool", "active = true; built = false; dragPart = -1; inset_ = 0.0f;",
     "active = true; dragPart = -1; inset_ = 0.0f;", "drop built reset"),
    ("tool", "active = true; built = false; dragPart = -1; inset_ = 0.0f;",
     "active = true; built = false; inset_ = 0.0f;", "drop drag reset"),
    ("tool", "active = true; built = false; dragPart = -1; inset_ = 0.0f;",
     "active = true; built = false; dragPart = -1;", "drop inset reset"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;", "anchor = image.anchor;", "drop validity"),
    ("tool", "baseAnchor = image.baseAnchor; insetAxis = image.insetAxis;", "insetAxis = image.insetAxis;", "drop base anchor"),
    ("tool", "gizmoSelHash = image.gizmoSelHash; image.clear();", "image.clear();", "drop hash"),
    ("tool", "bool any = source.hasAnySelectedVertices();", "bool any = false;", "drop selection branch"),
    ("tool", "if (any && !source.isVertexSelected(vi)) continue;", "", "drop selection guard"),
    ("tool", "source.facesAroundVertex(cast(uint)vi)", "source.facesAroundVertex(0)", "drop incident vertex"),
    ("tool", "image.insetAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);",
     "image.insetAxis = (len >= 0) ? sum * (1.0f/len) : Vec3(0,1,0);", "drop fallback threshold"),
    ("tool", "image.gizmoValid = true;", "", "drop valid seal"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.prepareVertexBevelActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.VertexBevel, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.VertexBevel, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.VertexBevel, ok);",
     "PreparedActivateKind.VertexBevel, true);", "forge effect acceptance"),
    ("context", "e.vertexBevelActivation.validate();", "true;", "drop validation"),
    ("context", "e.vertexBevelActivation.install();", "", "drop context install"),
    ("context", "e.vertexBevelActivation.abort();", "", "drop context abort"),
):
    o, c, t = vertex_bevel_activation_owner, record_context, vertex_bevel_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == vertex_bevel_activation_owner and c == record_context and
         t == vertex_bevel_activation_tool) or vertex_bevel_activation_gate(o,c,t)):
        fail(f"VertexBevel activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_vertex_bevel_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_vertex_bevel_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("VertexBevel activation token copy was not rejected:\n" + run.stdout)

# Exact VertexExtrude activation detaches the baseline and the two-axis
# vertex-normal frame while preserving every drag/viewport field.
vertex_extrude_activation_owner = (ROOT /
    "source/prepared_vertex_extrude_activation.d").read_text()
vertex_extrude_activation_tool = (ROOT /
    "source/tools/edit/vertex_extrude_tool.d").read_text()
def vertex_extrude_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("private void reinitSession()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    bstart = pt.find("final PreparedVertexExtrudeActivationImage buildPreparedActivation(")
    bend = pt.find("final Mesh* preparedActivationMesh()", bstart)
    builder = pt[bstart:bend] if bstart >= 0 and bend > bstart else ""
    istart = pt.find("final void installPreparedActivation(")
    iend = pt.find("final PreparedSessionActivateEffect prepareActivate(", istart)
    installer = pt[istart:iend] if istart >= 0 and iend > istart else ""
    fstart = pt.find("private static void computePreparedGizmoFrame")
    fend = pt.find("void rebuildPreview()", fstart)
    formula = pt[fstart:fend] if fstart >= 0 and fend > fstart else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedVertexExtrudeActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is VertexExtrudeTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in builder and
        not re.search(r"(?<!\.)\b(active|built|dragPart|shift_|width_|gizmoValid|"
                      r"anchor|baseAnchor|shiftAxis|widthAxis|gizmoSelHash|"
                      r"dragLastMX|dragLastMY|dragBaseShift|dragBaseWidth|cachedVp)\s*=", builder) and
        tool.count("image.gizmoValid = gizmoValid; image.anchor = anchor;") == 3 and
        tool.count("image.baseAnchor = baseAnchor; image.shiftAxis = shiftAxis;") == 3 and
        tool.count("image.widthAxis = widthAxis; image.gizmoSelHash = gizmoSelHash;") == 3 and
        "active = true; built = false; dragPart = -1;" in installer and
        "shift_ = 0.0f; width_ = 0.0f;" in installer and
        "image.before.moveInto(before);" in installer and
        "gizmoValid = image.gizmoValid; anchor = image.anchor;" in installer and
        "baseAnchor = image.baseAnchor; shiftAxis = image.shiftAxis;" in installer and
        "widthAxis = image.widthAxis; gizmoSelHash = image.gizmoSelHash;" in installer and
        "image.clear();" in installer and
        "image.gizmoValid = false;" in formula and
        "if (source.vertices.length == 0) return;" in formula and
        "bool any = source.hasAnySelectedVertices();" in formula and
        "if (any && !source.isVertexSelected(vi)) continue;" in formula and
        "source.facesAroundVertex(cast(uint)vi)" in formula and
        "sum = sum + source.faceNormal(cast(uint)fi);" in formula and
        "image.anchor = source.selectionCentroidVertices();" in formula and
        "image.shiftAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);" in formula and
        "Vec3 up = (abs(image.shiftAxis.y) < 0.9f) ? Vec3(0,1,0) : Vec3(1,0,0);" in formula and
        "Vec3 side = cross(image.shiftAxis, up);" in formula and
        "image.widthAxis = (slen > 1e-6f) ? side * (1.0f/slen) : Vec3(1,0,0);" in formula and
        "image.baseAnchor = image.anchor;" in formula and
        "source.selectionSignature(EditMode.Vertices)" in formula and
        "image.gizmoValid = true;" in formula and
        "PreparedVertexExtrudeActivationOwner.prepare(this)" in producer and
        "context.prepareVertexExtrudeActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareVertexExtrudeActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.VertexExtrude, ok);" in producer and
        not any(x in producer for x in ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in ("prepareActivate(", "PreparedRecordContext")) and
        "e.vertexExtrudeActivation.validate();" in context and
        "e.vertexExtrudeActivation.install();" in context and
        "e.vertexExtrudeActivation.abort();" in context)
if not vertex_extrude_activation_gate(vertex_extrude_activation_owner,
                                      record_context, vertex_extrude_activation_tool):
    fail("VertexExtrude activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is VertexExtrudeTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "dragLastMX = 0; image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "write live state during prepare"),
    ("tool", "image.gizmoValid = gizmoValid; image.anchor = anchor;", "", "drop frame seed"),
    ("tool", "active = true; built = false; dragPart = -1;", "built = false; dragPart = -1;", "drop active reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; dragPart = -1;", "drop built reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; built = false;", "drop drag reset"),
    ("tool", "shift_ = 0.0f; width_ = 0.0f;", "width_ = 0.0f;", "drop shift reset"),
    ("tool", "shift_ = 0.0f; width_ = 0.0f;", "shift_ = 0.0f;", "drop width reset"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;", "anchor = image.anchor;", "drop validity"),
    ("tool", "baseAnchor = image.baseAnchor; shiftAxis = image.shiftAxis;", "shiftAxis = image.shiftAxis;", "drop base anchor"),
    ("tool", "baseAnchor = image.baseAnchor; shiftAxis = image.shiftAxis;", "baseAnchor = image.baseAnchor;", "drop shift axis"),
    ("tool", "widthAxis = image.widthAxis; gizmoSelHash = image.gizmoSelHash;", "gizmoSelHash = image.gizmoSelHash;", "drop width axis"),
    ("tool", "widthAxis = image.widthAxis; gizmoSelHash = image.gizmoSelHash;", "widthAxis = image.widthAxis;", "drop hash"),
    ("tool", "bool any = source.hasAnySelectedVertices();", "bool any = false;", "drop selection branch"),
    ("tool", "if (any && !source.isVertexSelected(vi)) continue;", "", "drop selection guard"),
    ("tool", "source.facesAroundVertex(cast(uint)vi)", "source.facesAroundVertex(0)", "drop incident vertex"),
    ("tool", "image.shiftAxis = (len > 1e-6f) ? sum * (1.0f/len) : Vec3(0,1,0);",
     "image.shiftAxis = (len >= 0) ? sum * (1.0f/len) : Vec3(0,1,0);", "drop shift fallback"),
    ("tool", "Vec3 up = (abs(image.shiftAxis.y) < 0.9f) ? Vec3(0,1,0) : Vec3(1,0,0);",
     "Vec3 up = false ? Vec3(0,1,0) : Vec3(1,0,0);", "drop up threshold"),
    ("tool", "image.widthAxis = (slen > 1e-6f) ? side * (1.0f/slen) : Vec3(1,0,0);",
     "image.widthAxis = (slen >= 0) ? side * (1.0f/slen) : Vec3(1,0,0);", "drop width fallback"),
    ("tool", "image.gizmoValid = true;", "", "drop valid seal"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.prepareVertexExtrudeActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.VertexExtrude, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.VertexExtrude, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.VertexExtrude, ok);",
     "PreparedActivateKind.VertexExtrude, true);", "forge effect acceptance"),
    ("context", "e.vertexExtrudeActivation.validate();", "true;", "drop validation"),
    ("context", "e.vertexExtrudeActivation.install();", "", "drop context install"),
    ("context", "e.vertexExtrudeActivation.abort();", "", "drop context abort"),
):
    o, c, t = vertex_extrude_activation_owner, record_context, vertex_extrude_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == vertex_extrude_activation_owner and c == record_context and
         t == vertex_extrude_activation_tool) or vertex_extrude_activation_gate(o,c,t)):
        fail(f"VertexExtrude activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_vertex_extrude_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_vertex_extrude_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("VertexExtrude activation token copy was not rejected:\n" + run.stdout)

edge_extrude_activation_owner = (ROOT /
    "source/prepared_edge_extrude_activation.d").read_text()
edge_extrude_activation_tool = (ROOT /
    "source/tools/edit/edge_extrude.d").read_text()
def edge_extrude_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("private void reinitSession()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    bstart = pt.find("final PreparedEdgeExtrudeActivationImage buildPreparedActivation(")
    bend = pt.find("final Mesh* preparedActivationMesh()", bstart)
    builder = pt[bstart:bend] if bstart >= 0 and bend > bstart else ""
    istart = pt.find("final void installPreparedActivation(")
    iend = pt.find("final PreparedSessionActivateEffect prepareActivate(", istart)
    installer = pt[istart:iend] if istart >= 0 and iend > istart else ""
    fstart = pt.find("private static void computePreparedGizmoFrame")
    fend = len(pt)
    formula = pt[fstart:fend] if fstart >= 0 and fend > fstart else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedEdgeExtrudeActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is EdgeExtrudeTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "Mesh* delegate() nothrow @nogc meshSrc_;" in tool and
        "image.before = MeshSnapshot.capture(*source); image.valid = true;" in builder and
        not re.search(r"(?<!\.)\b(active|built|dragPart|extrude_|width_|gizmoValid|"
                      r"anchor|baseAnchor|extrudeAxis|widthAxis|gizmoSelHash|"
                      r"dragLastMX|dragLastMY|dragStartMX|dragStartMY|"
                      r"dragBaseExtrude|dragBaseWidth|freeLockAxis|cachedVp)\s*=", builder) and
        tool.count("image.gizmoValid = gizmoValid; image.anchor = anchor;") == 3 and
        tool.count("image.baseAnchor = baseAnchor; image.extrudeAxis = extrudeAxis;") == 3 and
        tool.count("image.widthAxis = widthAxis; image.gizmoSelHash = gizmoSelHash;") == 3 and
        "active = true; built = false; dragPart = -1;" in installer and
        "extrude_ = 0.0f; width_ = 0.0f;" in installer and
        "image.before.moveInto(before);" in installer and
        "gizmoValid = image.gizmoValid; anchor = image.anchor;" in installer and
        "baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;" in installer and
        "widthAxis = image.widthAxis; gizmoSelHash = image.gizmoSelHash;" in installer and
        "image.gizmoValid = false;" in formula and
        "image.gizmoSelHash = source.selectionSignature(EditMode.Edges);" in formula and
        "if (source.edges.length == 0) return;" in formula and
        "auto opEdges = source.operandEdgeMask();" in formula and
        "bool selected = i < opEdges.length && opEdges[i];" in formula and
        "if (!selected) continue;" in formula and
        "centSum = centSum + pa + pb;" in formula and "centN  += 2;" in formula and
        "preparedEdgeAveragedNormal(source, cast(uint)i)" in formula and
        "if (tl > 1e-6f)" in formula and "Vec3 inward = cross(ne, t);" in formula and
        "if (il > 1e-6f) insetSum = insetSum + (inward / il);" in formula and
        "if (centN == 0) return;" in formula and
        "image.anchor = Vec3(centSum.x / centN, centSum.y / centN, centSum.z / centN);" in formula and
        "image.baseAnchor = image.anchor;" in formula and
        "image.extrudeAxis = (nl > 1e-6f) ? (normSum / nl) : Vec3(0, 1, 0);" in formula and
        "Vec3 w = insetSum - image.extrudeAxis * dot(insetSum, image.extrudeAxis);" in formula and
        "if (wl > 1e-6f)" in formula and "image.widthAxis = w / wl;" in formula and
        "abs(image.extrudeAxis.x) < 0.9f" in formula and
        "image.widthAxis = (pl > 1e-6f) ? (perp / pl) : Vec3(1, 0, 0);" in formula and
        "source.facesAroundEdge(ei)" in formula and
        "return (l > 1e-6f) ? (sum / l) : Vec3(0, 1, 0);" in formula and
        "image.gizmoValid = true;" in formula and
        "PreparedEdgeExtrudeActivationOwner.prepare(this)" in producer and
        "context.prepareEdgeExtrudeActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareEdgeExtrudeActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.EdgeExtrude, ok);" in producer and
        not any(x in producer for x in ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in ("prepareActivate(", "PreparedRecordContext")) and
        "e.edgeExtrudeActivation.validate();" in context and
        "e.edgeExtrudeActivation.install();" in context and
        "e.edgeExtrudeActivation.abort();" in context)
if not edge_extrude_activation_gate(edge_extrude_activation_owner,
                                    record_context, edge_extrude_activation_tool):
    fail("EdgeExtrude activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is EdgeExtrudeTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation(result.source_);", "", "drop builder"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content guard"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null; source_ = null;", "target_ = null;", "retain payload"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "", "drop snapshot"),
    ("tool", "image.before = MeshSnapshot.capture(*source); image.valid = true;",
     "dragLastMX = 0; image.before = MeshSnapshot.capture(*source); image.valid = true;", "write live during prepare"),
    ("tool", "image.gizmoValid = gizmoValid; image.anchor = anchor;", "", "drop frame seed"),
    ("tool", "active = true; built = false; dragPart = -1;", "built = false; dragPart = -1;", "drop active reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; dragPart = -1;", "drop built reset"),
    ("tool", "active = true; built = false; dragPart = -1;", "active = true; built = false;", "drop drag reset"),
    ("tool", "extrude_ = 0.0f; width_ = 0.0f;", "width_ = 0.0f;", "drop extrude reset"),
    ("tool", "extrude_ = 0.0f; width_ = 0.0f;", "extrude_ = 0.0f;", "drop width reset"),
    ("tool", "image.before.moveInto(before);", "before = image.before;", "shallow snapshot"),
    ("tool", "gizmoValid = image.gizmoValid; anchor = image.anchor;", "anchor = image.anchor;", "drop valid install"),
    ("tool", "baseAnchor = image.baseAnchor; extrudeAxis = image.extrudeAxis;", "extrudeAxis = image.extrudeAxis;", "drop base anchor"),
    ("tool", "widthAxis = image.widthAxis; gizmoSelHash = image.gizmoSelHash;", "gizmoSelHash = image.gizmoSelHash;", "drop width axis"),
    ("tool", "image.gizmoSelHash = source.selectionSignature(EditMode.Edges);", "", "drop empty hash law"),
    ("tool", "auto opEdges = source.operandEdgeMask();", "auto opEdges = new bool[](source.edges.length);", "drop operand funnel"),
    ("tool", "if (!selected) continue;", "", "drop operand guard"),
    ("tool", "preparedEdgeAveragedNormal(source, cast(uint)i)", "Vec3(0,1,0)", "drop adjacent normals"),
    ("tool", "if (centN == 0) return;", "", "drop centroid guard"),
    ("tool", "image.extrudeAxis = (nl > 1e-6f) ? (normSum / nl) : Vec3(0, 1, 0);",
     "image.extrudeAxis = (nl >= 0) ? (normSum / nl) : Vec3(0, 1, 0);", "drop normal fallback"),
    ("tool", "Vec3 w = insetSum - image.extrudeAxis * dot(insetSum, image.extrudeAxis);",
     "Vec3 w = insetSum;", "drop width orthogonalization"),
    ("tool", "if (wl > 1e-6f)", "if (wl >= 0)", "drop width fallback"),
    ("tool", "abs(image.extrudeAxis.x) < 0.9f", "false", "drop perpendicular choice"),
    ("tool", "image.gizmoValid = true;", "", "drop valid seal"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.prepareEdgeExtrudeActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.EdgeExtrude, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.EdgeExtrude, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.EdgeExtrude, ok);", "PreparedActivateKind.EdgeExtrude, true);", "forge acceptance"),
    ("context", "e.edgeExtrudeActivation.validate();", "true;", "drop validation"),
    ("context", "e.edgeExtrudeActivation.install();", "", "drop context install"),
    ("context", "e.edgeExtrudeActivation.abort();", "", "drop context abort"),
):
    o, c, t = edge_extrude_activation_owner, record_context, edge_extrude_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == edge_extrude_activation_owner and c == record_context and
         t == edge_extrude_activation_tool) or edge_extrude_activation_gate(o,c,t)):
        fail(f"EdgeExtrude activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_edge_extrude_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_edge_extrude_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("EdgeExtrude activation token copy was not rejected:\n" + run.stdout)

edge_slice_activation_owner = (ROOT /
    "source/prepared_edge_slice_activation.d").read_text()
edge_slice_activation_tool = (ROOT /
    "source/tools/slice/edge_slice_tool.d").read_text()
def edge_slice_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    start = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    end = pt.find("override void deactivate()", start)
    producer = pt[start:end] if start >= 0 and end > start else ""
    bstart = pt.find("final PreparedEdgeSliceActivationImage buildPreparedActivation(")
    bend = pt.find("final void installPreparedActivation(", bstart)
    builder = pt[bstart:bend] if bstart >= 0 and bend > bstart else ""
    istart = pt.find("final void installPreparedActivation(")
    iend = pt.find("final PreparedSessionActivateEffect prepareActivate(", istart)
    installer = pt[istart:iend] if istart >= 0 and iend > istart else ""
    legacy = re.search(r"override void activate\(\)\s*\{", pt)
    legacy_body = pt[legacy.end():balanced_source(pt, legacy.end())-1] if legacy else ""
    return (
        "final class PreparedEdgeSliceActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is EdgeSliceTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation();" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null;" in owner and
        "return PreparedEdgeSliceActivationImage(true);" in builder and
        not re.search(r"(?<!\.)\b(active|armed_|scrubbing_|built_|phase_|"
                      r"latchedPoints_|edgesParam_|dragPart_|activePoint_|armedKey_|"
                      r"chainBefore_|split_|middle_|snap_|show_|chainArm_|tA_|tB_|"
                      r"pointProxy_|vpWorld_)\s*=", builder) and
        "active = true; armed_ = false; scrubbing_ = false; built_ = false;" in installer and
        "phase_ = Phase.Idle; latchedPoints_ = []; edgesParam_ = [];" in installer and
        "dragPart_ = -1; activePoint_ = -1;" in installer and
        "armedKey_ = MeshCacheKey.init; chainBefore_ = MeshSnapshot.init;" in installer and
        "image.clear();" in installer and
        not re.search(r"\b(split_|middle_|snap_|show_|chainArm_|tA_|tB_|"
                      r"pointProxy_|vpWorld_)\s*=", installer) and
        "PreparedEdgeSliceActivationOwner.prepare(this)" in producer and
        "context.prepareEdgeSliceActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareEdgeSliceActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.EdgeSlice, ok);" in producer and
        not any(x in producer for x in ("context.validate(", "context.install(", "owner.install(")) and
        not any(x in legacy_body for x in ("prepareActivate(", "PreparedRecordContext")) and
        "e.edgeSliceActivation.validate();" in context and
        "e.edgeSliceActivation.install();" in context and
        "e.edgeSliceActivation.abort();" in context)
if not edge_slice_activation_gate(edge_slice_activation_owner,
                                  record_context, edge_slice_activation_tool):
    fail("EdgeSlice activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is EdgeSliceTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedActivation();", "", "drop builder"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("owner", "image_.clear(); target_ = null;", "target_ = null;", "retain payload"),
    ("tool", "return PreparedEdgeSliceActivationImage(true);",
     "active = false; return PreparedEdgeSliceActivationImage(true);", "write live during prepare"),
    ("tool", "active = true; armed_ = false; scrubbing_ = false; built_ = false;",
     "armed_ = false; scrubbing_ = false; built_ = false;", "drop active reset"),
    ("tool", "active = true; armed_ = false; scrubbing_ = false; built_ = false;",
     "active = true; scrubbing_ = false; built_ = false;", "drop armed reset"),
    ("tool", "active = true; armed_ = false; scrubbing_ = false; built_ = false;",
     "active = true; armed_ = false; built_ = false;", "drop scrub reset"),
    ("tool", "active = true; armed_ = false; scrubbing_ = false; built_ = false;",
     "active = true; armed_ = false; scrubbing_ = false;", "drop built reset"),
    ("tool", "phase_ = Phase.Idle; latchedPoints_ = []; edgesParam_ = [];",
     "latchedPoints_ = []; edgesParam_ = [];", "drop phase reset"),
    ("tool", "phase_ = Phase.Idle; latchedPoints_ = []; edgesParam_ = [];",
     "phase_ = Phase.Idle; edgesParam_ = [];", "retain latched chain"),
    ("tool", "phase_ = Phase.Idle; latchedPoints_ = []; edgesParam_ = [];",
     "phase_ = Phase.Idle; latchedPoints_ = [];", "retain edges param"),
    ("tool", "dragPart_ = -1; activePoint_ = -1;", "activePoint_ = -1;", "drop drag reset"),
    ("tool", "dragPart_ = -1; activePoint_ = -1;", "dragPart_ = -1;", "drop active point reset"),
    ("tool", "armedKey_ = MeshCacheKey.init; chainBefore_ = MeshSnapshot.init;",
     "chainBefore_ = MeshSnapshot.init;", "retain armed key"),
    ("tool", "armedKey_ = MeshCacheKey.init; chainBefore_ = MeshSnapshot.init;",
     "armedKey_ = MeshCacheKey.init;", "retain snapshot"),
    ("tool", "dragPart_ = -1; activePoint_ = -1;",
     "dragPart_ = -1; activePoint_ = -1; split_ = true;", "reset sticky split"),
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "context.prepareEdgeSliceActivation(owner)", "true", "drop enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.EdgeSlice, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.EdgeSlice, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.EdgeSlice, ok);",
     "PreparedActivateKind.EdgeSlice, true);", "forge acceptance"),
    ("context", "e.edgeSliceActivation.validate();", "true;", "drop validation"),
    ("context", "e.edgeSliceActivation.install();", "", "drop context install"),
    ("context", "e.edgeSliceActivation.abort();", "", "drop context abort"),
):
    o, c, t = edge_slice_activation_owner, record_context, edge_slice_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == edge_slice_activation_owner and c == record_context and
         t == edge_slice_activation_tool) or edge_slice_activation_gate(o,c,t)):
        fail(f"EdgeSlice activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_edge_slice_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_edge_slice_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("EdgeSlice activation token copy was not rejected:\n" + run.stdout)

loop_slice_activation_owner = (ROOT /
    "source/prepared_loop_slice_activation.d").read_text()
loop_slice_activation_tool = (ROOT /
    "source/tools/slice/loop_slice_tool.d").read_text()
def loop_slice_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    bs = pt.find("final PreparedLoopSliceActivationImage buildPreparedActivation(")
    be = pt.find("final void installPreparedActivation(", bs)
    ins = pt.find("final void installPreparedActivation(")
    ine = pt.find("final PreparedSessionActivateEffect prepareActivate(", ins)
    ps = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    pe = pt.find("private void reinitSession()", ps)
    builder = pt[bs:be] if bs >= 0 and be > bs else ""
    installer = pt[ins:ine] if ins >= 0 and ine > ins else ""
    producer = pt[ps:pe] if ps >= 0 and pe > ps else ""
    return (
        "final class PreparedLoopSliceActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is LoopSliceTool.classinfo" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "image.count = count_ < 1 ? 1 : count_;" in builder and
        "image.positions = positions_.dup;" in builder and
        "image.positions ~= 0.5f;" in builder and
        "image.positions.length = cast(size_t)image.count;" in builder and
        "image.count > 1 && mode_ != Mode.Free" in builder and
        "image.positions[k] = (k + 1.0f) / (image.count + 1.0f);" in builder and
        "image.positionProxy = image.positions.length ? image.positions[0] : 0.5f;" in builder and
        "image.before = MeshSnapshot.capture(*source);" in builder and
        not re.search(r"(?<!\.)\b(active|armed_|scrubbing_|built_|seeds_|armedSelFaces_|"
                      r"insertAt_|removeTrigger_|count_|current_|positions_|positionProxy_|"
                      r"armedKey_|before_)\s*=", builder) and
        "active = true; armed_ = false; scrubbing_ = false; built_ = false;" in installer and
        "seeds_ = []; armedSelFaces_ = [];" in installer and
        "insertAt_ = 0.5f; removeTrigger_ = false;" in installer and
        "count_ = image.count; current_ = 0;" in installer and
        "positions_ = image.positions; image.positions = null;" in installer and
        "positionProxy_ = image.positionProxy;" in installer and
        "armedKey_ = MeshCacheKey.init;" in installer and
        "image.before.moveInto(before_);" in installer and
        not re.search(r"\b(mode_|selectNew_|sliceSelected_|keepQuads_|sliceNgon_|"
                      r"sliceSplit_|sliceCaps_|gap_|curvature_|curveTension_|profile_|"
                      r"depth_|reverseX_|reverseY_|aspect_|length_|sliderX_|sliderY_|"
                      r"seedA_|seedB_|vpWorld_)\s*=", installer) and
        "PreparedLoopSliceActivationOwner.prepare(this)" in producer and
        "context.prepareLoopSliceActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareLoopSliceActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.LoopSlice, ok);" in producer and
        "e.loopSliceActivation.validate();" in context and
        "e.loopSliceActivation.install();" in context and
        "e.loopSliceActivation.abort();" in context)
if not loop_slice_activation_gate(loop_slice_activation_owner,
                                  record_context, loop_slice_activation_tool):
    fail("LoopSlice activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is LoopSliceTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content validation"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("tool", "image.positions = positions_.dup;", "positions_ = []; image.positions = positions_.dup;", "write live during prepare"),
    ("tool", "image.count = count_ < 1 ? 1 : count_;", "image.count = count_;", "drop count lower bound"),
    ("tool", "image.positions ~= 0.5f;", "", "drop grow"),
    ("tool", "image.positions.length = cast(size_t)image.count;", "", "drop shrink"),
    ("tool", "image.count > 1 && mode_ != Mode.Free", "image.count > 1", "drop free mode"),
    ("tool", "active = true; armed_ = false; scrubbing_ = false; built_ = false;", "active = true;", "drop flags"),
    ("tool", "seeds_ = []; armedSelFaces_ = [];", "seeds_ = [];", "retain face latch"),
    ("tool", "insertAt_ = 0.5f; removeTrigger_ = false;", "", "drop triggers"),
    ("tool", "count_ = image.count; current_ = 0;", "current_ = 0;", "drop count normalization"),
    ("tool", "positions_ = image.positions; image.positions = null;", "positions_ = image.positions;", "alias retained payload"),
    ("tool", "armedKey_ = MeshCacheKey.init;", "", "retain armed key"),
    ("tool", "image.before.moveInto(before_);", "", "drop baseline"),
    ("tool", "context.prepareLoopSliceActivation(owner)", "true", "drop enlist"),
    ("tool", "context.prepareLoopSliceActivation(owner) &&\n            context.markNoHistoryInstall()",
     "context.markNoHistoryInstall() &&\n            context.prepareLoopSliceActivation(owner)", "reorder history before owner"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop history seal"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.LoopSlice, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.LoopSlice, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.LoopSlice, ok);", "PreparedActivateKind.LoopSlice, true);", "forge acceptance"),
    ("context", "e.loopSliceActivation.validate();", "true;", "drop validation"),
    ("context", "e.loopSliceActivation.install();", "", "drop context install"),
    ("context", "e.loopSliceActivation.abort();", "", "drop context abort"),
):
    o, c, t = loop_slice_activation_owner, record_context, loop_slice_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == loop_slice_activation_owner and c == record_context and
         t == loop_slice_activation_tool) or loop_slice_activation_gate(o,c,t)):
        fail(f"LoopSlice activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_loop_slice_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_loop_slice_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("LoopSlice activation token copy was not rejected:\n" + run.stdout)

slice_activation_owner = (ROOT / "source/prepared_slice_activation.d").read_text()
slice_activation_tool = (ROOT / "source/tools/slice/slice_tool.d").read_text()
def slice_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    bs = pt.find("final PreparedSliceActivationImage buildPreparedActivation(")
    be = pt.find("final void installPreparedActivation(", bs)
    ins = pt.find("final void installPreparedActivation(")
    ine = pt.find("final PreparedSessionActivateEffect prepareActivate(", ins)
    ps = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    pe = pt.find("override void deactivate()", ps)
    builder = pt[bs:be] if bs >= 0 and be > bs else ""
    installer = pt[ins:ine] if ins >= 0 and ine > ins else ""
    producer = pt[ps:pe] if ps >= 0 and pe > ps else ""
    return (
        "final class PreparedSliceActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is SliceTool.classinfo" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.before.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "image.before = MeshSnapshot.capture(*source);" in builder and
        "image.restrictFaces = sliceRestrictFaces(*source);" in builder and
        "image.armedKey.stamp(*source);" in builder and
        not re.search(r"(?<!\.)\b(active|dragPart_|previewLive_|haveBefore_|"
                      r"haveRaw_|snapTempInvert_|haveFrozen_|pendingAxisClassify_|"
                      r"hasLine_|drawGesture_|ctrlPending_|ctrlAxis_|gapDrag_|"
                      r"axisLocked_|before_|restrictFaces_|armedKey_)\s*=", builder) and
        "active = true; dragPart_ = DragNone; previewLive_ = false;" in installer and
        "haveBefore_ = true; haveRaw_ = false; snapTempInvert_ = false;" in installer and
        "haveFrozen_ = false; pendingAxisClassify_ = false;" in installer and
        "hasLine_ = false; drawGesture_ = false; ctrlPending_ = false;" in installer and
        "ctrlAxis_ = -1; gapDrag_ = false; axisLocked_ = false;" in installer and
        "image.before.moveInto(before_);" in installer and
        "restrictFaces_ = image.restrictFaces; image.restrictFaces = null;" in installer and
        "armedKey_ = image.armedKey;" in installer and
        not re.search(r"\b(start_|end_|fast_|axis_|vector_|infinite_|split_|caps_|"
                      r"gap_|gapSide_|snap_|snapAngle_|rawStart_|rawEnd_|frozenNormal_|"
                      r"vpWorld_)\s*=", installer) and
        "PreparedSliceActivationOwner.prepare(this)" in producer and
        "context.prepareSliceActivation(owner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareSliceActivation(owner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.Slice, ok);" in producer and
        "e.sliceActivation.validate();" in context and
        "e.sliceActivation.install();" in context and
        "e.sliceActivation.abort();" in context)
if not slice_activation_gate(slice_activation_owner, record_context,
                             slice_activation_tool):
    fail("Slice activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is SliceTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.before.matches(*source_)", "false", "drop content validation"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("tool", "image.before = MeshSnapshot.capture(*source);", "active = false; image.before = MeshSnapshot.capture(*source);", "write live during prepare"),
    ("tool", "image.restrictFaces = sliceRestrictFaces(*source);", "image.restrictFaces = null;", "drop restriction capture"),
    ("tool", "image.armedKey.stamp(*source);", "", "drop armed stamp"),
    ("tool", "active = true; dragPart_ = DragNone; previewLive_ = false;", "active = true;", "drop primary reset"),
    ("tool", "haveBefore_ = true; haveRaw_ = false; snapTempInvert_ = false;", "haveBefore_ = true;", "drop raw reset"),
    ("tool", "haveFrozen_ = false; pendingAxisClassify_ = false;", "haveFrozen_ = false;", "retain pending classify"),
    ("tool", "hasLine_ = false; drawGesture_ = false; ctrlPending_ = false;", "hasLine_ = false;", "drop line/ctrl reset"),
    ("tool", "ctrlAxis_ = -1; gapDrag_ = false; axisLocked_ = false;", "ctrlAxis_ = -1;", "drop remaining reset"),
    ("tool", "image.before.moveInto(before_);", "", "drop baseline"),
    ("tool", "restrictFaces_ = image.restrictFaces; image.restrictFaces = null;", "restrictFaces_ = image.restrictFaces;", "retain restriction payload"),
    ("tool", "armedKey_ = image.armedKey;", "", "drop armed key"),
    ("tool", "context.prepareSliceActivation(owner) &&\n            context.markNoHistoryInstall()",
     "context.markNoHistoryInstall() &&\n            context.prepareSliceActivation(owner)", "reorder history before owner"),
    ("tool", "context.prepareSliceActivation(owner)", "true", "drop enlist"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.Slice, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.Slice, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.Slice, ok);", "PreparedActivateKind.Slice, true);", "forge acceptance"),
    ("context", "e.sliceActivation.validate();", "true;", "drop validation"),
    ("context", "e.sliceActivation.install();", "", "drop context install"),
    ("context", "e.sliceActivation.abort();", "", "drop context abort"),
):
    o, c, t = slice_activation_owner, record_context, slice_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == slice_activation_owner and c == record_context and
         t == slice_activation_tool) or slice_activation_gate(o,c,t)):
        fail(f"Slice activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_slice_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_slice_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("Slice activation token copy was not rejected:\n" + run.stdout)

tack_activation_owner = (ROOT / "source/prepared_tack_activation.d").read_text()
tack_activation_tool = (ROOT / "source/tools/edit/tack.d").read_text()
def tack_activation_gate(owner, context, tool):
    po = without_unittests(owner); pt = without_unittests(tool)
    bs = pt.find("final PreparedTackActivationImage buildPreparedActivation(")
    be = pt.find("final void installPreparedActivation(", bs)
    ins = pt.find("final void installPreparedActivation(")
    ine = pt.find("final PreparedSessionActivateEffect prepareActivate(", ins)
    ps = pt.find("final PreparedSessionActivateEffect prepareActivate(")
    pe = pt.find("final Mesh* preparedActivationMesh", ps)
    builder = pt[bs:be] if bs >= 0 and be > bs else ""
    installer = pt[ins:ine] if ins >= 0 and ine > ins else ""
    producer = pt[ps:pe] if ps >= 0 and pe > ps else ""
    return (
        "final class PreparedTackActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in po for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo !is TackTool.classinfo" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.baseline.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "image_.clear(); target_ = null; source_ = null;" in owner and
        "image.sourceFace = firstSelectedFace(*source);" in builder and
        "private static int firstSelectedFace(ref const Mesh source)" in pt and
        "source.connectedComponentVertices(cast(uint)image.sourceFace) : [];" in builder and
        "image.baseline = MeshSnapshot.capture(*source);" in builder and
        not re.search(r"(?<!\.)\b(sourceFace_|islandMask_|baseSnap_|"
                      r"hoveredTargetFace_|previewActive_)\s*=", builder) and
        "sourceFace_ = image.sourceFace;" in installer and
        "islandMask_ = image.islandMask; image.islandMask = null;" in installer and
        "image.baseline.moveInto(baseSnap_);" in installer and
        "hoveredTargetFace_ = -1; previewActive_ = false;" in installer and
        not re.search(r"\b(params_|previewMesh_|clickedPoint_|targetNormal_|vpWorld_)\s*=", installer) and
        "PreparedTackActivationOwner.prepare(this)" in producer and
        "gpuOwner.replacesLikeLegacyInit()" in producer and
        "gpuOwner.owns(&previewGpu_)" in producer and
        "context.prepareTackActivation(stateOwner)" in producer and
        "context.prepareCreate(gpuOwner)" in producer and
        "context.markNoHistoryInstall()" in producer and
        producer.find("context.prepareTackActivation(stateOwner)") <
            producer.find("context.prepareCreate(gpuOwner)") <
            producer.find("context.markNoHistoryInstall()") and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
        "            PreparedActivateKind.Tack, ok);" in producer and
        "e.tackActivation.validate();" in context and
        "e.tackActivation.install();" in context and
        "e.tackActivation.abort();" in context)
if not tack_activation_gate(tack_activation_owner, record_context,
                            tack_activation_tool):
    fail("Tack activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is TackTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop identity"),
    ("owner", "!image_.baseline.matches(*source_)", "false", "drop content validation"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("tool", "image.sourceFace = firstSelectedFace(*source);", "sourceFace_ = -1; image.sourceFace = firstSelectedFace(*source);", "write live during prepare"),
    ("tool", "image.sourceFace = firstSelectedFace(*source);", "image.sourceFace = firstSelectedFace();", "re-read provider for source face"),
    ("tool", "source.connectedComponentVertices(cast(uint)image.sourceFace) : [];", "[];", "drop island capture"),
    ("tool", "image.baseline = MeshSnapshot.capture(*source);", "", "drop baseline"),
    ("tool", "sourceFace_ = image.sourceFace;", "", "drop source install"),
    ("tool", "islandMask_ = image.islandMask; image.islandMask = null;", "islandMask_ = image.islandMask;", "retain island payload"),
    ("tool", "image.baseline.moveInto(baseSnap_);", "", "drop baseline install"),
    ("tool", "hoveredTargetFace_ = -1; previewActive_ = false;", "previewActive_ = false;", "drop hover reset"),
    ("tool", "gpuOwner.replacesLikeLegacyInit()", "true", "drop legacy replace"),
    ("tool", "gpuOwner.owns(&previewGpu_)", "true", "drop GPU identity"),
    ("tool", "context.prepareTackActivation(stateOwner) &&\n            context.prepareCreate(gpuOwner) && context.markNoHistoryInstall()",
     "context.prepareCreate(gpuOwner) &&\n            context.prepareTackActivation(stateOwner) && context.markNoHistoryInstall()", "reorder GPU before state"),
    ("tool", "context.prepareTackActivation(stateOwner)", "true", "drop state enlist"),
    ("tool", "context.prepareCreate(gpuOwner)", "true", "drop GPU enlist"),
    ("tool", "context.prepareCreate(gpuOwner) && context.markNoHistoryInstall()",
     "context.prepareCreate(gpuOwner) && true", "drop NoHistory seal"),
    ("tool", "context.prepareCreate(gpuOwner) && context.markNoHistoryInstall()",
     "context.markNoHistoryInstall() && context.prepareCreate(gpuOwner)", "reorder NoHistory before GPU"),
    ("tool", "return PreparedSessionActivateEffect(preparedToolStateOwner,\n"
     "            PreparedActivateKind.Tack, ok);",
     "return PreparedSessionActivateEffect(OwnedId.init,\n"
     "            PreparedActivateKind.Tack, ok);", "forge effect owner"),
    ("tool", "PreparedActivateKind.Tack, ok);", "PreparedActivateKind.Tack, true);", "forge acceptance"),
    ("context", "e.tackActivation.validate();", "true;", "drop validation"),
    ("context", "e.tackActivation.install();", "", "drop context install"),
    ("context", "e.tackActivation.abort();", "", "drop context abort"),
):
    o, c, t = tack_activation_owner, record_context, tack_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == tack_activation_owner and c == record_context and
         t == tack_activation_tool) or tack_activation_gate(o,c,t)):
        fail(f"Tack activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_tack_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_tack_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("Tack activation token copy was not rejected:\n" + run.stdout)

# CommandWrapper activation is one detached CPU session image. The concrete
# product roster is closed here and in the owner; ClickPointHandler has no GL
# allocation until draw(), so this transition intentionally has no GPU arm.
command_wrapper_activation_owner = \
    (ROOT / "source/prepared_command_wrapper_activation.d").read_text()
command_wrapper_activation_tool = \
    (ROOT / "source/tools/common/command_wrapper.d").read_text()
def command_wrapper_activation_gate(owner, context, tool):
    return (owner.count("@disable this(this)") == 2 and
        "final class PreparedCommandWrapperActivationOwner" in owner and
        all(("target.classinfo is " + product + ".classinfo") in owner for product in
            ("XfrmSmoothTool", "XfrmJitterTool", "XfrmQuantizeTool", "EdgeSlideTool")) and
        "result.source_ = target.preparedActivationMesh();" in owner and
        "result.image_ = target.buildPreparedActivation();" in owner and
        "target_.preparedActivationMatches(source_, image_.baseline)" in owner and
        "target_.installPreparedActivation(image_);" in owner and
        "image.baseline = meshPtr.vertices.dup;" in tool and
        "image.falloffs = currentFalloffConfigs();" in tool and
        "image.clickHandle = new ClickPointHandler();" in tool and
        "baseline = image.baseline; image.baseline = null;" in tool and
        "lastAppliedFalloffs = image.falloffs; image.falloffs = null;" in tool and
        "clickHandle = image.clickHandle; image.clickHandle = null;" in tool and
        "dirty = false; paramsDirty = false; dragging = false;" in tool and
        "refireDriving_ = false; refireCommitted_ = false;" in tool and
        "context.prepareCommandWrapperActivation(owner) &&\n            context.markNoHistoryInstall()" in tool and
        "PreparedActivateKind.CommandWrapper, ok);" in tool and
        "CommandWrapperActivationState" in context and
        "e.commandWrapperActivation.validate();" in context and
        "e.commandWrapperActivation.install();" in context and
        "e.commandWrapperActivation.abort();" in context)
if not command_wrapper_activation_gate(command_wrapper_activation_owner,
                                       record_context,
                                       command_wrapper_activation_tool):
    fail("CommandWrapper activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo is EdgeSlideTool.classinfo", "false", "drop product"),
    ("owner", "result.source_ = target.preparedActivationMesh();", "", "drop source capture"),
    ("owner", "target_.preparedActivationMatches(source_, image_.baseline)", "true", "drop validation"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("tool", "image.baseline = meshPtr.vertices.dup;", "", "drop baseline"),
    ("tool", "image.falloffs = currentFalloffConfigs();", "", "drop falloff set"),
    ("tool", "image.clickHandle = new ClickPointHandler();", "", "drop click handle"),
    ("tool", "baseline = image.baseline; image.baseline = null;", "baseline = image.baseline;", "retain baseline payload"),
    ("tool", "dirty = false; paramsDirty = false; dragging = false;", "dirty = false; dragging = false;", "drop param reset"),
    ("tool", "context.prepareCommandWrapperActivation(owner)", "true", "drop state arm"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory seal"),
    ("context", "e.commandWrapperActivation.validate();", "true;", "drop context validation"),
    ("context", "e.commandWrapperActivation.install();", "", "drop context install"),
    ("context", "e.commandWrapperActivation.abort();", "", "drop context abort"),
):
    o, c, t = command_wrapper_activation_owner, record_context, command_wrapper_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if ((o == command_wrapper_activation_owner and c == record_context and
         t == command_wrapper_activation_tool) or
            command_wrapper_activation_gate(o, c, t)):
        fail(f"CommandWrapper activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_command_wrapper_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_command_wrapper_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("CommandWrapper activation token copy was not rejected:\n" + run.stdout)

bridge_activation_owner = (ROOT / "source/prepared_bridge_activation.d").read_text()
bridge_activation_tool = (ROOT / "source/tools/edit/bridge_tool.d").read_text()
def bridge_activation_gate(owner, context, tool, gpu):
    gpu_block = gpu[gpu.find("final class GpuCreateUploadOwner") :]
    activation_block = owner[:owner.find("struct PreparedBridgeDeactivateToken")]
    tool_activation_block = tool[:tool.find(
        "final PreparedBridgeDeactivateImage buildPreparedDeactivateState")]
    return (activation_block.count("@disable this(this)") == 2 and
        "final class PreparedBridgeActivationOwner" in owner and
        "target.classinfo !is BridgeTool.classinfo" in activation_block and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "target_.preparedActivationMode() != image_.mode" in owner and
        "!image_.baseline.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_);" in owner and
        "auto resolved = resolveBridgeSelection(*source, image.mode);" in tool and
        "image.baseline = MeshSnapshot.capture(*source);" in tool and
        "image.sessionKey.stamp(*source);" in tool and
        "rebuildBridgePreview(image.baseline, image.preview" in tool and
        "image.baseline.moveInto(baseSnap_);" in tool and
        "previewMesh_ = image.preview; image.preview = Mesh.init;" in tool and
        "engaged = false; dragging_ = false;" in tool and
        "havePreviewCache = valid_;" in tool and
        "context.prepareBridgeActivation(stateOwner)" in tool and
        "if (ok && stateOwner.selectionValid)" in tool and
        "context.prepareCreateUpload(createUploadOwner, stateOwner.previewMesh)" in tool and
        "context.prepareCreate(createOwner)" in tool and
        tool_activation_block.find("context.prepareBridgeActivation(stateOwner)") <
            tool_activation_block.find("context.prepareCreateUpload(createUploadOwner") <
            tool_activation_block.find("context.markNoHistoryInstall()",
                tool_activation_block.find("context.prepareCreateUpload(createUploadOwner")) and
        "createUploadOwner.replacesLikeLegacyInit()" in tool and
        "createOwner.replacesLikeLegacyInit()" in tool and
        "PreparedActivateKind.Bridge, ok);" in tool and
        "BridgeActivationState" in context and
        "e.bridgeActivation.validate();" in context and
        "e.bridgeActivation.install();" in context and
        "e.bridgeActivation.abort();" in context and
        "GpuMeshNames created, expectedTarget;" in gpu_block and
        "peekGpuMeshNames(*target) != expectedTarget" in gpu_block and
        "bool replacesLikeLegacyInit() const nothrow @nogc" in gpu_block)
if not bridge_activation_gate(bridge_activation_owner, record_context,
                              bridge_activation_tool, mesh_gpu):
    fail("Bridge activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is BridgeTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop Mesh identity"),
    ("owner", "target_.preparedActivationMode() != image_.mode", "false", "drop mode identity"),
    ("owner", "!image_.baseline.matches(*source_)", "false", "drop content validation"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("tool", "auto resolved = resolveBridgeSelection(*source, image.mode);", "", "drop selection capture"),
    ("tool", "image.baseline = MeshSnapshot.capture(*source);", "", "drop baseline"),
    ("tool", "image.sessionKey.stamp(*source);", "", "drop session key"),
    ("tool", "rebuildBridgePreview(image.baseline, image.preview", "false /*", "drop detached preview"),
    ("tool", "image.baseline.moveInto(baseSnap_);", "", "drop baseline transfer"),
    ("tool", "previewMesh_ = image.preview; image.preview = Mesh.init;", "previewMesh_ = image.preview;", "retain preview payload"),
    ("tool", "context.prepareBridgeActivation(stateOwner)", "true", "drop CPU arm"),
    ("tool", "context.prepareCreateUpload(createUploadOwner, stateOwner.previewMesh)", "true", "drop valid GPU arm"),
    ("tool", "context.prepareCreate(createOwner)", "true", "drop invalid GPU arm"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory seal"),
    ("gpu", "peekGpuMeshNames(*target) != expectedTarget", "false", "drop replacement header identity"),
    ("context", "e.bridgeActivation.validate();", "true;", "drop context validation"),
    ("context", "e.bridgeActivation.install();", "", "drop context install"),
    ("context", "e.bridgeActivation.abort();", "", "drop context abort"),
):
    o, c, t, g = bridge_activation_owner, record_context, bridge_activation_tool, mesh_gpu
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    elif target == "gpu":
        pos = g.find(old, g.find("final class GpuCreateUploadOwner"))
        if pos >= 0: g = g[:pos] + new + g[pos + len(old):]
    else: t = t.replace(old, new, 1)
    if bridge_activation_gate(o, c, t, g):
        fail(f"Bridge activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_bridge_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_bridge_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("Bridge activation token copy was not rejected:\n" + run.stdout)

mirror_activation_owner = (ROOT / "source/prepared_mirror_activation.d").read_text()
mirror_activation_tool = (ROOT / "source/tools/alignment/mirror.d").read_text()
def mirror_activation_gate(owner, context, tool, gpu):
    gpu_block = gpu[gpu.find("final class GpuCreateUploadOwner") :]
    activation_block = owner[:owner.find("struct PreparedMirrorDeactivateToken")]
    tool_activation_block = tool[:tool.find(
        "final PreparedMirrorDeactivateImage buildPreparedDeactivateState")]
    return (activation_block.count("@disable this(this)") == 2 and
        "final class PreparedMirrorActivationOwner" in owner and
        "target.classinfo !is MirrorTool.classinfo" in activation_block and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!target_.preparedActivationParamsMatch(image_.params)" in owner and
        "!image_.baseline.matches(*source_)" in owner and
        "target_.installPreparedActivation(image_);" in owner and
        "image.baseline = MeshSnapshot.capture(*source);" in tool and
        "image.mask = source.operandFaceMask();" in tool and
        "image.params = params_;" in tool and
        "rebuildMirrorPreview(image.baseline, image.preview" in tool and
        "image.left = derivedLeft(image.params);" in tool and
        "image.up = derivedUp(image.params);" in tool and
        "image.baseline.moveInto(baseSnap);" in tool and
        "baseMask = image.mask; image.mask = null;" in tool and
        "previewMesh = image.preview; image.preview = Mesh.init;" in tool and
        "params_.left = image.left; params_.up = image.up;" in tool and
        "engaged = false; moverDragAxis = -1; toolHandles.clearHaul();" in tool and
        "cachedAxis = image.params.axis; cachedCenter = image.params.center;" in tool and
        "cachedDistance = image.params.distance; cachedAngle = image.params.angle;" in tool and
        "havePreviewCache = true; image.valid = false;" in tool and
        "context.prepareMirrorActivation(stateOwner)" in tool and
        "context.prepareCreateUpload(uploadOwner, stateOwner.previewMesh)" in tool and
        tool_activation_block.find("context.prepareMirrorActivation(stateOwner)") <
            tool_activation_block.find("context.prepareCreateUpload(uploadOwner") <
            tool_activation_block.find("context.markNoHistoryInstall()",
                tool_activation_block.find("context.prepareCreateUpload(uploadOwner")) and
        "uploadOwner.replacesLikeLegacyInit()" in tool and
        "PreparedActivateKind.Mirror, ok);" in tool and
        "MirrorActivationState" in context and
        "e.mirrorActivation.validate();" in context and
        "e.mirrorActivation.install();" in context and
        "e.mirrorActivation.abort();" in context and
        "peekGpuMeshNames(*target) != expectedTarget" in gpu_block)
if not mirror_activation_gate(mirror_activation_owner, record_context,
                              mirror_activation_tool, mesh_gpu):
    fail("Mirror activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is MirrorTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop Mesh identity"),
    ("owner", "!target_.preparedActivationParamsMatch(image_.params)", "false", "drop parameter identity"),
    ("owner", "!image_.baseline.matches(*source_)", "false", "drop content validation"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop install"),
    ("tool", "image.baseline = MeshSnapshot.capture(*source);", "", "drop baseline"),
    ("tool", "image.mask = source.operandFaceMask();", "", "drop operand mask"),
    ("tool", "rebuildMirrorPreview(image.baseline, image.preview", "false /*", "drop detached preview"),
    ("tool", "image.left = derivedLeft(image.params);", "", "drop derived left"),
    ("tool", "image.up = derivedUp(image.params);", "", "drop derived up"),
    ("tool", "image.baseline.moveInto(baseSnap);", "", "drop baseline transfer"),
    ("tool", "baseMask = image.mask; image.mask = null;", "baseMask = image.mask;", "retain mask payload"),
    ("tool", "previewMesh = image.preview; image.preview = Mesh.init;", "previewMesh = image.preview;", "retain preview payload"),
    ("tool", "params_.left = image.left; params_.up = image.up;", "", "drop derived readout install"),
    ("tool", "engaged = false; moverDragAxis = -1; toolHandles.clearHaul();", "engaged = false;", "drop interaction reset"),
    ("tool", "cachedAxis = image.params.axis; cachedCenter = image.params.center;", "", "drop axis/center cache"),
    ("tool", "cachedDistance = image.params.distance; cachedAngle = image.params.angle;", "", "drop distance/angle cache"),
    ("tool", "context.prepareMirrorActivation(stateOwner)", "true", "drop CPU arm"),
    ("tool", "context.prepareCreateUpload(uploadOwner, stateOwner.previewMesh)", "true", "drop GPU arm"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory seal"),
    ("context", "e.mirrorActivation.validate();", "true;", "drop context validation"),
    ("context", "e.mirrorActivation.install();", "", "drop context install"),
    ("context", "e.mirrorActivation.abort();", "", "drop context abort"),
):
    o, c, t = mirror_activation_owner, record_context, mirror_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if mirror_activation_gate(o, c, t, mesh_gpu):
        fail(f"Mirror activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_mirror_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_mirror_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("Mirror activation token copy was not rejected:\n" + run.stdout)

def mirror_deactivate_state_gate(owner, context, tool):
    block = owner[owner.find("struct PreparedMirrorDeactivateToken"):]
    return (block.count("@disable this(this)") == 2 and
        "final class PreparedMirrorDeactivateOwner" in block and
        "target.classinfo !is MirrorTool.classinfo" in block and
        "result.image_ = target.buildPreparedDeactivateState();" in block and
        "!target_.preparedDeactivateStateMatches(image_)" in block and
        "target_.installPreparedDeactivateState(image_); consume();" in block and
        "image_.clear(); target_ = null;" in block and
        "return PreparedMirrorDeactivateImage(true, engaged, havePreviewCache);" in tool and
        "engaged == image.expectedEngaged" in tool and
        "havePreviewCache == image.expectedPreviewCache" in tool and
        "engaged = false; havePreviewCache = false; image.clear();" in tool and
        "MirrorDeactivateState" in context and
        "e.mirrorDeactivate.validate();" in context and
        "e.mirrorDeactivate.install();" in context and
        "e.mirrorDeactivate.abort();" in context)
if not mirror_deactivate_state_gate(mirror_activation_owner, record_context,
                                    mirror_activation_tool):
    fail("Mirror deactivation state owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is MirrorTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedDeactivateState();", "", "drop capture"),
    ("owner", "!target_.preparedDeactivateStateMatches(image_)", "false", "drop state validation"),
    ("owner", "target_.installPreparedDeactivateState(image_); consume();", "consume();", "drop install"),
    ("owner", "image_.clear(); target_ = null;", "target_ = null;", "drop scrub"),
    ("tool", "return PreparedMirrorDeactivateImage(true, engaged, havePreviewCache);", "return PreparedMirrorDeactivateImage.init;", "drop projection"),
    ("tool", "engaged = false; havePreviewCache = false; image.clear();", "engaged = false; image.clear();", "drop cache reset"),
    ("context", "e.mirrorDeactivate.validate();", "true;", "drop context validation"),
    ("context", "e.mirrorDeactivate.install();", "", "drop context install"),
    ("context", "e.mirrorDeactivate.abort();", "", "drop context abort"),
):
    o, c, t = mirror_activation_owner, record_context, mirror_activation_tool
    if target == "owner":
        pos = o.find(old, o.find("struct PreparedMirrorDeactivateToken"))
        if pos >= 0: o = o[:pos] + new + o[pos + len(old):]
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if mirror_deactivate_state_gate(o, c, t):
        fail(f"Mirror deactivation state mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_mirror_deactivate_token_copy.d",
    ROOT / "tests/compile_fail/prepared_mirror_deactivate_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("Mirror deactivation token copy was not rejected:\n" + run.stdout)

def bridge_deactivate_state_gate(owner, context, tool):
    block = owner[owner.find("struct PreparedBridgeDeactivateToken"):]
    return (block.count("@disable this(this)") == 2 and
        "final class PreparedBridgeDeactivateOwner" in block and
        "target.classinfo !is BridgeTool.classinfo" in block and
        "result.image_ = target.buildPreparedDeactivateState();" in block and
        "!target_.preparedDeactivateStateMatches(image_)" in block and
        "target_.installPreparedDeactivateState(image_); consume();" in block and
        "image_.clear(); target_ = null;" in block and
        "image.expectedEngaged = engaged;" in tool and
        "image.loopA = loopA_.dup; image.loopB = loopB_.dup;" in tool and
        "sessionKey_ == image.sessionKey" in tool and
        "engaged = false; havePreviewCache = false; image.clear();" in tool and
        "BridgeDeactivateState" in context and
        "e.bridgeDeactivate.validate();" in context and
        "e.bridgeDeactivate.install();" in context and
        "e.bridgeDeactivate.abort();" in context)
if not bridge_deactivate_state_gate(bridge_activation_owner, record_context,
                                    bridge_activation_tool):
    fail("Bridge deactivation state owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is BridgeTool.classinfo", "false", "broaden product"),
    ("owner", "result.image_ = target.buildPreparedDeactivateState();", "", "drop capture"),
    ("owner", "!target_.preparedDeactivateStateMatches(image_)", "false", "drop state validation"),
    ("owner", "target_.installPreparedDeactivateState(image_); consume();", "consume();", "drop install"),
    ("owner", "image_.clear(); target_ = null;", "target_ = null;", "drop scrub"),
    ("tool", "image.loopA = loopA_.dup; image.loopB = loopB_.dup;", "", "drop loop capture"),
    ("tool", "sessionKey_ == image.sessionKey", "true", "drop session validation"),
    ("tool", "engaged = false; havePreviewCache = false; image.clear();", "engaged = false; image.clear();", "drop cache reset"),
    ("context", "e.bridgeDeactivate.validate();", "true;", "drop context validation"),
    ("context", "e.bridgeDeactivate.install();", "", "drop context install"),
    ("context", "e.bridgeDeactivate.abort();", "", "drop context abort"),
):
    o, c, t = bridge_activation_owner, record_context, bridge_activation_tool
    if target == "owner":
        pos = o.find(old, o.find("struct PreparedBridgeDeactivateToken"))
        if pos >= 0: o = o[:pos] + new + o[pos + len(old):]
    elif target == "context": c = c.replace(old, new, 1)
    else:
        pos = t.find(old, t.find("final PreparedBridgeDeactivateImage"))
        if pos >= 0: t = t[:pos] + new + t[pos + len(old):]
    if bridge_deactivate_state_gate(o, c, t):
        fail(f"Bridge deactivation state mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_bridge_deactivate_token_copy.d",
    ROOT / "tests/compile_fail/prepared_bridge_deactivate_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("Bridge deactivation token copy was not rejected:\n" + run.stdout)

def bridge_deactivate_producer_gate(tool, effect):
    start = tool.find("final PreparedDeactivateEffect prepareDeactivate(")
    end = tool.find("version(unittest) final void seedPreparedDeactivateStateForTest", start)
    body = tool[start:end]
    effect_block = effect[effect.find("enum PreparedDeactivateKind"):
        effect.find("enum PreparedActivateKind")]
    return (start >= 0 and end > start and "Bridge," in effect_block and
        "scope(failure) context.discard();" in body and
        "PreparedBridgeDeactivateOwner.prepare(this)" in body and
        "&layer.meshRef() is mesh" in body and
        "ownsPreparedPreviewDestroy(previewDestroy)" in body and
        "image.sessionKey.matches(*mesh)" in tool and
        "beginPreparedShadow(candidate)" in tool and
        "applyBridgeOp(candidate, image.loopA, image.loopB," in tool and
        "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);" in tool and
        "ownsPreparedMainUpload(mainUpload)" in body and
        "context.prepareStampedMeshImage(layer, candidate," in body and
        "context.prepareUpload(mainUpload, candidate)" in body and
        "context.prepareDestroy(previewDestroy)" in body and
        "cmd.setSnapshots(pre, MeshSnapshot.capture(candidate), \"Bridge\");" in body and
        "context.prepareGestureCarrierMismatch()" in body and
        "context.markHistoryInstall()" in body and
        "context.markNoHistoryInstall()" in body and
        "context.prepareBridgeDeactivate(stateOwner)" in body and
        body.find("context.prepareStampedMeshImage(layer, candidate,") <
            body.find("context.prepareUpload(mainUpload, candidate)") <
            body.find("context.prepareDestroy(previewDestroy)") <
            body.find("context.markHistoryInstall()") <
            body.find("context.prepareBridgeDeactivate(stateOwner)") and
        "PreparedDeactivateKind.Bridge, historyPrepared, ok);" in body)
bridge_deactivate_effect = (ROOT / "source/prepared_tool_effect.d").read_text()
if not bridge_deactivate_producer_gate(bridge_activation_tool,
                                       bridge_deactivate_effect):
    fail("Bridge deactivation producer contract drift")
for target, old, new, label in (
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "&layer.meshRef() is mesh", "true", "drop layer identity"),
    ("tool", "ownsPreparedPreviewDestroy(previewDestroy)", "true", "drop preview identity"),
    ("tool", "beginPreparedShadow(candidate)", "beginPreparedShadow(*mesh)", "drop detached shadow"),
    ("tool", "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);", "", "drop delivery capture"),
    ("tool", "ownsPreparedMainUpload(mainUpload)", "true", "drop main GPU identity"),
    ("tool", "context.prepareStampedMeshImage(layer, candidate,", "false /* dropped mesh enlist */ (", "drop mesh enlist"),
    ("tool", "context.prepareUpload(mainUpload, candidate)", "true", "drop GPU upload"),
    ("tool", "context.prepareDestroy(previewDestroy)", "true", "drop preview destroy"),
    ("tool", "context.prepareGestureCarrierMismatch()", "true", "drop carrier diagnostic"),
    ("tool", "context.markHistoryInstall()", "true", "drop history marker"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop no-history marker"),
    ("tool", "context.prepareBridgeDeactivate(stateOwner)", "true", "drop final state"),
    ("effect", "Bridge,", "None,", "drop closed effect kind"),
):
    t, e = bridge_activation_tool, bridge_deactivate_effect
    if target == "effect":
        pos = e.find(old, e.find("enum PreparedDeactivateKind"));
        if pos >= 0: e = e[:pos] + new + e[pos + len(old):]
    else:
        pos = t.find(old, t.find("final PreparedDeactivateEffect prepareDeactivate("))
        if pos < 0: pos = t.find(old, t.find("buildPreparedDeactivateCandidate"))
        if pos >= 0: t = t[:pos] + new + t[pos + len(old):]
    if bridge_deactivate_producer_gate(t, e):
        fail(f"Bridge deactivation producer mutation did not RED: {label}")

box_deactivate_tool = (ROOT / "source/tools/create/box.d").read_text()
box_deactivate_owner = (ROOT / "source/prepared_private_state.d").read_text()
box_deactivate_effect = (ROOT / "source/prepared_tool_effect.d").read_text()
def box_deactivate_gate(tool, owner, effect):
    start = tool.find("final PreparedDeactivateEffect prepareDeactivate(")
    end = tool.find("override void deactivate()", start)
    body = tool[start:end]
    candidate = tool[tool.find("private bool buildPreparedDeactivateCandidate("):start]
    state = tool[tool.find("final PreparedBoxDeactivateImage buildPreparedDeactivateState"):start]
    owner_block = owner[owner.find("static PreparedPrivateStateOwner boxDeactivate"):]
    effect_block = effect[effect.find("enum PreparedDeactivateKind"):
        effect.find("enum PreparedActivateKind")]
    return (start >= 0 and end > start and "Box," in effect_block and
        "target.classinfo !is BoxTool.classinfo" in owner_block and
        "target.buildPreparedDeactivateState(clearTracking)" in owner_block and
        "!boxTarget.preparedDeactivateStateMatches(boxDeactivateImage)" in owner_block and
        "boxTarget.installPreparedDeactivateState(boxDeactivateImage);" in owner_block and
        "image.expectedState = cast(ubyte)state;" in state and
        "image.expectedLastSnap = lastSnap" in state and
        "frame.toWorld == image.frame.toWorld" in state and
        "if (image.clearTracking)" in state and
        "lastSnap = SnapResult.init; image.clear();" in state and
        "beginPreparedShadow(candidate)" in candidate and
        "buildCuboidParametric(&candidate, image.params);" in candidate and
        "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);" in candidate and
        "scope(failure) context.discard();" in body and
        "&layer.meshRef() is mesh" in body and
        "ownsPreparedPreviewDestroy(previewDestroy)" in body and
        "ownsPreparedMainUpload(mainUpload)" in body and
        "context.prepareStampedMeshImage(layer, candidate," in body and
        "context.prepareUpload(mainUpload, candidate)" in body and
        "context.prepareDestroy(previewDestroy)" in body and
        "PreparedHistoryKind.ReplaceRunTail" in body and
        "cmd.setSnapshots(pre, MeshSnapshot.capture(candidate), \"Create Box\");" in body and
        "context.prepareGestureCarrierMismatch()" in body and
        "PreparedPrivateStateOwner.boxDeactivate(" in body and
        "context.prepareSnapClear(snapOwner)" in body and
        "context.markHistoryInstall()" in body and
        "context.markNoHistoryInstall()" in body and
        "context.preparePrivateState(stateOwner)" in body and
        body.find("context.prepareStampedMeshImage(layer, candidate,") <
            body.find("context.prepareUpload(mainUpload, candidate)") <
            body.find("context.prepareDestroy(previewDestroy)") <
            body.find("context.markHistoryInstall()") <
            body.find("context.preparePrivateState(stateOwner)") <
            body.find("context.prepareSnapClear(snapOwner)") and
        "PreparedDeactivateKind.Box, historyPrepared, ok);" in body)
if not box_deactivate_gate(box_deactivate_tool, box_deactivate_owner,
                           box_deactivate_effect):
    fail("Box deactivation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is BoxTool.classinfo", "false", "broaden product"),
    ("owner", "!boxTarget.preparedDeactivateStateMatches(boxDeactivateImage)", "false", "drop state validation"),
    ("owner", "boxTarget.installPreparedDeactivateState(boxDeactivateImage);", "", "drop state install"),
    ("tool", "beginPreparedShadow(candidate)", "beginPreparedShadow(*mesh)", "drop detached shadow"),
    ("tool", "buildCuboidParametric(&candidate, image.params);", "", "drop captured kernel"),
    ("tool", "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);", "", "drop delivery"),
    ("tool", "&layer.meshRef() is mesh", "true", "drop layer identity"),
    ("tool", "ownsPreparedPreviewDestroy(previewDestroy)", "true", "drop preview identity"),
    ("tool", "ownsPreparedMainUpload(mainUpload)", "true", "drop main GPU identity"),
    ("tool", "context.prepareStampedMeshImage(layer, candidate,", "false /* dropped mesh */ (", "drop mesh enlist"),
    ("tool", "context.prepareUpload(mainUpload, candidate)", "true", "drop upload"),
    ("tool", "context.prepareDestroy(previewDestroy)", "true", "drop destroy"),
    ("tool", "PreparedHistoryKind.ReplaceRunTail", "PreparedHistoryKind.Plain", "drop run-tail mode"),
    ("tool", "context.prepareGestureCarrierMismatch()", "true", "drop carrier diagnostic"),
    ("tool", "context.prepareSnapClear(snapOwner)", "true", "drop snap clear"),
    ("tool", "context.markHistoryInstall()", "true", "drop history marker"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop no-history marker"),
    ("tool", "context.preparePrivateState(stateOwner)", "true", "drop final state"),
    ("effect", "Box,", "None,", "drop effect kind"),
):
    t, o, e = box_deactivate_tool, box_deactivate_owner, box_deactivate_effect
    if target == "effect":
        pos = e.find(old, e.find("enum PreparedDeactivateKind"))
        if pos >= 0: e = e[:pos] + new + e[pos + len(old):]
    elif target == "owner":
        pos = o.find(old, o.find("static PreparedPrivateStateOwner boxDeactivate"))
        if pos >= 0: o = o[:pos] + new + o[pos + len(old):]
    else:
        pos = t.find(old, t.find("private bool buildPreparedDeactivateCandidate("))
        if pos >= 0: t = t[:pos] + new + t[pos + len(old):]
    if box_deactivate_gate(t, o, e):
        fail(f"Box deactivation mutation did not RED: {label}")

pen_deactivate_tool = (ROOT / "source/tools/create/pen.d").read_text()
pen_deactivate_owner = (ROOT / "source/prepared_private_state.d").read_text()
pen_deactivate_effect = (ROOT / "source/prepared_tool_effect.d").read_text()
def pen_deactivate_gate(tool, owner, effect, context, handlers):
    start = tool.find("final PreparedDeactivateEffect prepareDeactivate(")
    end = tool.find("override void deactivate()", start)
    body = tool[start:end]
    candidate = tool[tool.find("private bool buildPreparedDeactivateCandidate("):start]
    state = tool[tool.find("final PreparedPenDeactivateImage buildPreparedDeactivateState"):start]
    owner_start = owner.find("static PreparedPrivateStateOwner penDeactivate")
    owner_end = owner.find("static PreparedPrivateStateOwner penParam", owner_start)
    owner_factory = owner[owner_start:owner_end]
    owner_block = owner[owner_start:]
    effect_block = effect[effect.find("enum PreparedDeactivateKind"):
        effect.find("enum PreparedActivateKind")]
    return (start >= 0 and end > start and
        re.search(r"\bPen\s*,", effect_block) is not None and
        "final class BoxHandlerBatchResourceOwner" in handlers and
        "bool prepareDestroy(BoxHandlerBatchResourceOwner owner)" in context and
        "target.classinfo !is PenTool.classinfo" in owner_factory and
        "target.buildPreparedDeactivateState()" in owner_factory and
        "!penTarget.preparedDeactivateStateMatches(penDeactivateImage)" in owner_block and
        "penTarget.installPreparedDeactivateState(penDeactivateImage);" in owner_block and
        "image.vertices = vertices_.dup;" in state and
        "frame.toWorld == image.toWorld" in state and
        "installPreparedMeshImage(previewMesh, image.previewClear);" in state and
        "beginPreparedShadow(candidate)" in candidate and
        "foreach (v; image.vertices)" in candidate and
        "candidate.declareCornerAppend(); candidate.buildLoops();" in candidate and
        "candidate.syncSelection();" in candidate and
        "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);" in candidate and
        "scope(failure) context.discard();" in body and
        "&layer.meshRef() is mesh" in body and
        "ownsPreparedHandlers(handlerDestroy)" in body and
        "ownsPreparedMainUpload(mainCommitUpload)" in body and
        "ownsPreparedMainUpload(mainRefreshUpload)" in body and
        "ownsPreparedPreviewUpload(previewEmptyUpload)" in body and
        "ownsPreparedPreviewDestroy(previewDestroy)" in body and
        "context.prepareStampedMeshImage(layer, candidate," in body and
        "context.prepareUpload(mainCommitUpload, candidate)" in body and
        "cmd.setSnapshots(pre, MeshSnapshot.capture(candidate), \"Pen Polygon\");" in body and
        "context.prepareGestureCarrierMismatch()" in body and
        "context.prepareUpload(mainRefreshUpload, candidate)" in body and
        "context.prepareDestroy(handlerDestroy)" in body and
        "PreparedPrivateStateOwner.penDeactivate(this)" in body and
        "context.preparePrivateState(stateOwner)" in body and
        "context.prepareUpload(previewEmptyUpload, emptyPreview)" in body and
        "context.prepareSnapClear(snapOwner)" in body and
        "context.prepareDestroy(previewDestroy)" in body and
        body.find("context.prepareStampedMeshImage(layer, candidate,") <
            body.find("context.prepareUpload(mainCommitUpload, candidate)") <
            body.find("context.markHistoryInstall()") <
            body.find("context.prepareUpload(mainRefreshUpload, candidate)") <
            body.find("context.prepareDestroy(handlerDestroy)") <
            body.find("context.preparePrivateState(stateOwner)") <
            body.find("context.prepareUpload(previewEmptyUpload, emptyPreview)") <
            body.find("context.prepareDestroy(previewDestroy)") and
        "PreparedDeactivateKind.Pen, historyPrepared, ok);" in body)
handler_shapes_for_pen = (ROOT / "source/handles/shapes.d").read_text()
if not pen_deactivate_gate(pen_deactivate_tool, pen_deactivate_owner,
        pen_deactivate_effect, record_context, handler_shapes_for_pen):
    fail("Pen deactivation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is PenTool.classinfo", "false", "broaden product"),
    ("owner", "!penTarget.preparedDeactivateStateMatches(penDeactivateImage)", "false", "drop state validation"),
    ("owner", "penTarget.installPreparedDeactivateState(penDeactivateImage);", "", "drop state install"),
    ("tool", "image.vertices = vertices_.dup;", "image.vertices = vertices_;", "borrow vertex input"),
    ("tool", "beginPreparedShadow(candidate)", "beginPreparedShadow(*mesh)", "drop detached shadow"),
    ("tool", "candidate.syncSelection();", "", "drop final selection sync"),
    ("tool", "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);", "", "drop delivery"),
    ("tool", "&layer.meshRef() is mesh", "true", "drop layer identity"),
    ("tool", "ownsPreparedHandlers(handlerDestroy)", "true", "drop handler identity"),
    ("tool", "ownsPreparedMainUpload(mainCommitUpload)", "true", "drop commit upload identity"),
    ("tool", "ownsPreparedMainUpload(mainRefreshUpload)", "true", "drop refresh upload identity"),
    ("tool", "ownsPreparedPreviewUpload(previewEmptyUpload)", "true", "drop preview upload identity"),
    ("tool", "ownsPreparedPreviewDestroy(previewDestroy)", "true", "drop preview destroy identity"),
    ("tool", "context.prepareStampedMeshImage(layer, candidate,", "false /* dropped mesh */ (", "drop mesh enlist"),
    ("tool", "context.prepareUpload(mainCommitUpload, candidate)", "true", "drop commit upload"),
    ("tool", "context.prepareGestureCarrierMismatch()", "true", "drop carrier diagnostic"),
    ("tool", "context.prepareUpload(mainRefreshUpload, candidate)", "true", "drop refresh upload"),
    ("tool", "context.prepareDestroy(handlerDestroy)", "true", "drop handler destroy"),
    ("tool", "context.preparePrivateState(stateOwner)", "true", "drop final state"),
    ("tool", "context.prepareUpload(previewEmptyUpload, emptyPreview)", "true", "drop preview clear upload"),
    ("tool", "context.prepareSnapClear(snapOwner)", "true", "drop short-stroke snap clear"),
    ("tool", "context.prepareDestroy(previewDestroy)", "true", "drop preview destroy"),
    ("effect", "Pen,", "None,", "drop effect kind"),
):
    t, o, e = pen_deactivate_tool, pen_deactivate_owner, pen_deactivate_effect
    if target == "effect":
        pos = e.find(old, e.find("enum PreparedDeactivateKind"))
        if pos >= 0: e = e[:pos] + new + e[pos + len(old):]
    elif target == "owner":
        pos = o.find(old, o.find("static PreparedPrivateStateOwner penDeactivate"))
        if pos >= 0: o = o[:pos] + new + o[pos + len(old):]
    else:
        pos = t.find(old, t.find("final PreparedPenDeactivateImage"))
        if pos >= 0: t = t[:pos] + new + t[pos + len(old):]
    if pen_deactivate_gate(t, o, e, record_context, handler_shapes_for_pen):
        fail(f"Pen deactivation mutation did not RED: {label}")

primitive_deactivate_tool = (ROOT / "source/tools/create/primitive_create_tool.d").read_text()
primitive_deactivate_owner = (ROOT / "source/prepared_private_state.d").read_text()
primitive_deactivate_effect = (ROOT / "source/prepared_tool_effect.d").read_text()
def primitive_deactivate_gate(tool, owner, effect):
    start = tool.find("final PreparedDeactivateEffect prepareDeactivate(")
    body = tool[start:tool.find("override void evaluate()", start)]
    state = tool[tool.find("struct PreparedPrimitiveDeactivateImage"):start]
    owner_block = owner[owner.find("static PreparedPrivateStateOwner primitiveDeactivate"):]
    effect_block = effect[effect.find("enum PreparedDeactivateKind"):
        effect.find("enum PreparedActivateKind")]
    return (start >= 0 and "Primitive," in effect_block and
        "expectedWillCommit" in state and "expectedCommitValid" in state and
        "image.expectedProductWitness = preparedDeactivateProductWitness();" in state and
        "image.expectedFrameWitness = preparedBytesWitness(&frame," in state and
        "image.expectedProductWitness ==" in state and
        "beginPreparedShadow(candidate)" in tool and
        "buildInto(&candidate);" in tool and
        "applyFrameToMeshRange(&candidate, firstNewVert, firstNewFace);" in tool and
        "candidate.declareCornerAppend();" in tool and
        "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);" in tool and
        "target.buildPreparedDeactivateState(" in owner_block and
        "!primitiveTarget.preparedDeactivateStateMatches(" in owner_block and
        "primitiveTarget.installPreparedDeactivateState(" in owner_block and
        "&layer.meshRef() is mesh" in body and
        "previewDestroy.owns(&previewGpu)" in body and
        "mainUpload.owns(gpu)" in body and
        "context.prepareStampedMeshImage(layer, candidate," in body and
        "context.prepareUpload(mainUpload, candidate)" in body and
        "context.preparePrivateState(stateOwner)" in body and
        "context.prepareDestroy(previewDestroy)" in body and
        "PreparedHistoryKind.Plain" in body and
        "context.prepareGestureCarrierMismatch()" in body and
        "context.markHistoryInstall()" in body and
        "context.markNoHistoryInstall()" in body and
        "context.prepareSnapClear(snapOwner)" in body and
        body.find("context.prepareStampedMeshImage(layer, candidate,") <
            body.find("context.prepareUpload(mainUpload, candidate)") <
            body.find("context.preparePrivateState(stateOwner)") <
            body.find("context.prepareDestroy(previewDestroy)") <
            body.find("context.markHistoryInstall()") <
            body.find("context.prepareSnapClear(snapOwner)") and
        "PreparedDeactivateKind.Primitive, historyPrepared, ok);" in body)
if not primitive_deactivate_gate(primitive_deactivate_tool,
        primitive_deactivate_owner, primitive_deactivate_effect):
    fail("Primitive deactivation prepared contract drift")
for target, old, new, label in (
    ("tool", "beginPreparedShadow(candidate)", "beginPreparedShadow(*mesh)", "drop detached shadow"),
    ("tool", "buildInto(&candidate);", "buildInto(mesh);", "write live product"),
    ("tool", "image.expectedProductWitness = preparedDeactivateProductWitness();",
     "image.expectedProductWitness = 0;", "drop product witness"),
    ("tool", "&layer.meshRef() is mesh", "true", "drop layer identity"),
    ("tool", "previewDestroy.owns(&previewGpu)", "true", "drop preview identity"),
    ("tool", "mainUpload.owns(gpu)", "true", "drop upload identity"),
    ("tool", "context.prepareStampedMeshImage(layer, candidate,", "false /* mesh */ (", "drop mesh enlist"),
    ("tool", "context.preparePrivateState(stateOwner)", "true", "drop final state"),
    ("tool", "context.prepareDestroy(previewDestroy)", "true", "drop preview destroy"),
    ("tool", "PreparedHistoryKind.Plain", "PreparedHistoryKind.ReplaceRunTail", "change history mode"),
    ("tool", "context.prepareSnapClear(snapOwner)", "true", "drop snap clear"),
    ("effect", "Primitive,", "None,", "drop effect kind"),
):
    t, o, e = primitive_deactivate_tool, primitive_deactivate_owner, primitive_deactivate_effect
    if target == "effect":
        pos = e.find(old, e.find("enum PreparedDeactivateKind"))
        if pos >= 0: e = e[:pos] + new + e[pos + len(old):]
    elif target == "owner":
        pos = o.find(old, o.find("static PreparedPrivateStateOwner primitiveDeactivate"))
        if pos >= 0: o = o[:pos] + new + o[pos + len(old):]
    else:
        candidate_mutation = old in {
            "beginPreparedShadow(candidate)", "buildInto(&candidate);",
            "image.expectedProductWitness = preparedDeactivateProductWitness();"}
        search_from = t.find("struct PreparedPrimitiveDeactivateImage") if candidate_mutation \
            else t.find("final PreparedDeactivateEffect prepareDeactivate(")
        pos = t.find(old, search_from)
        if pos >= 0: t = t[:pos] + new + t[pos + len(old):]
    if primitive_deactivate_gate(t, o, e):
        fail(f"Primitive deactivation mutation did not RED: {label}")

topology_update_tool = (ROOT / "source/tools/edit/topology_pen/tool.d").read_text()
topology_update_owner = (ROOT / "source/prepared_topology_pen_update.d").read_text()
topology_update_effect = (ROOT / "source/prepared_tool_effect.d").read_text()
def topology_update_gate(tool, owner, context, effect):
    start = tool.find("final PreparedTopologyPenUpdateImage buildPreparedUpdate(")
    end = tool.find("// ---------------------------------------------------------------------", start)
    body = tool[start:end]
    effect_block = effect[effect.find("enum PreparedTopologyPenUpdateKind"):]
    return (start >= 0 and "PacketAbsent, Packet" in effect_block and
        "if (auto packet = vts.get!ConstrainHitPacket())" in body and
        "image.nextHit = *packet;" in body and
        "resolveHoverTarget(image.nextHit, vp," in body and
        "lastHit_ == image.expectedHit" in body and
        "lastTarget_ == image.expectedTarget" in body and
        "lastHit_ = image.nextHit; lastTarget_ = image.nextTarget;" in body and
        "PreparedTopologyPenUpdateOwner.prepare(this, vts)" in body and
        "context.prepareTopologyPenUpdate(owner)" in body and
        "context.markNoHistoryInstall()" in body and
        "target.classinfo !is TopologyPenTool.classinfo" in owner and
        "target_.preparedUpdateMatches(image_)" in owner and
        "target_.installPreparedUpdate(image_); consume();" in owner and
        owner.count("@disable this(this)") == 2 and
        "bool prepareTopologyPenUpdate(PreparedTopologyPenUpdateOwner owner)" in context and
        "case PreparedResourceKind.TopologyPenUpdateState:" in context and
        "e.topologyPenUpdate.validate();" in context and
        "e.topologyPenUpdate.install();" in context and
        "e.topologyPenUpdate.abort();" in context)
if not topology_update_gate(topology_update_tool, topology_update_owner,
        record_context, topology_update_effect):
    fail("TopologyPen update prepared contract drift")
for target, old, new, label in (
    ("tool", "image.nextHit = *packet;", "image.nextHit = lastHit_;", "drop packet capture"),
    ("tool", "resolveHoverTarget(image.nextHit, vp,", "lastTarget /* stale */ (", "drop target resolve"),
    ("tool", "lastHit_ == image.expectedHit", "true", "drop hit validation"),
    ("tool", "lastTarget_ == image.expectedTarget", "true", "drop target validation"),
    ("tool", "lastHit_ = image.nextHit; lastTarget_ = image.nextTarget;", "", "drop atomic install"),
    ("tool", "context.prepareTopologyPenUpdate(owner)", "true", "drop owner enlist"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop no-history seal"),
    ("owner", "target.classinfo !is TopologyPenTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedUpdateMatches(image_)", "true", "drop owner validation"),
    ("context", "e.topologyPenUpdate.install();", "", "drop context install"),
):
    t, o, c = topology_update_tool, topology_update_owner, record_context
    if target == "tool":
        pos = t.find(old, t.find("final PreparedTopologyPenUpdateImage buildPreparedUpdate("))
        if pos >= 0: t = t[:pos] + new + t[pos + len(old):]
    elif target == "owner": o = o.replace(old, new, 1)
    else: c = c.replace(old, new, 1)
    if topology_update_gate(t, o, c, topology_update_effect):
        fail(f"TopologyPen update mutation did not RED: {label}")

mirror_deactivate_effect = (ROOT / "source/prepared_tool_effect.d").read_text()
def mirror_deactivate_producer_gate(tool, effect):
    start = tool.find("final PreparedDeactivateEffect prepareDeactivate(")
    end = tool.find("override void deactivate()", start)
    body = tool[start:end]
    effect_block = effect[effect.find("enum PreparedDeactivateKind"):
        effect.find("enum PreparedActivateKind")]
    return (start >= 0 and end > start and
        "Mirror," in effect_block and
        "scope(failure) context.discard();" in body and
        "PreparedMirrorDeactivateOwner.prepare(this)" in body and
        "&layer.meshRef() is mesh" in body and
        "ownsPreparedPreviewDestroy(previewDestroy)" in body and
        "buildPreparedDeactivateCandidate(candidate, pre," in body and
        "beginPreparedShadow(candidate)" in tool and
        "candidate.mirrorFacesPlane(candidate.operandFaceMask()," in tool and
        "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);" in tool and
        "ownsPreparedMainUpload(mainUpload)" in body and
        "context.prepareStampedMeshImage(layer, candidate," in body and
        "context.prepareUpload(mainUpload, candidate)" in body and
        "context.prepareDestroy(previewDestroy)" in body and
        "cmd.setSnapshots(pre, MeshSnapshot.capture(candidate), \"Mirror\");" in body and
        "context.prepareGestureCarrierMismatch()" in body and
        "context.markHistoryInstall()" in body and
        "context.markNoHistoryInstall()" in body and
        "context.prepareMirrorDeactivate(stateOwner)" in body and
        body.find("context.prepareStampedMeshImage(layer, candidate,") <
            body.find("context.prepareUpload(mainUpload, candidate)") <
            body.find("context.prepareDestroy(previewDestroy)") <
            body.find("context.markHistoryInstall()") <
            body.find("context.prepareMirrorDeactivate(stateOwner)") and
        "PreparedDeactivateKind.Mirror, historyPrepared, ok);" in body)
if not mirror_deactivate_producer_gate(mirror_activation_tool,
                                       mirror_deactivate_effect):
    fail("Mirror deactivation producer contract drift")
for target, old, new, label in (
    ("tool", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("tool", "&layer.meshRef() is mesh", "true", "drop layer identity"),
    ("tool", "ownsPreparedPreviewDestroy(previewDestroy)", "true", "drop preview identity"),
    ("tool", "beginPreparedShadow(candidate)", "beginPreparedShadow(*mesh)", "drop detached shadow"),
    ("tool", "drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);", "", "drop delivery capture"),
    ("tool", "ownsPreparedMainUpload(mainUpload)", "true", "drop main GPU identity"),
    ("tool", "context.prepareStampedMeshImage(layer, candidate,", "false /* dropped mesh enlist */ (", "drop mesh enlist"),
    ("tool", "context.prepareUpload(mainUpload, candidate)", "true", "drop GPU upload"),
    ("tool", "context.prepareDestroy(previewDestroy)", "true", "drop preview destroy"),
    ("tool", "context.prepareGestureCarrierMismatch()", "true", "drop carrier diagnostic"),
    ("tool", "context.markHistoryInstall()", "true", "drop history marker"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop no-history marker"),
    ("tool", "context.prepareMirrorDeactivate(stateOwner)", "true", "drop final state"),
    ("effect", "Mirror,", "None,", "drop closed effect kind"),
):
    t, e = mirror_activation_tool, mirror_deactivate_effect
    if target == "effect": e = e.replace(old, new, 1)
    else:
        pos = t.find(old, t.find("final PreparedDeactivateEffect prepareDeactivate("))
        if pos < 0: pos = t.find(old)
        if pos >= 0: t = t[:pos] + new + t[pos + len(old):]
    if mirror_deactivate_producer_gate(t, e):
        fail(f"Mirror deactivation producer mutation did not RED: {label}")

edge_extend_tool_activation_owner = (
    ROOT / "source/prepared_edge_extend_tool_activation.d").read_text()
edge_extend_tool_activation_tool = (
    ROOT / "source/tools/edit/edge_extend.d").read_text()
def edge_extend_tool_activation_gate(owner, context, tool):
    return (owner.count("@disable this(this)") == 4 and
        "final class PreparedEdgeExtendToolActivationOwner" in owner and
        "target.classinfo !is EdgeExtendTool.classinfo" in owner and
        "result.image_ = target.buildPreparedActivation(result.source_);" in owner and
        "PreparedXfrmActivationSessionOwner.prepare(" in owner and
        "PreparedTransformProductActivationOwner.prepare(" in owner and
        "if (!result.image_.moveHandle)" in owner and
        "target_.preparedActivationMesh() !is source_" in owner and
        "!image_.baseline.matches(*source_)" in owner and
        "xfrmOwner_.owns(target_.preparedEmbeddedXfrm())" in owner and
        "target_.preparedActivationBanksMatch(image_.moveHandle" in owner and
        "target_.installPreparedActivationPre(image_);" in owner and
        "if (extraMoveOwner_ !is null) extraMoveOwner_.install();" in owner and
        "target_.installPreparedActivationPost(image_);" in owner and
        "if (xfrmOwner_ !is null) xfrmOwner_.abort();" in owner and
        "image.baseline = MeshSnapshot.capture(*source);" in tool and
        "image.pivot = source.selectionBBoxCenterEdges();" in tool and
        "image.moveHandle = moveHandle_; image.rotateHandle = rotateHandle_;" in tool and
        "active = true;" in tool and
        "xfrm.flagT = image.moveHandle; xfrm.flagR = image.rotateHandle;" in tool and
        "built = false; dragBank = DragBank.None; preview_.reset();" in tool and
        "image.baseline.moveInto(before); initPivot_ = image.pivot;" in tool and
        "context.prepareEdgeExtendToolActivationPre(owner)" in tool and
        "context.prepareXfrmActivationPre(xfrmOwner)" in tool and
        "context.markNoHistoryInstall()" in tool and
        "context.prepareXfrmActivationPost(xfrmOwner)" in tool and
        "context.prepareEdgeExtendToolActivationPost(owner)" in tool and
        tool.find("context.prepareEdgeExtendToolActivationPre(owner)") <
            tool.find("context.prepareXfrmActivationPre(xfrmOwner)") <
            tool.find("context.markNoHistoryInstall()", tool.find("context.prepareXfrmActivationPre(xfrmOwner)")) <
            tool.find("context.prepareXfrmActivationPost(xfrmOwner)") <
            tool.find("context.prepareEdgeExtendToolActivationPost(owner)") and
        "PreparedActivateKind.EdgeExtend, ok);" in tool and
        "EdgeExtendToolActivationPreState" in context and
        "EdgeExtendToolActivationPostState" in context and
        "e.edgeExtendToolActivation.validatePre();" in context and
        "e.edgeExtendToolActivation.validatePost();" in context and
        "e.edgeExtendToolActivation.installPre();" in context and
        "e.edgeExtendToolActivation.installPost();" in context and
        "e.edgeExtendToolActivation.abort();" in context)
if not edge_extend_tool_activation_gate(edge_extend_tool_activation_owner,
                                        record_context,
                                        edge_extend_tool_activation_tool):
    fail("EdgeExtend activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is EdgeExtendTool.classinfo", "false", "broaden product"),
    ("owner", "if (!result.image_.moveHandle)", "if (false)", "drop off-bank haul activation"),
    ("owner", "target_.preparedActivationMesh() !is source_", "false", "drop Mesh identity"),
    ("owner", "!image_.baseline.matches(*source_)", "false", "drop content validation"),
    ("owner", "xfrmOwner_.owns(target_.preparedEmbeddedXfrm())", "true", "drop embedded Xfrm identity"),
    ("owner", "target_.preparedActivationBanksMatch(image_.moveHandle", "true || /*", "drop bank identity"),
    ("owner", "target_.installPreparedActivationPre(image_);", "", "drop outer pre install"),
    ("owner", "if (extraMoveOwner_ !is null) extraMoveOwner_.install();", "", "drop off-bank Move install"),
    ("owner", "target_.installPreparedActivationPost(image_);", "", "drop outer post install"),
    ("owner", "if (xfrmOwner_ !is null) xfrmOwner_.abort();", "", "drop nested abort"),
    ("tool", "image.baseline = MeshSnapshot.capture(*source);", "", "drop baseline"),
    ("tool", "image.pivot = source.selectionBBoxCenterEdges();", "", "drop frozen pivot"),
    ("tool", "image.moveHandle = moveHandle_; image.rotateHandle = rotateHandle_;", "", "drop bank capture"),
    ("tool", "xfrm.flagT = image.moveHandle; xfrm.flagR = image.rotateHandle;", "", "drop bank pre install"),
    ("tool", "built = false; dragBank = DragBank.None; preview_.reset();", "built = false;", "drop session reset"),
    ("tool", "image.baseline.moveInto(before); initPivot_ = image.pivot;", "", "drop baseline/pivot transfer"),
    ("tool", "context.prepareEdgeExtendToolActivationPre(owner)", "true", "drop outer pre arm"),
    ("tool", "context.prepareXfrmActivationPre(xfrmOwner)", "true", "drop Xfrm pre arm"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory marker"),
    ("tool", "context.prepareXfrmActivationPost(xfrmOwner)", "true", "drop Xfrm post arm"),
    ("tool", "context.prepareEdgeExtendToolActivationPost(owner)", "true", "drop outer post arm"),
    ("context", "e.edgeExtendToolActivation.validatePre();", "true;", "drop context pre validation"),
    ("context", "e.edgeExtendToolActivation.validatePost();", "true;", "drop context post validation"),
    ("context", "e.edgeExtendToolActivation.installPre();", "", "drop context pre install"),
    ("context", "e.edgeExtendToolActivation.installPost();", "", "drop context post install"),
    ("context", "e.edgeExtendToolActivation.abort();", "", "drop context abort"),
):
    o, c, t = edge_extend_tool_activation_owner, record_context, edge_extend_tool_activation_tool
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: t = t.replace(old, new, 1)
    if edge_extend_tool_activation_gate(o, c, t):
        fail(f"EdgeExtend activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_edge_extend_tool_activation_pre_token_copy.d",
    ROOT / "tests/compile_fail/prepared_edge_extend_tool_activation_post_token_copy.d",
    ROOT / "tests/compile_fail/prepared_edge_extend_tool_activation_validated_pre_token_copy.d",
    ROOT / "tests/compile_fail/prepared_edge_extend_tool_activation_validated_post_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("EdgeExtend activation token copy was not rejected:\n" + run.stdout)

topology_pen_activation_owner = (
    ROOT / "source/prepared_topology_pen_activation.d").read_text()
topology_pen_activation_tool = (
    ROOT / "source/tools/edit/topology_pen/tool.d").read_text()
topology_pen_snap = (ROOT / "source/toolpipe/stages/snap.d").read_text()
topology_pen_constrain = (ROOT / "source/toolpipe/stages/constrain.d").read_text()
topology_pen_pipeline = (ROOT / "source/toolpipe/pipeline.d").read_text()
topology_pen_popup = (ROOT / "source/popup_state.d").read_text()
def topology_pen_activation_gate(owner, context, tool, snap, constrain,
                                 pipeline, popup):
    activation_start = tool.find(
        "final PreparedSessionActivateEffect prepareActivate")
    activation_end = tool.find(
        "version(unittest) final void seedPreparedActivationForTest",
        activation_start)
    activation = tool[activation_start:activation_end]
    activation_state_start = tool.find(
        "final PreparedTopologyPenActivationImage buildPreparedActivation")
    activation_state = tool[activation_state_start:activation_end]
    return (owner.count("@disable this(this)") == 2 and
        "final class PreparedTopologyPenActivationOwner" in owner and
        "target.classinfo !is TopologyPenTool.classinfo" in owner and
        "result.pipe_ = g_pipeCtx;" in owner and
        "capturePreparedPushProjection()" in owner and
        "capturePreparedCompositionProjection()" in owner and
        "g_pipeCtx !is pipe_" in owner and
        "pipeline.ownsTaskStage(TaskCode.Snap, snap_)" in owner and
        "pipeline.ownsTaskStage(TaskCode.Cons, constrain_)" in owner and
        "matchesPreparedPushProjection(snapProjection_)" in owner and
        "matchesPreparedCompositionProjection(" in owner and
        "target_.installPreparedActivation(image_);" in owner and
        "snap_.installPreparedPushEnabled(snapOwner_, true);" in owner and
        "!constrainProjection_.userLocked" in owner and
        "constrain_.installPreparedPointComposition();" in owner and
        owner.find("target_.installPreparedActivation(image_);") <
            owner.find("snap_.installPreparedPushEnabled(snapOwner_, true);") <
            owner.find("constrain_.installPreparedPointComposition();") and
        "image.expectedHit = lastHit_; image.expectedTarget = lastTarget_;" in activation_state and
        "image.expectedDecline = slideDecline_;" in activation_state and
        "image.expectedDeclineSeed = slideDeclineSeed_;" in activation_state and
        "lastHit_ = ConstrainHitPacket.init; lastTarget_ = HoverTarget.init;" in activation_state and
        "slideDecline_ = SlideDecline.None; slideDeclineSeed_ = -1;" in activation_state and
        "context.prepareTopologyPenActivation(owner)" in tool and
        activation.count("context.markNoHistoryInstall()") == 1 and
        tool.find("context.prepareTopologyPenActivation(owner)") <
            tool.find("context.markNoHistoryInstall()", tool.find("context.prepareTopologyPenActivation(owner)")) and
        "PreparedActivateKind.TopologyPen, ok);" in tool and
        "TopologyPenActivationState" in context and
        "e.topologyPenActivation.validate();" in context and
        "e.topologyPenActivation.install();" in context and
        "e.topologyPenActivation.abort();" in context and
        "PreparedSnapPushProjection capturePreparedPushProjection()" in snap and
        "matchesPreparedPushProjection" in snap and
        "installPreparedPushEnabled(string owner, bool value) nothrow" in snap and
        "PreparedConstrainCompositionProjection capturePreparedCompositionProjection()" in constrain and
        "matchesPreparedCompositionProjection" in constrain and
        "installPreparedPointComposition() nothrow" in constrain and
        "bool ownsTaskStage(TaskCode task, Stage expected) const nothrow @nogc" in pipeline and
        "void installPreparedStatePath(string path, string value) nothrow" in popup)
if not topology_pen_activation_gate(topology_pen_activation_owner, record_context,
        topology_pen_activation_tool, topology_pen_snap, topology_pen_constrain,
        topology_pen_pipeline, topology_pen_popup):
    fail("TopologyPen activation prepared contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is TopologyPenTool.classinfo", "false", "broaden product"),
    ("owner", "result.pipe_ = g_pipeCtx;", "result.pipe_ = null;", "drop pipeline capture"),
    ("owner", "g_pipeCtx !is pipe_", "false", "drop pipeline identity"),
    ("owner", "pipeline.ownsTaskStage(TaskCode.Snap, snap_)", "true", "drop Snap stage identity"),
    ("owner", "pipeline.ownsTaskStage(TaskCode.Cons, constrain_)", "true", "drop CONS stage identity"),
    ("owner", "matchesPreparedPushProjection(snapProjection_)", "true", "drop Snap projection"),
    ("owner", "matchesPreparedCompositionProjection(", "true || (", "drop CONS projection"),
    ("owner", "target_.installPreparedActivation(image_);", "", "drop local reset"),
    ("owner", "snap_.installPreparedPushEnabled(snapOwner_, true);", "", "drop Snap arm"),
    ("owner", "!constrainProjection_.userLocked", "false", "drop unlocked composition"),
    ("owner", "constrain_.installPreparedPointComposition();", "", "drop CONS composition"),
    ("tool", "image.expectedHit = lastHit_; image.expectedTarget = lastTarget_;", "", "drop local capture"),
    ("tool", "slideDecline_ = SlideDecline.None; slideDeclineSeed_ = -1;", "", "drop local install"),
    ("tool", "context.prepareTopologyPenActivation(owner)", "true", "drop owner arm"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory seal"),
    ("context", "e.topologyPenActivation.validate();", "true;", "drop context validation"),
    ("context", "e.topologyPenActivation.install();", "", "drop context install"),
    ("context", "e.topologyPenActivation.abort();", "", "drop context abort"),
    ("snap", "installPreparedPushEnabled(string owner, bool value) nothrow", "installPreparedPushEnabled(string owner, bool value)", "drop Snap nothrow"),
    ("constrain", "installPreparedPointComposition() nothrow", "installPreparedPointComposition()", "drop CONS nothrow"),
    ("pipeline", "ownsTaskStage(TaskCode task, Stage expected) const nothrow @nogc", "ownsTaskStage(TaskCode task, Stage expected) const", "drop stage-check guarantees"),
    ("popup", "installPreparedStatePath(string path, string value) nothrow", "installPreparedStatePath(string path, string value)", "drop popup nothrow"),
):
    o, c, t = topology_pen_activation_owner, record_context, topology_pen_activation_tool
    s, co, p, po = topology_pen_snap, topology_pen_constrain, topology_pen_pipeline, topology_pen_popup
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    elif target == "tool": t = t.replace(old, new, 1)
    elif target == "snap": s = s.replace(old, new, 1)
    elif target == "constrain": co = co.replace(old, new, 1)
    elif target == "pipeline": p = p.replace(old, new, 1)
    else: po = po.replace(old, new, 1)
    if topology_pen_activation_gate(o, c, t, s, co, p, po):
        fail(f"TopologyPen activation mutation did not RED: {label}")
for fixture in (
    ROOT / "tests/compile_fail/prepared_topology_pen_activation_token_copy.d",
    ROOT / "tests/compile_fail/prepared_topology_pen_activation_validated_token_copy.d",
):
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(fixture)], cwd=ROOT,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("TopologyPen activation token copy was not rejected:\n" + run.stdout)

# P1.0b.5d.1 infrastructure only: a closed four-kind private-state journal,
# detached whole-Mesh adoption with exact caller-supplied change flags, and a
# frozen Primitive product/reset projection set. Install never dispatches the
# legacy resetSession virtual.
b5d1_sources = {
    "owner": (ROOT / "source/prepared_private_state.d").read_text(),
    "context": record_context,
    "document": (ROOT / "source/document.d").read_text(),
    "primitive": (ROOT / "source/tools/create/primitive_create_tool.d").read_text(),
    "sphere": (ROOT / "source/tools/create/sphere.d").read_text(),
}
primitive_products = sorted(
    str(p.relative_to(ROOT)) for p in (ROOT / "source/tools/create").glob("*.d")
    if re.search(r"final class \w+\s*:\s*(?:PrimitiveCreateTool|HandledCreateTool|SizedRadialCreateTool)",
                 p.read_text()))
expected_primitive_products = [
    "source/tools/create/capsule.d", "source/tools/create/cone.d",
    "source/tools/create/cylinder.d", "source/tools/create/sphere.d",
    "source/tools/create/torus.d", "source/tools/create/tube.d",
]
def b5d1_gate(s):
    return ("enum PreparedPrivateStateKind : ubyte" in s["owner"] and
            all(kind in s["owner"] for kind in
                ("Box, BoxDeactivate, Pen, PenDeactivate, PenParam, Primitive, PrimitiveDeactivate,", "Vertex", "ArraySession", "CloneSession",
                 "MagnetSession", "ReductionSession")) and
            s["owner"].count("@disable this(this)") == 2 and
            "delegate" not in s["owner"] and "void*" not in s["owner"] and
            "cast(void*)" not in s["owner"] and
            "void install() nothrow @nogc" in s["owner"] and
            "validatedToken.generation != generation" in s["owner"] and
            "BoxTool boxTarget;" in s["owner"] and "PenTool penTarget;" in s["owner"] and
            "SphereTool sphereTarget;" in s["owner"] and "VertexTool vertexTarget;" in s["owner"] and
            "boxTarget.installPreparedPrivateActivation();" in s["owner"] and
            "penTarget.installPreparedPrivateActivation();" in s["owner"] and
            "sphereTarget.installPreparedSphereReset(sphereClearMethod, sphereAxis);" in s["owner"] and
            "vertexTarget.installPreparedPrivateDeactivate();" in s["owner"] and
            s["owner"].count("pending = validated = false;") == 2 and
            "bool preparePrivateState(PreparedPrivateStateOwner owner)" in s["context"] and
            "bool prepareMeshImageCommit(Layer layer, ref const Mesh image, uint flags)" in s["context"] and
            s["context"].count("layer.replaceEnlistedShadow(image)") >= 1 and
            s["context"].count("layer.enlistedShadow().commitChange(flags)") == 1 and
            s["context"].count("PreparedDeliveryJournal.prepare([spec])") == 2 and
            s["context"].find("layer.replaceEnlistedShadow(image)") <
                s["context"].find("layer.enlistedShadow().commitChange(flags)") <
                s["context"].find("PreparedDeliveryJournal.prepare([spec])") and
            "bool replaceEnlistedShadow(ref const Mesh image)" in s["document"] and
            "final void installPreparedPrimitiveReset() nothrow @nogc" in s["primitive"] and
            "final void installHandledResetProjection() nothrow @nogc" in s["primitive"] and
            "final void installPreparedSphereReset(bool clearMethod, int nextAxis)" in s["sphere"] and
            "installPreparedRadialActivationPre();" in s["sphere"] and
            primitive_products == expected_primitive_products)
if not b5d1_gate(b5d1_sources):
    fail("P1.0b.5d.1 private-state/topology infrastructure drift")
for name, old, new, label in (
    ("owner", "@disable this(this);", "", "make private-state token copyable"),
    ("owner", "validatedToken.generation != generation", "false", "drop one-shot generation"),
    ("owner", "pending = validated = false;", "",
     "drop private-state consumption"),
    ("owner", "BoxTool boxTarget;", "void* boxTarget;",
     "smuggle untyped target"),
    ("owner", "private enum PrimitiveProjection", "alias Smuggled = void delegate();\nprivate enum PrimitiveProjection",
     "smuggle caller behavior"),
    ("context", "layer.replaceEnlistedShadow(image)", "true", "drop detached Mesh image"),
    ("context", "layer.enlistedShadow().commitChange(flags)", "",
     "drop exact Mesh flags"),
    ("context", "PreparedDeliveryJournal.prepare([spec])", "null",
     "drop topology delivery preparation"),
    ("sphere", "installPreparedRadialActivationPre();", "", "drop inherited leaf reset"),
):
    mutant = dict(b5d1_sources); mutant[name] = mutant[name].replace(old, new, 1)
    if mutant[name] == b5d1_sources[name] or b5d1_gate(mutant):
        fail(f"P1.0b.5d.1 named mutation did not RED: {label}")
for path in (ROOT / "source/tools").rglob("*.d"):
    body = path.read_text()
    if (".preparePrivateState(" in body or ".prepareMeshImageCommit(" in body) and \
            path.relative_to(ROOT).as_posix() not in {
                "source/tools/create/vertex_place.d",
                "source/tools/create/arc.d",
                "source/tools/alignment/array_tool.d",
                "source/tools/alignment/clone_tool.d",
                "source/tools/deform/magnet.d",
                "source/tools/edit/reduce.d",
                "source/tools/alignment/radial_sweep_tool.d",
                "source/tools/create/box.d",
                "source/tools/create/pen.d",
                "source/tools/create/primitive_create_tool.d"}:
        fail(f"P1.0b.5d.1 dormant infrastructure has hook caller: {path.relative_to(ROOT)}")

# P1.0b.5d.2 first fully closed root: Vertex deactivate preserves the exact
# snap-global -> private-field order without introducing an empty history
# transition. The no-history marker consumes the prepared history image and is
# mutually exclusive with HistoryInstall.
b5d2_vertex = (ROOT / "source/tools/create/vertex_place.d").read_text()
def b5d2_gate(context, vertex):
    start = vertex.find("final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context,")
    end = vertex.find("override bool prepareDoorDeactivate", start)
    product = vertex[start:end]
    return ("HistoryInstall, NoHistoryInstall," in context and
            "bool markNoHistoryInstall()" in context and
            "if (history_ !is null) history_.discardPreparedToken(token_);\n"
            "            installedHistory = true;" in context and
            "if (historyMarker_) return true;" in context and
            "if (noHistoryMarker_) return true;" in context and
            "history_ is null || noHistoryMarker_" in context and
            "final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context," in vertex and
            product.count("context.prepareSnapClear(snapOwner)") == 1 and
            product.count("context.preparePrivateState(stateOwner)") == 1 and
            product.count("context.markNoHistoryInstall()") == 1 and
            product.find("context.prepareSnapClear(snapOwner)") <
                product.find("context.preparePrivateState(stateOwner)") <
                product.find("context.markNoHistoryInstall()") and
            "stateOwner.owns(this)" in product and
            "if (!accepted && context !is null) context.discard();" in product)
if not b5d2_gate(record_context, b5d2_vertex):
    fail("P1.0b.5d.2 Vertex deactivate contract drift")
for target, old, new, label in (
    ("context", "history_ is null || noHistoryMarker_", "history_ is null",
     "allow both history seals"),
    ("context", "if (historyMarker_) return true;", "",
     "drop idempotent history seal"),
    ("context", "if (noHistoryMarker_) return true;", "",
     "drop idempotent no-history seal"),
    ("context", "if (history_ !is null) history_.discardPreparedToken(token_);\n"
     "            installedHistory = true;",
     "installedHistory = true;", "drop empty history consumption"),
    ("vertex", "stateOwner.owns(this)", "true", "drop Vertex owner identity"),
    ("vertex", "context.prepareSnapClear(snapOwner)", "true", "drop snap clear"),
    ("vertex", "context.preparePrivateState(stateOwner)", "true", "drop private reset"),
    ("vertex", "context.markNoHistoryInstall()", "true", "drop no-history seal"),
    ("vertex", "if (!accepted && context !is null) context.discard();", "",
     "drop terminal refusal"),
):
    c, v = record_context, b5d2_vertex
    if target == "context": c = c.replace(old, new, 1)
    else: v = v.replace(old, new, 1)
    if (c == record_context and v == b5d2_vertex) or b5d2_gate(c, v):
        fail(f"P1.0b.5d.2 named mutation did not RED: {label}")

# P1.0b.5e isolated activation-session image infrastructure. Exactly four
# concrete products share the closed flags + detached MeshSnapshot effect;
# no lifecycle hook calls these owners before producer review.
b5e_owner = (ROOT / "source/prepared_private_state.d").read_text()
b5e_context = record_context
b5e_tools = {
    name: (ROOT / path).read_text() for name, path in {
        "array": "source/tools/alignment/array_tool.d",
        "clone": "source/tools/alignment/clone_tool.d",
        "magnet": "source/tools/deform/magnet.d",
        "reduction": "source/tools/edit/reduce.d",
    }.items()
}
b5e_snapshot = (ROOT / "source/snapshot.d").read_text()
def b5e_gate(owner, context, sources, snapshot=b5e_snapshot):
    return (all(kind in owner for kind in
                ("ArraySession", "CloneSession", "MagnetSession", "ReductionSession")) and
            "MeshSnapshot activationBaseline;" in owner and
            owner.count("target.classinfo !is") == 9 and
            "o.activationBaseline = image;" in owner and
            "failSessionPrepareForTest_" in owner and
            all(f"{prefix}Target.installPreparedActivation(activationBaseline);" in owner
                for prefix in ("array", "clone", "magnet", "reduction")) and
            all("final MeshSnapshot prepareActivationBaseline()" in source and
                "final void installPreparedActivation(ref MeshSnapshot image) nothrow @nogc" in source and
                "image.moveInto(before);" in source
                for source in sources.values()) and
            "activationBaseline = MeshSnapshot.init;" in owner and
            owner.count("&& activationBaseline.filled") == 4 and
            "void moveInto(ref MeshSnapshot destination) nothrow @nogc" in snapshot and
            "this = MeshSnapshot.init;" in snapshot and
            "active = true; built = false; image.moveInto(before);" in sources["reduction"] and
            "active = true; built = false; dragging = false; pickedVi = -1;" in sources["magnet"] and
            all(kind in context for kind in
                ("ArraySessionState", "CloneSessionState", "MagnetSessionState",
                 "ReductionSessionState")))
if not b5e_gate(b5e_owner, b5e_context, b5e_tools):
    fail("P1.0b.5e activation-session image owner drift")
for target, old, new, label in (
    ("owner", "MeshSnapshot activationBaseline;", "MeshSnapshot* activationBaseline;",
     "alias activation baseline"),
    ("owner", "target.classinfo !is CloneTool.classinfo", "false",
     "admit derived Clone product"),
    ("owner", "o.activationBaseline = image;", "",
     "drop detached image retention"),
    ("owner", "reductionTarget.installPreparedActivation(activationBaseline);", "",
     "drop fixed Reduction install"),
    ("owner", "activationBaseline = MeshSnapshot.init;", "",
     "omit abort payload clear"),
    ("owner", "&& activationBaseline.filled", "",
     "re-arm consumed session owner"),
    ("snapshot", "this = MeshSnapshot.init;", "",
     "omit move-source payload clear"),
    ("reduction", "image.moveInto(before);", "before = image;",
     "shallow-copy snapshot descriptor"),
    ("reduction", "active = true; built = false; image.moveInto(before);",
     "active = true; image.moveInto(before);", "drop private built reset"),
):
    owner, context, sources, snapshot = b5e_owner, b5e_context, dict(b5e_tools), b5e_snapshot
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "snapshot": snapshot = snapshot.replace(old, new, 1)
    else: sources[target] = sources[target].replace(old, new, 1)
    if ((owner == b5e_owner and sources == b5e_tools and snapshot == b5e_snapshot) or
            b5e_gate(owner, context, sources, snapshot)):
        fail(f"P1.0b.5e named mutation did not RED: {label}")
for source in b5e_tools.values():
    for hook in ("override void activate()",):
        start = source.find(hook)
        if start >= 0:
            body_start = source.find("{", start) + 1
            body = source[body_start:balanced_source(source, body_start)-1]
            if "PreparedPrivateStateOwner" in body or "preparePrivateState" in body:
                fail("P1.0b.5e owner reached from production activation hook")

# P1.0b.5f four dormant activation producers: private session image first,
# then explicit no-history token consumption. Legacy hooks remain sole callers.
def b5f_gate(sources):
    for name, source in sources.items():
        expected_kind = {"array":"Array", "clone":"Clone", "magnet":"Magnet",
                         "reduction":"Reduction"}[name]
        start = source.find("final PreparedSessionActivateEffect prepareActivate(")
        end = source.find("version(unittest)", start)
        producer = source[start:end]
        if (start < 0 or producer.count("owner.owns(this)") != 1 or
            producer.count("context.preparePrivateState(owner)") != 1 or
            producer.count("context.markNoHistoryInstall()") != 1 or
            producer.find("context.preparePrivateState(owner)") >
                producer.find("context.markNoHistoryInstall()") or
            "if (!accepted && context !is null) context.discard();" not in producer or
            f"PreparedActivateKind.{expected_kind}, accepted" not in producer):
            return False
    return True
if not b5f_gate(b5e_tools):
    fail("P1.0b.5f activation producer contract drift")
for name, old, new, label in (
    ("array", "owner.owns(this)", "true", "drop Array identity"),
    ("clone", "context.preparePrivateState(owner)", "true", "drop Clone install"),
    ("magnet", "context.markNoHistoryInstall()", "true", "drop Magnet history seal"),
    ("reduction", "if (!accepted && context !is null) context.discard();", "",
     "drop Reduction terminal refusal"),
    ("array",
     "context.preparePrivateState(owner) && context.markNoHistoryInstall()",
     "context.markNoHistoryInstall() && context.preparePrivateState(owner)",
     "reorder Array history before state"),
):
    mutant = dict(b5e_tools); mutant[name] = mutant[name].replace(old, new, 1)
    if mutant[name] == b5e_tools[name] or b5f_gate(mutant):
        fail(f"P1.0b.5f named mutation did not RED: {label}")
for name, source in b5e_tools.items():
    match = re.search(r"override\s+void\s+activate\s*\(\)\s*\{", source)
    body = source[match.end():balanced_source(source, match.end())-1]
    if "prepareActivate(" in body or "preparePrivateState(" in body:
        fail(f"P1.0b.5f {name} legacy activation calls dormant producer")

# P1.0b.5g isolated closed Radial Sweep selection/profile session owner.
b5g_owner = (ROOT / "source/prepared_selection_profile.d").read_text()
b5g_image = (ROOT / "source/prepared_selection_profile_image.d").read_text()
b5g_tool = (ROOT / "source/tools/alignment/radial_sweep_tool.d").read_text()
def b5g_gate(owner, image, context, tool):
    forbidden = ("void*", "delegate", "function(", "Variant", "ubyte[] payload")
    return (not any(x in without_unittests(owner) for x in forbidden) and
            "RadialSweepTool target_;" in owner and
            "target_ is target" in owner and
            "target.classinfo !is RadialSweepTool.classinfo" in owner and
            "RadialSweepProfileImage image_;" in owner and
            "MeshSnapshot mesh;" in image and "uint[] profile;" in image and
            "SessionMeshKey sessionKey;" in image and
            "source.extractSelectedEdgeChain(owner.image_.closed)" in owner and
            "source.faceVertexRing(selected[0]).dup" in owner and
            "owner.image_.valid = owner.image_.profile.length >= 3;" in owner and
            "bool begin() nothrow @nogc" in owner and
            "void install() nothrow @nogc" in owner and
            "void abort() nothrow @nogc" in owner and
            owner.count("consumed_ = true") >= 2 and
            owner.count("consumed_ = true; begun_ = false; target_ = null; image_.clear();") == 2 and
            "target_.installPreparedSelectionProfile(image_);" in owner and
            "target_ = null; image_.clear();" in owner and
            "final void installPreparedSelectionProfile(ref RadialSweepProfileImage image)" in tool and
            "image.mesh.moveInto(baseSnap);" in tool and
            "profile_ = image.profile; image.profile = null;" in tool and
            "RadialSweepProfileState" in context and
            "bool prepareSelectionProfile(PreparedSelectionProfileOwner owner)" in context and
            "e.selectionProfile.install();" in context and
            "e.selectionProfile.abort();" in context)
if not b5g_gate(b5g_owner, b5g_image, b5e_context, b5g_tool):
    fail("P1.0b.5g selection-profile owner drift")
for target, old, new, label in (
    ("owner", "target_ is target", "true", "drop exact target identity"),
    ("owner", "target.classinfo !is RadialSweepTool.classinfo", "false", "admit behaviorful derived product"),
    ("owner", "owner.image_.profile.length >= 3", "owner.image_.profile.length >= 2", "weaken polygon arity threshold"),
    ("owner", "source.faceVertexRing(selected[0]).dup", "source.faceVertexRing(selected[0])", "alias profile"),
    ("owner", "consumed_ = true; begun_ = false; target_ = null; image_.clear();", "begun_ = false;", "re-arm installed owner"),
    ("owner", "target_.installPreparedSelectionProfile(image_);", "", "drop fixed install"),
    ("tool", "image.mesh.moveInto(baseSnap);", "", "drop detached mesh install"),
    ("tool", "profile_ = image.profile; image.profile = null;", "profile_ = image.profile;", "omit profile transfer scrub"),
    ("context", "e.selectionProfile.abort();", "", "drop context abort"),
):
    owner, image, context, tool = b5g_owner, b5g_image, b5e_context, b5g_tool
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "tool": tool = tool.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if b5g_gate(owner, image, context, tool):
        fail(f"P1.0b.5g named mutation did not RED: {label}")
for hook in ("override void activate()", "override void resyncSession()"):
    start = b5g_tool.find(hook); body_start = b5g_tool.find("{", start) + 1
    body = b5g_tool[body_start:balanced_source(b5g_tool, body_start)-1]
    if "PreparedSelectionProfileOwner" in body or "prepareSelectionProfile" in body:
        fail("P1.0b.5g owner reached from production hook")

# P1.0b.5h isolated full Radial Sweep private transition owner.
b5h_owner = (ROOT / "source/prepared_radial_sweep_transition.d").read_text()
def b5h_gate(owner, context, tool):
    production = without_unittests(owner)
    ds = tool.find("final RadialSweepTransitionImage buildPreparedDeactivateImage()")
    db = tool.find("{", ds) + 1
    deactivate_builder = tool[db:balanced_source(tool, db)-1] if ds >= 0 else ""
    ps = tool.find("final RadialSweepTransitionImage buildPreparedParamImage(string name)")
    pb = tool.find("{", ps) + 1
    param_builder = tool[pb:balanced_source(tool, pb)-1] if ps >= 0 else ""
    return ("enum PreparedRadialSweepTransitionKind : ubyte { Activate, Param, Deactivate }" in tool and
            not any(x in production for x in ("void*", " delegate", " function(", "ubyte[]")) and
            "RadialSweepTool target_;" in owner and
            "RadialSweepTransitionImage image_;" in owner and
            "target.classinfo is RadialSweepTool.classinfo" in owner and
            "ref const(Mesh) previewForGpuUpload()" in owner and
            "target_.installPreparedTransition(image_);" in owner and
            owner.count("target_ = null; image_.clear();") == 2 and
            "struct RadialSweepTransitionImage" in tool and
            "PreparedRadialSweepTransitionKind kind;" in tool and
            "bool engaged, havePreviewCache, hasPreview, clearHaul, valid;" in tool and
            "baseSnap.restore(detachedBase);" in tool and
            "result.profile.profile = profile_.dup;" in tool and
            "final void installPreparedTransition(ref RadialSweepTransitionImage image)" in tool and
            "profile_ = image.profile.profile; image.profile.profile = null;" in tool and
            "if (image.hasPreview)" in tool and
            "previewMesh = image.previewMesh; image.previewMesh = Mesh.init;" in tool and
            "if (image.kind == PreparedRadialSweepTransitionKind.Deactivate)" in tool and
            "engaged = false; havePreviewCache = false; image.clear(); return;" in tool and
            "result.kind = PreparedRadialSweepTransitionKind.Deactivate;" in tool and
            "result.engaged = false; result.havePreviewCache = false;" in tool and
            "previewMesh" not in deactivate_builder and "MeshSnapshot" not in deactivate_builder and
            "clearHaul" not in deactivate_builder and
            "result.hasPreview = true; result.clearHaul = true;" in tool and
            "result.clearHaul" not in param_builder and
            "if (len < 1e-6f) len = 1.0f;" in param_builder and
            "case 0: result.params.axis = Vec3(len, 0, 0);" in tool and
            "case 1: result.params.axis = Vec3(0, len, 0);" in tool and
            "case 2: result.params.axis = Vec3(0, 0, len);" in tool and
            "else if (name == \"axis\") result.params.axisPreset = 3;" in tool and
            "if (image.clearHaul) toolHandles.clearHaul();" in tool and
            "RadialSweepTransitionState" in context and
            "bool prepareRadialSweepTransition(PreparedRadialSweepTransitionOwner owner)" in context and
            "e.radialSweepTransition.install();" in context and
            "e.radialSweepTransition.abort();" in context)
if not b5h_gate(b5h_owner, b5e_context, b5g_tool):
    fail("P1.0b.5h Radial Sweep transition owner drift")
for target, old, new, label in (
    ("owner", "target.classinfo is RadialSweepTool.classinfo", "target !is null", "admit derived target"),
    ("owner", "target_.installPreparedTransition(image_);", "", "drop fixed install"),
    ("owner", "target_ = null; image_.clear();", "", "retain consumed payload"),
    ("tool", "baseSnap.restore(detachedBase);", "", "alias parameter base"),
    ("tool", "result.profile.profile = profile_.dup;", "result.profile.profile = profile_;", "alias parameter profile"),
    ("tool", "image.profile.profile = null;", "", "omit profile source scrub"),
    ("tool", "image.previewMesh = Mesh.init;", "", "omit preview source scrub"),
    ("tool", "if (image.hasPreview)", "if (true)", "drop explicit preview obligation"),
    ("tool", "if (image.clearHaul) toolHandles.clearHaul();", "", "drop exact haul branch"),
    ("tool", "result.kind = PreparedRadialSweepTransitionKind.Param;", "result.kind = PreparedRadialSweepTransitionKind.Param; result.clearHaul = true;", "add Param haul clear"),
    ("tool", "if (len < 1e-6f) len = 1.0f;", "len = 1.0f;", "remove collapsed-axis guard"),
    ("tool", "if (len < 1e-6f) len = 1.0f;", "if (len <= 1e-6f) len = 1.0f;", "change collapsed-axis boundary"),
    ("tool", "case 0: result.params.axis = Vec3(len, 0, 0);", "case 0: result.params.axis = Vec3(0, len, 0);", "break X quick-axis formula"),
    ("tool", "case 1: result.params.axis = Vec3(0, len, 0);", "case 1: result.params.axis = Vec3(len, 0, 0);", "break Y quick-axis formula"),
    ("tool", "case 2: result.params.axis = Vec3(0, 0, len);", "case 2: result.params.axis = Vec3(len, 0, 0);", "break Z quick-axis formula"),
    ("tool", "else if (name == \"axis\") result.params.axisPreset = 3;", "", "drop manual-axis quick branch"),
    ("tool", "engaged = false; havePreviewCache = false; image.clear(); return;", "havePreviewCache = false; image.clear(); return;", "drop Deactivate engaged reset"),
    ("context", "e.radialSweepTransition.abort();", "", "drop context abort"),
):
    owner, context, tool = b5h_owner, b5e_context, b5g_tool
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "tool": tool = tool.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if b5h_gate(owner, context, tool):
        fail(f"P1.0b.5h named mutation did not RED: {label}")
for hook in ("override void activate()", "override void onParamChanged(string name)",
             "override void deactivate()"):
    start = b5g_tool.find(hook); body_start = b5g_tool.find("{", start) + 1
    body = b5g_tool[body_start:balanced_source(b5g_tool, body_start)-1]
    if "PreparedRadialSweepTransitionOwner" in body or "prepareRadialSweepTransition" in body:
        fail("P1.0b.5h transition owner reached from production hook")

# P1.0b.5i dormant Radial Sweep producers. Param is private transition ->
# preview upload -> no-history. Deactivate conditionally installs mesh/delivery
# -> main upload, always destroys preview GPU, conditionally installs history,
# then installs the exact private reset. Activate composes the reviewed profile,
# transition and atomic create-upload owners while remaining dormant.
b5i_tool = b5g_tool
def b5i_gate(tool):
    return (tool.count("final PreparedRadialSweepEffect prepareParamChanged(") == 1 and
            tool.count("final PreparedRadialSweepEffect prepareDeactivate(") == 1 and
            tool.count("final PreparedRadialSweepEffect prepareActivate(") == 1 and
            "profile !is null && ownsPreviewCreateUpload(createUpload)" in tool and
            "PreparedRadialSweepTransitionOwner.activation(this, profile)" in tool and
            tool.count("transition.owns(this)") == 2 and
            "context.prepareRadialSweepTransition(transition) &&\n            context.prepareCreateUpload(createUpload," in tool and
            "context.prepareRadialSweepTransition(transition) &&\n            context.prepareUpload(uploadOwner, transition.previewForGpuUpload)" in tool and
            tool.count("scope(failure) context.discard();") == 3 and
            "if (ok) inserted = buildPreparedCommitCandidate(candidate, pre," in tool and
            "context.prepareStampedMeshImage(layer, candidate," in tool and
            "installedCommitMatchesPreparedForTest" in tool and
            "auto expectedVersions = [lastPreparedMutationVersion_, lastPreparedTopologyVersion_];" in tool and
            "memcmp(installedVersions.ptr, expectedVersions.ptr," in tool and
            "bool prepareStampedMeshImage(Layer layer, ref const Mesh image," in b5e_context and
            "enlistedDeliveryForStampedImage(flags, domains)" in b5e_context and
            "context.prepareUpload(mainUpload, candidate)" in tool and
            "if (ok) ok = context.prepareDestroy(previewDestroy);" in tool and
            "ok = context.prepareGestureCarrierMismatch();" in tool and
            "historyPrepared ? context.markHistoryInstall()" in tool and
            "context.prepareRadialSweepTransition(transition);" in tool and
            tool.count("if (!ok && context !is null) context.discard();") == 2)
if not b5i_gate(b5i_tool):
    fail("P1.0b.5i Radial Sweep producer contract drift")
for old, new, label in (
    ("transition.owns(this)", "true", "drop transition owner identity"),
    ("profile !is null && ownsPreviewCreateUpload(createUpload)", "profile !is null", "drop Activate GPU target identity"),
    ("PreparedRadialSweepTransitionOwner.activation(this, profile)", "null", "drop Activate profile/private image"),
    ("context.prepareRadialSweepTransition(transition) &&\n            context.prepareCreateUpload(createUpload,",
     "context.prepareCreateUpload(createUpload, transition.previewForGpuUpload) &&\n            context.prepareRadialSweepTransition(transition) && false /*",
     "reorder Activate GPU before private image"),
    ("context.prepareRadialSweepTransition(transition) &&\n            context.prepareUpload(uploadOwner, transition.previewForGpuUpload)",
     "context.prepareUpload(uploadOwner, transition.previewForGpuUpload) &&\n            context.prepareRadialSweepTransition(transition)", "reorder Param upload"),
    ("scope(failure) context.discard();", "", "drop function exception cleanup"),
    ("if (ok) inserted = buildPreparedCommitCandidate(candidate, pre,", "if (true) inserted = buildPreparedCommitCandidate(candidate, pre,", "build before validation"),
    ("context.prepareStampedMeshImage(layer, candidate,", "context.prepareMeshImageCommit(layer, candidate, kRevolveEditScope) && false /*", "re-stamp detached candidate"),
    ("[lastPreparedMutationVersion_, lastPreparedTopologyVersion_]", "[lastPreparedMutationVersion_ + 1, lastPreparedTopologyVersion_]", "accept extra mutation stamp"),
    ("if (ok) ok = context.prepareDestroy(previewDestroy);", "", "drop preview destroy"),
    ("ok = context.prepareGestureCarrierMismatch();", "ok = true;", "drop carrier mismatch diagnostic"),
    ("historyPrepared ? context.markHistoryInstall()", "context.markNoHistoryInstall()", "drop history branch"),
    ("if (ok) ok = context.prepareRadialSweepTransition(transition);", "", "drop private reset"),
):
    mutant = b5i_tool.replace(old, new, 1)
    if mutant == b5i_tool or b5i_gate(mutant):
        fail(f"P1.0b.5i named mutation did not RED: {label}")

def radial_activate_profile_gate(selection, transition):
    return ("bool takeUnbegun(RadialSweepTool expected," in selection and
            "target_ !is expected" in selection and
            "profile.takeUnbegun(target, profileImage)" in transition)
if not radial_activate_profile_gate(b5g_owner, b5h_owner):
    fail("Radial Sweep Activate profile target identity drift")
for target, old, new, label in (
    ("selection", "target_ !is expected", "false", "drop profile target identity"),
    ("transition", "profile.takeUnbegun(target, profileImage)",
     "profile.takeUnbegun(null, profileImage)", "drop expected target forwarding"),
):
    selection, transition = b5g_owner, b5h_owner
    if target == "selection": selection = selection.replace(old, new, 1)
    else: transition = transition.replace(old, new, 1)
    if radial_activate_profile_gate(selection, transition):
        fail(f"Radial Sweep Activate profile mutation did not RED: {label}")

# Dormant combined first-upload owner. It is the only admissible bridge from
# an empty target to a fully uploaded target: names and CPU payload share one
# owner/generation and one context entry, with no create-only install state.
def combined_upload_gate(gpu, context):
    start = gpu.find("final class GpuCreateUploadOwner")
    block = gpu[start:] if start >= 0 else ""
    return (start >= 0 and
            "struct PreparedGpuCreateUploadToken" in gpu and
            "struct ValidatedGpuCreateUploadToken" in gpu and
            gpu.count("@disable this(this);") >= 6 and
            "GpuMeshNames created, expectedTarget;" in block and
            "GpuMesh prepared;" in block and
            "private bool isDefaultEmptyGpuMesh(ref GpuMesh gpu)" in gpu and
            block.count("isDefaultEmptyGpuMesh(*target)") == 2 and
            "setNames(next, created);" in block and
            "next.buildUploadCpu(mesh, vpos, null, null, null);" in block and
            "scope(failure) cleanupPrepared();" in block and
            "(threadIdentity ^ requiredThread) != 0" in block and
            "(contextIdentity ^ requiredContext) != 0" in block and
            "enlistedPrepared.generation != generation" in block and
            "enlistedValidated.generation != generation" in block and
            "!sameGpuUploadVersion(target, baseUploadVersion)" in block and
            "peekGpuMeshNames(*target) != expectedTarget" in block and
            "immutable bool replaceLikeInit;" in block and
            "bool replacesLikeLegacyInit() const nothrow @nogc" in block and
            block.count("prepared.submitUploadGl();") == 2 and
            "g_fc.upload(uploadedVertexCount);" in block and
            "fakeUsedNames[fakeCallLength++] = used[i];" in block and
            block.find("prepared.submitUploadGl();") <
                block.find("setNames(*target, created);") <
                block.find("installUploadState(target[0], prepared);") and
            "void installEnlisted() nothrow @nogc" in block and
            "void abortEnlisted() nothrow @nogc" in block and
            "bool prepareCreateUpload(GpuCreateUploadOwner owner, ref const Mesh mesh)" in context and
            "e.gpuCreateUpload.validateEnlisted(resourceThread_, resourceContext_)" in context and
            "e.gpuCreateUpload.installEnlisted();" in context and
            "e.gpuCreateUpload.abortEnlisted();" in context)
if not combined_upload_gate(mesh_gpu, record_context):
    fail("combined GPU create-upload owner contract drift")
for target, old, new, label in (
    ("gpu", "setNames(next, created);", "", "build payload against zero names"),
    ("gpu", "!isDefaultEmptyGpuMesh(*target)", "false", "admit dirty target projection"),
    ("gpu", "scope(failure) cleanupPrepared();", "", "leak names on prepare throw"),
    ("gpu", "(threadIdentity ^ requiredThread) != 0", "false", "drop thread identity"),
    ("gpu", "enlistedValidated.generation != generation", "false", "drop validated generation"),
    ("gpu", "!sameGpuUploadVersion(target, baseUploadVersion)", "false", "drop target generation"),
    ("gpu", "peekGpuMeshNames(*target) != expectedTarget", "false", "drop replacement target identity"),
    ("gpu", "(!replaceLikeInit && !isDefaultEmptyGpuMesh(*target))", "false", "broaden ordinary create-upload"),
    ("gpu", "prepared.submitUploadGl();", "", "drop first upload submission"),
    ("gpu", "g_fc.upload(uploadedVertexCount);", "", "drop upload work counter"),
    ("gpu", "setNames(*target, created);", "", "drop atomic header transfer"),
    ("gpu", "setNames(*target, created);\n        installUploadState(target[0], prepared);",
     "installUploadState(target[0], prepared);\n        setNames(*target, created);",
     "reorder payload before header transfer"),
    ("context", "e.gpuCreateUpload.abortEnlisted();", "", "drop context abort"),
):
    gpu, context = mesh_gpu, record_context
    if target == "gpu":
        pos = gpu.find(old, gpu.find("final class GpuCreateUploadOwner"))
        if pos >= 0: gpu = gpu[:pos] + new + gpu[pos + len(old):]
    else: context = context.replace(old, new, 1)
    if (target == "gpu" and pos < 0) or combined_upload_gate(gpu, context):
        fail(f"combined GPU create-upload mutation did not RED: {label}")
for path in (ROOT / "source").rglob("*.d"):
    if path.name in ("mesh_gpu.d", "prepared_record_context.d",
                     "radial_sweep_tool.d", "bridge_tool.d", "mirror.d"): continue
    if ".prepareCreateUpload(" in without_unittests(path.read_text()):
        fail("combined GPU create-upload gained a pre-cutover caller")

# Isolated RadialArray shared session transition owner. This owner unlocks the
# activate/deactivate private projections for later producers; topology/GPU/
# history remain separate reviewed effects and the ledger is unchanged here.
radial_array_owner = (ROOT / "source/prepared_radial_array_transition.d").read_text()
radial_array_tool = (ROOT / "source/tools/alignment/radial_array_tool.d").read_text()
def radial_array_owner_gate(owner, context, tool):
    production = without_unittests(owner)
    return ("final class PreparedRadialArrayTransitionOwner" in owner and
            "struct PreparedRadialArrayTransitionToken" in owner and
            "struct ValidatedRadialArrayTransitionToken" in owner and
            owner.count("@disable this(this);") == 2 and
            not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and
            "target.classinfo is RadialArrayTool.classinfo" in owner and
            "target.ownsPreparedMesh(&source)" in owner and
            "prepared_.generation != generation_" in owner and
            "validatedToken_.generation != generation_" in owner and
            "target_.installPreparedTransition(image_);" in owner and
            "!image_.valid && !image_.before.filled" in owner and
            "image_.before.vertices.length == 0" in owner and
            "pending_ = validated_ = false; consumed_ = true; target_ = null;" in owner and
            "struct RadialArrayTransitionImage" in tool and
            "MeshSnapshot before;" in tool and
            "final bool ownsPreparedMesh(const Mesh* candidate)" in tool and
            "image.before = MeshSnapshot.capture(source);" in tool and
            "image.before.moveInto(before);" in tool and
            "active = image.active; built = image.built; dragPart = image.dragPart;" in tool and
            "if (image.clearHaul) toolHandles.clearHaul(); image.clear();" in tool and
            "bool prepareRadialArrayTransition(PreparedRadialArrayTransitionOwner owner)" in context and
            "e.radialArrayTransition.validate();" in context and
            "e.radialArrayTransition.install();" in context and
            "e.radialArrayTransition.abort();" in context and
            "final PreparedRadialArrayEffect prepareActivate(PreparedRecordContext context)" in tool and
            "PreparedRadialArrayTransitionOwner.activation(this, *live)" in tool and
            "context.prepareRadialArrayTransition(transition) &&" in tool and
            "context.markNoHistoryInstall();" in tool and
            "final PreparedRadialArrayEffect prepareSessionDeactivate(" in tool and
            tool.count("auto live = mesh;") == 2 and
            "if (live is null) {" in tool and
            "cmd !is null && cmd.meshPtr() is live" in tool and
            "MeshSnapshot.capture(*live)" in tool and
            "else ok = context.prepareGestureCarrierMismatch();" in tool and
            "historyPrepared ? context.markHistoryInstall()" in tool and
            "PreparedRadialArrayTransitionOwner.deactivation(this)" in tool and
            tool.count("scope(failure) context.discard();") == 3)
if not radial_array_owner_gate(radial_array_owner, record_context, radial_array_tool):
    fail("RadialArray transition owner contract drift")
if re.search(r"final\s+PreparedDeactivateEffect\s+prepareDeactivate\s*\(",
             radial_array_tool):
    fail("RadialArray retained a second root-shaped deactivation producer")
for target, old, new, label in (
    ("owner", "target.classinfo is RadialArrayTool.classinfo", "target !is null", "admit derived product"),
    ("owner", "target.ownsPreparedMesh(&source)", "true", "admit foreign mesh"),
    ("owner", "prepared_.generation != generation_", "false", "drop prepared generation"),
    ("owner", "validatedToken_.generation != generation_", "false", "drop validated generation"),
    ("owner", "target_.installPreparedTransition(image_);", "", "drop fixed install"),
    ("owner", "image_.before.vertices.length == 0", "true", "omit snapshot scrub proof"),
    ("owner", "pending_ = validated_ = false; consumed_ = true; target_ = null;", "pending_ = validated_ = false;", "rearm consumed owner"),
    ("tool", "image.before.moveInto(before);", "", "drop detached activation snapshot"),
    ("tool", "image.before = MeshSnapshot.capture(source);", "image.before = MeshSnapshot.init;", "replace deep snapshot with empty/shallow image"),
    ("tool", "if (image.clearHaul) toolHandles.clearHaul(); image.clear();", "image.clear();", "drop haul reset"),
    ("context", "e.radialArrayTransition.abort();", "", "drop context abort"),
    ("tool", "PreparedRadialArrayTransitionOwner.activation(this, *live)", "null", "drop activation owner"),
    ("tool", "historyPrepared ? context.markHistoryInstall()", "false ? context.markHistoryInstall()", "drop history branch"),
    ("tool", "auto live = mesh;", "auto live = cast(Mesh*) null;", "drop cached live subject"),
    ("tool", "if (live is null) {", "if (false) {", "drop null subject refusal"),
    ("tool", "cmd !is null && cmd.meshPtr() is live", "cmd !is null", "admit wrong-Mesh history carrier"),
    ("tool", "else ok = context.prepareGestureCarrierMismatch();", "else ok = true;", "drop mismatch diagnostic"),
    ("tool", "PreparedRadialArrayTransitionOwner.deactivation(this)", "null", "drop deactivate owner"),
    ("tool", "scope(failure) context.discard();", "", "drop producer failure cleanup"),
):
    owner, context, tool = radial_array_owner, record_context, radial_array_tool
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "tool": tool = tool.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if radial_array_owner_gate(owner, context, tool):
        fail(f"RadialArray transition mutation did not RED: {label}")

def radial_array_param_gate(owner, tool, context):
    start = tool.find("final PreparedRadialArrayEffect prepareParamChanged(")
    end = tool.find("override void evaluate()", start)
    producer = tool[start:end]
    return (all(x in tool for x in (
                "PreparedRadialArrayTransitionKind : ubyte { Activate, Param, Deactivate }",
                "image.expectedLive = MeshSnapshot.capture(live);",
                "image.expectedBefore = MeshSnapshot.capture(baseline);",
                "auto shadow = beginPreparedShadow(image.candidate);",
                "image.candidate.radialArrayFaces(mask, count_, axisChar()",
                "drainPreparedShadowDelivery(image.candidate",
                "sameBytes(center, other.center)",
                "image.expectedLive.matches(live)",
                "image.expectedBefore.matches(before)")) and
            all(x in owner for x in (
                "static PreparedRadialArrayTransitionOwner param(",
                "!target.ownsPreparedMesh(&layer.meshRef())",
                "&layer_.meshRef() !is source_",
                "!target_.preparedParamMatches(image_, *source_)")) and
            all(x in producer for x in (
                "PreparedRadialArrayTransitionOwner.param(this, layer)",
                "uploadOwner.owns(gpu)",
                "context.prepareStampedMeshImage(layer, transition.candidate,",
                "context.prepareRadialArrayTransition(transition)",
                "context.prepareUpload(uploadOwner, transition.candidate)",
                "context.markNoHistoryInstall()", "scope(failure) context.discard();",
                "if (!ok) context.discard();")) and
            producer.find("context.prepareStampedMeshImage") <
                producer.find("context.prepareRadialArrayTransition(transition)") <
                producer.find("context.prepareUpload(uploadOwner") <
                producer.find("context.markNoHistoryInstall()") and
            "PreparedRadialArrayKind : ubyte { Activate, Param, Deactivate }" in
                (ROOT / "source/prepared_tool_effect.d").read_text())
if not radial_array_param_gate(radial_array_owner, radial_array_tool,
                               record_context):
    fail("RadialArray onParamChanged prepared contract drift")
for target, old, new, label in (
    ("tool", "image.expectedLive = MeshSnapshot.capture(live);", "", "drop live witness"),
    ("tool", "auto shadow = beginPreparedShadow(image.candidate);", "", "drop detached shadow"),
    ("tool", "sameBytes(center, other.center)", "true", "drop byte-exact center"),
    ("owner", "!target.ownsPreparedMesh(&layer.meshRef())", "false", "drop Layer subject"),
    ("owner", "&layer_.meshRef() !is source_", "false", "drop retained subject"),
    ("tool", "uploadOwner.owns(gpu)", "true", "drop GPU identity"),
    ("tool", "context.prepareRadialArrayTransition(transition)", "true", "drop state"),
    ("tool", "context.prepareUpload(uploadOwner, transition.candidate)", "true", "drop upload"),
    ("tool", "context.markNoHistoryInstall()", "true", "drop NoHistory"),
):
    o, t = radial_array_owner, radial_array_tool
    if target == "owner":
        pos = o.find(old, o.find("static PreparedRadialArrayTransitionOwner param("))
        if pos < 0: pos = o.find(old)
        o = o[:pos] + new + o[pos + len(old):]
    else:
        producer_start = t.find("final PreparedRadialArrayEffect prepareParamChanged(")
        start = producer_start if old in t[producer_start:] else t.find(
            "struct RadialArrayParamProjection")
        pos = t.find(old, start); t = t[:pos] + new + t[pos + len(old):]
    if radial_array_param_gate(o, t, record_context):
        fail(f"RadialArray parameter mutation did not RED: {label}")
for hook in ("override void activate()", "override void deactivate()",
             "override void onParamChanged(string pname)"):
    start = radial_array_tool.find(hook); body_start = radial_array_tool.find("{", start) + 1
    body = radial_array_tool[body_start:balanced_source(radial_array_tool, body_start)-1]
    if "PreparedRadialArrayTransitionOwner" in body or "prepareRadialArrayTransition" in body:
        fail("RadialArray transition owner reached from production hook")

# Isolated shared activation projection for the exact registered LinearAlign
# and RadialAlign products. No producer/hook calls it yet.
transform_activation_owner = (ROOT / "source/prepared_transform_activation.d").read_text()
transform_tool = (ROOT / "source/tools/transform/transform.d").read_text()
linear_align_tool = (ROOT / "source/tools/alignment/linear_align_tool.d").read_text()
radial_align_tool = (ROOT / "source/tools/alignment/radial_align_tool.d").read_text()
bend_tool = (ROOT / "source/tools/deform/bend.d").read_text()
push_tool = (ROOT / "source/tools/deform/push.d").read_text()
def transform_activation_gate(owner, context, tool):
    production = without_unittests(owner)
    builder_projection = (
        "image.gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];\n"
        "        image.lastSelectionHash = ulong.max;\n"
        "        image.lastMutationVersion = ulong.max;\n"
        "        image.dragAxis = -1; image.active = true;\n"
        "        image.vertexCacheDirty = true;\n"
        "        image.needsGpuUpdate = image.centerManual = image.wholeMeshDrag =\n"
        "            image.propsDragging = false;\n"
        "        image.valid = true; return image;")
    install_projection = (
        "gpuMatrix = image.gpuMatrix; lastSelectionHash = image.lastSelectionHash;\n"
        "        lastMutationVersion = image.lastMutationVersion;\n"
        "        dragAxis = image.dragAxis; active = image.active;\n"
        "        vertexCacheDirty = image.vertexCacheDirty;\n"
        "        needsGpuUpdate = image.needsGpuUpdate; centerManual = image.centerManual;\n"
        "        wholeMeshDrag = image.wholeMeshDrag; propsDragging = image.propsDragging;\n"
        "        image.clear();")
    return ("final class PreparedTransformActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo is LinearAlignTool.classinfo" in owner and
        "target.classinfo is RadialAlignTool.classinfo" in owner and
        "target.classinfo is BendTool.classinfo" in owner and
        "target.classinfo is PushTool.classinfo" in owner and
        "prepared_.generation != generation_" in owner and
        "validatedToken_.generation != generation_" in owner and
        "target_.installPreparedActivation(image_); consume();" in owner and
        "pending_ = validated_ = false; consumed_ = true; target_ = null;" in owner and
        "struct PreparedTransformActivationImage" in tool and
        builder_projection in tool and install_projection in tool and
        "final void installPreparedActivation(" in tool and
        "lastSelectionHash = image.lastSelectionHash" in tool and
        "lastMutationVersion = image.lastMutationVersion" in tool and
        "needsGpuUpdate = image.needsGpuUpdate" in tool and
        "wholeMeshDrag = image.wholeMeshDrag" in tool and
        "image.clear();" in tool and
        "bool prepareTransformActivation(PreparedTransformActivationOwner owner)" in context and
        "e.transformActivation.validate();" in context and
        "e.transformActivation.install();" in context and
        "e.transformActivation.abort();" in context)
if not transform_activation_gate(transform_activation_owner, record_context, transform_tool):
    fail("Transform activation owner contract drift")
def transform_producer_gate(linear, radial, bend, push):
    def producer_body(source):
        start = source.find("final PreparedTransformActivationEffect prepareActivate(")
        if start < 0: return ""
        body_start = source.find("{", start) + 1
        return source[body_start:balanced_source(source, body_start)-1]
    linear_body, radial_body = producer_body(linear), producer_body(radial)
    bend_body, push_body = producer_body(bend), producer_body(push)
    common = ("scope(failure) context.discard();",
        "context.prepareTransformActivation(owner) &&",
        "context.markNoHistoryInstall();", "if (!ok) context.discard();")
    return ("PreparedTransformActivationOwner.prepare(this)" in linear_body and
        all(x in linear_body for x in common) and
        "return PreparedTransformActivationEffect(preparedToolStateOwner,\n"
        "            PreparedTransformActivationKind.LinearAlign, ok);" in linear_body and
        "PreparedTransformActivationOwner.prepare(this)" in radial_body and
        all(x in radial_body for x in common) and
        "return PreparedTransformActivationEffect(preparedToolStateOwner,\n"
        "            PreparedTransformActivationKind.RadialAlign, ok);" in radial_body and
        "PreparedTransformActivationOwner.prepare(this)" in bend_body and
        all(x in bend_body for x in common) and
        "return PreparedTransformActivationEffect(preparedToolStateOwner,\n"
        "            PreparedTransformActivationKind.Bend, ok);" in bend_body and
        "PreparedTransformActivationOwner.prepare(this)" in push_body and
        all(x in push_body for x in common) and
        "return PreparedTransformActivationEffect(preparedToolStateOwner,\n"
        "            PreparedTransformActivationKind.Push, ok);" in push_body and
        not any(x in linear_body + radial_body + bend_body + push_body for x in
            ("owner.install(", "context.install(", "context.validate(")))
if not transform_producer_gate(linear_align_tool, radial_align_tool,
        bend_tool, push_tool):
    fail("Transform activation producer contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo is LinearAlignTool.classinfo", "false", "drop LinearAlign admission"),
    ("owner", "target.classinfo is RadialAlignTool.classinfo", "false", "drop RadialAlign admission"),
    ("owner", "target.classinfo is BendTool.classinfo", "false", "drop Bend admission"),
    ("owner", "target.classinfo is PushTool.classinfo", "false", "drop Push admission"),
    ("owner", "target.classinfo is LinearAlignTool.classinfo", "cast(LinearAlignTool) target !is null", "broaden LinearAlign admission to derived behavior"),
    ("owner", "prepared_.generation != generation_", "false", "drop prepared generation"),
    ("owner", "validatedToken_.generation != generation_", "false", "drop validated generation"),
    ("owner", "target_.installPreparedActivation(image_); consume();", "consume();", "drop fixed install"),
    ("tool", "lastSelectionHash = image.lastSelectionHash", "lastSelectionHash = 0", "drop selection sentinel"),
    ("tool", "needsGpuUpdate = image.needsGpuUpdate", "needsGpuUpdate = true", "drop GPU dirty reset"),
    ("tool", "image.lastSelectionHash = ulong.max;", "image.lastSelectionHash = 0;", "change cache hash sentinel"),
    ("tool", "image.lastMutationVersion = ulong.max;", "image.lastMutationVersion = 0;", "change mutation sentinel"),
    ("tool", "image.dragAxis = -1; image.active = true;", "image.dragAxis = 0; image.active = false;", "change active drag projection"),
    ("tool", "image.vertexCacheDirty = true;", "image.vertexCacheDirty = false;", "change cache dirty projection"),
    ("tool", "image.propsDragging = false;", "image.propsDragging = true;", "change false flag projection"),
    ("tool", "image.gpuMatrix = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];", "image.gpuMatrix[] = 0;", "change identity GPU matrix"),
    ("tool", "gpuMatrix = image.gpuMatrix; lastSelectionHash = image.lastSelectionHash;", "lastSelectionHash = image.lastSelectionHash; gpuMatrix = image.gpuMatrix;", "reorder fixed install"),
    ("context", "e.transformActivation.abort();", "", "drop context abort"),
):
    owner, context, tool = transform_activation_owner, record_context, transform_tool
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "tool": tool = tool.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if transform_activation_gate(owner, context, tool):
        fail(f"Transform activation mutation did not RED: {label}")
for target, old, new, label in (
    ("linear", "PreparedTransformActivationOwner.prepare(this)", "null", "drop LinearAlign owner"),
    ("radial", "PreparedTransformActivationOwner.prepare(this)", "null", "drop RadialAlign owner"),
    ("linear", "context.prepareTransformActivation(owner) &&", "true &&", "drop LinearAlign enlist"),
    ("radial", "context.markNoHistoryInstall();", "true;", "drop RadialAlign NoHistory order"),
    ("linear", "scope(failure) context.discard();", "", "drop LinearAlign failure cleanup"),
    ("linear", "PreparedTransformActivationKind.LinearAlign, ok", "PreparedTransformActivationKind.RadialAlign, ok", "swap LinearAlign accepted kind"),
    ("radial", "PreparedTransformActivationKind.RadialAlign, ok", "PreparedTransformActivationKind.LinearAlign, ok", "swap RadialAlign accepted kind"),
    ("linear", "return PreparedTransformActivationEffect(preparedToolStateOwner,", "return PreparedTransformActivationEffect(OwnedId.init,", "replace accepted owner"),
    ("radial", "auto owner = PreparedTransformActivationOwner.prepare(this);", "auto owner = PreparedTransformActivationOwner.prepare(this); owner.install();", "mutate live state during prepare"),
    ("bend", "PreparedTransformActivationOwner.prepare(this)", "null", "drop Bend owner"),
    ("push", "context.prepareTransformActivation(owner) &&", "true &&", "drop Push enlist"),
    ("bend", "PreparedTransformActivationKind.Bend, ok", "PreparedTransformActivationKind.Push, ok", "swap Bend accepted kind"),
    ("push", "scope(failure) context.discard();", "", "drop Push failure cleanup"),
):
    linear, radial, bend, push = (linear_align_tool, radial_align_tool,
                                  bend_tool, push_tool)
    if target == "linear": linear = linear.replace(old, new, 1)
    elif target == "radial": radial = radial.replace(old, new, 1)
    elif target == "bend": bend = bend.replace(old, new, 1)
    else: push = push.replace(old, new, 1)
    if transform_producer_gate(linear, radial, bend, push):
        fail(f"Transform activation producer mutation did not RED: {label}")
for path, aggregate in (("tools/transform/transform.d", "TransformTool"),
                        ("tools/alignment/linear_align_tool.d", "LinearAlignTool"),
                        ("tools/alignment/radial_align_tool.d", "RadialAlignTool"),
                        ("tools/deform/bend.d", "BendTool"),
                        ("tools/deform/push.d", "PushTool")):
    source = (ROOT / "source" / path).read_text()
    start = source.find("override void activate()")
    body_start = source.find("{", start) + 1
    body = source[body_start:balanced_source(source, body_start)-1]
    if "PreparedTransformActivationOwner" in body or "prepareTransformActivation" in body:
        fail(f"Transform activation owner reached from production hook: {aggregate}")

transform_copy_fixture = ROOT / "tests/compile_fail/prepared_transform_activation_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(transform_copy_fixture)],
    cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Transform activation token copy was not rejected:\n" + run.stdout)

# Wrapper-owned Xfrm activation reset image. This is intentionally only the
# pre/post value projection: enabled sub-products and prepared history are not
# yet composed, so the Xfrm/Transform declaration rows remain deferred.
xfrm_activation_reset = (ROOT / "source/tools/transform/xfrm_transform.d").read_text()
def xfrm_activation_reset_gate(source, transform):
    prepared_bodies = ""
    bodies = []
    for signature in ("final PreparedXfrmActivationResetImage buildPreparedActivationReset(",
                      "final void installPreparedActivationResetPre(",
                      "final void installPreparedActivationResetPost("):
        start = source.find(signature)
        if start < 0: return False
        body_start = source.find("{", start) + 1
        body = source[body_start:balanced_source(source, body_start)-1]
        bodies.append(body); prepared_bodies += body
    return (
        "struct PreparedXfrmActivationResetImage" in source and
        "final PreparedXfrmActivationResetImage buildPreparedActivationReset()\n"
        "            nothrow @nogc" in source and
        [semantic_digest(body) for body in bodies] == [
            "0c0189f9125980fdd81edff3b546ad39eab91ec5c956b966fb9e3efe8cba5a75",
            "fb7447f80e0dcd58e218fc69a263945f45389ef8ce9d1a8c413bc1fabb31bb93",
            "4302564b892a4b3318c044a5cf215ece4c714b7168085b4c941f3811c20096a5"] and
        "image.run = resyncPreserveDisplayFields ? run : XformState.init;" in prepared_bodies and
        "const bool hadRun = runBaselineValid;" in prepared_bodies and
        "image.moveRunKnown = hadRun ? false : moveRec.runKnown;" in prepared_bodies and
        "image.rotateRunKnown = hadRun ? false : rotateRec.runKnown;" in prepared_bodies and
        "image.scaleRunKnown = hadRun ? false : scaleRec.runKnown;" in prepared_bodies and
        "image.priorRotateWasViewRing = hadRun" in prepared_bodies and
        "final void installPreparedActivationResetPre(" in source and
        "installPreparedActivation(image.base);" in prepared_bodies and
        "activeDrag = null;" in prepared_bodies and
        "dragBaseline.length = 0;" in prepared_bodies and
        "moveRec.pinKnown = false;" in prepared_bodies and
        "lastAppliedGestureMutationVersion = ulong.max;" in prepared_bodies and
        "armedUndoEpoch = ulong.max;" in prepared_bodies and
        "refireAnchor.length = 0;" in prepared_bodies and
        "foldSrc_.length = 0;" in prepared_bodies and
        "itemEditTargets_.length = 0;" in prepared_bodies and
        "itemEditBefore_.length = 0;" in prepared_bodies and
        "final void installPreparedActivationResetPost(" in source and
        "recordViaInSession = true;" in prepared_bodies and
        "if (flagR) rotateSub.setRecordViaInSession(true);" in prepared_bodies and
        "if (flagS) scaleSub.setRecordViaInSession(true);" in prepared_bodies and
        "currentRunBank = DragBank.None;" in prepared_bodies and
        prepared_bodies.count("runBaselineValid = false;") == 2 and
        prepared_bodies.count("runFrameValid = false;") == 2 and
        prepared_bodies.count("morphRunValid_ = false;") == 2 and
        prepared_bodies.count("itemBaselineValid = false;") == 2 and
        prepared_bodies.count("runGpuBufferDirty = false;") == 2 and
        "lastAcenMode = -1;" in prepared_bodies and
        "lastSlotSigValid = false;" in prepared_bodies and
        "frame.settled = false;" in prepared_bodies and
        "frame.valid = false;" in prepared_bodies and
        "image.clear();" in prepared_bodies and
        "public final void setRecordViaInSession(bool on) nothrow @nogc" in transform and
        not any(x in prepared_bodies
                for x in ("activate();", "nextRun()", "context.", "history.")))
if not xfrm_activation_reset_gate(xfrm_activation_reset, transform_tool):
    fail("Xfrm activation reset image contract drift")
for target, old, new, label in (
    ("xfrm", "final PreparedXfrmActivationResetImage buildPreparedActivationReset()\n"
     "            nothrow @nogc",
     "final PreparedXfrmActivationResetImage buildPreparedActivationReset()",
     "drop nothrow reset builder"),
    ("xfrm", "image.run = resyncPreserveDisplayFields ? run : XformState.init;",
     "image.run = XformState.init;", "drop display preservation"),
    ("xfrm", "image.moveRunKnown = hadRun ? false : moveRec.runKnown;",
     "image.moveRunKnown = false;", "collapse hadRun known branch"),
    ("xfrm", "dragBaseline.length = 0;", "", "retain drag baseline"),
    ("xfrm", "moveRec.pinKnown = false;", "", "retain pin-known"),
    ("xfrm", "refireAnchor.length = 0;", "", "retain refire anchor"),
    ("xfrm", "itemEditBefore_.length = 0;", "", "retain item baseline"),
    ("xfrm", "frame.valid = false;", "frame.valid = true;", "retain valid frame"),
    ("transform", "public final void setRecordViaInSession(bool on) nothrow @nogc",
     "public void setRecordViaInSession(bool on)", "drop nothrow routing seam"),
):
    xfrm, transform = xfrm_activation_reset, transform_tool
    if target == "xfrm": xfrm = xfrm.replace(old, new, 1)
    else: transform = transform.replace(old, new, 1)
    if xfrm_activation_reset_gate(xfrm, transform):
        fail(f"Xfrm activation reset mutation did not RED: {label}")

# Exact two-phase Xfrm activation/session composition. The prepared history
# marker remains between pre and post, matching legacy nextRun placement.
xfrm_activation_owner = (ROOT / "source/prepared_xfrm_activation_session.d").read_text()
def xfrm_activation_session_gate(owner, context, xfrm, transform):
    def method_body(source, signature):
        start = source.find(signature)
        if start < 0: return ""
        body_start = source.find("{", start) + 1
        return source[body_start:balanced_source(source, body_start)-1]
    producer = method_body(xfrm,
        "final PreparedXfrmActivationEffect prepareActivate(")
    legacy = method_body(xfrm, "override void activate()")
    pre_install = method_body(owner, "void installPre() nothrow @nogc")
    post_install = method_body(owner, "void installPost() nothrow @nogc")
    return (
        "final class PreparedXfrmActivationSessionOwner" in owner and
        owner.count("@disable this(this);") == 4 and
        "target.classinfo !is XfrmTransformTool.classinfo" in owner and
        "owner.flags_ & 1" in owner and "owner.flags_ & 2" in owner and
        "owner.flags_ & 4" in owner and
        owner.count("PreparedTransformProductActivationOwner.prepare(") == 3 and
        "target_.preparedActivationShape(flags_, move_, rotate_, scale_)" in owner and
        "pre_.owner != owner_" in owner and "post_.owner != owner_" in owner and
        "pre_.generation != generation_" in owner and
        "post_.generation != generation_" in owner and
        "validatedPre_.owner != owner_" in owner and
        "validatedPre_.generation != generation_" in owner and
        "validatedPost_.owner != owner_" in owner and
        "validatedPost_.generation != generation_" in owner and
        pre_install.find("target_.installPreparedActivationResetPre(reset_);") <
            pre_install.find("if (moveOwner_ !is null) moveOwner_.install();") <
            pre_install.find("if (rotateOwner_ !is null) rotateOwner_.install();") <
            pre_install.find("if (scaleOwner_ !is null) scaleOwner_.install();") <
            pre_install.find("target_.installPreparedWrapperLinks();") and
        "target_.installPreparedActivationResetPost(reset_);" in post_install and
        "shapeValid()" not in pre_install and "shapeValid()" not in post_install and
        "bool prepareXfrmActivationPre(PreparedXfrmActivationSessionOwner owner)" in context and
        "bool prepareXfrmActivationPost(PreparedXfrmActivationSessionOwner owner)" in context and
        "xfrmLayoutStage_ != 2 || xfrmLayoutOwner_ !is owner" in context and
        "xfrmLayoutStage_ != 0 && xfrmLayoutStage_ != 3" in context and
        "resources_[$ - 2].kind != PreparedResourceKind.XfrmActivationPreState" in context and
        "history_ is null || noHistoryMarker_" in context and
        "if (historyMarker_) return true;" in context and
        context.count("|| history_ is null) return PreparedHistoryResult.init;") == 2 and
        "|| history_ is null) return 0;" in context and
        "e.xfrmActivation.validatePre();" in context and
        "e.xfrmActivation.validatePost();" in context and
        "e.xfrmActivation.installPre();" in context and
        "e.xfrmActivation.installPost();" in context and
        context.count("e.xfrmActivation.abort();") == 1 and
        "begun_ = true;" in context and
        "bool hasHistory() const nothrow @nogc" in context and
        "bool ownsHistory(CommandHistory expected) const nothrow @nogc" in context and
        "if (history_ !is null) history_.discardPreparedToken(token_);" in context and
        "if (!installedHistory && history_ !is null)" in context and
        "PreparedXfrmActivationSessionOwner.prepare(this)" in producer and
        "context.prepareXfrmActivationPre(owner)" in producer and
        producer.find("context.prepareXfrmActivationPre(owner)") <
            producer.find("runId = context.nextRun();") <
            producer.find("context.markHistoryInstall()") <
            producer.find("context.prepareXfrmActivationPost(owner)") and
        "else if (ok) {\n            ok = context.markNoHistoryInstall();" in producer and
        "context.ownsHistory(preparedHistoryOwner())" in producer and
        "if (!context.ownsHistory(preparedHistoryOwner())) {\n"
        "            context.discard();" in producer and
        "scope(failure) context.discard();" in producer and
        "if (!ok) context.discard();" in producer and
        "return PreparedXfrmActivationEffect(preparedToolStateOwner, runId,\n"
        "            flags, ok);" in producer and
        not any(x in producer for x in ("context.validate(", "context.install(",
                                         "owner.install")) and
        "PreparedXfrmActivationSessionOwner" not in legacy and
        "prepareXfrmActivation" not in legacy and
        "final CommandHistory preparedHistoryOwner() nothrow @nogc" in transform and
        "final void installPreparedWrapperLinks() nothrow @nogc" in xfrm)
if not xfrm_activation_session_gate(xfrm_activation_owner, record_context,
        xfrm_activation_reset, transform_tool):
    fail("Xfrm activation session owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is XfrmTransformTool.classinfo", "false",
     "broaden Xfrm admission"),
    ("owner", "owner.flags_ & 2", "owner.flags_ & 1", "drop Rotate flag"),
    ("owner", "owner.flags_ & 1", "owner.flags_ & 2", "drop Move flag"),
    ("owner", "owner.flags_ & 4", "owner.flags_ & 2", "drop Scale flag"),
    ("owner", "pre_.owner != owner_", "false", "drop pre owner identity"),
    ("owner", "pre_.generation != generation_", "false", "drop pre generation"),
    ("owner", "post_.owner != owner_", "false", "drop prepared post owner"),
    ("owner", "post_.generation != generation_", "false", "drop prepared post generation"),
    ("owner", "validatedPre_.owner != owner_", "false", "drop validated pre owner"),
    ("owner", "validatedPre_.generation != generation_", "false", "drop validated pre generation"),
    ("owner", "validatedPost_.owner != owner_", "false", "drop validated post owner"),
    ("owner", "validatedPost_.generation != generation_", "false",
     "drop post generation"),
    ("owner", "if (rotateOwner_ !is null) rotateOwner_.install();", "",
     "drop Rotate activation"),
    ("owner", "target_.installPreparedWrapperLinks();", "",
     "drop wrapper links"),
    ("owner", "consumed_ ||\n            validatedPre_.owner",
     "consumed_ || !shapeValid() ||\n            validatedPre_.owner",
     "reread live shape during pre install"),
    ("owner", "consumed_ ||\n            validatedPost_.owner",
     "consumed_ || !shapeValid() ||\n            validatedPost_.owner",
     "reread live shape during post install"),
    ("context", "e.xfrmActivation.installPre();", "", "drop pre install"),
    ("context", "e.xfrmActivation.installPost();", "", "drop post install"),
    ("context", "xfrmLayoutStage_ != 2 || xfrmLayoutOwner_ !is owner", "false",
     "drop phase order/owner"),
    ("context", "xfrmLayoutStage_ != 0 && xfrmLayoutStage_ != 3", "false",
     "accept incomplete phase journal"),
    ("xfrm", "runId = context.nextRun();", "runId = 1;", "drop prepared nextRun"),
    ("xfrm", "context.markHistoryInstall()", "context.markNoHistoryInstall()",
     "swap history marker"),
    ("xfrm", "scope(failure) context.discard();", "", "drop failure cleanup"),
    ("xfrm", "if (!context.ownsHistory(preparedHistoryOwner())) {\n"
     "            context.discard();", "if (!context.ownsHistory(preparedHistoryOwner())) {",
     "drop mismatch cleanup"),
    ("xfrm", "PreparedXfrmActivationEffect(preparedToolStateOwner, runId,\n"
     "            flags, ok)", "PreparedXfrmActivationEffect(OwnedId.init, runId,\n"
     "            flags, ok)", "wrong effect owner"),
    ("xfrm", "PreparedXfrmActivationEffect(preparedToolStateOwner, runId,\n"
     "            flags, ok)", "PreparedXfrmActivationEffect(preparedToolStateOwner, 0,\n"
     "            flags, ok)", "wrong effect run"),
    ("xfrm", "PreparedXfrmActivationEffect(preparedToolStateOwner, runId,\n"
     "            flags, ok)", "PreparedXfrmActivationEffect(preparedToolStateOwner, runId,\n"
     "            0, ok)", "wrong effect flags"),
    ("xfrm", "PreparedXfrmActivationEffect(preparedToolStateOwner, runId,\n"
     "            flags, ok)", "PreparedXfrmActivationEffect(preparedToolStateOwner, runId,\n"
     "            flags, true)", "wrong effect acceptance"),
    ("transform", "final CommandHistory preparedHistoryOwner() nothrow @nogc",
     "final CommandHistory preparedHistoryOwner()", "drop history identity seam"),
):
    owner, context, xfrm, transform = (xfrm_activation_owner, record_context,
                                       xfrm_activation_reset, transform_tool)
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "context": context = context.replace(old, new, 1)
    elif target == "xfrm": xfrm = xfrm.replace(old, new, 1)
    else: transform = transform.replace(old, new, 1)
    if xfrm_activation_session_gate(owner, context, xfrm, transform):
        fail(f"Xfrm activation session mutation did not RED: {label}")

xfrm_copy_fixture = ROOT / "tests/compile_fail/prepared_xfrm_activation_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(xfrm_copy_fixture)],
    cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Xfrm activation token copy was not rejected:\n" + run.stdout)

# Exact Move/Rotate/Scale activation owner infrastructure. Xfrm is excluded:
# its activation owns subtool wiring and history-run lifecycle beyond this image.
transform_product_owner = (ROOT / "source/prepared_transform_product_activation.d").read_text()
move_tool = (ROOT / "source/tools/transform/move.d").read_text()
rotate_tool = (ROOT / "source/tools/transform/rotate.d").read_text()
scale_tool = (ROOT / "source/tools/transform/scale.d").read_text()
def transform_product_gate(owner, context, move, rotate, scale):
    production = without_unittests(owner)
    return ("final class PreparedTransformProductActivationOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "target.classinfo is MoveTool.classinfo" in owner and
        "target.classinfo is RotateTool.classinfo" in owner and
        "target.classinfo is ScaleTool.classinfo" in owner and
        "prepared_.generation != generation_" in owner and
        "validatedToken_.generation != generation_" in owner and
        "final switch (kind_)" in owner and "consume();" in owner and
        "(cast(MoveTool) target_).installPreparedProductActivation(move_);" in owner and
        "(cast(RotateTool) target_).installPreparedProductActivation(rotate_);" in owner and
        "(cast(ScaleTool) target_).installPreparedProductActivation(scale_);" in owner and
        "void scrub() nothrow @nogc { move_.clear(); rotate_.clear(); scale_.clear(); }" in owner and
        "return !move_.valid && !rotate_.valid && !scale_.valid" in owner and
        "rotate_.origVertices.length == 0" in owner and
        "scale_.activationVertices.length == 0" in owner and
        "struct PreparedMoveActivationImage" in move and
        "image.propInput = Vec3(0, 0, 0)" in move and
        "installPreparedActivation(image.base); propInput = image.propInput; image.clear();" in move and
        "struct PreparedRotateActivationImage" in rotate and
        "image.origVertices = live.vertices.dup;" in rotate and
        "image.angleAccum = image.propDeg = image.headlessRotate = Vec3(0,0,0);" in rotate and
        "image.pendingRotateAxis = -1; image.pendingRotateAngle = 0;" in rotate and
        "image.pendingRotateViewAxis = Vec3(0,0,0);" in rotate and
        "image.origVertices = null;" in rotate and
        "installPreparedActivation(image.base); angleAccum = image.angleAccum;\n"
        "        propDeg = image.propDeg; origVertices = image.origVertices;\n"
        "        image.origVertices = null; headlessRotate = image.headlessRotate;\n"
        "        pendingRotateAxis = image.pendingRotateAxis;\n"
        "        pendingRotateAngle = image.pendingRotateAngle;\n"
        "        pendingRotateViewAxis = image.pendingRotateViewAxis; image.clear();" in rotate and
        "struct PreparedScaleActivationImage" in scale and
        "Vec3 scaleAccum = Vec3(1,1,1), propScale = Vec3(1,1,1);" in scale and
        "Vec3 headlessScale = Vec3(1,1,1), pendingScale = Vec3(1,1,1);" in scale and
        "bool pendingScaleValid, valid;" in scale and
        "image.activationVertices = live.vertices.dup;" in scale and
        "image.activationCenter = handler.center" in scale and
        "handler.setPosition(Vec3(2,3,4));" in scale and
        "activationCenter == center" in scale and
        "image.activationVertices = null;" in scale and
        "installPreparedActivation(image.base); scaleAccum = image.scaleAccum;\n"
        "        propScale = image.propScale; activationVertices = image.activationVertices;\n"
        "        image.activationVertices = null; activationCenter = image.activationCenter;\n"
        "        headlessScale = image.headlessScale;\n"
        "        pendingScaleValid = image.pendingScaleValid;\n"
        "        pendingScale = image.pendingScale; image.clear();" in scale and
        "bool prepareTransformProductActivation(PreparedTransformProductActivationOwner owner)" in context and
        "e.transformProductActivation.validate();" in context and
        "e.transformProductActivation.install();" in context and
        "e.transformProductActivation.abort();" in context and
        "if (validated_Once && !noHistoryMarker_) return;" in context)
if not transform_product_gate(transform_product_owner, record_context,
        move_tool, rotate_tool, scale_tool):
    fail("Transform product activation owner contract drift")
def transform_product_producer_gate(move, rotate, scale):
    def body(source):
        start = source.find("final PreparedTransformProductEffect prepareActivate(")
        if start < 0: return ""
        begin = source.find("{", start) + 1
        return source[begin:balanced_source(source, begin)-1]
    bodies = {"Move": body(move), "Rotate": body(rotate), "Scale": body(scale)}
    for kind, producer in bodies.items():
        if not all(x in producer for x in (
                "scope(failure) context.discard();",
                "PreparedTransformProductActivationOwner.prepare(this)",
                "context.prepareTransformProductActivation(owner) &&",
                "context.markNoHistoryInstall();",
                "if (!ok) context.discard();",
                "return PreparedTransformProductEffect(preparedToolStateOwner,\n"
                f"            PreparedTransformProductKind.{kind}, ok);")):
            return False
        if any(x in producer for x in ("owner.install(", "context.install(",
                "context.validate(", "installPreparedProductActivation(")):
            return False
    return True
if not transform_product_producer_gate(move_tool, rotate_tool, scale_tool):
    fail("Transform product activation producer contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo is MoveTool.classinfo", "false", "drop Move admission"),
    ("owner", "target.classinfo is RotateTool.classinfo", "false", "drop Rotate admission"),
    ("owner", "target.classinfo is ScaleTool.classinfo", "false", "drop Scale admission"),
    ("owner", "target.classinfo is MoveTool.classinfo", "cast(MoveTool) target !is null", "broaden Move admission to derived"),
    ("owner", "validatedToken_.generation != generation_", "false", "drop validated generation"),
    ("owner", "(cast(ScaleTool) target_).installPreparedProductActivation(scale_);", "", "drop Scale install"),
    ("owner", "(cast(MoveTool) target_).installPreparedProductActivation(move_);", "", "drop fixed Move switch install"),
    ("owner", "(cast(RotateTool) target_).installPreparedProductActivation(rotate_);", "", "drop fixed Rotate switch install"),
    ("owner", "move_.clear(); rotate_.clear(); scale_.clear();", "move_.clear();", "omit union payload scrub"),
    ("rotate", "image.origVertices = live.vertices.dup;", "image.origVertices = live.vertices;", "shallow Rotate baseline"),
    ("rotate", "image.pendingRotateAxis = -1", "image.pendingRotateAxis = 0", "change Rotate pending axis"),
    ("rotate", "image.pendingRotateAngle = 0;", "image.pendingRotateAngle = 1;", "change Rotate pending angle"),
    ("rotate", "image.angleAccum = image.propDeg = image.headlessRotate = Vec3(0,0,0);", "image.angleAccum = Vec3(1,0,0); image.propDeg = image.headlessRotate = Vec3(0,0,0);", "change Rotate angle accumulator"),
    ("rotate", "image.angleAccum = image.propDeg = image.headlessRotate = Vec3(0,0,0);", "image.propDeg = Vec3(1,0,0); image.angleAccum = image.headlessRotate = Vec3(0,0,0);", "change Rotate property accumulator"),
    ("rotate", "image.angleAccum = image.propDeg = image.headlessRotate = Vec3(0,0,0);", "image.headlessRotate = Vec3(1,0,0); image.angleAccum = image.propDeg = Vec3(0,0,0);", "change Rotate headless accumulator"),
    ("move", "installPreparedActivation(image.base); propInput = image.propInput; image.clear();", "installPreparedActivation(image.base); image.clear();", "drop Move value install"),
    ("move", "image.propInput = Vec3(0, 0, 0)", "image.propInput = Vec3(1, 0, 0)", "change Move fixed value"),
    ("rotate", "pendingRotateAngle = image.pendingRotateAngle;\n        pendingRotateViewAxis", "pendingRotateViewAxis = image.pendingRotateViewAxis;\n        pendingRotateAngle", "reorder Rotate fixed install"),
    ("scale", "image.activationVertices = live.vertices.dup;", "image.activationVertices = live.vertices;", "shallow Scale baseline"),
    ("scale", "image.activationCenter = handler.center", "image.activationCenter = Vec3.init", "drop Scale center"),
    ("scale", "handler.setPosition(Vec3(2,3,4));", "handler.setPosition(Vec3(8,8,8));", "collapse old/captured Scale center distinction"),
    ("scale", "Vec3 scaleAccum = Vec3(1,1,1), propScale = Vec3(1,1,1);", "Vec3 scaleAccum = Vec3(0,0,0), propScale = Vec3(1,1,1);", "change Scale accumulator ones"),
    ("scale", "Vec3 scaleAccum = Vec3(1,1,1), propScale = Vec3(1,1,1);", "Vec3 scaleAccum = Vec3(1,1,1), propScale = Vec3(0,0,0);", "change Scale property ones"),
    ("scale", "Vec3 headlessScale = Vec3(1,1,1), pendingScale = Vec3(1,1,1);", "Vec3 headlessScale = Vec3(0,0,0), pendingScale = Vec3(1,1,1);", "change Scale headless ones"),
    ("scale", "Vec3 headlessScale = Vec3(1,1,1), pendingScale = Vec3(1,1,1);", "Vec3 headlessScale = Vec3(1,1,1), pendingScale = Vec3(0,0,0);", "change Scale pending ones"),
    ("scale", "bool pendingScaleValid, valid;", "bool pendingScaleValid = true, valid;", "change Scale pending-valid default"),
    ("scale", "pendingScaleValid = image.pendingScaleValid;\n        pendingScale = image.pendingScale; image.clear();", "pendingScale = image.pendingScale;\n        pendingScaleValid = image.pendingScaleValid; image.clear();", "reorder Scale fixed install tail"),
    ("context", "e.transformProductActivation.abort();", "", "drop context abort"),
    ("context", "if (validated_Once && !noHistoryMarker_) return;", "if (validated_Once) return;", "drop validated NoHistory discard"),
    ("context", "if (validated_Once && !noHistoryMarker_) return;", "if (validated_Once && false) return;", "widen discard to validated History"),
):
    owner, context = transform_product_owner, record_context
    move, rotate, scale = move_tool, rotate_tool, scale_tool
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "move": move = move.replace(old, new, 1)
    elif target == "rotate": rotate = rotate.replace(old, new, 1)
    elif target == "scale": scale = scale.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if transform_product_gate(owner, context, move, rotate, scale):
        fail(f"Transform product activation mutation did not RED: {label}")
for target, old, new, label in (
    ("move", "PreparedTransformProductActivationOwner.prepare(this)", "null", "drop Move producer owner"),
    ("rotate", "context.prepareTransformProductActivation(owner) &&", "true &&", "drop Rotate producer enlist"),
    ("scale", "context.markNoHistoryInstall();", "true;", "drop Scale NoHistory order"),
    ("move", "PreparedTransformProductKind.Move, ok", "PreparedTransformProductKind.Rotate, ok", "swap Move result kind"),
    ("rotate", "PreparedTransformProductKind.Rotate, ok", "PreparedTransformProductKind.Scale, ok", "swap Rotate result kind"),
    ("scale", "PreparedTransformProductKind.Scale, ok", "PreparedTransformProductKind.Move, ok", "swap Scale result kind"),
    ("move", "return PreparedTransformProductEffect(preparedToolStateOwner,\n            PreparedTransformProductKind.Move, ok);", "return PreparedTransformProductEffect(OwnedId.init,\n            PreparedTransformProductKind.Move, ok);", "wrong Move accepted owner"),
    ("rotate", "return PreparedTransformProductEffect(preparedToolStateOwner,\n            PreparedTransformProductKind.Rotate, ok);", "return PreparedTransformProductEffect(OwnedId.init,\n            PreparedTransformProductKind.Rotate, ok);", "wrong Rotate accepted owner"),
    ("scale", "return PreparedTransformProductEffect(preparedToolStateOwner,\n            PreparedTransformProductKind.Scale, ok);", "return PreparedTransformProductEffect(OwnedId.init,\n            PreparedTransformProductKind.Scale, ok);", "wrong Scale accepted owner"),
    ("move", "auto owner = PreparedTransformProductActivationOwner.prepare(this);", "auto owner = PreparedTransformProductActivationOwner.prepare(this); owner.install();", "early Move owner install"),
    ("scale", "auto owner = PreparedTransformProductActivationOwner.prepare(this);", "auto owner = PreparedTransformProductActivationOwner.prepare(this); installPreparedProductActivation(PreparedScaleActivationImage.init);", "early Scale direct installer"),
    ("rotate", "scope(failure) context.discard();", "", "drop Rotate failure cleanup"),
    ("scale", "if (!ok) context.discard();", "", "drop Scale refusal discard"),
):
    move, rotate, scale = move_tool, rotate_tool, scale_tool
    if target == "move": move = move.replace(old, new, 1)
    elif target == "rotate": rotate = rotate.replace(old, new, 1)
    else: scale = scale.replace(old, new, 1)
    if transform_product_producer_gate(move, rotate, scale):
        fail(f"Transform product producer mutation did not RED: {label}")
for source, name in ((move_tool, "Move"), (rotate_tool, "Rotate"), (scale_tool, "Scale")):
    start = source.find("override void activate()")
    body_start = source.find("{", start) + 1
    body = source[body_start:balanced_source(source, body_start)-1]
    if "PreparedTransformProductActivationOwner" in body or \
            "prepareTransformProductActivation" in body:
        fail(f"Transform product owner reached from production {name} hook")

product_copy_fixture = ROOT / "tests/compile_fail/prepared_transform_product_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(product_copy_fixture)],
    cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Transform product activation token copy was not rejected:\n" + run.stdout)

# Exact Move update owner plus dormant Prepared+Legacy producer. The production
# update root itself remains Legacy until P1.0c.
move_update_owner = (ROOT / "source/prepared_move_update.d").read_text()
def move_update_gate(owner, context, move):
    production = without_unittests(owner)
    update_match = re.search(r"override\s+void\s+update\s*\(ref VectorStack vts\)\s*\{", move)
    if not update_match: return False
    update_body = move[update_match.end():balanced_source(move, update_match.end())-1]
    return (
        "final class PreparedMoveUpdateOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and
        production.count("VectorStack") == 2 and
        "target.classinfo !is MoveTool.classinfo" in owner and
        "prepared_.owner != owner_" in owner and
        "prepared_.generation != generation_" in owner and
        "validatedToken_.owner != owner_" in owner and
        "validatedToken_.generation != generation_" in owner and
        "case PreparedMoveUpdateBranch.InactiveNoop:\n            return PreparedMoveUpdateKind.InactiveNoop;" in owner and
        "case PreparedMoveUpdateBranch.DraggingNoop:\n            return PreparedMoveUpdateKind.DraggingNoop;" in owner and
        "case PreparedMoveUpdateBranch.WrapperEditOpenNoop:\n            return PreparedMoveUpdateKind.WrapperEditOpenNoop;" in owner and
        "case PreparedMoveUpdateBranch.Refresh:\n            return PreparedMoveUpdateKind.Refresh;" in owner and
        "target_.installPreparedMoveUpdate(image_);\n        consume();" in owner and
        "image_.clear(); pending_ = validated_ = false; consumed_ = true;" in owner and
        "enum PreparedMoveUpdateBranch : ubyte" in move and
        "InactiveNoop, DraggingNoop, WrapperEditOpenNoop, Refresh" in move and
        "if (!active) { image.branch = PreparedMoveUpdateBranch.InactiveNoop; return image; }" in move and
        "if (dragAxis >= 0) { image.branch = PreparedMoveUpdateBranch.DraggingNoop; return image; }" in move and
        "auto wrapper = cast(XfrmTransformTool) wrapperRef;" in move and
        "if (wrapper !is null) wrapEditOpen = wrapper.publicEditIsOpen();" in move and
        "image.branch = PreparedMoveUpdateBranch.WrapperEditOpenNoop;" in move and
        "image.branch = PreparedMoveUpdateBranch.Refresh;\n        image.center = queryActionCenter(vts);" in move and
        "final void installPreparedMoveUpdate(ref PreparedMoveUpdateImage image)\n            nothrow @nogc" in move and
        "cachedCenter = image.center;\n            handler.setPosition(image.center);\n        }\n        image.clear();" in move and
        "bool prepareMoveUpdate(PreparedMoveUpdateOwner owner)" in context and
        "e.moveUpdate.validate();" in context and
        "e.moveUpdate.install();" in context and
        "e.moveUpdate.abort();" in context and
        "PreparedMoveUpdateOwner" not in update_body and
        "prepareMoveUpdate" not in update_body)
if not move_update_gate(move_update_owner, record_context, move_tool):
    fail("Move update owner contract drift")
move_update_production_calls = sum(
    without_unittests(text).count("PreparedMoveUpdateOwner.prepare(") +
    without_unittests(text).count(".prepareMoveUpdate(")
    for text in prepared_source_texts.values())
if move_update_production_calls != 6:
    fail("Move update owner escaped its three dormant producers")

def move_update_producer_gate(move):
    start = move.find("final PreparedMoveUpdateEffect prepareUpdate(")
    if start < 0: return False
    begin = move.find("{", start) + 1
    body = move[begin:balanced_source(move, begin)-1]
    return all(x in body for x in (
        "if (context is null) return PreparedMoveUpdateEffect(\n"
        "            preparedToolStateOwner, PreparedMoveUpdateKind.None, false);",
        "scope(failure) context.discard();",
        "PreparedMoveUpdateOwner.prepare(this, vts)",
        "auto kind = owner is null ? PreparedMoveUpdateKind.None : owner.effectKind();",
        "context.prepareMoveUpdate(owner) &&\n            context.markNoHistoryInstall();",
        "if (!ok) context.discard();",
        "return PreparedMoveUpdateEffect(preparedToolStateOwner, kind, ok);")) and \
        not any(x in body for x in ("owner.install(", "context.install(",
            "context.validate(", "installPreparedMoveUpdate("))
if not move_update_producer_gate(move_tool):
    fail("Move update dormant producer contract drift")

for target, old, new, label in (
    ("owner", "target.classinfo !is MoveTool.classinfo", "cast(MoveTool) target is null", "broaden exact Move admission"),
    ("owner", "prepared_.owner != owner_", "false", "drop prepared owner identity"),
    ("owner", "prepared_.generation != generation_", "false", "drop prepared generation"),
    ("owner", "validatedToken_.owner != owner_", "false", "drop validated owner identity"),
    ("owner", "validatedToken_.generation != generation_", "false", "drop validated generation"),
    ("owner", "return PreparedMoveUpdateKind.InactiveNoop;", "return PreparedMoveUpdateKind.Refresh;", "swap inactive branch effect"),
    ("owner", "return PreparedMoveUpdateKind.DraggingNoop;", "return PreparedMoveUpdateKind.Refresh;", "swap dragging branch effect"),
    ("owner", "return PreparedMoveUpdateKind.WrapperEditOpenNoop;", "return PreparedMoveUpdateKind.InactiveNoop;", "swap wrapper-open branch effect"),
    ("owner", "return PreparedMoveUpdateKind.Refresh;", "return PreparedMoveUpdateKind.DraggingNoop;", "swap refresh branch effect"),
    ("owner", "target_.installPreparedMoveUpdate(image_);", "", "drop fixed install"),
    ("owner", "image_.clear(); pending_ = validated_ = false; consumed_ = true;", "pending_ = validated_ = false; consumed_ = true;", "omit payload scrub"),
    ("move", "if (!active) { image.branch = PreparedMoveUpdateBranch.InactiveNoop; return image; }", "", "drop inactive guard"),
    ("move", "if (dragAxis >= 0) { image.branch = PreparedMoveUpdateBranch.DraggingNoop; return image; }", "", "drop drag guard"),
    ("move", "auto wrapper = cast(XfrmTransformTool) wrapperRef;", "auto wrapper = cast(XfrmTransformTool) null;", "drop wrapper cast observation"),
    ("move", "if (wrapper !is null) wrapEditOpen = wrapper.publicEditIsOpen();", "", "drop wrapper edit-open observation"),
    ("move", "image.center = queryActionCenter(vts);", "image.center = Vec3.init;", "drop captured center"),
    ("move", "cachedCenter = image.center;", "", "drop cached-center install"),
    ("move", "cachedCenter = image.center;\n            handler.setPosition(image.center);", "handler.setPosition(image.center);\n            cachedCenter = image.center;", "reorder fixed install"),
    ("context", "e.moveUpdate.validate();", "true;", "drop context validation"),
    ("context", "e.moveUpdate.install();", "", "drop context install"),
    ("context", "e.moveUpdate.abort();", "", "drop context abort"),
):
    owner, context, move = move_update_owner, record_context, move_tool
    if target == "owner": owner = owner.replace(old, new, 1)
    elif target == "move": move = move.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if move_update_gate(owner, context, move):
        fail(f"Move update mutation did not RED: {label}")

for old, new, label in (
    ("scope(failure) context.discard();", "", "drop function failure cleanup"),
    ("PreparedMoveUpdateOwner.prepare(this, vts)", "null", "drop owner prepare"),
    ("context.prepareMoveUpdate(owner) &&", "true &&", "drop context enlist"),
    ("context.markNoHistoryInstall();", "true;", "drop NoHistory ordering"),
    ("if (!ok) context.discard();", "", "drop refusal discard"),
    ("owner.effectKind()", "PreparedMoveUpdateKind.None", "drop branch result"),
    ("PreparedMoveUpdateEffect(preparedToolStateOwner, kind, ok)",
     "PreparedMoveUpdateEffect(OwnedId.init, kind, ok)", "wrong accepted owner"),
    ("auto owner = PreparedMoveUpdateOwner.prepare(this, vts);",
     "auto owner = PreparedMoveUpdateOwner.prepare(this, vts); owner.install();",
     "early owner install"),
):
    mutant = move_tool.replace(old, new, 1)
    if move_update_producer_gate(mutant):
        fail(f"Move update producer mutation did not RED: {label}")

move_update_copy_fixture = ROOT / "tests/compile_fail/prepared_move_update_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(move_update_copy_fixture)],
    cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Move update token copy was not rejected:\n" + run.stdout)

# Exact Rotate/Scale update owners. These are the first update roots whose
# detached effect jointly owns mesh delivery, optional refire history and two
# live tool instances (sub-tool + wrapper), so every identity and install rung
# is pinned here rather than inferred from the passing behavior tests.
def rs_update_gate(owner, context, tool_source, stem, cls):
    production = without_unittests(owner)
    lower = stem.lower()
    update_match = re.search(r"override\s+void\s+update\s*\(ref VectorStack vts\)\s*\{",
                             tool_source)
    if not update_match: return False
    update_body = tool_source[update_match.end():balanced_source(
        tool_source, update_match.end())-1]
    return all(x in owner for x in (
        f"final class Prepared{stem}UpdateOwner",
        "@disable this(this);",
        f"target.classinfo !is {cls}.classinfo",
        "mesh_ !is &layer_.meshRef()",
        "target_.preparedWrapperForUpdate() !is wrapper_",
        "target_.preparedEditModeForUpdate() != mode_",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        f"target_.installPreparedUpdate(image_); consume();",
        "image_.clear(); target_ = null; layer_ = null; mesh_ = null;")) and \
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and \
        all(x in context for x in (
            f"bool prepare{stem}Update(Prepared{stem}UpdateOwner owner)",
            f"e.{lower}Update.validate();",
            f"e.{lower}Update.install();",
            f"e.{lower}Update.abort();")) and \
        all(x in tool_source for x in (
            f"final Prepared{stem}UpdateEffect prepareUpdate(",
            f"Prepared{stem}UpdateOwner.prepare(this, layer, vts, context)",
            "context.markHistoryInstall()", "context.markNoHistoryInstall()",
            "context.prepareStampedMeshImage(layer, owner.candidate()",
            f"context.prepare{stem}Update(owner)",
            "if (!ok) context.discard();")) and \
        not any(x in update_body for x in (
            f"Prepared{stem}UpdateOwner", f"prepare{stem}Update"))

for stem, cls, owner_path, tool_source in (
    ("Rotate", "RotateTool", "source/prepared_rotate_update.d", rotate_tool),
    ("Scale", "ScaleTool", "source/prepared_scale_update.d", scale_tool),
):
    rs_owner = (ROOT / owner_path).read_text()
    if not rs_update_gate(rs_owner, record_context, tool_source, stem, cls):
        fail(f"{stem} update owner contract drift")
    for target, old, new, label in (
        ("owner", f"target.classinfo !is {cls}.classinfo", "false", "broaden exact class"),
        ("owner", "mesh_ !is &layer_.meshRef()", "false", "drop mesh identity"),
        ("owner", "target_.preparedWrapperForUpdate() !is wrapper_", "false", "drop wrapper identity"),
        ("owner", "target_.preparedEditModeForUpdate() != mode_", "false", "drop mode identity"),
        ("owner", "prepared_.generation != generation_", "false", "drop prepared generation"),
        ("owner", "validatedToken_.generation != generation_", "false", "drop validated generation"),
        ("owner", "target_.installPreparedUpdate(image_); consume();", "consume();", "drop fixed install"),
        ("context", f"e.{stem.lower()}Update.validate();", "true;", "drop context validate"),
        ("context", f"e.{stem.lower()}Update.install();", "", "drop context install"),
        ("context", f"e.{stem.lower()}Update.abort();", "", "drop context abort"),
        ("tool", "context.markHistoryInstall()", "true", "drop history marker"),
        ("tool", "context.prepareStampedMeshImage(layer, owner.candidate()", "context.prepareStampedMeshImageMissing(layer, owner.candidate()", "drop mesh enlist"),
        ("tool", f"context.prepare{stem}Update(owner)", "true", "drop owner enlist"),
    ):
        mo, co, ts = rs_owner, record_context, tool_source
        if target == "owner": mo = mo.replace(old, new, 1)
        elif target == "context": co = co.replace(old, new, 1)
        else: ts = ts.replace(old, new, 1)
        if rs_update_gate(mo, co, ts, stem, cls):
            fail(f"{stem} update mutation did not RED: {label}")
    copy_fixture = ROOT / f"tests/compile_fail/prepared_{stem.lower()}_update_token_copy.d"
    run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(copy_fixture)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if run.returncode == 0 or ("not copyable" not in run.stdout and
            not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail(f"{stem} update token copy was not rejected:\n" + run.stdout)

# TopologyPen drop jointly closes an optional live-move history carrier and
# restores two SnapStage planes (guide registry + startup enable push).
topopen_deact_owner = (ROOT / "source/prepared_topology_pen_deactivate.d").read_text()
topopen_tool = prepared_source_texts[ROOT / "source/tools/edit/topology_pen/tool.d"]
def topopen_deact_gate(owner, context, tool_source, snap_source):
    production = without_unittests(owner)
    hook = re.search(r"override\s+void\s+deactivate\s*\(\)\s*\{", tool_source)
    if not hook: return False
    hook_body = tool_source[hook.end():balanced_source(tool_source, hook.end())-1]
    return all(x in owner for x in (
        "final class PreparedTopologyPenDeactivateOwner",
        "target.classinfo !is TopologyPenTool.classinfo",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_", "validatedToken_.generation != generation_",
        "target_.preparedSnapGuideForDeactivate() !is guide_",
        "target_.preparedSnapArmOwner() != snapOwner_", "g_pipeCtx !is pipe_",
        "snap_.matchesPreparedPushProjection(snapProjection_)",
        "snap_.matchesPreparedGuides(expectedGuides_)",
        "target_.installPreparedDeactivate(image_);",
        "snap_.installPreparedGuides(nextGuides_);",
        "snap_.installPreparedPopEnabled(snapOwner_);")) and \
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and \
        all(x in context for x in (
            "bool prepareTopologyPenDeactivate(PreparedTopologyPenDeactivateOwner owner)",
            "e.topologyPenDeactivate.validate();",
            "e.topologyPenDeactivate.install();",
            "e.topologyPenDeactivate.abort();")) and \
        all(x in tool_source for x in (
            "final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context)",
            "PreparedTopologyPenDeactivateOwner.prepare(this, context)",
            "owner.historyPrepared() ? context.markHistoryInstall()",
            ": context.markNoHistoryInstall();",
            "context.prepareTopologyPenDeactivate(owner)",
            "if (!ok) context.discard();")) and \
        all(x in snap_source for x in (
            "SnapGuide[] prepareGuideRemoval(SnapGuide guide)",
            "bool matchesPreparedGuides(const SnapGuide[] expected) const nothrow @nogc",
            "void installPreparedGuides(ref SnapGuide[] next) nothrow @nogc",
            "_guides = next; next = null;",
            "void installPreparedPopEnabled(string owner) nothrow")) and \
        "PreparedTopologyPenDeactivateOwner" not in hook_body

snap_stage_source = prepared_source_texts[ROOT / "source/toolpipe/stages/snap.d"]
if not topopen_deact_gate(topopen_deact_owner, record_context,
                          topopen_tool, snap_stage_source):
    fail("TopologyPen deactivate owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is TopologyPenTool.classinfo", "false", "broaden exact class"),
    ("owner", "target_.preparedSnapGuideForDeactivate() !is guide_", "false", "drop guide identity"),
    ("owner", "target_.preparedSnapArmOwner() != snapOwner_", "false", "drop snap owner"),
    ("owner", "g_pipeCtx !is pipe_", "false", "drop pipe identity"),
    ("owner", "snap_.matchesPreparedPushProjection(snapProjection_)", "true", "drop push projection"),
    ("owner", "snap_.matchesPreparedGuides(expectedGuides_)", "true", "drop guide projection"),
    ("owner", "target_.installPreparedDeactivate(image_);", "", "drop tool install"),
    ("owner", "snap_.installPreparedGuides(nextGuides_);", "", "drop guide install"),
    ("owner", "snap_.installPreparedPopEnabled(snapOwner_);", "", "drop pop install"),
    ("context", "e.topologyPenDeactivate.validate();", "true;", "drop context validate"),
    ("context", "e.topologyPenDeactivate.install();", "", "drop context install"),
    ("context", "e.topologyPenDeactivate.abort();", "", "drop context abort"),
    ("tool", "context.prepareTopologyPenDeactivate(owner)", "true", "drop context enlist"),
    ("snap", "_guides = next; next = null;", "next = null;", "drop guide transfer"),
):
    o, c, t, s = topopen_deact_owner, record_context, topopen_tool, snap_stage_source
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    elif target == "tool": t = t.replace(old, new, 1)
    else: s = s.replace(old, new, 1)
    if topopen_deact_gate(o, c, t, s):
        fail(f"TopologyPen deactivate mutation did not RED: {label}")
topopen_copy = ROOT / "tests/compile_fail/prepared_topology_pen_deactivate_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(topopen_copy)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
        fail("TopologyPen deactivate token copy was not rejected:\n" + run.stdout)

# Xfrm update tail is the fixed final phase after the typed T/R/S owners:
# subject cache -> shared pose -> wrapper GPU projection.
xfrm_tail_owner = (ROOT / "source/prepared_xfrm_update_tail.d").read_text()
xfrm_tail_handles = (ROOT / "source/tools/transform/xfrm_handles.d").read_text()
def xfrm_update_tail_gate(owner, context, xfrm, handles):
    production = without_unittests(owner)
    prepared_handles_start = handles.find(
        "private void installPreparedSharedGizmoPose")
    prepared_handles_body = handles[
        prepared_handles_start:balanced_source(
            handles, handles.find("{", prepared_handles_start) + 1)]
    return all(x in owner for x in (
        "final class PreparedXfrmUpdateTailOwner",
        "target.classinfo !is XfrmTransformTool.classinfo",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.preparedUpdateTailMatches(image_)",
        "target_.installPreparedUpdateTail(image_);")) and \
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and \
        all(x in context for x in (
            "bool prepareXfrmUpdateTail(PreparedXfrmUpdateTailOwner owner)",
            "e.xfrmUpdateTail.validate();", "e.xfrmUpdateTail.install();",
            "e.xfrmUpdateTail.abort();")) and \
        all(x in xfrm for x in (
            "PreparedXfrmUpdateTailImage buildPreparedUpdateTail(",
            "preparedUpdateTailMatches(",
            "installPreparedUpdateTail(ref PreparedXfrmUpdateTailImage image)",
            "cachedSubjType_ = image.nextSubject;",
            "installPreparedSharedGizmoPose(image.center, image.basisX,",
            "if (image.writeGpuMatrix) gpuMatrix = image.nextGpuMatrix;",
            "gpu is image.expectedGpu && needsGpuUpdate == image.expectedNeedsGpu",
            "if (image.clearNeedsGpu) needsGpuUpdate = false;",
            "projectedGpuMatrix(out bool write) const nothrow @nogc")) and \
        all(x in prepared_handles_body for x in (
            "installPreparedSharedGizmoPose(Vec3 center, Vec3 bX,",
            "nothrow @nogc",
            "if (flagT) moveSub.setWrapperGizmoPose(center, bX, bY, bZ);",
            "if (flagR) rotateSub.setWrapperGizmoPose(center, bX, bY, bZ);",
            "if (flagS) scaleSub.setWrapperGizmoPose(center, bX, bY, bZ);",
            "syncScaleBankStandoff();"))

if not xfrm_update_tail_gate(xfrm_tail_owner, record_context,
                             prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"],
                             xfrm_tail_handles):
    fail("Xfrm update tail owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is XfrmTransformTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedUpdateTailMatches(image_)", "true", "drop live validation"),
    ("owner", "target_.installPreparedUpdateTail(image_);", "", "drop fixed install"),
    ("context", "e.xfrmUpdateTail.validate();", "true;", "drop context validation"),
    ("context", "e.xfrmUpdateTail.install();", "", "drop context install"),
    ("context", "e.xfrmUpdateTail.abort();", "", "drop context abort"),
    ("xfrm", "cachedSubjType_ = image.nextSubject;", "", "drop subject install"),
    ("xfrm", "if (image.writeGpuMatrix) gpuMatrix = image.nextGpuMatrix;", "", "drop GPU projection"),
    ("xfrm", "if (image.clearNeedsGpu) needsGpuUpdate = false;", "", "drop GPU flag clear"),
    ("handles", "if (flagT) moveSub.setWrapperGizmoPose(center, bX, bY, bZ);", "", "drop Move pose"),
    ("handles", "if (flagR) rotateSub.setWrapperGizmoPose(center, bX, bY, bZ);", "", "drop Rotate pose"),
    ("handles", "if (flagS) scaleSub.setWrapperGizmoPose(center, bX, bY, bZ);", "", "drop Scale pose"),
):
    o, c = xfrm_tail_owner, record_context
    x = prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"]
    h = xfrm_tail_handles
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    elif target == "xfrm": x = x.replace(old, new, 1)
    else:
        before, found, after = h.rpartition(old)
        h = before + new + after if found else h
    if xfrm_update_tail_gate(o, c, x, h):
        fail(f"Xfrm update tail mutation did not RED: {label}")
xfrm_tail_copy = ROOT / "tests/compile_fail/prepared_xfrm_update_tail_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(xfrm_tail_copy)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Xfrm update tail token copy was not rejected:\n" + run.stdout)

xfrm_close_owner = (ROOT / "source/prepared_xfrm_update_edit_close.d").read_text()
xfrm_transform_base = (ROOT / "source/tools/transform/transform.d").read_text()
xfrm_item_source = (ROOT / "source/tools/transform/xfrm_item.d").read_text()
def xfrm_update_edit_close_gate(owner, context, xfrm, base, item):
    production = without_unittests(owner)
    item_start = item.find("private LayerXformEdit buildPreparedItemEditCmd()")
    item_end = item.find("// Task 0614 Phase 3", item_start)
    prepared_item = item[item_start:item_end]
    return all(x in owner for x in (
        "final class PreparedXfrmUpdateEditCloseOwner",
        "target.classinfo !is XfrmTransformTool.classinfo",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.preparedUpdateEditCloseMatches(image_)",
        "target_.installPreparedUpdateEditClose(image_);")) and \
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and \
        all(x in context for x in (
            "bool prepareXfrmUpdateEditClose(PreparedXfrmUpdateEditCloseOwner owner)",
            "e.xfrmUpdateEditClose.validate();",
            "e.xfrmUpdateEditClose.install();",
            "e.xfrmUpdateEditClose.abort();")) and \
        all(x in xfrm for x in (
            "buildPreparedUpdateEditClose(", "buildPreparedItemEditCmd()",
            "buildPreparedEditCmd(label)",
            "rotateSub.buildPreparedEditCmd(\"Rotate\")",
            "scaleSub.buildPreparedEditCmd(\"Scale\")",
            "preparedUpdateEditCloseMatches(",
            "rotateSub.preparedEditCloseMatches(image.rotate)",
            "scaleSub.preparedEditCloseMatches(image.scale)",
            "rotateSub.installPreparedEditClose(image.rotate)",
            "scaleSub.installPreparedEditClose(image.scale)",
            "installPreparedUpdateEditClose(")) and \
        all(x in base for x in (
            "private Command buildPreparedMorphEditCmd(string label)",
            "protected Command buildPreparedEditCmd(string label)",
            "idx.reserve(editIdx.length);",
            "morphEditBeforeHas_[i], valNow, hasNow",
            "capturePreparedEditClose()", "preparedEditCloseMatches(",
            "installPreparedEditClose(")) and \
        all(x in prepared_item for x in (
            "private LayerXformEdit buildPreparedItemEditCmd()",
            "payload.reserve(itemEditTargets_.length);",
            "capturePreparedItemEditClose()", "preparedItemEditCloseMatches(",
            "installPreparedItemEditClose("))

if not xfrm_update_edit_close_gate(xfrm_close_owner, record_context,
        prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"],
        xfrm_transform_base, xfrm_item_source):
    fail("Xfrm update edit-close owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is XfrmTransformTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedUpdateEditCloseMatches(image_)", "true", "drop state validation"),
    ("owner", "target_.installPreparedUpdateEditClose(image_);", "", "drop fixed install"),
    ("context", "e.xfrmUpdateEditClose.validate();", "true;", "drop context validation"),
    ("context", "e.xfrmUpdateEditClose.install();", "", "drop context install"),
    ("context", "e.xfrmUpdateEditClose.abort();", "", "drop context abort"),
    ("xfrm", "buildPreparedItemEditCmd()", "null", "drop item command"),
    ("xfrm", "buildPreparedEditCmd(label)", "null", "drop component command"),
    ("xfrm", "rotateSub.buildPreparedEditCmd(\"Rotate\")", "null", "drop rotate command"),
    ("xfrm", "scaleSub.buildPreparedEditCmd(\"Scale\")", "null", "drop scale command"),
    ("xfrm", "rotateSub.installPreparedEditClose(image.rotate)", "", "drop rotate close"),
    ("xfrm", "scaleSub.installPreparedEditClose(image.scale)", "", "drop scale close"),
    ("base", "idx.reserve(editIdx.length);", "", "drop detached position ownership"),
    ("base", "morphEditBeforeHas_[i], valNow, hasNow", "false, valNow, hasNow", "drop morph presence"),
    ("item", "payload.reserve(itemEditTargets_.length);", "", "drop detached item ownership"),
):
    o, c = xfrm_close_owner, record_context
    x = prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"]
    b, i = xfrm_transform_base, xfrm_item_source
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    elif target == "xfrm": x = x.replace(old, new, 1)
    elif target == "base": b = b.replace(old, new, 1)
    else:
        before, found, after = i.rpartition(old)
        i = before + new + after if found else i
    if xfrm_update_edit_close_gate(o, c, x, b, i):
        fail(f"Xfrm update edit-close mutation did not RED: {label}")
xfrm_close_copy = ROOT / "tests/compile_fail/prepared_xfrm_update_edit_close_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(xfrm_close_copy)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Xfrm update edit-close token copy was not rejected:\n" + run.stdout)

xfrm_slot_owner = (ROOT / "source/prepared_xfrm_slot_poll.d").read_text()
def xfrm_slot_poll_gate(owner, context, xfrm):
    return all(s in owner for s in (
        "final class PreparedXfrmSlotPollOwner",
        "target.classinfo !is XfrmTransformTool.classinfo",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.preparedSlotPollMatches(image_)",
        "target_.installPreparedSlotPoll(image_);")) and \
        all(s in context for s in (
            "bool prepareXfrmSlotPoll(PreparedXfrmSlotPollOwner owner)",
            "e.xfrmSlotPoll.validate();", "e.xfrmSlotPoll.install();",
            "e.xfrmSlotPoll.abort();")) and \
        all(s in xfrm for s in (
            "PreparedXfrmSlotPollImage buildPreparedSlotPoll(",
            "if (!lastSlotSigValid || p.slotBoundary)",
            "preparedSlotPollMatches(", "installPreparedSlotPoll(",
            "lastSlotSig = image.nextSignature;",
            "lastAcenEpoch = image.nextAcenEpoch;",
            "lastSlotSigValid = image.nextValid;"))
if not xfrm_slot_poll_gate(xfrm_slot_owner, record_context,
        prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"]):
    fail("Xfrm slot-poll owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is XfrmTransformTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedSlotPollMatches(image_)", "true", "drop validation"),
    ("owner", "target_.installPreparedSlotPoll(image_);", "", "drop install"),
    ("context", "e.xfrmSlotPoll.validate();", "true;", "drop context validation"),
    ("context", "e.xfrmSlotPoll.install();", "", "drop context install"),
    ("context", "e.xfrmSlotPoll.abort();", "", "drop context abort"),
    ("xfrm", "lastSlotSig = image.nextSignature;", "", "drop signature latch"),
    ("xfrm", "lastAcenEpoch = image.nextAcenEpoch;", "", "drop ACEN epoch latch"),
    ("xfrm", "lastSlotSigValid = image.nextValid;", "", "drop validity latch"),
):
    o, c = xfrm_slot_owner, record_context
    x = prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"]
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else: x = x.replace(old, new, 1)
    if xfrm_slot_poll_gate(o, c, x):
        fail(f"Xfrm slot-poll mutation did not RED: {label}")
xfrm_slot_copy = ROOT / "tests/compile_fail/prepared_xfrm_slot_poll_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(xfrm_slot_copy)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Xfrm slot-poll token copy was not rejected:\n" + run.stdout)

xfrm_boundary_owner = (ROOT / "source/prepared_xfrm_update_boundary.d").read_text()
def xfrm_update_boundary_gate(owner, context, xfrm, acen):
    acen_start = acen.find("void installPreparedClearSoftPlaced()")
    acen_end = acen.find("/// True iff", acen_start)
    prepared_acen = acen[acen_start:acen_end]
    return all(s in owner for s in (
        "final class PreparedXfrmUpdateBoundaryOwner",
        "target.classinfo !is XfrmTransformTool.classinfo",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.preparedUpdateBoundaryMatches(image_)",
        "target_.installPreparedUpdateBoundary(image_);")) and \
        all(s in context for s in (
            "bool prepareXfrmUpdateBoundary(PreparedXfrmUpdateBoundaryOwner owner)",
            "e.xfrmUpdateBoundary.validate();",
            "e.xfrmUpdateBoundary.install();",
            "e.xfrmUpdateBoundary.abort();")) and \
        all(s in xfrm for s in (
            "PreparedXfrmUpdateBoundaryImage buildPreparedUpdateBoundary(",
            "lastSelectionHash = image.nextSelectionHash;",
            "lastMutationVersion = image.nextMutationVersion;",
            "lastAppliedGestureMutationVersion = ulong.max;\n"
            "            armedUndoEpoch = ulong.max;\n"
            "            refireAnchor = null;",
            "runBaselineValid = false;\n"
            "        runFrameValid = false;\n"
            "        morphRunValid_ = false;\n"
            "        itemBaselineValid = false;\n"
            "        runGpuBufferDirty = false;\n"
            "        if (image.hadRun)",
            "armedUndoEpoch = ulong.max;", "refireAnchor = null;",
            "runBaselineValid = false;", "runFrameValid = false;",
            "morphRunValid_ = false;", "itemBaselineValid = false;",
            "runGpuBufferDirty = false;", "moveRec.runKnown = false;",
            "rotateRec.runKnown = false;", "scaleRec.runKnown = false;",
            "runPriorRotateWasViewRing = false;",
            "image.expectedAcen.installPreparedClearSoftPlaced();",
            "frame.settled = false;", "frame.valid = false;")) and \
        "bool preparedSoftPinMatches(Pin expected)" in acen and \
        all(s in prepared_acen for s in (
            "void installPreparedClearSoftPlaced() nothrow @nogc",
            "softPin = Pin.init;"))
if not xfrm_update_boundary_gate(xfrm_boundary_owner, record_context,
        prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"],
        prepared_source_texts[ROOT / "source/toolpipe/stages/actcenter.d"]):
    fail("Xfrm update boundary owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is XfrmTransformTool.classinfo", "false", "broaden product"),
    ("owner", "target_.preparedUpdateBoundaryMatches(image_)", "true", "drop validation"),
    ("owner", "target_.installPreparedUpdateBoundary(image_);", "", "drop install"),
    ("context", "e.xfrmUpdateBoundary.validate();", "true;", "drop context validation"),
    ("context", "e.xfrmUpdateBoundary.install();", "", "drop context install"),
    ("context", "e.xfrmUpdateBoundary.abort();", "", "drop context abort"),
    ("xfrm", "lastSelectionHash = image.nextSelectionHash;", "", "drop selection latch"),
    ("xfrm", "lastAppliedGestureMutationVersion = ulong.max;\n"
             "            armedUndoEpoch = ulong.max;\n"
             "            refireAnchor = null;", "", "drop refire stamp reset"),
    ("xfrm", "runBaselineValid = false;\n"
             "        runFrameValid = false;\n"
             "        morphRunValid_ = false;\n"
             "        itemBaselineValid = false;\n"
             "        runGpuBufferDirty = false;\n"
             "        if (image.hadRun)", "if (image.hadRun)", "drop run reset"),
    ("xfrm", "image.expectedAcen.installPreparedClearSoftPlaced();", "", "drop soft clear"),
    ("acen", "softPin = Pin.init;", "", "drop soft-pin write"),
):
    o, c = xfrm_boundary_owner, record_context
    x = prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"]
    a = prepared_source_texts[ROOT / "source/toolpipe/stages/actcenter.d"]
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    elif target == "xfrm": x = x.replace(old, new, 1)
    else:
        start = a.find("void installPreparedClearSoftPlaced()")
        pos = a.find(old, start)
        if pos >= 0: a = a[:pos] + new + a[pos + len(old):]
    if xfrm_update_boundary_gate(o, c, x, a):
        fail(f"Xfrm update boundary mutation did not RED: {label}")
xfrm_boundary_copy = ROOT / "tests/compile_fail/prepared_xfrm_update_boundary_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(xfrm_boundary_copy)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Xfrm update boundary token copy was not rejected:\n" + run.stdout)

xfrm_move_regrade_owner = (ROOT / "source/prepared_xfrm_move_regrade.d").read_text()
def xfrm_move_regrade_gate(owner, context, xfrm):
    return all(s in owner for s in (
        "final class PreparedXfrmMoveRegradeOwner",
        "target.classinfo !is XfrmTransformTool.classinfo",
        "target.preparedMeshForUpdate() !is &layer.meshRef()",
        "prepared_.owner != owner_", "prepared_.generation != generation_",
        "validatedToken_.owner != owner_",
        "validatedToken_.generation != generation_",
        "target_.preparedMoveRegradeMatches(image_, layer_.meshRef())",
        "target_.installPreparedMoveRegrade(image_);")) and \
        all(s in context for s in (
            "bool prepareXfrmMoveRegrade(PreparedXfrmMoveRegradeOwner owner)",
            "e.xfrmMoveRegrade.validate();", "e.xfrmMoveRegrade.install();",
            "e.xfrmMoveRegrade.abort();")) and \
        all(s in xfrm for s in (
            "PreparedXfrmMoveRegradeImage buildPreparedMoveRegrade(",
            "buildPreparedRefireCandidate(",
            "detachedItemTargets[i] = new Layer();",
            "detachedItemTargets[i].xform = target.xform;",
            "result.nextItemXforms[i] = target.xform;",
            "image.wrapperRefire = buildPreparedRefireState(",
            "preparedMoveRegradeMatches(",
            "installPreparedMoveRegrade(",
            "vertexIndicesToProcess = image.nextIndices;",
            "dragFalloff = image.nextFalloff;",
            "dragSnap = image.nextSnap;",
            "dragSymmetry = image.nextSymmetry;",
            "target.xform = image.nextItemXforms[i];",
            "installPreparedRefireState(image.wrapperRefire);"))
if not xfrm_move_regrade_gate(xfrm_move_regrade_owner, record_context,
        prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"]):
    fail("Xfrm Move re-grade owner contract drift")
for target, old, new, label in (
    ("owner", "target.classinfo !is XfrmTransformTool.classinfo", "false", "broaden product"),
    ("owner", "target.preparedMeshForUpdate() !is &layer.meshRef()", "false", "drop source identity"),
    ("owner", "target_.preparedMoveRegradeMatches(image_, layer_.meshRef())", "true", "drop validation"),
    ("owner", "target_.installPreparedMoveRegrade(image_);", "", "drop install"),
    ("context", "e.xfrmMoveRegrade.validate();", "true;", "drop context validation"),
    ("context", "e.xfrmMoveRegrade.install();", "", "drop context install"),
    ("context", "e.xfrmMoveRegrade.abort();", "", "drop context abort"),
    ("xfrm", "detachedItemTargets[i] = new Layer();", "detachedItemTargets[i] = target;", "alias live item"),
    ("xfrm", "vertexIndicesToProcess = image.nextIndices;", "", "drop cache install"),
    ("xfrm", "dragFalloff = image.nextFalloff;", "", "drop falloff install"),
    ("xfrm", "target.xform = image.nextItemXforms[i];", "", "drop item install"),
    ("xfrm", "installPreparedRefireState(image.wrapperRefire);", "", "drop refire state"),
):
    o, c = xfrm_move_regrade_owner, record_context
    x = prepared_source_texts[ROOT / "source/tools/transform/xfrm_transform.d"]
    if target == "owner": o = o.replace(old, new, 1)
    elif target == "context": c = c.replace(old, new, 1)
    else:
        before, found, after = x.rpartition(old)
        x = before + new + after if found else x
    if xfrm_move_regrade_gate(o, c, x):
        fail(f"Xfrm Move re-grade mutation did not RED: {label}")
xfrm_move_regrade_copy = ROOT / "tests/compile_fail/prepared_xfrm_move_regrade_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(xfrm_move_regrade_copy)], cwd=ROOT,
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Xfrm Move re-grade token copy was not rejected:\n" + run.stdout)

def complete_xfrm_update_root_gate(xfrm):
    signature = "final PreparedXfrmUpdateEffect prepareUpdate(ref VectorStack vts,"
    start = xfrm.find(signature)
    if start < 0: return False
    begin = xfrm.find("{", start) + 1
    body = xfrm[begin:balanced_source(xfrm, begin)-1]
    required = (
        "auto projection = projectPreparedUpdatePre(vts);",
        "PreparedXfrmUpdateEditCloseOwner.prepare(",
        "PreparedXfrmUpdateBoundaryOwner.prepare(",
        "PreparedXfrmSlotPollOwner.prepare(this, projection)",
        "PreparedXfrmMoveRegradeOwner.prepare(",
        "PreparedMoveUpdateOwner.prepare(moveSub, vts)",
        "PreparedRotateUpdateOwner.prepare(",
        "PreparedScaleUpdateOwner.prepare(",
        "PreparedXfrmUpdateTailOwner.prepare(",
        "context.consolidate(history.currentRunId)", "context.nextRun()",
        "context.markHistoryInstall()", "context.markNoHistoryInstall()",
        "context.prepareXfrmUpdateEditClose(editClose)",
        "context.prepareXfrmUpdateBoundary(boundaryOwner)",
        "context.prepareXfrmSlotPoll(slotOwner)",
        "context.prepareXfrmMoveRegrade(moveRegrade)",
        "context.prepareUpload(wrapperUpload,",
        "context.prepareMoveUpdate(moveOwner)",
        "context.prepareRotateUpdate(rotateOwner)",
        "context.prepareScaleUpdate(scaleOwner)",
        "context.prepareXfrmUpdateTail(tailOwner)")
    if not all(s in body for s in required): return False
    if body.count("context.prepareUpload(wrapperUpload,") != 2: return False
    order = (
        "context.markHistoryInstall()",
        "context.prepareXfrmUpdateEditClose(editClose)",
        "context.prepareXfrmUpdateBoundary(boundaryOwner)",
        "context.prepareXfrmSlotPoll(slotOwner)",
        "context.prepareXfrmMoveRegrade(moveRegrade)",
        "context.prepareUpload(wrapperUpload,",
        "context.prepareMoveUpdate(moveOwner)",
        "context.prepareRotateUpdate(rotateOwner)",
        "context.prepareScaleUpdate(scaleOwner)",
        "context.prepareXfrmUpdateTail(tailOwner)")
    return all(body.find(order[i]) < body.find(order[i + 1])
               for i in range(len(order) - 1))
complete_xfrm_source = prepared_source_texts[
    ROOT / "source/tools/transform/xfrm_transform.d"]
if not complete_xfrm_update_root_gate(complete_xfrm_source):
    fail("complete Xfrm update root contract drift")
for old, new, label in (
    ("context.consolidate(history.currentRunId)", "PreparedHistoryResult.init", "drop consolidate"),
    ("context.prepareXfrmUpdateEditClose(editClose)", "true", "drop edit close"),
    ("context.prepareXfrmUpdateBoundary(boundaryOwner)", "true", "drop boundary"),
    ("context.prepareXfrmSlotPoll(slotOwner)", "true", "drop slot latch"),
    ("context.prepareXfrmMoveRegrade(moveRegrade)", "true", "drop Move re-grade"),
    ("context.prepareUpload(wrapperUpload,", "context.prepareUpload(null,", "drop upload owner"),
    ("context.prepareRotateUpdate(rotateOwner)", "true", "drop Rotate bank"),
    ("context.prepareScaleUpdate(scaleOwner)", "true", "drop Scale bank"),
    ("context.prepareXfrmUpdateTail(tailOwner)", "true", "drop wrapper tail"),
):
    root_start = complete_xfrm_source.find(
        "final PreparedXfrmUpdateEffect prepareUpdate(ref VectorStack vts,")
    pos = complete_xfrm_source.find(old, root_start)
    mutated = complete_xfrm_source
    if pos >= 0:
        mutated = (mutated[:pos] + new + mutated[pos + len(old):])
    if complete_xfrm_update_root_gate(mutated):
        fail(f"complete Xfrm update root mutation did not RED: {label}")

edge_extend_update = prepared_source_texts[
    ROOT / "source/tools/edit/edge_extend.d"]
def edge_extend_update_gate(source):
    signature = "final PreparedXfrmUpdateEffect prepareUpdate(ref VectorStack vts,"
    start = source.find(signature)
    if start < 0: return False
    begin = source.find("{", start) + 1
    body = source[begin:balanced_source(source, begin)-1]
    return all(s in body for s in (
        "!ownsPreparedLayer(layer)",
        "xfrm.prepareUpdate(vts, context, layer, uploadOwner)",
        "PreparedXfrmUpdateEffect(preparedToolStateOwner,",
        "inner.kind, inner.accepted)"))
if not edge_extend_update_gate(edge_extend_update):
    fail("EdgeExtend update composition contract drift")
for old, new, label in (
    ("!ownsPreparedLayer(layer)", "false", "drop outer Layer identity"),
    ("xfrm.prepareUpdate(vts, context, layer, uploadOwner)",
     "PreparedXfrmUpdateEffect.init", "drop embedded Xfrm product"),
    ("inner.kind, inner.accepted)", "inner.kind, true)", "forge acceptance"),
):
    mutant = edge_extend_update.replace(old, new, 1)
    if mutant == edge_extend_update or edge_extend_update_gate(mutant):
        fail(f"EdgeExtend update mutation did not RED: {label}")

# Closed inherited base-noop owner infrastructure.  The effective product
# table above proves DragWeldTool is the sole activate/deactivate admission;
# this tranche deliberately has no producer or ledger claim yet.
inherited_noop_owner = (ROOT / "source/prepared_inherited_noop.d").read_text()
def inherited_noop_gate(owner, context):
    production = without_unittests(owner)
    install_match = re.search(r"void install\(\) nothrow @nogc\s*\{", production)
    if not install_match: return False
    install_body = production[install_match.end():balanced_source(
        production, install_match.end())-1]
    install_normalized = re.sub(r"\s+", " ", install_body).strip()
    exact_install = (
        "if (!pending_ || !validated_ || consumed_ || target_ is null || "
        "validatedToken_.owner != owner_ || "
        "validatedToken_.generation != generation_) return; consume();"
    )
    admit_match = re.search(r"static bool admit\(Tool target, "
        r"PreparedInheritedNoopKind kind\)\s*nothrow @nogc\s*\{", production)
    if not admit_match: return False
    admit_body = production[admit_match.end():balanced_source(
        production, admit_match.end())-1]
    admitted = re.findall(r"target\.classinfo is (\w+)\.classinfo", admit_body)
    expected_admitted = sorted(list(BASE_TOOL_EFFECTIVE_PRODUCTS["update"]) +
                               ["DragWeldTool"])
    return (
        "final class PreparedInheritedNoopOwner" in owner and
        owner.count("@disable this(this);") == 2 and
        not any(x in production for x in (" delegate", " function(", "void*", "ubyte[]")) and
        "if (kind != PreparedInheritedNoopKind.Update)\n"
        "            return target.classinfo is DragWeldTool.classinfo;" in owner and
        sorted(admitted) == expected_admitted and
        "prepared_.owner != owner_" in owner and
        "prepared_.generation != generation_" in owner and
        "validatedToken_.owner != owner_" in owner and
        "validatedToken_.generation != generation_" in owner and
        install_normalized == exact_install and
        "bool prepareInheritedNoop(PreparedInheritedNoopOwner owner)" in context and
        "e.inheritedNoop.validate();" in context and
        "e.inheritedNoop.install();" in context and
        "e.inheritedNoop.abort();" in context)
if not inherited_noop_gate(inherited_noop_owner, record_context):
    fail("Inherited base-noop owner contract drift")
inherited_noop_production_calls = sum(
    without_unittests(text).count("PreparedInheritedNoopOwner.prepare(") +
    without_unittests(text).count(".prepareInheritedNoop(")
    for text in prepared_source_texts.values())
if inherited_noop_production_calls != 2:
    fail("Inherited base-noop owner escaped its one dormant producer")
def inherited_noop_producer_gate(owner):
    production = without_unittests(owner)
    match = re.search(r"PreparedInheritedNoopEffect prepareInheritedNoop\(\s*"
        r"Tool target, PreparedInheritedNoopKind kind,\s*"
        r"PreparedRecordContext context\)\s*\{", production)
    if not match: return False
    body = production[match.end():balanced_source(production, match.end())-1]
    return all(x in body for x in (
        "auto targetOwner = target is null ? OwnedId.init\n"
        "                                      : target.preparedLifecycleOwner;",
        "if (context is null)",
        "scope(failure) context.discard();",
        "PreparedInheritedNoopOwner.prepare(target, kind)",
        "context.prepareInheritedNoop(owner) && context.markNoHistoryInstall();",
        "if (!accepted) context.discard();",
        "return PreparedInheritedNoopEffect(targetOwner, kind, accepted);")) and \
        body.count("PreparedInheritedNoopEffect(") == 2 and \
        not any(x in body for x in ("owner.install(", "context.install(",
                                    "context.validate("))
if not inherited_noop_producer_gate(inherited_noop_owner):
    fail("Inherited base-noop dormant producer contract drift")

def inherited_free_producer_call_count(source_texts):
    total = 0
    for text in source_texts.values():
        production = without_unittests(text)
        total += len(re.findall(r"(?<![\w.])prepareInheritedNoop\s*\(",
                                production))
    return total
# The two matches are the free function definition and the context method
# definition; method calls are dot-prefixed and counted by the owner census.
if inherited_free_producer_call_count(prepared_source_texts) != 2:
    fail("Inherited base-noop free producer gained a production caller")
free_call_mutant = dict(prepared_source_texts)
free_call_mutant[next(iter(free_call_mutant))] += \
    "\nvoid inheritedNoopEscapeForMutation() { prepareInheritedNoop(null, " \
    "PreparedInheritedNoopKind.Activate, null); }\n"
if inherited_free_producer_call_count(free_call_mutant) == 2:
    fail("Inherited base-noop free-producer escape mutation did not RED")
for target, old, new, label in (
    ("owner", "return target.classinfo is DragWeldTool.classinfo;", "return true;", "broaden lifecycle admission"),
    ("owner", "target.classinfo is ArcTool.classinfo ||", "", "drop update admission"),
    ("owner", "prepared_.owner != owner_", "false", "drop prepared owner"),
    ("owner", "prepared_.generation != generation_", "false", "drop prepared generation"),
    ("owner", "validatedToken_.owner != owner_", "false", "drop validated owner"),
    ("owner", "validatedToken_.generation != generation_", "false", "drop validated generation"),
    ("owner", "void install() nothrow @nogc", "void install()", "drop nothrow install"),
    ("owner", "        consume();\n    }\n\n    void abort()", "    }\n\n    void abort()", "drop install consume"),
    ("owner", "        consume();\n    }\n\n    void abort()", "        target_.activate(); consume();\n    }\n\n    void abort()", "smuggle lifecycle call"),
    ("owner", "        consume();\n    }\n\n    void abort()", "        target_.resyncSession(); consume();\n    }\n\n    void abort()", "smuggle non-lifecycle side effect"),
    ("owner", "        if (!pending_ || !validated_ || consumed_ || target_ is null ||\n            validatedToken_.owner != owner_ ||\n            validatedToken_.generation != generation_) return;\n        consume();", "        consume();", "drop exact install guard"),
    ("context", "e.inheritedNoop.validate();", "true;", "drop context validation"),
    ("context", "e.inheritedNoop.install();", "", "drop context install"),
    ("context", "e.inheritedNoop.abort();", "", "drop context abort"),
):
    owner, context = inherited_noop_owner, record_context
    if target == "owner": owner = owner.replace(old, new, 1)
    else: context = context.replace(old, new, 1)
    if inherited_noop_gate(owner, context):
        fail(f"Inherited base-noop mutation did not RED: {label}")

context_enlist_contract = (
    "resources_.reserve(1 + resources_.length);\n"
    "        if (!owner.begin()) return false;\n"
    "        scope(failure) owner.abort();"
)
def inherited_context_enlist_ok(context):
    match = re.search(
        r"bool prepareInheritedNoop\(PreparedInheritedNoopOwner owner\)\s*\{",
        context)
    if not match: return False
    body = context[match.end():balanced_source(context, match.end())-1]
    return context_enlist_contract in body and \
        "e.inheritedNoop = owner; resources_ ~= e; return true;" in body
if not inherited_context_enlist_ok(record_context):
    fail("Inherited base-noop reserve/begin/failure-cleanup order drift")
context_method = re.search(
    r"bool prepareInheritedNoop\(PreparedInheritedNoopOwner owner\)\s*\{",
    record_context)
context_body_end = balanced_source(record_context, context_method.end())
context_mutant = (record_context[:context_method.start()] +
    record_context[context_method.start():context_body_end].replace(
        "scope(failure) owner.abort();", "", 1) +
    record_context[context_body_end:])
if inherited_context_enlist_ok(context_mutant):
    fail("Inherited base-noop failure-cleanup mutation did not RED")

for old, new, label in (
    ("scope(failure) context.discard();", "", "drop producer failure cleanup"),
    ("PreparedInheritedNoopOwner.prepare(target, kind)", "null", "drop producer owner"),
    ("context.prepareInheritedNoop(owner) &&", "true &&", "drop producer enlist"),
    ("context.markNoHistoryInstall();", "true;", "drop producer NoHistory"),
    ("if (!accepted) context.discard();", "", "drop producer refusal discard"),
    ("return PreparedInheritedNoopEffect(targetOwner, kind, accepted);",
     "return PreparedInheritedNoopEffect(OwnedId.init, kind, accepted);",
     "wrong accepted owner"),
    ("return PreparedInheritedNoopEffect(targetOwner, kind, accepted);",
     "return PreparedInheritedNoopEffect(targetOwner, PreparedInheritedNoopKind.Deactivate, accepted);",
     "substitute result kind"),
    ("auto owner = PreparedInheritedNoopOwner.prepare(target, kind);",
     "auto owner = PreparedInheritedNoopOwner.prepare(target, kind); owner.install();",
     "early producer install"),
):
    mutant = inherited_noop_owner.replace(old, new, 1)
    if inherited_noop_producer_gate(mutant):
        fail(f"Inherited base-noop producer mutation did not RED: {label}")

inherited_noop_copy_fixture = ROOT / "tests/compile_fail/prepared_inherited_noop_token_copy.d"
run = subprocess.run(["dmd", "-c", *DMD_FLAGS, str(inherited_noop_copy_fixture)],
    cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout and
        not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("Inherited base-noop token copy was not rejected:\n" + run.stdout)

# P1.0c door capability grows off Tool's universal virtual surface. This first
# admitted tranche is exact so a class cannot silently inherit the legacy door
# while still appearing in the prepared writer census.
simple_door_clients = {
    "source/tools/deform/stroke_extrude_tool.d": "StrokeExtrudeTool",
    "source/tools/deform/smooth_shift_tool.d": "SmoothShiftTool",
    "source/tools/edit/poly_inset_tool.d": "PolyInsetTool",
    "source/tools/edit/poly_extrude.d": "PolyExtrudeTool",
    "source/tools/edit/edge_bevel.d": "EdgeBevelTool",
    "source/tools/edit/edge_extrude.d": "EdgeExtrudeTool",
    "source/tools/edit/poly_bevel.d": "PolyBevelTool",
    "source/tools/edit/vertex_bevel_tool.d": "VertexBevelTool",
    "source/tools/edit/vertex_extrude_tool.d": "VertexExtrudeTool",
    "source/tools/edit/vert_merge_tool.d": "VertexMergeTool",
}
private_state_door_clients = {
    "source/tools/alignment/array_tool.d": ("ArrayTool", "arraySession"),
    "source/tools/alignment/clone_tool.d": ("CloneTool", "cloneSession"),
    "source/tools/deform/magnet.d": ("MagnetTool", "magnetSession"),
    "source/tools/edit/reduce.d": ("ReductionTool", "reductionSession"),
}
cutting_door_clients = {
    "source/tools/slice/slice_tool.d": "SliceTool",
    "source/tools/slice/edge_slice_tool.d": "EdgeSliceTool",
    "source/tools/slice/loop_slice_tool.d": "LoopSliceTool",
}
gpu_layer_door_clients = {
    "source/tools/edit/edge_extend.d": "EdgeExtendTool",
}
vertex_door_clients = {
    "source/tools/create/vertex_place.d": "VertexTool",
}
typed_context_door_clients = {
    "source/tools/edit/topology_pen/tool.d": (
        "TopologyPenTool", "prepareActivate(context).accepted",
        "prepareDeactivate(context).resourceAccepted"),
}
resource_lifecycle_door_clients = {
    "source/tools/common/command_wrapper.d": (
        "abstract class CommandWrapperTool : Tool, RefireClient, PreparedToolDoorClient",
        "new ClickPointResourceOwner(clickHandle, threadIdentity,",
        "prepareDeactivate(context, owner).resourceAccepted",
        "prepareActivate(context).accepted"),
    "source/tools/edit/tack.d": (
        "class TackTool : Tool, PreparedToolDoorClient",
        "new GpuResourceOwner(&previewGpu_, threadIdentity,",
        "prepareDeactivate(context, owner).resourceAccepted",
        "new GpuCreateOwner(&previewGpu_, threadIdentity,"),
}
alignment_door_clients = {
    "source/tools/alignment/mirror.d": (
        "class MirrorTool : Tool, PreparedToolDoorClient",
        "new GpuCreateUploadOwner(&previewGpu, threadIdentity,",
        "new GpuUploadOwner(gpu, threadIdentity, contextIdentity)",
        "new GpuResourceOwner(&previewGpu, threadIdentity,"),
    "source/tools/alignment/radial_array_tool.d": (
        "class RadialArrayTool : Tool, PreparedToolDoorClient",
        "return prepareActivate(context).accepted;",
        "return prepareSessionDeactivate(context).accepted;"),
    "source/tools/alignment/radial_sweep_tool.d": (
        "class RadialSweepTool : Tool, PreparedToolDoorClient",
        "PreparedSelectionProfileOwner.radialSweep(this, *source,",
        "PreparedRadialSweepTransitionOwner.deactivate(this)",
        "new GpuCreateUploadOwner(&previewGpu, threadIdentity,"),
}
create_bridge_door_clients = {
    "source/tools/create/arc.d": (
        "class ArcTool : Tool, PreparedToolDoorClient",
        "PreparedPrivateStateOwner.arcIdle(this)",
        "context.preparePrivateState(owner)",
        "return prepareDoorIdle(context);"),
    "source/tools/create/box.d": (
        "class BoxTool : Tool, KeepAliveOnCancel, PreparedToolDoorClient",
        "new GpuCreateOwner(&previewGpu, threadIdentity,",
        "prepareDeactivate(context, layer, upload, destroy,"),
    "source/tools/create/primitive_create_tool.d": (
        "abstract class PrimitiveCreateTool : Tool, KeepAliveOnCancel, PreparedToolDoorClient",
        "new GpuCreateOwner(&previewGpu, threadIdentity,",
        "prepareDeactivate(context, layer, upload, destroy,"),
    "source/tools/create/pen.d": (
        "class PenTool : Tool, PreparedToolDoorClient",
        "new BoxHandlerBatchResourceOwner(vertHandlers,",
        "emptyUpload, destroy, handlers, new SnapOverlayOwner()"),
    "source/tools/edit/bridge_tool.d": (
        "class BridgeTool : Tool, PreparedToolDoorClient",
        "new GpuCreateOwner(&previewGpu_, threadIdentity,",
        "new GpuCreateUploadOwner(&previewGpu_, threadIdentity,"),
}
def p10c_door_capability_gate(context, sources, xfrm):
    if not all(x in context for x in (
            "interface PreparedToolPoseDoorClient",
            "bool prepareDoorInitialPose(ref VectorStack vts,")):
        return False
    if not all(x in context for x in (
            "interface PreparedToolDoorClient",
            "mixin template PreparedSimpleToolDoorClient(LayerT)",
            ": context.markNoHistoryInstall()",
            "return prepareActivate(context).accepted;")):
        return False
    if context.count("effect.historyAccepted ? context.markHistoryInstall()") != 2:
        return False
    for path, aggregate in simple_door_clients.items():
        body = sources[path]
        if f"class {aggregate} : Tool, PreparedToolDoorClient" not in body or \
                "mixin PreparedSimpleToolDoorClient!Layer;" not in body:
            return False
    for path, (aggregate, factory) in private_state_door_clients.items():
        body = sources[path]
        if f"class {aggregate} : Tool, PreparedToolDoorClient" not in body and \
                f"final class {aggregate} : Tool, PreparedToolDoorClient" not in body:
            return False
        if "mixin PreparedPrivateStateToolDoorClient!(Layer," not in body or \
                f"PreparedPrivateStateOwner.{factory});" not in body:
            return False
    for path, aggregate in cutting_door_clients.items():
        body = sources[path]
        if "PreparedToolDoorClient" not in body or \
                "override bool prepareDoorDeactivate(" not in body or \
                "override bool prepareDoorActivate(" not in body:
            return False
        if aggregate == "SliceTool" and \
                "prepareDeactivate(context, layer).resourceAccepted" not in body:
            return False
        if aggregate == "EdgeSliceTool" and not all(x in body for x in (
                "new GpuUploadOwner(gpu, threadIdentity, contextIdentity)",
                "new BoxHandlerBatchResourceOwner(handles_, threadIdentity,",
                "prepareDeactivate(context, layer, upload, handlers).resourceAccepted")):
            return False
        if aggregate == "LoopSliceTool" and not all(x in body for x in (
                "new GpuUploadOwner(gpu, threadIdentity, contextIdentity)",
                "prepareDeactivate(context, layer, upload).resourceAccepted")):
            return False
    for path, aggregate in gpu_layer_door_clients.items():
        body = sources[path]
        if f"class {aggregate} : Tool, PreparedToolDoorClient" not in body or \
                "new GpuUploadOwner(gpu, threadIdentity, contextIdentity)" not in body or \
                "prepareDeactivate(context, layer, upload).resourceAccepted" not in body or \
                "return prepareActivate(context).accepted;" not in body:
            return False
    for path, aggregate in vertex_door_clients.items():
        body = sources[path]
        if f"class {aggregate} : Tool, PreparedToolDoorClient" not in body or \
                not all(x in body for x in (
                    "prepareDeactivate(context, new SnapOverlayOwner(),",
                    "PreparedPrivateStateOwner.vertex(this)).resourceAccepted",
                    "auto prepared = prepareActivate();",
                    "validatePreparedActivate(prepared, validated)",
                    "auto owner = PreparedPrivateStateOwner.vertex(this);",
                    "context.preparePrivateState(owner)",
                    "context.markNoHistoryInstall()")):
            return False
    for path, (aggregate, activate, deactivate) in typed_context_door_clients.items():
        body = sources[path]
        if f"class {aggregate} : Tool, InputBindable, PreparedToolDoorClient" not in body or \
                f"return {activate};" not in body or \
                f"return {deactivate};" not in body:
            return False
    for path, needles in resource_lifecycle_door_clients.items():
        body = sources[path]
        if not all(needle in body for needle in needles):
            return False
    tack = sources["source/tools/edit/tack.d"]
    if "contextIdentity, true);" not in tack or \
            "return prepareActivate(context, owner).accepted;" not in tack:
        return False
    for path, needles in alignment_door_clients.items():
        if not all(needle in sources[path] for needle in needles):
            return False
    mirror = sources["source/tools/alignment/mirror.d"]
    sweep = sources["source/tools/alignment/radial_sweep_tool.d"]
    if "contextIdentity, true);" not in mirror or \
            "prepareDeactivate(context, layer, upload, destroy).resourceAccepted" not in mirror:
        return False
    if "contextIdentity, true);" not in sweep or not all(x in sweep for x in (
            "new GpuUploadOwner(gpu, threadIdentity, contextIdentity)",
            "new GpuResourceOwner(&previewGpu, threadIdentity,",
            "prepareDeactivate(context, transition, layer, upload, destroy).accepted")):
        return False
    for path, needles in create_bridge_door_clients.items():
        if not all(needle in sources[path] for needle in needles):
            return False
    for path in ("source/tools/create/box.d",
                 "source/tools/create/primitive_create_tool.d"):
        body = sources[path]
        if "contextIdentity, true);" not in body or not all(x in body for x in (
                "new GpuUploadOwner(gpu, threadIdentity, contextIdentity)",
                "new GpuResourceOwner(&previewGpu, threadIdentity,",
                "new SnapOverlayOwner()).resourceAccepted")):
            return False
    pen = sources["source/tools/create/pen.d"]
    if not all(x in pen for x in (
            "new GpuCreateOwner(&previewGpu, threadIdentity,",
            "auto commitUpload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity)",
            "auto refreshUpload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity)",
            "new GpuResourceOwner(&previewGpu, threadIdentity,")):
        return False
    bridge = sources["source/tools/edit/bridge_tool.d"]
    if "prepareActivate(context, create, upload).accepted" not in bridge or \
            "prepareDeactivate(context, layer, upload, destroy).resourceAccepted" not in bridge:
        return False
    arc_owner = (ROOT / "source/prepared_private_state.d").read_text()
    if not all(x in arc_owner for x in (
            "ArcIdle", "static PreparedPrivateStateOwner arcIdle(ArcTool target)",
            "arcStateWitness = target.preparedArcStateWitness()",
            "arcTarget.preparedArcStateWitness() != arcStateWitness",
            "arcTarget.installPreparedArcIdle()")):
        return False
    if "case PreparedPrivateStateKind.ArcIdle: e.kind = PreparedResourceKind.ArcState; break;" not in context:
        return False
    edge_extend = sources["source/tools/edit/edge_extend.d"]
    topology_pen = sources["source/tools/edit/topology_pen/tool.d"]
    if not all(x in edge_extend for x in (
            "PreparedToolPoseDoorClient",
            "override bool prepareDoorInitialPose(ref VectorStack vts,\n"
            "            PreparedRecordContext context, Layer layer,\n"
            "            ulong threadIdentity, ulong contextIdentity) {\n"
            "        auto upload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity);",
            "return prepareUpdate(vts, context, layer, upload).accepted;")):
        return False
    if not all(x in topology_pen for x in (
            "PreparedToolPoseDoorClient",
            "override bool prepareDoorInitialPose(ref VectorStack vts,",
            "return prepareUpdate(vts, context).accepted;")):
        return False
    return ("PreparedToolDoorClient," in xfrm and
        "PreparedToolPoseDoorClient," in xfrm and
        "override bool prepareDoorInitialPose(ref VectorStack vts," in xfrm and
        "auto upload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity);" in xfrm and
        "return prepareUpdate(vts, context, layer, upload).accepted;" in xfrm and
        "override bool prepareDoorDeactivate(" in xfrm and
        "override bool prepareDoorActivate(" in xfrm and
        "return prepareActivate(context).accepted;" in xfrm)

door_sources = {p: (ROOT / p).read_text() for p in
    set(simple_door_clients) | set(private_state_door_clients) |
    set(cutting_door_clients) | set(gpu_layer_door_clients) |
    set(vertex_door_clients) | set(typed_context_door_clients) |
    set(resource_lifecycle_door_clients) | set(alignment_door_clients) |
    set(create_bridge_door_clients)}
door_xfrm = (ROOT / "source/tools/transform/xfrm_transform.d").read_text()
if not p10c_door_capability_gate(record_context, door_sources, door_xfrm):
    fail("P1.0c prepared door capability tranche drift")
for target, old, new, label in (
    ("context", "effect.historyAccepted ? context.markHistoryInstall()",
     "false ? context.markHistoryInstall()", "drop history routing"),
    ("context", "return prepareActivate(context).accepted;",
     "return true;", "drop activation producer"),
    (next(iter(simple_door_clients)),
     "class StrokeExtrudeTool : Tool, PreparedToolDoorClient",
     "class StrokeExtrudeTool : Tool",
     "drop concrete capability"),
    (next(iter(private_state_door_clients)),
     "PreparedPrivateStateOwner.arraySession);",
     "PreparedPrivateStateOwner.cloneSession);",
     "substitute private-state owner"),
    ("source/tools/slice/edge_slice_tool.d",
     "new BoxHandlerBatchResourceOwner(handles_, threadIdentity,",
     "new BoxHandlerBatchResourceOwner(null, threadIdentity,",
     "drop cutting handler identity"),
    ("source/tools/edit/edge_extend.d",
     "override bool prepareDoorInitialPose(ref VectorStack vts,\n            PreparedRecordContext context, Layer layer,\n            ulong threadIdentity, ulong contextIdentity) {\n        auto upload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity);",
     "override bool prepareDoorInitialPose(ref VectorStack vts,\n            PreparedRecordContext context, Layer layer,\n            ulong threadIdentity, ulong contextIdentity) {\n        auto upload = new GpuUploadOwner(null, threadIdentity, contextIdentity);",
     "drop pose GPU subject identity"),
    (next(iter(vertex_door_clients)),
     "auto owner = PreparedPrivateStateOwner.vertex(this);",
     "auto owner = PreparedPrivateStateOwner.vertex(null);",
     "drop Vertex private-state subject identity"),
    (next(iter(typed_context_door_clients)),
     "return prepareDeactivate(context).resourceAccepted;",
     "return true;",
     "drop Topology Pen deactivation producer"),
    ("source/tools/common/command_wrapper.d",
     "new ClickPointResourceOwner(clickHandle, threadIdentity,",
     "new ClickPointResourceOwner(null, threadIdentity,",
     "drop Command Wrapper click-handle identity"),
    ("source/tools/edit/tack.d",
     "new GpuCreateOwner(&previewGpu_, threadIdentity,",
     "new GpuCreateOwner(null, threadIdentity,",
     "drop Tack activation GPU identity"),
    ("source/tools/alignment/mirror.d",
     "new GpuResourceOwner(&previewGpu, threadIdentity,",
     "new GpuResourceOwner(null, threadIdentity,",
     "drop Mirror preview GPU identity"),
    ("source/tools/alignment/radial_array_tool.d",
     "return prepareSessionDeactivate(context).accepted;",
     "return true;",
     "drop Radial Array deactivation producer"),
    ("source/tools/alignment/radial_sweep_tool.d",
     "PreparedSelectionProfileOwner.radialSweep(this, *source,",
     "PreparedSelectionProfileOwner.radialSweep(null, *source,",
     "drop Radial Sweep profile subject identity"),
    ("source/tools/create/box.d",
     "new GpuCreateOwner(&previewGpu, threadIdentity,",
     "new GpuCreateOwner(null, threadIdentity,",
     "drop Box preview GPU identity"),
    ("source/tools/create/pen.d",
     "new BoxHandlerBatchResourceOwner(vertHandlers,",
     "new BoxHandlerBatchResourceOwner(null,",
     "drop Pen handler batch identity"),
    ("source/tools/create/primitive_create_tool.d",
     "new SnapOverlayOwner()).resourceAccepted",
     "null).resourceAccepted",
     "drop Primitive snap owner"),
    ("source/tools/edit/bridge_tool.d",
     "new GpuCreateUploadOwner(&previewGpu_, threadIdentity,",
     "new GpuCreateUploadOwner(null, threadIdentity,",
     "drop Bridge preview GPU identity"),
    ("source/tools/create/arc.d",
     "PreparedPrivateStateOwner.arcIdle(this)",
     "PreparedPrivateStateOwner.arcIdle(null)",
     "drop Arc private-state subject identity"),
    ("xfrm", "return prepareActivate(context).accepted;", "return true;",
     "drop Xfrm activation producer"),
):
    c, sources, xfrm = record_context, dict(door_sources), door_xfrm
    if target == "context": c = c.replace(old, new, 1)
    elif target == "xfrm": xfrm = xfrm.replace(old, new, 1)
    else: sources[target] = sources[target].replace(old, new, 1)
    if p10c_door_capability_gate(c, sources, xfrm):
        fail(f"P1.0c door capability mutation did not RED: {label}")

print(f"prepared protocol census PASS ({len(MANIFEST)} symbols, 2 shared-funnel callers, {len(fixtures) + 6} compile-fail fixtures)")
