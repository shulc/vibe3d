/// Point sampling for `GET /api/viewport/probe` (card slot-resource-isolation).
///
/// ONE READBACK PER REQUEST, and that is the contract, not an optimisation.
/// The provider used to call `glReadPixels` once per requested point. Each
/// call is a full GPU round trip for this context, and under a shared GPU
/// (two gate pairs = 32+ `--test` instances on one card) a round trip costs
/// milliseconds: a 3000-point lattice measured 5.15 s on a 32-instance rig and
/// ran past the HTTP bridge's 5 s main-thread wait, which is the `HTTP 500`
/// `timeout waiting for main thread` the display tests reported. The same rig
/// answers one point in 11 ms. So the cost scales with the NUMBER OF READS, and
/// the requests are served from a single rectangle read covering every point.
/// Evidence and the before/after table: the card, `tools/local/probe-backlog-rig.sh`.
module viewport_probe_sampling;

import std.array : Appender;

/// One requested sample: the caller's coordinates (top-left origin) and
/// whether they fall inside the `W x H` target.
struct ProbePoint {
    int x, y;
    bool inside;
}

/// A readback rectangle in GL coordinates (origin bottom-left). `w == 0`
/// means nothing needs reading.
struct ProbeReadRect {
    int x, y, w, h;
}

/// Reads `w x h` RGBA8 pixels at GL coordinates `(x, y)` into `rgba`, tightly
/// packed, rows bottom-up (glReadPixels' layout).
alias ProbePixelReader = void delegate(int x, int y, int w, int h, ubyte[] rgba);

/// Parse `x,y;x,y;...`. Empty and malformed specs are dropped, exactly as the
/// per-point loop dropped them, so the response shape is unchanged.
ProbePoint[] parseProbePoints(string points, int W, int H) {
    import std.array  : split;
    import std.conv   : to;
    import std.string : strip;

    ProbePoint[] result;
    foreach (spec; points.split(";")) {
        auto s = spec.strip();
        if (s.length == 0) continue;
        auto xy = s.split(",");
        if (xy.length != 2) continue;
        int px, py;
        try {
            px = xy[0].strip.to!int;
            py = xy[1].strip.to!int;
        } catch (Exception) {
            continue;
        }
        result ~= ProbePoint(px, py,
                             px >= 0 && py >= 0 && px < W && py < H);
    }
    return result;
}

/// The smallest GL-space rectangle that covers every inside point.
ProbeReadRect probeReadRect(const(ProbePoint)[] pts, int H) {
    bool any;
    int x0, x1, y0, y1;   // top-left space, inclusive
    foreach (p; pts) {
        if (!p.inside) continue;
        if (!any) { x0 = x1 = p.x; y0 = y1 = p.y; any = true; continue; }
        if (p.x < x0) x0 = p.x;
        if (p.x > x1) x1 = p.x;
        if (p.y < y0) y0 = p.y;
        if (p.y > y1) y1 = p.y;
    }
    if (!any) return ProbeReadRect.init;
    // Flip: top-left row y is GL row H-1-y, so the rect's GL bottom is row y1.
    return ProbeReadRect(x0, H - 1 - y1, x1 - x0 + 1, y1 - y0 + 1);
}

/// Append the `"points":[...]` array for `points` against a `W x H` target,
/// calling `read` AT MOST ONCE (never for a request with no inside point).
void putProbePoints(ref Appender!string buf, string points, int W, int H,
                    scope ProbePixelReader read) {
    import std.format : format;

    auto pts = parseProbePoints(points, W, H);
    const rect = probeReadRect(pts, H);
    ubyte[] pixels;
    if (rect.w > 0) {
        pixels = new ubyte[](cast(size_t)rect.w * rect.h * 4);
        read(rect.x, rect.y, rect.w, rect.h, pixels);
    }

    buf.put(`"points":[`);
    foreach (i, p; pts) {
        if (i) buf.put(",");
        if (!p.inside) {
            buf.put(format(`{"x":%d,"y":%d,"error":"outside the cell"}`, p.x, p.y));
            continue;
        }
        const col = p.x - rect.x;
        const row = (H - 1 - p.y) - rect.y;
        const at  = (cast(size_t)row * rect.w + col) * 4;
        buf.put(format(`{"x":%d,"y":%d,"r":%d,"g":%d,"b":%d,"a":%d}`,
                       p.x, p.y, pixels[at], pixels[at + 1],
                       pixels[at + 2], pixels[at + 3]));
    }
    buf.put("]");
}
