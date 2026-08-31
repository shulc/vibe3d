module prepared_effect_delegate;
import prepared_tool_effect;
alias Callback = void delegate();
static assert(requirePreparedField!Callback);

