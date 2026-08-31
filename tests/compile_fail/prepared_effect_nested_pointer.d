module prepared_effect_nested_pointer;
import prepared_tool_effect;
struct NestedBorrow { int* borrowed; }
static assert(requirePreparedField!NestedBorrow);

