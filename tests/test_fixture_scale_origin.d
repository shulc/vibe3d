// Reference-parity suite: uniform scale about the world origin, across element
// mode (vertex/edge/polygon) × selection {none,one,adjacent,islands} — the same
// selections as the move matrix. Engine-neutral (scale about a fixed pivot, no
// recovery). Empty selection scales the whole mesh; non-empty scales about
// pivot [0,0,0].

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/scale_origin.json");
    runParitySuite(json);
}
