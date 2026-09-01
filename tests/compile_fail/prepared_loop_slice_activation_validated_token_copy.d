module tests.compile_fail.prepared_loop_slice_activation_validated_token_copy;
import prepared_loop_slice_activation : ValidatedLoopSliceActivationToken;
void main() { ValidatedLoopSliceActivationToken a; auto b = a; }
