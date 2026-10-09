// Shared fixture + chunk census for the LWO PTAG-per-kind tests (task 4067).
//
// Two consumers, kept in two modules on purpose so one `dub test` run reports
// both reds when the writer pin is rolled back (druntime stops a MODULE at its
// first failed assert):
//   tests/unit/io/lwo_export_test.d              -- round-trip semantics
//   tests/unit/io/lwo_export_ptag_census_test.d  -- on-disk chunk layout
//
// THE DISCRIMINATING DESIGN. A PTAG SURF carries no polygon kind: an entry is
// `[VX poly][u2 tag]` and `poly` is LOCAL to the most-recent POLS chunk. A
// writer that emits ONE trailing PTAG for a layer holding both FACE and PTCH
// polygons therefore produces a file no conformant reader can decode: every
// entry binds to the LAST POLS chunk (PTCH), the FACE entries are misapplied
// to PTCH polygons and the FACE polygons receive no tag at all. Our own
// importer decodes that legacy layout positionally (task 0683), which is why
// a round-trip through it is green on BOTH writer versions and cannot pin the
// fix -- the witness has to be a conformant most-recent-POLS reader.
//
// The FACE polygons carry the NON-default surface ("Roof", index 1) and the
// PTCH polygons the default one ("Body", index 0). Under the legacy layout a
// last-wins conformant reader overwrites each PTCH polygon with its own
// (correct) entry last, and leaves every FACE polygon at surface 0 -- so a
// fixture whose FACE polygons wanted surface 0 would read back CORRECT BY
// ACCIDENT. With FACE -> Roof the first FACE polygon reads "Body" and the
// mismatch is visible at the first polygon checked. There are more PTCH than
// FACE polygons so the legacy file's FACE-local indices all fall inside the
// PTCH chunk's range: the reader must MISREAD, not throw, so that the red is a
// surface-tag mismatch rather than a range exception.
module tests.unit.io.lwo_ptag_fixture;

import mesh : Mesh, Surface;
import math : Vec3;

/// Surface table: index 0 is the reader's default for an untagged polygon.
immutable string[2] kSurfaceNames = ["Body", "Roof"];

/// The mixed fixture, tri k at x = 10k. Face order interleaves the kinds so
/// the per-kind POLS-local numbering differs from the flat face index for
/// every polygon but the first.
immutable bool[5] kMixedSubpatch = [false, true, false, true, true];
immutable uint[5] kMixedMaterial = [1, 0, 1, 0, 0];   // FACE -> Roof, PTCH -> Body

/// N separate triangles, tri k at x offset 10k, so an imported polygon's
/// source is recoverable from its first vertex (`sourceTri`). Per-tri kind
/// and material from the two arrays; the surface table is `kSurfaceNames`.
Mesh kindTris(const(bool)[] subpatch, const(uint)[] material)
{
    assert(subpatch.length == material.length);
    Mesh m = Mesh.init;
    uint[ulong] el;
    foreach (uint k; 0 .. cast(uint) subpatch.length) {
        const float x = k * 10.0f;
        const uint b = cast(uint) m.vertices.length;
        m.vertices ~= [Vec3(x, 0, 0), Vec3(x + 1, 0, 0), Vec3(x, 1, 0)];
        m.addFaceFast(el, [b, b + 1, b + 2]);
    }
    m.buildLoops();
    m.resizeSubpatch();
    foreach (i, sub; subpatch)
        m.setFaceSubpatch(i, sub);
    m.surfaces = surfaceTable();
    m.faceMaterial = material.dup;
    return m;
}

/// The surface table every fixture here carries.
Surface[] surfaceTable()
{
    Surface[] s;
    foreach (name; kSurfaceNames) {
        Surface x;
        x.name = name;
        s ~= x;
    }
    return s;
}

/// Three vertices, no polygons, surfaces present -- the "layer with no
/// polygons of a kind" case at its strongest (no polygons of ANY kind).
Mesh pointsOnly()
{
    Mesh m = Mesh.init;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)];
    m.surfaces = surfaceTable();
    return m;
}

/// Which fixture triangle a polygon came from, by its first vertex's x.
int sourceTri(float x0)
{
    return cast(int) ((x0 + 0.5f) / 10.0f);
}

// ---------------------------------------------------------------------------
// Chunk census: the top-level chunk list of an LWO2 image, with the two
// facts the layout law is about -- POLS kinds/counts and PTAG SURF entry
// counts, in file order. Deliberately NOT a reader: it binds nothing.
// ---------------------------------------------------------------------------

struct LwoChunkCensus {
    string[] ids;             // every top-level chunk id, in file order
    string[] polsKinds;       // "FACE" / "PTCH" / ... per POLS chunk
    uint[]   polsCounts;      // polygons per POLS chunk
    uint[]   ptagSurfCounts;  // entries per PTAG SURF chunk
    uint     tags;            // TAGS chunks seen
    uint     surf;            // SURF chunks seen
}

private ushort be16(const(ubyte)[] s) { return cast(ushort) ((s[0] << 8) | s[1]); }
private uint   be32(const(ubyte)[] s)
{
    return (cast(uint) s[0] << 24) | (cast(uint) s[1] << 16) | (cast(uint) s[2] << 8) | s[3];
}

LwoChunkCensus lwoChunkCensus(const(ubyte)[] b)
{
    LwoChunkCensus c;
    assert(b.length >= 12 && b[0 .. 4] == "FORM" && b[8 .. 12] == "LWO2",
           "not an LWO2 image");
    size_t p = 12;
    while (p + 8 <= b.length) {
        const string id = cast(string) b[p .. p + 4].idup;
        const uint sz = be32(b[p + 4 .. p + 8]);
        const(ubyte)[] data = b[p + 8 .. p + 8 + sz];
        c.ids ~= id;
        if (id == "POLS") {
            c.polsKinds ~= cast(string) data[0 .. 4].idup;
            size_t q = 4; uint n = 0;
            while (q < data.length) {
                const uint cnt = be16(data[q .. q + 2]) & 0x3FF;
                q += 2;
                foreach (_; 0 .. cnt) q += (data[q] == 0xFF) ? 4 : 2;   // VX
                ++n;
            }
            c.polsCounts ~= n;
        } else if (id == "PTAG") {
            if (data[0 .. 4] == "SURF") {
                size_t q = 4; uint n = 0;
                while (q < data.length) {
                    q += (data[q] == 0xFF) ? 4 : 2;                       // VX poly
                    q += 2;                                               // u2 tag
                    ++n;
                }
                c.ptagSurfCounts ~= n;
            }
        } else if (id == "TAGS") {
            ++c.tags;
        } else if (id == "SURF") {
            ++c.surf;
        }
        p += 8 + sz + (sz & 1);
    }
    return c;
}

// ---------------------------------------------------------------------------
// A minimal LWO2 image with hand-written SURF bodies (S1e): one triangle
// tagged with TAGS entry 0, the TAGS table `tags`, and one SURF chunk per
// `surfs` entry carrying exactly the given sub-chunks — so a test can omit or
// set COLR / GLOS / SMAN at will, which the writer package cannot.
// ---------------------------------------------------------------------------

/// One SURF sub-chunk: id and raw body bytes.
struct LwoSub { string id; ubyte[] data; }

/// A SURF chunk: surface name and its sub-chunks.
struct LwoSurf { string name; LwoSub[] subs; }

private void putBe16(ref ubyte[] a, uint v) { a ~= cast(ubyte)(v >> 8); a ~= cast(ubyte)v; }
private void putBe32(ref ubyte[] a, uint v) {
    a ~= cast(ubyte)(v >> 24); a ~= cast(ubyte)(v >> 16); a ~= cast(ubyte)(v >> 8); a ~= cast(ubyte)v;
}
private void putS0(ref ubyte[] a, string s) {
    a ~= cast(const(ubyte)[]) s; a ~= 0;
    if ((s.length + 1) & 1) a ~= 0;
}
private void putChunk(ref ubyte[] a, string id, const(ubyte)[] body_) {
    a ~= cast(const(ubyte)[]) id; putBe32(a, cast(uint)body_.length); a ~= body_;
    if (body_.length & 1) a ~= 0;
}

/// The big-endian F4 bytes of `v` (a SURF scalar sub-chunk body, no envelope).
ubyte[] lwoF4(float v) {
    ubyte[] a;
    putBe32(a, *cast(uint*)&v);
    return a;
}

ubyte[] lwoImage(string[] tags, LwoSurf[] surfs) {
    ubyte[] body_ = cast(ubyte[]) "LWO2".dup;
    ubyte[] t;
    foreach (s; tags) putS0(t, s);
    putChunk(body_, "TAGS", t);
    ubyte[] layr;
    putBe16(layr, 0); putBe16(layr, 0);
    foreach (_; 0 .. 3) putBe32(layr, 0);
    putS0(layr, "L");
    putChunk(body_, "LAYR", layr);
    ubyte[] pnts;
    foreach (p; [[0f, 0f, 0f], [1f, 0f, 0f], [0f, 1f, 0f]]) foreach (c; p) pnts ~= lwoF4(c);
    putChunk(body_, "PNTS", pnts);
    ubyte[] pols = cast(ubyte[]) "FACE".dup;
    putBe16(pols, 3); putBe16(pols, 0); putBe16(pols, 1); putBe16(pols, 2);
    putChunk(body_, "POLS", pols);
    ubyte[] ptag = cast(ubyte[]) "SURF".dup;
    putBe16(ptag, 0); putBe16(ptag, 0);
    putChunk(body_, "PTAG", ptag);
    foreach (s; surfs) {
        ubyte[] sb;
        putS0(sb, s.name);
        putS0(sb, "");
        foreach (sub; s.subs) {
            sb ~= cast(const(ubyte)[]) sub.id;
            putBe16(sb, cast(uint)sub.data.length);
            sb ~= sub.data;
            if (sub.data.length & 1) sb ~= 0;
        }
        putChunk(body_, "SURF", sb);
    }
    ubyte[] img = cast(ubyte[]) "FORM".dup;
    putBe32(img, cast(uint)body_.length);
    img ~= body_;
    return img;
}
