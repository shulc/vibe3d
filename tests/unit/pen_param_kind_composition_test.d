module tests.unit.pen_param_kind_composition_test;

import prepared_tool_effect : PreparedPenParamKind;

unittest {
    static assert([__traits(allMembers, PreparedPenParamKind)] ==
        ["None", "Noop", "CurrentPoint", "Position", "Preview"]);
}
