module tests.compile_fail.prepared_bridge_activation_validated_token_copy;
import prepared_bridge_activation : ValidatedBridgeActivationToken;
void main() { ValidatedBridgeActivationToken a; auto b = a; }
