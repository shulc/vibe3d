module tests.compile_fail.prepared_mirror_deactivate_validated_token_copy;
import prepared_mirror_activation : ValidatedMirrorDeactivateToken;
void main() { ValidatedMirrorDeactivateToken a; auto b = a; }
