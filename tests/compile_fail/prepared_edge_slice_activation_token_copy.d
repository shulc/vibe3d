module tests.compile_fail.prepared_edge_slice_activation_token_copy;
import prepared_edge_slice_activation : PreparedEdgeSliceActivationToken;
void main() { PreparedEdgeSliceActivationToken a; auto b = a; }
