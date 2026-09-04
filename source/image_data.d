module image_data;

/// An image item's payload (task 0616). A CLASS reference — unlike `Mesh`
/// (a value struct `MeshSnapshot` moves) — so that a `Layer` can be REPOINTED
/// at another payload through `Layer.imageRef()` without the field itself
/// having to move, and so the pixel-cache handle a later stage parks here has
/// one identity to hang off.
///
/// EVERY ITEM OWNS ITS OWN `ImageData`. An earlier revision of this comment
/// said the opposite — that `LayerDuplicate` points a clone at the exact same
/// object — and that is not what the code does, nor what it may do:
/// `commands/layer/commands.d` deep-copies all seven fields into a fresh
/// `ImageData`, and `io/native.d`'s round-trip test asserts two same-path
/// clips come back as two DISTINCT payloads. The aliasing version shipped
/// briefly under the heading "one decode, N consumers" and was a real defect:
/// `image.replace` on the clone re-pointed BOTH rows, because they were one
/// object. Sharing belongs one level down (the plan's cache is keyed by PATH,
/// so two items naturally meet at one cache entry) and one level up
/// (`ItemLink` is how many consumers reference one clip). Not here.
///
/// `Layer.parent` is the existing precedent for a shared class reference on
/// `Layer`, and the cautionary one: it has no refcount, which is the
/// un-refcounted-alias shape the pixel cache must not repeat.
///
/// Stage 2 shipped only the one field that already had a consumer:
/// `storedPath`, so a duplicated image row had something non-default to
/// compare against its source. Stage 3 adds the two remaining v1 channels the
/// item's provider bundle exposes — `colorspace` and `useAlpha`
/// (`layer_params.d`'s `kindParams`, §Q2 of the plan). Both are AUTHORED
/// fields, never computed — the distinction that keeps them out of the
/// "derived value in a writable channel" trap a `format` channel would have
/// been. Stage 4 added the DERIVED `width` / `height` / `channels` /
/// `missing`, recomputed from the file by `io/image_path.d`'s
/// `refreshImageMeta` and never authored, so none of them is a provider param.
/// There is no `resolvedPath` field and no `format` field: the resolved
/// absolute path is computed on demand (`resolveStoredPath`) rather than
/// cached beside a `storedPath` it could contradict, and the pixel format the
/// panel shows is derived from `channels` at display time
/// (`ui/image_rows.d`'s `pixelFormatText`). Stage 5 adds the pixel-cache
/// handle. Bend #4 (the plan) notes the limit this shape has, in advance: a
/// faithful one-slot-per-kind payload for kind #2 and #3, a tagged union by
/// kind #6 — not paid for now.
///
/// A hazard for Stage 5 specifically, flagged here in advance because this
/// is the class the pixel-cache handle lands on: `io.image_decode
/// .DecodedImage` (task 0616's decoder, `bbfe3a48`) is manual-release, not
/// automatic — copying is `@disable`d and `free()` returns its C-heap buffer
/// to the decoder's allocator, but there is no `~this()`. Parking one
/// directly inside this GC-managed class and expecting GC finalisation to
/// call `free()` for you will leak the C-heap buffer (a GC collection does
/// not run struct destructors it never had, and even if it did, D class
/// finalization order at collection time is not something to lean on for a
/// non-GC resource). Stage 5's refcount must land BEFORE the first
/// `.free()` call site exists — the same ordering the `Layer.parent`
/// cautionary note above makes for the alias itself: ship the count, then
/// the thing that needs it, not the other way around.
final class ImageData {
    string storedPath;             ///< the authored path, as it will be
                                    ///< serialised (Stage 4 owns the store-
                                    ///< relative / resolve-absolute rules;
                                    ///< this stage only holds the field)
    // Task 0616 Stage 3 — the two inert v1 channels (plan §Q2). Measured
    // defaults: `colorspace` `'(default)'`, `useAlpha` `1`. `colorspace` is
    // narrowed to a closed three-tag ENUM rather than the measured open
    // `string` (plan divergence 4) — the only reversal cost, if the tag set
    // ever needs to be open-ended, is one `Param.enum_` → `Param.string_`
    // swap in `layer_params.d`; this field's TYPE stays `string` either way.
    string colorspace = "(default)"; ///< closed tag set: see kindParams' Enum
                                      ///< declaration in layer_params.d
    bool   useAlpha   = true;        ///< inert; round-tripped, nothing reads it

    // -----------------------------------------------------------------------
    // Task 0616 Ph5 — the DERIVED half. Recomputed from the file by
    // `io.image_path.refreshImageMeta`; never authored, never a `Param`,
    // never serialised. The split is the point: the three fields above are
    // what the document SAYS, these four are what the disk ANSWERED, and the
    // answer is allowed to change under the document without the document
    // changing (that is exactly what `image.reload` exists to observe).
    //
    // Persisting any of these would create the second source of truth the
    // plan's §Q2 forbids: it goes stale the moment the file changes on disk,
    // and — worse — a stale `width` cannot be told apart from a fresh one, so
    // a reader would report a confident wrong number for a file it never
    // opened.
    // -----------------------------------------------------------------------
    int  width;      ///< pixels; 0 while `missing`
    int  height;     ///< pixels; 0 while `missing`
    int  channels;   ///< channel count present in the SOURCE file (1/2/3/4);
                      ///< 0 while `missing`. The list's "format" column is a
                      ///< rendering of this, not the file extension.
    bool missing = true; ///< true until a read of `storedPath` has SUCCEEDED.
                          ///< Defaults true rather than false because a payload
                          ///< that was never refreshed has not resolved
                          ///< anything — "unresolved" is the honest initial
                          ///< answer, and claiming `missing == false` for a
                          ///< path nobody has opened is the one wrong answer
                          ///< a consumer cannot detect.

    // Task 0635 added a MEMOISED half here — a rendering of the two halves
    // above, held so a draw path did not rebuild it once per row per frame.
    // Task 0771 moved it off this object entirely: it was a UI cache with no
    // business on the document's own payload class, and unlike the derived
    // fields above it carries no information of the document's — a
    // `RowTextMemo[ImageData]` side table, keyed on this object's identity
    // and pruned by the panel's own draw pass, now lives in
    // `ui/image_rows.d`, the cache's only reader. See that module for the
    // struct, the table, and the lifetime rule that replaces the field.
}


/// A reference-image plane's payload (task 0612). A class reference, for the
/// same two reasons `ImageData` is one: a `Layer` can be repointed at another
/// payload without the field moving, and the object has one identity to hang
/// things off.
///
/// EVERY FIELD IS AN AUTHORED CHANNEL. There is deliberately nothing derived
/// here and no path of its own:
///
///   * the image's PIXEL DIMENSIONS live on the linked clip's `ImageData`,
///     where the disk answered them;
///   * the resolved absolute PATH is computed on demand from that clip;
///   * the TEXTURE lives in the path-keyed pixel cache (`image_cache.d`).
///
/// So there is no second source of truth to keep in sync, and none of the
/// staleness `ImageData`'s own comment argues against. The plane's placement
/// is a pure FUNCTION of these channels plus the item transform plus the
/// clip's dimensions; nothing about it is stored.
final class ImagePlaneData {
    // ---- what the plane faces -------------------------------------------
    /// Which axis-aligned view this plane is a reference FOR. A closed token
    /// set rather than an int, for the reason `ItemKind`'s own comment gives:
    /// the token is what `.v3d` carries, so a later value appended to the set
    /// cannot reshuffle a stored file. The declaration that pins the set is
    /// the `Param.enum_` in `layer_params.d`.
    ///
    /// No "camera" value: we have no camera item to project from.
    string projection = "front";
    /// Whether the plane is also drawn in a free-orbit (perspective) cell.
    /// The measured channel is the NEGATIVE `hide in perspective`, default
    /// "shown"; the positive spelling is the reference's own UI label and is
    /// what this field carries, so the default reads `true` rather than
    /// `false` meaning the same thing.
    bool showInPerspective = true;

    // ---- how big it is ---------------------------------------------------
    /// World metres per image pixel — the channel that makes "a 1 m backdrop
    /// makes a 1 m character" expressible at all, and the one the whole task
    /// is for. A LIVE property, not an import-time constant: writing it after
    /// the clip is linked resizes the plane (measured, 2026-08-09).
    ///
    /// Bounded at its `Param` declaration (`layer_params.d`) with an enforced
    /// floor, so a zero or a NaN cannot reach the extent formula and produce
    /// a degenerate or non-finite quad. It is not count-like — nothing
    /// allocates or loops on it — so it owes no kernel `MAX_` cap.
    float pixelSize = 0.01f;
    /// Whether the image's proportion is locked. It selects between two
    /// extent LAWS (measured): on, the base is `(W*p, H*p)` scaled by the
    /// single factor `min(sx, sy)`; off, the base is the image's HEIGHT on
    /// both axes and the scale applies per-axis. It is NOT a constraint on
    /// the scale gesture — that reading was measured false — which is why it
    /// lives here, on the item, and not in the transform tool.
    bool keepAspect = true;

    // ---- what it looks like ---------------------------------------------
    // Three signed/unsigned fractions rather than the measured "percent"
    // type: a fraction is what the shader multiplies by, and carrying 0..100
    // here would put a unit conversion between the channel and its only
    // consumer. Each is bounded with `enforceBounds` at its declaration.
    float brightness   = 0.0f;   ///< -1 .. +1; 0 = unchanged
    float contrast     = 0.0f;   ///< -1 .. +1; 0 = unchanged
    float transparency = 0.0f;   ///<  0 .. 1;  0 = opaque, 1 = invisible
    bool  invert       = false;  ///< invert RGB (a pencil drawing on white)
    bool  flipHorizontal = false;///< mirror across the plane's vertical axis
    bool  smooth       = false;  ///< filter neighbouring pixels (low-res scans)
}
