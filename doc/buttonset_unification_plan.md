# Buttonset unification plan — Container as the single shape

## Goal

Replace the parallel `Panel` (multi-panel side bar) and flat
`Button[]` (status bar) types in `source/buttonset.d` with a single
`Container` shape used by both `config/buttons.yaml` and
`config/statusline.yaml`. The two loaders share one parser; the two
renderers in `app.d` stay independent (tabs / vertical-stack vs
horizontal-row), but they consume the same data.

This subsumes `doc/button_grouping_plan.md` — adding `groups:` to
the status bar drops out of this refactor for free, since the
shared `Container` always has groups.

## Today's types (recap)

```d
struct Group {
    string   title;
    Button[] buttons;
}

struct PanelItem {     // mix of Group or standalone Button
    bool   isGroup;
    Button button;
    Group  group;
}

struct Panel {
    string      title;
    PanelItem[] items;
}

Panel[]  loadButtons(path);      // panels.yaml
Button[] loadStatusLine(path);   // flat buttons.yaml
```

`PanelItem`'s "either Group or Button" union is unused in practice —
every entry in today's `buttons.yaml` is a Group with a title.
Standalone-Button-inside-Panel never appears.

## Target types

```d
struct Group {                   // unchanged
    string   title;
    Button[] buttons;
}

struct Container {               // replaces Panel + PanelItem
    string  title;               // visible OR grouping-only depending on renderer
    Group[] groups;
}

Container[] loadButtons(path);      // panels.yaml → Container[]
Container[] loadStatusLine(path);   // statusline.yaml → Container[] (typically size 1)
```

`Container` carries one optional `title` and zero-or-more `Group`s.
Whether `title` is rendered is a **renderer concern**, not a data
shape concern:

- Side-panel renderer in `app.d`: shows `Container.title` as a tab
  header (today's "Tools" / "Modify" / etc. tabs).
- Status-bar renderer: ignores `Container.title` entirely (status
  bar is too short for per-section headers).

`Group.title` similarly:
- Side panel: shows as a sub-section header above its buttons.
- Status bar: invisible — used only as a key for diagnostics + group
  identity in the parser.

## Schema

### `config/buttons.yaml` (multi-panel side bar)

Today:

```yaml
panels:
  - title: Tools
    items:
      - title: File
        buttons: [...]
      - title: Transform
        buttons: [...]
```

After:

```yaml
panels:
  - title: Tools                    # Container.title (rendered as tab)
    groups:                         # was `items`; standalone-Button drops
      - title: File                 # Group.title (rendered as header)
        buttons: [...]
      - title: Transform
        buttons: [...]
```

Two YAML diffs:
- `items:` → `groups:` (every entry is a group; the `Group | Button`
  union is dropped).
- Standalone `Button` entries inside `items:` are no longer
  supported — wrap each into a single-button Group with a sensible
  title.

`buttons.yaml` today has no standalone-Button-inside-items, so the
file mechanically migrates with a key rename only.

### `config/statusline.yaml` (status bar)

Today (flat):

```yaml
buttons:
  - { label: Vertices, ... }
  - { label: Edges,    ... }
  - { label: Polygons, ... }
```

After:

```yaml
panels:                              # same key as buttons.yaml — same parser
  - title: status                    # Container.title (status bar ignores it)
    groups:
      - title: editmode              # Group.title (status bar ignores it)
        buttons:
          - { label: Vertices, ... }
          - { label: Edges,    ... }
          - { label: Polygons, ... }
      - title: workplane             # next group → 8 px gap before
        buttons:
          - label: Work Plane
            action: { kind: popup, ... }
```

Both YAML files now share the EXACT same shape (`panels: → groups: →
buttons:`). The loader is one parser; the file's CONTENTS differ
(side bar names tabs, status bar uses anonymous-ish containers).

## Backward compatibility

For minimum migration friction:

- `buttons.yaml` accepts BOTH `items:` (legacy) and `groups:` (new).
  When `items:` is present, each entry must be a Group (the `Button`
  variant is rejected with a loader error referring to the file
  path + entry index — auto-migration is risky given there are no
  current uses but a non-zero number of forks may have one).
- `statusline.yaml` accepts BOTH the legacy flat top-level
  `buttons:` (today's shape, wrapped in a single anonymous
  Container) and the new `panels:` top-level. Existing
  statusline.yaml works without edits.

Loader picks the path by which key is present at root. Throw if
both or neither are present.

## Implementation steps

### Step 1 — types + parser refactor

`source/buttonset.d`:

- Drop `PanelItem`. Drop `Panel`. Add `Container`.
- New private helper `parseGroup(NodeT, ctx, path) → Group` (extract
  today's inline parser logic).
- New private helper `parseContainer(NodeT, ctx, path) → Container`
  that calls `parseGroup` per entry.
- `loadButtons(path) → Container[]` — recognises `panels:` (new) +
  `items:` inside each Container (legacy `items:` only when no
  `groups:` key).
- `loadStatusLine(path) → Container[]` — recognises `panels:` (new)
  OR legacy flat `buttons:` (wrapped into a single Container with
  `title: "default"`, single Group with `title: "default"`).

Module-level public API:

```d
struct Group     { string title; Button[] buttons; }
struct Container { string title; Group[]  groups;  }

Container[] loadButtons(string path);
Container[] loadStatusLine(string path);
Button[]    allButtons(ref Container c);   // helper for startup validation
```

### Step 2 — side-panel renderer

`app.d`'s side-panel render path uses `Container[]` instead of
`Panel[]`. Rename usages mechanically:

- `panels[].title` (was `Panel.title`) — used for tab headers.
- `panels[].groups[].title` — used for group sub-headers.
- `panels[].groups[].buttons[]` — render loop unchanged.

The today's mixed `PanelItem.isGroup` branch goes away — every
entry is a Group, so the inner loop simplifies.

### Step 3 — status-bar renderer

`app.d`'s status-bar render path consumes `Container[]`:

```d
foreach (ci, ref ctr; statusBar) {
    foreach (gi, ref grp; ctr.groups) {
        if (gi > 0) {
            ImGui.SameLine();
            ImGui.Dummy(ImVec2(8, 0));   // inter-group gap
            ImGui.SameLine();
        }
        foreach (bi, ref btn; grp.buttons) {
            if (bi > 0) ImGui.SameLine();
            ImGui.PushID(format("%s/%s/%d", ctr.title, grp.title, bi));
            scope(exit) ImGui.PopID();
            // ... existing per-button render ...
        }
    }
    if (ci + 1 < statusBar.length)
        ImGui.Dummy(ImVec2(16, 0));  // inter-container gap (rare)
}
```

`Container.title` is ignored — no header drawn. `Group.title`
is also ignored at render time but used as the PushID key.

### Step 4 — migrate `statusline.yaml`

Rewrite under the new `panels:` / `groups:` / `buttons:` shape:

```yaml
panels:
  - title: status
    groups:
      - title: editmode
        buttons:
          - { label: Vertices, ... }
          - { label: Edges,    ... }
          - { label: Polygons, ... }
```

Existing flat-`buttons:` form stays parsed via the legacy branch in
step 1, so the rewrite is opt-in. Once migrated, we get
`workplane` as a second group for free in step 5.

### Step 5 — wire `Work Plane` button

After `popup_buttons_plan.md` §8.0-8.3 lands (popup `kind:` in
buttons), append a second group to the status-bar Container:

```yaml
panels:
  - title: status
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
                - { kind: divider }
                # ... etc ...
```

Inter-group gap renders automatically — no separator markers
needed.

### Step 6 — drop legacy

Once both files are migrated and confirmed working in the GUI, the
loader's legacy branches can be removed. Optional cleanup; the
backward-compat code is small (~30 LOC) and harmless to keep.

## Tests

- `tests/test_buttonset.d` (NEW) — unit-tests the loader against
  small in-memory YAML fixtures: legacy shape, new shape,
  malformed input. Bypasses HTTP since this is pure parsing.
- Existing GUI smoke (43+ unit / 74 modo_diff / 30 blender_diff)
  must stay green at every step.
- Visual verification in the running GUI: tabs render correctly,
  groups have the right gaps, status bar has the new
  edit-mode-vs-workplane spacing.

## Out of scope

- **Single-file UI config** (option C from the discussion). Keep
  `buttons.yaml` and `statusline.yaml` as separate files for
  isolation; they merely SHARE a parser.
- **New container types** (right panel, floating palette). Adding
  them just means another `loadXxx → Container[]` call site and a
  new render path; the data shape doesn't grow.
- **Title rendering preferences in YAML.** Whether to show
  `Container.title` is a renderer choice baked into each call site,
  not a YAML field. Keeps schema minimal.
- **Standalone-button-inside-Container** (i.e. dropping the Group
  wrapper for single buttons). Forces a Group everywhere; tiny
  YAML cost (one wrapper line per single-button group) for
  schema simplicity.

## Open questions

1. **Legacy shape support indefinitely or sunset date?** Keeping
   the legacy `items:` (buttons.yaml) and flat `buttons:`
   (statusline.yaml) branches forever costs ~30 LOC. Removing them
   eventually keeps the loader lean. Recommend: keep both for one
   release after migration, then drop.
2. **Inter-container gap width** (between adjacent Containers in
   status bar). Default to 16 px (twice the inter-group gap)? Single
   constant in code; tune later. Note: status bar will typically
   have just ONE Container, so this is a corner case.
3. **`allButtons` helper signature** — today returns `Button[]`
   from a `Panel`. Keep that, or generalise to take a `Container`?
   Recommend: rewrite to take `Container` since `Panel` goes away.
4. **Naming `Container`**: alternatives are `Section`, `Page`,
   `Panel` (kept). Recommend `Container` for symmetry with
   "container of groups" phrasing in the discussion; `Panel` stays
   in the YAML key (`panels:`) for user-facing familiarity.

## Subphases

Each step is one commit; build + test gate at every step.

1. **buttonset.d types + parser** (~150 LOC)
2. **app.d side-panel renderer migration** (~80 LOC)
3. **app.d status-bar renderer migration** (~60 LOC)
4. **`statusline.yaml` migration** (~10 YAML)
5. **(deferred) `Work Plane` button** — after popup_buttons_plan
   8.0-8.3.
6. **(deferred) drop legacy branches** — after both files migrated
   and stable.

Total ≈ 300 LOC + ~10 YAML for steps 1-4. Step 5 depends on the
popup-buttons subphases; step 6 is optional cleanup.
