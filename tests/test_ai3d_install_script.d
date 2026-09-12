// test_ai3d_install_script.d — offline test for
// tools/ai3d_worker/install_linux.sh (task 0403): --help and --dry-run must
// work without any network or filesystem side effects. The editor's
// Generate 3D panel "Install" confirmation popup / streamed-log flow calls
// this script for a REAL install; the automated suite only ever exercises
// --dry-run, per task 0403's "never run a real install here" instruction —
// a real run needs torch + a multi-GB TRELLIS clone, which is owner-only.

import std.algorithm.searching : canFind;
import std.conv    : octal, to;
import std.file    : exists, tempDir, mkdirRecurse, rmdirRecurse, setAttributes, write;
import std.path    : buildPath;
import std.process : execute, environment;
import std.random  : uniform;
import std.stdio   : stderr;

private enum installScript = "tools/ai3d_worker/install_linux.sh";

// D disallows a try/catch directly inside a scope(exit) statement, so
// best-effort cleanup goes through this nothrow helper instead (same
// pattern as remesh_job.d's own tryRemove).
private void tryRmdirRecurse(string dir) nothrow {
    try rmdirRecurse(dir); catch (Exception) {}
}

private enum GpuProbeCell {
    cudaMissing,
    vramMissing,
    transientCudaFailure,
}

private auto runGpuProbe(string scratch, GpuProbeCell cell) {
    const fakeBin = buildPath(scratch, "fake-bin");
    const fakeSmi = buildPath(fakeBin, "nvidia-smi");
    const callCount = buildPath(scratch, "nvidia-smi-call-count");
    mkdirRecurse(fakeBin);

    string body;
    final switch (cell) {
    case GpuProbeCell.cudaMissing:
        body =
            "case \"${1:-}\" in\n"
          ~ "  --query-gpu=name) printf 'Fake GPU\\n'; exit 0 ;;\n"
          ~ "  --query-gpu=memory.total) printf '12288\\n'; exit 0 ;;\n"
          ~ "esac\n"
          ~ "printf 'NVIDIA-SMI output without a version field\\n'\n";
        break;
    case GpuProbeCell.vramMissing:
        body =
            "case \"${1:-}\" in\n"
          ~ "  --query-gpu=name) printf 'Fake GPU\\n'; exit 0 ;;\n"
          ~ "  --query-gpu=memory.total) printf '[N/A]\\n'; exit 0 ;;\n"
          ~ "esac\n"
          ~ "printf 'CUDA Version: 13.1\\n'\n";
        break;
    case GpuProbeCell.transientCudaFailure:
        body =
            "case \"${1:-}\" in\n"
          ~ "  --query-gpu=name) printf 'Fake GPU\\n'; exit 0 ;;\n"
          ~ "  --query-gpu=memory.total) printf '12288\\n'; exit 0 ;;\n"
          ~ "esac\n"
          ~ "n=$(cat \"$VIBE3D_NVIDIA_CALL_COUNT\" 2>/dev/null || printf 0)\n"
          ~ "n=$((n + 1))\n"
          ~ "printf '%s\\n' \"$n\" > \"$VIBE3D_NVIDIA_CALL_COUNT\"\n"
          ~ "if [ \"$n\" -eq 1 ]; then printf 'CUDA Version: 13.1\\n'; exit 0; fi\n"
          ~ "printf 'transient nvidia-smi failure\\n' >&2\n"
          ~ "exit 255\n";
        break;
    }

    write(fakeSmi, "#!/bin/sh\n" ~ body);
    setAttributes(fakeSmi, octal!755);

    auto env = environment.toAA();
    env["PATH"] = fakeBin ~ ":" ~ environment.get("PATH", "");
    env["XDG_DATA_HOME"] = buildPath(scratch, "xdg-data");
    env["VIBE3D_REQUIRED_CUDA"] = "12.1";
    env["VIBE3D_MIN_VRAM_MB"] = "6000";
    env["VIBE3D_NVIDIA_CALL_COUNT"] = callCount;
    return execute(
        [installScript, "--dry-run", "--location", buildPath(scratch, "install-here"),
         "--trellis-root", buildPath(scratch, "unused-trellis-root")],
        env);
}

private bool selectedGpuProbe(string name) {
    const selected = environment.get("VIBE3D_AI3D_PREFLIGHT_CELL", "all");
    return selected == "all" || selected == name;
}

unittest {
    if (!exists(installScript)) {
        stderr.writeln("SKIP test_ai3d_install_script (install_linux.sh not found — cwd not repo root?)");
        return;
    }

    // --help exits 0 and documents every flag, without touching anything.
    auto help = execute([installScript, "--help"]);
    assert(help.status == 0, help.output);
    assert(help.output.canFind("--dry-run"));
    assert(help.output.canFind("--location"));
    assert(help.output.canFind("--trellis-root"));

    // --dry-run: prints the full plan, creates/downloads/writes NOTHING,
    // exits 0. XDG_DATA_HOME is overridden to a scratch dir so this test
    // can never touch a real user's ~/.local/share/vibe3d, even though
    // --dry-run itself is documented to write nothing there either way.
    const scratch = buildPath(tempDir(),
        "vibe3d_ai3d_install_test_" ~ uniform(0, int.max).to!string);
    const loc = buildPath(scratch, "install-here");
    scope(exit) tryRmdirRecurse(scratch);

    string[string] env;
    env["XDG_DATA_HOME"] = buildPath(scratch, "xdg-data");

    auto dry = execute(
        [installScript, "--dry-run", "--location", loc,
         "--trellis-root", "/tmp/vibe3d-test-nonexistent-trellis-root"],
        env);
    assert(dry.status == 0, dry.output);
    assert(dry.output.canFind("no changes made"), dry.output);
    assert(dry.output.canFind(loc), dry.output);
    assert(dry.output.canFind("~4 GB"), "plan must call out the separate model download size");

    assert(!exists(loc), "--dry-run must not create the install location");
    assert(!exists(env["XDG_DATA_HOME"]), "--dry-run must not write the config file");

    if (selectedGpuProbe("cuda")) {
        const probeScratch = buildPath(scratch, "cuda-missing");
        auto probe = runGpuProbe(probeScratch, GpuProbeCell.cudaMissing);
        assert(probe.status == 0,
               "cell 1: missing CUDA field must warn and continue; output:\n" ~ probe.output);
        assert(probe.output.canFind(
            "WARNING: could not read the driver's CUDA version from nvidia-smi (need >= 12.1)."),
            "cell 1: missing CUDA field must print its WARNING; output:\n" ~ probe.output);
    }

    if (selectedGpuProbe("vram")) {
        const probeScratch = buildPath(scratch, "vram-missing");
        auto probe = runGpuProbe(probeScratch, GpuProbeCell.vramMissing);
        assert(probe.status == 0,
               "cell 2: non-numeric VRAM must warn and continue; output:\n" ~ probe.output);
        assert(probe.output.canFind(
            "WARNING: could not read GPU VRAM from nvidia-smi (need >= 6000 MiB)."),
            "cell 2: non-numeric VRAM must print its WARNING; output:\n" ~ probe.output);
    }

    if (selectedGpuProbe("toctou")) {
        const probeScratch = buildPath(scratch, "transient-cuda-failure");
        auto probe = runGpuProbe(probeScratch, GpuProbeCell.transientCudaFailure);
        assert(probe.status == 0,
               "cell 3: a transient value-read failure must warn and continue; output:\n" ~ probe.output);
        assert(probe.output.canFind(
            "WARNING: could not read the driver's CUDA version from nvidia-smi (need >= 12.1)."),
            "cell 3: transient CUDA read failure must print its WARNING; output:\n" ~ probe.output);
    }
}

void main() {}
