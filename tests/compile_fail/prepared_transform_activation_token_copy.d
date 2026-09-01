module prepared_transform_activation_token_copy;
import prepared_transform_activation : PreparedTransformActivationToken,
    ValidatedTransformActivationToken;
void copyPrepared(ref PreparedTransformActivationToken value) { auto copy = value; }
void copyValidated(ref ValidatedTransformActivationToken value) { auto copy = value; }
