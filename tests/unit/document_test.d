// Module unittests for `document`, moved verbatim out of source/document.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
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
