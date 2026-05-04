# Popup buttons plan — dropdown menus with checkmark items

## Goal

Add a third button-kind to `config/buttons.yaml` (alongside the
existing `tool` / `command` / `script` actions) that, when clicked,
opens a popup with a vertical list of item-rows. Each row is itself a
mini-button — running a command / activating a tool / executing a
script — with an optional checkmark on the left that indicates the
"current state" of whatever the item represents (active workplane
mode, current edit-mode, active falloff type, etc.).

This unblocks compact UI for stage-based subsystems coming in Phase 7
(Workplane mode picker, Action Center picker, Falloff type picker)
and matches MODO's dropdown-button conventions described in
`tool_pipe.html` (the Tool Pipe viewport's row-with-checkbox layout)
and `workplane.html` (the Work Plane menu bar dropdown).

## Motivation / use cases

| Use case | Today | With popup buttons |
|---|---|---|
| Switch Workplane mode | 4 separate buttons (Auto, World X/Y/Z) eating panel space | 1 "Workplane ▾" button → popup with 4 rows + ✓ on the active mode |
| Switch edit mode | Keys 1/2/3 only — no UI | "Verts ▾" button + popup with 3 rows |
| Action Center picker (Phase 7.2) | TBD | "ACEN ▾" button + popup |
| Falloff picker (Phase 7.5) | TBD | "Falloff ▾" button + popup |
| Snap-types toggle (Phase 7.3) | TBD | "Snap ▾" button + popup with multi-checkable rows |
| Selection mode in modeling layouts | (no analog yet) | Future use |
| Status-bar stage swappers (`phase7_plan.md` §7.9) | TBD | Direct fit |

Each is a small, finite list that's currently UI-impaired without a
dropdown. Adding popups makes the existing toolbar architecture
extensible without growing horizontally.

## YAML schema design

### Existing button shape (recap)

```yaml
- label: Box
  action: { kind: tool, id: prim.cube }
  ctrl:                     # optional modifier override
    label: "Unit Box"
    action: { kind: script, lines: ["..."] }
```

### New shape — `kind: popup`

The button itself looks identical (label + optional shortcut). The
`action` block uses the new `popup` kind with an `items` list
instead of an `id` / `lines` payload.

```yaml
- label: Workplane
  action:
    kind: popup
    items:
      - label: Auto
        action: { kind: command, id: workplane.reset }
        checked: { kind: state, expr: "workplane.auto == 'true'" }

      - label: World Y
        action:
          kind: script
          lines: ["tool.pipe.attr workplane mode worldY"]
        checked: { kind: state, expr: "workplane.mode == 'worldY'" }

      - label: World X
        action:
          kind: script
          lines: ["tool.pipe.attr workplane mode worldX"]
        checked: { kind: state, expr: "workplane.mode == 'worldX'" }

      - label: World Z
        action:
          kind: script
          lines: ["tool.pipe.attr workplane mode worldZ"]
        checked: { kind: state, expr: "workplane.mode == 'worldZ'" }

      - { kind: divider }                   # horizontal rule

      - label: Align To Selection
        action: { kind: command, id: workplane.alignToSelection }
        # No `checked` — pure-action item, no indicator.

      - label: Reset
        action: { kind: command, id: workplane.reset }
```

### Item types in `items[]`

| Item kind | Fields | Render |
|---|---|---|
| `action` (default; inferred when `label` is set) | `label`, `action`, optional `checked` | Row with optional ✓ indicator + label |
| `divider` (when only `kind: divider`) | none | Horizontal separator line |
| `header` | `label` only | Bold label, non-clickable group title |

Headers and dividers are non-interactive — they organise the popup
when item count grows past ~6.

### `action` inside an item

Reuses the existing top-level `Action` schema verbatim — `tool` /
`command` / `script`. So a popup item can do anything a top-level
button can do; nothing is lost by burying actions inside a popup.

### `checked` block (state query)

The hard part. Three options:

#### Option A — explicit per-item state expression

```yaml
checked: { kind: state, expr: "workplane.mode == 'worldY'" }
```

Pros: declarative, lives in YAML.
Cons: needs an expression evaluator (parser + state lookup). Not zero
cost.

#### Option B — predicate id

```yaml
checked: { kind: predicate, id: "workplane.mode.worldY" }
```

Pros: no parser; just a lookup in a registry of known predicate
delegates.
Cons: every distinct check needs a predicate registered in D code;
YAML can't introduce new ones.

#### Option C — query path + value

```yaml
checked: { path: "workplane/mode", equals: "worldY" }
```

Pros: zero parsing — just a string-keyed `state[path]` lookup, with
`equals` literal compare. Easy to extend (each subsystem registers its
state into the lookup map).
Cons: limited to equality comparisons. No `&&` / `||`. Adequate for
the use cases listed above; richer logic stays out of YAML.

**Recommendation: option C.** Simplest implementation, fits every
listed use case. Can grow to expression-based later (option A) if
needed.

State paths grow naturally:
- `workplane/mode` → "auto" / "worldX" / "worldY" / "worldZ" / "custom"
- `workplane/auto` → "true" / "false"
- `editMode` → "vertices" / "edges" / "polygons"
- `activeTool` → "" / "move" / "prim.cube" / …
- `actionCenter/mode` → "selection" / "origin" / "element" / "local" (Phase 7.2)
- `falloff/type` → "none" / "linear" / "radial" / … (Phase 7.5)
- `snap/types` → comma-separated list, e.g. "vertex,edge" (Phase 7.3)

### Multi-checkable variant (for Snap-types)

Snap allows multiple types simultaneously (Vertex AND Edge). For
that:

```yaml
checked: { path: "snap/types", contains: "vertex" }
```

`contains` is a substring / list-element match. Two items can both
report `checked=true` and the popup shows two ✓s — natural for
multi-toggle UX.

## ImGui rendering

ImGui has `BeginPopup` / `EndPopup` with `MenuItem` rows. Maps almost
1:1 to our schema:

```d
if (renderStyledButton("Workplane ▾", "", false, false, size)) {
    ImGui.OpenPopup("workplane_popup");
}
if (ImGui.BeginPopup("workplane_popup")) {
    foreach (item; popup.items) {
        final switch (item.kind) {
            case ItemKind.action:
                bool isChecked = evalChecked(item.checked);
                if (ImGui.MenuItem(item.label, /*shortcut*/ null, isChecked))
                    runItemAction(item.action);
                break;
            case ItemKind.divider:
                ImGui.Separator();
                break;
            case ItemKind.header:
                ImGui.TextDisabled(item.label);
                break;
        }
    }
    ImGui.EndPopup();
}
```

`MenuItem` with the `selected` parameter draws the ✓ on the left
automatically — no custom drawing needed. The popup positions
itself below the parent button by default; the user can dismiss it
by clicking outside or pressing Esc.

### Popup label formatting

The button's label gets a "▾" suffix to signal it opens a popup:

```yaml
- label: Workplane          # YAML stays clean
  action: { kind: popup, ... }
```

```
[ Workplane ▾ ]   # rendered with auto-suffix
```

The suffix is added by `renderButton` when `action.kind ==
popup`. Or YAML can override it by writing `label: "Workplane"` and
appending the glyph manually — but the default-add keeps YAML lean.

### Optional: button-label shows current value

Cool variant: the popup-button's label reflects the active item.
"Workplane: WorldY ▾" instead of "Workplane ▾". Implementation:

```yaml
- label: { template: "Workplane: {workplane/mode} ▾" }
  action: { kind: popup, ... }
```

The label is a template string with `{path}` placeholders resolved
from the same state map. Defer this to a follow-up — first commit
ships fixed labels.

## Subphases

### 8.0 — Schema parsing + ItemKind

- Extend `source/buttonset.d`:
  - New `ActionKind.popup` value.
  - `Action.popupItems` field (struct holding a `PopupItem[]`).
  - `PopupItem` struct: `kind` (action / divider / header), `label`,
    `Action action` for action kind, `Checked checked` (path +
    equals/contains).
  - Loader recognises `kind: popup`, walks `items` list.
- `tests/test_buttons_popup.d`: load a sample `buttons.yaml` with a
  popup, assert struct shape.

Size: ~250 LOC.

### 8.1 — Render path + ImGui popup

- `app.d`'s `renderButton` branches on `ActionKind.popup`:
  - Renders the styled button as today; on click, opens the popup.
  - `ImGui.BeginPopup` + per-item `MenuItem` / `Separator` /
    `TextDisabled`.
  - Action item click → reuses the same dispatch path as top-level
    buttons (`activateToolById` / `runCommand` / scripted line
    execution).
- No state queries yet — all `checked` values render as `false` in
  this commit.

Size: ~200 LOC.

### 8.2 — State registry + checked evaluation

- `source/state_registry.d` (new): a global string→string map.
  Subsystems write into it after every relevant change:
  - editmode → `state["editMode"] = "polygons"`.
  - activeToolId → `state["activeTool"] = "prim.cube"`.
  - WorkplaneStage → `state["workplane/mode"] = "worldY"` etc.
- `evalChecked(Checked c)` looks up `state[c.path]` and runs the
  comparison operator (`equals` / `contains`).
- Popup re-evaluates on every render frame (cheap — popup is rarely
  open simultaneously with heavy redraws).
- Subsystems hook into the registry where they already mutate their
  state (no new "observer" plumbing required).

Size: ~200 LOC.

### 8.3 — Real popups in `buttons.yaml`

- Add a `Workplane ▾` popup button to the Create panel (or a new
  Mode panel).
- Add an `Edit Mode ▾` popup (Vertices / Edges / Polygons) wired to
  the existing key-1/2/3 actions.
- Manual smoke test in the GUI; existing tests stay green.

Size: ~50 LOC (mostly YAML).

### 8.4 — (Optional) Templated labels

Defer until 8.0-8.3 land. Adds the `{path}` template syntax to button
labels.

## Out of scope

- **Submenus** (popup item that opens another popup). Possible later;
  no immediate use case — every targeted use is a flat list.
- **Mouse-hover-to-open** (vs click-to-open). Click is enough; hover
  open requires extra state machine and timing UX.
- **Right-click context menus on items**. Not needed for the listed
  use cases; defer.
- **Keyboard-driven popup navigation** (arrow keys + Enter). ImGui's
  built-in `MenuItem` handles this automatically when the popup has
  focus.
- **Custom item icons**. Pure text rows for now; icons can come if/
  when we add icons to top-level buttons too.
- **Dynamic items** generated from runtime data (e.g. "list every
  registered tool here"). Not needed for the listed cases; would
  require a callback type in the YAML schema.

## Open questions

1. **Popup auto-close on action click** — every MenuItem dismisses
   the popup by default. Sometimes the user wants to toggle several
   things in one open (multi-snap). Add a `dismissOnClick: false`
   per-item flag? Defer until first use case forces it.
2. **State path naming convention** — `/`-separated (`workplane/mode`)
   or `.`-separated (`workplane.mode`)? Dot collides with command
   namespacing in argstrings; slash is unambiguous. Pick slash.
3. **Popup positioning** — default ImGui places the popup below the
   button. For status-bar buttons (Phase 7.9), we'd want above.
   Add a `direction: above|below` field on the popup later if
   needed.
4. **State registry concurrency** — vibe3d is single-threaded for
   most modeling state, but the HTTP server runs on its own thread.
   The state map should be `__gshared` with a mutex around writes,
   or restricted to main-thread writes only (HTTP commands route
   their effects through `tickCommand` on main thread anyway).
   Pick: writes only on main thread → no mutex needed.
5. **Persistence** — should the popup-button state survive across
   sessions (e.g. last-used Workplane mode)? MODO's Tool Cache says
   yes for tools. Defer; main-line vibe3d has no such persistence
   yet.

## Success metrics

- 4 subphases (8.0–8.3) land as separate commits.
- A real `Workplane ▾` button appears in `buttons.yaml`, shows the
  4 modes + reset/align entries, the active mode shows a ✓.
- An `Edit Mode ▾` popup replaces the current-no-button situation
  for selecting Vertices / Edges / Polygons in the toolbar.
- Existing tests stay green (no regression on top-level buttons).
- `tests/test_buttons_popup.d` exercises both the YAML parser and
  the state-registry checked evaluation.

## Size estimate

Total ≈ 700 LOC across 4 commits — small to medium feature.

| Subphase | LOC | Notes |
|---|---|---|
| 8.0 Schema parsing | ~250 | dyaml extension, struct definitions, loader test |
| 8.1 Render path | ~200 | ImGui popup + dispatch reuse |
| 8.2 State registry + checked | ~200 | new global map + Workplane / EditMode / Tool hookups |
| 8.3 buttons.yaml entries | ~50  | mostly YAML; tiny D delta |
| 8.4 Templated labels (deferred) | ~100 | follow-up |
