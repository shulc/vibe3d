module prepared_effect_nested_slice;
import prepared_tool_effect;
struct NestedBorrow { ubyte[] borrowed; }
static assert(requirePreparedField!NestedBorrow);

