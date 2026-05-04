# Button grouping plan — group structure in status bar

## Goal

Extend `config/statusline.yaml` to use the same `groups` /
`buttons` shape that `config/buttons.yaml` already supports, so
buttons can be visually grouped via the existing `Group` struct.
Buttons inside one group sit edge-to-edge (today's behaviour);
adjacent groups get a small gap between them.

Trigger: a new `Work Plane ▾` popup button in the status bar must
not visually merge with the `Vertices` / `Edges` / `Polygons` trio
— they belong to two different concerns and need a visible gap.

## Current state

`config/statusline.yaml` is a flat button list:

```yaml
buttons:
  - { label: Vertices, action: ... }
  - { label: Edges,    action: ... }
  - { label: Polygons, action: ... }
```

`source/buttonset.d` exposes `loadStatusLine(path) → Button[]`. The
render loop in `app.d` puts every button on the same line via
`SameLine()`, no gap.

`config/buttons.yaml` (side panel) already has a richer shape:

```yaml
panels:
  - title: Tools
    items:
      - title: Transform
        buttons: [...]              # group of buttons
      - title: Create
        buttons: [...]
      - { label: ... }              # standalone button (no group)
```

`Panel.items[]` holds `PanelItem`s that are either a `Group` (with
`title` + `buttons[]`) or a single `Button`. The renderer in `app.d`
already gives free vertical breathing room between groups in the
side panel because each group emits a separator-line + new column.

## Schema design — reuse `groups`

Promote statusline.yaml to the same group-of-buttons shape:

```yaml
groups:
  - title: editmode             # grouping-only label (not rendered)
    buttons:
      - { label: Vertices, action: ... }
      - { label: Edges,    action: ... }
      - { label: Polygons, action: ... }
  - title: workplane
    buttons:
      - label: Work Plane
        action: { kind: popup, ... }
```

Rules:

- `title` is **mandatory** in YAML for the loader's identity (so
  errors can refer to a meaningful name) but **never rendered** in
  the status bar. It serves purely as a group key for grouping +
  diagnostics.
- Backward-compatibility: if `statusline.yaml` still has a
  flat top-level `buttons:` (today's shape), the loader treats it
  as a single anonymous group named `default`. Existing files keep
  working with no edits.
- Within a group, buttons render edge-to-edge (no gap).
- Between groups, the renderer inserts an 8-12 px horizontal gap.

This mirrors the side panel's `Panel.items` → `Group.buttons`
hierarchy exactly. No new schema concepts are introduced.

## Implementation

### Step 1 — extend `buttonset.d`

- Reuse the existing `Group` struct (already has `title` and
  `Button[] buttons`).
- Change `loadStatusLine`'s return type:

  ```d
  Group[] loadStatusLine(string path);
  ```

- Loader paths:
  - YAML has `groups:` → walk each, build a `Group` with `title` +
    `buttons[]` (parsed via existing `parseButton`).
  - YAML has flat `buttons:` (legacy) → wrap in a single
    `Group{ title: "default", buttons: [...] }` and return.
  - Neither key present → throw a loader error referring to the
    file path.

### Step 2 — render

`app.d`'s status-bar loop becomes nested:

```d
foreach (gi, ref grp; statusLineGroups) {
    if (gi > 0) {
        ImGui.SameLine();
        ImGui.Dummy(ImVec2(8, 0));     // inter-group gap
        ImGui.SameLine();
    }
    foreach (bi, ref btn; grp.buttons) {
        if (bi > 0) ImGui.SameLine();
        ImGui.PushID(format("%s/%d", grp.title, bi));
        scope(exit) ImGui.PopID();
        // ... existing per-button render ...
    }
}
```

The `gi > 0` gap is the only new visual element — single integer
gap-width constant, easy to tune.

`PushID` now uses the group title + button index instead of a flat
running index. This keeps ImGui widget IDs stable across renders
even when buttons are reordered within / across groups.

### Step 3 — `statusline.yaml` migration

Rewrite the file to the new shape:

```yaml
groups:
  - title: editmode
    buttons:
      - label: Vertices
        action: { kind: script, lines: ["select.typeFrom vertex"] }
        alt:
          label: "Convert V"
          action: { kind: script, lines: ["select.convert vertex"] }
      - label: Edges
        action: { kind: script, lines: ["select.typeFrom edge"] }
        alt:
          label: "Convert E"
          action: { kind: script, lines: ["select.convert edge"] }
      - label: Polygons
        action: { kind: script, lines: ["select.typeFrom polygon"] }
        alt:
          label: "Convert P"
          action: { kind: script, lines: ["select.convert polygon"] }
```

The legacy flat-`buttons:` form keeps working via the
backward-compatibility branch in step 1 — migration is opt-in.

### Step 4 — wire `Work Plane`

Once popup buttons (`popup_buttons_plan.md`) lands:

```yaml
groups:
  - title: editmode
    buttons:
      - { label: Vertices, ... }
      - { label: Edges,    ... }
      - { label: Polygons, ... }
  - title: workplane
    buttons:
      - label: Work Plane
        action:
          kind: popup
          items:
            - label: Auto
              action: { kind: command, id: workplane.reset }
              checked: { path: "workplane/auto", equals: "true" }
            - label: World Y
              action: { kind: script, lines: ["tool.pipe.attr workplane mode worldY"] }
              checked: { path: "workplane/mode", equals: "worldY" }
            - label: World X
              action: { kind: script, lines: ["tool.pipe.attr workplane mode worldX"] }
              checked: { path: "workplane/mode", equals: "worldX" }
            - label: World Z
              action: { kind: script, lines: ["tool.pipe.attr workplane mode worldZ"] }
              checked: { path: "workplane/mode", equals: "worldZ" }
            - { kind: divider }
            - label: Align To Selection
              action: { kind: command, id: workplane.alignToSelection }
            - label: Reset
              action: { kind: command, id: workplane.reset }
```

## Subphases

If both this plan and `popup_buttons_plan.md` are on the table:

1. **Group schema + render** (this plan, steps 1-3, ~150 LOC).
   Lands now — no popup dependency. Migrating today's flat list to
   a single `editmode` group is the smoke test.
2. **Popup buttons** (`popup_buttons_plan.md` §8.0-8.3, ~700 LOC).
3. **Status-bar Work Plane button** (this plan step 4, ~25 lines
   YAML). Depends on both above.

## Out of scope

- **Group title rendering in status bar.** `title` is grouping-key
  only; status bar is too short for visible labels.
- **Nested groups.** Single level of grouping is plenty.
- **Inline mini-headers.** The side panel already renders group
  titles when present; status bar deliberately doesn't.
- **Drag-to-reorder.** Static YAML.
- **Sub-grouping inside a side-panel `Group.buttons`.** Existing
  `Panel.items` already gives one level of grouping there; rare
  to need more.

## Open questions

1. **Mandatory vs optional `title`** — make it required for explicit
   key naming, or allow anonymous groups (`title:` omitted)?
   Recommend mandatory — even one-button groups should be named
   for diagnostics. Loader errors otherwise become `"unnamed group
   #2"` which is harder to debug.
2. **Default gap width between groups** — 8 px? 12 px? Single
   constant in code; tune after seeing it on the actual status
   bar.
3. **Visible divider line in the gap** — draw a 1 px vertical line
   in the inter-group space, or empty? Recommend empty first; add
   the line only if user feedback says the gap reads weak.

## Size estimate

Total ≈ 150 LOC + ~30 YAML lines.

| Step | LOC | Notes |
|---|---|---|
| 1 buttonset.d loader change | ~70 | parse `groups:` shape; backward-compat branch for flat `buttons:` |
| 2 app.d render | ~40 | nested loop, inter-group gap |
| 3 statusline.yaml migration | ~10 YAML | wrap existing buttons under `groups: [{ title: editmode, buttons: ... }]` |
| 4 Work Plane group + popup | ~25 YAML | depends on popup-buttons landing |
