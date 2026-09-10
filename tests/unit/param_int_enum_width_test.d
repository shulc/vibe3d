// Regression cells for int-enum storage width (task 5240).  Param.IntEnum's
// fallback renderer reads and writes through `iePtr`, so these use the real
// FalloffStage schema instead of rebuilding the pointer arithmetic in a test.
module tests.unit.param_int_enum_width_test;

import params : IntEnumEntry, Param, stringifyParam;
import std.array : join;
import std.format : format;
import toolpipe.packets : ElementConnect, ElementMode, FalloffType, LassoStyle;
import toolpipe.stages.falloff : FalloffStage;

unittest
{
    enum WideEnum : int { Zero }
    enum NarrowEnum : ubyte { Zero }
    static immutable entries = [
        IntEnumEntry(0, "zero", "Zero"),
    ];

    WideEnum wide;
    NarrowEnum narrow;
    static assert(__traits(compiles,
        Param.intEnum_("wide", "Wide", &wide, entries, 0)));
    static assert(!__traits(compiles,
        Param.intEnum_("narrow", "Narrow", &narrow, entries, 0)));
}

private Param namedParam(Param[] params, string name)
{
    foreach (p; params)
        if (p.name == name)
            return p;
    assert(false, "missing Param named " ~ name);
}

unittest
{
    string[] failures;

    auto reading = new FalloffStage();
    reading.type = FalloffType.Element;
    auto params = reading.params();
    size_t populated;
    foreach (p; params)
        if (p.name == "shape" || p.name == "mode" || p.name == "connect")
            ++populated;
    assert(reading.type == FalloffType.Element,
        "element read population floor: Element falloff is not active");
    assert(populated == 3,
        format("element read population floor: expected shape/mode/connect, got %d", populated));

    auto mode = namedParam(params, "mode");
    auto connect = namedParam(params, "connect");
    const autoValue = stringifyParam(mode);
    assert(reading.setAttr("mode", "polygon"),
        "element read population floor: typed mode write was refused");
    const polygonValue = stringifyParam(mode);
    const connectValue = stringifyParam(connect);
    if (autoValue != "auto")
        failures ~= format("element read mode(auto): expected auto, got %s", autoValue);
    if (polygonValue != "polygon")
        failures ~= format("element read mode(polygon): expected polygon, got %s", polygonValue);
    if (connectValue != "ignore")
        failures ~= format("element read connect(ignore): expected ignore, got %s", connectValue);

    auto modeWriter = new FalloffStage();
    modeWriter.type = FalloffType.Element;
    auto modeWriterParam = namedParam(modeWriter.params(), "mode");
    assert(modeWriter.steps == 2,
        format("elementMode write population floor: expected steps=2 before write, got %d",
               modeWriter.steps));
    *modeWriterParam.iePtr = cast(int) ElementMode.Polygon;
    if (modeWriter.elementMode != ElementMode.Polygon)
        failures ~= format("elementMode write: expected polygon, got %s",
                           modeWriter.elementMode);
    if (modeWriter.steps != 2)
        failures ~= format("elementMode write corrupted steps: expected 2, got %d",
                           modeWriter.steps);

    auto connectWriter = new FalloffStage();
    connectWriter.type = FalloffType.Element;
    connectWriter.elementMode = ElementMode.Polygon;
    auto connectWriterParam = namedParam(connectWriter.params(), "connect");
    assert(connectWriter.elementMode == ElementMode.Polygon,
        "connect write population floor: elementMode must be non-zero before write");
    *connectWriterParam.iePtr = cast(int) ElementConnect.Rigid;
    if (connectWriter.connect != ElementConnect.Rigid)
        failures ~= format("connect write: expected rigid, got %s", connectWriter.connect);
    if (connectWriter.elementMode != ElementMode.Polygon)
        failures ~= format("connect write corrupted elementMode: expected polygon, got %s",
                           connectWriter.elementMode);

    assert(failures.length == 0, failures.join("\n"));
}

unittest
{
    string[] failures;

    auto reading = new FalloffStage();
    reading.type = FalloffType.Lasso;
    reading.lassoPolyX = new float[](20);
    reading.lassoPolyY = new float[](20);
    assert(reading.lassoPolyX.length == 20 && reading.lassoPolyY.length == 20,
        "lassoStyle read population floor: expected a 20-point polygon");
    auto params = reading.params();
    size_t populated;
    foreach (p; params)
        if (p.name == "lassoStyle")
            ++populated;
    assert(populated == 1,
        format("lassoStyle read population floor: expected one style Param, got %d", populated));
    auto style = namedParam(params, "lassoStyle");
    const styleValue = stringifyParam(style);
    if (styleValue != "freehand")
        failures ~= format("lassoStyle read: expected freehand, got %s", styleValue);

    auto writer = new FalloffStage();
    writer.type = FalloffType.Lasso;
    writer.lassoPolyX = new float[](20);
    writer.lassoPolyY = new float[](20);
    auto writerParam = namedParam(writer.params(), "lassoStyle");
    assert(writer.lassoPolyX.length == 20 && writer.lassoPolyY.length == 20,
        "lassoStyle write population floor: expected a 20-point polygon before write");
    *writerParam.iePtr = cast(int) LassoStyle.Rectangle;
    if (writer.lassoStyle != LassoStyle.Rectangle)
        failures ~= format("lassoStyle write: expected rectangle, got %s", writer.lassoStyle);
    if (writer.lassoPolyX.length != 20)
        failures ~= format("lassoStyle write corrupted lassoPolyX.length: expected 20, got %d",
                           writer.lassoPolyX.length);

    assert(failures.length == 0, failures.join("\n"));
}
