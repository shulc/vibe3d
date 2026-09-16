module tests.unit.subpatch_key_fold_test;

import core.internal.hash : hashOf;
import math : Vec3;
import mesh : Mesh;
import mesh_dirty : foldSubpatchKeyMember;
import std.format : format;
import subpatch_osd : computeSubpatchTopologyKey;
import subpatch_preview : computeReusablePreviewKey;

private ulong reverseFold(T)(ulong folded, auto ref const T value)
    pure nothrow @nogc @safe
{
    enum ulong kMulInverse = 0x0887493432BADB37UL;
    enum ulong kAdd = 0xD1B54A32D192ED03UL;
    ulong rotated = (folded - kAdd) * kMulInverse;
    rotated ^= cast(ulong)hashOf(value);
    return (rotated >> 27) | (rotated << (64 - 27));
}

private Mesh reuseCage(bool withCrease = true)
{
    Mesh cage;
    cage.vertices.length = 26;
    foreach (i, ref v; cage.vertices)
        v = Vec3(cast(float)i * 0.1f,
                 cast(float)i * 0.2f,
                 cast(float)i * 0.3f);

    cage.edges.length = 48;
    foreach (i, ref edge; cage.edges)
        edge = [cast(uint)(i % 26), cast(uint)((i + 1) % 26)];

    cage.faces._store.length = 24;
    foreach (i, ref face; cage.faces._store)
        face = [cast(uint)(i % 26), cast(uint)((i + 1) % 26),
                cast(uint)((i + 2) % 26), cast(uint)((i + 3) % 26)];
    cage.resizeSubpatch();
    foreach (ref mark; cage.faceMarks) mark |= Mesh.Marks.Subpatch;
    if (withCrease)
        assert(cage.setCreaseWeight(0, 0.25f));
    return cage;
}

private struct TopologyInputs
{
    int nv = 26;
    int nf = 24;
    int level = 3;
    int[] faceCounts;
    int[] faceIndices;
    int[] creasePairs;
    float[] creaseWeights;
    int[] cornerVerts;
    float[] cornerWeights;
}

private TopologyInputs topologyInputs()
{
    TopologyInputs t;
    foreach (i; 0 .. t.nf) {
        t.faceCounts ~= 4;
        foreach (j; 0 .. 4)
            t.faceIndices ~= (i * 4 + j) % t.nv;
    }
    t.creasePairs = [0, 1, 4, 5];
    t.creaseWeights = [0.5f, 1.5f];
    t.cornerVerts = [2, 8];
    t.cornerWeights = [10.0f, 5.0f];
    return t;
}

private ulong topologyKey(ref const TopologyInputs t)
{
    return computeSubpatchTopologyKey(
        t.nv, t.nf, t.level, t.faceCounts, t.faceIndices,
        t.creasePairs, t.creaseWeights, t.cornerVerts, t.cornerWeights);
}

unittest // the fold is a bijection of the prior state for a fixed member
{
    enum ulong kMul = 0x9E3779B185EBCA87UL;
    enum ulong kMulInverse = 0x0887493432BADB37UL;
    static assert((kMul * kMulInverse) == 1,
        "the fold multiplier must stay invertible modulo 2^64");

    const uint[] suffix = [3u, 1u, 4u, 1u, 5u, 9u];
    immutable ulong[] states = [
        0UL, 1UL, ulong.max, 0x0123456789ABCDEFUL,
        0xFEDCBA9876543210UL,
    ];
    foreach (state; states) {
        const folded = foldSubpatchKeyMember(state, suffix);
        assert(reverseFold(folded, suffix) == state,
            format("fold inverse lost prior state %016x", state));
    }
    assert(foldSubpatchKeyMember(states[3], suffix)
        != foldSubpatchKeyMember(states[4], suffix),
        "one unchanged suffix must not merge two distinct prefix states");
}

unittest // every reusable-preview member moves the key beyond the old funnel
{
    auto baseCage = reuseCage();
    assert(baseCage.faces.length == 24,
        "member matrix must stay on the measured 24-face cage");
    const ulong base = computeReusablePreviewKey(baseCage, 3);

    string[] members;
    ulong[] keys;
    void record(string member, ref Mesh cage, int depth = 3) {
        members ~= member;
        keys ~= computeReusablePreviewKey(cage, depth);
    }

    { auto m = reuseCage(); record("depth", m, 2); }
    { auto m = reuseCage(); m.vertices ~= Vec3(7, 8, 9); record("vertex count", m); }
    { auto m = reuseCage(); m.edges ~= [24u, 25u]; record("edge count", m); }
    { auto m = reuseCage(); m.faces._store ~= [0u, 1u, 2u]; record("face count", m); }
    { auto m = reuseCage(); m.vertices[0].y += 0.375f; record("vertex positions", m); }
    { auto m = reuseCage(); m.edges[0][1] = 7; record("edge table", m); }
    { auto m = reuseCage(); m.faces._store[0] ~= 4u; record("face arity", m); }
    { auto m = reuseCage(); m.faces._store[0][0] = 9; record("face indices", m); }
    { auto m = reuseCage(); m.faceMarks[0] &= ~Mesh.Marks.Subpatch; record("subpatch marks", m); }
    { auto m = reuseCage(); m.faceMarks[0] |= Mesh.Marks.Hide; record("hide marks", m); }
    { auto m = reuseCage(); assert(m.setCreaseWeight(0, 0.75f)); record("crease weights", m); }
    { auto m = reuseCage(false); record("crease-map presence", m); }

    assert(keys.length == 12,
        "reusable-preview member matrix must contain all 12 members");
    foreach (i, key; keys)
        assert(key != base, format(
            "reusable-preview key ignored `%s` on the 24-face cage", members[i]));
}

unittest // every OSD topology-LRU member moves its slot-addressing key
{
    auto baseInputs = topologyInputs();
    assert(baseInputs.nf == 24 && baseInputs.faceCounts.length == 24,
        "topology member matrix must stay on the measured 24-face cage");
    const ulong base = topologyKey(baseInputs);

    string[] members;
    ulong[] keys;
    void record(string member, ref TopologyInputs t) {
        members ~= member;
        keys ~= topologyKey(t);
    }

    { auto t = topologyInputs(); ++t.nv; record("vertex count", t); }
    { auto t = topologyInputs(); ++t.nf; record("face count", t); }
    { auto t = topologyInputs(); --t.level; record("effective level", t); }
    { auto t = topologyInputs(); --t.faceCounts[0]; record("face counts", t); }
    { auto t = topologyInputs(); ++t.faceIndices[0]; record("face indices", t); }
    { auto t = topologyInputs(); ++t.creasePairs[0]; record("crease pairs", t); }
    { auto t = topologyInputs(); t.creaseWeights[0] = 0.75f; record("crease weights", t); }
    { auto t = topologyInputs(); ++t.cornerVerts[0]; record("corner vertices", t); }
    { auto t = topologyInputs(); t.cornerWeights[0] = 7.5f; record("corner weights", t); }

    assert(keys.length == 9,
        "OSD topology member matrix must contain all nine members");
    foreach (i, key; keys)
        assert(key != base, format(
            "OSD topology key ignored `%s` on the 24-face cage", members[i]));
}
