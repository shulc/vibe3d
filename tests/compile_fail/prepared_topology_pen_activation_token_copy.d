module tests.compile_fail.prepared_topology_pen_activation_token_copy;
import prepared_topology_pen_activation : PreparedTopologyPenActivationToken;
void main() { PreparedTopologyPenActivationToken a; auto b = a; }
