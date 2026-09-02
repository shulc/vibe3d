module prepared_xfrm_update_tail_token_copy;
import prepared_xfrm_update_tail : PreparedXfrmUpdateTailToken,
    ValidatedXfrmUpdateTailToken;
void main() {
    PreparedXfrmUpdateTailToken prepared;
    auto preparedCopy = prepared;
    ValidatedXfrmUpdateTailToken validated;
    auto validatedCopy = validated;
}
