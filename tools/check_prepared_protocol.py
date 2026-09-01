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
    for row in CURRENT_WRITERS["products"]:
        product = f"{module_alias[row['module']]}.{row['aggregate']}"
        lines.append(f"static assert(is({product} == class));")
    path = Path(td) / "prepared_writer_traits.d"
    path.write_text("\n".join(lines))
    compile_traits = subprocess.run(["dmd", "-o-", *DMD_FLAGS, str(path)], cwd=ROOT,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if compile_traits.returncode:
        fail("P1.0b.0 compiler-backed owner/signature census failed:\n" + compile_traits.stdout)

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
all_hook_keys = {(r["module"], r["aggregate"], r["symbol"])
                 for r in CURRENT_WRITERS["hooks"]}
if not TOOL_STATE_CONVERTED <= all_hook_keys:
    fail("P1.0b.1 converted tool-state row left the frozen census")
TOOL_STATE_DEFERRED = all_hook_keys - TOOL_STATE_CONVERTED

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
    "1500a754b4b9103d0ff8cc978ad874680a1a8f1e293e3bece17fadd7cbf91c64"
def validate_deferred_rows(rows, require_canonical=True):
    keys = {(r["key"]["module"], r["key"]["aggregate"],
             r["key"]["symbol"], r["key"]["signature"]) for r in rows}
    expected = {(r["module"], r["aggregate"], r["symbol"], r["signature"])
                for r in CURRENT_WRITERS["hooks"]
                if (r["module"], r["aggregate"], r["symbol"])
                   not in TOOL_STATE_CONVERTED}
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
for field in ("batch", "reason"):
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
batch_pair = next((i, j) for i in range(len(batch_swap))
                  for j in range(i + 1, len(batch_swap))
                  if batch_swap[i]["batch"] != batch_swap[j]["batch"])
batch_swap[batch_pair[0]]["batch"], batch_swap[batch_pair[1]]["batch"] = \
    batch_swap[batch_pair[1]]["batch"], batch_swap[batch_pair[0]]["batch"]
expect_deferred_exact_drift(batch_swap, "allowed-batch swap")

reason_swap = json.loads(json.dumps(TOOL_STATE_DEFERRED_ROWS))
reason_pair = next((i, j) for i in range(len(reason_swap))
                   for j in range(i + 1, len(reason_swap))
                   if reason_swap[i]["reason"] != reason_swap[j]["reason"])
reason_swap[reason_pair[0]]["reason"], reason_swap[reason_pair[1]]["reason"] = \
    reason_swap[reason_pair[1]]["reason"], reason_swap[reason_pair[0]]["reason"]
expect_deferred_exact_drift(reason_swap, "allowed-reason swap")

reason_replace = json.loads(json.dumps(TOOL_STATE_DEFERRED_ROWS))
reason_replace[0]["reason"] = "different nonempty reviewed-looking reason"
expect_deferred_exact_drift(reason_replace, "nonempty-reason replacement")

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
for path in (ROOT / "source").rglob("*.d"):
    if path.name not in ("record_observer_hub.d", "command_history.d"):
        production_hub_refs += path.read_text().count("RecordObserverHub")
if production_hub_refs:
    fail("P1.0b.3a record observer hub gained a pre-cutover caller")
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
        "\nbool p1Unauthorized(ref Tool active, CommandHistory history, ref ChangeBus bus, "
        "ref PreparedArm prepared) nothrow { return commitPreparedArm(active, history, bus, prepared); }\n")
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
         ("change_bus", "PreparedDeliveryJournal.copyOf", "PreparedDeliveryJournal(const(PreparedJournalEntry)[])")},
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
    (ast_dir / "change_bus.d").write_text("module change_bus; import prepared_tool_effect; struct ChangeBus{} struct PreparedDeliveryJournal{static PreparedDeliveryJournal copyOf(const(PreparedJournalEntry)[]){return PreparedDeliveryJournal();} void replay(ref ChangeBus) nothrow{}}")
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
    if re.search(r"\b(?:PreparedDeliveryJournal\.)?copyOf\s*\(", body):
        calls.add(("change_bus", "PreparedDeliveryJournal.copyOf", "PreparedDeliveryJournal(const(PreparedJournalEntry)[])"))
    known_syntax = re.sub(r"\b(?:OwnedBytes\.)?copyOf\s*\(", "(", body)
    known_syntax = re.sub(r"\b(?:result\.effects\.)?append\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\bresult\.candidate_\.prepareFrom\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\bresult\.candidate_\.discardCandidate\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\bhistory\.prepareCurrentImage\s*\(", "(", known_syntax)
    known_syntax = re.sub(r"\b(?:PreparedDeliveryJournal\.)?copyOf\s*\(", "(", known_syntax)
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
with tempfile.TemporaryDirectory(prefix="vibe3d-prepared-copy-") as td:
    copy_dir = Path(td)
    for name in ("prepared_tool_effect", "prepared_tool_transition"):
        (copy_dir / f"{name}.d").write_text((ROOT / f"source/{name}.d").read_text())
    (copy_dir / "command_history.d").write_text("module command_history; struct PreparedHistoryImage{} class CommandHistory{PreparedHistoryImage prepareCurrentImage(){return PreparedHistoryImage();} void installPreparedImage(ref PreparedHistoryImage) nothrow{}}")
    (copy_dir / "change_bus.d").write_text("module change_bus; import prepared_tool_effect; struct ChangeBus{} struct PreparedDeliveryJournal{static PreparedDeliveryJournal copyOf(const(PreparedJournalEntry)[]){return PreparedDeliveryJournal();} void replay(ref ChangeBus) nothrow{}}")
    (copy_dir / "tool.d").write_text("module tool; class Tool{}")
    (copy_dir / "registry.d").write_text("module registry; import tool; alias ToolFactory=Tool delegate();")
    (copy_dir / copy_fixture.name).write_text(copy_fixture.read_text())
    run = subprocess.run(["dmd", "-c", "-I.", copy_fixture.name], cwd=copy_dir,
                         text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if run.returncode == 0 or ("not copyable" not in run.stdout
                           and not ("copy constructor" in run.stdout and "disabled" in run.stdout)):
    fail("PreparedArm copy was not rejected by its disabled copy constructor:\n" + run.stdout)

print(f"prepared protocol census PASS ({len(MANIFEST)} symbols, 0 door callers, {len(fixtures)} compile-fail fixtures)")
