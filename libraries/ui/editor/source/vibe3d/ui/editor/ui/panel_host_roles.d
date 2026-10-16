module vibe3d.ui.editor.ui.panel_host_roles;

import vibe3d.ui.editor.buttonset : Panel, Group;
import vibe3d.editing.commands.runtime.command : g_testMode;
import d_imgui.imgui_h : ImVec2;
import vibe3d.documents.model.document : Document;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.registry : Registry;
import vibe3d.editing.contracts.seltype : SelTypeOrder;
import vibe3d.runtime.application_core.session_owner : Session;
import vibe3d.platform.input.shortcuts : ShortcutTable;

// These roles borrow the original live slots and callbacks; none owns a second
// application, layout or modal state (task 20262940; evidence: private body custody).
alias MeshDg = ref Mesh delegate() nothrow @nogc;

struct TabLayoutBorrow {
    ImVec2* tabPosPtr;
    ImVec2* tabSizePtr;
    @property ref ImVec2 tabPos() { return *tabPosPtr; }
    @property ref ImVec2 tabSize() { return *tabSizePtr; }
}

struct SideLayoutBorrow {
    ImVec2* sidePosPtr;
    ImVec2* sideSizePtr;
    @property ref ImVec2 sidePos() { return *sidePosPtr; }
    @property ref ImVec2 sideSize() { return *sideSizePtr; }
}

struct StatusLayoutBorrow {
    ImVec2* statusPosPtr;
    ImVec2* statusSizePtr;
    @property ref ImVec2 statusPos() { return *statusPosPtr; }
    @property ref ImVec2 statusSize() { return *statusSizePtr; }
}

struct TabPanelRole {
    TabLayoutBorrow layout;
    Panel[]* panelsPtr;
    int* activePanelIdxPtr;
    @property ref Panel[] panels() { return *panelsPtr; }
    @property ref int activePanelIdx() { return *activePanelIdxPtr; }
    @property ref bool testMode() { return g_testMode; }
}

struct SidePanelRole {
    SideLayoutBorrow layout;
    Panel[]* panelsPtr;
    int* activePanelIdxPtr;
    string* activeToolIdPtr;
    ShortcutTable* shortcutsPtr;
    Registry* regPtr;
    Session* sessionOwner;
    MeshDg meshDg;
    bool kGenerateAiAvailable;
    @property ref Panel[] panels() { return *panelsPtr; }
    @property ref int activePanelIdx() { return *activePanelIdxPtr; }
    @property string activeToolId() { return *activeToolIdPtr; }
    @property ref ShortcutTable shortcuts() { return *shortcutsPtr; }
    @property ref Registry reg() { return *regPtr; }
    @property ref Document document() { return sessionOwner.document; }
    @property ref EditMode editMode() { return sessionOwner.editMode; }
    @property ref Mesh mesh() nothrow @nogc { return meshDg(); }
    @property ref bool testMode() { return g_testMode; }
}

struct StatusPanelRole {
    StatusLayoutBorrow layout;
    Group[]* statusLineGroupsPtr;
    string* activeToolIdPtr;
    ShortcutTable* shortcutsPtr;
    Registry* regPtr;
    Session* sessionOwner;
    MeshDg meshDg;
    bool kAiToggleAvailable;
    bool kCopilotEnabled;
    @property ref Group[] statusLineGroups() { return *statusLineGroupsPtr; }
    @property string activeToolId() { return *activeToolIdPtr; }
    @property ref ShortcutTable shortcuts() { return *shortcutsPtr; }
    @property ref Registry reg() { return *regPtr; }
    @property ref Document document() { return sessionOwner.document; }
    @property ref EditMode editMode() { return sessionOwner.editMode; }
    @property ref SelTypeOrder selTypeOrder() { return sessionOwner.selTypeOrder; }
    @property ref Mesh mesh() nothrow @nogc { return meshDg(); }
    @property ref bool testMode() { return g_testMode; }
}

version (web) {} else {
    import vibe3d.runtime.ai3d.ai3d.job_controller : Ai3dJobController;
    import vibe3d.runtime.ai3d.ai3d.worker_manager : Ai3dWorkerManager;
    import core.time : MonoTime;

    struct Ai3dModalBorrow {
        bool* healthCheckedPtr;
        bool* healthOkPtr;
        int* healthProtocolPtr;
        string* healthBackendPtr;
        bool* healthObjCapablePtr;
        string* healthMessagePtr;
        string* jobIdPtr;
        string* statePtr;
        string* stagePtr;
        double* progressPtr;
        string* errorCodePtr;
        string* errorMessagePtr;
        @property ref bool healthChecked() { return *healthCheckedPtr; }
        @property ref bool healthOk() { return *healthOkPtr; }
        @property ref int healthProtocol() { return *healthProtocolPtr; }
        @property ref string healthBackend() { return *healthBackendPtr; }
        @property ref bool healthObjCapable() { return *healthObjCapablePtr; }
        @property ref string healthMessage() { return *healthMessagePtr; }
        @property ref string jobId() { return *jobIdPtr; }
        @property ref string state() { return *statePtr; }
        @property ref string stage() { return *stagePtr; }
        @property ref double progress() { return *progressPtr; }
        @property ref string errorCode() { return *errorCodePtr; }
        @property ref string errorMessage() { return *errorMessagePtr; }
    }

    struct Ai3dPanelRole {
        Ai3dModalBorrow ai3dModal;
        bool* ai3dModalOpenPtr;
        bool* ai3dModalPendingOpenPtr;
        string* ai3dPickedImagePathPtr;
        char[256]* ai3dWorkerUrlBufPtr;
        bool* ai3dWorkerStartingPtr;
        MonoTime* ai3dWorkerStartDeadlinePtr;
        MonoTime* ai3dWorkerNextHealthProbePtr;
        bool* ai3dInstallConfirmOpenPtr;
        bool* ai3dInstallConfirmPendingOpenPtr;
        int* ai3dMaxFacesPtr;
        Ai3dJobController ai3dController;
        Ai3dWorkerManager ai3dWorkerManager;
        @property ref bool ai3dModalOpen() { return *ai3dModalOpenPtr; }
        @property ref bool ai3dModalPendingOpen() { return *ai3dModalPendingOpenPtr; }
        @property ref string ai3dPickedImagePath() { return *ai3dPickedImagePathPtr; }
        @property ref char[256] ai3dWorkerUrlBuf() { return *ai3dWorkerUrlBufPtr; }
        @property ref bool ai3dWorkerStarting() { return *ai3dWorkerStartingPtr; }
        @property ref MonoTime ai3dWorkerStartDeadline() { return *ai3dWorkerStartDeadlinePtr; }
        @property ref MonoTime ai3dWorkerNextHealthProbe() { return *ai3dWorkerNextHealthProbePtr; }
        @property ref bool ai3dInstallConfirmOpen() { return *ai3dInstallConfirmOpenPtr; }
        @property ref bool ai3dInstallConfirmPendingOpen() { return *ai3dInstallConfirmPendingOpenPtr; }
        @property ref int ai3dMaxFaces() { return *ai3dMaxFacesPtr; }
    }
}

struct GuardModalRole {
private:
    bool delegate() awaitingAnswer_;
    string delegate() promptText_;
    bool delegate() answerSave_;
    void delegate() answerDiscard_;
    void delegate() answerCancel_;
public:
    this(bool delegate() awaitingAnswer, string delegate() promptText,
            bool delegate() answerSave, void delegate() answerDiscard,
            void delegate() answerCancel) {
        awaitingAnswer_ = awaitingAnswer;
        promptText_ = promptText;
        answerSave_ = answerSave;
        answerDiscard_ = answerDiscard;
        answerCancel_ = answerCancel;
    }
    bool isBound() const {
        return awaitingAnswer_ !is null && promptText_ !is null
            && answerSave_ !is null && answerDiscard_ !is null
            && answerCancel_ !is null;
    }
    @property bool awaitingAnswer() { return awaitingAnswer_(); }
    @property string promptText() { return promptText_(); }
    bool answerSave() { return answerSave_(); }
    void answerDiscard() { answerDiscard_(); }
    void answerCancel() { answerCancel_(); }
}
