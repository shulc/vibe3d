module lib.portpolicy;
// Which HTTP port the perf harness may clear and launch on (task 9220).
//
// The harness clears any vibe3d on its port before launching (lib.lifecycle
// `killStaleVibe`), so its port must never be one a gate worker listens on:
// the old default 8088 is worker 8 of run_test.d slot 0, and a perf run beside
// a gate SIGTERMed that worker mid-suite (gate-pool logs 2026-10-02). The
// forbidden windows are DERIVED from tools.harness.runslots, the module that
// hands workers their ports, so a change of slot count or stride moves the
// refusal with it. A `PerfPort` exists only through `admitPerfPort`, and the
// kill/launch seams take a `PerfPort`, so no port reaches a kill unadmitted.

import std.format : format;
import tools.harness.runslots : kMaxRunSlots, kPrivateFamilies,
    kPrivateFamilySpan, kPrivatePortBase, kSlotPortStride, slotPortBase;

/// Half-open port window [lo, hiExclusive) owned by somebody else.
struct PortRange {
    int lo, hiExclusive;
    string owner;
    bool contains(int p) const { return p >= lo && p < hiExclusive; }
}

/// Every window a run_test.d worker can listen on: the canonical family's
/// kMaxRunSlots slot windows, and the private (test-seam) families' blocks.
PortRange[] gateWorkerPortRanges() {
    return [
        PortRange(slotPortBase(0),
                  slotPortBase(kMaxRunSlots - 1) + kSlotPortStride,
                  format("run_test.d slot windows 0..%d", kMaxRunSlots - 1)),
        PortRange(kPrivatePortBase,
                  kPrivatePortBase + kPrivateFamilies * kPrivateFamilySpan,
                  "run_test.d private-family worker blocks"),
    ];
}

/// Task-lane HTTP ports: tools/local/task-wt-new.sh hands each lane a 10-port
/// block at 8300 + 10*((first/block) % 60). This window COPIES that formula
/// (60 blocks of 10 from 8300) rather than deriving it: the script lives in
/// the private tree, which this module cannot read. Change both together. An
/// explicit lane port is the normal way to run perf in a lane, so it is
/// ADMITTED; only the default must stay out of it (a default run would clear
/// some lane's instance).
enum PortRange kLanePortBlocks = PortRange(8300, 8900, "task-lane port blocks");

/// Default port: outside every gate worker window and every lane block.
enum ushort kPerfDefaultPort = 8990;

/// The flag that admits a worker-window port anyway.
enum string kAllowWorkerPortFlag = "allow-gate-worker-port";

/// A port the policy has admitted. Not default-constructible and its
/// constructor is module-private: `admitPerfPort` is the only way to get one.
/// `value_` is immutable, so neither a tuple-of nor a get-member write can
/// change it and a held `PerfPort` cannot be reassigned. What the type cannot
/// refuse (its init value, void initialisation, a pointer cast, a string
/// mix-in) is refused by the raw-text census in tests/unit/perf_port_policy_test.d.
struct PerfPort {
    private immutable ushort value_;
    @disable this();
    private this(ushort v) { value_ = v; }
    ushort value() const { return value_; }
}

class PerfPortRefused : Exception {
    this(string msg) { super(msg); }
}

/// Is `port` inside a gate worker window? `w` names the window when it is.
bool inGateWorkerWindow(ushort port, out PortRange w) {
    foreach (r; gateWorkerPortRanges())
        if (r.contains(port)) { w = r; return true; }
    return false;
}

/// Admit `port`, or throw PerfPortRefused BEFORE anything is killed. A port in
/// a gate worker window is admitted only with `allowWorkerPort`.
PerfPort admitPerfPort(ushort port, bool allowWorkerPort) {
    PortRange w;
    if (inGateWorkerWindow(port, w)) {
        if (!allowWorkerPort)
            throw new PerfPortRefused(format(
                "refusing --http-port %d: it is inside %s [%d, %d), where "
                ~ "gate workers listen, and this harness clears any vibe3d on "
                ~ "its port before launching -- it would kill a gate worker. "
                ~ "Use the default (%d) or your lane port, or pass --%s if "
                ~ "you mean it.",
                port, w.owner, w.lo, w.hiExclusive, kPerfDefaultPort,
                kAllowWorkerPortFlag));
    }
    return PerfPort(port);
}
