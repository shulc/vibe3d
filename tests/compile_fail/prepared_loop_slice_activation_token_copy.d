module tests.compile_fail.prepared_loop_slice_activation_token_copy;
import prepared_loop_slice_activation : PreparedLoopSliceActivationToken;
void main() { PreparedLoopSliceActivationToken a; auto b = a; }
