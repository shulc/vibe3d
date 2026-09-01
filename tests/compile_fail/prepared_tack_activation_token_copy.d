module tests.compile_fail.prepared_tack_activation_token_copy;
import prepared_tack_activation : PreparedTackActivationToken;
void main() { PreparedTackActivationToken a; auto b = a; }
