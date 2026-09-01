module tests.compile_fail.prepared_bridge_deactivate_token_copy;
import prepared_bridge_activation : PreparedBridgeDeactivateToken;
void main() { PreparedBridgeDeactivateToken a; auto b = a; }
