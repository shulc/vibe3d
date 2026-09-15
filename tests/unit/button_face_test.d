module tests.unit.button_face_test;

import std.file : readText;
import std.string : count, indexOf;
import ui.button_face : ButtonFace, buttonFaceColours;

private string functionBody(string text, string signature) {
    auto start = text.indexOf(signature);
    assert(start >= 0, "U3 production function is missing");
    auto next = text.indexOf("\n}", start);
    assert(next >= 0, "U3 production function body is unterminated");
    return text[start .. next + 2];
}

unittest { // U3a: all four faces use the shared palette in both variants
    uint checked;
    foreach (isCommand; [false, true]) {
        auto normal = buttonFaceColours(ButtonFace.normal, isCommand);
        auto hover = buttonFaceColours(ButtonFace.hover, isCommand);
        auto on = buttonFaceColours(ButtonFace.on, isCommand);
        auto disabled = buttonFaceColours(ButtonFace.disabled, isCommand);
        assert(normal.bevel && !normal.engraved);
        assert(hover.bevel && !hover.engraved && hover.fill != normal.fill);
        assert(!on.bevel && !on.engraved && on.fill == uint.max);
        assert(disabled.bevel && disabled.engraved && disabled.fill == normal.fill);
        checked += 4;
    }
    assert(checked == 8, "U3a face/palette table lost a row");
}

unittest { // U3b: panel button chrome consumes the shared palette
    auto text = readText("source/ui/panels.d");
    auto body = functionBody(text, "bool renderStyledButton(");
    assert(body.count("ImVec4(0.") == 0,
        "U3b renderStyledButton regained a local colour literal");
    assert(body.count("styledButtonPalette(") >= 1,
        "U3b renderStyledButton bypasses the shared palette");
}

unittest { // U3c: panel row geometry consumes the shared padding
    auto text = readText("source/ui/panels.d");
    auto body = functionBody(text, "void pushButtonBarStyle()");
    assert(body.count("kButtonBarPadding") >= 1,
        "U3c pushButtonBarStyle bypasses shared padding");
    assert(body.count("ImVec2(6, 5)") == 0,
        "U3c pushButtonBarStyle regained local padding");
}
