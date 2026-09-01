module tests.compile_fail.prepared_edge_extrude_activation_validated_token_copy;
import prepared_edge_extrude_activation : ValidatedEdgeExtrudeActivationToken;
void main() { ValidatedEdgeExtrudeActivationToken a; auto b = a; }
