module tests.compile_fail.prepared_mirror_activation_validated_token_copy;
import prepared_mirror_activation : ValidatedMirrorActivationToken;
void main() { ValidatedMirrorActivationToken a; auto b = a; }
