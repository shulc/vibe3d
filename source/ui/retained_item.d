module ui.retained_item;

import document : Document, Layer;

/// One document item that a UI operation keeps across frames: an open inline
/// rename, or a remove waiting for its confirmation.
///
/// CONTRACT (task 6359). The item is held by IDENTITY. Its document index is never
/// stored: it is resolved against the live document at the moment of use,
/// because `layer.delete` splices indices, `layer.reorder` permutes them and a
/// load replaces the whole document under the same pointer. A held item that
/// is no longer a member resolves to nothing, and the caller ends its pending
/// operation without dispatching a command. This is a target token, not a
/// second primary: nothing else reads it.
struct RetainedItem {
    private Layer item_;

    void hold(Layer item) { item_ = item; }
    void release() { item_ = null; }

    @property bool held() const { return item_ !is null; }
    @property inout(Layer) item() inout { return item_; }

    bool holds(const(Layer) item) const {
        return item_ !is null && item_ is item;
    }

    /// The live document index of the held item. False when nothing is held
    /// or the held item is not a member of `document`. The document is taken
    /// by reference: every caller has one, so "no document" is not a state.
    bool resolve(ref const(Document) document, out size_t index) const {
        if (item_ is null) return false;
        index = document.indexOf(item_);
        return index < document.layers.length;
    }
}
