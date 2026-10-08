module tests.unit.application_boundary_checker_test;

import std.path : buildPath, dirName;
import std.process : execute;
import std.stdio : writeln;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    auto tests = execute(["python3", buildPath(repoRoot, "tools", "test_standalone_boundary.py")]);
    assert(tests.status == 0, "boundary checker controls: " ~ tests.output);
    version (BoundaryProductionWitness) enum onlyProduction = true;
    else enum onlyProduction = false;
    version (BoundaryUnittestWitness) enum onlyUnittest = true;
    else enum onlyUnittest = false;
    if (onlyProduction || onlyUnittest) {
        string[] command = ["python3", buildPath(repoRoot, "tools", "check_standalone_boundary.py"),
            "--root", buildPath(repoRoot, "tests", "core"), "--config", "core", "--compiler", "dmd"];
        if (onlyUnittest) {
            auto production = execute(command);
            assert(production.status == 0,
                "production closure must stay green before unittest boundary: " ~ production.output);
            writeln(production.output);
            command ~= "--unittest";
        }
        auto result = execute(command);
        assert(result.status == 0, "production independent boundary witness: " ~ result.output);
    }
}
