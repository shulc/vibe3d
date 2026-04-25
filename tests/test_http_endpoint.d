import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

// Helper function to compare floating point numbers
bool approxEqual(double a, double b, double epsilon = 1e-6) {
    return fabs(a - b) < epsilon;
}

unittest { // Test the /api/model endpoint
    auto response = get("http://localhost:8080/api/model");

    // Parse the response as JSON
    auto json = parseJSON(response);

    // Check if required fields exist
    assert("vertexCount" in json, "Missing vertexCount field");
    assert("edgeCount" in json, "Missing edgeCount field");
    assert("faceCount" in json, "Missing faceCount field");
    assert("vertices" in json, "Missing vertices field");
    assert("edges" in json, "Missing edges field");
    assert("faces" in json, "Missing faces field");

    // Check vertex data
    auto vertices = json["vertices"];
    assert(vertices.type == JSONType.ARRAY, "Vertices should be an array");

    // Check that we have the expected number of vertices for a cube (8)
    assert(vertices.array.length == 8, "Expected 8 vertices for a cube");

    // Expected vertex positions for a unit cube centered at origin
    double[3][8] expectedVertices;
    expectedVertices[0] = [-0.5, -0.5, -0.5];
    expectedVertices[1] = [ 0.5, -0.5, -0.5];
    expectedVertices[2] = [ 0.5,  0.5, -0.5];
    expectedVertices[3] = [-0.5,  0.5, -0.5];
    expectedVertices[4] = [-0.5, -0.5,  0.5];
    expectedVertices[5] = [ 0.5, -0.5,  0.5];
    expectedVertices[6] = [ 0.5,  0.5,  0.5];
    expectedVertices[7] = [-0.5,  0.5,  0.5];

    // Check that each vertex has 3 coordinates and matches expected values
    foreach (i, vertex; vertices.array) {
        assert(vertex.array.length == 3, "Each vertex should have 3 coordinates");

        // Check that the vertex coordinates match expected values
        assert(approxEqual(vertex.array[0].floating, expectedVertices[i][0]),
               "Vertex " ~ to!(string)(i) ~ " X coordinate mismatch");
        assert(approxEqual(vertex.array[1].floating, expectedVertices[i][1]),
               "Vertex " ~ to!(string)(i) ~ " Y coordinate mismatch");
        assert(approxEqual(vertex.array[2].floating, expectedVertices[i][2]),
               "Vertex " ~ to!(string)(i) ~ " Z coordinate mismatch");
    }

    // Check edge data — 12 edges for a cube, in the order addFace inserts them.
    auto edges = json["edges"];
    assert(edges.type == JSONType.ARRAY, "Edges should be an array");
    assert(edges.array.length == 12, "Expected 12 edges for a cube, got "
           ~ to!string(edges.array.length));

    int[2][12] expectedEdges = [
        [0, 3], [3, 2], [2, 1], [1, 0],   // back face perimeter
        [4, 5], [5, 6], [6, 7], [7, 4],   // front face perimeter
        [0, 4], [7, 3],                   // left-face new edges
        [2, 6],                           // right-face new edge
        [5, 1],                           // right-face new edge
    ];
    foreach (i, edge; edges.array) {
        assert(edge.array.length == 2, "Each edge should have 2 vertex indices");
        assert(edge.array[0].integer == expectedEdges[i][0],
               "Edge " ~ to!string(i) ~ " endpoint 0 mismatch");
        assert(edge.array[1].integer == expectedEdges[i][1],
               "Edge " ~ to!string(i) ~ " endpoint 1 mismatch");
    }

    // Check face data
    auto faces = json["faces"];
    assert(faces.type == JSONType.ARRAY, "Faces should be an array");

    // Check that we have the expected number of faces for a cube (6)
    assert(faces.array.length == 6, "Expected 6 faces for a cube");

    // Expected face definitions for a cube (vertex indices)
    int[4][6] expectedFaces;
    expectedFaces[0] = [0, 3, 2, 1];  // Back face
    expectedFaces[1] = [4, 5, 6, 7];  // Front face
    expectedFaces[2] = [0, 4, 7, 3];  // Left face
    expectedFaces[3] = [1, 2, 6, 5];  // Right face
    expectedFaces[4] = [3, 7, 6, 2];  // Top face
    expectedFaces[5] = [0, 1, 5, 4];  // Bottom face

    // Check that each face has 4 vertices (quads) and matches expected values
    foreach (i, face; faces.array) {
        assert(face.array.length == 4, "Each face should have 4 vertices");

        // Check that the face vertex indices match expected values
        assert(face.array[0].integer == expectedFaces[i][0],
               "Face " ~ to!(string)(i) ~ " vertex 0 index mismatch");
        assert(face.array[1].integer == expectedFaces[i][1],
               "Face " ~ to!(string)(i) ~ " vertex 1 index mismatch");
        assert(face.array[2].integer == expectedFaces[i][2],
               "Face " ~ to!(string)(i) ~ " vertex 2 index mismatch");
        assert(face.array[3].integer == expectedFaces[i][3],
               "Face " ~ to!(string)(i) ~ " vertex 3 index mismatch");
    }
}
