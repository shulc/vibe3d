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
    px = (nx * 0.5f + 0.5f)          * vp.width;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height;
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
    px = (nx * 0.5f + 0.5f)          * vp.width;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height;
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