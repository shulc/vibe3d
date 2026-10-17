module tests.unit.root_test_package_population_test;

// Keep the Wave8 private snapshot fixture compiled exactly once in the root
// test configuration. Runtime cell execution remains ut_runner's authority;
// the completed package migration no longer needs a frozen ModuleInfo roster.
private template SnapshotFixturePopulation() {
    import vibe3d.mesh.core.mesh;
    enum coreCells = __traits(getUnitTests, vibe3d.mesh.core.mesh).length;
    static assert(coreCells >= 2, "ROOT-SNAPSHOT-CELL core unittest population floor");
    enum mappedCells = () {
        size_t count;
        static foreach (cell; __traits(getUnitTests, vibe3d.mesh.core.mesh)) {
            static foreach (attribute; __traits(getAttributes, cell)) {
                static if (is(typeof(attribute) == string)) {
                    static if (attribute == "mesh-snapshot-private-cells") ++count;
                }
            }
        }
        return count;
    }();
    static assert(mappedCells == 1,
        "ROOT-SNAPSHOT-CELL mapped private fixture must be compiled exactly once");
    static assert(coreCells > mappedCells,
        "ROOT-SNAPSHOT-CELL ordinary core unittest complement floor");
    enum SnapshotFixturePopulation = true;
}

static assert(SnapshotFixturePopulation!());
