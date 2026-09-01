module tests.compile_fail.prepared_vertex_bevel_activation_token_copy;
import prepared_vertex_bevel_activation : PreparedVertexBevelActivationToken;
void main() { PreparedVertexBevelActivationToken a; auto b = a; }
