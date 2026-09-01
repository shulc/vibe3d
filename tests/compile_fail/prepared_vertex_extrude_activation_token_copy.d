module tests.compile_fail.prepared_vertex_extrude_activation_token_copy;
import prepared_vertex_extrude_activation : PreparedVertexExtrudeActivationToken;
void main() { PreparedVertexExtrudeActivationToken a; auto b = a; }
