module ui.item_rename;

import document : Document, Layer;
import ui.retained_item : RetainedItem;

enum size_t ItemRenameCapacity = 256;

/// Inline item-name editor storage owned by one application instance. Layers
/// and Images deliberately share this state because both panels list items of
/// the same document (tasks 5880, 6359). The edited item is a `RetainedItem`: its
/// index is resolved when the rename commits, never kept from the click.
struct ItemRenameState {
    private RetainedItem target_;
    char[ItemRenameCapacity] buffer = '\0';

    @property const(char)[] text() const {
        import std.string : fromStringz;
        return fromStringz(buffer.ptr);
    }

    void setText(string value) {
        import std.algorithm.comparison : min;

        buffer[] = 0;
        const n = min(value.length, buffer.length - 1);
        buffer[0 .. n] = value[0 .. n];
    }

    void begin(Layer item, string seed) {
        target_.hold(item);
        setText(seed);
    }

    void close() {
        target_.release();
    }

    @property bool open() const {
        return target_.held;
    }

    bool activeFor(const(Layer) item) const {
        return target_.holds(item);
    }
}

enum ItemRenameExit {
    none,
    commit,
    cancel,
    deactivate,
}

alias ItemRenameDispatch = void delegate(string id, string paramsJson);

/// Headless reaction seam used by both item-list panels. Drawing decides the
/// widget event; this controller preserves the shared state transition and the
/// existing `layer.rename` command route without depending on ImGui.
struct ItemRenameController {
private:
    ItemRenameState* state_;
    const(Document)* document_;
    ItemRenameDispatch dispatch_;

    void cancelDetached() {
        size_t index;
        if (!state_.target_.resolve(*document_, index))
            state_.close();
    }

public:
    this(ref ItemRenameState state, const(Document)* document,
         ItemRenameDispatch dispatch) {
        state_ = &state;
        document_ = document;
        dispatch_ = dispatch;
    }

    @property char[] buffer() {
        return state_.buffer[];
    }

    @property const(char)[] text() const {
        return state_.text;
    }

    bool activeFor(const(Layer) item) const {
        return state_.activeFor(item);
    }

    void begin(Layer item, string seed) {
        state_.begin(item, seed);
    }

    void setText(string value) {
        state_.setText(value);
    }

    void finish(ItemRenameExit exit) {
        final switch (exit) {
        case ItemRenameExit.none:
            return;
        case ItemRenameExit.commit:
            immutable string newName = state_.text.idup;
            size_t index;
            if (newName.length && dispatch_ !is null
                && state_.target_.resolve(*document_, index)) {
                import std.conv : to;
                import std.json : JSONValue;

                dispatch_("layer.rename",
                    `{"index":` ~ to!string(index) ~ `,"name":`
                    ~ JSONValue(newName).toString() ~ `}`);
            }
            state_.close();
            return;
        case ItemRenameExit.cancel:
        case ItemRenameExit.deactivate:
            state_.close();
            return;
        }
    }
}

/// Binds the shared state for one panel draw. A rename whose item has left the
/// document is cancelled here, before the panel's window, with no command.
ItemRenameController bindItemRenameController(ref ItemRenameState state,
        const(Document)* document, ItemRenameDispatch dispatch) {
    auto rename = ItemRenameController(state, document, dispatch);
    rename.cancelDetached();
    return rename;
}
