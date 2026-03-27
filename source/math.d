module math;

import std.math : tan, sin, cos, sqrt, PI, abs;
// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

struct Vec3 { float x, y, z; }
struct Vec4 { float x, y, z, w; }

struct Viewport {
    float[16] view;
    float[16] proj;
    int width;
    int height;
    int x = 0;   // window-space left edge
    int y = 0;   // window-space top edge
}

Vec3 vec3Add  (Vec3 a, Vec3 b)  { return Vec3(a.x+b.x, a.y+b.y, a.z+b.z); }
Vec3 vec3Sub  (Vec3 a, Vec3 b)  { return Vec3(a.x-b.x, a.y-b.y, a.z-b.z); }
Vec3 vec3Scale(Vec3 v, float s) { return Vec3(v.x*s, v.y*s, v.z*s); }

Vec3 normalize(Vec3 v) {
    float len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
    return Vec3(v.x/len, v.y/len, v.z/len);
}
Vec3 cross(Vec3 a, Vec3 b) {
    return Vec3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
float dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }

immutable float[16] identityMatrix = [
    1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1,
];

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
    Vec3 f = normalize(vec3Sub(center, eye));
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
    if (c.w <= 0.0f) return false;
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
    if (c.w <= 0.0f) return false;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) import std.math : isClose;

unittest { // vec3Add
    auto r = vec3Add(Vec3(1,2,3), Vec3(4,5,6));
    assert(r.x == 5 && r.y == 7 && r.z == 9);
}

unittest { // vec3Sub
    auto r = vec3Sub(Vec3(4,5,6), Vec3(1,2,3));
    assert(r.x == 3 && r.y == 3 && r.z == 3);
}

unittest { // vec3Scale
    auto r = vec3Scale(Vec3(1,2,3), 2.0f);
    assert(r.x == 2 && r.y == 4 && r.z == 6);
}

unittest { // vec3Scale by zero
    auto r = vec3Scale(Vec3(5,-3,7), 0.0f);
    assert(r.x == 0 && r.y == 0 && r.z == 0);
}

unittest { // normalize axis-aligned
    auto n = normalize(Vec3(3,0,0));
    assert(isClose(n.x, 1.0f) && isClose(n.y, 0.0f) && isClose(n.z, 0.0f));
}

unittest { // normalize length == 1
    auto n = normalize(Vec3(1,2,3));
    float len = sqrt(n.x*n.x + n.y*n.y + n.z*n.z);
    assert(isClose(len, 1.0f));
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