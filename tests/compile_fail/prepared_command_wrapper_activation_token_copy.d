module tests.compile_fail.prepared_command_wrapper_activation_token_copy;
import prepared_command_wrapper_activation : PreparedCommandWrapperActivationToken;
void main() { PreparedCommandWrapperActivationToken a; auto b = a; }
