module tests.compile_fail.prepared_mirror_activation_token_copy;
import prepared_mirror_activation : PreparedMirrorActivationToken;
void main() { PreparedMirrorActivationToken a; auto b = a; }
