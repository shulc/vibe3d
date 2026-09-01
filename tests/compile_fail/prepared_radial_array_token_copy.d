module prepared_radial_array_token_copy;

import prepared_radial_array_transition : PreparedRadialArrayTransitionToken,
    ValidatedRadialArrayTransitionToken;

void copyPrepared(ref PreparedRadialArrayTransitionToken token) {
    auto forbidden = token;
}

void copyValidated(ref ValidatedRadialArrayTransitionToken token) {
    auto forbidden = token;
}
