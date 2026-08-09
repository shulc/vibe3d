// Tool Properties id namespace — identical labels in two sections are LEGAL
// (task 0640).
//
// WHAT IS BEING ASSERTED, AND WHY IT IS THE OPPOSITE OF THE OBVIOUS TEST.
//
// The panel used to render every section header and every stage row with no
// PushID anywhere, so the whole column shared ONE ImGui id scope and a label
// did two jobs at once: text for a human, key for ImGui. Two stages could not
// pick the same word — `constrain` and `path` both labelled their master
// toggle "Enabled" and were, to ImGui, one widget drawn twice.
//
// The tempting test is "no two labels in the column are equal". That test pins
// the DEFECT: it demands exactly the property the fix exists to abolish, and it
// would go green on a build that renamed one label and left the flat namespace
// in place. So this test does the reverse — it BUILDS the collision (two
// sections whose rows carry the same label; two sections whose TITLES are the
// same string) and asserts the panel gives them distinct identities anyway.
// If a future change dodges a clash by renaming, the setup assertions below
// fail and say so.
//
// HOW THE CONFLICT IS OBSERVED WITHOUT PIXELS.
//
// ImGui's own diagnostic ("N visible items with conflicting ID!", a dark-red
// panel plus a red box round each culprit) reaches a user as pixels and writes
// nothing to stderr — and it only arms while the mouse HOVERS one of the
// culprits, because imgui.cpp counts duplicates inside ItemHoverable. Our
// harness cannot hover an ImGui widget at all, and this was measured, not
// assumed (task 0640):
//
//   * `--test` DROPS real keyboard/mouse input (source/app.d, SDL_PollEvent
//     loop), so an xdotool pointer over a widget never reaches ImGui;
//   * the synthetic SDL events `/api/play-events` injects carry no `windowID`
//     (source/eventlog.d never sets one), and the ImGui SDL backend's very
//     first act on a mouse event is to resolve `windowID` to a viewport and
//     bail when it is unknown.
//
// Both halves were confirmed on a live instance under Xvfb: with a REAL
// pointer and no `--test`, hovering either "Enabled" checkbox raises the red
// panel with both checkboxes boxed on the pre-fix build, and raises nothing on
// the fixed one (hover itself verified by pixel value, so the clean shot is
// not just a shot that missed).
//
// So the panel instead records, as it draws, the ids ImGui itself would assign
// — the same `GetID` hash at the same point in the same id stack — and serves
// them at GET /api/toolprops/ids. Equal ids ARE the conflict; that is the
// condition ImGui's detector tests, minus the hover it needs to notice.
//
// The payload also carries, per section, the id the header WOULD have had with
// no scope open (`sectionUnscoped`). That is this test's built-in "before"
// value: for the two stacked falloffs it is the SAME number for both, which is
// the collision, in the same response that shows the real ids differ.
//
// VERIFIED BY MUTATION. Each wrong implementation below was applied to the
// green tree, built, and run; the reported value is the one observed.
//
//   M1  `PropertyPanel.pushScope` opens no ImGui scope (the pre-fix state:
//       sections share the window's namespace) →
//       RED: the "Enabled" rows of `constrain` and `path` share ImGui id
//       1698505582.
//
//   M2  `drawProvider` pushes no per-row scope (the section scope alone) →
//       RED: rows path/enabled and path/index draw under the SAME id seed
//       (4167788489). Note assertions 1 and 2 stay GREEN under M2 — distinct
//       section scopes still separate the two "Enabled" rows — so the seed
//       assertion is the only thing that catches it.
//
//   M3  the section scope wraps the BODY only, leaving the header at window
//       scope →
//       RED: the two "Linear Falloff" section headers share ImGui id
//       939269766 — the same number the payload reports as their
//       `sectionUnscoped` id, which is what "the header was never covered"
//       looks like.

import std.net.curl : get, post;
import std.json     : parseJSON, JSONValue, JSONType;
import std.conv     : to;
import std.format   : format;
import core.thread  : Thread;
import core.time    : msecs;

void main() {}

string baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

void cmd(string line) {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/command", line));
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

struct IdEntry {
    string section;
    string kind;
    string key;
    string label;
    ulong  id;

    string where() const {
        return section.length ? format("%s/%s", section, key) : key;
    }
}

IdEntry[] fetchIds() {
    // ImGuiID is a u32 widened to a JSON number; std.json picks INTEGER or
    // UINTEGER by value, so read whichever arrived.
    static ulong idOf(JSONValue v) {
        return v.type == JSONType.uinteger ? v.uinteger : cast(ulong) v.integer;
    }
    auto j = parseJSON(cast(string) get(baseUrl ~ "/api/toolprops/ids"));
    IdEntry[] outp;
    foreach (v; j["items"].array)
        outp ~= IdEntry(v["section"].str, v["kind"].str, v["key"].str,
                        v["label"].str, idOf(v["id"]));
    return outp;
}

/// The panel records while it draws, so the first read after a command can
/// land before the frame that reflects it. Poll for the rig instead of
/// sleeping a guessed interval.
IdEntry[] awaitIds(bool delegate(IdEntry[]) ready, string what) {
    IdEntry[] ids;
    foreach (_; 0 .. 100) {
        ids = fetchIds();
        if (ready(ids)) return ids;
        Thread.sleep(50.msecs);
    }
    assert(false, "Tool Properties never drew " ~ what
        ~ " (got " ~ ids.length.to!string ~ " recorded ids)");
}

// Rows are addressed by (kind, enclosing section, wire name) — two stages can
// and do carry the same wire name. Section entries are addressed by (kind,
// key) alone: `key` IS the section id, and their own `section` attribution
// depends on where in `drawSection` the record is taken, which is one of the
// things under test.
bool has(IdEntry[] ids, string kind, string section, string key) {
    foreach (ref e; ids)
        if (e.kind == kind && e.section == section && e.key == key) return true;
    return false;
}

IdEntry pick(IdEntry[] ids, string kind, string section, string key) {
    foreach (ref e; ids)
        if (e.kind == kind && e.section == section && e.key == key) return e;
    assert(false, format("no %s entry for %s/%s in the recorded column",
                         kind, section, key));
}

bool hasK(IdEntry[] ids, string kind, string key) {
    foreach (ref e; ids) if (e.kind == kind && e.key == key) return true;
    return false;
}

IdEntry pickK(IdEntry[] ids, string kind, string key) {
    foreach (ref e; ids) if (e.kind == kind && e.key == key) return e;
    assert(false, format("no %s entry keyed %s in the recorded column",
                         kind, key));
}

/// Undo everything the rig turned on, whether the assertions passed or blew up.
void restoreSharedInstance() {
    try {
        cmd("ui.toolProperties hide");
        cmd("tool.pipe.attr path enabled false");
        post(baseUrl ~ "/api/reset", "");
    } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------

unittest {
    post(baseUrl ~ "/api/reset", "");
    // Leave the shared instance as found, however this ends — a visible Tool
    // Properties window swallows the synthetic viewport drags other tests
    // depend on, and a stacked falloff bleeds into any test that reads the
    // WGHT stage. Armed BEFORE the rig, so a command that throws half-way
    // through building it still gets cleaned up. (A `try` cannot live inside a
    // `scope(exit)` body in D, so the restore is a function.)
    scope(exit) restoreSharedInstance();

    // ---- the rig ----------------------------------------------------------
    // Two stages whose rows share a LABEL: `constrain` is registered enabled
    // out of the box, `path` needs its master toggle (which is the pipe
    // registration flag on that stage) turned on to draw a section at all.
    //
    // Two stages whose SECTION TITLES are the same string: a primary falloff
    // and a stacked extra of the same type both render "Linear Falloff".
    //
    // A tool must be active for the panel to open, and under --test the panel
    // itself is opt-in.
    cmd("tool.set move");
    cmd("tool.pipe.attr path enabled true");
    cmd("falloff.linear");
    cmd("falloff.add linear");
    cmd("ui.toolProperties show");

    auto ids = awaitIds(x => has(x, "row", "constrain", "enabled")
                          && has(x, "row", "path", "enabled")
                          && hasK(x, "section", "falloff")
                          && hasK(x, "section", "falloff#1"),
                        "the constrain/path rows and both falloff sections");

    // ---- setup: the collision is really built -----------------------------
    // These are not decoration. They are the guard against "fix" by rename:
    // if either pair stops sharing its string, the situation under test no
    // longer exists and the assertions below would pass vacuously.
    auto consEnabled = pick(ids, "row", "constrain", "enabled");
    auto pathEnabled = pick(ids, "row", "path",      "enabled");
    assert(consEnabled.label == pathEnabled.label,
        format("setup: the two master toggles must still carry the SAME label "
             ~ "(constrain=\"%s\", path=\"%s\") — identical labels are the "
             ~ "thing being made legal, so renaming one to dodge the clash "
             ~ "empties this test instead of fixing anything",
               consEnabled.label, pathEnabled.label));

    auto fo0     = pickK(ids, "section",         "falloff");
    auto fo1     = pickK(ids, "section",         "falloff#1");
    auto fo0Root = pickK(ids, "sectionUnscoped", "falloff");
    auto fo1Root = pickK(ids, "sectionUnscoped", "falloff#1");
    assert(fo0.label == fo1.label,
        format("setup: the two falloff sections must still carry the SAME "
             ~ "title (\"%s\" vs \"%s\")", fo0.label, fo1.label));
    assert(fo0Root.id == fo1Root.id,
        format("setup: with no scope open the two \"%s\" headers must hash to "
             ~ "ONE id — that equality IS the collision this test resolves; "
             ~ "got %d vs %d, so the rig no longer reproduces it",
               fo0.label, fo0Root.id, fo1Root.id));

    // ---- 1. two stages, one label, two widgets ----------------------------
    assert(consEnabled.id != pathEnabled.id,
        format("the \"%s\" rows of `constrain` and `path` share ImGui id %d — "
             ~ "to ImGui that is ONE widget drawn twice: the click lands on "
             ~ "whichever drew first and the other is unreachable",
               consEnabled.label, consEnabled.id));

    // ---- 2. no two rows in the whole column are one widget ----------------
    foreach (i, ref a; ids) {
        if (a.kind != "row") continue;
        foreach (ref b; ids[i + 1 .. $]) {
            if (b.kind != "row") continue;
            assert(a.id != b.id,
                format("rows %s (\"%s\") and %s (\"%s\") both hash to id %d",
                       a.where, a.label, b.where, b.label, a.id));
        }
    }

    // ---- 3. every row owns its own id scope -------------------------------
    // Distinct SEEDS, not just distinct widget ids: this is what makes two
    // rows of the SAME stage free to share a label, and it also covers the
    // widgets whose label is not the row's — the enum radio emits one
    // RadioButton per entry, keyed on the entry's text.
    foreach (i, ref a; ids) {
        if (a.kind != "rowScope") continue;
        foreach (ref b; ids[i + 1 .. $]) {
            if (b.kind != "rowScope") continue;
            assert(a.id != b.id,
                format("rows %s and %s draw under the SAME id seed (%d) — "
                     ~ "any label they happen to share collides",
                       a.where, b.where, a.id));
        }
    }

    // ---- 4. two sections, one title, two headers --------------------------
    assert(fo0.id != fo1.id,
        format("the two \"%s\" section headers share ImGui id %d",
               fo0.label, fo0.id));
    foreach (i, ref a; ids) {
        if (a.kind != "section") continue;
        foreach (ref b; ids[i + 1 .. $]) {
            if (b.kind != "section") continue;
            assert(a.id != b.id,
                format("section headers %s (\"%s\") and %s (\"%s\") both hash "
                       ~ "to id %d", a.key, a.label, b.key, b.label, a.id));
        }
    }

    // ---- 5. the scope is open BEFORE the header is hashed -----------------
    // CollapsingHeader takes its id from its own label and is emitted outside
    // the section body, so a scope opened around the body only would leave the
    // header at window scope. Compare each header's real id against the id it
    // would have had there: equal means uncovered.
    int headers = 0;
    foreach (ref s; ids) {
        if (s.kind != "section") continue;
        auto root = pickK(ids, "sectionUnscoped", s.key);
        assert(s.id != root.id,
            format("section \"%s\" (%s) hashed its header to %d with no scope "
                 ~ "open — the id scope must cover the HEADER, not just the "
                 ~ "body", s.label, s.key, s.id));
        ++headers;
    }
    assert(headers >= 2,
        "setup: expected at least two collapsing sections in the column, got "
        ~ headers.to!string);
}
