module prepared_effect_function_pointer;
import prepared_tool_effect;
alias Callback = void function();
static assert(requirePreparedField!Callback);

