module tests.unit.io.native_source_cells_test;

import io.native;
import std.file;
import std.json;
import std.conv;
import std.format;
import std.algorithm;
import vibe3d.mesh.core.mesh;
import math;
import vibe3d.util.spatial.spatial;
import vibe3d.documents.model.document;
import layer_params;
import vibe3d.editing.params.params;
import io.image_path;
import vibe3d.editing.contracts.seltype;
import vibe3d.mesh.core.mesh_selsets;

// ===========================================================================
// Task 0616 Ph6 — the v8 additions, enumerated. Each block names the wrong
// implementation its fixture separates out.
//
// These are IN-MODULE rather than HTTP tests because the things v8 newly
// carries — an item link, a parent, a focus that is not the primary — have no
// HTTP surface at all in this slice. An HTTP test would have to assert the
// empty set, which is an inert assertion.
// ===========================================================================

version (unittest) {
    import std.file       : tempDir, mkdirRecurse, rmdirRecurse, readText;
    import std.path       : buildPath, dirName, buildNormalizedPath;
    import io.image_path  : writeTestBmp;
    import vibe3d.documents.model.document       : LinkState;

    /// A wiped scratch directory for one `.v3d` codec test. Wiped, not merely
    /// created: a file left behind by a previous run — including a DELIBERATE
    /// BREAK run — is otherwise visible to the next one, and a test whose
    /// result depends on that is not a test. (The same lesson `io/image_path`
    /// records, learned there first.)
    private string v3dTestDir(string tag) {
        auto d = buildPath(tempDir(), "vibe3d_v3d8_" ~ tag);
        if (exists(d)) rmdirRecurse(d);
        mkdirRecurse(d);
        return d;
    }

    /// An image item with a payload already pointed at `absPath`.
    private Layer makeImageLayer(string name, string absPath) {
        auto l = new Layer;
        l.kind = ItemKind.Image;
        l.name = name;
        auto img = new ImageData();
        img.storedPath = absPath;
        refreshImageMeta(img);
        l.imageRef() = img;
        return l;
    }

    private Layer makeEmptyLayer(string name) {
        auto l = new Layer;
        l.kind = ItemKind.Empty;
        l.name = name;
        return l;
    }
}

// ---------------------------------------------------------------------------
// N1 — THE CLIP LIST ROUND-TRIPS, AND THE DOCUMENT CAN MOVE.
//
// The fixture carries TWO image items on ONE path. That is the case the link
// design calls out: with two clips sharing a path, a path-keyed implementation
// resolves to the WRONG clip rather than to nothing, which a one-clip fixture
// reads as success. Their CHANNELS are pairwise different (a non-default enum
// tag each, and opposite `useAlpha`), so a codec that wrote one item's channels
// for both — or that reconstructed the provider from defaults and never
// injected — reads a different value on at least one of them.
//
// The move is done by actually COPYING both files into another directory and
// loading from there, with a DIFFERENT image (9x4 vs 3x2) waiting at the
// destination: an implementation that stored the absolute path resolves to a
// file that really does still exist, so only the dimensions separate the two.
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    auto root = v3dTestDir("clips");
    auto dirA = buildPath(root, "A");
    auto dirB = buildPath(root, "B");
    auto docA = buildPath(dirA, "scene.v3d");
    auto docB = buildPath(dirB, "scene.v3d");
    writeTestBmp(buildPath(dirA, "img.bmp"), 3, 2);
    writeTestBmp(buildPath(dirB, "img.bmp"), 9, 4);

    auto doc = Document.bootstrap(makeCube());       // "Layer 1", the primary
    auto clipA = makeImageLayer("alpha", buildPath(dirA, "img.bmp"));
    auto clipB = makeImageLayer("bravo", buildPath(dirA, "img.bmp"));
    clipA.imageOrNull().colorspace = "linear";       // non-default enum tag
    clipA.imageOrNull().useAlpha   = false;          // non-default bool
    clipB.imageOrNull().colorspace = "sRGB";         // a DIFFERENT non-default
    doc.layers = [doc.layers[0], clipA, clipB];
    doc.setActive(0);

    assert(clipA.imageOrNull().storedPath == clipB.imageOrNull().storedPath,
        "fixture: the two clips share ONE path — that is what makes a "
      ~ "path-keyed identity bug resolve to the wrong clip instead of to none");
    assert(clipA.imageOrNull().width == 3 && clipA.imageOrNull().height == 2,
        "fixture: A's image resolved before the save");

    assert(writeV3d(doc, docA), "write must succeed");

    // --- what the FILE says ------------------------------------------------
    {
        auto raw = parseJSON(readText(docA));
        auto l1  = raw["layers"].array[1];
        assert(l1["type"].str == "image", "the item declares its kind");
        assert(l1["image"]["filename"].str == "img.bmp",
            "the path is stored RELATIVE to the document — with an absolute "
          ~ "stored form the move below would prove nothing. Got "
          ~ l1["image"]["filename"].str);
        assert("filename" !in l1["channels"],
            "`filename` is a READ-ONLY param and must not ride the generic "
          ~ "channels block: injecting it there on load would author the path "
          ~ "behind the command that owns the resolve");
        assert(l1["channels"]["colorspace"].str == "linear",
            "the authored enum channel is written by VALUE");
        assert(l1["channels"]["useAlpha"].type == JSONType.false_);
        assert("width" !in l1["channels"] && "height" !in l1["channels"]
            && "missing" !in l1["channels"],
            "the DERIVED fields are not channels and must never be persisted "
          ~ "— a stored width goes stale the moment the file changes on disk");
    }

    // --- reading it back in place ------------------------------------------
    {
        Document back;
        assert(readV3d(docA, back), "round-trip load must succeed");
        assert(back.layers.length == 3, "both clips survive alongside the mesh");
        auto a = back.layers[1], b = back.layers[2];
        assert(a.name == "alpha" && b.name == "bravo", "names round-trip");
        assert(a.kind == ItemKind.Image && b.kind == ItemKind.Image);
        assert(a.imageOrNull() !is null && b.imageOrNull() !is null,
            "an image item comes back with a CONSTRUCTED payload");
        assert(a.imageOrNull() !is b.imageOrNull(),
            "two items sharing a path are still two payloads — one shared "
          ~ "object would make an edit to either reach both");
        assert(a.imageOrNull().colorspace == "linear"
            && b.imageOrNull().colorspace == "sRGB",
            "each item's enum channel comes back with ITS OWN value, got \""
          ~ a.imageOrNull().colorspace ~ "\" / \"" ~ b.imageOrNull().colorspace ~ "\"");
        assert(a.imageOrNull().useAlpha == false && b.imageOrNull().useAlpha == true,
            "and its own bool channel");
        assert(a.imageOrNull().width == 3 && a.imageOrNull().height == 2
            && !a.imageOrNull().missing,
            "the DERIVED metadata is re-read from the file, not from the "
          ~ "document, got " ~ a.imageOrNull().width.to!string ~ "x"
          ~ a.imageOrNull().height.to!string);
    }

    // --- the document MOVES ------------------------------------------------
    write(docB, readText(docA));
    {
        Document moved;
        assert(readV3d(docB, moved), "the moved document must still load");
        auto a = moved.layers[1].imageOrNull();
        assert(a !is null && !a.missing, "and still find its image");
        assert(a.width == 9 && a.height == 4,
            "it finds the copy that travelled WITH it (9x4), not the one left "
          ~ "behind in A (3x2) — which still exists, so \"resolves to "
          ~ "something\" would pass either way. Got "
          ~ a.width.to!string ~ "x" ~ a.height.to!string);
        assert(dirName(a.storedPath) == buildNormalizedPath(dirB),
            "…and says so in its resolved path: " ~ a.storedPath);
    }
}

// ---------------------------------------------------------------------------
// N2 — THE LINKS ROUND-TRIP, BY IDENTITY.
//
// Discriminating in four ways, each aimed at a named wrong implementation:
//   (a) THREE clips, and the surviving links point at the MIDDLE one — an
//       off-by-one in the index encoding lands on a neighbour that exists, so
//       "the link resolves" passes;
//   (b) TWO consumers on the SAME clip — a "restore the first match and stop"
//       bug is invisible with one, and `is`-identity is what proves many→one
//       rather than two lookalike restorations;
//   (c) clipA carries the SAME PATH as clipB — a path-keyed encoding resolves
//       to clipA and `referrersOf(clipA)` reads 2 instead of 0;
//   (d) the second consumer holds TWO slots whose names sort opposite to their
//       insertion order, so the written order proves the canonical ordering is
//       the list's and not the insertion history's.
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    auto root = v3dTestDir("links");
    auto path = buildPath(root, "scene.v3d");
    writeTestBmp(buildPath(root, "one.bmp"), 3, 2);
    writeTestBmp(buildPath(root, "two.bmp"), 5, 7);

    auto doc = Document.bootstrap(makeCube());
    auto meshPrimary = doc.layers[0];
    auto clipA = makeImageLayer("alpha", buildPath(root, "one.bmp"));
    auto clipB = makeImageLayer("bravo", buildPath(root, "one.bmp"));  // SAME path
    auto clipC = makeImageLayer("charlie", buildPath(root, "two.bmp"));
    auto consX = makeEmptyLayer("consumerX");
    auto consY = makeEmptyLayer("consumerY");
    // Insert "maskImage" FIRST on consY, so the canonical (sorted) order below
    // is the OPPOSITE of the insertion order.
    consX.setLink("maskImage",  clipB);
    consY.setLink("maskImage",  clipB);
    consY.setLink("decalImage", clipC);

    doc.layers = [clipA, clipB, clipC, meshPrimary, consX, consY];
    doc.setActive(3);
    assert(doc.primary is meshPrimary);
    assert(doc.indexOf(clipB) == 1,
        "fixture: the referenced clip is a MIDDLE row, so an off-by-one lands "
      ~ "on a clip that exists");

    assert(writeV3d(doc, path), "write must succeed");

    // The canonical slot order reaches the FILE, not just the object.
    {
        auto raw = parseJSON(readText(path));
        auto ly  = raw["layers"].array[5]["links"].array;
        assert(ly.length == 2, "both slots written");
        assert(ly[0]["slot"].str == "decalImage" && ly[1]["slot"].str == "maskImage",
            "the links block is written straight out of the canonical "
          ~ "(name-sorted) slot list, NOT in insertion order — got "
          ~ ly[0]["slot"].str ~ " first");
        assert(ly[1]["target"].integer == 1,
            "the target is the index of the MIDDLE clip");
    }

    Document back;
    assert(readV3d(path, back), "round-trip load must succeed");
    assert(back.layers.length == 6, "every item survives");
    auto bClipA = back.layers[0], bClipB = back.layers[1], bClipC = back.layers[2];
    auto bX = back.layers[4], bY = back.layers[5];
    assert(bClipB.name == "bravo" && bX.name == "consumerX" && bY.name == "consumerY",
        "sanity: the round trip preserved the item ORDER");

    assert(bX.link("maskImage").state(back) == LinkState.Live,
        "the restored link resolves against the document that holds it");
    assert(bX.link("maskImage").resolve(back) is bClipB,
        "…to the MIDDLE clip. An off-by-one reads \"alpha\" or \"charlie\"; a "
      ~ "path-keyed encoding reads \"alpha\" (same path as bravo)");
    assert(bY.link("maskImage").resolve(back) is bX.link("maskImage").resolve(back),
        "both consumers resolve to ONE AND THE SAME object — two lookalike "
      ~ "items would pass a non-null check and fail this");
    assert(bY.link("decalImage").resolve(back) is bClipC,
        "the second slot on the same consumer points somewhere else entirely");
    assert(bY.linkSlots().length == 2 && bX.linkSlots().length == 1,
        "no slot was invented and none was lost");

    const(Layer)[] refs;
    back.referrersOf(bClipB, refs);
    assert(refs.length == 2 && refs[0] is bX && refs[1] is bY,
        "the reverse sweep finds BOTH consumers — a restore that stopped at "
      ~ "the first match reads 1, got " ~ refs.length.to!string);
    back.referrersOf(bClipA, refs);
    assert(refs.length == 0,
        "and NONE for the clip that merely shares bravo's path — a path-keyed "
      ~ "encoding reads 2 here, got " ~ refs.length.to!string);
}

// ---------------------------------------------------------------------------
// N3 — A DANGLING LINK DEGRADES TO Unset ACROSS THE WIRE, and does NOT
// re-point at whatever now occupies the index.
//
// The wire encoding is the target's INDEX. A dangling target is by definition
// not a member, so it HAS no index — the slot cannot be written and comes back
// unset. That is an honest property of the encoding and is deliberately not
// papered over with a sentinel or a tombstone (either would be the second
// identity scheme the index encoding depends on not existing).
//
// It also partially retracts one of the three reasons the link design gives
// for keeping dangling links: "deleted carries strictly more information than
// never-set" holds in memory and NOT across a save.
//
// Discriminating: after the victim is removed, ANOTHER clip slides into its
// index. So the wrong implementation — one that wrote the stale index anyway —
// comes back `Live` and pointing at "charlie". The assertion is on the OBJECT,
// not only on the state, because a sentinel-index implementation could also
// read `Unset` while having silently re-pointed something else.
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    auto root = v3dTestDir("dangling");
    auto path = buildPath(root, "scene.v3d");
    writeTestBmp(buildPath(root, "one.bmp"), 3, 2);

    auto doc = Document.bootstrap(makeCube());
    auto meshPrimary = doc.layers[0];
    auto clipB = makeImageLayer("bravo",   buildPath(root, "one.bmp"));
    auto clipC = makeImageLayer("charlie", buildPath(root, "one.bmp"));
    auto consX = makeEmptyLayer("consumerX");
    consX.setLink("maskImage", clipB);

    doc.layers = [clipB, clipC, meshPrimary, consX];
    doc.setActive(2);
    assert(consX.link("maskImage").state(doc) == LinkState.Live,
        "fixture: the link starts Live");

    // Remove the target from the document WITHOUT touching the link — exactly
    // what `layer.delete` leaves behind (links are never swept).
    doc.layers = [clipC, meshPrimary, consX];
    doc.setActive(1);
    assert(consX.link("maskImage").state(doc) == LinkState.Dangling,
        "precondition: the link is genuinely DANGLING before the save — "
      ~ "without this the assertion below would be about an Unset link and "
      ~ "would prove nothing");
    assert(doc.layers[0] is clipC,
        "precondition: another clip has slid into the victim's old index, so a "
      ~ "codec that wrote the stale index would come back pointing at it");

    assert(writeV3d(doc, path), "write must succeed");
    {
        auto raw = parseJSON(readText(path));
        assert("links" !in raw["layers"].array[2],
            "an unencodable slot is DROPPED, not written with a sentinel");
    }

    Document back;
    assert(readV3d(path, back), "load must succeed — a dangling link is not a "
      ~ "malformed document");
    auto bX = back.layers[2];
    assert(bX.name == "consumerX", "sanity: the consumer is where we left it");
    assert(bX.link("maskImage").state(back) == LinkState.Unset,
        "a dangling link cannot be encoded as an index, so it comes back "
      ~ "UNSET — this is the documented cost of the index encoding");
    assert(bX.link("maskImage").targetUnchecked() is null,
        "…and it points at NOTHING, not at whatever took over the index. A "
      ~ "codec that wrote the stale index reads \"charlie\" here");
    assert(bX.linkSlots().length == 0,
        "the slot itself is gone, not left behind empty");
}

// ---------------------------------------------------------------------------
// N4 — A `primaryLayer` NAMING AN ITEM THAT CANNOT BE THE EDIT TARGET IS
// CORRECTED, NOT OBEYED AND NOT REJECTED.
//
// This input became reachable only in v8: the `"type"` token is what lets a
// file name a non-mesh item as the primary, which is why the reader's own
// comment called it "the exposure Stage 8 must close".
//
// Four wrong answers read four different ways:
//   (a) a raw pointer write leaves the primary on the image — asserted BOTH by
//       identity and by the capability, because an implementation that
//       repaired the flag without moving the pointer passes one and fails the
//       other;
//   (b) collapsing the focus onto the repaired primary reads layers[1];
//   (c) DROPPING the offending item to make the index valid reads 2 layers;
//   (d) rejecting outright reads false.
// ---------------------------------------------------------------------------
unittest {
    auto root = v3dTestDir("primary_fix");
    auto path = buildPath(root, "scene.v3d");
    writeTestBmp(buildPath(root, "one.bmp"), 3, 2);

    enum string tri = `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}`;
    write(path,
        `{"formatVersion":8,"primaryLayer":0,"focusedItem":0,"layers":[`
        ~ `{"type":"image","selected":true,"channels":{"name":"clip"},`
        ~ `"image":{"filename":"one.bmp"}},`
        ~ `{"type":"mesh","selected":false,"channels":{"name":"M1"},` ~ tri ~ `},`
        ~ `{"type":"mesh","selected":false,"channels":{"name":"M2"},` ~ tri ~ `}`
        ~ `]}`);

    // THE FIXTURE DETAIL THAT MAKES (a) NON-VACUOUS, found by the break check:
    // ONLY the image is marked selected. With a mesh ALSO marked selected, the
    // post-swap `selectItem(mesh, Add)` pass promotes it to primary anyway and
    // the raw-write implementation reaches the same final state — the
    // assertions below would then hold against the very code they exist to
    // reject. Deselecting both meshes removes that rescue, so a raw
    // `document.primary = parsed[primaryLayer]` write leaves the primary on the
    // image and (a) reads it.

    Document back;
    assert(readV3d(path, back),
        "(d) a malformed index is a REPAIRABLE inconsistency, not a malformed "
      ~ "document — the load must succeed");
    assert(back.layers.length == 3,
        "(c) nothing is dropped to make the index valid, got "
      ~ back.layers.length.to!string);
    assert(back.layers[0].kind == ItemKind.Image && back.layers[0].name == "clip");
    assert(back.primary is back.layers[1],
        "(a) the primary re-homes to the first item that CAN be one, got \""
      ~ back.primary.name ~ "\"");
    assert(kindInfo(back.primary.kind).canBePrimary,
        "(a) …and the capability agrees — an implementation that repaired the "
      ~ "flag without moving the pointer passes the identity check and fails "
      ~ "this one");
    assert(back.focusedItem is back.layers[0],
        "(b) the focus stays where the FILE put it. Collapsing it onto the "
      ~ "repaired primary is the exclusive-select collapse the split exists to "
      ~ "prevent — got \"" ~ back.focusedItem.name ~ "\"");
    assert(back.focusedItem.selected, "and the focus invariant still holds");
}

// ---------------------------------------------------------------------------
// N4b — the SIBLING case: a document with NO item that can be the edit target
// is REJECTED, and the caller's document is untouched.
//
// There is no representable repair: `Document`'s invariants require a primary
// that `canBePrimary`, so every layer-list consumer would otherwise be
// reasoning about a document the type system says cannot exist.
// ---------------------------------------------------------------------------
unittest {
    auto root = v3dTestDir("no_primary");
    auto path = buildPath(root, "scene.v3d");
    writeTestBmp(buildPath(root, "one.bmp"), 3, 2);

    write(path,
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"image","selected":true,"channels":{"name":"clip"},`
        ~ `"image":{"filename":"one.bmp"}},`
        ~ `{"type":"empty","selected":false,"channels":{"name":"E"}}`
        ~ `]}`);

    import vibe3d.mesh.core.mesh : makeCube;
    auto live = Document.bootstrap(makeCube());
    live.layers[0].name = "keepme";
    auto priorPrimary = live.primary;

    assert(!readV3d(path, live),
        "a document with no possible edit target is rejected, not repaired");
    assert(live.layers.length == 1 && live.layers[0].name == "keepme",
        "and the caller's document is untouched, got "
      ~ live.layers.length.to!string ~ " layer(s)");
    assert(live.primary is priorPrimary,
        "…including its primary POINTER, which a half-committed swap would "
      ~ "have left stale");
}

// ---------------------------------------------------------------------------
// N5 — A CHANNEL VALUE THE PARAM CODEC REFUSES CANNOT HALF-COMMIT THE
// DOCUMENT.
//
// `injectParamsInto` THROWS a plain `Exception` — not a `JSONException` — on an
// unknown enum tag and on a wrong JSON type for a String param. The assertion
// is NOT "it does not crash": it is that the CALLER'S DOCUMENT IS UNCHANGED.
// Three wrong implementations read differently:
//   * an uncaught throw kills the test outright;
//   * a load that returns true leaves a half-parsed document;
//   * a load that returns false AFTER the atomic swap reads 2 layers with a
//     stale primary pointer — which is the one the inject-before-swap ordering
//     is really about.
//
// Two fixtures, because they reach different `throw` sites in the same
// function.
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    auto root = v3dTestDir("bad_channel");
    writeTestBmp(buildPath(root, "one.bmp"), 3, 2);
    enum string tri = `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}`;

    string[2] fixtures = [
        // (1) an unknown ENUM tag on the image item's `colorspace`.
        `{"formatVersion":8,"primaryLayer":1,"layers":[`
        ~ `{"type":"image","selected":false,"channels":{"name":"clip",`
        ~ `"colorspace":"not-a-real-tag"},"image":{"filename":"one.bmp"}},`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"M"},` ~ tri ~ `}`
        ~ `]}`,
        // (2) a non-string value for the String param `name`.
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":42},` ~ tri ~ `}`
        ~ `]}`,
    ];

    foreach (fi, body_; fixtures) {
        auto path = buildPath(root, format("bad%d.v3d", fi));
        write(path, body_);

        // A known-good two-item document is the thing that must survive.
        auto live = Document.bootstrap(makeCube());
        live.layers[0].name = "keepme";
        auto second = new Layer; second.name = "alsokeepme"; second.meshRef() = makeCube();
        live.layers ~= second;
        live.setActive(0);
        auto priorPrimary = live.primary;

        assert(!readV3d(path, live),
            format("fixture %d: a refused channel value must reject the load", fi));
        assert(live.layers.length == 2,
            format("fixture %d: the caller's document keeps its LENGTH — a "
                ~ "reject after the atomic swap reads %d", fi, live.layers.length));
        assert(live.layers[0].name == "keepme" && live.layers[1].name == "alsokeepme",
            format("fixture %d: …and its contents", fi));
        assert(live.primary is priorPrimary,
            format("fixture %d: …and its primary POINTER, which a post-swap "
                ~ "reject leaves stale", fi));
    }
}

// ---------------------------------------------------------------------------
// N6 — THE UNSUPPORTED-VERSION MESSAGE NAMES BOTH VERSIONS, SAYS THE FILE IS
// NOT DAMAGED, AND — THE PART THAT MAKES ANY OF THAT WORTH ASSERTING — LEAVES
// THIS FUNCTION.
//
// The wording is a contract, not a nicety (owner, task 0616 Ph6): "could not
// open" reads as corruption and sends the user hunting a problem that does not
// exist.
//
// WHAT CHANGED HERE AND WHY (review B1). The first version of this test read
// the message off a `log.d` LISTENER. That proved the string was written; it
// did not prove anyone receives it — and nobody did. `log.d` has one sink, a
// stderr echo; there is no log panel, and the only non-test `addLogListener`
// in the whole tree was this test's own. So the message was asserted through a
// channel the application never opens, while File → Open of a pre-v8 document
// visibly did nothing at all. That is the same inert shape this task has been
// caught by at every stage, one level up: not an assertion that cannot fail,
// but an assertion about a value nothing downstream reads.
//
// So the assertion is now on `lastV3dRejectReason()` — the value `FileLoad`
// copies into `Command.refusalReason()`, which the dispatch funnel appends to
// the HTTP error text and `runCommand` turns into the modal notice. Break the
// delivery and this goes red; the listener version stayed green.
//
// Discriminating on content, unchanged and still needed: the file's version
// AND the editor's must BOTH appear. A message naming only one of them
// (`"unsupported formatVersion 7"`) tells the user nothing about what this
// build wants, and reads differently here. Whole PHRASES, never a bare digit —
// forced by an earlier break check, where a bare "8" needle passed against the
// reader's own `readV3d: path=…/vibe3d_v3d8_…` info line.
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;
    import std.algorithm : canFind;

    auto root = v3dTestDir("version_gate");
    enum string tri = `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}`;

    // Three ways to be the wrong version: older, newer, and unlabelled.
    struct Case { int ver; string[] mustMention; }
    auto cases = [
        Case(7,  ["format version 7",  "version 8", "not damaged", "EARLIER"]),
        Case(99, ["format version 99", "version 8", "not damaged", "NEWER"]),
    ];

    foreach (ci, c; cases) {
        auto path = buildPath(root, format("v%d.v3d", c.ver));
        write(path, format(
            `{"formatVersion":%d,"primaryLayer":0,"layers":[`
            ~ `{"type":"mesh","selected":true,"channels":{"name":"M"},%s}]}`,
            c.ver, tri));

        auto live = Document.bootstrap(makeCube());
        live.layers[0].name = "keepme";
        assert(!readV3d(path, live),
            format("case %d: a v%d file must be rejected", ci, c.ver));
        assert(live.layers.length == 1 && live.layers[0].name == "keepme",
            format("case %d: …with the caller's document untouched", ci));

        auto reason = lastV3dRejectReason();
        assert(reason.length > 0,
            format("case %d: the reader must hand its reason OUT, not only "
                ~ "log it — a caller with nothing to say shows nothing", ci));
        foreach (needle; c.mustMention)
            assert(reason.canFind(needle),
                format("case %d: the rejection message must mention \"%s\" — "
                    ~ "naming only one of the two versions, or saying merely "
                    ~ "\"could not open\", sends the user looking for "
                    ~ "corruption that is not there. Got:\n%s",
                    ci, needle, reason));
        assert(!reason.canFind("reject:"),
            format("case %d: the `reject:` tag is log grep-bait and must not "
                ~ "reach a dialog. Got:\n%s", ci, reason));
    }

    // A file with no version key at all is a separate branch: there is no
    // file version to name, so the message must still name the EDITOR's.
    {
        auto path = buildPath(root, "noversion.v3d");
        write(path, format(`{"primaryLayer":0,"layers":[`
            ~ `{"type":"mesh","selected":true,"channels":{"name":"M"},%s}]}`, tri));
        auto live = Document.bootstrap(makeCube());
        assert(!readV3d(path, live), "an unlabelled file is rejected");
        auto reason = lastV3dRejectReason();
        assert(reason.canFind("formatVersion") && reason.canFind("version 8"),
            "the unlabelled-file message names the key it wanted and the "
          ~ "version this build reads. Got:\n" ~ reason);
    }

    // A load that SUCCEEDS leaves no reason behind. Without this, a reader
    // that never cleared the field would report the previous document's
    // rejection against a file that opened perfectly — and `runCommand` would
    // raise a dialog over a successful File → Open.
    {
        auto path = buildPath(root, "good.v3d");
        write(path, format(
            `{"formatVersion":%d,"primaryLayer":0,"layers":[`
            ~ `{"type":"mesh","selected":true,"channels":{"name":"M"},%s}]}`,
            kV3dFormatVersion, tri));
        auto live = Document.bootstrap(makeCube());
        assert(readV3d(path, live), "control: the current version loads");
        assert(lastV3dRejectReason() == "",
            "a successful load reports no reason; got \""
          ~ lastV3dRejectReason() ~ "\" left over from the rejects above");
    }
}

// ---------------------------------------------------------------------------
// N7 — THE WRITER EMITS EVERY ITEM, AND ENFORCES IT IN A RELEASE BINARY
// (review S1).
//
// The precondition itself is old: `parent` / `links` / `primaryLayer` /
// `focusedItem` are indices into the array `writeV3d` emits, so a write that
// skips an item re-points every reference past the hole at its neighbour. What
// guarded it was a plain `assert` at the end of the emit loop, and every
// shipped binary is built `--build=release` (`tools/release/*.sh`, both CI
// release jobs), where `-release` strips plain asserts outright. So the one
// precondition whose violation silently corrupts every reference in the file
// was checked in development builds only. It is now an `if` + `return false`.
//
// Discriminating — the wrong implementation is the SHIPPED v7 one: skip the
// items the format cannot represent (`if (!layer.hasMesh && !layer.hasImage)
// continue;`). The fixture puts an item with NO payload in the MIDDLE, so that
// implementation drops it, the surviving items shift down one, and:
//
//   * `writeV3d` returns false where the correct one returns true;
//   * the written `links` target names a DIFFERENT item, which the reload
//     assertion below reads by identity rather than by "not null".
//
// The middle placement matters: the per-item check fires on the iteration
// AFTER a drop, so an item dropped last would only be caught by the tail
// length check. Both halves are exercised — one fixture per half.
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    auto root = v3dTestDir("emit_every_item");
    writeTestBmp(buildPath(root, "clip.bmp"), 3, 2);
    auto path = buildPath(root, "scene.v3d");

    // [0] mesh (primary)  [1] empty consumer, NO payload  [2] image
    auto doc  = Document.bootstrap(makeCube());
    doc.layers[0].name = "Base";
    auto consumer = new Layer;
    consumer.kind = ItemKind.Empty;
    consumer.name = "consumer";
    auto clip = makeImageLayer("clip", buildPath(root, "clip.bmp"));
    doc.layers ~= consumer;
    doc.layers ~= clip;
    consumer.setLink("backdropImage", clip);
    doc.setActive(0);

    assert(!consumer.hasMesh && !consumer.hasImage,
        "fixture precondition: the middle item carries NEITHER payload, which "
      ~ "is exactly what a payload-filtered write would drop. Without this the "
      ~ "test could not tell an unfiltered writer from a filtered one");
    assert(doc.indexOf(clip) == 2, "fixture: the link target is the LAST item");

    assert(writeV3d(doc, path),
        "an item the format has no payload block for is still WRITTEN — it "
      ~ "holds the link, and it owns index 1");

    {
        auto raw = parseJSON(readText(path));
        assert(raw["layers"].array.length == 3,
            "every item reached the file; got "
          ~ raw["layers"].array.length.to!string);
        assert(raw["layers"].array[1]["type"].str == "empty",
            "…the payload-less one at ITS OWN index, not squeezed out");
        assert(raw["layers"].array[1]["links"].array[0]["target"].integer == 2,
            "…and its link still names index 2. A filtered write renumbers "
          ~ "this to 1, which after the reload is the consumer itself");
    }

    Document back;
    assert(readV3d(path, back), "the written document reloads");
    assert(back.layers.length == 3);
    assert(back.layers[1].link("backdropImage").resolve(back) is back.layers[2],
        "the link comes back pointing at the IMAGE, read by identity — a "
      ~ "renumbered write resolves to a real item too, just the wrong one");

    // The tail half of the check: an item dropped AFTER the last emitted one
    // leaves no later iteration to notice the position drift, so the length
    // comparison is not redundant with the per-item one.
    auto trailing = new Layer;
    trailing.kind = ItemKind.Empty;
    trailing.name = "trailing";
    doc.layers ~= trailing;
    auto path2 = buildPath(root, "scene2.v3d");
    assert(writeV3d(doc, path2), "…and a payload-less item in LAST position");
    assert(parseJSON(readText(path2))["layers"].array.length == 4,
        "all four items written");
}

// ---------------------------------------------------------------------------
// N8 — THE WRITER NEVER EMITS A CHANNEL VALUE ITS OWN READER REFUSES
// (review S2).
//
// `paramToJson` is a general value formatter and is deliberately lenient for
// the two enum kinds: `Kind.Enum` writes the live string verbatim, and
// `Kind.IntEnum` has a documented raw-integer fallback. `injectParamsInto` —
// the reader's only channel writer — THROWS on both, and `readV3d`'s outer
// backstop turns that throw into a rejection of the WHOLE DOCUMENT. So a
// value that never passed through a validating write path produces a file that
// saves without complaint and then will not open: the worst failure this
// format has, and one the user cannot act on because the save reported
// success.
//
// N5's fixture (1) is literally such a file, hand-authored. It is reachable
// for real as soon as an item channel is backed by a D enum with a member the
// table does not list (task 0612's first channel is exactly that shape).
//
// Discriminating: `colorspace` is set to a tag outside its declared three by a
// DIRECT FIELD WRITE — the one route with no validation on it — and the
// assertion is that the document RELOADS. With the guard removed the file
// carries "not-a-real-tag", `readV3d` rejects it, and `assert(readV3d(...))`
// reads false. The second half pins WHAT was written instead: the declared
// default, not a blank and not the bad tag.
// ---------------------------------------------------------------------------
unittest {
    import vibe3d.mesh.core.mesh : makeCube;

    auto root = v3dTestDir("bad_live_channel");
    writeTestBmp(buildPath(root, "clip.bmp"), 3, 2);
    auto path = buildPath(root, "scene.v3d");

    auto doc  = Document.bootstrap(makeCube());
    auto clip = makeImageLayer("clip", buildPath(root, "clip.bmp"));
    doc.layers ~= clip;
    doc.setActive(0);

    // The only unvalidated route to the field. `layer.attr` rejects an
    // undeclared tag and both injector forms throw on one (task 3150 widened
    // the reader's tolerance to unreadable NUMBERS only), which is precisely
    // why this state is not reachable through them.
    clip.imageOrNull().colorspace = "not-a-real-tag";
    {
        auto prov = new LayerPropsProvider(clip);
        bool declared = false;
        foreach (ref p; prov.params())
            if (p.name == "colorspace")
                foreach (ref e; p.enumValues)
                    if (e[0] == "not-a-real-tag") declared = true;
        assert(!declared,
            "fixture precondition: the value really is outside the declared "
          ~ "tag set — if the set ever grows to include it this test goes "
          ~ "quietly inert");
    }

    assert(writeV3d(doc, path), "the write still succeeds");
    {
        auto raw = parseJSON(readText(path));
        auto ch  = raw["layers"].array[1]["channels"];
        assert(ch["colorspace"].str != "not-a-real-tag",
            "the undeclared tag must not reach the file — this is the byte "
          ~ "that makes the document unopenable. Got \""
          ~ ch["colorspace"].str ~ "\"");
        assert(ch["colorspace"].str == "(default)",
            "…and what is written in its place is the DECLARED DEFAULT, which "
          ~ "the reader accepts by construction. Got \""
          ~ ch["colorspace"].str ~ "\"");
    }

    Document back;
    assert(readV3d(path, back),
        "THE POINT: a document saved with an out-of-domain channel value still "
      ~ "opens. Without the guard the reader refuses the whole file and the "
      ~ "user's work is unreachable through a save that said it worked. "
      ~ "Reason given: " ~ lastV3dRejectReason());
    assert(back.layers.length == 2, "both items came back");
    assert(back.layers[1].imageOrNull().colorspace == "(default)",
        "…and the clip's channel reads the substituted default, got \""
      ~ back.layers[1].imageOrNull().colorspace ~ "\"");
}

