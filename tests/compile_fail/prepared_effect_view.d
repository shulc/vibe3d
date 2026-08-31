module prepared_effect_view;
import prepared_tool_effect;
struct BorrowingView { int[] source; size_t index; }
static assert(requirePreparedField!BorrowingView);

