#!/usr/bin/env python3
"""Source census used by the P1.0b.0 frozen writer manifest.

This is deliberately a source/AST-shaped inventory, not a list of friendly
names: a row is module + enclosing aggregate + exact symbol and contains the
ordered domain word and source call edges from that exact body.
"""
from pathlib import Path
import hashlib
import json
import re

DOMAINS = ("ToolState", "Mesh", "CommandHistory", "GpuGl",
           "SessionPipeStickyParam")

def _mask_comments(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/|/\+.*?\+/", lambda m: " " * len(m.group()),
                  text, flags=re.S)

def _mask_unittests(text):
    masked = list(text)
    for match in list(re.finditer(r"(?:\bversion\s*\(\s*unittest\s*\)\s*|\bunittest\s*)\{", _mask_comments(text)))[::-1]:
        try: end = _balanced(text, match.end())
        except ValueError: continue
        masked[match.start():end] = " " * (end - match.start())
    return "".join(masked)

def _balanced(text, start):
    depth = 1
    i = start
    quote = None
    comment = None
    while i < len(text) and depth:
        c = text[i]
        if comment == "//":
            if c == "\n": comment = None
        elif comment in ("/*", "/+"):
            close = "*/" if comment == "/*" else "+/"
            if text.startswith(close, i): comment = None; i += 2; continue
        elif quote:
            if c == "\\": i += 2; continue
            if c == quote: quote = None
        elif text.startswith("//", i): comment = "//"; i += 2; continue
        elif text.startswith("/*", i): comment = "/*"; i += 2; continue
        elif text.startswith("/+", i): comment = "/+"; i += 2; continue
        elif c in "\"'": quote = c
        elif c == "{" : depth += 1
        elif c == "}" : depth -= 1
        i += 1
    if depth: raise ValueError("unbalanced D source")
    return i

def _aggregate(text, pos):
    found = "<module>"
    declarations = _mask_comments(text)
    for m in re.finditer(r"\b(?:class|struct)\s+(\w+)[^{;]*\{", declarations[:pos]):
        try:
            if _balanced(text, m.end()) > pos: found = m.group(1)
        except ValueError: pass
    return found

def _calls(body):
    out = []
    scrub = re.sub(r"//[^\n]*|/\*.*?\*/|\"(?:\\.|[^\"])*\"", " ", body,
                   flags=re.S)
    for m in re.finditer(r"(?<!\bnew\s)(\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*\(", scrub):
        name = m.group(1)
        if name.split(".")[-1] in {"if","for","foreach","while","switch","catch","assert","cast","version"}: continue
        out.append(name)
    return out

def _semantic_digest(body):
    # Approximate the compiler token stream: comments and formatting are not
    # behavior, while identifiers, literals and operators remain significant.
    tokens = re.sub(r"//[^\n]*|/\*.*?\*/|/\+.*?\+/", " ", body, flags=re.S)
    tokens = " ".join(tokens.split())
    return hashlib.sha256(tokens.encode()).hexdigest()

def _domains(body):
    """Ordered conservative writer-domain word, statement by statement."""
    word = []
    body = re.sub(r"//[^\n]*|/\*.*?\*/|/\+.*?\+/|\"(?:\\.|[^\"])*\"",
                  " ", body, flags=re.S)
    for stmt in re.split(r"[;{}]", body):
        s = stmt.strip()
        if not s: continue
        tags = []
        if re.search(r"(?:history|command|undo|record|commitEdit)", s, re.I): tags.append("CommandHistory")
        if re.search(r"(?:mesh|topology|selection|\bsel\w*|snapshot|appendBuild|commitPolygon|cancelPolygon|evaluate)", s, re.I): tags.append("Mesh")
        if re.search(r"(?:gpu|\bgl[A-Z]|preview|buffer|upload|vao|vbo|evaluate)", s, re.I): tags.append("GpuGl")
        if re.search(r"(?:session|pipe|sticky|param|editMode|document)", s, re.I): tags.append("SessionPipeStickyParam")
        # Assignment/increment to anything not clearly owner-qualified is
        # tool-private state. Calls alone are represented by their call edge.
        if re.search(r"(?<![=!<>])=(?!=)|\+\+|--", s) and not tags: tags.append("ToolState")
        for tag in DOMAINS:
            if tag in tags and (not word or word[-1] != tag): word.append(tag)
    return word

def _methods(path, names):
    text = path.read_text()
    module_match = re.search(r"^module\s+([\w.]+)\s*;", text, re.M)
    if not module_match: raise ValueError(f"missing module declaration: {path}")
    module = module_match.group(1)
    rows = []
    pat = re.compile(r"\b(?:override\s+)?(?:final\s+)?(void|Param\[\])\s+(" + "|".join(names) + r")\s*\(([^;{}]*)\)\s*\{")
    for m in pat.finditer(text):
        end = _balanced(text, m.end())
        body = text[m.end():end-1]
        rows.append({"module": module, "aggregate": _aggregate(text, m.start()),
                     "symbol": m.group(2),
                     "signature": f"{m.group(1)}({re.sub(r'\\s+', ' ', m.group(3).strip())})",
                     "semantic_sha256": _semantic_digest(body)})
    return rows

def scan(root):
    root = Path(root)
    tool_files = sorted((root / "source/tools").rglob("*.d"))
    hooks = []
    for p in [root / "source/tool.d", *tool_files]:
        hooks += _methods(p, ("activate", "update", "onParamChanged", "deactivate"))
    params = []
    for p in [root / "source/tool.d", *tool_files]: params += _methods(p, ("params",))
    reg = (root / "source/registration.d").read_text()
    factories = []
    for m in re.finditer(r'reg\.toolFactories\["([^"]+)"\]\s*=\s*typedToolFactory!(\w+)\s*\(\(\)\s*\{', reg):
        end = _balanced(reg, m.end())
        body = reg[m.end():end-1]
        factories.append({"id": m.group(1), "aggregate": _aggregate(reg, m.start()),
                          "symbol": "toolFactories[\"%s\"]" % m.group(1),
                          "product_types": [m.group(2)],
                          "semantic_sha256": _semantic_digest(body)})
    # Runtime-generated preset ids are a production factory path too. Its
    # product is the product of the referenced base factory, not a new class.
    presets = (root / "source/tool_presets.d").read_text()
    preset_assign = list(re.finditer(r"reg\.toolFactories\[p\.id\]\s*=\s*typedPresetFactory\s*;", presets))
    if len(preset_assign) != 1:
        raise ValueError("expected the single generated preset factory assignment")
    maker = re.search(r"ToolFactory\s+makeFactory\(T\)\([^)]*\)\s*\{", presets)
    if not maker: raise ValueError("preset makeFactory vanished")
    maker_end = _balanced(presets, maker.end())
    maker_body = presets[maker.end():maker_end-1]
    factories.append({"id": "<generated:p.id>", "aggregate": "registerToolPresets",
                      "symbol": "toolFactories[p.id]", "product_types": [],
                      "semantic_sha256": _semantic_digest(maker_body)})

    # Exhaustive production assignment proof. registration.d has no generated
    # ids; tool_presets.d has exactly the one dynamic assignment above.
    assignment_count = len(re.findall(r"\breg\.toolFactories\s*\[[^]]+\]\s*=", reg)) \
        + len(re.findall(r"\breg\.toolFactories\s*\[[^]]+\]\s*=", presets))
    if assignment_count != len(factories):
        raise ValueError(f"factory assignment census mismatch: source={assignment_count} rows={len(factories)}")

    # Reachability is product-driven, not "every method with this spelling".
    # Expand concrete factory products through inheritance and composed
    # subtools constructed in their class bodies (XfrmTransformTool is the
    # important production composition: Move/Rotate/Scale).
    classes = {}
    for path in [root / "source/tool.d", *tool_files]:
        text = path.read_text()
        module_match = re.search(r"^module\s+([\w.]+)\s*;", text, re.M)
        masked = _mask_comments(text)
        for cm in re.finditer(r"\bclass\s+(\w+)\s*(?::\s*([^\{]+))?\s*\{", masked):
            end = _balanced(text, cm.end())
            bases = re.findall(r"\b[A-Za-z_]\w*\b", cm.group(2) or "")
            classes[cm.group(1)] = {"bases": bases, "module": module_match.group(1),
                                    "constructs": re.findall(r"\bnew\s+([A-Za-z_]\w*)\s*\(", text[cm.end():end-1])}
    by_id = {f["id"]: f for f in factories if not f["id"].startswith("<")}
    preset_text = (root / "config/tool_presets.yaml").read_text()
    preset_bases = sorted(set(re.findall(r"^\s*base:\s*([^\s#]+)", preset_text, re.M)))
    unknown_bases = [base for base in preset_bases if base not in by_id]
    if unknown_bases: raise ValueError(f"preset base lacks factory descriptor: {unknown_bases}")
    factories[-1]["preset_bases"] = preset_bases
    factories[-1]["product_types"] = sorted({product for base in preset_bases
                                              for product in by_id[base]["product_types"]})
    reachable = {c for f in factories for c in f["product_types"]}
    changed = True
    while changed:
        changed = False
        for aggregate in list(reachable):
            info = classes.get(aggregate, {})
            for related in info.get("bases", []) + info.get("constructs", []):
                if related in classes and related not in reachable:
                    reachable.add(related); changed = True
    hooks = [row for row in hooks if row["aggregate"] in reachable]
    params = [row for row in params if row["aggregate"] in reachable]

    surfaces = []
    for path, symbol in ((root / "source/app.d", "activateToolById"),
                         (root / "source/commands/tool/set.d", "applyImpl")):
        text = path.read_text()
        match = re.search(r"\b" + symbol + r"\s*\([^;{}]*\)[^{;]*\{", _mask_comments(text))
        if not match: raise ValueError(f"legacy surface vanished: {symbol}")
        end = _balanced(text, match.end())
        body = text[match.end():end-1]
        mm = re.search(r"^module\s+([\w.]+)\s*;", text, re.M)
        module = mm.group(1) if mm else path.stem
        surfaces.append({"module": module, "aggregate": _aggregate(text, match.start()),
                         "symbol": symbol, "classification": "LegacyDoor",
                         "semantic_sha256": _semantic_digest(body),
                         "prepared_delegations": len(re.findall(
                             r"\b(?:prepareArm|commitPreparedArm|producePreparedEffects|installLegacyPreparedEffects)\s*\(", body))})
    bypasses = []
    internal_publishers = []
    bypass_pattern = re.compile(r"\b(?:prepareArm|commitPreparedArm|producePreparedEffects|installLegacyPreparedEffects)\s*\(")
    for path in sorted((root / "source").rglob("*.d")):
        text = _mask_comments(path.read_text())
        for match in bypass_pattern.finditer(text):
            row = {"path": str(path.relative_to(root)),
                   "symbol": match.group(0).split("(")[0].strip(),
                   "line": text.count("\n", 0, match.start()) + 1}
            line_start = text.rfind("\n", 0, match.start()) + 1
            prefix = text[line_start:match.start()].strip()
            if path.name == "prepared_tool_transition.d" and (
                    (row["symbol"] == "prepareArm" and prefix == "PreparedArm") or
                    (row["symbol"] == "commitPreparedArm" and prefix == "bool")):
                internal_publishers.append(row)
            else:
                bypasses.append(row)
    products = [{"module": classes[name]["module"], "aggregate": name,
                 "symbol": "factoryProduct", "signature": name}
                for name in sorted({product for factory in factories
                                    for product in factory["product_types"]})]
    return {"hooks": hooks, "params": params, "factories": factories,
            "products": products, "surfaces": surfaces, "bypasses": bypasses,
            "internal_publishers": internal_publishers}

def canonical(data):
    return json.dumps(data, sort_keys=True, separators=(",", ":"))

if __name__ == "__main__":
    import sys
    print(json.dumps(scan(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parents[1]),
                     indent=2, sort_keys=True))
