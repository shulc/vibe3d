module ui.item_rename;

enum size_t ItemRenameCapacity = 256;

/// Inline item-name editor storage owned by one application instance. Layers
/// and Images deliberately share this state because both panels address the
/// same document-layer index space (task 5880).
struct ItemRenameState {
    int index = -1;
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

    void begin(size_t itemIndex, string seed) {
        index = cast(int)itemIndex;
        setText(seed);
    }

    void close() {
        index = -1;
    }

    bool activeFor(size_t itemIndex) const {
        return index >= 0 && cast(size_t)index == itemIndex;
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
    ItemRenameDispatch dispatch_;

public:
    this(ref ItemRenameState state, ItemRenameDispatch dispatch) {
        state_ = &state;
        dispatch_ = dispatch;
    }

    @property char[] buffer() {
        return state_.buffer[];
    }

    @property const(char)[] text() const {
        return state_.text;
    }

    bool activeFor(size_t itemIndex) const {
        return state_.activeFor(itemIndex);
    }

    void begin(size_t itemIndex, string seed) {
        state_.begin(itemIndex, seed);
    }

    void setText(string value) {
        state_.setText(value);
    }

    void finish(size_t itemIndex, ItemRenameExit exit) {
        final switch (exit) {
        case ItemRenameExit.none:
            return;
        case ItemRenameExit.commit:
            immutable string newName = state_.text.idup;
            if (newName.length && dispatch_ !is null) {
                import std.conv : to;
                import std.json : JSONValue;

                dispatch_("layer.rename",
                    `{"index":` ~ to!string(itemIndex) ~ `,"name":`
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

ItemRenameController bindItemRenameController(ref ItemRenameState state,
        ItemRenameDispatch dispatch) {
    return ItemRenameController(state, dispatch);
}
