module tests.unit.application_boundary_checker_test;

import std.algorithm : canFind;
import std.path : buildPath, dirName;
import std.process : execute;
import std.stdio : writeln;
import std.string : lineSplitter;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    version (BoundaryCoordinateWitness) {
        auto coordinate = execute(["python3", "-c",
            "import sys;sys.path.insert(0,sys.argv[1]+'/tools');"
            ~ "import test_standalone_boundary as t;"
            ~ "result=t.unittest.TestResult();"
            ~ "t.BoundaryControls('test_selected_coordinate_declarations').run(result);"
            ~ "assert result.testsRun == 1 and result.wasSuccessful(), (result.testsRun,result.errors,result.failures);"
            ~ "print('PKG-COORDINATE-CONTROLS passed=1')", repoRoot]);
        assert(coordinate.status == 0 && coordinate.output.lineSplitter.canFind("PKG-COORDINATE-CONTROLS passed=1"),
            "support selected coordinate controls: " ~ coordinate.output);
        return;
    }
    version (BoundaryRawTreeWitness) {
        auto raw = execute(["python3", "-c",
            "import sys;sys.path.insert(0,sys.argv[1]+'/tools');"
            ~ "import test_standalone_boundary as t;"
            ~ "t.BoundaryControls('test_current_support_raw_tree').test_current_support_raw_tree();"
            ~ "t.BoundaryControls('test_current_support_runtime_identities').test_current_support_runtime_identities();"
            ~ "print('PKG-RAW-CONTROLS owners=55')", repoRoot]);
        assert(raw.status == 0 && raw.output.lineSplitter.canFind("PKG-RAW-CONTROLS owners=55"),
            "support actual raw-tree controls: " ~ raw.output);
        return;
    }
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
                "--root", buildPath(repoRoot, "apps", "cli"), "--compiler", "dmd"];
            auto cli = execute(command);
            assert(cli.status == 0, "CLI production independent boundary witness: " ~ cli.output);
        }
    }
    static import mathApi = vibe3d.util.math;
    static import oldMath = vibe3d.util.math.math;
    static import oldVector = vibe3d.util.math.math_vector;
    static import oldMatrix = vibe3d.util.math.math_matrix;
    static import oldQuaternion = vibe3d.util.math.math_quaternion;
    static import oldGeometry = vibe3d.util.math.math_geometry;
    static assert(is(oldMath.Vec3 == mathApi.Vec3) && is(oldVector.Vec3 == mathApi.Vec3),
        "Wave19 math old umbrella/vector imports retain original types");
    static assert(__traits(isSame, oldMatrix.identityMatrix, mathApi.identityMatrix)
        && __traits(isSame, oldQuaternion.slerp, mathApi.slerp)
        && __traits(isSame, oldGeometry.faceNormalFirst3, mathApi.faceNormalFirst3),
        "Wave19 math old component imports retain original overloads");
    static foreach (name; ["Vec3", "Vec4", "vec3Lerp", "normalize", "cross", "dot", "rotateAboutAxis", "rotateAboutPivot", "scaleAlongBasis", "safeNormalize", "identityMatrix", "translationMatrix", "pivotRotationMatrix", "pivotScaleMatrix", "pivotScaleMatrixBasis", "matrixFromEulerZYX", "eulerZYXFromMatrix", "applyAffine", "transformPoint", "matrixMirrorsWinding", "normalMatrix", "frameMatrix", "frameMatrixInverse", "matMul4", "wrapAboutPivot", "wrapAboutPivotStable", "modelMatrix", "mulMV", "lookAt", "perspectiveMatrix", "orthographicMatrix", "Quat", "slerp", "quatFromMatrix", "matrixFromQuat", "faceNormalFirst3", "pointInPolygon2D", "frontFacingLocal", "ringStartCornerSign", "closestOnSegment2D", "closestOnSegment2DSquared", "rayPlaneIntersect", "closestOnSegmentToRay", "perpendicularFrame", "rayTriangleIntersect", "closestPointOnTriangle2D", "triangulatePolygonEarClip", "planeFromLineAndWorkplane", "planeForSlice", "snapAngleToMultiple", "snapLineEndpointToAngle", "closestPointOnSegmentToRay", "closestPointOnLineToRay", "offsetInPlane", "offsetMeetDir", "offsetMeet", "bevelMiterPoint", "bevelArcPoints"])
        static assert(__traits(hasMember, mathApi, name), "Wave19 math approved facade export: " ~ name);
    static assert(!__traits(hasMember, mathApi, "isClose"), "Wave19 math fixture import stays hidden");
    static import d2MeshApi = vibe3d.mesh.core;
    static import d2MeshBody = vibe3d.mesh.core.mesh;
    static import d2DocumentApi = vibe3d.documents.model;
    static import d2DocumentBody = vibe3d.documents.model.document;
    enum d2MeshExports = ["Mesh", "FaceList"];
    enum d2DocumentExports = ["Document", "Layer", "MIN_ITEM_SCALE_MAG", "MAX_ITEM_SCALE_MAG",
        "ItemXform", "sanitizeItemXform", "ItemKind", "ItemKindInfo", "kindInfo", "kindFromToken",
        "tokenOf", "ImageData", "ImagePlaneData"];
    static assert(d2MeshExports.length == 2 && d2DocumentExports.length == 13,
        "Wave19 D2 exact approved facade export populations");
    static foreach (name; d2MeshExports) {
        static assert(__traits(hasMember, d2MeshApi, name),
            "Wave19 mesh facade approved export: " ~ name);
        static assert(__traits(isSame, __traits(getMember, d2MeshApi, name),
            __traits(getMember, d2MeshBody, name)),
            "Wave19 mesh facade original symbol identity: " ~ name);
    }
    static foreach (name; d2DocumentExports) {
        static assert(__traits(hasMember, d2DocumentApi, name),
            "Wave19 document facade approved export: " ~ name);
        static assert(__traits(isSame, __traits(getMember, d2DocumentApi, name),
            __traits(getMember, d2DocumentBody, name)),
            "Wave19 document facade original symbol identity: " ~ name);
    }
    static assert(__traits(hasMember, d2MeshBody, "MapKind")
        && __traits(hasMember, d2MeshBody, "Loop")
        && __traits(hasMember, d2MeshBody, "makeCube"),
        "Wave19 mesh refused controls name actual public implementation exports");
    static foreach (name; ["MapKind", "Loop", "makeCube", "CornerProvenance", "beginDeliveryBatchGlobal"])
        static assert(!__traits(hasMember, d2MeshApi, name),
            "Wave19 mesh facade refuses unapproved implementation export: " ~ name);
    static assert(__traits(hasMember, d2DocumentBody, "ItemLink")
        && __traits(hasMember, d2DocumentBody, "LinkState")
        && __traits(hasMember, d2DocumentBody, "NoEditTargetException"),
        "Wave19 document refused controls name actual public implementation exports");
    static foreach (name; ["ItemLink", "LinkState", "LinkSlot", "NoEditTargetException",
        "kNoEditTargetReason", "PreparedLayerReadScope", "noEditTargetMesh"])
        static assert(!__traits(hasMember, d2DocumentApi, name),
            "Wave19 document facade refuses unapproved implementation export: " ~ name);
    static foreach (name; ["mixedDoc", "staleDoc", "PendingPreparedMeshImage", "g_nextLayerBirthId"])
        static assert(!__traits(hasMember, d2DocumentApi, name),
            "Wave19 document facade fixture/private storage stays hidden: " ~ name);

    auto tests = execute(["python3", buildPath(repoRoot, "tools", "test_standalone_boundary.py")]);
    assert(tests.status == 0, "boundary checker controls: " ~ tests.output);
    auto support = execute(["python3", buildPath(repoRoot, "tools",
        "check_package_support_boundary.py"), "--self-test"]);
    assert(support.status == 0, "support package checker controls: " ~ support.output);
    assert(support.output.lineSplitter.canFind("PKG-SELF-CONTROLS passed=794"),
        "support package checker missing control population");
    auto math = execute(["python3", buildPath(repoRoot, "tools", "check_package_support_boundary.py"), "--check", "--package", "math", "--compiler", "dmd"]);
    assert(math.status == 0 && math.output.canFind("PKG-BOUNDARY-VERDICT=GREEN"), "Wave19 math current selected boundary: " ~ math.output);
    assert(support.output.canFind("PKG-BOUNDARY-VERDICT=GREEN"),
        "support package checker missing terminal verdict");
}
