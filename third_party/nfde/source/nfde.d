module nfde;

import core.stdc.limits : PATH_MAX;
version (Windows) import core.stdc.wchar_ : wcslen;
import core.stdc.string : strlen;
import std.conv : asOriginalType, castFrom, to;
import std.string : toStringz;
import std.traits : isPointer;
import std.utf : toUTF8, toUTF16z, toUTFz;

import nfde_bindings;

package alias toUTF8z = toUTFz!(char*);
version (Windows) package alias Char = wchar;
else package alias Char = char;
version (Windows) package alias String = wstring;
else package alias String = string;
package auto isInitialized = false;

static this() {
  // [vibe3d vendor patch, task 0431] The upstream ctor assert'd on a failed
  // NFD_Init(). Under the xdg-desktop-portal backend NFD_Init() opens a D-Bus
  // session-bus connection, which fails on a host with a DISPLAY but no session
  // bus (CI's `vibe3d --test` under xvfb-run, headless service accounts). An
  // assert there would abort EVERY process start. Soften to a stderr warning and
  // leave isInitialized=false; the dialog functions below early-return
  // Result.error while uninitialized, so a failed init degrades to a no-op menu
  // action rather than a crash. Neutral for Windows/macOS (their init does not
  // fail this way). See third_party/nfde/PATCHES.md.
  isInitialized = (NFD_Init() == NFD_OKAY);
  if (!isInitialized) {
    import core.stdc.stdio : fprintf, stderr;
    const(char)* err = NFD_GetError();
    if (err is null) err = "unknown error";
    fprintf(stderr, "nfde: NFD_Init failed: %s -- native file dialogs unavailable\n", err);
  }
}
static ~this() {
  if (isInitialized) NFD_Quit();
}

///
enum Result : int {
  ///
  error,
  ///
  okay,
  ///
  cancel
}

///
string getError() {
  auto error = NFD_GetError();
  if (error !is null) NFD_ClearError();
  return error is null ? null : error.to!string.idup;
}

///
nfdnchar_t* toNfdChar(T)(T value) if (isPointer!T) {
  return castFrom!(T).to!(nfdnchar_t*)(value);
}

///
alias FilterItem = nfdnfilteritem_t;

///
Result openDialog(out string path, FilterItem[] filters, string defaultPath = null) {
  if (!isInitialized) return Result.error;  // [vibe3d vendor patch 0431] see PATCHES.md
  nfdnchar_t* outPath;

  version (Windows) auto response = NFD_OpenDialogN(
    &outPath, filters.ptr, filters.length.to!uint, defaultPath.toUTF16z.toNfdChar
  );
  else auto response = NFD_OpenDialogN(&outPath, filters.ptr, filters.length.to!uint, defaultPath.toStringz);
  if (response.asOriginalType == Result.okay) {
    version (Windows) const selectedPath = (
      cast(wchar[]) outPath[0 .. (cast(wchar*) outPath).wcslen]
    ).toUTF8.to!string;
    else const selectedPath = outPath[0 .. outPath.strlen].to!string.idup;
    NFD_FreePathN(outPath);
    path = selectedPath;
  }
  return response.asOriginalType.to!Result;
}

// TODO: NFD_OpenDialogN_With

///
Result openDialogMultiple(out PathSet paths, FilterItem[] filters, string defaultPath = null) {
  if (!isInitialized) return Result.error;  // [vibe3d vendor patch 0431] see PATCHES.md
  PathSet outPaths;

  version (Windows) auto response = NFD_OpenDialogMultipleN(
    outPaths.ptr, filters.ptr, filters.length.to!uint, defaultPath.toUTF16z.toNfdChar
  );
  else auto response = NFD_OpenDialogMultipleN(outPaths.ptr, filters.ptr, filters.length.to!uint, defaultPath.toUTF8z);
  paths = outPaths;
  return response.asOriginalType.to!Result;
}

// TODO: NFD_OpenDialogMultipleN_With

///
Result saveDialog(out string path, FilterItem[] filters, string defaultName = null, string defaultPath = null) {
  if (!isInitialized) return Result.error;  // [vibe3d vendor patch 0431] see PATCHES.md
  nfdnchar_t* savePath;

  version (Windows) auto response = NFD_SaveDialogN(
    &savePath, filters.ptr, filters.length.to!uint, defaultPath.toUTF16z.toNfdChar, defaultName.toUTF16z.toNfdChar
  );
  else auto response = NFD_SaveDialogN(
    &savePath, filters.ptr, filters.length.to!uint, defaultPath.toUTF8z, defaultName.toUTF8z
  );
  if (response.asOriginalType == Result.okay) {
    version (Windows) const selectedPath = (
      cast(wchar[]) savePath[0 .. (cast(wchar*) savePath).wcslen]
    ).toUTF8.to!string;
    else const selectedPath = savePath[0 .. savePath.strlen].to!string.idup;
    NFD_FreePathN(savePath.toNfdChar);
    path = selectedPath;
  }
  return response.asOriginalType.to!Result;
}

// TODO: NFD_SaveDialogN_With

///
Result pickFolder(out string path, string defaultPath = null) {
  if (!isInitialized) return Result.error;  // [vibe3d vendor patch 0431] see PATCHES.md
  nfdnchar_t* outPath;

  version (Windows) auto response = NFD_PickFolderN(&outPath, defaultPath.toUTF16z.toNfdChar);
  else auto response = NFD_PickFolderN(&outPath, defaultPath.toUTF8z);
  if (response.asOriginalType == Result.okay) {
    version (Windows) const selectedPath = (
      cast(wchar[]) outPath[0 .. (cast(wchar*) outPath).wcslen]
    ).toUTF8.to!string;
    else const selectedPath = outPath[0 .. outPath.strlen].to!string.idup;
    NFD_FreePathN(outPath.toNfdChar);
    path = selectedPath;
  }
  return response.asOriginalType.to!Result;
}

// TODO: NFD_PickFolderN_With

///
alias PathSetSize = nfdpathsetsize_t;

///
struct PathSet {
  package nfdpathset_t* set;

  ~this() {
    NFD_PathSet_Free(set);
  }

  const(void)** ptr() const @property {
    import std.conv : castFrom;
    return castFrom!(const void*).to!(const(void)**)(set);
  }

  ///
  ulong length() const @property {
    nfdpathsetsize_t count;
    assert(NFD_PathSet_GetCount(set, &count).asOriginalType == Result.okay);
    return count.to!ulong;
  }

  // TODO: Implement an enumerator interface with std.slice: NFD_PathSet_GetEnum, NFD_PathSet_EnumNextN, NFD_PathSet_FreeEnum

  ///
  string opIndex(size_t i) {
    assert(i >= 0 && i < this.length);
    auto path = new nfdnchar_t[PATH_MAX];
    auto pathPtr = path.ptr;
    assert(NFD_PathSet_GetPathN(set, i.to!nfdpathsetsize_t, &pathPtr).asOriginalType == Result.okay);
    // TODO: NFD_PathSet_FreePathN
    return path.to!string;
  }

  /// Returns: UTF-8 path at offset, `index`.
  string pathAt(size_t index) {
    assert(index >= 0 && index < this.length);
    auto path = new nfdu8char_t[PATH_MAX];
    auto pathPtr = path.ptr;
    assert(NFD_PathSet_GetPathU8(set, index.to!nfdpathsetsize_t, &pathPtr).asOriginalType == Result.okay);
    // TODO: NFD_PathSet_FreePathU8
    return path.to!string;
  }
}
