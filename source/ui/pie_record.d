module ui.pie_record;

// Drawn pie frames for test readback; task/evidence: doc/tasks/work/6208-pie-menu-reference-parity.md.
struct DrawnPieBox {
    int slot;
    string label;
    int x;
    int y;
    int w;
    int h;
    string face;
}

struct DrawnPieFrame {
    bool open;
    string menu;
    int cx;
    int cy;
    int unitH;
    int boxW;
    int hover = -1;
    string hubState = "idle";
    int tickSlot = -1;
    bool imguiCtrl;
    DrawnPieBox[] boxes;
    ulong publishes;
}

private __gshared DrawnPieFrame g_scratch;
private __gshared DrawnPieFrame g_published;
private __gshared Object g_mx;

shared static this() { g_mx = new Object(); }

void beginPieFrame(bool open, string menu, int cx, int cy, int unitH,
                   int hover) {
    import command : g_testMode;
    if (!g_testMode) return;
    g_scratch = DrawnPieFrame(open, menu, cx, cy, unitH, 0, hover,
                             hover >= 0 ? "aimed" : "idle", hover,
                             false, null, 0);
}

void setPieBoxWidth(int boxW) {
    import command : g_testMode;
    if (g_testMode) g_scratch.boxW = boxW;
}

void recordPieBox(DrawnPieBox box) {
    import command : g_testMode;
    if (g_testMode) g_scratch.boxes ~= box;
}

void endPieFrame() {
    import command : g_testMode;
    if (!g_testMode) return;
    import ImGui = d_imgui;
    g_scratch.imguiCtrl = ImGui.GetIO().KeyCtrl;
    synchronized (g_mx) {
        g_scratch.publishes = g_published.publishes + 1;
        g_published = g_scratch;
        g_published.boxes = g_scratch.boxes.dup;
    }
}

string pieFrameJson() {
    import std.json : JSONValue;
    DrawnPieFrame frame;
    synchronized (g_mx) {
        frame = g_published;
        frame.boxes = g_published.boxes.dup;
    }
    JSONValue[] boxes;
    foreach (ref box; frame.boxes) {
        JSONValue j;
        j["slot"] = JSONValue(box.slot);
        j["label"] = JSONValue(box.label);
        j["x"] = JSONValue(box.x);
        j["y"] = JSONValue(box.y);
        j["w"] = JSONValue(box.w);
        j["h"] = JSONValue(box.h);
        j["face"] = JSONValue(box.face);
        boxes ~= j;
    }
    JSONValue hub;
    hub["state"] = JSONValue(frame.hubState);
    hub["tickSlot"] = JSONValue(frame.tickSlot);
    JSONValue root;
    root["open"] = JSONValue(frame.open);
    root["menu"] = JSONValue(frame.menu);
    root["cx"] = JSONValue(frame.cx);
    root["cy"] = JSONValue(frame.cy);
    root["unitH"] = JSONValue(frame.unitH);
    root["boxW"] = JSONValue(frame.boxW);
    root["hover"] = JSONValue(frame.hover);
    root["hub"] = hub;
    root["imguiCtrl"] = JSONValue(frame.imguiCtrl);
    root["boxes"] = JSONValue(boxes);
    root["publishes"] = JSONValue(frame.publishes);
    return root.toString();
}
