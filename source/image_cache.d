module image_cache;

// ---------------------------------------------------------------------------
// Task 0612 Stage 1 — the path-keyed pixel + GL-texture cache.
//
// This module is the FIRST and ONLY place in the build that will ever call
// `io.image_decode.imageDecode`, and therefore the only place that calls
// `DecodedImage.free()`. That ordering is the whole reason it lands as its
// own stage, ahead of the item kind that needs it:
//
//   * `DecodedImage` is manual-release. It has an explicit `free()` and
//     deliberately NO destructor, so a GC finalizer will never return its
//     C-heap buffer (`io/image_decode.d`, and `document.d`'s `ImageData`
//     comment says the same thing from the other end). "Just free when
//     you're done" has to be somebody's job, once, in one place.
//   * Two DIFFERENT items may name one file. `document.d` states that every
//     image item owns its own `ImageData` and that sharing "belongs in the
//     path-keyed pixel cache one level down". This is that level: two clips
//     on one path meet at ONE entry, and duplicating an item does not
//     duplicate a texture.
//   * Four separate sites replace the whole `Document` (scene reset, the
//     `.v3d` reader, the interchange import, and a layer delete's splice).
//     None of them releases any per-layer GPU resource, and none of them
//     needs to: residency here is RECONCILED against a caller-supplied set
//     of live paths, so a document that was replaced wholesale simply yields
//     a different set on the next call.
//
// WHAT THIS MODULE DOES NOT KNOW. It has never heard of `Document`, `Layer`,
// item kinds or links — it is handed an array of strings. That is what lets
// this stage ship and be fully tested BEFORE the item kind exists, and it
// keeps the question "what is live" in the module that understands planes
// (task 0612 Stage 4's `collectLivePlanePaths`). The only imports here are
// the decoder and, in a `version (unittest)` build, its BMP fixture helper.
//
// WHY RECONCILED AGAINST A SET AND NOT AGAINST THE FRAME. An earlier design
// for this cache was frame-scoped (`beginFrame` / `require` / `endFrame`,
// with `require` called from the draw). Against this tree that is a bug, not
// a style choice: the per-cell draw runs only for a DIRTY cell, so a clean
// frame issues no `require`, an unconditional `endFrame` then frees the
// texture, and the next camera movement decodes it from disk again — a full
// stb decode plus `glTexImage2D` PER FRAME during an orbit. The precedent
// this cache actually follows is `ui/panels.d`'s background-GPU eviction
// loop, which asks a pure DOCUMENT question ("is this layer still a visible
// non-primary member?") and is therefore safe to run lazily and late.
// `reconcile` asks the same shape of question. `lookup` — the only call the
// draw makes — cannot decode, cannot allocate and cannot change residency,
// which is what structurally prevents a dirty-cell skip from ever deciding
// what is resident.
//
// THREADING. Main thread only. The instance below is a module-level global
// and therefore THREAD-LOCAL (D's default for mutable module state), which is
// deliberate: a wrong-thread reader gets its own empty cache rather than a
// data race on GL ids, and every real consumer — the frame loop, the
// viewport teardown, and the bridged `/api/images` handler — already runs on
// the main thread. Nothing here takes a lock, and nothing here may be called
// from the HTTP thread directly.
// ---------------------------------------------------------------------------

import io.image_decode : DecodedImage, ImageInfo, imageDecode, imageInfo,
                          MAX_IMAGE_BYTES;
import log : logWarn;

/// Upper bound on TOTAL resident GL bytes.
///
/// A policy knob, not a safety one — the safety bounds on any single image
/// are two layers up in `io/image_decode.d` (`MAX_IMAGE_DIM`, the decoded
/// byte budget) and are not re-derived or re-tested here. What this bound is
/// for is the one cost that follows from residency tracking LINKS rather than
/// DRAWS: a plane whose viewport cell is not currently on screen still holds
/// its texture. That is the right trade (hiding or looking away must not
/// re-read the disk), and this is its ceiling.
enum size_t CACHE_BUDGET_BYTES = 256UL * 1024 * 1024;

/// How much of a file is read to answer "how big is this image" before
/// committing to a decode. Mirrors `io/image_path.d`'s window and exists for
/// the same reason: the admission decision below needs the header, and
/// reading a whole photograph to learn its width would defeat the point.
/// Deliberately NOT imported from that module — this one must not acquire a
/// dependency on `document.d`, which `io/image_path.d` imports.
private enum size_t HEADER_WINDOW = 256 * 1024;

/// The refcount-free, path-keyed residency cache.
///
/// "Refcount-free" is not a shortcut: the count a reference-counted design
/// would maintain is exactly "how many live links name this path", and the
/// caller already computes that set every frame. Deriving residency from the
/// set is one authority instead of two, and it cannot drift — a missed
/// decrement is unrepresentable.
///
/// Non-copyable. It owns GL names and (transiently) a C-heap pixel buffer; a
/// bitwise copy would hand two owners one texture.
struct ImagePixelCache {
    private struct Entry {
        string path;      ///< resolved absolute path — the key
        uint   tex;       ///< GL texture name; 0 when `!loaded`
        size_t bytes;     ///< resident GL bytes (w*h*4); 0 when `!loaded`.
                           ///< The DIMENSIONS are deliberately not kept: see
                           ///< the note under `lookup`. Only their product
                           ///< reaches this struct, and only the budget reads
                           ///< it.
        ulong  liveTick;  ///< the `reconcile` generation this was last live in
        bool   loaded;    ///< false for a FAILURE MEMO (see `reconcile`)
    }

    // A plain array, scanned linearly, not an associative array. The set is
    // tiny (one entry per distinct file named by a live link) and the array
    // gives a deterministic order, which an AA's hash order would not — the
    // same reasoning `Layer.links_` records for its sorted slot array.
    private Entry[] entries_;
    private ulong   tick_;      ///< reconcile generation counter
    private ulong   decodes_;   ///< successful decodes since construction
    private size_t  bytes_;     ///< sum of `loaded` entries' `bytes`

    /// The residency ceiling for THIS cache. A field rather than only the
    /// module constant so a test can set a budget it can actually reach
    /// without writing a 256 MiB fixture.
    size_t budgetBytes = CACHE_BUDGET_BYTES;

    @disable this(this);

    version (unittest) {
        // No GL in a `dub test` build, so a synthetic, monotonically
        // increasing name stands in for `glGenTextures`. It exists so
        // `lookup` can still answer "resident" vs "not" — the distinction the
        // tests are about — and it is never handed to GL, because in this
        // build there is no GL to hand it to.
        private uint nextFakeTex_ = 1;
    }

    // -----------------------------------------------------------------------
    // The two verbs
    // -----------------------------------------------------------------------

    /// Bring residency in line with `liveSet`: free every resident entry that
    /// is not named in it, then decode + upload every path in it that is not
    /// already resident. Idempotent and cheap when the set is unchanged.
    ///
    /// Call it ONCE PER FRAME, from the frame loop, BEFORE the per-cell
    /// render loop — never per cell, never from inside the dirty-gated draw.
    /// (Task 0612 Stage 5 adds that call site; this stage ships the cache
    /// with no caller at all.)
    ///
    /// ORDER IS LOAD-BEARING. Departures are processed BEFORE arrivals, so a
    /// path that replaces another within one reconcile inherits the headroom
    /// the departing one released. Reversing the two would let a swap fail
    /// the budget check for a frame and then succeed on the next — a
    /// one-frame flicker whose cause is invisible at the call site.
    ///
    /// FAILURE MEMOS. A path that cannot be read or decoded is remembered as
    /// a non-resident entry, so a broken file is attempted ONCE rather than
    /// once per frame for as long as something links to it. The memo is
    /// dropped as soon as the path leaves the live set, which is what makes
    /// re-pointing an item, or an explicit reload, retry it naturally.
    void reconcile(const(string)[] liveSet) {
        ++tick_;

        // Pass 1 — mark. A duplicate path in `liveSet` is not an error and is
        // not a second entry: this is exactly the "two clips, one file" case
        // the payload model pushes down to here.
        foreach (p; liveSet) {
            if (p.length == 0) continue;
            auto e = find(p);
            if (e !is null) e.liveTick = tick_;
        }

        // Pass 2 — depart. Everything not marked this generation goes,
        // including failure memos.
        size_t keep = 0;
        foreach (i; 0 .. entries_.length) {
            if (entries_[i].liveTick == tick_) {
                if (keep != i) entries_[keep] = entries_[i];
                ++keep;
            } else {
                release(entries_[i]);
            }
        }
        entries_.length = keep;

        // Pass 3 — arrive.
        foreach (p; liveSet) {
            if (p.length == 0) continue;
            if (find(p) !is null) continue;   // resident, or memoed as failed
            load(p);
        }
    }

    /// The already-resident texture name for `absPath`, or 0.
    ///
    /// NEVER decodes, NEVER allocates, NEVER mutates residency. This is the
    /// ONLY call the draw pass makes, and that restriction is the structural
    /// half of the design: with no way to load from the draw, a per-cell
    /// dirty skip cannot influence what is resident, no matter how the draw
    /// is later rearranged.
    uint lookup(string absPath) const {
        foreach (ref e; entries_)
            if (e.path == absPath) return e.tex;
        return 0;
    }

    // DELIBERATELY NOT OFFERED: a `dimensions(path)` accessor, and the cache
    // does not even RETAIN the decoded width/height (only their product, for
    // the budget). Publishing them would create a SECOND authority on "how big is this
    // image" beside the clip's own `ImageData`, which is where the disk's
    // answer lives and where every consumer already reads it. The two agree
    // today and would diverge the moment a file changes under a resident
    // texture — with nothing to say which of the two a caller got. One
    // question, one answer: the clip's payload for the size, this cache for
    // the texture.

    // -----------------------------------------------------------------------
    // Counters — the observable surface (`/api/images`, and every test here)
    // -----------------------------------------------------------------------

    /// Number of paths holding a live texture. A failure memo is NOT resident
    /// and is not counted: it holds no pixels and no GL name.
    size_t residentEntries() const {
        size_t n = 0;
        foreach (ref e; entries_) if (e.loaded) ++n;
        return n;
    }

    /// Total resident GL bytes — `width * height * 4` per entry, because the
    /// decoder always produces RGBA and the CPU-side buffer is released the
    /// line after the upload. Deliberately NOT the file size: a 54-byte BMP
    /// and a 54-byte JPEG do not cost the same on the GPU, and it is GPU
    /// bytes the budget is about.
    size_t residentBytes() const { return bytes_; }

    /// Successful decodes since construction. The counter that makes "the
    /// orbit does not re-read the disk" an assertable statement rather than a
    /// hope.
    ulong decodeCount() const { return decodes_; }

    /// Release every texture and forget every entry. Idempotent, null-safe,
    /// and safe to call with no GL context in a `version (unittest)` build.
    /// Owner: `ViewportManager.shutdown` — the existing all-cells teardown
    /// site, so this cache is torn down exactly where every other GL object
    /// with a lifetime longer than a frame already is.
    void shutdown() {
        foreach (ref e; entries_) release(e);
        entries_.length = 0;
        tick_  = 0;
        bytes_ = 0;
        // `decodes_` deliberately survives: it counts what this PROCESS has
        // read off the disk, which is a diagnostic about behaviour over time,
        // not a property of the current residency.
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    private inout(Entry)* find(string path) inout {
        foreach (i; 0 .. entries_.length)
            if (entries_[i].path == path) return &entries_[i];
        return null;
    }

    /// Read, size-check, decode and upload `path`, or record a failure memo.
    private void load(string path) {
        import std.conv : to;

        ulong size;
        if (!statBounded(path, size)) { memoFailure(path); return; }

        // The HEADER first, from a bounded window, because the admission
        // decision below only needs the dimensions. Reading a whole
        // photograph to learn its width — and then discovering there is no
        // room for it — would be paid on every frame the refusal stands.
        immutable size_t windowWant =
            size < HEADER_WINDOW ? cast(size_t) size : HEADER_WINDOW;
        ubyte[] bytes;
        if (!readAtMost(path, windowWant, bytes)) { memoFailure(path); return; }

        ImageInfo info;
        if (!imageInfo(bytes, info)) {
            // Only a TRUNCATED read can be the reason: a file that fitted the
            // window has already given its final answer. Retry once against
            // the whole (already size-checked) file, so the window can never
            // turn a decodable image into a broken one — the same fallback,
            // for the same reason, as `io/image_path.d`'s header reader.
            if (size <= windowWant) { memoFailure(path); return; }
            if (!readAtMost(path, cast(size_t) size, bytes)) { memoFailure(path); return; }
            if (!imageInfo(bytes, info)) { memoFailure(path); return; }
        }

        // Admission, not eviction. The budget is checked BEFORE the decode,
        // and an over-budget path is simply not admitted — a path that IS
        // resident is never dropped to make room for one that is not.
        // Evicting a live entry instead would re-decode it on the very next
        // reconcile, which is the decode-per-frame loop this whole design
        // exists to prevent; it would also do it while reporting a perfectly
        // healthy residency count.
        //
        // No memo for this case, on purpose: an over-budget refusal must heal
        // itself the moment something else leaves the live set, so it costs
        // one bounded HEADER read per frame and no decode. A failure memo
        // here would make the recovery depend on the user re-pointing the
        // item.
        immutable size_t want = cast(size_t) info.width * cast(size_t) info.height * 4;
        if (bytes_ + want > budgetBytes) {
            logWarn("image", "cache: '" ~ path ~ "' not admitted — "
                ~ want.to!string ~ " bytes would exceed the "
                ~ budgetBytes.to!string ~ "-byte residency budget");
            return;
        }

        if (bytes.length < size && !readAtMost(path, cast(size_t) size, bytes)) {
            memoFailure(path);
            return;
        }

        DecodedImage img;
        if (!imageDecode(bytes, img)) { memoFailure(path); return; }
        scope (exit) img.free();   // CPU pixels die with this scope, always

        immutable uint tex = upload(img);
        if (tex == 0) { memoFailure(path); return; }

        ++decodes_;
        immutable size_t held = cast(size_t) img.width * cast(size_t) img.height * 4;
        bytes_ += held;
        entries_ ~= Entry(path, tex, held, tick_, true);
    }

    /// The file's size, rejected if it exceeds `MAX_IMAGE_BYTES`.
    ///
    /// The size is a number this process did not write, so it is checked
    /// against the bound BEFORE any read rather than after — the same rule,
    /// and the same constant, `io/image_path.d`'s header reader applies. The
    /// rejection is made against the REAL size, never against however much of
    /// the file was read, or the bound would silently become
    /// `min(bound, window)`.
    private static bool statBounded(string path, out ulong size) {
        import std.file : getSize;
        import std.conv : to;
        try {
            size = getSize(path);
        } catch (Exception e) {
            logWarn("image", "cache: cannot stat '" ~ path ~ "': " ~ e.msg);
            return false;
        }
        if (size > MAX_IMAGE_BYTES) {
            logWarn("image", "cache: rejected '" ~ path ~ "': " ~ size.to!string
                ~ " bytes, larger than the " ~ MAX_IMAGE_BYTES.to!string ~ "-byte bound");
            return false;
        }
        return true;
    }

    private static bool readAtMost(string path, size_t want, ref ubyte[] bytes) {
        import std.file : read;
        try {
            bytes = cast(ubyte[]) read(path, want);
        } catch (Exception e) {
            logWarn("image", "cache: cannot read '" ~ path ~ "': " ~ e.msg);
            return false;
        }
        return true;
    }

    private void memoFailure(string path) {
        entries_ ~= Entry(path, 0, 0, tick_, false);
    }

    /// Hand the decoded RGBA buffer to GL and return the texture name.
    ///
    /// House pattern (`viewport.d`'s `ViewportFbo`): generate the name here,
    /// specify storage, set the four sampler parameters explicitly rather
    /// than inheriting whatever the default sampler state happens to be, and
    /// ALWAYS unbind so no later draw finds a texture bound it did not bind.
    private uint upload(ref DecodedImage img) {
        version (unittest) {
            return nextFakeTex_++;
        } else {
            import bindbc.opengl;
            import gl_thread_guard : glThreadGuard;
            glThreadGuard("imageCache.upload");

            uint tex = 0;
            glGenTextures(1, &tex);
            if (tex == 0) return 0;
            glBindTexture(GL_TEXTURE_2D, tex);
            // Row alignment: an RGBA buffer is always 4-byte aligned per row,
            // so the default GL_UNPACK_ALIGNMENT of 4 is already correct —
            // set explicitly anyway, because the value is global GL state
            // some other pass is free to have changed.
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, img.width, img.height, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, img.pixels.ptr);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glBindTexture(GL_TEXTURE_2D, 0);
            return tex;
        }
    }

    private void release(ref Entry e) {
        if (!e.loaded) return;
        bytes_ -= e.bytes;
        version (unittest) {
            // nothing to hand back; the synthetic name is never reused
        } else {
            import bindbc.opengl;
            if (e.tex != 0) glDeleteTextures(1, &e.tex);
        }
        e.tex    = 0;
        e.bytes  = 0;
        e.loaded = false;
    }
}

// ---------------------------------------------------------------------------
// The process-wide instance.
//
// Module-level and therefore thread-local (see the threading note at the top
// of this file). Reached through an accessor rather than exported directly so
// that "who touches the cache" stays greppable as a call, and so a future
// move into an owner object is one function body rather than a sweep.
// ---------------------------------------------------------------------------
private ImagePixelCache g_imagePixelCache;

/// The main thread's pixel cache.
ref ImagePixelCache imagePixelCache() { return g_imagePixelCache; }

// ===========================================================================
// Tests
//
// Every test below is over LITERAL STRING ARRAYS — no `Document`, no links,
// no item kind. That is deliberate and is half the reason the module is split
// this way: a cache test that had to build a document could quietly become a
// test of the selection model instead of a test of the cache.
// ===========================================================================

version (unittest) {
    import io.image_path : writeTestBmp, imageTestDir;
    import std.path : buildPath;
}
