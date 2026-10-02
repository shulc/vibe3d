// I2 (viewport shading S4b, task 9250): the vendored Reflection images
// (`assets/shading/`) against their manifest. Order: the row floor, then each
// row's file sha256, then its decode (size + decoded-pixel sha256, which ties
// the converter's channel and row order to `decodePng16`), then the licence
// and source records, the embedded tables, and the size ratchet.
module tests.unit.shading_assets_test;

import std.algorithm : canFind, sort, startsWith;
import std.array : split;
import std.conv : to;
import std.digest : toHexString, LetterCase;
import std.digest.sha : sha256Of;
import std.file : read, readText, exists, dirEntries, SpanMode, write, remove, getSize;
import std.format : format;
import std.path : buildPath, dirName, baseName;
import std.string : strip, splitLines, toLower;

import io.image_decode : decodePng16;
import viewport_env : kEnvAssets, kMatcapAssets;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum assetDir = buildPath(repoRoot, "assets", "shading");

private struct Row {
    string output, input, inputSha, outputSha, pixelsSha;
    int width, height;
    string scale, sigma, licence;
}

private Row[] manifest() {
    Row[] rows;
    foreach (line; readText(buildPath(assetDir, "MANIFEST.tsv")).splitLines) {
        if (line.length == 0 || line.startsWith("#") || line.startsWith("output\t")) continue;
        auto c = line.split("\t");
        assert(c.length == 10, "MANIFEST.tsv: a row of " ~ c.length.to!string ~ " columns: " ~ line);
        rows ~= Row(c[0], c[1], c[2], c[3], c[4], c[5].to!int, c[6].to!int, c[7], c[8], c[9]);
    }
    return rows;
}

private string hex(const(ubyte)[] bytes) {
    return sha256Of(bytes).toHexString!(LetterCase.lower).idup;
}

/// sha256 of the decoded pixels as the converter defines it: uint16
/// little-endian RGB, top row first (alpha dropped).
private string pixelsHex(const(ushort)[] rgba) {
    ubyte[] b;
    b.reserve(rgba.length / 4 * 6);
    foreach (i; 0 .. rgba.length / 4)
        foreach (c; 0 .. 3) {
            immutable ushort v = rgba[i * 4 + c];
            b ~= cast(ubyte)(v & 0xFF);
            b ~= cast(ubyte)(v >> 8);
        }
    return hex(b);
}

/// Floor → file sha → decode, for every manifest row.
unittest {
    auto rows = manifest();
    // [E4] Row floor FIRST: 3 environments + 8 MatCaps × 2 layers.
    assert(rows.length == 19, format("MANIFEST.tsv: %d rows, expected 19 (3 env + 16 matcap)", rows.length));
    size_t env, mc;
    foreach (r; rows) {
        immutable path = buildPath(assetDir, r.output);
        assert(exists(path), "manifest names a missing file: " ~ r.output);
        immutable got = hex(cast(const(ubyte)[]) read(path));
        assert(got == r.outputSha, format("%s: file sha256 %s, manifest %s", r.output, got, r.outputSha));
        int w, h;
        auto px = decodePng16(cast(const(ubyte)[]) read(path), w, h);
        assert(px !is null && w == r.width && h == r.height,
            format("%s decoded to %dx%d, manifest %dx%d", r.output, w, h, r.width, r.height));
        assert(pixelsHex(px) == r.pixelsSha,
            format("%s: decoded-pixel sha256 differs from the manifest's", r.output));
        assert(r.licence == "CC0-1.0", r.output ~ ": licence " ~ r.licence);
        assert(r.scale == "16", r.output ~ ": linear scale " ~ r.scale
            ~ " (viewport_env.kShadingImageLinearScale is 16)");
        if (r.output.startsWith("env_")) ++env; else if (r.output.startsWith("matcap_")) ++mc;
    }
    assert(env == 3 && mc == 16, format("manifest kinds: %d env + %d matcap, expected 3 + 16", env, mc));
}

/// [E5] The sha predicate is live: a copy with one byte flipped no longer
/// matches its row.
unittest {
    auto r = manifest()[0];
    auto bytes = cast(ubyte[]) read(buildPath(assetDir, r.output)).dup;
    bytes[bytes.length / 2] ^= 0x01;
    import std.process : thisProcessID;
    immutable tmp = buildPath("/var/tmp", format("vibe3d-shading-flip-%d.png", thisProcessID()));
    write(tmp, bytes);
    scope(exit) if (exists(tmp)) remove(tmp);
    assert(hex(cast(const(ubyte)[]) read(tmp)) != r.outputSha,
        "a one-byte-flipped copy still matches the manifest sha");
}

/// SOURCES.md names every output; no line naming a MatCap file carries a URL
/// (the MatCap source is recorded privately only); THIRD_PARTY_LICENSES.md
/// has the row.
unittest {
    immutable src = readText(buildPath(assetDir, "SOURCES.md"));
    size_t named, matcapLines;
    foreach (r; manifest()) {
        assert(src.canFind(r.output), "SOURCES.md does not name " ~ r.output);
        ++named;
    }
    assert(named == 19);
    foreach (line; src.splitLines) {
        if (!line.canFind("matcap_")) continue;
        ++matcapLines;
        assert(!line.toLower.canFind("http"), "SOURCES.md: a MatCap line carries a URL: " ~ line);
    }
    // Complement floor: the check saw every MatCap row (16 table rows).
    assert(matcapLines >= 16, format("SOURCES.md: only %d lines name a MatCap file", matcapLines));
    assert(readText(buildPath(repoRoot, "THIRD_PARTY_LICENSES.md")).canFind("assets/shading"),
        "THIRD_PARTY_LICENSES.md has no row for assets/shading");
}

/// The embedded tables and the manifest name the same images, both ways.
unittest {
    string[] fromTables, fromManifest;
    foreach (a; kEnvAssets) fromTables ~= "env_" ~ a.name ~ ".png";
    foreach (a; kMatcapAssets) {
        fromTables ~= "matcap_" ~ a.name ~ "_diffuse.png";
        fromTables ~= "matcap_" ~ a.name ~ "_specular.png";
    }
    assert(kEnvAssets.length == 3 && kMatcapAssets.length == 8,
        format("tables: %d env + %d matcap, expected 3 + 8", kEnvAssets.length, kMatcapAssets.length));
    foreach (r; manifest()) fromManifest ~= r.output;
    sort(fromTables); sort(fromManifest);
    assert(fromTables == fromManifest,
        format("embedded tables %s vs manifest %s", fromTables, fromManifest));
    // The embedded bytes ARE the files (the string import reads the tree).
    foreach (a; kEnvAssets)
        assert(a.png == cast(const(ubyte)[]) read(buildPath(assetDir, "env_" ~ a.name ~ ".png")),
            "embedded env_" ~ a.name ~ " differs from the file");
}

/// Size ratchet — OURS, not a derived law: the vendored PNGs total at most
/// 2 MiB, a ceiling set above the owner-accepted ≈ 1.6 MB so a re-conversion
/// or an added image cannot grow the binaries unnoticed; raising it is an
/// owner call. Measured 2026-10-03: `cat assets/shading/*.png | wc -c` →
/// 1599242.
unittest {
    ulong total;
    size_t files;
    foreach (e; dirEntries(assetDir, "*.png", SpanMode.shallow)) { total += getSize(e.name); ++files; }
    assert(files == 19, format("assets/shading: %d PNGs, expected 19", files));
    assert(total <= 2_097_152, format("assets/shading/*.png total %d bytes, over the 2 MiB ratchet", total));
}
