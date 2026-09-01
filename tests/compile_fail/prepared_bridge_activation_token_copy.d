module tests.compile_fail.prepared_bridge_activation_token_copy;
import prepared_bridge_activation : PreparedBridgeActivationToken;
void main() { PreparedBridgeActivationToken a; auto b = a; }
