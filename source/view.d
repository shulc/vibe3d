module view;

import math;
import std.math : sqrt, tan, PI;

// CameraView
class View {
    float azimuth   =  0.5f;
    float elevation =  0.4f;
    float distance  =  3.0f;
    Vec3  focus     =  Vec3(0, 0, 0);
    immutable float minDist = 0.0001f;
    immutable float maxDist = float.max;
    immutable float maxElev = cast(float)(89.0f * PI / 180.0f);
    int width, height;
    int x, y;
    float[16] view;
    float[16] proj;
    Vec3 eye;

    this(int x, int y, int w, int h) { setSize(w, h); setPos(x, y); }
    void setSize(int w, int h) { width = w; height = h; }
    void setPos(int x, int y) { this.x = x; this.y = y; }
    void reset() {
        azimuth   =  0.5f;
        elevation =  0.4f;
        distance  =  3.0f;
        focus     =  Vec3(0, 0, 0);
    }

    void orbit(int dx, int dy) {
        azimuth   -= dx * 0.005f;
        elevation += dy * 0.005f;
        if (elevation >  maxElev) elevation =  maxElev;
        if (elevation < -maxElev) elevation = -maxElev;
    }

    void zoom(int dx) {
        distance -= dx * 0.01f * distance;
        if (distance < minDist) distance = minDist;
        if (distance > maxDist) distance = maxDist;
    }

    void pan(int dx, int dy) {
        Vec3 off     = sphericalToCartesian(azimuth, elevation, distance);
        Vec3 forward = normalize(Vec3(-off.x, -off.y, -off.z));
        Vec3 right   = normalize(cross(forward, Vec3(0, 1, 0)));
        Vec3 up      = cross(right, forward);
        float speed  = distance * 0.001f;
        focus += right * (-dx * speed);
        focus += up    * (dy * speed);
    }

    Viewport viewport() {
        Vec3 offset = sphericalToCartesian(azimuth, elevation, distance);
        eye    = focus + offset;
        view   = lookAt(eye, focus, Vec3(0, 1, 0));
        proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                        cast(float)width / height, 0.001f, 100.0f);
        return Viewport(view, proj, width, height, x, y, eye);
    }

    // ---------------------------------------------------------------------------
    // Frame-to-fit helper
    // ---------------------------------------------------------------------------

    // Adjusts `focus` and `distance` so the bounding sphere of `verts` fills
    // 90 % of the viewport (keeping the current orbit azimuth/elevation).
    string toJson() const {
        import std.format : format;
        return format(
            `{"azimuth":%f,"elevation":%f,"distance":%f,` ~
            `"focus":{"x":%f,"y":%f,"z":%f},` ~
            `"eye":{"x":%f,"y":%f,"z":%f},` ~
            `"width":%d,"height":%d}`,
            azimuth, elevation, distance,
            focus.x, focus.y, focus.z,
            eye.x, eye.y, eye.z,
            width, height);
    }

    void frameToVertices(Vec3[] verts)
    {
        if (verts.length == 0) return;

        float fovY = 45.0f * PI / 180.0f;

        Vec3 mn = verts[0], mx = verts[0];
        foreach (ref v; verts) {
            if (v.x < mn.x) mn.x = v.x;
            if (v.y < mn.y) mn.y = v.y;
            if (v.z < mn.z) mn.z = v.z;
            if (v.x > mx.x) mx.x = v.x;
            if (v.y > mx.y) mx.y = v.y;
            if (v.z > mx.z) mx.z = v.z;
        }

        focus = (mn + mx) * 0.5f;

        float dx = mx.x - mn.x, dy = mx.y - mn.y, dz = mx.z - mn.z;
        float radius = sqrt(dx*dx + dy*dy + dz*dz) * 0.5f;
        if (radius < 1e-6f) radius = 1e-6f;

        // Use the tighter field-of-view (Y or X) so the shape fits in both axes.
        float aspect    = cast(float)width / height;
        float halfTanY  = tan(fovY * 0.5f);
        float halfTanX  = halfTanY * aspect;
        float halfTanMin = halfTanY < halfTanX ? halfTanY : halfTanX;

        distance = radius / (0.9f * halfTanMin);
        // Keep the bounding sphere fully beyond the near clip plane (0.1).
        if (distance < radius + 0.001f) distance = radius + 0.001f;
        if (distance < minDist) distance = minDist;
        if (distance > maxDist) distance = maxDist;
    }
};