module tests.compile_fail.prepared_slice_activation_validated_token_copy;
import prepared_slice_activation : ValidatedSliceActivationToken;
void main() { ValidatedSliceActivationToken a; auto b = a; }
