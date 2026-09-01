module prepared_move_update_token_copy;
import prepared_move_update : PreparedMoveUpdateToken, ValidatedMoveUpdateToken;
void main() {
    PreparedMoveUpdateToken prepared;
    auto preparedCopy = prepared;
    ValidatedMoveUpdateToken validated;
    auto validatedCopy = validated;
}
