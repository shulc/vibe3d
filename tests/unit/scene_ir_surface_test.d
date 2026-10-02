// The importers' surface record reaches the mesh WHOLE (S1d): an
// `ImportedSurface` with every member non-default flows through the public
// `flattenToMesh` into a `Surface` whose matching members are all
// non-default — a member `toSurface` forgets reddens here by name. (The member
// pin itself lives in tests/unit/surface_defaults_test.d.)
module tests.unit.scene_ir_surface_test;

import std.format : format;

import math        : Vec3;
import mesh        : Mesh, Surface;
import io.scene_ir : ImportedScene, ImportedPart, ImportedSurface, flattenToMesh;

unittest {
    ImportedSurface s;
    s.name              = "X";
    s.baseColor         = Vec3(0.1f, 0.2f, 0.3f);
    s.diffuse           = 0.11f;
    s.specular          = 0.22f;
    s.glossiness        = 0.33f;
    s.opacity           = 0.44f;
    s.smoothing         = !ImportedSurface.init.smoothing;
    s.smoothingAngleDeg = 12.5f;
    s.twoSided       = !ImportedSurface.init.twoSided;
    // Population floor: the record above sets every member.
    size_t set;
    static foreach (m; __traits(allMembers, ImportedSurface))
        if (__traits(getMember, s, m) != __traits(getMember, ImportedSurface.init, m)) ++set;
    assert(set == __traits(allMembers, ImportedSurface).length && set == 9,
        format("rig: %d of %d ImportedSurface members are non-default", set,
               __traits(allMembers, ImportedSurface).length));

    ImportedPart p;
    p.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)];
    p.faces    = [[0u, 1, 2]];
    p.surfaces = [s];
    ImportedScene sc;
    sc.parts = [p];
    Mesh m = flattenToMesh(sc);
    assert(m.surfaces.length == 1, format("flattenToMesh carried %d surfaces, expected 1", m.surfaces.length));
    const o = m.surfaces[0];
    enum string[2][] map = [["name", "name"], ["baseColor", "baseColor"],
        ["diffuse", "diffuseAmount"], ["specular", "specularAmount"],
        ["glossiness", "glossiness"], ["opacity", "opacity"],
        ["smoothing", "smoothing"], ["smoothingAngleDeg", "smoothingAngleDeg"],
        ["twoSided", "twoSided"]];
    size_t checked;
    static foreach (pair; map) {
        assert(__traits(getMember, o, pair[1]) == __traits(getMember, s, pair[0]),
            "flattenToMesh dropped ImportedSurface." ~ pair[0] ~ " (Surface." ~ pair[1] ~ ")");
        ++checked;
    }
    assert(checked == 9, format("mapped %d members, expected 9", checked));
}

unittest { // every surface dump carries the flag's VALUE (a constant would pass the frozen all-false planes)
    import std.algorithm : canFind;
    import http_json : meshPlanesJson, meshToJsonDetailed;
    import tests.unit.fixtures : dumpMeshPlanes;
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1, 2]);
    m.buildLoops();
    Surface a, b;
    b.twoSided = true;
    m.surfaces = [a, b];
    immutable planes = meshPlanesJson(m);
    assert(planes.canFind(`"twoSided": false}`) && planes.canFind(`"twoSided": true}`),
        "meshPlanesJson does not emit each surface's twoSided value");
    immutable model = meshToJsonDetailed(m);
    assert(model.canFind(`"twoSided":false}`) && model.canFind(`"twoSided":true}`),
        "the /api/model dump does not emit each surface's twoSided value");
    auto t = dumpMeshPlanes(m);
    Mesh n = m;
    n.surfaces = [a, a];
    assert(dumpMeshPlanes(n)["surfaces"] != t["surfaces"],
        "the fixtures dump cannot tell a two-sided surface from a single-sided one");
}
