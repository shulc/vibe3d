module tools.harness.runslots;

// Host run SLOTS (task 6205): N counting slots replace the one host-wide run
// lock. Every heavy test lane on a host -- `run_test.d`, the module gate
// (`dub test --config=tests`) and the gate-pool dispatcher -- holds exactly ONE
// slot, taken as the first free member of the family by flock(LOCK_NB), and
// never waits while holding one. A nightly perf window takes EVERY member of
// the family (kMaxRunSlots, not the configured N), so perf stays exclusive
// however N is configured. Holders of one slot never block while holding, and
// perf acquires in ascending order, so no wait cycle exists.
//
// Slot 0 IS the pre-6205 lock path. An unrebased lane still flocks that one
// file and still puts its workers on 8080.., which is exactly slot 0's port
// window, so old and new code exclude each other where they could collide.
//
// The env seam keeps its old name (VIBE3D_PERF_RUNTEST_LOCK_PATH): it names the
// family BASE, so every test that isolated the old lock isolates the whole
// family (and the per-checkout build lock) with no further change.

import core.sys.posix.fcntl     : open, O_CREAT, O_RDWR;
import core.sys.posix.sys.stat  : stat, stat_t;
import core.sys.posix.sys.types : ssize_t;
import core.sys.posix.unistd    : close, ftruncate, getpid, getppid;
import std.algorithm : canFind;
import std.conv      : octal, to;
import std.file      : exists, readText;
import std.format    : format;
import std.path      : buildPath;
import std.process   : environment;
import std.string    : lineSplitter, startsWith, strip, toStringz;

extern(C) private int flock(int fd, int operation) nothrow @nogc;
private pragma(mangle, "write")
extern(C) ssize_t slotWrite(int fd, const(void)* buf, size_t count) nothrow @nogc;
private enum LOCK_EX = 2, LOCK_NB = 4, LOCK_UN = 8;

enum kRunSlotBaseEnv        = "VIBE3D_PERF_RUNTEST_LOCK_PATH";
enum kRunSlotsEnv           = "VIBE3D_RUN_SLOTS";
enum kCanonicalRunSlotBase  = "/tmp/vibe3d-run-test.lock";
enum kInheritedRunLockPidEnv = "VIBE3D_INHERITED_RUN_LOCK_PID";
enum kInheritedRunLockFdEnv  = "VIBE3D_INHERITED_RUN_LOCK_FD";

/// The family's size. Perf takes all of these; N is clamped to it.
enum int kMaxRunSlots = 6;
/// Default N: two full gates fit this host's 62 GB beside the writers' own
/// builds (measurements in the 6205 card). Per host: VIBE3D_RUN_SLOTS or the
/// one-integer file runSlotsConfigPath().
enum int kDefaultRunSlots = 2;

/// Default worker ports: slot k owns [8080 + 36k, 8080 + 36k + 36). Six
/// windows end at 8295, below the lane port blocks that start at 8300. A
/// PRIVATE family (the test seam) gets windows at 28080.. instead: a test's
/// nested runner must never clear a production run's workers by port.
enum ushort kDefaultPortBase = 8080;
enum ushort kPrivatePortBase = 28080;
enum ushort kSlotPortStride  = 36;

string runSlotBase()
{
    const configured = environment.get(kRunSlotBaseEnv, "");
    return configured.length ? configured : kCanonicalRunSlotBase;
}

string runSlotPath(string base, int k)
{
    return k == 0 ? base : format("%s.slot.%d", base, k);
}

string[] runSlotFamily(string base)
{
    string[] paths;
    foreach (k; 0 .. kMaxRunSlots) paths ~= runSlotPath(base, k);
    return paths;
}

/// The per-checkout build lock: one run per worktree, under the same seam.
string worktreeLockPath(string base, string root)
{
    import std.digest     : toHexString, LetterCase;
    import std.digest.md  : md5Of;
    return format("%s.wt.%s", base,
                  toHexString!(LetterCase.lower)(md5Of(root))[0 .. 12]);
}

ushort slotPortBase(int k, string base = kCanonicalRunSlotBase)
{
    const origin = base == kCanonicalRunSlotBase ? kDefaultPortBase : kPrivatePortBase;
    return cast(ushort)(origin + k * kSlotPortStride);
}

string runSlotsConfigPath()
{
    const xdg = environment.get("XDG_CONFIG_HOME", "");
    const root = xdg.length ? xdg : buildPath(environment.get("HOME", "/tmp"), ".config");
    return buildPath(root, "vibe3d", "run-slots");
}

struct SlotCount { int n; string source; string error; }

/// Parse one slot-count value; an out-of-range or malformed value is an ERROR,
/// never silently clamped, so a typo cannot turn a host exclusive or unbounded.
SlotCount parseSlotCount(string raw, string source)
{
    SlotCount c;
    c.source = source;
    try {
        const v = raw.strip.to!int;
        if (v >= 1 && v <= kMaxRunSlots) { c.n = v; return c; }
    } catch (Exception) {}
    c.error = format("%s: slot count '%s' is not an integer in 1..%d",
                     source, raw.strip, kMaxRunSlots);
    return c;
}

SlotCount configuredRunSlots()
{
    const env = environment.get(kRunSlotsEnv, "");
    if (env.length) return parseSlotCount(env, kRunSlotsEnv);
    const path = runSlotsConfigPath();
    if (exists(path)) {
        try return parseSlotCount(readText(path), path);
        catch (Exception e) return SlotCount(0, path, path ~ ": " ~ e.msg);
    }
    return SlotCount(kDefaultRunSlots, "default");
}

struct RunSlot
{
    int    fd = -1;      // ours to close; -1 when borrowed
    int    index = -1;
    string path;
    bool   borrowed;
    bool   held() const { return index >= 0; }
}

void stampSlot(int fd, string tag)
{
    if (fd < 0) return;
    ftruncate(fd, 0);
    const stamp = tag.length ? format("pid %d %s\n", getpid(), tag)
                             : format("pid %d\n", getpid());
    slotWrite(fd, stamp.ptr, stamp.length);
}

/// One non-blocking pass over slots 0..n-1. True with `s` filled on success.
bool tryAcquireFreeSlot(string base, int n, ref RunSlot s, string tag = "")
{
    foreach (k; 0 .. n) {
        const path = runSlotPath(base, k);
        const fd = open(path.toStringz, O_RDWR | O_CREAT, octal!"644");
        if (fd < 0) continue;
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            s = RunSlot(fd, k, path, false);
            stampSlot(fd, tag);
            return true;
        }
        close(fd);
    }
    return false;
}

void releaseSlot(ref RunSlot s)
{
    if (!s.borrowed && s.fd >= 0) {
        flock(s.fd, LOCK_UN);
        close(s.fd);
    }
    s = RunSlot.init;
}

/// Is `path` held right now? Probes with a momentary LOCK_NB, which is the
/// only way flock answers; a free slot is released again at once. A slot file
/// that does not exist is free, and the probe does not create it.
bool slotHeld(string path)
{
    const fd = open(path.toStringz, O_RDWR);
    if (fd < 0) return false;
    scope(exit) close(fd);
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
        flock(fd, LOCK_UN);
        return false;
    }
    return true;
}

string slotStamp(string path)
{
    try return readText(path).strip;
    catch (Exception) return "";
}

bool processHasAncestor(int ancestor)
{
    int current = getppid();
    foreach (_; 0 .. 64) {
        if (current == ancestor) return true;
        if (current <= 1) return false;
        try {
            int parent;
            foreach (line; readText(format("/proc/%d/status", current)).lineSplitter) {
                if (!line.startsWith("PPid:")) continue;
                parent = line["PPid:".length .. $].strip.to!int;
                break;
            }
            if (parent <= 0 || parent == current) return false;
            current = parent;
        } catch (Exception) {
            return false;
        }
    }
    return false;
}

/// The family index whose file `st` is, or -1.
private int slotIndexOf(string base, ref const stat_t st)
{
    foreach (k; 0 .. kMaxRunSlots) {
        stat_t slot;
        if (stat(runSlotPath(base, k).toStringz, &slot) != 0) continue;
        if (slot.st_dev == st.st_dev && slot.st_ino == st.st_ino) return k;
    }
    return -1;
}

private bool fdinfoShowsFlock(string fdinfo)
{
    try {
        foreach (line; readText(fdinfo).lineSplitter)
            if (line.startsWith("lock:") && line.canFind("FLOCK") && line.canFind("WRITE"))
                return true;
    } catch (Exception) {}
    return false;
}

/// Which slot of `base`'s family does descriptor `fd` OF PROCESS `holder`
/// hold a flock on? -1 when none. Two routes, because each fails somewhere:
///   * the descriptor was INHERITED (it is open in this process too): fstat
///     it and read /proc/self/fdinfo -- works inside a user namespace, where
///     another process's /proc/<pid>/fd is not readable;
///   * it was NOT (`dub test` closes inherited fds before running the module
///     gate): read the holder's /proc/<pid>/fd and fdinfo instead.
/// Either way the flock must be visible on that open file description, so an
/// unlocked descriptor on a slot file is not a lease.
int heldSlotOf(string base, int holder, int fd)
{
    import core.sys.posix.sys.stat : fstat;
    stat_t own;
    if (fstat(fd, &own) == 0) {
        const k = slotIndexOf(base, own);
        if (k >= 0 && fdinfoShowsFlock(format("/proc/self/fdinfo/%d", fd)))
            return k;
    }
    stat_t held;
    if (stat(format("/proc/%d/fd/%d", holder, fd).toStringz, &held) != 0)
        return -1;
    const k = slotIndexOf(base, held);
    if (k < 0) return -1;
    return fdinfoShowsFlock(format("/proc/%d/fdinfo/%d", holder, fd)) ? k : -1;
}

/// A descendant may borrow a slot its live ANCESTOR holds (a nested runner, or
/// the gates under a gate-pool dispatcher). Everyone else must queue. A lease
/// that is SET but rejected is said out loud: the caller then takes a second
/// slot while its ancestor holds the first, which is legal but is exactly the
/// "wait while holding" shape a lease exists to avoid.
bool borrowInheritedSlot(string base, ref RunSlot s)
{
    import std.stdio : stderr;
    const rawPid = environment.get(kInheritedRunLockPidEnv, "");
    const rawFd  = environment.get(kInheritedRunLockFdEnv, "");
    if (!rawPid.length && !rawFd.length) return false;
    bool reject(string why)
    {
        stderr.writefln("warning: run-slot lease %s=%s %s=%s rejected (%s); "
                      ~ "taking a slot of my own instead",
                        kInheritedRunLockPidEnv, rawPid, kInheritedRunLockFdEnv,
                        rawFd, why);
        return false;
    }
    int holder, fd;
    try { holder = rawPid.to!int; fd = rawFd.to!int; }
    catch (Exception) return reject("not two integers");
    if (holder <= 1 || fd < 0) return reject("out of range");
    if (!processHasAncestor(holder)) return reject("the holder is not my ancestor");
    const k = heldSlotOf(base, holder, fd);
    if (k < 0) return reject("that descriptor holds no flock on a slot of " ~ base);
    s = RunSlot(-1, k, runSlotPath(base, k), true);
    return true;
}

unittest // slot paths: slot 0 is the pre-6205 lock, the rest are distinct
{
    const fam = runSlotFamily(kCanonicalRunSlotBase);
    assert(fam.length == 6, "family size moved");
    assert(fam[0] == "/tmp/vibe3d-run-test.lock",
        "slot 0 must stay the legacy lock path so unrebased lanes still exclude it");
    assert(fam[1] == "/tmp/vibe3d-run-test.lock.slot.1");
    foreach (i; 0 .. fam.length)
        foreach (j; i + 1 .. fam.length)
            assert(fam[i] != fam[j], "two slots share a path");
}

unittest // default worker-port windows are disjoint and stay below 8300
{
    assert(slotPortBase(0) == 8080, "slot 0 keeps the legacy default port");
    foreach (k; 0 .. kMaxRunSlots - 1)
        assert(slotPortBase(k) + kSlotPortStride <= slotPortBase(k + 1),
            format("slot %d's port window overlaps slot %d's", k, k + 1));
    assert(slotPortBase(kMaxRunSlots - 1) + kSlotPortStride <= 8300,
        "the last slot's window reaches the lane port blocks at 8300");
    assert(slotPortBase(5, "/tmp/private.lock") + kSlotPortStride <= 65535
        && slotPortBase(0, "/tmp/private.lock") >= slotPortBase(5) + kSlotPortStride,
        "a private family's port windows overlap the production family's");
}

unittest // a slot count is 1..6 or an error, never a silent clamp
{
    assert(parseSlotCount("2", "t").n == 2);
    assert(parseSlotCount(" 6\n", "t").n == 6);
    foreach (bad; ["0", "7", "-1", "two", ""]) {
        const c = parseSlotCount(bad, "t");
        assert(c.n == 0 && c.error.length, "accepted slot count '" ~ bad ~ "'");
    }
}
