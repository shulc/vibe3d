module vibe3d.ui.editor.ui.item_click_source_test;

import vibe3d.ui.editor.ui.item_rows : itemClickMode;

unittest {
    // Every cell of the 2x2, because the interesting one is the pair and a
    // three-case test would not have it.
    assert(itemClickMode(false, false) == `"set"`);
    assert(itemClickMode(true,  false) == `"toggle"`);
    assert(itemClickMode(false, true)  == `"range"`);
    assert(itemClickMode(true,  true)  == `"range"`,   // Shift wins the pair
        "Ctrl+Shift must not fall back to toggle — Shift would be inert");
}
