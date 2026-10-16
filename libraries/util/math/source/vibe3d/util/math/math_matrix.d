module vibe3d.util.math.math_matrix;

import vibe3d.util.math.math_vector;
import vibe3d.util.math.math_quaternion;
import vibe3d.util.math.math_geometry;
import std.math : tan, sin, cos, sqrt, PI, abs, acos, asin, atan2, round, isFinite;
version (unittest) import std.math : isClose;


immutable float[16] identityMatrix = [
    1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1,
];

// Pure translation matrix (column-major, OpenGL convention).
float[16] translationMatrix(Vec3 t) {
    return [1,0,0,0, 0,1,0,0, 0,0,1,0, t.x,t.y,t.z,1];
}

// Rodrigues rotation around an arbitrary axis through a pivot point (column-major).
// The axis must already be normalised.
float[16] pivotRotationMatrix(Vec3 pivot, Vec3 axis, float angle) {
    float c = cos(angle), s = sin(angle), t = 1.0f - c;
    float ax = axis.x, ay = axis.y, az = axis.z;
    // Row-indexed rotation entries R[row][col]
    float r00 = c + ax*ax*t,      r01 = ax*ay*t - az*s, r02 = ax*az*t + ay*s;
    float r10 = ax*ay*t + az*s,   r11 = c + ay*ay*t,    r12 = ay*az*t - ax*s;
    float r20 = ax*az*t - ay*s,   r21 = ay*az*t + ax*s, r22 = c + az*az*t;
    // Translation: pivot - R * pivot
    float tx = pivot.x - (r00*pivot.x + r01*pivot.y + r02*pivot.z);
    float ty = pivot.y - (r10*pivot.x + r11*pivot.y + r12*pivot.z);
    float tz = pivot.z - (r20*pivot.x + r21*pivot.y + r22*pivot.z);
    // Column-major storage: m[row + col*4]
    return [r00, r10, r20, 0,
            r01, r11, r21, 0,
            r02, r12, r22, 0,
            tx,  ty,  tz,  1];
}


// Non-uniform scale around a pivot point (column-major).
float[16] pivotScaleMatrix(Vec3 pivot, float sx, float sy, float sz) {
    return [sx, 0,  0,  0,
            0,  sy, 0,  0,
            0,  0,  sz, 0,
            pivot.x*(1.0f-sx), pivot.y*(1.0f-sy), pivot.z*(1.0f-sz), 1];
}

// Non-uniform scale around a pivot, along an arbitrary orthonormal basis
// (ax, ay, az). M = T(pivot) * R * diag(s) * R^T * T(-pivot) where
// R has columns [ax | ay | az]. With identity basis it's equivalent to
// pivotScaleMatrix above.
float[16] pivotScaleMatrixBasis(Vec3 pivot, Vec3 ax, Vec3 ay, Vec3 az,
                                float sx, float sy, float sz) {
    // M3[i,j] = ax[i]*sx*ax[j] + ay[i]*sy*ay[j] + az[i]*sz*az[j]
    float m00 = ax.x*sx*ax.x + ay.x*sy*ay.x + az.x*sz*az.x;
    float m01 = ax.x*sx*ax.y + ay.x*sy*ay.y + az.x*sz*az.y;
    float m02 = ax.x*sx*ax.z + ay.x*sy*ay.z + az.x*sz*az.z;
    float m10 = ax.y*sx*ax.x + ay.y*sy*ay.x + az.y*sz*az.x;
    float m11 = ax.y*sx*ax.y + ay.y*sy*ay.y + az.y*sz*az.y;
    float m12 = ax.y*sx*ax.z + ay.y*sy*ay.z + az.y*sz*az.z;
    float m20 = ax.z*sx*ax.x + ay.z*sy*ay.x + az.z*sz*az.x;
    float m21 = ax.z*sx*ax.y + ay.z*sy*ay.y + az.z*sz*az.y;
    float m22 = ax.z*sx*ax.z + ay.z*sy*ay.z + az.z*sz*az.z;
    // Affine offset so the pivot is fixed: t = pivot - M3 * pivot
    float tx = pivot.x - (m00*pivot.x + m01*pivot.y + m02*pivot.z);
    float ty = pivot.y - (m10*pivot.x + m11*pivot.y + m12*pivot.z);
    float tz = pivot.z - (m20*pivot.x + m21*pivot.y + m22*pivot.z);
    return [m00, m10, m20, 0,
            m01, m11, m21, 0,
            m02, m12, m22, 0,
            tx,  ty,  tz,  1];
}

// ---------------------------------------------------------------------------
// Cumulative-euler helpers for the rotate panel.
//
// matrixFromEulerZYX / eulerZYXFromMatrix are exact inverses and pin to the
// SAME convention the transform tool's `composeFor` (tools/xfrm_transform.d)
// uses for its rotate factor. composeFor starts from identity and LEFT-
// multiplies the per-axis factors in order X, then Y, then Z:
//   M = R(Z) * ( R(Y) * ( R(X) * I ) )
// via `M = matMul4(pivotRotationMatrix(origin, axis, rad), M)`, skipping any
// factor whose angle is 0. The net rotation is therefore world R = Rz·Ry·Rx.
// We rebuild that exact product here by reusing pivotRotationMatrix + matMul4
// (no hand-rolled parallel matrix), so the layout/handedness is identical by
// construction. Angles are DEGREES; deg.x=RX about basis X, deg.y=RY, deg.z=RZ.
// ---------------------------------------------------------------------------

// Build R = Rz·Ry·Rx about the ORIGIN from euler degrees, matching composeFor's
// left-multiply sequence (and its zero-angle skip) bit-for-bit.
float[16] matrixFromEulerZYX(Vec3 deg) {
    enum float D2R = cast(float)(PI / 180.0);
    float[16] M = identityMatrix;
    void rot(Vec3 axis, float d) {
        if (d == 0) return;   // exact zero-angle skip, as composeFor does
        M = matMul4(pivotRotationMatrix(Vec3(0, 0, 0), axis, d * D2R), M);
    }
    rot(Vec3(1, 0, 0), deg.x);   // RX (rightmost factor)
    rot(Vec3(0, 1, 0), deg.y);   // RY
    rot(Vec3(0, 0, 1), deg.z);   // RZ (leftmost factor)
    return M;
}

// Decompose a rotation matrix (column-major, m[row + col*4], 3×3 block at
// indices 0,1,2,4,5,6,8,9,10) into ZYX euler DEGREES such that
// matrixFromEulerZYX(eulerZYXFromMatrix(M)) ≈ M for any rotation M.
//
// With R = Rz·Ry·Rx and R[row][col] stored at m[row + col*4]:
//   R[2][0] = m[2]  = -sin(ry)
//   R[2][1] = m[6]  =  sin(rx)*cos(ry)
//   R[2][2] = m[10] =  cos(rx)*cos(ry)
//   R[1][0] = m[1]  =  cos(ry)*sin(rz)
//   R[0][0] = m[0]  =  cos(ry)*cos(rz)
// so ry = asin(-m[2]); away from gimbal-lock,
//   rx = atan2(m[6], m[10]),  rz = atan2(m[1], m[0]).
//
// Gimbal lock (cos(ry) → 0, i.e. ry → ±90°): rx and rz become a single coupled
// DOF. Canonical convention: pin rz = 0 and fold the rotation into rx. There
//   R[0][1] = m[4] = -cos(rx ∓ rz)·... collapses; with rz=0 the recoverable
// angle is rx = atan2(-m[4], m[5]) at ry=+90°, and rx = atan2(m[4], m[5]) at
// ry=-90° (signs follow from the product with sy=±1). Both are captured by
// atan2(sy*m[4]... — implemented explicitly below.
Vec3 eulerZYXFromMatrix(float[16] M) {
    enum float R2D = cast(float)(180.0 / PI);
    float sy = -M[2];                 // -R[2][0] = sin(ry)
    if (sy > 1.0f) sy = 1.0f;
    if (sy < -1.0f) sy = -1.0f;
    float ry = asin(sy);
    float rx, rz;
    // cos(ry): gimbal-lock when this is ~0.
    float cy = sqrt(M[6]*M[6] + M[10]*M[10]); // = |cos(ry)| via R[2][1],R[2][2]
    if (cy > 1e-6f) {
        rx = atan2(M[6], M[10]);      // atan2(R[2][1], R[2][2])
        rz = atan2(M[1], M[0]);       // atan2(R[1][0], R[0][0])
    } else {
        // Singular: pin rz = 0, fold remaining rotation into rx.
        // At ry=+90° (sy=+1): R[0][1]=m[4]=sin(rx-rz), R[1][1]=m[5]=cos(rx-rz).
        // At ry=-90° (sy=-1): R[0][1]=m[4]=-sin(rx+rz), R[1][1]=m[5]=cos(rx+rz).
        rz = 0.0f;
        if (sy > 0.0f) rx = atan2(M[4], M[5]);
        else           rx = atan2(-M[4], M[5]);
    }
    return Vec3(rx * R2D, ry * R2D, rz * R2D);
}

// Apply a column-major affine matrix to a point (w == 1): returns the xyz of
// M·(p,1). Same math as `mulMV(m, Vec4(p, 1))` but inlined so this stays
// @safe/pure/nothrow/@nogc (mulMV carries none of those attributes).
Vec3 applyAffine(float[16] m, Vec3 p) @safe pure nothrow @nogc {
    return Vec3(
        m[0]*p.x + m[4]*p.y + m[ 8]*p.z + m[12],
        m[1]*p.x + m[5]*p.y + m[ 9]*p.z + m[13],
        m[2]*p.x + m[6]*p.y + m[10]*p.z + m[14],
    );
}

// Affine transform of a point by a COLUMN-MAJOR float[16] (w = 1; perspective
// divide skipped — affine matrices have d-row [0,0,0,1]). PUBLIC, reusable name
// for the interchange exporters (LWO bake, assimp node transform) so they need
// not reach for the `private` equivalent in io/scene_import.d. Forwards to
// applyAffine — same math, NOT a second spelling of it.
Vec3 transformPoint(const float[16] m, Vec3 p) @safe pure nothrow @nogc {
    return applyAffine(m, p);
}

/// True when `m`'s LINEAR part (upper-left 3x3, column-major) reverses
/// handedness — `det < 0`. Transforming geometry through such a matrix MIRRORS
/// it, so a face whose vertex order was counter-clockwise (outward) in the
/// source space comes out clockwise (inward) in the target space: the points
/// move, the index order does not, and the normal flips. Whoever BAKES such a
/// matrix into points must therefore also reverse each face's vertex order (and
/// any per-CORNER attribute that rides along with it) to keep the surface
/// outward — see `tools/create/create_common.frameIsLeftHanded` (which now
/// forwards here) for the same rule at the primitive-creation boundary, and
/// `io/scene_ir.flattenDocument` / `io/lwo_export` / `io/scene_export` for it at
/// the export boundary.
///
/// Takes the whole 4x4 for call-site convenience; the translation column plays
/// no part in handedness.
bool matrixMirrorsWinding(const float[16] m) @safe pure nothrow @nogc {
    // det of the upper-left 3x3, column-major: element (row r, col c) is m[c*4+r].
    const float a = m[0], b = m[4], c = m[8];
    const float d = m[1], e = m[5], f = m[9];
    const float g = m[2], h = m[6], i = m[10];
    return a*(e*i - f*h) - b*(d*i - f*g) + c*(d*h - e*g) < 0;
}

/// The normal matrix of `m` (column-major, upper 3×3): `sign(det) · cofactor`,
/// i.e. the inverse-transpose's DIRECTION — finite at `det == 0` (sign +1) and
/// orientation-preserving under a mirror. Column-major `float[9]`. The one
/// normal transform: the face VBO's lit draw (`u_normalMatrix`) and the CPU
/// line shade (`retopology_line_shade.lineShade`) both read it (model M3).
float[9] normalMatrix(const float[16] m) @safe pure nothrow @nogc {
    // Rows of the upper 3×3 (a(r,c) = m[c*4 + r]).
    immutable Vec3 r0 = Vec3(m[0], m[4], m[8]);
    immutable Vec3 r1 = Vec3(m[1], m[5], m[9]);
    immutable Vec3 r2 = Vec3(m[2], m[6], m[10]);
    // Cofactor rows: r1×r2, r2×r0, r0×r1.
    immutable Vec3 c0 = cross(r1, r2), c1 = cross(r2, r0), c2 = cross(r0, r1);
    immutable float det = r0.x * c0.x + r0.y * c0.y + r0.z * c0.z;
    immutable float s = det < 0.0f ? -1.0f : 1.0f;
    float[9] o;
    // o[c*3 + r] = s · C(r, c); C row r = c_r.
    o[0] = s * c0.x; o[3] = s * c0.y; o[6] = s * c0.z;
    o[1] = s * c1.x; o[4] = s * c1.y; o[7] = s * c1.z;
    o[2] = s * c2.x; o[5] = s * c2.y; o[8] = s * c2.z;
    return o;
}


// Build a column-major orthonormal frame matrix from a basis. The basis
// vectors right/up/fwd are placed in columns 0/1/2 of the upper-left 3x3;
// rotation-only (translation 0, w 1). Same column-major (m[row + col*4])
// convention as modelMatrix — equivalent to modelMatrix(right, up, fwd,
// Vec3(1,1,1), Vec3(0,0,0)) but spelled out for the AxisPacket frame cache.
float[16] frameMatrix(Vec3 right, Vec3 up, Vec3 fwd) @safe pure nothrow @nogc {
    return [
        right.x, right.y, right.z, 0,
        up.x,    up.y,    up.z,    0,
        fwd.x,   fwd.y,   fwd.z,   0,
        0,       0,       0,       1,
    ];
}

// Inverse of frameMatrix for an ORTHONORMAL basis: the inverse of an
// orthonormal rotation equals its transpose, so the basis vectors become
// the ROWS of the upper-left 3x3 (column-major storage m[row + col*4]).
float[16] frameMatrixInverse(Vec3 right, Vec3 up, Vec3 fwd) @safe pure nothrow @nogc {
    return [
        right.x, up.x, fwd.x, 0,
        right.y, up.y, fwd.y, 0,
        right.z, up.z, fwd.z, 0,
        0,       0,    0,     1,
    ];
}



// Column-major 4x4 matrix multiplication: C = A * B
//
// Task 0617: attributed @safe pure nothrow @nogc (it always qualified — pure
// arithmetic over fixed-size stack arrays) so the "no allocation on a picking
// path" property of `ModelSpace`/`projectionSpace` below is compiler-enforced
// rather than merely asserted in a comment.
float[16] matMul4(float[16] a, float[16] b) @safe pure nothrow @nogc {
    float[16] c;
    for (int col = 0; col < 4; col++)
        for (int row = 0; row < 4; row++) {
            float s = 0;
            for (int k = 0; k < 4; k++)
                s += a[row + k*4] * b[k + col*4];
            c[row + col*4] = s;
        }
    return c;
}

// Re-express an ORIGIN-FIXING matrix `M` (one built so that the intended
// transform is `pivot + M*(v - pivot)`, the convention applyXformMatrix uses) as
// a plain world-space matrix `W` such that `W*v == pivot + M*(v - pivot)`. This
// is the bridge between the CPU fold's pivot-relative matrix and the GPU
// fast-path's `u_model` (applied directly to baseline verts): W = T(pivot) * M *
// T(-pivot). For an origin-fixing rotation/scale this returns exactly the
// about-pivot builder (pivotRotationMatrix(pivot,..) / pivotScaleMatrixBasis(
// pivot,..)) — see the unittests — so the GPU path can reuse the CPU fold matrix
// instead of rebuilding a parallel about-pivot one (MS-4.5).
float[16] wrapAboutPivot(float[16] M, Vec3 pivot) {
    return matMul4(translationMatrix(pivot),
                   matMul4(M, translationMatrix(Vec3(-pivot.x, -pivot.y, -pivot.z))));
}

/// Precision-stable variant of wrapAboutPivot. Computes the translate column
/// `pivot − M_lin·pivot + t_fold` in double precision so that the large-minus-large
/// cancellation at a far pivot (|pivot| >> 1) does not lose bits. The linear
/// block (upper-left 3×3) is unchanged. The returned matrix is algebraically
/// identical to wrapAboutPivot(M, pivot) in exact arithmetic and avoids the
/// ~|pivot|·2^-23 float32 error for large |pivot|.
float[16] wrapAboutPivotStable(float[16] M, Vec3 pivot) {
    // M is origin-fixing: the intended GPU transform is W·v = pivot + M_lin·(v−pivot) + t_fold,
    // equivalently W·v = M_lin·v + (pivot − M_lin·pivot + t_fold).
    // W_trans = pivot − M_lin·pivot + t_fold, computed in double to avoid
    // large-minus-large cancellation when |pivot| is large (far action center).

    // Extract M_lin (upper-left 3×3, column-major) and t_fold.
    double m00 = M[0], m10 = M[1], m20 = M[2];
    double m01 = M[4], m11 = M[5], m21 = M[6];
    double m02 = M[8], m12 = M[9], m22 = M[10];
    double tf0 = M[12], tf1 = M[13], tf2 = M[14];

    // pivot in double
    double px = cast(double)pivot.x;
    double py = cast(double)pivot.y;
    double pz = cast(double)pivot.z;

    // M_lin · pivot (double)
    double mp_x = m00*px + m01*py + m02*pz;
    double mp_y = m10*px + m11*py + m12*pz;
    double mp_z = m20*px + m21*py + m22*pz;

    // W_trans = pivot − M_lin·pivot + t_fold (exact large-minus-large in double)
    double wx = px - mp_x + tf0;
    double wy = py - mp_y + tf1;
    double wz = pz - mp_z + tf2;

    float[16] W = identityMatrix;
    W[0]  = M[0];  W[1]  = M[1];  W[2]  = M[2];
    W[4]  = M[4];  W[5]  = M[5];  W[6]  = M[6];
    W[8]  = M[8];  W[9]  = M[9];  W[10] = M[10];
    W[12] = cast(float)wx;
    W[13] = cast(float)wy;
    W[14] = cast(float)wz;
    W[15] = 1.0f;
    return W;
}

// Build a column-major model matrix from a local frame + scale + translation.
// Columns are: right*scale.x, up*scale.y, fwd*scale.z, translation.
float[16] modelMatrix(Vec3 right, Vec3 up, Vec3 fwd,
                      Vec3 scale, Vec3 translate) {
    return [
        right.x*scale.x, right.y*scale.x, right.z*scale.x, 0,
        up.x   *scale.y, up.y   *scale.y, up.z   *scale.y, 0,
        fwd.x  *scale.z, fwd.y  *scale.z, fwd.z  *scale.z, 0,
        translate.x,     translate.y,     translate.z,      1,
    ];
}

// Column-major 4x4 * Vec4
Vec4 mulMV(const ref float[16] m, Vec4 v) {
    return Vec4(
        m[0]*v.x + m[4]*v.y + m[ 8]*v.z + m[12]*v.w,
        m[1]*v.x + m[5]*v.y + m[ 9]*v.z + m[13]*v.w,
        m[2]*v.x + m[6]*v.y + m[10]*v.z + m[14]*v.w,
        m[3]*v.x + m[7]*v.y + m[11]*v.z + m[15]*v.w,
    );
}

float[16] lookAt(Vec3 eye, Vec3 center, Vec3 worldUp) {
    Vec3 f = normalize(center - eye);
    Vec3 r = normalize(cross(f, worldUp));
    Vec3 u = cross(r, f);
    return [
         r.x,  u.x, -f.x, 0,
         r.y,  u.y, -f.y, 0,
         r.z,  u.z, -f.z, 0,
        -dot(r,eye), -dot(u,eye), dot(f,eye), 1,
    ];
}

float[16] perspectiveMatrix(float fovY, float aspect, float near, float far) {
    float f  = 1.0f / tan(fovY * 0.5f);
    float nf = near - far;
    return [
        f / aspect, 0,                    0,  0,
        0,          f,                    0,  0,
        0,          0,   (far + near) / nf, -1,
        0,          0, 2*far*near / nf,      0,
    ];
}

/// Orthographic projection matrix (column-major, symmetric frustum).
/// halfH   = half-height of the projection slab in world units.
/// aspect  = viewport width / height.
/// near, far = clip distances.
/// m[15] == 1 distinguishes this from perspectiveMatrix (m[15] == 0).
float[16] orthographicMatrix(float halfH, float aspect, float near, float far) {
    float rw = 1.0f / (halfH * aspect);
    float rh = 1.0f / halfH;
    float rd = -2.0f / (far - near);
    float tz = -(far + near) / (far - near);
    return [
        rw, 0,  0,  0,
        0,  rh, 0,  0,
        0,  0,  rd, 0,
        0,  0,  tz, 1,
    ];
}
