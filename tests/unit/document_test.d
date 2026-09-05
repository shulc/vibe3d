// Module unittests for `document`. Task 0706 moved the first batch out of
// source/document.d, 4061 the rest, and 4120 dissolved the `mixin template`
// the second batch travelled in -- so every block here is now an ordinary
// top-level `unittest` and no production module imports this one. The handful
// that read module-private state reach it through the `version (unittest)`
// seam at the tail of source/document.d; its own comment carries the law.
module tests.unit.document_test;

import mesh    : Mesh;
import seltype : SelMode;
import math    : Vec3, identityMatrix, translationMatrix, matrixFromEulerZYX,
                 pivotScaleMatrix, matMul4, ModelSpace;
import std.conv : to;
import document;

unittest {
    // accessor identity: active(), activeMesh(), activeMeshRef() all resolve
    // to the same heap mesh; the address is stable across repeated calls.
    Mesh m;
    auto doc = Document.bootstrap(m);

    Mesh* p1 = doc.activeMesh();
    Mesh* p2 = doc.activeMesh();
    assert(p1 is p2, "activeMesh() is stable across calls");

    assert(p1 is &doc.active().meshRef(),
           "activeMesh() points at the active layer's mesh field");
    assert(&doc.activeMeshRef() is p1,
           "activeMeshRef() and activeMesh() identify the same mesh");
    // primary aliases the active mesh.
    assert(p1 is &doc.primary.meshRef(), "activeMesh() points at the primary's mesh");

    // Layer is a class: a copy of the Document struct shares the same Layer
    // object (reference), hence the same interior mesh pointer.
    Document doc2 = doc;
    assert(doc2.active() is doc.active(),
           "Document copy shares the same Layer reference (class identity)");
    assert(doc2.activeMesh() is doc.activeMesh(),
           "shared Layer ⇒ shared interior mesh address");
    assert(doc2.primary is doc.primary, "Document copy shares the same primary ref");
}

unittest {
    // multi-layer shape: setActive moves primary/selected/activeIndex in
    // lockstep and the SET-of-one invariant survives every move.
    Mesh m;
    auto doc = Document.bootstrap(m);
    auto l2 = new Layer;
    l2.name = "Layer 2";
    doc.layers ~= l2;
    assert(doc.layers.length == 2);

    Mesh* a0 = doc.activeMesh();
    assert(doc.primary is doc.layers[0] && doc.layers[0].selected);
    assert(!doc.layers[1].selected, "second layer starts deselected");

    doc.setActive(1);
    Mesh* a1 = doc.activeMesh();
    assert(a0 !is a1, "distinct layers have distinct mesh addresses");
    assert(a1 is &doc.layers[1].meshRef(), "activeMesh() follows the primary");
    assert(doc.activeIndex == 1, "activeIndex tracks the active move");
    assert(doc.primary is doc.layers[1], "primary tracks the active move");
    assert(doc.layers[1].selected && !doc.layers[0].selected,
           "exactly the new active layer is selected (SET-of-one)");
    size_t selCount = 0;
    foreach (l; doc.layers) if (l.selected) ++selCount;
    assert(selCount == 1, "still exactly one selected after the move");

    // setActive clamps an out-of-range index into the last layer.
    doc.setActive(99);
    assert(doc.activeIndex == 1 && doc.primary is doc.layers[1],
           "out-of-range setActive clamps to the last layer");
}

unittest {  // every ItemKind has a row with a distinct, non-empty token.
    import std.traits : EnumMembers;
    bool[string] seen;
    foreach (k; EnumMembers!ItemKind) {
        auto info = kindInfo(k);
        assert(info.token.length > 0, "every kind has a non-empty wire token");
        assert(info.token !in seen, "wire tokens are pairwise distinct");
        seen[info.token] = true;
    }
}

unittest {  // kindFromToken is validated, reject-on-unknown (the R-cap #1
            // chokepoint: never a cast, never an index by a caller number).
            // S4: `kind` is `ref`, not `out` — a rejected token must leave
            // it TRULY unchanged (not silently reset to ItemKind.Mesh by
            // D's out-parameter zero-init), so seed it with a non-Mesh
            // sentinel and confirm every rejection leaves the sentinel.
    ItemKind k = ItemKind.Empty;
    assert(!kindFromToken("", k), "empty token rejected");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (empty token)");
    assert(!kindFromToken("MESH", k), "wrong case rejected (case-sensitive)");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (wrong case)");
    assert(!kindFromToken("backdrop", k), "an unshipped kind's token rejected");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (unshipped kind)");
    assert(!kindFromToken("\x00garbage\xff", k), "arbitrary garbage rejected");
    assert(k == ItemKind.Empty, "rejection leaves kind unchanged (garbage)");
}

unittest {  // tokenOf / kindFromToken round-trip for every shipped kind.
    import std.traits : EnumMembers;
    foreach (k; EnumMembers!ItemKind) {
        // Seed with the OPPOSITE kind so a match must genuinely overwrite it
        // (not merely "happen to already equal" the expected result).
        ItemKind back = (k == ItemKind.Mesh) ? ItemKind.Empty : ItemKind.Mesh;
        assert(kindFromToken(tokenOf(k), back), "tokenOf(k) must itself resolve");
        assert(back == k, "round-trip must return the same kind");
    }
}

unittest {  // a non-mesh item reports no mesh through the capability accessors.
    auto l = new Layer;
    l.kind = ItemKind.Empty;
    assert(!l.hasMesh, "Empty has no mesh capability");
    assert(l.meshOrNull is null, "meshOrNull is null for a non-mesh item");
}

unittest {  // the Image row's five pre-existing capabilities are all false,
            // matching the measured reference item (no mesh, no transform,
            // never the mesh edit target, nothing drawn in the viewport, and
            // — Bend #2 — not listed in the scene list either).
    auto info = kindInfo(ItemKind.Image);
    assert(info.token == "image", "Image row's wire token");
    assert(!info.hasMesh,       "Image: hasMesh == false");
    assert(!info.hasXform,      "Image: hasXform == false (Bend #1 — the forcing assert row)");
    assert(!info.canBePrimary,  "Image: canBePrimary == false");
    assert(!info.drawsGeometry, "Image: drawsGeometry == false");
    assert(!info.isSceneItem,   "Image: isSceneItem == false (Bend #2)");
    // The one capability that IS true for this kind — the payload it owns.
    assert(info.hasImage, "Image: hasImage == true (it is the kind this bit exists for)");

    // Mesh and Empty must NOT have picked up the two new bits by accident —
    // both are real document items (visible in the layer panel), and
    // neither owns pixel data.
    assert(kindInfo(ItemKind.Mesh).isSceneItem,  "Mesh: isSceneItem == true");
    assert(kindInfo(ItemKind.Empty).isSceneItem, "Empty: isSceneItem == true");
    assert(!kindInfo(ItemKind.Mesh).hasImage,  "Mesh: hasImage == false");
    assert(!kindInfo(ItemKind.Empty).hasImage, "Empty: hasImage == false");
}

unittest {  // NIT: rehomePrimary on an EMPTY layers list must not crash and
            // must return null (the only answer the ≥1-mesh invariant allows
            // when there is nothing to promote to).
    Document doc;                                // default-constructed: layers.length == 0
    assert(doc.layers.length == 0);
    assert(doc.rehomePrimary(0) is null, "no layers => no candidate");
    assert(doc.rehomePrimary(5) is null, "an out-of-range `at` on an empty list is also safe");
}

// ---------------------------------------------------------------------------
// Task 0612 Stage 2 — the moving-set gate (plan §7.2, first half).
//
// The accessor's own comment used to say a `hasXform` filter "would be a
// branch that can never be false". `ItemKind.Image` made that false, and
// image clips are selectable, so a clip in the selection was silently
// receiving an `ItemXform` its kind declares it does not have.
//
// The fixture is what makes this test able to fail in BOTH directions, which
// is the point: it holds a mesh (`hasXform`), a clip (`!hasXform`) AND a
// plane (`hasXform`), all three selected.
//   * the ungated implementation reads 3 and puts the CLIP in the set;
//   * a "non-mesh items never move" implementation reads 1 and drops the
//     plane — which would defeat the entire task.
// Only a capability gate reads 2 with the plane present. The clip is placed
// in the MIDDLE so "dropped the last one" and "excluded the clip" are
// different observations.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    Document doc;
    auto mesh = new Layer;  mesh.name  = "Mesh";
    auto clip = new Layer;  clip.name  = "Clip";  clip.kind  = ItemKind.Image;
    auto plane = new Layer; plane.name = "Plane"; plane.kind = ItemKind.ImagePlane;
    doc.layers = [mesh, clip, plane];
    doc.selectItem(mesh, SelMode.Set);
    doc.selectItem(clip,  SelMode.Add);
    doc.selectItem(plane, SelMode.Add);

    Layer[] buf;
    doc.selectedItemsInto(buf);
    assert(buf.length == 2,
        "the moving set is the SELECTED items that have a transform — the "
        ~ "ungated version reads 3. got " ~ buf.length.to!string);
    assert(buf[0] is mesh, "the mesh moves");
    assert(buf[1] is plane,
        "the reference-image PLANE moves — a kind-based 'only meshes' gate "
        ~ "would drop it, and placing it with the ordinary transform tools is "
        ~ "the whole premise of the item");
    foreach (l; buf)
        assert(l !is clip,
            "the image CLIP does not move: its kind declares hasXform == false, "
            ~ "so writing an ItemXform onto it is writing to a channel it does "
            ~ "not have");

    // The clip is still SELECTED — the gate narrows the transform target set,
    // it does not touch the selection. Collapsing the two would make the
    // Layers panel and the moving set disagree about what the user picked.
    assert(clip.selected, "the clip stays selected; only the moving set narrows");
}

// ---------------------------------------------------------------------------
// Task 0612 Stage 2 — the image-plane capability row and its payload trio.
//
// Three of the row's columns are already proved AT COMPILE TIME by the
// `static assert`s over `kItemKindTable` (`hasXform`, `isSceneItem`, and
// `!hasMesh`), so asserting them again here would be theatre. What is NOT
// compile-proved, and is genuinely wrong-implementable, is:
//   * `hasImage` — setting it true to reuse the Images panel's machinery is
//     the tempting shortcut, and it would put the plane in the clip list AND
//     make it its own image source, defeating the link indirection;
//   * `canBePrimary` — true here would make a plane a candidate mesh edit
//     target, and `Document`'s invariant would then hand `activeMeshRef()` a
//     layer with no mesh;
//   * `drawsGeometry` — false is what keeps the plane out of the background
//     MESH pass, whose body dereferences `meshRef()` unconditionally. (The
//     static assert makes `true` uncompilable, so this row asserts the value
//     we actually chose rather than the one the compiler forbids.)
// ---------------------------------------------------------------------------
unittest {
    const info = kindInfo(ItemKind.ImagePlane);
    assert(info.token == "imagePlane", "the wire token");
    assert(info.hasImagePlane, "the plane's own capability bit");
    assert(!info.hasImage,
        "a plane LINKS to an image, it does not own one — true here would put "
        ~ "it in the Images panel and give it a second, private image source");
    assert(!info.canBePrimary,
        "a plane is never the mesh edit target");
    assert(!info.drawsGeometry,
        "the plane draws on its OWN display axis; `drawsGeometry` gates the "
        ~ "MESH pass and would upload an empty mesh for it");

    // The trio answers by CAPABILITY, and the payload is null until something
    // constructs one — the same two-step as the image payload.
    auto plane = new Layer; plane.kind = ItemKind.ImagePlane;
    auto mesh  = new Layer;
    assert(plane.hasImagePlane, "capability follows kind");
    assert(!mesh.hasImagePlane, "a mesh layer has no plane payload");
    assert(mesh.imagePlaneOrNull() is null,
        "and asking a mesh for one answers null rather than asserting");
    assert(plane.imagePlaneOrNull() is null,
        "a plane's payload is null until constructed — `hasImagePlane` says "
        ~ "'this kind CAN have one', never 'it has one'");

    plane.imagePlaneRef() = new ImagePlaneData();
    auto p = plane.imagePlaneOrNull();
    assert(p !is null, "and the rebind through imagePlaneRef() sticks");
    // Defaults, asserted where they are declared rather than trusted: these
    // are the measured reference defaults, and `pixelSize` in particular is
    // the number the worked example in the help resolves against (512 px at
    // 0.01 = 5.12 m).
    assert(p.projection == "front", "default projection");
    assert(p.showInPerspective, "shown in perspective by default");
    assert(p.pixelSize == 0.01f, "default metres per pixel");
    assert(p.keepAspect, "proportion locked by default");
    assert(p.brightness == 0.0f && p.contrast == 0.0f && p.transparency == 0.0f,
        "the look channels start neutral");
    assert(!p.invert && !p.flipHorizontal && !p.smooth, "and the look flags off");
}

unittest {  // default ItemXform composes to identity (within 1e-6).
    import std.math : isClose;
    import math : identityMatrix;
    ItemXform x;                       // pos=0, rot=0, scl=1, pivot=0
    auto m = x.composedMatrix();
    foreach (i; 0 .. 16)
        assert(isClose(m[i], identityMatrix[i], 1e-6f, 1e-6f),
               "default ItemXform must compose to identity");
}

unittest {  // pure translation (no rot/scale/pivot) → translation in column 3.
    import std.math : isClose;
    ItemXform x;
    x.pos = Vec3(3, -2, 5);
    auto m = x.composedMatrix();
    // Column-major: translation at m[12],m[13],m[14]; 3×3 block = identity.
    assert(isClose(m[12], 3,  1e-6f, 1e-6f));
    assert(isClose(m[13], -2, 1e-6f, 1e-6f));
    assert(isClose(m[14], 5,  1e-6f, 1e-6f));
    assert(isClose(m[0], 1, 1e-6f, 1e-6f) && isClose(m[5], 1, 1e-6f, 1e-6f)
        && isClose(m[10], 1, 1e-6f, 1e-6f));
}

unittest {  // known TRS-about-pivot vs an INDEPENDENT hand-built expected matrix.
    import std.math : sin, cos, PI, isClose;

    // Inputs.
    Vec3 pos   = Vec3(1, 2, 3);
    Vec3 rdeg  = Vec3(0, 90, 0);          // 90° about Y only (clean closed form)
    Vec3 scl   = Vec3(2, 3, 4);
    Vec3 pivot = Vec3(0.5f, -1.0f, 0.25f);

    ItemXform x;
    x.pos = pos; x.rot = rdeg; x.scl = scl; x.pivot = pivot;
    auto got = x.composedMatrix();

    // ---- Independent expected matrix (column-major m[row + col*4]) ----------
    // R = Ry(90°): cos=0, sin=1. Column-major rotation about Y:
    //   Rcol = [ c 0 -s | 0 1 0 | s 0 c ] (rows) →
    //   [r00 r01 r02; r10 r11 r12; r20 r21 r22] = [0 0 1; 0 1 0; -1 0 0].
    double c = cos(90.0 * PI / 180.0), s = sin(90.0 * PI / 180.0);
    double[3][3] R = [
        [ c,   0.0,  s  ],
        [ 0.0, 1.0,  0.0],
        [-s,   0.0,  c  ],
    ];
    // RS = R · diag(scl)  (scale columns).
    double[3][3] RS;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3)
        RS[i][j] = R[i][j] * [scl.x, scl.y, scl.z][j];
    // Linear part L = RS (rotation+scale, pivot only affects translation).
    // Translation: from M = T(pos)·T(pivot)·RS_about_origin·T(-pivot), the
    // about-pivot affine offset for a linear map L is  pivot - L·pivot, then
    // shifted by pos+pivot folded as: t = pos + (pivot - L·pivot).
    double[3] piv = [pivot.x, pivot.y, pivot.z];
    double[3] Lpiv;
    foreach (i; 0 .. 3)
        Lpiv[i] = RS[i][0]*piv[0] + RS[i][1]*piv[1] + RS[i][2]*piv[2];
    double[3] t = [
        pos.x + (piv[0] - Lpiv[0]),
        pos.y + (piv[1] - Lpiv[1]),
        pos.z + (piv[2] - Lpiv[2]),
    ];
    // Assemble expected column-major float[16]: exp[row + col*4].
    double[16] exp;
    foreach (col; 0 .. 3) foreach (row; 0 .. 3)
        exp[row + col*4] = RS[row][col];
    exp[3] = exp[7] = exp[11] = 0;
    exp[12] = t[0]; exp[13] = t[1]; exp[14] = t[2]; exp[15] = 1;

    foreach (i; 0 .. 16)
        assert(isClose(got[i], cast(float)exp[i], 1e-5f, 1e-5f),
               "composedMatrix mismatch vs independent hand formula at index");
}

unittest {  // default ItemXform -> isIdentity, invertible, not mirrored;
    // m/mInv are literally identityMatrix (the exact fast path, §3.5).
    import math : identityMatrix;
    ItemXform x;
    auto ms = x.modelSpace();
    assert(ms.isIdentity && ms.invertible && !ms.mirrored);
    foreach (i; 0 .. 16) {
        assert(ms.m[i]    == identityMatrix[i]);
        assert(ms.mInv[i] == identityMatrix[i]);
    }
}

unittest {  // a non-zero pivot ALONE (rot=0, scl=1) must still be identity —
    // T(pivot)*I*T(-pivot) == I for any pivot. Pins that the isIdentity
    // check is deliberately blind to `pivot`.
    ItemXform x;
    x.pivot = Vec3(5, -3, 2);
    auto ms = x.modelSpace();
    assert(ms.isIdentity, "pivot alone (rot=0, scl=1) must not break the identity fast path");
}

unittest {  // M . M^-1 ~= I for a combined rot + non-uniform-scale + pivot xform.
    import std.math : isClose;
    ItemXform x;
    x.pos   = Vec3(4, -1, 2);
    x.rot   = Vec3(15, -40, 70);
    x.scl   = Vec3(2, 0.5f, 3);
    x.pivot = Vec3(1, 1, -1);
    auto ms = x.modelSpace();
    assert(!ms.isIdentity && ms.invertible);

    auto prod = matMul4(ms.m, ms.mInv);
    foreach (i; 0 .. 16)
        assert(isClose(prod[i], identityMatrix[i], 1e-4f, 1e-4f),
               "M * mInv must be ~identity for a rot+non-uniform-scale+pivot transform");
}

unittest {  // The trap the plan calls out by name: R^T (what modelSpace's
    // mInv actually uses) is NOT the same matrix as matrixFromEulerZYX(-rot)
    // (Rz(-)*Ry(-)*Rx(-), the reverse-order product) for a rotation that
    // mixes more than one axis. If a future edit "simplifies" mInv's
    // rotation term to matrixFromEulerZYX(-rot), THIS must fail.
    import std.math : isClose;
    Vec3 rot = Vec3(20, -35, 50); // multi-axis, away from any accidental symmetry
    auto Rt = matrixFromEulerZYX(rot);
    // Hand-transpose (same construction modelSpace() uses internally).
    float[16] RtT = [
        Rt[0], Rt[4], Rt[ 8], 0,
        Rt[1], Rt[5], Rt[ 9], 0,
        Rt[2], Rt[6], Rt[10], 0,
        0,     0,     0,      1,
    ];
    auto wrongInverse = matrixFromEulerZYX(Vec3(-rot.x, -rot.y, -rot.z));
    bool anyDifferent = false;
    foreach (i; 0 .. 16)
        if (!isClose(RtT[i], wrongInverse[i], 1e-4f, 1e-4f)) anyDifferent = true;
    assert(anyDifferent,
        "R^T must differ from matrixFromEulerZYX(-rot) for a multi-axis rotation "
        ~ "-- if they match, the trap this test guards against has gone silent");
}

unittest {  // scl.z == 0 -> !invertible (and scl.x/scl.y likewise, R2).
    ItemXform x;
    x.scl = Vec3(2, 3, 0);
    auto ms = x.modelSpace();
    assert(!ms.isIdentity);
    assert(!ms.invertible, "a zero scale component must report !invertible");
}

unittest {  // mirrored == true for exactly one OR three negative scale
    // components, false for zero or two — the PRODUCT rule (§3.7), not
    // "any component is negative".
    ItemXform x;

    x.scl = Vec3(2, 3, 4);      // zero negatives
    assert(!x.modelSpace().mirrored);

    x.scl = Vec3(-2, 3, 4);     // one negative
    assert(x.modelSpace().mirrored);

    x.scl = Vec3(-2, -3, 4);    // two negatives
    assert(!x.modelSpace().mirrored);

    x.scl = Vec3(-2, -3, -4);   // three negatives
    assert(x.modelSpace().mirrored);
}

unittest {  // projectionSpace's forward-projection identity, exercised through
    // the PRODUCTION factory (math.d's own unittest covers the general
    // primitive; this pins document.ItemXform.modelSpace() specifically).
    import std.math : PI, isClose;
    import math : projectionSpace, projectToWindow, lookAt, perspectiveMatrix, Viewport;

    ItemXform x;
    x.pos = Vec3(2, 0, -1);
    x.rot = Vec3(0, 25, 0);
    x.scl = Vec3(1, 1, 1);
    auto ms = x.modelSpace();
    assert(!ms.isIdentity);

    Vec3 eye = Vec3(0, 3, 10);
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(50.0f * PI / 180.0f, 1.0f, 0.01f, 100.0f);
    vp.width = 300; vp.height = 300; vp.eye = eye;

    Vec3 pLocal = Vec3(0.2f, 0.1f, 0.4f);
    auto vpLocal = projectionSpace(vp, ms);
    float px1, py1, z1;
    bool ok1 = projectToWindow(pLocal, vpLocal, px1, py1, z1);

    Vec3 pWorld = ms.toWorldPoint(pLocal);
    float px2, py2, z2;
    bool ok2 = projectToWindow(pWorld, vp, px2, py2, z2);

    assert(ok1 == ok2 && ok1);
    assert(isClose(px1, px2, 1e-3f, 1e-3f) && isClose(py1, py2, 1e-3f, 1e-3f),
        "projectionSpace(vp, x.modelSpace()) must agree with pre-transforming the point");
}

// ---------------------------------------------------------------------------
// Task 0770 — `foregroundLayersInto`/`foregroundLayerCount`, one pass instead
// of N restarts of the walk. Both cases below are load-bearing for the same
// reason: task 0721 grepped `source/` and found ZERO callers of either
// function outside `document.d` — their own unittest blocks are the only
// thing that will ever run this code, so a test is not a nice-to-have here,
// it is the entire proof the fix did what it claims.
// ---------------------------------------------------------------------------

unittest {  // the rewrite must answer the SAME order the restart-per-rank walk
            // did, including a selSeat TIE — the third key
            // `nthEditTargetCandidate`'s own doc comment names — and BOTH
            // stages (current selection, then the deselect history).
    Mesh m0;
    auto doc = Document.bootstrap(m0);   // layer 0 = A, real seat (via setActive)
    auto a = doc.layers[0];
    auto b = new Layer; b.name = "B";
    auto c = new Layer; c.name = "C";
    auto d = new Layer; d.name = "D";
    doc.layers ~= [b, c, d];

    // C gets a genuine seat through the mutator.
    doc.selectItem(c, SelMode.Add);
    // B and D are wired in with a raw field write instead — the shape
    // several loaders and `revert()` paths use (document_selection.d's own
    // comment on the walk) — so both keep the "never seated" value, 0, and
    // TIE with each other.
    b.selected = true;
    d.selected = true;
    // A moves into HISTORY: deselect it through the mutator so its selSeat
    // survives into the bucket instead of the object simply vanishing.
    doc.selectItem(a, SelMode.Remove);

    Layer[] fg;
    doc.foregroundLayersInto(fg);
    assert(fg.length == 4 && fg[0] is b && fg[1] is d && fg[2] is c && fg[3] is a,
        "current stage first, sorted by (selSeat, layers-index): B and D tie "
        ~ "at seat 0 and split on index (B=1 before D=3); C's real seat "
        ~ "sorts after both. A survives only in the HISTORY stage, which "
        ~ "the walk places after the whole current stage, not merged into it");
    assert(doc.foregroundLayerCount() == 4, "count agrees with the list length");
}

unittest {  // the quadratic-oracle regression. `foregroundLayersInto` used to
            // restart the O(L) walk once per rank and pay for it TWICE (count,
            // then fill) -- 1.57 ms measured at 64 selected layers (task
            // 0721), growing roughly cubically in the layer count because both
            // L (candidates) and the per-candidate restart cost scale with it:
            // 84.6 ms at 256 layers, measured while proving this fix (same
            // dmd -O -release -inline method 0721 used). At the size below,
            // extrapolating that growth puts the restart-per-rank shape at
            // low SECONDS for a single call -- nowhere near the bound this
            // asserts, which the one-pass form clears with a wide margin
            // (tens of microseconds, measured the same way).
    import std.datetime.stopwatch : StopWatch, AutoStart;

    Mesh m0;
    auto doc = Document.bootstrap(m0);
    enum layerCount = 800;
    foreach (i; 1 .. layerCount) {
        auto l = new Layer;
        l.name = "L";
        doc.layers ~= l;
    }
    foreach (i; 1 .. layerCount) doc.selectItem(doc.layers[i], SelMode.Add);

    Layer[] fg;
    doc.foregroundLayersInto(fg);              // warm-up + correctness smoke
    assert(fg.length == layerCount);
    assert(doc.foregroundLayerCount() == layerCount);

    auto sw = StopWatch(AutoStart.yes);
    foreach (i; 0 .. 20) doc.foregroundLayersInto(fg);
    immutable msecs = sw.peek.total!"msecs";
    assert(msecs < 200,
        "20 calls to foregroundLayersInto at " ~ layerCount.to!string
        ~ " selected layers took " ~ msecs.to!string ~ " ms -- the "
        ~ "restart-per-rank walk this pins against needed low SECONDS for a "
        ~ "SINGLE call at this size (extrapolated from the 84.6 ms measured "
        ~ "at 256 layers)");
}

// ===========================================================================
// TASK 1906 STAGE 3 — `Layer` MINTS AN IDENTITY AND REGISTERS IT.
//
// `source/mesh_dirty.d`'s own ABA cell proves the LAW (a changed birth at an
// address advances every watcher for it). This proves the other half — that
// the law is actually wired to the object whose address reuse is the hazard —
// and it is a separate cell because the two fail for different reasons: the
// law can be correct with nothing calling it, and the call can be present
// against a law that does nothing.
//
// Mutations, each in isolation:
//   * delete `birthId = ++g_nextLayerBirthId;` from `Layer.this()`
//     ⇒ block (1) reddens: two layers share the id 0.
//   * delete the `noteMeshBirth(...)` call from `Layer.this()`
//     ⇒ block (2) reddens: the table has no record for the layer's mesh.
// ===========================================================================
unittest {
    import document  : Layer;
    import mesh_dirty : notedBirthAt;

    auto a = new Layer();
    auto b = new Layer();

    // (1) The identity is MINTED, once per layer, and monotone.
    assert(a.birthId != 0 && b.birthId != 0,
        "every Layer mints a nonzero identity — 0 is the 'never seated' value");
    assert(b.birthId > a.birthId,
        "the identity is monotone, so a later layer can never be mistaken for "
      ~ "an earlier one that occupied the same address");

    // (2) …and REGISTERED against the address the caches key on. Without this
    //     the mint is a field nobody reads.
    assert(notedBirthAt(cast(size_t)&a.meshRef()) == a.birthId,
        "Layer's constructor must register its identity against its mesh "
      ~ "address — that registration is the whole ABA close");
    assert(notedBirthAt(cast(size_t)&b.meshRef()) == b.birthId,
        "…for every layer, not just the first");
}


// ---------------------------------------------------------------------------
// In-module unit tests (Stage 0 contract: SET-of-one invariants, primary ==
// active, accessor identity, lockstep on every active move). Types only — no
// app.d wiring exercised.
// ---------------------------------------------------------------------------

unittest {
    // bootstrap invariants
    Mesh m;
    auto doc = Document.bootstrap(m);
    assert(doc.layers.length == 1, "bootstrap must yield exactly one layer");
    assert(doc.layers.length >= 1, "layers.length >= 1 contract");
    assert(doc.activeIndex == 0, "bootstrap active layer is index 0");
    assert(doc.active() !is null, "active layer object is non-null");
    assert(doc.active().name == "Layer 1", "bootstrap names the layer 'Layer 1'");
    assert(doc.active().visible, "bootstrap layer is visible");
    assert(!doc.background(doc.active()), "bootstrap layer is foreground (not background)");
    assert(doc.foreground(doc.active()), "bootstrap layer is foreground (derived)");
    // SET-of-one + primary invariants.
    assert(doc.primary !is null, "primary is non-null");
    assert(doc.primary is doc.active(), "primary == active");
    assert(doc.primary is doc.layers[doc.activeIndex], "primary == layers[activeIndex]");
    assert(doc.primary.selected, "primary is selected");
    size_t selCount = 0;
    foreach (l; doc.layers) if (l.selected) ++selCount;
    assert(selCount == 1, "exactly one layer selected (SET-of-one)");
    assert(doc.isPrimary(doc.active()), "isPrimary(active) is true");
    assert(doc.isFocused(doc.focusedItem), "isFocused(focusedItem) is true");
    assert(doc.isFocused(doc.active()), "on an all-mesh document, focus == primary");
}



// ---------------------------------------------------------------------------
// Stage 2a/2b contract: the multi-select mutators + the FULLY DERIVED
// background/foreground rule. A shared helper asserts the load-bearing
// invariants AND that the derived helpers track `selected`/`visible` exactly
// (there is no longer any stored bool — Stage 2b deleted it).
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Task 0616 Stage 6 (Ph3): the consumer → item link.
//
// The fixture below is built to defeat the two ways a link test goes inert:
//
//   * THREE image items, TWO consumers. With one of each, "the link resolved
//     to the right item" is indistinguishable from "everything resolves to
//     the only item there is", and a sweep that clears the first match and
//     stops is indistinguishable from a correct one.
//   * TWO of the images share one `storedPath`. A path-keyed implementation
//     then resolves to the WRONG one of the two, with a different name to
//     read — so "a path is not identity" has an observable value, not just an
//     argument.
//   * Deletes happen in the MIDDLE of the list. Deleting the tail cannot tell
//     "the link reports dangling" apart from "an index was clamped into an
//     empty range", and cannot expose the index scheme's real failure — the
//     slot past the hole changing owner.
// ---------------------------------------------------------------------------

version (unittest) {
    private struct LinkFixture {
        Document doc;
        Layer meshLayer, clipA, clipB, clipC, consumerX, consumerY;
    }

    /// layers = [mesh, clipA, clipB, clipC, consumerX, consumerY]
    ///   clipA and clipB deliberately share one storedPath;
    ///   consumerX links backdropImage→clipB and maskImage→clipC,
    ///   consumerY links backdropImage→clipB  (many→one on clipB).
    private LinkFixture makeLinkFixture() {
        LinkFixture f;
        Mesh m;
        f.doc = Document.bootstrap(m);
        f.meshLayer = f.doc.layers[0];

        Layer mkClip(string name, string path) {
            auto l = new Layer;
            l.kind = ItemKind.Image;
            l.name = name;
            l.imageRef() = new ImageData();
            l.imageRef().storedPath = path;
            return l;
        }
        Layer mkConsumer(string name) {
            auto l = new Layer;
            l.kind = ItemKind.Empty;   // a scene item that is not itself an image
            l.name = name;
            return l;
        }

        f.clipA = mkClip("clipA", "shared.png");
        f.clipB = mkClip("clipB", "shared.png");   // SAME file, different item
        f.clipC = mkClip("clipC", "other.png");
        f.consumerX = mkConsumer("consumerX");
        f.consumerY = mkConsumer("consumerY");
        f.doc.layers ~= [f.clipA, f.clipB, f.clipC, f.consumerX, f.consumerY];

        // Slots set in REVERSE alphabetical order, so the canonical ordering
        // `linkSlots()` promises is produced by the insert, not by luck.
        f.consumerX.setLink("maskImage",     f.clipC);
        f.consumerX.setLink("backdropImage", f.clipB);
        f.consumerY.setLink("backdropImage", f.clipB);
        return f;
    }
}

unittest {  // Ph3 core: many→one, per-slot independence, canonical slot order,
            // and the reverse sweep. Every assertion here needs at least two
            // clips or two slots to be able to fail.
    auto f = makeLinkFixture();

    auto xBack = f.consumerX.link("backdropImage").resolve(f.doc);
    auto yBack = f.consumerY.link("backdropImage").resolve(f.doc);
    auto xMask = f.consumerX.link("maskImage").resolve(f.doc);

    assert(xBack is f.clipB, "consumerX's backdrop link resolves to clipB");
    assert(yBack is f.clipB, "consumerY's backdrop link resolves to clipB");
    assert(xBack is yBack,
        "two consumers of one image must resolve to the SAME object, not to "
        ~ "two equal-looking ones");
    assert(xMask is f.clipC,
        "a second named slot on the SAME consumer is independent — this is "
        ~ "clipC, not the other slot's clipB");

    assert(f.consumerX.link("backdropImage").state(f.doc) == LinkState.Live);
    assert(f.consumerX.link("noSuchSlot").state(f.doc) == LinkState.Unset,
        "an absent slot is Unset, not Dangling and not a crash");
    assert(f.consumerX.link("noSuchSlot").resolve(f.doc) is null);
    assert(f.meshLayer.linkSlots().length == 0, "an item with no links has no slots");

    // A READ-ONLY handle can ask for one slot by name, not merely enumerate
    // them (review NIT 1). This is a compile-time claim as much as a runtime
    // one: `link()` was mutable-only, so this line did not compile at all and
    // a `const(Layer)` consumer had to hand-scan `linkSlots()`.
    {
        const(Layer) ro = f.consumerX;
        assert(ro.link("backdropImage").targetUnchecked() is f.clipB,
            "a const(Layer) resolves one named slot");
        assert(ro.link("noSuchSlot").isSet() == false,
            "and gets the Unset link for an absent one, same as a mutable one");
    }

    // Canonical order, and the exact slot set — inserted mask-then-backdrop.
    auto slots = f.consumerX.linkSlots();
    assert(slots.length == 2, "consumerX has exactly two slots");
    assert(slots[0].name == "backdropImage" && slots[1].name == "maskImage",
        "linkSlots() is name-sorted regardless of insertion order");

    // The reverse direction. clipB has two referrers, in layers order.
    Layer[] refs;
    f.doc.referrersOf(f.clipB, refs);
    assert(refs.length == 2, "clipB has two referrers");
    assert(refs[0] is f.consumerX && refs[1] is f.consumerY,
        "referrersOf reports in layers order");

    // A PATH IS NOT IDENTITY. clipA carries byte-identical `storedPath` to
    // clipB and is reached by nothing — a path-keyed link or a path-keyed
    // sweep would hand back clipA (it is the earlier of the two) and would
    // report clipA as having two referrers.
    assert(f.clipA.imageOrNull.storedPath == f.clipB.imageOrNull.storedPath,
        "fixture vacuity guard: the two clips really do share one path");
    assert(f.clipA !is f.clipB, "…and are still two distinct items");
    f.doc.referrersOf(f.clipA, refs);
    assert(refs.length == 0,
        "nothing links to clipA — sharing a file with clipB is not sharing "
        ~ "clipB's identity");
    f.doc.referrersOf(f.clipC, refs);
    assert(refs.length == 1 && refs[0] is f.consumerX, "clipC has one referrer");
}

unittest {  // A NAME IS NOT IDENTITY — renaming either end changes nothing.
    auto f = makeLinkFixture();

    f.clipB.name     = "renamed";      // the target
    f.consumerX.name = "consumerX2";   // and the consumer, for good measure

    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipB,
        "rename must not break the link");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB,
        "…for either consumer");
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC,
        "…and must not disturb the sibling slot");
    assert(f.consumerX.linkSlots()[0].name == "backdropImage",
        "the SLOT name belongs to the consumer, not to the target — a target "
        ~ "rename does not rename the slot");

    // Names are not even unique: give a second item the renamed one's name and
    // the link still names exactly one item.
    f.clipC.name = "renamed";
    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipB,
        "two items may share a name; the link still resolves to one of them");
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC,
        "…and the other slot still resolves to the OTHER one");
}

unittest {  // AN INDEX IS NOT IDENTITY — a pure reorder of layers[] moves
            // every slot number and no link.
    auto f = makeLinkFixture();
    assert(f.doc.indexOf(f.clipB) == 2 && f.doc.indexOf(f.clipC) == 3,
        "fixture vacuity guard: clipB at 2, clipC at 3 before the permute");

    // Move clipB (2) to the tail — the shape `layer.reorder` produces.
    f.doc.layers = f.doc.layers[0 .. 2] ~ f.doc.layers[3 .. $] ~ f.clipB;
    assert(f.doc.indexOf(f.clipB) == 5 && f.doc.indexOf(f.clipC) == 2,
        "vacuity guard: both slot numbers really did change");

    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipB,
        "reorder must not move a link");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB);
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC);
}

unittest {  // Deleting the MIDDLE clip: both links report themselves dangling,
            // the sibling slot is untouched, and nothing swaps to a neighbour.
    auto f = makeLinkFixture();
    immutable size_t bIdx = f.doc.indexOf(f.clipB);
    assert(bIdx == 2, "vacuity guard: clipB is a MIDDLE layer, not the tail");

    // Splice clipB out — the exact operation LayerDelete performs.
    f.doc.layers = f.doc.layers[0 .. bIdx] ~ f.doc.layers[bIdx + 1 .. $];
    assert(f.doc.layers.length == 5,
        "vacuity guard: the list is still non-empty, so 'dangling' cannot be "
        ~ "an index clamped into an empty range");

    assert(f.consumerX.link("backdropImage").state(f.doc) == LinkState.Dangling,
        "a link to a deleted item reports Dangling");
    assert(f.consumerY.link("backdropImage").state(f.doc) == LinkState.Dangling,
        "…for BOTH consumers — not just the first one a sweep would reach");
    assert(f.consumerX.link("backdropImage").resolve(f.doc) is null,
        "a dangling link resolves to null");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is null);
    assert(f.consumerX.link("backdropImage").state(f.doc) != LinkState.Unset,
        "Dangling is distinguishable from Unset — 'the image you chose was "
        ~ "deleted' is not the same statement as 'you chose no image'");

    // NOT A SILENT SWAP. clipC sat at slot 3; the delete slid consumerX into
    // that slot. A link that stored the NUMBER 3 would now hand back
    // consumerX — a live, plausible-looking, completely wrong item. The first
    // assertion is the vacuity guard that proves the slot really changed
    // owner, so the second one is testing something.
    assert(f.doc.layers[3] is f.consumerX,
        "vacuity guard: the middle delete moved a DIFFERENT item into clipC's "
        ~ "old slot 3");
    assert(f.consumerX.link("maskImage").resolve(f.doc) is f.clipC,
        "the surviving link followed the OBJECT, not the slot number");
    assert(f.consumerX.link("maskImage").state(f.doc) == LinkState.Live);

    // The identity survives even though the resolution does not — which is
    // what makes the reverse sweep able to answer "who was pointing at the
    // thing that just went", the question a re-point UI or a later
    // clear-on-delete policy has to ask.
    assert(f.consumerX.link("backdropImage").targetUnchecked() is f.clipB,
        "a dangling link still names WHICH item it lost");
    Layer[] refs;
    f.doc.referrersOf(f.clipB, refs);
    assert(refs.length == 2 && refs[0] is f.consumerX && refs[1] is f.consumerY,
        "referrersOf still finds both consumers of the deleted clip");

    // Undo shape: reinsert the SAME object at its old slot. Both links are
    // Live again, on one and the same object, with nothing to restore.
    f.doc.layers = f.doc.layers[0 .. bIdx] ~ f.clipB ~ f.doc.layers[bIdx .. $];
    auto xBack = f.consumerX.link("backdropImage").resolve(f.doc);
    auto yBack = f.consumerY.link("backdropImage").resolve(f.doc);
    assert(xBack is f.clipB && yBack is f.clipB,
        "reinserting the object relinks both consumers");
    assert(xBack is yBack,
        "…to ONE object — an implementation that restored two links onto two "
        ~ "objects would pass a 'both are non-null' check");
}

unittest {  // A link answers for the document it is ASKED about. This is the
            // whole-document-replacement case (scene reset, .v3d load,
            // interchange import) — the one no delete-time sweep can cover.
    auto f     = makeLinkFixture();
    auto other = makeLinkFixture();   // same shape, all-new objects

    assert(other.doc.layers[2].name == "clipB",
        "vacuity guard: the other document has a same-named item at the SAME "
        ~ "slot, so an index- or name-keyed link would happily resolve here");
    assert(other.doc.layers[2] !is f.clipB, "…but it is a different object");

    assert(f.consumerX.link("backdropImage").state(other.doc) == LinkState.Dangling,
        "a link into a replaced-away document is Dangling, not Live");
    assert(f.consumerX.link("backdropImage").resolve(other.doc) is null,
        "…and must not resolve into the new document's item at that slot");
    assert(f.consumerX.link("backdropImage").state(f.doc) == LinkState.Live,
        "the same link is still Live against its own document — the state is "
        ~ "a property of the PAIR, not of the link");
}

unittest {  // Slot mutation: replace, clear, the null-target spelling, and the
            // independence a cloned slot set must have.
    auto f = makeLinkFixture();

    // Replace, not append.
    f.consumerX.setLink("backdropImage", f.clipA);
    assert(f.consumerX.linkSlots().length == 2, "re-pointing a slot does not add one");
    assert(f.consumerX.link("backdropImage").resolve(f.doc) is f.clipA,
        "the slot now points at clipA");
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB,
        "…and the OTHER consumer's slot is untouched");

    // Clear, and the null-target spelling of the same thing — one
    // representation of "points at nothing", never a leftover empty slot.
    assert(f.consumerX.clearLink("backdropImage"), "clearLink reports the removal");
    assert(!f.consumerX.clearLink("backdropImage"), "…and reports nothing the second time");
    assert(f.consumerX.linkSlots().length == 1, "the slot is gone, not emptied");
    assert(f.consumerX.linkSlots()[0].name == "maskImage");
    f.consumerX.setLink("maskImage", null);
    assert(f.consumerX.linkSlots().length == 0,
        "setLink(name, null) removes the slot rather than leaving an unset one");

    // Cloning a slot set shares TARGETS but not the slot array.
    auto clone = new Layer;
    clone.kind = ItemKind.Empty;
    clone.name = "clone";
    clone.copyLinksFrom(f.consumerY);
    f.doc.layers ~= clone;
    assert(clone.link("backdropImage").resolve(f.doc) is f.clipB,
        "the clone points at the SAME item, not a copy of it");
    clone.setLink("backdropImage", f.clipC);
    assert(f.consumerY.link("backdropImage").resolve(f.doc) is f.clipB,
        "re-pointing the clone must not write through into the source's slots");
    assert(clone.link("backdropImage").resolve(f.doc) is f.clipC);
}


// ---------------------------------------------------------------------------
// What used to be the tail of `source/document.d`. Task 4061 moved it here as
// a `mixin template` instantiated back inside `document`, because some of it
// reads module-private state; task 4120 measured how much (four blocks and one
// oracle, not 45) and replaced the arc with the `version (unittest)` seam at
// the tail of `source/document.d`, which is what the `test*` calls below reach.
// ---------------------------------------------------------------------------

/// TEST-ONLY oracle for the in-module unit tests below. Every check here is
/// a plain `assert()`, which `-release` strips entirely (dlang.org: `-release`
/// disables assertions other than `assert(0)`) — this function enforces
/// nothing in a release binary; production code must never come to depend on
/// it firing.
private void assertDocInvariants(ref Document d) {
    assert(d.layers.length >= 1, "layers.length >= 1");
    // TASK 0654 — the three clauses that used to sit here ("primary non-null",
    // "focusedItem non-null", "at least one layer is always selected") are
    // replaced by the BICONDITIONAL. The oracle no longer forbids the empty
    // state; it forbids every HALFWAY state around it, which is the part that
    // is actually load-bearing now.
    // TASK 0668 — the biconditional SPLIT. `focusedItem` still tracks
    // emptiness exactly; `primary` now tracks whether anything SELECTED can
    // be the edit target, which is a strictly weaker question. `empty` below
    // therefore means "no edit target", not "nothing selected" — the two
    // parted company the moment an item that cannot be primary was allowed to
    // be the only selected one.
    // TASK 0671 — `primary` is a WALK now, so the oracle reads it ONCE and
    // asserts against that value. Re-reading it per clause would let a walk
    // that is not a function of the state pass by answering differently each
    // time, which is the one failure mode a derived target has that a stored
    // one does not.
    auto prim = d.primary;
    immutable bool empty = prim is null;
    bool primaryInLayers = false;
    bool focusedInLayers = false;
    bool anyCanBePrimary = false;
    size_t selCount = 0;
    size_t stateCanBePrimary = 0;
    foreach (l; d.layers) {
        if (l is prim) primaryInLayers = true;
        if (l is d.focusedItem) focusedInLayers = true;
        if (l.selected) ++selCount;
        if (kindInfo(l.kind).canBePrimary && d.selectionState(l) != SelState.None)
            ++stateCanBePrimary;
        if (kindInfo(l.kind).canBePrimary) anyCanBePrimary = true;
        // Task 0671: the derivation is `roleOf`, and these two are one arm of
        // it each. Restated so a `foreground`/`background` that stopped
        // agreeing with the classifier is caught here rather than at whichever
        // consumer noticed first.
        assert(d.background(l) == (d.roleOf(l) == LayerRole.Background),
            "derived background() == roleOf() is Background");
        assert(d.foreground(l) == (d.roleOf(l) == LayerRole.Foreground),
            "derived foreground() == roleOf() is Foreground");
        // A layer is never simultaneously foreground and background.
        assert(!(d.foreground(l) && d.background(l)),
            "foreground and background are mutually exclusive");
        // Task 0671: an item is never in BOTH lists. `selectionState` resolves
        // current-first so it could never SAY so, which is exactly why the
        // storage has to be checked directly.
        if (l.selected)
            assert(!testHistoryBucketHolds(d, l),
                "a CURRENT item must not also sit in its kind's history bucket");
    }
    assert(empty || primaryInLayers, "primary is a member of layers");
    // TASK 0671 — the primary is NOT necessarily selected any more. That
    // clause was the storage model talking: it held because a stored pointer
    // had to be kept pointing at something the user could see marked. A
    // latched target is in the history list, and the whole point is that it
    // survives its own deselection. What it must still be is FOREGROUND, which
    // is the property every consumer actually depends on.
    assert(empty || d.roleOf(prim) == LayerRole.Foreground,
        "the edit target is a foreground layer (task 0671)");
    assert(empty || d.selectionState(prim) != SelState.None,
        "the edit target has a non-zero selection state (task 0671)");
    // The focus is the SELECTION's pointer, so it is governed by `selCount`,
    // not by `empty` (task 0668). Keeping it on `empty` would have made this
    // oracle reject the very state the task exists to produce.
    immutable bool noSelection = selCount == 0;
    assert((d.focusedItem is null) == noSelection,
        "focusedItem is null exactly when nothing is selected (task 0654/0668)");
    assert(noSelection || focusedInLayers, "focusedItem is a member of layers (task 0615)");
    assert(noSelection || d.focusedItem.selected,
        "focusedItem is selected (task 0615; relaxed from Stage 2's focusedItem is primary)");
    // The other direction, restated for 0671: no primary ⟺ no `canBePrimary`
    // item has a non-zero SELECTION STATE. 0668's version of this line read
    // `selected` and would now reject the very state this task exists to
    // produce — a mesh latched in the history bucket with nothing selected.
    // Without the clause in some form the oracle would accept "no target while
    // a targetable item is foreground", i.e. an edit target available and the
    // walk failing to find it.
    assert(empty == (stateCanBePrimary == 0),
        "primary is null exactly when no item with a selection state can be "
        ~ "the edit target (task 0671)");
    // …and it really is the WALK's head, not merely some candidate. This is
    // the clause that would catch a `primary` re-implemented as anything other
    // than `nthEditTargetCandidate(0)`.
    assert(prim is testEditTargetCandidate(d, 0),
        "the edit target is the head of the foreground walk (task 0671)");
    // NIT: `anyCanBePrimary` is already implied by `primaryInLayers` + the
    // `canBePrimary` assertion just below (primary is itself a layer that
    // can be primary), so it cannot currently fail independently. Kept
    // anyway — it documents the invariant directly and is free if the two
    // facts it depends on are ever decoupled by a future change.
    //
    // SF3 (review round 2): this oracle must key on the CAPABILITY
    // (`canBePrimary`), not on mesh-ness (`hasMesh`) — every refuse path in
    // `exclusiveSelect` / `rehomePrimary` / `anotherPrimaryCandidate` keys
    // on `canBePrimary`, and today the two coincide only because `Mesh` is
    // the sole `canBePrimary` kind. A future kind with a mesh but barred
    // from being the edit target (e.g. read-only reference geometry) would
    // silently decouple a `hasMesh`-keyed oracle from the invariant it is
    // meant to guard.
    assert(anyCanBePrimary, "at least one layer can be primary (document invariant, task 0615)");
    assert(empty || kindInfo(prim.kind).canBePrimary,
        "primary can always be primary (task 0615, §Q2)");
    // activeIndex (derived) tracks the primary by identity — and answers the
    // OUT-OF-RANGE sentinel, never `0`, when there is no primary (task 0654).
    if (empty)
        assert(d.activeIndex == d.layers.length,
            "activeIndex is the absent-sentinel when there is no primary (task 0654)");
    else
        assert(d.layers[d.activeIndex] is prim, "activeIndex points at primary");
}

// Build a 3-layer document A/B/C, A primary+selected (SET-of-one), for the
// mutator tests. All meshes default-constructed (geometry irrelevant here).
private Document threeLayerDoc() {
    Mesh m;
    auto doc = Document.bootstrap(m);          // Layer 1 (A) selected primary
    auto b = new Layer; b.name = "B"; doc.layers ~= b;
    auto c = new Layer; c.name = "C"; doc.layers ~= c;
    doc.setActive(0);                          // A primary, B/C deselected
    return doc;
}

unittest {  // mode:set is exclusive — equals today's setActive behaviour.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is b, "set makes the target primary");
    assert(b.selected && !a.selected && !c.selected, "set is exclusive");
    size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
    assert(sel == 1, "set leaves exactly one selected");
}

unittest {  // mode:add accumulates selection; the target stays on the HEAD.
    // TASK 0671 — INTENT CHANGE. This case used to assert "add promotes the
    // newest to primary", which is the reading a stored pointer invites and
    // which the reference contradicts: with `set B; add A` the target is B,
    // the EARLIER one. The current selection is a queue and the target is its
    // head, so an add appends and changes nothing about who is being edited.
    // (Frozen: `tests/fixtures/edit_target_legality.json`, cell
    // `flush_is_per_item_kind` step 3, whose `foreground_order` column pins
    // the order this test reads through `foregroundLayersInto`.)
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Add);
    assertDocInvariants(doc);
    assert(a.selected && b.selected && !c.selected, "add keeps prior selection");
    assert(doc.primary is a, "add does NOT promote — the target is the head, A");
    assert(doc.focusedItem is b, "…but the FOCUS is the newest touch, B");
    doc.selectItem(c, SelMode.Add);
    assertDocInvariants(doc);
    assert(a.selected && b.selected && c.selected, "three selected (multi-foreground)");
    assert(doc.primary is a, "still the head");
    Layer[] fg;
    doc.foregroundLayersInto(fg);
    assert(fg.length == 3 && fg[0] is a && fg[1] is b && fg[2] is c,
        "the foreground list is the selection queue in SEAT order, and the "
        ~ "target is its head — one walk, two questions");
}

unittest {  // mode:add in REVERSE layer order: seat order, not `layers` order.
    // The discriminating rig for the ordering law. `set C; add A` selects the
    // LAST layer first, so an implementation that reads `layers` order answers
    // A and the seat order answers C. Without this, both readings agree on
    // every ascending rig above.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], c = doc.layers[2];
    doc.selectItem(c, SelMode.Set);
    doc.selectItem(a, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.primary is c,
        "the target is the earliest SELECTED, not the earliest LISTED — a "
        ~ "`layers`-order walk answers A here");
    Layer[] fg;
    doc.foregroundLayersInto(fg);
    assert(fg.length == 2 && fg[0] is c && fg[1] is a,
        "…and the list is in the same order the target was picked from");
}

unittest {  // mode:remove of the target: CURRENT outranks HISTORY.
    // TASK 0671 — the case that separates "history is a second queue" from
    // "history is just more of the first". The removed item keeps a non-zero
    // selection state and its seat (1, the earliest of the three), so a walk
    // that merged the two lists by seat would put it back at the head and the
    // target would never move off a deselected layer. It does not: the walk
    // runs CURRENT to exhaustion first, so the target promotes to B — and the
    // latched A is still in the list, just last.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A is the head
    doc.selectItem(c, SelMode.Add);            // A,B,C selected; A is the head
    doc.selectItem(a, SelMode.Remove);         // remove the TARGET
    assertDocInvariants(doc);
    assert(!a.selected, "A deselected");
    assert(doc.selectionState(a) == SelState.History, "…into the mesh bucket");
    assert(doc.primary is b,
        "the target promoted to the first remaining CURRENT item, even though "
        ~ "the latched A holds an earlier seat — a seat-only merge answers A");
    Layer[] fg;
    doc.foregroundLayersInto(fg);
    assert(fg.length == 3 && fg[0] is b && fg[1] is c && fg[2] is a,
        "the WALK is current-then-history: B, C, then the latched A");
    assert(doc.primary is fg[0], "…and the target is the head of it");
}

unittest {  // mode:remove of a NON-target keeps the target.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A target, B focus
    doc.selectItem(b, SelMode.Remove);         // remove the non-target, focused B
    assertDocInvariants(doc);
    assert(!b.selected && a.selected, "B deselected, A remains");
    assert(doc.primary is a, "the target is unchanged on a non-target remove");
    assert(doc.focusedItem is a, "focus fell back to the remaining current item");
}

unittest {  // S3: selectItem(Remove) must re-home focus ONLY when the
            // removed layer itself held focus — an unrelated, still-
            // selected, still-valid focus must survive. Behavioural check
            // (which layer focus is on after the sequence), not just an
            // invariant pass — assertDocInvariants alone cannot see this.
            //
            // NIT (review round 2): reach the split state (primary !=
            // focusedItem) through REAL mutators, not a raw `doc.focusedItem
            // = …` field write — no mutator can produce that split on an
            // all-mesh document (every mutator keeps primary/focusedItem in
            // lockstep when every layer can be primary). The mixed-document
            // fixture reaches the identical split legitimately: Add on a
            // non-mesh layer moves focus without moving primary (§L2).
    auto doc = mixedDoc();                     // [meshA(primary+focus), empty, meshB]
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.selectItem(meshB, SelMode.Add);        // meshA, meshB selected; meshB primary+focus
    doc.setPrimary(meshA);                     // primary+focus back to meshA
    doc.selectItem(empty, SelMode.Add);        // + empty selected; focus->empty, primary stays meshA
    assertDocInvariants(doc);
    assert(doc.primary is meshA && doc.focusedItem is empty && meshB.selected);
    // Discriminating check for `isFocused` (review round): the bootstrap
    // unittest's `isFocused` checks pass even if the predicate were
    // mis-written to compare against the edit target (`primary`/`active()`)
    // instead of `focusedItem`, because on an all-mesh document the two
    // coincide. Here they deliberately do NOT: meshA is primary but must NOT
    // be focused, empty holds focus but is NOT primary.
    assert(!doc.isFocused(meshA), "isFocused: the mesh primary is not the focus here");
    assert(doc.isFocused(empty),  "isFocused: the non-mesh item holds the focus here");

    doc.selectItem(meshB, SelMode.Remove);     // remove meshB: neither primary(meshA) nor focus(empty)
    assertDocInvariants(doc);
    assert(!meshB.selected, "meshB deselected");
    assert(doc.primary is meshA, "primary untouched by an unrelated remove");
    assert(doc.focusedItem is empty, "focus untouched by an unrelated remove");
}

unittest {  // mode:remove of the LAST selected EMPTIES the selection (task 0654)
            // — and KEEPS the edit target (task 0671).
    // ~~INTENT CHANGE, not a repaired test. This case used to assert the exact
    // opposite ("cannot deselect the last selected layer") because the ≥1
    // invariant made emptying unrepresentable. 0653 measured the reference —
    // ctrl-clicking the last selected item empties — and the owner decided we
    // follow it, so the old assertion is now pinning behaviour we deliberately
    // removed.~~
    //
    // SECOND INTENT CHANGE (task 0671), and it is the half 0653 could not see.
    // 0653 measured that the SELECTION empties; the line that followed it here
    // ("and drops the primary with it") was never measured — it was forced,
    // because in the model of the day there was nowhere else for the target to
    // live. 0670 read the mechanism: deselecting MOVES the item into its
    // kind's history bucket, its selection state stays non-zero, and the walk
    // still finds it. So the selection empties and the mesh is still the thing
    // you are editing.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0];
    doc.selectItem(a, SelMode.Remove);         // A is the only selected
    assertDocInvariants(doc);
    assert(!a.selected, "removing the last selected layer deselects it (task 0654)");
    assert(doc.selectedItemCount() == 0, "the item selection is empty");
    assert(doc.focusedItem is null, "the FOCUS goes with the selection — it is the "
        ~ "current list's pointer and the current list is empty");
    assert(doc.selectionState(a) == SelState.History,
        "…and A moved into the mesh history bucket rather than out of existence");
    // POPULATION FLOOR for the oracle's storage clause (4120 review). The
    // oracle asserts the NEGATIVE — no CURRENT item also sits in its kind's
    // bucket — and that is satisfied by an empty bucket just as happily as by
    // a correct one, over every document in this file. This is the one place
    // that pins the other side: A has just been deselected, so the bucket it
    // reads is known non-empty and known to hold exactly A. Take this away and
    // `testHistoryBucketHolds` is never once observed returning true.
    assert(testHistoryBucketHolds(doc, a),
        "the deselect really wrote A into its kind's history bucket — the "
        ~ "STORAGE, not `selectionState`'s current-first resolution of it");
    foreach (other; doc.layers[1 .. $])
        assert(!testHistoryBucketHolds(doc, other),
            "…and only A: a bucket that swallowed the untouched layers would "
            ~ "satisfy the line above for the wrong reason");
    // POPULATION FLOOR for that loop, and it is the same defect one level
    // down (4120 re-review): the loop is non-empty only because
    // `threeLayerDoc()` happens to build three layers, so a fixture that
    // built one would leave the "and only A" clause passing over nothing —
    // green before the swallow and green after it. Kept BELOW the loop so
    // the mutation line numbers already recorded for this cell still point
    // at the asserts they were taken from.
    assert(doc.layers.length == 3,
        "the `only A` loop above had two other layers to reject");
    assert(doc.primary is a && doc.hasEditTarget(),
        "task 0671: the edit target is the head of [current ++ history], so it "
        ~ "is still A. A model that read `selected` would answer null here.");
    assert(doc.foreground(a),
        "…and A draws as FOREGROUND, not as a dimmed background layer being "
        ~ "silently edited — the objection 0668 raised, answered");
    assert(doc.activeIndex == 0, "activeIndex follows the latched target");
    assert(doc.activeMesh() !is null, "there is a mesh to bind");
}

unittest {  // the absent edit target, reached the way the reference reaches it
            // (task 0671): every mesh's bucket flushed, then the holder gone.
    //
    // WHY NOT `clearItemSelection` ANY MORE: it does not produce this state, it
    // produces the LATCHED one (the unittest above). Building the no-target
    // state now takes a document in which no `canBePrimary` item has any
    // selection state at all — here, one assembled without ever selecting.
    Document doc;
    auto a = new Layer; a.name = "A";
    auto b = new Layer; b.name = "B";
    doc.layers = [a, b];
    assertDocInvariants(doc);
    assert(doc.primary is null && !doc.hasEditTarget(),
        "nothing has a selection state, so the walk is empty");
    assert(doc.focusedItem is null, "and nothing is selected");
    // The absent-sentinel, spelled out: a consumer that indexes `layers` with
    // this gets a bounds error, not layer 0's geometry.
    assert(doc.activeIndex == doc.layers.length,
        "activeIndex is the absent-sentinel, NOT 0");
    assert(doc.activeMesh() is null, "activeMesh() refuses by returning null");
    bool threw = false;
    try { doc.activeMeshRef(); } catch (NoEditTargetException) { threw = true; }
    assert(threw, "activeMeshRef() refuses by throwing NoEditTargetException");
    // Both are BACKGROUND — this is what "everything dims" looks like, and it
    // is a different state from the latched one above where A is foreground.
    foreach (l; doc.layers)
        assert(doc.background(l) && !doc.foreground(l),
            "with no selection state anywhere, every visible layer is background");
    // …and it is not a trap: one select recovers.
    doc.selectItem(b, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is b && doc.hasEditTarget(),
        "a select out of the no-target state installs a target again");
}

unittest {  // clearItemSelection empties the SELECTION in one transition, is
            // idempotent, and LEAVES THE EDIT TARGET (task 0671).
    auto doc = threeLayerDoc();
    doc.selectItem(doc.layers[1], SelMode.Add);   // {A, B}
    assert(doc.selectedItemCount() == 2, "precondition: two selected");
    assert(doc.primary is doc.layers[0],
        "precondition: the target is the queue HEAD (A, selected first), not "
        ~ "the newest addition — task 0671");
    doc.clearItemSelection();
    assertDocInvariants(doc);
    assert(doc.selectedItemCount() == 0 && doc.focusedItem is null,
        "clear empties the whole set at once");
    doc.clearItemSelection();                     // idempotent
    assertDocInvariants(doc);
    assert(doc.selectedItemCount() == 0, "clearing an empty selection is a no-op");
    // TASK 0671 — the target survived, and it is still the head of the same
    // order: both A and B went into the mesh bucket, A was seated first.
    assert(doc.primary is doc.layers[0],
        "an empty item selection with a live edit target is a LEGAL state "
        ~ "(frozen fixture edit_target_legality / target_set_nothing_selected)");
    assert(doc.foreground(doc.layers[0]) && doc.foreground(doc.layers[1]),
        "…and both latched meshes are foreground: two foreground layers with "
        ~ "nothing selected, which is the walk's own answer and not a special case");
    assert(doc.background(doc.layers[2]),
        "the mesh that was never selected is background — the negative control, "
        ~ "without which 'everything is foreground' would pass here");
    // Selecting again re-flushes the bucket, so the latch does not accumulate.
    doc.selectItem(doc.layers[2], SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is doc.layers[2] && doc.hasEditTarget(),
        "a select out of the empty state installs a primary again");
    assert(doc.foregroundLayerCount() == 1,
        "…and exactly one: selecting a MESH flushes the mesh bucket, so the two "
        ~ "latched layers are gone from the walk rather than joining it");
}

unittest {  // mode:toggle flips selection (remove ↔ add).
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Toggle);         // B not selected → add
    assertDocInvariants(doc);
    // TASK 0671 — `add` does NOT promote. The target is the queue head, and A
    // was seated first. This line used to read `doc.primary is b`.
    assert(b.selected && doc.primary is a,
        "toggle-on selects, and the target stays on the earlier-seated A");
    doc.selectItem(b, SelMode.Toggle);         // B selected → remove
    assertDocInvariants(doc);
    assert(!b.selected, "toggle-off deselects");
    assert(doc.primary is a, "the target was on A throughout");
}

unittest {  // setPrimary RE-SEATS an already-selected member at the front.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A is the head
    assert(doc.primary is a, "precondition: the head is A (task 0671)");
    doc.setPrimary(b);                         // re-seat B at the front
    assertDocInvariants(doc);
    assert(a.selected && b.selected, "set is preserved");
    assert(doc.primary is b, "setPrimary moved the edit target to B");
    assert(doc.selectedItemCount() == 2, "…without deselecting anyone");
    // setPrimary on a not-yet-selected layer selects it (focus invariant).
    auto c = doc.layers[2];
    doc.setPrimary(c);
    assertDocInvariants(doc);
    assert(c.selected && doc.primary is c, "setPrimary selects + re-seats");
    assert(doc.selectedItemCount() == 3, "…and still does not deselect anyone");
}

unittest {  // TASK 0671 — HIDING THE EDIT TARGET DOES NOT MOVE IT.
    // ~~hide-primary promotion: setVisible(false) on primary moves it.~~
    // ~~S2: hiding the primary must not steal focus from an unrelated item.~~
    // ~~hide-primary refusal: no other selected+visible layer.~~
    //
    // Three cases retired into one, because the behaviour all three pinned was
    // an artefact of `foreground(l) == visible && selected`: a hidden primary
    // was neither foreground nor background, so it HAD to be handed on or the
    // hide had to be refused. Measured (`tests/fixtures/
    // edit_target_legality.json`, cell `hidden_mesh_keeps_the_target`) the
    // reference does neither — visibility and targethood are independent, and
    // its own classifier says so: the hidden arm keeps a targetable item
    // FOREGROUND instead of dropping it. `promoteAwayFromHiddenPrimary` is now
    // the constant `true` and this is what replaces its three tests.
    //
    // The CONTROL is the third block: the target still moves normally when a
    // different mesh is selected, so the first two are not a frozen read.
    auto doc = threeLayerDoc();
    auto a = doc.layers[0], b = doc.layers[1];
    doc.selectItem(b, SelMode.Add);            // A,B selected; A is the head
    assert(doc.primary is a, "precondition: A holds the target");

    a.visible = false;                         // hide the TARGET
    assert(doc.promoteAwayFromHiddenPrimary(), "hiding is never refused now");
    assertDocInvariants(doc);
    assert(doc.primary is a,
        "THE MEASUREMENT: a hidden layer is still the edit target — B does not "
        ~ "inherit it, and the hide is not refused");
    assert(doc.foreground(a),
        "…and it classifies FOREGROUND while hidden, which is what stops the "
        ~ "walk skipping it");
    assert(doc.roleOf(a) != LayerRole.Background,
        "…and specifically NOT background: it must not become a dimmed snap "
        ~ "source while it is the thing being edited");
    assert(doc.focusedItem is b, "the focus is untouched by any of this");

    // A hidden mesh with NO selection state is not a layer at all — the
    // negative control for the arm above, which would otherwise pass for an
    // implementation that made every hidden mesh foreground.
    auto c = doc.layers[2];
    c.visible = false;
    assert(doc.roleOf(c) == LayerRole.None,
        "a hidden item with no selection state is neither foreground nor "
        ~ "background — the reference's 'none of those' state");

    // CONTROL: the target still moves.
    doc.selectItem(b, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is b, "CONTROL: selecting another mesh moves the target");
    assert(!doc.foreground(a),
        "…and the hidden former target loses its state entirely, because "
        ~ "selecting a mesh FLUSHES the mesh bucket");
}

// ---------------------------------------------------------------------------
// Task 0615 Stage 1: `ItemKind` + the capability table. Pure lookups — no
// `Document` involved yet.
// ---------------------------------------------------------------------------




unittest {  // a default-constructed Layer is a mesh item.
    auto l = new Layer;
    assert(l.kind == ItemKind.Mesh, "new Layer defaults to ItemKind.Mesh");
    assert(l.hasMesh, "a default Layer has a mesh");
    assert(l.meshOrNull !is null, "meshOrNull is non-null for a mesh item");
    assert(cast(size_t) l.meshOrNull == testMeshFieldAddr(l),
        "meshOrNull points at the mesh field");
    assert(cast(size_t) &l.meshRef() == testMeshFieldAddr(l),
        "meshRef() aliases the same mesh field");
}


// ---------------------------------------------------------------------------
// Task 0616 Stage 2, T2 (capability-row half): `kindInfo(ItemKind.Image)`
// field by field, and the image-payload accessor trio (mirrors the mesh
// trio tests just above).
// ---------------------------------------------------------------------------


unittest {  // hasImage()/imageOrNull()/imageRef() mirror the mesh trio: a
            // non-image item reports no image through the capability
            // accessors, and an image item's imageRef() aliases the same
            // field imageOrNull() reads.
    auto mesh = new Layer;
    assert(!mesh.hasImage, "a default (mesh-kind) Layer has no image capability");
    assert(mesh.imageOrNull is null, "imageOrNull is null for a non-image item");

    auto img = new Layer;
    img.kind = ItemKind.Image;
    assert(img.hasImage, "an Image-kind layer has the image capability");
    // Freshly kind-flipped, no payload constructed yet — capability true,
    // instance payload still null (mirrors "hasMesh answers CAN, not DOES").
    assert(img.imageOrNull is null, "imageOrNull is null until something constructs an ImageData");

    img.imageRef() = new ImageData();

    // A fresh `ImageData`'s FIELD INITIALISERS, read before anything
    // overwrites them. These are reference-measured contract values (see the
    // `ImageData` declaration above), and until this assertion existed a typo
    // in either initialiser was invisible to the whole suite: the param
    // `default_` that layer_params.d declares is an INDEPENDENT literal in a
    // different module, so `bool useAlpha = false;` here would have kept every
    // param-side default assertion green while silently changing what a newly
    // constructed image item means. `storedPath` needs no such line — it has
    // no initialiser (empty is `string.init`) and is overwritten below.
    assert(img.imageOrNull.colorspace == "(default)",
        "a fresh ImageData initialises colorspace to '(default)'");
    assert(img.imageOrNull.useAlpha == true,
        "a fresh ImageData initialises useAlpha to true");

    img.imageRef().storedPath = "logo.png";
    assert(img.imageOrNull !is null, "imageOrNull is non-null once imageRef() is assigned");
    assert(img.imageOrNull.storedPath == "logo.png", "imageOrNull aliases the same object imageRef() wrote");
    assert(cast(size_t) &img.imageRef() == testImageFieldAddr(img),
        "imageRef() aliases the same image_ field");
}

// ---------------------------------------------------------------------------
// Task 0615 Stages 3 / 3b: the mesh-primary rule (§Q2), the L2 exclusive-
// select formula, and the L1 `rehomePrimary` promotion algorithm — all
// exercised over a MIXED document, which no test before this task could
// build (see plan §Lifecycle invariants, R14).
// ---------------------------------------------------------------------------

/// [MeshA(primary), Empty, MeshB] — the fixture the plan's L1/L2 walkthroughs
/// use, built directly against the type API (no command layer involved).
private Document mixedDoc() {
    Mesh m;
    auto doc = Document.bootstrap(m);           // "Layer 1" == MeshA
    doc.layers[0].name = "MeshA";
    auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB";
    doc.layers ~= empty;
    doc.layers ~= meshB;
    doc.setActive(0);                            // MeshA primary+focused
    return doc;
}

unittest {  // Stage 3: selecting a non-mesh item (mode:add) moves focus,
            // never primary, and never deselects the mesh primary.
            //
            // TASK 0668 kept this law and inverted only `Set`'s. The pair is
            // the point: without an `Add` row asserting the OPPOSITE outcome,
            // 0668's fix could have been written as "a non-mesh selection
            // never has a primary", which would also drop the edit target on
            // a ctrl-click — where the user is adding to a selection, not
            // replacing it.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1];
    assert(doc.primary is meshA && doc.focusedItem is meshA);

    doc.selectItem(empty, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.focusedItem is empty, "Add on a non-mesh item moves focus");
    assert(doc.primary is meshA, "Add on a non-mesh item never moves primary");
    assert(meshA.selected, "the mesh primary stays selected under Add");
    size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
    assert(sel == 2, "and the set GREW to {meshA, empty} — Add is not Set");
}

unittest {  // TASK 0668 — this INVERTS Stage 3 / L2, which asserted the
            // opposite ("exclusive select of a non-mesh item must not evict
            // the mesh primary"). That law was forced by the pre-0654
            // invariants, not chosen: with a non-null selected primary
            // mandatory, sparing the mesh was the only representable answer.
            // 0654 made an absent primary legal, so exclusive is exclusive for
            // every kind. Both entry points that implement it are covered
            // (selectItem(Set) and setActive).
            //
            // The COUNT is the load-bearing assertion. "The target is
            // selected" passed under the old law too — only `sel == 1`
            // separates "cleared all others" from "cleared none", and the
            // fixture has THREE layers so it also separates it from "cleared
            // exactly one".
    // TASK 0671 — BOTH HALVES AT ONCE, which is the whole point of the task.
    // 0668 bought the reference's selected SET (the non-mesh item ALONE) by
    // spending the edit target; 0670 read the mechanism and there was never a
    // trade to make. Deselecting the mesh moves it into the MESH bucket;
    // selecting the non-mesh item flushes the item's OWN bucket and leaves the
    // mesh one standing; so the set is `{target}` AND the mesh is still the
    // thing being edited. This is `tests/fixtures/layer_main_latched.json`
    // rows 3 and 5, in a unit test.
    static void check(Document doc, Layer meshA, Layer empty) {
        assertDocInvariants(doc);
        assert(doc.primary is meshA,
               "0671: the edit target stays LATCHED on the last-selected mesh");
        assert(!meshA.selected,
               "0668, kept: the exclusive select is exclusive — the mesh is "
               ~ "DESELECTED, not spared, so the SET matches the reference");
        assert(doc.selectionState(meshA) == SelState.History,
               "…and what it became is HISTORY, not nothing: one bucket, and "
               ~ "the non-mesh selection could not reach it");
        assert(doc.foreground(meshA) && !doc.background(meshA),
               "…so it draws FOREGROUND. A latched target that derived as "
               ~ "BACKGROUND — dimmed, read-only, a snap source — while the "
               ~ "toolpipe wrote to it is the state 0668 refused to represent, "
               ~ "and it is not what the reference does either.");
        assert(empty.selected && doc.focusedItem is empty,
               "the target is selected and becomes the focus");
        size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
        assert(sel == 1, "the selected set is exactly {target}");
        assert(doc.hasEditTarget() && doc.activeMesh() !is null,
               "every edit-target accessor answers, because there IS one");
        assert(doc.activeIndex == doc.indexOf(meshA),
               "and activeIndex names the latched mesh");
        // The OTHER mesh in the fixture never had a selection state, so it is
        // background — without this row "everything is foreground" would pass.
        assert(doc.foregroundLayerCount() == 1,
               "exactly one foreground layer: the latched mesh. The non-mesh "
               ~ "item is not a candidate and MeshB never had a state.");
    }

    auto d1 = mixedDoc();
    d1.selectItem(d1.layers[1], SelMode.Set);
    check(d1, d1.layers[0], d1.layers[1]);

    auto d2 = mixedDoc();
    d2.setActive(1);
    check(d2, d2.layers[0], d2.layers[1]);
}

unittest {  // TASK 0671 — the round trip, and the LATCH MOVES.
            // ~~0668: selecting a mesh again RESTORES the edit target.~~ There
            // is nothing to restore now; what this has to show instead is that
            // the latched value is not pinned to one layer — it follows
            // whichever mesh was selected last. Two meshes are what make that
            // observable at all (`layer_main_latched`'s own premise note).
    auto doc = mixedDoc();                           // [MeshA, Empty, MeshB]
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.selectItem(empty, SelMode.Set);              // plane-alike alone
    assert(doc.primary is meshA, "precondition: latched on MeshA");
    doc.selectItem(meshB, SelMode.Set);              // the OTHER mesh
    assertDocInvariants(doc);
    assert(doc.primary is meshB && doc.focusedItem is meshB,
        "selecting a mesh moves both the target and the focus");
    assert(!meshA.selected && doc.selectionState(meshA) == SelState.None,
        "…and FLUSHES the mesh bucket, so the previously latched MeshA loses "
        ~ "its state entirely rather than accumulating beside MeshB");
    assert(doc.background(meshA), "…which is what makes it background again");
    doc.selectItem(empty, SelMode.Set);              // and latch again
    assertDocInvariants(doc);
    assert(doc.primary is meshB,
        "the latch re-arms on the OTHER mesh — so it is the last mesh selected, "
        ~ "not a value pinned to one particular layer");
    assert(!doc.layers[2].selected, "and the non-mesh item is the whole set");
}

unittest {  // Stage 3: the walk SKIPS the non-mesh candidate, in both queues.
    // TASK 0671 — the mechanism changed under this test and its point did not:
    // a non-mesh item must never end up as the edit target, whichever list it
    // is sitting in. The old rig reached the question through a promotion that
    // no longer happens, so the rig moved; the negative it asserts did not.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.setPrimary(meshB);                       // meshB seated at the front
    doc.selectItem(empty, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.primary is meshB, "precondition: meshB heads the current queue");
    // Drop BOTH meshes, leaving the non-mesh item as the only CURRENT one.
    doc.selectItem(meshB, SelMode.Remove);
    doc.selectItem(meshA, SelMode.Remove);
    assertDocInvariants(doc);
    assert(!meshA.selected && !meshB.selected && empty.selected,
        "the non-mesh item is now the entire current selection");
    assert(doc.primary !is empty && doc.primary !is null,
        "the target is never the non-mesh item — the walk filters on the "
        ~ "capability in BOTH stages, not just in the current one");
    assert(doc.primary is meshB,
        "…and it is the front-seated meshB, which is the head of the history "
        ~ "queue for the same reason it was the head of the current one");
}

unittest {  // Stage 3: setPrimary on a non-mesh item selects it and moves
            // focus, but refuses to move primary and deselects no one.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1];
    doc.setPrimary(empty);
    assertDocInvariants(doc);
    assert(empty.selected, "setPrimary selects the target");
    assert(doc.focusedItem is empty, "setPrimary moves focus");
    assert(doc.primary is meshA, "setPrimary refuses to move primary onto a non-mesh item");
    assert(meshA.selected, "setPrimary must not deselect the prior primary");
}

unittest {  // Stage 3b / L1, RED-before-fix. Fixture from the plan:
            // [MeshA(primary), Empty, MeshB]; splice out MeshA (index 0). The
            // pre-revision wording picks the successor by ARRAY POSITION
            // (`setActive(0)`), landing on Empty — which then leaves `primary`
            // dangling on the spliced-out MeshA. `rehomePrimary` must instead
            // skip Empty and land on MeshB.
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.layers = [empty, meshB];                 // MeshA spliced out at index 0
    auto survivor = doc.rehomePrimary(0);
    assert(survivor is meshB, "forward scan from the vacated slot skips Empty");
    // SF3 (review round 2): assert the CAPABILITY (`canBePrimary`), not
    // mesh-ness (`hasMesh`) — see `assertDocInvariants`'s matching fix.
    assert(kindInfo(survivor.kind).canBePrimary, "the survivor can always be primary");

    // Close the loop the way the eventual LayerDelete caller will (Stage 6,
    // plan §L1: `doc.setActive(doc.indexOf(survivor))` — `survivor` is
    // `canBePrimary` by construction, so `setActive` takes its unchanged
    // all-mesh branch and genuinely selects it).
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
    assert(doc.primary is survivor, "primary now names the rehomed survivor");
    assert(doc.layers[doc.activeIndex] is doc.primary,
           "activeIndex now resolves correctly — false under the old positional wording");
}

unittest {  // Stage 3b: removing the layer at the TAIL falls back to a
            // backward scan; matches the plan's [MeshA, Empty, MeshB(primary)].
    auto doc = mixedDoc();
    auto meshA = doc.layers[0], empty = doc.layers[1], meshB = doc.layers[2];
    doc.setActive(2);                            // MeshB becomes primary
    assertDocInvariants(doc);
    doc.layers = [meshA, empty];                 // MeshB spliced out at index 2
    auto survivor = doc.rehomePrimary(2);
    assert(survivor is meshA, "backward scan over [MeshA, Empty] finds MeshA");

    // NIT: close the loop the same way the forward-scan test above does —
    // leaving the fixture un-set-active'd would violate L1 (primary would
    // still name the spliced-out MeshB) even though the pure `rehomePrimary`
    // query itself already answered correctly.
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
    assert(doc.primary is survivor, "primary now names the rehomed survivor");
}

unittest {  // Stage 3b: an all-mesh document is the DEGENERATE case and must
            // match today's exact positional rule
            // (`commands/layer/commands.d:420-421`), at both `at` extremes.
    auto doc = threeLayerDoc();                  // A(primary), B, C — all mesh
    auto a = doc.layers[0], b = doc.layers[1], c = doc.layers[2];

    Document afterRemoveHead = doc;
    afterRemoveHead.layers = [b, c];             // A spliced out at index 0
    assert(afterRemoveHead.rehomePrimary(0) is b, "degenerate case == layers[at]");

    Document afterRemoveTail = doc;
    afterRemoveTail.layers = [a, b];             // C spliced out at index 2
    assert(afterRemoveTail.rehomePrimary(2) is b, "degenerate case == layers[$-1]");
}

unittest {  // NIT: rehomePrimary — a genuinely INTERIOR removal, where the
            // forward scan must step over more than one non-primary
            // candidate before it succeeds (previous tests found the
            // survivor on the very first element checked).
    Mesh m;
    auto doc = Document.bootstrap(m);
    doc.layers[0].name = "MeshA";
    auto loc1  = new Layer; loc1.name  = "Loc1";  loc1.kind  = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB";
    auto loc2  = new Layer; loc2.name  = "Loc2";  loc2.kind  = ItemKind.Empty;
    auto meshC = new Layer; meshC.name = "MeshC";
    doc.layers ~= [loc1, meshB, loc2, meshC];
    doc.setActive(2);                            // MeshB primary
    assertDocInvariants(doc);

    doc.layers = [doc.layers[0], loc1, loc2, meshC]; // MeshB spliced out at index 2
    auto survivor = doc.rehomePrimary(2);
    assert(survivor is meshC, "interior forward scan steps over Loc2 to find MeshC");
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
}

unittest {  // NIT: rehomePrimary — forward scan finds nothing at all,
            // forcing a genuinely multi-step BACKWARD scan from an interior
            // position (not just the immediate predecessor).
    Mesh m;
    auto doc = Document.bootstrap(m);
    doc.layers[0].name = "MeshA";
    auto loc1  = new Layer; loc1.name  = "Loc1";  loc1.kind  = ItemKind.Empty;
    auto meshB = new Layer; meshB.name = "MeshB";
    auto loc2  = new Layer; loc2.name  = "Loc2";  loc2.kind  = ItemKind.Empty;
    auto loc3  = new Layer; loc3.name  = "Loc3";  loc3.kind  = ItemKind.Empty;
    doc.layers ~= [loc1, meshB, loc2, loc3];
    doc.setActive(2);                            // MeshB primary
    assertDocInvariants(doc);

    doc.layers = [doc.layers[0], loc1, loc2, loc3];  // MeshB spliced out at index 2
    auto survivor = doc.rehomePrimary(2);
    assert(survivor is doc.layers[0],
        "forward scan finds nothing; backward scan steps over Loc1 to MeshA");
    doc.setActive(doc.indexOf(survivor));
    assertDocInvariants(doc);
}


unittest {  // Stage 3b: indexOf resolves by identity; absent ⇒ layers.length.
    auto doc = mixedDoc();
    assert(doc.indexOf(doc.layers[1]) == 1);
    assert(doc.indexOf(doc.layers[2]) == 2);
    auto stray = new Layer;
    assert(doc.indexOf(stray) == doc.layers.length, "absent layer ⇒ layers.length sentinel");
}

// ---------------------------------------------------------------------------
// Task 0614 Phase 6: `selectedItemsInto` is the SOLE answer to "which items
// does an item-mode gesture act on". Four properties, each of which a
// plausible alternative implementation gets wrong:
//   * membership is `selected`, and NOTHING else — a non-mesh item that can
//     never be primary is in the set (that is the whole point of Phase 6),
//     and a HIDDEN selected item stays in it (see the accessor's own note on
//     why `foreground()` is the wrong predicate here);
//   * order is `layers` order, deterministically — the undo payload's
//     first-touch union is built on it;
//   * the buffer is reused, so a SHRINK must not leave a stale tail visible
//     through `length` (an implementation that only ever grows the buffer
//     reads three entries where two are selected);
//   * a single-selection document yields exactly the primary.
// ---------------------------------------------------------------------------

unittest {  // selectedItemsInto — membership, order, and buffer reuse.
    import std.conv : to;
    auto doc = mixedDoc();                       // [MeshA(primary), Empty, MeshB]
    Layer[] buf;

    // Bootstrap: exactly the primary is selected.
    doc.selectedItemsInto(buf);
    assert(buf.length == 1 && buf[0] is doc.layers[0],
        "a single-selection document yields exactly the primary — got length "
        ~ buf.length.to!string);

    // A non-mesh item joins the set even though it can never be primary —
    // Phase 6 is the first thing that can transform one.
    doc.selectItem(doc.layers[1], SelMode.Add);
    doc.selectItem(doc.layers[2], SelMode.Add);
    doc.selectedItemsInto(buf);
    assert(buf.length == 3,
        "every selected item is in the moving set — got length "
        ~ buf.length.to!string);
    assert(buf[0] is doc.layers[0] && buf[1] is doc.layers[1] && buf[2] is doc.layers[2],
        "the moving set is emitted in `layers` order, deterministically");
    assert(buf[1].kind == ItemKind.Empty && !doc.isPrimary(buf[1]),
        "a non-primary, non-mesh item is a legitimate transform target");

    // Hidden but selected stays in — the deliberate divergence from
    // `foreground()`, pinned so a later `visible &&` cannot slip in unnoticed.
    doc.layers[2].visible = false;
    doc.selectedItemsInto(buf);
    assert(buf.length == 3 && buf[2] is doc.layers[2],
        "a HIDDEN but selected item stays in the moving set (`selected`, not "
        ~ "`visible && selected`) — got length " ~ buf.length.to!string);
    doc.layers[2].visible = true;

    // SHRINK through the same buffer: no stale tail may remain readable.
    doc.selectItem(doc.layers[1], SelMode.Remove);
    doc.selectItem(doc.layers[2], SelMode.Remove);
    doc.selectedItemsInto(buf);
    assert(buf.length == 1 && buf[0] is doc.layers[0],
        "the reused buffer must SHRINK to the new count — a stale tail would "
        ~ "make a de-selected item keep receiving the gesture. got length "
        ~ buf.length.to!string);
}


// ---------------------------------------------------------------------------
// Task 0612 Stage 8 — `itemTransformTarget` / `itemTransformTargets`, the walk
// of every reachable focus-vs-primary state (plan §7.2's table, driven through
// the REAL mutators rather than by writing the two pointers by hand — the
// whole claim is that the mutators keep them in lockstep on an all-mesh
// document, and a hand-written state could not have refuted it).
//
// WRONG IMPLEMENTATIONS THIS DISCRIMINATES AGAINST
//   * the pre-Stage-8 code — no narrowing at all. Reads 2 in the "plane
//     selected alone" row where the correct answer is 1, and names the MESH
//     as the target where the correct answer is the plane.
//   * "narrow to exactly the focus" (the tempting one-liner). Reads 1 in the
//     multi-mesh row, where two meshes must both move — that is the row that
//     kills it, and it is why the table has a ctrl-add-mesh step.
//   * "drop the primary whenever anything else is selected". Reads 1 in the
//     multi-mesh row too, for a different reason: there focus IS primary.
//
// The mesh-only rows are the CONTROL. They are the entire neutrality proof
// for changing what four call sites bind, so they are asserted first and
// their answers are the pre-Stage-8 answers, unchanged.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;
    Document doc;
    auto meshA = new Layer;  meshA.name = "A";
    auto meshB = new Layer;  meshB.name = "B";
    auto plane = new Layer;  plane.name = "P"; plane.kind = ItemKind.ImagePlane;
    auto plane2 = new Layer; plane2.name = "P2"; plane2.kind = ItemKind.ImagePlane;
    doc.layers = [meshA, meshB, plane, plane2];
    doc.selectItem(meshA, SelMode.Set);

    Layer[] buf;
    string names() {
        string s;
        foreach (i, l; buf) { if (i) s ~= ","; s ~= l.name; }
        return "{" ~ s ~ "}";
    }

    // --- CONTROL: an all-mesh document is bit-for-bit what it always was ---
    testExclusiveSelect(doc, meshA);
    assert(doc.itemTransformTarget() is meshA && doc.itemTransformTarget() is doc.primary,
        "all-mesh control: the target IS the primary, so every measured L2 "
        ~ "centre is preserved");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is meshA, "select mesh A ⇒ {A}, got " ~ names());

    doc.selectItem(meshB, SelMode.Add);          // ctrl-add a second MESH
    // TASK 0671 — the two pointers no longer move in lockstep here: `Add`
    // appends to the selection queue and the target is the queue's HEAD, so
    // the focus lands on B while A keeps the target. This line used to read
    // `doc.primary is meshB`, and it is exactly that lockstep going away that
    // made approximation D's `target !is primary` condition wrong — see
    // `itemTransformTargets`. The row below is what would have caught it.
    assert(doc.primary is meshA && doc.focusedItem is meshB,
        "Add moves the FOCUS to the newest and leaves the target on the head");
    doc.itemTransformTargets(buf);
    assert(buf.length == 2 && buf[0] is meshA && buf[1] is meshB,
        "MULTI-MESH DRAG IS UNTOUCHED: {A,B}. A 'narrow to the focus' "
        ~ "implementation reads {B} here, and so does a D whose condition is "
        ~ "still `target !is primary`. got " ~ names());
    assert(doc.isTransformTarget(meshA) && doc.isTransformTarget(meshB),
        "…and the per-layer bool agrees with the set, on both rows");

    // --- TASK 0668: the plane SELECTED ALONE, and it really is alone ------
    // This row used to open by asserting that a mesh was STILL primary and
    // STILL selected ("the document invariant FORCES the mesh to stay
    // selected — if it did not, there would be nothing for D to subtract").
    // 0668 removed the forcing from the exclusive path, so the correct answer
    // {P} now comes out of the SELECTION rather than out of approximation D.
    // The row is kept, and inverted, because it is the one a user reaches by
    // clicking a plane.
    doc.selectItem(plane, SelMode.Set);
    assert(doc.primary is meshA,
        "0671: an exclusive select of a plane leaves the mesh edit target "
        ~ "LATCHED — 0668's `is null` was the cost this task removes");
    assert(!meshA.selected && !meshB.selected,
        "…and neither mesh is spared into the selection: 0668's half is kept");
    assert(doc.itemTransformTarget() is plane,
        "the target follows the FOCUS onto the plane — the pre-Stage-8 "
        ~ "binding reads the mesh here, which is the gizmo sitting on the "
        ~ "character while the panel shows the plane's numbers");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is plane,
        "select the plane ⇒ {P} ONLY. got " ~ names());
    assert(!doc.isTransformTarget(meshA) && doc.isTransformTarget(plane),
        "…and the derived per-layer bool `/api/layers` reports agrees with "
        ~ "the set it is derived from");

    // --- ctrl-add a mesh back: recovery, and it is ONE click --------------
    doc.selectItem(meshA, SelMode.Add);
    assert(doc.focusedItem is meshA && doc.primary is meshA,
        "Add on a mesh re-homes BOTH pointers onto it");
    doc.itemTransformTargets(buf);
    assert(buf.length == 2,
        "ctrl-adding the mesh brings it back into the set. got " ~ names());

    // --- APPROXIMATION D, which 0668 did NOT retire ----------------------
    // D subtracts the primary from the moving set when it is not the
    // transform target. 0668 removed the state that made D unavoidable (a
    // plane selected by itself), but not the state D exists for: select a
    // MESH, then ctrl-ADD a plane. The mesh is genuinely selected — the user
    // asked for it — the focus is on the plane, and D is what stops the drag
    // taking the model along with the reference image. `itemTransformTargets`
    // documents this as the ONE declared divergence; `tests/
    // test_item_transform_focus.d` T-X6 pins it end to end.
    doc.selectItem(meshA, SelMode.Set);
    doc.selectItem(plane, SelMode.Add);
    assert(doc.primary is meshA && meshA.selected && plane.selected,
        "vacuity guard: the mesh is selected BY THE USER here (Add, not the "
        ~ "old forcing), or there would be nothing for D to subtract");
    assert(doc.focusedItem is plane, "…and the focus is on the plane");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is plane,
        "D: the selected-but-not-targeted primary is subtracted ⇒ {P}. The "
        ~ "ungated set reads {A,P} and drags the model with the reference "
        ~ "image. got " ~ names());

    // --- two planes over that same mesh selection ------------------------
    doc.selectItem(plane2, SelMode.Add);
    doc.itemTransformTargets(buf);
    assert(buf.length == 2 && buf[0] is plane && buf[1] is plane2,
        "P1 + P2 move together and the subtracted mesh does not — got "
        ~ names());

    // --- ctrl-REMOVE the planes: the Remove arm re-homes focus ------------
    doc.selectItem(plane2, SelMode.Remove);
    doc.selectItem(plane,  SelMode.Remove);
    assert(doc.primary is meshA && doc.focusedItem is doc.primary,
        "Remove re-homes the focus to the primary, so the narrowing lifts "
        ~ "by itself — no stored bit to go stale");
    doc.itemTransformTargets(buf);
    assert(buf.length == 1 && buf[0] is doc.primary,
        "…and the set recovers to the mesh alone. got " ~ names());
}


// ---------------------------------------------------------------------------
// Task 0615 S3 (review round 3): `meshLayers()` is the plan's primary
// mitigation for the tier the compiler cannot check — its whole claim is
// "iterating it can never yield a non-mesh layer". Exercise BOTH overload
// instantiations (mutable `This=Document`, const `This=const(Document)`)
// against the mixed fixture, so the claim is actually proved rather than
// merely asserted in a comment.
// ---------------------------------------------------------------------------

unittest {  // meshLayers() — mutable receiver.
    auto doc = mixedDoc();                       // [MeshA(primary), Empty, MeshB]
    size_t seen = 0;
    foreach (l; doc.meshLayers()) {
        assert(l.hasMesh, "meshLayers() (mutable) must never yield a non-mesh layer");
        ++seen;
    }
    assert(seen == 2, "meshLayers() (mutable) yields exactly the mesh-kind layers");
}

unittest {  // meshLayers() — const receiver, the shape every real caller uses
            // (io/scene_ir.d, io/scene_export.d, io/lwo_export.d all take
            // `const ref Document`).
    const doc = mixedDoc();
    size_t seen = 0;
    foreach (l; doc.meshLayers()) {
        assert(l.hasMesh, "meshLayers() (const) must never yield a non-mesh layer");
        ++seen;
    }
    assert(seen == 2, "meshLayers() (const) yields exactly the mesh-kind layers");
}

unittest {  // S5: selectItem/setPrimary must guard MEMBERSHIP, not just
            // null — a stray `Layer` that is not (or no longer) in `layers`
            // must be a total no-op, never installed as target/focus/primary
            // (L1: `primary`/`focusedItem` always name a layer IN `layers`).
    auto doc = threeLayerDoc();
    auto a = doc.layers[0];
    auto stray = new Layer;                    // never added to doc.layers

    doc.selectItem(stray, SelMode.Set);
    assertDocInvariants(doc);
    assert(doc.primary is a && doc.focusedItem is a, "selectItem(Set) ignores a stray layer");
    assert(!stray.selected, "selectItem never touches a stray layer's state");

    doc.selectItem(stray, SelMode.Add);
    assertDocInvariants(doc);
    assert(doc.primary is a && doc.focusedItem is a, "selectItem(Add) on a stray layer is also a no-op");

    doc.setPrimary(stray);
    assertDocInvariants(doc);
    assert(doc.primary is a && doc.focusedItem is a, "setPrimary ignores a stray layer");
}

// ---------------------------------------------------------------------------
// Task 0615, review round 2: SF1 (guard MEMBERSHIP, not just null — a STALE
// `primary`/`focusedItem` is non-null but no longer a member of `layers`)
// and SF2 (the `Add` and `setPrimary` arms must not leave `primary`
// null/stale either). The S5 tests above prove the null/absent-STRAY case;
// these prove the STALE case the earlier fix's null check cannot see.
// ---------------------------------------------------------------------------

/// SF1 fixture: a `Document` whose `primary` AND `focusedItem` are STALE —
/// non-null, but no longer members of `layers` — the exact shape a LIVE
/// `Document` reaches when a caller replaces `layers` via direct field
/// assignment before repointing `primary`. This is not a contrived state:
/// it is literally what `io/native.d`'s `.v3d` loader does today
/// (`document.layers = parsed;` at `:450`, before any mutator runs) to the
/// app's live `Document`, reused by `ref` from `commands/file/load.d:122`.
/// Returns the document plus the two GENUINE (post-swap) members: `empty`
/// (not `canBePrimary`) and `meshB` (the only `canBePrimary` survivor, so
/// the one `rehomePrimary` must land on).
private Document staleDoc(out Layer empty, out Layer meshB) {
    auto doc = mixedDoc();                  // [meshA(primary+focus), Empty, MeshB]
    empty = new Layer; empty.name = "FreshEmpty"; empty.kind = ItemKind.Empty;
    meshB = new Layer; meshB.name = "FreshMeshB";
    doc.layers = [empty, meshB];            // `primary`/`focusedItem` still name
                                             // the OLD meshA — now STALE.
    return doc;
}

unittest {  // SF1: exclusiveSelect (reached via BOTH `selectItem(Set)` and
            // `setActive`, mirroring the L2 test above) must not install a
            // STALE primary. The original hazard: the null check never fires
            // on a stale reference (it is non-null), so `primaryAfter` stayed
            // the stale layer and was written straight into `primary` — a
            // silent L1 violation.
            //
            // TASK 0668 CLOSED IT AT THE SOURCE rather than by repairing it.
            // The `: primary` branch that could carry a stale pointer into
            // `primaryAfter` is gone: `primary-after` is now either `target`
            // (checked a member) or null. So the assertion changes from "the
            // stale primary was REHOMED" to "no primary was installed at all",
            // and the L1 property under test — `primary` is never a
            // non-member — is stronger, not weaker.
    static void check(Document doc, Layer empty, Layer meshB) {
        assertDocInvariants(doc);
        assert(doc.primary is null,
            "SF1/0668: a target that cannot be primary installs NO primary, so "
            ~ "the stale one cannot survive into it");
        assert(!meshB.selected,
            "…and the exclusive select did not drag a mesh in behind it");
        assert(doc.focusedItem is empty, "the target still becomes focus");
    }

    Layer empty1, meshB1;
    auto d1 = staleDoc(empty1, meshB1);
    d1.selectItem(empty1, SelMode.Set);     // exclusiveSelect via selectItem(Set)
    check(d1, empty1, meshB1);

    Layer empty2, meshB2;
    auto d2 = staleDoc(empty2, meshB2);
    d2.setActive(0);                        // exclusiveSelect via setActive (idx 0 == empty2)
    check(d2, empty2, meshB2);
}

unittest {  // TASK 0671 — A STALE EDIT TARGET IS NOT REPRESENTABLE ANY MORE.
            // ~~SF1's surviving half (0668): `recoverStalePrimary` is still
            // the repair for the two arms that never route through
            // `exclusiveSelect`.~~ There is nothing left to repair. The target
            // is derived by ENUMERATING `layers`, so an item that leaves the
            // list stops being an answer the same instant — a whole class of
            // defect (and the function that fixed it) went away with the
            // field. What replaces the two "rehomed" rows is the stronger
            // claim: after the replacement the target is decided by the NEW
            // list alone, and nothing is conjured into it.
    {   // STALE → the departed layer is simply not an answer.
        Layer empty, meshB;
        auto doc = staleDoc(empty, meshB);
        doc.selectItem(empty, SelMode.Add);
        assertDocInvariants(doc);
        assert(doc.primary is null,
            "the old primary left `layers`, so the walk cannot reach it — and "
            ~ "no replacement is invented: meshB was never selected");
        assert(!meshB.selected,
            "above all it is not SELECTED on the way; that is the substitution "
            ~ "0654 removed everywhere else, and the pre-0671 repair did it here");
        assert(doc.focusedItem is empty, "Add still moves focus to the target");
    }
    {   // ABSENT → stays absent. RED before 0668: the mesh gets selected.
        // TASK 0671 — the rig had to change, and the change IS the finding.
        // It used to reach "no edit target" with `clearItemSelection()`, which
        // does not produce that state any more: dropping the selection LATCHES
        // every mesh that was in it. The state still exists, it is just reached
        // by having no mesh with a selection state at all — here, a document
        // nobody has selected anything in yet.
        Document doc;
        auto empty = new Layer; empty.name = "E0"; empty.kind = ItemKind.Empty;
        auto meshA = new Layer; meshA.name  = "M0";
        doc.layers = [empty, meshA];
        assert(doc.primary is null, "precondition: no target to begin with");
        doc.selectItem(empty, SelMode.Add);
        assertDocInvariants(doc);
        assert(doc.primary is null,
            "0668: an Add on a non-mesh item from a document with no "
            ~ "targetable item must not conjure an edit target");
        size_t sel = 0; foreach (l; doc.layers) if (l.selected) ++sel;
        assert(sel == 1,
            "and exactly one item is selected — the one that was added. The "
            ~ "pre-0668 repair read 2 here, having selected a mesh nobody "
            ~ "clicked");
    }
}

unittest {  // SF1, RED-before-fix: the focus assignment inside
            // `selectItem(Remove)`'s non-primary branch (`:368`-shape) must
            // guard membership too. Pre-fix it unconditionally copies
            // `primary` into `focusedItem`; with a STALE primary that
            // installs a non-member focus — the same L1 violation, just on
            // the other pointer. This arm does NOT repair `primary` itself
            // (only `Set`/`Add`/`setPrimary` do — see the next test), so
            // only `focusedItem` is checked here; `assertDocInvariants`
            // would still fail on the (deliberately still-stale) `primary`.
            //
            // `focusedItem` is set by a raw field write here, not a mutator:
            // every mutator that touches `focusedItem` (`Set`/`Add`/
            // `setPrimary`) ALSO now self-heals a stale `primary` (SF1/SF2),
            // so routing through one would repair the very staleness this
            // test needs to hold constant. This mirrors how `staleDoc`
            // itself is built — production reaches this shape via a raw
            // `document.layers = …` write too (`io/native.d:450`).
    Layer empty, meshB;
    auto doc = staleDoc(empty, meshB);
    empty.selected = true;
    meshB.selected = true;
    doc.focusedItem = empty;

    doc.selectItem(empty, SelMode.Remove);
    assert(!empty.selected, "empty deselected");
    assert(doc.focusedItem is meshB,
        "SF1: the focus fallback must not install the STALE primary — it must fall back to rehomePrimary");
    assert(doc.isMember(doc.focusedItem), "the recovered focusedItem is a genuine member of layers");
}

unittest {  // SF2 as amended by TASK 0668. The original read: `selectItem(Add)`
            // on a non-mesh layer must not leave `primary` null, because a
            // `Document` assembled by direct field writes starts with
            // `primary is null` and `Add`'s `if (canBePrimary) primary = l;`
            // has no `else`. 0654 then made a null primary a LEGAL state, and
            // after that the repair could no longer tell "mid-assembly" from
            // "the user emptied the selection" — it only ever saw `null`. It
            // chose wrongly for the second, and the second is the common one:
            // measured before this change, ctrl-adding a plane to an empty
            // selection came back with a MESH selected and primary.
            //
            // So a null primary now stays null. The stale case — the one the
            // repair can actually identify — is unchanged and is covered by
            // the `staleDoc` tests above.
    Document doc;
    auto empty = new Layer; empty.name = "E"; empty.kind = ItemKind.Empty;
    auto meshA = new Layer; meshA.name = "M";
    doc.layers = [empty, meshA];            // primary/focusedItem still null

    doc.selectItem(empty, SelMode.Add);
    assert(doc.primary is null,
        "SF2/0668: Add on a non-mesh target leaves an ABSENT primary absent — "
        ~ "it must not conjure an edit target the caller never asked for");
    assert(!meshA.selected,
        "…and above all must not SELECT one: that is the substitution 0654 "
        ~ "removed everywhere else");
    assert(doc.focusedItem is empty, "Add still moves focus to the non-mesh target");
    assertDocInvariants(doc);
}

unittest {  // SF2, RED-before-fix: setPrimary on a non-mesh layer must not
            // leave `primary` null either — same defect class as Add, the
            // sibling arm the earlier fix skipped.
    Document doc;
    auto empty = new Layer; empty.name = "E2"; empty.kind = ItemKind.Empty;
    auto meshA = new Layer; meshA.name = "M2";
    doc.layers = [empty, meshA];            // primary/focusedItem still null

    doc.setPrimary(empty);
    assert(doc.primary is null,
        "SF2/0668: same amendment as the Add arm — an ABSENT primary stays "
        ~ "absent; see that test for why the repair can no longer tell "
        ~ "mid-assembly from an emptied selection");
    assert(!meshA.selected, "…and no mesh is selected on the way");
    assert(doc.focusedItem is empty, "setPrimary still moves focus to the target");
    assertDocInvariants(doc);
}

unittest {  // TASK 0671 — the `setPrimary` half of the same retirement.
            // ~~SF2's surviving half (0668): a STALE primary is still
            // repaired by `recoverStalePrimary`.~~
    Layer empty, meshB;
    auto doc = staleDoc(empty, meshB);
    doc.setPrimary(empty);
    assert(doc.primary is null,
        "setPrimary on a non-targetable item seats it and focuses it; the walk "
        ~ "then filters it out and finds nothing else with a selection state");
    assert(!meshB.selected, "…and no mesh is selected on the way");
    assert(doc.focusedItem is empty, "and the focus is still the target");
    assertDocInvariants(doc);
    // …and the recovery is one ordinary select, exactly as everywhere else.
    doc.setPrimary(meshB);
    assert(doc.primary is meshB && doc.isMember(doc.primary) && meshB.selected,
        "CONTROL: seating a targetable item really does install a target, so "
        ~ "the null above is a real absence and not a broken walk");
    assertDocInvariants(doc);
}

// ---------------------------------------------------------------------------
// Survey #3 Phase 0: ItemXform.composedMatrix() correctness.
//
// The default xform (pos=0, rot=0, scl=1, pivot=0) MUST equal identity. A known
// {pos,rot_deg,scl,pivot} must produce the expected 4×4 — computed here by an
// INDEPENDENT hand formula (NOT by calling composedMatrix), so fixture and code
// cannot agree tautologically and hide a bug. Order under test:
//     M = T(pos) · T(pivot) · Rz·Ry·Rx · S · T(-pivot)  (ZYX, degrees).
// ---------------------------------------------------------------------------




// ---------------------------------------------------------------------------
// Task 0617: ItemXform.modelSpace() — the picking-facing ModelSpace factory.
// ---------------------------------------------------------------------------








unittest { // P1.0b.3c Layer-owned detached Mesh image and stable address.
    import math : Vec3;
    auto layer = new Layer();
    layer.meshRef().vertices = [Vec3(1, 2, 3), Vec3(4, 5, 6)];
    layer.meshRef().faces._store = [[0u, 1u, 0u]];
    layer.meshRef().edgeIndexMap[17UL] = 4;
    auto liveAddress = &layer.meshRef();
    auto token = layer.beginPreparedMesh();
    auto overlap = layer.beginPreparedMesh();
    auto overlapValidated = layer.validatesPreparedMesh(overlap);
    assert(!overlapValidated.valid);
    assert(testPreparedPendingImage(layer).vertices.ptr !is
           layer.meshRef().vertices.ptr);
    assert(testPreparedPendingImage(layer).faces[0].ptr !is
           layer.meshRef().faces[0].ptr);

    // Every replacement candidate crosses the same full safety boundary as
    // the live image at begin. Refusal preserves both the prior image and the
    // still-consumable owner token.
    const Vec3 prior = testPreparedPendingImage(layer).vertices[0];
    import mesh_edit_delta : MeshEditScope;
    import mesh : MeshEditBatch, detachedPreparedMesh;
    Mesh unsafeEdit = detachedPreparedMesh(layer.meshRef());
    auto editBatch = MeshEditBatch(unsafeEdit, cast(uint)MeshEditScope.Points);
    assert(!layer.prepareMeshImage(token, unsafeEdit));
    editBatch.close();
    assert(testPreparedPendingImage(layer).vertices[0] == prior);

    Mesh unsafeChanges = detachedPreparedMesh(layer.meshRef());
    unsafeChanges.noteChange(MeshEditScope.Position);
    assert(!layer.prepareMeshImage(token, unsafeChanges));
    assert(testPreparedPendingImage(layer).vertices[0] == prior);

    import mesh : MapDomain;
    Mesh unsafeArmed;
    assert(unsafeArmed.addMeshMap("armed-corner", 1,
                                  MapDomain.PolyVertex) !is null);
    auto armedRewrite = unsafeArmed.beginCornerRewrite();
    assert(!layer.prepareMeshImage(token, unsafeArmed));
    assert(testPreparedPendingImage(layer).vertices[0] == prior);

    Mesh unsafeDeclared;
    assert(unsafeDeclared.addMeshMap("corner", 1, MapDomain.PolyVertex) !is null);
    auto declaredRewrite = unsafeDeclared.beginCornerRewrite();
    unsafeDeclared.declareCornerProvenance(declaredRewrite.unchanged());
    assert(unsafeDeclared.cornerRewritePending());
    assert(!layer.prepareMeshImage(token, unsafeDeclared));
    assert(testPreparedPendingImage(layer).vertices[0] == prior);

    Mesh desired = detachedPreparedMesh(layer.meshRef());
    desired.vertices[0] = Vec3(9, 8, 7);
    desired.faces[0][0] = 1;
    desired.edgeIndexMap[17UL] = 99;
    assert(layer.prepareMeshImage(token, desired));
    desired = Mesh.init; // caller temporary may die before install.
    assert(layer.meshRef().vertices[0] == Vec3(1, 2, 3));

    auto other = new Layer();
    auto wrong = other.validatesPreparedMesh(token);
    assert(!wrong.valid);
    auto validated = layer.validatesPreparedMesh(token);
    assert(validated.valid);
    layer.installPreparedMesh(validated);
    assert(&layer.meshRef() is liveAddress);
    assert(layer.meshRef().vertices[0] == Vec3(9, 8, 7));
    assert(layer.meshRef().faces[0][0] == 1);
    assert(layer.meshRef().edgeIndexMap[17UL] == 99);
    layer.installPreparedMesh(validated); // one-shot.
    assert(&layer.meshRef() is liveAddress);

    auto discarded = layer.beginPreparedMesh();
    layer.discardPreparedMesh(discarded);
    assert(testPreparedPendingImage(layer) is null);
}

static assert(!__traits(compiles, {
    PreparedLayerMeshToken a; PreparedLayerMeshToken b = a;
}));
static assert(!__traits(compiles, {
    ValidatedLayerMeshToken a; ValidatedLayerMeshToken b = a;
}));

unittest {
    import math : Vec3;
    auto doc = Document.bootstrap(Mesh.init);
    auto layer = doc.primary;
    layer.meshRef().vertices = [Vec3(1, 2, 3)];
    auto live = &layer.meshRef();
    assert(layer.beginEnlistedMesh());
    layer.enlistedShadow().vertices[0] = Vec3(9, 8, 7);
    {
        auto projected = beginPreparedLayerRead(layer);
        assert(&doc.activeMeshRef() is &layer.enlistedShadow());
        assert(doc.activeMeshRef().vertices[0] == Vec3(9, 8, 7));
        projected.close();
    }
    assert(&doc.activeMeshRef() is live);
    assert(doc.activeMeshRef().vertices[0] == Vec3(1, 2, 3));
    layer.abortEnlistedMesh();
}
