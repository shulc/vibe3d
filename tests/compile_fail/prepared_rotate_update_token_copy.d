module prepared_rotate_update_token_copy;
import prepared_rotate_update : PreparedRotateUpdateToken, ValidatedRotateUpdateToken;
void main() {
    PreparedRotateUpdateToken prepared;
    auto preparedCopy = prepared;
    ValidatedRotateUpdateToken validated;
    auto validatedCopy = validated;
}
