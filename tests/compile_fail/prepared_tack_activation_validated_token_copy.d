module tests.compile_fail.prepared_tack_activation_validated_token_copy;
import prepared_tack_activation : ValidatedTackActivationToken;
void main() { ValidatedTackActivationToken a; auto b = a; }
