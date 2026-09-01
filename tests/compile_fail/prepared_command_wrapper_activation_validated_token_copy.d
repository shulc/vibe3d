module tests.compile_fail.prepared_command_wrapper_activation_validated_token_copy;
import prepared_command_wrapper_activation : ValidatedCommandWrapperActivationToken;
void main() { ValidatedCommandWrapperActivationToken a; auto b = a; }
