module prepared_transform_product_token_copy;
import prepared_transform_product_activation : PreparedTransformProductActivationToken,
    ValidatedTransformProductActivationToken;
void copyPrepared(ref PreparedTransformProductActivationToken value) { auto copy = value; }
void copyValidated(ref ValidatedTransformProductActivationToken value) { auto copy = value; }
