module app_version;

// ---------------------------------------------------------------------------
// app_version — what this binary is, decided at compile time (task 0641).
//
// THE SOURCE OF TRUTH IS THE `appVersion` LITERAL BELOW. It is source code, not
// a build artifact: no git call, no generated module, no string import, no
// network. `dub build` in a clean clone unpacked from a tarball on a machine
// with no git installed produces a binary that can still name itself. That
// property is the reason this is a plain enum and not `git describe`.
//
// Two mirrors are kept honest by machinery instead of by discipline:
//
//   1. `dub.json`'s own `"version"` field. It has to exist (it is what `dub
//      describe`, and any future package consumer, reads) but it is a SECOND
//      place the number is written, and a second place is a place to drift.
//      tests/test_app_version.d parses dub.json and fails when it disagrees
//      with what the running binary reports.
//
//   2. The release tag. `.github/workflows/build.yml`'s `check` job refuses to
//      build when `vX.Y.Z` does not equal this literal. The check runs BEFORE
//      the matrix, so a mismatched tag costs no build time. Deliberately a
//      VERIFICATION and not a substitution: nothing injects the tag into the
//      binary, so the binary cannot be made to claim a version its source did
//      not carry.
//
// The build date comes from D's `__DATE__` token — a compile-time builtin, so
// it costs no build step and cannot break an offline build. It exists to
// separate nightlies from each other and from the release they share a version
// with: nightlies run at most once a day and only when a commit landed, so
// "0.0.2 built Aug 09 2026" names exactly one build. A short commit hash would
// name it more precisely, and was rejected on price — see the task file.
//
// Everything a user needs to paste into a bug report is in `appAboutLines`.
// That array is drawn by the About window AND printed by `--version` AND
// served by `/api/version`; it is ONE array precisely so those three can never
// tell three different stories.
// ---------------------------------------------------------------------------

/// The version of this editor. Bump here, and only here, to cut a release; the
/// CI tag check and the dub.json test both key off this literal.
enum appVersion = "0.0.2";

/// Compile date, `Mmm dd yyyy` (D builtin — no build step, no git).
///
/// Caveat, deliberately accepted: dub rebuilds the whole package when any
/// source file changes, so this is fresh for CI (which builds from a fresh
/// checkout, and whose nightly only runs when a commit landed) and stale only
/// for an incremental developer build where nothing recompiled.
enum appBuildDate = __DATE__;

/// Which build configuration produced this binary. Ordered WithRender first:
/// the `with-render` configuration defines WithAI too.
version (WithRender)  enum appBuildConfig = "with-render";
else version (WithAI) enum appBuildConfig = "modeling";
else                  enum appBuildConfig = "modeling-noai";

private {
    version (Windows)      enum kOs = "windows";
    else version (OSX)     enum kOs = "macos";
    else version (linux)   enum kOs = "linux";
    else version (FreeBSD) enum kOs = "freebsd";
    else                   enum kOs = "unknown-os";

    // macOS ships both slices, so the architecture is load-bearing in a report,
    // not decoration.
    version (X86_64)       enum kArch = "x86_64";
    else version (AArch64) enum kArch = "arm64";
    else version (X86)     enum kArch = "x86";
    else                   enum kArch = "unknown-arch";
}

/// OS + architecture, e.g. `linux-x86_64`, `macos-arm64`, `windows-x86_64`.
enum appPlatform = kOs ~ "-" ~ kArch;

/// The identity block, as lines.
///
/// This IS the About window's row model, the `--version` output and the
/// `/api/version` payload. A consumer that builds its own string instead of
/// reading this array is the bug this module exists to prevent, and
/// tests/test_app_version.d compares the terminal against the served copy to
/// catch exactly that.
///
/// `immutable` module data rather than an `enum`: an enum array literal
/// allocates a fresh array at every use site, and the About window draws it
/// once per frame.
immutable string[] appAboutLines = [
    "vibe3d "    ~ appVersion,
    "build: "    ~ appBuildConfig,
    "platform: " ~ appPlatform,
    "built: "    ~ appBuildDate,
];
