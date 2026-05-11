# MODO tool-config formats reference

Notes on how MODO 9 stores **tool presets** and **tool UI** as
declarative config rather than code. Captured from spelunking
`/home/ashagarov/Program/Modo902/resrc/*.cfg` and the bundled
SDK headers in `LXSDK_661446/include/`. Useful as we keep
porting MODO's UX patterns into vibe3d.

Files referenced live under `/home/ashagarov/Program/Modo902/resrc/`.
Cross-references to vibe3d below assume the current repo layout.

---

## 1. `presets.cfg` — Tool Presets

### Anatomy

Each preset is a `<hash type="ToolPreset" key="<preset-id>">` block.
Inside it lists one or more `<list type="Tool" val="...">` rows; each
row is one toolpipe entry, possibly with `<list type="Attr">` children.

Example — `xfrm.shear` (`presets.cfg:~7000`):

```xml
<hash type="ToolPreset" key="xfrm.shear">
  <list type="Tool" val="falloff.linear +ESFQG 'WGHT'">
    <list type="Attr">auto integer 1</list>
    <list type="Attr">shape integer 0</list>
    <list type="Attr">mode integer 0</list>
    <list type="Attr">p0 float 0.000000</list>
    <list type="Attr">p1 float 0.000000</list>
  </list>
  <list type="Tool" val="xfrm.transform +ESFQG 'ACTR'">
    <list type="Attr">TX float 0.000000</list>
    <list type="Attr">TY float 0.000000</list>
    ...
  </list>
</hash>
```

Reading it: «xfrm.shear is `falloff.linear` in the WGHT slot +
`xfrm.transform` in the ACTR slot, each with these initial attrs».

### `val` field decomposed

```
<tool-id> +<FLAG_LETTERS> '<TASK_CODE>'
```

#### tool-id

Identifier of a C++-registered tool or modifier.

| MODO tool-id          | Role                                            |
|-----------------------|-------------------------------------------------|
| `xfrm.transform`      | Universal transform tool (move/rotate/scale)    |
| `xfrm.rotate` / `.scale` | Transform variants with fixed mode           |
| `falloff.linear` / `.radial` / `.screen` / `.cylinder` | Falloff modifiers |
| `actr.auto` / `actr.select` / ... | ActionCenter modifiers               |
| `axis.auto` / `axis.element` / ... | Axis modifiers                       |
| `prim.cube` / `prim.sphere` / ... | Primitive-creation tools             |
| `tool.sculpt` / `Bend` / `Flex`   | Standalone tools                     |

vibe3d analogues: `move`, `rotate`, `scale`, `bevel`, `prim.cube`,
etc. — registered in `app.d::reg.toolFactories`.

#### `+<FLAG_LETTERS>` — per-pipe-entry behaviour bits

Observed flag combinations in `presets.cfg`:
```
+E   +EA   +ESX   +EASFQG   +EATSFQG   +EALSFQG   +EASTFQG
+ESFQG   +ESFQGI   +EDSFQG   +EATSFQG   +EADSFQG   +ETSFQG
```

Letter meaning is **not exposed in the open SDK headers**;
best-effort interpretation from context + Tool Pipe panel docs +
`LXfTMOD_*` bits in `lxvmodel.h`:

| Letter | Likely meaning                                              | SDK link                |
|--------|-------------------------------------------------------------|-------------------------|
| **E**  | **Enabled** — entry active in pipe (Tool Pipe "E" column)   | always present          |
| **A**  | **Auto** mode — auto-attribute hauling                       | `LXfTMOD_*ATTRHAUL`     |
| **D**  | **Default / Drag-reset**                                     | —                       |
| **S**  | **Solo** / **Symmetric** input                               | —                       |
| **F**  | **Falloff-input** / **Final**                                | —                       |
| **Q**  | **Quiet** — UI / hauling suppressed                          | —                       |
| **G**  | **General** input pattern (handles + click)                  | `LXfTMOD_I_GENERAL`     |
| **T**  | **Transparent** input pass-through                           | —                       |
| **L**  | **Locked** — modifier can't be removed                       | —                       |
| **X**  | **eXclusive** / no-select-through                            | `I*_NOSELECT`           |
| **I**  | **Initial** / input-attrhaul                                 | `LXfTMOD_I0_ATTRHAUL`   |

Typical `+ESFQG` for falloffs / `+EASFQG` for transform tools is
«Enabled, Symmetric, Falloff-input, Quiet handles, General-input».
vibe3d ignores these — every stage we register has fixed defaults.

#### `'<TASK_CODE>'` — toolpipe slot

FOURCC from `LXi_TASK_*` in `lxtool.h`. vibe3d's `TaskCode` enum
in `source/toolpipe/stage.d` mirrors these 1:1 (the in-scope
subset):

| MODO   | vibe3d `TaskCode`    | vibe3d ordinal (from `LXs_ORD_*`) |
|--------|----------------------|-----------------------------------|
| `WORK` | `Work`               | `0x30`                            |
| `SYMM` | `Symm`               | `0x31`                            |
| `CONT` | `Cont`               | `0x38`                            |
| `STYL` | `Styl`               | `0x39`                            |
| `SNAP` | `Snap`               | `0x40`                            |
| `CONS` | `Cons`               | `0x41`                            |
| `ACEN` | `Acen`               | `0x60`                            |
| `AXIS` | `Axis`               | `0x70`                            |
| `PATH` | `Path`               | `0x80`                            |
| `WGHT` | `Wght`               | `0x90`                            |
| `ACTR` | `Actr`               | `0xF0`                            |
| `POST` | `Post`               | `0xF1`                            |

Plus paint/brush/particle/effector/side codes that vibe3d
doesn't ship.

### vibe3d equivalent — `config/tool_presets.yaml`

We collapse MODO's verbose XML to:

```yaml
- id: xfrm.shear
  base: move
  pipe:
    falloff:
      type: linear
```

`base` names a vibe3d tool-id from `reg.toolFactories`; `pipe.<stageId>`
names a stage via `Pipeline.findById(...)` (matches `Stage.id()`).
Loader: `source/tool_presets.d`. Registered into the factory map at
app startup right after the static commands.

We **don't** ship the `+FLAGS` field — vibe3d's per-stage defaults
already cover what those flags configured per-preset in MODO.

---

## 2. `props.cfg` — Tool Properties UI

21 649 lines describing every Tool Properties form in MODO.
Architecture is fully declarative — tool C++ code only registers
the attribute schema; the UI layout lives here.

### Sheet — one form / form-fragment

```xml
<hash type="Sheet" key="15515130155:sheet">
  <atom type="Label">Cube</atom>
  <atom type="Filter">28985590035:filterPreset</atom>
  <atom type="Group">toolprops/primitives</atom>
  <list type="Control" val="sub 24301140007:sheet">          <!-- sub-sheet -->
    <atom type="Label">Position 3D Gang</atom>
    <atom type="Style">inlinegang</atom>
  </list>
  <list type="Control" val="cmd tool.attr prim.cube radius ?">   <!-- attr widget -->
  <list type="Control" val="cmd tool.attr prim.cube segmentsR ?">
  <list type="Control" val="cmd tool.attr prim.cube sharp ?">
  <list type="Control" val="div ">                              <!-- separator -->
  <list type="Control" val="cmd tool.attr prim.cube axis ?">
  <list type="Control" val="cmd tool.attr prim.cube uvs ?">
  ...
  <list type="Control" val="cmd tool.apply">                    <!-- action button -->
    <atom type="Label">Apply</atom>
  </list>
</hash>
```

### Control kinds (the `val=` first token)

| `val=`                         | What it renders                                  |
|--------------------------------|--------------------------------------------------|
| `cmd tool.attr <id> <attr> ?`  | auto-widget bound to `<id>.<attr>` (type from schema) |
| `cmd tool.apply`               | Apply button                                     |
| `cmd <commandId> ...`          | arbitrary command-button                         |
| `cmd item.channel <chan> ?`    | item-channel binding (animation/proc rig)        |
| `sub <hash>:sheet`             | embed another Sheet (used for "gangs" — groups)  |
| `div `                         | horizontal separator                             |
| `ref <hash>:sheet`             | reference (similar to sub but inlined)           |

The trailing `?` in `cmd tool.attr ...` means «auto-substitute
current value of the attribute». Without it, the control becomes
a "set to fixed value" button.

### Sheet-level atoms

| Atom              | Meaning                                                          |
|-------------------|------------------------------------------------------------------|
| `Label`           | Human-readable title (i18n via `@@N` placeholders)               |
| `Desc`            | Tooltip / longer description                                     |
| `Filter`          | Preset-key — predicate that gates Sheet visibility (see below)   |
| `Group`           | Parent container in the form-tree (`toolprops/primitives`, ...)  |
| `Layout`          | `properties` / `vtoolbar` / `htoolbar` / `popover` / ...         |
| `Columns`         | Auto-flow grid column count                                      |
| `IconMode` / `IconSize` | text / icon / both, small / med / large                   |
| `Style`           | `inlinegang` / `forcetabs` / `toolchoice` / ...                  |
| `Export`          | 0/1 — whether the Sheet is user-exportable                       |
| `ShowLabel`       | 0/1 — whether the title chip renders                             |

### Filter Presets — when to show the Sheet

`<atom type="Filter">` points at a `<hash type="Preset" key="...">`
that is itself a tiny boolean predicate over runtime state:

```xml
<hash type="Preset" key="28985590035:filterPreset">
  <list type="Node">1 .group 0 ""</list>
  <list type="Node">1 toolType prim.cube</list>          <!-- predicate atom -->
  <list type="Node">-1 .endgroup </list>
</hash>
```

Reads as: «show this Sheet when `toolType == prim.cube`».

Other observed predicates: `selectionType`, `meshType`, `editMode`,
`viewType` (3D / UV / etc.), `itemType`. Groups (`.group` / `.endgroup`)
let you build AND / OR trees. Same machinery powers menu
visibility, tool-button enable/disable, etc.

### Category / Group hierarchy

Two complementary mechanisms:

1. **`<atom type="Group">toolprops/primitives</atom>`** —
   parent container in a fixed tree. The Tool Properties root sheet
   (`toolprops:general`) renders all Sheets whose `Group` resolves
   inside its sub-tree.
2. **`<hash type="InCategory" key="toolprops:general#head">`** —
   alternative ad-hoc attachment with an `Ordinal` for sort order.

### Scale

- Total: 21 649 lines, ~2 330 `<hash>` blocks.
- `cmd tool.attr prim.cube` alone appears 60 times — one tool with
  many variant forms (3D-mode / 2D-mode / UV / compact / full).

---

## 3. Mapping to vibe3d

| MODO                          | vibe3d today                                  |
|-------------------------------|-----------------------------------------------|
| `presets.cfg ToolPreset`      | `config/tool_presets.yaml` + `source/tool_presets.d` |
| Tool's `+FLAGS`               | Not modelled — pipeline defaults              |
| Tool's `'TASK'` slot          | `Stage.taskCode()` + `Pipeline.add` ordinal   |
| `props.cfg Sheet`             | `Tool.params()` schema + `drawProperties()`   |
| Filter Preset                 | (implicit — sheet is per-tool)                |
| `cmd tool.attr <id> <attr> ?` | `PropertyPanel` auto-renders `Param`          |
| `cmd tool.apply`              | (per-tool button, currently in `drawProperties`) |

We've mirrored MODO's **presets** layer faithfully. The **props**
layer is still code-driven via `Tool.params()` + `drawProperties()`.

### Strengths of vibe3d's current code-driven approach

- Layout lives next to the tool's logic — refactor-safe.
- Type-safe `Param` schema, compile-time errors on rename.
- Less boilerplate for the common case (auto-rendered widgets).

### When to migrate to a `config/tool_props.yaml`

Triggers (none hit yet):
- > ~30 tools — repetitive `drawProperties` becomes a maintenance tax.
- Multi-variant forms (vibe3d would want one tool's UI to change
  between Vertex / Edge / Polygon modes the way MODO does between
  3D / 2D / UV).
- Designer-editable layouts (non-coder rearranges widgets without
  a D compile cycle).

When we cross those triggers, the YAML schema looks like:

```yaml
sheets:
  - id: prim.cube
    label: Cube
    filter: { toolType: prim.cube }
    items:
      - { kind: section, label: Position }
      - { kind: attr,    tool: prim.cube, attr: cenX }
      - { kind: attr,    tool: prim.cube, attr: cenY }
      - { kind: attr,    tool: prim.cube, attr: cenZ }
      - { kind: divider }
      - { kind: section, label: Size }
      - { kind: attr,    tool: prim.cube, attr: sizeX }
      ...
      - { kind: button,  command: tool.apply, label: Apply }
```

with a loader matching `source/buttonset.d`'s pattern and a
renderer that walks the items, doing `Tool.params()` lookups by
attr name. Filter Presets in MODO map to a `filter:` block (predicate
tree the same way `Checked` blocks already work for popup items).

---

## 4. Related MODO files (for future reference)

| File                             | What it stores                                       |
|----------------------------------|------------------------------------------------------|
| `resrc/presets.cfg`              | ToolPresets (compound tool definitions)              |
| `resrc/props.cfg`                | Tool Properties Sheets (UI layout)                   |
| `resrc/cmdhelp.cfg` / `cmdhelpmod.cfg` | Command help text / argument schemas           |
| `resrc/cmdhelptools.cfg`         | Tool-specific command help                           |
| `resrc/_toolui.cfg`              | Tool UI message hooks (sparse — most lives in props) |
| `resrc/701_frm_modotools.cfg`    | The MODO Tools palette (the left-side toolbar tabs)  |
| `resrc/SymmetryPopover.cfg`      | Symmetry popover layout                              |
| `resrc/_snap.cfg`                | Snap popover layout                                  |
| `resrc/inmapdefault.cfg`         | Keyboard shortcut bindings                           |
| `resrc/ToolIcons.cfg`            | Icon registry for tool buttons                       |
| `resrc/macros.cfg`               | User-recordable macros                               |
| `LXSDK_661446/include/lxtool.h`  | `LXi_TASK_*` FOURCC constants, ILxTool vtable        |
| `LXSDK_661446/include/lxvmodel.h`| `LXfTMOD_*` tool-mode flag bits                      |
| `LXSDK_661446/include/lxpredest.h`| Preset destination / brush-preset machinery         |
