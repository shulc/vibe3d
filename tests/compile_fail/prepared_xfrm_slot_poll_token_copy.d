module prepared_xfrm_slot_poll_token_copy;
import prepared_xfrm_slot_poll : PreparedXfrmSlotPollToken,
    ValidatedXfrmSlotPollToken;
void main() {
    PreparedXfrmSlotPollToken prepared; auto preparedCopy = prepared;
    ValidatedXfrmSlotPollToken validated; auto validatedCopy = validated;
}
