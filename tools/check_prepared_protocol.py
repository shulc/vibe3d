#!/usr/bin/env python3
"""P1.0a source/compile-fail census. No production activation door may call it."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import json
import shutil

from prepared_writer_census import scan as scan_writer_graph, canonical as canonical_writer_graph

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
