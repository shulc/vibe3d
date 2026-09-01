module prepared_scale_update_token_copy;
import prepared_scale_update : PreparedScaleUpdateToken, ValidatedScaleUpdateToken;
void main() {
    PreparedScaleUpdateToken prepared;
    auto preparedCopy = prepared;
    ValidatedScaleUpdateToken validated;
    auto validatedCopy = validated;
}
