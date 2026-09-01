module tests.compile_fail.prepared_mirror_deactivate_token_copy;
import prepared_mirror_activation : PreparedMirrorDeactivateToken;
void main() { PreparedMirrorDeactivateToken a; auto b = a; }
