module math;

import std.math : tan, sin, cos, sqrt, PI, abs;
// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

struct Vec3 {
    float x, y, z;

    Vec3 opBinary(string op)(Vec3 b) const @safe pure nothrow @nogc
    if (op == "+" || op == "-") {
        static if (op == "+") return Vec3(x+b.x, y+b.y, z+b.z);
        else                  return Vec3(x-b.x, y-b.y, z-b.z);
    }
    Vec3 opBinary(string op)(float s) const @safe pure nothrow @nogc
    if (op == "*") { return Vec3(x*s, y*s, z*s); }
    Vec3 opBinaryRight(string op)(float s) const @safe pure nothrow @nogc
    if (op == "*") { return Vec3(x*s, y*s, z*s); }
    Vec3 opUnary(string op)() const @safe pure nothrow @nogc
    if (op == "-") { return Vec3(-x, -y, -z); }
    ref Vec3 opOpAssign(string op)(Vec3 b) @safe pure nothrow @nogc
    if (op == "+" || op == "-") {
        static if (op == "+") { x += b.x; y += b.y; z += b.z; }
        else                  { x -= b.x; y -= b.y; z -= b.z; }
        return this;
    }
    ref Vec3 opOpAssign(string op)(float s) @safe pure nothrow @nogc
    if (op == "*") { x *= s; y *= s; z *= s; return this; }
    float length() const @safe pure nothrow @nogc { return sqrt(x*x + y*y + z*z); }
}
struct Vec4 { float x, y, z, w; }

struct Viewport {
    float[16] view;
    float[16] proj;
    int width;
    int height;
    int x = 0;   // window-space left edge
    int y = 0;   // window-space top edge
    Vec3 eye;
}

Vec3 vec3Lerp(Vec3 a, Vec3 b, float t) @safe pure nothrow @nogc {
    return Vec3(a.x+t*(b.x-a.x), a.y+t*(b.y-a.y), a.z+t*(b.z-a.z));
}

Vec3 normalize(Vec3 v) @safe pure nothrow @nogc {
    float len = v.length;
    return Vec3(v.x/len, v.y/len, v.z/len);
}
Vec3 cross(Vec3 a, Vec3 b) @safe pure nothrow @nogc {
    return Vec3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
float dot(Vec3 a, Vec3 b) @safe pure nothrow @nogc { return a.x*b.x + a.y*b.y + a.z*b.z; }

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

// Column-major 4x4 matrix multiplication: C = A * B
float[16] matMul4(float[16] a, float[16] b) {
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

Vec3 sphericalToCartesian(float az, float el, float dist) {
    return Vec3(dist * cos(el) * sin(az),
                dist * sin(el),
                dist * cos(el) * cos(az));
}

// Project world point to window pixel coords.
// Returns false if behind camera or outside frustum.
// px, py  — window-space pixels (Y down)
// ndcZ    — NDC depth in [-1, 1]
bool projectToWindow(Vec3 world, const ref Viewport vp,
                     out float px, out float py, out float ndcZ) {
    Vec4 v = mulMV(vp.view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 c = mulMV(vp.proj, v);
    if (!(c.w > 0.0f)) return false; // rejects NaN and non-positive
    float nx = c.x / c.w;
    float ny = c.y / c.w;
    ndcZ     = c.z / c.w;
    if (nx < -1 || nx > 1 || ny < -1 || ny > 1 || ndcZ < -1 || ndcZ > 1)
        return false;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

// Like projectToWindow but does NOT reject points outside the screen boundary.
// Only rejects points behind the camera (w <= 0).
// Use this for hit-testing line segments that may extend off-screen.
bool projectToWindowFull(Vec3 world, const ref Viewport vp,
                         out float px, out float py, out float ndcZ) {
    Vec4 v = mulMV(vp.view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 c = mulMV(vp.proj, v);
    if (!(c.w > 0.0f)) return false; // rejects NaN and non-positive
    float nx = c.x / c.w;
    float ny = c.y / c.w;
    ndcZ = c.z / c.w;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

// 2D point-in-polygon test (ray casting, works for convex and concave polygons).
bool pointInPolygon2D(float px, float py, float[] xs, float[] ys) {
    int n = cast(int)xs.length;
    bool inside = false;
    for (int i = 0, j = n - 1; i < n; j = i++) {
        if (((ys[i] > py) != (ys[j] > py)) &&
            (px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]))
            inside = !inside;
    }
    return inside;
}

// Closest distance from point (px,py) to segment (ax,ay)-(bx,by).
// t is the interpolation parameter [0..1] of the closest point on segment.
float closestOnSegment2D(float px, float py,
                          float ax, float ay, float bx, float by,
                          out float t) {
    float dx = bx - ax, dy = by - ay;
    float len2 = dx*dx + dy*dy;
    if (len2 < 1e-6f) { t = 0.0f; return sqrt((px-ax)*(px-ax)+(py-ay)*(py-ay)); }
    t = ((px-ax)*dx + (py-ay)*dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = ax + t*dx, cy = ay + t*dy;
    return sqrt((px-cx)*(px-cx) + (py-cy)*(py-cy));
}

// Optimized version that returns squared distance (avoids sqrt)
float closestOnSegment2DSquared(float px, float py,
                                 float ax, float ay, float bx, float by,
                                 out float t) {
    float dx = bx - ax, dy = by - ay;
    float len2 = dx*dx + dy*dy;
    if (len2 < 1e-6f) { t = 0.0f; return (px-ax)*(px-ax)+(py-ay)*(py-ay); }
    t = ((px-ax)*dx + (py-ay)*dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = ax + t*dx, cy = ay + t*dy;
    return (px-cx)*(px-cx) + (py-cy)*(py-cy);
}

// ---------------------------------------------------------------------------
// Ray helpers used by plane drag
// ---------------------------------------------------------------------------

// World-space ray direction through screen pixel (sx, sy).
// Uses the view+proj stored in vp; accounts for viewport offset.
Vec3 screenRay(float sx, float sy, const ref Viewport vp)
{
    import std.math : sqrt;
    // NDC, Y-up
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;

    // View-space direction: invert perspective projection.
    // proj[0] = f/aspect, proj[5] = f  (diagonal of perspective matrix, row/col 0 and 1).
    // Using M[row][col] = m[row + col*4]: proj[0]=m[0], proj[5]=m[5].
    float vx = nx / vp.proj[0];
    float vy = ny / vp.proj[5];
    // vz = -1 (camera looks along -Z in view space)

    // Rotate to world space: world = R^T * view_dir,
    // where R rows are view[0,4,8], view[1,5,9], view[2,6,10]  (M[row][col]=m[row+col*4]).
    // R^T col j = R row j, so world.x = R col0 · view_dir = view[0]*vx + view[1]*vy + view[2]*(-1)
    const ref float[16] v = vp.view;
    Vec3 d = Vec3(
        v[0]*vx + v[1]*vy + v[2]*(-1.0f),
        v[4]*vx + v[5]*vy + v[6]*(-1.0f),
        v[8]*vx + v[9]*vy + v[10]*(-1.0f),
    );
    float len = d.length;
    return len > 1e-9f ? Vec3(d.x/len, d.y/len, d.z/len) : Vec3(0,0,-1);
}

// Intersect ray (origin + t*dir) with plane (point on plane + normal).
// Returns false when ray is parallel to the plane.
bool rayPlaneIntersect(Vec3 origin, Vec3 dir, Vec3 planePoint, Vec3 n,
                               out Vec3 hit)
{
    import std.math : abs;
    float denom = dot(n, dir);
    if (abs(denom) < 1e-6f) return false;
    Vec3 d = planePoint - origin;
    float t = dot(n, d) / denom;
    hit = origin + dir * t;
    return true;
}

// Safe normalize — returns (0,1,0) for near-zero vectors.
Vec3 safeNormalize(Vec3 v) @safe pure nothrow @nogc {
    float len = v.length;
    return len > 1e-6f ? Vec3(v.x/len, v.y/len, v.z/len) : Vec3(0, 1, 0);
}


// Blender offset_in_plane: direction perpendicular to edgeDir inside a face.
//
// edgeDir  — normalized direction of the bevel edge (va→vb for F1, vb→va for F2)
// faceNorm — unit normal of the face the new vertex lives in
//
// Returns unit vector d such that  orig + d * width  places the new vertex at
// perpendicular distance width from the bevel-edge line, lying in the face plane.
// Formula: cross(faceNorm, edgeDir), normalised — points INTO the face.
Vec3 offsetInPlane(Vec3 edgeDir, Vec3 faceNorm) @safe pure nothrow @nogc {
    Vec3 p = cross(faceNorm, edgeDir);
    float len = p.length;
    return len > 1e-6f ? Vec3(p.x/len, p.y/len, p.z/len) : Vec3(0, 1, 0);
}

// Blender offset_meet: junction-vertex offset direction.
//
// e1 — unit vector FROM jv toward prevV in the gap face (face winding prevV→jv→nextV)
// e2 — unit vector FROM jv toward nextV in the gap face
// faceNorm — unit normal of the gap face
//
// In the gap face, prevV arrives INTO jv (F2 winding → edge direction = -e1),
// while nextV departs FROM jv (F1 winding → edge direction = +e2).
// So the two offset lines are:
//   L1: p1 + t*e1,  where p1 = offsetInPlane(-e1, faceNorm)  ← prevV / F2 side
//   L2: p2 + s*e2,  where p2 = offsetInPlane( e2, faceNorm)  ← nextV / F1 side
// Returns direction d s.t.  jv + d*width  = intersection of L1 and L2.
Vec3 offsetMeetDir(Vec3 e1, Vec3 e2, Vec3 faceNorm) @safe pure nothrow @nogc {
    Vec3 p1 = offsetInPlane(-e1, faceNorm); // prevV side: negate (F2 winding)
    Vec3 p2 = offsetInPlane(e2,  faceNorm); // nextV side: direct (F1 winding)

    Vec3  rhs   = p2 - p1;
    Vec3  n     = cross(e1, e2);
    float denom = dot(n, n);
    if (denom < 1e-12f) {
        return safeNormalize((p1 + p2) * 0.5f);
    }
    float t = dot(cross(rhs, e2), n) / denom;
    return p1 + e1 * t;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) import std.math : isClose;

unittest { // vec3Add
    auto r = Vec3(1,2,3) + Vec3(4,5,6);
    assert(r.x == 5 && r.y == 7 && r.z == 9);
}

unittest { // vec3Sub
    auto r = Vec3(4,5,6) - Vec3(1,2,3);
    assert(r.x == 3 && r.y == 3 && r.z == 3);
}

unittest { // vec3Scale
    auto r = Vec3(1,2,3) * 2.0f;
    assert(r.x == 2 && r.y == 4 && r.z == 6);
}

unittest { // vec3Scale by zero
    auto r = Vec3(5,-3,7) * 0.0f;
    assert(r.x == 0 && r.y == 0 && r.z == 0);
}

unittest { // normalize axis-aligned
    auto n = normalize(Vec3(3,0,0));
    assert(isClose(n.x, 1.0f) && isClose(n.y, 0.0f) && isClose(n.z, 0.0f));
}

unittest { // normalize length == 1
    auto n = normalize(Vec3(1,2,3));
    assert(isClose(n.length, 1.0f));
}

unittest { // dot
    assert(isClose(dot(Vec3(1,0,0), Vec3(1,0,0)),  1.0f));
    assert(isClose(dot(Vec3(1,0,0), Vec3(0,1,0)),  0.0f));
    assert(isClose(dot(Vec3(1,0,0), Vec3(-1,0,0)), -1.0f));
}

unittest { // cross X×Y = Z
    auto r = cross(Vec3(1,0,0), Vec3(0,1,0));
    assert(isClose(r.x, 0) && isClose(r.y, 0) && isClose(r.z, 1));
}

unittest { // cross anti-commutative
    auto a = Vec3(1,2,3), b = Vec3(4,5,6);
    auto ab = cross(a, b), ba = cross(b, a);
    assert(isClose(ab.x, -ba.x) && isClose(ab.y, -ba.y) && isClose(ab.z, -ba.z));
}

unittest { // cross of parallel vectors is zero
    auto r = cross(Vec3(1,0,0), Vec3(2,0,0));
    assert(isClose(r.x, 0) && isClose(r.y, 0) && isClose(r.z, 0));
}

unittest { // mulMV with identity
    auto r = mulMV(identityMatrix, Vec4(1,2,3,1));
    assert(isClose(r.x,1) && isClose(r.y,2) && isClose(r.z,3) && isClose(r.w,1));
}

unittest { // modelMatrix identity frame → identity matrix
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(1,1,1), Vec3(0,0,0));
    foreach (i, v; identityMatrix)
        assert(isClose(m[i], v));
}

unittest { // modelMatrix translation stored in last column
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(1,1,1), Vec3(5,-3,7));
    assert(isClose(m[12], 5) && isClose(m[13], -3) && isClose(m[14], 7));
}

unittest { // modelMatrix non-uniform scale
    auto m = modelMatrix(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                         Vec3(2,3,4), Vec3(0,0,0));
    assert(isClose(m[0], 2) && isClose(m[5], 3) && isClose(m[10], 4));
}

unittest { // lookAt — origin is in front of camera
    auto m = lookAt(Vec3(0,0,5), Vec3(0,0,0), Vec3(0,1,0));
    Vec4 o = mulMV(m, Vec4(0,0,0,1));
    assert(isClose(o.x, 0, 1e-4f) && isClose(o.y, 0, 1e-4f));
    assert(o.z < 0);
}

unittest { // sphericalToCartesian az=0 el=0 → +Z
    auto v = sphericalToCartesian(0.0f, 0.0f, 1.0f);
    assert(isClose(v.x, 0) && isClose(v.y, 0) && isClose(v.z, 1));
}

unittest { // sphericalToCartesian el=PI/2 → straight up
    auto v = sphericalToCartesian(0.0f, PI/2, 1.0f);
    assert(isClose(v.y, 1.0f, 1e-5f));
    assert(isClose(v.x, 0, 1e-5f, 1e-5f) && isClose(v.z, 0, 1e-5f, 1e-5f));
}

unittest { // sphericalToCartesian dist=0 → zero vector
    auto v = sphericalToCartesian(1.23f, 0.45f, 0.0f);
    assert(isClose(v.x, 0) && isClose(v.y, 0) && isClose(v.z, 0));
}

unittest { // pointInPolygon2D square
    float[] xs = [0, 4, 4, 0];
    float[] ys = [0, 0, 4, 4];
    assert( pointInPolygon2D(2, 2, xs, ys));
    assert(!pointInPolygon2D(5, 2, xs, ys));
    assert(!pointInPolygon2D(2, 5, xs, ys));
}

unittest { // pointInPolygon2D triangle
    float[] xs = [0, 2, 4];
    float[] ys = [0, 4, 0];
    assert( pointInPolygon2D(2, 1.5f, xs, ys));
    assert(!pointInPolygon2D(-1, 2,   xs, ys));
}

unittest { // closestOnSegment2D — point above midpoint
    float t;
    float d = closestOnSegment2D(2, 1, 0, 0, 4, 0, t);
    assert(isClose(d, 1.0f) && isClose(t, 0.5f));
}

unittest { // closestOnSegment2D — clamp to t=1
    float t;
    float d = closestOnSegment2D(6, 0, 0, 0, 4, 0, t);
    assert(isClose(t, 1.0f) && isClose(d, 2.0f));
}

unittest { // closestOnSegment2D — clamp to t=0
    float t;
    float d = closestOnSegment2D(-1, 0, 0, 0, 4, 0, t);
    assert(isClose(t, 0.0f) && isClose(d, 1.0f));
}

unittest { // closestOnSegment2D — degenerate segment
    float t;
    float d = closestOnSegment2D(3, 4, 0, 0, 0, 0, t);
    assert(isClose(t, 0.0f) && isClose(d, 5.0f));
}

// Helper: viewport with lookAt camera at Z=5 and 90° symmetric perspective
version(unittest) private Viewport makeTestViewport() {
    Viewport vp;
    vp.view   = lookAt(Vec3(0,0,5), Vec3(0,0,0), Vec3(0,1,0));
    vp.proj   = perspectiveMatrix(PI/2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

unittest { // screenRay: center pixel → along -Z
    auto vp = makeTestViewport();
    auto r = screenRay(400, 400, vp);
    assert(isClose(r.x, 0, 1e-5f, 1e-5f));
    assert(isClose(r.y, 0, 1e-5f, 1e-5f));
    assert(isClose(r.z, -1.0f));
}

unittest { // screenRay: result is always unit length
    auto vp = makeTestViewport();
    foreach (sx; [0.0f, 400.0f, 799.0f])
        foreach (sy; [0.0f, 400.0f, 799.0f]) {
            auto r = screenRay(sx, sy, vp);
            assert(isClose(r.length, 1.0f, 1e-4f));
        }
}

unittest { // screenRay: top-left pixel → (-1/√3, 1/√3, -1/√3) with 90° FOV aspect=1
    // proj[0]=proj[5]=1, so nx=-1,ny=1 → view-dir (-1,1,-1) → normalized
    auto vp = makeTestViewport();
    auto r = screenRay(0, 0, vp);
    float inv3 = 1.0f / sqrt(3.0f);
    assert(isClose(r.x, -inv3, 1e-4f));
    assert(isClose(r.y,  inv3, 1e-4f));
    assert(isClose(r.z, -inv3, 1e-4f));
}

unittest { // screenRay: viewport offset shifts pixel-to-NDC mapping
    auto vp = makeTestViewport();
    vp.x = 100;
    vp.y = 50;
    // Center of the offset viewport is now pixel (500, 450)
    auto r = screenRay(500, 450, vp);
    assert(isClose(r.x, 0, 1e-5f, 1e-5f));
    assert(isClose(r.y, 0, 1e-5f, 1e-5f));
    assert(isClose(r.z, -1.0f));
}

unittest { // rayPlaneIntersect: ray from above hits XZ plane at origin
    Vec3 hit;
    bool ok = rayPlaneIntersect(Vec3(0,5,0), Vec3(0,-1,0),
                                Vec3(0,0,0), Vec3(0,1,0), hit);
    assert(ok);
    assert(isClose(hit.x, 0, 1e-5f, 1e-5f));
    assert(isClose(hit.y, 0, 1e-5f, 1e-5f));
    assert(isClose(hit.z, 0, 1e-5f, 1e-5f));
}

unittest { // rayPlaneIntersect: angled ray hits offset plane at correct point
    // Ray from origin along (1,1,0)/√2, plane at x=3 with normal (1,0,0)
    // t = 3/s where s=1/√2, hit = (3, 3, 0)
    float s = 1.0f / sqrt(2.0f);
    Vec3 hit;
    bool ok = rayPlaneIntersect(Vec3(0,0,0), Vec3(s,s,0),
                                Vec3(3,0,0), Vec3(1,0,0), hit);
    assert(ok);
    assert(isClose(hit.x, 3.0f, 1e-4f));
    assert(isClose(hit.y, 3.0f, 1e-4f));
    assert(isClose(hit.z, 0, 1e-5f, 1e-5f));
}

unittest { // rayPlaneIntersect: ray parallel to plane returns false
    Vec3 hit;
    assert(!rayPlaneIntersect(Vec3(0,5,0), Vec3(1,0,0),
                              Vec3(0,0,0), Vec3(0,1,0), hit));
}

unittest { // rayPlaneIntersect: near-parallel ray below threshold returns false
    Vec3 hit;
    // dot((0,1,0), (1, 5e-7, 0)) = 5e-7 < 1e-6
    assert(!rayPlaneIntersect(Vec3(0,0,0), Vec3(1.0f, 5e-7f, 0),
                              Vec3(0,1,0), Vec3(0,1,0), hit));
}

unittest { // vec3Length
    assert(isClose(Vec3(3,4,0).length, 5.0f));
    assert(isClose(Vec3(0,0,0).length, 0.0f));
    assert(isClose(Vec3(1,0,0).length, 1.0f));
}

unittest { // vec3Lerp
    auto r = vec3Lerp(Vec3(0,0,0), Vec3(4,4,4), 0.25f);
    assert(isClose(r.x, 1.0f) && isClose(r.y, 1.0f) && isClose(r.z, 1.0f));
    auto a = vec3Lerp(Vec3(1,2,3), Vec3(5,6,7), 0.0f);
    assert(isClose(a.x, 1.0f) && isClose(a.y, 2.0f) && isClose(a.z, 3.0f));
    auto b = vec3Lerp(Vec3(1,2,3), Vec3(5,6,7), 1.0f);
    assert(isClose(b.x, 5.0f) && isClose(b.y, 6.0f) && isClose(b.z, 7.0f));
}