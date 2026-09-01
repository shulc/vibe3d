module prepared_inherited_noop_token_copy;

import prepared_inherited_noop : PreparedInheritedNoopToken;

void main() {
    PreparedInheritedNoopToken first;
    auto copied = first;
}
