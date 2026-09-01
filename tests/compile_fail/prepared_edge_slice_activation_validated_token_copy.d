module tests.compile_fail.prepared_edge_slice_activation_validated_token_copy;
import prepared_edge_slice_activation : ValidatedEdgeSliceActivationToken;
void main() { ValidatedEdgeSliceActivationToken a; auto b = a; }
