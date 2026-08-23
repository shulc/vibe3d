module input_context;

// ---------------------------------------------------------------------------
// The context a chord is pressed IN (task 1810).
//
// Three slots:
//
//   zone     — which panel / viewport the cursor is over
//   mode     — the current selection type
//   whenTool — the armed tool
//
// A fourth is deliberately absent: WHICH ELEMENT the cursor is over inside a
// viewport — a vertex, an edge, a handle, empty space. It is a later step, it
// needs `hover_state`, and it is the least load-bearing of the four: the great
// majority of a realistic binding set does not care what is under the pointer,
// only which panel the pointer is in.
//
// WHY THE CONTEXT IS COMPUTED PER EVENT AND NOT STORED PER BINDING: a binding
// is a static fact about configuration; the context is a live fact about this
// keystroke. Resolving one against the other is a pure function
// (`shortcuts.resolveBinding`), which is the only reason "which binding won"
// is testable at all.
//
// THE CURSOR PROBLEM, NAMED: a keyboard event carries no coordinates. The
// position used is `eventlog.queryMouse`, i.e. the last position the app saw —
// which under event replay is the position the LOG says, not wherever the
// developer's real mouse rests. `commands/ui/pie.d` already depends on this
// for the same reason; reading SDL directly would make every replayed test
// resolve against the machine it happens to run on.
// ---------------------------------------------------------------------------

struct InputContext {
    string zone;      // "" = over nothing we have named
    string mode;      // "vertex" | "edge" | "polygon" | "item"; "" = unknown
    string whenTool;  // active tool id; "" = no tool armed

    int cursorX = -1; // what `zone` was resolved from — reported, not matched
    int cursorY = -1;
}

/// Build the context for the keystroke happening now.
///
/// `selType` and `activeToolId` are passed in rather than reached for, so this
/// module depends on neither `seltype` nor the editor: the two callers that
/// have them (the keyboard router and the HTTP probe) are the two places that
/// should be deciding what "current" means.
InputContext currentInputContext(string selTypeName, string activeToolId) {
    import eventlog    : queryMouse;
    import input_zones : zoneAt;

    InputContext ctx;
    int mx, my;
    queryMouse(mx, my);
    ctx.cursorX  = mx;
    ctx.cursorY  = my;
    ctx.zone     = zoneAt(mx, my);
    ctx.mode     = selTypeName;
    ctx.whenTool = activeToolId;
    return ctx;
}

// ---------------------------------------------------------------------------
// Published readback for `GET /api/input/context` (task 1810 Ф5).
//
// "Which binding won" is otherwise INVISIBLE. A chord that resolved to the
// wrong row and a chord that resolved to nothing look identical from outside —
// in both cases the thing you expected did not happen — so a test could pin
// the outcome of one scoped binding and never notice that it was winning for
// the wrong reason. This endpoint makes the resolution itself the observable.
//
// Two halves, published differently because they change at different rates:
//
//   * the ZONE RECTANGLES and the live mode/tool are a per-frame fact, mirrored
//     under a lock the same way `ui/availability.d` mirrors its drawn buttons —
//     the reader gets one whole frame, never a half-built one;
//   * the BINDING TABLE is immutable after startup, so it is snapshotted once.
//     That is what lets the HTTP thread run `resolveBinding` itself: the
//     resolver is pure, and re-running it off-thread against a frozen table
//     cannot disagree with what the keyboard router did.
// ---------------------------------------------------------------------------

import input_zones : Zone;
import shortcuts   : Binding;

private __gshared Zone[]   g_pubZones;
private __gshared string   g_pubMode;
private __gshared string   g_pubTool;
private __gshared int      g_pubCurX = -1, g_pubCurY = -1;
private __gshared Binding[] g_bindingSnapshot;
private __gshared Object   g_mx;

shared static this() { g_mx = new Object(); }

/// Freeze the loaded input map for off-thread resolution. Called once, after
/// `loadShortcuts`.
void setBindingSnapshot(Binding[] bindings) {
    synchronized (g_mx) { g_bindingSnapshot = bindings.dup; }
}

/// Mirror this frame's zone layout and live slots. Called once per frame from
/// the draw loop, right after the zone frame is published.
void publishInputContext(Zone[] zones, string mode, string tool, int curX, int curY) {
    synchronized (g_mx) {
        g_pubZones = zones.dup;
        g_pubMode  = mode;
        g_pubTool  = tool;
        g_pubCurX  = curX;
        g_pubCurY  = curY;
    }
}

/// `GET /api/input/context[?x=&y=][&key=<canon>]`.
///
/// With no `x`/`y` the answer is for the cursor the app last saw; with them,
/// for that point — which is what lets a test ask "what would this chord do
/// over the Items panel" without moving anything.
string inputContextJson(bool havePoint, int px, int py, string canon) {
    import std.json : JSONValue;
    import shortcuts : resolveBinding, bindingWeight, BindingKind;
    import std.conv  : to;

    Zone[]    zones;
    Binding[] binds;
    string    mode, tool;
    int       cx, cy;
    synchronized (g_mx) {
        zones = g_pubZones.dup;
        binds = g_bindingSnapshot.dup;
        mode  = g_pubMode;
        tool  = g_pubTool;
        cx    = g_pubCurX;
        cy    = g_pubCurY;
    }

    immutable int qx = havePoint ? px : cx;
    immutable int qy = havePoint ? py : cy;

    // Same last-published-wins rule as `input_zones.zoneAt`, over the mirror.
    string zone = "";
    foreach (ref z; zones)
        if (z.contains(qx, qy)) zone = z.name;

    JSONValue root;
    root["zone"]    = JSONValue(zone);
    root["mode"]    = JSONValue(mode);
    root["tool"]    = JSONValue(tool);
    root["cursorX"] = JSONValue(qx);
    root["cursorY"] = JSONValue(qy);

    JSONValue[] zj;
    foreach (ref z; zones) {
        JSONValue o;
        o["name"] = JSONValue(z.name);
        o["x"] = JSONValue(cast(int) z.x);
        o["y"] = JSONValue(cast(int) z.y);
        o["w"] = JSONValue(cast(int) z.w);
        o["h"] = JSONValue(cast(int) z.h);
        zj ~= o;
    }
    root["zones"] = JSONValue(zj);

    if (canon.length > 0) {
        root["key"] = JSONValue(canon);
        immutable int bi = resolveBinding(binds, canon, zone, mode, tool);
        if (bi < 0) {
            root["matched"] = JSONValue(false);
        } else {
            auto b = binds[bi];
            JSONValue m;
            m["kind"]     = JSONValue(b.kind == BindingKind.tool ? "tool"
                                    : b.kind == BindingKind.command ? "command"
                                    : "editmode");
            m["id"]       = JSONValue(b.id);
            m["args"]     = JSONValue(b.args);
            m["weight"]   = JSONValue(bindingWeight(b));
            m["zone"]     = JSONValue(b.zone);
            m["mode"]     = JSONValue(b.mode);
            m["whenTool"] = JSONValue(b.whenTool);
            m["scoped"]   = JSONValue(b.scoped_);
            root["matched"] = JSONValue(true);
            root["binding"] = m;
        }
    }
    return root.toString();
}
