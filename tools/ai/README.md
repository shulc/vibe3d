# AI ranker training data tools

These offline runners turn interaction-log records into trainer-input JSONL for
the ranker trainer. Two sources feed the same exporter
(`exportAiTrainingDatasetJsonl`):

- **Synthetic corpus** — a small deterministic set, for smoke tests:

  ```sh
  rdmd -I=source tools/ai/dump_training_dataset.d > /tmp/train.jsonl
  ```

- **Real captured sessions** — labeled records from live editor use (below):

  ```sh
  rdmd -I=source tools/ai/capture_to_training_dataset.d /tmp/capture.jsonl \
      > /tmp/train.jsonl
  ```

  Reads a path argument or stdin; blank and `//`-comment lines are skipped.
  Stats (`total` / `labeled` / `unlabeled`) print to stderr; stdout is clean
  JSONL.

## Opt-in live interaction-log capture

Capture is **OFF by default**. Enable it by pointing it at a writable file:

```sh
VIBE3D_AI_LOG=/tmp/capture.jsonl ./vibe3d      # env var (primary)
./vibe3d --ai-log /tmp/capture.jsonl           # CLI flag (alias; CLI wins)
```

When neither is set, nothing is recorded and the sink is fully inert (no file
is opened, no per-frame work). With a path set, the editor appends one JSON
record per line at each genuine **apply** point:

- an **element select-pick** (`groupId: "elements"`) — which of the
  vertex/edge/face under the cursor was selected; and
- a **handle click-apply** (`groupId: "handles"`) — which overlapping handle was
  grabbed.

Capture fires exactly once per apply (never per hover or per drag-motion frame).
Each record's `appliedWinner` is the candidate the user actually applied — the
training label. The `source` field is tagged `live-session:<pid>` so corpora
from different sessions stay distinguishable.

Capture is independent of the in-editor AI master switch: with the advisor off,
the applied winner is simply the default winner — i.e. the element/handle the
user picked — which is exactly the label we want.

## Line format

Each line is one `AiInteractionLogRecord` JSON object (the same serialization
used everywhere in the AI subsystem): a schema version, an interaction context
(mouse position, modifier keys, active-tool id, edit-mode id), the candidate
set, the default/applied winners, and an optional outcome. Feed a captured file
straight into the runner above to expand it into trainer features.

## Privacy

Captured records contain only interaction features and synthetic candidate ids
(e.g. `element:vertex:3`, `handle:10`, mouse coordinates, modifier-key flags,
tool/edit-mode ids). No file paths, document or scene names, or user identities
are written.

## Live inference (opt-in, off by default)

The captured corpus trains a candidate ranker; once exported to `ranker.onnx`,
the editor can consult it live to influence which handle is picked. This is
**off by default** and enabled explicitly with a model path:

```
VIBE3D_AI_MODEL=/path/to/ranker.onnx ./vibe3d
./vibe3d --ai-model /path/to/ranker.onnx          # CLI wins over the env var
```

When unset, behavior is exactly as before — the deterministic advisor only. When
set, the model becomes the handle decision source, but every prediction still
passes the same phase / captured / hover gates as the manual path (the model
never bypasses them). If the prediction is low-confidence, rejected, or the model
fails to load (or the runtime is absent), the path falls through to the existing
deterministic advisor — identical to the unset case, never a crash.
