// Pure half of the parallel module gate (task 7900): how the roster is packed
// onto worker processes, what a worker's result file says, and the verdict a
// parent may draw from N of them. The process orchestration lives in
// tests/unit/ut_runner.d; everything here is data in, data out, so each way a
// merge can lie (a skipped module, a duplicated one, a shard that died) has a
// cell below that makes it say so. Card: doc/tasks/work/parallel-module-gate.md.
module tests.unit.ut_shard_plan;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.format : format;
import std.string : lineSplitter, split, startsWith, strip;

/// Modules that must share ONE worker process, so they never run concurrently
/// with each other. A group is packed as a single item and keeps the serial
/// order inside its shard. Each row names the resource the group shares; the
/// census cell below keeps the port group closed over the tree.
immutable string[][] kPinnedGroups = [
    // PORTS: each of these starts a real HttpServer (or binds a listening
    // socket) on a port it chose by binding port 0 and closing it again. That
    // choose-then-bind window is harmless in one process, where the modules
    // run one after another, and a collision between two processes that run
    // them at once.
    kPortGroup,
];

immutable string[] kPortGroup = [
    "tests.unit.frame_counts_owner_test",
    "tests.unit.frame_probe_owner_test",
    "tests.unit.history_http_adapter_test",
    "tests.unit.history_replay_boundary_test",
    "tests.unit.http_server_test",
    "tests.unit.model_handles_owned_transport_test",
    "tests.unit.playback_owner_test",
    "tests.unit.request_result_ownership_test",
    "tests.unit.selection_projection_test",
    "tests.unit.test_mode_request_gate_test",
    "tests.unit.tool_state_owned_route_test",
    // Spawns a real worker process on a port chosen the same way.
    "ai3d.worker_manager",
];

/// Parse `UT <ms> <module>` lines (the VIBE3D_UT_TIMINGS format).
double[string] parseTimings(string text)
{
    double[string] result;
    foreach (line; text.lineSplitter)
    {
        const fields = line.strip.split;
        if (fields.length != 3 || fields[0] != "UT")
            continue;
        try
            result[fields[2]] = fields[1].to!double;
        catch (Exception)
            continue;
    }
    return result;
}

/// Pack `roster` (ModuleInfo order) onto at most `n` shards. With timings the
/// pack is greedy longest-processing-time-first; without any, round-robin.
/// A module missing from `weights` weighs the median of the known ones.
/// Returned shards hold roster INDICES in ascending order, so every worker
/// runs its modules in the serial gate's relative order. Empty shards are
/// dropped.
size_t[][] packShards(const string[] roster, const double[string] weights,
                      size_t n, const string[][] pinned)
{
    assert(n >= 1, "packShards needs at least one shard");
    size_t[][] shards = new size_t[][](n);

    if (weights.length == 0)
    {
        // Round-robin, but a pinned group still travels as one item.
        size_t[][] items = groupItems(roster, pinned);
        foreach (i, item; items)
            shards[i % n] ~= item;
    }
    else
    {
        double[] known = weights.values.dup;
        known.sort;
        const fallback = known[known.length / 2];
        double weightOf(size_t idx)
        {
            if (auto w = roster[idx] in weights)
                return *w;
            return fallback;
        }

        size_t[][] items = groupItems(roster, pinned);
        // D initialises doubles to NaN, and NaN compares false both ways.
        auto itemWeight = new double[](items.length);
        itemWeight[] = 0;
        foreach (i, item; items)
            foreach (idx; item)
                itemWeight[i] += weightOf(idx);

        size_t[] order = new size_t[](items.length);
        foreach (i; 0 .. items.length)
            order[i] = i;
        // Heaviest first; ties by first roster index, so the pack is a pure
        // function of its inputs.
        order.sort!((a, b) => itemWeight[a] > itemWeight[b]
            || (itemWeight[a] == itemWeight[b] && items[a][0] < items[b][0]));

        auto load = new double[](n);
        load[] = 0;
        foreach (i; order)
        {
            size_t best = 0;
            foreach (s; 1 .. n)
                if (load[s] < load[best])
                    best = s;
            shards[best] ~= items[i];
            load[best] += itemWeight[i];
        }
    }

    size_t[][] result;
    foreach (shard; shards)
    {
        if (!shard.length)
            continue;
        auto sorted = shard.dup;
        sorted.sort;
        result ~= sorted;
    }
    return result;
}

// Each pinned group present in the roster becomes one item (its members in
// roster order); every other module is an item of its own.
private size_t[][] groupItems(const string[] roster, const string[][] pinned)
{
    size_t[string] indexOf;
    foreach (i, name; roster)
        indexOf[name] = i;
    bool[size_t] grouped;
    size_t[][] items;
    foreach (group; pinned)
    {
        size_t[] item;
        foreach (name; group)
            if (auto idx = name in indexOf)
                if (*idx !in grouped)
                {
                    item ~= *idx;
                    grouped[*idx] = true;
                }
        if (item.length)
        {
            item.sort;
            items ~= item;
        }
    }
    foreach (i; 0 .. roster.length)
        if (i !in grouped)
            items ~= [i];
    // Items in the order of their first member, so round-robin is stable.
    items.sort!((a, b) => a[0] < b[0]);
    return items;
}

/// Problems with a plan before anything is spawned: every roster index must
/// appear exactly once, and every pinned group present must sit on one shard.
string[] validatePlan(const string[] roster, const size_t[][] shards,
                      const string[][] pinned)
{
    string[] problems;
    auto seen = new size_t[](roster.length);
    size_t[string] shardOf;
    foreach (s, shard; shards)
        foreach (idx; shard)
        {
            if (idx >= roster.length)
            {
                problems ~= format("shard %d holds index %d outside the roster of %d",
                                   s, idx, roster.length);
                continue;
            }
            ++seen[idx];
            shardOf[roster[idx]] = s;
        }
    foreach (i, count; seen)
        if (count != 1)
            problems ~= format("module %s is planned %d times, expected once",
                               roster[i], count);
    foreach (group; pinned)
    {
        size_t[] where;
        foreach (name; group)
            if (auto s = name in shardOf)
                if (!where.canFind(*s))
                    where ~= *s;
        if (where.length > 1)
            problems ~= format("pinned group %s is split over shards %s",
                               group, where);
    }
    return problems;
}

/// What one worker process left behind.
struct ShardOutcome
{
    size_t index;
    string[] assigned;      // what the parent told it to run
    string resultText;      // its result file, "" when there is none
    bool exited;            // terminated normally (not by a signal)
    int status;             // exit code when `exited`, signal number otherwise
}

struct ModuleReport
{
    string name;
    bool passed;
    double ms;
}

/// The parent's verdict over all shards.
struct MergeVerdict
{
    string[] problems;      // non-empty = the run is NOT a gate result
    size_t executed;        // modules reported + modules never reported
    size_t passed;          // modules REPORTED as passed, nothing else
    ModuleReport[] reports; // every valid report, any shard
}

/// Merge shard outcomes against the dispatched roster. A module counts as
/// passed only when a shard REPORTED it passed and that shard then closed its
/// file and exited consistently; a module nobody reported counts as executed
/// and failed, so an incomplete run can never print executed == passed.
MergeVerdict mergeShards(const string[] roster, const ShardOutcome[] outcomes)
{
    MergeVerdict v;
    size_t[string] reportedCount;
    bool[string] tainted;   // reported by a shard that has a problem of its own

    foreach (o; outcomes)
    {
        const problemsBefore = v.problems.length;
        string[] started;
        ModuleReport[] reports;
        bool began, ended;
        size_t endExecuted, endPassed;
        string refusal;
        foreach (line; o.resultText.lineSplitter)
        {
            const f = line.strip.split;
            if (!f.length)
                continue;
            switch (f[0])
            {
            case "UT-SHARD-BEGIN":
                began = f.length == 2 && f[1] == o.index.to!string;
                break;
            case "UT-MOD-START":
                if (f.length == 2) started ~= f[1];
                break;
            case "UT-MOD":
                if (f.length == 4 && (f[1] == "PASS" || f[1] == "FAIL"))
                {
                    double ms = 0;
                    try ms = f[2].to!double; catch (Exception) {}
                    reports ~= ModuleReport(f[3], f[1] == "PASS", ms);
                }
                else
                    v.problems ~= format("shard %d: malformed line `%s`",
                                         o.index, line);
                break;
            case "UT-SHARD-END":
                if (f.length == 3 && f[1].startsWith("executed=")
                    && f[2].startsWith("passed="))
                {
                    ended = true;
                    try
                    {
                        endExecuted = f[1]["executed=".length .. $].to!size_t;
                        endPassed = f[2]["passed=".length .. $].to!size_t;
                    }
                    catch (Exception)
                        ended = false;
                }
                break;
            case "UT-SHARD-REFUSED":
                refusal = line.strip;
                break;
            default:
                break;
            }
        }

        const label = format("shard %d (%d modules)", o.index, o.assigned.length);
        if (!o.resultText.length)
            v.problems ~= label ~ ": wrote no result file";
        else if (!began)
            v.problems ~= label ~ ": result file has no valid UT-SHARD-BEGIN line";
        if (refusal.length)
            v.problems ~= label ~ ": " ~ refusal;
        if (!o.exited)
            v.problems ~= format("%s: killed by signal %d", label, o.status);
        if (!ended)
        {
            string running = started.length > reports.length
                ? " while running " ~ started[$ - 1] : "";
            v.problems ~= format("%s: no UT-SHARD-END line; it stopped after "
                ~ "reporting %d module(s)%s", label, reports.length, running);
        }

        size_t shardPassed;
        size_t[string] mine;
        foreach (r; reports)
        {
            if (!o.assigned.canFind(r.name))
                v.problems ~= format("%s reported %s, which it was not assigned",
                                     label, r.name);
            if (++mine.require(r.name, 0) > 1)
                v.problems ~= format("%s reported %s %d times", label, r.name,
                                     mine[r.name]);
            if (r.passed) ++shardPassed;
        }
        foreach (name; o.assigned)
            if (name !in mine)
                v.problems ~= format("%s never reported assigned module %s",
                                     label, name);
        if (ended && (endExecuted != reports.length || endPassed != shardPassed))
            v.problems ~= format("%s: UT-SHARD-END says executed=%d passed=%d, "
                ~ "its module lines say %d and %d", label, endExecuted, endPassed,
                reports.length, shardPassed);
        if (o.exited && ended)
        {
            const want = shardPassed == reports.length ? 0 : 1;
            if (o.status != want)
                v.problems ~= format("%s: exit status %d, expected %d for "
                    ~ "%d/%d passed", label, o.status, want, shardPassed,
                    reports.length);
        }

        const shardTainted = v.problems.length != problemsBefore;
        foreach (r; reports)
        {
            ++reportedCount.require(r.name, 0);
            if (shardTainted)
                tainted[r.name] = true;
            v.reports ~= r;
        }
    }

    bool[string] inRoster;
    foreach (name; roster)
    {
        inRoster[name] = true;
        const c = reportedCount.get(name, 0);
        if (c != 1)
            v.problems ~= format("module %s was reported %d times across all "
                                 ~ "shards, expected once", name, c);
    }
    foreach (name, c; reportedCount)
        if (name !in inRoster)
            v.problems ~= format("module %s was reported but never dispatched", name);

    // A pass counts only when it is the module's single report and the shard
    // that made it closed its file and exited consistently: a shard that lied
    // or died forfeits every pass it printed.
    foreach (r; v.reports)
        if (r.passed && reportedCount[r.name] == 1 && r.name in inRoster
            && r.name !in tainted)
            ++v.passed;
    // Executed is the dispatched population whenever anything is missing, so
    // the missing ones read as failures, never as a smaller clean total.
    v.executed = v.problems.length ? roster.length : v.reports.length;
    // Holds by construction: passes are counted over reports seen exactly once
    // in the roster, and executed is the roster length or the report count.
    assert(v.passed <= v.executed, "mergeShards counted more passes than executions");
    return v;
}

// ---------------------------------------------------------------------------

version (unittest)
{
    private immutable string[] kRoster = ["m.a", "m.b", "m.c", "m.d", "m.e"];

    private string cleanResult(size_t shard, const string[] names,
                               const string[] failed = [])
    {
        string text = format("UT-SHARD-BEGIN %d\n", shard);
        size_t passed;
        foreach (n; names)
        {
            const ok = !failed.canFind(n);
            if (ok) ++passed;
            text ~= format("UT-MOD-START %s\nUT-MOD %s 1.000 %s\n", n,
                           ok ? "PASS" : "FAIL", n);
        }
        return text ~ format("UT-SHARD-END executed=%d passed=%d\n",
                             names.length, passed);
    }

    private ShardOutcome[] cleanRun()
    {
        return [
            ShardOutcome(0, ["m.a", "m.c", "m.e"],
                         cleanResult(0, ["m.a", "m.c", "m.e"]), true, 0),
            ShardOutcome(1, ["m.b", "m.d"],
                         cleanResult(1, ["m.b", "m.d"]), true, 0),
        ];
    }

    private bool mentions(const string[] problems, string needle)
    {
        foreach (p; problems)
            if (p.canFind(needle))
                return true;
        return false;
    }
}

unittest // the clean control: two consistent shards merge to the serial total
{
    const v = mergeShards(kRoster, cleanRun());
    assert(v.problems.length == 0, format("clean run flagged: %s", v.problems));
    assert(v.executed == 5 && v.passed == 5,
        format("clean run merged to executed=%d passed=%d", v.executed, v.passed));
}

unittest // a shard that silently skips a module is red, and the total says so
{
    auto run = cleanRun();
    // m.c is dropped from the file entirely: no START, no MOD line, and the
    // END line is rewritten to agree -- the worst case, a consistent liar.
    run[0].resultText = cleanResult(0, ["m.a", "m.e"]);
    const v = mergeShards(kRoster, run);
    assert(mentions(v.problems, "never reported assigned module m.c"),
        format("skipped module not named: %s", v.problems));
    // The lying shard forfeits the passes it did print (m.a, m.e): only the
    // honest shard's two count.
    assert(v.executed == 5 && v.passed == 2,
        format("a skip must read executed=5 passed=2, got %d/%d",
               v.executed, v.passed));
}

unittest // a module run twice (one per shard, or twice in one) is red
{
    auto run = cleanRun();
    run[1].resultText = cleanResult(1, ["m.b", "m.d", "m.c"]);
    run[1].assigned = ["m.b", "m.d", "m.c"];
    const v = mergeShards(kRoster, run);
    assert(mentions(v.problems, "m.c was reported 2 times"),
        format("cross-shard duplicate not named: %s", v.problems));
    // Neither shard lied about its own assignment, so no shard is tainted:
    // only the single-report rule keeps the duplicate from counting twice.
    assert(v.passed < v.executed, format(
        "a cross-shard duplicate merged to a clean %d/%d", v.passed, v.executed));

    auto twice = cleanRun();
    twice[0].resultText = cleanResult(0, ["m.a", "m.c", "m.c", "m.e"]);
    const w = mergeShards(kRoster, twice);
    assert(mentions(w.problems, "reported m.c 2 times"),
        format("in-shard duplicate not named: %s", w.problems));
    assert(w.passed < w.executed, format(
        "an in-shard duplicate merged to a clean %d/%d", w.passed, w.executed));
}

unittest // each merge rule names its own breach (one cell per rule)
{
    // A result file that belongs to another shard (files swapped).
    auto swapped = cleanRun();
    swapped[0].resultText = cleanResult(1, ["m.a", "m.c", "m.e"]);
    assert(mentions(mergeShards(kRoster, swapped).problems,
        "shard 0 (3 modules): result file has no valid UT-SHARD-BEGIN"));

    // A shard that ran a module it was not given.
    auto stray = cleanRun();
    stray[0].resultText = cleanResult(0, ["m.a", "m.b", "m.c", "m.e"]);
    stray[1].resultText = cleanResult(1, ["m.d"]);
    assert(mentions(mergeShards(kRoster, stray).problems,
        "shard 0 (3 modules) reported m.b, which it was not assigned"));

    // An END line that disagrees with the module lines above it.
    auto liar = cleanRun();
    liar[1].resultText = "UT-SHARD-BEGIN 1\nUT-MOD PASS 1.0 m.b\nUT-MOD PASS 1.0 m.d\n"
                       ~ "UT-SHARD-END executed=3 passed=3\n";
    assert(mentions(mergeShards(kRoster, liar).problems,
        "UT-SHARD-END says executed=3 passed=3, its module lines say 2 and 2"));

    // A roster module that no shard was given at all.
    auto orphan = cleanRun();
    orphan[0].assigned = ["m.a", "m.c"];
    orphan[0].resultText = cleanResult(0, ["m.a", "m.c"]);
    const o = mergeShards(kRoster, orphan);
    assert(mentions(o.problems, "module m.e was reported 0 times"),
        format("an undispatched roster module was not named: %s", o.problems));
    assert(o.executed == 5 && o.passed == 4, format("%d/%d", o.executed, o.passed));

    // A module nobody dispatched, reported anyway.
    auto ghost = cleanRun();
    ghost[1].assigned = ["m.b", "m.d", "m.z"];
    ghost[1].resultText = cleanResult(1, ["m.b", "m.d", "m.z"]);
    assert(mentions(mergeShards(kRoster, ghost).problems,
        "module m.z was reported but never dispatched"));

    // A worker that refused its assignment.
    auto refused = cleanRun();
    refused[1].resultText = "UT-SHARD-BEGIN 1\nUT-SHARD-REFUSED assigned 2 modules, "
                          ~ "this binary has 1 of them with unittests\n";
    refused[1].status = 2;
    assert(mentions(mergeShards(kRoster, refused).problems,
        "UT-SHARD-REFUSED assigned 2 modules"));
}

unittest // a crashed shard is red with the module it died in, never a smaller green
{
    auto run = cleanRun();
    // Died by SIGSEGV inside m.c: START written, no MOD, no END.
    run[0].resultText = "UT-SHARD-BEGIN 0\nUT-MOD-START m.a\nUT-MOD PASS 1.0 m.a\n"
                      ~ "UT-MOD-START m.c\n";
    run[0].exited = false;
    run[0].status = 11;
    const v = mergeShards(kRoster, run);
    assert(mentions(v.problems, "killed by signal 11"), format("%s", v.problems));
    assert(mentions(v.problems, "while running m.c"), format("%s", v.problems));
    assert(v.executed == 5 && v.passed == 2,
        format("a crashed shard must forfeit all its modules, got %d/%d",
               v.executed, v.passed));

    // Exit 0 with no file at all is just as red.
    auto silent = cleanRun();
    silent[1].resultText = "";
    const s = mergeShards(kRoster, silent);
    assert(mentions(s.problems, "wrote no result file") && s.passed == 3
        && s.executed == 5, format("%s %d/%d", s.problems, s.executed, s.passed));
}

unittest // exit status must agree with the shard's own lines
{
    auto run = cleanRun();
    run[1].resultText = cleanResult(1, ["m.b", "m.d"], ["m.d"]);
    run[1].status = 1;
    const v = mergeShards(kRoster, run);
    assert(v.problems.length == 0 && v.executed == 5 && v.passed == 4,
        format("an honest failure must merge cleanly as 4/5: %s", v.problems));

    run[1].status = 0; // claims success over a FAIL line
    assert(mentions(mergeShards(kRoster, run).problems, "exit status 0, expected 1"));
}

unittest // the pack: each module once, pinned groups whole, LPT balance
{
    const roster = ["a", "b", "c", "d", "e", "f", "g"];
    const double[string] w = ["a": 10, "b": 1, "c": 1, "d": 9, "e": 1, "f": 1, "g": 8];
    const string[][] pinned = [["b", "f"]];
    const shards = packShards(roster, w, 3, pinned);
    assert(validatePlan(roster, shards, pinned).length == 0,
        format("pack produced an invalid plan %s", shards));
    assert(shards.length == 3, format("expected 3 shards, got %s", shards));
    // The three heavy modules land on three different shards.
    foreach (s; shards)
        assert(s.canFind(0) + s.canFind(3) + s.canFind(6) == 1,
            format("LPT did not spread the heavy modules: %s", shards));

    // Round-robin without timings still keeps the group together.
    const rr = packShards(roster, null, 3, pinned);
    assert(validatePlan(roster, rr, pinned).length == 0,
        format("round-robin produced an invalid plan %s", rr));

    // validatePlan sees a duplicate and a split group.
    assert(validatePlan(roster, [[0, 1, 2, 3], [3, 4, 5, 6]], pinned)
        .mentions("module d is planned 2 times"));
    assert(validatePlan(roster, [[0, 1, 2, 3], [4, 6]], pinned)
        .mentions("module f is planned 0 times"));
    assert(validatePlan(roster, [[0, 1, 2], [3, 4, 5, 6]], pinned)
        .mentions("pinned group"));
}

unittest // census: every unittest module that listens on a chosen port is pinned
{
    import std.algorithm : filter;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildPath, dirName, extension;
    import std.regex : ctRegex, escaper, matchAll, matchFirst, regex;
    import std.conv : text;

    enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    // A text scan, so it over-approximates. The POPULATION is every module
    // with a unittest that constructs an HttpServer or binds a socket itself.
    // A module LISTENS when it binds, or when some variable it assigned
    // `new HttpServer(` to has `.start()` called on it -- any name.
    static immutable newServerRx = ctRegex!(`\b(\w+)\s*=\s*new HttpServer\(`);
    static immutable anyServerRx = ctRegex!(`new HttpServer\(`);
    static immutable bindRx = ctRegex!(`\.bind\(new InternetAddress\(`);
    static immutable moduleRx = ctRegex!(`(?m)^module\s+([\w.]+)\s*;`);
    enum Exempt { listens, neverStarts }
    static immutable Exempt[string] exempt = [
        // Binds port 0 and KEEPS the listener open; the kernel owns that port
        // for as long as the test needs it.
        "tests.unit.ai3d.job_controller_test": Exempt.listens,
        // Production modules with no unittest block of their own: the text
        // says `unittest` only in prose, and the bind is the product.
        "http_transport": Exempt.listens,
        "app": Exempt.listens,
        // Construct an HttpServer and drive it in-process, never start()ing
        // it: no socket. Exempt only while that stays true.
        "tests.unit.portless_route_ports_test": Exempt.neverStarts,
        "tests.unit.playback_parse_owner_test": Exempt.neverStarts,
        "application_command_binding_ownership_test": Exempt.neverStarts,
        "tests.unit.live_registration_rig": Exempt.neverStarts,
        "tests.unit.version_gate_census_ai3d_remesh_test": Exempt.neverStarts,
        "http_server": Exempt.neverStarts,
    ];

    string[] offenders;
    size_t population, listeners;
    foreach (root; ["tests/unit", "source"])
        foreach (e; dirEntries(buildPath(repoRoot, root), SpanMode.depth)
                    .filter!(e => e.isFile && e.name.extension == ".d"))
        {
            if (e.name == __FILE_FULL_PATH__)
                continue;
            const src = readText(e.name);
            if (!src.canFind("unittest"))
                continue;
            const binds = !!matchFirst(src, bindRx);
            if (!binds && !matchFirst(src, anyServerRx))
                continue;
            auto m = matchFirst(src, moduleRx);
            if (!m)
                continue;
            ++population;
            bool serves;
            foreach (c; matchAll(src, newServerRx))
                if (matchFirst(src, regex(text(`\b`, escaper(c[1]), `\.start\(\)`))))
                    serves = true;
            const listens = binds || serves;
            if (listens)
                ++listeners;
            if (kPortGroup.canFind(m[1]))
                continue;
            if (auto x = m[1] in exempt)
            {
                if (*x == Exempt.listens || !listens)
                    continue;
            }
            else if (!listens)
                offenders ~= m[1] ~ " (constructs an HttpServer; exempt it as neverStarts or pin it)";
            if (listens)
                offenders ~= m[1];
        }
    assert(offenders.length == 0, format(
        "these unittest modules listen on a port but are neither in kPortGroup "
      ~ "nor exempt, so the parallel module gate may run them beside another "
      ~ "server test and collide on a port: %s", offenders));
    // The group only protects anything if the PRODUCTION runner packs and
    // validates with it: pin the table and the two call texts in ut_runner.d.
    assert(kPinnedGroups.canFind(kPortGroup),
        "kPortGroup is no longer one of kPinnedGroups, so nothing pins it");
    const runner = readText(buildPath(repoRoot, "tests", "unit", "ut_runner.d"));
    foreach (call; ["packShards(roster, weights, jobs, kPinnedGroups)",
                    "validatePlan(roster, shards, kPinnedGroups)"])
        assert(runner.canFind(call),
            "tests/unit/ut_runner.d no longer calls `" ~ call ~ "`");
    // Population floors, measured 2026-09-25: a scan that matched nothing
    // would pass the checks above.
    assert(population == kPortGroup.length + exempt.length, format(
        "the port census matched %d modules, kPortGroup + exempt list %d",
        population, kPortGroup.length + exempt.length));
    assert(listeners == kPortGroup.length + 3, format(
        "the port census found %d listening modules, expected %d",
        listeners, kPortGroup.length + 3));
}

unittest // CI caps the workers to its core count (the VM reports 16 vCPUs on 4 cores)
{
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : indexOf;

    enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    const ci = readText(buildPath(repoRoot, ".github", "workflows", "ci.yaml"));
    const run = ci.indexOf("run: xvfb-run -a dub test --config=tests --compiler=dmd");
    assert(run > 0, "ci.yaml lost its module-gate step");
    const env = ci[0 .. run].lastIndexOfEnv;
    assert(ci[env .. run].canFind("VIBE3D_UT_JOBS: 4"),
        "ci.yaml's module-gate step no longer sets VIBE3D_UT_JOBS: 4; the "
      ~ "default would start min(8, CPUs) workers on a 7.7 GiB VM");
}

version (unittest) private size_t lastIndexOfEnv(const(char)[] text)
{
    import std.string : lastIndexOf;
    const at = text.lastIndexOf("      env:\n");
    return at < 0 ? 0 : cast(size_t) at;
}
