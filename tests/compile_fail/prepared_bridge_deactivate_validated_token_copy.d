module tests.compile_fail.prepared_bridge_deactivate_validated_token_copy;
import prepared_bridge_activation : ValidatedBridgeDeactivateToken;
void main() { ValidatedBridgeDeactivateToken a; auto b = a; }
