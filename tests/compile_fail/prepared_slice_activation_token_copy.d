module tests.compile_fail.prepared_slice_activation_token_copy;
import prepared_slice_activation : PreparedSliceActivationToken;
void main() { PreparedSliceActivationToken a; auto b = a; }
