module falloff_rmb_discipline_test;

import falloff_handles : FalloffRMBDiscipline, falloffRMBDiscipline;
import toolpipe.packets : FalloffType;

unittest {
    const kinds = [
        FalloffType.None,
        FalloffType.Linear,
        FalloffType.Radial,
        FalloffType.Screen,
        FalloffType.Lasso,
        FalloffType.Cylinder,
        FalloffType.Element,
        FalloffType.Selection,
        FalloffType.Composite,
        FalloffType.VertexMap,
    ];

    size_t point3D;
    size_t absoluteInteger;
    size_t incrementalFloat;
    size_t noAttributeGesture;
    foreach (kind; kinds) {
        final switch (falloffRMBDiscipline(kind)) {
            case FalloffRMBDiscipline.Point3D:          ++point3D; break;
            case FalloffRMBDiscipline.AbsoluteInteger: ++absoluteInteger; break;
            case FalloffRMBDiscipline.IncrementalFloat:++incrementalFloat; break;
            case FalloffRMBDiscipline.None:             ++noAttributeGesture; break;
        }
    }

    assert(point3D != 0 && point3D == 3,
        "RMB population floor: point placement must contain exactly "
        ~ "linear, radial, and cylinder");
    assert(absoluteInteger != 0 && absoluteInteger == 2,
        "RMB population floor: absolute integer haul must contain exactly "
        ~ "screen and selection");
    assert(incrementalFloat != 0 && incrementalFloat == 1,
        "RMB population floor: incremental float haul must contain exactly "
        ~ "element");
    assert(noAttributeGesture == 4,
        "RMB population floor: none, lasso, composite, and vertexMap must "
        ~ "remain outside attribute gestures");
}
