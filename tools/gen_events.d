/+
  tools/gen_events.d — event-log generator for vibe3D automated tests.

  Generates SDL event logs that reproduce camera and selection operations,
  suitable for use with /api/play-events in --test mode.

  Compile:
    dmd tools/gen_events.d -of=gen_events

  Usage:
    ./gen_events orbit  <targetAz> <targetEl>
    ./gen_events zoom   <targetDist>
    ./gen_events pan    <targetFocX> <targetFocY> <targetFocZ>
    ./gen_events select-vertices <idx1> [idx2 ...]

  All operations start from the default camera state:
    azimuth=0.5, elevation=0.4, distance=3.0, focus=(0,0,0)
    viewport: x=150, y=0, width=650, height=562 (window 800×600, panel 150px, status 38px)

  Output is written to stdout — redirect to a .log file:
    ./gen_events orbit -0.575 0.530 > tests/events/camera_rotate_events.log
+/

module gen_events;

import std.stdio, std.math, std.format, std.conv, std.string, std.algorithm, std.array;

// ---------------------------------------------------------------------------
// Minimal math (mirrors source/math.d, no SDL/OpenGL dependency)
// ---------------------------------------------------------------------------

struct Vec3 { float x, y, z; }
struct Vec4 { float x, y, z, w; }

Vec3 vec3Add  (Vec3 a, Vec3 b)  { return Vec3(a.x+b.x, a.y+b.y, a.z+b.z); }
Vec3 vec3Sub  (Vec3 a, Vec3 b)  { return Vec3(a.x-b.x, a.y-b.y, a.z-b.z); }
Vec3 vec3Scale(Vec3 v, float s) { return Vec3(v.x*s, v.y*s, v.z*s); }

float dotV(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }

Vec3 normalizeV(Vec3 v) {
    float len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
    if (len < 1e-9f) return Vec3(0, 0, 1);
    return Vec3(v.x/len, v.y/len, v.z/len);
}

Vec3 crossV(Vec3 a, Vec3 b) {
    return Vec3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}

// Column-major 4×4 × Vec4
Vec4 mulMV(const float[16] m, Vec4 v) {
    return Vec4(
        m[0]*v.x + m[4]*v.y + m[ 8]*v.z + m[12]*v.w,
        m[1]*v.x + m[5]*v.y + m[ 9]*v.z + m[13]*v.w,
        m[2]*v.x + m[6]*v.y + m[10]*v.z + m[14]*v.w,
        m[3]*v.x + m[7]*v.y + m[11]*v.z + m[15]*v.w,
    );
}

float[16] lookAtM(Vec3 eye, Vec3 center, Vec3 worldUp) {
    Vec3 f = normalizeV(vec3Sub(center, eye));
    Vec3 r = normalizeV(crossV(f, worldUp));
    Vec3 u = crossV(r, f);
    return [
         r.x,  u.x, -f.x, 0,
         r.y,  u.y, -f.y, 0,
         r.z,  u.z, -f.z, 0,
        -dotV(r,eye), -dotV(u,eye), dotV(f,eye), 1,
    ];
}

float[16] perspectiveM(float fovY, float aspect, float near, float far) {
    float f  = 1.0f / tan(fovY * 0.5f);
    float nf = near - far;
    return [
        f / aspect, 0,                    0,  0,
        0,          f,                    0,  0,
        0,          0,   (far + near) / nf, -1,
        0,          0, 2*far*near / nf,      0,
    ];
}

Vec3 sphericalToCart(float az, float el, float dist) {
    return Vec3(dist * cos(el) * sin(az),
                dist * sin(el),
                dist * cos(el) * cos(az));
}

// Project world point → window pixel (Y-down, viewport-aware).
// Returns false if behind camera.
bool project(Vec3 world, float[16] view, float[16] proj,
             int vpX, int vpY, int vpW, int vpH,
             out float px, out float py) {
    Vec4 v = mulMV(view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 c = mulMV(proj, v);
    if (c.w <= 0.0f) return false;
    float nx = c.x / c.w;
    float ny = c.y / c.w;
    float nz = c.z / c.w;
    if (nz < -1 || nz > 1) return false;
    px = (nx * 0.5f + 0.5f)          * vpW + vpX;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vpH + vpY;
    return true;
}

// ---------------------------------------------------------------------------
// Default camera / viewport constants (from app.d: PANEL_W=150, STATUS_H=38)
// ---------------------------------------------------------------------------

immutable int   VP_X = 150, VP_Y = 0, VP_W = 650, VP_H = 562;
immutable float FOV_Y = 45.0f * PI / 180.0f;
immutable float NEAR = 0.001f, FAR = 100.0f;
immutable float MAX_ELEV = cast(float)(89.0f * PI / 180.0f);

// Default cube vertices (from mesh.d makeCube())
immutable Vec3[8] CUBE_VERTS = [
    Vec3(-0.5f, -0.5f, -0.5f), // 0
    Vec3( 0.5f, -0.5f, -0.5f), // 1
    Vec3( 0.5f,  0.5f, -0.5f), // 2
    Vec3(-0.5f,  0.5f, -0.5f), // 3
    Vec3(-0.5f, -0.5f,  0.5f), // 4
    Vec3( 0.5f, -0.5f,  0.5f), // 5
    Vec3( 0.5f,  0.5f,  0.5f), // 6
    Vec3(-0.5f,  0.5f,  0.5f), // 7
];

// ---------------------------------------------------------------------------
// Camera state
// ---------------------------------------------------------------------------

struct CamState {
    float az   = 0.5f;
    float el   = 0.4f;
    float dist = 3.0f;
    Vec3  focus = Vec3(0, 0, 0);

    // Mirrors View.orbit()
    void orbit(int dx, int dy) {
        az -= dx * 0.005f;
        el += dy * 0.005f;
        if (el >  MAX_ELEV) el =  MAX_ELEV;
        if (el < -MAX_ELEV) el = -MAX_ELEV;
    }

    // Mirrors View.zoom()
    void zoom(int dx) {
        dist -= dx * 0.01f * dist;
        if (dist < 0.0001f) dist = 0.0001f;
    }

    // Mirrors View.pan()
    void pan(int dx, int dy) {
        Vec3 off     = sphericalToCart(az, el, dist);
        Vec3 forward = normalizeV(Vec3(-off.x, -off.y, -off.z));
        Vec3 right   = normalizeV(crossV(forward, Vec3(0, 1, 0)));
        Vec3 up      = crossV(right, forward);
        float speed  = dist * 0.001f;
        focus = vec3Add(focus, vec3Scale(right, -dx * speed));
        focus = vec3Add(focus, vec3Scale(up,     dy * speed));
    }

    // Build view + proj matrices
    float[16] viewMatrix() const {
        Vec3 offset = sphericalToCart(az, el, dist);
        Vec3 eye = vec3Add(focus, offset);
        return lookAtM(eye, focus, Vec3(0, 1, 0));
    }

    float[16] projMatrix() const {
        float aspect = cast(float)VP_W / VP_H;
        return perspectiveM(FOV_Y, aspect, NEAR, FAR);
    }
}

// ---------------------------------------------------------------------------
// Event emitter
// ---------------------------------------------------------------------------

struct EventGen {
    double t      = 500.0;   // current timestamp (ms)
    int    mouseX = VP_X + VP_W / 2;   // window-space cursor X
    int    mouseY = VP_Y + VP_H / 2;   // window-space cursor Y
    CamState cam;

    string[] lines;

    void emit(string line) { lines ~= line; }

    void advance(double dt = 16.667) { t += dt; }

    // --- Window focus events at startup ---
    void writeHeader() {
        emit(format(`{"t":%.3f,"type":"SDL_WINDOWEVENT","sub":1}`, t)); advance(0.5);
        emit(format(`{"t":%.3f,"type":"SDL_WINDOWEVENT","sub":3}`, t)); advance(100);
        emit(format(`{"t":%.3f,"type":"SDL_WINDOWEVENT","sub":12}`, t)); advance(0.1);
        emit(format(`{"t":%.3f,"type":"SDL_WINDOWEVENT","sub":10}`, t)); advance(0.1);
        // Initial mouse movement to position cursor
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`,
            t, mouseX, mouseY));
        advance(16);
    }

    // Move cursor smoothly from current to (tx, ty) without button, in steps of ~maxStep px
    void moveCursorTo(int tx, int ty, int mod = 0, int maxStep = 20) {
        int dx = tx - mouseX, dy = ty - mouseY;
        int steps = max(1, (abs(dx) + abs(dy)) / maxStep);
        int doneX = 0, doneY = 0;
        foreach (i; 1 .. steps + 1) {
            int tdx = cast(int)round(cast(float)dx * i / steps);
            int tdy = cast(int)round(cast(float)dy * i / steps);
            int xrel = tdx - doneX, yrel = tdy - doneY;
            doneX = tdx; doneY = tdy;
            if (xrel == 0 && yrel == 0) continue;
            mouseX += xrel; mouseY += yrel;
            emit(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":0,"mod":%d}`,
                t, mouseX, mouseY, xrel, yrel, mod));
            advance();
        }
    }

    // Emit a drag segment (state=1) applying camera deltas in steps
    void drag(int totalDx, int totalDy, int mod) {
        int stepsX = abs(totalDx), stepsY = abs(totalDy);
        int totalSteps = max(stepsX, stepsY, 1);

        // Bresenham-style integer stepping along dominant axis.
        int doneX = 0, doneY = 0;
        foreach (step; 1 .. totalSteps + 1) {
            int targetDx = cast(int)round(cast(float)totalDx * step / totalSteps);
            int targetDy = cast(int)round(cast(float)totalDy * step / totalSteps);
            int xrel = targetDx - doneX;
            int yrel = targetDy - doneY;
            doneX = targetDx; doneY = targetDy;
            if (xrel == 0 && yrel == 0) continue;
            mouseX += xrel; mouseY += yrel;
            emit(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":%d}`,
                t, mouseX, mouseY, xrel, yrel, mod));
            advance();
        }
    }

    // --- Orbit operation ---
    // Applies Alt + LMB drag to reach targetAz/El from current state.
    void orbit(float targetAz, float targetEl) {
        int totalDx = cast(int)round((cam.az - targetAz) / 0.005f);
        int totalDy = cast(int)round((targetEl - cam.el) / 0.005f);

        // Press Alt — move mouse a bit with alt held first (matching real usage)
        emit(format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":1073742050,"scan":226,"mod":256,"repeat":0}`, t));
        advance();
        moveCursorTo(mouseX + 10, mouseY, 256);  // slight mouse movement with alt

        // Start drag
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":256}`,
            t, mouseX, mouseY));
        advance();

        // Apply drag (Alt mod = 256)
        drag(totalDx, totalDy, 256);

        // Apply to camera state
        cam.az = targetAz;
        float clampedEl = targetEl;
        if (clampedEl >  MAX_ELEV) clampedEl =  MAX_ELEV;
        if (clampedEl < -MAX_ELEV) clampedEl = -MAX_ELEV;
        cam.el = clampedEl;

        // Release
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":256}`,
            t, mouseX, mouseY));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYUP","sym":1073742050,"scan":226,"mod":256}`, t));
        advance(16);
    }

    // --- Zoom operation ---
    // Applies Alt+Ctrl + LMB drag to reach targetDist.
    // Each pixel step dx=+1 → dist *= 0.99 (zoom in); dx=-1 → dist *= 1.01 (zoom out).
    void zoom(float targetDist) {
        // Compute number of pixel steps
        int totalDx;
        if (targetDist < cam.dist) {
            // Zoom in: dist *= 0.99^n, n = log(target/dist) / log(0.99)
            // log(0.99) < 0 and log(ratio) < 0, so n is positive → rightward drag ✓
            totalDx = cast(int)round(log(targetDist / cam.dist) / log(0.99f));
        } else {
            // Zoom out: dist *= 1.01^n per leftward step → need negative dx
            // n = log(target/dist) / log(1.01) is positive → negate for leftward motion
            totalDx = -cast(int)round(log(targetDist / cam.dist) / log(1.01f));
        }

        // Press Alt + Ctrl (mod = 256|64 = 320)
        emit(format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":1073742050,"scan":226,"mod":256,"repeat":0}`, t));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":1073742048,"scan":224,"mod":320,"repeat":0}`, t));
        advance();
        moveCursorTo(mouseX + 5, mouseY, 320);

        // Start drag
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":320}`,
            t, mouseX, mouseY));
        advance();

        // Apply zoom drag (Alt+Ctrl mod = 320), only horizontal movement
        drag(totalDx, 0, 320);

        // Apply to camera state
        cam.dist = targetDist;

        // Release
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":320}`,
            t, mouseX, mouseY));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYUP","sym":1073742048,"scan":224,"mod":256}`, t));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYUP","sym":1073742050,"scan":226,"mod":0}`, t));
        advance(16);
    }

    // --- Pan operation ---
    // Applies Alt+Shift + LMB drag to reach target focus.
    void pan(float focX, float focY, float focZ) {
        Vec3 off     = sphericalToCart(cam.az, cam.el, cam.dist);
        Vec3 forward = normalizeV(Vec3(-off.x, -off.y, -off.z));
        Vec3 right   = normalizeV(crossV(forward, Vec3(0, 1, 0)));
        Vec3 up      = crossV(right, forward);
        float speed  = cam.dist * 0.001f;

        Vec3 delta = Vec3(focX - cam.focus.x, focY - cam.focus.y, focZ - cam.focus.z);
        int totalDx = cast(int)round(-dotV(delta, right) / speed);
        int totalDy = cast(int)round( dotV(delta, up)    / speed);

        // Press Alt + Shift (mod = 256|1 = 257)
        emit(format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":1073742050,"scan":226,"mod":256,"repeat":0}`, t));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":1073742049,"scan":225,"mod":257,"repeat":0}`, t));
        advance();
        moveCursorTo(mouseX + 5, mouseY, 257);

        // Start drag
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":257}`,
            t, mouseX, mouseY));
        advance();

        // Apply pan drag (Alt+Shift mod = 257)
        drag(totalDx, totalDy, 257);

        // Apply to camera state
        cam.focus = Vec3(focX, focY, focZ);

        // Release
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":257}`,
            t, mouseX, mouseY));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYUP","sym":1073742049,"scan":225,"mod":256}`, t));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYUP","sym":1073742050,"scan":226,"mod":0}`, t));
        advance(16);
    }

    // --- Select vertices by index ---
    // Moves cursor over each vertex's projected screen position and selects it.
    // First vertex: regular LMB (clears selection, selects first).
    // Subsequent vertices: Shift+LMB drag (adds to selection).
    // vertices: array of cube vertex indices (0-7 for default cube).
    void selectVertices(size_t[] indices) {
        if (indices.length == 0) return;

        float[16] viewMat = cam.viewMatrix();
        float[16] projMat = cam.projMatrix();

        // Project all requested vertices to screen
        int[] screenX, screenY;
        foreach (idx; indices) {
            if (idx >= CUBE_VERTS.length) {
                stderr.writefln("Warning: vertex index %d out of range (cube has %d verts)", idx, CUBE_VERTS.length);
                continue;
            }
            Vec3 v = CUBE_VERTS[idx];
            float px, py;
            if (!project(v, viewMat, projMat, VP_X, VP_Y, VP_W, VP_H, px, py)) {
                stderr.writefln("Warning: vertex %d is behind camera, skipping", idx);
                continue;
            }
            screenX ~= cast(int)round(px);
            screenY ~= cast(int)round(py);
        }
        if (screenX.length == 0) return;

        // Move cursor to first vertex, LMB drag to select it (clears existing selection)
        moveCursorTo(screenX[0], screenY[0]);

        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
            t, mouseX, mouseY));
        advance();

        // Drag through remaining vertices (selection accumulates during drag)
        foreach (i; 1 .. screenX.length) {
            int dx = screenX[i] - mouseX;
            int dy = screenY[i] - mouseY;
            int steps = max(1, (abs(dx) + abs(dy)) / 20);
            int doneX = 0, doneY = 0;
            foreach (step; 1 .. steps + 1) {
                int tdx = cast(int)round(cast(float)dx * step / steps);
                int tdy = cast(int)round(cast(float)dy * step / steps);
                int xrel = tdx - doneX, yrel = tdy - doneY;
                doneX = tdx; doneY = tdy;
                if (xrel == 0 && yrel == 0) continue;
                mouseX += xrel; mouseY += yrel;
                emit(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}`,
                    t, mouseX, mouseY, xrel, yrel));
                advance();
            }
        }

        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":0}`,
            t, mouseX, mouseY));
        advance(32);
    }

    // --- Select vertices by adding to existing selection (Shift+LMB drag) ---
    // Does NOT clear the current selection. Shifts through each vertex position.
    void selectAddVertices(size_t[] indices) {
        if (indices.length == 0) return;

        float[16] viewMat = cam.viewMatrix();
        float[16] projMat = cam.projMatrix();

        int[] screenX, screenY;
        foreach (idx; indices) {
            if (idx >= CUBE_VERTS.length) {
                stderr.writefln("Warning: vertex index %d out of range", idx);
                continue;
            }
            Vec3 v = CUBE_VERTS[idx];
            float px, py;
            if (!project(v, viewMat, projMat, VP_X, VP_Y, VP_W, VP_H, px, py)) {
                stderr.writefln("Warning: vertex %d is behind camera, skipping", idx);
                continue;
            }
            screenX ~= cast(int)round(px);
            screenY ~= cast(int)round(py);
        }
        if (screenX.length == 0) return;

        // Press Shift, move to first vertex
        emit(format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":1073742049,"scan":225,"mod":1,"repeat":0}`, t));
        advance();
        moveCursorTo(screenX[0], screenY[0], 1);  // mod=1 (Shift held)

        // MOUSEBUTTONDOWN with Shift → dragMode = SelectAdd (no selection clear)
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":1}`,
            t, mouseX, mouseY));
        advance();

        // Drag through remaining vertices (mod=0 is fine for select modes, but keep consistent)
        foreach (i; 1 .. screenX.length) {
            int dx = screenX[i] - mouseX;
            int dy = screenY[i] - mouseY;
            int steps = max(1, (abs(dx) + abs(dy)) / 20);
            int doneX = 0, doneY = 0;
            foreach (step; 1 .. steps + 1) {
                int tdx = cast(int)round(cast(float)dx * step / steps);
                int tdy = cast(int)round(cast(float)dy * step / steps);
                int xrel = tdx - doneX, yrel = tdy - doneY;
                doneX = tdx; doneY = tdy;
                if (xrel == 0 && yrel == 0) continue;
                mouseX += xrel; mouseY += yrel;
                emit(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":1}`,
                    t, mouseX, mouseY, xrel, yrel));
                advance();
            }
        }

        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":1}`,
            t, mouseX, mouseY));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYUP","sym":1073742049,"scan":225,"mod":0}`, t));
        advance(32);
    }

    // --- Deselect vertices with Ctrl+LMB drag (SelectRemove mode) ---
    void selectRemoveVertices(size_t[] indices) {
        if (indices.length == 0) return;

        float[16] viewMat = cam.viewMatrix();
        float[16] projMat = cam.projMatrix();

        int[] screenX, screenY;
        foreach (idx; indices) {
            if (idx >= CUBE_VERTS.length) {
                stderr.writefln("Warning: vertex index %d out of range", idx);
                continue;
            }
            Vec3 v = CUBE_VERTS[idx];
            float px, py;
            if (!project(v, viewMat, projMat, VP_X, VP_Y, VP_W, VP_H, px, py)) {
                stderr.writefln("Warning: vertex %d is behind camera, skipping", idx);
                continue;
            }
            screenX ~= cast(int)round(px);
            screenY ~= cast(int)round(py);
        }
        if (screenX.length == 0) return;

        // Ctrl mod = 64 (KMOD_LCTRL)
        emit(format(`{"t":%.3f,"type":"SDL_KEYDOWN","sym":1073742048,"scan":224,"mod":64,"repeat":0}`, t));
        advance();
        moveCursorTo(screenX[0], screenY[0], 64);

        // MOUSEBUTTONDOWN with Ctrl → dragMode = SelectRemove
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":64}`,
            t, mouseX, mouseY));
        advance();

        foreach (i; 1 .. screenX.length) {
            int dx = screenX[i] - mouseX;
            int dy = screenY[i] - mouseY;
            int steps = max(1, (abs(dx) + abs(dy)) / 20);
            int doneX = 0, doneY = 0;
            foreach (step; 1 .. steps + 1) {
                int tdx = cast(int)round(cast(float)dx * step / steps);
                int tdy = cast(int)round(cast(float)dy * step / steps);
                int xrel = tdx - doneX, yrel = tdy - doneY;
                doneX = tdx; doneY = tdy;
                if (xrel == 0 && yrel == 0) continue;
                mouseX += xrel; mouseY += yrel;
                emit(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":64}`,
                    t, mouseX, mouseY, xrel, yrel));
                advance();
            }
        }

        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":64}`,
            t, mouseX, mouseY));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_KEYUP","sym":1073742048,"scan":224,"mod":0}`, t));
        advance(32);
    }

    // --- Click at a specific position (no drag) ---
    // Moves cursor to (x, y) then clicks LMB without holding.
    // Clears selection if no vertex is within 3px of (x, y).
    void click(int x, int y) {
        moveCursorTo(x, y);
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
            t, mouseX, mouseY));
        advance();
        emit(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":0,"mod":0}`,
            t, mouseX, mouseY));
        advance(32);
    }

    void flush() {
        foreach (line; lines)
            writeln(line);
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

immutable string[] ALL_OPS = [
    "orbit", "zoom", "pan",
    "select-vertices", "select-add-vertices", "select-remove-vertices", "click",
];

bool isOp(string s) {
    foreach (op; ALL_OPS) if (s == op) return true;
    return false;
}

void usage() {
    stderr.writeln(
        "Usage: gen_events <op> [args] [<op> [args] ...]\n" ~
        "\n" ~
        "Operations (can be chained in sequence):\n" ~
        "  orbit  <targetAz> <targetEl>                  — camera orbit\n" ~
        "  zoom   <targetDist>                            — camera zoom\n" ~
        "  pan    <targetFocX> <targetFocY> <targetFocZ>  — camera pan\n" ~
        "  select-vertices     <idx1> [idx2 ...]  — select cube vertices (clears existing selection)\n" ~
        "  select-add-vertices    <idx1> [idx2 ...]  — Shift+LMB: add vertices to current selection\n" ~
        "  select-remove-vertices <idx1> [idx2 ...]  — Ctrl+LMB: remove vertices from selection\n" ~
        "  click  <x> <y>                            — LMB click at window coords (clears selection if no vertex nearby)\n" ~
        "\n" ~
        "All operations start from the default camera state:\n" ~
        "  az=0.5, el=0.4, dist=3.0, focus=(0,0,0)\n" ~
        "  viewport: x=150, y=0, w=650, h=562\n" ~
        "\n" ~
        "Examples:\n" ~
        "  gen_events orbit -0.575 0.530 > tests/events/camera_rotate.log\n" ~
        "  gen_events select-vertices 4 6 click 475 350 > tests/events/deselect.log"
    );
}

int main(string[] args) {
    if (args.length < 2) { usage(); return 1; }

    EventGen gen;
    gen.writeHeader();

    size_t i = 1;
    while (i < args.length) {
        string op = args[i++];
        switch (op) {
            case "orbit":
                if (i + 2 > args.length) { stderr.writeln("orbit requires: <targetAz> <targetEl>"); return 1; }
                gen.orbit(args[i++].to!float, args[i++].to!float);
                break;

            case "zoom":
                if (i + 1 > args.length) { stderr.writeln("zoom requires: <targetDist>"); return 1; }
                gen.zoom(args[i++].to!float);
                break;

            case "pan":
                if (i + 3 > args.length) { stderr.writeln("pan requires: <targetFocX> <targetFocY> <targetFocZ>"); return 1; }
                gen.pan(args[i++].to!float, args[i++].to!float, args[i++].to!float);
                break;

            case "select-vertices": {
                size_t[] indices;
                while (i < args.length && !isOp(args[i]))
                    indices ~= args[i++].to!size_t;
                if (indices.length == 0) { stderr.writeln("select-vertices requires at least one index"); return 1; }
                gen.selectVertices(indices);
                break;
            }

            case "select-add-vertices": {
                size_t[] indices;
                while (i < args.length && !isOp(args[i]))
                    indices ~= args[i++].to!size_t;
                if (indices.length == 0) { stderr.writeln("select-add-vertices requires at least one index"); return 1; }
                gen.selectAddVertices(indices);
                break;
            }

            case "select-remove-vertices": {
                size_t[] indices;
                while (i < args.length && !isOp(args[i]))
                    indices ~= args[i++].to!size_t;
                if (indices.length == 0) { stderr.writeln("select-remove-vertices requires at least one index"); return 1; }
                gen.selectRemoveVertices(indices);
                break;
            }

            case "click":
                if (i + 2 > args.length) { stderr.writeln("click requires: <x> <y>"); return 1; }
                gen.click(args[i++].to!int, args[i++].to!int);
                break;

            default:
                stderr.writefln("Unknown operation: %s", op);
                usage();
                return 1;
        }
    }

    gen.flush();
    return 0;
}
