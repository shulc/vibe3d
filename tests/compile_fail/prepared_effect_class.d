module prepared_effect_class;
import prepared_tool_effect;
class BorrowedObject { int value; }
static assert(requirePreparedField!BorrowedObject);

