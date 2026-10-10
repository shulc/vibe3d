module tests.unit.application_boundary_checker_test;

import std.algorithm : canFind;
import std.path : buildPath, dirName;
import std.process : execute;
import std.stdio : writeln;
import std.string : lineSplitter;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    version (BoundaryProductionWitness) enum onlyProduction = true;
    else enum onlyProduction = false;
    version (BoundaryUnittestWitness) enum onlyUnittest = true;
    else enum onlyUnittest = false;
    if (onlyProduction || onlyUnittest) {
        string[] command = ["python3", buildPath(repoRoot, "tools", "check_standalone_boundary.py"),
            "--root", buildPath(repoRoot, "tests", "core"), "--config", "core", "--compiler", "dmd"];
        version (BoundaryProductionFirst) enum firstProduction = true;
        else enum firstProduction = false;
        if (onlyUnittest && firstProduction) {
            auto production = execute(command);
            assert(production.status == 0,
                "production closure must stay green before unittest boundary: " ~ production.output);
            writeln(production.output);
        }
        if (onlyUnittest) command ~= "--unittest";
        auto result = execute(command);
        assert(result.status == 0, "production independent boundary witness: " ~ result.output);
        if (onlyProduction) {
            command = ["python3", buildPath(repoRoot, "tools", "check_standalone_boundary.py"),
                "--root", buildPath(repoRoot, "tools", "cli"), "--compiler", "dmd"];
            auto cli = execute(command);
            assert(cli.status == 0, "CLI production independent boundary witness: " ~ cli.output);
        }
    }
    auto tests = execute(["python3", buildPath(repoRoot, "tools", "test_standalone_boundary.py")]);
    assert(tests.status == 0, "boundary checker controls: " ~ tests.output);
    auto support = execute(["python3", buildPath(repoRoot, "tools",
        "check_package_support_boundary.py"), "--self-test"]);
    assert(support.status == 0, "support package checker controls: " ~ support.output);
    assert(support.output.lineSplitter.canFind("PKG-SELF-CONTROLS passed=539"),
        "support package checker missing control population");
    assert(support.output.canFind("PKG-BOUNDARY-VERDICT=GREEN"),
        "support package checker missing terminal verdict");
}
