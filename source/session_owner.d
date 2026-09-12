module session_owner;

import document : Document, noEditTargetMesh;
import editmode : EditMode;
import mesh : Mesh;
import seltype : SelType, SelTypeOrder, geometryEditMode, geometrySelType;

/// Stable owner for the document and selection-type state (task 5700).
/// Construct it through `create`/`bootstrap`, keep the returned pointer for the
/// application lifetime, and replace the document field in place. The focused
/// lifetime and mutation evidence is `tests/unit/session_ownership_test.d`.
struct Session {
private:
    Document     document_;
    SelTypeOrder selTypeOrder_;
    EditMode     editMode_ = EditMode.Vertices;

    this(Document document) {
        document_ = document;
        syncEditMode();
    }

    bool setGeometryType(EditMode mode) {
        const flipped = selTypeOrder_.touch(geometrySelType(mode));
        syncEditMode();
        return flipped;
    }

    void syncEditMode() {
        editMode_ = geometryEditMode(selTypeOrder_.mostRecentGeometry());
    }

public:
    @disable this(this);

    static Session* create(Document document) {
        return new Session(document);
    }

    static Session* bootstrap(Mesh mesh) {
        return create(Document.bootstrap(mesh));
    }

    @property ref Document document() nothrow @nogc {
        return document_;
    }

    @property ref const(Document) document() const nothrow @nogc {
        return document_;
    }

    @property ref SelTypeOrder selTypeOrder() nothrow @nogc {
        return selTypeOrder_;
    }

    @property ref const(SelTypeOrder) selTypeOrder() const nothrow @nogc {
        return selTypeOrder_;
    }

    @property ref EditMode editMode() nothrow @nogc {
        return editMode_;
    }

    @property ref const(EditMode) editMode() const nothrow @nogc {
        return editMode_;
    }

    Document* documentPtr() nothrow @nogc {
        return &document_;
    }

    SelTypeOrder* selTypeOrderPtr() nothrow @nogc {
        return &selTypeOrder_;
    }

    EditMode* editModePtr() nothrow @nogc {
        return &editMode_;
    }

    /// The application edit target, resolved afresh without entering a
    /// prepared-lifecycle read. This preserves `app.main.mesh`'s prior path;
    /// readers that require the prepared shadow still call `Document.activeMesh`.
    ref Mesh editMesh() nothrow @nogc {
        auto primary = document_.primary;
        return primary !is null ? primary.meshRef() : noEditTargetMesh();
    }

    bool promoteGeometryType(EditMode mode) {
        return setGeometryType(mode);
    }

    bool switchGeometryType(EditMode mode) {
        return setGeometryType(mode);
    }

    bool promoteItemType() {
        return selTypeOrder_.touch(SelType.Item);
    }

    bool switchItemType() {
        return selTypeOrder_.touch(SelType.Item);
    }

    void replaceDocument(Document document) {
        document_ = document;
    }
}
