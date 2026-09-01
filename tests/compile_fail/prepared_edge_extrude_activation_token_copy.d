module tests.compile_fail.prepared_edge_extrude_activation_token_copy;
import prepared_edge_extrude_activation : PreparedEdgeExtrudeActivationToken;
void main() { PreparedEdgeExtrudeActivationToken a; auto b = a; }
