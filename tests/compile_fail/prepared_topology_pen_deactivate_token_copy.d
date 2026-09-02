module prepared_topology_pen_deactivate_token_copy;
import prepared_topology_pen_deactivate : PreparedTopologyPenDeactivateToken,
    ValidatedTopologyPenDeactivateToken;
void main() {
    PreparedTopologyPenDeactivateToken prepared;
    auto preparedCopy = prepared;
    ValidatedTopologyPenDeactivateToken validated;
    auto validatedCopy = validated;
}
