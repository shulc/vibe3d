// include: shell.js
// include: minimum_runtime_check.js
(function() {
  // "30.0.0" -> 300000
  function humanReadableVersionToPacked(str) {
    str = str.split("-")[0];
    // Remove any trailing part from e.g. "12.53.3-alpha"
    var vers = str.split(".").slice(0, 3);
    while (vers.length < 3) vers.push("00");
    vers = vers.map((n, i, arr) => n.padStart(2, "0"));
    return vers.join("");
  }
  // 300000 -> "30.0.0"
  var packedVersionToHumanReadable = n => [ n / 1e4 | 0, (n / 100 | 0) % 100, n % 100 ].join(".");
  var TARGET_NOT_SUPPORTED = 2147483647;
  // Note: We use a typeof check here instead of optional chaining using
  // globalThis because older browsers might not have globalThis defined.
  // We skip the node version checking when running on Bun/Deno since the node
  // version they report doesn't seem to be useful.
  if (typeof process !== "undefined" && !process.versions?.bun && typeof Deno == "undefined") {
    var currentNodeVersion = process.versions?.node ? humanReadableVersionToPacked(process.versions.node) : TARGET_NOT_SUPPORTED;
    if (currentNodeVersion < 180300) {
      throw new Error(`This emscripten-generated code requires node v${packedVersionToHumanReadable(180300)} (detected v${packedVersionToHumanReadable(currentNodeVersion)})`);
    }
  }
  var userAgent = typeof navigator !== "undefined" && navigator.userAgent;
  if (!userAgent) {
    return;
  }
  var currentSafariVersion = userAgent.includes("Safari/") && !userAgent.includes("Chrome/") && userAgent.match(/Version\/(\d+\.?\d*\.?\d*)/) ? humanReadableVersionToPacked(userAgent.match(/Version\/(\d+\.?\d*\.?\d*)/)[1]) : TARGET_NOT_SUPPORTED;
  if (currentSafariVersion < 15e4) {
    throw new Error(`This emscripten-generated code requires Safari v${packedVersionToHumanReadable(15e4)} (detected v${currentSafariVersion})`);
  }
  var currentFirefoxVersion = userAgent.match(/Firefox\/(\d+(?:\.\d+)?)/) ? parseFloat(userAgent.match(/Firefox\/(\d+(?:\.\d+)?)/)[1]) : TARGET_NOT_SUPPORTED;
  if (currentFirefoxVersion < 79) {
    throw new Error(`This emscripten-generated code requires Firefox v79 (detected v${currentFirefoxVersion})`);
  }
  var currentChromeVersion = userAgent.match(/Chrome\/(\d+(?:\.\d+)?)/) ? parseFloat(userAgent.match(/Chrome\/(\d+(?:\.\d+)?)/)[1]) : TARGET_NOT_SUPPORTED;
  if (currentChromeVersion < 85) {
    throw new Error(`This emscripten-generated code requires Chrome v85 (detected v${currentChromeVersion})`);
  }
})();

// end include: minimum_runtime_check.js
// The Module object: Our interface to the outside world. We import
// and export values on it. There are various ways Module can be used:
// 1. Not defined. We create it here
// 2. A function parameter, function(moduleArg) => Promise<Module>
// 3. pre-run appended it, var Module = {}; ..generated code..
// 4. External script tag defines var Module.
// We need to check if Module already exists (e.g. case 3 above).
// Substitution will be replaced with actual code on later stage of the build,
// this way Closure Compiler will not mangle it (e.g. case 4. above).
// Note that if you want to run closure, and also to use Module
// after the generated code, you will need to define   var Module = {};
// before the code. Then that object will be used in the code, and you
// can continue to use Module afterwards as well.
var Module = typeof Module != "undefined" ? Module : {};

// Determine the runtime environment we are in. You can customize this by
// setting the ENVIRONMENT setting at compile time (see settings.js).
// Attempt to auto-detect the environment
var ENVIRONMENT_IS_WEB = !!globalThis.window;

var ENVIRONMENT_IS_WORKER = !!globalThis.WorkerGlobalScope;

// N.b. Electron.js environment is simultaneously a NODE-environment, but
// also a web environment.
var ENVIRONMENT_IS_NODE = globalThis.process?.versions?.node && globalThis.process?.type != "renderer";

var ENVIRONMENT_IS_SHELL = !ENVIRONMENT_IS_WEB && !ENVIRONMENT_IS_NODE && !ENVIRONMENT_IS_WORKER;

// --pre-jses are emitted after the Module integration code, so that they can
// refer to Module (if they choose; they can also define Module)
// include: /var/tmp/tmp3ooi7ep_.js
if (!Module["expectedDataFileDownloads"]) Module["expectedDataFileDownloads"] = 0;

Module["expectedDataFileDownloads"]++;

(() => {
  // Do not attempt to redownload the virtual filesystem data when in a pthread or a Wasm Worker context.
  var isPthread = typeof ENVIRONMENT_IS_PTHREAD != "undefined" && ENVIRONMENT_IS_PTHREAD;
  var isWasmWorker = typeof ENVIRONMENT_IS_WASM_WORKER != "undefined" && ENVIRONMENT_IS_WASM_WORKER;
  if (isPthread || isWasmWorker) return;
  var isNode = globalThis.process && globalThis.process.versions && globalThis.process.versions.node && globalThis.process.type != "renderer";
  async function loadPackage(metadata) {
    var PACKAGE_PATH = "";
    if (typeof window === "object") {
      PACKAGE_PATH = window["encodeURIComponent"](window.location.pathname.substring(0, window.location.pathname.lastIndexOf("/")) + "/");
    } else if (typeof process === "undefined" && typeof location !== "undefined") {
      // web worker
      PACKAGE_PATH = encodeURIComponent(location.pathname.substring(0, location.pathname.lastIndexOf("/")) + "/");
    }
    var PACKAGE_NAME = "/home/ashagarov/Code/wt/w16-browser-page/vibe3d/.build/web-dub-home/cache/vibe3d/0.0.2/build/web-$DFLAGS-u-F89JFSnkd-yh2_SvjoGA/vibe3d.data";
    var REMOTE_PACKAGE_BASE = "vibe3d.data";
    var REMOTE_PACKAGE_NAME = Module["locateFile"] ? Module["locateFile"](REMOTE_PACKAGE_BASE, "") : REMOTE_PACKAGE_BASE;
    var REMOTE_PACKAGE_SIZE = metadata["remote_package_size"];
    async function fetchRemotePackage(packageName, packageSize) {
      if (isNode) {
        var contents = require("fs").readFileSync(packageName);
        return new Uint8Array(contents).buffer;
      }
      if (!Module["dataFileDownloads"]) Module["dataFileDownloads"] = {};
      try {
        var response = await fetch(packageName);
      } catch (e) {
        throw new Error(`Network Error: ${packageName}`, {
          e
        });
      }
      if (!response.ok) {
        throw new Error(`${response.status}: ${response.url}`);
      }
      const chunks = [];
      const headers = response.headers;
      const total = Number(headers.get("Content-Length") || packageSize);
      let loaded = 0;
      Module["setStatus"] && Module["setStatus"]("Downloading data...");
      const reader = response.body.getReader();
      while (1) {
        var {done, value} = await reader.read();
        if (done) break;
        chunks.push(value);
        loaded += value.length;
        Module["dataFileDownloads"][packageName] = {
          loaded,
          total
        };
        let totalLoaded = 0;
        let totalSize = 0;
        for (const download of Object.values(Module["dataFileDownloads"])) {
          totalLoaded += download.loaded;
          totalSize += download.total;
        }
        Module["setStatus"] && Module["setStatus"](`Downloading data... (${totalLoaded}/${totalSize})`);
      }
      const packageData = new Uint8Array(chunks.map(c => c.length).reduce((a, b) => a + b, 0));
      let offset = 0;
      for (const chunk of chunks) {
        packageData.set(chunk, offset);
        offset += chunk.length;
      }
      return packageData.buffer;
    }
    var fetchPromise;
    var fetched = Module["getPreloadedPackage"] && Module["getPreloadedPackage"](REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE);
    if (!fetched) {
      // Note that we don't use await here because we want to execute the
      // the rest of this function immediately.
      fetchPromise = fetchRemotePackage(REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE);
    }
    async function runWithFS(Module) {
      function assert(check, msg) {
        if (!check) throw new Error(msg);
      }
      Module["FS_createPath"]("/", "config", true, true);
      Module["FS_createPath"]("/config", "forms", true, true);
      async function processPackageData(arrayBuffer) {
        assert(arrayBuffer, "Loading data file failed.");
        assert(arrayBuffer.constructor.name === ArrayBuffer.name, "bad input to processPackageData " + arrayBuffer.constructor.name);
        var byteArray = new Uint8Array(arrayBuffer);
        var curr;
        // Reuse the bytearray from the XHR as the source for file reads.
        for (var file of metadata["files"]) {
          var name = file["filename"];
          var data = byteArray.subarray(file["start"], file["end"]);
          // canOwn this data in the filesystem, it is a slice into the heap that will never change
          Module["FS_createDataFile"](name, null, data, true, true, true);
        }
        Module["removeRunDependency"]("datafile_/home/ashagarov/Code/wt/w16-browser-page/vibe3d/.build/web-dub-home/cache/vibe3d/0.0.2/build/web-$DFLAGS-u-F89JFSnkd-yh2_SvjoGA/vibe3d.data");
      }
      Module["addRunDependency"]("datafile_/home/ashagarov/Code/wt/w16-browser-page/vibe3d/.build/web-dub-home/cache/vibe3d/0.0.2/build/web-$DFLAGS-u-F89JFSnkd-yh2_SvjoGA/vibe3d.data");
      if (!Module["preloadResults"]) Module["preloadResults"] = {};
      Module["preloadResults"][PACKAGE_NAME] = {
        fromCache: false
      };
      if (!fetched) {
        fetched = await fetchPromise;
      }
      await processPackageData(fetched);
    }
    // Detect whether the module JS file has already been loaded.
    if (Module["FS_createPath"]) {
      runWithFS(Module);
    } else {
      if (!Module["preRun"]) Module["preRun"] = [];
      Module["preRun"].push(runWithFS);
    }
  }
  loadPackage({
    "files": [ {
      "filename": "/config/buttons.yaml",
      "start": 0,
      "end": 17773
    }, {
      "filename": "/config/forms/actioncenter.yaml",
      "start": 17773,
      "end": 19526
    }, {
      "filename": "/config/forms/array.yaml",
      "start": 19526,
      "end": 22700
    }, {
      "filename": "/config/forms/box.yaml",
      "start": 22700,
      "end": 24904
    }, {
      "filename": "/config/forms/falloff.yaml",
      "start": 24904,
      "end": 30615
    }, {
      "filename": "/config/forms/jitter.yaml",
      "start": 30615,
      "end": 32106
    }, {
      "filename": "/config/forms/layer_props.yaml",
      "start": 32106,
      "end": 40423
    }, {
      "filename": "/config/forms/loopslice.yaml",
      "start": 40423,
      "end": 44160
    }, {
      "filename": "/config/forms/quantize.yaml",
      "start": 44160,
      "end": 45212
    }, {
      "filename": "/config/forms/slice.yaml",
      "start": 45212,
      "end": 48900
    }, {
      "filename": "/config/forms/smooth.yaml",
      "start": 48900,
      "end": 50488
    }, {
      "filename": "/config/forms/topology_pen.yaml",
      "start": 50488,
      "end": 58789
    }, {
      "filename": "/config/forms/transform.yaml",
      "start": 58789,
      "end": 66779
    }, {
      "filename": "/config/pies.yaml",
      "start": 66779,
      "end": 70145
    }, {
      "filename": "/config/shortcuts.yaml",
      "start": 70145,
      "end": 74222
    }, {
      "filename": "/config/shortcuts_macos.yaml",
      "start": 74222,
      "end": 77817
    }, {
      "filename": "/config/statusline.yaml",
      "start": 77817,
      "end": 93894
    }, {
      "filename": "/config/tool_presets.yaml",
      "start": 93894,
      "end": 103728
    } ],
    "remote_package_size": 103728
  });
})();

// end include: /var/tmp/tmp3ooi7ep_.js
// include: /var/tmp/tmpukfrgoos.js
// All the pre-js content up to here must remain later on, we need to run
// it.
if ((typeof ENVIRONMENT_IS_WASM_WORKER != "undefined" && ENVIRONMENT_IS_WASM_WORKER) || (typeof ENVIRONMENT_IS_PTHREAD != "undefined" && ENVIRONMENT_IS_PTHREAD) || (typeof ENVIRONMENT_IS_AUDIO_WORKLET != "undefined" && ENVIRONMENT_IS_AUDIO_WORKLET)) Module["preRun"] = [];

var necessaryPreJSTasks = Module["preRun"].slice();

// end include: /var/tmp/tmpukfrgoos.js
// include: /var/tmp/tmprf18w7kf.js
if (!Module["preRun"]) throw "Module.preRun should exist because file support used it; did a pre-js delete it?";

necessaryPreJSTasks.forEach(task => {
  if (Module["preRun"].indexOf(task) < 0) throw "All preRun tasks that exist before user pre-js code should remain after; did you replace Module or modify Module.preRun?";
});

// end include: /var/tmp/tmprf18w7kf.js
var programArgs = [];

var thisProgram = "./this.program";

var quit_ = (status, toThrow) => {
  throw toThrow;
};

// In MODULARIZE mode _scriptName needs to be captured already at the very top of the page immediately when the page is parsed, so it is generated there
// before the page load. In non-MODULARIZE modes generate it here.
var _scriptName = globalThis.document?.currentScript?.src;

if (typeof __filename != "undefined") {
  // Node
  _scriptName = __filename;
} else if (ENVIRONMENT_IS_WORKER) {
  _scriptName = self.location.href;
}

// `/` should be present at the end if `scriptDirectory` is not empty
var scriptDirectory = "";

function locateFile(path) {
  return scriptDirectory + path;
}

// Hooks that are implemented differently in different runtime environments.
var readAsync, readBinary;

if (ENVIRONMENT_IS_NODE) {
  const isNode = globalThis.process?.versions?.node && globalThis.process?.type != "renderer";
  if (!isNode) throw new Error("not compiled for this environment (did you build to HTML and try to run it not on the web, or set ENVIRONMENT to something - like node - and run it someplace else - like on the web?)");
  // These modules will usually be used on Node.js. Load them eagerly to avoid
  // the complexity of lazy-loading.
  var fs = require("node:fs");
  scriptDirectory = __dirname + "/";
  // include: node_shell_read.js
  readBinary = filename => {
    // We need to re-wrap `file://` strings to URLs.
    filename = isFileURI(filename) ? new URL(filename) : filename;
    var ret = fs.readFileSync(filename);
    assert(Buffer.isBuffer(ret));
    return ret;
  };
  readAsync = async (filename, binary = true) => {
    // See the comment in the `readBinary` function.
    filename = isFileURI(filename) ? new URL(filename) : filename;
    var ret = fs.readFileSync(filename, binary ? undefined : "utf8");
    assert(binary ? Buffer.isBuffer(ret) : typeof ret == "string");
    return ret;
  };
  // end include: node_shell_read.js
  if (process.argv.length > 1) {
    thisProgram = process.argv[1].replace(/\\/g, "/");
  }
  programArgs = process.argv.slice(2);
  // MODULARIZE will export the module in the proper place outside, we don't need to export here
  if (typeof module != "undefined") {
    module["exports"] = Module;
  }
  quit_ = (status, toThrow) => {
    process.exitCode = status;
    throw toThrow;
  };
} else if (ENVIRONMENT_IS_SHELL) {} else // Note that this includes Node.js workers when relevant (pthreads is enabled).
// Node.js workers are detected as a combination of ENVIRONMENT_IS_WORKER and
// ENVIRONMENT_IS_NODE.
if (ENVIRONMENT_IS_WEB || ENVIRONMENT_IS_WORKER) {
  try {
    scriptDirectory = new URL(".", _scriptName).href;
  } catch {}
  if (!(globalThis.window || globalThis.WorkerGlobalScope)) throw new Error("not compiled for this environment (did you build to HTML and try to run it not on the web, or set ENVIRONMENT to something - like node - and run it someplace else - like on the web?)");
  {
    // include: web_or_worker_shell_read.js
    if (ENVIRONMENT_IS_WORKER) {
      readBinary = url => {
        var xhr = new XMLHttpRequest;
        xhr.open("GET", url, false);
        xhr.responseType = "arraybuffer";
        xhr.send(null);
        return new Uint8Array(/** @type{!ArrayBuffer} */ (xhr.response));
      };
    }
    readAsync = async url => {
      // Fetch has some additional restrictions over XHR, like it can't be used on a file:// url.
      // See https://github.com/github/fetch/pull/92#issuecomment-140665932
      // Cordova or Electron apps are typically loaded from a file:// url.
      // So use XHR on webview if URL is a file URL.
      if (isFileURI(url)) {
        return new Promise((resolve, reject) => {
          var xhr = new XMLHttpRequest;
          xhr.open("GET", url, true);
          xhr.responseType = "arraybuffer";
          xhr.onload = () => {
            if (xhr.status == 200 || (xhr.status == 0 && xhr.response)) {
              // file URLs can return 0
              resolve(xhr.response);
              return;
            }
            reject(xhr.status);
          };
          xhr.onerror = reject;
          xhr.send(null);
        });
      }
      var response = await fetch(url, {
        credentials: "same-origin"
      });
      if (response.ok) {
        return response.arrayBuffer();
      }
      throw new Error(response.status + " : " + response.url);
    };
  }
} else {
  throw new Error("environment detection error");
}

var out = console.log.bind(console);

var err = console.error.bind(console);

var IDBFS = "IDBFS is no longer included by default; build with -lidbfs.js";

var PROXYFS = "PROXYFS is no longer included by default; build with -lproxyfs.js";

var WORKERFS = "WORKERFS is no longer included by default; build with -lworkerfs.js";

var FETCHFS = "FETCHFS is no longer included by default; build with -lfetchfs.js";

var ICASEFS = "ICASEFS is no longer included by default; build with -licasefs.js";

var JSFILEFS = "JSFILEFS is no longer included by default; build with -ljsfilefs.js";

var OPFS = "OPFS is no longer included by default; build with -lopfs.js";

var NODEFS = "NODEFS is no longer included by default; build with -lnodefs.js";

// perform assertions in shell.js after we set up out() and err(), as otherwise
// if an assertion fails it cannot print the message
assert(!ENVIRONMENT_IS_SHELL, "shell environment detected but not enabled at build time (add `shell` to `-sENVIRONMENT` to enable)");

// end include: shell.js
// include: preamble.js
// === Preamble library stuff ===
// Documentation for the public APIs defined in this file must be updated in:
//    site/source/docs/api_reference/preamble.js.rst
// A prebuilt local version of the documentation is available at:
//    site/build/text/docs/api_reference/preamble.js.txt
// You can also build docs locally as HTML or other formats in site/
// An online HTML version (which may be of a different version of Emscripten)
//    is up at http://kripken.github.io/emscripten-site/docs/api_reference/preamble.js.html
var wasmBinary;

if (!globalThis.WebAssembly) {
  err("no native wasm support detected");
}

// Wasm globals
//========================================
// Runtime essentials
//========================================
// whether we are quitting the application. no code should run after this.
// set in exit() and abort()
var ABORT = false;

// set by exit() and abort().  Passed to 'onExit' handler.
// NOTE: This is also used as the process return code in shell environments
// but only when noExitRuntime is false.
var EXITSTATUS;

// In STRICT mode, we only define assert() when ASSERTIONS is set.  i.e. we
// don't define it at all in release modes.  This matches the behaviour of
// MINIMAL_RUNTIME.
// TODO(sbc): Make this the default even without STRICT enabled.
/** @type {function(*, string=)} */ function assert(condition, text) {
  if (!condition) {
    abort("Assertion failed" + (text ? ": " + text : ""));
  }
}

// We used to include malloc/free by default in the past. Show a helpful error in
// builds with assertions.
/**
 * Indicates whether filename is delivered via file protocol (as opposed to http/https)
 * @noinline
 */ var isFileURI = filename => filename.startsWith("file://");

// include: runtime_common.js
// include: runtime_exceptions.js
// Base Emscripten EH error class
class EmscriptenEH {}

class EmscriptenSjLj extends EmscriptenEH {}

// end include: runtime_exceptions.js
// include: runtime_debug.js
var runtimeDebug = true;

// Switch to false at runtime to disable logging at the right times
// Used by XXXXX_DEBUG settings to output debug messages.
function dbg(...args) {
  if (!runtimeDebug && typeof runtimeDebug != "undefined") return;
  // TODO(sbc): Make this configurable somehow.  Its not always convenient for
  // logging to show up as warnings.
  console.warn(...args);
}

// Endianness check
(() => {
  var h16 = new Int16Array(1);
  var h8 = new Int8Array(h16.buffer);
  h16[0] = 25459;
  if (h8[0] !== 115 || h8[1] !== 99) abort("Runtime error: expected the system to be little-endian! (Run with -sSUPPORT_BIG_ENDIAN to bypass)");
})();

function consumedModuleProp(prop) {
  var value = Module[prop];
  var msg = `Attempt to modify \`Module.${prop}\` after it has already been processed.  This can happen, for example, when code is injected via '--post-js' rather than '--pre-js'`;
  if (Array.isArray(value)) {
    value = new Proxy(value, {
      set(target, key, val) {
        abort(msg);
        return false;
      },
      defineProperty(target, key, descriptor) {
        abort(msg);
        return false;
      },
      deleteProperty(target, key) {
        abort(msg);
        return false;
      }
    });
  }
  Object.defineProperty(Module, prop, {
    configurable: true,
    get() {
      return value;
    },
    set() {
      abort(msg);
    }
  });
}

function makeInvalidEarlyAccess(name) {
  return () => assert(false, `call to '${name}' via reference taken before Wasm module initialization`);
}

function ignoredModuleProp(prop) {
  if (Object.getOwnPropertyDescriptor(Module, prop)) {
    abort(`\`Module.${prop}\` was supplied but \`${prop}\` not included in INCOMING_MODULE_JS_API`);
  }
}

// forcing the filesystem exports a few things by default
function isExportedByForceFilesystem(name) {
  return name === "FS_createPath" || name === "FS_createDataFile" || name === "FS_createPreloadedFile" || name === "FS_preloadFile" || name === "FS_unlink" || name === "addRunDependency" || // The old FS has some functionality that WasmFS lacks.
  name === "FS_createLazyFile" || name === "FS_createDevice" || name === "removeRunDependency";
}

/**
 * Intercept access to a symbols in the global symbol.  This enables us to give
 * informative warnings/errors when folks attempt to use symbols they did not
 * include in their build, or no symbols that no longer exist.
 *
 * We don't define this in MODULARIZE mode since in that mode emscripten symbols
 * are never placed in the global scope.
 */ function hookGlobalSymbolAccess(sym, func) {
  if (!Object.getOwnPropertyDescriptor(globalThis, sym)) {
    Object.defineProperty(globalThis, sym, {
      configurable: true,
      get() {
        func();
        return undefined;
      }
    });
  }
}

function missingGlobal(sym, msg) {
  hookGlobalSymbolAccess(sym, () => {
    warnOnce(`\`${sym}\` is no longer defined by emscripten. ${msg}`);
  });
}

missingGlobal("buffer", "Please use HEAP8.buffer or wasmMemory.buffer");

missingGlobal("asm", "Please use wasmExports instead");

function missingLibrarySymbol(sym) {
  hookGlobalSymbolAccess(sym, () => {
    // Can't `abort()` here because it would break code that does runtime
    // checks.  e.g. `if (typeof SDL === 'undefined')`.
    var msg = `\`${sym}\` is a library symbol and not included by default; add it to your library.js __deps or to DEFAULT_LIBRARY_FUNCS_TO_INCLUDE on the command line`;
    // DEFAULT_LIBRARY_FUNCS_TO_INCLUDE requires the name as it appears in
    // library.js, which means $name for a JS name with no prefix, or name
    // for a JS name like _name.
    var librarySymbol = sym;
    if (!librarySymbol.startsWith("_")) {
      librarySymbol = "$" + sym;
    }
    msg += ` (e.g. -sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE='${librarySymbol}')`;
    if (isExportedByForceFilesystem(sym)) {
      msg += ". Alternatively, forcing filesystem support (-sFORCE_FILESYSTEM) can export this for you";
    }
    warnOnce(msg);
  });
  // Any symbol that is not included from the JS library is also (by definition)
  // not exported on the Module object.
  unexportedRuntimeSymbol(sym);
}

function unexportedRuntimeSymbol(sym) {
  if (!Object.getOwnPropertyDescriptor(Module, sym)) {
    Object.defineProperty(Module, sym, {
      configurable: true,
      get() {
        var msg = `'${sym}' was not exported. add it to EXPORTED_RUNTIME_METHODS (see the Emscripten FAQ)`;
        if (isExportedByForceFilesystem(sym)) {
          msg += ". Alternatively, forcing filesystem support (-sFORCE_FILESYSTEM) can export this for you";
        }
        abort(msg);
      }
    });
  }
}

// end include: runtime_debug.js
// include: runtime_stack_check.js
const stackCookie1 = 34821223;

const stackCookie2 = 2310721022;

// Initializes the stack cookie. Called at the startup of main and at the startup of each thread in pthreads mode.
function writeStackCookie() {
  var max = _emscripten_stack_get_end();
  assert((max & 3) == 0);
  // If the stack ends at address zero we write our cookies 4 bytes into the
  // stack.  This prevents interference with SAFE_HEAP and ASAN which also
  // monitor writes to address zero.
  if (max == 0) {
    max += 4;
  }
  // The stack grow downwards towards _emscripten_stack_get_end.
  // We write cookies to the final two words in the stack and detect if they are
  // ever overwritten.
  HEAPU32[((max) >>> 2) >>> 0] = stackCookie1;
  HEAPU32[(((max) + (4)) >>> 2) >>> 0] = stackCookie2;
  // Also test the global address 0 for integrity.
  HEAPU32[((0) >>> 2) >>> 0] = 1668509029;
}

function u32ToHexString(num) {
  return "0x" + (num >>> 0).toString(16).padStart(8, "0");
}

function checkStackCookie() {
  if (ABORT) return;
  var max = _emscripten_stack_get_end();
  // See writeStackCookie().
  if (max == 0) {
    max += 4;
  }
  var val1 = HEAPU32[((max) >>> 2) >>> 0];
  var val2 = HEAPU32[(((max) + (4)) >>> 2) >>> 0];
  if (val1 != stackCookie1 || val2 != stackCookie2) {
    abort(`Stack overflow! Stack cookie has been overwritten at ${ptrToString(max)}, expected hex dwords ${u32ToHexString(stackCookie2)} and ${u32ToHexString(stackCookie1)}, but received ${u32ToHexString(val2)} ${u32ToHexString(val1)}`);
  }
  // Also test the global address 0 for integrity.
  if (HEAPU32[((0) >>> 2) >>> 0] != 1668509029) {
    abort("Runtime error: The application has corrupted its heap memory area (address zero)!");
  }
}

// end include: runtime_stack_check.js
// Memory management
var runtimeInitialized = false;

// When ALLOW_MEMORY_GROWTH is enabled, the conversion from Wasm
// memory to ArrayBuffer requires some additional logic.
function getMemoryBuffer() {
  return wasmMemory.buffer;
}

function updateMemoryViews() {
  // If we already have a heap that is resizeable/growable buffer we don't
  // need to do anything in updateMemoryViews.
  if (HEAP8?.buffer?.resizable) return;
  var b = getMemoryBuffer();
  HEAP8 = new Int8Array(b);
  HEAP16 = new Int16Array(b);
  HEAPU8 = new Uint8Array(b);
  HEAPU16 = new Uint16Array(b);
  HEAP32 = new Int32Array(b);
  HEAPU32 = new Uint32Array(b);
  HEAPF32 = new Float32Array(b);
  HEAPF64 = new Float64Array(b);
  HEAP64 = new BigInt64Array(b);
}

// include: memoryprofiler.js
// end include: memoryprofiler.js
// end include: runtime_common.js
assert(globalThis.Int32Array && globalThis.Float64Array && Int32Array.prototype.subarray && Int32Array.prototype.set, "JS engine does not provide full typed array support");

function preRun() {
  var preRun = Module["preRun"];
  if (preRun) {
    if (typeof preRun == "function") preRun = [ preRun ];
    onPreRuns.push(...preRun);
  }
  consumedModuleProp("preRun");
  // Begin ATPRERUNS hooks
  callRuntimeCallbacks(onPreRuns);
}

function initRuntime() {
  assert(!runtimeInitialized);
  runtimeInitialized = true;
  checkStackCookie();
  // Begin ATINITS hooks
  if (!Module["noFSInit"] && !FS.initialized) FS.init();
  TTY.init();
  // End ATINITS hooks
  wasmExports["__wasm_call_ctors"]();
  // Begin ATPOSTCTORS hooks
  FS.ignorePermissions = false;
  // End ATPOSTCTORS hooks
  checkStackCookie();
}

function postRun() {
  checkStackCookie();
}

/**
 * @param {string|number=} what
 */ function abort(what) {
  what = `Aborted(${what})`;
  // TODO(sbc): Should we remove printing and leave it up to whoever
  // catches the exception?
  err(what);
  ABORT = true;
  // Use a wasm runtime error, because a JS error might be seen as a foreign
  // exception, which means we'd run destructors on it. We need the error to
  // simply make the program stop.
  // FIXME This approach does not work in Wasm EH because it currently does not assume
  // all RuntimeErrors are from traps; it decides whether a RuntimeError is from
  // a trap or not based on a hidden field within the object. So at the moment
  // we don't have a way of throwing a wasm trap from JS. TODO Make a JS API that
  // allows this in the wasm spec.
  // Suppress closure compiler warning here. Closure compiler's builtin extern
  // definition for WebAssembly.RuntimeError claims it takes no arguments even
  // though it can.
  // TODO(https://github.com/google/closure-compiler/pull/3913): Remove if/when upstream closure gets fixed.
  /** @suppress {checkTypes} */ var e = new WebAssembly.RuntimeError(what);
  // Throw the error whether or not MODULARIZE is set because abort is used
  // in code paths apart from instantiation where an exception is expected
  // to be thrown when abort is called.
  throw e;
}

function createExportWrapper(name, func, nargs) {
  assert(func);
  return (...args) => {
    assert(runtimeInitialized, `native function \`${name}\` called before runtime initialization`);
    // Only assert for too many arguments. Too few can be valid since the missing arguments will be zero filled.
    assert(args.length <= nargs, `native function \`${name}\` called with ${args.length} args but expects ${nargs}`);
    return func(...args);
  };
}

var wasmBinaryFile;

function findWasmBinary() {
  return locateFile("vibe3d.wasm");
}

function getBinarySync(file) {
  if (file == wasmBinaryFile && wasmBinary) {
    return new Uint8Array(wasmBinary);
  }
  if (readBinary) {
    return readBinary(file);
  }
  // Throwing a plain string here, even though it not normally advisable since
  // this gets turning into an `abort` in instantiateArrayBuffer.
  throw "both async and sync fetching of the wasm failed";
}

async function getWasmBinary(binaryFile) {
  // If we don't have the binary yet, load it asynchronously using readAsync.
  if (!wasmBinary) {
    // Fetch the binary using readAsync
    try {
      var response = await readAsync(binaryFile);
      return new Uint8Array(response);
    } catch {}
  }
  // Otherwise, getBinarySync should be able to get it synchronously
  return getBinarySync(binaryFile);
}

async function instantiateArrayBuffer(binaryFile, imports) {
  try {
    var binary = await getWasmBinary(binaryFile);
    var instance = await WebAssembly.instantiate(binary, imports);
    return instance;
  } catch (reason) {
    err(`failed to asynchronously prepare wasm: ${reason}`);
    // Warn on some common problems.
    if (isFileURI(binaryFile)) {
      err(`warning: Loading from a file URI (${binaryFile}) is not supported in most browsers. See https://emscripten.org/docs/getting_started/FAQ.html#how-do-i-run-a-local-webserver-for-testing-why-does-my-program-stall-in-downloading-or-preparing`);
    }
    abort(reason);
  }
}

async function instantiateAsync(binary, binaryFile, imports) {
  if (!binary && !isFileURI(binaryFile) && !ENVIRONMENT_IS_NODE) {
    try {
      var response = fetch(binaryFile, {
        credentials: "same-origin"
      });
      var instantiationResult = await WebAssembly.instantiateStreaming(response, imports);
      return instantiationResult;
    } catch (reason) {
      // We expect the most common failure cause to be a bad MIME type for the binary,
      // in which case falling back to ArrayBuffer instantiation should work.
      err(`wasm streaming compile failed: ${reason}`);
      err("falling back to ArrayBuffer instantiation");
    }
  }
  return instantiateArrayBuffer(binaryFile, imports);
}

function getWasmImports() {
  // prepare imports
  var imports = {
    "env": wasmImports,
    "wasi_snapshot_preview1": wasmImports
  };
  return imports;
}

// Create the wasm instance.
// Receives the wasm imports, returns the exports.
async function createWasm() {
  // Load the wasm module and create an instance of using native support in the JS engine.
  // handle a generated wasm instance, receiving its exports and
  // performing other necessary setup
  function receiveInstance(instance) {
    wasmExports = instance.exports;
    wasmExports = applySignatureConversions(wasmExports);
    assignWasmExports(wasmExports);
    updateMemoryViews();
    return wasmExports;
  }
  // Prefer streaming instantiation if available.
  // Async compilation can be confusing when an error on the page overwrites Module
  // (for example, if the order of elements is wrong, and the one defining Module is
  // later), so we save Module and check it later.
  var trueModule = Module;
  function receiveInstantiationResult(result) {
    // 'result' is a ResultObject object which has both the module and instance.
    // receiveInstance() will swap in the exports (to Module.asm) so they can be called
    assert(Module === trueModule, "the Module object should not be replaced during async compilation - perhaps the order of HTML elements is wrong?");
    trueModule = null;
    // TODO: Due to Closure regression https://github.com/google/closure-compiler/issues/3193, the above line no longer optimizes out down to the following line.
    // When the regression is fixed, can restore the above PTHREADS-enabled path.
    return receiveInstance(result["instance"]);
  }
  var info = getWasmImports();
  wasmBinaryFile ??= findWasmBinary();
  var result = await instantiateAsync(wasmBinary, wasmBinaryFile, info);
  var exports = receiveInstantiationResult(result);
  return exports;
}

// end include: preamble.js
// Begin JS library code
class ExitStatus {
  name="ExitStatus";
  constructor(status) {
    this.message = `Program terminated with exit(${status})`;
    this.status = status;
  }
}

/** @type {!Int32Array} */ var HEAP32;

/** @type {!Int8Array} */ var HEAP8;

/** @type {!Uint32Array} */ var HEAPU32;

var callRuntimeCallbacks = callbacks => {
  while (callbacks.length > 0) {
    // Pass the module as the first argument.
    callbacks.shift()(Module);
  }
};

var onPreRuns = [];

var addOnPreRun = cb => onPreRuns.push(cb);

function ptrToString(ptr) {
  assert(typeof ptr === "number", `ptrToString expects a number, got ${typeof ptr}`);
  // Convert to 32-bit unsigned value
  ptr >>>= 0;
  return "0x" + ptr.toString(16).padStart(8, "0");
}

var stackRestore = val => __emscripten_stack_restore(val);

var stackSave = () => _emscripten_stack_get_current();

var warnOnce = text => {
  warnOnce.shown ||= {};
  if (!warnOnce.shown[text]) {
    warnOnce.shown[text] = 1;
    if (ENVIRONMENT_IS_NODE) text = "warning: " + text;
    err(text);
  }
};

class ExceptionInfo {
  // excPtr - Thrown object pointer to wrap. Metadata pointer is calculated from it.
  constructor(excPtr) {
    this.excPtr = excPtr;
    this.ptr = excPtr - 24;
  }
  set_type(type) {
    HEAPU32[(((this.ptr) + (4)) >>> 2) >>> 0] = type;
  }
  get_type() {
    return HEAPU32[(((this.ptr) + (4)) >>> 2) >>> 0];
  }
  set_destructor(destructor) {
    HEAPU32[(((this.ptr) + (8)) >>> 2) >>> 0] = destructor;
  }
  get_destructor() {
    return HEAPU32[(((this.ptr) + (8)) >>> 2) >>> 0];
  }
  set_caught(caught) {
    caught = caught ? 1 : 0;
    HEAP8[(this.ptr) + (12) >>> 0] = caught;
  }
  get_caught() {
    return HEAP8[(this.ptr) + (12) >>> 0] != 0;
  }
  set_rethrown(rethrown) {
    rethrown = rethrown ? 1 : 0;
    HEAP8[(this.ptr) + (13) >>> 0] = rethrown;
  }
  get_rethrown() {
    return HEAP8[(this.ptr) + (13) >>> 0] != 0;
  }
  // Initialize native structure fields. Should be called once after allocated.
  init(type, destructor) {
    this.set_adjusted_ptr(0);
    this.set_type(type);
    this.set_destructor(destructor);
  }
  set_adjusted_ptr(adjustedPtr) {
    HEAPU32[(((this.ptr) + (16)) >>> 2) >>> 0] = adjustedPtr;
  }
  get_adjusted_ptr() {
    return HEAPU32[(((this.ptr) + (16)) >>> 2) >>> 0];
  }
}

var uncaughtExceptionCount = 0;

var __Unwind_RaiseException = ex => {
  assert(false, "Exception thrown, but exception catching is not enabled. Compile with -sNO_DISABLE_EXCEPTION_CATCHING or -sEXCEPTION_CATCHING_ALLOWED=[..] to catch.");
};

var INT53_MAX = 9007199254740992;

var INT53_MIN = -9007199254740992;

var bigintToI53Checked = num => (num < INT53_MIN || num > INT53_MAX) ? NaN : Number(num);

function ___cxa_throw(ptr, type, destructor) {
  ptr >>>= 0;
  type >>>= 0;
  destructor >>>= 0;
  var info = new ExceptionInfo(ptr);
  // Initialize ExceptionInfo content after it was allocated in __cxa_allocate_exception.
  info.init(type, destructor);
  uncaughtExceptionCount++;
  __Unwind_RaiseException(ptr);
}

var PATH = {
  isAbs: path => path.charAt(0) === "/",
  splitPath: filename => {
    var splitPathRe = /^(\/?|)([\s\S]*?)((?:\.{1,2}|[^\/]+?|)(\.[^.\/]*|))(?:[\/]*)$/;
    return splitPathRe.exec(filename).slice(1);
  },
  normalizeArray: (parts, allowAboveRoot) => {
    // if the path tries to go above the root, `up` ends up > 0
    var up = 0;
    for (var i = parts.length - 1; i >= 0; i--) {
      var last = parts[i];
      if (last === ".") {
        parts.splice(i, 1);
      } else if (last === "..") {
        parts.splice(i, 1);
        up++;
      } else if (up) {
        parts.splice(i, 1);
        up--;
      }
    }
    // if the path is allowed to go above the root, restore leading ..s
    if (allowAboveRoot) {
      for (;up; up--) {
        parts.unshift("..");
      }
    }
    return parts;
  },
  normalize: path => {
    var isAbsolute = PATH.isAbs(path), trailingSlash = path.slice(-1) === "/";
    // Normalize the path
    path = PATH.normalizeArray(path.split("/").filter(p => !!p), !isAbsolute).join("/");
    if (!path && !isAbsolute) {
      path = ".";
    }
    if (path && trailingSlash) {
      path += "/";
    }
    return (isAbsolute ? "/" : "") + path;
  },
  dirname: path => {
    var result = PATH.splitPath(path), root = result[0], dir = result[1];
    if (!root && !dir) {
      // No dirname whatsoever
      return ".";
    }
    if (dir) {
      // It has a dirname, strip trailing slash
      dir = dir.slice(0, -1);
    }
    return root + dir;
  },
  basename: path => path && path.match(/([^\/]+|\/)\/*$/)[1],
  join: (...paths) => PATH.normalize(paths.join("/")),
  join2: (l, r) => PATH.normalize(l + "/" + r)
};

var initRandomFill = () => {
  // This block is not needed on v19+ since crypto.getRandomValues is builtin
  if (ENVIRONMENT_IS_NODE) {
    var nodeCrypto = require("node:crypto");
    return view => (nodeCrypto.randomFillSync(view), 0);
  }
  return view => (crypto.getRandomValues(view), 0);
};

var randomFill = view => (randomFill = initRandomFill())(view);

var PATH_FS = {
  resolve: (...args) => {
    var resolvedPath = "", resolvedAbsolute = false;
    for (var i = args.length - 1; i >= -1 && !resolvedAbsolute; i--) {
      var path = (i >= 0) ? args[i] : FS.cwd();
      // Skip empty and invalid entries
      if (typeof path != "string") {
        throw new TypeError("Arguments to path.resolve must be strings");
      } else if (!path) {
        return "";
      }
      resolvedPath = path + "/" + resolvedPath;
      resolvedAbsolute = PATH.isAbs(path);
    }
    // At this point the path should be resolved to a full absolute path, but
    // handle relative paths to be safe (might happen when process.cwd() fails)
    resolvedPath = PATH.normalizeArray(resolvedPath.split("/").filter(p => !!p), !resolvedAbsolute).join("/");
    return ((resolvedAbsolute ? "/" : "") + resolvedPath) || ".";
  },
  relative: (from, to) => {
    from = PATH_FS.resolve(from).slice(1);
    to = PATH_FS.resolve(to).slice(1);
    function trim(arr) {
      var start = 0;
      for (;start < arr.length; start++) {
        if (arr[start] !== "") break;
      }
      var end = arr.length - 1;
      for (;end >= 0; end--) {
        if (arr[end] !== "") break;
      }
      if (start > end) return [];
      return arr.slice(start, end - start + 1);
    }
    var fromParts = trim(from.split("/"));
    var toParts = trim(to.split("/"));
    var length = Math.min(fromParts.length, toParts.length);
    var samePartsLength = length;
    for (var i = 0; i < length; i++) {
      if (fromParts[i] !== toParts[i]) {
        samePartsLength = i;
        break;
      }
    }
    var outputParts = [];
    for (var i = samePartsLength; i < fromParts.length; i++) {
      outputParts.push("..");
    }
    outputParts = outputParts.concat(toParts.slice(samePartsLength));
    return outputParts.join("/");
  }
};

var UTF8Decoder = globalThis.TextDecoder && new TextDecoder;

/**
   * heapOrArray is either a regular array, or a JavaScript typed array view.
   * @param {number} idx
   * @param {number=} maxBytesToRead
   * @param {boolean=} ignoreNul
   * @return {number}
   */ var findStringEnd = (heapOrArray, idx, maxBytesToRead, ignoreNul) => {
  var maxIdx = idx + maxBytesToRead;
  if (ignoreNul) return maxIdx;
  // TextDecoder needs to know the byte length in advance, it doesn't stop on
  // null terminator by itself.
  // As a tiny code save trick, compare idx against maxIdx using a negation,
  // so that maxBytesToRead=undefined/NaN means Infinity.
  while (heapOrArray[idx] && !(idx >= maxIdx)) ++idx;
  return idx;
};

/**
   * Given a pointer 'idx' to a null-terminated UTF8-encoded string in the given
   * array that contains uint8 values, returns a copy of that string as a
   * Javascript String object.
   * heapOrArray is either a regular array, or a JavaScript typed array view.
   * @param {number=} idx
   * @param {number=} maxBytesToRead
   * @param {boolean=} ignoreNul - If true, the function will not stop on a NUL character.
   * @return {string}
   */ var UTF8ArrayToString = (heapOrArray, idx = 0, maxBytesToRead, ignoreNul) => {
  idx >>>= 0;
  var endPtr = findStringEnd(heapOrArray, idx, maxBytesToRead, ignoreNul);
  // When using conditional TextDecoder, skip it for short strings as the overhead of the native call is not worth it.
  if (endPtr - idx > 16 && heapOrArray.buffer && UTF8Decoder) {
    return UTF8Decoder.decode(heapOrArray.subarray(idx, endPtr));
  }
  var str = "";
  while (idx < endPtr) {
    // For UTF8 byte structure, see:
    // http://en.wikipedia.org/wiki/UTF-8#Description
    // https://www.ietf.org/rfc/rfc2279.txt
    // https://tools.ietf.org/html/rfc3629
    var u0 = heapOrArray[idx++];
    if (!(u0 & 128)) {
      str += String.fromCharCode(u0);
      continue;
    }
    var u1 = heapOrArray[idx++] & 63;
    if ((u0 & 224) == 192) {
      str += String.fromCharCode(((u0 & 31) << 6) | u1);
      continue;
    }
    var u2 = heapOrArray[idx++] & 63;
    if ((u0 & 240) == 224) {
      u0 = ((u0 & 15) << 12) | (u1 << 6) | u2;
    } else {
      if ((u0 & 248) != 240) warnOnce(`Invalid UTF-8 leading byte ${ptrToString(u0)} encountered when deserializing a UTF-8 string in wasm memory to a JS string!`);
      u0 = ((u0 & 7) << 18) | (u1 << 12) | (u2 << 6) | (heapOrArray[idx++] & 63);
    }
    if (u0 < 65536) {
      str += String.fromCharCode(u0);
    } else {
      var ch = u0 - 65536;
      str += String.fromCharCode(55296 | (ch >> 10), 56320 | (ch & 1023));
    }
  }
  return str;
};

var FS_stdin_getChar_buffer = [];

var lengthBytesUTF8 = str => {
  var len = 0;
  for (var i = 0; i < str.length; ++i) {
    // Gotcha: charCodeAt returns a 16-bit word that is a UTF-16 encoded code
    // unit, not a Unicode code point of the character! So decode
    // UTF16->UTF32->UTF8.
    // See http://unicode.org/faq/utf_bom.html#utf16-3
    var c = str.charCodeAt(i);
    // possibly a lead surrogate
    if (c <= 127) {
      len++;
    } else if (c <= 2047) {
      len += 2;
    } else if (c >= 55296 && c <= 57343) {
      len += 4;
      ++i;
    } else {
      len += 3;
    }
  }
  return len;
};

var stringToUTF8Array = (str, heap, outIdx, maxBytesToWrite) => {
  outIdx >>>= 0;
  assert(typeof str === "string", `stringToUTF8Array expects a string (got ${typeof str})`);
  // Parameter maxBytesToWrite is not optional. Negative values, 0, null,
  // undefined and false each don't write out any bytes.
  if (!(maxBytesToWrite > 0)) return 0;
  var startIdx = outIdx;
  var endIdx = outIdx + maxBytesToWrite - 1;
  // -1 for string null terminator.
  for (var i = 0; i < str.length; ++i) {
    // For UTF8 byte structure, see http://en.wikipedia.org/wiki/UTF-8#Description
    // and https://www.ietf.org/rfc/rfc2279.txt
    // and https://tools.ietf.org/html/rfc3629
    var u = str.codePointAt(i);
    if (u <= 127) {
      if (outIdx >= endIdx) break;
      heap[outIdx++ >>> 0] = u;
    } else if (u <= 2047) {
      if (outIdx + 1 >= endIdx) break;
      heap[outIdx++ >>> 0] = 192 | (u >> 6);
      heap[outIdx++ >>> 0] = 128 | (u & 63);
    } else if (u <= 65535) {
      if (outIdx + 2 >= endIdx) break;
      heap[outIdx++ >>> 0] = 224 | (u >> 12);
      heap[outIdx++ >>> 0] = 128 | ((u >> 6) & 63);
      heap[outIdx++ >>> 0] = 128 | (u & 63);
    } else {
      if (outIdx + 3 >= endIdx) break;
      if (u > 1114111) warnOnce(`Invalid Unicode code point ${ptrToString(u)} encountered when serializing a JS string to a UTF-8 string in wasm memory! (Valid unicode code points should be in range 0-0x10FFFF).`);
      heap[outIdx++ >>> 0] = 240 | (u >> 18);
      heap[outIdx++ >>> 0] = 128 | ((u >> 12) & 63);
      heap[outIdx++ >>> 0] = 128 | ((u >> 6) & 63);
      heap[outIdx++ >>> 0] = 128 | (u & 63);
      // Gotcha: if codePoint is over 0xFFFF, it is represented as a surrogate pair in UTF-16.
      // We need to manually skip over the second code unit for correct iteration.
      i++;
    }
  }
  // Null-terminate the pointer to the buffer.
  heap[outIdx >>> 0] = 0;
  return outIdx - startIdx;
};

/** @type {function(string, boolean=, number=)} */ var intArrayFromString = (stringy, dontAddNull, length) => {
  var len = length > 0 ? length : lengthBytesUTF8(stringy) + 1;
  var u8array = new Array(len);
  var numBytesWritten = stringToUTF8Array(stringy, u8array, 0, u8array.length);
  if (dontAddNull) u8array.length = numBytesWritten;
  return u8array;
};

var FS_stdin_getChar = () => {
  if (!FS_stdin_getChar_buffer.length) {
    var result = null;
    if (ENVIRONMENT_IS_NODE) {
      // we will read data by chunks of BUFSIZE
      var BUFSIZE = 256;
      var buf = Buffer.alloc(BUFSIZE);
      var bytesRead = 0;
      // For some reason we must suppress a closure warning here, even though
      // fd definitely exists on process.stdin, and is even the proper way to
      // get the fd of stdin,
      // https://github.com/nodejs/help/issues/2136#issuecomment-523649904
      // This started to happen after moving this logic out of library_tty.js,
      // so it is related to the surrounding code in some unclear manner.
      /** @suppress {missingProperties} */ var fd = process.stdin.fd;
      try {
        bytesRead = fs.readSync(fd, buf, 0, BUFSIZE);
      } catch (e) {
        // Cross-platform differences: on Windows, reading EOF throws an
        // exception, but on other OSes, reading EOF returns 0. Uniformize
        // behavior by treating the EOF exception to return 0.
        if (e.toString().includes("EOF")) bytesRead = 0; else throw e;
      }
      if (bytesRead > 0) {
        result = buf.slice(0, bytesRead).toString("utf-8");
      }
    } else if (globalThis.window?.prompt) {
      // Browser.
      result = window.prompt("Input: ");
      // returns null on cancel
      if (result !== null) {
        result += "\n";
      }
    } else {}
    if (!result) {
      return null;
    }
    FS_stdin_getChar_buffer = intArrayFromString(result, true);
  }
  return FS_stdin_getChar_buffer.shift();
};

var TTY = {
  ttys: [],
  init() {},
  shutdown() {},
  register(dev, ops) {
    TTY.ttys[dev] = {
      input: [],
      output: [],
      ops
    };
    FS.registerDevice(dev, TTY.stream_ops);
  },
  stream_ops: {
    open(stream) {
      var tty = TTY.ttys[stream.node.rdev];
      if (!tty) {
        throw new FS.ErrnoError(43);
      }
      stream.tty = tty;
      stream.seekable = false;
    },
    close(stream) {
      // flush any pending line data
      stream.tty.ops.fsync(stream.tty);
    },
    fsync(stream) {
      stream.tty.ops.fsync(stream.tty);
    },
    read(stream, buffer, offset, length, pos) {
      if (!stream.tty || !stream.tty.ops.get_char) {
        throw new FS.ErrnoError(60);
      }
      var bytesRead = 0;
      for (var i = 0; i < length; i++) {
        var result;
        try {
          result = stream.tty.ops.get_char(stream.tty);
        } catch (e) {
          throw new FS.ErrnoError(29);
        }
        if (result === undefined && !bytesRead) {
          throw new FS.ErrnoError(6);
        }
        if (result === null || result === undefined) break;
        bytesRead++;
        buffer[offset + i] = result;
        // We currently only support canonical mode (ICANON), where
        // read(2) returns as soon as a line delimiter is read.
        if (result === 10) break;
      }
      if (bytesRead) {
        stream.node.atime = Date.now();
      }
      return bytesRead;
    },
    write(stream, buffer, offset, length, pos) {
      if (!stream.tty || !stream.tty.ops.put_char) {
        throw new FS.ErrnoError(60);
      }
      try {
        for (var i = 0; i < length; i++) {
          stream.tty.ops.put_char(stream.tty, buffer[offset + i]);
        }
      } catch (e) {
        throw new FS.ErrnoError(29);
      }
      if (length) {
        stream.node.mtime = stream.node.ctime = Date.now();
      }
      return i;
    }
  },
  default_tty_ops: {
    get_char(tty) {
      return FS_stdin_getChar();
    },
    put_char(tty, val) {
      if (val === null || val === 10) {
        out(UTF8ArrayToString(tty.output));
        tty.output = [];
      } else {
        if (val != 0) tty.output.push(val);
      }
    },
    fsync(tty) {
      if (tty.output?.length > 0) {
        out(UTF8ArrayToString(tty.output));
        tty.output = [];
      }
    },
    ioctl_tcgets(tty) {
      // typical setting
      return {
        c_iflag: 25856,
        c_oflag: 5,
        c_cflag: 191,
        c_lflag: 35387,
        c_cc: [ 3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]
      };
    },
    ioctl_tcsets(tty, optional_actions, data) {
      // currently just ignore
      return 0;
    },
    ioctl_tiocgwinsz(tty) {
      return [ 24, 80 ];
    }
  },
  default_tty1_ops: {
    put_char(tty, val) {
      if (val === null || val === 10) {
        err(UTF8ArrayToString(tty.output));
        tty.output = [];
      } else {
        if (val != 0) tty.output.push(val);
      }
    },
    fsync(tty) {
      if (tty.output?.length > 0) {
        err(UTF8ArrayToString(tty.output));
        tty.output = [];
      }
    }
  }
};

var mmapAlloc = size => {
  abort("internal error: mmapAlloc called but `emscripten_builtin_memalign` native symbol not exported");
};

var MEMFS = {
  ops_table: null,
  mount(mount) {
    return MEMFS.createNode(null, "/", 16895, 0);
  },
  createNode(parent, name, mode, dev) {
    if (FS.isBlkdev(mode) || FS.isFIFO(mode)) {
      // not supported
      throw new FS.ErrnoError(63);
    }
    MEMFS.ops_table ||= {
      dir: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr,
          lookup: MEMFS.node_ops.lookup,
          mknod: MEMFS.node_ops.mknod,
          rename: MEMFS.node_ops.rename,
          unlink: MEMFS.node_ops.unlink,
          rmdir: MEMFS.node_ops.rmdir,
          readdir: MEMFS.node_ops.readdir,
          symlink: MEMFS.node_ops.symlink
        },
        stream: {
          llseek: MEMFS.stream_ops.llseek
        }
      },
      file: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr
        },
        stream: {
          llseek: MEMFS.stream_ops.llseek,
          read: MEMFS.stream_ops.read,
          write: MEMFS.stream_ops.write,
          mmap: MEMFS.stream_ops.mmap,
          msync: MEMFS.stream_ops.msync
        }
      },
      link: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr,
          readlink: MEMFS.node_ops.readlink
        },
        stream: {}
      },
      chrdev: {
        node: {
          getattr: MEMFS.node_ops.getattr,
          setattr: MEMFS.node_ops.setattr
        },
        stream: FS.chrdev_stream_ops
      }
    };
    var node = FS.createNode(parent, name, mode, dev);
    if (FS.isDir(node.mode)) {
      node.node_ops = MEMFS.ops_table.dir.node;
      node.stream_ops = MEMFS.ops_table.dir.stream;
      node.contents = {};
    } else if (FS.isFile(node.mode)) {
      node.node_ops = MEMFS.ops_table.file.node;
      node.stream_ops = MEMFS.ops_table.file.stream;
      // The actual number of bytes used in the typed array, as opposed to
      // contents.length which gives the whole capacity.
      node.usedBytes = 0;
      // The byte data of the file is stored in a typed array.
      // Note: typed arrays are not resizable like normal JS arrays are, so
      // there is a small penalty involved for appending file writes that
      // continuously grow a file similar to std::vector capacity vs used.
      node.contents = MEMFS.emptyFileContents ??= new Uint8Array(0);
    } else if (FS.isLink(node.mode)) {
      node.node_ops = MEMFS.ops_table.link.node;
      node.stream_ops = MEMFS.ops_table.link.stream;
    } else if (FS.isChrdev(node.mode)) {
      node.node_ops = MEMFS.ops_table.chrdev.node;
      node.stream_ops = MEMFS.ops_table.chrdev.stream;
    }
    node.atime = node.mtime = node.ctime = Date.now();
    // add the new node to the parent
    if (parent) {
      parent.contents[name] = node;
      parent.atime = parent.mtime = parent.ctime = node.atime;
    }
    return node;
  },
  getFileDataAsTypedArray(node) {
    assert(FS.isFile(node.mode), "getFileDataAsTypedArray called on non-file");
    return node.contents.subarray(0, node.usedBytes);
  },
  expandFileStorage(node, newCapacity) {
    var prevCapacity = node.contents.length;
    if (prevCapacity >= newCapacity) return;
    // No need to expand, the storage was already large enough.
    // Don't expand strictly to the given requested limit if it's only a very
    // small increase, but instead geometrically grow capacity.
    // For small filesizes (<1MB), perform size*2 geometric increase, but for
    // large sizes, do a much more conservative size*1.125 increase to avoid
    // overshooting the allocation cap by a very large margin.
    var CAPACITY_DOUBLING_MAX = 1024 * 1024;
    newCapacity = Math.max(newCapacity, (prevCapacity * (prevCapacity < CAPACITY_DOUBLING_MAX ? 2 : 1.125)) >>> 0);
    if (prevCapacity) newCapacity = Math.max(newCapacity, 256);
    // At minimum allocate 256b for each file when expanding.
    var oldContents = MEMFS.getFileDataAsTypedArray(node);
    node.contents = new Uint8Array(newCapacity);
    // Allocate new storage.
    node.contents.set(oldContents);
  },
  resizeFileStorage(node, newSize) {
    if (node.usedBytes == newSize) return;
    var oldContents = node.contents;
    node.contents = new Uint8Array(newSize);
    // Allocate new storage.
    node.contents.set(oldContents.subarray(0, Math.min(newSize, node.usedBytes)));
    // Copy old data over to the new storage.
    node.usedBytes = newSize;
  },
  node_ops: {
    getattr(node) {
      var attr = {};
      // device numbers reuse inode numbers.
      attr.dev = FS.isChrdev(node.mode) ? node.id : 1;
      attr.ino = node.id;
      attr.mode = node.mode;
      attr.nlink = 1;
      attr.uid = 0;
      attr.gid = 0;
      attr.rdev = node.rdev;
      if (FS.isDir(node.mode)) {
        attr.size = 4096;
      } else if (FS.isFile(node.mode)) {
        attr.size = node.usedBytes;
      } else if (FS.isLink(node.mode)) {
        attr.size = node.link.length;
      } else {
        attr.size = 0;
      }
      attr.atime = new Date(node.atime);
      attr.mtime = new Date(node.mtime);
      attr.ctime = new Date(node.ctime);
      // NOTE: In our implementation, st_blocks = Math.ceil(st_size/st_blksize),
      //       but this is not required by the standard.
      attr.blksize = 4096;
      attr.blocks = Math.ceil(attr.size / attr.blksize);
      return attr;
    },
    setattr(node, attr) {
      for (const key of [ "mode", "atime", "mtime", "ctime" ]) {
        if (attr[key] != null) {
          node[key] = attr[key];
        }
      }
      if (attr.size !== undefined) {
        MEMFS.resizeFileStorage(node, attr.size);
      }
    },
    lookup(parent, name) {
      throw new FS.ErrnoError(44);
    },
    mknod(parent, name, mode, dev) {
      return MEMFS.createNode(parent, name, mode, dev);
    },
    rename(old_node, new_dir, new_name) {
      var new_node;
      try {
        new_node = FS.lookupNode(new_dir, new_name);
      } catch (e) {}
      if (new_node) {
        if (FS.isDir(old_node.mode)) {
          // if we're overwriting a directory at new_name, make sure it's empty.
          for (var i in new_node.contents) {
            throw new FS.ErrnoError(55);
          }
        }
        FS.hashRemoveNode(new_node);
      }
      // do the internal rewiring
      delete old_node.parent.contents[old_node.name];
      new_dir.contents[new_name] = old_node;
      old_node.name = new_name;
      new_dir.ctime = new_dir.mtime = old_node.parent.ctime = old_node.parent.mtime = Date.now();
    },
    unlink(parent, name) {
      delete parent.contents[name];
      parent.ctime = parent.mtime = Date.now();
    },
    rmdir(parent, name) {
      var node = FS.lookupNode(parent, name);
      for (var i in node.contents) {
        throw new FS.ErrnoError(55);
      }
      delete parent.contents[name];
      parent.ctime = parent.mtime = Date.now();
    },
    readdir(node) {
      return [ ".", "..", ...Object.keys(node.contents) ];
    },
    symlink(parent, newname, oldpath) {
      var node = MEMFS.createNode(parent, newname, 511 | 40960, 0);
      node.link = oldpath;
      return node;
    },
    readlink(node) {
      if (!FS.isLink(node.mode)) {
        throw new FS.ErrnoError(28);
      }
      return node.link;
    }
  },
  stream_ops: {
    read(stream, buffer, offset, length, position) {
      var contents = stream.node.contents;
      if (position >= stream.node.usedBytes) return 0;
      var size = Math.min(stream.node.usedBytes - position, length);
      assert(size >= 0);
      buffer.set(contents.subarray(position, position + size), offset);
      return size;
    },
    write(stream, buffer, offset, length, position, canOwn) {
      assert(buffer.subarray, "FS.write expects a TypedArray");
      // If the buffer is located in main memory (HEAP), and if
      // memory can grow, we can't hold on to references of the
      // memory buffer, as they may get invalidated. That means we
      // need to copy its contents.
      if (buffer.buffer === HEAP8.buffer) {
        canOwn = false;
      }
      if (!length) return 0;
      var node = stream.node;
      node.mtime = node.ctime = Date.now();
      if (canOwn) {
        assert(!position, "canOwn must imply no weird position inside the file");
        node.contents = buffer.subarray(offset, offset + length);
        node.usedBytes = length;
      } else if (!node.usedBytes && !position) {
        // If this is a simple first write to an empty file, do a fast set since we don't need to care about old data.
        node.contents = buffer.slice(offset, offset + length);
        node.usedBytes = length;
      } else {
        MEMFS.expandFileStorage(node, position + length);
        // Use typed array write which is available.
        node.contents.set(buffer.subarray(offset, offset + length), position);
        node.usedBytes = Math.max(node.usedBytes, position + length);
      }
      return length;
    },
    llseek(stream, offset, whence) {
      var position = offset;
      if (whence === 1) {
        position += stream.position;
      } else if (whence === 2) {
        if (FS.isFile(stream.node.mode)) {
          position += stream.node.usedBytes;
        }
      }
      if (position < 0) {
        throw new FS.ErrnoError(28);
      }
      return position;
    },
    mmap(stream, length, position, prot, flags) {
      if (!FS.isFile(stream.node.mode)) {
        throw new FS.ErrnoError(43);
      }
      var ptr;
      var allocated;
      var contents = stream.node.contents;
      // Only make a new copy when MAP_PRIVATE is specified.
      if (!(flags & 2) && contents.buffer === HEAP8.buffer) {
        // We can't emulate MAP_SHARED when the file is not backed by the
        // buffer we're mapping to (e.g. the HEAP buffer).
        allocated = false;
        ptr = contents.byteOffset;
      } else {
        allocated = true;
        ptr = mmapAlloc(length);
        if (!ptr) {
          throw new FS.ErrnoError(48);
        }
        if (contents) {
          // Try to avoid unnecessary slices.
          if (position > 0 || position + length < contents.length) {
            if (contents.subarray) {
              contents = contents.subarray(position, position + length);
            } else {
              contents = Array.prototype.slice.call(contents, position, position + length);
            }
          }
          HEAP8.set(contents, ptr >>> 0);
        }
      }
      return {
        ptr,
        allocated
      };
    },
    msync(stream, buffer, offset, length, mmapFlags) {
      MEMFS.stream_ops.write(stream, buffer, 0, length, offset, false);
      // should we check if bytesWritten and length are the same?
      return 0;
    }
  }
};

var FS_modeStringToFlags = str => {
  if (typeof str != "string") return str;
  var flagModes = {
    "r": 0,
    "r+": 2,
    "w": 512 | 64 | 1,
    "w+": 512 | 64 | 2,
    "a": 1024 | 64 | 1,
    "a+": 1024 | 64 | 2
  };
  var flags = flagModes[str];
  if (typeof flags == "undefined") {
    throw new Error(`Unknown file open mode: ${str}`);
  }
  return flags;
};

var FS_fileDataToTypedArray = data => {
  if (typeof data == "string") {
    data = intArrayFromString(data, true);
  }
  if (!data.subarray) {
    data = new Uint8Array(data);
  }
  return data;
};

var FS_getMode = (canRead, canWrite) => {
  var mode = 0;
  if (canRead) mode |= 292 | 73;
  if (canWrite) mode |= 146;
  return mode;
};

/** @type {!Uint8Array} */ var HEAPU8;

/**
   * Given a pointer 'ptr' to a null-terminated UTF8-encoded string in the
   * emscripten HEAP, returns a copy of that string as a Javascript String object.
   *
   * @param {number} ptr
   * @param {number=} maxBytesToRead - An optional length that specifies the
   *   maximum number of bytes to read. You can omit this parameter to scan the
   *   string until the first 0 byte. If maxBytesToRead is passed, and the string
   *   at [ptr, ptr+maxBytesToReadr[ contains a null byte in the middle, then the
   *   string will cut short at that byte index.
   * @param {boolean=} ignoreNul - If true, the function will not stop on a NUL character.
   * @return {string}
   */ var UTF8ToString = (ptr, maxBytesToRead, ignoreNul) => {
  assert(typeof ptr == "number", `UTF8ToString expects a number (got ${typeof ptr})`);
  ptr >>>= 0;
  return ptr ? UTF8ArrayToString(HEAPU8, ptr, maxBytesToRead, ignoreNul) : "";
};

var strError = errno => UTF8ToString(_strerror(errno));

var ERRNO_CODES = {
  "EPERM": 63,
  "ENOENT": 44,
  "ESRCH": 71,
  "EINTR": 27,
  "EIO": 29,
  "ENXIO": 60,
  "E2BIG": 1,
  "ENOEXEC": 45,
  "EBADF": 8,
  "ECHILD": 12,
  "EAGAIN": 6,
  "EWOULDBLOCK": 6,
  "ENOMEM": 48,
  "EACCES": 2,
  "EFAULT": 21,
  "ENOTBLK": 105,
  "EBUSY": 10,
  "EEXIST": 20,
  "EXDEV": 75,
  "ENODEV": 43,
  "ENOTDIR": 54,
  "EISDIR": 31,
  "EINVAL": 28,
  "ENFILE": 41,
  "EMFILE": 33,
  "ENOTTY": 59,
  "ETXTBSY": 74,
  "EFBIG": 22,
  "ENOSPC": 51,
  "ESPIPE": 70,
  "EROFS": 69,
  "EMLINK": 34,
  "EPIPE": 64,
  "EDOM": 18,
  "ERANGE": 68,
  "ENOMSG": 49,
  "EIDRM": 24,
  "ECHRNG": 106,
  "EL2NSYNC": 156,
  "EL3HLT": 107,
  "EL3RST": 108,
  "ELNRNG": 109,
  "EUNATCH": 110,
  "ENOCSI": 111,
  "EL2HLT": 112,
  "EDEADLK": 16,
  "ENOLCK": 46,
  "EBADE": 113,
  "EBADR": 114,
  "EXFULL": 115,
  "ENOANO": 104,
  "EBADRQC": 103,
  "EBADSLT": 102,
  "EDEADLOCK": 16,
  "EBFONT": 101,
  "ENOSTR": 100,
  "ENODATA": 116,
  "ETIME": 117,
  "ENOSR": 118,
  "ENONET": 119,
  "ENOPKG": 120,
  "EREMOTE": 121,
  "ENOLINK": 47,
  "EADV": 122,
  "ESRMNT": 123,
  "ECOMM": 124,
  "EPROTO": 65,
  "EMULTIHOP": 36,
  "EDOTDOT": 125,
  "EBADMSG": 9,
  "ENOTUNIQ": 126,
  "EBADFD": 127,
  "EREMCHG": 128,
  "ELIBACC": 129,
  "ELIBBAD": 130,
  "ELIBSCN": 131,
  "ELIBMAX": 132,
  "ELIBEXEC": 133,
  "ENOSYS": 52,
  "ENOTEMPTY": 55,
  "ENAMETOOLONG": 37,
  "ELOOP": 32,
  "EOPNOTSUPP": 138,
  "EPFNOSUPPORT": 139,
  "ECONNRESET": 15,
  "ENOBUFS": 42,
  "EAFNOSUPPORT": 5,
  "EPROTOTYPE": 67,
  "ENOTSOCK": 57,
  "ENOPROTOOPT": 50,
  "ESHUTDOWN": 140,
  "ECONNREFUSED": 14,
  "EADDRINUSE": 3,
  "ECONNABORTED": 13,
  "ENETUNREACH": 40,
  "ENETDOWN": 38,
  "ETIMEDOUT": 73,
  "EHOSTDOWN": 142,
  "EHOSTUNREACH": 23,
  "EINPROGRESS": 26,
  "EALREADY": 7,
  "EDESTADDRREQ": 17,
  "EMSGSIZE": 35,
  "EPROTONOSUPPORT": 66,
  "ESOCKTNOSUPPORT": 137,
  "EADDRNOTAVAIL": 4,
  "ENETRESET": 39,
  "EISCONN": 30,
  "ENOTCONN": 53,
  "ETOOMANYREFS": 141,
  "EUSERS": 136,
  "EDQUOT": 19,
  "ESTALE": 72,
  "ENOTSUP": 138,
  "ENOMEDIUM": 148,
  "EILSEQ": 25,
  "EOVERFLOW": 61,
  "ECANCELED": 11,
  "ENOTRECOVERABLE": 56,
  "EOWNERDEAD": 62,
  "ESTRPIPE": 135
};

var asyncLoad = async url => {
  var arrayBuffer = await readAsync(url);
  assert(arrayBuffer, `Loading data file "${url}" failed (no arrayBuffer).`);
  return new Uint8Array(arrayBuffer);
};

var FS_createDataFile = (...args) => FS.createDataFile(...args);

var getUniqueRunDependency = id => {
  var orig = id;
  while (1) {
    if (!runDependencyTracking[id]) return id;
    id = orig + Math.random();
  }
};

var dependenciesPromise = null;

var resolveRunDependencies = async () => dependenciesPromise;

var runDependencies = 0;

var dependenciesPromiseResolve = null;

var runDependencyTracking = {};

var runDependencyWatcher = null;

var removeRunDependency = id => {
  runDependencies--;
  assert(id, "removeRunDependency requires an ID");
  assert(runDependencyTracking[id]);
  delete runDependencyTracking[id];
  if (!runDependencies) {
    if (runDependencyWatcher !== null) {
      clearInterval(runDependencyWatcher);
      runDependencyWatcher = null;
    }
    dependenciesPromiseResolve();
  }
};

var addRunDependency = id => {
  if (!runDependencies) {
    dependenciesPromise = new Promise(resolve => dependenciesPromiseResolve = resolve);
  }
  runDependencies++;
  assert(id, "addRunDependency requires an ID");
  assert(!runDependencyTracking[id]);
  runDependencyTracking[id] = 1;
  if (!runDependencyWatcher && globalThis.setInterval) {
    // Check for missing dependencies every few seconds
    runDependencyWatcher = setInterval(() => {
      if (ABORT) {
        clearInterval(runDependencyWatcher);
        runDependencyWatcher = null;
        return;
      }
      var shown = false;
      for (var dep in runDependencyTracking) {
        if (!shown) {
          shown = true;
          err("still waiting on run dependencies:");
        }
        err(`dependency: ${dep}`);
      }
      if (shown) {
        err("(end of list)");
      }
    }, 1e4);
    // Prevent this timer from keeping the runtime alive if nothing
    // else is.
    runDependencyWatcher.unref?.();
  }
};

var preloadPlugins = [];

var FS_handledByPreloadPlugin = async (byteArray, fullname) => {
  // Ensure plugins are ready.
  if (typeof Browser != "undefined") Browser.init();
  for (var plugin of preloadPlugins) {
    if (plugin["canHandle"](fullname)) {
      assert(plugin["handle"].constructor.name === "AsyncFunction", "Filesystem plugin handlers must be async functions (See #24914)");
      return plugin["handle"](byteArray, fullname);
    }
  }
  // If no plugin handled this file then return the original/unmodified
  // byteArray.
  return byteArray;
};

var FS_preloadFile = async (parent, name, url, canRead, canWrite, dontCreateFile, canOwn, preFinish) => {
  // TODO we should allow people to just pass in a complete filename instead
  // of parent and name being that we just join them anyways
  var fullname = name ? PATH_FS.resolve(PATH.join2(parent, name)) : parent;
  var dep = getUniqueRunDependency(`cp ${fullname}`);
  // might have several active requests for the same fullname
  addRunDependency(dep);
  try {
    var byteArray = url;
    if (typeof url == "string") {
      byteArray = await asyncLoad(url);
    }
    byteArray = await FS_handledByPreloadPlugin(byteArray, fullname);
    preFinish?.();
    if (!dontCreateFile) {
      FS_createDataFile(parent, name, byteArray, canRead, canWrite, canOwn);
    }
  } finally {
    removeRunDependency(dep);
  }
};

var FS_createPreloadedFile = (parent, name, url, canRead, canWrite, onload, onerror, dontCreateFile, canOwn, preFinish) => {
  FS_preloadFile(parent, name, url, canRead, canWrite, dontCreateFile, canOwn, preFinish).then(onload).catch(onerror);
};

var FS = {
  root: null,
  mounts: [],
  devices: {},
  streams: [],
  nextInode: 1,
  nameTable: null,
  currentPath: "/",
  initialized: false,
  ignorePermissions: true,
  filesystems: null,
  syncFSRequests: 0,
  ErrnoError: class extends Error {
    name="ErrnoError";
    // We set the `name` property to be able to identify `FS.ErrnoError`
    // - the `name` is a standard ECMA-262 property of error objects. Kind of good to have it anyway.
    // - when using PROXYFS, an error can come from an underlying FS
    // as different FS objects have their own FS.ErrnoError each,
    // the test `err instanceof FS.ErrnoError` won't detect an error coming from another filesystem, causing bugs.
    // we'll use the reliable test `err.name == "ErrnoError"` instead
    constructor(errno) {
      super(runtimeInitialized ? strError(errno) : "");
      this.errno = errno;
      for (var key in ERRNO_CODES) {
        if (ERRNO_CODES[key] === errno) {
          this.code = key;
          break;
        }
      }
    }
  },
  FSStream: class {
    shared={};
    get object() {
      return this.node;
    }
    set object(val) {
      this.node = val;
    }
    get isRead() {
      return (this.flags & 2097155) !== 1;
    }
    get isWrite() {
      return (this.flags & 2097155) !== 0;
    }
    get isAppend() {
      return (this.flags & 1024);
    }
    get flags() {
      return this.shared.flags;
    }
    set flags(val) {
      this.shared.flags = val;
    }
    get position() {
      return this.shared.position;
    }
    set position(val) {
      this.shared.position = val;
    }
  },
  FSNode: class {
    node_ops={};
    stream_ops={};
    readMode=292 | 73;
    writeMode=146;
    mounted=null;
    constructor(parent, name, mode, rdev) {
      if (!parent) {
        parent = this;
      }
      this.parent = parent;
      this.mount = parent.mount;
      this.id = FS.nextInode++;
      this.name = name;
      this.mode = mode;
      this.rdev = rdev;
      this.atime = this.mtime = this.ctime = Date.now();
    }
    get read() {
      return (this.mode & this.readMode) === this.readMode;
    }
    set read(val) {
      val ? this.mode |= this.readMode : this.mode &= ~this.readMode;
    }
    get write() {
      return (this.mode & this.writeMode) === this.writeMode;
    }
    set write(val) {
      val ? this.mode |= this.writeMode : this.mode &= ~this.writeMode;
    }
    get isFolder() {
      return FS.isDir(this.mode);
    }
    get isDevice() {
      return FS.isChrdev(this.mode);
    }
    // The per-inode readiness wait-queue. The node carries a Set of listener
    // entries {cb}; producers (SOCKFS, PIPEFS) call notifyListeners on a
    // readiness transition, and poll()/epoll consume it. It lives on the node
    // (not the fd) so dup'd fds share one queue. Only nodes that derive real
    // readiness (sockets, pipes, and an epoll's own node) ever use this -
    // always-ready types (regular files, ttys) never register or notify.
    addListener(cb, exclusive = false) {
      var entry = {
        cb,
        exclusive
      };
      var listeners = (this.listeners ??= new Set);
      listeners.add(entry);
      return {
        listeners,
        entry
      };
    }
    notifyListeners(flags) {
      // Iterates the set without copying, which is safe ONLY under a
      // load-bearing contract that every internal listener must honour:
      //   1. A listener must not run user code synchronously (a poll waiter only
      //      resolves a Promise; an epoll registration only re-lists +
      //      re-notifies; the epoll callback only schedules a tick). User code
      //      runs on a later tick, never inside this loop.
      //   2. A listener may delete entries only from ITS OWN waiter, never from
      //      a sibling node's set that may be mid-iteration. (Deleting an entry
      //      of the set being iterated here is fine - a Set tolerates removal of
      //      a not-yet-visited entry mid-iteration; mutating a *different* node's
      //      set is fine because that set is not being iterated.)
      // Violating either gives silently skipped wakeups that are near-impossible
      // to reproduce. Any new producer/listener must preserve it.
      if (!this.listeners) return;
      // Fire every non-exclusive listener. Among EPOLLEXCLUSIVE registrations
      // (one fd watched by several epolls) wake only one, rotating round-robin
      // per node, to avoid a thundering herd. (Only epoll registrations are ever
      // exclusive; poll waiters and a node's own consumers are not.)
      var excl;
      for (var entry of this.listeners) {
        if (entry.exclusive) (excl ||= []).push(entry); else entry.cb(flags);
      }
      if (excl) {
        var i = (this.exclTurn || 0) % excl.length;
        this.exclTurn = i + 1;
        excl[i].cb(flags);
      }
    }
  },
  lookupPath(path, opts = {}) {
    if (!path) {
      throw new FS.ErrnoError(44);
    }
    opts.follow_mount ??= true;
    if (!PATH.isAbs(path)) {
      path = FS.cwd() + "/" + path;
    }
    // limit max consecutive symlinks to SYMLOOP_MAX.
    linkloop: for (var nlinks = 0; nlinks < 40; nlinks++) {
      // split the absolute path
      var parts = path.split("/").filter(p => !!p);
      // start at the root
      var current = FS.root;
      var current_path = "/";
      for (var i = 0; i < parts.length; i++) {
        var islast = (i === parts.length - 1);
        if (islast && opts.parent) {
          // stop resolving
          break;
        }
        if (parts[i] === ".") {
          continue;
        }
        if (parts[i] === "..") {
          current_path = PATH.dirname(current_path);
          if (FS.isRoot(current)) {
            path = current_path + "/" + parts.slice(i + 1).join("/");
            // We're making progress here, don't let many consecutive ..'s
            // lead to ELOOP
            nlinks--;
            continue linkloop;
          } else {
            current = current.parent;
          }
          continue;
        }
        current_path = PATH.join2(current_path, parts[i]);
        try {
          current = FS.lookupNode(current, parts[i]);
        } catch (e) {
          // if noent_okay is true, suppress a ENOENT in the last component
          // and return an object with an undefined node. This is needed for
          // resolving symlinks in the path when creating a file.
          if ((e?.errno === 44) && islast && opts.noent_okay) {
            return {
              path: current_path
            };
          }
          throw e;
        }
        // jump to the mount's root node if this is a mountpoint
        if (FS.isMountpoint(current) && (!islast || opts.follow_mount)) {
          current = current.mounted.root;
        }
        // by default, lookupPath will not follow a symlink if it is the final path component.
        // setting opts.follow = true will override this behavior.
        if (FS.isLink(current.mode) && (!islast || opts.follow)) {
          if (!current.node_ops.readlink) {
            throw new FS.ErrnoError(52);
          }
          var link = current.node_ops.readlink(current);
          if (!PATH.isAbs(link)) {
            link = PATH.dirname(current_path) + "/" + link;
          }
          path = link + "/" + parts.slice(i + 1).join("/");
          continue linkloop;
        }
      }
      return {
        path: current_path,
        node: current
      };
    }
    throw new FS.ErrnoError(32);
  },
  getPath(node) {
    var path;
    while (true) {
      if (FS.isRoot(node)) {
        var mount = node.mount.mountpoint;
        if (!path) return mount;
        return mount[mount.length - 1] !== "/" ? `${mount}/${path}` : mount + path;
      }
      path = path ? `${node.name}/${path}` : node.name;
      node = node.parent;
    }
  },
  hashName(parentid, name) {
    var hash = 0;
    for (var i = 0; i < name.length; i++) {
      hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0;
    }
    return ((parentid + hash) >>> 0) % FS.nameTable.length;
  },
  hashAddNode(node) {
    var hash = FS.hashName(node.parent.id, node.name);
    node.name_next = FS.nameTable[hash];
    FS.nameTable[hash] = node;
  },
  hashRemoveNode(node) {
    var hash = FS.hashName(node.parent.id, node.name);
    if (FS.nameTable[hash] === node) {
      FS.nameTable[hash] = node.name_next;
    } else {
      var current = FS.nameTable[hash];
      while (current) {
        if (current.name_next === node) {
          current.name_next = node.name_next;
          break;
        }
        current = current.name_next;
      }
    }
  },
  lookupNode(parent, name) {
    var errCode = FS.mayLookup(parent);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    var hash = FS.hashName(parent.id, name);
    for (var node = FS.nameTable[hash]; node; node = node.name_next) {
      var nodeName = node.name;
      if (node.parent.id === parent.id && nodeName === name) {
        return node;
      }
    }
    // if we failed to find it in the cache, call into the VFS
    return FS.lookup(parent, name);
  },
  createNode(parent, name, mode, rdev) {
    assert(typeof parent == "object");
    var node = new FS.FSNode(parent, name, mode, rdev);
    FS.hashAddNode(node);
    return node;
  },
  destroyNode(node) {
    FS.hashRemoveNode(node);
  },
  isRoot(node) {
    return node === node.parent;
  },
  isMountpoint(node) {
    return !!node.mounted;
  },
  isFile(mode) {
    return (mode & 61440) === 32768;
  },
  isDir(mode) {
    return (mode & 61440) === 16384;
  },
  isLink(mode) {
    return (mode & 61440) === 40960;
  },
  isChrdev(mode) {
    return (mode & 61440) === 8192;
  },
  isBlkdev(mode) {
    return (mode & 61440) === 24576;
  },
  isFIFO(mode) {
    return (mode & 61440) === 4096;
  },
  isSocket(mode) {
    return (mode & 49152) === 49152;
  },
  flagsToPermissionString(flag) {
    var perms = [ "r", "w", "rw" ][flag & 3];
    if ((flag & 512)) {
      perms += "w";
    }
    return perms;
  },
  nodePermissions(node, perms) {
    if (FS.ignorePermissions) {
      return 0;
    }
    // return 0 if any user, group or owner bits are set.
    if (perms.includes("r") && !(node.mode & 292)) {
      return 2;
    }
    if (perms.includes("w") && !(node.mode & 146)) {
      return 2;
    }
    if (perms.includes("x") && !(node.mode & 73)) {
      return 2;
    }
    return 0;
  },
  mayLookup(dir) {
    if (!FS.isDir(dir.mode)) return 54;
    var errCode = FS.nodePermissions(dir, "x");
    if (errCode) return errCode;
    if (!dir.node_ops.lookup) return 2;
    return 0;
  },
  mayCreate(dir, name) {
    if (!FS.isDir(dir.mode)) {
      return 54;
    }
    try {
      var node = FS.lookupNode(dir, name);
      return 20;
    } catch (e) {}
    return FS.nodePermissions(dir, "wx");
  },
  mayDelete(dir, name, isdir) {
    var node;
    try {
      node = FS.lookupNode(dir, name);
    } catch (e) {
      return e.errno;
    }
    var errCode = FS.nodePermissions(dir, "wx");
    if (errCode) {
      return errCode;
    }
    if (isdir) {
      if (!FS.isDir(node.mode)) {
        return 54;
      }
      if (FS.isRoot(node) || FS.getPath(node) === FS.cwd()) {
        return 10;
      }
    } else if (FS.isDir(node.mode)) {
      return 31;
    }
    return 0;
  },
  mayOpen(node, flags) {
    if (!node) {
      return 44;
    }
    if (FS.isLink(node.mode)) {
      return 32;
    }
    var mode = FS.flagsToPermissionString(flags);
    if (FS.isDir(node.mode)) {
      // opening for write
      // TODO: check for O_SEARCH? (== search for dir only)
      if (mode !== "r" || (flags & (512 | 64))) {
        return 31;
      }
    }
    return FS.nodePermissions(node, mode);
  },
  checkOpExists(op, err) {
    if (!op) {
      throw new FS.ErrnoError(err);
    }
    return op;
  },
  MAX_OPEN_FDS: 4096,
  nextfd() {
    for (var fd = 0; fd <= FS.MAX_OPEN_FDS; fd++) {
      if (!FS.streams[fd]) {
        return fd;
      }
    }
    throw new FS.ErrnoError(33);
  },
  getStreamChecked(fd) {
    var stream = FS.getStream(fd);
    if (!stream) {
      throw new FS.ErrnoError(8);
    }
    return stream;
  },
  getStream: fd => FS.streams[fd],
  createStream(stream, fd = -1) {
    assert(fd >= -1);
    // clone it, so we can return an instance of FSStream
    stream = Object.assign(new FS.FSStream, stream);
    if (fd == -1) {
      fd = FS.nextfd();
    }
    stream.fd = fd;
    FS.streams[fd] = stream;
    return stream;
  },
  closeStream(fd) {
    FS.streams[fd] = null;
  },
  dupStream(origStream, fd = -1) {
    var stream = FS.createStream(origStream, fd);
    stream.stream_ops?.dup?.(stream);
    return stream;
  },
  doSetAttr(stream, node, attr) {
    var setattr = stream?.stream_ops.setattr;
    var arg = setattr ? stream : node;
    setattr ??= node.node_ops.setattr;
    FS.checkOpExists(setattr, 63);
    try {
      setattr(arg, attr);
    } catch (e) {
      if (e instanceof RangeError) {
        throw new FS.ErrnoError(22);
      }
      throw e;
    }
  },
  chrdev_stream_ops: {
    open(stream) {
      var device = FS.getDevice(stream.node.rdev);
      // override node's stream ops with the device's
      stream.stream_ops = device.stream_ops;
      // forward the open call
      stream.stream_ops.open?.(stream);
    },
    llseek() {
      throw new FS.ErrnoError(70);
    }
  },
  major: dev => ((dev) >> 8),
  minor: dev => ((dev) & 255),
  makedev: (ma, mi) => ((ma) << 8 | (mi)),
  registerDevice(dev, ops) {
    FS.devices[dev] = {
      stream_ops: ops
    };
  },
  getDevice: dev => FS.devices[dev],
  getMounts(mount) {
    var mounts = [];
    var check = [ mount ];
    while (check.length) {
      var m = check.pop();
      mounts.push(m);
      check.push(...m.mounts);
    }
    return mounts;
  },
  syncfs(populate, callback) {
    if (typeof populate == "function") {
      callback = populate;
      populate = false;
    }
    FS.syncFSRequests++;
    if (FS.syncFSRequests > 1) {
      err(`warning: ${FS.syncFSRequests} FS.syncfs operations in flight at once, probably just doing extra work`);
    }
    var mounts = FS.getMounts(FS.root.mount);
    var completed = 0;
    function doCallback(errCode) {
      assert(FS.syncFSRequests > 0);
      FS.syncFSRequests--;
      return callback(errCode);
    }
    function done(errCode) {
      if (errCode) {
        if (!done.errored) {
          done.errored = true;
          return doCallback(errCode);
        }
        return;
      }
      if (++completed >= mounts.length) {
        doCallback(null);
      }
    }
    // sync all mounts
    for (var mount of mounts) {
      if (mount.type.syncfs) {
        mount.type.syncfs(mount, populate, done);
      } else {
        done(null);
      }
    }
  },
  mount(type, opts, mountpoint) {
    if (typeof type == "string") {
      // The filesystem was not included, and instead we have an error
      // message stored in the variable.
      throw type;
    }
    var root = mountpoint === "/";
    var pseudo = !mountpoint;
    var node;
    if (root && FS.root) {
      throw new FS.ErrnoError(10);
    } else if (!root && !pseudo) {
      var lookup = FS.lookupPath(mountpoint, {
        follow_mount: false
      });
      mountpoint = lookup.path;
      // use the absolute path
      node = lookup.node;
      if (FS.isMountpoint(node)) {
        throw new FS.ErrnoError(10);
      }
      if (!FS.isDir(node.mode)) {
        throw new FS.ErrnoError(54);
      }
    }
    var mount = {
      type,
      opts,
      mountpoint,
      mounts: []
    };
    // create a root node for the fs
    var mountRoot = type.mount(mount);
    mountRoot.mount = mount;
    mount.root = mountRoot;
    if (root) {
      FS.root = mountRoot;
    } else if (node) {
      // set as a mountpoint
      node.mounted = mount;
      // add the new mount to the current mount's children
      if (node.mount) {
        node.mount.mounts.push(mount);
      }
    }
    return mountRoot;
  },
  unmount(mountpoint) {
    var lookup = FS.lookupPath(mountpoint, {
      follow_mount: false
    });
    if (!FS.isMountpoint(lookup.node)) {
      throw new FS.ErrnoError(28);
    }
    // destroy the nodes for this mount, and all its child mounts
    var node = lookup.node;
    var mount = node.mounted;
    var mounts = FS.getMounts(mount);
    for (var [hash, current] of Object.entries(FS.nameTable)) {
      while (current) {
        var next = current.name_next;
        if (mounts.includes(current.mount)) {
          FS.destroyNode(current);
        }
        current = next;
      }
    }
    // no longer a mountpoint
    node.mounted = null;
    // remove this mount from the child mounts
    var idx = node.mount.mounts.indexOf(mount);
    assert(idx !== -1);
    node.mount.mounts.splice(idx, 1);
  },
  lookup(parent, name) {
    return parent.node_ops.lookup(parent, name);
  },
  mknod(path, mode, dev) {
    var lookup = FS.lookupPath(path, {
      parent: true
    });
    var parent = lookup.node;
    var name = PATH.basename(path);
    if (!name) {
      throw new FS.ErrnoError(28);
    }
    if (name === "." || name === "..") {
      throw new FS.ErrnoError(20);
    }
    var errCode = FS.mayCreate(parent, name);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.mknod) {
      throw new FS.ErrnoError(63);
    }
    return parent.node_ops.mknod(parent, name, mode, dev);
  },
  statfs(path) {
    return FS.statfsNode(FS.lookupPath(path, {
      follow: true
    }).node);
  },
  statfsStream(stream) {
    // We keep a separate statfsStream function because noderawfs overrides
    // it. In noderawfs, stream.node is sometimes null. Instead, we need to
    // look at stream.path.
    return FS.statfsNode(stream.node);
  },
  statfsNode(node) {
    // NOTE: None of the defaults here are true. We're just returning safe and
    //       sane values. Currently nodefs and rawfs replace these defaults,
    //       other file systems leave them alone.
    var rtn = {
      bsize: 4096,
      frsize: 4096,
      blocks: 1e6,
      bfree: 5e5,
      bavail: 5e5,
      files: FS.nextInode,
      ffree: FS.nextInode - 1,
      fsid: 42,
      flags: 2,
      namelen: 255
    };
    if (node.node_ops.statfs) {
      Object.assign(rtn, node.node_ops.statfs(node.mount.opts.root));
    }
    return rtn;
  },
  create(path, mode = 438) {
    mode &= 4095;
    mode |= 32768;
    return FS.mknod(path, mode, 0);
  },
  mkdir(path, mode = 511) {
    mode &= 511 | 512;
    mode |= 16384;
    return FS.mknod(path, mode, 0);
  },
  mkdirTree(path, mode) {
    var dirs = path.split("/");
    var d = "";
    for (var dir of dirs) {
      if (!dir) continue;
      if (d || PATH.isAbs(path)) d += "/";
      d += dir;
      try {
        FS.mkdir(d, mode);
      } catch (e) {
        if (e.errno != 20) throw e;
      }
    }
  },
  mkdev(path, mode, dev) {
    if (typeof dev == "undefined") {
      dev = mode;
      mode = 438;
    }
    mode |= 8192;
    return FS.mknod(path, mode, dev);
  },
  symlink(oldpath, newpath) {
    if (!PATH_FS.resolve(oldpath)) {
      throw new FS.ErrnoError(44);
    }
    var lookup = FS.lookupPath(newpath, {
      parent: true
    });
    var parent = lookup.node;
    if (!parent) {
      throw new FS.ErrnoError(44);
    }
    var newname = PATH.basename(newpath);
    var errCode = FS.mayCreate(parent, newname);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.symlink) {
      throw new FS.ErrnoError(63);
    }
    return parent.node_ops.symlink(parent, newname, oldpath);
  },
  link(oldpath, newpath, flags) {
    var lookup = FS.lookupPath(newpath, {
      parent: true
    });
    var parent = lookup.node;
    if (!parent) {
      throw new FS.ErrnoError(44);
    }
    var newname = PATH.basename(newpath);
    var errCode = FS.mayCreate(parent, newname);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    // Hardlinks are only supported by filesystem backends that provide a
    // `link` node op (e.g. NODERAWFS backed by the host). NODEFS omits it:
    // a host hardlink cannot be confined to the mount root.
    if (!parent.node_ops.link) {
      throw new FS.ErrnoError(34);
    }
    return parent.node_ops.link(parent, newname, oldpath, flags);
  },
  rename(old_path, new_path) {
    var old_dirname = PATH.dirname(old_path);
    var new_dirname = PATH.dirname(new_path);
    var old_name = PATH.basename(old_path);
    var new_name = PATH.basename(new_path);
    // parents must exist
    var lookup, old_dir, new_dir;
    // let the errors from non existent directories percolate up
    lookup = FS.lookupPath(old_path, {
      parent: true
    });
    old_dir = lookup.node;
    lookup = FS.lookupPath(new_path, {
      parent: true
    });
    new_dir = lookup.node;
    if (!old_dir || !new_dir) throw new FS.ErrnoError(44);
    // need to be part of the same mount
    if (old_dir.mount !== new_dir.mount) {
      throw new FS.ErrnoError(75);
    }
    // source must exist
    var old_node = FS.lookupNode(old_dir, old_name);
    // old path should not be an ancestor of the new path
    var relative = PATH_FS.relative(old_path, new_dirname);
    if (relative.charAt(0) !== ".") {
      throw new FS.ErrnoError(28);
    }
    // new path should not be an ancestor of the old path
    relative = PATH_FS.relative(new_path, old_dirname);
    if (relative.charAt(0) !== ".") {
      throw new FS.ErrnoError(55);
    }
    // see if the new path already exists
    var new_node;
    try {
      new_node = FS.lookupNode(new_dir, new_name);
    } catch (e) {}
    // early out if nothing needs to change
    if (old_node === new_node) {
      return;
    }
    // we'll need to delete the old entry
    var isdir = FS.isDir(old_node.mode);
    var errCode = FS.mayDelete(old_dir, old_name, isdir);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    // need delete permissions if we'll be overwriting.
    // need create permissions if new doesn't already exist.
    errCode = new_node ? FS.mayDelete(new_dir, new_name, isdir) : FS.mayCreate(new_dir, new_name);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!old_dir.node_ops.rename) {
      throw new FS.ErrnoError(63);
    }
    if (FS.isMountpoint(old_node) || (new_node && FS.isMountpoint(new_node))) {
      throw new FS.ErrnoError(10);
    }
    // if we are going to change the parent, check write permissions
    if (new_dir !== old_dir) {
      errCode = FS.nodePermissions(old_dir, "w");
      if (errCode) {
        throw new FS.ErrnoError(errCode);
      }
    }
    // remove the node from the lookup hash
    FS.hashRemoveNode(old_node);
    // do the underlying fs rename
    try {
      old_dir.node_ops.rename(old_node, new_dir, new_name);
      // update old node (we do this here to avoid each backend
      // needing to)
      old_node.parent = new_dir;
    } catch (e) {
      throw e;
    } finally {
      // add the node back to the hash (in case node_ops.rename
      // changed its name)
      FS.hashAddNode(old_node);
    }
  },
  rmdir(path) {
    var lookup = FS.lookupPath(path, {
      parent: true
    });
    var parent = lookup.node;
    var name = PATH.basename(path);
    var node = FS.lookupNode(parent, name);
    var errCode = FS.mayDelete(parent, name, true);
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.rmdir) {
      throw new FS.ErrnoError(63);
    }
    if (FS.isMountpoint(node)) {
      throw new FS.ErrnoError(10);
    }
    parent.node_ops.rmdir(parent, name);
    FS.destroyNode(node);
  },
  readdir(path) {
    var lookup = FS.lookupPath(path, {
      follow: true
    });
    var node = lookup.node;
    var readdir = FS.checkOpExists(node.node_ops.readdir, 54);
    return readdir(node);
  },
  unlink(path) {
    var lookup = FS.lookupPath(path, {
      parent: true
    });
    var parent = lookup.node;
    if (!parent) {
      throw new FS.ErrnoError(44);
    }
    var name = PATH.basename(path);
    var node = FS.lookupNode(parent, name);
    var errCode = FS.mayDelete(parent, name, false);
    if (errCode) {
      // According to POSIX, we should map EISDIR to EPERM, but
      // we instead do what Linux does (and we must, as we use
      // the musl linux libc).
      throw new FS.ErrnoError(errCode);
    }
    if (!parent.node_ops.unlink) {
      throw new FS.ErrnoError(63);
    }
    if (FS.isMountpoint(node)) {
      throw new FS.ErrnoError(10);
    }
    parent.node_ops.unlink(parent, name);
    FS.destroyNode(node);
  },
  readlink(path) {
    var lookup = FS.lookupPath(path);
    var link = lookup.node;
    if (!link) {
      throw new FS.ErrnoError(44);
    }
    if (!link.node_ops.readlink) {
      throw new FS.ErrnoError(28);
    }
    return link.node_ops.readlink(link);
  },
  stat(path, dontFollow) {
    var lookup = FS.lookupPath(path, {
      follow: !dontFollow
    });
    var node = lookup.node;
    var getattr = FS.checkOpExists(node.node_ops.getattr, 63);
    return getattr(node);
  },
  fstat(fd) {
    var stream = FS.getStreamChecked(fd);
    var node = stream.node;
    var getattr = stream.stream_ops.getattr;
    var arg = getattr ? stream : node;
    getattr ??= node.node_ops.getattr;
    FS.checkOpExists(getattr, 63);
    return getattr(arg);
  },
  lstat(path) {
    return FS.stat(path, true);
  },
  doChmod(stream, node, mode, dontFollow) {
    FS.doSetAttr(stream, node, {
      mode: (mode & 4095) | (node.mode & ~4095),
      ctime: Date.now(),
      dontFollow
    });
  },
  chmod(path, mode, dontFollow) {
    var node;
    if (typeof path == "string") {
      var lookup = FS.lookupPath(path, {
        follow: !dontFollow
      });
      node = lookup.node;
    } else {
      node = path;
    }
    FS.doChmod(null, node, mode, dontFollow);
  },
  lchmod(path, mode) {
    FS.chmod(path, mode, true);
  },
  fchmod(fd, mode) {
    var stream = FS.getStreamChecked(fd);
    FS.doChmod(stream, stream.node, mode, false);
  },
  doChown(stream, node, dontFollow) {
    FS.doSetAttr(stream, node, {
      timestamp: Date.now(),
      dontFollow
    });
  },
  chown(path, uid, gid, dontFollow) {
    var node;
    if (typeof path == "string") {
      var lookup = FS.lookupPath(path, {
        follow: !dontFollow
      });
      node = lookup.node;
    } else {
      node = path;
    }
    FS.doChown(null, node, dontFollow);
  },
  lchown(path, uid, gid) {
    FS.chown(path, uid, gid, true);
  },
  fchown(fd, uid, gid) {
    var stream = FS.getStreamChecked(fd);
    FS.doChown(stream, stream.node, false);
  },
  doTruncate(stream, node, len) {
    if (FS.isDir(node.mode)) {
      throw new FS.ErrnoError(31);
    }
    if (!FS.isFile(node.mode)) {
      throw new FS.ErrnoError(28);
    }
    var errCode = FS.nodePermissions(node, "w");
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    FS.doSetAttr(stream, node, {
      size: len,
      timestamp: Date.now()
    });
  },
  truncate(path, len) {
    if (len < 0) {
      throw new FS.ErrnoError(28);
    }
    var node;
    if (typeof path == "string") {
      var lookup = FS.lookupPath(path, {
        follow: true
      });
      node = lookup.node;
    } else {
      node = path;
    }
    FS.doTruncate(null, node, len);
  },
  ftruncate(fd, len) {
    var stream = FS.getStreamChecked(fd);
    if (len < 0 || (stream.flags & 2097155) === 0) {
      throw new FS.ErrnoError(28);
    }
    FS.doTruncate(stream, stream.node, len);
  },
  utime(path, atime, mtime, dontFollow) {
    var lookup = FS.lookupPath(path, {
      follow: !dontFollow
    });
    FS.doSetAttr(null, lookup.node, {
      atime,
      mtime,
      dontFollow
    });
  },
  open(path, flags, mode = 438) {
    if (path === "") {
      throw new FS.ErrnoError(44);
    }
    flags = FS_modeStringToFlags(flags);
    if ((flags & 64)) {
      mode = (mode & 4095) | 32768;
    } else {
      mode = 0;
    }
    var node;
    var isDirPath;
    if (typeof path == "object") {
      node = path;
    } else {
      isDirPath = path.endsWith("/");
      // noent_okay makes it so that if the final component of the path
      // doesn't exist, lookupPath returns `node: undefined`. `path` will be
      // updated to point to the target of all symlinks.
      var lookup = FS.lookupPath(path, {
        follow: !(flags & 131072),
        noent_okay: true
      });
      node = lookup.node;
      path = lookup.path;
    }
    // perhaps we need to create the node
    var created = false;
    if ((flags & 64)) {
      if (node) {
        // if O_CREAT and O_EXCL are set, error out if the node already exists
        if ((flags & 128)) {
          throw new FS.ErrnoError(20);
        }
      } else if (isDirPath) {
        throw new FS.ErrnoError(31);
      } else {
        // node doesn't exist, try to create it
        // Ignore the permission bits here to ensure we can `open` this new
        // file below. We use chmod below to apply the permissions once the
        // file is open.
        node = FS.mknod(path, mode | 511, 0);
        created = true;
      }
    }
    if (!node) {
      throw new FS.ErrnoError(44);
    }
    // can't truncate a device
    if (FS.isChrdev(node.mode)) {
      flags &= ~512;
    }
    // if asked only for a directory, then this must be one
    if ((flags & 65536) && !FS.isDir(node.mode)) {
      throw new FS.ErrnoError(54);
    }
    // check permissions, if this is not a file we just created now (it is ok to
    // create and write to a file with read-only permissions; it is read-only
    // for later use)
    if (!created) {
      var errCode = FS.mayOpen(node, flags);
      if (errCode) {
        throw new FS.ErrnoError(errCode);
      }
    }
    // do truncation if necessary
    if ((flags & 512) && !created) {
      FS.truncate(node, 0);
    }
    // we've already handled these, don't pass down to the underlying vfs
    flags &= ~(128 | 512 | 131072);
    // register the stream with the filesystem
    var stream = FS.createStream({
      node,
      path: FS.getPath(node),
      // we want the absolute path to the node
      flags,
      seekable: true,
      position: 0,
      stream_ops: node.stream_ops,
      // used by the file family libc calls (fopen, fwrite, ferror, etc.)
      ungotten: [],
      error: false
    });
    // call the new stream's open function
    if (stream.stream_ops.open) {
      stream.stream_ops.open(stream);
    }
    if (created) {
      FS.chmod(node, mode & 511);
    }
    return stream;
  },
  close(stream) {
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if (stream.getdents) stream.getdents = null;
    // free readdir state
    // The fd is going away: wake anything waiting on it (poll/epoll) with
    // POLLNVAL so a blocking wait unblocks and an epoll registration is evicted
    // on its next derive. Only sockets/pipes/epoll ever carry a wait-queue, so
    // for every other stream (incl. nodeless noderawfs stdio) this is a no-op.
    stream.node?.notifyListeners(32);
    try {
      if (stream.stream_ops.close) {
        stream.stream_ops.close(stream);
      }
    } catch (e) {
      throw e;
    } finally {
      FS.closeStream(stream.fd);
    }
    stream.fd = null;
  },
  isClosed(stream) {
    return stream.fd === null;
  },
  llseek(stream, offset, whence) {
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if (!stream.seekable || !stream.stream_ops.llseek) {
      throw new FS.ErrnoError(70);
    }
    if (whence != 0 && whence != 1 && whence != 2) {
      throw new FS.ErrnoError(28);
    }
    stream.position = stream.stream_ops.llseek(stream, offset, whence);
    stream.ungotten = [];
    return stream.position;
  },
  read(stream, buffer, offset, length, position) {
    assert(offset >= 0);
    if (length < 0 || position < 0) {
      throw new FS.ErrnoError(28);
    }
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if ((stream.flags & 2097155) === 1) {
      throw new FS.ErrnoError(8);
    }
    if (FS.isDir(stream.node.mode)) {
      throw new FS.ErrnoError(31);
    }
    if (!stream.stream_ops.read) {
      throw new FS.ErrnoError(28);
    }
    var seeking = typeof position != "undefined";
    if (!seeking) {
      position = stream.position;
    } else if (!stream.seekable) {
      throw new FS.ErrnoError(70);
    }
    var bytesRead = stream.stream_ops.read(stream, buffer, offset, length, position);
    if (!seeking) stream.position += bytesRead;
    return bytesRead;
  },
  write(stream, buffer, offset, length, position, canOwn) {
    assert(offset >= 0);
    assert(buffer.subarray, "FS.write expects a TypedArray");
    if (length < 0 || position < 0) {
      throw new FS.ErrnoError(28);
    }
    if (FS.isClosed(stream)) {
      throw new FS.ErrnoError(8);
    }
    if ((stream.flags & 2097155) === 0) {
      throw new FS.ErrnoError(8);
    }
    if (FS.isDir(stream.node.mode)) {
      throw new FS.ErrnoError(31);
    }
    if (!stream.stream_ops.write) {
      throw new FS.ErrnoError(28);
    }
    if (stream.seekable && stream.flags & 1024) {
      // seek to the end before writing in append mode
      FS.llseek(stream, 0, 2);
    }
    var seeking = typeof position != "undefined";
    if (!seeking) {
      position = stream.position;
    } else if (!stream.seekable) {
      throw new FS.ErrnoError(70);
    }
    var bytesWritten = stream.stream_ops.write(stream, buffer, offset, length, position, canOwn);
    if (!seeking) stream.position += bytesWritten;
    return bytesWritten;
  },
  mmap(stream, length, position, prot, flags) {
    // User requests writing to file (prot & PROT_WRITE != 0).
    // Checking if we have permissions to write to the file unless
    // MAP_PRIVATE flag is set. According to POSIX spec it is possible
    // to write to file opened in read-only mode with MAP_PRIVATE flag,
    // as all modifications will be visible only in the memory of
    // the current process.
    if ((prot & 2) && !(flags & 2) && (stream.flags & 2097155) !== 2) {
      throw new FS.ErrnoError(2);
    }
    if ((stream.flags & 2097155) === 1) {
      throw new FS.ErrnoError(2);
    }
    if (!stream.stream_ops.mmap) {
      throw new FS.ErrnoError(43);
    }
    if (!length) {
      throw new FS.ErrnoError(28);
    }
    return stream.stream_ops.mmap(stream, length, position, prot, flags);
  },
  msync(stream, buffer, offset, length, mmapFlags) {
    assert(offset >= 0);
    if (!stream.stream_ops.msync) {
      return 0;
    }
    return stream.stream_ops.msync(stream, buffer, offset, length, mmapFlags);
  },
  ioctl(stream, cmd, arg) {
    if (!stream.stream_ops.ioctl) {
      throw new FS.ErrnoError(59);
    }
    return stream.stream_ops.ioctl(stream, cmd, arg);
  },
  readFile(path, opts = {}) {
    opts.flags = opts.flags ?? 0;
    opts.encoding = opts.encoding ?? "binary";
    if (opts.encoding !== "utf8" && opts.encoding !== "binary") {
      abort(`Invalid encoding type "${opts.encoding}"`);
    }
    var stream = FS.open(path, opts.flags);
    var stat = FS.stat(path);
    var length = stat.size;
    var buf = new Uint8Array(length);
    FS.read(stream, buf, 0, length, 0);
    if (opts.encoding === "utf8") {
      buf = UTF8ArrayToString(buf);
    }
    FS.close(stream);
    return buf;
  },
  writeFile(path, data, opts = {}) {
    opts.flags = opts.flags ?? 577;
    var stream = FS.open(path, opts.flags, opts.mode);
    data = FS_fileDataToTypedArray(data);
    FS.write(stream, data, 0, data.byteLength, undefined, opts.canOwn);
    FS.close(stream);
  },
  cwd: () => FS.currentPath,
  chdir(path) {
    var lookup = FS.lookupPath(path, {
      follow: true
    });
    if (lookup.node === null) {
      throw new FS.ErrnoError(44);
    }
    if (!FS.isDir(lookup.node.mode)) {
      throw new FS.ErrnoError(54);
    }
    var errCode = FS.nodePermissions(lookup.node, "x");
    if (errCode) {
      throw new FS.ErrnoError(errCode);
    }
    FS.currentPath = lookup.path;
  },
  createDefaultDirectories() {
    FS.mkdir("/tmp");
    FS.mkdir("/home");
    FS.mkdir("/home/web_user");
  },
  createDefaultDevices() {
    // create /dev
    FS.mkdir("/dev");
    // setup /dev/null
    FS.registerDevice(FS.makedev(1, 3), {
      read: () => 0,
      write: (stream, buffer, offset, length, pos) => length,
      llseek: () => 0
    });
    FS.mkdev("/dev/null", FS.makedev(1, 3));
    // setup /dev/tty and /dev/tty1
    // stderr needs to print output using err() rather than out()
    // so we register a second tty just for it.
    TTY.register(FS.makedev(5, 0), TTY.default_tty_ops);
    TTY.register(FS.makedev(6, 0), TTY.default_tty1_ops);
    FS.mkdev("/dev/tty", FS.makedev(5, 0));
    FS.mkdev("/dev/tty1", FS.makedev(6, 0));
    // setup /dev/[u]random
    // use a buffer to avoid overhead of individual crypto calls per byte
    var randomBuffer = new Uint8Array(1024), randomLeft = 0;
    var randomByte = () => {
      if (!randomLeft) {
        randomFill(randomBuffer);
        randomLeft = randomBuffer.byteLength;
      }
      return randomBuffer[--randomLeft];
    };
    FS.createDevice("/dev", "random", randomByte);
    FS.createDevice("/dev", "urandom", randomByte);
    // we're not going to emulate the actual shm device,
    // just create the tmp dirs that reside in it commonly
    FS.mkdir("/dev/shm");
    FS.mkdir("/dev/shm/tmp");
  },
  createSpecialDirectories() {
    // create /proc/self/fd which allows /proc/self/fd/6 => readlink gives the
    // name of the stream for fd 6 (see test_unistd_ttyname)
    FS.mkdir("/proc");
    var proc_self = FS.mkdir("/proc/self");
    FS.mkdir("/proc/self/fd");
    FS.mount({
      mount() {
        var node = FS.createNode(proc_self, "fd", 16895, 73);
        node.stream_ops = {
          llseek: MEMFS.stream_ops.llseek
        };
        node.node_ops = {
          lookup(parent, name) {
            var fd = +name;
            var stream = FS.getStreamChecked(fd);
            var ret = {
              parent: null,
              mount: {
                mountpoint: "fake"
              },
              node_ops: {
                readlink: () => stream.path
              },
              id: fd + 1
            };
            ret.parent = ret;
            // make it look like a simple root node
            return ret;
          },
          readdir() {
            return Array.from(FS.streams.entries()).filter(([k, v]) => v).map(([k, v]) => k.toString());
          }
        };
        return node;
      }
    }, {}, "/proc/self/fd");
  },
  createStandardStreams(input, output, error) {
    // TODO deprecate the old functionality of a single
    // input / output callback and that utilizes FS.createDevice
    // and instead require a unique set of stream ops
    // by default, we symlink the standard streams to the
    // default tty devices. however, if the standard streams
    // have been overwritten we create a unique device for
    // them instead.
    if (input) {
      FS.createDevice("/dev", "stdin", input);
    } else {
      FS.symlink("/dev/tty", "/dev/stdin");
    }
    if (output) {
      FS.createDevice("/dev", "stdout", null, output);
    } else {
      FS.symlink("/dev/tty", "/dev/stdout");
    }
    if (error) {
      FS.createDevice("/dev", "stderr", null, error);
    } else {
      FS.symlink("/dev/tty1", "/dev/stderr");
    }
    // open default streams for the stdin, stdout and stderr devices
    var stdin = FS.open("/dev/stdin", 0);
    var stdout = FS.open("/dev/stdout", 1);
    var stderr = FS.open("/dev/stderr", 1);
    assert(stdin.fd === 0, `invalid handle for stdin (${stdin.fd})`);
    assert(stdout.fd === 1, `invalid handle for stdout (${stdout.fd})`);
    assert(stderr.fd === 2, `invalid handle for stderr (${stderr.fd})`);
  },
  staticInit() {
    FS.nameTable = new Array(4096);
    FS.mount(MEMFS, {}, "/");
    FS.createDefaultDirectories();
    FS.createDefaultDevices();
    FS.createSpecialDirectories();
    FS.filesystems = {
      "MEMFS": MEMFS
    };
  },
  init(input, output, error) {
    assert(!FS.initialized, "FS.init was previously called. If you want to initialize later with custom parameters, remove any earlier calls (note that one is automatically added to the generated code)");
    FS.initialized = true;
    // Allow Module.stdin etc. to provide defaults, if none explicitly passed to us here
    FS.createStandardStreams(input, output, error);
  },
  quit() {
    FS.initialized = false;
    // force-flush all streams, so we get musl std streams printed out
    _fflush(0);
    // close all of our streams
    for (var stream of FS.streams) {
      if (stream) {
        FS.close(stream);
      }
    }
  },
  findObject(path, dontResolveLastLink) {
    var ret = FS.analyzePath(path, dontResolveLastLink);
    if (!ret.exists) {
      return null;
    }
    return ret.object;
  },
  analyzePath(path, dontResolveLastLink) {
    // operate from within the context of the symlink's target
    try {
      var lookup = FS.lookupPath(path, {
        follow: !dontResolveLastLink
      });
      path = lookup.path;
    } catch (e) {}
    var ret = {
      isRoot: false,
      exists: false,
      error: 0,
      name: null,
      path: null,
      object: null,
      parentExists: false,
      parentPath: null,
      parentObject: null
    };
    try {
      var lookup = FS.lookupPath(path, {
        parent: true
      });
      ret.parentExists = true;
      ret.parentPath = lookup.path;
      ret.parentObject = lookup.node;
      ret.name = PATH.basename(path);
      lookup = FS.lookupPath(path, {
        follow: !dontResolveLastLink
      });
      ret.exists = true;
      ret.path = lookup.path;
      ret.object = lookup.node;
      ret.name = lookup.node.name;
      ret.isRoot = lookup.path === "/";
    } catch (e) {
      ret.error = e.errno;
    }
    return ret;
  },
  createPath(parent, path, canRead, canWrite) {
    parent = typeof parent == "string" ? parent : FS.getPath(parent);
    var parts = path.split("/").reverse();
    while (parts.length) {
      var part = parts.pop();
      if (!part) continue;
      var current = PATH.join2(parent, part);
      try {
        FS.mkdir(current);
      } catch (e) {
        if (e.errno != 20) throw e;
      }
      parent = current;
    }
    return current;
  },
  createFile(parent, name, properties, canRead, canWrite) {
    var path = PATH.join2(typeof parent == "string" ? parent : FS.getPath(parent), name);
    var mode = FS_getMode(canRead, canWrite);
    return FS.create(path, mode);
  },
  createDataFile(parent, name, data, canRead, canWrite, canOwn) {
    var path = name;
    if (parent) {
      parent = typeof parent == "string" ? parent : FS.getPath(parent);
      path = name ? PATH.join2(parent, name) : parent;
    }
    var mode = FS_getMode(canRead, canWrite);
    var node = FS.create(path, mode);
    if (data) {
      data = FS_fileDataToTypedArray(data);
      // make sure we can write to the file
      FS.chmod(node, mode | 146);
      var stream = FS.open(node, 577);
      FS.write(stream, data, 0, data.length, 0, canOwn);
      FS.close(stream);
      FS.chmod(node, mode);
    }
  },
  createDevice(parent, name, input, output) {
    var path = PATH.join2(typeof parent == "string" ? parent : FS.getPath(parent), name);
    var mode = FS_getMode(!!input, !!output);
    FS.createDevice.major ??= 64;
    var dev = FS.makedev(FS.createDevice.major++, 0);
    // Create a fake device that a set of stream ops to emulate
    // the old behavior.
    FS.registerDevice(dev, {
      open(stream) {
        stream.seekable = false;
      },
      close(stream) {
        // flush any pending line data
        if (output?.buffer?.length) {
          output(10);
        }
      },
      read(stream, buffer, offset, length, pos) {
        var bytesRead = 0;
        for (var i = 0; i < length; i++) {
          var result;
          try {
            result = input();
          } catch (e) {
            throw new FS.ErrnoError(29);
          }
          if (result === undefined && !bytesRead) {
            throw new FS.ErrnoError(6);
          }
          if (result === null || result === undefined) break;
          bytesRead++;
          buffer[offset + i] = result;
        }
        if (bytesRead) {
          stream.node.atime = Date.now();
        }
        return bytesRead;
      },
      write(stream, buffer, offset, length, pos) {
        for (var i = 0; i < length; i++) {
          try {
            output(buffer[offset + i]);
          } catch (e) {
            throw new FS.ErrnoError(29);
          }
        }
        if (length) {
          stream.node.mtime = stream.node.ctime = Date.now();
        }
        return i;
      }
    });
    return FS.mkdev(path, mode, dev);
  },
  forceLoadFile(obj) {
    if (obj.isDevice || obj.isFolder || obj.link || obj.contents) return true;
    if (globalThis.XMLHttpRequest) {
      abort("Lazy loading should have been performed (contents set) in createLazyFile, but it was not. Lazy loading only works in web workers. Use --embed-file or --preload-file in emcc on the main thread.");
    } else {
      // Command-line.
      try {
        obj.contents = readBinary(obj.url);
      } catch (e) {
        throw new FS.ErrnoError(29);
      }
    }
  },
  createLazyFile(parent, name, url, canRead, canWrite) {
    // Lazy chunked Uint8Array (implements get and length from Uint8Array).
    // Actual getting is abstracted away for eventual reuse.
    class LazyUint8Array {
      lengthKnown=false;
      chunks=[];
      // Loaded chunks. Index is the chunk number
      get(idx) {
        if (idx > this.length - 1 || idx < 0) {
          return undefined;
        }
        var chunkOffset = idx % this.chunkSize;
        var chunkNum = (idx / this.chunkSize) | 0;
        return this.getter(chunkNum)[chunkOffset];
      }
      setDataGetter(getter) {
        this.getter = getter;
      }
      cacheLength() {
        // Find length
        var xhr = new XMLHttpRequest;
        xhr.open("HEAD", url, false);
        xhr.send(null);
        if (!(xhr.status >= 200 && xhr.status < 300 || xhr.status === 304)) abort(`Couldn't load ${url}. Status: ${xhr.status}`);
        var datalength = Number(xhr.getResponseHeader("Content-length"));
        var header;
        var hasByteServing = (header = xhr.getResponseHeader("Accept-Ranges")) && header === "bytes";
        var usesGzip = (header = xhr.getResponseHeader("Content-Encoding")) && header === "gzip";
        var chunkSize = 1024 * 1024;
        // Chunk size in bytes
        if (!hasByteServing) chunkSize = datalength;
        // Function to get a range from the remote URL.
        var doXHR = (from, to) => {
          if (from > to) abort(`invalid range (${from}, ${to}) or no bytes requested!`);
          if (to > datalength - 1) abort(`only ${datalength} bytes available! programmer error!`);
          // TODO: Use mozResponseArrayBuffer, responseStream, etc. if available.
          var xhr = new XMLHttpRequest;
          xhr.open("GET", url, false);
          if (datalength !== chunkSize) xhr.setRequestHeader("Range", `bytes=${from}-${to}`);
          // Some hints to the browser that we want binary data.
          xhr.responseType = "arraybuffer";
          if (xhr.overrideMimeType) {
            xhr.overrideMimeType("text/plain; charset=x-user-defined");
          }
          xhr.send(null);
          if (!(xhr.status >= 200 && xhr.status < 300 || xhr.status === 304)) abort(`Couldn't load ${url}. Status: ${xhr.status}`);
          if (xhr.response !== undefined) {
            return new Uint8Array(/** @type{Array<number>} */ (xhr.response || []));
          }
          return intArrayFromString(xhr.responseText ?? "", true);
        };
        var lazyArray = this;
        lazyArray.setDataGetter(chunkNum => {
          var start = chunkNum * chunkSize;
          var end = (chunkNum + 1) * chunkSize - 1;
          // including this byte
          end = Math.min(end, datalength - 1);
          // if datalength-1 is selected, this is the last block
          if (typeof lazyArray.chunks[chunkNum] == "undefined") {
            lazyArray.chunks[chunkNum] = doXHR(start, end);
          }
          if (typeof lazyArray.chunks[chunkNum] == "undefined") abort("doXHR failed!");
          return lazyArray.chunks[chunkNum];
        });
        if (usesGzip || !datalength) {
          // if the server uses gzip or doesn't supply the length, we have to download the whole file to get the (uncompressed) length
          chunkSize = datalength = 1;
          // this will force getter(0)/doXHR do download the whole file
          datalength = this.getter(0).length;
          chunkSize = datalength;
          out("LazyFiles on gzip forces download of the whole file when length is accessed");
        }
        this._length = datalength;
        this._chunkSize = chunkSize;
        this.lengthKnown = true;
      }
      get length() {
        if (!this.lengthKnown) {
          this.cacheLength();
        }
        return this._length;
      }
      get chunkSize() {
        if (!this.lengthKnown) {
          this.cacheLength();
        }
        return this._chunkSize;
      }
    }
    if (globalThis.XMLHttpRequest) {
      if (!ENVIRONMENT_IS_WORKER) abort("Cannot do synchronous binary XHRs outside webworkers in modern browsers. Use --embed-file or --preload-file in emcc");
      var lazyArray = new LazyUint8Array;
      var properties = {
        isDevice: false,
        contents: lazyArray
      };
    } else {
      var properties = {
        isDevice: false,
        url
      };
    }
    var node = FS.createFile(parent, name, properties, canRead, canWrite);
    // This is a total hack, but I want to get this lazy file code out of the
    // core of MEMFS. If we want to keep this lazy file concept I feel it should
    // be its own thin LAZYFS proxying calls to MEMFS.
    if (properties.contents) {
      node.contents = properties.contents;
    } else if (properties.url) {
      node.contents = null;
      node.url = properties.url;
    }
    // Add a function that defers querying the file size until it is asked the first time.
    Object.defineProperties(node, {
      usedBytes: {
        get: function() {
          return this.contents.length;
        }
      }
    });
    // override each stream op with one that tries to force load the lazy file first
    var stream_ops = {};
    for (const [key, fn] of Object.entries(node.stream_ops)) {
      stream_ops[key] = (...args) => {
        FS.forceLoadFile(node);
        return fn(...args);
      };
    }
    function writeChunks(stream, buffer, offset, length, position) {
      var contents = stream.node.contents;
      if (position >= contents.length) return 0;
      var size = Math.min(contents.length - position, length);
      assert(size >= 0);
      if (contents.slice) {
        // normal array
        for (var i = 0; i < size; i++) {
          buffer[offset + i] = contents[position + i];
        }
      } else {
        for (var i = 0; i < size; i++) {
          // LazyUint8Array from sync binary XHR
          buffer[offset + i] = contents.get(position + i);
        }
      }
      return size;
    }
    // use a custom read function
    stream_ops.read = (stream, buffer, offset, length, position) => {
      FS.forceLoadFile(node);
      return writeChunks(stream, buffer, offset, length, position);
    };
    // use a custom mmap function
    stream_ops.mmap = (stream, length, position, prot, flags) => {
      FS.forceLoadFile(node);
      var ptr = mmapAlloc(length);
      if (!ptr) {
        throw new FS.ErrnoError(48);
      }
      writeChunks(stream, HEAP8, ptr, length, position);
      return {
        ptr,
        allocated: true
      };
    };
    node.stream_ops = stream_ops;
    return node;
  }
};

/** not-@type {!BigInt64Array} */ var HEAP64;

var SYSCALLS = {
  currentUmask: 18,
  calculateAt(dirfd, path, allowEmpty) {
    if (PATH.isAbs(path)) {
      return path;
    }
    // relative path
    var dir;
    if (dirfd === -100) {
      dir = FS.cwd();
    } else {
      var dirstream = SYSCALLS.getStreamFromFD(dirfd);
      dir = dirstream.path;
    }
    if (path.length == 0) {
      if (!allowEmpty) {
        throw new FS.ErrnoError(44);
      }
      return dir;
    }
    return dir + "/" + path;
  },
  writeStat(buf, stat) {
    HEAPU32[((buf) >>> 2) >>> 0] = stat.dev;
    HEAPU32[(((buf) + (4)) >>> 2) >>> 0] = stat.mode;
    HEAPU32[(((buf) + (8)) >>> 2) >>> 0] = stat.nlink;
    HEAPU32[(((buf) + (12)) >>> 2) >>> 0] = stat.uid;
    HEAPU32[(((buf) + (16)) >>> 2) >>> 0] = stat.gid;
    HEAPU32[(((buf) + (20)) >>> 2) >>> 0] = stat.rdev;
    HEAP64[(((buf) + (24)) >>> 3) >>> 0] = BigInt(stat.size);
    HEAP32[(((buf) + (32)) >>> 2) >>> 0] = 4096;
    HEAP32[(((buf) + (36)) >>> 2) >>> 0] = stat.blocks;
    var atime = stat.atime.getTime();
    var mtime = stat.mtime.getTime();
    var ctime = stat.ctime.getTime();
    HEAP64[(((buf) + (40)) >>> 3) >>> 0] = BigInt(Math.floor(atime / 1e3));
    HEAPU32[(((buf) + (48)) >>> 2) >>> 0] = (atime % 1e3) * 1e3 * 1e3;
    HEAP64[(((buf) + (56)) >>> 3) >>> 0] = BigInt(Math.floor(mtime / 1e3));
    HEAPU32[(((buf) + (64)) >>> 2) >>> 0] = (mtime % 1e3) * 1e3 * 1e3;
    HEAP64[(((buf) + (72)) >>> 3) >>> 0] = BigInt(Math.floor(ctime / 1e3));
    HEAPU32[(((buf) + (80)) >>> 2) >>> 0] = (ctime % 1e3) * 1e3 * 1e3;
    HEAP64[(((buf) + (88)) >>> 3) >>> 0] = BigInt(stat.ino);
    return 0;
  },
  writeStatFs(buf, stats) {
    HEAPU32[(((buf) + (4)) >>> 2) >>> 0] = stats.bsize;
    HEAPU32[(((buf) + (60)) >>> 2) >>> 0] = stats.bsize;
    HEAP64[(((buf) + (8)) >>> 3) >>> 0] = BigInt(stats.blocks);
    HEAP64[(((buf) + (16)) >>> 3) >>> 0] = BigInt(stats.bfree);
    HEAP64[(((buf) + (24)) >>> 3) >>> 0] = BigInt(stats.bavail);
    HEAP64[(((buf) + (32)) >>> 3) >>> 0] = BigInt(stats.files);
    HEAP64[(((buf) + (40)) >>> 3) >>> 0] = BigInt(stats.ffree);
    HEAPU32[(((buf) + (48)) >>> 2) >>> 0] = stats.fsid;
    HEAPU32[(((buf) + (64)) >>> 2) >>> 0] = stats.flags;
    // ST_NOSUID
    HEAPU32[(((buf) + (56)) >>> 2) >>> 0] = stats.namelen;
  },
  doMsync(addr, stream, len, flags, offset) {
    if (!FS.isFile(stream.node.mode)) {
      throw new FS.ErrnoError(43);
    }
    if (flags & 2) {
      // MAP_PRIVATE calls need not to be synced back to underlying fs
      return 0;
    }
    var buffer = HEAPU8.subarray(addr >>> 0, addr + len >>> 0);
    FS.msync(stream, buffer, offset, len, flags);
  },
  getStreamFromFD(fd) {
    var stream = FS.getStreamChecked(fd);
    return stream;
  },
  varargs: undefined,
  getStr(ptr) {
    var ret = UTF8ToString(ptr);
    return ret;
  }
};

function ___syscall_chmod(path, mode) {
  path >>>= 0;
  try {
    path = SYSCALLS.getStr(path);
    FS.chmod(path, mode);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_fchmod(fd, mode) {
  try {
    FS.fchmod(fd, mode);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

var syscallGetVarargI = () => {
  assert(SYSCALLS.varargs != undefined);
  // the `+` prepended here is necessary to convince the JSCompiler that varargs is indeed a number.
  var ret = HEAP32[((+SYSCALLS.varargs) >>> 2) >>> 0];
  SYSCALLS.varargs += 4;
  return ret;
};

var syscallGetVarargP = syscallGetVarargI;

/** @type {!Int16Array} */ var HEAP16;

function ___syscall_fcntl64(fd, cmd, varargs) {
  varargs >>>= 0;
  SYSCALLS.varargs = varargs;
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    switch (cmd) {
     case 0:
      {
        var arg = syscallGetVarargI();
        if (arg < 0) {
          return -28;
        }
        while (FS.streams[arg]) {
          arg++;
        }
        var newStream;
        newStream = FS.dupStream(stream, arg);
        return newStream.fd;
      }

     case 1:
     case 2:
      return 0;

     // FD_CLOEXEC makes no sense for a single process.
      case 3:
      return stream.flags;

     case 4:
      {
        var arg = syscallGetVarargI();
        var mask = 289792;
        stream.flags = (stream.flags & ~mask) | (arg & mask);
        return 0;
      }

     case 12:
      {
        var arg = syscallGetVarargP();
        var offset = 0;
        // We're always unlocked.
        HEAP16[(((arg) + (offset)) >>> 1) >>> 0] = 2;
        return 0;
      }

     case 13:
     case 14:
      // Pretend that the locking is successful. These are process-level locks,
      // and Emscripten programs are a single process. If we supported linking a
      // filesystem between programs, we'd need to do more here.
      // See https://github.com/emscripten-core/emscripten/issues/23697
      return 0;
    }
    return -28;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_fstat64(fd, buf) {
  buf >>>= 0;
  try {
    return SYSCALLS.writeStat(buf, FS.fstat(fd));
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_ftruncate64(fd, length) {
  length = bigintToI53Checked(length);
  try {
    if (isNaN(length)) return -22;
    FS.ftruncate(fd, length);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

var stringToUTF8 = (str, outPtr, maxBytesToWrite) => {
  assert(typeof maxBytesToWrite == "number", "stringToUTF8 requires a third parameter that specifies the length of the output buffer");
  return stringToUTF8Array(str, HEAPU8, outPtr, maxBytesToWrite);
};

function ___syscall_getcwd(buf, size) {
  buf >>>= 0;
  size >>>= 0;
  try {
    if (!size) return -28;
    var cwd = FS.cwd();
    var cwdLengthInBytes = lengthBytesUTF8(cwd) + 1;
    if (size < cwdLengthInBytes) return -68;
    stringToUTF8(cwd, buf, size);
    return cwdLengthInBytes;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_getdents64(fd, dirp, count) {
  dirp >>>= 0;
  count >>>= 0;
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    stream.getdents ||= FS.readdir(stream.path);
    var struct_size = 280;
    var pos = 0;
    var off = FS.llseek(stream, 0, 1);
    var startIdx = Math.floor(off / struct_size);
    var endIdx = Math.min(stream.getdents.length, startIdx + Math.floor(count / struct_size));
    for (var idx = startIdx; idx < endIdx; idx++) {
      var id;
      var type;
      var name = stream.getdents[idx];
      if (name === ".") {
        id = stream.node.id;
        type = 4;
      } else if (name === "..") {
        var lookup = FS.lookupPath(stream.path, {
          parent: true
        });
        id = lookup.node.id;
        type = 4;
      } else {
        var child;
        try {
          child = FS.lookupNode(stream.node, name);
        } catch (e) {
          // If the entry is not a directory, file, or symlink, nodefs
          // lookupNode will raise EINVAL. Skip these and continue.
          if (e?.errno === 28) {
            continue;
          }
          throw e;
        }
        id = child.id;
        type = FS.isChrdev(child.mode) ? 2 : // character device.
        FS.isDir(child.mode) ? 4 : // directory
        FS.isLink(child.mode) ? 10 : // symbolic link.
        8;
      }
      assert(id);
      HEAP64[((dirp + pos) >>> 3) >>> 0] = BigInt(id);
      HEAP64[(((dirp + pos) + (8)) >>> 3) >>> 0] = BigInt((idx + 1) * struct_size);
      HEAP16[(((dirp + pos) + (16)) >>> 1) >>> 0] = 280;
      HEAP8[(dirp + pos) + (18) >>> 0] = type;
      stringToUTF8(name, dirp + pos + 19, 256);
      pos += struct_size;
    }
    FS.llseek(stream, idx * struct_size, 0);
    return pos;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_ioctl(fd, op, varargs) {
  varargs >>>= 0;
  SYSCALLS.varargs = varargs;
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    switch (op) {
     case 21509:
      {
        if (!stream.tty) return -59;
        return 0;
      }

     case 21505:
      {
        if (!stream.tty) return -59;
        if (stream.tty.ops.ioctl_tcgets) {
          var termios = stream.tty.ops.ioctl_tcgets(stream);
          var argp = syscallGetVarargP();
          HEAP32[((argp) >>> 2) >>> 0] = termios.c_iflag || 0;
          HEAP32[(((argp) + (4)) >>> 2) >>> 0] = termios.c_oflag || 0;
          HEAP32[(((argp) + (8)) >>> 2) >>> 0] = termios.c_cflag || 0;
          HEAP32[(((argp) + (12)) >>> 2) >>> 0] = termios.c_lflag || 0;
          for (var i = 0; i < 32; i++) {
            HEAP8[(argp + i) + (17) >>> 0] = termios.c_cc[i] || 0;
          }
          return 0;
        }
        return 0;
      }

     case 21510:
     case 21511:
     case 21512:
      {
        if (!stream.tty) return -59;
        return 0;
      }

     case 21506:
     case 21507:
     case 21508:
      {
        if (!stream.tty) return -59;
        if (stream.tty.ops.ioctl_tcsets) {
          var argp = syscallGetVarargP();
          var c_iflag = HEAP32[((argp) >>> 2) >>> 0];
          var c_oflag = HEAP32[(((argp) + (4)) >>> 2) >>> 0];
          var c_cflag = HEAP32[(((argp) + (8)) >>> 2) >>> 0];
          var c_lflag = HEAP32[(((argp) + (12)) >>> 2) >>> 0];
          var c_cc = [];
          for (var i = 0; i < 32; i++) {
            c_cc.push(HEAP8[(argp + i) + (17) >>> 0]);
          }
          return stream.tty.ops.ioctl_tcsets(stream.tty, op, {
            c_iflag,
            c_oflag,
            c_cflag,
            c_lflag,
            c_cc
          });
        }
        return 0;
      }

     case 21519:
      {
        if (!stream.tty) return -59;
        var argp = syscallGetVarargP();
        HEAP32[((argp) >>> 2) >>> 0] = 0;
        return 0;
      }

     case 21520:
      {
        if (!stream.tty) return -59;
        return -28;
      }

     case 21537:
     case 21531:
      {
        var argp = syscallGetVarargP();
        return FS.ioctl(stream, op, argp);
      }

     case 21523:
      {
        // TODO: in theory we should write to the winsize struct that gets
        // passed in, but for now musl doesn't read anything on it
        if (!stream.tty) return -59;
        if (stream.tty.ops.ioctl_tiocgwinsz) {
          var winsize = stream.tty.ops.ioctl_tiocgwinsz(stream.tty);
          var argp = syscallGetVarargP();
          HEAP16[((argp) >>> 1) >>> 0] = winsize[0];
          HEAP16[(((argp) + (2)) >>> 1) >>> 0] = winsize[1];
        }
        return 0;
      }

     case 21524:
      {
        // TODO: technically, this ioctl call should change the window size.
        // but, since emscripten doesn't have any concept of a terminal window
        // yet, we'll just silently throw it away as we do TIOCGWINSZ
        if (!stream.tty) return -59;
        return 0;
      }

     case 21515:
      {
        if (!stream.tty) return -59;
        return 0;
      }

     default:
      return -28;
    }
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_lstat64(path, buf) {
  path >>>= 0;
  buf >>>= 0;
  try {
    path = SYSCALLS.getStr(path);
    return SYSCALLS.writeStat(buf, FS.lstat(path));
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_mkdirat(dirfd, path, mode) {
  path >>>= 0;
  try {
    path = SYSCALLS.getStr(path);
    path = SYSCALLS.calculateAt(dirfd, path);
    mode &= ~SYSCALLS.currentUmask;
    FS.mkdir(path, mode, 0);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_newfstatat(dirfd, path, buf, flags) {
  path >>>= 0;
  buf >>>= 0;
  try {
    path = SYSCALLS.getStr(path);
    var nofollow = flags & 256;
    var allowEmpty = flags & 4096;
    flags = flags & (~6400);
    assert(!flags, `unknown flags in __syscall_newfstatat: ${flags}`);
    path = SYSCALLS.calculateAt(dirfd, path, allowEmpty);
    return SYSCALLS.writeStat(buf, nofollow ? FS.lstat(path) : FS.stat(path));
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_openat(dirfd, path, flags, varargs) {
  path >>>= 0;
  varargs >>>= 0;
  SYSCALLS.varargs = varargs;
  try {
    path = SYSCALLS.getStr(path);
    path = SYSCALLS.calculateAt(dirfd, path);
    var mode = varargs ? syscallGetVarargI() : 0;
    if (flags & 64) {
      mode &= ~SYSCALLS.currentUmask;
    }
    return FS.open(path, flags, mode).fd;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_rmdir(path) {
  path >>>= 0;
  try {
    path = SYSCALLS.getStr(path);
    FS.rmdir(path);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_stat64(path, buf) {
  path >>>= 0;
  buf >>>= 0;
  try {
    path = SYSCALLS.getStr(path);
    return SYSCALLS.writeStat(buf, FS.stat(path));
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

function ___syscall_unlinkat(dirfd, path, flags) {
  path >>>= 0;
  try {
    path = SYSCALLS.getStr(path);
    path = SYSCALLS.calculateAt(dirfd, path);
    if (!flags) {
      FS.unlink(path);
    } else if (flags === 512) {
      FS.rmdir(path);
    } else {
      return -28;
    }
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

var readI53FromI64 = ptr => HEAPU32[((ptr) >>> 2) >>> 0] + HEAP32[(((ptr) + (4)) >>> 2) >>> 0] * 4294967296;

function ___syscall_utimensat(dirfd, path, times, flags) {
  path >>>= 0;
  times >>>= 0;
  try {
    var nofollow = flags & 256;
    path = SYSCALLS.getStr(path);
    path = SYSCALLS.calculateAt(dirfd, path, true);
    var now = Date.now(), atime, mtime;
    if (!times) {
      atime = now;
      mtime = now;
    } else {
      var seconds = readI53FromI64(times);
      var nanoseconds = HEAP32[(((times) + (8)) >>> 2) >>> 0];
      if (nanoseconds == 1073741823) {
        atime = now;
      } else if (nanoseconds == 1073741822) {
        atime = null;
      } else {
        atime = (seconds * 1e3) + (nanoseconds / (1e3 * 1e3));
      }
      times += 16;
      seconds = readI53FromI64(times);
      nanoseconds = HEAP32[(((times) + (8)) >>> 2) >>> 0];
      if (nanoseconds == 1073741823) {
        mtime = now;
      } else if (nanoseconds == 1073741822) {
        mtime = null;
      } else {
        mtime = (seconds * 1e3) + (nanoseconds / (1e3 * 1e3));
      }
    }
    // null here means UTIME_OMIT was passed. If both were set to UTIME_OMIT then
    // we can skip the call completely.
    if ((mtime ?? atime) !== null) {
      FS.utime(path, atime, mtime, nofollow);
    }
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return -e.errno;
  }
}

var __abort_js = () => abort("native code called abort()");

var isLeapYear = year => year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);

var MONTH_DAYS_LEAP_CUMULATIVE = [ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 ];

var MONTH_DAYS_REGULAR_CUMULATIVE = [ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 ];

var ydayFromDate = date => {
  var leap = isLeapYear(date.getFullYear());
  var monthDaysCumulative = (leap ? MONTH_DAYS_LEAP_CUMULATIVE : MONTH_DAYS_REGULAR_CUMULATIVE);
  var yday = monthDaysCumulative[date.getMonth()] + date.getDate() - 1;
  // -1 since it's days since Jan 1
  return yday;
};

function __localtime_js(time, tmPtr) {
  time = bigintToI53Checked(time);
  tmPtr >>>= 0;
  var date = new Date(time * 1e3);
  if (isNaN(date.getTime())) {
    return 1;
  }
  HEAP32[((tmPtr) >>> 2) >>> 0] = date.getSeconds();
  HEAP32[(((tmPtr) + (4)) >>> 2) >>> 0] = date.getMinutes();
  HEAP32[(((tmPtr) + (8)) >>> 2) >>> 0] = date.getHours();
  HEAP32[(((tmPtr) + (12)) >>> 2) >>> 0] = date.getDate();
  HEAP32[(((tmPtr) + (16)) >>> 2) >>> 0] = date.getMonth();
  HEAP32[(((tmPtr) + (20)) >>> 2) >>> 0] = date.getFullYear() - 1900;
  HEAP32[(((tmPtr) + (24)) >>> 2) >>> 0] = date.getDay();
  var yday = ydayFromDate(date) | 0;
  HEAP32[(((tmPtr) + (28)) >>> 2) >>> 0] = yday;
  HEAP32[(((tmPtr) + (36)) >>> 2) >>> 0] = -(date.getTimezoneOffset() * 60);
  // Attention: DST is in December in South, and some regions don't have DST at all.
  var start = new Date(date.getFullYear(), 0, 1);
  var summerOffset = new Date(date.getFullYear(), 6, 1).getTimezoneOffset();
  var winterOffset = start.getTimezoneOffset();
  var dst = (summerOffset != winterOffset && date.getTimezoneOffset() == Math.min(winterOffset, summerOffset)) | 0;
  HEAP32[(((tmPtr) + (32)) >>> 2) >>> 0] = dst;
  return 0;
}

var __tzset_js = function(timezone, daylight, std_name, dst_name) {
  timezone >>>= 0;
  daylight >>>= 0;
  std_name >>>= 0;
  dst_name >>>= 0;
  // TODO: Use (malleable) environment variables instead of system settings.
  var currentYear = (new Date).getFullYear();
  var winter = new Date(currentYear, 0, 1);
  var summer = new Date(currentYear, 6, 1);
  var winterOffset = winter.getTimezoneOffset();
  var summerOffset = summer.getTimezoneOffset();
  // Local standard timezone offset. Local standard time is not adjusted for
  // daylight savings.  This code uses the fact that getTimezoneOffset returns
  // a greater value during Standard Time versus Daylight Saving Time (DST).
  // Thus it determines the expected output during Standard Time, and it
  // compares whether the output of the given date the same (Standard) or less
  // (DST).
  var stdTimezoneOffset = Math.max(winterOffset, summerOffset);
  // timezone is specified as seconds west of UTC ("The external variable
  // `timezone` shall be set to the difference, in seconds, between
  // Coordinated Universal Time (UTC) and local standard time."), the same
  // as returned by stdTimezoneOffset.
  // See http://pubs.opengroup.org/onlinepubs/009695399/functions/tzset.html
  HEAPU32[((timezone) >>> 2) >>> 0] = stdTimezoneOffset * 60;
  HEAP32[((daylight) >>> 2) >>> 0] = Number(winterOffset != summerOffset);
  var extractZone = timezoneOffset => {
    // Why inverse sign?
    // Read here https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Date/getTimezoneOffset
    var sign = timezoneOffset >= 0 ? "-" : "+";
    var absOffset = Math.abs(timezoneOffset);
    var hours = String(Math.floor(absOffset / 60)).padStart(2, "0");
    var minutes = String(absOffset % 60).padStart(2, "0");
    return `UTC${sign}${hours}${minutes}`;
  };
  var winterName = extractZone(winterOffset);
  var summerName = extractZone(summerOffset);
  assert(winterName);
  assert(summerName);
  assert(lengthBytesUTF8(winterName) <= 16, `timezone name truncated to fit in TZNAME_MAX (${winterName})`);
  assert(lengthBytesUTF8(summerName) <= 16, `timezone name truncated to fit in TZNAME_MAX (${summerName})`);
  if (summerOffset < winterOffset) {
    // Northern hemisphere
    stringToUTF8(winterName, std_name, 17);
    stringToUTF8(summerName, dst_name, 17);
  } else {
    stringToUTF8(winterName, dst_name, 17);
    stringToUTF8(summerName, std_name, 17);
  }
};

var _emscripten_get_now = () => performance.now();

var _emscripten_get_now_res = () => {
  // return resolution of get_now, in nanoseconds
  if (ENVIRONMENT_IS_NODE) {
    return 1;
  }
  // Modern environment where performance.now() is supported:
  return 1e3;
};

var nowIsMonotonic = 1;

var checkWasiClock = clock_id => clock_id >= 0 && clock_id <= 3;

function _clock_res_get(clk_id, pres) {
  pres >>>= 0;
  if (!checkWasiClock(clk_id)) {
    return 28;
  }
  var nsec;
  // all wasi clocks but realtime are monotonic
  if (clk_id === 0) {
    nsec = 1e3 * 1e3;
  } else if (nowIsMonotonic) {
    nsec = _emscripten_get_now_res();
  } else {
    return 52;
  }
  HEAP64[((pres) >>> 3) >>> 0] = BigInt(nsec);
  return 0;
}

var _emscripten_date_now = () => Date.now();

function _clock_time_get(clk_id, ignored_precision, ptime) {
  ignored_precision = bigintToI53Checked(ignored_precision);
  ptime >>>= 0;
  if (!checkWasiClock(clk_id)) {
    return 28;
  }
  var now;
  // all wasi clocks but realtime are monotonic
  if (clk_id === 0) {
    now = _emscripten_date_now();
  } else if (nowIsMonotonic) {
    now = _emscripten_get_now();
  } else {
    return 52;
  }
  // "now" is in ms, and wasi times are in ns.
  var nsec = Math.round(now * 1e3 * 1e3);
  HEAP64[((ptime) >>> 3) >>> 0] = BigInt(nsec);
  return 0;
}

var handleException = e => {
  // Certain exception types we do not treat as errors since they are used for
  // internal control flow.
  // 1. ExitStatus, which is thrown by exit()
  // 2. "unwind", which is thrown by emscripten_unwind_to_js_event_loop() and others
  //    that wish to return to JS event loop.
  if (e instanceof ExitStatus || e == "unwind") {
    return EXITSTATUS;
  }
  checkStackCookie();
  if (e instanceof WebAssembly.RuntimeError) {
    if (_emscripten_stack_get_current() <= 0) {
      err("Stack overflow detected.  You can try increasing -sSTACK_SIZE (currently set to 65536)");
    }
  }
  quit_(1, e);
};

var keepRuntimeAlive = () => true;

var _proc_exit = code => {
  EXITSTATUS = code;
  if (!keepRuntimeAlive()) {
    ABORT = true;
  }
  quit_(code, new ExitStatus(code));
};

var runtimeKeepaliveCounter = 0;

/** @param {boolean|number=} implicit */ var exitJS = (status, implicit) => {
  EXITSTATUS = status;
  checkUnflushedContent();
  // if exit() was called explicitly, warn the user if the runtime isn't actually being shut down
  if (keepRuntimeAlive() && !implicit) {
    var msg = `program exited (with status: ${status}), but keepRuntimeAlive() is set (counter=${runtimeKeepaliveCounter}) due to an async operation, so halting execution but not exiting the runtime or preventing further async execution (you can use emscripten_force_exit, if you want to force a true shutdown)`;
    err(msg);
  }
  _proc_exit(status);
};

var _exit = exitJS;

var maybeExit = () => {
  if (!keepRuntimeAlive()) {
    try {
      _exit(EXITSTATUS);
    } catch (e) {
      handleException(e);
    }
  }
};

var callUserCallback = func => {
  if (ABORT) {
    err("user callback triggered after runtime exited or application aborted.  Ignoring.");
    return;
  }
  try {
    return func();
  } catch (e) {
    handleException(e);
  } finally {
    maybeExit();
  }
};

function getFullscreenElement() {
  return document.fullscreenElement ?? document.webkitFullscreenElement;
}

/** @param {number=} timeout */ var safeSetTimeout = (func, timeout) => setTimeout(() => {
  callUserCallback(func);
}, timeout);

var Browser = {
  useWebGL: false,
  isFullscreen: false,
  pointerLock: false,
  moduleContextCreatedCallbacks: [],
  preloadedImages: {},
  preloadedAudios: {},
  getCanvas: () => Module["canvas"],
  init() {
    if (Browser.initted) return;
    Browser.initted = true;
    // Support for plugins that can process preloaded files. You can add more of these to
    // your app by creating and appending to preloadPlugins.
    // Each plugin is asked if it can handle a file based on the file's name. If it can,
    // it is given the file's raw data. When it is done, it calls a callback with the file's
    // (possibly modified) data. For example, a plugin might decompress a file, or it
    // might create some side data structure for use later (like an Image element, etc.).
    var imagePlugin = {};
    imagePlugin["canHandle"] = name => !Module["noImageDecoding"] && /\.(jpg|jpeg|png|bmp|webp)$/i.test(name);
    imagePlugin["handle"] = async (byteArray, name) => {
      var b = new Blob([ byteArray ], {
        type: Browser.getMimetype(name)
      });
      if (b.size !== byteArray.length) {
        // Safari bug #118630
        // Safari's Blob can only take an ArrayBuffer
        b = new Blob([ (new Uint8Array(byteArray)).buffer ], {
          type: Browser.getMimetype(name)
        });
      }
      var url = URL.createObjectURL(b);
      return new Promise((resolve, reject) => {
        var img = new Image;
        img.onload = () => {
          assert(img.complete, `Image ${name} could not be decoded`);
          var canvas = /** @type {!HTMLCanvasElement} */ (document.createElement("canvas"));
          canvas.width = img.width;
          canvas.height = img.height;
          var ctx = canvas.getContext("2d");
          ctx.drawImage(img, 0, 0);
          Browser.preloadedImages[name] = canvas;
          URL.revokeObjectURL(url);
          resolve(byteArray);
        };
        img.onerror = event => {
          err(`Image ${url} could not be decoded`);
          reject();
        };
        img.src = url;
      });
    };
    preloadPlugins.push(imagePlugin);
    var audioPlugin = {};
    audioPlugin["canHandle"] = name => !Module["noAudioDecoding"] && name.slice(-4) in {
      ".ogg": 1,
      ".wav": 1,
      ".mp3": 1
    };
    audioPlugin["handle"] = async (byteArray, name) => new Promise((resolve, reject) => {
      var done = false;
      function finish(audio) {
        if (done) return;
        done = true;
        Browser.preloadedAudios[name] = audio;
        resolve(byteArray);
      }
      var b = new Blob([ byteArray ], {
        type: Browser.getMimetype(name)
      });
      var url = URL.createObjectURL(b);
      // XXX we never revoke this!
      var audio = new Audio;
      audio.addEventListener("canplaythrough", () => finish(audio));
      // use addEventListener due to chromium bug 124926
      audio.onerror = event => {
        if (done) return;
        err(`warning: browser could not fully decode audio ${name}, trying slower base64 approach`);
        function encode64(data) {
          var BASE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
          var PAD = "=";
          var ret = "";
          var leftchar = 0;
          var leftbits = 0;
          for (var byte of data) {
            leftchar = (leftchar << 8) | byte;
            leftbits += 8;
            while (leftbits >= 6) {
              var curr = (leftchar >> (leftbits - 6)) & 63;
              leftbits -= 6;
              ret += BASE[curr];
            }
          }
          if (leftbits == 2) {
            ret += BASE[(leftchar & 3) << 4];
            ret += PAD + PAD;
          } else if (leftbits == 4) {
            ret += BASE[(leftchar & 15) << 2];
            ret += PAD;
          }
          return ret;
        }
        audio.src = "data:audio/x-" + name.slice(-3) + ";base64," + encode64(byteArray);
        finish(audio);
      };
      audio.src = url;
      // workaround for chrome bug 124926 - we do not always get oncanplaythrough or onerror
      safeSetTimeout(() => {
        finish(audio);
      }, 1e4);
    });
    preloadPlugins.push(audioPlugin);
    // Canvas event setup
    function pointerLockChange() {
      var canvas = Browser.getCanvas();
      Browser.pointerLock = document.pointerLockElement === canvas;
    }
    var canvas = Browser.getCanvas();
    if (canvas) {
      // forced aspect ratio can be enabled by defining 'forcedAspectRatio' on Module
      // Module['forcedAspectRatio'] = 4 / 3;
      document.addEventListener("pointerlockchange", pointerLockChange);
    }
  },
  createContext(/** @type {HTMLCanvasElement} */ canvas, useWebGL, setInModule, webGLContextAttributes) {
    if (useWebGL && Module["ctx"] && canvas == Browser.getCanvas()) return Module["ctx"];
    // no need to recreate GL context if it's already been created for this canvas.
    var ctx;
    var contextHandle;
    if (useWebGL) {
      // For GLES2/desktop GL compatibility, adjust a few defaults to be different to WebGL defaults, so that they align better with the desktop defaults.
      var contextAttributes = {
        antialias: false,
        alpha: false,
        majorVersion: 2
      };
      if (webGLContextAttributes) {
        for (var attribute in webGLContextAttributes) {
          contextAttributes[attribute] = webGLContextAttributes[attribute];
        }
      }
      // This check of existence of GL is here to satisfy Closure compiler, which yells if variable GL is referenced below but GL object is not
      // actually compiled in because application is not doing any GL operations. TODO: Ideally if GL is not being used, this function
      // Browser.createContext() should not even be emitted.
      if (typeof GL != "undefined") {
        contextHandle = GL.createContext(canvas, contextAttributes);
        if (contextHandle) {
          ctx = GL.getContext(contextHandle).GLctx;
        }
      }
    } else {
      ctx = canvas.getContext("2d");
    }
    if (!ctx) return null;
    if (setInModule) {
      if (!useWebGL) assert(typeof GLctx == "undefined", "cannot set in module if GLctx is used, but we are a non-GL context that would replace it");
      Module["ctx"] = ctx;
      if (useWebGL) GL.makeContextCurrent(contextHandle);
      Browser.useWebGL = useWebGL;
      Browser.moduleContextCreatedCallbacks.forEach(callback => callback());
      Browser.init();
    }
    return ctx;
  },
  fullscreenHandlersInstalled: false,
  lockPointer: undefined,
  resizeCanvas: undefined,
  requestFullscreen(lockPointer, resizeCanvas) {
    Browser.lockPointer = lockPointer;
    Browser.resizeCanvas = resizeCanvas;
    if (typeof Browser.lockPointer == "undefined") Browser.lockPointer = true;
    if (typeof Browser.resizeCanvas == "undefined") Browser.resizeCanvas = false;
    var canvas = Browser.getCanvas();
    function fullscreenChange() {
      Browser.isFullscreen = false;
      var canvasContainer = canvas.parentNode;
      if (getFullscreenElement() === canvasContainer) {
        canvas.exitFullscreen = Browser.exitFullscreen;
        if (Browser.lockPointer) canvas.requestPointerLock();
        Browser.isFullscreen = true;
        if (Browser.resizeCanvas) {
          Browser.setFullscreenCanvasSize();
        } else {
          Browser.updateCanvasDimensions(canvas);
        }
      } else {
        // remove the full screen specific parent of the canvas again to restore the HTML structure from before going full screen
        canvasContainer.parentNode.insertBefore(canvas, canvasContainer);
        canvasContainer.parentNode.removeChild(canvasContainer);
        if (Browser.resizeCanvas) {
          Browser.setWindowedCanvasSize();
        } else {
          Browser.updateCanvasDimensions(canvas);
        }
      }
    }
    if (!Browser.fullscreenHandlersInstalled) {
      Browser.fullscreenHandlersInstalled = true;
      document.addEventListener("fullscreenchange", fullscreenChange);
      document.addEventListener("webkitfullscreenchange", fullscreenChange);
    }
    // create a new parent to ensure the canvas has no siblings. this allows browsers to optimize full screen performance when its parent is the full screen root
    var canvasContainer = document.createElement("div");
    canvas.parentNode.insertBefore(canvasContainer, canvas);
    canvasContainer.appendChild(canvas);
    // use parent of canvas as full screen root to allow aspect ratio correction (Firefox stretches the root to screen size)
    // Safari didn't support Element.requestFullscreen until 16.4
    // See: https://developer.mozilla.org/en-US/docs/Web/API/Element/requestFullscreen
    /** @suppress {checkTypes} */ canvasContainer.requestFullscreen ??= (canvasContainer["webkitRequestFullscreen"] ? () => canvasContainer["webkitRequestFullscreen"](Element.ALLOW_KEYBOARD_INPUT) : null) ?? (canvasContainer["webkitRequestFullScreen"] ? () => canvasContainer["webkitRequestFullScreen"](Element.ALLOW_KEYBOARD_INPUT) : null);
    canvasContainer.requestFullscreen();
  },
  exitFullscreen() {
    // This is workaround for chrome. Trying to exit from fullscreen
    // not in fullscreen state will cause 'TypeError: Document not active'
    // in chrome. See https://github.com/emscripten-core/emscripten/pull/8236
    if (!Browser.isFullscreen) {
      return false;
    }
    var CFS = document.exitFullscreen ?? document["webkitCancelFullScreen"];
    CFS.apply(document, []);
    return true;
  },
  safeSetTimeout(func, timeout) {
    // Legacy function, this is used by the SDL2 port so we need to keep it
    // around at least until that is updated.
    // See https://github.com/libsdl-org/SDL/pull/6304
    return safeSetTimeout(func, timeout);
  },
  getMimetype(name) {
    return {
      "jpg": "image/jpeg",
      "jpeg": "image/jpeg",
      "png": "image/png",
      "bmp": "image/bmp",
      "ogg": "audio/ogg",
      "wav": "audio/wav",
      "mp3": "audio/mpeg"
    }[name.slice(name.lastIndexOf(".") + 1)];
  },
  getUserMedia(func) {
    return navigator.mediaDevices.getUserMedia(func);
  },
  getMouseWheelDelta(event) {
    var delta = 0;
    switch (event.type) {
     case "DOMMouseScroll":
      // 3 lines make up a step
      delta = event.detail / 3;
      break;

     case "mousewheel":
      // 120 units make up a step
      delta = event.wheelDelta / 120;
      break;

     case "wheel":
      delta = event.deltaY;
      switch (event.deltaMode) {
       case 0:
        // DOM_DELTA_PIXEL: 100 pixels make up a step
        delta /= 100;
        break;

       case 1:
        // DOM_DELTA_LINE: 3 lines make up a step
        delta /= 3;
        break;

       case 2:
        // DOM_DELTA_PAGE: A page makes up 80 steps
        delta *= 80;
        break;

       default:
        abort("unrecognized mouse wheel delta mode: " + event.deltaMode);
      }
      break;

     default:
      abort("unrecognized mouse wheel event: " + event.type);
    }
    return delta;
  },
  mouseX: 0,
  mouseY: 0,
  mouseMovementX: 0,
  mouseMovementY: 0,
  touches: {},
  lastTouches: {},
  calculateMouseCoords(pageX, pageY) {
    // Calculate the movement based on the changes
    // in the coordinates.
    var canvas = Browser.getCanvas();
    var rect = canvas.getBoundingClientRect();
    var adjustedX = pageX - (window.scrollX + rect.left);
    var adjustedY = pageY - (window.scrollY + rect.top);
    // the canvas might be CSS-scaled compared to its backbuffer;
    // SDL-using content will want mouse coordinates in terms
    // of backbuffer units.
    adjustedX = adjustedX * (canvas.width / rect.width);
    adjustedY = adjustedY * (canvas.height / rect.height);
    return {
      x: adjustedX,
      y: adjustedY
    };
  },
  setMouseCoords(pageX, pageY) {
    const {x, y} = Browser.calculateMouseCoords(pageX, pageY);
    Browser.mouseMovementX = x - Browser.mouseX;
    Browser.mouseMovementY = y - Browser.mouseY;
    Browser.mouseX = x;
    Browser.mouseY = y;
  },
  calculateMouseEvent(event) {
    // event should be mousemove, mousedown or mouseup
    if (Browser.pointerLock) {
      // When the pointer is locked, calculate the coordinates
      // based on the movement of the mouse.
      Browser.mouseMovementX = event.movementX;
      Browser.mouseMovementY = event.movementY;
      // add the mouse delta to the current absolute mouse position
      Browser.mouseX += Browser.mouseMovementX;
      Browser.mouseY += Browser.mouseMovementY;
    } else {
      if (event.type === "touchstart" || event.type === "touchend" || event.type === "touchmove") {
        var touch = event.touch;
        if (touch === undefined) {
          return;
        }
        var coords = Browser.calculateMouseCoords(touch.pageX, touch.pageY);
        if (event.type === "touchstart") {
          Browser.lastTouches[touch.identifier] = coords;
          Browser.touches[touch.identifier] = coords;
        } else if (event.type === "touchend" || event.type === "touchmove") {
          var last = Browser.touches[touch.identifier];
          last ||= coords;
          Browser.lastTouches[touch.identifier] = last;
          Browser.touches[touch.identifier] = coords;
        }
        return;
      }
      Browser.setMouseCoords(event.pageX, event.pageY);
    }
  },
  resizeListeners: [],
  updateResizeListeners() {
    var canvas = Browser.getCanvas();
    Browser.resizeListeners.forEach(listener => listener(canvas.width, canvas.height));
  },
  setCanvasSize(width, height, noUpdates) {
    var canvas = Browser.getCanvas();
    Browser.updateCanvasDimensions(canvas, width, height);
    if (!noUpdates) Browser.updateResizeListeners();
  },
  windowedWidth: 0,
  windowedHeight: 0,
  setFullscreenCanvasSize() {
    // check if SDL is available
    if (typeof SDL != "undefined") {
      var flags = HEAPU32[((SDL.screen) >>> 2) >>> 0];
      flags = flags | 8388608;
      // set SDL_FULLSCREEN flag
      HEAP32[((SDL.screen) >>> 2) >>> 0] = flags;
    }
    Browser.updateCanvasDimensions(Browser.getCanvas());
    Browser.updateResizeListeners();
  },
  setWindowedCanvasSize() {
    // check if SDL is available
    if (typeof SDL != "undefined") {
      var flags = HEAPU32[((SDL.screen) >>> 2) >>> 0];
      flags = flags & ~8388608;
      // clear SDL_FULLSCREEN flag
      HEAP32[((SDL.screen) >>> 2) >>> 0] = flags;
    }
    Browser.updateCanvasDimensions(Browser.getCanvas());
    Browser.updateResizeListeners();
  },
  updateCanvasDimensions(canvas, wNative, hNative) {
    if (wNative && hNative) {
      canvas.widthNative = wNative;
      canvas.heightNative = hNative;
    } else {
      wNative = canvas.widthNative;
      hNative = canvas.heightNative;
    }
    var w = wNative;
    var h = hNative;
    if ((getFullscreenElement() === canvas.parentNode) && (typeof screen != "undefined")) {
      var factor = Math.min(screen.width / w, screen.height / h);
      w = Math.round(w * factor);
      h = Math.round(h * factor);
    }
    if (Browser.resizeCanvas) {
      if (canvas.width != w) canvas.width = w;
      if (canvas.height != h) canvas.height = h;
      if (typeof canvas.style != "undefined") {
        canvas.style.removeProperty("width");
        canvas.style.removeProperty("height");
      }
    } else {
      if (canvas.width != wNative) canvas.width = wNative;
      if (canvas.height != hNative) canvas.height = hNative;
      if (typeof canvas.style != "undefined") {
        if (w != wNative || h != hNative) {
          canvas.style.setProperty("width", w + "px", "important");
          canvas.style.setProperty("height", h + "px", "important");
        } else {
          canvas.style.removeProperty("width");
          canvas.style.removeProperty("height");
        }
      }
    }
  }
};

var EGL = {
  errorCode: 12288,
  defaultDisplayInitialized: false,
  currentContext: 0,
  currentReadSurface: 0,
  currentDrawSurface: 0,
  contextAttributes: {
    alpha: false,
    depth: false,
    stencil: false,
    antialias: false
  },
  stringCache: {},
  setErrorCode(code) {
    EGL.errorCode = code;
  },
  chooseConfig(display, attribList, config, config_size, numConfigs) {
    if (display != 62e3) {
      EGL.setErrorCode(12296);
      return 0;
    }
    if (attribList) {
      // read attribList if it is non-null
      for (;;) {
        var param = HEAP32[((attribList) >>> 2) >>> 0];
        if (param == 12321) {
          var alphaSize = HEAP32[(((attribList) + (4)) >>> 2) >>> 0];
          EGL.contextAttributes.alpha = (alphaSize > 0);
        } else if (param == 12325) {
          var depthSize = HEAP32[(((attribList) + (4)) >>> 2) >>> 0];
          EGL.contextAttributes.depth = (depthSize > 0);
        } else if (param == 12326) {
          var stencilSize = HEAP32[(((attribList) + (4)) >>> 2) >>> 0];
          EGL.contextAttributes.stencil = (stencilSize > 0);
        } else if (param == 12337) {
          var samples = HEAP32[(((attribList) + (4)) >>> 2) >>> 0];
          EGL.contextAttributes.antialias = (samples > 0);
        } else if (param == 12338) {
          var samples = HEAP32[(((attribList) + (4)) >>> 2) >>> 0];
          EGL.contextAttributes.antialias = (samples == 1);
        } else if (param == 12544) {
          var requestedPriority = HEAP32[(((attribList) + (4)) >>> 2) >>> 0];
          EGL.contextAttributes.lowLatency = (requestedPriority != 12547);
        } else if (param == 12344) {
          break;
        }
        attribList += 8;
      }
    }
    if ((!config || !config_size) && !numConfigs) {
      EGL.setErrorCode(12300);
      return 0;
    }
    if (numConfigs) {
      HEAP32[((numConfigs) >>> 2) >>> 0] = 1;
    }
    if (config && config_size > 0) {
      HEAPU32[((config) >>> 2) >>> 0] = 62002;
    }
    EGL.setErrorCode(12288);
    return 1;
  }
};

var _eglBindAPI = api => {
  if (api == 12448) {
    EGL.setErrorCode(12288);
    return 1;
  }
  // if (api == 0x30A1 /* EGL_OPENVG_API */ || api == 0x30A2 /* EGL_OPENGL_API */) {
  EGL.setErrorCode(12300);
  return 0;
};

function _eglChooseConfig(display, attrib_list, configs, config_size, numConfigs) {
  display >>>= 0;
  attrib_list >>>= 0;
  configs >>>= 0;
  numConfigs >>>= 0;
  return EGL.chooseConfig(display, attrib_list, configs, config_size, numConfigs);
}

var GLctx;

var webgl_enable_WEBGL_draw_instanced_base_vertex_base_instance = ctx => // Closure is expected to be allowed to minify the '.dibvbi' property, so not accessing it quoted.
!!(ctx.dibvbi = ctx.getExtension("WEBGL_draw_instanced_base_vertex_base_instance"));

var webgl_enable_WEBGL_multi_draw_instanced_base_vertex_base_instance = ctx => !!(ctx.mdibvbi = ctx.getExtension("WEBGL_multi_draw_instanced_base_vertex_base_instance"));

var webgl_enable_EXT_polygon_offset_clamp = ctx => !!(ctx.extPolygonOffsetClamp = ctx.getExtension("EXT_polygon_offset_clamp"));

var webgl_enable_EXT_clip_control = ctx => !!(ctx.extClipControl = ctx.getExtension("EXT_clip_control"));

var webgl_enable_WEBGL_polygon_mode = ctx => !!(ctx.webglPolygonMode = ctx.getExtension("WEBGL_polygon_mode"));

var webgl_enable_WEBGL_multi_draw = ctx => // Closure is expected to be allowed to minify the '.multiDrawWebgl' property, so not accessing it quoted.
!!(ctx.multiDrawWebgl = ctx.getExtension("WEBGL_multi_draw"));

var getEmscriptenSupportedExtensions = ctx => {
  // Restrict the list of advertised extensions to those that we actually
  // support.
  var supportedExtensions = [ // WebGL 2 extensions
  "EXT_color_buffer_float", "EXT_conservative_depth", "EXT_disjoint_timer_query_webgl2", "EXT_texture_norm16", "NV_shader_noperspective_interpolation", "WEBGL_clip_cull_distance", // WebGL 1 and WebGL 2 extensions
  "EXT_clip_control", "EXT_color_buffer_half_float", "EXT_depth_clamp", "EXT_float_blend", "EXT_polygon_offset_clamp", "EXT_texture_compression_bptc", "EXT_texture_compression_rgtc", "EXT_texture_filter_anisotropic", "KHR_parallel_shader_compile", "OES_texture_float_linear", "WEBGL_blend_func_extended", "WEBGL_compressed_texture_astc", "WEBGL_compressed_texture_etc", "WEBGL_compressed_texture_etc1", "WEBGL_compressed_texture_s3tc", "WEBGL_compressed_texture_s3tc_srgb", "WEBGL_debug_renderer_info", "WEBGL_debug_shaders", "WEBGL_lose_context", "WEBGL_multi_draw", "WEBGL_polygon_mode" ];
  // .getSupportedExtensions() can return null if context is lost, so coerce to empty array.
  return ctx.getSupportedExtensions()?.filter(ext => supportedExtensions.includes(ext)) ?? [];
};

var registerPreMainLoop = f => {
  // Does nothing unless $MainLoop is included/used.
  typeof MainLoop != "undefined" && MainLoop.preMainLoop.push(f);
};

var webglBufferSubData = (target, offset, size, data, src = HEAPU8) => {
  GLctx.bufferSubData(target, offset, src.subarray(data, data + size));
};

var GL = {
  counter: 1,
  buffers: [],
  mappedBuffers: {},
  programs: [],
  framebuffers: [],
  renderbuffers: [],
  textures: [],
  shaders: [],
  vaos: [],
  contexts: [],
  offscreenCanvases: {},
  queries: [],
  samplers: [],
  transformFeedbacks: [],
  syncs: [],
  byteSizeByTypeRoot: 5120,
  byteSizeByType: [ 1, 1, 2, 2, 4, 4, 4, 2, 3, 4, 8 ],
  stringCache: {},
  stringiCache: {},
  unpackAlignment: 4,
  unpackRowLength: 0,
  recordError: errorCode => {
    if (!GL.lastError) {
      GL.lastError = errorCode;
    }
  },
  getNewId: table => {
    var ret = GL.counter++;
    for (var i = table.length; i < ret; i++) {
      table[i] = null;
    }
    // Skip over any non-null elements that might have been created by
    // glBindBuffer.
    while (table[ret]) {
      ret = GL.counter++;
    }
    return ret;
  },
  genObject: (n, buffers, createFunction, objectTable) => {
    for (var i = 0; i < n; i++) {
      var buffer = GLctx[createFunction]();
      var id = buffer && GL.getNewId(objectTable);
      if (buffer) {
        buffer.name = id;
        objectTable[id] = buffer;
      } else {
        GL.recordError(1282);
      }
      HEAP32[(((buffers) + (i * 4)) >>> 2) >>> 0] = id;
    }
  },
  MAX_TEMP_BUFFER_SIZE: 2097152,
  numTempVertexBuffersPerSize: 64,
  log2ceilLookup: i => 32 - Math.clz32(i ? i - 1 : 0),
  generateTempBuffers: (quads, context) => {
    var largestIndex = GL.log2ceilLookup(GL.MAX_TEMP_BUFFER_SIZE);
    context.tempVertexBufferCounters1 = [];
    context.tempVertexBufferCounters2 = [];
    context.tempVertexBufferCounters1.length = context.tempVertexBufferCounters2.length = largestIndex + 1;
    context.tempVertexBuffers1 = [];
    context.tempVertexBuffers2 = [];
    context.tempVertexBuffers1.length = context.tempVertexBuffers2.length = largestIndex + 1;
    context.tempIndexBuffers = [];
    context.tempIndexBuffers.length = largestIndex + 1;
    for (var i = 0; i <= largestIndex; ++i) {
      context.tempIndexBuffers[i] = null;
      // Created on-demand
      context.tempVertexBufferCounters1[i] = context.tempVertexBufferCounters2[i] = 0;
      var ringbufferLength = GL.numTempVertexBuffersPerSize;
      context.tempVertexBuffers1[i] = [];
      context.tempVertexBuffers2[i] = [];
      var ringbuffer1 = context.tempVertexBuffers1[i];
      var ringbuffer2 = context.tempVertexBuffers2[i];
      ringbuffer1.length = ringbuffer2.length = ringbufferLength;
      for (var j = 0; j < ringbufferLength; ++j) {
        ringbuffer1[j] = ringbuffer2[j] = null;
      }
    }
    if (quads) {
      // GL_QUAD indexes can be precalculated
      context.tempQuadIndexBuffer = GLctx.createBuffer();
      context.GLctx.bindBuffer(34963, context.tempQuadIndexBuffer);
      var numIndexes = GL.MAX_TEMP_BUFFER_SIZE >> 1;
      var quadIndexes = new Uint16Array(numIndexes);
      var i = 0, v = 0;
      while (1) {
        quadIndexes[i++] = v;
        if (i >= numIndexes) break;
        quadIndexes[i++] = v + 1;
        if (i >= numIndexes) break;
        quadIndexes[i++] = v + 2;
        if (i >= numIndexes) break;
        quadIndexes[i++] = v;
        if (i >= numIndexes) break;
        quadIndexes[i++] = v + 2;
        if (i >= numIndexes) break;
        quadIndexes[i++] = v + 3;
        if (i >= numIndexes) break;
        v += 4;
      }
      context.GLctx.bufferData(34963, quadIndexes, 35044);
      context.GLctx.bindBuffer(34963, null);
    }
  },
  getTempVertexBuffer: sizeBytes => {
    var idx = GL.log2ceilLookup(sizeBytes);
    var ringbuffer = GL.currentContext.tempVertexBuffers1[idx];
    var nextFreeBufferIndex = GL.currentContext.tempVertexBufferCounters1[idx];
    GL.currentContext.tempVertexBufferCounters1[idx] = (GL.currentContext.tempVertexBufferCounters1[idx] + 1) & (GL.numTempVertexBuffersPerSize - 1);
    var vbo = ringbuffer[nextFreeBufferIndex];
    if (vbo) {
      return vbo;
    }
    var prevVBO = GLctx.getParameter(34964);
    ringbuffer[nextFreeBufferIndex] = GLctx.createBuffer();
    GLctx.bindBuffer(34962, ringbuffer[nextFreeBufferIndex]);
    GLctx.bufferData(34962, 1 << idx, 35048);
    GLctx.bindBuffer(34962, prevVBO);
    return ringbuffer[nextFreeBufferIndex];
  },
  getTempIndexBuffer: sizeBytes => {
    var idx = GL.log2ceilLookup(sizeBytes);
    var ibo = GL.currentContext.tempIndexBuffers[idx];
    if (ibo) {
      return ibo;
    }
    var prevIBO = GLctx.getParameter(34965);
    GL.currentContext.tempIndexBuffers[idx] = GLctx.createBuffer();
    GLctx.bindBuffer(34963, GL.currentContext.tempIndexBuffers[idx]);
    GLctx.bufferData(34963, 1 << idx, 35048);
    GLctx.bindBuffer(34963, prevIBO);
    return GL.currentContext.tempIndexBuffers[idx];
  },
  newRenderingFrameStarted: () => {
    if (!GL.currentContext) {
      return;
    }
    var vb = GL.currentContext.tempVertexBuffers1;
    GL.currentContext.tempVertexBuffers1 = GL.currentContext.tempVertexBuffers2;
    GL.currentContext.tempVertexBuffers2 = vb;
    vb = GL.currentContext.tempVertexBufferCounters1;
    GL.currentContext.tempVertexBufferCounters1 = GL.currentContext.tempVertexBufferCounters2;
    GL.currentContext.tempVertexBufferCounters2 = vb;
    var largestIndex = GL.log2ceilLookup(GL.MAX_TEMP_BUFFER_SIZE);
    for (var i = 0; i <= largestIndex; ++i) {
      GL.currentContext.tempVertexBufferCounters1[i] = 0;
    }
  },
  getSource: (shader, count, string, length) => {
    var source = "";
    for (var i = 0; i < count; ++i) {
      var len = length ? HEAPU32[(((length) + (i * 4)) >>> 2) >>> 0] : undefined;
      source += UTF8ToString(HEAPU32[(((string) + (i * 4)) >>> 2) >>> 0], len);
    }
    return source;
  },
  calcBufLength: (size, type, stride, count) => {
    if (stride > 0) {
      return count * stride;
    }
    var typeSize = GL.byteSizeByType[type - GL.byteSizeByTypeRoot];
    return size * typeSize * count;
  },
  usedTempBuffers: [],
  preDrawHandleClientVertexAttribBindings: count => {
    GL.resetBufferBinding = false;
    // TODO: initial pass to detect ranges we need to upload, might not need
    // an upload per attrib
    for (var i = 0; i < GL.currentContext.maxVertexAttribs; ++i) {
      var cb = GL.currentContext.clientBuffers[i];
      if (!cb.clientside || !cb.enabled) continue;
      assert(count || !GLctx.currentElementArrayBufferBinding, "must use array buffers when using element buffer");
      GL.resetBufferBinding = true;
      var size = GL.calcBufLength(cb.size, cb.type, cb.stride, count);
      var buf = GL.getTempVertexBuffer(size);
      GLctx.bindBuffer(34962, buf);
      webglBufferSubData(34962, 0, size, cb.ptr);
      cb.vertexAttribPointerAdaptor.call(GLctx, i, cb.size, cb.type, cb.normalized, cb.stride, 0);
    }
  },
  postDrawHandleClientVertexAttribBindings: () => {
    if (GL.resetBufferBinding) {
      GLctx.bindBuffer(34962, GL.buffers[GLctx.currentArrayBufferBinding]);
    }
  },
  createContext: (/** @type {HTMLCanvasElement} */ canvas, webGLContextAttributes) => {
    // BUG: Workaround Safari WebGL issue: After successfully acquiring WebGL
    // context on a canvas, calling .getContext() will always return that
    // context independent of which 'webgl' or 'webgl2'
    // context version was passed. See:
    //   https://webkit.org/b/222758
    // and:
    //   https://github.com/emscripten-core/emscripten/issues/13295.
    // TODO: Once the bug is fixed and shipped in Safari, adjust the Safari
    // version field in above check.
    if (!canvas.getContextSafariWebGL2Fixed) {
      canvas.getContextSafariWebGL2Fixed = canvas.getContext;
      /** @type {function(this:HTMLCanvasElement, string, (Object|null)=): (Object|null)} */ function fixedGetContext(ver, attrs) {
        var gl = canvas.getContextSafariWebGL2Fixed(ver, attrs);
        return ((ver == "webgl") == (gl instanceof WebGLRenderingContext)) ? gl : null;
      }
      canvas.getContext = fixedGetContext;
    }
    var ctx = canvas.getContext("webgl2", webGLContextAttributes);
    if (!ctx) return 0;
    var handle = GL.registerContext(ctx, webGLContextAttributes);
    return handle;
  },
  registerContext: (ctx, webGLContextAttributes) => {
    // without pthreads a context is just an integer ID
    var handle = GL.getNewId(GL.contexts);
    var context = {
      handle,
      attributes: webGLContextAttributes,
      version: webGLContextAttributes.majorVersion,
      GLctx: ctx
    };
    // Store the created context object so that we can access the context
    // given a canvas without having to pass the parameters again.
    if (ctx.canvas) ctx.canvas.GLctxObject = context;
    GL.contexts[handle] = context;
    if (typeof webGLContextAttributes.enableExtensionsByDefault == "undefined" || webGLContextAttributes.enableExtensionsByDefault) {
      GL.initExtensions(context);
    }
    context.maxVertexAttribs = context.GLctx.getParameter(34921);
    context.clientBuffers = [];
    for (var i = 0; i < context.maxVertexAttribs; i++) {
      context.clientBuffers[i] = {
        enabled: false,
        clientside: false,
        size: 0,
        type: 0,
        normalized: 0,
        stride: 0,
        ptr: 0,
        vertexAttribPointerAdaptor: null
      };
    }
    GL.generateTempBuffers(false, context);
    return handle;
  },
  makeContextCurrent: contextHandle => {
    // Active Emscripten GL layer context object.
    GL.currentContext = GL.contexts[contextHandle];
    // Active WebGL context object.
    Module["ctx"] = GLctx = GL.currentContext?.GLctx;
    return !(contextHandle && !GLctx);
  },
  getContext: contextHandle => GL.contexts[contextHandle],
  deleteContext: contextHandle => {
    if (GL.currentContext === GL.contexts[contextHandle]) {
      GL.currentContext = null;
    }
    if (typeof JSEvents == "object") {
      // Release all JS event handlers on the DOM element that the GL context is
      // associated with since the context is now deleted.
      JSEvents.removeAllHandlersOnTarget(GL.contexts[contextHandle].GLctx.canvas);
    }
    // Make sure the canvas object no longer refers to the context object so
    // there are no GC surprises.
    if (GL.contexts[contextHandle]?.GLctx.canvas) {
      GL.contexts[contextHandle].GLctx.canvas.GLctxObject = undefined;
    }
    GL.contexts[contextHandle] = null;
  },
  initExtensions: context => {
    // If this function is called without a specific context object, init the
    // extensions of the currently active context.
    context ||= GL.currentContext;
    if (context.initExtensionsDone) return;
    context.initExtensionsDone = true;
    var GLctx = context.GLctx;
    // Detect the presence of a few extensions manually, since the GL interop
    // layer itself will need to know if they exist.
    // Extensions that are available in both WebGL 1 and WebGL 2
    webgl_enable_WEBGL_multi_draw(GLctx);
    webgl_enable_EXT_polygon_offset_clamp(GLctx);
    webgl_enable_EXT_clip_control(GLctx);
    webgl_enable_WEBGL_polygon_mode(GLctx);
    // Extensions that are available from WebGL >= 2 (no-op if called on a WebGL 1 context active)
    webgl_enable_WEBGL_draw_instanced_base_vertex_base_instance(GLctx);
    webgl_enable_WEBGL_multi_draw_instanced_base_vertex_base_instance(GLctx);
    // On WebGL 2, EXT_disjoint_timer_query is replaced with an alternative
    // that's based on core APIs, and exposes only the queryCounterEXT()
    // entrypoint.
    if (context.version >= 2) {
      GLctx.disjointTimerQueryExt = GLctx.getExtension("EXT_disjoint_timer_query_webgl2");
    }
    // However, Firefox exposes the WebGL 1 version on WebGL 2 as well and
    // thus we look for the WebGL 1 version again if the WebGL 2 version
    // isn't present. https://bugzil.la/1328882
    if (context.version < 2 || !GLctx.disjointTimerQueryExt) {
      GLctx.disjointTimerQueryExt = GLctx.getExtension("EXT_disjoint_timer_query");
    }
    for (var ext of getEmscriptenSupportedExtensions(GLctx)) {
      // WEBGL_lose_context, WEBGL_debug_renderer_info and WEBGL_debug_shaders
      // are not enabled by default.
      if (!ext.includes("lose_context") && !ext.includes("debug")) {
        // Call .getExtension() to enable that extension permanently.
        GLctx.getExtension(ext);
      }
    }
  }
};

function _eglCreateContext(display, config, hmm, contextAttribs) {
  display >>>= 0;
  config >>>= 0;
  hmm >>>= 0;
  contextAttribs >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  // EGL 1.4 spec says default EGL_CONTEXT_CLIENT_VERSION is GLES1, but this is not supported by Emscripten.
  // So user must pass EGL_CONTEXT_CLIENT_VERSION == 2 to initialize EGL.
  var glesContextVersion = 1;
  for (;;) {
    var param = HEAP32[((contextAttribs) >>> 2) >>> 0];
    if (param == 12440) {
      glesContextVersion = HEAP32[(((contextAttribs) + (4)) >>> 2) >>> 0];
    } else if (param == 12344) {
      break;
    } else {
      /* EGL1.4 specifies only EGL_CONTEXT_CLIENT_VERSION as supported attribute */ EGL.setErrorCode(12292);
      return 0;
    }
    contextAttribs += 8;
  }
  if (glesContextVersion < 2 || glesContextVersion > 3) {
    EGL.setErrorCode(12293);
    return 0;
  }
  EGL.contextAttributes.majorVersion = glesContextVersion - 1;
  // WebGL 1 is GLES 2, WebGL2 is GLES3
  EGL.contextAttributes.minorVersion = 0;
  EGL.context = GL.createContext(Browser.getCanvas(), EGL.contextAttributes);
  if (EGL.context != 0) {
    EGL.setErrorCode(12288);
    // Run callbacks so that GL emulation works
    GL.makeContextCurrent(EGL.context);
    Browser.useWebGL = true;
    Browser.moduleContextCreatedCallbacks.forEach(callback => callback());
    // Note: This function only creates a context, but it shall not make it active.
    GL.makeContextCurrent(null);
    return 62004;
  } else {
    EGL.setErrorCode(12297);
    // By the EGL 1.4 spec, an implementation that does not support GLES2 (WebGL in this case), this error code is set.
    return 0;
  }
}

function _eglCreateWindowSurface(display, config, win, attrib_list) {
  display >>>= 0;
  config >>>= 0;
  attrib_list >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  if (config != 62002) {
    EGL.setErrorCode(12293);
    return 0;
  }
  // TODO: Examine attrib_list! Parameters that can be present there are:
  // - EGL_RENDER_BUFFER (must be EGL_BACK_BUFFER)
  // - EGL_VG_COLORSPACE (can't be set)
  // - EGL_VG_ALPHA_FORMAT (can't be set)
  EGL.setErrorCode(12288);
  return 62006;
}

function _eglDestroyContext(display, context) {
  display >>>= 0;
  context >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  if (context != 62004) {
    EGL.setErrorCode(12294);
    return 0;
  }
  GL.deleteContext(EGL.context);
  EGL.setErrorCode(12288);
  if (EGL.currentContext == context) {
    EGL.currentContext = 0;
  }
  return 1;
}

function _eglDestroySurface(display, surface) {
  display >>>= 0;
  surface >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  if (surface != 62006) {
    EGL.setErrorCode(12301);
    return 1;
  }
  if (EGL.currentReadSurface == surface) {
    EGL.currentReadSurface = 0;
  }
  if (EGL.currentDrawSurface == surface) {
    EGL.currentDrawSurface = 0;
  }
  EGL.setErrorCode(12288);
  return 1;
}

function _eglGetConfigAttrib(display, config, attribute, value) {
  display >>>= 0;
  config >>>= 0;
  value >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  if (config != 62002) {
    EGL.setErrorCode(12293);
    return 0;
  }
  if (!value) {
    EGL.setErrorCode(12300);
    return 0;
  }
  EGL.setErrorCode(12288);
  switch (attribute) {
   case 12320:
    // EGL_BUFFER_SIZE
    HEAP32[((value) >>> 2) >>> 0] = EGL.contextAttributes.alpha ? 32 : 24;
    return 1;

   case 12321:
    // EGL_ALPHA_SIZE
    HEAP32[((value) >>> 2) >>> 0] = EGL.contextAttributes.alpha ? 8 : 0;
    return 1;

   case 12322:
    // EGL_BLUE_SIZE
    HEAP32[((value) >>> 2) >>> 0] = 8;
    return 1;

   case 12323:
    // EGL_GREEN_SIZE
    HEAP32[((value) >>> 2) >>> 0] = 8;
    return 1;

   case 12324:
    // EGL_RED_SIZE
    HEAP32[((value) >>> 2) >>> 0] = 8;
    return 1;

   case 12325:
    // EGL_DEPTH_SIZE
    HEAP32[((value) >>> 2) >>> 0] = EGL.contextAttributes.depth ? 24 : 0;
    return 1;

   case 12326:
    // EGL_STENCIL_SIZE
    HEAP32[((value) >>> 2) >>> 0] = EGL.contextAttributes.stencil ? 8 : 0;
    return 1;

   case 12327:
    // EGL_CONFIG_CAVEAT
    // We can return here one of EGL_NONE (0x3038), EGL_SLOW_CONFIG (0x3050) or EGL_NON_CONFORMANT_CONFIG (0x3051).
    HEAP32[((value) >>> 2) >>> 0] = 12344;
    return 1;

   case 12328:
    // EGL_CONFIG_ID
    HEAP32[((value) >>> 2) >>> 0] = 62002;
    return 1;

   case 12329:
    // EGL_LEVEL
    HEAP32[((value) >>> 2) >>> 0] = 0;
    return 1;

   case 12330:
    // EGL_MAX_PBUFFER_HEIGHT
    HEAP32[((value) >>> 2) >>> 0] = 4096;
    return 1;

   case 12331:
    // EGL_MAX_PBUFFER_PIXELS
    HEAP32[((value) >>> 2) >>> 0] = 16777216;
    return 1;

   case 12332:
    // EGL_MAX_PBUFFER_WIDTH
    HEAP32[((value) >>> 2) >>> 0] = 4096;
    return 1;

   case 12333:
    // EGL_NATIVE_RENDERABLE
    HEAP32[((value) >>> 2) >>> 0] = 0;
    return 1;

   case 12334:
    // EGL_NATIVE_VISUAL_ID
    HEAP32[((value) >>> 2) >>> 0] = 0;
    return 1;

   case 12335:
    // EGL_NATIVE_VISUAL_TYPE
    HEAP32[((value) >>> 2) >>> 0] = 12344;
    return 1;

   case 12337:
    // EGL_SAMPLES
    HEAP32[((value) >>> 2) >>> 0] = EGL.contextAttributes.antialias ? 4 : 0;
    return 1;

   case 12338:
    // EGL_SAMPLE_BUFFERS
    HEAP32[((value) >>> 2) >>> 0] = EGL.contextAttributes.antialias ? 1 : 0;
    return 1;

   case 12339:
    // EGL_SURFACE_TYPE
    HEAP32[((value) >>> 2) >>> 0] = 4;
    return 1;

   case 12340:
    // EGL_TRANSPARENT_TYPE
    // If this returns EGL_TRANSPARENT_RGB (0x3052), transparency is used through color-keying. No such thing applies to Emscripten canvas.
    HEAP32[((value) >>> 2) >>> 0] = 12344;
    return 1;

   case 12341:
   // EGL_TRANSPARENT_BLUE_VALUE
    case 12342:
   // EGL_TRANSPARENT_GREEN_VALUE
    case 12343:
    // EGL_TRANSPARENT_RED_VALUE
    // "If EGL_TRANSPARENT_TYPE is EGL_NONE, then the values for EGL_TRANSPARENT_RED_VALUE, EGL_TRANSPARENT_GREEN_VALUE, and EGL_TRANSPARENT_BLUE_VALUE are undefined."
    HEAP32[((value) >>> 2) >>> 0] = -1;
    return 1;

   case 12345:
   // EGL_BIND_TO_TEXTURE_RGB
    case 12346:
    // EGL_BIND_TO_TEXTURE_RGBA
    HEAP32[((value) >>> 2) >>> 0] = 0;
    return 1;

   case 12347:
    // EGL_MIN_SWAP_INTERVAL
    HEAP32[((value) >>> 2) >>> 0] = 0;
    return 1;

   case 12348:
    // EGL_MAX_SWAP_INTERVAL
    HEAP32[((value) >>> 2) >>> 0] = 1;
    return 1;

   case 12349:
   // EGL_LUMINANCE_SIZE
    case 12350:
    // EGL_ALPHA_MASK_SIZE
    HEAP32[((value) >>> 2) >>> 0] = 0;
    return 1;

   case 12351:
    // EGL_COLOR_BUFFER_TYPE
    // EGL has two types of buffers: EGL_RGB_BUFFER and EGL_LUMINANCE_BUFFER.
    HEAP32[((value) >>> 2) >>> 0] = 12430;
    return 1;

   case 12352:
    // EGL_RENDERABLE_TYPE
    // A bit combination of EGL_OPENGL_ES_BIT,EGL_OPENVG_BIT,EGL_OPENGL_ES2_BIT and EGL_OPENGL_BIT.
    HEAP32[((value) >>> 2) >>> 0] = 4;
    return 1;

   case 12354:
    // EGL_CONFORMANT
    // "EGL_CONFORMANT is a mask indicating if a client API context created with respect to the corresponding EGLConfig will pass the required conformance tests for that API."
    HEAP32[((value) >>> 2) >>> 0] = 0;
    return 1;

   default:
    EGL.setErrorCode(12292);
    return 0;
  }
}

function _eglGetDisplay(nativeDisplayType) {
  nativeDisplayType >>>= 0;
  EGL.setErrorCode(12288);
  // Emscripten EGL implementation "emulates" X11, and eglGetDisplay is
  // expected to accept/receive a pointer to an X11 Display object (or
  // EGL_DEFAULT_DISPLAY).
  if (nativeDisplayType != 0 && nativeDisplayType != 1) {
    return 0;
  }
  return 62e3;
}

var _eglGetError = () => EGL.errorCode;

function _eglInitialize(display, majorVersion, minorVersion) {
  display >>>= 0;
  majorVersion >>>= 0;
  minorVersion >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  if (majorVersion) {
    HEAP32[((majorVersion) >>> 2) >>> 0] = 1;
  }
  if (minorVersion) {
    HEAP32[((minorVersion) >>> 2) >>> 0] = 4;
  }
  EGL.defaultDisplayInitialized = true;
  EGL.setErrorCode(12288);
  return 1;
}

function _eglMakeCurrent(display, draw, read, context) {
  display >>>= 0;
  draw >>>= 0;
  read >>>= 0;
  context >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  //\todo An EGL_NOT_INITIALIZED error is generated if EGL is not initialized for dpy.
  if (context != 0 && context != 62004) {
    EGL.setErrorCode(12294);
    return 0;
  }
  if ((read != 0 && read != 62006) || (draw != 0 && draw != 62006)) {
    EGL.setErrorCode(12301);
    return 0;
  }
  GL.makeContextCurrent(context ? EGL.context : null);
  EGL.currentContext = context;
  EGL.currentDrawSurface = draw;
  EGL.currentReadSurface = read;
  EGL.setErrorCode(12288);
  return 1;
}

var stringToNewUTF8 = str => {
  var size = lengthBytesUTF8(str) + 1;
  var ret = _malloc(size);
  if (ret) stringToUTF8(str, ret, size);
  return ret;
};

function _eglQueryString(display, name) {
  display >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  //\todo An EGL_NOT_INITIALIZED error is generated if EGL is not initialized for dpy.
  EGL.setErrorCode(12288);
  if (EGL.stringCache[name]) return EGL.stringCache[name];
  var ret;
  switch (name) {
   case 12371:
    ret = stringToNewUTF8("Emscripten");
    break;

   case 12372:
    ret = stringToNewUTF8("1.4 Emscripten EGL");
    break;

   case 12373:
    ret = stringToNewUTF8("");
    break;

   // Currently not supporting any EGL extensions.
    case 12429:
    ret = stringToNewUTF8("OpenGL_ES");
    break;

   default:
    EGL.setErrorCode(12300);
    return 0;
  }
  EGL.stringCache[name] = ret;
  return ret;
}

function _eglSwapBuffers(dpy, surface) {
  dpy >>>= 0;
  surface >>>= 0;
  if (!EGL.defaultDisplayInitialized) {
    EGL.setErrorCode(12289);
  } else if (!GLctx) {
    EGL.setErrorCode(12290);
  } else if (GLctx.isContextLost()) {
    EGL.setErrorCode(12302);
  } else {
    // According to documentation this does an implicit flush.
    // Due to discussion at https://github.com/emscripten-core/emscripten/pull/1871
    // the flush was removed since this _may_ result in slowing code down.
    //_glFlush();
    EGL.setErrorCode(12288);
    return 1;
  }
  return 0;
}

/**
   * @param {number=} arg
   * @param {boolean=} noSetTiming
   */ var setMainLoop = (iterFunc, fps, simulateInfiniteLoop, arg, noSetTiming) => {
  assert(!MainLoop.func, "emscripten_set_main_loop: there can only be one main loop function at once");
  MainLoop.func = iterFunc;
  MainLoop.arg = arg;
  var thisMainLoopId = MainLoop.currentlyRunningMainloop;
  function checkIsRunning() {
    if (thisMainLoopId < MainLoop.currentlyRunningMainloop) {
      maybeExit();
      return false;
    }
    return true;
  }
  // We create the loop runner here but it is not actually running until
  // _emscripten_set_main_loop_timing is called (which might happen at a
  // later time).
  MainLoop.runner = function MainLoop_runner() {
    if (ABORT) return;
    if (MainLoop.queue.length > 0) {
      var start = Date.now();
      var blocker = MainLoop.queue.shift();
      blocker.func(blocker.arg);
      if (MainLoop.remainingBlockers) {
        var remaining = MainLoop.remainingBlockers;
        var next = remaining % 1 == 0 ? remaining - 1 : Math.floor(remaining);
        if (blocker.counted) {
          MainLoop.remainingBlockers = next;
        } else {
          // not counted, but move the progress along a tiny bit
          next = next + .5;
          // do not steal all the next one's progress
          MainLoop.remainingBlockers = (8 * remaining + next) / 9;
        }
      }
      MainLoop.updateStatus();
      // catches pause/resume main loop from blocker execution
      if (!checkIsRunning()) return;
      setTimeout(MainLoop.runner, 0);
      return;
    }
    // catch pauses from non-main loop sources
    if (!checkIsRunning()) return;
    // Implement very basic swap interval control
    MainLoop.currentFrameNumber = MainLoop.currentFrameNumber + 1 | 0;
    if (MainLoop.timingMode == 1 && MainLoop.timingValue > 1 && MainLoop.currentFrameNumber % MainLoop.timingValue != 0) {
      // Not the scheduled time to render this frame - skip.
      MainLoop.scheduler();
      return;
    } else if (MainLoop.timingMode == 0) {
      MainLoop.tickStartTime = _emscripten_get_now();
      if (Module["ctx"]) {
        warnOnce("Looks like you are rendering without using requestAnimationFrame for the main loop. You should use 0 for the frame rate in emscripten_set_main_loop in order to use requestAnimationFrame, as that can greatly improve your frame rates!");
      }
    }
    MainLoop.runIter(iterFunc);
    // catch pauses from the main loop itself
    if (!checkIsRunning()) return;
    MainLoop.scheduler();
  };
  if (!noSetTiming) {
    if (fps > 0) {
      _emscripten_set_main_loop_timing(0, 1e3 / fps);
    } else {
      // Do rAF by rendering each frame (no decimating)
      _emscripten_set_main_loop_timing(1, 1);
    }
    MainLoop.scheduler();
  }
  if (simulateInfiniteLoop) {
    throw "unwind";
  }
};

var MainLoop = {
  func: null,
  scheduler: null,
  currentlyRunningMainloop: 0,
  arg: 0,
  timingMode: 0,
  timingValue: 0,
  currentFrameNumber: 0,
  queue: [],
  preMainLoop: [],
  postMainLoop: [],
  pause() {
    if (MainLoop.scheduler) {
      MainLoop.scheduler = null;
      // Incrementing this signals the previous main loop that it's now become old, and it must return.
      MainLoop.currentlyRunningMainloop++;
    }
  },
  resume() {
    MainLoop.currentlyRunningMainloop++;
    var timingMode = MainLoop.timingMode;
    var timingValue = MainLoop.timingValue;
    var func = MainLoop.func;
    MainLoop.func = null;
    // do not set timing and call scheduler, we will do it on the next lines
    setMainLoop(func, 0, false, MainLoop.arg, true);
    _emscripten_set_main_loop_timing(timingMode, timingValue);
    MainLoop.scheduler();
  },
  updateStatus() {},
  init() {},
  runIter(func) {
    if (ABORT) return;
    for (var pre of MainLoop.preMainLoop) {
      if (pre() === false) {
        return;
      }
    }
    callUserCallback(func);
    for (var post of MainLoop.postMainLoop) {
      post();
    }
    checkStackCookie();
  },
  nextRAF: 0,
  fakeRequestAnimationFrame(func) {
    // try to keep 60fps between calls to here
    var now = Date.now();
    if (!MainLoop.nextRAF) {
      MainLoop.nextRAF = now + 1e3 / 60;
    } else {
      while (now + 2 >= MainLoop.nextRAF) {
        // fudge a little, to avoid timer jitter causing us to do lots of delay:0
        MainLoop.nextRAF += 1e3 / 60;
      }
    }
    var delay = Math.max(MainLoop.nextRAF - now, 0);
    setTimeout(func, delay);
  },
  requestAnimationFrame(func) {
    if (globalThis.requestAnimationFrame) {
      requestAnimationFrame(func);
    } else {
      MainLoop.fakeRequestAnimationFrame(func);
    }
  }
};

var _emscripten_set_main_loop_timing = (mode, value) => {
  MainLoop.timingMode = mode;
  MainLoop.timingValue = value;
  if (!MainLoop.func) {
    err("emscripten_set_main_loop_timing: Cannot set timing mode for main loop since a main loop does not exist! Call emscripten_set_main_loop first to set one up.");
    return 1;
  }
  if (mode == 0) {
    MainLoop.scheduler = function MainLoop_scheduler_setTimeout() {
      var timeUntilNextTick = Math.max(0, MainLoop.tickStartTime + value - _emscripten_get_now()) | 0;
      setTimeout(MainLoop.runner, timeUntilNextTick);
    };
  } else if (mode == 1) {
    MainLoop.scheduler = function MainLoop_scheduler_rAF() {
      MainLoop.requestAnimationFrame(MainLoop.runner);
    };
  } else {
    assert(mode == 2);
    if (!MainLoop.setImmediate) {
      if (globalThis.scheduler) {
        // Some modern browsers implement scheduler.postTask, but not all.
        MainLoop.setImmediate = scheduler.postTask.bind(scheduler);
      } else if (globalThis.setImmediate) {
        MainLoop.setImmediate = setImmediate;
      } else {
        // Emulate setImmediate. (note: not a complete polyfill, we don't emulate clearImmediate() to keep code size to minimum, since not needed)
        var setImmediates = [];
        var emscriptenMainLoopMessageId = "setimmediate";
        /** @param {Event} event */ var MainLoop_setImmediate_messageHandler = event => {
          if (event.data === emscriptenMainLoopMessageId) {
            event.stopPropagation();
            setImmediates.shift()();
          }
        };
        addEventListener("message", MainLoop_setImmediate_messageHandler, true);
        MainLoop.setImmediate = /** @type{function(function(): ?, ...?): number} */ (func => {
          setImmediates.push(func);
          if (ENVIRONMENT_IS_WORKER) {
            // The postMessge API in a Worker, sends message to the main
            // thread and does not support the `targetOrigin` (*) argument.
            postMessage(emscriptenMainLoopMessageId);
          } else {
            postMessage(emscriptenMainLoopMessageId, "*");
          }
        });
      }
    }
    MainLoop.scheduler = function MainLoop_scheduler_setImmediate() {
      MainLoop.setImmediate(MainLoop.runner);
    };
  }
  return 0;
};

function _eglSwapInterval(display, interval) {
  display >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  if (interval == 0) _emscripten_set_main_loop_timing(0, 0); else _emscripten_set_main_loop_timing(1, interval);
  EGL.setErrorCode(12288);
  return 1;
}

function _eglTerminate(display) {
  display >>>= 0;
  if (display != 62e3) {
    EGL.setErrorCode(12296);
    return 0;
  }
  EGL.currentContext = 0;
  EGL.currentReadSurface = 0;
  EGL.currentDrawSurface = 0;
  EGL.defaultDisplayInitialized = false;
  EGL.setErrorCode(12288);
  return 1;
}

var _eglWaitClient = () => {
  EGL.setErrorCode(12288);
  return 1;
};

var _eglWaitGL = _eglWaitClient;

var _eglWaitNative = nativeEngineId => {
  EGL.setErrorCode(12288);
  return 1;
};

var readEmAsmArgsArray = [];

/** @type {!Float64Array} */ var HEAPF64;

var readEmAsmArgs = (sigPtr, buf) => {
  // Nobody should have mutated _readEmAsmArgsArray underneath us to be something else than an array.
  assert(Array.isArray(readEmAsmArgsArray));
  // The input buffer is allocated on the stack, so it must be stack-aligned.
  assert(buf % 16 == 0);
  readEmAsmArgsArray.length = 0;
  var ch;
  // Most arguments are i32s, so shift the buffer pointer so it is a plain
  // index into HEAP32.
  while (ch = HEAPU8[sigPtr++ >>> 0]) {
    var chr = String.fromCharCode(ch);
    var validChars = [ "d", "f", "i", "p" ];
    // In WASM_BIGINT mode we support passing i64 values as bigint.
    validChars.push("j");
    assert(validChars.includes(chr), `Invalid character ${ch}("${chr}") in readEmAsmArgs! Use only [${validChars}], and do not specify "v" for void return argument.`);
    // Floats are always passed as doubles, so all types except for 'i'
    // are 8 bytes and require alignment.
    var wide = (ch != 105);
    wide &= (ch != 112);
    buf += wide && (buf % 8) ? 4 : 0;
    readEmAsmArgsArray.push(// Special case for pointers under wasm64 or CAN_ADDRESS_2GB mode.
    ch == 112 ? HEAPU32[((buf) >>> 2) >>> 0] : ch == 106 ? HEAP64[((buf) >>> 3) >>> 0] : ch == 105 ? HEAP32[((buf) >>> 2) >>> 0] : HEAPF64[((buf) >>> 3) >>> 0]);
    buf += wide ? 8 : 4;
  }
  return readEmAsmArgsArray;
};

var runEmAsmFunction = (code, sigPtr, argbuf) => {
  var args = readEmAsmArgs(sigPtr, argbuf);
  assert(ASM_CONSTS.hasOwnProperty(code), `No EM_ASM constant found at address ${code}.  The loaded WebAssembly file is likely out of sync with the generated JavaScript.`);
  return ASM_CONSTS[code](...args);
};

function _emscripten_asm_const_int(code, sigPtr, argbuf) {
  code >>>= 0;
  sigPtr >>>= 0;
  argbuf >>>= 0;
  return runEmAsmFunction(code, sigPtr, argbuf);
}

var runMainThreadEmAsm = (emAsmAddr, sigPtr, argbuf, sync) => {
  var args = readEmAsmArgs(sigPtr, argbuf);
  assert(ASM_CONSTS.hasOwnProperty(emAsmAddr), `No EM_ASM constant found at address ${emAsmAddr}.  The loaded WebAssembly file is likely out of sync with the generated JavaScript.`);
  return ASM_CONSTS[emAsmAddr](...args);
};

function _emscripten_asm_const_int_sync_on_main_thread(emAsmAddr, sigPtr, argbuf) {
  emAsmAddr >>>= 0;
  sigPtr >>>= 0;
  argbuf >>>= 0;
  return runMainThreadEmAsm(emAsmAddr, sigPtr, argbuf, 1);
}

function _emscripten_asm_const_ptr_sync_on_main_thread(emAsmAddr, sigPtr, argbuf) {
  emAsmAddr >>>= 0;
  sigPtr >>>= 0;
  argbuf >>>= 0;
  return runMainThreadEmAsm(emAsmAddr, sigPtr, argbuf, 1);
}

var _emscripten_cancel_main_loop = () => {
  MainLoop.pause();
  MainLoop.func = null;
};

function _emscripten_err(str) {
  str >>>= 0;
  return err(UTF8ToString(str));
}

var onExits = [];

var addOnExit = cb => onExits.push(cb);

var JSEvents = {
  removeAllEventListeners() {
    while (JSEvents.eventHandlers.length) {
      JSEvents._removeHandler(JSEvents.eventHandlers.length - 1);
    }
    JSEvents.deferredCalls = [];
  },
  inEventHandler: 0,
  deferredCalls: [],
  deferCall(targetFunction, precedence, argsList) {
    function arraysHaveEqualContent(arrA, arrB) {
      if (arrA.length != arrB.length) return false;
      for (var i = 0; i < arrA.length; i++) {
        if (arrA[i] != arrB[i]) return false;
      }
      return true;
    }
    // Test if the given call was already queued, and if so, don't add it again.
    for (var call of JSEvents.deferredCalls) {
      if (call.targetFunction == targetFunction && arraysHaveEqualContent(call.argsList, argsList)) {
        return;
      }
    }
    JSEvents.deferredCalls.push({
      targetFunction,
      precedence,
      argsList
    });
    JSEvents.deferredCalls.sort((x, y) => x.precedence - y.precedence);
  },
  removeDeferredCalls(targetFunction) {
    JSEvents.deferredCalls = JSEvents.deferredCalls.filter(call => call.targetFunction != targetFunction);
  },
  canPerformEventHandlerRequests() {
    // Browsers that support navigator.userActivation.isActive: https://developer.mozilla.org/en-US/docs/Web/API/UserActivation/isActive
    if (navigator.userActivation) {
      // Verify against transient activation status from UserActivation API
      // whether it is possible to perform a request here without needing to defer. See
      // https://developer.mozilla.org/en-US/docs/Web/Security/User_activation#transient_activation
      // and https://caniuse.com/mdn-api_useractivation
      return navigator.userActivation.isActive;
    }
    return JSEvents.inEventHandler && JSEvents.currentEventHandler.allowsDeferredCalls;
  },
  runDeferredCalls() {
    if (!JSEvents.canPerformEventHandlerRequests()) {
      return;
    }
    var deferredCalls = JSEvents.deferredCalls;
    JSEvents.deferredCalls = [];
    for (var call of deferredCalls) {
      call.targetFunction(...call.argsList);
    }
  },
  eventHandlers: [],
  removeAllHandlersOnTarget: (target, eventTypeString) => {
    for (var i = 0; i < JSEvents.eventHandlers.length; ++i) {
      if (JSEvents.eventHandlers[i].target == target && (!eventTypeString || eventTypeString == JSEvents.eventHandlers[i].eventTypeString)) {
        JSEvents._removeHandler(i--);
      }
    }
  },
  _removeHandler(i) {
    var h = JSEvents.eventHandlers[i];
    h.target.removeEventListener(h.eventTypeString, h.eventListenerFunc, h.useCapture);
    JSEvents.eventHandlers.splice(i, 1);
  },
  registerOrRemoveHandler(eventHandler) {
    if (!eventHandler.target) {
      err("registerOrRemoveHandler: the target element for event handler registration does not exist, when processing the following event handler registration:");
      console.dir(eventHandler);
      return -4;
    }
    if (eventHandler.callbackfunc) {
      eventHandler.eventListenerFunc = function(event) {
        // Increment nesting count for the event handler.
        ++JSEvents.inEventHandler;
        JSEvents.currentEventHandler = eventHandler;
        // Process any old deferred calls the user has placed.
        JSEvents.runDeferredCalls();
        // Process the actual event, calls back to user C code handler.
        eventHandler.handlerFunc(event);
        // Process any new deferred calls that were placed right now from this event handler.
        JSEvents.runDeferredCalls();
        // Out of event handler - restore nesting count.
        --JSEvents.inEventHandler;
      };
      eventHandler.target.addEventListener(eventHandler.eventTypeString, eventHandler.eventListenerFunc, eventHandler.useCapture);
      JSEvents.eventHandlers.push(eventHandler);
    } else {
      for (var i = 0; i < JSEvents.eventHandlers.length; ++i) {
        if (JSEvents.eventHandlers[i].target == eventHandler.target && JSEvents.eventHandlers[i].eventTypeString == eventHandler.eventTypeString) {
          JSEvents._removeHandler(i--);
        }
      }
    }
    return 0;
  },
  removeSingleHandler(eventHandler) {
    let success = false;
    for (let i = 0; i < JSEvents.eventHandlers.length; ++i) {
      const handler = JSEvents.eventHandlers[i];
      if (handler.target === eventHandler.target && handler.eventTypeId === eventHandler.eventTypeId && handler.callbackfunc === eventHandler.callbackfunc && handler.userData === eventHandler.userData) {
        // in some very rare cases (ex: Safari / fullscreen events), there is more than 1 handler (eventTypeString is different)
        JSEvents._removeHandler(i--);
        success = true;
      }
    }
    return success ? 0 : -5;
  },
  getNodeNameForTarget(target) {
    if (target == window) return "#window";
    if (target == screen) return "#screen";
    return target?.nodeName ?? "";
  },
  fullscreenEnabled() {
    return document.fullscreenEnabled ?? document.webkitFullscreenEnabled;
  }
};

/** @type {Object} */ var specialHTMLTargets = [ 0, globalThis.document ?? 0, globalThis.window ?? 0 ];

var maybeCStringToJsString = cString => cString > 2 ? UTF8ToString(cString) : cString;

var findEventTarget = target => {
  target = maybeCStringToJsString(target);
  var domElement = specialHTMLTargets[target] || globalThis.document?.querySelector(target);
  return domElement;
};

var findCanvasEventTarget = findEventTarget;

function _emscripten_get_canvas_element_size(target, width, height) {
  target >>>= 0;
  width >>>= 0;
  height >>>= 0;
  var canvas = findCanvasEventTarget(target);
  if (!canvas) return -4;
  HEAP32[((width) >>> 2) >>> 0] = canvas.width;
  HEAP32[((height) >>> 2) >>> 0] = canvas.height;
}

var stackAlloc = sz => __emscripten_stack_alloc(sz);

var stringToUTF8OnStack = str => {
  var size = lengthBytesUTF8(str) + 1;
  var ret = stackAlloc(size);
  stringToUTF8(str, ret, size);
  return ret;
};

var getCanvasElementSize = target => {
  var sp = stackSave();
  var w = stackAlloc(8);
  var h = w + 4;
  var targetInt = stringToUTF8OnStack(target.id);
  var ret = _emscripten_get_canvas_element_size(targetInt, w, h);
  var size = [ HEAP32[((w) >>> 2) >>> 0], HEAP32[((h) >>> 2) >>> 0] ];
  stackRestore(sp);
  return size;
};

function _emscripten_set_canvas_element_size(target, width, height) {
  target >>>= 0;
  var canvas = findCanvasEventTarget(target);
  if (!canvas) return -4;
  canvas.width = width;
  canvas.height = height;
  return 0;
}

var setCanvasElementSize = (target, width, height) => {
  if (!target.controlTransferredOffscreen) {
    target.width = width;
    target.height = height;
  } else {
    // This function is being called from high-level JavaScript code instead of asm.js/Wasm,
    // and it needs to synchronously proxy over to another thread, so marshal the string onto the heap to do the call.
    var sp = stackSave();
    var targetInt = stringToUTF8OnStack(target.id);
    _emscripten_set_canvas_element_size(targetInt, width, height);
    stackRestore(sp);
  }
};

var currentFullscreenStrategy = 0;

var wasmTableMirror = [];

var getWasmTableEntry = funcPtr => {
  var func = wasmTableMirror[funcPtr];
  if (!func) {
    /** @suppress {checkTypes} */ wasmTableMirror[funcPtr] = func = wasmTable.get(funcPtr);
  }
  /** @suppress {checkTypes} */ assert(wasmTable.get(funcPtr) == func, "table mirror is out of date");
  return func;
};

var callCanvasResizedCallback = strategy => {
  if (strategy.canvasResizedCallback) {
    getWasmTableEntry(strategy.canvasResizedCallback)(37, 0, strategy.canvasResizedCallbackUserData);
  }
};

var registerRestoreOldStyle = canvas => {
  var canvasSize = getCanvasElementSize(canvas);
  var oldWidth = canvasSize[0];
  var oldHeight = canvasSize[1];
  var oldCssWidth = canvas.style.width;
  var oldCssHeight = canvas.style.height;
  var oldBackgroundColor = canvas.style.backgroundColor;
  // Chrome reads color from here.
  var oldDocumentBackgroundColor = document.body.style.backgroundColor;
  // IE11 reads color from here.
  // Firefox always has black background color.
  var oldPaddingLeft = canvas.style.paddingLeft;
  // Chrome, FF, Safari
  var oldPaddingRight = canvas.style.paddingRight;
  var oldPaddingTop = canvas.style.paddingTop;
  var oldPaddingBottom = canvas.style.paddingBottom;
  var oldMarginLeft = canvas.style.marginLeft;
  // IE11
  var oldMarginRight = canvas.style.marginRight;
  var oldMarginTop = canvas.style.marginTop;
  var oldMarginBottom = canvas.style.marginBottom;
  var oldDocumentBodyMargin = document.body.style.margin;
  var oldDocumentOverflow = document.documentElement.style.overflow;
  // Chrome, Firefox
  var oldDocumentScroll = document.body.scroll;
  // IE
  var oldImageRendering = canvas.style.imageRendering;
  function restoreOldStyle() {
    if (!getFullscreenElement()) {
      document.removeEventListener("fullscreenchange", restoreOldStyle);
      document.removeEventListener("webkitfullscreenchange", restoreOldStyle);
      setCanvasElementSize(canvas, oldWidth, oldHeight);
      canvas.style.width = oldCssWidth;
      canvas.style.height = oldCssHeight;
      canvas.style.backgroundColor = oldBackgroundColor;
      // Chrome
      // IE11 hack: assigning 'undefined' or an empty string to document.body.style.backgroundColor has no effect, so first assign back the default color
      // before setting the undefined value. Setting undefined value is also important, or otherwise we would later treat that as something that the user
      // had explicitly set so subsequent fullscreen transitions would not set background color properly.
      if (!oldDocumentBackgroundColor) document.body.style.backgroundColor = "white";
      document.body.style.backgroundColor = oldDocumentBackgroundColor;
      // IE11
      canvas.style.paddingLeft = oldPaddingLeft;
      // Chrome, FF, Safari
      canvas.style.paddingRight = oldPaddingRight;
      canvas.style.paddingTop = oldPaddingTop;
      canvas.style.paddingBottom = oldPaddingBottom;
      canvas.style.marginLeft = oldMarginLeft;
      // IE11
      canvas.style.marginRight = oldMarginRight;
      canvas.style.marginTop = oldMarginTop;
      canvas.style.marginBottom = oldMarginBottom;
      document.body.style.margin = oldDocumentBodyMargin;
      document.documentElement.style.overflow = oldDocumentOverflow;
      // Chrome, Firefox
      document.body.scroll = oldDocumentScroll;
      // IE
      canvas.style.imageRendering = oldImageRendering;
      if (canvas.GLctxObject) canvas.GLctxObject.GLctx.viewport(0, 0, oldWidth, oldHeight);
      callCanvasResizedCallback(currentFullscreenStrategy);
    }
  }
  document.addEventListener("fullscreenchange", restoreOldStyle);
  document.addEventListener("webkitfullscreenchange", restoreOldStyle);
  return restoreOldStyle;
};

var setLetterbox = (element, topBottom, leftRight) => {
  // Cannot use margin to specify letterboxes in FF or Chrome, since those ignore margins in fullscreen mode.
  element.style.paddingLeft = element.style.paddingRight = leftRight + "px";
  element.style.paddingTop = element.style.paddingBottom = topBottom + "px";
};

var getBoundingClientRect = e => specialHTMLTargets.indexOf(e) < 0 ? e.getBoundingClientRect() : {
  "left": 0,
  "top": 0
};

var JSEvents_resizeCanvasForFullscreen = (target, strategy) => {
  var restoreOldStyle = registerRestoreOldStyle(target);
  var cssWidth = strategy.softFullscreen ? innerWidth : screen.width;
  var cssHeight = strategy.softFullscreen ? innerHeight : screen.height;
  var rect = getBoundingClientRect(target);
  var windowedCssWidth = rect.width;
  var windowedCssHeight = rect.height;
  var canvasSize = getCanvasElementSize(target);
  var windowedRttWidth = canvasSize[0];
  var windowedRttHeight = canvasSize[1];
  if (strategy.scaleMode == 3) {
    setLetterbox(target, (cssHeight - windowedCssHeight) / 2, (cssWidth - windowedCssWidth) / 2);
    cssWidth = windowedCssWidth;
    cssHeight = windowedCssHeight;
  } else if (strategy.scaleMode == 2) {
    if (cssWidth * windowedRttHeight < windowedRttWidth * cssHeight) {
      var desiredCssHeight = windowedRttHeight * cssWidth / windowedRttWidth;
      setLetterbox(target, (cssHeight - desiredCssHeight) / 2, 0);
      cssHeight = desiredCssHeight;
    } else {
      var desiredCssWidth = windowedRttWidth * cssHeight / windowedRttHeight;
      setLetterbox(target, 0, (cssWidth - desiredCssWidth) / 2);
      cssWidth = desiredCssWidth;
    }
  }
  // If we are adding padding, must choose a background color or otherwise Chrome will give the
  // padding a default white color. Do it only if user has not customized their own background color.
  target.style.backgroundColor ||= "black";
  // IE11 does the same, but requires the color to be set in the document body.
  document.body.style.backgroundColor ||= "black";
  // IE11
  // Firefox always shows black letterboxes independent of style color.
  target.style.width = cssWidth + "px";
  target.style.height = cssHeight + "px";
  if (strategy.filteringMode == 1) {
    target.style.imageRendering = "optimizeSpeed";
    target.style.imageRendering = "-moz-crisp-edges";
    target.style.imageRendering = "-o-crisp-edges";
    target.style.imageRendering = "-webkit-optimize-contrast";
    target.style.imageRendering = "optimize-contrast";
    target.style.imageRendering = "crisp-edges";
    target.style.imageRendering = "pixelated";
  }
  var dpiScale = (strategy.canvasResolutionScaleMode == 2) ? devicePixelRatio : 1;
  if (strategy.canvasResolutionScaleMode != 0) {
    var newWidth = (cssWidth * dpiScale) | 0;
    var newHeight = (cssHeight * dpiScale) | 0;
    setCanvasElementSize(target, newWidth, newHeight);
    if (target.GLctxObject) target.GLctxObject.GLctx.viewport(0, 0, newWidth, newHeight);
  }
  return restoreOldStyle;
};

var JSEvents_requestFullscreen = (target, strategy) => {
  // EMSCRIPTEN_FULLSCREEN_SCALE_DEFAULT + EMSCRIPTEN_FULLSCREEN_CANVAS_SCALE_NONE is a mode where no extra logic is performed to the DOM elements.
  if (strategy.scaleMode != 0 || strategy.canvasResolutionScaleMode != 0) {
    JSEvents_resizeCanvasForFullscreen(target, strategy);
  }
  if (target.requestFullscreen) {
    target.requestFullscreen();
  } else if (target.webkitRequestFullscreen) {
    // Safari didn't Element.requestFullscreen support until 16.4
    // See: https://developer.mozilla.org/en-US/docs/Web/API/Element/requestFullscreen
    target.webkitRequestFullscreen(Element.ALLOW_KEYBOARD_INPUT);
  } else {
    return JSEvents.fullscreenEnabled() ? -3 : -1;
  }
  currentFullscreenStrategy = strategy;
  callCanvasResizedCallback(strategy);
  return 0;
};

var _emscripten_exit_fullscreen = () => {
  if (!JSEvents.fullscreenEnabled()) return -1;
  // Make sure no queued up calls will fire after this.
  JSEvents.removeDeferredCalls(JSEvents_requestFullscreen);
  var d = specialHTMLTargets[1];
  if (d.exitFullscreen) {
    d.fullscreenElement && d.exitFullscreen();
  } else if (d.webkitExitFullscreen) {
    d.webkitFullscreenElement && d.webkitExitFullscreen();
  } else {
    return -1;
  }
  return 0;
};

var requestPointerLock = target => {
  if (target.requestPointerLock) {
    target.requestPointerLock();
  } else {
    // document.body is known to accept pointer lock, so use that to differentiate if the user passed a bad element,
    // or if the whole browser just doesn't support the feature.
    if (document.body.requestPointerLock) {
      return -3;
    }
    return -1;
  }
  return 0;
};

var _emscripten_exit_pointerlock = () => {
  // Make sure no queued up calls will fire after this.
  JSEvents.removeDeferredCalls(requestPointerLock);
  if (!document.exitPointerLock) return -1;
  document.exitPointerLock();
  return 0;
};

var _emscripten_get_device_pixel_ratio = () => globalThis.devicePixelRatio ?? 1;

function _emscripten_get_element_css_size(target, width, height) {
  target >>>= 0;
  width >>>= 0;
  height >>>= 0;
  target = findEventTarget(target);
  if (!target) return -4;
  var rect = getBoundingClientRect(target);
  HEAPF64[((width) >>> 3) >>> 0] = rect.width;
  HEAPF64[((height) >>> 3) >>> 0] = rect.height;
  return 0;
}

var fillGamepadEventData = (eventStruct, e) => {
  HEAPF64[((eventStruct) >>> 3) >>> 0] = e.timestamp;
  for (var i = 0; i < e.axes.length; ++i) {
    HEAPF64[(((eventStruct + i * 8) + (16)) >>> 3) >>> 0] = e.axes[i];
  }
  for (var i = 0; i < e.buttons.length; ++i) {
    HEAP8[(eventStruct + i) + (1040) >>> 0] = e.buttons[i].pressed;
    HEAPF64[(((eventStruct + i * 8) + (528)) >>> 3) >>> 0] = e.buttons[i].value;
  }
  HEAP8[(eventStruct) + (1104) >>> 0] = e.connected;
  HEAP32[(((eventStruct) + (1108)) >>> 2) >>> 0] = e.index;
  HEAP32[(((eventStruct) + (8)) >>> 2) >>> 0] = e.axes.length;
  HEAP32[(((eventStruct) + (12)) >>> 2) >>> 0] = e.buttons.length;
  stringToUTF8(e.id, eventStruct + 1112, 64);
  stringToUTF8(e.mapping, eventStruct + 1176, 64);
};

function _emscripten_get_gamepad_status(index, gamepadState) {
  gamepadState >>>= 0;
  assert(JSEvents.lastGamepadState, "emscripten_get_gamepad_status() called before emscripten_sample_gamepad_data()");
  // INVALID_PARAM is returned on a Gamepad index that never was there.
  if (index < 0 || index >= JSEvents.lastGamepadState.length) return -5;
  // NO_DATA is returned on a Gamepad index that was removed.
  // For previously disconnected gamepads there should be an empty slot (null/undefined/false) at the index.
  // This is because gamepads must keep their original position in the array.
  // For example, removing the first of two gamepads produces [null/undefined/false, gamepad].
  if (!JSEvents.lastGamepadState[index]) return -7;
  fillGamepadEventData(gamepadState, JSEvents.lastGamepadState[index]);
  return 0;
}

var getHeapMax = () => // Stay one Wasm page short of 4GB: while e.g. Chrome is able to allocate
// full 4GB Wasm memories, the size will wrap back to 0 bytes in Wasm side
// for any code that deals with heap sizes, which would require special
// casing all heap size related code to treat 0 specially.
4294901760;

function _emscripten_get_heap_max() {
  return getHeapMax();
}

var _emscripten_get_num_gamepads = () => {
  assert(JSEvents.lastGamepadState, "emscripten_get_num_gamepads() called before emscripten_sample_gamepad_data()");
  // N.B. Do not call emscripten_get_num_gamepads() unless having first called emscripten_sample_gamepad_data(), and that has returned EMSCRIPTEN_RESULT_SUCCESS.
  // Otherwise the following line will throw an exception.
  return JSEvents.lastGamepadState.length;
};

function _emscripten_get_screen_size(width, height) {
  width >>>= 0;
  height >>>= 0;
  HEAP32[((width) >>> 2) >>> 0] = screen.width;
  HEAP32[((height) >>> 2) >>> 0] = screen.height;
}

var _emscripten_glActiveTexture = x0 => GLctx.activeTexture(x0);

var _emscripten_glAttachShader = (program, shader) => {
  GLctx.attachShader(GL.programs[program], GL.shaders[shader]);
};

var _emscripten_glBeginQuery = (target, id) => {
  GLctx.beginQuery(target, GL.queries[id]);
};

var _emscripten_glBeginQueryEXT = (target, id) => {
  GLctx.disjointTimerQueryExt["beginQueryEXT"](target, GL.queries[id]);
};

var _emscripten_glBeginTransformFeedback = x0 => GLctx.beginTransformFeedback(x0);

function _emscripten_glBindAttribLocation(program, index, name) {
  name >>>= 0;
  GLctx.bindAttribLocation(GL.programs[program], index, UTF8ToString(name));
}

var _emscripten_glBindBuffer = (target, buffer) => {
  // Calling glBindBuffer with an unknown buffer will implicitly create a
  // new one.  Here we bypass `GL.counter` and directly using the ID passed
  // in.
  if (buffer && !GL.buffers[buffer]) {
    var b = GLctx.createBuffer();
    b.name = buffer;
    GL.buffers[buffer] = b;
  }
  if (target == 34962) {
    GLctx.currentArrayBufferBinding = buffer;
  } else if (target == 34963) {
    GLctx.currentElementArrayBufferBinding = buffer;
  }
  if (target == 35051) {
    // In WebGL 2 glReadPixels entry point, we need to use a different WebGL 2
    // API function call when a buffer is bound to
    // GL_PIXEL_PACK_BUFFER_BINDING point, so must keep track whether that
    // binding point is non-null to know what is the proper API function to
    // call.
    GLctx.currentPixelPackBufferBinding = buffer;
  } else if (target == 35052) {
    // In WebGL 2 gl(Compressed)Tex(Sub)Image[23]D entry points, we need to
    // use a different WebGL 2 API function call when a buffer is bound to
    // GL_PIXEL_UNPACK_BUFFER_BINDING point, so must keep track whether that
    // binding point is non-null to know what is the proper API function to
    // call.
    GLctx.currentPixelUnpackBufferBinding = buffer;
  }
  GLctx.bindBuffer(target, GL.buffers[buffer]);
};

var _emscripten_glBindBufferBase = (target, index, buffer) => {
  GLctx.bindBufferBase(target, index, GL.buffers[buffer]);
};

function _emscripten_glBindBufferRange(target, index, buffer, offset, ptrsize) {
  offset >>>= 0;
  ptrsize >>>= 0;
  GLctx.bindBufferRange(target, index, GL.buffers[buffer], offset, ptrsize);
}

var _emscripten_glBindFramebuffer = (target, framebuffer) => {
  GLctx.bindFramebuffer(target, GL.framebuffers[framebuffer]);
};

var _emscripten_glBindRenderbuffer = (target, renderbuffer) => {
  GLctx.bindRenderbuffer(target, GL.renderbuffers[renderbuffer]);
};

var _emscripten_glBindSampler = (unit, sampler) => {
  GLctx.bindSampler(unit, GL.samplers[sampler]);
};

var _emscripten_glBindTexture = (target, texture) => {
  GLctx.bindTexture(target, GL.textures[texture]);
};

var _emscripten_glBindTransformFeedback = (target, id) => {
  GLctx.bindTransformFeedback(target, GL.transformFeedbacks[id]);
};

var _emscripten_glBindVertexArray = vao => {
  GLctx.bindVertexArray(GL.vaos[vao]);
  var ibo = GLctx.getParameter(34965);
  GLctx.currentElementArrayBufferBinding = ibo ? (ibo.name | 0) : 0;
};

var _glBindVertexArray = _emscripten_glBindVertexArray;

var _emscripten_glBindVertexArrayOES = _glBindVertexArray;

var _emscripten_glBlendColor = (x0, x1, x2, x3) => GLctx.blendColor(x0, x1, x2, x3);

var _emscripten_glBlendEquation = x0 => GLctx.blendEquation(x0);

var _emscripten_glBlendEquationSeparate = (x0, x1) => GLctx.blendEquationSeparate(x0, x1);

var _emscripten_glBlendFunc = (x0, x1) => GLctx.blendFunc(x0, x1);

var _emscripten_glBlendFuncSeparate = (x0, x1, x2, x3) => GLctx.blendFuncSeparate(x0, x1, x2, x3);

var _emscripten_glBlitFramebuffer = (x0, x1, x2, x3, x4, x5, x6, x7, x8, x9) => GLctx.blitFramebuffer(x0, x1, x2, x3, x4, x5, x6, x7, x8, x9);

function _emscripten_glBufferData(target, size, data, usage) {
  size >>>= 0;
  data >>>= 0;
  // N.b. here first form specifies a heap subarray, second form an integer
  // size, so the ?: code here is polymorphic. It is advised to avoid
  // randomly mixing both uses in calling code, to avoid any potential JS
  // engine JIT issues.
  GLctx.bufferData(target, data ? HEAPU8.subarray(data >>> 0, data + size >>> 0) : size, usage);
}

function _emscripten_glBufferSubData(target, offset, size, data) {
  offset >>>= 0;
  size >>>= 0;
  data >>>= 0;
  return webglBufferSubData(target, offset, size, data);
}

var _emscripten_glCheckFramebufferStatus = x0 => GLctx.checkFramebufferStatus(x0);

var _emscripten_glClear = x0 => GLctx.clear(x0);

var _emscripten_glClearBufferfi = (x0, x1, x2, x3) => GLctx.clearBufferfi(x0, x1, x2, x3);

/** @type {!Float32Array} */ var HEAPF32;

function _emscripten_glClearBufferfv(buffer, drawbuffer, value) {
  value >>>= 0;
  GLctx.clearBufferfv(buffer, drawbuffer, HEAPF32, ((value) >>> 2));
}

function _emscripten_glClearBufferiv(buffer, drawbuffer, value) {
  value >>>= 0;
  GLctx.clearBufferiv(buffer, drawbuffer, HEAP32, ((value) >>> 2));
}

function _emscripten_glClearBufferuiv(buffer, drawbuffer, value) {
  value >>>= 0;
  GLctx.clearBufferuiv(buffer, drawbuffer, HEAPU32, ((value) >>> 2));
}

var _emscripten_glClearColor = (x0, x1, x2, x3) => GLctx.clearColor(x0, x1, x2, x3);

var _emscripten_glClearDepthf = x0 => GLctx.clearDepth(x0);

var _emscripten_glClearStencil = x0 => GLctx.clearStencil(x0);

function _emscripten_glClientWaitSync(sync, flags, timeout) {
  sync >>>= 0;
  // WebGL2 vs GLES3 differences: in GLES3, the timeout parameter is a uint64, where 0xFFFFFFFFFFFFFFFFULL means GL_TIMEOUT_IGNORED.
  // In JS, there's no 64-bit value types, so instead timeout is taken to be signed, and GL_TIMEOUT_IGNORED is given value -1.
  // Inherently the value accepted in the timeout is lossy, and can't take in arbitrary u64 bit pattern (but most likely doesn't matter)
  // See https://www.khronos.org/registry/webgl/specs/latest/2.0/#5.15
  timeout = Number(timeout);
  return GLctx.clientWaitSync(GL.syncs[sync], flags, timeout);
}

var _emscripten_glClipControlEXT = (origin, depth) => {
  GLctx.extClipControl["clipControlEXT"](origin, depth);
};

var _emscripten_glColorMask = (red, green, blue, alpha) => {
  GLctx.colorMask(!!red, !!green, !!blue, !!alpha);
};

var _emscripten_glCompileShader = shader => {
  GLctx.compileShader(GL.shaders[shader]);
};

function _emscripten_glCompressedTexImage2D(target, level, internalFormat, width, height, border, imageSize, data) {
  data >>>= 0;
  // `data` may be null here, which means "allocate uninitialized space but
  // don't upload" in GLES parlance, but `compressedTexImage2D` requires the
  // final data parameter, so we simply pass a heap view starting at zero
  // effectively uploading whatever happens to be near address zero.  See
  // https://github.com/emscripten-core/emscripten/issues/19300.
  if (true) {
    if (GLctx.currentPixelUnpackBufferBinding || !imageSize) {
      GLctx.compressedTexImage2D(target, level, internalFormat, width, height, border, imageSize, data);
      return;
    }
  }
  GLctx.compressedTexImage2D(target, level, internalFormat, width, height, border, HEAPU8.subarray(data >>> 0, data + imageSize >>> 0));
}

function _emscripten_glCompressedTexImage3D(target, level, internalFormat, width, height, depth, border, imageSize, data) {
  data >>>= 0;
  if (GLctx.currentPixelUnpackBufferBinding) {
    GLctx.compressedTexImage3D(target, level, internalFormat, width, height, depth, border, imageSize, data);
  } else {
    GLctx.compressedTexImage3D(target, level, internalFormat, width, height, depth, border, HEAPU8, data, imageSize);
  }
}

function _emscripten_glCompressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, imageSize, data) {
  data >>>= 0;
  if (true) {
    if (GLctx.currentPixelUnpackBufferBinding || !imageSize) {
      GLctx.compressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, imageSize, data);
      return;
    }
  }
  GLctx.compressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, HEAPU8.subarray(data >>> 0, data + imageSize >>> 0));
}

function _emscripten_glCompressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, imageSize, data) {
  data >>>= 0;
  if (GLctx.currentPixelUnpackBufferBinding) {
    GLctx.compressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, imageSize, data);
  } else {
    GLctx.compressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, HEAPU8, data, imageSize);
  }
}

function _emscripten_glCopyBufferSubData(x0, x1, x2, x3, x4) {
  x2 >>>= 0;
  x3 >>>= 0;
  x4 >>>= 0;
  return GLctx.copyBufferSubData(x0, x1, x2, x3, x4);
}

var _emscripten_glCopyTexImage2D = (x0, x1, x2, x3, x4, x5, x6, x7) => GLctx.copyTexImage2D(x0, x1, x2, x3, x4, x5, x6, x7);

var _emscripten_glCopyTexSubImage2D = (x0, x1, x2, x3, x4, x5, x6, x7) => GLctx.copyTexSubImage2D(x0, x1, x2, x3, x4, x5, x6, x7);

var _emscripten_glCopyTexSubImage3D = (x0, x1, x2, x3, x4, x5, x6, x7, x8) => GLctx.copyTexSubImage3D(x0, x1, x2, x3, x4, x5, x6, x7, x8);

var _emscripten_glCreateProgram = () => {
  var id = GL.getNewId(GL.programs);
  var program = GLctx.createProgram();
  // Store additional information needed for each shader program:
  program.name = id;
  // Lazy cache results of
  // glGetProgramiv(GL_ACTIVE_UNIFORM_MAX_LENGTH/GL_ACTIVE_ATTRIBUTE_MAX_LENGTH/GL_ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH)
  program.maxUniformLength = program.maxAttributeLength = program.maxUniformBlockNameLength = 0;
  program.uniformIdCounter = 1;
  GL.programs[id] = program;
  return id;
};

var _emscripten_glCreateShader = shaderType => {
  var id = GL.getNewId(GL.shaders);
  GL.shaders[id] = GLctx.createShader(shaderType);
  return id;
};

var _emscripten_glCullFace = x0 => GLctx.cullFace(x0);

function _emscripten_glDeleteBuffers(n, buffers) {
  buffers >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((buffers) + (i * 4)) >>> 2) >>> 0];
    var buffer = GL.buffers[id];
    // From spec: "glDeleteBuffers silently ignores 0's and names that do not
    // correspond to existing buffer objects."
    if (!buffer) continue;
    GLctx.deleteBuffer(buffer);
    buffer.name = 0;
    GL.buffers[id] = null;
    if (id == GLctx.currentArrayBufferBinding) GLctx.currentArrayBufferBinding = 0;
    if (id == GLctx.currentElementArrayBufferBinding) GLctx.currentElementArrayBufferBinding = 0;
    if (id == GLctx.currentPixelPackBufferBinding) GLctx.currentPixelPackBufferBinding = 0;
    if (id == GLctx.currentPixelUnpackBufferBinding) GLctx.currentPixelUnpackBufferBinding = 0;
  }
}

function _emscripten_glDeleteFramebuffers(n, framebuffers) {
  framebuffers >>>= 0;
  for (var i = 0; i < n; ++i) {
    var id = HEAP32[(((framebuffers) + (i * 4)) >>> 2) >>> 0];
    var framebuffer = GL.framebuffers[id];
    if (!framebuffer) continue;
    // GL spec: "glDeleteFramebuffers silently ignores 0s and names that do not correspond to existing framebuffer objects".
    GLctx.deleteFramebuffer(framebuffer);
    framebuffer.name = 0;
    GL.framebuffers[id] = null;
  }
}

var _emscripten_glDeleteProgram = id => {
  if (!id) return;
  var program = GL.programs[id];
  if (!program) {
    // glDeleteProgram actually signals an error when deleting a nonexisting
    // object, unlike some other GL delete functions.
    GL.recordError(1281);
    return;
  }
  GLctx.deleteProgram(program);
  program.name = 0;
  GL.programs[id] = null;
};

function _emscripten_glDeleteQueries(n, ids) {
  ids >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((ids) + (i * 4)) >>> 2) >>> 0];
    var query = GL.queries[id];
    if (!query) continue;
    // GL spec: "unused names in ids are ignored, as is the name zero."
    GLctx.deleteQuery(query);
    GL.queries[id] = null;
  }
}

function _emscripten_glDeleteQueriesEXT(n, ids) {
  ids >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((ids) + (i * 4)) >>> 2) >>> 0];
    var query = GL.queries[id];
    if (!query) continue;
    // GL spec: "unused names in ids are ignored, as is the name zero."
    GLctx.disjointTimerQueryExt["deleteQueryEXT"](query);
    GL.queries[id] = null;
  }
}

function _emscripten_glDeleteRenderbuffers(n, renderbuffers) {
  renderbuffers >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((renderbuffers) + (i * 4)) >>> 2) >>> 0];
    var renderbuffer = GL.renderbuffers[id];
    if (!renderbuffer) continue;
    // GL spec: "glDeleteRenderbuffers silently ignores 0s and names that do not correspond to existing renderbuffer objects".
    GLctx.deleteRenderbuffer(renderbuffer);
    renderbuffer.name = 0;
    GL.renderbuffers[id] = null;
  }
}

function _emscripten_glDeleteSamplers(n, samplers) {
  samplers >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((samplers) + (i * 4)) >>> 2) >>> 0];
    var sampler = GL.samplers[id];
    if (!sampler) continue;
    GLctx.deleteSampler(sampler);
    sampler.name = 0;
    GL.samplers[id] = null;
  }
}

var _emscripten_glDeleteShader = id => {
  if (!id) return;
  var shader = GL.shaders[id];
  if (!shader) {
    // glDeleteShader actually signals an error when deleting a nonexisting
    // object, unlike some other GL delete functions.
    GL.recordError(1281);
    return;
  }
  GLctx.deleteShader(shader);
  GL.shaders[id] = null;
};

function _emscripten_glDeleteSync(id) {
  id >>>= 0;
  if (!id) return;
  var sync = GL.syncs[id];
  if (!sync) {
    // glDeleteSync signals an error when deleting a nonexisting object, unlike some other GL delete functions.
    GL.recordError(1281);
    return;
  }
  GLctx.deleteSync(sync);
  sync.name = 0;
  GL.syncs[id] = null;
}

function _emscripten_glDeleteTextures(n, textures) {
  textures >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((textures) + (i * 4)) >>> 2) >>> 0];
    var texture = GL.textures[id];
    // GL spec: "glDeleteTextures silently ignores 0s and names that do not
    // correspond to existing textures".
    if (!texture) continue;
    GLctx.deleteTexture(texture);
    texture.name = 0;
    GL.textures[id] = null;
  }
}

function _emscripten_glDeleteTransformFeedbacks(n, ids) {
  ids >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((ids) + (i * 4)) >>> 2) >>> 0];
    var transformFeedback = GL.transformFeedbacks[id];
    if (!transformFeedback) continue;
    // GL spec: "unused names in ids are ignored, as is the name zero."
    GLctx.deleteTransformFeedback(transformFeedback);
    transformFeedback.name = 0;
    GL.transformFeedbacks[id] = null;
  }
}

function _emscripten_glDeleteVertexArrays(n, vaos) {
  vaos >>>= 0;
  for (var i = 0; i < n; i++) {
    var id = HEAP32[(((vaos) + (i * 4)) >>> 2) >>> 0];
    GLctx.deleteVertexArray(GL.vaos[id]);
    GL.vaos[id] = null;
  }
}

var _glDeleteVertexArrays = _emscripten_glDeleteVertexArrays;

var _emscripten_glDeleteVertexArraysOES = _glDeleteVertexArrays;

var _emscripten_glDepthFunc = x0 => GLctx.depthFunc(x0);

var _emscripten_glDepthMask = flag => {
  GLctx.depthMask(!!flag);
};

var _emscripten_glDepthRangef = (x0, x1) => GLctx.depthRange(x0, x1);

var _emscripten_glDetachShader = (program, shader) => {
  GLctx.detachShader(GL.programs[program], GL.shaders[shader]);
};

var _emscripten_glDisable = x0 => GLctx.disable(x0);

var _emscripten_glDisableVertexAttribArray = index => {
  var cb = GL.currentContext.clientBuffers[index];
  cb.enabled = false;
  GLctx.disableVertexAttribArray(index);
};

var _emscripten_glDrawArrays = (mode, first, count) => {
  // bind any client-side buffers
  GL.preDrawHandleClientVertexAttribBindings(first + count);
  GLctx.drawArrays(mode, first, count);
  GL.postDrawHandleClientVertexAttribBindings();
};

var _emscripten_glDrawArraysInstanced = (mode, first, count, primcount) => {
  GLctx.drawArraysInstanced(mode, first, count, primcount);
};

var _glDrawArraysInstanced = _emscripten_glDrawArraysInstanced;

var _emscripten_glDrawArraysInstancedANGLE = _glDrawArraysInstanced;

var _emscripten_glDrawArraysInstancedARB = _glDrawArraysInstanced;

var _emscripten_glDrawArraysInstancedEXT = _glDrawArraysInstanced;

var _emscripten_glDrawArraysInstancedNV = _glDrawArraysInstanced;

var tempFixedLengthArray = [];

function _emscripten_glDrawBuffers(n, bufs) {
  bufs >>>= 0;
  var bufArray = tempFixedLengthArray[n];
  for (var i = 0; i < n; i++) {
    bufArray[i] = HEAP32[(((bufs) + (i * 4)) >>> 2) >>> 0];
  }
  GLctx.drawBuffers(bufArray);
}

var _glDrawBuffers = _emscripten_glDrawBuffers;

var _emscripten_glDrawBuffersEXT = _glDrawBuffers;

var _emscripten_glDrawBuffersWEBGL = _glDrawBuffers;

function _emscripten_glDrawElements(mode, count, type, indices) {
  indices >>>= 0;
  var buf;
  var vertexes = 0;
  if (!GLctx.currentElementArrayBufferBinding) {
    var size = GL.calcBufLength(1, type, 0, count);
    buf = GL.getTempIndexBuffer(size);
    GLctx.bindBuffer(34963, buf);
    webglBufferSubData(34963, 0, size, indices);
    // Calculating vertex count if shader's attribute data is on client side
    if (count > 0) {
      for (var i = 0; i < GL.currentContext.maxVertexAttribs; ++i) {
        var cb = GL.currentContext.clientBuffers[i];
        if (cb.clientside && cb.enabled) {
          let arrayClass;
          switch (type) {
           case 5121:
            arrayClass = Uint8Array;
            break;

           case 5123:
            arrayClass = Uint16Array;
            break;

           case 5125:
            arrayClass = Uint32Array;
            break;

           default:
            GL.recordError(1282);
            return;
          }
          vertexes = new arrayClass(HEAPU8.buffer, indices, count).reduce((max, current) => Math.max(max, current)) + 1;
          break;
        }
      }
    }
    // the index is now 0
    indices = 0;
  }
  // bind any client-side buffers
  GL.preDrawHandleClientVertexAttribBindings(vertexes);
  GLctx.drawElements(mode, count, type, indices);
  GL.postDrawHandleClientVertexAttribBindings(count);
  if (!GLctx.currentElementArrayBufferBinding) {
    GLctx.bindBuffer(34963, null);
  }
}

function _emscripten_glDrawElementsInstanced(mode, count, type, indices, primcount) {
  indices >>>= 0;
  GLctx.drawElementsInstanced(mode, count, type, indices, primcount);
}

var _glDrawElementsInstanced = _emscripten_glDrawElementsInstanced;

var _emscripten_glDrawElementsInstancedANGLE = _glDrawElementsInstanced;

var _emscripten_glDrawElementsInstancedARB = _glDrawElementsInstanced;

var _emscripten_glDrawElementsInstancedEXT = _glDrawElementsInstanced;

var _emscripten_glDrawElementsInstancedNV = _glDrawElementsInstanced;

var _glDrawElements = _emscripten_glDrawElements;

function _emscripten_glDrawRangeElements(mode, start, end, count, type, indices) {
  indices >>>= 0;
  // TODO: This should be a trivial pass-through function registered at the bottom of this page as
  // glFuncs[6][1] += ' drawRangeElements';
  // but due to https://bugzil.la/1202427,
  // we work around by ignoring the range.
  _glDrawElements(mode, count, type, indices);
}

var _emscripten_glEnable = x0 => GLctx.enable(x0);

var _emscripten_glEnableVertexAttribArray = index => {
  var cb = GL.currentContext.clientBuffers[index];
  cb.enabled = true;
  GLctx.enableVertexAttribArray(index);
};

var _emscripten_glEndQuery = x0 => GLctx.endQuery(x0);

var _emscripten_glEndQueryEXT = target => {
  GLctx.disjointTimerQueryExt["endQueryEXT"](target);
};

var _emscripten_glEndTransformFeedback = () => GLctx.endTransformFeedback();

function _emscripten_glFenceSync(condition, flags) {
  var sync = GLctx.fenceSync(condition, flags);
  if (sync) {
    var id = GL.getNewId(GL.syncs);
    sync.name = id;
    GL.syncs[id] = sync;
    return id;
  }
  return 0;
}

var _emscripten_glFinish = () => GLctx.finish();

var _emscripten_glFlush = () => GLctx.flush();

var emscriptenWebGLGetBufferBinding = target => {
  switch (target) {
   case 34962:
    target = 34964;
    break;

   case 34963:
    target = 34965;
    break;

   case 35051:
    target = 35053;
    break;

   case 35052:
    target = 35055;
    break;

   case 35982:
    target = 35983;
    break;

   case 36662:
    target = 36662;
    break;

   case 36663:
    target = 36663;
    break;

   case 35345:
    target = 35368;
    break;
  }
  var buffer = GLctx.getParameter(target);
  if (buffer) return buffer.name | 0; else return 0;
};

var emscriptenWebGLValidateMapBufferTarget = target => {
  switch (target) {
   case 34962:
   // GL_ARRAY_BUFFER
    case 34963:
   // GL_ELEMENT_ARRAY_BUFFER
    case 36662:
   // GL_COPY_READ_BUFFER
    case 36663:
   // GL_COPY_WRITE_BUFFER
    case 35051:
   // GL_PIXEL_PACK_BUFFER
    case 35052:
   // GL_PIXEL_UNPACK_BUFFER
    case 35882:
   // GL_TEXTURE_BUFFER
    case 35982:
   // GL_TRANSFORM_FEEDBACK_BUFFER
    case 35345:
    // GL_UNIFORM_BUFFER
    return true;

   default:
    return false;
  }
};

function _emscripten_glFlushMappedBufferRange(target, offset, length) {
  offset >>>= 0;
  length >>>= 0;
  if (!emscriptenWebGLValidateMapBufferTarget(target)) {
    GL.recordError(1280);
    err("GL_INVALID_ENUM in glFlushMappedBufferRange");
    return;
  }
  var mapping = GL.mappedBuffers[emscriptenWebGLGetBufferBinding(target)];
  if (!mapping) {
    GL.recordError(1282);
    err("buffer was never mapped in glFlushMappedBufferRange");
    return;
  }
  if (!(mapping.access & 16)) {
    GL.recordError(1282);
    err("buffer was not mapped with GL_MAP_FLUSH_EXPLICIT_BIT in glFlushMappedBufferRange");
    return;
  }
  if (offset < 0 || length < 0 || offset + length > mapping.length) {
    GL.recordError(1281);
    err("invalid range in glFlushMappedBufferRange");
    return;
  }
  webglBufferSubData(target, mapping.offset, length, mapping.mem + offset);
}

var _emscripten_glFramebufferRenderbuffer = (target, attachment, renderbuffertarget, renderbuffer) => {
  GLctx.framebufferRenderbuffer(target, attachment, renderbuffertarget, GL.renderbuffers[renderbuffer]);
};

var _emscripten_glFramebufferTexture2D = (target, attachment, textarget, texture, level) => {
  GLctx.framebufferTexture2D(target, attachment, textarget, GL.textures[texture], level);
};

var _emscripten_glFramebufferTextureLayer = (target, attachment, texture, level, layer) => {
  GLctx.framebufferTextureLayer(target, attachment, GL.textures[texture], level, layer);
};

var _emscripten_glFrontFace = x0 => GLctx.frontFace(x0);

function _emscripten_glGenBuffers(n, buffers) {
  buffers >>>= 0;
  GL.genObject(n, buffers, "createBuffer", GL.buffers);
}

function _emscripten_glGenFramebuffers(n, ids) {
  ids >>>= 0;
  GL.genObject(n, ids, "createFramebuffer", GL.framebuffers);
}

function _emscripten_glGenQueries(n, ids) {
  ids >>>= 0;
  GL.genObject(n, ids, "createQuery", GL.queries);
}

function _emscripten_glGenQueriesEXT(n, ids) {
  ids >>>= 0;
  for (var i = 0; i < n; i++) {
    var query = GLctx.disjointTimerQueryExt["createQueryEXT"]();
    if (!query) {
      GL.recordError(1282);
      while (i < n) HEAP32[(((ids) + (i++ * 4)) >>> 2) >>> 0] = 0;
      return;
    }
    var id = GL.getNewId(GL.queries);
    query.name = id;
    GL.queries[id] = query;
    HEAP32[(((ids) + (i * 4)) >>> 2) >>> 0] = id;
  }
}

function _emscripten_glGenRenderbuffers(n, renderbuffers) {
  renderbuffers >>>= 0;
  GL.genObject(n, renderbuffers, "createRenderbuffer", GL.renderbuffers);
}

function _emscripten_glGenSamplers(n, samplers) {
  samplers >>>= 0;
  GL.genObject(n, samplers, "createSampler", GL.samplers);
}

function _emscripten_glGenTextures(n, textures) {
  textures >>>= 0;
  GL.genObject(n, textures, "createTexture", GL.textures);
}

function _emscripten_glGenTransformFeedbacks(n, ids) {
  ids >>>= 0;
  GL.genObject(n, ids, "createTransformFeedback", GL.transformFeedbacks);
}

function _emscripten_glGenVertexArrays(n, arrays) {
  arrays >>>= 0;
  GL.genObject(n, arrays, "createVertexArray", GL.vaos);
}

var _glGenVertexArrays = _emscripten_glGenVertexArrays;

var _emscripten_glGenVertexArraysOES = _glGenVertexArrays;

var _emscripten_glGenerateMipmap = x0 => GLctx.generateMipmap(x0);

var __glGetActiveAttribOrUniform = (funcName, program, index, bufSize, length, size, type, name) => {
  program = GL.programs[program];
  var info = GLctx[funcName](program, index);
  if (info) {
    // If an error occurs, nothing will be written to length, size and type and name.
    var numBytesWrittenExclNull = name && stringToUTF8(info.name, name, bufSize);
    if (length) HEAP32[((length) >>> 2) >>> 0] = numBytesWrittenExclNull;
    if (size) HEAP32[((size) >>> 2) >>> 0] = info.size;
    if (type) HEAP32[((type) >>> 2) >>> 0] = info.type;
  }
};

function _emscripten_glGetActiveAttrib(program, index, bufSize, length, size, type, name) {
  length >>>= 0;
  size >>>= 0;
  type >>>= 0;
  name >>>= 0;
  return __glGetActiveAttribOrUniform("getActiveAttrib", program, index, bufSize, length, size, type, name);
}

function _emscripten_glGetActiveUniform(program, index, bufSize, length, size, type, name) {
  length >>>= 0;
  size >>>= 0;
  type >>>= 0;
  name >>>= 0;
  return __glGetActiveAttribOrUniform("getActiveUniform", program, index, bufSize, length, size, type, name);
}

function _emscripten_glGetActiveUniformBlockName(program, uniformBlockIndex, bufSize, length, uniformBlockName) {
  length >>>= 0;
  uniformBlockName >>>= 0;
  program = GL.programs[program];
  var result = GLctx.getActiveUniformBlockName(program, uniformBlockIndex);
  if (!result) return;
  // If an error occurs, nothing will be written to uniformBlockName or length.
  if (uniformBlockName && bufSize > 0) {
    var numBytesWrittenExclNull = stringToUTF8(result, uniformBlockName, bufSize);
    if (length) HEAP32[((length) >>> 2) >>> 0] = numBytesWrittenExclNull;
  } else {
    if (length) HEAP32[((length) >>> 2) >>> 0] = 0;
  }
}

function _emscripten_glGetActiveUniformBlockiv(program, uniformBlockIndex, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if params == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  program = GL.programs[program];
  if (pname == 35393) {
    var name = GLctx.getActiveUniformBlockName(program, uniformBlockIndex);
    HEAP32[((params) >>> 2) >>> 0] = name.length + 1;
    return;
  }
  var result = GLctx.getActiveUniformBlockParameter(program, uniformBlockIndex, pname);
  if (result === null) return;
  // If an error occurs, nothing should be written to params.
  if (pname == 35395) {
    for (var i = 0; i < result.length; i++) {
      HEAP32[(((params) + (i * 4)) >>> 2) >>> 0] = result[i];
    }
  } else {
    HEAP32[((params) >>> 2) >>> 0] = result;
  }
}

function _emscripten_glGetActiveUniformsiv(program, uniformCount, uniformIndices, pname, params) {
  uniformIndices >>>= 0;
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if params == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  if (uniformCount > 0 && uniformIndices == 0) {
    GL.recordError(1281);
    return;
  }
  program = GL.programs[program];
  var ids = [];
  for (var i = 0; i < uniformCount; i++) {
    ids.push(HEAP32[(((uniformIndices) + (i * 4)) >>> 2) >>> 0]);
  }
  var result = GLctx.getActiveUniforms(program, ids, pname);
  if (!result) return;
  // GL spec: If an error is generated, nothing is written out to params.
  var len = result.length;
  for (var i = 0; i < len; i++) {
    HEAP32[(((params) + (i * 4)) >>> 2) >>> 0] = result[i];
  }
}

function _emscripten_glGetAttachedShaders(program, maxCount, count, shaders) {
  count >>>= 0;
  shaders >>>= 0;
  var result = GLctx.getAttachedShaders(GL.programs[program]);
  var len = result.length;
  if (len > maxCount) {
    len = maxCount;
  }
  HEAP32[((count) >>> 2) >>> 0] = len;
  for (var i = 0; i < len; ++i) {
    var id = GL.shaders.indexOf(result[i]);
    HEAP32[(((shaders) + (i * 4)) >>> 2) >>> 0] = id;
  }
}

function _emscripten_glGetAttribLocation(program, name) {
  name >>>= 0;
  return GLctx.getAttribLocation(GL.programs[program], UTF8ToString(name));
}

var readI53FromU64 = ptr => HEAPU32[((ptr) >>> 2) >>> 0] + HEAPU32[(((ptr) + (4)) >>> 2) >>> 0] * 4294967296;

var writeI53ToI64 = (ptr, num) => {
  HEAPU32[((ptr) >>> 2) >>> 0] = num;
  var lower = HEAPU32[((ptr) >>> 2) >>> 0];
  HEAPU32[(((ptr) + (4)) >>> 2) >>> 0] = (num - lower) / 4294967296;
  var deserialized = (num >= 0) ? readI53FromU64(ptr) : readI53FromI64(ptr);
  var offset = ((ptr) >>> 2);
  if (deserialized != num) warnOnce(`writeI53ToI64() out of range: serialized JS Number ${num} to Wasm heap as bytes lo=${ptrToString(HEAPU32[offset >>> 0])}, hi=${ptrToString(HEAPU32[offset + 1 >>> 0])}, which deserializes back to ${deserialized} instead!`);
};

var webglGetExtensions = () => {
  var exts = getEmscriptenSupportedExtensions(GLctx);
  exts = exts.concat(exts.map(e => "GL_" + e));
  return exts;
};

var emscriptenWebGLGet = (name_, p, type) => {
  // Guard against user passing a null pointer.
  // Note that GLES2 spec does not say anything about how passing a null
  // pointer should be treated.  Testing on desktop core GL 3, the application
  // crashes on glGetIntegerv to a null pointer, but better to report an error
  // instead of doing anything random.
  if (!p) {
    GL.recordError(1281);
    return;
  }
  var ret = undefined;
  switch (name_) {
   // Handle a few trivial GLES values
    case 36346:
    // GL_SHADER_COMPILER
    ret = 1;
    break;

   case 36344:
    // GL_SHADER_BINARY_FORMATS
    if (type != 0 && type != 1) {
      GL.recordError(1280);
    }
    // Do not write anything to the out pointer, since no binary formats are
    // supported.
    return;

   case 34814:
   // GL_NUM_PROGRAM_BINARY_FORMATS
    case 36345:
    // GL_NUM_SHADER_BINARY_FORMATS
    ret = 0;
    break;

   case 34466:
    // GL_NUM_COMPRESSED_TEXTURE_FORMATS
    // WebGL doesn't have GL_NUM_COMPRESSED_TEXTURE_FORMATS (it's obsolete
    // since GL_COMPRESSED_TEXTURE_FORMATS returns a JS array that can be
    // queried for length), so implement it ourselves to allow C++ GLES2
    // code to get the length.
    var formats = GLctx.getParameter(34467);
    ret = formats ? formats.length : 0;
    break;

   case 33309:
    // GL_NUM_EXTENSIONS
    if (GL.currentContext.version < 2) {
      // Calling GLES3/WebGL2 function with a GLES2/WebGL1 context
      GL.recordError(1282);
      return;
    }
    ret = webglGetExtensions().length;
    break;

   case 33307:
   // GL_MAJOR_VERSION
    case 33308:
    // GL_MINOR_VERSION
    if (GL.currentContext.version < 2) {
      GL.recordError(1280);
      // GL_INVALID_ENUM
      return;
    }
    ret = name_ == 33307 ? 3 : 0;
    // return version 3.0
    break;
  }
  if (ret === undefined) {
    var result = GLctx.getParameter(name_);
    switch (typeof result) {
     case "number":
      ret = result;
      break;

     case "boolean":
      ret = result ? 1 : 0;
      break;

     case "string":
      GL.recordError(1280);
      // GL_INVALID_ENUM
      return;

     case "object":
      if (result === null) {
        // null is a valid result for some (e.g., which buffer is bound -
        // perhaps nothing is bound), but otherwise can mean an invalid
        // name_, which we need to report as an error
        switch (name_) {
         case 34964:
         // ARRAY_BUFFER_BINDING
          case 35725:
         // CURRENT_PROGRAM
          case 34965:
         // ELEMENT_ARRAY_BUFFER_BINDING
          case 36006:
         // FRAMEBUFFER_BINDING or DRAW_FRAMEBUFFER_BINDING
          case 36007:
         // RENDERBUFFER_BINDING
          case 32873:
         // TEXTURE_BINDING_2D
          case 34229:
         // WebGL 2 GL_VERTEX_ARRAY_BINDING, or WebGL 1 extension OES_vertex_array_object GL_VERTEX_ARRAY_BINDING_OES
          case 36662:
         // COPY_READ_BUFFER_BINDING or COPY_READ_BUFFER
          case 36663:
         // COPY_WRITE_BUFFER_BINDING or COPY_WRITE_BUFFER
          case 35053:
         // PIXEL_PACK_BUFFER_BINDING
          case 35055:
         // PIXEL_UNPACK_BUFFER_BINDING
          case 36010:
         // READ_FRAMEBUFFER_BINDING
          case 35097:
         // SAMPLER_BINDING
          case 35869:
         // TEXTURE_BINDING_2D_ARRAY
          case 32874:
         // TEXTURE_BINDING_3D
          case 36389:
         // TRANSFORM_FEEDBACK_BINDING
          case 35983:
         // TRANSFORM_FEEDBACK_BUFFER_BINDING
          case 35368:
         // UNIFORM_BUFFER_BINDING
          case 34068:
          {
            // TEXTURE_BINDING_CUBE_MAP
            ret = 0;
            break;
          }

         default:
          {
            GL.recordError(1280);
            // GL_INVALID_ENUM
            return;
          }
        }
      } else if (result instanceof Float32Array || result instanceof Uint32Array || result instanceof Int32Array || result instanceof Array) {
        for (var i = 0; i < result.length; ++i) {
          switch (type) {
           case 0:
            HEAP32[(((p) + (i * 4)) >>> 2) >>> 0] = result[i];
            break;

           case 2:
            HEAPF32[(((p) + (i * 4)) >>> 2) >>> 0] = result[i];
            break;

           case 4:
            HEAP8[(p) + (i) >>> 0] = result[i] ? 1 : 0;
            break;
          }
        }
        return;
      } else {
        try {
          ret = result.name | 0;
        } catch (e) {
          GL.recordError(1280);
          // GL_INVALID_ENUM
          err(`GL_INVALID_ENUM in glGet${type}v: Unknown object returned from WebGL getParameter(${name_})! (error: ${e})`);
          return;
        }
      }
      break;

     default:
      GL.recordError(1280);
      // GL_INVALID_ENUM
      err(`GL_INVALID_ENUM in glGet${type}v: Native code calling glGet${type}v(${name_}) and it returns ${result} of type ${typeof (result)}!`);
      return;
    }
  }
  switch (type) {
   case 1:
    writeI53ToI64(p, ret);
    break;

   case 0:
    HEAP32[((p) >>> 2) >>> 0] = ret;
    break;

   case 2:
    HEAPF32[((p) >>> 2) >>> 0] = ret;
    break;

   case 4:
    HEAP8[p >>> 0] = ret ? 1 : 0;
    break;
  }
};

function _emscripten_glGetBooleanv(name_, p) {
  p >>>= 0;
  return emscriptenWebGLGet(name_, p, 4);
}

function _emscripten_glGetBufferParameteri64v(target, value, data) {
  data >>>= 0;
  if (!data) {
    // GLES2 specification does not specify how to behave if data is a null pointer. Since calling this function does not make sense
    // if data == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  writeI53ToI64(data, GLctx.getBufferParameter(target, value));
}

function _emscripten_glGetBufferParameteriv(target, value, data) {
  data >>>= 0;
  if (!data) {
    // GLES2 specification does not specify how to behave if data is a null
    // pointer. Since calling this function does not make sense if data ==
    // null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAP32[((data) >>> 2) >>> 0] = GLctx.getBufferParameter(target, value);
}

function _emscripten_glGetBufferPointerv(target, pname, params) {
  params >>>= 0;
  if (pname == 35005) {
    var ptr = 0;
    var mappedBuffer = GL.mappedBuffers[emscriptenWebGLGetBufferBinding(target)];
    if (mappedBuffer) {
      ptr = mappedBuffer.mem;
    }
    HEAP32[((params) >>> 2) >>> 0] = ptr;
  } else {
    GL.recordError(1280);
    err("GL_INVALID_ENUM in glGetBufferPointerv");
  }
}

var _emscripten_glGetError = () => {
  var error = GLctx.getError() || GL.lastError;
  GL.lastError = 0;
  return error;
};

function _emscripten_glGetFloatv(name_, p) {
  p >>>= 0;
  return emscriptenWebGLGet(name_, p, 2);
}

function _emscripten_glGetFragDataLocation(program, name) {
  name >>>= 0;
  return GLctx.getFragDataLocation(GL.programs[program], UTF8ToString(name));
}

function _emscripten_glGetFramebufferAttachmentParameteriv(target, attachment, pname, params) {
  params >>>= 0;
  var result = GLctx.getFramebufferAttachmentParameter(target, attachment, pname);
  if (result instanceof WebGLRenderbuffer || result instanceof WebGLTexture) {
    result = result.name | 0;
  }
  HEAP32[((params) >>> 2) >>> 0] = result;
}

var emscriptenWebGLGetIndexed = (target, index, data, type) => {
  if (!data) {
    // GLES2 specification does not specify how to behave if data is a null pointer. Since calling this function does not make sense
    // if data == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  var result = GLctx.getIndexedParameter(target, index);
  var ret;
  switch (typeof result) {
   case "boolean":
    ret = result ? 1 : 0;
    break;

   case "number":
    ret = result;
    break;

   case "object":
    if (result === null) {
      switch (target) {
       case 35983:
       // TRANSFORM_FEEDBACK_BUFFER_BINDING
        case 35368:
        // UNIFORM_BUFFER_BINDING
        ret = 0;
        break;

       default:
        {
          GL.recordError(1280);
          // GL_INVALID_ENUM
          return;
        }
      }
    } else if (result instanceof WebGLBuffer) {
      ret = result.name | 0;
    } else {
      GL.recordError(1280);
      // GL_INVALID_ENUM
      return;
    }
    break;

   default:
    GL.recordError(1280);
    // GL_INVALID_ENUM
    return;
  }
  switch (type) {
   case 1:
    writeI53ToI64(data, ret);
    break;

   case 0:
    HEAP32[((data) >>> 2) >>> 0] = ret;
    break;

   case 2:
    HEAPF32[((data) >>> 2) >>> 0] = ret;
    break;

   case 4:
    HEAP8[data >>> 0] = ret ? 1 : 0;
    break;

   default:
    abort("internal emscriptenWebGLGetIndexed() error, bad type: " + type);
  }
};

function _emscripten_glGetInteger64i_v(target, index, data) {
  data >>>= 0;
  return emscriptenWebGLGetIndexed(target, index, data, 1);
}

function _emscripten_glGetInteger64v(name_, p) {
  p >>>= 0;
  emscriptenWebGLGet(name_, p, 1);
}

function _emscripten_glGetIntegeri_v(target, index, data) {
  data >>>= 0;
  return emscriptenWebGLGetIndexed(target, index, data, 0);
}

function _emscripten_glGetIntegerv(name_, p) {
  p >>>= 0;
  return emscriptenWebGLGet(name_, p, 0);
}

function _emscripten_glGetInternalformativ(target, internalformat, pname, bufSize, params) {
  params >>>= 0;
  if (bufSize < 0) {
    GL.recordError(1281);
    return;
  }
  if (!params) {
    // GLES3 specification does not specify how to behave if values is a null pointer. Since calling this function does not make sense
    // if values == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  var ret = GLctx.getInternalformatParameter(target, internalformat, pname);
  if (ret === null) return;
  for (var i = 0; i < ret.length && i < bufSize; ++i) {
    HEAP32[(((params) + (i * 4)) >>> 2) >>> 0] = ret[i];
  }
}

function _emscripten_glGetProgramBinary(program, bufSize, length, binaryFormat, binary) {
  length >>>= 0;
  binaryFormat >>>= 0;
  binary >>>= 0;
  GL.recordError(1282);
}

function _emscripten_glGetProgramInfoLog(program, maxLength, length, infoLog) {
  length >>>= 0;
  infoLog >>>= 0;
  var log = GLctx.getProgramInfoLog(GL.programs[program]);
  if (log === null) log = "(unknown error)";
  var numBytesWrittenExclNull = (maxLength > 0 && infoLog) ? stringToUTF8(log, infoLog, maxLength) : 0;
  if (length) HEAP32[((length) >>> 2) >>> 0] = numBytesWrittenExclNull;
}

function _emscripten_glGetProgramiv(program, pname, p) {
  p >>>= 0;
  if (!p) {
    // GLES2 specification does not specify how to behave if p is a null
    // pointer. Since calling this function does not make sense if p == null,
    // issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  if (program >= GL.counter) {
    GL.recordError(1281);
    return;
  }
  program = GL.programs[program];
  if (pname == 35716) {
    // GL_INFO_LOG_LENGTH
    var log = GLctx.getProgramInfoLog(program);
    if (log === null) log = "(unknown error)";
    HEAP32[((p) >>> 2) >>> 0] = log.length + 1;
  } else if (pname == 35719) {
    if (!program.maxUniformLength) {
      var numActiveUniforms = GLctx.getProgramParameter(program, 35718);
      for (var i = 0; i < numActiveUniforms; ++i) {
        program.maxUniformLength = Math.max(program.maxUniformLength, GLctx.getActiveUniform(program, i).name.length + 1);
      }
    }
    HEAP32[((p) >>> 2) >>> 0] = program.maxUniformLength;
  } else if (pname == 35722) {
    if (!program.maxAttributeLength) {
      var numActiveAttributes = GLctx.getProgramParameter(program, 35721);
      for (var i = 0; i < numActiveAttributes; ++i) {
        program.maxAttributeLength = Math.max(program.maxAttributeLength, GLctx.getActiveAttrib(program, i).name.length + 1);
      }
    }
    HEAP32[((p) >>> 2) >>> 0] = program.maxAttributeLength;
  } else if (pname == 35381) {
    if (!program.maxUniformBlockNameLength) {
      var numActiveUniformBlocks = GLctx.getProgramParameter(program, 35382);
      for (var i = 0; i < numActiveUniformBlocks; ++i) {
        program.maxUniformBlockNameLength = Math.max(program.maxUniformBlockNameLength, GLctx.getActiveUniformBlockName(program, i).length + 1);
      }
    }
    HEAP32[((p) >>> 2) >>> 0] = program.maxUniformBlockNameLength;
  } else {
    HEAP32[((p) >>> 2) >>> 0] = GLctx.getProgramParameter(program, pname);
  }
}

function _emscripten_glGetQueryObjecti64vEXT(id, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if p == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  var query = GL.queries[id];
  var param;
  if (GL.currentContext.version < 2) {
    param = GLctx.disjointTimerQueryExt["getQueryObjectEXT"](query, pname);
  } else {
    param = GLctx.getQueryParameter(query, pname);
  }
  var ret;
  if (typeof param == "boolean") {
    ret = param ? 1 : 0;
  } else {
    ret = param;
  }
  writeI53ToI64(params, ret);
}

function _emscripten_glGetQueryObjectivEXT(id, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if p == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  var query = GL.queries[id];
  var param = GLctx.disjointTimerQueryExt["getQueryObjectEXT"](query, pname);
  var ret;
  if (typeof param == "boolean") {
    ret = param ? 1 : 0;
  } else {
    ret = param;
  }
  HEAP32[((params) >>> 2) >>> 0] = ret;
}

var _glGetQueryObjecti64vEXT = _emscripten_glGetQueryObjecti64vEXT;

var _emscripten_glGetQueryObjectui64vEXT = _glGetQueryObjecti64vEXT;

function _emscripten_glGetQueryObjectuiv(id, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if p == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  var query = GL.queries[id];
  var param = GLctx.getQueryParameter(query, pname);
  var ret;
  if (typeof param == "boolean") {
    ret = param ? 1 : 0;
  } else {
    ret = param;
  }
  HEAP32[((params) >>> 2) >>> 0] = ret;
}

var _glGetQueryObjectivEXT = _emscripten_glGetQueryObjectivEXT;

var _emscripten_glGetQueryObjectuivEXT = _glGetQueryObjectivEXT;

function _emscripten_glGetQueryiv(target, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if p == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAP32[((params) >>> 2) >>> 0] = GLctx.getQuery(target, pname);
}

function _emscripten_glGetQueryivEXT(target, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if p == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAP32[((params) >>> 2) >>> 0] = GLctx.disjointTimerQueryExt["getQueryEXT"](target, pname);
}

function _emscripten_glGetRenderbufferParameteriv(target, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if params == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAP32[((params) >>> 2) >>> 0] = GLctx.getRenderbufferParameter(target, pname);
}

function _emscripten_glGetSamplerParameterfv(sampler, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES3 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if p == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAPF32[((params) >>> 2) >>> 0] = GLctx.getSamplerParameter(GL.samplers[sampler], pname);
}

function _emscripten_glGetSamplerParameteriv(sampler, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES3 specification does not specify how to behave if params is a null pointer. Since calling this function does not make sense
    // if p == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAP32[((params) >>> 2) >>> 0] = GLctx.getSamplerParameter(GL.samplers[sampler], pname);
}

function _emscripten_glGetShaderInfoLog(shader, maxLength, length, infoLog) {
  length >>>= 0;
  infoLog >>>= 0;
  var log = GLctx.getShaderInfoLog(GL.shaders[shader]);
  if (log === null) log = "(unknown error)";
  var numBytesWrittenExclNull = (maxLength > 0 && infoLog) ? stringToUTF8(log, infoLog, maxLength) : 0;
  if (length) HEAP32[((length) >>> 2) >>> 0] = numBytesWrittenExclNull;
}

function _emscripten_glGetShaderPrecisionFormat(shaderType, precisionType, range, precision) {
  range >>>= 0;
  precision >>>= 0;
  var result = GLctx.getShaderPrecisionFormat(shaderType, precisionType);
  HEAP32[((range) >>> 2) >>> 0] = result.rangeMin;
  HEAP32[(((range) + (4)) >>> 2) >>> 0] = result.rangeMax;
  HEAP32[((precision) >>> 2) >>> 0] = result.precision;
}

function _emscripten_glGetShaderSource(shader, bufSize, length, source) {
  length >>>= 0;
  source >>>= 0;
  var result = GLctx.getShaderSource(GL.shaders[shader]);
  if (!result) return;
  // If an error occurs, nothing will be written to length or source.
  var numBytesWrittenExclNull = (bufSize > 0 && source) ? stringToUTF8(result, source, bufSize) : 0;
  if (length) HEAP32[((length) >>> 2) >>> 0] = numBytesWrittenExclNull;
}

function _emscripten_glGetShaderiv(shader, pname, p) {
  p >>>= 0;
  if (!p) {
    // GLES2 specification does not specify how to behave if p is a null
    // pointer. Since calling this function does not make sense if p == null,
    // issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  if (pname == 35716) {
    // GL_INFO_LOG_LENGTH
    var log = GLctx.getShaderInfoLog(GL.shaders[shader]);
    if (log === null) log = "(unknown error)";
    // The GLES2 specification says that if the shader has an empty info log,
    // a value of 0 is returned. Otherwise the log has a null char appended.
    // (An empty string is falsey, so we can just check that instead of
    // looking at log.length.)
    var logLength = log ? log.length + 1 : 0;
    HEAP32[((p) >>> 2) >>> 0] = logLength;
  } else if (pname == 35720) {
    // GL_SHADER_SOURCE_LENGTH
    var source = GLctx.getShaderSource(GL.shaders[shader]);
    // source may be a null, or the empty string, both of which are falsey
    // values that we report a 0 length for.
    var sourceLength = source ? source.length + 1 : 0;
    HEAP32[((p) >>> 2) >>> 0] = sourceLength;
  } else {
    HEAP32[((p) >>> 2) >>> 0] = GLctx.getShaderParameter(GL.shaders[shader], pname);
  }
}

function _emscripten_glGetString(name_) {
  var ret = GL.stringCache[name_];
  if (!ret) {
    switch (name_) {
     case 7939:
      ret = stringToNewUTF8(webglGetExtensions().join(" "));
      break;

     case 7936:
     case 7937:
     case 37445:
     case 37446:
      var s = GLctx.getParameter(name_);
      if (!s) {
        GL.recordError(1280);
      }
      ret = s ? stringToNewUTF8(s) : 0;
      break;

     case 7938:
      var webGLVersion = GLctx.getParameter(7938);
      // return GLES version string corresponding to the version of the WebGL context
      var glVersion = `OpenGL ES 2.0 (${webGLVersion})`;
      if (true) glVersion = `OpenGL ES 3.0 (${webGLVersion})`;
      ret = stringToNewUTF8(glVersion);
      break;

     case 35724:
      var glslVersion = GLctx.getParameter(35724);
      // extract the version number 'N.M' from the string 'WebGL GLSL ES N.M ...'
      var ver_re = /^WebGL GLSL ES ([0-9]\.[0-9][0-9]?)(?:$| .*)/;
      var ver_num = glslVersion.match(ver_re);
      if (ver_num !== null) {
        if (ver_num[1].length == 3) ver_num[1] = ver_num[1] + "0";
        // ensure minor version has 2 digits
        glslVersion = `OpenGL ES GLSL ES ${ver_num[1]} (${glslVersion})`;
      }
      ret = stringToNewUTF8(glslVersion);
      break;

     default:
      GL.recordError(1280);
    }
    GL.stringCache[name_] = ret;
  }
  return ret;
}

function _emscripten_glGetStringi(name, index) {
  if (GL.currentContext.version < 2) {
    GL.recordError(1282);
    // Calling GLES3/WebGL2 function with a GLES2/WebGL1 context
    return 0;
  }
  var stringiCache = GL.stringiCache[name];
  if (stringiCache) {
    if (index < 0 || index >= stringiCache.length) {
      GL.recordError(1281);
      return 0;
    }
    return stringiCache[index];
  }
  switch (name) {
   case 7939:
    var exts = webglGetExtensions().map(stringToNewUTF8);
    stringiCache = GL.stringiCache[name] = exts;
    if (index < 0 || index >= stringiCache.length) {
      GL.recordError(1281);
      return 0;
    }
    return stringiCache[index];

   default:
    GL.recordError(1280);
    return 0;
  }
}

function _emscripten_glGetSynciv(sync, pname, bufSize, length, values) {
  sync >>>= 0;
  length >>>= 0;
  values >>>= 0;
  if (bufSize < 0) {
    // GLES3 specification does not specify how to behave if bufSize < 0, however in the spec wording for glGetInternalformativ, it does say that GL_INVALID_VALUE should be raised,
    // so raise GL_INVALID_VALUE here as well.
    GL.recordError(1281);
    return;
  }
  if (!values) {
    // GLES3 specification does not specify how to behave if values is a null pointer. Since calling this function does not make sense
    // if values == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  var ret = GLctx.getSyncParameter(GL.syncs[sync], pname);
  if (ret !== null) {
    HEAP32[((values) >>> 2) >>> 0] = ret;
    if (length) HEAP32[((length) >>> 2) >>> 0] = 1;
  }
}

function _emscripten_glGetTexParameterfv(target, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null
    // pointer. Since calling this function does not make sense if p == null,
    // issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAPF32[((params) >>> 2) >>> 0] = GLctx.getTexParameter(target, pname);
}

function _emscripten_glGetTexParameteriv(target, pname, params) {
  params >>>= 0;
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null
    // pointer. Since calling this function does not make sense if p == null,
    // issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  HEAP32[((params) >>> 2) >>> 0] = GLctx.getTexParameter(target, pname);
}

function _emscripten_glGetTransformFeedbackVarying(program, index, bufSize, length, size, type, name) {
  length >>>= 0;
  size >>>= 0;
  type >>>= 0;
  name >>>= 0;
  program = GL.programs[program];
  var info = GLctx.getTransformFeedbackVarying(program, index);
  if (!info) return;
  // If an error occurred, the return parameters length, size, type and name will be unmodified.
  if (name && bufSize > 0) {
    var numBytesWrittenExclNull = stringToUTF8(info.name, name, bufSize);
    if (length) HEAP32[((length) >>> 2) >>> 0] = numBytesWrittenExclNull;
  } else {
    if (length) HEAP32[((length) >>> 2) >>> 0] = 0;
  }
  if (size) HEAP32[((size) >>> 2) >>> 0] = info.size;
  if (type) HEAP32[((type) >>> 2) >>> 0] = info.type;
}

function _emscripten_glGetUniformBlockIndex(program, uniformBlockName) {
  uniformBlockName >>>= 0;
  return GLctx.getUniformBlockIndex(GL.programs[program], UTF8ToString(uniformBlockName));
}

function _emscripten_glGetUniformIndices(program, uniformCount, uniformNames, uniformIndices) {
  uniformNames >>>= 0;
  uniformIndices >>>= 0;
  if (!uniformIndices) {
    // GLES2 specification does not specify how to behave if uniformIndices is a null pointer. Since calling this function does not make sense
    // if uniformIndices == null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  if (uniformCount > 0 && (uniformNames == 0 || uniformIndices == 0)) {
    GL.recordError(1281);
    return;
  }
  program = GL.programs[program];
  var names = [];
  for (var i = 0; i < uniformCount; i++) names.push(UTF8ToString(HEAPU32[(((uniformNames) + (i * 4)) >>> 2) >>> 0]));
  var result = GLctx.getUniformIndices(program, names);
  if (!result) return;
  // GL spec: If an error is generated, nothing is written out to uniformIndices.
  var len = result.length;
  for (var i = 0; i < len; i++) {
    HEAP32[(((uniformIndices) + (i * 4)) >>> 2) >>> 0] = result[i];
  }
}

/** @suppress {checkTypes} */ var jstoi_q = str => parseInt(str);

/** @noinline */ var webglGetLeftBracePos = name => name.slice(-1) == "]" && name.lastIndexOf("[");

var webglPrepareUniformLocationsBeforeFirstUse = program => {
  var uniformLocsById = program.uniformLocsById, // Maps GLuint -> WebGLUniformLocation
  uniformSizeAndIdsByName = program.uniformSizeAndIdsByName, // Maps name -> [uniform array length, GLuint]
  i, j;
  // On the first time invocation of glGetUniformLocation on this shader program:
  // initialize cache data structures and discover which uniforms are arrays.
  if (!uniformLocsById) {
    // maps GLint integer locations to WebGLUniformLocations
    program.uniformLocsById = uniformLocsById = {};
    // maps integer locations back to uniform name strings, so that we can lazily fetch uniform array locations
    program.uniformArrayNamesById = {};
    var numActiveUniforms = GLctx.getProgramParameter(program, 35718);
    for (i = 0; i < numActiveUniforms; ++i) {
      var u = GLctx.getActiveUniform(program, i);
      var nm = u.name;
      var sz = u.size;
      var lb = webglGetLeftBracePos(nm);
      var arrayName = lb > 0 ? nm.slice(0, lb) : nm;
      // Assign a new location.
      var id = program.uniformIdCounter;
      program.uniformIdCounter += sz;
      // Eagerly get the location of the uniformArray[0] base element.
      // The remaining indices >0 will be left for lazy evaluation to
      // improve performance. Those may never be needed to fetch, if the
      // application fills arrays always in full starting from the first
      // element of the array.
      uniformSizeAndIdsByName[arrayName] = [ sz, id ];
      // Store placeholder integers in place that highlight that these
      // >0 index locations are array indices pending population.
      for (j = 0; j < sz; ++j) {
        uniformLocsById[id] = j;
        program.uniformArrayNamesById[id++] = arrayName;
      }
    }
  }
};

function _emscripten_glGetUniformLocation(program, name) {
  name >>>= 0;
  name = UTF8ToString(name);
  if (program = GL.programs[program]) {
    webglPrepareUniformLocationsBeforeFirstUse(program);
    var uniformLocsById = program.uniformLocsById;
    // Maps GLuint -> WebGLUniformLocation
    var arrayIndex = 0;
    var uniformBaseName = name;
    // Invariant: when populating integer IDs for uniform locations, we must
    // maintain the precondition that arrays reside in contiguous addresses,
    // i.e. for a 'vec4 colors[10];', colors[4] must be at location
    // colors[0]+4.  However, user might call glGetUniformLocation(program,
    // "colors") for an array, so we cannot discover based on the user input
    // arguments whether the uniform we are dealing with is an array. The only
    // way to discover which uniforms are arrays is to enumerate over all the
    // active uniforms in the program.
    var leftBrace = webglGetLeftBracePos(name);
    // If user passed an array accessor "[index]", parse the array index off the accessor.
    if (leftBrace > 0) {
      arrayIndex = jstoi_q(name.slice(leftBrace + 1)) >>> 0;
      // "index]", coerce parseInt(']') with >>>0 to treat "foo[]" as "foo[0]" and foo[-1] as unsigned out-of-bounds.
      uniformBaseName = name.slice(0, leftBrace);
    }
    // Have we cached the location of this uniform before?
    // A pair [array length, GLint of the uniform location]
    var sizeAndId = program.uniformSizeAndIdsByName[uniformBaseName];
    // If a uniform with this name exists, and if its index is within the
    // array limits (if it's even an array), query the WebGLlocation, or
    // return an existing cached location.
    if (sizeAndId && arrayIndex < sizeAndId[0]) {
      arrayIndex += sizeAndId[1];
      // Add the base location of the uniform to the array index offset.
      if ((uniformLocsById[arrayIndex] = uniformLocsById[arrayIndex] || GLctx.getUniformLocation(program, name))) {
        return arrayIndex;
      }
    }
  } else {
    // N.b. we are currently unable to distinguish between GL program IDs that
    // never existed vs GL program IDs that have been deleted, so report
    // GL_INVALID_VALUE in both cases.
    GL.recordError(1281);
  }
  return -1;
}

var webglGetProgramUniformLocation = (program, location) => {
  if (program) {
    var webglLoc = program.uniformLocsById[location];
    // program.uniformLocsById[location] stores either an integer, or a
    // WebGLUniformLocation.
    // If an integer, we have not yet bound the location, so do it now. The
    // integer value specifies the array index we should bind to.
    if (typeof webglLoc == "number") {
      program.uniformLocsById[location] = webglLoc = GLctx.getUniformLocation(program, program.uniformArrayNamesById[location] + (webglLoc > 0 ? `[${webglLoc}]` : ""));
    }
    // Else an already cached WebGLUniformLocation, return it.
    return webglLoc;
  } else {
    GL.recordError(1282);
  }
};

/** @suppress{checkTypes} */ var emscriptenWebGLGetUniform = (program, location, params, type) => {
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null
    // pointer. Since calling this function does not make sense if params ==
    // null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  program = GL.programs[program];
  webglPrepareUniformLocationsBeforeFirstUse(program);
  var data = GLctx.getUniform(program, webglGetProgramUniformLocation(program, location));
  if (typeof data == "number" || typeof data == "boolean") {
    switch (type) {
     case 0:
      HEAP32[((params) >>> 2) >>> 0] = data;
      break;

     case 2:
      HEAPF32[((params) >>> 2) >>> 0] = data;
      break;
    }
  } else {
    for (var i = 0; i < data.length; i++) {
      switch (type) {
       case 0:
        HEAP32[(((params) + (i * 4)) >>> 2) >>> 0] = data[i];
        break;

       case 2:
        HEAPF32[(((params) + (i * 4)) >>> 2) >>> 0] = data[i];
        break;
      }
    }
  }
};

function _emscripten_glGetUniformfv(program, location, params) {
  params >>>= 0;
  emscriptenWebGLGetUniform(program, location, params, 2);
}

function _emscripten_glGetUniformiv(program, location, params) {
  params >>>= 0;
  emscriptenWebGLGetUniform(program, location, params, 0);
}

function _emscripten_glGetUniformuiv(program, location, params) {
  params >>>= 0;
  return emscriptenWebGLGetUniform(program, location, params, 0);
}

/** @suppress{checkTypes} */ var emscriptenWebGLGetVertexAttrib = (index, pname, params, type) => {
  if (!params) {
    // GLES2 specification does not specify how to behave if params is a null
    // pointer. Since calling this function does not make sense if params ==
    // null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  if (GL.currentContext.clientBuffers[index].enabled) {
    err("glGetVertexAttrib*v on client-side array: not supported, bad data returned");
  }
  var data = GLctx.getVertexAttrib(index, pname);
  if (pname == 34975) {
    HEAP32[((params) >>> 2) >>> 0] = data && data["name"];
  } else if (typeof data == "number" || typeof data == "boolean") {
    switch (type) {
     case 0:
      HEAP32[((params) >>> 2) >>> 0] = data;
      break;

     case 2:
      HEAPF32[((params) >>> 2) >>> 0] = data;
      break;

     case 5:
      HEAP32[((params) >>> 2) >>> 0] = Math.fround(data);
      break;
    }
  } else {
    for (var i = 0; i < data.length; i++) {
      switch (type) {
       case 0:
        HEAP32[(((params) + (i * 4)) >>> 2) >>> 0] = data[i];
        break;

       case 2:
        HEAPF32[(((params) + (i * 4)) >>> 2) >>> 0] = data[i];
        break;

       case 5:
        HEAP32[(((params) + (i * 4)) >>> 2) >>> 0] = Math.fround(data[i]);
        break;
      }
    }
  }
};

function _emscripten_glGetVertexAttribIiv(index, pname, params) {
  params >>>= 0;
  // N.B. This function may only be called if the vertex attribute was specified using the function glVertexAttribI4iv(),
  // otherwise the results are undefined. (GLES3 spec 6.1.12)
  emscriptenWebGLGetVertexAttrib(index, pname, params, 0);
}

var _glGetVertexAttribIiv = _emscripten_glGetVertexAttribIiv;

var _emscripten_glGetVertexAttribIuiv = _glGetVertexAttribIiv;

function _emscripten_glGetVertexAttribPointerv(index, pname, pointer) {
  pointer >>>= 0;
  if (!pointer) {
    // GLES2 specification does not specify how to behave if pointer is a null
    // pointer. Since calling this function does not make sense if pointer ==
    // null, issue a GL error to notify user about it.
    GL.recordError(1281);
    return;
  }
  if (GL.currentContext.clientBuffers[index].enabled) {
    err("glGetVertexAttribPointer on client-side array: not supported, bad data returned");
  }
  HEAP32[((pointer) >>> 2) >>> 0] = GLctx.getVertexAttribOffset(index, pname);
}

function _emscripten_glGetVertexAttribfv(index, pname, params) {
  params >>>= 0;
  // N.B. This function may only be called if the vertex attribute was
  // specified using the function glVertexAttrib*f(), otherwise the results
  // are undefined. (GLES3 spec 6.1.12)
  emscriptenWebGLGetVertexAttrib(index, pname, params, 2);
}

function _emscripten_glGetVertexAttribiv(index, pname, params) {
  params >>>= 0;
  // N.B. This function may only be called if the vertex attribute was
  // specified using the function glVertexAttrib*f(), otherwise the results
  // are undefined. (GLES3 spec 6.1.12)
  emscriptenWebGLGetVertexAttrib(index, pname, params, 5);
}

var _emscripten_glHint = (x0, x1) => GLctx.hint(x0, x1);

function _emscripten_glInvalidateFramebuffer(target, numAttachments, attachments) {
  attachments >>>= 0;
  var list = tempFixedLengthArray[numAttachments];
  for (var i = 0; i < numAttachments; i++) {
    list[i] = HEAP32[(((attachments) + (i * 4)) >>> 2) >>> 0];
  }
  GLctx.invalidateFramebuffer(target, list);
}

function _emscripten_glInvalidateSubFramebuffer(target, numAttachments, attachments, x, y, width, height) {
  attachments >>>= 0;
  var list = tempFixedLengthArray[numAttachments];
  for (var i = 0; i < numAttachments; i++) {
    list[i] = HEAP32[(((attachments) + (i * 4)) >>> 2) >>> 0];
  }
  GLctx.invalidateSubFramebuffer(target, list, x, y, width, height);
}

var _emscripten_glIsBuffer = buffer => {
  var b = GL.buffers[buffer];
  if (!b) return 0;
  return GLctx.isBuffer(b);
};

var _emscripten_glIsEnabled = x0 => GLctx.isEnabled(x0);

var _emscripten_glIsFramebuffer = framebuffer => {
  var fb = GL.framebuffers[framebuffer];
  if (!fb) return 0;
  return GLctx.isFramebuffer(fb);
};

var _emscripten_glIsProgram = program => {
  program = GL.programs[program];
  if (!program) return 0;
  return GLctx.isProgram(program);
};

var _emscripten_glIsQuery = id => {
  var query = GL.queries[id];
  if (!query) return 0;
  return GLctx.isQuery(query);
};

var _emscripten_glIsQueryEXT = id => {
  var query = GL.queries[id];
  if (!query) return 0;
  return GLctx.disjointTimerQueryExt["isQueryEXT"](query);
};

var _emscripten_glIsRenderbuffer = renderbuffer => {
  var rb = GL.renderbuffers[renderbuffer];
  if (!rb) return 0;
  return GLctx.isRenderbuffer(rb);
};

var _emscripten_glIsSampler = id => {
  var sampler = GL.samplers[id];
  if (!sampler) return 0;
  return GLctx.isSampler(sampler);
};

var _emscripten_glIsShader = shader => {
  var s = GL.shaders[shader];
  if (!s) return 0;
  return GLctx.isShader(s);
};

function _emscripten_glIsSync(sync) {
  sync >>>= 0;
  return GLctx.isSync(GL.syncs[sync]);
}

var _emscripten_glIsTexture = id => {
  var texture = GL.textures[id];
  if (!texture) return 0;
  return GLctx.isTexture(texture);
};

var _emscripten_glIsTransformFeedback = id => GLctx.isTransformFeedback(GL.transformFeedbacks[id]);

var _emscripten_glIsVertexArray = array => {
  var vao = GL.vaos[array];
  if (!vao) return 0;
  return GLctx.isVertexArray(vao);
};

var _glIsVertexArray = _emscripten_glIsVertexArray;

var _emscripten_glIsVertexArrayOES = _glIsVertexArray;

var _emscripten_glLineWidth = x0 => GLctx.lineWidth(x0);

var _emscripten_glLinkProgram = program => {
  program = GL.programs[program];
  GLctx.linkProgram(program);
  // Invalidate earlier computed uniform->ID mappings, those have now become stale
  program.uniformLocsById = 0;
  // Mark as null-like so that glGetUniformLocation() knows to populate this again.
  program.uniformSizeAndIdsByName = {};
};

function _emscripten_glMapBufferRange(target, offset, length, access) {
  offset >>>= 0;
  length >>>= 0;
  if ((access & (1 | 32)) != 0) {
    err("glMapBufferRange access does not support MAP_READ or MAP_UNSYNCHRONIZED");
    return 0;
  }
  if ((access & 2) == 0) {
    err("glMapBufferRange access must include MAP_WRITE");
    return 0;
  }
  if ((access & (4 | 8)) == 0) {
    err("glMapBufferRange access must include INVALIDATE_BUFFER or INVALIDATE_RANGE");
    return 0;
  }
  if (!emscriptenWebGLValidateMapBufferTarget(target)) {
    GL.recordError(1280);
    err("GL_INVALID_ENUM in glMapBufferRange");
    return 0;
  }
  var mem = _malloc(length), binding = emscriptenWebGLGetBufferBinding(target);
  if (!mem) return 0;
  binding = GL.mappedBuffers[binding] ??= {};
  binding.offset = offset;
  binding.length = length;
  binding.mem = mem;
  binding.access = access;
  return mem;
}

var _emscripten_glPauseTransformFeedback = () => GLctx.pauseTransformFeedback();

var _emscripten_glPixelStorei = (pname, param) => {
  if (pname == 3317) {
    GL.unpackAlignment = param;
  } else if (pname == 3314) {
    GL.unpackRowLength = param;
  }
  GLctx.pixelStorei(pname, param);
};

var _emscripten_glPolygonModeWEBGL = (face, mode) => {
  GLctx.webglPolygonMode["polygonModeWEBGL"](face, mode);
};

var _emscripten_glPolygonOffset = (x0, x1) => GLctx.polygonOffset(x0, x1);

var _emscripten_glPolygonOffsetClampEXT = (factor, units, clamp) => {
  GLctx.extPolygonOffsetClamp["polygonOffsetClampEXT"](factor, units, clamp);
};

function _emscripten_glProgramBinary(program, binaryFormat, binary, length) {
  binary >>>= 0;
  GL.recordError(1280);
}

var _emscripten_glProgramParameteri = (program, pname, value) => {
  GL.recordError(1280);
};

var _emscripten_glQueryCounterEXT = (id, target) => {
  GLctx.disjointTimerQueryExt["queryCounterEXT"](GL.queries[id], target);
};

var _emscripten_glReadBuffer = x0 => GLctx.readBuffer(x0);

var computeUnpackAlignedImageSize = (width, height, sizePerPixel) => {
  function roundedToNextMultipleOf(x, y) {
    return (x + y - 1) & -y;
  }
  var plainRowSize = (GL.unpackRowLength || width) * sizePerPixel;
  var alignedRowSize = roundedToNextMultipleOf(plainRowSize, GL.unpackAlignment);
  return height * alignedRowSize;
};

var colorChannelsInGlTextureFormat = format => {
  // Micro-optimizations for size: map format to size by subtracting smallest
  // enum value (0x1902) from all values first.  Also omit the most common
  // size value (1) from the list, which is assumed by formats not on the
  // list.
  var colorChannels = {
    // 0x1902 /* GL_DEPTH_COMPONENT */ - 0x1902: 1,
    // 0x1906 /* GL_ALPHA */ - 0x1902: 1,
    5: 3,
    6: 4,
    // 0x1909 /* GL_LUMINANCE */ - 0x1902: 1,
    8: 2,
    29502: 3,
    29504: 4,
    // 0x1903 /* GL_RED */ - 0x1902: 1,
    26917: 2,
    26918: 2,
    // 0x8D94 /* GL_RED_INTEGER */ - 0x1902: 1,
    29846: 3,
    29847: 4
  };
  return colorChannels[format - 6402] || 1;
};

/** @type {!Uint16Array} */ var HEAPU16;

var heapObjectForWebGLType = type => {
  // Micro-optimization for size: Subtract lowest GL enum number (0x1400/* GL_BYTE */) from type to compare
  // smaller values for the heap, for shorter generated code size.
  // Also the type HEAPU16 is not tested for explicitly, but any unrecognized type will return out HEAPU16.
  // (since most types are HEAPU16)
  type -= 5120;
  if (type == 0) return HEAP8;
  if (type == 1) return HEAPU8;
  if (type == 2) return HEAP16;
  if (type == 4) return HEAP32;
  if (type == 6) return HEAPF32;
  if (type == 5 || type == 28922 || type == 28520 || type == 30779 || type == 30782) return HEAPU32;
  return HEAPU16;
};

var toTypedArrayIndex = (pointer, heap) => pointer >>> (31 - Math.clz32(heap.BYTES_PER_ELEMENT));

var emscriptenWebGLGetTexPixelData = (type, format, width, height, pixels) => {
  var heap = heapObjectForWebGLType(type);
  var sizePerPixel = colorChannelsInGlTextureFormat(format) * heap.BYTES_PER_ELEMENT;
  var bytes = computeUnpackAlignedImageSize(width, height, sizePerPixel);
  return heap.subarray(toTypedArrayIndex(pixels, heap) >>> 0, toTypedArrayIndex(pixels + bytes, heap) >>> 0);
};

function _emscripten_glReadPixels(x, y, width, height, format, type, pixels) {
  pixels >>>= 0;
  if (true) {
    if (GLctx.currentPixelPackBufferBinding) {
      GLctx.readPixels(x, y, width, height, format, type, pixels);
      return;
    }
  }
  var pixelData = emscriptenWebGLGetTexPixelData(type, format, width, height, pixels);
  if (!pixelData) {
    GL.recordError(1280);
    return;
  }
  GLctx.readPixels(x, y, width, height, format, type, pixelData);
}

var _emscripten_glReleaseShaderCompiler = () => {};

var _emscripten_glRenderbufferStorage = (x0, x1, x2, x3) => GLctx.renderbufferStorage(x0, x1, x2, x3);

var _emscripten_glRenderbufferStorageMultisample = (x0, x1, x2, x3, x4) => GLctx.renderbufferStorageMultisample(x0, x1, x2, x3, x4);

var _emscripten_glResumeTransformFeedback = () => GLctx.resumeTransformFeedback();

var _emscripten_glSampleCoverage = (value, invert) => {
  GLctx.sampleCoverage(value, !!invert);
};

var _emscripten_glSamplerParameterf = (sampler, pname, param) => {
  GLctx.samplerParameterf(GL.samplers[sampler], pname, param);
};

function _emscripten_glSamplerParameterfv(sampler, pname, params) {
  params >>>= 0;
  var param = HEAPF32[((params) >>> 2) >>> 0];
  GLctx.samplerParameterf(GL.samplers[sampler], pname, param);
}

var _emscripten_glSamplerParameteri = (sampler, pname, param) => {
  GLctx.samplerParameteri(GL.samplers[sampler], pname, param);
};

function _emscripten_glSamplerParameteriv(sampler, pname, params) {
  params >>>= 0;
  var param = HEAP32[((params) >>> 2) >>> 0];
  GLctx.samplerParameteri(GL.samplers[sampler], pname, param);
}

var _emscripten_glScissor = (x0, x1, x2, x3) => GLctx.scissor(x0, x1, x2, x3);

function _emscripten_glShaderBinary(count, shaders, binaryformat, binary, length) {
  shaders >>>= 0;
  binary >>>= 0;
  GL.recordError(1280);
}

function _emscripten_glShaderSource(shader, count, string, length) {
  string >>>= 0;
  length >>>= 0;
  var source = GL.getSource(shader, count, string, length);
  GLctx.shaderSource(GL.shaders[shader], source);
}

var _emscripten_glStencilFunc = (x0, x1, x2) => GLctx.stencilFunc(x0, x1, x2);

var _emscripten_glStencilFuncSeparate = (x0, x1, x2, x3) => GLctx.stencilFuncSeparate(x0, x1, x2, x3);

var _emscripten_glStencilMask = x0 => GLctx.stencilMask(x0);

var _emscripten_glStencilMaskSeparate = (x0, x1) => GLctx.stencilMaskSeparate(x0, x1);

var _emscripten_glStencilOp = (x0, x1, x2) => GLctx.stencilOp(x0, x1, x2);

var _emscripten_glStencilOpSeparate = (x0, x1, x2, x3) => GLctx.stencilOpSeparate(x0, x1, x2, x3);

function _emscripten_glTexImage2D(target, level, internalFormat, width, height, border, format, type, pixels) {
  pixels >>>= 0;
  if (true) {
    if (GLctx.currentPixelUnpackBufferBinding) {
      GLctx.texImage2D(target, level, internalFormat, width, height, border, format, type, pixels);
      return;
    }
  }
  var pixelData = pixels ? emscriptenWebGLGetTexPixelData(type, format, width, height, pixels) : null;
  GLctx.texImage2D(target, level, internalFormat, width, height, border, format, type, pixelData);
}

function _emscripten_glTexImage3D(target, level, internalFormat, width, height, depth, border, format, type, pixels) {
  pixels >>>= 0;
  if (GLctx.currentPixelUnpackBufferBinding) {
    GLctx.texImage3D(target, level, internalFormat, width, height, depth, border, format, type, pixels);
  } else if (pixels) {
    var heap = heapObjectForWebGLType(type);
    var pixelData = emscriptenWebGLGetTexPixelData(type, format, width, height * depth, pixels);
    GLctx.texImage3D(target, level, internalFormat, width, height, depth, border, format, type, pixelData);
  } else {
    GLctx.texImage3D(target, level, internalFormat, width, height, depth, border, format, type, null);
  }
}

var _emscripten_glTexParameterf = (x0, x1, x2) => GLctx.texParameterf(x0, x1, x2);

function _emscripten_glTexParameterfv(target, pname, params) {
  params >>>= 0;
  var param = HEAPF32[((params) >>> 2) >>> 0];
  GLctx.texParameterf(target, pname, param);
}

var _emscripten_glTexParameteri = (x0, x1, x2) => GLctx.texParameteri(x0, x1, x2);

function _emscripten_glTexParameteriv(target, pname, params) {
  params >>>= 0;
  var param = HEAP32[((params) >>> 2) >>> 0];
  GLctx.texParameteri(target, pname, param);
}

var _emscripten_glTexStorage2D = (x0, x1, x2, x3, x4) => GLctx.texStorage2D(x0, x1, x2, x3, x4);

var _emscripten_glTexStorage3D = (x0, x1, x2, x3, x4, x5) => GLctx.texStorage3D(x0, x1, x2, x3, x4, x5);

function _emscripten_glTexSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels) {
  pixels >>>= 0;
  if (true) {
    if (GLctx.currentPixelUnpackBufferBinding) {
      GLctx.texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels);
      return;
    }
  }
  var pixelData = pixels ? emscriptenWebGLGetTexPixelData(type, format, width, height, pixels) : null;
  GLctx.texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixelData);
}

function _emscripten_glTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels) {
  pixels >>>= 0;
  if (GLctx.currentPixelUnpackBufferBinding) {
    GLctx.texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels);
  } else if (pixels) {
    var heap = heapObjectForWebGLType(type);
    var pixelData = emscriptenWebGLGetTexPixelData(type, format, width, height * depth, pixels);
    GLctx.texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixelData);
  } else {
    GLctx.texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, null);
  }
}

function _emscripten_glTransformFeedbackVaryings(program, count, varyings, bufferMode) {
  varyings >>>= 0;
  program = GL.programs[program];
  var vars = [];
  for (var i = 0; i < count; i++) vars.push(UTF8ToString(HEAPU32[(((varyings) + (i * 4)) >>> 2) >>> 0]));
  GLctx.transformFeedbackVaryings(program, vars, bufferMode);
}

var webglGetUniformLocation = location => webglGetProgramUniformLocation(GLctx.currentProgram, location);

var _emscripten_glUniform1f = (location, v0) => {
  GLctx.uniform1f(webglGetUniformLocation(location), v0);
};

var miniTempWebGLFloatBuffers = [];

function _emscripten_glUniform1fv(location, count, value) {
  value >>>= 0;
  if (count <= 288) {
    // avoid allocation when uploading few enough uniforms
    var view = miniTempWebGLFloatBuffers[count];
    for (var i = 0; i < count; ++i) {
      view[i] = HEAPF32[(((value) + (4 * i)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAPF32.subarray((((value) >>> 2)) >>> 0, ((value + count * 4) >>> 2) >>> 0);
  }
  GLctx.uniform1fv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform1i = (location, v0) => {
  GLctx.uniform1i(webglGetUniformLocation(location), v0);
};

var miniTempWebGLIntBuffers = [];

function _emscripten_glUniform1iv(location, count, value) {
  value >>>= 0;
  if (count <= 288) {
    // avoid allocation when uploading few enough uniforms
    var view = miniTempWebGLIntBuffers[count];
    for (var i = 0; i < count; ++i) {
      view[i] = HEAP32[(((value) + (4 * i)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAP32.subarray((((value) >>> 2)) >>> 0, ((value + count * 4) >>> 2) >>> 0);
  }
  GLctx.uniform1iv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform1ui = (location, v0) => {
  GLctx.uniform1ui(webglGetUniformLocation(location), v0);
};

function _emscripten_glUniform1uiv(location, count, value) {
  value >>>= 0;
  count && GLctx.uniform1uiv(webglGetUniformLocation(location), HEAPU32, ((value) >>> 2), count);
}

var _emscripten_glUniform2f = (location, v0, v1) => {
  GLctx.uniform2f(webglGetUniformLocation(location), v0, v1);
};

function _emscripten_glUniform2fv(location, count, value) {
  value >>>= 0;
  if (count <= 144) {
    // avoid allocation when uploading few enough uniforms
    count *= 2;
    var view = miniTempWebGLFloatBuffers[count];
    for (var i = 0; i < count; i += 2) {
      view[i] = HEAPF32[(((value) + (4 * i)) >>> 2) >>> 0];
      view[i + 1] = HEAPF32[(((value) + (4 * i + 4)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAPF32.subarray((((value) >>> 2)) >>> 0, ((value + count * 8) >>> 2) >>> 0);
  }
  GLctx.uniform2fv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform2i = (location, v0, v1) => {
  GLctx.uniform2i(webglGetUniformLocation(location), v0, v1);
};

function _emscripten_glUniform2iv(location, count, value) {
  value >>>= 0;
  if (count <= 144) {
    // avoid allocation when uploading few enough uniforms
    count *= 2;
    var view = miniTempWebGLIntBuffers[count];
    for (var i = 0; i < count; i += 2) {
      view[i] = HEAP32[(((value) + (4 * i)) >>> 2) >>> 0];
      view[i + 1] = HEAP32[(((value) + (4 * i + 4)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAP32.subarray((((value) >>> 2)) >>> 0, ((value + count * 8) >>> 2) >>> 0);
  }
  GLctx.uniform2iv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform2ui = (location, v0, v1) => {
  GLctx.uniform2ui(webglGetUniformLocation(location), v0, v1);
};

function _emscripten_glUniform2uiv(location, count, value) {
  value >>>= 0;
  count && GLctx.uniform2uiv(webglGetUniformLocation(location), HEAPU32, ((value) >>> 2), count * 2);
}

var _emscripten_glUniform3f = (location, v0, v1, v2) => {
  GLctx.uniform3f(webglGetUniformLocation(location), v0, v1, v2);
};

function _emscripten_glUniform3fv(location, count, value) {
  value >>>= 0;
  if (count <= 96) {
    // avoid allocation when uploading few enough uniforms
    count *= 3;
    var view = miniTempWebGLFloatBuffers[count];
    for (var i = 0; i < count; i += 3) {
      view[i] = HEAPF32[(((value) + (4 * i)) >>> 2) >>> 0];
      view[i + 1] = HEAPF32[(((value) + (4 * i + 4)) >>> 2) >>> 0];
      view[i + 2] = HEAPF32[(((value) + (4 * i + 8)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAPF32.subarray((((value) >>> 2)) >>> 0, ((value + count * 12) >>> 2) >>> 0);
  }
  GLctx.uniform3fv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform3i = (location, v0, v1, v2) => {
  GLctx.uniform3i(webglGetUniformLocation(location), v0, v1, v2);
};

function _emscripten_glUniform3iv(location, count, value) {
  value >>>= 0;
  if (count <= 96) {
    // avoid allocation when uploading few enough uniforms
    count *= 3;
    var view = miniTempWebGLIntBuffers[count];
    for (var i = 0; i < count; i += 3) {
      view[i] = HEAP32[(((value) + (4 * i)) >>> 2) >>> 0];
      view[i + 1] = HEAP32[(((value) + (4 * i + 4)) >>> 2) >>> 0];
      view[i + 2] = HEAP32[(((value) + (4 * i + 8)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAP32.subarray((((value) >>> 2)) >>> 0, ((value + count * 12) >>> 2) >>> 0);
  }
  GLctx.uniform3iv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform3ui = (location, v0, v1, v2) => {
  GLctx.uniform3ui(webglGetUniformLocation(location), v0, v1, v2);
};

function _emscripten_glUniform3uiv(location, count, value) {
  value >>>= 0;
  count && GLctx.uniform3uiv(webglGetUniformLocation(location), HEAPU32, ((value) >>> 2), count * 3);
}

var _emscripten_glUniform4f = (location, v0, v1, v2, v3) => {
  GLctx.uniform4f(webglGetUniformLocation(location), v0, v1, v2, v3);
};

function _emscripten_glUniform4fv(location, count, value) {
  value >>>= 0;
  if (count <= 72) {
    // avoid allocation when uploading few enough uniforms
    var view = miniTempWebGLFloatBuffers[4 * count];
    // hoist the heap out of the loop for size and for pthreads+growth.
    var heap = HEAPF32;
    value = ((value) >>> 2);
    count *= 4;
    for (var i = 0; i < count; i += 4) {
      var dst = value + i;
      view[i] = heap[dst >>> 0];
      view[i + 1] = heap[dst + 1 >>> 0];
      view[i + 2] = heap[dst + 2 >>> 0];
      view[i + 3] = heap[dst + 3 >>> 0];
    }
  } else {
    var view = HEAPF32.subarray((((value) >>> 2)) >>> 0, ((value + count * 16) >>> 2) >>> 0);
  }
  GLctx.uniform4fv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform4i = (location, v0, v1, v2, v3) => {
  GLctx.uniform4i(webglGetUniformLocation(location), v0, v1, v2, v3);
};

function _emscripten_glUniform4iv(location, count, value) {
  value >>>= 0;
  if (count <= 72) {
    // avoid allocation when uploading few enough uniforms
    count *= 4;
    var view = miniTempWebGLIntBuffers[count];
    for (var i = 0; i < count; i += 4) {
      view[i] = HEAP32[(((value) + (4 * i)) >>> 2) >>> 0];
      view[i + 1] = HEAP32[(((value) + (4 * i + 4)) >>> 2) >>> 0];
      view[i + 2] = HEAP32[(((value) + (4 * i + 8)) >>> 2) >>> 0];
      view[i + 3] = HEAP32[(((value) + (4 * i + 12)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAP32.subarray((((value) >>> 2)) >>> 0, ((value + count * 16) >>> 2) >>> 0);
  }
  GLctx.uniform4iv(webglGetUniformLocation(location), view);
}

var _emscripten_glUniform4ui = (location, v0, v1, v2, v3) => {
  GLctx.uniform4ui(webglGetUniformLocation(location), v0, v1, v2, v3);
};

function _emscripten_glUniform4uiv(location, count, value) {
  value >>>= 0;
  count && GLctx.uniform4uiv(webglGetUniformLocation(location), HEAPU32, ((value) >>> 2), count * 4);
}

var _emscripten_glUniformBlockBinding = (program, uniformBlockIndex, uniformBlockBinding) => {
  program = GL.programs[program];
  GLctx.uniformBlockBinding(program, uniformBlockIndex, uniformBlockBinding);
};

function _emscripten_glUniformMatrix2fv(location, count, transpose, value) {
  value >>>= 0;
  if (count <= 72) {
    // avoid allocation when uploading few enough uniforms
    count *= 4;
    var view = miniTempWebGLFloatBuffers[count];
    for (var i = 0; i < count; i += 4) {
      view[i] = HEAPF32[(((value) + (4 * i)) >>> 2) >>> 0];
      view[i + 1] = HEAPF32[(((value) + (4 * i + 4)) >>> 2) >>> 0];
      view[i + 2] = HEAPF32[(((value) + (4 * i + 8)) >>> 2) >>> 0];
      view[i + 3] = HEAPF32[(((value) + (4 * i + 12)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAPF32.subarray((((value) >>> 2)) >>> 0, ((value + count * 16) >>> 2) >>> 0);
  }
  GLctx.uniformMatrix2fv(webglGetUniformLocation(location), !!transpose, view);
}

function _emscripten_glUniformMatrix2x3fv(location, count, transpose, value) {
  value >>>= 0;
  count && GLctx.uniformMatrix2x3fv(webglGetUniformLocation(location), !!transpose, HEAPF32, ((value) >>> 2), count * 6);
}

function _emscripten_glUniformMatrix2x4fv(location, count, transpose, value) {
  value >>>= 0;
  count && GLctx.uniformMatrix2x4fv(webglGetUniformLocation(location), !!transpose, HEAPF32, ((value) >>> 2), count * 8);
}

function _emscripten_glUniformMatrix3fv(location, count, transpose, value) {
  value >>>= 0;
  if (count <= 32) {
    // avoid allocation when uploading few enough uniforms
    count *= 9;
    var view = miniTempWebGLFloatBuffers[count];
    for (var i = 0; i < count; i += 9) {
      view[i] = HEAPF32[(((value) + (4 * i)) >>> 2) >>> 0];
      view[i + 1] = HEAPF32[(((value) + (4 * i + 4)) >>> 2) >>> 0];
      view[i + 2] = HEAPF32[(((value) + (4 * i + 8)) >>> 2) >>> 0];
      view[i + 3] = HEAPF32[(((value) + (4 * i + 12)) >>> 2) >>> 0];
      view[i + 4] = HEAPF32[(((value) + (4 * i + 16)) >>> 2) >>> 0];
      view[i + 5] = HEAPF32[(((value) + (4 * i + 20)) >>> 2) >>> 0];
      view[i + 6] = HEAPF32[(((value) + (4 * i + 24)) >>> 2) >>> 0];
      view[i + 7] = HEAPF32[(((value) + (4 * i + 28)) >>> 2) >>> 0];
      view[i + 8] = HEAPF32[(((value) + (4 * i + 32)) >>> 2) >>> 0];
    }
  } else {
    var view = HEAPF32.subarray((((value) >>> 2)) >>> 0, ((value + count * 36) >>> 2) >>> 0);
  }
  GLctx.uniformMatrix3fv(webglGetUniformLocation(location), !!transpose, view);
}

function _emscripten_glUniformMatrix3x2fv(location, count, transpose, value) {
  value >>>= 0;
  count && GLctx.uniformMatrix3x2fv(webglGetUniformLocation(location), !!transpose, HEAPF32, ((value) >>> 2), count * 6);
}

function _emscripten_glUniformMatrix3x4fv(location, count, transpose, value) {
  value >>>= 0;
  count && GLctx.uniformMatrix3x4fv(webglGetUniformLocation(location), !!transpose, HEAPF32, ((value) >>> 2), count * 12);
}

function _emscripten_glUniformMatrix4fv(location, count, transpose, value) {
  value >>>= 0;
  if (count <= 18) {
    // avoid allocation when uploading few enough uniforms
    var view = miniTempWebGLFloatBuffers[16 * count];
    // hoist the heap out of the loop for size and for pthreads+growth.
    var heap = HEAPF32;
    value = ((value) >>> 2);
    count *= 16;
    for (var i = 0; i < count; i += 16) {
      var dst = value + i;
      view[i] = heap[dst >>> 0];
      view[i + 1] = heap[dst + 1 >>> 0];
      view[i + 2] = heap[dst + 2 >>> 0];
      view[i + 3] = heap[dst + 3 >>> 0];
      view[i + 4] = heap[dst + 4 >>> 0];
      view[i + 5] = heap[dst + 5 >>> 0];
      view[i + 6] = heap[dst + 6 >>> 0];
      view[i + 7] = heap[dst + 7 >>> 0];
      view[i + 8] = heap[dst + 8 >>> 0];
      view[i + 9] = heap[dst + 9 >>> 0];
      view[i + 10] = heap[dst + 10 >>> 0];
      view[i + 11] = heap[dst + 11 >>> 0];
      view[i + 12] = heap[dst + 12 >>> 0];
      view[i + 13] = heap[dst + 13 >>> 0];
      view[i + 14] = heap[dst + 14 >>> 0];
      view[i + 15] = heap[dst + 15 >>> 0];
    }
  } else {
    var view = HEAPF32.subarray((((value) >>> 2)) >>> 0, ((value + count * 64) >>> 2) >>> 0);
  }
  GLctx.uniformMatrix4fv(webglGetUniformLocation(location), !!transpose, view);
}

function _emscripten_glUniformMatrix4x2fv(location, count, transpose, value) {
  value >>>= 0;
  count && GLctx.uniformMatrix4x2fv(webglGetUniformLocation(location), !!transpose, HEAPF32, ((value) >>> 2), count * 8);
}

function _emscripten_glUniformMatrix4x3fv(location, count, transpose, value) {
  value >>>= 0;
  count && GLctx.uniformMatrix4x3fv(webglGetUniformLocation(location), !!transpose, HEAPF32, ((value) >>> 2), count * 12);
}

var _emscripten_glUnmapBuffer = target => {
  if (!emscriptenWebGLValidateMapBufferTarget(target)) {
    GL.recordError(1280);
    err("GL_INVALID_ENUM in glUnmapBuffer");
    return 0;
  }
  var buffer = emscriptenWebGLGetBufferBinding(target);
  var mapping = GL.mappedBuffers[buffer];
  if (!mapping || !mapping.mem) {
    GL.recordError(1282);
    err("buffer was never mapped in glUnmapBuffer");
    return 0;
  }
  if (!(mapping.access & 16)) {
    /* GL_MAP_FLUSH_EXPLICIT_BIT */ webglBufferSubData(target, mapping.offset, mapping.length, mapping.mem);
  }
  _free(mapping.mem);
  mapping.mem = 0;
  return 1;
};

var _emscripten_glUseProgram = program => {
  program = GL.programs[program];
  GLctx.useProgram(program);
  // Record the currently active program so that we can access the uniform
  // mapping table of that program.
  GLctx.currentProgram = program;
};

var _emscripten_glValidateProgram = program => {
  GLctx.validateProgram(GL.programs[program]);
};

var _emscripten_glVertexAttrib1f = (x0, x1) => GLctx.vertexAttrib1f(x0, x1);

function _emscripten_glVertexAttrib1fv(index, v) {
  v >>>= 0;
  GLctx.vertexAttrib1f(index, HEAPF32[v >>> 2]);
}

var _emscripten_glVertexAttrib2f = (x0, x1, x2) => GLctx.vertexAttrib2f(x0, x1, x2);

function _emscripten_glVertexAttrib2fv(index, v) {
  v >>>= 0;
  GLctx.vertexAttrib2f(index, HEAPF32[v >>> 2], HEAPF32[v + 4 >>> 2]);
}

var _emscripten_glVertexAttrib3f = (x0, x1, x2, x3) => GLctx.vertexAttrib3f(x0, x1, x2, x3);

function _emscripten_glVertexAttrib3fv(index, v) {
  v >>>= 0;
  GLctx.vertexAttrib3f(index, HEAPF32[v >>> 2], HEAPF32[v + 4 >>> 2], HEAPF32[v + 8 >>> 2]);
}

var _emscripten_glVertexAttrib4f = (x0, x1, x2, x3, x4) => GLctx.vertexAttrib4f(x0, x1, x2, x3, x4);

function _emscripten_glVertexAttrib4fv(index, v) {
  v >>>= 0;
  GLctx.vertexAttrib4f(index, HEAPF32[v >>> 2], HEAPF32[v + 4 >>> 2], HEAPF32[v + 8 >>> 2], HEAPF32[v + 12 >>> 2]);
}

var _emscripten_glVertexAttribDivisor = (index, divisor) => {
  GLctx.vertexAttribDivisor(index, divisor);
};

var _glVertexAttribDivisor = _emscripten_glVertexAttribDivisor;

var _emscripten_glVertexAttribDivisorANGLE = _glVertexAttribDivisor;

var _emscripten_glVertexAttribDivisorARB = _glVertexAttribDivisor;

var _emscripten_glVertexAttribDivisorEXT = _glVertexAttribDivisor;

var _emscripten_glVertexAttribDivisorNV = _glVertexAttribDivisor;

var _emscripten_glVertexAttribI4i = (x0, x1, x2, x3, x4) => GLctx.vertexAttribI4i(x0, x1, x2, x3, x4);

function _emscripten_glVertexAttribI4iv(index, v) {
  v >>>= 0;
  GLctx.vertexAttribI4i(index, HEAP32[v >>> 2], HEAP32[v + 4 >>> 2], HEAP32[v + 8 >>> 2], HEAP32[v + 12 >>> 2]);
}

var _emscripten_glVertexAttribI4ui = (x0, x1, x2, x3, x4) => GLctx.vertexAttribI4ui(x0, x1, x2, x3, x4);

function _emscripten_glVertexAttribI4uiv(index, v) {
  v >>>= 0;
  GLctx.vertexAttribI4ui(index, HEAPU32[v >>> 2], HEAPU32[v + 4 >>> 2], HEAPU32[v + 8 >>> 2], HEAPU32[v + 12 >>> 2]);
}

function _emscripten_glVertexAttribIPointer(index, size, type, stride, ptr) {
  ptr >>>= 0;
  var cb = GL.currentContext.clientBuffers[index];
  if (!GLctx.currentArrayBufferBinding) {
    cb.size = size;
    cb.type = type;
    cb.normalized = false;
    cb.stride = stride;
    cb.ptr = ptr;
    cb.clientside = true;
    cb.vertexAttribPointerAdaptor = /** @this {WebGLRenderingContext} */ function(index, size, type, normalized, stride, ptr) {
      this.vertexAttribIPointer(index, size, type, stride, ptr);
    };
    return;
  }
  cb.clientside = false;
  GLctx.vertexAttribIPointer(index, size, type, stride, ptr);
}

function _emscripten_glVertexAttribPointer(index, size, type, normalized, stride, ptr) {
  ptr >>>= 0;
  var cb = GL.currentContext.clientBuffers[index];
  if (!GLctx.currentArrayBufferBinding) {
    cb.size = size;
    cb.type = type;
    cb.normalized = normalized;
    cb.stride = stride;
    cb.ptr = ptr;
    cb.clientside = true;
    cb.vertexAttribPointerAdaptor = /** @this {WebGLRenderingContext} */ function(index, size, type, normalized, stride, ptr) {
      this.vertexAttribPointer(index, size, type, normalized, stride, ptr);
    };
    return;
  }
  cb.clientside = false;
  GLctx.vertexAttribPointer(index, size, type, !!normalized, stride, ptr);
}

var _emscripten_glViewport = (x0, x1, x2, x3) => GLctx.viewport(x0, x1, x2, x3);

function _emscripten_glWaitSync(sync, flags, timeout) {
  sync >>>= 0;
  // See WebGL2 vs GLES3 difference on GL_TIMEOUT_IGNORED above (https://www.khronos.org/registry/webgl/specs/latest/2.0/#5.15)
  timeout = Number(timeout);
  GLctx.waitSync(GL.syncs[sync], flags, timeout);
}

var _emscripten_has_asyncify = () => 0;

var doRequestFullscreen = (target, strategy) => {
  if (!JSEvents.fullscreenEnabled()) return -1;
  target = findEventTarget(target);
  if (!target) return -4;
  if (!target.requestFullscreen && !target.webkitRequestFullscreen) {
    return -3;
  }
  // Queue this function call if we're not currently in an event handler and
  // the user saw it appropriate to do so.
  if (!JSEvents.canPerformEventHandlerRequests()) {
    if (strategy.deferUntilInEventHandler) {
      JSEvents.deferCall(JSEvents_requestFullscreen, 1, [ target, strategy ]);
      return 1;
    }
    return -2;
  }
  return JSEvents_requestFullscreen(target, strategy);
};

function _emscripten_request_fullscreen_strategy(target, deferUntilInEventHandler, fullscreenStrategy) {
  target >>>= 0;
  fullscreenStrategy >>>= 0;
  var strategy = {
    scaleMode: HEAP32[((fullscreenStrategy) >>> 2) >>> 0],
    canvasResolutionScaleMode: HEAP32[(((fullscreenStrategy) + (4)) >>> 2) >>> 0],
    filteringMode: HEAP32[(((fullscreenStrategy) + (8)) >>> 2) >>> 0],
    deferUntilInEventHandler,
    canvasResizedCallback: HEAP32[(((fullscreenStrategy) + (12)) >>> 2) >>> 0],
    canvasResizedCallbackUserData: HEAP32[(((fullscreenStrategy) + (16)) >>> 2) >>> 0]
  };
  return doRequestFullscreen(target, strategy);
}

function _emscripten_request_pointerlock(target, deferUntilInEventHandler) {
  target >>>= 0;
  target = findEventTarget(target);
  if (!target) return -4;
  if (!target.requestPointerLock) {
    return -1;
  }
  // Queue this function call if we're not currently in an event handler and
  // the user saw it appropriate to do so.
  if (!JSEvents.canPerformEventHandlerRequests()) {
    if (deferUntilInEventHandler) {
      JSEvents.deferCall(requestPointerLock, 2, [ target ]);
      return 1;
    }
    return -2;
  }
  return requestPointerLock(target);
}

var alignMemory = (size, alignment) => {
  assert(alignment, "alignment argument is required");
  return Math.ceil(size / alignment) * alignment;
};

var growMemory = size => {
  var oldHeapSize = wasmMemory.buffer.byteLength;
  var pages = ((size - oldHeapSize + 65535) / 65536) | 0;
  try {
    // round size grow request up to wasm page size (fixed 64KB per spec)
    wasmMemory.grow(pages);
    // .grow() takes a delta compared to the previous size
    updateMemoryViews();
    return 1;
  } catch (e) {
    err(`growMemory: Attempted to grow heap from ${oldHeapSize} bytes to ${size} bytes, but got error: ${e}`);
  }
};

function _emscripten_resize_heap(requestedSize) {
  requestedSize >>>= 0;
  var oldSize = HEAPU8.length;
  // With multithreaded builds, races can happen (another thread might increase the size
  // in between), so return a failure, and let the caller retry.
  assert(requestedSize > oldSize);
  // Memory resize rules:
  // 1.  Always increase heap size to at least the requested size, rounded up
  //     to next page multiple.
  // 2a. If MEMORY_GROWTH_LINEAR_STEP == -1, excessively resize the heap
  //     geometrically: increase the heap size according to
  //     MEMORY_GROWTH_GEOMETRIC_STEP factor (default +20%), At most
  //     overreserve by MEMORY_GROWTH_GEOMETRIC_CAP bytes (default 96MB).
  // 2b. If MEMORY_GROWTH_LINEAR_STEP != -1, excessively resize the heap
  //     linearly: increase the heap size by at least
  //     MEMORY_GROWTH_LINEAR_STEP bytes.
  // 3.  Max size for the heap is capped at 2048MB-WASM_PAGE_SIZE, or by
  //     MAXIMUM_MEMORY, or by ASAN limit, depending on which is smallest
  // 4.  If we were unable to allocate as much memory, it may be due to
  //     over-eager decision to excessively reserve due to (3) above.
  //     Hence if an allocation fails, cut down on the amount of excess
  //     growth, in an attempt to succeed to perform a smaller allocation.
  // A limit is set for how much we can grow. We should not exceed that
  // (the wasm binary specifies it, so if we tried, we'd fail anyhow).
  var maxHeapSize = getHeapMax();
  if (requestedSize > maxHeapSize) {
    err(`Cannot enlarge memory, requested ${requestedSize} bytes, but the limit is ${maxHeapSize} bytes!`);
    return false;
  }
  // Loop through potential heap size increases. If we attempt a too eager
  // reservation that fails, cut down on the attempted size and reserve a
  // smaller bump instead. (max 3 times, chosen somewhat arbitrarily)
  for (var cutDown = 1; cutDown <= 4; cutDown *= 2) {
    var overGrownHeapSize = oldSize * (1 + .2 / cutDown);
    // ensure geometric growth
    // but limit overreserving (default to capping at +96MB overgrowth at most)
    overGrownHeapSize = Math.min(overGrownHeapSize, requestedSize + 100663296);
    var newSize = Math.min(maxHeapSize, alignMemory(Math.max(requestedSize, overGrownHeapSize), 65536));
    var replacement = growMemory(newSize);
    if (replacement) {
      return true;
    }
  }
  err(`Failed to grow the heap from ${oldSize} bytes to ${newSize} bytes, not enough memory!`);
  return false;
}

/** @suppress {checkTypes} */ var _emscripten_sample_gamepad_data = () => {
  try {
    if (navigator.getGamepads) return (JSEvents.lastGamepadState = navigator.getGamepads()) ? 0 : -1;
  } catch (e) {
    err(`navigator.getGamepads() exists, but failed to execute with exception ${e}. Disabling Gamepad access.`);
    navigator.getGamepads = null;
  }
  return -1;
};

var registerBeforeUnloadEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString) => {
  var beforeUnloadEventHandlerFunc = e => {
    // Note: This is always called on the main browser thread, since it needs synchronously return a value!
    var confirmationMessage = getWasmTableEntry(callbackfunc)(eventTypeId, 0, userData);
    if (confirmationMessage) {
      confirmationMessage = UTF8ToString(confirmationMessage);
    }
    if (confirmationMessage) {
      e.preventDefault();
      e.returnValue = confirmationMessage;
      return confirmationMessage;
    }
  };
  var eventHandler = {
    target: findEventTarget(target),
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: beforeUnloadEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_beforeunload_callback_on_thread(userData, callbackfunc, targetThread) {
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  if (typeof onbeforeunload == "undefined") return -1;
  // beforeunload callback can only be registered on the main browser thread, because the page will go away immediately after returning from the handler,
  // and there is no time to start proxying it anywhere.
  if (targetThread !== 1) return -5;
  return registerBeforeUnloadEventCallback(2, userData, true, callbackfunc, 28, "beforeunload");
}

var registerFocusEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 256;
  JSEvents.focusEvent ||= _malloc(eventSize);
  var focusEventHandlerFunc = e => {
    var nodeName = JSEvents.getNodeNameForTarget(e.target);
    var id = e.target.id ?? "";
    var focusEvent = JSEvents.focusEvent;
    stringToUTF8(nodeName, focusEvent + 0, 128);
    stringToUTF8(id, focusEvent + 128, 128);
    if (getWasmTableEntry(callbackfunc)(eventTypeId, focusEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target: findEventTarget(target),
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: focusEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_blur_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerFocusEventCallback(target, userData, useCapture, callbackfunc, 12, "blur", targetThread);
}

function _emscripten_set_element_css_size(target, width, height) {
  target >>>= 0;
  target = findEventTarget(target);
  if (!target) return -4;
  target.style.width = width + "px";
  target.style.height = height + "px";
  return 0;
}

function _emscripten_set_focus_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerFocusEventCallback(target, userData, useCapture, callbackfunc, 13, "focus", targetThread);
}

var fillFullscreenChangeEventData = eventStruct => {
  var fullscreenElement = getFullscreenElement();
  var isFullscreen = !!fullscreenElement;
  // Assigning a boolean to HEAP32 with expected type coercion.
  /** @suppress{checkTypes} */ HEAP8[eventStruct >>> 0] = isFullscreen;
  HEAP8[(eventStruct) + (1) >>> 0] = JSEvents.fullscreenEnabled();
  // If transitioning to fullscreen, report info about the element that is now fullscreen.
  // If transitioning to windowed mode, report info about the element that just was fullscreen.
  var reportedElement = isFullscreen ? fullscreenElement : JSEvents.previousFullscreenElement;
  var nodeName = JSEvents.getNodeNameForTarget(reportedElement);
  var id = reportedElement?.id ?? "";
  stringToUTF8(nodeName, eventStruct + 2, 128);
  stringToUTF8(id, eventStruct + 130, 128);
  HEAP32[(((eventStruct) + (260)) >>> 2) >>> 0] = reportedElement?.clientWidth ?? 0;
  HEAP32[(((eventStruct) + (264)) >>> 2) >>> 0] = reportedElement?.clientHeight ?? 0;
  HEAP32[(((eventStruct) + (268)) >>> 2) >>> 0] = screen.width;
  HEAP32[(((eventStruct) + (272)) >>> 2) >>> 0] = screen.height;
  if (isFullscreen) {
    JSEvents.previousFullscreenElement = fullscreenElement;
  }
};

var registerFullscreenChangeEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 276;
  JSEvents.fullscreenChangeEvent ||= _malloc(eventSize);
  var fullscreenChangeEventHandlerFunc = e => {
    var fullscreenChangeEvent = JSEvents.fullscreenChangeEvent;
    fillFullscreenChangeEventData(fullscreenChangeEvent);
    if (getWasmTableEntry(callbackfunc)(eventTypeId, fullscreenChangeEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target,
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: fullscreenChangeEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_fullscreenchange_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  if (!JSEvents.fullscreenEnabled()) return -1;
  target = findEventTarget(target);
  if (!target) return -4;
  // TODO: When this block is removed, also change test/test_html5_remove_event_listener.c test expectation on emscripten_set_fullscreenchange_callback().
  registerFullscreenChangeEventCallback(target, userData, useCapture, callbackfunc, 19, "webkitfullscreenchange", targetThread);
  return registerFullscreenChangeEventCallback(target, userData, useCapture, callbackfunc, 19, "fullscreenchange", targetThread);
}

var registerGamepadEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 1240;
  JSEvents.gamepadEvent ||= _malloc(eventSize);
  var gamepadEventHandlerFunc = e => {
    var gamepadEvent = JSEvents.gamepadEvent;
    fillGamepadEventData(gamepadEvent, e["gamepad"]);
    if (getWasmTableEntry(callbackfunc)(eventTypeId, gamepadEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target: findEventTarget(target),
    allowsDeferredCalls: true,
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: gamepadEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_gamepadconnected_callback_on_thread(userData, useCapture, callbackfunc, targetThread) {
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  if (_emscripten_sample_gamepad_data()) return -1;
  return registerGamepadEventCallback(2, userData, useCapture, callbackfunc, 26, "gamepadconnected", targetThread);
}

function _emscripten_set_gamepaddisconnected_callback_on_thread(userData, useCapture, callbackfunc, targetThread) {
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  if (_emscripten_sample_gamepad_data()) return -1;
  return registerGamepadEventCallback(2, userData, useCapture, callbackfunc, 27, "gamepaddisconnected", targetThread);
}

var registerKeyEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 160;
  JSEvents.keyEvent ||= _malloc(eventSize);
  var keyEventHandlerFunc = e => {
    assert(e);
    var keyEventData = JSEvents.keyEvent;
    HEAPF64[((keyEventData) >>> 3) >>> 0] = e.timeStamp;
    var idx = ((keyEventData) >>> 2);
    HEAP32[idx + 2 >>> 0] = e.location;
    HEAP8[keyEventData + 12 >>> 0] = e.ctrlKey;
    HEAP8[keyEventData + 13 >>> 0] = e.shiftKey;
    HEAP8[keyEventData + 14 >>> 0] = e.altKey;
    HEAP8[keyEventData + 15 >>> 0] = e.metaKey;
    HEAP8[keyEventData + 16 >>> 0] = e.repeat;
    HEAP32[idx + 5 >>> 0] = e.charCode;
    HEAP32[idx + 6 >>> 0] = e.keyCode;
    HEAP32[idx + 7 >>> 0] = e.which;
    stringToUTF8(e.key ?? "", keyEventData + 32, 32);
    stringToUTF8(e.code ?? "", keyEventData + 64, 32);
    stringToUTF8(e.char ?? "", keyEventData + 96, 32);
    stringToUTF8(e.locale ?? "", keyEventData + 128, 32);
    if (getWasmTableEntry(callbackfunc)(eventTypeId, keyEventData, userData)) e.preventDefault();
  };
  var eventHandler = {
    target: findEventTarget(target),
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: keyEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_keydown_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerKeyEventCallback(target, userData, useCapture, callbackfunc, 2, "keydown", targetThread);
}

function _emscripten_set_keypress_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerKeyEventCallback(target, userData, useCapture, callbackfunc, 1, "keypress", targetThread);
}

function _emscripten_set_keyup_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerKeyEventCallback(target, userData, useCapture, callbackfunc, 3, "keyup", targetThread);
}

var _emscripten_set_main_loop_arg = function(func, arg, fps, simulateInfiniteLoop) {
  func >>>= 0;
  arg >>>= 0;
  var iterFunc = () => getWasmTableEntry(func)(arg);
  setMainLoop(iterFunc, fps, simulateInfiniteLoop, arg);
};

var fillMouseEventData = (eventStruct, e, target) => {
  assert(eventStruct % 4 == 0);
  HEAPF64[((eventStruct) >>> 3) >>> 0] = e.timeStamp;
  var idx = ((eventStruct) >>> 2);
  HEAP32[idx + 2 >>> 0] = e.screenX;
  HEAP32[idx + 3 >>> 0] = e.screenY;
  HEAP32[idx + 4 >>> 0] = e.clientX;
  HEAP32[idx + 5 >>> 0] = e.clientY;
  HEAP8[eventStruct + 24 >>> 0] = e.ctrlKey;
  HEAP8[eventStruct + 25 >>> 0] = e.shiftKey;
  HEAP8[eventStruct + 26 >>> 0] = e.altKey;
  HEAP8[eventStruct + 27 >>> 0] = e.metaKey;
  HEAP16[idx * 2 + 14 >>> 0] = e.button;
  HEAP16[idx * 2 + 15 >>> 0] = e.buttons;
  HEAP32[idx + 8 >>> 0] = e.movementX;
  HEAP32[idx + 9 >>> 0] = e.movementY;
  // Note: rect contains doubles (truncated to placate SAFE_HEAP, which is the same behaviour when writing to HEAP32 anyway)
  var rect = getBoundingClientRect(target);
  HEAP32[idx + 10 >>> 0] = e.clientX - (rect.left | 0);
  HEAP32[idx + 11 >>> 0] = e.clientY - (rect.top | 0);
};

var registerMouseEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 64;
  JSEvents.mouseEvent ||= _malloc(eventSize);
  target = findEventTarget(target);
  var mouseEventHandlerFunc = e => {
    // TODO: Make this access thread safe, or this could update live while app is reading it.
    fillMouseEventData(JSEvents.mouseEvent, e, target);
    if (getWasmTableEntry(callbackfunc)(eventTypeId, JSEvents.mouseEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target,
    allowsDeferredCalls: eventTypeString != "mousemove" && eventTypeString != "mouseenter" && eventTypeString != "mouseleave",
    // Mouse move events do not allow fullscreen/pointer lock requests to be handled in them!
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: mouseEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_mousedown_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerMouseEventCallback(target, userData, useCapture, callbackfunc, 5, "mousedown", targetThread);
}

function _emscripten_set_mouseenter_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerMouseEventCallback(target, userData, useCapture, callbackfunc, 33, "mouseenter", targetThread);
}

function _emscripten_set_mouseleave_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerMouseEventCallback(target, userData, useCapture, callbackfunc, 34, "mouseleave", targetThread);
}

function _emscripten_set_mousemove_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerMouseEventCallback(target, userData, useCapture, callbackfunc, 8, "mousemove", targetThread);
}

function _emscripten_set_mouseup_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerMouseEventCallback(target, userData, useCapture, callbackfunc, 6, "mouseup", targetThread);
}

var fillPointerlockChangeEventData = eventStruct => {
  var pointerLockElement = document.pointerLockElement;
  var isPointerlocked = !!pointerLockElement;
  // Assigning a boolean to HEAP32 with expected type coercion.
  /** @suppress{checkTypes} */ HEAP8[eventStruct >>> 0] = isPointerlocked;
  var nodeName = JSEvents.getNodeNameForTarget(pointerLockElement);
  var id = pointerLockElement?.id ?? "";
  stringToUTF8(nodeName, eventStruct + 1, 128);
  stringToUTF8(id, eventStruct + 129, 128);
};

var registerPointerlockChangeEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 257;
  JSEvents.pointerlockChangeEvent ||= _malloc(eventSize);
  var pointerlockChangeEventHandlerFunc = e => {
    var pointerlockChangeEvent = JSEvents.pointerlockChangeEvent;
    fillPointerlockChangeEventData(pointerlockChangeEvent);
    if (getWasmTableEntry(callbackfunc)(eventTypeId, pointerlockChangeEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target,
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: pointerlockChangeEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_pointerlockchange_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  if (!document.body?.requestPointerLock) {
    return -1;
  }
  target = findEventTarget(target);
  if (!target) return -4;
  return registerPointerlockChangeEventCallback(target, userData, useCapture, callbackfunc, 20, "pointerlockchange", targetThread);
}

var registerUiEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 36;
  JSEvents.uiEvent ||= _malloc(eventSize);
  target = findEventTarget(target);
  var uiEventHandlerFunc = e => {
    if (e.target != target) {
      // Never take ui events such as scroll via a 'bubbled' route, but always from the direct element that
      // was targeted. Otherwise e.g. if app logs a message in response to a page scroll, the Emscripten log
      // message box could cause to scroll, generating a new (bubbled) scroll message, causing a new log print,
      // causing a new scroll, etc..
      return;
    }
    var b = document.body;
    // Take document.body to a variable, Closure compiler does not outline access to it on its own.
    if (!b) {
      // During a page unload 'body' can be null, with "Cannot read property 'clientWidth' of null" being thrown
      return;
    }
    var uiEvent = JSEvents.uiEvent;
    HEAP32[((uiEvent) >>> 2) >>> 0] = 0;
    // always zero for resize and scroll
    HEAP32[(((uiEvent) + (4)) >>> 2) >>> 0] = b.clientWidth;
    HEAP32[(((uiEvent) + (8)) >>> 2) >>> 0] = b.clientHeight;
    HEAP32[(((uiEvent) + (12)) >>> 2) >>> 0] = innerWidth;
    HEAP32[(((uiEvent) + (16)) >>> 2) >>> 0] = innerHeight;
    HEAP32[(((uiEvent) + (20)) >>> 2) >>> 0] = outerWidth;
    HEAP32[(((uiEvent) + (24)) >>> 2) >>> 0] = outerHeight;
    HEAP32[(((uiEvent) + (28)) >>> 2) >>> 0] = pageXOffset | 0;
    // scroll offsets are float
    HEAP32[(((uiEvent) + (32)) >>> 2) >>> 0] = pageYOffset | 0;
    if (getWasmTableEntry(callbackfunc)(eventTypeId, uiEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target,
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: uiEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_resize_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerUiEventCallback(target, userData, useCapture, callbackfunc, 10, "resize", targetThread);
}

var registerTouchEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 1552;
  JSEvents.touchEvent ||= _malloc(eventSize);
  target = findEventTarget(target);
  var touchEventHandlerFunc = e => {
    assert(e);
    var t, touches = {}, et = e.touches;
    // To ease marshalling different kinds of touches that browser reports (all touches are listed in e.touches,
    // only changed touches in e.changedTouches, and touches on target at a.targetTouches), mark a boolean in
    // each Touch object so that we can later loop only once over all touches we see to marshall over to Wasm.
    for (let t of et) {
      // Browser might recycle the generated Touch objects between each frame (Firefox on Android), so reset any
      // changed/target states we may have set from previous frame.
      t.isChanged = t.onTarget = 0;
      touches[t.identifier] = t;
    }
    // Mark which touches are part of the changedTouches list.
    for (let t of e.changedTouches) {
      t.isChanged = 1;
      touches[t.identifier] = t;
    }
    // Mark which touches are part of the targetTouches list.
    for (let t of e.targetTouches) {
      touches[t.identifier].onTarget = 1;
    }
    var touchEvent = JSEvents.touchEvent;
    HEAPF64[((touchEvent) >>> 3) >>> 0] = e.timeStamp;
    HEAP8[touchEvent + 12 >>> 0] = e.ctrlKey;
    HEAP8[touchEvent + 13 >>> 0] = e.shiftKey;
    HEAP8[touchEvent + 14 >>> 0] = e.altKey;
    HEAP8[touchEvent + 15 >>> 0] = e.metaKey;
    var idx = touchEvent + 16;
    var targetRect = getBoundingClientRect(target);
    var numTouches = 0;
    for (let t of Object.values(touches)) {
      var idx32 = ((idx) >>> 2);
      // Pre-shift the ptr to index to HEAP32 to save code size
      HEAP32[idx32 + 0 >>> 0] = t.identifier;
      HEAP32[idx32 + 1 >>> 0] = t.screenX;
      HEAP32[idx32 + 2 >>> 0] = t.screenY;
      HEAP32[idx32 + 3 >>> 0] = t.clientX;
      HEAP32[idx32 + 4 >>> 0] = t.clientY;
      HEAP32[idx32 + 5 >>> 0] = t.pageX;
      HEAP32[idx32 + 6 >>> 0] = t.pageY;
      HEAP8[idx + 28 >>> 0] = t.isChanged;
      HEAP8[idx + 29 >>> 0] = t.onTarget;
      HEAP32[idx32 + 8 >>> 0] = t.clientX - (targetRect.left | 0);
      HEAP32[idx32 + 9 >>> 0] = t.clientY - (targetRect.top | 0);
      idx += 48;
      if (++numTouches > 31) {
        break;
      }
    }
    HEAP32[(((touchEvent) + (8)) >>> 2) >>> 0] = numTouches;
    if (getWasmTableEntry(callbackfunc)(eventTypeId, touchEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target,
    allowsDeferredCalls: eventTypeString == "touchstart" || eventTypeString == "touchend",
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: touchEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_touchcancel_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerTouchEventCallback(target, userData, useCapture, callbackfunc, 25, "touchcancel", targetThread);
}

function _emscripten_set_touchend_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerTouchEventCallback(target, userData, useCapture, callbackfunc, 23, "touchend", targetThread);
}

function _emscripten_set_touchmove_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerTouchEventCallback(target, userData, useCapture, callbackfunc, 24, "touchmove", targetThread);
}

function _emscripten_set_touchstart_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  return registerTouchEventCallback(target, userData, useCapture, callbackfunc, 22, "touchstart", targetThread);
}

var fillVisibilityChangeEventData = eventStruct => {
  var visibilityStates = [ "hidden", "visible", "prerender", "unloaded" ];
  var visibilityState = visibilityStates.indexOf(document.visibilityState);
  // Assigning a boolean to HEAP32 with expected type coercion.
  /** @suppress{checkTypes} */ HEAP8[eventStruct >>> 0] = document.hidden;
  HEAP32[(((eventStruct) + (4)) >>> 2) >>> 0] = visibilityState;
};

var registerVisibilityChangeEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 8;
  JSEvents.visibilityChangeEvent ||= _malloc(eventSize);
  var visibilityChangeEventHandlerFunc = e => {
    var visibilityChangeEvent = JSEvents.visibilityChangeEvent;
    fillVisibilityChangeEventData(visibilityChangeEvent);
    if (getWasmTableEntry(callbackfunc)(eventTypeId, visibilityChangeEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target,
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: visibilityChangeEventHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_visibilitychange_callback_on_thread(userData, useCapture, callbackfunc, targetThread) {
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  if (!specialHTMLTargets[1]) {
    return -4;
  }
  return registerVisibilityChangeEventCallback(specialHTMLTargets[1], userData, useCapture, callbackfunc, 21, "visibilitychange", targetThread);
}

var registerWheelEventCallback = (target, userData, useCapture, callbackfunc, eventTypeId, eventTypeString, targetThread) => {
  var eventSize = 96;
  JSEvents.wheelEvent ||= _malloc(eventSize);
  // The DOM Level 3 events spec event 'wheel'
  var wheelHandlerFunc = e => {
    var wheelEvent = JSEvents.wheelEvent;
    fillMouseEventData(wheelEvent, e, target);
    HEAPF64[(((wheelEvent) + (64)) >>> 3) >>> 0] = e["deltaX"];
    HEAPF64[(((wheelEvent) + (72)) >>> 3) >>> 0] = e["deltaY"];
    HEAPF64[(((wheelEvent) + (80)) >>> 3) >>> 0] = e["deltaZ"];
    HEAP32[(((wheelEvent) + (88)) >>> 2) >>> 0] = e["deltaMode"];
    if (getWasmTableEntry(callbackfunc)(eventTypeId, wheelEvent, userData)) e.preventDefault();
  };
  var eventHandler = {
    target,
    allowsDeferredCalls: true,
    eventTypeString,
    eventTypeId,
    userData,
    callbackfunc,
    handlerFunc: wheelHandlerFunc,
    useCapture
  };
  return JSEvents.registerOrRemoveHandler(eventHandler);
};

function _emscripten_set_wheel_callback_on_thread(target, userData, useCapture, callbackfunc, targetThread) {
  target >>>= 0;
  userData >>>= 0;
  callbackfunc >>>= 0;
  targetThread >>>= 0;
  target = findEventTarget(target);
  if (!target) return -4;
  if (typeof target.onwheel != "undefined") {
    return registerWheelEventCallback(target, userData, useCapture, callbackfunc, 9, "wheel", targetThread);
  } else {
    return -1;
  }
}

function _emscripten_set_window_title(title) {
  title >>>= 0;
  return document.title = UTF8ToString(title);
}

var _emscripten_sleep = () => {
  abort("Please compile your program with async support in order to use asynchronous operations like emscripten_sleep");
};

var ENV = {};

var getExecutableName = () => thisProgram;

var getEnvStrings = () => {
  if (!getEnvStrings.strings) {
    // Default values.
    var lang = (globalThis.navigator?.language ?? "C").replace("-", "_") + ".UTF-8";
    var env = {
      "USER": "web_user",
      "LOGNAME": "web_user",
      "PATH": "/",
      "PWD": "/",
      "HOME": "/home/web_user",
      "LANG": lang,
      "_": getExecutableName()
    };
    // Apply the user-provided values, if any.
    for (var x in ENV) {
      // x is a key in ENV; if ENV[x] is undefined, that means it was
      // explicitly set to be so. We allow user code to do that to
      // force variables with default values to remain unset.
      if (ENV[x] === undefined) delete env[x]; else env[x] = ENV[x];
    }
    var strings = [];
    for (var x in env) {
      strings.push(`${x}=${env[x]}`);
    }
    getEnvStrings.strings = strings;
  }
  return getEnvStrings.strings;
};

function _environ_get(__environ, environ_buf) {
  __environ >>>= 0;
  environ_buf >>>= 0;
  var bufSize = 0;
  var envp = 0;
  for (var string of getEnvStrings()) {
    var ptr = environ_buf + bufSize;
    HEAPU32[(((__environ) + (envp)) >>> 2) >>> 0] = ptr;
    bufSize += stringToUTF8(string, ptr, Infinity) + 1;
    envp += 4;
  }
  return 0;
}

function _environ_sizes_get(penviron_count, penviron_buf_size) {
  penviron_count >>>= 0;
  penviron_buf_size >>>= 0;
  var strings = getEnvStrings();
  HEAPU32[((penviron_count) >>> 2) >>> 0] = strings.length;
  var bufSize = 0;
  for (var string of strings) {
    bufSize += lengthBytesUTF8(string) + 1;
  }
  HEAPU32[((penviron_buf_size) >>> 2) >>> 0] = bufSize;
  return 0;
}

function _fd_close(fd) {
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    FS.close(stream);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

function _fd_fdstat_get(fd, pbuf) {
  pbuf >>>= 0;
  try {
    var rightsBase = 0;
    var rightsInheriting = 0;
    var flags = 0;
    {
      var stream = SYSCALLS.getStreamFromFD(fd);
      // All character devices are terminals (other things a Linux system would
      // assume is a character device, like the mouse, we have special APIs for).
      var type = stream.tty ? 2 : FS.isDir(stream.mode) ? 3 : FS.isLink(stream.mode) ? 7 : 4;
    }
    HEAP8[pbuf >>> 0] = type;
    HEAP16[(((pbuf) + (2)) >>> 1) >>> 0] = flags;
    HEAP64[(((pbuf) + (8)) >>> 3) >>> 0] = BigInt(rightsBase);
    HEAP64[(((pbuf) + (16)) >>> 3) >>> 0] = BigInt(rightsInheriting);
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

/** @param {number=} offset */ var doReadv = (stream, iov, iovcnt, offset) => {
  var ret = 0;
  for (var i = 0; i < iovcnt; i++) {
    var ptr = HEAPU32[((iov) >>> 2) >>> 0];
    var len = HEAPU32[(((iov) + (4)) >>> 2) >>> 0];
    iov += 8;
    try {
      var curr = FS.read(stream, HEAP8, ptr, len, offset);
    } catch (e) {
      // On a non-blocking stream a subsequent read may would-block after we
      // already gathered data. POSIX readv is a single gather-read: return
      // what we have rather than failing the whole call.
      if (ret > 0 && e instanceof FS.ErrnoError && (e.errno == 6 || e.errno == 6)) {
        break;
      }
      throw e;
    }
    if (curr < 0) return -1;
    ret += curr;
    if (curr < len) break;
    // nothing more to read
    if (typeof offset != "undefined") {
      offset += curr;
    }
  }
  return ret;
};

function _fd_read(fd, iov, iovcnt, pnum) {
  iov >>>= 0;
  iovcnt >>>= 0;
  pnum >>>= 0;
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    var num = doReadv(stream, iov, iovcnt);
    HEAPU32[((pnum) >>> 2) >>> 0] = num;
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

function _fd_seek(fd, offset, whence, newOffset) {
  offset = bigintToI53Checked(offset);
  newOffset >>>= 0;
  try {
    if (isNaN(offset)) return 22;
    var stream = SYSCALLS.getStreamFromFD(fd);
    FS.llseek(stream, offset, whence);
    HEAP64[((newOffset) >>> 3) >>> 0] = BigInt(stream.position);
    if (stream.getdents && !offset && whence === 0) stream.getdents = null;
    // reset readdir state
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

/** @param {number=} offset */ var doWritev = (stream, iov, iovcnt, offset) => {
  // Gather all iovecs into one contiguous buffer and issue a single
  // FS.write, matching POSIX writev's single gather-write semantics (as
  // __syscall_sendmsg already does). Per-iovec writes fragment a stream
  // socket send into multiple segments, breaking stream byte semantics.
  if (iovcnt == 1) {
    // Single iovec: write directly from HEAP8, no gather buffer needed.
    return FS.write(stream, HEAP8, HEAPU32[((iov) >>> 2) >>> 0], HEAPU32[(((iov) + (4)) >>> 2) >>> 0], offset);
  }
  var total = 0;
  for (var i = 0, p = iov; i < iovcnt; i++, p += 8) {
    total += HEAPU32[(((p) + (4)) >>> 2) >>> 0];
  }
  var view = new Uint8Array(total);
  var voff = 0;
  for (var i = 0; i < iovcnt; i++, iov += 8) {
    var ptr = HEAPU32[((iov) >>> 2) >>> 0];
    var len = HEAPU32[(((iov) + (4)) >>> 2) >>> 0];
    view.set(HEAPU8.subarray(ptr >>> 0, ptr + len >>> 0), voff);
    voff += len;
  }
  return FS.write(stream, view, 0, total, offset);
};

function _fd_write(fd, iov, iovcnt, pnum) {
  iov >>>= 0;
  iovcnt >>>= 0;
  pnum >>>= 0;
  try {
    var stream = SYSCALLS.getStreamFromFD(fd);
    var num = doWritev(stream, iov, iovcnt);
    HEAPU32[((pnum) >>> 2) >>> 0] = num;
    return 0;
  } catch (e) {
    if (typeof FS == "undefined" || !(e.name === "ErrnoError")) throw e;
    return e.errno;
  }
}

var _glActiveTexture = _emscripten_glActiveTexture;

var _glAttachShader = _emscripten_glAttachShader;

var _glBindBuffer = _emscripten_glBindBuffer;

var _glBindSampler = _emscripten_glBindSampler;

var _glBindTexture = _emscripten_glBindTexture;

var _glBlendEquation = _emscripten_glBlendEquation;

var _glBlendEquationSeparate = _emscripten_glBlendEquationSeparate;

var _glBlendFuncSeparate = _emscripten_glBlendFuncSeparate;

var _glBufferData = _emscripten_glBufferData;

var _glBufferSubData = _emscripten_glBufferSubData;

var _glClear = _emscripten_glClear;

var _glClearColor = _emscripten_glClearColor;

var _glCompileShader = _emscripten_glCompileShader;

var _glCreateProgram = _emscripten_glCreateProgram;

var _glCreateShader = _emscripten_glCreateShader;

var _glDeleteShader = _emscripten_glDeleteShader;

var _glDeleteTextures = _emscripten_glDeleteTextures;

var _glDetachShader = _emscripten_glDetachShader;

var _glDisable = _emscripten_glDisable;

var _glEnable = _emscripten_glEnable;

var _glEnableVertexAttribArray = _emscripten_glEnableVertexAttribArray;

var _glGenBuffers = _emscripten_glGenBuffers;

var _glGenSamplers = _emscripten_glGenSamplers;

var _glGenTextures = _emscripten_glGenTextures;

var _glGetAttribLocation = _emscripten_glGetAttribLocation;

var _glGetIntegerv = _emscripten_glGetIntegerv;

var _glGetProgramInfoLog = _emscripten_glGetProgramInfoLog;

var _glGetProgramiv = _emscripten_glGetProgramiv;

var _glGetShaderInfoLog = _emscripten_glGetShaderInfoLog;

var _glGetShaderiv = _emscripten_glGetShaderiv;

var _glGetString = _emscripten_glGetString;

var _glGetUniformLocation = _emscripten_glGetUniformLocation;

var _glIsEnabled = _emscripten_glIsEnabled;

var _glIsProgram = _emscripten_glIsProgram;

var _glLinkProgram = _emscripten_glLinkProgram;

var _glPixelStorei = _emscripten_glPixelStorei;

var _glSamplerParameteri = _emscripten_glSamplerParameteri;

var _glScissor = _emscripten_glScissor;

var _glShaderSource = _emscripten_glShaderSource;

var _glTexImage2D = _emscripten_glTexImage2D;

var _glTexParameteri = _emscripten_glTexParameteri;

var _glTexSubImage2D = _emscripten_glTexSubImage2D;

var _glUniform1i = _emscripten_glUniform1i;

var _glUniformMatrix4fv = _emscripten_glUniformMatrix4fv;

var _glUseProgram = _emscripten_glUseProgram;

var _glVertexAttribPointer = _emscripten_glVertexAttribPointer;

var _glViewport = _emscripten_glViewport;

var autoResumeAudioContext = ctx => {
  for (var event of [ "keydown", "mousedown", "touchstart" ]) {
    for (var element of [ document, document.getElementById("canvas") ]) {
      element?.addEventListener(event, () => {
        if (ctx.state === "suspended") ctx.resume();
      }, {
        "once": true
      });
    }
  }
};

var dynCall = (sig, ptr, args = [], promising = false) => {
  assert(ptr, `null function pointer in dynCall`);
  assert(!promising, "async dynCall is not supported in this mode");
  assert(getWasmTableEntry(ptr), `missing table entry in dynCall: ${ptr}`);
  var func = getWasmTableEntry(ptr);
  var rtn = func(...args);
  function convert(rtn) {
    return sig[0] == "p" ? rtn >>> 0 : rtn;
  }
  return convert(rtn);
};

/**
   * @param {number} ptr
   * @param {number} value
   * @param {string} type
   */ function setValue(ptr, value, type = "i8") {
  if (type.endsWith("*")) type = "*";
  switch (type) {
   case "i1":
    HEAP8[ptr >>> 0] = value;
    break;

   case "i8":
    HEAP8[ptr >>> 0] = value;
    break;

   case "i16":
    HEAP16[((ptr) >>> 1) >>> 0] = value;
    break;

   case "i32":
    HEAP32[((ptr) >>> 2) >>> 0] = value;
    break;

   case "i64":
    HEAP64[((ptr) >>> 3) >>> 0] = BigInt(value);
    break;

   case "float":
    HEAPF32[((ptr) >>> 2) >>> 0] = value;
    break;

   case "double":
    HEAPF64[((ptr) >>> 3) >>> 0] = value;
    break;

   case "*":
    HEAPU32[((ptr) >>> 2) >>> 0] = value;
    break;

   default:
    abort(`invalid type for setValue: ${type}`);
  }
}

var FS_createPath = (...args) => FS.createPath(...args);

var FS_unlink = (...args) => FS.unlink(...args);

var FS_createLazyFile = (...args) => FS.createLazyFile(...args);

var FS_createDevice = (...args) => FS.createDevice(...args);

var createContext = Browser.createContext;

FS.createPreloadedFile = FS_createPreloadedFile;

FS.preloadFile = FS_preloadFile;

FS.staticInit();

// Signal GL rendering layer that processing of a new frame is about to
// start. This helps it optimize VBO double-buffering and reduce GPU stalls.
registerPreMainLoop(() => GL.newRenderingFrameStarted());

Module["requestAnimationFrame"] = MainLoop.requestAnimationFrame;

Module["pauseMainLoop"] = MainLoop.pause;

Module["resumeMainLoop"] = MainLoop.resume;

MainLoop.init();

for (let i = 0; i < 32; ++i) tempFixedLengthArray.push(new Array(i));

var miniTempWebGLFloatBuffersStorage = new Float32Array(288);

// Create GL_POOL_TEMP_BUFFERS_SIZE+1 temporary buffers, for uploads of size 0 through GL_POOL_TEMP_BUFFERS_SIZE inclusive
for (/**@suppress{duplicate}*/ var i = 0; i <= 288; ++i) {
  miniTempWebGLFloatBuffers[i] = miniTempWebGLFloatBuffersStorage.subarray(0, i);
}

var miniTempWebGLIntBuffersStorage = new Int32Array(288);

// Create GL_POOL_TEMP_BUFFERS_SIZE+1 temporary buffers, for uploads of size 0 through GL_POOL_TEMP_BUFFERS_SIZE inclusive
for (/**@suppress{duplicate}*/ var i = 0; i <= 288; ++i) {
  miniTempWebGLIntBuffers[i] = miniTempWebGLIntBuffersStorage.subarray(0, i);
}

// End JS library code
// include: postlibrary.js
// This file is included after the automatically-generated JS library code
// but before the wasm module is created.
{
  // Begin ATMODULES hooks
  if (Module["print"]) out = Module["print"];
  if (Module["printErr"]) err = Module["printErr"];
  if (Module["wasmBinary"]) wasmBinary = Module["wasmBinary"];
  // End ATMODULES hooks
  checkIncomingModuleAPI();
  if (Module["arguments"]) programArgs = Module["arguments"];
  // Assertions on removed incoming Module JS APIs.
  assert(typeof Module["memoryInitializerPrefixURL"] == "undefined", "Module.memoryInitializerPrefixURL option was removed, use Module.locateFile instead");
  assert(typeof Module["pthreadMainPrefixURL"] == "undefined", "Module.pthreadMainPrefixURL option was removed, use Module.locateFile instead");
  assert(typeof Module["cdInitializerPrefixURL"] == "undefined", "Module.cdInitializerPrefixURL option was removed, use Module.locateFile instead");
  assert(typeof Module["filePackagePrefixURL"] == "undefined", "Module.filePackagePrefixURL option was removed, use Module.locateFile instead");
  assert(typeof Module["read"] == "undefined", "Module.read option was removed");
  assert(typeof Module["readAsync"] == "undefined", "Module.readAsync option was removed (modify readAsync in JS)");
  assert(typeof Module["readBinary"] == "undefined", "Module.readBinary option was removed (modify readBinary in JS)");
  assert(typeof Module["setWindowTitle"] == "undefined", "Module.setWindowTitle option was removed (modify emscripten_set_window_title in JS)");
  assert(typeof Module["TOTAL_MEMORY"] == "undefined", "Module.TOTAL_MEMORY has been renamed Module.INITIAL_MEMORY");
  assert(typeof Module["ENVIRONMENT"] == "undefined", "Module.ENVIRONMENT has been deprecated. To force the environment, use the ENVIRONMENT compile-time option (for example, -sENVIRONMENT=web or -sENVIRONMENT=node)");
  assert(typeof Module["STACK_SIZE"] == "undefined", "STACK_SIZE can no longer be set at runtime.  Use -sSTACK_SIZE at link time");
  // If memory is defined in wasm, the user can't provide it, or set INITIAL_MEMORY
  assert(typeof Module["wasmMemory"] == "undefined", "Use of `wasmMemory` detected.  Use -sIMPORTED_MEMORY to define wasmMemory externally");
  assert(typeof Module["INITIAL_MEMORY"] == "undefined", "Detected runtime INITIAL_MEMORY setting.  Use -sIMPORTED_MEMORY to define wasmMemory dynamically");
}

// Begin runtime exports
Module["addRunDependency"] = addRunDependency;

Module["removeRunDependency"] = removeRunDependency;

Module["createContext"] = createContext;

Module["FS_preloadFile"] = FS_preloadFile;

Module["FS_unlink"] = FS_unlink;

Module["FS_createPath"] = FS_createPath;

Module["FS_createDevice"] = FS_createDevice;

Module["FS_createDataFile"] = FS_createDataFile;

Module["FS_createLazyFile"] = FS_createLazyFile;

var missingLibrarySymbols = [ "writeI53ToI64Clamped", "writeI53ToI64Signaling", "writeI53ToU64Clamped", "writeI53ToU64Signaling", "convertI32PairToI53", "convertI32PairToI53Checked", "convertU32PairToI53", "getTempRet0", "setTempRet0", "createNamedFunction", "zeroMemory", "withStackSave", "inetPton4", "inetNtop4", "inetPton6", "inetNtop6", "readSockaddr", "writeSockaddr", "getDynCaller", "runtimeKeepalivePush", "runtimeKeepalivePop", "asmjsMangle", "HandleAllocator", "addOnInit", "addOnPostCtor", "addOnPreMain", "addOnPostRun", "STACK_SIZE", "STACK_ALIGN", "POINTER_SIZE", "ASSERTIONS", "ccall", "cwrap", "convertJsFunctionToWasm", "getEmptyTableSlot", "updateTableMap", "getFunctionAddress", "addFunction", "removeFunction", "getValue", "intArrayToString", "AsciiToString", "stringToAscii", "UTF16ToString", "stringToUTF16", "lengthBytesUTF16", "UTF32ToString", "stringToUTF32", "lengthBytesUTF32", "writeArrayToMemory", "fillDeviceOrientationEventData", "registerDeviceOrientationEventCallback", "fillDeviceMotionEventData", "registerDeviceMotionEventCallback", "screenOrientation", "fillOrientationChangeEventData", "registerOrientationChangeEventCallback", "hideEverythingExceptGivenElement", "restoreHiddenElements", "softFullscreenResizeWebGLRenderTarget", "registerPointerlockErrorEventCallback", "fillBatteryEventData", "registerBatteryEventCallback", "jsStackTrace", "getCallstack", "convertPCtoSourceLocation", "wasiRightsToMuslOFlags", "wasiOFlagsToMuslOFlags", "setImmediateWrapped", "safeRequestAnimationFrame", "clearImmediateWrapped", "registerPostMainLoop", "getPromise", "makePromise", "addPromise", "idsToPromises", "makePromiseCallback", "findMatchingCatch", "incrementUncaughtExceptionCount", "decrementUncaughtExceptionCount", "Browser_asyncPrepareDataCounter", "arraySum", "addDays", "getSocketFromFD", "getSocketAddress", "FS_mkdirTree", "_setNetworkCallback", "writeGLArray", "registerWebGlEventCallback", "runAndAbortIfError", "writeStringToMemory", "writeAsciiToMemory", "allocateUTF8", "allocateUTF8OnStack", "demangle", "stackTrace", "getNativeTypeSize" ];

missingLibrarySymbols.forEach(missingLibrarySymbol);

var unexportedSymbols = [ "run", "out", "err", "callMain", "abort", "wasmExports", "writeStackCookie", "checkStackCookie", "writeI53ToI64", "readI53FromI64", "readI53FromU64", "INT53_MAX", "INT53_MIN", "bigintToI53Checked", "HEAP8", "HEAPU8", "HEAP16", "HEAPU16", "HEAP32", "HEAPU32", "HEAPF32", "HEAPF64", "HEAP64", "HEAPU64", "stackSave", "stackRestore", "stackAlloc", "ptrToString", "exitJS", "getHeapMax", "growMemory", "ENV", "ERRNO_CODES", "strError", "DNS", "Protocols", "Sockets", "timers", "warnOnce", "readEmAsmArgsArray", "readEmAsmArgs", "runEmAsmFunction", "runMainThreadEmAsm", "jstoi_q", "getExecutableName", "autoResumeAudioContext", "dynCall", "handleException", "keepRuntimeAlive", "callUserCallback", "maybeExit", "asyncLoad", "alignMemory", "mmapAlloc", "wasmTable", "wasmMemory", "getUniqueRunDependency", "noExitRuntime", "addOnPreRun", "addOnExit", "freeTableIndexes", "functionsInTableMap", "setValue", "PATH", "PATH_FS", "UTF8Decoder", "UTF8ArrayToString", "UTF8ToString", "stringToUTF8Array", "stringToUTF8", "lengthBytesUTF8", "intArrayFromString", "UTF16Decoder", "stringToNewUTF8", "stringToUTF8OnStack", "JSEvents", "registerKeyEventCallback", "specialHTMLTargets", "maybeCStringToJsString", "findEventTarget", "findCanvasEventTarget", "getBoundingClientRect", "fillMouseEventData", "registerMouseEventCallback", "registerWheelEventCallback", "registerUiEventCallback", "registerFocusEventCallback", "fillFullscreenChangeEventData", "registerFullscreenChangeEventCallback", "callCanvasResizedCallback", "JSEvents_requestFullscreen", "JSEvents_resizeCanvasForFullscreen", "registerRestoreOldStyle", "setLetterbox", "currentFullscreenStrategy", "restoreOldWindowedStyle", "doRequestFullscreen", "fillPointerlockChangeEventData", "registerPointerlockChangeEventCallback", "requestPointerLock", "fillVisibilityChangeEventData", "registerVisibilityChangeEventCallback", "registerTouchEventCallback", "fillGamepadEventData", "registerGamepadEventCallback", "registerBeforeUnloadEventCallback", "setCanvasElementSize", "getCanvasElementSize", "UNWIND_CACHE", "ExitStatus", "getEnvStrings", "checkWasiClock", "doReadv", "doWritev", "initRandomFill", "randomFill", "safeSetTimeout", "emSetImmediate", "emClearImmediate_deps", "emClearImmediate", "registerPreMainLoop", "promiseMap", "uncaughtExceptionCount", "exceptionCaught", "ExceptionInfo", "Browser", "requestFullscreen", "setCanvasSize", "getUserMedia", "getPreloadedImageData__data", "wget", "MONTH_DAYS_REGULAR", "MONTH_DAYS_LEAP", "MONTH_DAYS_REGULAR_CUMULATIVE", "MONTH_DAYS_LEAP_CUMULATIVE", "isLeapYear", "ydayFromDate", "SYSCALLS", "preloadPlugins", "FS_createPreloadedFile", "FS_modeStringToFlags", "FS_getMode", "FS_fileDataToTypedArray", "FS_stdin_getChar_buffer", "FS_stdin_getChar", "FS_readFile", "FS", "FS_root", "FS_mounts", "FS_devices", "FS_streams", "FS_nextInode", "FS_nameTable", "FS_currentPath", "FS_initialized", "FS_ignorePermissions", "FS_filesystems", "FS_syncFSRequests", "FS_lookupPath", "FS_getPath", "FS_hashName", "FS_hashAddNode", "FS_hashRemoveNode", "FS_lookupNode", "FS_createNode", "FS_destroyNode", "FS_isRoot", "FS_isMountpoint", "FS_isFile", "FS_isDir", "FS_isLink", "FS_isChrdev", "FS_isBlkdev", "FS_isFIFO", "FS_isSocket", "FS_flagsToPermissionString", "FS_nodePermissions", "FS_mayLookup", "FS_mayCreate", "FS_mayDelete", "FS_mayOpen", "FS_checkOpExists", "FS_nextfd", "FS_getStreamChecked", "FS_getStream", "FS_createStream", "FS_closeStream", "FS_dupStream", "FS_doSetAttr", "FS_chrdev_stream_ops", "FS_major", "FS_minor", "FS_makedev", "FS_registerDevice", "FS_getDevice", "FS_getMounts", "FS_syncfs", "FS_mount", "FS_unmount", "FS_lookup", "FS_mknod", "FS_statfs", "FS_statfsStream", "FS_statfsNode", "FS_create", "FS_mkdir", "FS_mkdev", "FS_symlink", "FS_link", "FS_rename", "FS_rmdir", "FS_readdir", "FS_readlink", "FS_stat", "FS_fstat", "FS_lstat", "FS_doChmod", "FS_chmod", "FS_lchmod", "FS_fchmod", "FS_doChown", "FS_chown", "FS_lchown", "FS_fchown", "FS_doTruncate", "FS_truncate", "FS_ftruncate", "FS_utime", "FS_open", "FS_close", "FS_isClosed", "FS_llseek", "FS_read", "FS_write", "FS_mmap", "FS_msync", "FS_ioctl", "FS_writeFile", "FS_cwd", "FS_chdir", "FS_createDefaultDirectories", "FS_createDefaultDevices", "FS_createSpecialDirectories", "FS_createStandardStreams", "FS_staticInit", "FS_init", "FS_quit", "FS_findObject", "FS_analyzePath", "FS_createFile", "FS_forceLoadFile", "MEMFS", "TTY", "PIPEFS", "SOCKFS", "tempFixedLengthArray", "miniTempWebGLFloatBuffers", "miniTempWebGLIntBuffers", "heapObjectForWebGLType", "toTypedArrayIndex", "webgl_enable_WEBGL_multi_draw", "webgl_enable_EXT_polygon_offset_clamp", "webgl_enable_EXT_clip_control", "webgl_enable_WEBGL_polygon_mode", "GL", "emscriptenWebGLGet", "computeUnpackAlignedImageSize", "colorChannelsInGlTextureFormat", "emscriptenWebGLGetTexPixelData", "emscriptenWebGLGetUniform", "webglGetProgramUniformLocation", "webglGetUniformLocation", "webglPrepareUniformLocationsBeforeFirstUse", "webglGetLeftBracePos", "emscriptenWebGLGetVertexAttrib", "__glGetActiveAttribOrUniform", "emscriptenWebGLGetBufferBinding", "emscriptenWebGLValidateMapBufferTarget", "AL", "GLUT", "EGL", "GLEW", "IDBStore", "emscriptenWebGLGetIndexed", "webgl_enable_WEBGL_draw_instanced_base_vertex_base_instance", "webgl_enable_WEBGL_multi_draw_instanced_base_vertex_base_instance", "print", "printErr", "jstoi_s" ];

unexportedSymbols.forEach(unexportedRuntimeSymbol);

// End runtime exports
// Begin JS library exports
// End JS library exports
// end include: postlibrary.js
function checkIncomingModuleAPI() {
  ignoredModuleProp("ENVIRONMENT");
  ignoredModuleProp("dynamicLibraries");
  ignoredModuleProp("elementPointerLock");
  ignoredModuleProp("instantiateWasm");
  ignoredModuleProp("locateFile");
  ignoredModuleProp("monitorRunDependencies");
  ignoredModuleProp("noExitRuntime");
  ignoredModuleProp("noInitialRun");
  ignoredModuleProp("onAbort");
  ignoredModuleProp("onExit");
  ignoredModuleProp("postRun");
  ignoredModuleProp("preInit");
  ignoredModuleProp("setStatus");
  ignoredModuleProp("statusMessage");
  ignoredModuleProp("stderr");
  ignoredModuleProp("stdin");
  ignoredModuleProp("stdout");
  ignoredModuleProp("thisProgram");
  ignoredModuleProp("wasm");
  ignoredModuleProp("websocket");
  ignoredModuleProp("fetchSettings");
  ignoredModuleProp("logReadFiles");
  ignoredModuleProp("loadSplitModule");
  ignoredModuleProp("onMalloc");
  ignoredModuleProp("onRealloc");
  ignoredModuleProp("onFree");
  ignoredModuleProp("onSbrkGrow");
  ignoredModuleProp("onCOSCacheHit");
  ignoredModuleProp("onCOSCacheMiss");
  ignoredModuleProp("onCOSStore");
  ignoredModuleProp("GL_MAX_TEXTURE_IMAGE_UNITS");
  ignoredModuleProp("SDL_canPlayWithWebAudio");
  ignoredModuleProp("SDL_numSimultaneouslyQueuedBuffers");
  ignoredModuleProp("freePreloadedMediaOnUse");
  ignoredModuleProp("preinitializedWebGLContext");
  ignoredModuleProp("keyboardListeningElement");
  ignoredModuleProp("doNotCaptureKeyboard");
  ignoredModuleProp("extraStackTrace");
  ignoredModuleProp("preloadPlugins");
  ignoredModuleProp("preMainLoop");
  ignoredModuleProp("postMainLoop");
  ignoredModuleProp("forcedAspectRatio");
  ignoredModuleProp("mainScriptUrlOrBlob");
  ignoredModuleProp("onFullScreen");
  ignoredModuleProp("INITIAL_MEMORY");
  ignoredModuleProp("wasmMemory");
}

var ASM_CONSTS = {
  2571865: () => {
    if (typeof (AudioContext) !== "undefined") {
      return true;
    } else if (typeof (webkitAudioContext) !== "undefined") {
      return true;
    }
    return false;
  },
  2572012: () => {
    if ((typeof (navigator.mediaDevices) !== "undefined") && (typeof (navigator.mediaDevices.getUserMedia) !== "undefined")) {
      return true;
    } else if (typeof (navigator.webkitGetUserMedia) !== "undefined") {
      return true;
    }
    return false;
  },
  2572246: $0 => {
    if (typeof (Module["SDL2"]) === "undefined") {
      Module["SDL2"] = {};
    }
    var SDL2 = Module["SDL2"];
    if (!$0) {
      SDL2.audio = {};
    } else {
      SDL2.capture = {};
    }
    if (!SDL2.audioContext) {
      if (typeof (AudioContext) !== "undefined") {
        SDL2.audioContext = new AudioContext;
      } else if (typeof (webkitAudioContext) !== "undefined") {
        SDL2.audioContext = new webkitAudioContext;
      }
      if (SDL2.audioContext) {
        if ((typeof navigator.userActivation) === "undefined") {
          autoResumeAudioContext(SDL2.audioContext);
        }
      }
    }
    return SDL2.audioContext === undefined ? -1 : 0;
  },
  2572798: () => {
    var SDL2 = Module["SDL2"];
    return SDL2.audioContext.sampleRate;
  },
  2572866: ($0, $1, $2, $3) => {
    var SDL2 = Module["SDL2"];
    var have_microphone = function(stream) {
      if (SDL2.capture.silenceTimer !== undefined) {
        clearInterval(SDL2.capture.silenceTimer);
        SDL2.capture.silenceTimer = undefined;
        SDL2.capture.silenceBuffer = undefined;
      }
      SDL2.capture.mediaStreamNode = SDL2.audioContext.createMediaStreamSource(stream);
      SDL2.capture.scriptProcessorNode = SDL2.audioContext.createScriptProcessor($1, $0, 1);
      SDL2.capture.scriptProcessorNode.onaudioprocess = function(audioProcessingEvent) {
        if ((SDL2 === undefined) || (SDL2.capture === undefined)) {
          return;
        }
        audioProcessingEvent.outputBuffer.getChannelData(0).fill(0);
        SDL2.capture.currentCaptureBuffer = audioProcessingEvent.inputBuffer;
        dynCall("vp", $2, [ $3 ]);
      };
      SDL2.capture.mediaStreamNode.connect(SDL2.capture.scriptProcessorNode);
      SDL2.capture.scriptProcessorNode.connect(SDL2.audioContext.destination);
      SDL2.capture.stream = stream;
    };
    var no_microphone = function(error) {};
    SDL2.capture.silenceBuffer = SDL2.audioContext.createBuffer($0, $1, SDL2.audioContext.sampleRate);
    SDL2.capture.silenceBuffer.getChannelData(0).fill(0);
    var silence_callback = function() {
      SDL2.capture.currentCaptureBuffer = SDL2.capture.silenceBuffer;
      dynCall("vp", $2, [ $3 ]);
    };
    SDL2.capture.silenceTimer = setInterval(silence_callback, ($1 / SDL2.audioContext.sampleRate) * 1e3);
    if ((navigator.mediaDevices !== undefined) && (navigator.mediaDevices.getUserMedia !== undefined)) {
      navigator.mediaDevices.getUserMedia({
        audio: true,
        video: false
      }).then(have_microphone).catch(no_microphone);
    } else if (navigator.webkitGetUserMedia !== undefined) {
      navigator.webkitGetUserMedia({
        audio: true,
        video: false
      }, have_microphone, no_microphone);
    }
  },
  2574559: ($0, $1, $2, $3) => {
    var SDL2 = Module["SDL2"];
    SDL2.audio.scriptProcessorNode = SDL2.audioContext["createScriptProcessor"]($1, 0, $0);
    SDL2.audio.scriptProcessorNode["onaudioprocess"] = function(e) {
      if ((SDL2 === undefined) || (SDL2.audio === undefined)) {
        return;
      }
      if (SDL2.audio.silenceTimer !== undefined) {
        clearInterval(SDL2.audio.silenceTimer);
        SDL2.audio.silenceTimer = undefined;
        SDL2.audio.silenceBuffer = undefined;
      }
      SDL2.audio.currentOutputBuffer = e["outputBuffer"];
      dynCall("vp", $2, [ $3 ]);
    };
    SDL2.audio.scriptProcessorNode["connect"](SDL2.audioContext["destination"]);
    if (SDL2.audioContext.state === "suspended") {
      SDL2.audio.silenceBuffer = SDL2.audioContext.createBuffer($0, $1, SDL2.audioContext.sampleRate);
      SDL2.audio.silenceBuffer.getChannelData(0).fill(0);
      var silence_callback = function() {
        if ((typeof navigator.userActivation) !== "undefined") {
          if (navigator.userActivation.hasBeenActive) {
            SDL2.audioContext.resume();
          }
        }
        SDL2.audio.currentOutputBuffer = SDL2.audio.silenceBuffer;
        dynCall("vp", $2, [ $3 ]);
        SDL2.audio.currentOutputBuffer = undefined;
      };
      SDL2.audio.silenceTimer = setInterval(silence_callback, ($1 / SDL2.audioContext.sampleRate) * 1e3);
    }
  },
  2575734: ($0, $1) => {
    var SDL2 = Module["SDL2"];
    var numChannels = SDL2.capture.currentCaptureBuffer.numberOfChannels;
    for (var c = 0; c < numChannels; ++c) {
      var channelData = SDL2.capture.currentCaptureBuffer.getChannelData(c);
      if (channelData.length != $1) {
        throw "Web Audio capture buffer length mismatch! Destination size: " + channelData.length + " samples vs expected " + $1 + " samples!";
      }
      if (numChannels == 1) {
        for (var j = 0; j < $1; ++j) {
          setValue($0 + (j * 4), channelData[j], "float");
        }
      } else {
        for (var j = 0; j < $1; ++j) {
          setValue($0 + (((j * numChannels) + c) * 4), channelData[j], "float");
        }
      }
    }
  },
  2576339: ($0, $1) => {
    var SDL2 = Module["SDL2"];
    var buf = $0 >>> 2;
    var numChannels = SDL2.audio.currentOutputBuffer["numberOfChannels"];
    for (var c = 0; c < numChannels; ++c) {
      var channelData = SDL2.audio.currentOutputBuffer["getChannelData"](c);
      if (channelData.length != $1) {
        throw "Web Audio output buffer length mismatch! Destination size: " + channelData.length + " samples vs expected " + $1 + " samples!";
      }
      for (var j = 0; j < $1; ++j) {
        channelData[j] = HEAPF32[buf + (j * numChannels + c) >>> 0];
      }
    }
  },
  2576828: $0 => {
    var SDL2 = Module["SDL2"];
    if ($0) {
      if (SDL2.capture.silenceTimer !== undefined) {
        clearInterval(SDL2.capture.silenceTimer);
      }
      if (SDL2.capture.stream !== undefined) {
        var tracks = SDL2.capture.stream.getAudioTracks();
        for (var i = 0; i < tracks.length; i++) {
          SDL2.capture.stream.removeTrack(tracks[i]);
        }
      }
      if (SDL2.capture.scriptProcessorNode !== undefined) {
        SDL2.capture.scriptProcessorNode.onaudioprocess = function(audioProcessingEvent) {};
        SDL2.capture.scriptProcessorNode.disconnect();
      }
      if (SDL2.capture.mediaStreamNode !== undefined) {
        SDL2.capture.mediaStreamNode.disconnect();
      }
      SDL2.capture = undefined;
    } else {
      if (SDL2.audio.scriptProcessorNode != undefined) {
        SDL2.audio.scriptProcessorNode.disconnect();
      }
      if (SDL2.audio.silenceTimer !== undefined) {
        clearInterval(SDL2.audio.silenceTimer);
      }
      SDL2.audio = undefined;
    }
    if ((SDL2.audioContext !== undefined) && (SDL2.audio === undefined) && (SDL2.capture === undefined)) {
      SDL2.audioContext.close();
      SDL2.audioContext = undefined;
    }
  },
  2577834: ($0, $1, $2) => {
    var w = $0;
    var h = $1;
    var pixels = $2;
    if (!Module["SDL2"]) Module["SDL2"] = {};
    var SDL2 = Module["SDL2"];
    if (SDL2.ctxCanvas !== Module["canvas"]) {
      SDL2.ctx = Browser.createContext(Module["canvas"], false, true);
      SDL2.ctxCanvas = Module["canvas"];
    }
    if (SDL2.w !== w || SDL2.h !== h || SDL2.imageCtx !== SDL2.ctx) {
      SDL2.image = SDL2.ctx.createImageData(w, h);
      SDL2.w = w;
      SDL2.h = h;
      SDL2.imageCtx = SDL2.ctx;
    }
    var data = SDL2.image.data;
    var src = pixels / 4;
    var dst = 0;
    var num;
    if (typeof CanvasPixelArray !== "undefined" && data instanceof CanvasPixelArray) {
      num = data.length;
      while (dst < num) {
        var val = HEAP32[src >>> 0];
        data[dst] = val & 255;
        data[dst + 1] = (val >> 8) & 255;
        data[dst + 2] = (val >> 16) & 255;
        data[dst + 3] = 255;
        src++;
        dst += 4;
      }
    } else {
      if (SDL2.data32Data !== data) {
        SDL2.data32 = new Int32Array(data.buffer);
        SDL2.data8 = new Uint8Array(data.buffer);
        SDL2.data32Data = data;
      }
      var data32 = SDL2.data32;
      num = data32.length;
      data32.set(HEAP32.subarray(src >>> 0, src + num >>> 0));
      var data8 = SDL2.data8;
      var i = 3;
      var j = i + 4 * num;
      if (num % 8 == 0) {
        while (i < j) {
          data8[i] = 255;
          i = i + 4 | 0;
          data8[i] = 255;
          i = i + 4 | 0;
          data8[i] = 255;
          i = i + 4 | 0;
          data8[i] = 255;
          i = i + 4 | 0;
          data8[i] = 255;
          i = i + 4 | 0;
          data8[i] = 255;
          i = i + 4 | 0;
          data8[i] = 255;
          i = i + 4 | 0;
          data8[i] = 255;
          i = i + 4 | 0;
        }
      } else {
        while (i < j) {
          data8[i] = 255;
          i = i + 4 | 0;
        }
      }
    }
    SDL2.ctx.putImageData(SDL2.image, 0, 0);
  },
  2579300: ($0, $1, $2, $3, $4) => {
    var w = $0;
    var h = $1;
    var hot_x = $2;
    var hot_y = $3;
    var pixels = $4;
    var canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    var ctx = canvas.getContext("2d");
    var image = ctx.createImageData(w, h);
    var data = image.data;
    var src = pixels / 4;
    var dst = 0;
    var num;
    if (typeof CanvasPixelArray !== "undefined" && data instanceof CanvasPixelArray) {
      num = data.length;
      while (dst < num) {
        var val = HEAP32[src >>> 0];
        data[dst] = val & 255;
        data[dst + 1] = (val >> 8) & 255;
        data[dst + 2] = (val >> 16) & 255;
        data[dst + 3] = (val >> 24) & 255;
        src++;
        dst += 4;
      }
    } else {
      var data32 = new Int32Array(data.buffer);
      num = data32.length;
      data32.set(HEAP32.subarray(src >>> 0, src + num >>> 0));
    }
    ctx.putImageData(image, 0, 0);
    var url = hot_x === 0 && hot_y === 0 ? "url(" + canvas.toDataURL() + "), auto" : "url(" + canvas.toDataURL() + ") " + hot_x + " " + hot_y + ", auto";
    var urlBuf = _malloc(url.length + 1);
    stringToUTF8(url, urlBuf, url.length + 1);
    return urlBuf;
  },
  2580288: $0 => {
    if (Module["canvas"]) {
      Module["canvas"].style["cursor"] = UTF8ToString($0);
    }
  },
  2580371: () => {
    if (Module["canvas"]) {
      Module["canvas"].style["cursor"] = "none";
    }
  },
  2580440: () => window.innerWidth,
  2580470: () => window.innerHeight
};

function ImGui_ImplSDL2_EmscriptenOpenURL(url) {
  url = url ? UTF8ToString(url) : null;
  if (url) window.open(url, "_blank");
}

// Imports from the Wasm binary.
var _free = makeInvalidEarlyAccess("_free");

var _malloc = makeInvalidEarlyAccess("_malloc");

var _main = Module["_main"] = makeInvalidEarlyAccess("_main");

var _fflush = makeInvalidEarlyAccess("_fflush");

var _strerror = makeInvalidEarlyAccess("_strerror");

var _emscripten_stack_get_end = makeInvalidEarlyAccess("_emscripten_stack_get_end");

var _emscripten_stack_get_base = makeInvalidEarlyAccess("_emscripten_stack_get_base");

var _emscripten_stack_init = makeInvalidEarlyAccess("_emscripten_stack_init");

var _emscripten_stack_get_free = makeInvalidEarlyAccess("_emscripten_stack_get_free");

var __emscripten_stack_restore = makeInvalidEarlyAccess("__emscripten_stack_restore");

var __emscripten_stack_alloc = makeInvalidEarlyAccess("__emscripten_stack_alloc");

var _emscripten_stack_get_current = makeInvalidEarlyAccess("_emscripten_stack_get_current");

var memory = makeInvalidEarlyAccess("memory");

var __indirect_function_table = makeInvalidEarlyAccess("__indirect_function_table");

var __D14weightmap_view11__moduleRefZ = Module["__D14weightmap_view11__moduleRefZ"] = makeInvalidEarlyAccess("__D14weightmap_view11__moduleRefZ");

var __D13web_gl_loader11__moduleRefZ = Module["__D13web_gl_loader11__moduleRefZ"] = makeInvalidEarlyAccess("__D13web_gl_loader11__moduleRefZ");

var __D15viewport_scheme11__moduleRefZ = Module["__D15viewport_scheme11__moduleRefZ"] = makeInvalidEarlyAccess("__D15viewport_scheme11__moduleRefZ");

var __D21viewport_overlay_mode11__moduleRefZ = Module["__D21viewport_overlay_mode11__moduleRefZ"] = makeInvalidEarlyAccess("__D21viewport_overlay_mode11__moduleRefZ");

var __D29viewport_command_registration11__moduleRefZ = Module["__D29viewport_command_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D29viewport_command_registration11__moduleRefZ");

var __D8viewport11__moduleRefZ = Module["__D8viewport11__moduleRefZ"] = makeInvalidEarlyAccess("__D8viewport11__moduleRefZ");

var __D8viewgrid11__moduleRefZ = Module["__D8viewgrid11__moduleRefZ"] = makeInvalidEarlyAccess("__D8viewgrid11__moduleRefZ");

var __D26view_settings_registration11__moduleRefZ = Module["__D26view_settings_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D26view_settings_registration11__moduleRefZ");

var __D4view11__moduleRefZ = Module["__D4view11__moduleRefZ"] = makeInvalidEarlyAccess("__D4view11__moduleRefZ");

var __D7uv_weld11__moduleRefZ = Module["__D7uv_weld11__moduleRefZ"] = makeInvalidEarlyAccess("__D7uv_weld11__moduleRefZ");

var __D9uv_unwrap11__moduleRefZ = Module["__D9uv_unwrap11__moduleRefZ"] = makeInvalidEarlyAccess("__D9uv_unwrap11__moduleRefZ");

var __D12uv_transform11__moduleRefZ = Module["__D12uv_transform11__moduleRefZ"] = makeInvalidEarlyAccess("__D12uv_transform11__moduleRefZ");

var __D8uv_relax11__moduleRefZ = Module["__D8uv_relax11__moduleRefZ"] = makeInvalidEarlyAccess("__D8uv_relax11__moduleRefZ");

var __D10uv_project11__moduleRefZ = Module["__D10uv_project11__moduleRefZ"] = makeInvalidEarlyAccess("__D10uv_project11__moduleRefZ");

var __D9uv_island11__moduleRefZ = Module["__D9uv_island11__moduleRefZ"] = makeInvalidEarlyAccess("__D9uv_island11__moduleRefZ");

var __D2ui15viewport_render11__moduleRefZ = Module["__D2ui15viewport_render11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui15viewport_render11__moduleRefZ");

var __D2ui19viewport_props_role11__moduleRefZ = Module["__D2ui19viewport_props_role11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui19viewport_props_role11__moduleRefZ");

var __D2ui21tool_properties_panel11__moduleRefZ = Module["__D2ui21tool_properties_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui21tool_properties_panel11__moduleRefZ");

var __D2ui9stat_rows11__moduleRefZ = Module["__D2ui9stat_rows11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui9stat_rows11__moduleRefZ");

var __D2ui11stat_record11__moduleRefZ = Module["__D2ui11stat_record11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui11stat_record11__moduleRefZ");

var __D2ui13retained_item11__moduleRefZ = Module["__D2ui13retained_item11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui13retained_item11__moduleRefZ");

var __D2ui18remesh_modal_state11__moduleRefZ = Module["__D2ui18remesh_modal_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui18remesh_modal_state11__moduleRefZ");

var __D2ui10pie_render11__moduleRefZ = Module["__D2ui10pie_render11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui10pie_render11__moduleRefZ");

var __D2ui10pie_record11__moduleRefZ = Module["__D2ui10pie_record11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui10pie_record11__moduleRefZ");

var __D2ui6panels11__moduleRefZ = Module["__D2ui6panels11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui6panels11__moduleRefZ");

var __D2ui12panel_chrome11__moduleRefZ = Module["__D2ui12panel_chrome11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui12panel_chrome11__moduleRefZ");

var __D2ui10mode_popup11__moduleRefZ = Module["__D2ui10mode_popup11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui10mode_popup11__moduleRefZ");

var __D2ui16layer_list_panel11__moduleRefZ = Module["__D2ui16layer_list_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui16layer_list_panel11__moduleRefZ");

var __D2ui9item_rows11__moduleRefZ = Module["__D2ui9item_rows11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui9item_rows11__moduleRefZ");

var __D2ui11item_rename11__moduleRefZ = Module["__D2ui11item_rename11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui11item_rename11__moduleRefZ");

var __D2ui11item_glyphs11__moduleRefZ = Module["__D2ui11item_glyphs11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui11item_glyphs11__moduleRefZ");

var __D2ui18imgui_window_class11__moduleRefZ = Module["__D2ui18imgui_window_class11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui18imgui_window_class11__moduleRefZ");

var __D2ui10image_rows11__moduleRefZ = Module["__D2ui10image_rows11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui10image_rows11__moduleRefZ");

var __D2ui16image_list_panel11__moduleRefZ = Module["__D2ui16image_list_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui16image_list_panel11__moduleRefZ");

var __D2ui13history_panel11__moduleRefZ = Module["__D2ui13history_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui13history_panel11__moduleRefZ");

var __D2ui17guard_modal_state11__moduleRefZ = Module["__D2ui17guard_modal_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui17guard_modal_state11__moduleRefZ");

var __D2ui9dock_drag11__moduleRefZ = Module["__D2ui9dock_drag11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui9dock_drag11__moduleRefZ");

var __D2ui13discard_guard11__moduleRefZ = Module["__D2ui13discard_guard11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui13discard_guard11__moduleRefZ");

var __D2ui14command_notice11__moduleRefZ = Module["__D2ui14command_notice11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui14command_notice11__moduleRefZ");

var __D2ui14channels_panel11__moduleRefZ = Module["__D2ui14channels_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui14channels_panel11__moduleRefZ");

var __D2ui12channel_rows11__moduleRefZ = Module["__D2ui12channel_rows11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui12channel_rows11__moduleRefZ");

var __D2ui11button_face11__moduleRefZ = Module["__D2ui11button_face11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui11button_face11__moduleRefZ");

var __D2ui12availability11__moduleRefZ = Module["__D2ui12availability11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui12availability11__moduleRefZ");

var __D2ui11action_menu11__moduleRefZ = Module["__D2ui11action_menu11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ui11action_menu11__moduleRefZ");

var __D12tsan_preinit11__moduleRefZ = Module["__D12tsan_preinit11__moduleRefZ"] = makeInvalidEarlyAccess("__D12tsan_preinit11__moduleRefZ");

var __D13tsan_annotate11__moduleRefZ = Module["__D13tsan_annotate11__moduleRefZ"] = makeInvalidEarlyAccess("__D13tsan_annotate11__moduleRefZ");

var __D27transform_tool_registration11__moduleRefZ = Module["__D27transform_tool_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D27transform_tool_registration11__moduleRefZ");

var __D9trackball11__moduleRefZ = Module["__D9trackball11__moduleRefZ"] = makeInvalidEarlyAccess("__D9trackball11__moduleRefZ");

var __D5tools9transform14xfrm_transform11__moduleRefZ = Module["__D5tools9transform14xfrm_transform11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform14xfrm_transform11__moduleRefZ");

var __D5tools9transform9xfrm_item11__moduleRefZ = Module["__D5tools9transform9xfrm_item11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform9xfrm_item11__moduleRefZ");

var __D5tools9transform12xfrm_handles11__moduleRefZ = Module["__D5tools9transform12xfrm_handles11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform12xfrm_handles11__moduleRefZ");

var __D5tools9transform10xfrm_apply11__moduleRefZ = Module["__D5tools9transform10xfrm_apply11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform10xfrm_apply11__moduleRefZ");

var __D5tools9transform13xform_kernels11__moduleRefZ = Module["__D5tools9transform13xform_kernels11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform13xform_kernels11__moduleRefZ");

var __D5tools9transformQk11__moduleRefZ = Module["__D5tools9transformQk11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transformQk11__moduleRefZ");

var __D5tools9transform5scale11__moduleRefZ = Module["__D5tools9transform5scale11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform5scale11__moduleRefZ");

var __D5tools9transform6rotate11__moduleRefZ = Module["__D5tools9transform6rotate11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform6rotate11__moduleRefZ");

var __D5tools9transform19relocate_plane_test11__moduleRefZ = Module["__D5tools9transform19relocate_plane_test11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform19relocate_plane_test11__moduleRefZ");

var __D5tools9transform14relocate_plane11__moduleRefZ = Module["__D5tools9transform14relocate_plane11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform14relocate_plane11__moduleRefZ");

var __D5tools9transform4move11__moduleRefZ = Module["__D5tools9transform4move11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform4move11__moduleRefZ");

var __D5tools9transform11morph_route11__moduleRefZ = Module["__D5tools9transform11morph_route11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform11morph_route11__moduleRefZ");

var __D5tools9transform18item_xform_kernels11__moduleRefZ = Module["__D5tools9transform18item_xform_kernels11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform18item_xform_kernels11__moduleRefZ");

var __D5tools9transform7arcball11__moduleRefZ = Module["__D5tools9transform7arcball11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9transform7arcball11__moduleRefZ");

var __D5tools5slice10slice_tool11__moduleRefZ = Module["__D5tools5slice10slice_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools5slice10slice_tool11__moduleRefZ");

var __D5tools5slice15loop_slice_tool11__moduleRefZ = Module["__D5tools5slice15loop_slice_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools5slice15loop_slice_tool11__moduleRefZ");

var __D5tools5slice10edge_slide11__moduleRefZ = Module["__D5tools5slice10edge_slide11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools5slice10edge_slide11__moduleRefZ");

var __D5tools5slice15edge_slice_tool11__moduleRefZ = Module["__D5tools5slice15edge_slice_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools5slice15edge_slice_tool11__moduleRefZ");

var __D5tools4edit19vertex_extrude_tool11__moduleRefZ = Module["__D5tools4edit19vertex_extrude_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit19vertex_extrude_tool11__moduleRefZ");

var __D5tools4edit17vertex_bevel_tool11__moduleRefZ = Module["__D5tools4edit17vertex_bevel_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit17vertex_bevel_tool11__moduleRefZ");

var __D5tools4edit15vert_merge_tool11__moduleRefZ = Module["__D5tools4edit15vert_merge_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit15vert_merge_tool11__moduleRefZ");

var __D5tools4edit12topology_pen4tool11__moduleRefZ = Module["__D5tools4edit12topology_pen4tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12topology_pen4tool11__moduleRefZ");

var __D5tools4edit12topology_pen10snap_guide11__moduleRefZ = Module["__D5tools4edit12topology_pen10snap_guide11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12topology_pen10snap_guide11__moduleRefZ");

var __D5tools4edit12topology_pen6render11__moduleRefZ = Module["__D5tools4edit12topology_pen6render11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12topology_pen6render11__moduleRefZ");

var __D5tools4edit12topology_pen11__moduleRefZ = Module["__D5tools4edit12topology_pen11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12topology_pen11__moduleRefZ");

var __D5tools4edit12topology_pen4json11__moduleRefZ = Module["__D5tools4edit12topology_pen4json11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12topology_pen4json11__moduleRefZ");

var __D5tools4edit12topology_pen4defs11__moduleRefZ = Module["__D5tools4edit12topology_pen4defs11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12topology_pen4defs11__moduleRefZ");

var __D5tools4edit4tack11__moduleRefZ = Module["__D5tools4edit4tack11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit4tack11__moduleRefZ");

var __D5tools4edit12smooth_relax11__moduleRefZ = Module["__D5tools4edit12smooth_relax11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12smooth_relax11__moduleRefZ");

var __D5tools4edit6reduce11__moduleRefZ = Module["__D5tools4edit6reduce11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit6reduce11__moduleRefZ");

var __D5tools4edit15preview_rebuild11__moduleRefZ = Module["__D5tools4edit15preview_rebuild11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit15preview_rebuild11__moduleRefZ");

var __D5tools4edit15poly_inset_tool11__moduleRefZ = Module["__D5tools4edit15poly_inset_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit15poly_inset_tool11__moduleRefZ");

var __D5tools4edit12poly_extrude11__moduleRefZ = Module["__D5tools4edit12poly_extrude11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12poly_extrude11__moduleRefZ");

var __D5tools4edit10poly_bevel11__moduleRefZ = Module["__D5tools4edit10poly_bevel11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit10poly_bevel11__moduleRefZ");

var __D5tools4edit12edge_extrude11__moduleRefZ = Module["__D5tools4edit12edge_extrude11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit12edge_extrude11__moduleRefZ");

var __D5tools4edit11edge_extend11__moduleRefZ = Module["__D5tools4edit11edge_extend11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit11edge_extend11__moduleRefZ");

var __D5tools4edit10edge_bevel11__moduleRefZ = Module["__D5tools4edit10edge_bevel11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit10edge_bevel11__moduleRefZ");

var __D5tools4edit9drag_weld11__moduleRefZ = Module["__D5tools4edit9drag_weld11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit9drag_weld11__moduleRefZ");

var __D5tools4edit11bridge_tool11__moduleRefZ = Module["__D5tools4edit11bridge_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools4edit11bridge_tool11__moduleRefZ");

var __D5tools6deform19stroke_extrude_tool11__moduleRefZ = Module["__D5tools6deform19stroke_extrude_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6deform19stroke_extrude_tool11__moduleRefZ");

var __D5tools6deform17smooth_shift_tool11__moduleRefZ = Module["__D5tools6deform17smooth_shift_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6deform17smooth_shift_tool11__moduleRefZ");

var __D5tools6deform4push11__moduleRefZ = Module["__D5tools6deform4push11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6deform4push11__moduleRefZ");

var __D5tools6deform6magnet11__moduleRefZ = Module["__D5tools6deform6magnet11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6deform6magnet11__moduleRefZ");

var __D5tools6deform4bend11__moduleRefZ = Module["__D5tools6deform4bend11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6deform4bend11__moduleRefZ");

var __D5tools6create12vertex_place11__moduleRefZ = Module["__D5tools6create12vertex_place11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create12vertex_place11__moduleRefZ");

var __D5tools6create4tube11__moduleRefZ = Module["__D5tools6create4tube11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create4tube11__moduleRefZ");

var __D5tools6create5torus11__moduleRefZ = Module["__D5tools6create5torus11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create5torus11__moduleRefZ");

var __D5tools6create6sphere11__moduleRefZ = Module["__D5tools6create6sphere11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create6sphere11__moduleRefZ");

var __D5tools6create21primitive_create_tool11__moduleRefZ = Module["__D5tools6create21primitive_create_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create21primitive_create_tool11__moduleRefZ");

var __D5tools6create3pen11__moduleRefZ = Module["__D5tools6create3pen11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create3pen11__moduleRefZ");

var __D5tools6create8cylinder11__moduleRefZ = Module["__D5tools6create8cylinder11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create8cylinder11__moduleRefZ");

var __D5tools6create13create_common11__moduleRefZ = Module["__D5tools6create13create_common11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create13create_common11__moduleRefZ");

var __D5tools6create4cone11__moduleRefZ = Module["__D5tools6create4cone11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create4cone11__moduleRefZ");

var __D5tools6create7capsule11__moduleRefZ = Module["__D5tools6create7capsule11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create7capsule11__moduleRefZ");

var __D5tools6create3box11__moduleRefZ = Module["__D5tools6create3box11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create3box11__moduleRefZ");

var __D5tools6create3arc11__moduleRefZ = Module["__D5tools6create3arc11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6create3arc11__moduleRefZ");

var __D5tools6common16session_mesh_key11__moduleRefZ = Module["__D5tools6common16session_mesh_key11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6common16session_mesh_key11__moduleRefZ");

var __D5tools6common15command_wrapper11__moduleRefZ = Module["__D5tools6common15command_wrapper11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools6common15command_wrapper11__moduleRefZ");

var __D5tools9alignment17radial_sweep_tool11__moduleRefZ = Module["__D5tools9alignment17radial_sweep_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment17radial_sweep_tool11__moduleRefZ");

var __D5tools9alignment17radial_array_tool11__moduleRefZ = Module["__D5tools9alignment17radial_array_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment17radial_array_tool11__moduleRefZ");

var __D5tools9alignment17radial_align_tool11__moduleRefZ = Module["__D5tools9alignment17radial_align_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment17radial_align_tool11__moduleRefZ");

var __D5tools9alignment6mirror11__moduleRefZ = Module["__D5tools9alignment6mirror11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment6mirror11__moduleRefZ");

var __D5tools9alignment17linear_align_tool11__moduleRefZ = Module["__D5tools9alignment17linear_align_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment17linear_align_tool11__moduleRefZ");

var __D5tools9alignment10clone_tool11__moduleRefZ = Module["__D5tools9alignment10clone_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment10clone_tool11__moduleRefZ");

var __D5tools9alignment10array_tool11__moduleRefZ = Module["__D5tools9alignment10array_tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment10array_tool11__moduleRefZ");

var __D5tools9alignment13align_kernels11__moduleRefZ = Module["__D5tools9alignment13align_kernels11__moduleRefZ"] = makeInvalidEarlyAccess("__D5tools9alignment13align_kernels11__moduleRefZ");

var __D8toolpipe7subject11__moduleRefZ = Module["__D8toolpipe7subject11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe7subject11__moduleRefZ");

var __D8toolpipe6stages9workplane11__moduleRefZ = Module["__D8toolpipe6stages9workplane11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages9workplane11__moduleRefZ");

var __D8toolpipe6stages8symmetry11__moduleRefZ = Module["__D8toolpipe6stages8symmetry11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages8symmetry11__moduleRefZ");

var __D8toolpipe6stages4snap11__moduleRefZ = Module["__D8toolpipe6stages4snap11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages4snap11__moduleRefZ");

var __D8toolpipe6stages4path11__moduleRefZ = Module["__D8toolpipe6stages4path11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages4path11__moduleRefZ");

var __D8toolpipe6stages7falloff11__moduleRefZ = Module["__D8toolpipe6stages7falloff11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages7falloff11__moduleRefZ");

var __D8toolpipe6stages9constrain11__moduleRefZ = Module["__D8toolpipe6stages9constrain11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages9constrain11__moduleRefZ");

var __D8toolpipe6stages4axis11__moduleRefZ = Module["__D8toolpipe6stages4axis11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages4axis11__moduleRefZ");

var __D8toolpipe6stages9actcenter11__moduleRefZ = Module["__D8toolpipe6stages9actcenter11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe6stages9actcenter11__moduleRefZ");

var __D8toolpipe5stage11__moduleRefZ = Module["__D8toolpipe5stage11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe5stage11__moduleRefZ");

var __D8toolpipe8pipeline11__moduleRefZ = Module["__D8toolpipe8pipeline11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe8pipeline11__moduleRefZ");

var __D8toolpipe7packets11__moduleRefZ = Module["__D8toolpipe7packets11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe7packets11__moduleRefZ");

var __D8toolpipe11__moduleRefZ = Module["__D8toolpipe11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe11__moduleRefZ");

var __D8toolpipe5obbox11__moduleRefZ = Module["__D8toolpipe5obbox11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe5obbox11__moduleRefZ");

var __D8toolpipe5guide11__moduleRefZ = Module["__D8toolpipe5guide11__moduleRefZ"] = makeInvalidEarlyAccess("__D8toolpipe5guide11__moduleRefZ");

var __D12tool_presets11__moduleRefZ = Module["__D12tool_presets11__moduleRefZ"] = makeInvalidEarlyAccess("__D12tool_presets11__moduleRefZ");

var __D27tool_lifecycle_registration11__moduleRefZ = Module["__D27tool_lifecycle_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D27tool_lifecycle_registration11__moduleRefZ");

var __D10tool_input11__moduleRefZ = Module["__D10tool_input11__moduleRefZ"] = makeInvalidEarlyAccess("__D10tool_input11__moduleRefZ");

var __D11tool_disarm11__moduleRefZ = Module["__D11tool_disarm11__moduleRefZ"] = makeInvalidEarlyAccess("__D11tool_disarm11__moduleRefZ");

var __D25tool_activation_ownership11__moduleRefZ = Module["__D25tool_activation_ownership11__moduleRefZ"] = makeInvalidEarlyAccess("__D25tool_activation_ownership11__moduleRefZ");

var __D4tool11__moduleRefZ = Module["__D4tool11__moduleRefZ"] = makeInvalidEarlyAccess("__D4tool11__moduleRefZ");

var __D13symmetry_pick11__moduleRefZ = Module["__D13symmetry_pick11__moduleRefZ"] = makeInvalidEarlyAccess("__D13symmetry_pick11__moduleRefZ");

var __D8symmetry11__moduleRefZ = Module["__D8symmetry11__moduleRefZ"] = makeInvalidEarlyAccess("__D8symmetry11__moduleRefZ");

var __D19subpatch_worker_web11__moduleRefZ = Module["__D19subpatch_worker_web11__moduleRefZ"] = makeInvalidEarlyAccess("__D19subpatch_worker_web11__moduleRefZ");

var __D15subpatch_worker11__moduleRefZ = Module["__D15subpatch_worker11__moduleRefZ"] = makeInvalidEarlyAccess("__D15subpatch_worker11__moduleRefZ");

var __D16subpatch_preview11__moduleRefZ = Module["__D16subpatch_preview11__moduleRefZ"] = makeInvalidEarlyAccess("__D16subpatch_preview11__moduleRefZ");

var __D12subpatch_osd11__moduleRefZ = Module["__D12subpatch_osd11__moduleRefZ"] = makeInvalidEarlyAccess("__D12subpatch_osd11__moduleRefZ");

var __D10step_trace11__moduleRefZ = Module["__D10step_trace11__moduleRefZ"] = makeInvalidEarlyAccess("__D10step_trace11__moduleRefZ");

var __D8snapshot11__moduleRefZ = Module["__D8snapshot11__moduleRefZ"] = makeInvalidEarlyAccess("__D8snapshot11__moduleRefZ");

var __D11snap_render11__moduleRefZ = Module["__D11snap_render11__moduleRefZ"] = makeInvalidEarlyAccess("__D11snap_render11__moduleRefZ");

var __D13snap_election11__moduleRefZ = Module["__D13snap_election11__moduleRefZ"] = makeInvalidEarlyAccess("__D13snap_election11__moduleRefZ");

var __D4snap11__moduleRefZ = Module["__D4snap11__moduleRefZ"] = makeInvalidEarlyAccess("__D4snap11__moduleRefZ");

var __D9shortcuts11__moduleRefZ = Module["__D9shortcuts11__moduleRefZ"] = makeInvalidEarlyAccess("__D9shortcuts11__moduleRefZ");

var __D6shader11__moduleRefZ = Module["__D6shader11__moduleRefZ"] = makeInvalidEarlyAccess("__D6shader11__moduleRefZ");

var __D13session_owner11__moduleRefZ = Module["__D13session_owner11__moduleRefZ"] = makeInvalidEarlyAccess("__D13session_owner11__moduleRefZ");

var __D7seltype11__moduleRefZ = Module["__D7seltype11__moduleRefZ"] = makeInvalidEarlyAccess("__D7seltype11__moduleRefZ");

var __D14selftest_fault11__moduleRefZ = Module["__D14selftest_fault11__moduleRefZ"] = makeInvalidEarlyAccess("__D14selftest_fault11__moduleRefZ");

var __D20selection_projection11__moduleRefZ = Module["__D20selection_projection11__moduleRefZ"] = makeInvalidEarlyAccess("__D20selection_projection11__moduleRefZ");

var __D17selection_product11__moduleRefZ = Module["__D17selection_product11__moduleRefZ"] = makeInvalidEarlyAccess("__D17selection_product11__moduleRefZ");

var __D30selection_command_registration11__moduleRefZ = Module["__D30selection_command_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D30selection_command_registration11__moduleRefZ");

var __D17select_visibility11__moduleRefZ = Module["__D17select_visibility11__moduleRefZ"] = makeInvalidEarlyAccess("__D17select_visibility11__moduleRefZ");

var __D9sdl_error11__moduleRefZ = Module["__D9sdl_error11__moduleRefZ"] = makeInvalidEarlyAccess("__D9sdl_error11__moduleRefZ");

var __D14screen_buckets11__moduleRefZ = Module["__D14screen_buckets11__moduleRefZ"] = makeInvalidEarlyAccess("__D14screen_buckets11__moduleRefZ");

var __D19scene_reset_effects11__moduleRefZ = Module["__D19scene_reset_effects11__moduleRefZ"] = makeInvalidEarlyAccess("__D19scene_reset_effects11__moduleRefZ");

var __D33scene_file_lifecycle_registration11__moduleRefZ = Module["__D33scene_file_lifecycle_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D33scene_file_lifecycle_registration11__moduleRefZ");

var __D6render5scene11__moduleRefZ = Module["__D6render5scene11__moduleRefZ"] = makeInvalidEarlyAccess("__D6render5scene11__moduleRefZ");

var __D6render11rpr_backend11__moduleRefZ = Module["__D6render11rpr_backend11__moduleRefZ"] = makeInvalidEarlyAccess("__D6render11rpr_backend11__moduleRefZ");

var __D6render10render_mvp11__moduleRefZ = Module["__D6render10render_mvp11__moduleRefZ"] = makeInvalidEarlyAccess("__D6render10render_mvp11__moduleRefZ");

var __D6render11render_diff11__moduleRefZ = Module["__D6render11render_diff11__moduleRefZ"] = makeInvalidEarlyAccess("__D6render11render_diff11__moduleRefZ");

var __D6render14cycles_backend11__moduleRefZ = Module["__D6render14cycles_backend11__moduleRefZ"] = makeInvalidEarlyAccess("__D6render14cycles_backend11__moduleRefZ");

var __D6render14backend_bridge11__moduleRefZ = Module["__D6render14backend_bridge11__moduleRefZ"] = makeInvalidEarlyAccess("__D6render14backend_bridge11__moduleRefZ");

var __D6render7backend11__moduleRefZ = Module["__D6render7backend11__moduleRefZ"] = makeInvalidEarlyAccess("__D6render7backend11__moduleRefZ");

var __D6remesh10remesh_job11__moduleRefZ = Module["__D6remesh10remesh_job11__moduleRefZ"] = makeInvalidEarlyAccess("__D6remesh10remesh_job11__moduleRefZ");

var __D6remesh13region_stitch11__moduleRefZ = Module["__D6remesh13region_stitch11__moduleRefZ"] = makeInvalidEarlyAccess("__D6remesh13region_stitch11__moduleRefZ");

var __D8registry11__moduleRefZ = Module["__D8registry11__moduleRefZ"] = makeInvalidEarlyAccess("__D8registry11__moduleRefZ");

var __D12registration11__moduleRefZ = Module["__D12registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D12registration11__moduleRefZ");

var __D19record_observer_hub11__moduleRefZ = Module["__D19record_observer_hub11__moduleRefZ"] = makeInvalidEarlyAccess("__D19record_observer_hub11__moduleRefZ");

var __D14property_panel11__moduleRefZ = Module["__D14property_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D14property_panel11__moduleRefZ");

var __D25prepared_xfrm_update_tail11__moduleRefZ = Module["__D25prepared_xfrm_update_tail11__moduleRefZ"] = makeInvalidEarlyAccess("__D25prepared_xfrm_update_tail11__moduleRefZ");

var __D31prepared_xfrm_update_edit_close11__moduleRefZ = Module["__D31prepared_xfrm_update_edit_close11__moduleRefZ"] = makeInvalidEarlyAccess("__D31prepared_xfrm_update_edit_close11__moduleRefZ");

var __D29prepared_xfrm_update_boundary11__moduleRefZ = Module["__D29prepared_xfrm_update_boundary11__moduleRefZ"] = makeInvalidEarlyAccess("__D29prepared_xfrm_update_boundary11__moduleRefZ");

var __D23prepared_xfrm_slot_poll11__moduleRefZ = Module["__D23prepared_xfrm_slot_poll11__moduleRefZ"] = makeInvalidEarlyAccess("__D23prepared_xfrm_slot_poll11__moduleRefZ");

var __D20prepared_xfrm_replay11__moduleRefZ = Module["__D20prepared_xfrm_replay11__moduleRefZ"] = makeInvalidEarlyAccess("__D20prepared_xfrm_replay11__moduleRefZ");

var __D26prepared_xfrm_refire_state11__moduleRefZ = Module["__D26prepared_xfrm_refire_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D26prepared_xfrm_refire_state11__moduleRefZ");

var __D32prepared_xfrm_activation_session11__moduleRefZ = Module["__D32prepared_xfrm_activation_session11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_xfrm_activation_session11__moduleRefZ");

var __D34prepared_vertex_merge_param_update11__moduleRefZ = Module["__D34prepared_vertex_merge_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D34prepared_vertex_merge_param_update11__moduleRefZ");

var __D32prepared_vertex_merge_activation11__moduleRefZ = Module["__D32prepared_vertex_merge_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_vertex_merge_activation11__moduleRefZ");

var __D36prepared_vertex_extrude_param_update11__moduleRefZ = Module["__D36prepared_vertex_extrude_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D36prepared_vertex_extrude_param_update11__moduleRefZ");

var __D34prepared_vertex_extrude_activation11__moduleRefZ = Module["__D34prepared_vertex_extrude_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D34prepared_vertex_extrude_activation11__moduleRefZ");

var __D34prepared_vertex_bevel_param_update11__moduleRefZ = Module["__D34prepared_vertex_bevel_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D34prepared_vertex_bevel_param_update11__moduleRefZ");

var __D32prepared_vertex_bevel_activation11__moduleRefZ = Module["__D32prepared_vertex_bevel_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_vertex_bevel_activation11__moduleRefZ");

var __D37prepared_transform_product_activation11__moduleRefZ = Module["__D37prepared_transform_product_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D37prepared_transform_product_activation11__moduleRefZ");

var __D29prepared_transform_activation11__moduleRefZ = Module["__D29prepared_transform_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D29prepared_transform_activation11__moduleRefZ");

var __D28prepared_topology_pen_update11__moduleRefZ = Module["__D28prepared_topology_pen_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D28prepared_topology_pen_update11__moduleRefZ");

var __D32prepared_topology_pen_deactivate11__moduleRefZ = Module["__D32prepared_topology_pen_deactivate11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_topology_pen_deactivate11__moduleRefZ");

var __D32prepared_topology_pen_activation11__moduleRefZ = Module["__D32prepared_topology_pen_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_topology_pen_activation11__moduleRefZ");

var __D24prepared_tool_transition11__moduleRefZ = Module["__D24prepared_tool_transition11__moduleRefZ"] = makeInvalidEarlyAccess("__D24prepared_tool_transition11__moduleRefZ");

var __D20prepared_tool_effect11__moduleRefZ = Module["__D20prepared_tool_effect11__moduleRefZ"] = makeInvalidEarlyAccess("__D20prepared_tool_effect11__moduleRefZ");

var __D24prepared_tack_activation11__moduleRefZ = Module["__D24prepared_tack_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D24prepared_tack_activation11__moduleRefZ");

var __D34prepared_stroke_extrude_activation11__moduleRefZ = Module["__D34prepared_stroke_extrude_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D34prepared_stroke_extrude_activation11__moduleRefZ");

var __D34prepared_smooth_shift_param_update11__moduleRefZ = Module["__D34prepared_smooth_shift_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D34prepared_smooth_shift_param_update11__moduleRefZ");

var __D32prepared_smooth_shift_activation11__moduleRefZ = Module["__D32prepared_smooth_shift_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_smooth_shift_activation11__moduleRefZ");

var __D27prepared_slice_param_update11__moduleRefZ = Module["__D27prepared_slice_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D27prepared_slice_param_update11__moduleRefZ");

var __D25prepared_slice_deactivate11__moduleRefZ = Module["__D25prepared_slice_deactivate11__moduleRefZ"] = makeInvalidEarlyAccess("__D25prepared_slice_deactivate11__moduleRefZ");

var __D25prepared_slice_activation11__moduleRefZ = Module["__D25prepared_slice_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D25prepared_slice_activation11__moduleRefZ");

var __D32prepared_selection_profile_image11__moduleRefZ = Module["__D32prepared_selection_profile_image11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_selection_profile_image11__moduleRefZ");

var __D26prepared_selection_profile11__moduleRefZ = Module["__D26prepared_selection_profile11__moduleRefZ"] = makeInvalidEarlyAccess("__D26prepared_selection_profile11__moduleRefZ");

var __D21prepared_scale_update11__moduleRefZ = Module["__D21prepared_scale_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D21prepared_scale_update11__moduleRefZ");

var __D22prepared_rotate_update11__moduleRefZ = Module["__D22prepared_rotate_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D22prepared_rotate_update11__moduleRefZ");

var __D31prepared_reduction_param_update11__moduleRefZ = Module["__D31prepared_reduction_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D31prepared_reduction_param_update11__moduleRefZ");

var __D23prepared_record_context11__moduleRefZ = Module["__D23prepared_record_context11__moduleRefZ"] = makeInvalidEarlyAccess("__D23prepared_record_context11__moduleRefZ");

var __D32prepared_radial_sweep_transition11__moduleRefZ = Module["__D32prepared_radial_sweep_transition11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_radial_sweep_transition11__moduleRefZ");

var __D32prepared_radial_array_transition11__moduleRefZ = Module["__D32prepared_radial_array_transition11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_radial_array_transition11__moduleRefZ");

var __D22prepared_private_state11__moduleRefZ = Module["__D22prepared_private_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D22prepared_private_state11__moduleRefZ");

var __D32prepared_poly_inset_param_update11__moduleRefZ = Module["__D32prepared_poly_inset_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_poly_inset_param_update11__moduleRefZ");

var __D30prepared_poly_inset_activation11__moduleRefZ = Module["__D30prepared_poly_inset_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D30prepared_poly_inset_activation11__moduleRefZ");

var __D34prepared_poly_extrude_param_update11__moduleRefZ = Module["__D34prepared_poly_extrude_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D34prepared_poly_extrude_param_update11__moduleRefZ");

var __D32prepared_poly_extrude_activation11__moduleRefZ = Module["__D32prepared_poly_extrude_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_poly_extrude_activation11__moduleRefZ");

var __D32prepared_poly_bevel_param_update11__moduleRefZ = Module["__D32prepared_poly_bevel_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_poly_bevel_param_update11__moduleRefZ");

var __D30prepared_poly_bevel_activation11__moduleRefZ = Module["__D30prepared_poly_bevel_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D30prepared_poly_bevel_activation11__moduleRefZ");

var __D24prepared_pipe_activation11__moduleRefZ = Module["__D24prepared_pipe_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D24prepared_pipe_activation11__moduleRefZ");

var __D20prepared_move_update11__moduleRefZ = Module["__D20prepared_move_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D20prepared_move_update11__moduleRefZ");

var __D26prepared_mirror_activation11__moduleRefZ = Module["__D26prepared_mirror_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D26prepared_mirror_activation11__moduleRefZ");

var __D28prepared_magnet_param_update11__moduleRefZ = Module["__D28prepared_magnet_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D28prepared_magnet_param_update11__moduleRefZ");

var __D32prepared_loop_slice_param_update11__moduleRefZ = Module["__D32prepared_loop_slice_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_loop_slice_param_update11__moduleRefZ");

var __D30prepared_loop_slice_deactivate11__moduleRefZ = Module["__D30prepared_loop_slice_deactivate11__moduleRefZ"] = makeInvalidEarlyAccess("__D30prepared_loop_slice_deactivate11__moduleRefZ");

var __D30prepared_loop_slice_activation11__moduleRefZ = Module["__D30prepared_loop_slice_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D30prepared_loop_slice_activation11__moduleRefZ");

var __D23prepared_inherited_noop11__moduleRefZ = Module["__D23prepared_inherited_noop11__moduleRefZ"] = makeInvalidEarlyAccess("__D23prepared_inherited_noop11__moduleRefZ");

var __D32prepared_edge_slice_param_update11__moduleRefZ = Module["__D32prepared_edge_slice_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_edge_slice_param_update11__moduleRefZ");

var __D30prepared_edge_slice_deactivate11__moduleRefZ = Module["__D30prepared_edge_slice_deactivate11__moduleRefZ"] = makeInvalidEarlyAccess("__D30prepared_edge_slice_deactivate11__moduleRefZ");

var __D30prepared_edge_slice_activation11__moduleRefZ = Module["__D30prepared_edge_slice_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D30prepared_edge_slice_activation11__moduleRefZ");

var __D34prepared_edge_extrude_param_update11__moduleRefZ = Module["__D34prepared_edge_extrude_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D34prepared_edge_extrude_param_update11__moduleRefZ");

var __D32prepared_edge_extrude_activation11__moduleRefZ = Module["__D32prepared_edge_extrude_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_edge_extrude_activation11__moduleRefZ");

var __D36prepared_edge_extend_tool_activation11__moduleRefZ = Module["__D36prepared_edge_extend_tool_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D36prepared_edge_extend_tool_activation11__moduleRefZ");

var __D33prepared_edge_extend_param_update11__moduleRefZ = Module["__D33prepared_edge_extend_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D33prepared_edge_extend_param_update11__moduleRefZ");

var __D31prepared_edge_extend_deactivate11__moduleRefZ = Module["__D31prepared_edge_extend_deactivate11__moduleRefZ"] = makeInvalidEarlyAccess("__D31prepared_edge_extend_deactivate11__moduleRefZ");

var __D32prepared_edge_bevel_param_update11__moduleRefZ = Module["__D32prepared_edge_bevel_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D32prepared_edge_bevel_param_update11__moduleRefZ");

var __D30prepared_edge_bevel_activation11__moduleRefZ = Module["__D30prepared_edge_bevel_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D30prepared_edge_bevel_activation11__moduleRefZ");

var __D35prepared_command_wrapper_activation11__moduleRefZ = Module["__D35prepared_command_wrapper_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D35prepared_command_wrapper_activation11__moduleRefZ");

var __D26prepared_bridge_activation11__moduleRefZ = Module["__D26prepared_bridge_activation11__moduleRefZ"] = makeInvalidEarlyAccess("__D26prepared_bridge_activation11__moduleRefZ");

var __D18prepared_box_param11__moduleRefZ = Module["__D18prepared_box_param11__moduleRefZ"] = makeInvalidEarlyAccess("__D18prepared_box_param11__moduleRefZ");

var __D27prepared_array_param_update11__moduleRefZ = Module["__D27prepared_array_param_update11__moduleRefZ"] = makeInvalidEarlyAccess("__D27prepared_array_param_update11__moduleRefZ");

var __D5prefs11__moduleRefZ = Module["__D5prefs11__moduleRefZ"] = makeInvalidEarlyAccess("__D5prefs11__moduleRefZ");

var __D11popup_state11__moduleRefZ = Module["__D11popup_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D11popup_state11__moduleRefZ");

var __D19playback_controller11__moduleRefZ = Module["__D19playback_controller11__moduleRefZ"] = makeInvalidEarlyAccess("__D19playback_controller11__moduleRefZ");

var __D11plane_bytes11__moduleRefZ = Module["__D11plane_bytes11__moduleRefZ"] = makeInvalidEarlyAccess("__D11plane_bytes11__moduleRefZ");

var __D15pipe_gizmo_host11__moduleRefZ = Module["__D15pipe_gizmo_host11__moduleRefZ"] = makeInvalidEarlyAccess("__D15pipe_gizmo_host11__moduleRefZ");

var __D25pipe_command_registration11__moduleRefZ = Module["__D25pipe_command_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D25pipe_command_registration11__moduleRefZ");

var __D9pie_state11__moduleRefZ = Module["__D9pie_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D9pie_state11__moduleRefZ");

var __D9pie_menus11__moduleRefZ = Module["__D9pie_menus11__moduleRefZ"] = makeInvalidEarlyAccess("__D9pie_menus11__moduleRefZ");

var __D12pie_geometry11__moduleRefZ = Module["__D12pie_geometry11__moduleRefZ"] = makeInvalidEarlyAccess("__D12pie_geometry11__moduleRefZ");

var __D10perf_probe11__moduleRefZ = Module["__D10perf_probe11__moduleRefZ"] = makeInvalidEarlyAccess("__D10perf_probe11__moduleRefZ");

var __D4path11__moduleRefZ = Module["__D4path11__moduleRefZ"] = makeInvalidEarlyAccess("__D4path11__moduleRefZ");

var __D14params_widgets11__moduleRefZ = Module["__D14params_widgets11__moduleRefZ"] = makeInvalidEarlyAccess("__D14params_widgets11__moduleRefZ");

var __D6params11__moduleRefZ = Module["__D6params11__moduleRefZ"] = makeInvalidEarlyAccess("__D6params11__moduleRefZ");

var __D13overlay_space11__moduleRefZ = Module["__D13overlay_space11__moduleRefZ"] = makeInvalidEarlyAccess("__D13overlay_space11__moduleRefZ");

var __D8operator11__moduleRefZ = Module["__D8operator11__moduleRefZ"] = makeInvalidEarlyAccess("__D8operator11__moduleRefZ");

var __D12morph_target11__moduleRefZ = Module["__D12morph_target11__moduleRefZ"] = makeInvalidEarlyAccess("__D12morph_target11__moduleRefZ");

var __D15mesh_visibility11__moduleRefZ = Module["__D15mesh_visibility11__moduleRefZ"] = makeInvalidEarlyAccess("__D15mesh_visibility11__moduleRefZ");

var __D9mesh_topo11__moduleRefZ = Module["__D9mesh_topo11__moduleRefZ"] = makeInvalidEarlyAccess("__D9mesh_topo11__moduleRefZ");

var __D10mesh_stats11__moduleRefZ = Module["__D10mesh_stats11__moduleRefZ"] = makeInvalidEarlyAccess("__D10mesh_stats11__moduleRefZ");

var __D12mesh_selsets11__moduleRefZ = Module["__D12mesh_selsets11__moduleRefZ"] = makeInvalidEarlyAccess("__D12mesh_selsets11__moduleRefZ");

var __D11mesh_planes11__moduleRefZ = Module["__D11mesh_planes11__moduleRefZ"] = makeInvalidEarlyAccess("__D11mesh_planes11__moduleRefZ");

var __D8mesh_ops7thicken11__moduleRefZ = Module["__D8mesh_ops7thicken11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops7thicken11__moduleRefZ");

var __D8mesh_ops11select_loop11__moduleRefZ = Module["__D8mesh_ops11select_loop11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops11select_loop11__moduleRefZ");

var __D8mesh_ops7revolve11__moduleRefZ = Module["__D8mesh_ops7revolve11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops7revolve11__moduleRefZ");

var __D8mesh_ops10poly_bevel11__moduleRefZ = Module["__D8mesh_ops10poly_bevel11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops10poly_bevel11__moduleRefZ");

var __D8mesh_ops10loop_slice11__moduleRefZ = Module["__D8mesh_ops10loop_slice11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops10loop_slice11__moduleRefZ");

var __D8mesh_ops7extrude11__moduleRefZ = Module["__D8mesh_ops7extrude11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops7extrude11__moduleRefZ");

var __D8mesh_ops10edge_bevel11__moduleRefZ = Module["__D8mesh_ops10edge_bevel11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops10edge_bevel11__moduleRefZ");

var __D8mesh_ops8decimate11__moduleRefZ = Module["__D8mesh_ops8decimate11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops8decimate11__moduleRefZ");

var __D8mesh_ops3cut11__moduleRefZ = Module["__D8mesh_ops3cut11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops3cut11__moduleRefZ");

var __D8mesh_ops14connected_mask11__moduleRefZ = Module["__D8mesh_ops14connected_mask11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops14connected_mask11__moduleRefZ");

var __D8mesh_ops7cleanup11__moduleRefZ = Module["__D8mesh_ops7cleanup11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops7cleanup11__moduleRefZ");

var __D8mesh_ops6bridge11__moduleRefZ = Module["__D8mesh_ops6bridge11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops6bridge11__moduleRefZ");

var __D8mesh_ops8box_geom11__moduleRefZ = Module["__D8mesh_ops8box_geom11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops8box_geom11__moduleRefZ");

var __D8mesh_ops12bevel_vertex11__moduleRefZ = Module["__D8mesh_ops12bevel_vertex11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops12bevel_vertex11__moduleRefZ");

var __D8mesh_ops9bevel_fin11__moduleRefZ = Module["__D8mesh_ops9bevel_fin11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops9bevel_fin11__moduleRefZ");

var __D8mesh_ops12bevel_curves11__moduleRefZ = Module["__D8mesh_ops12bevel_curves11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_ops12bevel_curves11__moduleRefZ");

var __D10mesh_morph11__moduleRefZ = Module["__D10mesh_morph11__moduleRefZ"] = makeInvalidEarlyAccess("__D10mesh_morph11__moduleRefZ");

var __D8mesh_gpu11__moduleRefZ = Module["__D8mesh_gpu11__moduleRefZ"] = makeInvalidEarlyAccess("__D8mesh_gpu11__moduleRefZ");

var __D15mesh_edit_delta11__moduleRefZ = Module["__D15mesh_edit_delta11__moduleRefZ"] = makeInvalidEarlyAccess("__D15mesh_edit_delta11__moduleRefZ");

var __D15mesh_edge_slice11__moduleRefZ = Module["__D15mesh_edge_slice11__moduleRefZ"] = makeInvalidEarlyAccess("__D15mesh_edge_slice11__moduleRefZ");

var __D10mesh_dirty11__moduleRefZ = Module["__D10mesh_dirty11__moduleRefZ"] = makeInvalidEarlyAccess("__D10mesh_dirty11__moduleRefZ");

var __D16mesh_corner_maps11__moduleRefZ = Module["__D16mesh_corner_maps11__moduleRefZ"] = makeInvalidEarlyAccess("__D16mesh_corner_maps11__moduleRefZ");

var __D25mesh_command_registration11__moduleRefZ = Module["__D25mesh_command_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D25mesh_command_registration11__moduleRefZ");

var __D9mesh_bbox11__moduleRefZ = Module["__D9mesh_bbox11__moduleRefZ"] = makeInvalidEarlyAccess("__D9mesh_bbox11__moduleRefZ");

var __D13mesh_analysis11__moduleRefZ = Module["__D13mesh_analysis11__moduleRefZ"] = makeInvalidEarlyAccess("__D13mesh_analysis11__moduleRefZ");

var __D4mesh11__moduleRefZ = Module["__D4mesh11__moduleRefZ"] = makeInvalidEarlyAccess("__D4mesh11__moduleRefZ");

var __D4math11__moduleRefZ = Module["__D4math11__moduleRefZ"] = makeInvalidEarlyAccess("__D4math11__moduleRefZ");

var __D14macro_recorder11__moduleRefZ = Module["__D14macro_recorder11__moduleRefZ"] = makeInvalidEarlyAccess("__D14macro_recorder11__moduleRefZ");

var __D3log11__moduleRefZ = Module["__D3log11__moduleRefZ"] = makeInvalidEarlyAccess("__D3log11__moduleRefZ");

var __D23live_registration_roles11__moduleRefZ = Module["__D23live_registration_roles11__moduleRefZ"] = makeInvalidEarlyAccess("__D23live_registration_roles11__moduleRefZ");

var __D19layout_reset_action11__moduleRefZ = Module["__D19layout_reset_action11__moduleRefZ"] = makeInvalidEarlyAccess("__D19layout_reset_action11__moduleRefZ");

var __D12layer_params11__moduleRefZ = Module["__D12layer_params11__moduleRefZ"] = makeInvalidEarlyAccess("__D12layer_params11__moduleRefZ");

var __D8json_num11__moduleRefZ = Module["__D8json_num11__moduleRefZ"] = makeInvalidEarlyAccess("__D8json_num11__moduleRefZ");

var __D10item_xform11__moduleRefZ = Module["__D10item_xform11__moduleRefZ"] = makeInvalidEarlyAccess("__D10item_xform11__moduleRefZ");

var __D9item_pick11__moduleRefZ = Module["__D9item_pick11__moduleRefZ"] = makeInvalidEarlyAccess("__D9item_pick11__moduleRefZ");

var __D10item_kinds11__moduleRefZ = Module["__D10item_kinds11__moduleRefZ"] = makeInvalidEarlyAccess("__D10item_kinds11__moduleRefZ");

var __D25item_command_registration11__moduleRefZ = Module["__D25item_command_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D25item_command_registration11__moduleRefZ");

var __D2io8scene_ir11__moduleRefZ = Module["__D2io8scene_ir11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io8scene_ir11__moduleRefZ");

var __D2io12scene_import11__moduleRefZ = Module["__D2io12scene_import11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io12scene_import11__moduleRefZ");

var __D2io12scene_export11__moduleRefZ = Module["__D2io12scene_export11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io12scene_export11__moduleRefZ");

var __D2io6native11__moduleRefZ = Module["__D2io6native11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io6native11__moduleRefZ");

var __D2io10lwo_import11__moduleRefZ = Module["__D2io10lwo_import11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io10lwo_import11__moduleRefZ");

var __D2io10lwo_export11__moduleRefZ = Module["__D2io10lwo_export11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io10lwo_export11__moduleRefZ");

var __D2io10image_path11__moduleRefZ = Module["__D2io10image_path11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io10image_path11__moduleRefZ");

var __D2io12image_decode11__moduleRefZ = Module["__D2io12image_decode11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io12image_decode11__moduleRefZ");

var __D2io7formats11__moduleRefZ = Module["__D2io7formats11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io7formats11__moduleRefZ");

var __D2io19file_dialog_browser11__moduleRefZ = Module["__D2io19file_dialog_browser11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io19file_dialog_browser11__moduleRefZ");

var __D2io11file_dialog11__moduleRefZ = Module["__D2io11file_dialog11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io11file_dialog11__moduleRefZ");

var __D2io9doc_state11__moduleRefZ = Module["__D2io9doc_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io9doc_state11__moduleRefZ");

var __D2io14assimp_runtime11__moduleRefZ = Module["__D2io14assimp_runtime11__moduleRefZ"] = makeInvalidEarlyAccess("__D2io14assimp_runtime11__moduleRefZ");

var __D11input_zones11__moduleRefZ = Module["__D11input_zones11__moduleRefZ"] = makeInvalidEarlyAccess("__D11input_zones11__moduleRefZ");

var __D12input_router11__moduleRefZ = Module["__D12input_router11__moduleRefZ"] = makeInvalidEarlyAccess("__D12input_router11__moduleRefZ");

var __D17input_frame_state11__moduleRefZ = Module["__D17input_frame_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D17input_frame_state11__moduleRefZ");

var __D13input_context11__moduleRefZ = Module["__D13input_context11__moduleRefZ"] = makeInvalidEarlyAccess("__D13input_context11__moduleRefZ");

var __D11imgui_style11__moduleRefZ = Module["__D11imgui_style11__moduleRefZ"] = makeInvalidEarlyAccess("__D11imgui_style11__moduleRefZ");

var __D19imgui_flag_boundary11__moduleRefZ = Module["__D19imgui_flag_boundary11__moduleRefZ"] = makeInvalidEarlyAccess("__D19imgui_flag_boundary11__moduleRefZ");

var __D16imgui_event_gate11__moduleRefZ = Module["__D16imgui_event_gate11__moduleRefZ"] = makeInvalidEarlyAccess("__D16imgui_event_gate11__moduleRefZ");

var __D11image_plane11__moduleRefZ = Module["__D11image_plane11__moduleRefZ"] = makeInvalidEarlyAccess("__D11image_plane11__moduleRefZ");

var __D10image_data11__moduleRefZ = Module["__D10image_data11__moduleRefZ"] = makeInvalidEarlyAccess("__D10image_data11__moduleRefZ");

var __D11image_cache11__moduleRefZ = Module["__D11image_cache11__moduleRefZ"] = makeInvalidEarlyAccess("__D11image_cache11__moduleRefZ");

var __D14http_transport11__moduleRefZ = Module["__D14http_transport11__moduleRefZ"] = makeInvalidEarlyAccess("__D14http_transport11__moduleRefZ");

var __D11http_server11__moduleRefZ = Module["__D11http_server11__moduleRefZ"] = makeInvalidEarlyAccess("__D11http_server11__moduleRefZ");

var __D14http_providers11__moduleRefZ = Module["__D14http_providers11__moduleRefZ"] = makeInvalidEarlyAccess("__D14http_providers11__moduleRefZ");

var __D9http_json11__moduleRefZ = Module["__D9http_json11__moduleRefZ"] = makeInvalidEarlyAccess("__D9http_json11__moduleRefZ");

var __D20http_command_adapter11__moduleRefZ = Module["__D20http_command_adapter11__moduleRefZ"] = makeInvalidEarlyAccess("__D20http_command_adapter11__moduleRefZ");

var __D11hover_state11__moduleRefZ = Module["__D11hover_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D11hover_state11__moduleRefZ");

var __D26history_macro_registration11__moduleRefZ = Module["__D26history_macro_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D26history_macro_registration11__moduleRefZ");

var __D7handles6shapes11__moduleRefZ = Module["__D7handles6shapes11__moduleRefZ"] = makeInvalidEarlyAccess("__D7handles6shapes11__moduleRefZ");

var __D7handles7gl_util11__moduleRefZ = Module["__D7handles7gl_util11__moduleRefZ"] = makeInvalidEarlyAccess("__D7handles7gl_util11__moduleRefZ");

var __D7handles13gizmo_metrics11__moduleRefZ = Module["__D7handles13gizmo_metrics11__moduleRefZ"] = makeInvalidEarlyAccess("__D7handles13gizmo_metrics11__moduleRefZ");

var __D7handles7arbiter11__moduleRefZ = Module["__D7handles7arbiter11__moduleRefZ"] = makeInvalidEarlyAccess("__D7handles7arbiter11__moduleRefZ");

var __D7handler11__moduleRefZ = Module["__D7handler11__moduleRefZ"] = makeInvalidEarlyAccess("__D7handler11__moduleRefZ");

var __D25guarded_action_controller11__moduleRefZ = Module["__D25guarded_action_controller11__moduleRefZ"] = makeInvalidEarlyAccess("__D25guarded_action_controller11__moduleRefZ");

var __D10gpu_select11__moduleRefZ = Module["__D10gpu_select11__moduleRefZ"] = makeInvalidEarlyAccess("__D10gpu_select11__moduleRefZ");

var __D15gl_thread_guard11__moduleRefZ = Module["__D15gl_thread_guard11__moduleRefZ"] = makeInvalidEarlyAccess("__D15gl_thread_guard11__moduleRefZ");

var __D5gizmo11__moduleRefZ = Module["__D5gizmo11__moduleRefZ"] = makeInvalidEarlyAccess("__D5gizmo11__moduleRefZ");

var __D18geometry_clipboard11__moduleRefZ = Module["__D18geometry_clipboard11__moduleRefZ"] = makeInvalidEarlyAccess("__D18geometry_clipboard11__moduleRefZ");

var __D11frame_stall11__moduleRefZ = Module["__D11frame_stall11__moduleRefZ"] = makeInvalidEarlyAccess("__D11frame_stall11__moduleRefZ");

var __D12frame_runner11__moduleRefZ = Module["__D12frame_runner11__moduleRefZ"] = makeInvalidEarlyAccess("__D12frame_runner11__moduleRefZ");

var __D12forms_render11__moduleRefZ = Module["__D12forms_render11__moduleRefZ"] = makeInvalidEarlyAccess("__D12forms_render11__moduleRefZ");

var __D5forms11__moduleRefZ = Module["__D5forms11__moduleRefZ"] = makeInvalidEarlyAccess("__D5forms11__moduleRefZ");

var __D20file_io_registration11__moduleRefZ = Module["__D20file_io_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D20file_io_registration11__moduleRefZ");

var __D14falloff_render11__moduleRefZ = Module["__D14falloff_render11__moduleRefZ"] = makeInvalidEarlyAccess("__D14falloff_render11__moduleRefZ");

var __D15falloff_handles11__moduleRefZ = Module["__D15falloff_handles11__moduleRefZ"] = makeInvalidEarlyAccess("__D15falloff_handles11__moduleRefZ");

var __D7falloff11__moduleRefZ = Module["__D7falloff11__moduleRefZ"] = makeInvalidEarlyAccess("__D7falloff11__moduleRefZ");

var __D8eventlog11__moduleRefZ = Module["__D8eventlog11__moduleRefZ"] = makeInvalidEarlyAccess("__D8eventlog11__moduleRefZ");

var __D10editor_app11__moduleRefZ = Module["__D10editor_app11__moduleRefZ"] = makeInvalidEarlyAccess("__D10editor_app11__moduleRefZ");

var __D8editmode11__moduleRefZ = Module["__D8editmode11__moduleRefZ"] = makeInvalidEarlyAccess("__D8editmode11__moduleRefZ");

var __D22edit_tool_registration11__moduleRefZ = Module["__D22edit_tool_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D22edit_tool_registration11__moduleRefZ");

var __D12edit_session11__moduleRefZ = Module["__D12edit_session11__moduleRefZ"] = makeInvalidEarlyAccess("__D12edit_session11__moduleRefZ");

var __D13drag_identity11__moduleRefZ = Module["__D13drag_identity11__moduleRefZ"] = makeInvalidEarlyAccess("__D13drag_identity11__moduleRefZ");

var __D4drag11__moduleRefZ = Module["__D4drag11__moduleRefZ"] = makeInvalidEarlyAccess("__D4drag11__moduleRefZ");

var __D18document_selection11__moduleRefZ = Module["__D18document_selection11__moduleRefZ"] = makeInvalidEarlyAccess("__D18document_selection11__moduleRefZ");

var __D8document11__moduleRefZ = Module["__D8document11__moduleRefZ"] = makeInvalidEarlyAccess("__D8document11__moduleRefZ");

var __D12display_sync11__moduleRefZ = Module["__D12display_sync11__moduleRefZ"] = makeInvalidEarlyAccess("__D12display_sync11__moduleRefZ");

var __D13display_state11__moduleRefZ = Module["__D13display_state11__moduleRefZ"] = makeInvalidEarlyAccess("__D13display_state11__moduleRefZ");

var __D13deform_magnet11__moduleRefZ = Module["__D13deform_magnet11__moduleRefZ"] = makeInvalidEarlyAccess("__D13deform_magnet11__moduleRefZ");

var __D24create_tool_registration11__moduleRefZ = Module["__D24create_tool_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D24create_tool_registration11__moduleRefZ");

var __D13copilot_panel11__moduleRefZ = Module["__D13copilot_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D13copilot_panel11__moduleRefZ");

var __D15copilot_overlay11__moduleRefZ = Module["__D15copilot_overlay11__moduleRefZ"] = makeInvalidEarlyAccess("__D15copilot_overlay11__moduleRefZ");

var __D28copilot_command_registration11__moduleRefZ = Module["__D28copilot_command_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D28copilot_command_registration11__moduleRefZ");

var __D14coord_rounding11__moduleRefZ = Module["__D14coord_rounding11__moduleRefZ"] = makeInvalidEarlyAccess("__D14coord_rounding11__moduleRefZ");

var __D10constraint11__moduleRefZ = Module["__D10constraint11__moduleRefZ"] = makeInvalidEarlyAccess("__D10constraint11__moduleRefZ");

var __D8commands9workplane11__moduleRefZ = Module["__D8commands9workplane11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands9workplane11__moduleRefZ");

var __D8commands8viewport11view_preset11__moduleRefZ = Module["__D8commands8viewport11view_preset11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport11view_preset11__moduleRefZ");

var __D8commands8viewport6master11__moduleRefZ = Module["__D8commands8viewport6master11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport6master11__moduleRefZ");

var __D8commands8viewport13layout_preset11__moduleRefZ = Module["__D8commands8viewport13layout_preset11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport13layout_preset11__moduleRefZ");

var __D8commands8viewport12independence11__moduleRefZ = Module["__D8commands8viewport12independence11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport12independence11__moduleRefZ");

var __D8commands8viewport10grid_steps11__moduleRefZ = Module["__D8commands8viewport10grid_steps11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport10grid_steps11__moduleRefZ");

var __D8commands8viewport12fit_selected11__moduleRefZ = Module["__D8commands8viewport12fit_selected11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport12fit_selected11__moduleRefZ");

var __D8commands8viewport3fit11__moduleRefZ = Module["__D8commands8viewport3fit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport3fit11__moduleRefZ");

var __D8commands8viewport7display11__moduleRefZ = Module["__D8commands8viewport7display11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport7display11__moduleRefZ");

var __D8commands8viewport12command_base11__moduleRefZ = Module["__D8commands8viewport12command_base11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8viewport12command_base11__moduleRefZ");

var __D8commands2ui14viewport_props11__moduleRefZ = Module["__D8commands2ui14viewport_props11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui14viewport_props11__moduleRefZ");

var __D8commands2ui15tool_properties11__moduleRefZ = Module["__D8commands2ui15tool_properties11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui15tool_properties11__moduleRefZ");

var __D8commands2ui10statistics11__moduleRefZ = Module["__D8commands2ui10statistics11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui10statistics11__moduleRefZ");

var __D8commands2ui3pie11__moduleRefZ = Module["__D8commands2ui3pie11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui3pie11__moduleRefZ");

var __D8commands2ui12layout_reset11__moduleRefZ = Module["__D8commands2ui12layout_reset11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui12layout_reset11__moduleRefZ");

var __D8commands2ui10layer_list11__moduleRefZ = Module["__D8commands2ui10layer_list11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui10layer_list11__moduleRefZ");

var __D8commands2ui10image_list11__moduleRefZ = Module["__D8commands2ui10image_list11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui10image_list11__moduleRefZ");

var __D8commands2ui13copilot_panel11__moduleRefZ = Module["__D8commands2ui13copilot_panel11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui13copilot_panel11__moduleRefZ");

var __D8commands2ui8channels11__moduleRefZ = Module["__D8commands2ui8channels11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui8channels11__moduleRefZ");

var __D8commands2ui5about11__moduleRefZ = Module["__D8commands2ui5about11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ui5about11__moduleRefZ");

var __D8commands4tool3set11__moduleRefZ = Module["__D8commands4tool3set11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool3set11__moduleRefZ");

var __D8commands4tool5reset11__moduleRefZ = Module["__D8commands4tool5reset11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool5reset11__moduleRefZ");

var __D8commands4tool4pipe11__moduleRefZ = Module["__D8commands4tool4pipe11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool4pipe11__moduleRefZ");

var __D8commands4tool10panel_edit11__moduleRefZ = Module["__D8commands4tool10panel_edit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool10panel_edit11__moduleRefZ");

var __D8commands4tool9lifecycle11__moduleRefZ = Module["__D8commands4tool9lifecycle11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool9lifecycle11__moduleRefZ");

var __D8commands4tool4host11__moduleRefZ = Module["__D8commands4tool4host11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool4host11__moduleRefZ");

var __D8commands4tool8headless11__moduleRefZ = Module["__D8commands4tool8headless11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool8headless11__moduleRefZ");

var __D8commands4tool8do_apply11__moduleRefZ = Module["__D8commands4tool8do_apply11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool8do_apply11__moduleRefZ");

var __D8commands4tool13begin_session11__moduleRefZ = Module["__D8commands4tool13begin_session11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool13begin_session11__moduleRefZ");

var __D8commands4tool4attr11__moduleRefZ = Module["__D8commands4tool4attr11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4tool4attr11__moduleRefZ");

var __D8commands15test_undo_flags11__moduleRefZ = Module["__D8commands15test_undo_flags11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands15test_undo_flags11__moduleRefZ");

var __D8commands8symmetry6toggle11__moduleRefZ = Module["__D8commands8symmetry6toggle11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands8symmetry6toggle11__moduleRefZ");

var __D8commands4snap11toggle_type11__moduleRefZ = Module["__D8commands4snap11toggle_type11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4snap11toggle_type11__moduleRefZ");

var __D8commands4snap6toggle11__moduleRefZ = Module["__D8commands4snap6toggle11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4snap6toggle11__moduleRefZ");

var __D8commands4snap4mode11__moduleRefZ = Module["__D8commands4snap4mode11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4snap4mode11__moduleRefZ");

var __D8commands6select9type_from11__moduleRefZ = Module["__D8commands6select9type_from11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select9type_from11__moduleRefZ");

var __D8commands6select4sets11__moduleRefZ = Module["__D8commands6select4sets11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select4sets11__moduleRefZ");

var __D8commands6select4ring11__moduleRefZ = Module["__D8commands6select4ring11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select4ring11__moduleRefZ");

var __D8commands6select4more11__moduleRefZ = Module["__D8commands6select4more11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select4more11__moduleRefZ");

var __D8commands6select4loop11__moduleRefZ = Module["__D8commands6select4loop11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select4loop11__moduleRefZ");

var __D8commands6select4less11__moduleRefZ = Module["__D8commands6select4less11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select4less11__moduleRefZ");

var __D8commands6select6invert11__moduleRefZ = Module["__D8commands6select6invert11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select6invert11__moduleRefZ");

var __D8commands6select4fill11__moduleRefZ = Module["__D8commands6select4fill11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select4fill11__moduleRefZ");

var __D8commands6select6expand11__moduleRefZ = Module["__D8commands6select6expand11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select6expand11__moduleRefZ");

var __D8commands6select7element11__moduleRefZ = Module["__D8commands6select7element11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select7element11__moduleRefZ");

var __D8commands6select4drop11__moduleRefZ = Module["__D8commands6select4drop11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select4drop11__moduleRefZ");

var __D8commands6select7convert11__moduleRefZ = Module["__D8commands6select7convert11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select7convert11__moduleRefZ");

var __D8commands6select8contract11__moduleRefZ = Module["__D8commands6select8contract11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select8contract11__moduleRefZ");

var __D8commands6select7connect11__moduleRefZ = Module["__D8commands6select7connect11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select7connect11__moduleRefZ");

var __D8commands6select6by_tag11__moduleRefZ = Module["__D8commands6select6by_tag11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select6by_tag11__moduleRefZ");

var __D8commands6select7by_stat11__moduleRefZ = Module["__D8commands6select7by_stat11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select7by_stat11__moduleRefZ");

var __D8commands6select8boundary11__moduleRefZ = Module["__D8commands6select8boundary11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select8boundary11__moduleRefZ");

var __D8commands6select7between11__moduleRefZ = Module["__D8commands6select7between11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6select7between11__moduleRefZ");

var __D8commands5scene5reset11__moduleRefZ = Module["__D8commands5scene5reset11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands5scene5reset11__moduleRefZ");

var __D8commands5scene9load_mesh11__moduleRefZ = Module["__D8commands5scene9load_mesh11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands5scene9load_mesh11__moduleRefZ");

var __D8commands5prefs9trackball11__moduleRefZ = Module["__D8commands5prefs9trackball11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands5prefs9trackball11__moduleRefZ");

var __D8commands5prefs14coord_rounding11__moduleRefZ = Module["__D8commands5prefs14coord_rounding11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands5prefs14coord_rounding11__moduleRefZ");

var __D8commands4path6define11__moduleRefZ = Module["__D8commands4path6define11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4path6define11__moduleRefZ");

var __D8commands4mesh16weld_vertex_pair11__moduleRefZ = Module["__D8commands4mesh16weld_vertex_pair11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh16weld_vertex_pair11__moduleRefZ");

var __D8commands4mesh9weightmap11__moduleRefZ = Module["__D8commands4mesh9weightmap11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9weightmap11__moduleRefZ");

var __D8commands4mesh12vertex_split11__moduleRefZ = Module["__D8commands4mesh12vertex_split11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12vertex_split11__moduleRefZ");

var __D8commands4mesh10vertex_set11__moduleRefZ = Module["__D8commands4mesh10vertex_set11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10vertex_set11__moduleRefZ");

var __D8commands4mesh22vertex_position_result11__moduleRefZ = Module["__D8commands4mesh22vertex_position_result11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh22vertex_position_result11__moduleRefZ");

var __D8commands4mesh10vertex_new11__moduleRefZ = Module["__D8commands4mesh10vertex_new11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10vertex_new11__moduleRefZ");

var __D8commands4mesh14vertex_extrude11__moduleRefZ = Module["__D8commands4mesh14vertex_extrude11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh14vertex_extrude11__moduleRefZ");

var __D8commands4mesh11vertex_edit11__moduleRefZ = Module["__D8commands4mesh11vertex_edit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh11vertex_edit11__moduleRefZ");

var __D8commands4mesh13vertex_center11__moduleRefZ = Module["__D8commands4mesh13vertex_center11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh13vertex_center11__moduleRefZ");

var __D8commands4mesh12vertex_bevel11__moduleRefZ = Module["__D8commands4mesh12vertex_bevel11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12vertex_bevel11__moduleRefZ");

var __D8commands4mesh10vert_merge11__moduleRefZ = Module["__D8commands4mesh10vert_merge11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10vert_merge11__moduleRefZ");

var __D8commands4mesh9vert_join11__moduleRefZ = Module["__D8commands4mesh9vert_join11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9vert_join11__moduleRefZ");

var __D8commands4mesh9uv_unwrap11__moduleRefZ = Module["__D8commands4mesh9uv_unwrap11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9uv_unwrap11__moduleRefZ");

var __D8commands4mesh12uv_transform11__moduleRefZ = Module["__D8commands4mesh12uv_transform11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12uv_transform11__moduleRefZ");

var __D8commands4mesh8uv_relax11__moduleRefZ = Module["__D8commands4mesh8uv_relax11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh8uv_relax11__moduleRefZ");

var __D8commands4mesh10uv_project11__moduleRefZ = Module["__D8commands4mesh10uv_project11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10uv_project11__moduleRefZ");

var __D8commands4mesh7uv_pack11__moduleRefZ = Module["__D8commands4mesh7uv_pack11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh7uv_pack11__moduleRefZ");

var __D8commands4mesh11uv_map_util11__moduleRefZ = Module["__D8commands4mesh11uv_map_util11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh11uv_map_util11__moduleRefZ");

var __D8commands4mesh5unify11__moduleRefZ = Module["__D8commands4mesh5unify11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh5unify11__moduleRefZ");

var __D8commands4mesh6triple11__moduleRefZ = Module["__D8commands4mesh6triple11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6triple11__moduleRefZ");

var __D8commands4mesh9transform11__moduleRefZ = Module["__D8commands4mesh9transform11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9transform11__moduleRefZ");

var __D8commands4mesh7thicken11__moduleRefZ = Module["__D8commands4mesh7thicken11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh7thicken11__moduleRefZ");

var __D8commands4mesh10symmetrize11__moduleRefZ = Module["__D8commands4mesh10symmetrize11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10symmetrize11__moduleRefZ");

var __D8commands4mesh5sweep11__moduleRefZ = Module["__D8commands4mesh5sweep11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh5sweep11__moduleRefZ");

var __D8commands4mesh15subpatch_toggle11__moduleRefZ = Module["__D8commands4mesh15subpatch_toggle11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh15subpatch_toggle11__moduleRefZ");

var __D8commands4mesh17subdivide_faceted11__moduleRefZ = Module["__D8commands4mesh17subdivide_faceted11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh17subdivide_faceted11__moduleRefZ");

var __D8commands4mesh9subdivide11__moduleRefZ = Module["__D8commands4mesh9subdivide11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9subdivide11__moduleRefZ");

var __D8commands4mesh14stroke_extrude11__moduleRefZ = Module["__D8commands4mesh14stroke_extrude11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh14stroke_extrude11__moduleRefZ");

var __D8commands4mesh10split_face11__moduleRefZ = Module["__D8commands4mesh10split_face11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10split_face11__moduleRefZ");

var __D8commands4mesh10split_edge11__moduleRefZ = Module["__D8commands4mesh10split_edge11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10split_edge11__moduleRefZ");

var __D8commands4mesh9spin_edge11__moduleRefZ = Module["__D8commands4mesh9spin_edge11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9spin_edge11__moduleRefZ");

var __D8commands4mesh6spikey11__moduleRefZ = Module["__D8commands4mesh6spikey11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6spikey11__moduleRefZ");

var __D8commands4mesh12smooth_shift11__moduleRefZ = Module["__D8commands4mesh12smooth_shift11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12smooth_shift11__moduleRefZ");

var __D8commands4mesh6smooth11__moduleRefZ = Module["__D8commands4mesh6smooth11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6smooth11__moduleRefZ");

var __D8commands4mesh8set_part11__moduleRefZ = Module["__D8commands4mesh8set_part11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh8set_part11__moduleRefZ");

var __D8commands4mesh12set_material11__moduleRefZ = Module["__D8commands4mesh12set_material11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12set_material11__moduleRefZ");

var __D8commands4mesh12session_edit11__moduleRefZ = Module["__D8commands4mesh12session_edit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12session_edit11__moduleRefZ");

var __D8commands4mesh14selection_undo11__moduleRefZ = Module["__D8commands4mesh14selection_undo11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh14selection_undo11__moduleRefZ");

var __D8commands4mesh14selection_edit11__moduleRefZ = Module["__D8commands4mesh14selection_edit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh14selection_edit11__moduleRefZ");

var __D8commands4mesh6select11__moduleRefZ = Module["__D8commands4mesh6select11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6select11__moduleRefZ");

var __D8commands4mesh12screen_slice11__moduleRefZ = Module["__D8commands4mesh12screen_slice11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12screen_slice11__moduleRefZ");

var __D8commands4mesh7remove_11__moduleRefZ = Module["__D8commands4mesh7remove_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh7remove_11__moduleRefZ");

var __D8commands4mesh6remesh11__moduleRefZ = Module["__D8commands4mesh6remesh11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6remesh11__moduleRefZ");

var __D8commands4mesh6reduce11__moduleRefZ = Module["__D8commands4mesh6reduce11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6reduce11__moduleRefZ");

var __D8commands4mesh13radial_array_11__moduleRefZ = Module["__D8commands4mesh13radial_array_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh13radial_array_11__moduleRefZ");

var __D8commands4mesh12radial_align11__moduleRefZ = Module["__D8commands4mesh12radial_align11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12radial_align11__moduleRefZ");

var __D8commands4mesh8quantize11__moduleRefZ = Module["__D8commands4mesh8quantize11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh8quantize11__moduleRefZ");

var __D8commands4mesh9quadruple11__moduleRefZ = Module["__D8commands4mesh9quadruple11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9quadruple11__moduleRefZ");

var __D8commands4mesh13position_undo11__moduleRefZ = Module["__D8commands4mesh13position_undo11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh13position_undo11__moduleRefZ");

var __D8commands4mesh13polygon_align11__moduleRefZ = Module["__D8commands4mesh13polygon_align11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh13polygon_align11__moduleRefZ");

var __D8commands4mesh10poly_inset11__moduleRefZ = Module["__D8commands4mesh10poly_inset11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10poly_inset11__moduleRefZ");

var __D8commands4mesh6paste_11__moduleRefZ = Module["__D8commands4mesh6paste_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6paste_11__moduleRefZ");

var __D8commands4mesh11move_vertex11__moduleRefZ = Module["__D8commands4mesh11move_vertex11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh11move_vertex11__moduleRefZ");

var __D8commands4mesh10morph_edit11__moduleRefZ = Module["__D8commands4mesh10morph_edit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10morph_edit11__moduleRefZ");

var __D8commands4mesh5morph11__moduleRefZ = Module["__D8commands4mesh5morph11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh5morph11__moduleRefZ");

var __D8commands4mesh7mirror_11__moduleRefZ = Module["__D8commands4mesh7mirror_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh7mirror_11__moduleRefZ");

var __D8commands4mesh5merge11__moduleRefZ = Module["__D8commands4mesh5merge11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh5merge11__moduleRefZ");

var __D8commands4mesh13map_edit_undo11__moduleRefZ = Module["__D8commands4mesh13map_edit_undo11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh13map_edit_undo11__moduleRefZ");

var __D8commands4mesh12make_polygon11__moduleRefZ = Module["__D8commands4mesh12make_polygon11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12make_polygon11__moduleRefZ");

var __D8commands4mesh6magnet11__moduleRefZ = Module["__D8commands4mesh6magnet11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6magnet11__moduleRefZ");

var __D8commands4mesh10loop_slice11__moduleRefZ = Module["__D8commands4mesh10loop_slice11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10loop_slice11__moduleRefZ");

var __D8commands4mesh12linear_align11__moduleRefZ = Module["__D8commands4mesh12linear_align11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12linear_align11__moduleRefZ");

var __D8commands4mesh6jitter11__moduleRefZ = Module["__D8commands4mesh6jitter11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6jitter11__moduleRefZ");

var __D8commands4mesh4hide11__moduleRefZ = Module["__D8commands4mesh4hide11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh4hide11__moduleRefZ");

var __D8commands4mesh15gesture_payload11__moduleRefZ = Module["__D8commands4mesh15gesture_payload11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh15gesture_payload11__moduleRefZ");

var __D8commands4mesh4flip11__moduleRefZ = Module["__D8commands4mesh4flip11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh4flip11__moduleRefZ");

var __D8commands4mesh15fix_orientation11__moduleRefZ = Module["__D8commands4mesh15fix_orientation11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh15fix_orientation11__moduleRefZ");

var __D8commands4mesh12face_extrude11__moduleRefZ = Module["__D8commands4mesh12face_extrude11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12face_extrude11__moduleRefZ");

var __D8commands4mesh10edge_slide11__moduleRefZ = Module["__D8commands4mesh10edge_slide11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10edge_slide11__moduleRefZ");

var __D8commands4mesh10edge_slice11__moduleRefZ = Module["__D8commands4mesh10edge_slice11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10edge_slice11__moduleRefZ");

var __D8commands4mesh9edge_join11__moduleRefZ = Module["__D8commands4mesh9edge_join11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9edge_join11__moduleRefZ");

var __D8commands4mesh12edge_extrude11__moduleRefZ = Module["__D8commands4mesh12edge_extrude11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh12edge_extrude11__moduleRefZ");

var __D8commands4mesh11edge_extend11__moduleRefZ = Module["__D8commands4mesh11edge_extend11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh11edge_extend11__moduleRefZ");

var __D8commands4mesh11edge_crease11__moduleRefZ = Module["__D8commands4mesh11edge_crease11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh11edge_crease11__moduleRefZ");

var __D8commands4mesh10duplicate_11__moduleRefZ = Module["__D8commands4mesh10duplicate_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10duplicate_11__moduleRefZ");

var __D8commands4mesh13detriangulate11__moduleRefZ = Module["__D8commands4mesh13detriangulate11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh13detriangulate11__moduleRefZ");

var __D8commands4mesh7delete_11__moduleRefZ = Module["__D8commands4mesh7delete_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh7delete_11__moduleRefZ");

var __D8commands4mesh4cut_11__moduleRefZ = Module["__D8commands4mesh4cut_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh4cut_11__moduleRefZ");

var __D8commands4mesh5copy_11__moduleRefZ = Module["__D8commands4mesh5copy_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh5copy_11__moduleRefZ");

var __D8commands4mesh8collapse11__moduleRefZ = Module["__D8commands4mesh8collapse11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh8collapse11__moduleRefZ");

var __D8commands4mesh6clone_11__moduleRefZ = Module["__D8commands4mesh6clone_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6clone_11__moduleRefZ");

var __D8commands4mesh7cleanup11__moduleRefZ = Module["__D8commands4mesh7cleanup11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh7cleanup11__moduleRefZ");

var __D8commands4mesh6bridge11__moduleRefZ = Module["__D8commands4mesh6bridge11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6bridge11__moduleRefZ");

var __D8commands4mesh5bevel11__moduleRefZ = Module["__D8commands4mesh5bevel11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh5bevel11__moduleRefZ");

var __D8commands4mesh10axis_slice11__moduleRefZ = Module["__D8commands4mesh10axis_slice11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh10axis_slice11__moduleRefZ");

var __D8commands4mesh6array_11__moduleRefZ = Module["__D8commands4mesh6array_11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh6array_11__moduleRefZ");

var __D8commands4mesh9add_point11__moduleRefZ = Module["__D8commands4mesh9add_point11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4mesh9add_point11__moduleRefZ");

var __D8commands6macros13save_recorded11__moduleRefZ = Module["__D8commands6macros13save_recorded11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6macros13save_recorded11__moduleRefZ");

var __D8commands6macros6record11__moduleRefZ = Module["__D8commands6macros6record11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands6macros6record11__moduleRefZ");

var __D8commands5layer10xform_edit11__moduleRefZ = Module["__D8commands5layer10xform_edit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands5layer10xform_edit11__moduleRefZ");

var __D8commands5layerQp11__moduleRefZ = Module["__D8commands5layerQp11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands5layerQp11__moduleRefZ");

var __D8commands11image_planeQw11__moduleRefZ = Module["__D8commands11image_planeQw11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands11image_planeQw11__moduleRefZ");

var __D8commands5imageQp11__moduleRefZ = Module["__D8commands5imageQp11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands5imageQp11__moduleRefZ");

var __D8commands7history4undo11__moduleRefZ = Module["__D8commands7history4undo11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7history4undo11__moduleRefZ");

var __D8commands7history4show11__moduleRefZ = Module["__D8commands7history4show11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7history4show11__moduleRefZ");

var __D8commands7history14save_as_script11__moduleRefZ = Module["__D8commands7history14save_as_script11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7history14save_as_script11__moduleRefZ");

var __D8commands7history4redo11__moduleRefZ = Module["__D8commands7history4redo11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7history4redo11__moduleRefZ");

var __D8commands7history5clear11__moduleRefZ = Module["__D8commands7history5clear11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7history5clear11__moduleRefZ");

var __D8commands4file4save11__moduleRefZ = Module["__D8commands4file4save11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4file4save11__moduleRefZ");

var __D8commands4file4quit11__moduleRefZ = Module["__D8commands4file4quit11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4file4quit11__moduleRefZ");

var __D8commands4file4load11__moduleRefZ = Module["__D8commands4file4load11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4file4load11__moduleRefZ");

var __D8commands7falloff11__moduleRefZ = Module["__D8commands7falloff11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7falloff11__moduleRefZ");

var __D8commands7copilot14select_finding11__moduleRefZ = Module["__D8commands7copilot14select_finding11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7copilot14select_finding11__moduleRefZ");

var __D8commands7copilot13cycle_finding11__moduleRefZ = Module["__D8commands7copilot13cycle_finding11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7copilot13cycle_finding11__moduleRefZ");

var __D8commands7copilot7analyze11__moduleRefZ = Module["__D8commands7copilot7analyze11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands7copilot7analyze11__moduleRefZ");

var __D8commands9constrain6toggle11__moduleRefZ = Module["__D8commands9constrain6toggle11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands9constrain6toggle11__moduleRefZ");

var __D8commands4ai3d13import_result11__moduleRefZ = Module["__D8commands4ai3d13import_result11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4ai3d13import_result11__moduleRefZ");

var __D8commands4ai3d13generate_open11__moduleRefZ = Module["__D8commands4ai3d13generate_open11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4ai3d13generate_open11__moduleRefZ");

var __D8commands2ai6toggle11__moduleRefZ = Module["__D8commands2ai6toggle11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands2ai6toggle11__moduleRefZ");

var __D8commands4actr11__moduleRefZ = Module["__D8commands4actr11__moduleRefZ"] = makeInvalidEarlyAccess("__D8commands4actr11__moduleRefZ");

var __D15command_history11__moduleRefZ = Module["__D15command_history11__moduleRefZ"] = makeInvalidEarlyAccess("__D15command_history11__moduleRefZ");

var __D16command_executor11__moduleRefZ = Module["__D16command_executor11__moduleRefZ"] = makeInvalidEarlyAccess("__D16command_executor11__moduleRefZ");

var __D12command_args11__moduleRefZ = Module["__D12command_args11__moduleRefZ"] = makeInvalidEarlyAccess("__D12command_args11__moduleRefZ");

var __D7command11__moduleRefZ = Module["__D7command11__moduleRefZ"] = makeInvalidEarlyAccess("__D7command11__moduleRefZ");

var __D10change_bus11__moduleRefZ = Module["__D10change_bus11__moduleRefZ"] = makeInvalidEarlyAccess("__D10change_bus11__moduleRefZ");

var __D12camera_stamp11__moduleRefZ = Module["__D12camera_stamp11__moduleRefZ"] = makeInvalidEarlyAccess("__D12camera_stamp11__moduleRefZ");

var __D8bvh_pick11__moduleRefZ = Module["__D8bvh_pick11__moduleRefZ"] = makeInvalidEarlyAccess("__D8bvh_pick11__moduleRefZ");

var __D9buttonset11__moduleRefZ = Module["__D9buttonset11__moduleRefZ"] = makeInvalidEarlyAccess("__D9buttonset11__moduleRefZ");

var __D12bg_gpu_cache11__moduleRefZ = Module["__D12bg_gpu_cache11__moduleRefZ"] = makeInvalidEarlyAccess("__D12bg_gpu_cache11__moduleRefZ");

var __D9argstring11__moduleRefZ = Module["__D9argstring11__moduleRefZ"] = makeInvalidEarlyAccess("__D9argstring11__moduleRefZ");

var __D11args_dialog11__moduleRefZ = Module["__D11args_dialog11__moduleRefZ"] = makeInvalidEarlyAccess("__D11args_dialog11__moduleRefZ");

var __D27application_command_binding11__moduleRefZ = Module["__D27application_command_binding11__moduleRefZ"] = makeInvalidEarlyAccess("__D27application_command_binding11__moduleRefZ");

var __D11app_version11__moduleRefZ = Module["__D11app_version11__moduleRefZ"] = makeInvalidEarlyAccess("__D11app_version11__moduleRefZ");

var __D3app11__moduleRefZ = Module["__D3app11__moduleRefZ"] = makeInvalidEarlyAccess("__D3app11__moduleRefZ");

var __D23ai_command_registration11__moduleRefZ = Module["__D23ai_command_registration11__moduleRefZ"] = makeInvalidEarlyAccess("__D23ai_command_registration11__moduleRefZ");

var __D4ai3d15scene_validator11__moduleRefZ = Module["__D4ai3d15scene_validator11__moduleRefZ"] = makeInvalidEarlyAccess("__D4ai3d15scene_validator11__moduleRefZ");

var __D4ai3d10job_events11__moduleRefZ = Module["__D4ai3d10job_events11__moduleRefZ"] = makeInvalidEarlyAccess("__D4ai3d10job_events11__moduleRefZ");

var __D4ai3d11event_queue11__moduleRefZ = Module["__D4ai3d11event_queue11__moduleRefZ"] = makeInvalidEarlyAccess("__D4ai3d11event_queue11__moduleRefZ");

var __D2ai16training_dataset11__moduleRefZ = Module["__D2ai16training_dataset11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai16training_dataset11__moduleRefZ");

var __D2ai17synthetic_dataset11__moduleRefZ = Module["__D2ai17synthetic_dataset11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai17synthetic_dataset11__moduleRefZ");

var __D2ai23support_loop_candidates11__moduleRefZ = Module["__D2ai23support_loop_candidates11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai23support_loop_candidates11__moduleRefZ");

var __D2ai5state11__moduleRefZ = Module["__D2ai5state11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai5state11__moduleRefZ");

var __D2ai13ranker_schema11__moduleRefZ = Module["__D2ai13ranker_schema11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai13ranker_schema11__moduleRefZ");

var __D2ai12onnx_backend11__moduleRefZ = Module["__D2ai12onnx_backend11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai12onnx_backend11__moduleRefZ");

var __D2ai17offline_evaluator11__moduleRefZ = Module["__D2ai17offline_evaluator11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai17offline_evaluator11__moduleRefZ");

var __D2ai13model_adapter11__moduleRefZ = Module["__D2ai13model_adapter11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai13model_adapter11__moduleRefZ");

var __D2ai15mode_candidates11__moduleRefZ = Module["__D2ai15mode_candidates11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai15mode_candidates11__moduleRefZ");

var __D2ai22interaction_log_writer11__moduleRefZ = Module["__D2ai22interaction_log_writer11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai22interaction_log_writer11__moduleRefZ");

var __D2ai15interaction_log11__moduleRefZ = Module["__D2ai15interaction_log11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai15interaction_log11__moduleRefZ");

var __D2ai11interaction11__moduleRefZ = Module["__D2ai11interaction11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai11interaction11__moduleRefZ");

var __D2ai11exploration11__moduleRefZ = Module["__D2ai11exploration11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai11exploration11__moduleRefZ");

var __D2ai18element_candidates11__moduleRefZ = Module["__D2ai18element_candidates11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai18element_candidates11__moduleRefZ");

var __D2ai11debug_trace11__moduleRefZ = Module["__D2ai11debug_trace11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai11debug_trace11__moduleRefZ");

var __D2ai12copilot_gate11__moduleRefZ = Module["__D2ai12copilot_gate11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai12copilot_gate11__moduleRefZ");

var __D2ai8analysis11__moduleRefZ = Module["__D2ai8analysis11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai8analysis11__moduleRefZ");

var __D2ai7advisor11__moduleRefZ = Module["__D2ai7advisor11__moduleRefZ"] = makeInvalidEarlyAccess("__D2ai7advisor11__moduleRefZ");

var __D6bindbc6opengl4bind3arb7core_3011__moduleRefZ = Module["__D6bindbc6opengl4bind3arb7core_3011__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind3arb7core_3011__moduleRefZ");

var __D6bindbc6opengl4bind3arb7core_3111__moduleRefZ = Module["__D6bindbc6opengl4bind3arb7core_3111__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind3arb7core_3111__moduleRefZ");

var __D6bindbc6opengl4bind3arb7core_3311__moduleRefZ = Module["__D6bindbc6opengl4bind3arb7core_3311__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind3arb7core_3311__moduleRefZ");

var __D6bindbc6opengl4bind4gl1111__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1111__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl1111__moduleRefZ");

var __D6bindbc6opengl4bind4gl1311__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1311__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl1311__moduleRefZ");

var __D6bindbc6opengl4bind4gl1411__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1411__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl1411__moduleRefZ");

var __D6bindbc6opengl4bind4gl1511__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1511__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl1511__moduleRefZ");

var __D6bindbc6opengl4bind4gl2011__moduleRefZ = Module["__D6bindbc6opengl4bind4gl2011__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl2011__moduleRefZ");

var __D6bindbc6opengl4bind4gl3011__moduleRefZ = Module["__D6bindbc6opengl4bind4gl3011__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl3011__moduleRefZ");

var __D6bindbc6opengl4bind4gl3111__moduleRefZ = Module["__D6bindbc6opengl4bind4gl3111__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl3111__moduleRefZ");

var __D6bindbc6opengl4bind4gl3311__moduleRefZ = Module["__D6bindbc6opengl4bind4gl3311__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl4bind4gl3311__moduleRefZ");

var __D6bindbc6opengl7context11__moduleRefZ = Module["__D6bindbc6opengl7context11__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl7context11__moduleRefZ");

var __D6bindbc6opengl11__moduleRefZ = Module["__D6bindbc6opengl11__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6opengl11__moduleRefZ");

var __D6bindbc6loader7codegen11__moduleRefZ = Module["__D6bindbc6loader7codegen11__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6loader7codegen11__moduleRefZ");

var __D6bindbc6loader9sharedlib11__moduleRefZ = Module["__D6bindbc6loader9sharedlib11__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6loader9sharedlib11__moduleRefZ");

var __D3bvh1c11__moduleRefZ = Module["__D3bvh1c11__moduleRefZ"] = makeInvalidEarlyAccess("__D3bvh1c11__moduleRefZ");

var __D3osd1c11__moduleRefZ = Module["__D3osd1c11__moduleRefZ"] = makeInvalidEarlyAccess("__D3osd1c11__moduleRefZ");

var __D9stb_image1c11__moduleRefZ = Module["__D9stb_image1c11__moduleRefZ"] = makeInvalidEarlyAccess("__D9stb_image1c11__moduleRefZ");

var __D7d_imgui12imgui_cimgui11__moduleRefZ = Module["__D7d_imgui12imgui_cimgui11__moduleRefZ"] = makeInvalidEarlyAccess("__D7d_imgui12imgui_cimgui11__moduleRefZ");

var __D7d_imgui7imgui_h11__moduleRefZ = Module["__D7d_imgui7imgui_h11__moduleRefZ"] = makeInvalidEarlyAccess("__D7d_imgui7imgui_h11__moduleRefZ");

var __D7d_imgui11__moduleRefZ = Module["__D7d_imgui11__moduleRefZ"] = makeInvalidEarlyAccess("__D7d_imgui11__moduleRefZ");

var __D18imgui_impl_opengl311__moduleRefZ = Module["__D18imgui_impl_opengl311__moduleRefZ"] = makeInvalidEarlyAccess("__D18imgui_impl_opengl311__moduleRefZ");

var __D15imgui_impl_sdl211__moduleRefZ = Module["__D15imgui_impl_sdl211__moduleRefZ"] = makeInvalidEarlyAccess("__D15imgui_impl_sdl211__moduleRefZ");

var __D6bindbc3sdl6config11__moduleRefZ = Module["__D6bindbc3sdl6config11__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc3sdl6config11__moduleRefZ");

var __D6bindbc3sdl11__moduleRefZ = Module["__D6bindbc3sdl11__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc3sdl11__moduleRefZ");

var __D3sdl6stdinc11__moduleRefZ = Module["__D3sdl6stdinc11__moduleRefZ"] = makeInvalidEarlyAccess("__D3sdl6stdinc11__moduleRefZ");

var __D6bindbc6common7codegen11__moduleRefZ = Module["__D6bindbc6common7codegen11__moduleRefZ"] = makeInvalidEarlyAccess("__D6bindbc6common7codegen11__moduleRefZ");

var __D5dyaml8composer11__moduleRefZ = Module["__D5dyaml8composer11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml8composer11__moduleRefZ");

var __D5dyaml11constructor11__moduleRefZ = Module["__D5dyaml11constructor11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml11constructor11__moduleRefZ");

var __D5dyaml6dumper11__moduleRefZ = Module["__D5dyaml6dumper11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml6dumper11__moduleRefZ");

var __D5dyaml7emitter11__moduleRefZ = Module["__D5dyaml7emitter11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml7emitter11__moduleRefZ");

var __D5dyaml7escapes11__moduleRefZ = Module["__D5dyaml7escapes11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml7escapes11__moduleRefZ");

var __D5dyaml5event11__moduleRefZ = Module["__D5dyaml5event11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml5event11__moduleRefZ");

var __D5dyaml9exception11__moduleRefZ = Module["__D5dyaml9exception11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml9exception11__moduleRefZ");

var __D5dyaml6loader11__moduleRefZ = Module["__D5dyaml6loader11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml6loader11__moduleRefZ");

var __D5dyaml4node11__moduleRefZ = Module["__D5dyaml4node11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml4node11__moduleRefZ");

var __D5dyaml11__moduleRefZ = Module["__D5dyaml11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml11__moduleRefZ");

var __D5dyaml6parser11__moduleRefZ = Module["__D5dyaml6parser11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml6parser11__moduleRefZ");

var __D5dyaml5queue11__moduleRefZ = Module["__D5dyaml5queue11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml5queue11__moduleRefZ");

var __D5dyaml6reader11__moduleRefZ = Module["__D5dyaml6reader11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml6reader11__moduleRefZ");

var __D5dyaml11representer11__moduleRefZ = Module["__D5dyaml11representer11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml11representer11__moduleRefZ");

var __D5dyaml8resolver11__moduleRefZ = Module["__D5dyaml8resolver11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml8resolver11__moduleRefZ");

var __D5dyaml7scanner11__moduleRefZ = Module["__D5dyaml7scanner11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml7scanner11__moduleRefZ");

var __D5dyaml10serializer11__moduleRefZ = Module["__D5dyaml10serializer11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml10serializer11__moduleRefZ");

var __D5dyaml12tagdirective11__moduleRefZ = Module["__D5dyaml12tagdirective11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml12tagdirective11__moduleRefZ");

var __D5dyaml5token11__moduleRefZ = Module["__D5dyaml5token11__moduleRefZ"] = makeInvalidEarlyAccess("__D5dyaml5token11__moduleRefZ");

var __D4lwo211__moduleRefZ = Module["__D4lwo211__moduleRefZ"] = makeInvalidEarlyAccess("__D4lwo211__moduleRefZ");

var __D4lwo26writer11__moduleRefZ = Module["__D4lwo26writer11__moduleRefZ"] = makeInvalidEarlyAccess("__D4lwo26writer11__moduleRefZ");

var __D3etc1c4curl11__moduleRefZ = Module["__D3etc1c4curl11__moduleRefZ"] = makeInvalidEarlyAccess("__D3etc1c4curl11__moduleRefZ");

var __D3etc1c4zlib11__moduleRefZ = Module["__D3etc1c4zlib11__moduleRefZ"] = makeInvalidEarlyAccess("__D3etc1c4zlib11__moduleRefZ");

var __D3std9algorithm10comparison11__moduleRefZ = Module["__D3std9algorithm10comparison11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std9algorithm10comparison11__moduleRefZ");

var __D3std9algorithm9iteration11__moduleRefZ = Module["__D3std9algorithm9iteration11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std9algorithm9iteration11__moduleRefZ");

var __D3std9algorithm8mutation11__moduleRefZ = Module["__D3std9algorithm8mutation11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std9algorithm8mutation11__moduleRefZ");

var __D3std9algorithm9searching11__moduleRefZ = Module["__D3std9algorithm9searching11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std9algorithm9searching11__moduleRefZ");

var __D3std9algorithm7sorting11__moduleRefZ = Module["__D3std9algorithm7sorting11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std9algorithm7sorting11__moduleRefZ");

var __D3std5array11__moduleRefZ = Module["__D3std5array11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5array11__moduleRefZ");

var __D3std5ascii11__moduleRefZ = Module["__D3std5ascii11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5ascii11__moduleRefZ");

var __D3std6base6411__moduleRefZ = Module["__D3std6base6411__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6base6411__moduleRefZ");

var __D3std8bitmanip11__moduleRefZ = Module["__D3std8bitmanip11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8bitmanip11__moduleRefZ");

var __D3std10checkedint11__moduleRefZ = Module["__D3std10checkedint11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std10checkedint11__moduleRefZ");

var __D3std11concurrency11__moduleRefZ = Module["__D3std11concurrency11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std11concurrency11__moduleRefZ");

var __D3std4conv11__moduleRefZ = Module["__D3std4conv11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4conv11__moduleRefZ");

var __D3std8datetime4date11__moduleRefZ = Module["__D3std8datetime4date11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8datetime4date11__moduleRefZ");

var __D3std8datetime7systime11__moduleRefZ = Module["__D3std8datetime7systime11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8datetime7systime11__moduleRefZ");

var __D3std8datetime8timezone11__moduleRefZ = Module["__D3std8datetime8timezone11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8datetime8timezone11__moduleRefZ");

var __D3std6digest2md11__moduleRefZ = Module["__D3std6digest2md11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6digest2md11__moduleRefZ");

var __D3std6digest3sha11__moduleRefZ = Module["__D3std6digest3sha11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6digest3sha11__moduleRefZ");

var __D3std8encoding11__moduleRefZ = Module["__D3std8encoding11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8encoding11__moduleRefZ");

var __D3std9exception11__moduleRefZ = Module["__D3std9exception11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std9exception11__moduleRefZ");

var __D3std12experimental9allocator12gc_allocator11__moduleRefZ = Module["__D3std12experimental9allocator12gc_allocator11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std12experimental9allocator12gc_allocator11__moduleRefZ");

var __D3std12experimental9allocator10mallocator11__moduleRefZ = Module["__D3std12experimental9allocator10mallocator11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std12experimental9allocator10mallocator11__moduleRefZ");

var __D3std12experimental9allocator11__moduleRefZ = Module["__D3std12experimental9allocator11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std12experimental9allocator11__moduleRefZ");

var __D3std4file11__moduleRefZ = Module["__D3std4file11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4file11__moduleRefZ");

var __D3std6format8internal6floats11__moduleRefZ = Module["__D3std6format8internal6floats11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6format8internal6floats11__moduleRefZ");

var __D3std6format8internal5write11__moduleRefZ = Module["__D3std6format8internal5write11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6format8internal5write11__moduleRefZ");

var __D3std6format11__moduleRefZ = Module["__D3std6format11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6format11__moduleRefZ");

var __D3std6format4spec11__moduleRefZ = Module["__D3std6format4spec11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6format4spec11__moduleRefZ");

var __D3std6format5write11__moduleRefZ = Module["__D3std6format5write11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6format5write11__moduleRefZ");

var __D3std10functional11__moduleRefZ = Module["__D3std10functional11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std10functional11__moduleRefZ");

var __D3std8internal7cstring11__moduleRefZ = Module["__D3std8internal7cstring11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8internal7cstring11__moduleRefZ");

var __D3std8internal6memory11__moduleRefZ = Module["__D3std8internal6memory11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8internal6memory11__moduleRefZ");

var __D3std8internal12unicode_comp11__moduleRefZ = Module["__D3std8internal12unicode_comp11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8internal12unicode_comp11__moduleRefZ");

var __D3std8internal14unicode_tables11__moduleRefZ = Module["__D3std8internal14unicode_tables11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8internal14unicode_tables11__moduleRefZ");

var __D3std4json11__moduleRefZ = Module["__D3std4json11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4json11__moduleRefZ");

var __D3std6logger4core11__moduleRefZ = Module["__D3std6logger4core11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6logger4core11__moduleRefZ");

var __D3std6logger10filelogger11__moduleRefZ = Module["__D3std6logger10filelogger11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6logger10filelogger11__moduleRefZ");

var __D3std6logger11multilogger11__moduleRefZ = Module["__D3std6logger11multilogger11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6logger11multilogger11__moduleRefZ");

var __D3std4math9algebraic11__moduleRefZ = Module["__D3std4math9algebraic11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4math9algebraic11__moduleRefZ");

var __D3std4math11exponential11__moduleRefZ = Module["__D3std4math11exponential11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4math11exponential11__moduleRefZ");

var __D3std4math10operations11__moduleRefZ = Module["__D3std4math10operations11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4math10operations11__moduleRefZ");

var __D3std4math8rounding11__moduleRefZ = Module["__D3std4math8rounding11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4math8rounding11__moduleRefZ");

var __D3std4math6traits11__moduleRefZ = Module["__D3std4math6traits11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4math6traits11__moduleRefZ");

var __D3std4math12trigonometry11__moduleRefZ = Module["__D3std4math12trigonometry11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4math12trigonometry11__moduleRefZ");

var __D3std4meta11__moduleRefZ = Module["__D3std4meta11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4meta11__moduleRefZ");

var __D3std11parallelism11__moduleRefZ = Module["__D3std11parallelism11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std11parallelism11__moduleRefZ");

var __D3std4path11__moduleRefZ = Module["__D3std4path11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4path11__moduleRefZ");

var __D3std7process11__moduleRefZ = Module["__D3std7process11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std7process11__moduleRefZ");

var __D3std6random11__moduleRefZ = Module["__D3std6random11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6random11__moduleRefZ");

var __D3std5range11__moduleRefZ = Module["__D3std5range11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5range11__moduleRefZ");

var __D3std5range10primitives11__moduleRefZ = Module["__D3std5range10primitives11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5range10primitives11__moduleRefZ");

var __D3std5regex8internal12backtracking11__moduleRefZ = Module["__D3std5regex8internal12backtracking11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5regex8internal12backtracking11__moduleRefZ");

var __D3std5regex8internal2ir11__moduleRefZ = Module["__D3std5regex8internal2ir11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5regex8internal2ir11__moduleRefZ");

var __D3std5regex8internal6parser11__moduleRefZ = Module["__D3std5regex8internal6parser11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5regex8internal6parser11__moduleRefZ");

var __D3std5stdio11__moduleRefZ = Module["__D3std5stdio11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std5stdio11__moduleRefZ");

var __D3std6string11__moduleRefZ = Module["__D3std6string11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6string11__moduleRefZ");

var __D3std7sumtype11__moduleRefZ = Module["__D3std7sumtype11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std7sumtype11__moduleRefZ");

var __D3std6traits11__moduleRefZ = Module["__D3std6traits11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std6traits11__moduleRefZ");

var __D3std8typecons11__moduleRefZ = Module["__D3std8typecons11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std8typecons11__moduleRefZ");

var __D3std3uni11__moduleRefZ = Module["__D3std3uni11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std3uni11__moduleRefZ");

var __D3std3utf11__moduleRefZ = Module["__D3std3utf11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std3utf11__moduleRefZ");

var __D3std4uuid11__moduleRefZ = Module["__D3std4uuid11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4uuid11__moduleRefZ");

var __D3std7variant11__moduleRefZ = Module["__D3std7variant11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std7variant11__moduleRefZ");

var __D3std3zip11__moduleRefZ = Module["__D3std3zip11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std3zip11__moduleRefZ");

var __D3std4zlib11__moduleRefZ = Module["__D3std4zlib11__moduleRefZ"] = makeInvalidEarlyAccess("__D3std4zlib11__moduleRefZ");

var __D4core5bitop11__moduleRefZ = Module["__D4core5bitop11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core5bitop11__moduleRefZ");

var __D4core10checkedint11__moduleRefZ = Module["__D4core10checkedint11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core10checkedint11__moduleRefZ");

var __D4core5cpuid11__moduleRefZ = Module["__D4core5cpuid11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core5cpuid11__moduleRefZ");

var __D4core8demangle11__moduleRefZ = Module["__D4core8demangle11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8demangle11__moduleRefZ");

var __D4core9exception11__moduleRefZ = Module["__D4core9exception11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core9exception11__moduleRefZ");

var __D4core2gc6config11__moduleRefZ = Module["__D4core2gc6config11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core2gc6config11__moduleRefZ");

var __D4core2gc11gcinterface11__moduleRefZ = Module["__D4core2gc11gcinterface11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core2gc11gcinterface11__moduleRefZ");

var __D4core2gc8registry11__moduleRefZ = Module["__D4core2gc8registry11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core2gc8registry11__moduleRefZ");

var __D4core8internal5abort11__moduleRefZ = Module["__D4core8internal5abort11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5abort11__moduleRefZ");

var __D4core8internal5array9appending11__moduleRefZ = Module["__D4core8internal5array9appending11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array9appending11__moduleRefZ");

var __D4core8internal5array8capacity11__moduleRefZ = Module["__D4core8internal5array8capacity11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array8capacity11__moduleRefZ");

var __D4core8internal5array7casting11__moduleRefZ = Module["__D4core8internal5array7casting11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array7casting11__moduleRefZ");

var __D4core8internal5array13concatenation11__moduleRefZ = Module["__D4core8internal5array13concatenation11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array13concatenation11__moduleRefZ");

var __D4core8internal5array12construction11__moduleRefZ = Module["__D4core8internal5array12construction11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array12construction11__moduleRefZ");

var __D4core8internal5array11duplication11__moduleRefZ = Module["__D4core8internal5array11duplication11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array11duplication11__moduleRefZ");

var __D4core8internal5array8equality11__moduleRefZ = Module["__D4core8internal5array8equality11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array8equality11__moduleRefZ");

var __D4core8internal5array5utils11__moduleRefZ = Module["__D4core8internal5array5utils11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5array5utils11__moduleRefZ");

var __D4core8internal5cast_11__moduleRefZ = Module["__D4core8internal5cast_11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5cast_11__moduleRefZ");

var __D4core8internal9container5array11__moduleRefZ = Module["__D4core8internal9container5array11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal9container5array11__moduleRefZ");

var __D4core8internal9container6common11__moduleRefZ = Module["__D4core8internal9container6common11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal9container6common11__moduleRefZ");

var __D4core8internal9container7hashtab11__moduleRefZ = Module["__D4core8internal9container7hashtab11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal9container7hashtab11__moduleRefZ");

var __D4core8internal9container5treap11__moduleRefZ = Module["__D4core8internal9container5treap11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal9container5treap11__moduleRefZ");

var __D4core8internal7convert11__moduleRefZ = Module["__D4core8internal7convert11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal7convert11__moduleRefZ");

var __D4core8internal11destruction11__moduleRefZ = Module["__D4core8internal11destruction11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal11destruction11__moduleRefZ");

var __D4core8internal2gc4bits11__moduleRefZ = Module["__D4core8internal2gc4bits11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc4bits11__moduleRefZ");

var __D4core8internal2gc8blkcache11__moduleRefZ = Module["__D4core8internal2gc8blkcache11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc8blkcache11__moduleRefZ");

var __D4core8internal2gc9blockmeta11__moduleRefZ = Module["__D4core8internal2gc9blockmeta11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc9blockmeta11__moduleRefZ");

var __D4core8internal2gc4impl12conservativeQw11__moduleRefZ = Module["__D4core8internal2gc4impl12conservativeQw11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc4impl12conservativeQw11__moduleRefZ");

var __D4core8internal2gc4impl6manualQp11__moduleRefZ = Module["__D4core8internal2gc4impl6manualQp11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc4impl6manualQp11__moduleRefZ");

var __D4core8internal2gc4impl5protoQo11__moduleRefZ = Module["__D4core8internal2gc4impl5protoQo11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc4impl5protoQo11__moduleRefZ");

var __D4core8internal2gc2os11__moduleRefZ = Module["__D4core8internal2gc2os11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc2os11__moduleRefZ");

var __D4core8internal2gc9pooltable11__moduleRefZ = Module["__D4core8internal2gc9pooltable11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc9pooltable11__moduleRefZ");

var __D4core8internal2gc5proxy11__moduleRefZ = Module["__D4core8internal2gc5proxy11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal2gc5proxy11__moduleRefZ");

var __D4core8internal4hash11__moduleRefZ = Module["__D4core8internal4hash11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal4hash11__moduleRefZ");

var __D4core8internal8lifetime11__moduleRefZ = Module["__D4core8internal8lifetime11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal8lifetime11__moduleRefZ");

var __D4core8internal5newaa11__moduleRefZ = Module["__D4core8internal5newaa11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal5newaa11__moduleRefZ");

var __D4core8internal12parseoptions11__moduleRefZ = Module["__D4core8internal12parseoptions11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal12parseoptions11__moduleRefZ");

var __D4core8internal8spinlock11__moduleRefZ = Module["__D4core8internal8spinlock11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal8spinlock11__moduleRefZ");

var __D4core8internal6string11__moduleRefZ = Module["__D4core8internal6string11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal6string11__moduleRefZ");

var __D4core8internal7switch_11__moduleRefZ = Module["__D4core8internal7switch_11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal7switch_11__moduleRefZ");

var __D4core8internal3utf11__moduleRefZ = Module["__D4core8internal3utf11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal3utf11__moduleRefZ");

var __D4core8internal4util5array11__moduleRefZ = Module["__D4core8internal4util5array11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal4util5array11__moduleRefZ");

var __D4core8internal4util4math11__moduleRefZ = Module["__D4core8internal4util4math11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8internal4util4math11__moduleRefZ");

var __D4core8lifetime11__moduleRefZ = Module["__D4core8lifetime11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core8lifetime11__moduleRefZ");

var __D4core4math11__moduleRefZ = Module["__D4core4math11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core4math11__moduleRefZ");

var __D4core6memory11__moduleRefZ = Module["__D4core6memory11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core6memory11__moduleRefZ");

var __D4core7runtime11__moduleRefZ = Module["__D4core7runtime11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core7runtime11__moduleRefZ");

var __D4core4sync9condition11__moduleRefZ = Module["__D4core4sync9condition11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core4sync9condition11__moduleRefZ");

var __D4core4sync6config11__moduleRefZ = Module["__D4core4sync6config11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core4sync6config11__moduleRefZ");

var __D4core4sync9exception11__moduleRefZ = Module["__D4core4sync9exception11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core4sync9exception11__moduleRefZ");

var __D4core4sync5mutex11__moduleRefZ = Module["__D4core4sync5mutex11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core4sync5mutex11__moduleRefZ");

var __D4core6thread7context11__moduleRefZ = Module["__D4core6thread7context11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core6thread7context11__moduleRefZ");

var __D4core6thread8osthread11__moduleRefZ = Module["__D4core6thread8osthread11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core6thread8osthread11__moduleRefZ");

var __D4core6thread11__moduleRefZ = Module["__D4core6thread11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core6thread11__moduleRefZ");

var __D4core6thread10threadbase11__moduleRefZ = Module["__D4core6thread10threadbase11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core6thread10threadbase11__moduleRefZ");

var __D4core6thread11threadgroup11__moduleRefZ = Module["__D4core6thread11threadgroup11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core6thread11threadgroup11__moduleRefZ");

var __D4core6thread5types11__moduleRefZ = Module["__D4core6thread5types11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core6thread5types11__moduleRefZ");

var __D4core4time11__moduleRefZ = Module["__D4core4time11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core4time11__moduleRefZ");

var __D6object11__moduleRefZ = Module["__D6object11__moduleRefZ"] = makeInvalidEarlyAccess("__D6object11__moduleRefZ");

var __D2rt6aApply11__moduleRefZ = Module["__D2rt6aApply11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt6aApply11__moduleRefZ");

var __D2rt7aApplyR11__moduleRefZ = Module["__D2rt7aApplyR11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt7aApplyR11__moduleRefZ");

var __D2rt8arraycat11__moduleRefZ = Module["__D2rt8arraycat11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt8arraycat11__moduleRefZ");

var _rt_options = Module["_rt_options"] = makeInvalidEarlyAccess("_rt_options");

var _rt_envvars_enabled = Module["_rt_envvars_enabled"] = makeInvalidEarlyAccess("_rt_envvars_enabled");

var _rt_cmdline_enabled = Module["_rt_cmdline_enabled"] = makeInvalidEarlyAccess("_rt_cmdline_enabled");

var __D2rt6config11__moduleRefZ = Module["__D2rt6config11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt6config11__moduleRefZ");

var __D2rt9critical_11__moduleRefZ = Module["__D2rt9critical_11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt9critical_11__moduleRefZ");

var __D2rt3deh11__moduleRefZ = Module["__D2rt3deh11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt3deh11__moduleRefZ");

var __D2rt15deh_win64_posix11__moduleRefZ = Module["__D2rt15deh_win64_posix11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt15deh_win64_posix11__moduleRefZ");

var __D2rt6dmain211__moduleRefZ = Module["__D2rt6dmain211__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt6dmain211__moduleRefZ");

var __D2rt7dwarfeh11__moduleRefZ = Module["__D2rt7dwarfeh11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt7dwarfeh11__moduleRefZ");

var __D2rt7ehalloc11__moduleRefZ = Module["__D2rt7ehalloc11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt7ehalloc11__moduleRefZ");

var __D2rt8lifetime11__moduleRefZ = Module["__D2rt8lifetime11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt8lifetime11__moduleRefZ");

var __D2rt6memory11__moduleRefZ = Module["__D2rt6memory11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt6memory11__moduleRefZ");

var __D2rt5minfo11__moduleRefZ = Module["__D2rt5minfo11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt5minfo11__moduleRefZ");

var __D2rt8monitor_11__moduleRefZ = Module["__D2rt8monitor_11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt8monitor_11__moduleRefZ");

var __D2rt13sections_wasm11__moduleRefZ = Module["__D2rt13sections_wasm11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt13sections_wasm11__moduleRefZ");

var __D2rt5tlsgc11__moduleRefZ = Module["__D2rt5tlsgc11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt5tlsgc11__moduleRefZ");

var __D2rt4util8typeinfo11__moduleRefZ = Module["__D2rt4util8typeinfo11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt4util8typeinfo11__moduleRefZ");

var __D2rt4util7utility11__moduleRefZ = Module["__D2rt4util7utility11__moduleRefZ"] = makeInvalidEarlyAccess("__D2rt4util7utility11__moduleRefZ");

var __D4core3sys5posix7pthread11__moduleRefZ = Module["__D4core3sys5posix7pthread11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core3sys5posix7pthread11__moduleRefZ");

var __D4core3sys5posixQk4stat11__moduleRefZ = Module["__D4core3sys5posixQk4stat11__moduleRefZ"] = makeInvalidEarlyAccess("__D4core3sys5posixQk4stat11__moduleRefZ");

var wasmMemory = makeInvalidEarlyAccess("wasmMemory");

var wasmTable = makeInvalidEarlyAccess("wasmTable");

function assignWasmExports(wasmExports) {
  assert(typeof wasmExports["free"] != "undefined", "missing Wasm export: free");
  assert(typeof wasmExports["malloc"] != "undefined", "missing Wasm export: malloc");
  assert(typeof wasmExports["__main_argc_argv"] != "undefined", "missing Wasm export: __main_argc_argv");
  assert(typeof wasmExports["fflush"] != "undefined", "missing Wasm export: fflush");
  assert(typeof wasmExports["strerror"] != "undefined", "missing Wasm export: strerror");
  assert(typeof wasmExports["emscripten_stack_get_end"] != "undefined", "missing Wasm export: emscripten_stack_get_end");
  assert(typeof wasmExports["emscripten_stack_get_base"] != "undefined", "missing Wasm export: emscripten_stack_get_base");
  assert(typeof wasmExports["emscripten_stack_init"] != "undefined", "missing Wasm export: emscripten_stack_init");
  assert(typeof wasmExports["emscripten_stack_get_free"] != "undefined", "missing Wasm export: emscripten_stack_get_free");
  assert(typeof wasmExports["_emscripten_stack_restore"] != "undefined", "missing Wasm export: _emscripten_stack_restore");
  assert(typeof wasmExports["_emscripten_stack_alloc"] != "undefined", "missing Wasm export: _emscripten_stack_alloc");
  assert(typeof wasmExports["emscripten_stack_get_current"] != "undefined", "missing Wasm export: emscripten_stack_get_current");
  assert(typeof wasmExports["memory"] != "undefined", "missing Wasm export: memory");
  assert(typeof wasmExports["__indirect_function_table"] != "undefined", "missing Wasm export: __indirect_function_table");
  assert(typeof wasmExports["_D14weightmap_view11__moduleRefZ"] != "undefined", "missing Wasm export: _D14weightmap_view11__moduleRefZ");
  assert(typeof wasmExports["_D13web_gl_loader11__moduleRefZ"] != "undefined", "missing Wasm export: _D13web_gl_loader11__moduleRefZ");
  assert(typeof wasmExports["_D15viewport_scheme11__moduleRefZ"] != "undefined", "missing Wasm export: _D15viewport_scheme11__moduleRefZ");
  assert(typeof wasmExports["_D21viewport_overlay_mode11__moduleRefZ"] != "undefined", "missing Wasm export: _D21viewport_overlay_mode11__moduleRefZ");
  assert(typeof wasmExports["_D29viewport_command_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D29viewport_command_registration11__moduleRefZ");
  assert(typeof wasmExports["_D8viewport11__moduleRefZ"] != "undefined", "missing Wasm export: _D8viewport11__moduleRefZ");
  assert(typeof wasmExports["_D8viewgrid11__moduleRefZ"] != "undefined", "missing Wasm export: _D8viewgrid11__moduleRefZ");
  assert(typeof wasmExports["_D26view_settings_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D26view_settings_registration11__moduleRefZ");
  assert(typeof wasmExports["_D4view11__moduleRefZ"] != "undefined", "missing Wasm export: _D4view11__moduleRefZ");
  assert(typeof wasmExports["_D7uv_weld11__moduleRefZ"] != "undefined", "missing Wasm export: _D7uv_weld11__moduleRefZ");
  assert(typeof wasmExports["_D9uv_unwrap11__moduleRefZ"] != "undefined", "missing Wasm export: _D9uv_unwrap11__moduleRefZ");
  assert(typeof wasmExports["_D12uv_transform11__moduleRefZ"] != "undefined", "missing Wasm export: _D12uv_transform11__moduleRefZ");
  assert(typeof wasmExports["_D8uv_relax11__moduleRefZ"] != "undefined", "missing Wasm export: _D8uv_relax11__moduleRefZ");
  assert(typeof wasmExports["_D10uv_project11__moduleRefZ"] != "undefined", "missing Wasm export: _D10uv_project11__moduleRefZ");
  assert(typeof wasmExports["_D9uv_island11__moduleRefZ"] != "undefined", "missing Wasm export: _D9uv_island11__moduleRefZ");
  assert(typeof wasmExports["_D2ui15viewport_render11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui15viewport_render11__moduleRefZ");
  assert(typeof wasmExports["_D2ui19viewport_props_role11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui19viewport_props_role11__moduleRefZ");
  assert(typeof wasmExports["_D2ui21tool_properties_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui21tool_properties_panel11__moduleRefZ");
  assert(typeof wasmExports["_D2ui9stat_rows11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui9stat_rows11__moduleRefZ");
  assert(typeof wasmExports["_D2ui11stat_record11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui11stat_record11__moduleRefZ");
  assert(typeof wasmExports["_D2ui13retained_item11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui13retained_item11__moduleRefZ");
  assert(typeof wasmExports["_D2ui18remesh_modal_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui18remesh_modal_state11__moduleRefZ");
  assert(typeof wasmExports["_D2ui10pie_render11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui10pie_render11__moduleRefZ");
  assert(typeof wasmExports["_D2ui10pie_record11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui10pie_record11__moduleRefZ");
  assert(typeof wasmExports["_D2ui6panels11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui6panels11__moduleRefZ");
  assert(typeof wasmExports["_D2ui12panel_chrome11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui12panel_chrome11__moduleRefZ");
  assert(typeof wasmExports["_D2ui10mode_popup11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui10mode_popup11__moduleRefZ");
  assert(typeof wasmExports["_D2ui16layer_list_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui16layer_list_panel11__moduleRefZ");
  assert(typeof wasmExports["_D2ui9item_rows11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui9item_rows11__moduleRefZ");
  assert(typeof wasmExports["_D2ui11item_rename11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui11item_rename11__moduleRefZ");
  assert(typeof wasmExports["_D2ui11item_glyphs11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui11item_glyphs11__moduleRefZ");
  assert(typeof wasmExports["_D2ui18imgui_window_class11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui18imgui_window_class11__moduleRefZ");
  assert(typeof wasmExports["_D2ui10image_rows11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui10image_rows11__moduleRefZ");
  assert(typeof wasmExports["_D2ui16image_list_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui16image_list_panel11__moduleRefZ");
  assert(typeof wasmExports["_D2ui13history_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui13history_panel11__moduleRefZ");
  assert(typeof wasmExports["_D2ui17guard_modal_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui17guard_modal_state11__moduleRefZ");
  assert(typeof wasmExports["_D2ui9dock_drag11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui9dock_drag11__moduleRefZ");
  assert(typeof wasmExports["_D2ui13discard_guard11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui13discard_guard11__moduleRefZ");
  assert(typeof wasmExports["_D2ui14command_notice11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui14command_notice11__moduleRefZ");
  assert(typeof wasmExports["_D2ui14channels_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui14channels_panel11__moduleRefZ");
  assert(typeof wasmExports["_D2ui12channel_rows11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui12channel_rows11__moduleRefZ");
  assert(typeof wasmExports["_D2ui11button_face11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui11button_face11__moduleRefZ");
  assert(typeof wasmExports["_D2ui12availability11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui12availability11__moduleRefZ");
  assert(typeof wasmExports["_D2ui11action_menu11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ui11action_menu11__moduleRefZ");
  assert(typeof wasmExports["_D12tsan_preinit11__moduleRefZ"] != "undefined", "missing Wasm export: _D12tsan_preinit11__moduleRefZ");
  assert(typeof wasmExports["_D13tsan_annotate11__moduleRefZ"] != "undefined", "missing Wasm export: _D13tsan_annotate11__moduleRefZ");
  assert(typeof wasmExports["_D27transform_tool_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D27transform_tool_registration11__moduleRefZ");
  assert(typeof wasmExports["_D9trackball11__moduleRefZ"] != "undefined", "missing Wasm export: _D9trackball11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform14xfrm_transform11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform14xfrm_transform11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform9xfrm_item11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform9xfrm_item11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform12xfrm_handles11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform12xfrm_handles11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform10xfrm_apply11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform10xfrm_apply11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform13xform_kernels11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform13xform_kernels11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transformQk11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transformQk11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform5scale11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform5scale11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform6rotate11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform6rotate11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform19relocate_plane_test11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform19relocate_plane_test11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform14relocate_plane11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform14relocate_plane11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform4move11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform4move11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform11morph_route11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform11morph_route11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform18item_xform_kernels11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform18item_xform_kernels11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9transform7arcball11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9transform7arcball11__moduleRefZ");
  assert(typeof wasmExports["_D5tools5slice10slice_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools5slice10slice_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools5slice15loop_slice_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools5slice15loop_slice_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools5slice10edge_slide11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools5slice10edge_slide11__moduleRefZ");
  assert(typeof wasmExports["_D5tools5slice15edge_slice_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools5slice15edge_slice_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit19vertex_extrude_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit19vertex_extrude_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit17vertex_bevel_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit17vertex_bevel_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit15vert_merge_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit15vert_merge_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12topology_pen4tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12topology_pen4tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12topology_pen10snap_guide11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12topology_pen10snap_guide11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12topology_pen6render11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12topology_pen6render11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12topology_pen11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12topology_pen11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12topology_pen4json11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12topology_pen4json11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12topology_pen4defs11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12topology_pen4defs11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit4tack11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit4tack11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12smooth_relax11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12smooth_relax11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit6reduce11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit6reduce11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit15preview_rebuild11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit15preview_rebuild11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit15poly_inset_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit15poly_inset_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12poly_extrude11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12poly_extrude11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit10poly_bevel11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit10poly_bevel11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit12edge_extrude11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit12edge_extrude11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit11edge_extend11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit11edge_extend11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit10edge_bevel11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit10edge_bevel11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit9drag_weld11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit9drag_weld11__moduleRefZ");
  assert(typeof wasmExports["_D5tools4edit11bridge_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools4edit11bridge_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6deform19stroke_extrude_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6deform19stroke_extrude_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6deform17smooth_shift_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6deform17smooth_shift_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6deform4push11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6deform4push11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6deform6magnet11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6deform6magnet11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6deform4bend11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6deform4bend11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create12vertex_place11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create12vertex_place11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create4tube11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create4tube11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create5torus11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create5torus11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create6sphere11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create6sphere11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create21primitive_create_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create21primitive_create_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create3pen11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create3pen11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create8cylinder11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create8cylinder11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create13create_common11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create13create_common11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create4cone11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create4cone11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create7capsule11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create7capsule11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create3box11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create3box11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6create3arc11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6create3arc11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6common16session_mesh_key11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6common16session_mesh_key11__moduleRefZ");
  assert(typeof wasmExports["_D5tools6common15command_wrapper11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools6common15command_wrapper11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment17radial_sweep_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment17radial_sweep_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment17radial_array_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment17radial_array_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment17radial_align_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment17radial_align_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment6mirror11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment6mirror11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment17linear_align_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment17linear_align_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment10clone_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment10clone_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment10array_tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment10array_tool11__moduleRefZ");
  assert(typeof wasmExports["_D5tools9alignment13align_kernels11__moduleRefZ"] != "undefined", "missing Wasm export: _D5tools9alignment13align_kernels11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe7subject11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe7subject11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages9workplane11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages9workplane11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages8symmetry11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages8symmetry11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages4snap11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages4snap11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages4path11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages4path11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages7falloff11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages7falloff11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages9constrain11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages9constrain11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages4axis11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages4axis11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe6stages9actcenter11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe6stages9actcenter11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe5stage11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe5stage11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe8pipeline11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe8pipeline11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe7packets11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe7packets11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe5obbox11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe5obbox11__moduleRefZ");
  assert(typeof wasmExports["_D8toolpipe5guide11__moduleRefZ"] != "undefined", "missing Wasm export: _D8toolpipe5guide11__moduleRefZ");
  assert(typeof wasmExports["_D12tool_presets11__moduleRefZ"] != "undefined", "missing Wasm export: _D12tool_presets11__moduleRefZ");
  assert(typeof wasmExports["_D27tool_lifecycle_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D27tool_lifecycle_registration11__moduleRefZ");
  assert(typeof wasmExports["_D10tool_input11__moduleRefZ"] != "undefined", "missing Wasm export: _D10tool_input11__moduleRefZ");
  assert(typeof wasmExports["_D11tool_disarm11__moduleRefZ"] != "undefined", "missing Wasm export: _D11tool_disarm11__moduleRefZ");
  assert(typeof wasmExports["_D25tool_activation_ownership11__moduleRefZ"] != "undefined", "missing Wasm export: _D25tool_activation_ownership11__moduleRefZ");
  assert(typeof wasmExports["_D4tool11__moduleRefZ"] != "undefined", "missing Wasm export: _D4tool11__moduleRefZ");
  assert(typeof wasmExports["_D13symmetry_pick11__moduleRefZ"] != "undefined", "missing Wasm export: _D13symmetry_pick11__moduleRefZ");
  assert(typeof wasmExports["_D8symmetry11__moduleRefZ"] != "undefined", "missing Wasm export: _D8symmetry11__moduleRefZ");
  assert(typeof wasmExports["_D19subpatch_worker_web11__moduleRefZ"] != "undefined", "missing Wasm export: _D19subpatch_worker_web11__moduleRefZ");
  assert(typeof wasmExports["_D15subpatch_worker11__moduleRefZ"] != "undefined", "missing Wasm export: _D15subpatch_worker11__moduleRefZ");
  assert(typeof wasmExports["_D16subpatch_preview11__moduleRefZ"] != "undefined", "missing Wasm export: _D16subpatch_preview11__moduleRefZ");
  assert(typeof wasmExports["_D12subpatch_osd11__moduleRefZ"] != "undefined", "missing Wasm export: _D12subpatch_osd11__moduleRefZ");
  assert(typeof wasmExports["_D10step_trace11__moduleRefZ"] != "undefined", "missing Wasm export: _D10step_trace11__moduleRefZ");
  assert(typeof wasmExports["_D8snapshot11__moduleRefZ"] != "undefined", "missing Wasm export: _D8snapshot11__moduleRefZ");
  assert(typeof wasmExports["_D11snap_render11__moduleRefZ"] != "undefined", "missing Wasm export: _D11snap_render11__moduleRefZ");
  assert(typeof wasmExports["_D13snap_election11__moduleRefZ"] != "undefined", "missing Wasm export: _D13snap_election11__moduleRefZ");
  assert(typeof wasmExports["_D4snap11__moduleRefZ"] != "undefined", "missing Wasm export: _D4snap11__moduleRefZ");
  assert(typeof wasmExports["_D9shortcuts11__moduleRefZ"] != "undefined", "missing Wasm export: _D9shortcuts11__moduleRefZ");
  assert(typeof wasmExports["_D6shader11__moduleRefZ"] != "undefined", "missing Wasm export: _D6shader11__moduleRefZ");
  assert(typeof wasmExports["_D13session_owner11__moduleRefZ"] != "undefined", "missing Wasm export: _D13session_owner11__moduleRefZ");
  assert(typeof wasmExports["_D7seltype11__moduleRefZ"] != "undefined", "missing Wasm export: _D7seltype11__moduleRefZ");
  assert(typeof wasmExports["_D14selftest_fault11__moduleRefZ"] != "undefined", "missing Wasm export: _D14selftest_fault11__moduleRefZ");
  assert(typeof wasmExports["_D20selection_projection11__moduleRefZ"] != "undefined", "missing Wasm export: _D20selection_projection11__moduleRefZ");
  assert(typeof wasmExports["_D17selection_product11__moduleRefZ"] != "undefined", "missing Wasm export: _D17selection_product11__moduleRefZ");
  assert(typeof wasmExports["_D30selection_command_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D30selection_command_registration11__moduleRefZ");
  assert(typeof wasmExports["_D17select_visibility11__moduleRefZ"] != "undefined", "missing Wasm export: _D17select_visibility11__moduleRefZ");
  assert(typeof wasmExports["_D9sdl_error11__moduleRefZ"] != "undefined", "missing Wasm export: _D9sdl_error11__moduleRefZ");
  assert(typeof wasmExports["_D14screen_buckets11__moduleRefZ"] != "undefined", "missing Wasm export: _D14screen_buckets11__moduleRefZ");
  assert(typeof wasmExports["_D19scene_reset_effects11__moduleRefZ"] != "undefined", "missing Wasm export: _D19scene_reset_effects11__moduleRefZ");
  assert(typeof wasmExports["_D33scene_file_lifecycle_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D33scene_file_lifecycle_registration11__moduleRefZ");
  assert(typeof wasmExports["_D6render5scene11__moduleRefZ"] != "undefined", "missing Wasm export: _D6render5scene11__moduleRefZ");
  assert(typeof wasmExports["_D6render11rpr_backend11__moduleRefZ"] != "undefined", "missing Wasm export: _D6render11rpr_backend11__moduleRefZ");
  assert(typeof wasmExports["_D6render10render_mvp11__moduleRefZ"] != "undefined", "missing Wasm export: _D6render10render_mvp11__moduleRefZ");
  assert(typeof wasmExports["_D6render11render_diff11__moduleRefZ"] != "undefined", "missing Wasm export: _D6render11render_diff11__moduleRefZ");
  assert(typeof wasmExports["_D6render14cycles_backend11__moduleRefZ"] != "undefined", "missing Wasm export: _D6render14cycles_backend11__moduleRefZ");
  assert(typeof wasmExports["_D6render14backend_bridge11__moduleRefZ"] != "undefined", "missing Wasm export: _D6render14backend_bridge11__moduleRefZ");
  assert(typeof wasmExports["_D6render7backend11__moduleRefZ"] != "undefined", "missing Wasm export: _D6render7backend11__moduleRefZ");
  assert(typeof wasmExports["_D6remesh10remesh_job11__moduleRefZ"] != "undefined", "missing Wasm export: _D6remesh10remesh_job11__moduleRefZ");
  assert(typeof wasmExports["_D6remesh13region_stitch11__moduleRefZ"] != "undefined", "missing Wasm export: _D6remesh13region_stitch11__moduleRefZ");
  assert(typeof wasmExports["_D8registry11__moduleRefZ"] != "undefined", "missing Wasm export: _D8registry11__moduleRefZ");
  assert(typeof wasmExports["_D12registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D12registration11__moduleRefZ");
  assert(typeof wasmExports["_D19record_observer_hub11__moduleRefZ"] != "undefined", "missing Wasm export: _D19record_observer_hub11__moduleRefZ");
  assert(typeof wasmExports["_D14property_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D14property_panel11__moduleRefZ");
  assert(typeof wasmExports["_D25prepared_xfrm_update_tail11__moduleRefZ"] != "undefined", "missing Wasm export: _D25prepared_xfrm_update_tail11__moduleRefZ");
  assert(typeof wasmExports["_D31prepared_xfrm_update_edit_close11__moduleRefZ"] != "undefined", "missing Wasm export: _D31prepared_xfrm_update_edit_close11__moduleRefZ");
  assert(typeof wasmExports["_D29prepared_xfrm_update_boundary11__moduleRefZ"] != "undefined", "missing Wasm export: _D29prepared_xfrm_update_boundary11__moduleRefZ");
  assert(typeof wasmExports["_D23prepared_xfrm_slot_poll11__moduleRefZ"] != "undefined", "missing Wasm export: _D23prepared_xfrm_slot_poll11__moduleRefZ");
  assert(typeof wasmExports["_D20prepared_xfrm_replay11__moduleRefZ"] != "undefined", "missing Wasm export: _D20prepared_xfrm_replay11__moduleRefZ");
  assert(typeof wasmExports["_D26prepared_xfrm_refire_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D26prepared_xfrm_refire_state11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_xfrm_activation_session11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_xfrm_activation_session11__moduleRefZ");
  assert(typeof wasmExports["_D34prepared_vertex_merge_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D34prepared_vertex_merge_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_vertex_merge_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_vertex_merge_activation11__moduleRefZ");
  assert(typeof wasmExports["_D36prepared_vertex_extrude_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D36prepared_vertex_extrude_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D34prepared_vertex_extrude_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D34prepared_vertex_extrude_activation11__moduleRefZ");
  assert(typeof wasmExports["_D34prepared_vertex_bevel_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D34prepared_vertex_bevel_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_vertex_bevel_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_vertex_bevel_activation11__moduleRefZ");
  assert(typeof wasmExports["_D37prepared_transform_product_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D37prepared_transform_product_activation11__moduleRefZ");
  assert(typeof wasmExports["_D29prepared_transform_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D29prepared_transform_activation11__moduleRefZ");
  assert(typeof wasmExports["_D28prepared_topology_pen_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D28prepared_topology_pen_update11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_topology_pen_deactivate11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_topology_pen_deactivate11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_topology_pen_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_topology_pen_activation11__moduleRefZ");
  assert(typeof wasmExports["_D24prepared_tool_transition11__moduleRefZ"] != "undefined", "missing Wasm export: _D24prepared_tool_transition11__moduleRefZ");
  assert(typeof wasmExports["_D20prepared_tool_effect11__moduleRefZ"] != "undefined", "missing Wasm export: _D20prepared_tool_effect11__moduleRefZ");
  assert(typeof wasmExports["_D24prepared_tack_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D24prepared_tack_activation11__moduleRefZ");
  assert(typeof wasmExports["_D34prepared_stroke_extrude_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D34prepared_stroke_extrude_activation11__moduleRefZ");
  assert(typeof wasmExports["_D34prepared_smooth_shift_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D34prepared_smooth_shift_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_smooth_shift_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_smooth_shift_activation11__moduleRefZ");
  assert(typeof wasmExports["_D27prepared_slice_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D27prepared_slice_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D25prepared_slice_deactivate11__moduleRefZ"] != "undefined", "missing Wasm export: _D25prepared_slice_deactivate11__moduleRefZ");
  assert(typeof wasmExports["_D25prepared_slice_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D25prepared_slice_activation11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_selection_profile_image11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_selection_profile_image11__moduleRefZ");
  assert(typeof wasmExports["_D26prepared_selection_profile11__moduleRefZ"] != "undefined", "missing Wasm export: _D26prepared_selection_profile11__moduleRefZ");
  assert(typeof wasmExports["_D21prepared_scale_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D21prepared_scale_update11__moduleRefZ");
  assert(typeof wasmExports["_D22prepared_rotate_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D22prepared_rotate_update11__moduleRefZ");
  assert(typeof wasmExports["_D31prepared_reduction_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D31prepared_reduction_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D23prepared_record_context11__moduleRefZ"] != "undefined", "missing Wasm export: _D23prepared_record_context11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_radial_sweep_transition11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_radial_sweep_transition11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_radial_array_transition11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_radial_array_transition11__moduleRefZ");
  assert(typeof wasmExports["_D22prepared_private_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D22prepared_private_state11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_poly_inset_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_poly_inset_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D30prepared_poly_inset_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D30prepared_poly_inset_activation11__moduleRefZ");
  assert(typeof wasmExports["_D34prepared_poly_extrude_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D34prepared_poly_extrude_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_poly_extrude_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_poly_extrude_activation11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_poly_bevel_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_poly_bevel_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D30prepared_poly_bevel_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D30prepared_poly_bevel_activation11__moduleRefZ");
  assert(typeof wasmExports["_D24prepared_pipe_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D24prepared_pipe_activation11__moduleRefZ");
  assert(typeof wasmExports["_D20prepared_move_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D20prepared_move_update11__moduleRefZ");
  assert(typeof wasmExports["_D26prepared_mirror_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D26prepared_mirror_activation11__moduleRefZ");
  assert(typeof wasmExports["_D28prepared_magnet_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D28prepared_magnet_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_loop_slice_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_loop_slice_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D30prepared_loop_slice_deactivate11__moduleRefZ"] != "undefined", "missing Wasm export: _D30prepared_loop_slice_deactivate11__moduleRefZ");
  assert(typeof wasmExports["_D30prepared_loop_slice_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D30prepared_loop_slice_activation11__moduleRefZ");
  assert(typeof wasmExports["_D23prepared_inherited_noop11__moduleRefZ"] != "undefined", "missing Wasm export: _D23prepared_inherited_noop11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_edge_slice_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_edge_slice_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D30prepared_edge_slice_deactivate11__moduleRefZ"] != "undefined", "missing Wasm export: _D30prepared_edge_slice_deactivate11__moduleRefZ");
  assert(typeof wasmExports["_D30prepared_edge_slice_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D30prepared_edge_slice_activation11__moduleRefZ");
  assert(typeof wasmExports["_D34prepared_edge_extrude_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D34prepared_edge_extrude_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_edge_extrude_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_edge_extrude_activation11__moduleRefZ");
  assert(typeof wasmExports["_D36prepared_edge_extend_tool_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D36prepared_edge_extend_tool_activation11__moduleRefZ");
  assert(typeof wasmExports["_D33prepared_edge_extend_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D33prepared_edge_extend_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D31prepared_edge_extend_deactivate11__moduleRefZ"] != "undefined", "missing Wasm export: _D31prepared_edge_extend_deactivate11__moduleRefZ");
  assert(typeof wasmExports["_D32prepared_edge_bevel_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D32prepared_edge_bevel_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D30prepared_edge_bevel_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D30prepared_edge_bevel_activation11__moduleRefZ");
  assert(typeof wasmExports["_D35prepared_command_wrapper_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D35prepared_command_wrapper_activation11__moduleRefZ");
  assert(typeof wasmExports["_D26prepared_bridge_activation11__moduleRefZ"] != "undefined", "missing Wasm export: _D26prepared_bridge_activation11__moduleRefZ");
  assert(typeof wasmExports["_D18prepared_box_param11__moduleRefZ"] != "undefined", "missing Wasm export: _D18prepared_box_param11__moduleRefZ");
  assert(typeof wasmExports["_D27prepared_array_param_update11__moduleRefZ"] != "undefined", "missing Wasm export: _D27prepared_array_param_update11__moduleRefZ");
  assert(typeof wasmExports["_D5prefs11__moduleRefZ"] != "undefined", "missing Wasm export: _D5prefs11__moduleRefZ");
  assert(typeof wasmExports["_D11popup_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D11popup_state11__moduleRefZ");
  assert(typeof wasmExports["_D19playback_controller11__moduleRefZ"] != "undefined", "missing Wasm export: _D19playback_controller11__moduleRefZ");
  assert(typeof wasmExports["_D11plane_bytes11__moduleRefZ"] != "undefined", "missing Wasm export: _D11plane_bytes11__moduleRefZ");
  assert(typeof wasmExports["_D15pipe_gizmo_host11__moduleRefZ"] != "undefined", "missing Wasm export: _D15pipe_gizmo_host11__moduleRefZ");
  assert(typeof wasmExports["_D25pipe_command_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D25pipe_command_registration11__moduleRefZ");
  assert(typeof wasmExports["_D9pie_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D9pie_state11__moduleRefZ");
  assert(typeof wasmExports["_D9pie_menus11__moduleRefZ"] != "undefined", "missing Wasm export: _D9pie_menus11__moduleRefZ");
  assert(typeof wasmExports["_D12pie_geometry11__moduleRefZ"] != "undefined", "missing Wasm export: _D12pie_geometry11__moduleRefZ");
  assert(typeof wasmExports["_D10perf_probe11__moduleRefZ"] != "undefined", "missing Wasm export: _D10perf_probe11__moduleRefZ");
  assert(typeof wasmExports["_D4path11__moduleRefZ"] != "undefined", "missing Wasm export: _D4path11__moduleRefZ");
  assert(typeof wasmExports["_D14params_widgets11__moduleRefZ"] != "undefined", "missing Wasm export: _D14params_widgets11__moduleRefZ");
  assert(typeof wasmExports["_D6params11__moduleRefZ"] != "undefined", "missing Wasm export: _D6params11__moduleRefZ");
  assert(typeof wasmExports["_D13overlay_space11__moduleRefZ"] != "undefined", "missing Wasm export: _D13overlay_space11__moduleRefZ");
  assert(typeof wasmExports["_D8operator11__moduleRefZ"] != "undefined", "missing Wasm export: _D8operator11__moduleRefZ");
  assert(typeof wasmExports["_D12morph_target11__moduleRefZ"] != "undefined", "missing Wasm export: _D12morph_target11__moduleRefZ");
  assert(typeof wasmExports["_D15mesh_visibility11__moduleRefZ"] != "undefined", "missing Wasm export: _D15mesh_visibility11__moduleRefZ");
  assert(typeof wasmExports["_D9mesh_topo11__moduleRefZ"] != "undefined", "missing Wasm export: _D9mesh_topo11__moduleRefZ");
  assert(typeof wasmExports["_D10mesh_stats11__moduleRefZ"] != "undefined", "missing Wasm export: _D10mesh_stats11__moduleRefZ");
  assert(typeof wasmExports["_D12mesh_selsets11__moduleRefZ"] != "undefined", "missing Wasm export: _D12mesh_selsets11__moduleRefZ");
  assert(typeof wasmExports["_D11mesh_planes11__moduleRefZ"] != "undefined", "missing Wasm export: _D11mesh_planes11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops7thicken11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops7thicken11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops11select_loop11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops11select_loop11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops7revolve11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops7revolve11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops10poly_bevel11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops10poly_bevel11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops10loop_slice11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops10loop_slice11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops7extrude11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops7extrude11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops10edge_bevel11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops10edge_bevel11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops8decimate11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops8decimate11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops3cut11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops3cut11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops14connected_mask11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops14connected_mask11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops7cleanup11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops7cleanup11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops6bridge11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops6bridge11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops8box_geom11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops8box_geom11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops12bevel_vertex11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops12bevel_vertex11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops9bevel_fin11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops9bevel_fin11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_ops12bevel_curves11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_ops12bevel_curves11__moduleRefZ");
  assert(typeof wasmExports["_D10mesh_morph11__moduleRefZ"] != "undefined", "missing Wasm export: _D10mesh_morph11__moduleRefZ");
  assert(typeof wasmExports["_D8mesh_gpu11__moduleRefZ"] != "undefined", "missing Wasm export: _D8mesh_gpu11__moduleRefZ");
  assert(typeof wasmExports["_D15mesh_edit_delta11__moduleRefZ"] != "undefined", "missing Wasm export: _D15mesh_edit_delta11__moduleRefZ");
  assert(typeof wasmExports["_D15mesh_edge_slice11__moduleRefZ"] != "undefined", "missing Wasm export: _D15mesh_edge_slice11__moduleRefZ");
  assert(typeof wasmExports["_D10mesh_dirty11__moduleRefZ"] != "undefined", "missing Wasm export: _D10mesh_dirty11__moduleRefZ");
  assert(typeof wasmExports["_D16mesh_corner_maps11__moduleRefZ"] != "undefined", "missing Wasm export: _D16mesh_corner_maps11__moduleRefZ");
  assert(typeof wasmExports["_D25mesh_command_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D25mesh_command_registration11__moduleRefZ");
  assert(typeof wasmExports["_D9mesh_bbox11__moduleRefZ"] != "undefined", "missing Wasm export: _D9mesh_bbox11__moduleRefZ");
  assert(typeof wasmExports["_D13mesh_analysis11__moduleRefZ"] != "undefined", "missing Wasm export: _D13mesh_analysis11__moduleRefZ");
  assert(typeof wasmExports["_D4mesh11__moduleRefZ"] != "undefined", "missing Wasm export: _D4mesh11__moduleRefZ");
  assert(typeof wasmExports["_D4math11__moduleRefZ"] != "undefined", "missing Wasm export: _D4math11__moduleRefZ");
  assert(typeof wasmExports["_D14macro_recorder11__moduleRefZ"] != "undefined", "missing Wasm export: _D14macro_recorder11__moduleRefZ");
  assert(typeof wasmExports["_D3log11__moduleRefZ"] != "undefined", "missing Wasm export: _D3log11__moduleRefZ");
  assert(typeof wasmExports["_D23live_registration_roles11__moduleRefZ"] != "undefined", "missing Wasm export: _D23live_registration_roles11__moduleRefZ");
  assert(typeof wasmExports["_D19layout_reset_action11__moduleRefZ"] != "undefined", "missing Wasm export: _D19layout_reset_action11__moduleRefZ");
  assert(typeof wasmExports["_D12layer_params11__moduleRefZ"] != "undefined", "missing Wasm export: _D12layer_params11__moduleRefZ");
  assert(typeof wasmExports["_D8json_num11__moduleRefZ"] != "undefined", "missing Wasm export: _D8json_num11__moduleRefZ");
  assert(typeof wasmExports["_D10item_xform11__moduleRefZ"] != "undefined", "missing Wasm export: _D10item_xform11__moduleRefZ");
  assert(typeof wasmExports["_D9item_pick11__moduleRefZ"] != "undefined", "missing Wasm export: _D9item_pick11__moduleRefZ");
  assert(typeof wasmExports["_D10item_kinds11__moduleRefZ"] != "undefined", "missing Wasm export: _D10item_kinds11__moduleRefZ");
  assert(typeof wasmExports["_D25item_command_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D25item_command_registration11__moduleRefZ");
  assert(typeof wasmExports["_D2io8scene_ir11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io8scene_ir11__moduleRefZ");
  assert(typeof wasmExports["_D2io12scene_import11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io12scene_import11__moduleRefZ");
  assert(typeof wasmExports["_D2io12scene_export11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io12scene_export11__moduleRefZ");
  assert(typeof wasmExports["_D2io6native11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io6native11__moduleRefZ");
  assert(typeof wasmExports["_D2io10lwo_import11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io10lwo_import11__moduleRefZ");
  assert(typeof wasmExports["_D2io10lwo_export11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io10lwo_export11__moduleRefZ");
  assert(typeof wasmExports["_D2io10image_path11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io10image_path11__moduleRefZ");
  assert(typeof wasmExports["_D2io12image_decode11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io12image_decode11__moduleRefZ");
  assert(typeof wasmExports["_D2io7formats11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io7formats11__moduleRefZ");
  assert(typeof wasmExports["_D2io19file_dialog_browser11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io19file_dialog_browser11__moduleRefZ");
  assert(typeof wasmExports["_D2io11file_dialog11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io11file_dialog11__moduleRefZ");
  assert(typeof wasmExports["_D2io9doc_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io9doc_state11__moduleRefZ");
  assert(typeof wasmExports["_D2io14assimp_runtime11__moduleRefZ"] != "undefined", "missing Wasm export: _D2io14assimp_runtime11__moduleRefZ");
  assert(typeof wasmExports["_D11input_zones11__moduleRefZ"] != "undefined", "missing Wasm export: _D11input_zones11__moduleRefZ");
  assert(typeof wasmExports["_D12input_router11__moduleRefZ"] != "undefined", "missing Wasm export: _D12input_router11__moduleRefZ");
  assert(typeof wasmExports["_D17input_frame_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D17input_frame_state11__moduleRefZ");
  assert(typeof wasmExports["_D13input_context11__moduleRefZ"] != "undefined", "missing Wasm export: _D13input_context11__moduleRefZ");
  assert(typeof wasmExports["_D11imgui_style11__moduleRefZ"] != "undefined", "missing Wasm export: _D11imgui_style11__moduleRefZ");
  assert(typeof wasmExports["_D19imgui_flag_boundary11__moduleRefZ"] != "undefined", "missing Wasm export: _D19imgui_flag_boundary11__moduleRefZ");
  assert(typeof wasmExports["_D16imgui_event_gate11__moduleRefZ"] != "undefined", "missing Wasm export: _D16imgui_event_gate11__moduleRefZ");
  assert(typeof wasmExports["_D11image_plane11__moduleRefZ"] != "undefined", "missing Wasm export: _D11image_plane11__moduleRefZ");
  assert(typeof wasmExports["_D10image_data11__moduleRefZ"] != "undefined", "missing Wasm export: _D10image_data11__moduleRefZ");
  assert(typeof wasmExports["_D11image_cache11__moduleRefZ"] != "undefined", "missing Wasm export: _D11image_cache11__moduleRefZ");
  assert(typeof wasmExports["_D14http_transport11__moduleRefZ"] != "undefined", "missing Wasm export: _D14http_transport11__moduleRefZ");
  assert(typeof wasmExports["_D11http_server11__moduleRefZ"] != "undefined", "missing Wasm export: _D11http_server11__moduleRefZ");
  assert(typeof wasmExports["_D14http_providers11__moduleRefZ"] != "undefined", "missing Wasm export: _D14http_providers11__moduleRefZ");
  assert(typeof wasmExports["_D9http_json11__moduleRefZ"] != "undefined", "missing Wasm export: _D9http_json11__moduleRefZ");
  assert(typeof wasmExports["_D20http_command_adapter11__moduleRefZ"] != "undefined", "missing Wasm export: _D20http_command_adapter11__moduleRefZ");
  assert(typeof wasmExports["_D11hover_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D11hover_state11__moduleRefZ");
  assert(typeof wasmExports["_D26history_macro_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D26history_macro_registration11__moduleRefZ");
  assert(typeof wasmExports["_D7handles6shapes11__moduleRefZ"] != "undefined", "missing Wasm export: _D7handles6shapes11__moduleRefZ");
  assert(typeof wasmExports["_D7handles7gl_util11__moduleRefZ"] != "undefined", "missing Wasm export: _D7handles7gl_util11__moduleRefZ");
  assert(typeof wasmExports["_D7handles13gizmo_metrics11__moduleRefZ"] != "undefined", "missing Wasm export: _D7handles13gizmo_metrics11__moduleRefZ");
  assert(typeof wasmExports["_D7handles7arbiter11__moduleRefZ"] != "undefined", "missing Wasm export: _D7handles7arbiter11__moduleRefZ");
  assert(typeof wasmExports["_D7handler11__moduleRefZ"] != "undefined", "missing Wasm export: _D7handler11__moduleRefZ");
  assert(typeof wasmExports["_D25guarded_action_controller11__moduleRefZ"] != "undefined", "missing Wasm export: _D25guarded_action_controller11__moduleRefZ");
  assert(typeof wasmExports["_D10gpu_select11__moduleRefZ"] != "undefined", "missing Wasm export: _D10gpu_select11__moduleRefZ");
  assert(typeof wasmExports["_D15gl_thread_guard11__moduleRefZ"] != "undefined", "missing Wasm export: _D15gl_thread_guard11__moduleRefZ");
  assert(typeof wasmExports["_D5gizmo11__moduleRefZ"] != "undefined", "missing Wasm export: _D5gizmo11__moduleRefZ");
  assert(typeof wasmExports["_D18geometry_clipboard11__moduleRefZ"] != "undefined", "missing Wasm export: _D18geometry_clipboard11__moduleRefZ");
  assert(typeof wasmExports["_D11frame_stall11__moduleRefZ"] != "undefined", "missing Wasm export: _D11frame_stall11__moduleRefZ");
  assert(typeof wasmExports["_D12frame_runner11__moduleRefZ"] != "undefined", "missing Wasm export: _D12frame_runner11__moduleRefZ");
  assert(typeof wasmExports["_D12forms_render11__moduleRefZ"] != "undefined", "missing Wasm export: _D12forms_render11__moduleRefZ");
  assert(typeof wasmExports["_D5forms11__moduleRefZ"] != "undefined", "missing Wasm export: _D5forms11__moduleRefZ");
  assert(typeof wasmExports["_D20file_io_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D20file_io_registration11__moduleRefZ");
  assert(typeof wasmExports["_D14falloff_render11__moduleRefZ"] != "undefined", "missing Wasm export: _D14falloff_render11__moduleRefZ");
  assert(typeof wasmExports["_D15falloff_handles11__moduleRefZ"] != "undefined", "missing Wasm export: _D15falloff_handles11__moduleRefZ");
  assert(typeof wasmExports["_D7falloff11__moduleRefZ"] != "undefined", "missing Wasm export: _D7falloff11__moduleRefZ");
  assert(typeof wasmExports["_D8eventlog11__moduleRefZ"] != "undefined", "missing Wasm export: _D8eventlog11__moduleRefZ");
  assert(typeof wasmExports["_D10editor_app11__moduleRefZ"] != "undefined", "missing Wasm export: _D10editor_app11__moduleRefZ");
  assert(typeof wasmExports["_D8editmode11__moduleRefZ"] != "undefined", "missing Wasm export: _D8editmode11__moduleRefZ");
  assert(typeof wasmExports["_D22edit_tool_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D22edit_tool_registration11__moduleRefZ");
  assert(typeof wasmExports["_D12edit_session11__moduleRefZ"] != "undefined", "missing Wasm export: _D12edit_session11__moduleRefZ");
  assert(typeof wasmExports["_D13drag_identity11__moduleRefZ"] != "undefined", "missing Wasm export: _D13drag_identity11__moduleRefZ");
  assert(typeof wasmExports["_D4drag11__moduleRefZ"] != "undefined", "missing Wasm export: _D4drag11__moduleRefZ");
  assert(typeof wasmExports["_D18document_selection11__moduleRefZ"] != "undefined", "missing Wasm export: _D18document_selection11__moduleRefZ");
  assert(typeof wasmExports["_D8document11__moduleRefZ"] != "undefined", "missing Wasm export: _D8document11__moduleRefZ");
  assert(typeof wasmExports["_D12display_sync11__moduleRefZ"] != "undefined", "missing Wasm export: _D12display_sync11__moduleRefZ");
  assert(typeof wasmExports["_D13display_state11__moduleRefZ"] != "undefined", "missing Wasm export: _D13display_state11__moduleRefZ");
  assert(typeof wasmExports["_D13deform_magnet11__moduleRefZ"] != "undefined", "missing Wasm export: _D13deform_magnet11__moduleRefZ");
  assert(typeof wasmExports["_D24create_tool_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D24create_tool_registration11__moduleRefZ");
  assert(typeof wasmExports["_D13copilot_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D13copilot_panel11__moduleRefZ");
  assert(typeof wasmExports["_D15copilot_overlay11__moduleRefZ"] != "undefined", "missing Wasm export: _D15copilot_overlay11__moduleRefZ");
  assert(typeof wasmExports["_D28copilot_command_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D28copilot_command_registration11__moduleRefZ");
  assert(typeof wasmExports["_D14coord_rounding11__moduleRefZ"] != "undefined", "missing Wasm export: _D14coord_rounding11__moduleRefZ");
  assert(typeof wasmExports["_D10constraint11__moduleRefZ"] != "undefined", "missing Wasm export: _D10constraint11__moduleRefZ");
  assert(typeof wasmExports["_D8commands9workplane11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands9workplane11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport11view_preset11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport11view_preset11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport6master11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport6master11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport13layout_preset11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport13layout_preset11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport12independence11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport12independence11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport10grid_steps11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport10grid_steps11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport12fit_selected11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport12fit_selected11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport3fit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport3fit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport7display11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport7display11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8viewport12command_base11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8viewport12command_base11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui14viewport_props11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui14viewport_props11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui15tool_properties11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui15tool_properties11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui10statistics11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui10statistics11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui3pie11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui3pie11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui12layout_reset11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui12layout_reset11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui10layer_list11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui10layer_list11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui10image_list11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui10image_list11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui13copilot_panel11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui13copilot_panel11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui8channels11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui8channels11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ui5about11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ui5about11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool3set11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool3set11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool5reset11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool5reset11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool4pipe11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool4pipe11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool10panel_edit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool10panel_edit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool9lifecycle11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool9lifecycle11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool4host11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool4host11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool8headless11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool8headless11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool8do_apply11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool8do_apply11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool13begin_session11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool13begin_session11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4tool4attr11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4tool4attr11__moduleRefZ");
  assert(typeof wasmExports["_D8commands15test_undo_flags11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands15test_undo_flags11__moduleRefZ");
  assert(typeof wasmExports["_D8commands8symmetry6toggle11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands8symmetry6toggle11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4snap11toggle_type11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4snap11toggle_type11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4snap6toggle11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4snap6toggle11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4snap4mode11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4snap4mode11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select9type_from11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select9type_from11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select4sets11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select4sets11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select4ring11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select4ring11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select4more11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select4more11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select4loop11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select4loop11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select4less11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select4less11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select6invert11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select6invert11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select4fill11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select4fill11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select6expand11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select6expand11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select7element11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select7element11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select4drop11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select4drop11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select7convert11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select7convert11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select8contract11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select8contract11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select7connect11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select7connect11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select6by_tag11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select6by_tag11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select7by_stat11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select7by_stat11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select8boundary11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select8boundary11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6select7between11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6select7between11__moduleRefZ");
  assert(typeof wasmExports["_D8commands5scene5reset11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands5scene5reset11__moduleRefZ");
  assert(typeof wasmExports["_D8commands5scene9load_mesh11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands5scene9load_mesh11__moduleRefZ");
  assert(typeof wasmExports["_D8commands5prefs9trackball11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands5prefs9trackball11__moduleRefZ");
  assert(typeof wasmExports["_D8commands5prefs14coord_rounding11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands5prefs14coord_rounding11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4path6define11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4path6define11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh16weld_vertex_pair11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh16weld_vertex_pair11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9weightmap11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9weightmap11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12vertex_split11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12vertex_split11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10vertex_set11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10vertex_set11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh22vertex_position_result11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh22vertex_position_result11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10vertex_new11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10vertex_new11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh14vertex_extrude11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh14vertex_extrude11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh11vertex_edit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh11vertex_edit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh13vertex_center11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh13vertex_center11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12vertex_bevel11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12vertex_bevel11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10vert_merge11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10vert_merge11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9vert_join11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9vert_join11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9uv_unwrap11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9uv_unwrap11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12uv_transform11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12uv_transform11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh8uv_relax11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh8uv_relax11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10uv_project11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10uv_project11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh7uv_pack11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh7uv_pack11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh11uv_map_util11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh11uv_map_util11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh5unify11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh5unify11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6triple11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6triple11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9transform11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9transform11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh7thicken11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh7thicken11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10symmetrize11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10symmetrize11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh5sweep11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh5sweep11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh15subpatch_toggle11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh15subpatch_toggle11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh17subdivide_faceted11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh17subdivide_faceted11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9subdivide11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9subdivide11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh14stroke_extrude11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh14stroke_extrude11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10split_face11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10split_face11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10split_edge11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10split_edge11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9spin_edge11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9spin_edge11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6spikey11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6spikey11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12smooth_shift11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12smooth_shift11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6smooth11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6smooth11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh8set_part11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh8set_part11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12set_material11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12set_material11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12session_edit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12session_edit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh14selection_undo11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh14selection_undo11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh14selection_edit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh14selection_edit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6select11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6select11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12screen_slice11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12screen_slice11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh7remove_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh7remove_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6remesh11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6remesh11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6reduce11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6reduce11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh13radial_array_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh13radial_array_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12radial_align11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12radial_align11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh8quantize11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh8quantize11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9quadruple11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9quadruple11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh13position_undo11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh13position_undo11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh13polygon_align11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh13polygon_align11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10poly_inset11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10poly_inset11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6paste_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6paste_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh11move_vertex11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh11move_vertex11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10morph_edit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10morph_edit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh5morph11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh5morph11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh7mirror_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh7mirror_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh5merge11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh5merge11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh13map_edit_undo11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh13map_edit_undo11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12make_polygon11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12make_polygon11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6magnet11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6magnet11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10loop_slice11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10loop_slice11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12linear_align11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12linear_align11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6jitter11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6jitter11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh4hide11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh4hide11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh15gesture_payload11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh15gesture_payload11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh4flip11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh4flip11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh15fix_orientation11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh15fix_orientation11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12face_extrude11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12face_extrude11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10edge_slide11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10edge_slide11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10edge_slice11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10edge_slice11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9edge_join11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9edge_join11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh12edge_extrude11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh12edge_extrude11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh11edge_extend11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh11edge_extend11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh11edge_crease11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh11edge_crease11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10duplicate_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10duplicate_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh13detriangulate11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh13detriangulate11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh7delete_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh7delete_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh4cut_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh4cut_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh5copy_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh5copy_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh8collapse11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh8collapse11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6clone_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6clone_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh7cleanup11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh7cleanup11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6bridge11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6bridge11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh5bevel11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh5bevel11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh10axis_slice11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh10axis_slice11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh6array_11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh6array_11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4mesh9add_point11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4mesh9add_point11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6macros13save_recorded11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6macros13save_recorded11__moduleRefZ");
  assert(typeof wasmExports["_D8commands6macros6record11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands6macros6record11__moduleRefZ");
  assert(typeof wasmExports["_D8commands5layer10xform_edit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands5layer10xform_edit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands5layerQp11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands5layerQp11__moduleRefZ");
  assert(typeof wasmExports["_D8commands11image_planeQw11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands11image_planeQw11__moduleRefZ");
  assert(typeof wasmExports["_D8commands5imageQp11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands5imageQp11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7history4undo11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7history4undo11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7history4show11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7history4show11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7history14save_as_script11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7history14save_as_script11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7history4redo11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7history4redo11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7history5clear11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7history5clear11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4file4save11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4file4save11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4file4quit11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4file4quit11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4file4load11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4file4load11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7falloff11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7falloff11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7copilot14select_finding11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7copilot14select_finding11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7copilot13cycle_finding11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7copilot13cycle_finding11__moduleRefZ");
  assert(typeof wasmExports["_D8commands7copilot7analyze11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands7copilot7analyze11__moduleRefZ");
  assert(typeof wasmExports["_D8commands9constrain6toggle11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands9constrain6toggle11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4ai3d13import_result11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4ai3d13import_result11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4ai3d13generate_open11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4ai3d13generate_open11__moduleRefZ");
  assert(typeof wasmExports["_D8commands2ai6toggle11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands2ai6toggle11__moduleRefZ");
  assert(typeof wasmExports["_D8commands4actr11__moduleRefZ"] != "undefined", "missing Wasm export: _D8commands4actr11__moduleRefZ");
  assert(typeof wasmExports["_D15command_history11__moduleRefZ"] != "undefined", "missing Wasm export: _D15command_history11__moduleRefZ");
  assert(typeof wasmExports["_D16command_executor11__moduleRefZ"] != "undefined", "missing Wasm export: _D16command_executor11__moduleRefZ");
  assert(typeof wasmExports["_D12command_args11__moduleRefZ"] != "undefined", "missing Wasm export: _D12command_args11__moduleRefZ");
  assert(typeof wasmExports["_D7command11__moduleRefZ"] != "undefined", "missing Wasm export: _D7command11__moduleRefZ");
  assert(typeof wasmExports["_D10change_bus11__moduleRefZ"] != "undefined", "missing Wasm export: _D10change_bus11__moduleRefZ");
  assert(typeof wasmExports["_D12camera_stamp11__moduleRefZ"] != "undefined", "missing Wasm export: _D12camera_stamp11__moduleRefZ");
  assert(typeof wasmExports["_D8bvh_pick11__moduleRefZ"] != "undefined", "missing Wasm export: _D8bvh_pick11__moduleRefZ");
  assert(typeof wasmExports["_D9buttonset11__moduleRefZ"] != "undefined", "missing Wasm export: _D9buttonset11__moduleRefZ");
  assert(typeof wasmExports["_D12bg_gpu_cache11__moduleRefZ"] != "undefined", "missing Wasm export: _D12bg_gpu_cache11__moduleRefZ");
  assert(typeof wasmExports["_D9argstring11__moduleRefZ"] != "undefined", "missing Wasm export: _D9argstring11__moduleRefZ");
  assert(typeof wasmExports["_D11args_dialog11__moduleRefZ"] != "undefined", "missing Wasm export: _D11args_dialog11__moduleRefZ");
  assert(typeof wasmExports["_D27application_command_binding11__moduleRefZ"] != "undefined", "missing Wasm export: _D27application_command_binding11__moduleRefZ");
  assert(typeof wasmExports["_D11app_version11__moduleRefZ"] != "undefined", "missing Wasm export: _D11app_version11__moduleRefZ");
  assert(typeof wasmExports["_D3app11__moduleRefZ"] != "undefined", "missing Wasm export: _D3app11__moduleRefZ");
  assert(typeof wasmExports["_D23ai_command_registration11__moduleRefZ"] != "undefined", "missing Wasm export: _D23ai_command_registration11__moduleRefZ");
  assert(typeof wasmExports["_D4ai3d15scene_validator11__moduleRefZ"] != "undefined", "missing Wasm export: _D4ai3d15scene_validator11__moduleRefZ");
  assert(typeof wasmExports["_D4ai3d10job_events11__moduleRefZ"] != "undefined", "missing Wasm export: _D4ai3d10job_events11__moduleRefZ");
  assert(typeof wasmExports["_D4ai3d11event_queue11__moduleRefZ"] != "undefined", "missing Wasm export: _D4ai3d11event_queue11__moduleRefZ");
  assert(typeof wasmExports["_D2ai16training_dataset11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai16training_dataset11__moduleRefZ");
  assert(typeof wasmExports["_D2ai17synthetic_dataset11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai17synthetic_dataset11__moduleRefZ");
  assert(typeof wasmExports["_D2ai23support_loop_candidates11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai23support_loop_candidates11__moduleRefZ");
  assert(typeof wasmExports["_D2ai5state11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai5state11__moduleRefZ");
  assert(typeof wasmExports["_D2ai13ranker_schema11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai13ranker_schema11__moduleRefZ");
  assert(typeof wasmExports["_D2ai12onnx_backend11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai12onnx_backend11__moduleRefZ");
  assert(typeof wasmExports["_D2ai17offline_evaluator11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai17offline_evaluator11__moduleRefZ");
  assert(typeof wasmExports["_D2ai13model_adapter11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai13model_adapter11__moduleRefZ");
  assert(typeof wasmExports["_D2ai15mode_candidates11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai15mode_candidates11__moduleRefZ");
  assert(typeof wasmExports["_D2ai22interaction_log_writer11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai22interaction_log_writer11__moduleRefZ");
  assert(typeof wasmExports["_D2ai15interaction_log11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai15interaction_log11__moduleRefZ");
  assert(typeof wasmExports["_D2ai11interaction11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai11interaction11__moduleRefZ");
  assert(typeof wasmExports["_D2ai11exploration11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai11exploration11__moduleRefZ");
  assert(typeof wasmExports["_D2ai18element_candidates11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai18element_candidates11__moduleRefZ");
  assert(typeof wasmExports["_D2ai11debug_trace11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai11debug_trace11__moduleRefZ");
  assert(typeof wasmExports["_D2ai12copilot_gate11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai12copilot_gate11__moduleRefZ");
  assert(typeof wasmExports["_D2ai8analysis11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai8analysis11__moduleRefZ");
  assert(typeof wasmExports["_D2ai7advisor11__moduleRefZ"] != "undefined", "missing Wasm export: _D2ai7advisor11__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind3arb7core_3011__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind3arb7core_3011__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind3arb7core_3111__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind3arb7core_3111__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind3arb7core_3311__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind3arb7core_3311__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl1111__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl1111__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl1311__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl1311__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl1411__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl1411__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl1511__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl1511__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl2011__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl2011__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl3011__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl3011__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl3111__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl3111__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl4bind4gl3311__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl4bind4gl3311__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl7context11__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl7context11__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6opengl11__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6opengl11__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6loader7codegen11__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6loader7codegen11__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6loader9sharedlib11__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6loader9sharedlib11__moduleRefZ");
  assert(typeof wasmExports["_D3bvh1c11__moduleRefZ"] != "undefined", "missing Wasm export: _D3bvh1c11__moduleRefZ");
  assert(typeof wasmExports["_D3osd1c11__moduleRefZ"] != "undefined", "missing Wasm export: _D3osd1c11__moduleRefZ");
  assert(typeof wasmExports["_D9stb_image1c11__moduleRefZ"] != "undefined", "missing Wasm export: _D9stb_image1c11__moduleRefZ");
  assert(typeof wasmExports["_D7d_imgui12imgui_cimgui11__moduleRefZ"] != "undefined", "missing Wasm export: _D7d_imgui12imgui_cimgui11__moduleRefZ");
  assert(typeof wasmExports["_D7d_imgui7imgui_h11__moduleRefZ"] != "undefined", "missing Wasm export: _D7d_imgui7imgui_h11__moduleRefZ");
  assert(typeof wasmExports["_D7d_imgui11__moduleRefZ"] != "undefined", "missing Wasm export: _D7d_imgui11__moduleRefZ");
  assert(typeof wasmExports["_D18imgui_impl_opengl311__moduleRefZ"] != "undefined", "missing Wasm export: _D18imgui_impl_opengl311__moduleRefZ");
  assert(typeof wasmExports["_D15imgui_impl_sdl211__moduleRefZ"] != "undefined", "missing Wasm export: _D15imgui_impl_sdl211__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc3sdl6config11__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc3sdl6config11__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc3sdl11__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc3sdl11__moduleRefZ");
  assert(typeof wasmExports["_D3sdl6stdinc11__moduleRefZ"] != "undefined", "missing Wasm export: _D3sdl6stdinc11__moduleRefZ");
  assert(typeof wasmExports["_D6bindbc6common7codegen11__moduleRefZ"] != "undefined", "missing Wasm export: _D6bindbc6common7codegen11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml8composer11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml8composer11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml11constructor11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml11constructor11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml6dumper11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml6dumper11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml7emitter11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml7emitter11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml7escapes11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml7escapes11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml5event11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml5event11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml9exception11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml9exception11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml6loader11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml6loader11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml4node11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml4node11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml6parser11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml6parser11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml5queue11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml5queue11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml6reader11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml6reader11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml11representer11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml11representer11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml8resolver11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml8resolver11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml7scanner11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml7scanner11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml10serializer11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml10serializer11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml12tagdirective11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml12tagdirective11__moduleRefZ");
  assert(typeof wasmExports["_D5dyaml5token11__moduleRefZ"] != "undefined", "missing Wasm export: _D5dyaml5token11__moduleRefZ");
  assert(typeof wasmExports["_D4lwo211__moduleRefZ"] != "undefined", "missing Wasm export: _D4lwo211__moduleRefZ");
  assert(typeof wasmExports["_D4lwo26writer11__moduleRefZ"] != "undefined", "missing Wasm export: _D4lwo26writer11__moduleRefZ");
  assert(typeof wasmExports["_D3etc1c4curl11__moduleRefZ"] != "undefined", "missing Wasm export: _D3etc1c4curl11__moduleRefZ");
  assert(typeof wasmExports["_D3etc1c4zlib11__moduleRefZ"] != "undefined", "missing Wasm export: _D3etc1c4zlib11__moduleRefZ");
  assert(typeof wasmExports["_D3std9algorithm10comparison11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std9algorithm10comparison11__moduleRefZ");
  assert(typeof wasmExports["_D3std9algorithm9iteration11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std9algorithm9iteration11__moduleRefZ");
  assert(typeof wasmExports["_D3std9algorithm8mutation11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std9algorithm8mutation11__moduleRefZ");
  assert(typeof wasmExports["_D3std9algorithm9searching11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std9algorithm9searching11__moduleRefZ");
  assert(typeof wasmExports["_D3std9algorithm7sorting11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std9algorithm7sorting11__moduleRefZ");
  assert(typeof wasmExports["_D3std5array11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5array11__moduleRefZ");
  assert(typeof wasmExports["_D3std5ascii11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5ascii11__moduleRefZ");
  assert(typeof wasmExports["_D3std6base6411__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6base6411__moduleRefZ");
  assert(typeof wasmExports["_D3std8bitmanip11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8bitmanip11__moduleRefZ");
  assert(typeof wasmExports["_D3std10checkedint11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std10checkedint11__moduleRefZ");
  assert(typeof wasmExports["_D3std11concurrency11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std11concurrency11__moduleRefZ");
  assert(typeof wasmExports["_D3std4conv11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4conv11__moduleRefZ");
  assert(typeof wasmExports["_D3std8datetime4date11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8datetime4date11__moduleRefZ");
  assert(typeof wasmExports["_D3std8datetime7systime11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8datetime7systime11__moduleRefZ");
  assert(typeof wasmExports["_D3std8datetime8timezone11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8datetime8timezone11__moduleRefZ");
  assert(typeof wasmExports["_D3std6digest2md11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6digest2md11__moduleRefZ");
  assert(typeof wasmExports["_D3std6digest3sha11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6digest3sha11__moduleRefZ");
  assert(typeof wasmExports["_D3std8encoding11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8encoding11__moduleRefZ");
  assert(typeof wasmExports["_D3std9exception11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std9exception11__moduleRefZ");
  assert(typeof wasmExports["_D3std12experimental9allocator12gc_allocator11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std12experimental9allocator12gc_allocator11__moduleRefZ");
  assert(typeof wasmExports["_D3std12experimental9allocator10mallocator11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std12experimental9allocator10mallocator11__moduleRefZ");
  assert(typeof wasmExports["_D3std12experimental9allocator11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std12experimental9allocator11__moduleRefZ");
  assert(typeof wasmExports["_D3std4file11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4file11__moduleRefZ");
  assert(typeof wasmExports["_D3std6format8internal6floats11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6format8internal6floats11__moduleRefZ");
  assert(typeof wasmExports["_D3std6format8internal5write11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6format8internal5write11__moduleRefZ");
  assert(typeof wasmExports["_D3std6format11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6format11__moduleRefZ");
  assert(typeof wasmExports["_D3std6format4spec11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6format4spec11__moduleRefZ");
  assert(typeof wasmExports["_D3std6format5write11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6format5write11__moduleRefZ");
  assert(typeof wasmExports["_D3std10functional11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std10functional11__moduleRefZ");
  assert(typeof wasmExports["_D3std8internal7cstring11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8internal7cstring11__moduleRefZ");
  assert(typeof wasmExports["_D3std8internal6memory11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8internal6memory11__moduleRefZ");
  assert(typeof wasmExports["_D3std8internal12unicode_comp11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8internal12unicode_comp11__moduleRefZ");
  assert(typeof wasmExports["_D3std8internal14unicode_tables11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8internal14unicode_tables11__moduleRefZ");
  assert(typeof wasmExports["_D3std4json11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4json11__moduleRefZ");
  assert(typeof wasmExports["_D3std6logger4core11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6logger4core11__moduleRefZ");
  assert(typeof wasmExports["_D3std6logger10filelogger11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6logger10filelogger11__moduleRefZ");
  assert(typeof wasmExports["_D3std6logger11multilogger11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6logger11multilogger11__moduleRefZ");
  assert(typeof wasmExports["_D3std4math9algebraic11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4math9algebraic11__moduleRefZ");
  assert(typeof wasmExports["_D3std4math11exponential11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4math11exponential11__moduleRefZ");
  assert(typeof wasmExports["_D3std4math10operations11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4math10operations11__moduleRefZ");
  assert(typeof wasmExports["_D3std4math8rounding11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4math8rounding11__moduleRefZ");
  assert(typeof wasmExports["_D3std4math6traits11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4math6traits11__moduleRefZ");
  assert(typeof wasmExports["_D3std4math12trigonometry11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4math12trigonometry11__moduleRefZ");
  assert(typeof wasmExports["_D3std4meta11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4meta11__moduleRefZ");
  assert(typeof wasmExports["_D3std11parallelism11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std11parallelism11__moduleRefZ");
  assert(typeof wasmExports["_D3std4path11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4path11__moduleRefZ");
  assert(typeof wasmExports["_D3std7process11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std7process11__moduleRefZ");
  assert(typeof wasmExports["_D3std6random11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6random11__moduleRefZ");
  assert(typeof wasmExports["_D3std5range11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5range11__moduleRefZ");
  assert(typeof wasmExports["_D3std5range10primitives11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5range10primitives11__moduleRefZ");
  assert(typeof wasmExports["_D3std5regex8internal12backtracking11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5regex8internal12backtracking11__moduleRefZ");
  assert(typeof wasmExports["_D3std5regex8internal2ir11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5regex8internal2ir11__moduleRefZ");
  assert(typeof wasmExports["_D3std5regex8internal6parser11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5regex8internal6parser11__moduleRefZ");
  assert(typeof wasmExports["_D3std5stdio11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std5stdio11__moduleRefZ");
  assert(typeof wasmExports["_D3std6string11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6string11__moduleRefZ");
  assert(typeof wasmExports["_D3std7sumtype11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std7sumtype11__moduleRefZ");
  assert(typeof wasmExports["_D3std6traits11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std6traits11__moduleRefZ");
  assert(typeof wasmExports["_D3std8typecons11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std8typecons11__moduleRefZ");
  assert(typeof wasmExports["_D3std3uni11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std3uni11__moduleRefZ");
  assert(typeof wasmExports["_D3std3utf11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std3utf11__moduleRefZ");
  assert(typeof wasmExports["_D3std4uuid11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4uuid11__moduleRefZ");
  assert(typeof wasmExports["_D3std7variant11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std7variant11__moduleRefZ");
  assert(typeof wasmExports["_D3std3zip11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std3zip11__moduleRefZ");
  assert(typeof wasmExports["_D3std4zlib11__moduleRefZ"] != "undefined", "missing Wasm export: _D3std4zlib11__moduleRefZ");
  assert(typeof wasmExports["_D4core5bitop11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core5bitop11__moduleRefZ");
  assert(typeof wasmExports["_D4core10checkedint11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core10checkedint11__moduleRefZ");
  assert(typeof wasmExports["_D4core5cpuid11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core5cpuid11__moduleRefZ");
  assert(typeof wasmExports["_D4core8demangle11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8demangle11__moduleRefZ");
  assert(typeof wasmExports["_D4core9exception11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core9exception11__moduleRefZ");
  assert(typeof wasmExports["_D4core2gc6config11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core2gc6config11__moduleRefZ");
  assert(typeof wasmExports["_D4core2gc11gcinterface11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core2gc11gcinterface11__moduleRefZ");
  assert(typeof wasmExports["_D4core2gc8registry11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core2gc8registry11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5abort11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5abort11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array9appending11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array9appending11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array8capacity11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array8capacity11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array7casting11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array7casting11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array13concatenation11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array13concatenation11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array12construction11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array12construction11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array11duplication11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array11duplication11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array8equality11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array8equality11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5array5utils11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5array5utils11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5cast_11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5cast_11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal9container5array11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal9container5array11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal9container6common11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal9container6common11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal9container7hashtab11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal9container7hashtab11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal9container5treap11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal9container5treap11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal7convert11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal7convert11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal11destruction11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal11destruction11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc4bits11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc4bits11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc8blkcache11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc8blkcache11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc9blockmeta11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc9blockmeta11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc4impl12conservativeQw11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc4impl12conservativeQw11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc4impl6manualQp11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc4impl6manualQp11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc4impl5protoQo11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc4impl5protoQo11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc2os11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc2os11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc9pooltable11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc9pooltable11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal2gc5proxy11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal2gc5proxy11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal4hash11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal4hash11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal8lifetime11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal8lifetime11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal5newaa11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal5newaa11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal12parseoptions11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal12parseoptions11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal8spinlock11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal8spinlock11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal6string11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal6string11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal7switch_11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal7switch_11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal3utf11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal3utf11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal4util5array11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal4util5array11__moduleRefZ");
  assert(typeof wasmExports["_D4core8internal4util4math11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8internal4util4math11__moduleRefZ");
  assert(typeof wasmExports["_D4core8lifetime11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core8lifetime11__moduleRefZ");
  assert(typeof wasmExports["_D4core4math11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core4math11__moduleRefZ");
  assert(typeof wasmExports["_D4core6memory11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core6memory11__moduleRefZ");
  assert(typeof wasmExports["_D4core7runtime11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core7runtime11__moduleRefZ");
  assert(typeof wasmExports["_D4core4sync9condition11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core4sync9condition11__moduleRefZ");
  assert(typeof wasmExports["_D4core4sync6config11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core4sync6config11__moduleRefZ");
  assert(typeof wasmExports["_D4core4sync9exception11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core4sync9exception11__moduleRefZ");
  assert(typeof wasmExports["_D4core4sync5mutex11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core4sync5mutex11__moduleRefZ");
  assert(typeof wasmExports["_D4core6thread7context11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core6thread7context11__moduleRefZ");
  assert(typeof wasmExports["_D4core6thread8osthread11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core6thread8osthread11__moduleRefZ");
  assert(typeof wasmExports["_D4core6thread11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core6thread11__moduleRefZ");
  assert(typeof wasmExports["_D4core6thread10threadbase11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core6thread10threadbase11__moduleRefZ");
  assert(typeof wasmExports["_D4core6thread11threadgroup11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core6thread11threadgroup11__moduleRefZ");
  assert(typeof wasmExports["_D4core6thread5types11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core6thread5types11__moduleRefZ");
  assert(typeof wasmExports["_D4core4time11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core4time11__moduleRefZ");
  assert(typeof wasmExports["_D6object11__moduleRefZ"] != "undefined", "missing Wasm export: _D6object11__moduleRefZ");
  assert(typeof wasmExports["_D2rt6aApply11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt6aApply11__moduleRefZ");
  assert(typeof wasmExports["_D2rt7aApplyR11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt7aApplyR11__moduleRefZ");
  assert(typeof wasmExports["_D2rt8arraycat11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt8arraycat11__moduleRefZ");
  assert(typeof wasmExports["rt_options"] != "undefined", "missing Wasm export: rt_options");
  assert(typeof wasmExports["rt_envvars_enabled"] != "undefined", "missing Wasm export: rt_envvars_enabled");
  assert(typeof wasmExports["rt_cmdline_enabled"] != "undefined", "missing Wasm export: rt_cmdline_enabled");
  assert(typeof wasmExports["_D2rt6config11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt6config11__moduleRefZ");
  assert(typeof wasmExports["_D2rt9critical_11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt9critical_11__moduleRefZ");
  assert(typeof wasmExports["_D2rt3deh11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt3deh11__moduleRefZ");
  assert(typeof wasmExports["_D2rt15deh_win64_posix11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt15deh_win64_posix11__moduleRefZ");
  assert(typeof wasmExports["_D2rt6dmain211__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt6dmain211__moduleRefZ");
  assert(typeof wasmExports["_D2rt7dwarfeh11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt7dwarfeh11__moduleRefZ");
  assert(typeof wasmExports["_D2rt7ehalloc11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt7ehalloc11__moduleRefZ");
  assert(typeof wasmExports["_D2rt8lifetime11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt8lifetime11__moduleRefZ");
  assert(typeof wasmExports["_D2rt6memory11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt6memory11__moduleRefZ");
  assert(typeof wasmExports["_D2rt5minfo11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt5minfo11__moduleRefZ");
  assert(typeof wasmExports["_D2rt8monitor_11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt8monitor_11__moduleRefZ");
  assert(typeof wasmExports["_D2rt13sections_wasm11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt13sections_wasm11__moduleRefZ");
  assert(typeof wasmExports["_D2rt5tlsgc11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt5tlsgc11__moduleRefZ");
  assert(typeof wasmExports["_D2rt4util8typeinfo11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt4util8typeinfo11__moduleRefZ");
  assert(typeof wasmExports["_D2rt4util7utility11__moduleRefZ"] != "undefined", "missing Wasm export: _D2rt4util7utility11__moduleRefZ");
  assert(typeof wasmExports["_D4core3sys5posix7pthread11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core3sys5posix7pthread11__moduleRefZ");
  assert(typeof wasmExports["_D4core3sys5posixQk4stat11__moduleRefZ"] != "undefined", "missing Wasm export: _D4core3sys5posixQk4stat11__moduleRefZ");
  _free = createExportWrapper("free", wasmExports["free"], 1);
  _malloc = createExportWrapper("malloc", wasmExports["malloc"], 1);
  _main = Module["_main"] = createExportWrapper("__main_argc_argv", wasmExports["__main_argc_argv"], 2);
  _fflush = createExportWrapper("fflush", wasmExports["fflush"], 1);
  _strerror = createExportWrapper("strerror", wasmExports["strerror"], 1);
  _emscripten_stack_get_end = wasmExports["emscripten_stack_get_end"];
  _emscripten_stack_get_base = wasmExports["emscripten_stack_get_base"];
  _emscripten_stack_init = wasmExports["emscripten_stack_init"];
  _emscripten_stack_get_free = wasmExports["emscripten_stack_get_free"];
  __emscripten_stack_restore = wasmExports["_emscripten_stack_restore"];
  __emscripten_stack_alloc = wasmExports["_emscripten_stack_alloc"];
  _emscripten_stack_get_current = wasmExports["emscripten_stack_get_current"];
  memory = wasmMemory = wasmExports["memory"];
  __indirect_function_table = wasmTable = wasmExports["__indirect_function_table"];
  __D14weightmap_view11__moduleRefZ = Module["__D14weightmap_view11__moduleRefZ"] = (wasmExports["_D14weightmap_view11__moduleRefZ"].value) >>> 0;
  __D13web_gl_loader11__moduleRefZ = Module["__D13web_gl_loader11__moduleRefZ"] = (wasmExports["_D13web_gl_loader11__moduleRefZ"].value) >>> 0;
  __D15viewport_scheme11__moduleRefZ = Module["__D15viewport_scheme11__moduleRefZ"] = (wasmExports["_D15viewport_scheme11__moduleRefZ"].value) >>> 0;
  __D21viewport_overlay_mode11__moduleRefZ = Module["__D21viewport_overlay_mode11__moduleRefZ"] = (wasmExports["_D21viewport_overlay_mode11__moduleRefZ"].value) >>> 0;
  __D29viewport_command_registration11__moduleRefZ = Module["__D29viewport_command_registration11__moduleRefZ"] = (wasmExports["_D29viewport_command_registration11__moduleRefZ"].value) >>> 0;
  __D8viewport11__moduleRefZ = Module["__D8viewport11__moduleRefZ"] = (wasmExports["_D8viewport11__moduleRefZ"].value) >>> 0;
  __D8viewgrid11__moduleRefZ = Module["__D8viewgrid11__moduleRefZ"] = (wasmExports["_D8viewgrid11__moduleRefZ"].value) >>> 0;
  __D26view_settings_registration11__moduleRefZ = Module["__D26view_settings_registration11__moduleRefZ"] = (wasmExports["_D26view_settings_registration11__moduleRefZ"].value) >>> 0;
  __D4view11__moduleRefZ = Module["__D4view11__moduleRefZ"] = (wasmExports["_D4view11__moduleRefZ"].value) >>> 0;
  __D7uv_weld11__moduleRefZ = Module["__D7uv_weld11__moduleRefZ"] = (wasmExports["_D7uv_weld11__moduleRefZ"].value) >>> 0;
  __D9uv_unwrap11__moduleRefZ = Module["__D9uv_unwrap11__moduleRefZ"] = (wasmExports["_D9uv_unwrap11__moduleRefZ"].value) >>> 0;
  __D12uv_transform11__moduleRefZ = Module["__D12uv_transform11__moduleRefZ"] = (wasmExports["_D12uv_transform11__moduleRefZ"].value) >>> 0;
  __D8uv_relax11__moduleRefZ = Module["__D8uv_relax11__moduleRefZ"] = (wasmExports["_D8uv_relax11__moduleRefZ"].value) >>> 0;
  __D10uv_project11__moduleRefZ = Module["__D10uv_project11__moduleRefZ"] = (wasmExports["_D10uv_project11__moduleRefZ"].value) >>> 0;
  __D9uv_island11__moduleRefZ = Module["__D9uv_island11__moduleRefZ"] = (wasmExports["_D9uv_island11__moduleRefZ"].value) >>> 0;
  __D2ui15viewport_render11__moduleRefZ = Module["__D2ui15viewport_render11__moduleRefZ"] = (wasmExports["_D2ui15viewport_render11__moduleRefZ"].value) >>> 0;
  __D2ui19viewport_props_role11__moduleRefZ = Module["__D2ui19viewport_props_role11__moduleRefZ"] = (wasmExports["_D2ui19viewport_props_role11__moduleRefZ"].value) >>> 0;
  __D2ui21tool_properties_panel11__moduleRefZ = Module["__D2ui21tool_properties_panel11__moduleRefZ"] = (wasmExports["_D2ui21tool_properties_panel11__moduleRefZ"].value) >>> 0;
  __D2ui9stat_rows11__moduleRefZ = Module["__D2ui9stat_rows11__moduleRefZ"] = (wasmExports["_D2ui9stat_rows11__moduleRefZ"].value) >>> 0;
  __D2ui11stat_record11__moduleRefZ = Module["__D2ui11stat_record11__moduleRefZ"] = (wasmExports["_D2ui11stat_record11__moduleRefZ"].value) >>> 0;
  __D2ui13retained_item11__moduleRefZ = Module["__D2ui13retained_item11__moduleRefZ"] = (wasmExports["_D2ui13retained_item11__moduleRefZ"].value) >>> 0;
  __D2ui18remesh_modal_state11__moduleRefZ = Module["__D2ui18remesh_modal_state11__moduleRefZ"] = (wasmExports["_D2ui18remesh_modal_state11__moduleRefZ"].value) >>> 0;
  __D2ui10pie_render11__moduleRefZ = Module["__D2ui10pie_render11__moduleRefZ"] = (wasmExports["_D2ui10pie_render11__moduleRefZ"].value) >>> 0;
  __D2ui10pie_record11__moduleRefZ = Module["__D2ui10pie_record11__moduleRefZ"] = (wasmExports["_D2ui10pie_record11__moduleRefZ"].value) >>> 0;
  __D2ui6panels11__moduleRefZ = Module["__D2ui6panels11__moduleRefZ"] = (wasmExports["_D2ui6panels11__moduleRefZ"].value) >>> 0;
  __D2ui12panel_chrome11__moduleRefZ = Module["__D2ui12panel_chrome11__moduleRefZ"] = (wasmExports["_D2ui12panel_chrome11__moduleRefZ"].value) >>> 0;
  __D2ui10mode_popup11__moduleRefZ = Module["__D2ui10mode_popup11__moduleRefZ"] = (wasmExports["_D2ui10mode_popup11__moduleRefZ"].value) >>> 0;
  __D2ui16layer_list_panel11__moduleRefZ = Module["__D2ui16layer_list_panel11__moduleRefZ"] = (wasmExports["_D2ui16layer_list_panel11__moduleRefZ"].value) >>> 0;
  __D2ui9item_rows11__moduleRefZ = Module["__D2ui9item_rows11__moduleRefZ"] = (wasmExports["_D2ui9item_rows11__moduleRefZ"].value) >>> 0;
  __D2ui11item_rename11__moduleRefZ = Module["__D2ui11item_rename11__moduleRefZ"] = (wasmExports["_D2ui11item_rename11__moduleRefZ"].value) >>> 0;
  __D2ui11item_glyphs11__moduleRefZ = Module["__D2ui11item_glyphs11__moduleRefZ"] = (wasmExports["_D2ui11item_glyphs11__moduleRefZ"].value) >>> 0;
  __D2ui18imgui_window_class11__moduleRefZ = Module["__D2ui18imgui_window_class11__moduleRefZ"] = (wasmExports["_D2ui18imgui_window_class11__moduleRefZ"].value) >>> 0;
  __D2ui10image_rows11__moduleRefZ = Module["__D2ui10image_rows11__moduleRefZ"] = (wasmExports["_D2ui10image_rows11__moduleRefZ"].value) >>> 0;
  __D2ui16image_list_panel11__moduleRefZ = Module["__D2ui16image_list_panel11__moduleRefZ"] = (wasmExports["_D2ui16image_list_panel11__moduleRefZ"].value) >>> 0;
  __D2ui13history_panel11__moduleRefZ = Module["__D2ui13history_panel11__moduleRefZ"] = (wasmExports["_D2ui13history_panel11__moduleRefZ"].value) >>> 0;
  __D2ui17guard_modal_state11__moduleRefZ = Module["__D2ui17guard_modal_state11__moduleRefZ"] = (wasmExports["_D2ui17guard_modal_state11__moduleRefZ"].value) >>> 0;
  __D2ui9dock_drag11__moduleRefZ = Module["__D2ui9dock_drag11__moduleRefZ"] = (wasmExports["_D2ui9dock_drag11__moduleRefZ"].value) >>> 0;
  __D2ui13discard_guard11__moduleRefZ = Module["__D2ui13discard_guard11__moduleRefZ"] = (wasmExports["_D2ui13discard_guard11__moduleRefZ"].value) >>> 0;
  __D2ui14command_notice11__moduleRefZ = Module["__D2ui14command_notice11__moduleRefZ"] = (wasmExports["_D2ui14command_notice11__moduleRefZ"].value) >>> 0;
  __D2ui14channels_panel11__moduleRefZ = Module["__D2ui14channels_panel11__moduleRefZ"] = (wasmExports["_D2ui14channels_panel11__moduleRefZ"].value) >>> 0;
  __D2ui12channel_rows11__moduleRefZ = Module["__D2ui12channel_rows11__moduleRefZ"] = (wasmExports["_D2ui12channel_rows11__moduleRefZ"].value) >>> 0;
  __D2ui11button_face11__moduleRefZ = Module["__D2ui11button_face11__moduleRefZ"] = (wasmExports["_D2ui11button_face11__moduleRefZ"].value) >>> 0;
  __D2ui12availability11__moduleRefZ = Module["__D2ui12availability11__moduleRefZ"] = (wasmExports["_D2ui12availability11__moduleRefZ"].value) >>> 0;
  __D2ui11action_menu11__moduleRefZ = Module["__D2ui11action_menu11__moduleRefZ"] = (wasmExports["_D2ui11action_menu11__moduleRefZ"].value) >>> 0;
  __D12tsan_preinit11__moduleRefZ = Module["__D12tsan_preinit11__moduleRefZ"] = (wasmExports["_D12tsan_preinit11__moduleRefZ"].value) >>> 0;
  __D13tsan_annotate11__moduleRefZ = Module["__D13tsan_annotate11__moduleRefZ"] = (wasmExports["_D13tsan_annotate11__moduleRefZ"].value) >>> 0;
  __D27transform_tool_registration11__moduleRefZ = Module["__D27transform_tool_registration11__moduleRefZ"] = (wasmExports["_D27transform_tool_registration11__moduleRefZ"].value) >>> 0;
  __D9trackball11__moduleRefZ = Module["__D9trackball11__moduleRefZ"] = (wasmExports["_D9trackball11__moduleRefZ"].value) >>> 0;
  __D5tools9transform14xfrm_transform11__moduleRefZ = Module["__D5tools9transform14xfrm_transform11__moduleRefZ"] = (wasmExports["_D5tools9transform14xfrm_transform11__moduleRefZ"].value) >>> 0;
  __D5tools9transform9xfrm_item11__moduleRefZ = Module["__D5tools9transform9xfrm_item11__moduleRefZ"] = (wasmExports["_D5tools9transform9xfrm_item11__moduleRefZ"].value) >>> 0;
  __D5tools9transform12xfrm_handles11__moduleRefZ = Module["__D5tools9transform12xfrm_handles11__moduleRefZ"] = (wasmExports["_D5tools9transform12xfrm_handles11__moduleRefZ"].value) >>> 0;
  __D5tools9transform10xfrm_apply11__moduleRefZ = Module["__D5tools9transform10xfrm_apply11__moduleRefZ"] = (wasmExports["_D5tools9transform10xfrm_apply11__moduleRefZ"].value) >>> 0;
  __D5tools9transform13xform_kernels11__moduleRefZ = Module["__D5tools9transform13xform_kernels11__moduleRefZ"] = (wasmExports["_D5tools9transform13xform_kernels11__moduleRefZ"].value) >>> 0;
  __D5tools9transformQk11__moduleRefZ = Module["__D5tools9transformQk11__moduleRefZ"] = (wasmExports["_D5tools9transformQk11__moduleRefZ"].value) >>> 0;
  __D5tools9transform5scale11__moduleRefZ = Module["__D5tools9transform5scale11__moduleRefZ"] = (wasmExports["_D5tools9transform5scale11__moduleRefZ"].value) >>> 0;
  __D5tools9transform6rotate11__moduleRefZ = Module["__D5tools9transform6rotate11__moduleRefZ"] = (wasmExports["_D5tools9transform6rotate11__moduleRefZ"].value) >>> 0;
  __D5tools9transform19relocate_plane_test11__moduleRefZ = Module["__D5tools9transform19relocate_plane_test11__moduleRefZ"] = (wasmExports["_D5tools9transform19relocate_plane_test11__moduleRefZ"].value) >>> 0;
  __D5tools9transform14relocate_plane11__moduleRefZ = Module["__D5tools9transform14relocate_plane11__moduleRefZ"] = (wasmExports["_D5tools9transform14relocate_plane11__moduleRefZ"].value) >>> 0;
  __D5tools9transform4move11__moduleRefZ = Module["__D5tools9transform4move11__moduleRefZ"] = (wasmExports["_D5tools9transform4move11__moduleRefZ"].value) >>> 0;
  __D5tools9transform11morph_route11__moduleRefZ = Module["__D5tools9transform11morph_route11__moduleRefZ"] = (wasmExports["_D5tools9transform11morph_route11__moduleRefZ"].value) >>> 0;
  __D5tools9transform18item_xform_kernels11__moduleRefZ = Module["__D5tools9transform18item_xform_kernels11__moduleRefZ"] = (wasmExports["_D5tools9transform18item_xform_kernels11__moduleRefZ"].value) >>> 0;
  __D5tools9transform7arcball11__moduleRefZ = Module["__D5tools9transform7arcball11__moduleRefZ"] = (wasmExports["_D5tools9transform7arcball11__moduleRefZ"].value) >>> 0;
  __D5tools5slice10slice_tool11__moduleRefZ = Module["__D5tools5slice10slice_tool11__moduleRefZ"] = (wasmExports["_D5tools5slice10slice_tool11__moduleRefZ"].value) >>> 0;
  __D5tools5slice15loop_slice_tool11__moduleRefZ = Module["__D5tools5slice15loop_slice_tool11__moduleRefZ"] = (wasmExports["_D5tools5slice15loop_slice_tool11__moduleRefZ"].value) >>> 0;
  __D5tools5slice10edge_slide11__moduleRefZ = Module["__D5tools5slice10edge_slide11__moduleRefZ"] = (wasmExports["_D5tools5slice10edge_slide11__moduleRefZ"].value) >>> 0;
  __D5tools5slice15edge_slice_tool11__moduleRefZ = Module["__D5tools5slice15edge_slice_tool11__moduleRefZ"] = (wasmExports["_D5tools5slice15edge_slice_tool11__moduleRefZ"].value) >>> 0;
  __D5tools4edit19vertex_extrude_tool11__moduleRefZ = Module["__D5tools4edit19vertex_extrude_tool11__moduleRefZ"] = (wasmExports["_D5tools4edit19vertex_extrude_tool11__moduleRefZ"].value) >>> 0;
  __D5tools4edit17vertex_bevel_tool11__moduleRefZ = Module["__D5tools4edit17vertex_bevel_tool11__moduleRefZ"] = (wasmExports["_D5tools4edit17vertex_bevel_tool11__moduleRefZ"].value) >>> 0;
  __D5tools4edit15vert_merge_tool11__moduleRefZ = Module["__D5tools4edit15vert_merge_tool11__moduleRefZ"] = (wasmExports["_D5tools4edit15vert_merge_tool11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12topology_pen4tool11__moduleRefZ = Module["__D5tools4edit12topology_pen4tool11__moduleRefZ"] = (wasmExports["_D5tools4edit12topology_pen4tool11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12topology_pen10snap_guide11__moduleRefZ = Module["__D5tools4edit12topology_pen10snap_guide11__moduleRefZ"] = (wasmExports["_D5tools4edit12topology_pen10snap_guide11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12topology_pen6render11__moduleRefZ = Module["__D5tools4edit12topology_pen6render11__moduleRefZ"] = (wasmExports["_D5tools4edit12topology_pen6render11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12topology_pen11__moduleRefZ = Module["__D5tools4edit12topology_pen11__moduleRefZ"] = (wasmExports["_D5tools4edit12topology_pen11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12topology_pen4json11__moduleRefZ = Module["__D5tools4edit12topology_pen4json11__moduleRefZ"] = (wasmExports["_D5tools4edit12topology_pen4json11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12topology_pen4defs11__moduleRefZ = Module["__D5tools4edit12topology_pen4defs11__moduleRefZ"] = (wasmExports["_D5tools4edit12topology_pen4defs11__moduleRefZ"].value) >>> 0;
  __D5tools4edit4tack11__moduleRefZ = Module["__D5tools4edit4tack11__moduleRefZ"] = (wasmExports["_D5tools4edit4tack11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12smooth_relax11__moduleRefZ = Module["__D5tools4edit12smooth_relax11__moduleRefZ"] = (wasmExports["_D5tools4edit12smooth_relax11__moduleRefZ"].value) >>> 0;
  __D5tools4edit6reduce11__moduleRefZ = Module["__D5tools4edit6reduce11__moduleRefZ"] = (wasmExports["_D5tools4edit6reduce11__moduleRefZ"].value) >>> 0;
  __D5tools4edit15preview_rebuild11__moduleRefZ = Module["__D5tools4edit15preview_rebuild11__moduleRefZ"] = (wasmExports["_D5tools4edit15preview_rebuild11__moduleRefZ"].value) >>> 0;
  __D5tools4edit15poly_inset_tool11__moduleRefZ = Module["__D5tools4edit15poly_inset_tool11__moduleRefZ"] = (wasmExports["_D5tools4edit15poly_inset_tool11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12poly_extrude11__moduleRefZ = Module["__D5tools4edit12poly_extrude11__moduleRefZ"] = (wasmExports["_D5tools4edit12poly_extrude11__moduleRefZ"].value) >>> 0;
  __D5tools4edit10poly_bevel11__moduleRefZ = Module["__D5tools4edit10poly_bevel11__moduleRefZ"] = (wasmExports["_D5tools4edit10poly_bevel11__moduleRefZ"].value) >>> 0;
  __D5tools4edit12edge_extrude11__moduleRefZ = Module["__D5tools4edit12edge_extrude11__moduleRefZ"] = (wasmExports["_D5tools4edit12edge_extrude11__moduleRefZ"].value) >>> 0;
  __D5tools4edit11edge_extend11__moduleRefZ = Module["__D5tools4edit11edge_extend11__moduleRefZ"] = (wasmExports["_D5tools4edit11edge_extend11__moduleRefZ"].value) >>> 0;
  __D5tools4edit10edge_bevel11__moduleRefZ = Module["__D5tools4edit10edge_bevel11__moduleRefZ"] = (wasmExports["_D5tools4edit10edge_bevel11__moduleRefZ"].value) >>> 0;
  __D5tools4edit9drag_weld11__moduleRefZ = Module["__D5tools4edit9drag_weld11__moduleRefZ"] = (wasmExports["_D5tools4edit9drag_weld11__moduleRefZ"].value) >>> 0;
  __D5tools4edit11bridge_tool11__moduleRefZ = Module["__D5tools4edit11bridge_tool11__moduleRefZ"] = (wasmExports["_D5tools4edit11bridge_tool11__moduleRefZ"].value) >>> 0;
  __D5tools6deform19stroke_extrude_tool11__moduleRefZ = Module["__D5tools6deform19stroke_extrude_tool11__moduleRefZ"] = (wasmExports["_D5tools6deform19stroke_extrude_tool11__moduleRefZ"].value) >>> 0;
  __D5tools6deform17smooth_shift_tool11__moduleRefZ = Module["__D5tools6deform17smooth_shift_tool11__moduleRefZ"] = (wasmExports["_D5tools6deform17smooth_shift_tool11__moduleRefZ"].value) >>> 0;
  __D5tools6deform4push11__moduleRefZ = Module["__D5tools6deform4push11__moduleRefZ"] = (wasmExports["_D5tools6deform4push11__moduleRefZ"].value) >>> 0;
  __D5tools6deform6magnet11__moduleRefZ = Module["__D5tools6deform6magnet11__moduleRefZ"] = (wasmExports["_D5tools6deform6magnet11__moduleRefZ"].value) >>> 0;
  __D5tools6deform4bend11__moduleRefZ = Module["__D5tools6deform4bend11__moduleRefZ"] = (wasmExports["_D5tools6deform4bend11__moduleRefZ"].value) >>> 0;
  __D5tools6create12vertex_place11__moduleRefZ = Module["__D5tools6create12vertex_place11__moduleRefZ"] = (wasmExports["_D5tools6create12vertex_place11__moduleRefZ"].value) >>> 0;
  __D5tools6create4tube11__moduleRefZ = Module["__D5tools6create4tube11__moduleRefZ"] = (wasmExports["_D5tools6create4tube11__moduleRefZ"].value) >>> 0;
  __D5tools6create5torus11__moduleRefZ = Module["__D5tools6create5torus11__moduleRefZ"] = (wasmExports["_D5tools6create5torus11__moduleRefZ"].value) >>> 0;
  __D5tools6create6sphere11__moduleRefZ = Module["__D5tools6create6sphere11__moduleRefZ"] = (wasmExports["_D5tools6create6sphere11__moduleRefZ"].value) >>> 0;
  __D5tools6create21primitive_create_tool11__moduleRefZ = Module["__D5tools6create21primitive_create_tool11__moduleRefZ"] = (wasmExports["_D5tools6create21primitive_create_tool11__moduleRefZ"].value) >>> 0;
  __D5tools6create3pen11__moduleRefZ = Module["__D5tools6create3pen11__moduleRefZ"] = (wasmExports["_D5tools6create3pen11__moduleRefZ"].value) >>> 0;
  __D5tools6create8cylinder11__moduleRefZ = Module["__D5tools6create8cylinder11__moduleRefZ"] = (wasmExports["_D5tools6create8cylinder11__moduleRefZ"].value) >>> 0;
  __D5tools6create13create_common11__moduleRefZ = Module["__D5tools6create13create_common11__moduleRefZ"] = (wasmExports["_D5tools6create13create_common11__moduleRefZ"].value) >>> 0;
  __D5tools6create4cone11__moduleRefZ = Module["__D5tools6create4cone11__moduleRefZ"] = (wasmExports["_D5tools6create4cone11__moduleRefZ"].value) >>> 0;
  __D5tools6create7capsule11__moduleRefZ = Module["__D5tools6create7capsule11__moduleRefZ"] = (wasmExports["_D5tools6create7capsule11__moduleRefZ"].value) >>> 0;
  __D5tools6create3box11__moduleRefZ = Module["__D5tools6create3box11__moduleRefZ"] = (wasmExports["_D5tools6create3box11__moduleRefZ"].value) >>> 0;
  __D5tools6create3arc11__moduleRefZ = Module["__D5tools6create3arc11__moduleRefZ"] = (wasmExports["_D5tools6create3arc11__moduleRefZ"].value) >>> 0;
  __D5tools6common16session_mesh_key11__moduleRefZ = Module["__D5tools6common16session_mesh_key11__moduleRefZ"] = (wasmExports["_D5tools6common16session_mesh_key11__moduleRefZ"].value) >>> 0;
  __D5tools6common15command_wrapper11__moduleRefZ = Module["__D5tools6common15command_wrapper11__moduleRefZ"] = (wasmExports["_D5tools6common15command_wrapper11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment17radial_sweep_tool11__moduleRefZ = Module["__D5tools9alignment17radial_sweep_tool11__moduleRefZ"] = (wasmExports["_D5tools9alignment17radial_sweep_tool11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment17radial_array_tool11__moduleRefZ = Module["__D5tools9alignment17radial_array_tool11__moduleRefZ"] = (wasmExports["_D5tools9alignment17radial_array_tool11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment17radial_align_tool11__moduleRefZ = Module["__D5tools9alignment17radial_align_tool11__moduleRefZ"] = (wasmExports["_D5tools9alignment17radial_align_tool11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment6mirror11__moduleRefZ = Module["__D5tools9alignment6mirror11__moduleRefZ"] = (wasmExports["_D5tools9alignment6mirror11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment17linear_align_tool11__moduleRefZ = Module["__D5tools9alignment17linear_align_tool11__moduleRefZ"] = (wasmExports["_D5tools9alignment17linear_align_tool11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment10clone_tool11__moduleRefZ = Module["__D5tools9alignment10clone_tool11__moduleRefZ"] = (wasmExports["_D5tools9alignment10clone_tool11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment10array_tool11__moduleRefZ = Module["__D5tools9alignment10array_tool11__moduleRefZ"] = (wasmExports["_D5tools9alignment10array_tool11__moduleRefZ"].value) >>> 0;
  __D5tools9alignment13align_kernels11__moduleRefZ = Module["__D5tools9alignment13align_kernels11__moduleRefZ"] = (wasmExports["_D5tools9alignment13align_kernels11__moduleRefZ"].value) >>> 0;
  __D8toolpipe7subject11__moduleRefZ = Module["__D8toolpipe7subject11__moduleRefZ"] = (wasmExports["_D8toolpipe7subject11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages9workplane11__moduleRefZ = Module["__D8toolpipe6stages9workplane11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages9workplane11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages8symmetry11__moduleRefZ = Module["__D8toolpipe6stages8symmetry11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages8symmetry11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages4snap11__moduleRefZ = Module["__D8toolpipe6stages4snap11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages4snap11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages4path11__moduleRefZ = Module["__D8toolpipe6stages4path11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages4path11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages7falloff11__moduleRefZ = Module["__D8toolpipe6stages7falloff11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages7falloff11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages9constrain11__moduleRefZ = Module["__D8toolpipe6stages9constrain11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages9constrain11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages4axis11__moduleRefZ = Module["__D8toolpipe6stages4axis11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages4axis11__moduleRefZ"].value) >>> 0;
  __D8toolpipe6stages9actcenter11__moduleRefZ = Module["__D8toolpipe6stages9actcenter11__moduleRefZ"] = (wasmExports["_D8toolpipe6stages9actcenter11__moduleRefZ"].value) >>> 0;
  __D8toolpipe5stage11__moduleRefZ = Module["__D8toolpipe5stage11__moduleRefZ"] = (wasmExports["_D8toolpipe5stage11__moduleRefZ"].value) >>> 0;
  __D8toolpipe8pipeline11__moduleRefZ = Module["__D8toolpipe8pipeline11__moduleRefZ"] = (wasmExports["_D8toolpipe8pipeline11__moduleRefZ"].value) >>> 0;
  __D8toolpipe7packets11__moduleRefZ = Module["__D8toolpipe7packets11__moduleRefZ"] = (wasmExports["_D8toolpipe7packets11__moduleRefZ"].value) >>> 0;
  __D8toolpipe11__moduleRefZ = Module["__D8toolpipe11__moduleRefZ"] = (wasmExports["_D8toolpipe11__moduleRefZ"].value) >>> 0;
  __D8toolpipe5obbox11__moduleRefZ = Module["__D8toolpipe5obbox11__moduleRefZ"] = (wasmExports["_D8toolpipe5obbox11__moduleRefZ"].value) >>> 0;
  __D8toolpipe5guide11__moduleRefZ = Module["__D8toolpipe5guide11__moduleRefZ"] = (wasmExports["_D8toolpipe5guide11__moduleRefZ"].value) >>> 0;
  __D12tool_presets11__moduleRefZ = Module["__D12tool_presets11__moduleRefZ"] = (wasmExports["_D12tool_presets11__moduleRefZ"].value) >>> 0;
  __D27tool_lifecycle_registration11__moduleRefZ = Module["__D27tool_lifecycle_registration11__moduleRefZ"] = (wasmExports["_D27tool_lifecycle_registration11__moduleRefZ"].value) >>> 0;
  __D10tool_input11__moduleRefZ = Module["__D10tool_input11__moduleRefZ"] = (wasmExports["_D10tool_input11__moduleRefZ"].value) >>> 0;
  __D11tool_disarm11__moduleRefZ = Module["__D11tool_disarm11__moduleRefZ"] = (wasmExports["_D11tool_disarm11__moduleRefZ"].value) >>> 0;
  __D25tool_activation_ownership11__moduleRefZ = Module["__D25tool_activation_ownership11__moduleRefZ"] = (wasmExports["_D25tool_activation_ownership11__moduleRefZ"].value) >>> 0;
  __D4tool11__moduleRefZ = Module["__D4tool11__moduleRefZ"] = (wasmExports["_D4tool11__moduleRefZ"].value) >>> 0;
  __D13symmetry_pick11__moduleRefZ = Module["__D13symmetry_pick11__moduleRefZ"] = (wasmExports["_D13symmetry_pick11__moduleRefZ"].value) >>> 0;
  __D8symmetry11__moduleRefZ = Module["__D8symmetry11__moduleRefZ"] = (wasmExports["_D8symmetry11__moduleRefZ"].value) >>> 0;
  __D19subpatch_worker_web11__moduleRefZ = Module["__D19subpatch_worker_web11__moduleRefZ"] = (wasmExports["_D19subpatch_worker_web11__moduleRefZ"].value) >>> 0;
  __D15subpatch_worker11__moduleRefZ = Module["__D15subpatch_worker11__moduleRefZ"] = (wasmExports["_D15subpatch_worker11__moduleRefZ"].value) >>> 0;
  __D16subpatch_preview11__moduleRefZ = Module["__D16subpatch_preview11__moduleRefZ"] = (wasmExports["_D16subpatch_preview11__moduleRefZ"].value) >>> 0;
  __D12subpatch_osd11__moduleRefZ = Module["__D12subpatch_osd11__moduleRefZ"] = (wasmExports["_D12subpatch_osd11__moduleRefZ"].value) >>> 0;
  __D10step_trace11__moduleRefZ = Module["__D10step_trace11__moduleRefZ"] = (wasmExports["_D10step_trace11__moduleRefZ"].value) >>> 0;
  __D8snapshot11__moduleRefZ = Module["__D8snapshot11__moduleRefZ"] = (wasmExports["_D8snapshot11__moduleRefZ"].value) >>> 0;
  __D11snap_render11__moduleRefZ = Module["__D11snap_render11__moduleRefZ"] = (wasmExports["_D11snap_render11__moduleRefZ"].value) >>> 0;
  __D13snap_election11__moduleRefZ = Module["__D13snap_election11__moduleRefZ"] = (wasmExports["_D13snap_election11__moduleRefZ"].value) >>> 0;
  __D4snap11__moduleRefZ = Module["__D4snap11__moduleRefZ"] = (wasmExports["_D4snap11__moduleRefZ"].value) >>> 0;
  __D9shortcuts11__moduleRefZ = Module["__D9shortcuts11__moduleRefZ"] = (wasmExports["_D9shortcuts11__moduleRefZ"].value) >>> 0;
  __D6shader11__moduleRefZ = Module["__D6shader11__moduleRefZ"] = (wasmExports["_D6shader11__moduleRefZ"].value) >>> 0;
  __D13session_owner11__moduleRefZ = Module["__D13session_owner11__moduleRefZ"] = (wasmExports["_D13session_owner11__moduleRefZ"].value) >>> 0;
  __D7seltype11__moduleRefZ = Module["__D7seltype11__moduleRefZ"] = (wasmExports["_D7seltype11__moduleRefZ"].value) >>> 0;
  __D14selftest_fault11__moduleRefZ = Module["__D14selftest_fault11__moduleRefZ"] = (wasmExports["_D14selftest_fault11__moduleRefZ"].value) >>> 0;
  __D20selection_projection11__moduleRefZ = Module["__D20selection_projection11__moduleRefZ"] = (wasmExports["_D20selection_projection11__moduleRefZ"].value) >>> 0;
  __D17selection_product11__moduleRefZ = Module["__D17selection_product11__moduleRefZ"] = (wasmExports["_D17selection_product11__moduleRefZ"].value) >>> 0;
  __D30selection_command_registration11__moduleRefZ = Module["__D30selection_command_registration11__moduleRefZ"] = (wasmExports["_D30selection_command_registration11__moduleRefZ"].value) >>> 0;
  __D17select_visibility11__moduleRefZ = Module["__D17select_visibility11__moduleRefZ"] = (wasmExports["_D17select_visibility11__moduleRefZ"].value) >>> 0;
  __D9sdl_error11__moduleRefZ = Module["__D9sdl_error11__moduleRefZ"] = (wasmExports["_D9sdl_error11__moduleRefZ"].value) >>> 0;
  __D14screen_buckets11__moduleRefZ = Module["__D14screen_buckets11__moduleRefZ"] = (wasmExports["_D14screen_buckets11__moduleRefZ"].value) >>> 0;
  __D19scene_reset_effects11__moduleRefZ = Module["__D19scene_reset_effects11__moduleRefZ"] = (wasmExports["_D19scene_reset_effects11__moduleRefZ"].value) >>> 0;
  __D33scene_file_lifecycle_registration11__moduleRefZ = Module["__D33scene_file_lifecycle_registration11__moduleRefZ"] = (wasmExports["_D33scene_file_lifecycle_registration11__moduleRefZ"].value) >>> 0;
  __D6render5scene11__moduleRefZ = Module["__D6render5scene11__moduleRefZ"] = (wasmExports["_D6render5scene11__moduleRefZ"].value) >>> 0;
  __D6render11rpr_backend11__moduleRefZ = Module["__D6render11rpr_backend11__moduleRefZ"] = (wasmExports["_D6render11rpr_backend11__moduleRefZ"].value) >>> 0;
  __D6render10render_mvp11__moduleRefZ = Module["__D6render10render_mvp11__moduleRefZ"] = (wasmExports["_D6render10render_mvp11__moduleRefZ"].value) >>> 0;
  __D6render11render_diff11__moduleRefZ = Module["__D6render11render_diff11__moduleRefZ"] = (wasmExports["_D6render11render_diff11__moduleRefZ"].value) >>> 0;
  __D6render14cycles_backend11__moduleRefZ = Module["__D6render14cycles_backend11__moduleRefZ"] = (wasmExports["_D6render14cycles_backend11__moduleRefZ"].value) >>> 0;
  __D6render14backend_bridge11__moduleRefZ = Module["__D6render14backend_bridge11__moduleRefZ"] = (wasmExports["_D6render14backend_bridge11__moduleRefZ"].value) >>> 0;
  __D6render7backend11__moduleRefZ = Module["__D6render7backend11__moduleRefZ"] = (wasmExports["_D6render7backend11__moduleRefZ"].value) >>> 0;
  __D6remesh10remesh_job11__moduleRefZ = Module["__D6remesh10remesh_job11__moduleRefZ"] = (wasmExports["_D6remesh10remesh_job11__moduleRefZ"].value) >>> 0;
  __D6remesh13region_stitch11__moduleRefZ = Module["__D6remesh13region_stitch11__moduleRefZ"] = (wasmExports["_D6remesh13region_stitch11__moduleRefZ"].value) >>> 0;
  __D8registry11__moduleRefZ = Module["__D8registry11__moduleRefZ"] = (wasmExports["_D8registry11__moduleRefZ"].value) >>> 0;
  __D12registration11__moduleRefZ = Module["__D12registration11__moduleRefZ"] = (wasmExports["_D12registration11__moduleRefZ"].value) >>> 0;
  __D19record_observer_hub11__moduleRefZ = Module["__D19record_observer_hub11__moduleRefZ"] = (wasmExports["_D19record_observer_hub11__moduleRefZ"].value) >>> 0;
  __D14property_panel11__moduleRefZ = Module["__D14property_panel11__moduleRefZ"] = (wasmExports["_D14property_panel11__moduleRefZ"].value) >>> 0;
  __D25prepared_xfrm_update_tail11__moduleRefZ = Module["__D25prepared_xfrm_update_tail11__moduleRefZ"] = (wasmExports["_D25prepared_xfrm_update_tail11__moduleRefZ"].value) >>> 0;
  __D31prepared_xfrm_update_edit_close11__moduleRefZ = Module["__D31prepared_xfrm_update_edit_close11__moduleRefZ"] = (wasmExports["_D31prepared_xfrm_update_edit_close11__moduleRefZ"].value) >>> 0;
  __D29prepared_xfrm_update_boundary11__moduleRefZ = Module["__D29prepared_xfrm_update_boundary11__moduleRefZ"] = (wasmExports["_D29prepared_xfrm_update_boundary11__moduleRefZ"].value) >>> 0;
  __D23prepared_xfrm_slot_poll11__moduleRefZ = Module["__D23prepared_xfrm_slot_poll11__moduleRefZ"] = (wasmExports["_D23prepared_xfrm_slot_poll11__moduleRefZ"].value) >>> 0;
  __D20prepared_xfrm_replay11__moduleRefZ = Module["__D20prepared_xfrm_replay11__moduleRefZ"] = (wasmExports["_D20prepared_xfrm_replay11__moduleRefZ"].value) >>> 0;
  __D26prepared_xfrm_refire_state11__moduleRefZ = Module["__D26prepared_xfrm_refire_state11__moduleRefZ"] = (wasmExports["_D26prepared_xfrm_refire_state11__moduleRefZ"].value) >>> 0;
  __D32prepared_xfrm_activation_session11__moduleRefZ = Module["__D32prepared_xfrm_activation_session11__moduleRefZ"] = (wasmExports["_D32prepared_xfrm_activation_session11__moduleRefZ"].value) >>> 0;
  __D34prepared_vertex_merge_param_update11__moduleRefZ = Module["__D34prepared_vertex_merge_param_update11__moduleRefZ"] = (wasmExports["_D34prepared_vertex_merge_param_update11__moduleRefZ"].value) >>> 0;
  __D32prepared_vertex_merge_activation11__moduleRefZ = Module["__D32prepared_vertex_merge_activation11__moduleRefZ"] = (wasmExports["_D32prepared_vertex_merge_activation11__moduleRefZ"].value) >>> 0;
  __D36prepared_vertex_extrude_param_update11__moduleRefZ = Module["__D36prepared_vertex_extrude_param_update11__moduleRefZ"] = (wasmExports["_D36prepared_vertex_extrude_param_update11__moduleRefZ"].value) >>> 0;
  __D34prepared_vertex_extrude_activation11__moduleRefZ = Module["__D34prepared_vertex_extrude_activation11__moduleRefZ"] = (wasmExports["_D34prepared_vertex_extrude_activation11__moduleRefZ"].value) >>> 0;
  __D34prepared_vertex_bevel_param_update11__moduleRefZ = Module["__D34prepared_vertex_bevel_param_update11__moduleRefZ"] = (wasmExports["_D34prepared_vertex_bevel_param_update11__moduleRefZ"].value) >>> 0;
  __D32prepared_vertex_bevel_activation11__moduleRefZ = Module["__D32prepared_vertex_bevel_activation11__moduleRefZ"] = (wasmExports["_D32prepared_vertex_bevel_activation11__moduleRefZ"].value) >>> 0;
  __D37prepared_transform_product_activation11__moduleRefZ = Module["__D37prepared_transform_product_activation11__moduleRefZ"] = (wasmExports["_D37prepared_transform_product_activation11__moduleRefZ"].value) >>> 0;
  __D29prepared_transform_activation11__moduleRefZ = Module["__D29prepared_transform_activation11__moduleRefZ"] = (wasmExports["_D29prepared_transform_activation11__moduleRefZ"].value) >>> 0;
  __D28prepared_topology_pen_update11__moduleRefZ = Module["__D28prepared_topology_pen_update11__moduleRefZ"] = (wasmExports["_D28prepared_topology_pen_update11__moduleRefZ"].value) >>> 0;
  __D32prepared_topology_pen_deactivate11__moduleRefZ = Module["__D32prepared_topology_pen_deactivate11__moduleRefZ"] = (wasmExports["_D32prepared_topology_pen_deactivate11__moduleRefZ"].value) >>> 0;
  __D32prepared_topology_pen_activation11__moduleRefZ = Module["__D32prepared_topology_pen_activation11__moduleRefZ"] = (wasmExports["_D32prepared_topology_pen_activation11__moduleRefZ"].value) >>> 0;
  __D24prepared_tool_transition11__moduleRefZ = Module["__D24prepared_tool_transition11__moduleRefZ"] = (wasmExports["_D24prepared_tool_transition11__moduleRefZ"].value) >>> 0;
  __D20prepared_tool_effect11__moduleRefZ = Module["__D20prepared_tool_effect11__moduleRefZ"] = (wasmExports["_D20prepared_tool_effect11__moduleRefZ"].value) >>> 0;
  __D24prepared_tack_activation11__moduleRefZ = Module["__D24prepared_tack_activation11__moduleRefZ"] = (wasmExports["_D24prepared_tack_activation11__moduleRefZ"].value) >>> 0;
  __D34prepared_stroke_extrude_activation11__moduleRefZ = Module["__D34prepared_stroke_extrude_activation11__moduleRefZ"] = (wasmExports["_D34prepared_stroke_extrude_activation11__moduleRefZ"].value) >>> 0;
  __D34prepared_smooth_shift_param_update11__moduleRefZ = Module["__D34prepared_smooth_shift_param_update11__moduleRefZ"] = (wasmExports["_D34prepared_smooth_shift_param_update11__moduleRefZ"].value) >>> 0;
  __D32prepared_smooth_shift_activation11__moduleRefZ = Module["__D32prepared_smooth_shift_activation11__moduleRefZ"] = (wasmExports["_D32prepared_smooth_shift_activation11__moduleRefZ"].value) >>> 0;
  __D27prepared_slice_param_update11__moduleRefZ = Module["__D27prepared_slice_param_update11__moduleRefZ"] = (wasmExports["_D27prepared_slice_param_update11__moduleRefZ"].value) >>> 0;
  __D25prepared_slice_deactivate11__moduleRefZ = Module["__D25prepared_slice_deactivate11__moduleRefZ"] = (wasmExports["_D25prepared_slice_deactivate11__moduleRefZ"].value) >>> 0;
  __D25prepared_slice_activation11__moduleRefZ = Module["__D25prepared_slice_activation11__moduleRefZ"] = (wasmExports["_D25prepared_slice_activation11__moduleRefZ"].value) >>> 0;
  __D32prepared_selection_profile_image11__moduleRefZ = Module["__D32prepared_selection_profile_image11__moduleRefZ"] = (wasmExports["_D32prepared_selection_profile_image11__moduleRefZ"].value) >>> 0;
  __D26prepared_selection_profile11__moduleRefZ = Module["__D26prepared_selection_profile11__moduleRefZ"] = (wasmExports["_D26prepared_selection_profile11__moduleRefZ"].value) >>> 0;
  __D21prepared_scale_update11__moduleRefZ = Module["__D21prepared_scale_update11__moduleRefZ"] = (wasmExports["_D21prepared_scale_update11__moduleRefZ"].value) >>> 0;
  __D22prepared_rotate_update11__moduleRefZ = Module["__D22prepared_rotate_update11__moduleRefZ"] = (wasmExports["_D22prepared_rotate_update11__moduleRefZ"].value) >>> 0;
  __D31prepared_reduction_param_update11__moduleRefZ = Module["__D31prepared_reduction_param_update11__moduleRefZ"] = (wasmExports["_D31prepared_reduction_param_update11__moduleRefZ"].value) >>> 0;
  __D23prepared_record_context11__moduleRefZ = Module["__D23prepared_record_context11__moduleRefZ"] = (wasmExports["_D23prepared_record_context11__moduleRefZ"].value) >>> 0;
  __D32prepared_radial_sweep_transition11__moduleRefZ = Module["__D32prepared_radial_sweep_transition11__moduleRefZ"] = (wasmExports["_D32prepared_radial_sweep_transition11__moduleRefZ"].value) >>> 0;
  __D32prepared_radial_array_transition11__moduleRefZ = Module["__D32prepared_radial_array_transition11__moduleRefZ"] = (wasmExports["_D32prepared_radial_array_transition11__moduleRefZ"].value) >>> 0;
  __D22prepared_private_state11__moduleRefZ = Module["__D22prepared_private_state11__moduleRefZ"] = (wasmExports["_D22prepared_private_state11__moduleRefZ"].value) >>> 0;
  __D32prepared_poly_inset_param_update11__moduleRefZ = Module["__D32prepared_poly_inset_param_update11__moduleRefZ"] = (wasmExports["_D32prepared_poly_inset_param_update11__moduleRefZ"].value) >>> 0;
  __D30prepared_poly_inset_activation11__moduleRefZ = Module["__D30prepared_poly_inset_activation11__moduleRefZ"] = (wasmExports["_D30prepared_poly_inset_activation11__moduleRefZ"].value) >>> 0;
  __D34prepared_poly_extrude_param_update11__moduleRefZ = Module["__D34prepared_poly_extrude_param_update11__moduleRefZ"] = (wasmExports["_D34prepared_poly_extrude_param_update11__moduleRefZ"].value) >>> 0;
  __D32prepared_poly_extrude_activation11__moduleRefZ = Module["__D32prepared_poly_extrude_activation11__moduleRefZ"] = (wasmExports["_D32prepared_poly_extrude_activation11__moduleRefZ"].value) >>> 0;
  __D32prepared_poly_bevel_param_update11__moduleRefZ = Module["__D32prepared_poly_bevel_param_update11__moduleRefZ"] = (wasmExports["_D32prepared_poly_bevel_param_update11__moduleRefZ"].value) >>> 0;
  __D30prepared_poly_bevel_activation11__moduleRefZ = Module["__D30prepared_poly_bevel_activation11__moduleRefZ"] = (wasmExports["_D30prepared_poly_bevel_activation11__moduleRefZ"].value) >>> 0;
  __D24prepared_pipe_activation11__moduleRefZ = Module["__D24prepared_pipe_activation11__moduleRefZ"] = (wasmExports["_D24prepared_pipe_activation11__moduleRefZ"].value) >>> 0;
  __D20prepared_move_update11__moduleRefZ = Module["__D20prepared_move_update11__moduleRefZ"] = (wasmExports["_D20prepared_move_update11__moduleRefZ"].value) >>> 0;
  __D26prepared_mirror_activation11__moduleRefZ = Module["__D26prepared_mirror_activation11__moduleRefZ"] = (wasmExports["_D26prepared_mirror_activation11__moduleRefZ"].value) >>> 0;
  __D28prepared_magnet_param_update11__moduleRefZ = Module["__D28prepared_magnet_param_update11__moduleRefZ"] = (wasmExports["_D28prepared_magnet_param_update11__moduleRefZ"].value) >>> 0;
  __D32prepared_loop_slice_param_update11__moduleRefZ = Module["__D32prepared_loop_slice_param_update11__moduleRefZ"] = (wasmExports["_D32prepared_loop_slice_param_update11__moduleRefZ"].value) >>> 0;
  __D30prepared_loop_slice_deactivate11__moduleRefZ = Module["__D30prepared_loop_slice_deactivate11__moduleRefZ"] = (wasmExports["_D30prepared_loop_slice_deactivate11__moduleRefZ"].value) >>> 0;
  __D30prepared_loop_slice_activation11__moduleRefZ = Module["__D30prepared_loop_slice_activation11__moduleRefZ"] = (wasmExports["_D30prepared_loop_slice_activation11__moduleRefZ"].value) >>> 0;
  __D23prepared_inherited_noop11__moduleRefZ = Module["__D23prepared_inherited_noop11__moduleRefZ"] = (wasmExports["_D23prepared_inherited_noop11__moduleRefZ"].value) >>> 0;
  __D32prepared_edge_slice_param_update11__moduleRefZ = Module["__D32prepared_edge_slice_param_update11__moduleRefZ"] = (wasmExports["_D32prepared_edge_slice_param_update11__moduleRefZ"].value) >>> 0;
  __D30prepared_edge_slice_deactivate11__moduleRefZ = Module["__D30prepared_edge_slice_deactivate11__moduleRefZ"] = (wasmExports["_D30prepared_edge_slice_deactivate11__moduleRefZ"].value) >>> 0;
  __D30prepared_edge_slice_activation11__moduleRefZ = Module["__D30prepared_edge_slice_activation11__moduleRefZ"] = (wasmExports["_D30prepared_edge_slice_activation11__moduleRefZ"].value) >>> 0;
  __D34prepared_edge_extrude_param_update11__moduleRefZ = Module["__D34prepared_edge_extrude_param_update11__moduleRefZ"] = (wasmExports["_D34prepared_edge_extrude_param_update11__moduleRefZ"].value) >>> 0;
  __D32prepared_edge_extrude_activation11__moduleRefZ = Module["__D32prepared_edge_extrude_activation11__moduleRefZ"] = (wasmExports["_D32prepared_edge_extrude_activation11__moduleRefZ"].value) >>> 0;
  __D36prepared_edge_extend_tool_activation11__moduleRefZ = Module["__D36prepared_edge_extend_tool_activation11__moduleRefZ"] = (wasmExports["_D36prepared_edge_extend_tool_activation11__moduleRefZ"].value) >>> 0;
  __D33prepared_edge_extend_param_update11__moduleRefZ = Module["__D33prepared_edge_extend_param_update11__moduleRefZ"] = (wasmExports["_D33prepared_edge_extend_param_update11__moduleRefZ"].value) >>> 0;
  __D31prepared_edge_extend_deactivate11__moduleRefZ = Module["__D31prepared_edge_extend_deactivate11__moduleRefZ"] = (wasmExports["_D31prepared_edge_extend_deactivate11__moduleRefZ"].value) >>> 0;
  __D32prepared_edge_bevel_param_update11__moduleRefZ = Module["__D32prepared_edge_bevel_param_update11__moduleRefZ"] = (wasmExports["_D32prepared_edge_bevel_param_update11__moduleRefZ"].value) >>> 0;
  __D30prepared_edge_bevel_activation11__moduleRefZ = Module["__D30prepared_edge_bevel_activation11__moduleRefZ"] = (wasmExports["_D30prepared_edge_bevel_activation11__moduleRefZ"].value) >>> 0;
  __D35prepared_command_wrapper_activation11__moduleRefZ = Module["__D35prepared_command_wrapper_activation11__moduleRefZ"] = (wasmExports["_D35prepared_command_wrapper_activation11__moduleRefZ"].value) >>> 0;
  __D26prepared_bridge_activation11__moduleRefZ = Module["__D26prepared_bridge_activation11__moduleRefZ"] = (wasmExports["_D26prepared_bridge_activation11__moduleRefZ"].value) >>> 0;
  __D18prepared_box_param11__moduleRefZ = Module["__D18prepared_box_param11__moduleRefZ"] = (wasmExports["_D18prepared_box_param11__moduleRefZ"].value) >>> 0;
  __D27prepared_array_param_update11__moduleRefZ = Module["__D27prepared_array_param_update11__moduleRefZ"] = (wasmExports["_D27prepared_array_param_update11__moduleRefZ"].value) >>> 0;
  __D5prefs11__moduleRefZ = Module["__D5prefs11__moduleRefZ"] = (wasmExports["_D5prefs11__moduleRefZ"].value) >>> 0;
  __D11popup_state11__moduleRefZ = Module["__D11popup_state11__moduleRefZ"] = (wasmExports["_D11popup_state11__moduleRefZ"].value) >>> 0;
  __D19playback_controller11__moduleRefZ = Module["__D19playback_controller11__moduleRefZ"] = (wasmExports["_D19playback_controller11__moduleRefZ"].value) >>> 0;
  __D11plane_bytes11__moduleRefZ = Module["__D11plane_bytes11__moduleRefZ"] = (wasmExports["_D11plane_bytes11__moduleRefZ"].value) >>> 0;
  __D15pipe_gizmo_host11__moduleRefZ = Module["__D15pipe_gizmo_host11__moduleRefZ"] = (wasmExports["_D15pipe_gizmo_host11__moduleRefZ"].value) >>> 0;
  __D25pipe_command_registration11__moduleRefZ = Module["__D25pipe_command_registration11__moduleRefZ"] = (wasmExports["_D25pipe_command_registration11__moduleRefZ"].value) >>> 0;
  __D9pie_state11__moduleRefZ = Module["__D9pie_state11__moduleRefZ"] = (wasmExports["_D9pie_state11__moduleRefZ"].value) >>> 0;
  __D9pie_menus11__moduleRefZ = Module["__D9pie_menus11__moduleRefZ"] = (wasmExports["_D9pie_menus11__moduleRefZ"].value) >>> 0;
  __D12pie_geometry11__moduleRefZ = Module["__D12pie_geometry11__moduleRefZ"] = (wasmExports["_D12pie_geometry11__moduleRefZ"].value) >>> 0;
  __D10perf_probe11__moduleRefZ = Module["__D10perf_probe11__moduleRefZ"] = (wasmExports["_D10perf_probe11__moduleRefZ"].value) >>> 0;
  __D4path11__moduleRefZ = Module["__D4path11__moduleRefZ"] = (wasmExports["_D4path11__moduleRefZ"].value) >>> 0;
  __D14params_widgets11__moduleRefZ = Module["__D14params_widgets11__moduleRefZ"] = (wasmExports["_D14params_widgets11__moduleRefZ"].value) >>> 0;
  __D6params11__moduleRefZ = Module["__D6params11__moduleRefZ"] = (wasmExports["_D6params11__moduleRefZ"].value) >>> 0;
  __D13overlay_space11__moduleRefZ = Module["__D13overlay_space11__moduleRefZ"] = (wasmExports["_D13overlay_space11__moduleRefZ"].value) >>> 0;
  __D8operator11__moduleRefZ = Module["__D8operator11__moduleRefZ"] = (wasmExports["_D8operator11__moduleRefZ"].value) >>> 0;
  __D12morph_target11__moduleRefZ = Module["__D12morph_target11__moduleRefZ"] = (wasmExports["_D12morph_target11__moduleRefZ"].value) >>> 0;
  __D15mesh_visibility11__moduleRefZ = Module["__D15mesh_visibility11__moduleRefZ"] = (wasmExports["_D15mesh_visibility11__moduleRefZ"].value) >>> 0;
  __D9mesh_topo11__moduleRefZ = Module["__D9mesh_topo11__moduleRefZ"] = (wasmExports["_D9mesh_topo11__moduleRefZ"].value) >>> 0;
  __D10mesh_stats11__moduleRefZ = Module["__D10mesh_stats11__moduleRefZ"] = (wasmExports["_D10mesh_stats11__moduleRefZ"].value) >>> 0;
  __D12mesh_selsets11__moduleRefZ = Module["__D12mesh_selsets11__moduleRefZ"] = (wasmExports["_D12mesh_selsets11__moduleRefZ"].value) >>> 0;
  __D11mesh_planes11__moduleRefZ = Module["__D11mesh_planes11__moduleRefZ"] = (wasmExports["_D11mesh_planes11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops7thicken11__moduleRefZ = Module["__D8mesh_ops7thicken11__moduleRefZ"] = (wasmExports["_D8mesh_ops7thicken11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops11select_loop11__moduleRefZ = Module["__D8mesh_ops11select_loop11__moduleRefZ"] = (wasmExports["_D8mesh_ops11select_loop11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops7revolve11__moduleRefZ = Module["__D8mesh_ops7revolve11__moduleRefZ"] = (wasmExports["_D8mesh_ops7revolve11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops10poly_bevel11__moduleRefZ = Module["__D8mesh_ops10poly_bevel11__moduleRefZ"] = (wasmExports["_D8mesh_ops10poly_bevel11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops10loop_slice11__moduleRefZ = Module["__D8mesh_ops10loop_slice11__moduleRefZ"] = (wasmExports["_D8mesh_ops10loop_slice11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops7extrude11__moduleRefZ = Module["__D8mesh_ops7extrude11__moduleRefZ"] = (wasmExports["_D8mesh_ops7extrude11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops10edge_bevel11__moduleRefZ = Module["__D8mesh_ops10edge_bevel11__moduleRefZ"] = (wasmExports["_D8mesh_ops10edge_bevel11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops8decimate11__moduleRefZ = Module["__D8mesh_ops8decimate11__moduleRefZ"] = (wasmExports["_D8mesh_ops8decimate11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops3cut11__moduleRefZ = Module["__D8mesh_ops3cut11__moduleRefZ"] = (wasmExports["_D8mesh_ops3cut11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops14connected_mask11__moduleRefZ = Module["__D8mesh_ops14connected_mask11__moduleRefZ"] = (wasmExports["_D8mesh_ops14connected_mask11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops7cleanup11__moduleRefZ = Module["__D8mesh_ops7cleanup11__moduleRefZ"] = (wasmExports["_D8mesh_ops7cleanup11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops6bridge11__moduleRefZ = Module["__D8mesh_ops6bridge11__moduleRefZ"] = (wasmExports["_D8mesh_ops6bridge11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops8box_geom11__moduleRefZ = Module["__D8mesh_ops8box_geom11__moduleRefZ"] = (wasmExports["_D8mesh_ops8box_geom11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops12bevel_vertex11__moduleRefZ = Module["__D8mesh_ops12bevel_vertex11__moduleRefZ"] = (wasmExports["_D8mesh_ops12bevel_vertex11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops9bevel_fin11__moduleRefZ = Module["__D8mesh_ops9bevel_fin11__moduleRefZ"] = (wasmExports["_D8mesh_ops9bevel_fin11__moduleRefZ"].value) >>> 0;
  __D8mesh_ops12bevel_curves11__moduleRefZ = Module["__D8mesh_ops12bevel_curves11__moduleRefZ"] = (wasmExports["_D8mesh_ops12bevel_curves11__moduleRefZ"].value) >>> 0;
  __D10mesh_morph11__moduleRefZ = Module["__D10mesh_morph11__moduleRefZ"] = (wasmExports["_D10mesh_morph11__moduleRefZ"].value) >>> 0;
  __D8mesh_gpu11__moduleRefZ = Module["__D8mesh_gpu11__moduleRefZ"] = (wasmExports["_D8mesh_gpu11__moduleRefZ"].value) >>> 0;
  __D15mesh_edit_delta11__moduleRefZ = Module["__D15mesh_edit_delta11__moduleRefZ"] = (wasmExports["_D15mesh_edit_delta11__moduleRefZ"].value) >>> 0;
  __D15mesh_edge_slice11__moduleRefZ = Module["__D15mesh_edge_slice11__moduleRefZ"] = (wasmExports["_D15mesh_edge_slice11__moduleRefZ"].value) >>> 0;
  __D10mesh_dirty11__moduleRefZ = Module["__D10mesh_dirty11__moduleRefZ"] = (wasmExports["_D10mesh_dirty11__moduleRefZ"].value) >>> 0;
  __D16mesh_corner_maps11__moduleRefZ = Module["__D16mesh_corner_maps11__moduleRefZ"] = (wasmExports["_D16mesh_corner_maps11__moduleRefZ"].value) >>> 0;
  __D25mesh_command_registration11__moduleRefZ = Module["__D25mesh_command_registration11__moduleRefZ"] = (wasmExports["_D25mesh_command_registration11__moduleRefZ"].value) >>> 0;
  __D9mesh_bbox11__moduleRefZ = Module["__D9mesh_bbox11__moduleRefZ"] = (wasmExports["_D9mesh_bbox11__moduleRefZ"].value) >>> 0;
  __D13mesh_analysis11__moduleRefZ = Module["__D13mesh_analysis11__moduleRefZ"] = (wasmExports["_D13mesh_analysis11__moduleRefZ"].value) >>> 0;
  __D4mesh11__moduleRefZ = Module["__D4mesh11__moduleRefZ"] = (wasmExports["_D4mesh11__moduleRefZ"].value) >>> 0;
  __D4math11__moduleRefZ = Module["__D4math11__moduleRefZ"] = (wasmExports["_D4math11__moduleRefZ"].value) >>> 0;
  __D14macro_recorder11__moduleRefZ = Module["__D14macro_recorder11__moduleRefZ"] = (wasmExports["_D14macro_recorder11__moduleRefZ"].value) >>> 0;
  __D3log11__moduleRefZ = Module["__D3log11__moduleRefZ"] = (wasmExports["_D3log11__moduleRefZ"].value) >>> 0;
  __D23live_registration_roles11__moduleRefZ = Module["__D23live_registration_roles11__moduleRefZ"] = (wasmExports["_D23live_registration_roles11__moduleRefZ"].value) >>> 0;
  __D19layout_reset_action11__moduleRefZ = Module["__D19layout_reset_action11__moduleRefZ"] = (wasmExports["_D19layout_reset_action11__moduleRefZ"].value) >>> 0;
  __D12layer_params11__moduleRefZ = Module["__D12layer_params11__moduleRefZ"] = (wasmExports["_D12layer_params11__moduleRefZ"].value) >>> 0;
  __D8json_num11__moduleRefZ = Module["__D8json_num11__moduleRefZ"] = (wasmExports["_D8json_num11__moduleRefZ"].value) >>> 0;
  __D10item_xform11__moduleRefZ = Module["__D10item_xform11__moduleRefZ"] = (wasmExports["_D10item_xform11__moduleRefZ"].value) >>> 0;
  __D9item_pick11__moduleRefZ = Module["__D9item_pick11__moduleRefZ"] = (wasmExports["_D9item_pick11__moduleRefZ"].value) >>> 0;
  __D10item_kinds11__moduleRefZ = Module["__D10item_kinds11__moduleRefZ"] = (wasmExports["_D10item_kinds11__moduleRefZ"].value) >>> 0;
  __D25item_command_registration11__moduleRefZ = Module["__D25item_command_registration11__moduleRefZ"] = (wasmExports["_D25item_command_registration11__moduleRefZ"].value) >>> 0;
  __D2io8scene_ir11__moduleRefZ = Module["__D2io8scene_ir11__moduleRefZ"] = (wasmExports["_D2io8scene_ir11__moduleRefZ"].value) >>> 0;
  __D2io12scene_import11__moduleRefZ = Module["__D2io12scene_import11__moduleRefZ"] = (wasmExports["_D2io12scene_import11__moduleRefZ"].value) >>> 0;
  __D2io12scene_export11__moduleRefZ = Module["__D2io12scene_export11__moduleRefZ"] = (wasmExports["_D2io12scene_export11__moduleRefZ"].value) >>> 0;
  __D2io6native11__moduleRefZ = Module["__D2io6native11__moduleRefZ"] = (wasmExports["_D2io6native11__moduleRefZ"].value) >>> 0;
  __D2io10lwo_import11__moduleRefZ = Module["__D2io10lwo_import11__moduleRefZ"] = (wasmExports["_D2io10lwo_import11__moduleRefZ"].value) >>> 0;
  __D2io10lwo_export11__moduleRefZ = Module["__D2io10lwo_export11__moduleRefZ"] = (wasmExports["_D2io10lwo_export11__moduleRefZ"].value) >>> 0;
  __D2io10image_path11__moduleRefZ = Module["__D2io10image_path11__moduleRefZ"] = (wasmExports["_D2io10image_path11__moduleRefZ"].value) >>> 0;
  __D2io12image_decode11__moduleRefZ = Module["__D2io12image_decode11__moduleRefZ"] = (wasmExports["_D2io12image_decode11__moduleRefZ"].value) >>> 0;
  __D2io7formats11__moduleRefZ = Module["__D2io7formats11__moduleRefZ"] = (wasmExports["_D2io7formats11__moduleRefZ"].value) >>> 0;
  __D2io19file_dialog_browser11__moduleRefZ = Module["__D2io19file_dialog_browser11__moduleRefZ"] = (wasmExports["_D2io19file_dialog_browser11__moduleRefZ"].value) >>> 0;
  __D2io11file_dialog11__moduleRefZ = Module["__D2io11file_dialog11__moduleRefZ"] = (wasmExports["_D2io11file_dialog11__moduleRefZ"].value) >>> 0;
  __D2io9doc_state11__moduleRefZ = Module["__D2io9doc_state11__moduleRefZ"] = (wasmExports["_D2io9doc_state11__moduleRefZ"].value) >>> 0;
  __D2io14assimp_runtime11__moduleRefZ = Module["__D2io14assimp_runtime11__moduleRefZ"] = (wasmExports["_D2io14assimp_runtime11__moduleRefZ"].value) >>> 0;
  __D11input_zones11__moduleRefZ = Module["__D11input_zones11__moduleRefZ"] = (wasmExports["_D11input_zones11__moduleRefZ"].value) >>> 0;
  __D12input_router11__moduleRefZ = Module["__D12input_router11__moduleRefZ"] = (wasmExports["_D12input_router11__moduleRefZ"].value) >>> 0;
  __D17input_frame_state11__moduleRefZ = Module["__D17input_frame_state11__moduleRefZ"] = (wasmExports["_D17input_frame_state11__moduleRefZ"].value) >>> 0;
  __D13input_context11__moduleRefZ = Module["__D13input_context11__moduleRefZ"] = (wasmExports["_D13input_context11__moduleRefZ"].value) >>> 0;
  __D11imgui_style11__moduleRefZ = Module["__D11imgui_style11__moduleRefZ"] = (wasmExports["_D11imgui_style11__moduleRefZ"].value) >>> 0;
  __D19imgui_flag_boundary11__moduleRefZ = Module["__D19imgui_flag_boundary11__moduleRefZ"] = (wasmExports["_D19imgui_flag_boundary11__moduleRefZ"].value) >>> 0;
  __D16imgui_event_gate11__moduleRefZ = Module["__D16imgui_event_gate11__moduleRefZ"] = (wasmExports["_D16imgui_event_gate11__moduleRefZ"].value) >>> 0;
  __D11image_plane11__moduleRefZ = Module["__D11image_plane11__moduleRefZ"] = (wasmExports["_D11image_plane11__moduleRefZ"].value) >>> 0;
  __D10image_data11__moduleRefZ = Module["__D10image_data11__moduleRefZ"] = (wasmExports["_D10image_data11__moduleRefZ"].value) >>> 0;
  __D11image_cache11__moduleRefZ = Module["__D11image_cache11__moduleRefZ"] = (wasmExports["_D11image_cache11__moduleRefZ"].value) >>> 0;
  __D14http_transport11__moduleRefZ = Module["__D14http_transport11__moduleRefZ"] = (wasmExports["_D14http_transport11__moduleRefZ"].value) >>> 0;
  __D11http_server11__moduleRefZ = Module["__D11http_server11__moduleRefZ"] = (wasmExports["_D11http_server11__moduleRefZ"].value) >>> 0;
  __D14http_providers11__moduleRefZ = Module["__D14http_providers11__moduleRefZ"] = (wasmExports["_D14http_providers11__moduleRefZ"].value) >>> 0;
  __D9http_json11__moduleRefZ = Module["__D9http_json11__moduleRefZ"] = (wasmExports["_D9http_json11__moduleRefZ"].value) >>> 0;
  __D20http_command_adapter11__moduleRefZ = Module["__D20http_command_adapter11__moduleRefZ"] = (wasmExports["_D20http_command_adapter11__moduleRefZ"].value) >>> 0;
  __D11hover_state11__moduleRefZ = Module["__D11hover_state11__moduleRefZ"] = (wasmExports["_D11hover_state11__moduleRefZ"].value) >>> 0;
  __D26history_macro_registration11__moduleRefZ = Module["__D26history_macro_registration11__moduleRefZ"] = (wasmExports["_D26history_macro_registration11__moduleRefZ"].value) >>> 0;
  __D7handles6shapes11__moduleRefZ = Module["__D7handles6shapes11__moduleRefZ"] = (wasmExports["_D7handles6shapes11__moduleRefZ"].value) >>> 0;
  __D7handles7gl_util11__moduleRefZ = Module["__D7handles7gl_util11__moduleRefZ"] = (wasmExports["_D7handles7gl_util11__moduleRefZ"].value) >>> 0;
  __D7handles13gizmo_metrics11__moduleRefZ = Module["__D7handles13gizmo_metrics11__moduleRefZ"] = (wasmExports["_D7handles13gizmo_metrics11__moduleRefZ"].value) >>> 0;
  __D7handles7arbiter11__moduleRefZ = Module["__D7handles7arbiter11__moduleRefZ"] = (wasmExports["_D7handles7arbiter11__moduleRefZ"].value) >>> 0;
  __D7handler11__moduleRefZ = Module["__D7handler11__moduleRefZ"] = (wasmExports["_D7handler11__moduleRefZ"].value) >>> 0;
  __D25guarded_action_controller11__moduleRefZ = Module["__D25guarded_action_controller11__moduleRefZ"] = (wasmExports["_D25guarded_action_controller11__moduleRefZ"].value) >>> 0;
  __D10gpu_select11__moduleRefZ = Module["__D10gpu_select11__moduleRefZ"] = (wasmExports["_D10gpu_select11__moduleRefZ"].value) >>> 0;
  __D15gl_thread_guard11__moduleRefZ = Module["__D15gl_thread_guard11__moduleRefZ"] = (wasmExports["_D15gl_thread_guard11__moduleRefZ"].value) >>> 0;
  __D5gizmo11__moduleRefZ = Module["__D5gizmo11__moduleRefZ"] = (wasmExports["_D5gizmo11__moduleRefZ"].value) >>> 0;
  __D18geometry_clipboard11__moduleRefZ = Module["__D18geometry_clipboard11__moduleRefZ"] = (wasmExports["_D18geometry_clipboard11__moduleRefZ"].value) >>> 0;
  __D11frame_stall11__moduleRefZ = Module["__D11frame_stall11__moduleRefZ"] = (wasmExports["_D11frame_stall11__moduleRefZ"].value) >>> 0;
  __D12frame_runner11__moduleRefZ = Module["__D12frame_runner11__moduleRefZ"] = (wasmExports["_D12frame_runner11__moduleRefZ"].value) >>> 0;
  __D12forms_render11__moduleRefZ = Module["__D12forms_render11__moduleRefZ"] = (wasmExports["_D12forms_render11__moduleRefZ"].value) >>> 0;
  __D5forms11__moduleRefZ = Module["__D5forms11__moduleRefZ"] = (wasmExports["_D5forms11__moduleRefZ"].value) >>> 0;
  __D20file_io_registration11__moduleRefZ = Module["__D20file_io_registration11__moduleRefZ"] = (wasmExports["_D20file_io_registration11__moduleRefZ"].value) >>> 0;
  __D14falloff_render11__moduleRefZ = Module["__D14falloff_render11__moduleRefZ"] = (wasmExports["_D14falloff_render11__moduleRefZ"].value) >>> 0;
  __D15falloff_handles11__moduleRefZ = Module["__D15falloff_handles11__moduleRefZ"] = (wasmExports["_D15falloff_handles11__moduleRefZ"].value) >>> 0;
  __D7falloff11__moduleRefZ = Module["__D7falloff11__moduleRefZ"] = (wasmExports["_D7falloff11__moduleRefZ"].value) >>> 0;
  __D8eventlog11__moduleRefZ = Module["__D8eventlog11__moduleRefZ"] = (wasmExports["_D8eventlog11__moduleRefZ"].value) >>> 0;
  __D10editor_app11__moduleRefZ = Module["__D10editor_app11__moduleRefZ"] = (wasmExports["_D10editor_app11__moduleRefZ"].value) >>> 0;
  __D8editmode11__moduleRefZ = Module["__D8editmode11__moduleRefZ"] = (wasmExports["_D8editmode11__moduleRefZ"].value) >>> 0;
  __D22edit_tool_registration11__moduleRefZ = Module["__D22edit_tool_registration11__moduleRefZ"] = (wasmExports["_D22edit_tool_registration11__moduleRefZ"].value) >>> 0;
  __D12edit_session11__moduleRefZ = Module["__D12edit_session11__moduleRefZ"] = (wasmExports["_D12edit_session11__moduleRefZ"].value) >>> 0;
  __D13drag_identity11__moduleRefZ = Module["__D13drag_identity11__moduleRefZ"] = (wasmExports["_D13drag_identity11__moduleRefZ"].value) >>> 0;
  __D4drag11__moduleRefZ = Module["__D4drag11__moduleRefZ"] = (wasmExports["_D4drag11__moduleRefZ"].value) >>> 0;
  __D18document_selection11__moduleRefZ = Module["__D18document_selection11__moduleRefZ"] = (wasmExports["_D18document_selection11__moduleRefZ"].value) >>> 0;
  __D8document11__moduleRefZ = Module["__D8document11__moduleRefZ"] = (wasmExports["_D8document11__moduleRefZ"].value) >>> 0;
  __D12display_sync11__moduleRefZ = Module["__D12display_sync11__moduleRefZ"] = (wasmExports["_D12display_sync11__moduleRefZ"].value) >>> 0;
  __D13display_state11__moduleRefZ = Module["__D13display_state11__moduleRefZ"] = (wasmExports["_D13display_state11__moduleRefZ"].value) >>> 0;
  __D13deform_magnet11__moduleRefZ = Module["__D13deform_magnet11__moduleRefZ"] = (wasmExports["_D13deform_magnet11__moduleRefZ"].value) >>> 0;
  __D24create_tool_registration11__moduleRefZ = Module["__D24create_tool_registration11__moduleRefZ"] = (wasmExports["_D24create_tool_registration11__moduleRefZ"].value) >>> 0;
  __D13copilot_panel11__moduleRefZ = Module["__D13copilot_panel11__moduleRefZ"] = (wasmExports["_D13copilot_panel11__moduleRefZ"].value) >>> 0;
  __D15copilot_overlay11__moduleRefZ = Module["__D15copilot_overlay11__moduleRefZ"] = (wasmExports["_D15copilot_overlay11__moduleRefZ"].value) >>> 0;
  __D28copilot_command_registration11__moduleRefZ = Module["__D28copilot_command_registration11__moduleRefZ"] = (wasmExports["_D28copilot_command_registration11__moduleRefZ"].value) >>> 0;
  __D14coord_rounding11__moduleRefZ = Module["__D14coord_rounding11__moduleRefZ"] = (wasmExports["_D14coord_rounding11__moduleRefZ"].value) >>> 0;
  __D10constraint11__moduleRefZ = Module["__D10constraint11__moduleRefZ"] = (wasmExports["_D10constraint11__moduleRefZ"].value) >>> 0;
  __D8commands9workplane11__moduleRefZ = Module["__D8commands9workplane11__moduleRefZ"] = (wasmExports["_D8commands9workplane11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport11view_preset11__moduleRefZ = Module["__D8commands8viewport11view_preset11__moduleRefZ"] = (wasmExports["_D8commands8viewport11view_preset11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport6master11__moduleRefZ = Module["__D8commands8viewport6master11__moduleRefZ"] = (wasmExports["_D8commands8viewport6master11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport13layout_preset11__moduleRefZ = Module["__D8commands8viewport13layout_preset11__moduleRefZ"] = (wasmExports["_D8commands8viewport13layout_preset11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport12independence11__moduleRefZ = Module["__D8commands8viewport12independence11__moduleRefZ"] = (wasmExports["_D8commands8viewport12independence11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport10grid_steps11__moduleRefZ = Module["__D8commands8viewport10grid_steps11__moduleRefZ"] = (wasmExports["_D8commands8viewport10grid_steps11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport12fit_selected11__moduleRefZ = Module["__D8commands8viewport12fit_selected11__moduleRefZ"] = (wasmExports["_D8commands8viewport12fit_selected11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport3fit11__moduleRefZ = Module["__D8commands8viewport3fit11__moduleRefZ"] = (wasmExports["_D8commands8viewport3fit11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport7display11__moduleRefZ = Module["__D8commands8viewport7display11__moduleRefZ"] = (wasmExports["_D8commands8viewport7display11__moduleRefZ"].value) >>> 0;
  __D8commands8viewport12command_base11__moduleRefZ = Module["__D8commands8viewport12command_base11__moduleRefZ"] = (wasmExports["_D8commands8viewport12command_base11__moduleRefZ"].value) >>> 0;
  __D8commands2ui14viewport_props11__moduleRefZ = Module["__D8commands2ui14viewport_props11__moduleRefZ"] = (wasmExports["_D8commands2ui14viewport_props11__moduleRefZ"].value) >>> 0;
  __D8commands2ui15tool_properties11__moduleRefZ = Module["__D8commands2ui15tool_properties11__moduleRefZ"] = (wasmExports["_D8commands2ui15tool_properties11__moduleRefZ"].value) >>> 0;
  __D8commands2ui10statistics11__moduleRefZ = Module["__D8commands2ui10statistics11__moduleRefZ"] = (wasmExports["_D8commands2ui10statistics11__moduleRefZ"].value) >>> 0;
  __D8commands2ui3pie11__moduleRefZ = Module["__D8commands2ui3pie11__moduleRefZ"] = (wasmExports["_D8commands2ui3pie11__moduleRefZ"].value) >>> 0;
  __D8commands2ui12layout_reset11__moduleRefZ = Module["__D8commands2ui12layout_reset11__moduleRefZ"] = (wasmExports["_D8commands2ui12layout_reset11__moduleRefZ"].value) >>> 0;
  __D8commands2ui10layer_list11__moduleRefZ = Module["__D8commands2ui10layer_list11__moduleRefZ"] = (wasmExports["_D8commands2ui10layer_list11__moduleRefZ"].value) >>> 0;
  __D8commands2ui10image_list11__moduleRefZ = Module["__D8commands2ui10image_list11__moduleRefZ"] = (wasmExports["_D8commands2ui10image_list11__moduleRefZ"].value) >>> 0;
  __D8commands2ui13copilot_panel11__moduleRefZ = Module["__D8commands2ui13copilot_panel11__moduleRefZ"] = (wasmExports["_D8commands2ui13copilot_panel11__moduleRefZ"].value) >>> 0;
  __D8commands2ui8channels11__moduleRefZ = Module["__D8commands2ui8channels11__moduleRefZ"] = (wasmExports["_D8commands2ui8channels11__moduleRefZ"].value) >>> 0;
  __D8commands2ui5about11__moduleRefZ = Module["__D8commands2ui5about11__moduleRefZ"] = (wasmExports["_D8commands2ui5about11__moduleRefZ"].value) >>> 0;
  __D8commands4tool3set11__moduleRefZ = Module["__D8commands4tool3set11__moduleRefZ"] = (wasmExports["_D8commands4tool3set11__moduleRefZ"].value) >>> 0;
  __D8commands4tool5reset11__moduleRefZ = Module["__D8commands4tool5reset11__moduleRefZ"] = (wasmExports["_D8commands4tool5reset11__moduleRefZ"].value) >>> 0;
  __D8commands4tool4pipe11__moduleRefZ = Module["__D8commands4tool4pipe11__moduleRefZ"] = (wasmExports["_D8commands4tool4pipe11__moduleRefZ"].value) >>> 0;
  __D8commands4tool10panel_edit11__moduleRefZ = Module["__D8commands4tool10panel_edit11__moduleRefZ"] = (wasmExports["_D8commands4tool10panel_edit11__moduleRefZ"].value) >>> 0;
  __D8commands4tool9lifecycle11__moduleRefZ = Module["__D8commands4tool9lifecycle11__moduleRefZ"] = (wasmExports["_D8commands4tool9lifecycle11__moduleRefZ"].value) >>> 0;
  __D8commands4tool4host11__moduleRefZ = Module["__D8commands4tool4host11__moduleRefZ"] = (wasmExports["_D8commands4tool4host11__moduleRefZ"].value) >>> 0;
  __D8commands4tool8headless11__moduleRefZ = Module["__D8commands4tool8headless11__moduleRefZ"] = (wasmExports["_D8commands4tool8headless11__moduleRefZ"].value) >>> 0;
  __D8commands4tool8do_apply11__moduleRefZ = Module["__D8commands4tool8do_apply11__moduleRefZ"] = (wasmExports["_D8commands4tool8do_apply11__moduleRefZ"].value) >>> 0;
  __D8commands4tool13begin_session11__moduleRefZ = Module["__D8commands4tool13begin_session11__moduleRefZ"] = (wasmExports["_D8commands4tool13begin_session11__moduleRefZ"].value) >>> 0;
  __D8commands4tool4attr11__moduleRefZ = Module["__D8commands4tool4attr11__moduleRefZ"] = (wasmExports["_D8commands4tool4attr11__moduleRefZ"].value) >>> 0;
  __D8commands15test_undo_flags11__moduleRefZ = Module["__D8commands15test_undo_flags11__moduleRefZ"] = (wasmExports["_D8commands15test_undo_flags11__moduleRefZ"].value) >>> 0;
  __D8commands8symmetry6toggle11__moduleRefZ = Module["__D8commands8symmetry6toggle11__moduleRefZ"] = (wasmExports["_D8commands8symmetry6toggle11__moduleRefZ"].value) >>> 0;
  __D8commands4snap11toggle_type11__moduleRefZ = Module["__D8commands4snap11toggle_type11__moduleRefZ"] = (wasmExports["_D8commands4snap11toggle_type11__moduleRefZ"].value) >>> 0;
  __D8commands4snap6toggle11__moduleRefZ = Module["__D8commands4snap6toggle11__moduleRefZ"] = (wasmExports["_D8commands4snap6toggle11__moduleRefZ"].value) >>> 0;
  __D8commands4snap4mode11__moduleRefZ = Module["__D8commands4snap4mode11__moduleRefZ"] = (wasmExports["_D8commands4snap4mode11__moduleRefZ"].value) >>> 0;
  __D8commands6select9type_from11__moduleRefZ = Module["__D8commands6select9type_from11__moduleRefZ"] = (wasmExports["_D8commands6select9type_from11__moduleRefZ"].value) >>> 0;
  __D8commands6select4sets11__moduleRefZ = Module["__D8commands6select4sets11__moduleRefZ"] = (wasmExports["_D8commands6select4sets11__moduleRefZ"].value) >>> 0;
  __D8commands6select4ring11__moduleRefZ = Module["__D8commands6select4ring11__moduleRefZ"] = (wasmExports["_D8commands6select4ring11__moduleRefZ"].value) >>> 0;
  __D8commands6select4more11__moduleRefZ = Module["__D8commands6select4more11__moduleRefZ"] = (wasmExports["_D8commands6select4more11__moduleRefZ"].value) >>> 0;
  __D8commands6select4loop11__moduleRefZ = Module["__D8commands6select4loop11__moduleRefZ"] = (wasmExports["_D8commands6select4loop11__moduleRefZ"].value) >>> 0;
  __D8commands6select4less11__moduleRefZ = Module["__D8commands6select4less11__moduleRefZ"] = (wasmExports["_D8commands6select4less11__moduleRefZ"].value) >>> 0;
  __D8commands6select6invert11__moduleRefZ = Module["__D8commands6select6invert11__moduleRefZ"] = (wasmExports["_D8commands6select6invert11__moduleRefZ"].value) >>> 0;
  __D8commands6select4fill11__moduleRefZ = Module["__D8commands6select4fill11__moduleRefZ"] = (wasmExports["_D8commands6select4fill11__moduleRefZ"].value) >>> 0;
  __D8commands6select6expand11__moduleRefZ = Module["__D8commands6select6expand11__moduleRefZ"] = (wasmExports["_D8commands6select6expand11__moduleRefZ"].value) >>> 0;
  __D8commands6select7element11__moduleRefZ = Module["__D8commands6select7element11__moduleRefZ"] = (wasmExports["_D8commands6select7element11__moduleRefZ"].value) >>> 0;
  __D8commands6select4drop11__moduleRefZ = Module["__D8commands6select4drop11__moduleRefZ"] = (wasmExports["_D8commands6select4drop11__moduleRefZ"].value) >>> 0;
  __D8commands6select7convert11__moduleRefZ = Module["__D8commands6select7convert11__moduleRefZ"] = (wasmExports["_D8commands6select7convert11__moduleRefZ"].value) >>> 0;
  __D8commands6select8contract11__moduleRefZ = Module["__D8commands6select8contract11__moduleRefZ"] = (wasmExports["_D8commands6select8contract11__moduleRefZ"].value) >>> 0;
  __D8commands6select7connect11__moduleRefZ = Module["__D8commands6select7connect11__moduleRefZ"] = (wasmExports["_D8commands6select7connect11__moduleRefZ"].value) >>> 0;
  __D8commands6select6by_tag11__moduleRefZ = Module["__D8commands6select6by_tag11__moduleRefZ"] = (wasmExports["_D8commands6select6by_tag11__moduleRefZ"].value) >>> 0;
  __D8commands6select7by_stat11__moduleRefZ = Module["__D8commands6select7by_stat11__moduleRefZ"] = (wasmExports["_D8commands6select7by_stat11__moduleRefZ"].value) >>> 0;
  __D8commands6select8boundary11__moduleRefZ = Module["__D8commands6select8boundary11__moduleRefZ"] = (wasmExports["_D8commands6select8boundary11__moduleRefZ"].value) >>> 0;
  __D8commands6select7between11__moduleRefZ = Module["__D8commands6select7between11__moduleRefZ"] = (wasmExports["_D8commands6select7between11__moduleRefZ"].value) >>> 0;
  __D8commands5scene5reset11__moduleRefZ = Module["__D8commands5scene5reset11__moduleRefZ"] = (wasmExports["_D8commands5scene5reset11__moduleRefZ"].value) >>> 0;
  __D8commands5scene9load_mesh11__moduleRefZ = Module["__D8commands5scene9load_mesh11__moduleRefZ"] = (wasmExports["_D8commands5scene9load_mesh11__moduleRefZ"].value) >>> 0;
  __D8commands5prefs9trackball11__moduleRefZ = Module["__D8commands5prefs9trackball11__moduleRefZ"] = (wasmExports["_D8commands5prefs9trackball11__moduleRefZ"].value) >>> 0;
  __D8commands5prefs14coord_rounding11__moduleRefZ = Module["__D8commands5prefs14coord_rounding11__moduleRefZ"] = (wasmExports["_D8commands5prefs14coord_rounding11__moduleRefZ"].value) >>> 0;
  __D8commands4path6define11__moduleRefZ = Module["__D8commands4path6define11__moduleRefZ"] = (wasmExports["_D8commands4path6define11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh16weld_vertex_pair11__moduleRefZ = Module["__D8commands4mesh16weld_vertex_pair11__moduleRefZ"] = (wasmExports["_D8commands4mesh16weld_vertex_pair11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9weightmap11__moduleRefZ = Module["__D8commands4mesh9weightmap11__moduleRefZ"] = (wasmExports["_D8commands4mesh9weightmap11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12vertex_split11__moduleRefZ = Module["__D8commands4mesh12vertex_split11__moduleRefZ"] = (wasmExports["_D8commands4mesh12vertex_split11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10vertex_set11__moduleRefZ = Module["__D8commands4mesh10vertex_set11__moduleRefZ"] = (wasmExports["_D8commands4mesh10vertex_set11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh22vertex_position_result11__moduleRefZ = Module["__D8commands4mesh22vertex_position_result11__moduleRefZ"] = (wasmExports["_D8commands4mesh22vertex_position_result11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10vertex_new11__moduleRefZ = Module["__D8commands4mesh10vertex_new11__moduleRefZ"] = (wasmExports["_D8commands4mesh10vertex_new11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh14vertex_extrude11__moduleRefZ = Module["__D8commands4mesh14vertex_extrude11__moduleRefZ"] = (wasmExports["_D8commands4mesh14vertex_extrude11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh11vertex_edit11__moduleRefZ = Module["__D8commands4mesh11vertex_edit11__moduleRefZ"] = (wasmExports["_D8commands4mesh11vertex_edit11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh13vertex_center11__moduleRefZ = Module["__D8commands4mesh13vertex_center11__moduleRefZ"] = (wasmExports["_D8commands4mesh13vertex_center11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12vertex_bevel11__moduleRefZ = Module["__D8commands4mesh12vertex_bevel11__moduleRefZ"] = (wasmExports["_D8commands4mesh12vertex_bevel11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10vert_merge11__moduleRefZ = Module["__D8commands4mesh10vert_merge11__moduleRefZ"] = (wasmExports["_D8commands4mesh10vert_merge11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9vert_join11__moduleRefZ = Module["__D8commands4mesh9vert_join11__moduleRefZ"] = (wasmExports["_D8commands4mesh9vert_join11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9uv_unwrap11__moduleRefZ = Module["__D8commands4mesh9uv_unwrap11__moduleRefZ"] = (wasmExports["_D8commands4mesh9uv_unwrap11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12uv_transform11__moduleRefZ = Module["__D8commands4mesh12uv_transform11__moduleRefZ"] = (wasmExports["_D8commands4mesh12uv_transform11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh8uv_relax11__moduleRefZ = Module["__D8commands4mesh8uv_relax11__moduleRefZ"] = (wasmExports["_D8commands4mesh8uv_relax11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10uv_project11__moduleRefZ = Module["__D8commands4mesh10uv_project11__moduleRefZ"] = (wasmExports["_D8commands4mesh10uv_project11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh7uv_pack11__moduleRefZ = Module["__D8commands4mesh7uv_pack11__moduleRefZ"] = (wasmExports["_D8commands4mesh7uv_pack11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh11uv_map_util11__moduleRefZ = Module["__D8commands4mesh11uv_map_util11__moduleRefZ"] = (wasmExports["_D8commands4mesh11uv_map_util11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh5unify11__moduleRefZ = Module["__D8commands4mesh5unify11__moduleRefZ"] = (wasmExports["_D8commands4mesh5unify11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6triple11__moduleRefZ = Module["__D8commands4mesh6triple11__moduleRefZ"] = (wasmExports["_D8commands4mesh6triple11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9transform11__moduleRefZ = Module["__D8commands4mesh9transform11__moduleRefZ"] = (wasmExports["_D8commands4mesh9transform11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh7thicken11__moduleRefZ = Module["__D8commands4mesh7thicken11__moduleRefZ"] = (wasmExports["_D8commands4mesh7thicken11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10symmetrize11__moduleRefZ = Module["__D8commands4mesh10symmetrize11__moduleRefZ"] = (wasmExports["_D8commands4mesh10symmetrize11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh5sweep11__moduleRefZ = Module["__D8commands4mesh5sweep11__moduleRefZ"] = (wasmExports["_D8commands4mesh5sweep11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh15subpatch_toggle11__moduleRefZ = Module["__D8commands4mesh15subpatch_toggle11__moduleRefZ"] = (wasmExports["_D8commands4mesh15subpatch_toggle11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh17subdivide_faceted11__moduleRefZ = Module["__D8commands4mesh17subdivide_faceted11__moduleRefZ"] = (wasmExports["_D8commands4mesh17subdivide_faceted11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9subdivide11__moduleRefZ = Module["__D8commands4mesh9subdivide11__moduleRefZ"] = (wasmExports["_D8commands4mesh9subdivide11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh14stroke_extrude11__moduleRefZ = Module["__D8commands4mesh14stroke_extrude11__moduleRefZ"] = (wasmExports["_D8commands4mesh14stroke_extrude11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10split_face11__moduleRefZ = Module["__D8commands4mesh10split_face11__moduleRefZ"] = (wasmExports["_D8commands4mesh10split_face11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10split_edge11__moduleRefZ = Module["__D8commands4mesh10split_edge11__moduleRefZ"] = (wasmExports["_D8commands4mesh10split_edge11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9spin_edge11__moduleRefZ = Module["__D8commands4mesh9spin_edge11__moduleRefZ"] = (wasmExports["_D8commands4mesh9spin_edge11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6spikey11__moduleRefZ = Module["__D8commands4mesh6spikey11__moduleRefZ"] = (wasmExports["_D8commands4mesh6spikey11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12smooth_shift11__moduleRefZ = Module["__D8commands4mesh12smooth_shift11__moduleRefZ"] = (wasmExports["_D8commands4mesh12smooth_shift11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6smooth11__moduleRefZ = Module["__D8commands4mesh6smooth11__moduleRefZ"] = (wasmExports["_D8commands4mesh6smooth11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh8set_part11__moduleRefZ = Module["__D8commands4mesh8set_part11__moduleRefZ"] = (wasmExports["_D8commands4mesh8set_part11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12set_material11__moduleRefZ = Module["__D8commands4mesh12set_material11__moduleRefZ"] = (wasmExports["_D8commands4mesh12set_material11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12session_edit11__moduleRefZ = Module["__D8commands4mesh12session_edit11__moduleRefZ"] = (wasmExports["_D8commands4mesh12session_edit11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh14selection_undo11__moduleRefZ = Module["__D8commands4mesh14selection_undo11__moduleRefZ"] = (wasmExports["_D8commands4mesh14selection_undo11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh14selection_edit11__moduleRefZ = Module["__D8commands4mesh14selection_edit11__moduleRefZ"] = (wasmExports["_D8commands4mesh14selection_edit11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6select11__moduleRefZ = Module["__D8commands4mesh6select11__moduleRefZ"] = (wasmExports["_D8commands4mesh6select11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12screen_slice11__moduleRefZ = Module["__D8commands4mesh12screen_slice11__moduleRefZ"] = (wasmExports["_D8commands4mesh12screen_slice11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh7remove_11__moduleRefZ = Module["__D8commands4mesh7remove_11__moduleRefZ"] = (wasmExports["_D8commands4mesh7remove_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6remesh11__moduleRefZ = Module["__D8commands4mesh6remesh11__moduleRefZ"] = (wasmExports["_D8commands4mesh6remesh11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6reduce11__moduleRefZ = Module["__D8commands4mesh6reduce11__moduleRefZ"] = (wasmExports["_D8commands4mesh6reduce11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh13radial_array_11__moduleRefZ = Module["__D8commands4mesh13radial_array_11__moduleRefZ"] = (wasmExports["_D8commands4mesh13radial_array_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12radial_align11__moduleRefZ = Module["__D8commands4mesh12radial_align11__moduleRefZ"] = (wasmExports["_D8commands4mesh12radial_align11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh8quantize11__moduleRefZ = Module["__D8commands4mesh8quantize11__moduleRefZ"] = (wasmExports["_D8commands4mesh8quantize11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9quadruple11__moduleRefZ = Module["__D8commands4mesh9quadruple11__moduleRefZ"] = (wasmExports["_D8commands4mesh9quadruple11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh13position_undo11__moduleRefZ = Module["__D8commands4mesh13position_undo11__moduleRefZ"] = (wasmExports["_D8commands4mesh13position_undo11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh13polygon_align11__moduleRefZ = Module["__D8commands4mesh13polygon_align11__moduleRefZ"] = (wasmExports["_D8commands4mesh13polygon_align11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10poly_inset11__moduleRefZ = Module["__D8commands4mesh10poly_inset11__moduleRefZ"] = (wasmExports["_D8commands4mesh10poly_inset11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6paste_11__moduleRefZ = Module["__D8commands4mesh6paste_11__moduleRefZ"] = (wasmExports["_D8commands4mesh6paste_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh11move_vertex11__moduleRefZ = Module["__D8commands4mesh11move_vertex11__moduleRefZ"] = (wasmExports["_D8commands4mesh11move_vertex11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10morph_edit11__moduleRefZ = Module["__D8commands4mesh10morph_edit11__moduleRefZ"] = (wasmExports["_D8commands4mesh10morph_edit11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh5morph11__moduleRefZ = Module["__D8commands4mesh5morph11__moduleRefZ"] = (wasmExports["_D8commands4mesh5morph11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh7mirror_11__moduleRefZ = Module["__D8commands4mesh7mirror_11__moduleRefZ"] = (wasmExports["_D8commands4mesh7mirror_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh5merge11__moduleRefZ = Module["__D8commands4mesh5merge11__moduleRefZ"] = (wasmExports["_D8commands4mesh5merge11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh13map_edit_undo11__moduleRefZ = Module["__D8commands4mesh13map_edit_undo11__moduleRefZ"] = (wasmExports["_D8commands4mesh13map_edit_undo11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12make_polygon11__moduleRefZ = Module["__D8commands4mesh12make_polygon11__moduleRefZ"] = (wasmExports["_D8commands4mesh12make_polygon11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6magnet11__moduleRefZ = Module["__D8commands4mesh6magnet11__moduleRefZ"] = (wasmExports["_D8commands4mesh6magnet11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10loop_slice11__moduleRefZ = Module["__D8commands4mesh10loop_slice11__moduleRefZ"] = (wasmExports["_D8commands4mesh10loop_slice11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12linear_align11__moduleRefZ = Module["__D8commands4mesh12linear_align11__moduleRefZ"] = (wasmExports["_D8commands4mesh12linear_align11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6jitter11__moduleRefZ = Module["__D8commands4mesh6jitter11__moduleRefZ"] = (wasmExports["_D8commands4mesh6jitter11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh4hide11__moduleRefZ = Module["__D8commands4mesh4hide11__moduleRefZ"] = (wasmExports["_D8commands4mesh4hide11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh15gesture_payload11__moduleRefZ = Module["__D8commands4mesh15gesture_payload11__moduleRefZ"] = (wasmExports["_D8commands4mesh15gesture_payload11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh4flip11__moduleRefZ = Module["__D8commands4mesh4flip11__moduleRefZ"] = (wasmExports["_D8commands4mesh4flip11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh15fix_orientation11__moduleRefZ = Module["__D8commands4mesh15fix_orientation11__moduleRefZ"] = (wasmExports["_D8commands4mesh15fix_orientation11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12face_extrude11__moduleRefZ = Module["__D8commands4mesh12face_extrude11__moduleRefZ"] = (wasmExports["_D8commands4mesh12face_extrude11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10edge_slide11__moduleRefZ = Module["__D8commands4mesh10edge_slide11__moduleRefZ"] = (wasmExports["_D8commands4mesh10edge_slide11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10edge_slice11__moduleRefZ = Module["__D8commands4mesh10edge_slice11__moduleRefZ"] = (wasmExports["_D8commands4mesh10edge_slice11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9edge_join11__moduleRefZ = Module["__D8commands4mesh9edge_join11__moduleRefZ"] = (wasmExports["_D8commands4mesh9edge_join11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh12edge_extrude11__moduleRefZ = Module["__D8commands4mesh12edge_extrude11__moduleRefZ"] = (wasmExports["_D8commands4mesh12edge_extrude11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh11edge_extend11__moduleRefZ = Module["__D8commands4mesh11edge_extend11__moduleRefZ"] = (wasmExports["_D8commands4mesh11edge_extend11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh11edge_crease11__moduleRefZ = Module["__D8commands4mesh11edge_crease11__moduleRefZ"] = (wasmExports["_D8commands4mesh11edge_crease11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10duplicate_11__moduleRefZ = Module["__D8commands4mesh10duplicate_11__moduleRefZ"] = (wasmExports["_D8commands4mesh10duplicate_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh13detriangulate11__moduleRefZ = Module["__D8commands4mesh13detriangulate11__moduleRefZ"] = (wasmExports["_D8commands4mesh13detriangulate11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh7delete_11__moduleRefZ = Module["__D8commands4mesh7delete_11__moduleRefZ"] = (wasmExports["_D8commands4mesh7delete_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh4cut_11__moduleRefZ = Module["__D8commands4mesh4cut_11__moduleRefZ"] = (wasmExports["_D8commands4mesh4cut_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh5copy_11__moduleRefZ = Module["__D8commands4mesh5copy_11__moduleRefZ"] = (wasmExports["_D8commands4mesh5copy_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh8collapse11__moduleRefZ = Module["__D8commands4mesh8collapse11__moduleRefZ"] = (wasmExports["_D8commands4mesh8collapse11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6clone_11__moduleRefZ = Module["__D8commands4mesh6clone_11__moduleRefZ"] = (wasmExports["_D8commands4mesh6clone_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh7cleanup11__moduleRefZ = Module["__D8commands4mesh7cleanup11__moduleRefZ"] = (wasmExports["_D8commands4mesh7cleanup11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6bridge11__moduleRefZ = Module["__D8commands4mesh6bridge11__moduleRefZ"] = (wasmExports["_D8commands4mesh6bridge11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh5bevel11__moduleRefZ = Module["__D8commands4mesh5bevel11__moduleRefZ"] = (wasmExports["_D8commands4mesh5bevel11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh10axis_slice11__moduleRefZ = Module["__D8commands4mesh10axis_slice11__moduleRefZ"] = (wasmExports["_D8commands4mesh10axis_slice11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh6array_11__moduleRefZ = Module["__D8commands4mesh6array_11__moduleRefZ"] = (wasmExports["_D8commands4mesh6array_11__moduleRefZ"].value) >>> 0;
  __D8commands4mesh9add_point11__moduleRefZ = Module["__D8commands4mesh9add_point11__moduleRefZ"] = (wasmExports["_D8commands4mesh9add_point11__moduleRefZ"].value) >>> 0;
  __D8commands6macros13save_recorded11__moduleRefZ = Module["__D8commands6macros13save_recorded11__moduleRefZ"] = (wasmExports["_D8commands6macros13save_recorded11__moduleRefZ"].value) >>> 0;
  __D8commands6macros6record11__moduleRefZ = Module["__D8commands6macros6record11__moduleRefZ"] = (wasmExports["_D8commands6macros6record11__moduleRefZ"].value) >>> 0;
  __D8commands5layer10xform_edit11__moduleRefZ = Module["__D8commands5layer10xform_edit11__moduleRefZ"] = (wasmExports["_D8commands5layer10xform_edit11__moduleRefZ"].value) >>> 0;
  __D8commands5layerQp11__moduleRefZ = Module["__D8commands5layerQp11__moduleRefZ"] = (wasmExports["_D8commands5layerQp11__moduleRefZ"].value) >>> 0;
  __D8commands11image_planeQw11__moduleRefZ = Module["__D8commands11image_planeQw11__moduleRefZ"] = (wasmExports["_D8commands11image_planeQw11__moduleRefZ"].value) >>> 0;
  __D8commands5imageQp11__moduleRefZ = Module["__D8commands5imageQp11__moduleRefZ"] = (wasmExports["_D8commands5imageQp11__moduleRefZ"].value) >>> 0;
  __D8commands7history4undo11__moduleRefZ = Module["__D8commands7history4undo11__moduleRefZ"] = (wasmExports["_D8commands7history4undo11__moduleRefZ"].value) >>> 0;
  __D8commands7history4show11__moduleRefZ = Module["__D8commands7history4show11__moduleRefZ"] = (wasmExports["_D8commands7history4show11__moduleRefZ"].value) >>> 0;
  __D8commands7history14save_as_script11__moduleRefZ = Module["__D8commands7history14save_as_script11__moduleRefZ"] = (wasmExports["_D8commands7history14save_as_script11__moduleRefZ"].value) >>> 0;
  __D8commands7history4redo11__moduleRefZ = Module["__D8commands7history4redo11__moduleRefZ"] = (wasmExports["_D8commands7history4redo11__moduleRefZ"].value) >>> 0;
  __D8commands7history5clear11__moduleRefZ = Module["__D8commands7history5clear11__moduleRefZ"] = (wasmExports["_D8commands7history5clear11__moduleRefZ"].value) >>> 0;
  __D8commands4file4save11__moduleRefZ = Module["__D8commands4file4save11__moduleRefZ"] = (wasmExports["_D8commands4file4save11__moduleRefZ"].value) >>> 0;
  __D8commands4file4quit11__moduleRefZ = Module["__D8commands4file4quit11__moduleRefZ"] = (wasmExports["_D8commands4file4quit11__moduleRefZ"].value) >>> 0;
  __D8commands4file4load11__moduleRefZ = Module["__D8commands4file4load11__moduleRefZ"] = (wasmExports["_D8commands4file4load11__moduleRefZ"].value) >>> 0;
  __D8commands7falloff11__moduleRefZ = Module["__D8commands7falloff11__moduleRefZ"] = (wasmExports["_D8commands7falloff11__moduleRefZ"].value) >>> 0;
  __D8commands7copilot14select_finding11__moduleRefZ = Module["__D8commands7copilot14select_finding11__moduleRefZ"] = (wasmExports["_D8commands7copilot14select_finding11__moduleRefZ"].value) >>> 0;
  __D8commands7copilot13cycle_finding11__moduleRefZ = Module["__D8commands7copilot13cycle_finding11__moduleRefZ"] = (wasmExports["_D8commands7copilot13cycle_finding11__moduleRefZ"].value) >>> 0;
  __D8commands7copilot7analyze11__moduleRefZ = Module["__D8commands7copilot7analyze11__moduleRefZ"] = (wasmExports["_D8commands7copilot7analyze11__moduleRefZ"].value) >>> 0;
  __D8commands9constrain6toggle11__moduleRefZ = Module["__D8commands9constrain6toggle11__moduleRefZ"] = (wasmExports["_D8commands9constrain6toggle11__moduleRefZ"].value) >>> 0;
  __D8commands4ai3d13import_result11__moduleRefZ = Module["__D8commands4ai3d13import_result11__moduleRefZ"] = (wasmExports["_D8commands4ai3d13import_result11__moduleRefZ"].value) >>> 0;
  __D8commands4ai3d13generate_open11__moduleRefZ = Module["__D8commands4ai3d13generate_open11__moduleRefZ"] = (wasmExports["_D8commands4ai3d13generate_open11__moduleRefZ"].value) >>> 0;
  __D8commands2ai6toggle11__moduleRefZ = Module["__D8commands2ai6toggle11__moduleRefZ"] = (wasmExports["_D8commands2ai6toggle11__moduleRefZ"].value) >>> 0;
  __D8commands4actr11__moduleRefZ = Module["__D8commands4actr11__moduleRefZ"] = (wasmExports["_D8commands4actr11__moduleRefZ"].value) >>> 0;
  __D15command_history11__moduleRefZ = Module["__D15command_history11__moduleRefZ"] = (wasmExports["_D15command_history11__moduleRefZ"].value) >>> 0;
  __D16command_executor11__moduleRefZ = Module["__D16command_executor11__moduleRefZ"] = (wasmExports["_D16command_executor11__moduleRefZ"].value) >>> 0;
  __D12command_args11__moduleRefZ = Module["__D12command_args11__moduleRefZ"] = (wasmExports["_D12command_args11__moduleRefZ"].value) >>> 0;
  __D7command11__moduleRefZ = Module["__D7command11__moduleRefZ"] = (wasmExports["_D7command11__moduleRefZ"].value) >>> 0;
  __D10change_bus11__moduleRefZ = Module["__D10change_bus11__moduleRefZ"] = (wasmExports["_D10change_bus11__moduleRefZ"].value) >>> 0;
  __D12camera_stamp11__moduleRefZ = Module["__D12camera_stamp11__moduleRefZ"] = (wasmExports["_D12camera_stamp11__moduleRefZ"].value) >>> 0;
  __D8bvh_pick11__moduleRefZ = Module["__D8bvh_pick11__moduleRefZ"] = (wasmExports["_D8bvh_pick11__moduleRefZ"].value) >>> 0;
  __D9buttonset11__moduleRefZ = Module["__D9buttonset11__moduleRefZ"] = (wasmExports["_D9buttonset11__moduleRefZ"].value) >>> 0;
  __D12bg_gpu_cache11__moduleRefZ = Module["__D12bg_gpu_cache11__moduleRefZ"] = (wasmExports["_D12bg_gpu_cache11__moduleRefZ"].value) >>> 0;
  __D9argstring11__moduleRefZ = Module["__D9argstring11__moduleRefZ"] = (wasmExports["_D9argstring11__moduleRefZ"].value) >>> 0;
  __D11args_dialog11__moduleRefZ = Module["__D11args_dialog11__moduleRefZ"] = (wasmExports["_D11args_dialog11__moduleRefZ"].value) >>> 0;
  __D27application_command_binding11__moduleRefZ = Module["__D27application_command_binding11__moduleRefZ"] = (wasmExports["_D27application_command_binding11__moduleRefZ"].value) >>> 0;
  __D11app_version11__moduleRefZ = Module["__D11app_version11__moduleRefZ"] = (wasmExports["_D11app_version11__moduleRefZ"].value) >>> 0;
  __D3app11__moduleRefZ = Module["__D3app11__moduleRefZ"] = (wasmExports["_D3app11__moduleRefZ"].value) >>> 0;
  __D23ai_command_registration11__moduleRefZ = Module["__D23ai_command_registration11__moduleRefZ"] = (wasmExports["_D23ai_command_registration11__moduleRefZ"].value) >>> 0;
  __D4ai3d15scene_validator11__moduleRefZ = Module["__D4ai3d15scene_validator11__moduleRefZ"] = (wasmExports["_D4ai3d15scene_validator11__moduleRefZ"].value) >>> 0;
  __D4ai3d10job_events11__moduleRefZ = Module["__D4ai3d10job_events11__moduleRefZ"] = (wasmExports["_D4ai3d10job_events11__moduleRefZ"].value) >>> 0;
  __D4ai3d11event_queue11__moduleRefZ = Module["__D4ai3d11event_queue11__moduleRefZ"] = (wasmExports["_D4ai3d11event_queue11__moduleRefZ"].value) >>> 0;
  __D2ai16training_dataset11__moduleRefZ = Module["__D2ai16training_dataset11__moduleRefZ"] = (wasmExports["_D2ai16training_dataset11__moduleRefZ"].value) >>> 0;
  __D2ai17synthetic_dataset11__moduleRefZ = Module["__D2ai17synthetic_dataset11__moduleRefZ"] = (wasmExports["_D2ai17synthetic_dataset11__moduleRefZ"].value) >>> 0;
  __D2ai23support_loop_candidates11__moduleRefZ = Module["__D2ai23support_loop_candidates11__moduleRefZ"] = (wasmExports["_D2ai23support_loop_candidates11__moduleRefZ"].value) >>> 0;
  __D2ai5state11__moduleRefZ = Module["__D2ai5state11__moduleRefZ"] = (wasmExports["_D2ai5state11__moduleRefZ"].value) >>> 0;
  __D2ai13ranker_schema11__moduleRefZ = Module["__D2ai13ranker_schema11__moduleRefZ"] = (wasmExports["_D2ai13ranker_schema11__moduleRefZ"].value) >>> 0;
  __D2ai12onnx_backend11__moduleRefZ = Module["__D2ai12onnx_backend11__moduleRefZ"] = (wasmExports["_D2ai12onnx_backend11__moduleRefZ"].value) >>> 0;
  __D2ai17offline_evaluator11__moduleRefZ = Module["__D2ai17offline_evaluator11__moduleRefZ"] = (wasmExports["_D2ai17offline_evaluator11__moduleRefZ"].value) >>> 0;
  __D2ai13model_adapter11__moduleRefZ = Module["__D2ai13model_adapter11__moduleRefZ"] = (wasmExports["_D2ai13model_adapter11__moduleRefZ"].value) >>> 0;
  __D2ai15mode_candidates11__moduleRefZ = Module["__D2ai15mode_candidates11__moduleRefZ"] = (wasmExports["_D2ai15mode_candidates11__moduleRefZ"].value) >>> 0;
  __D2ai22interaction_log_writer11__moduleRefZ = Module["__D2ai22interaction_log_writer11__moduleRefZ"] = (wasmExports["_D2ai22interaction_log_writer11__moduleRefZ"].value) >>> 0;
  __D2ai15interaction_log11__moduleRefZ = Module["__D2ai15interaction_log11__moduleRefZ"] = (wasmExports["_D2ai15interaction_log11__moduleRefZ"].value) >>> 0;
  __D2ai11interaction11__moduleRefZ = Module["__D2ai11interaction11__moduleRefZ"] = (wasmExports["_D2ai11interaction11__moduleRefZ"].value) >>> 0;
  __D2ai11exploration11__moduleRefZ = Module["__D2ai11exploration11__moduleRefZ"] = (wasmExports["_D2ai11exploration11__moduleRefZ"].value) >>> 0;
  __D2ai18element_candidates11__moduleRefZ = Module["__D2ai18element_candidates11__moduleRefZ"] = (wasmExports["_D2ai18element_candidates11__moduleRefZ"].value) >>> 0;
  __D2ai11debug_trace11__moduleRefZ = Module["__D2ai11debug_trace11__moduleRefZ"] = (wasmExports["_D2ai11debug_trace11__moduleRefZ"].value) >>> 0;
  __D2ai12copilot_gate11__moduleRefZ = Module["__D2ai12copilot_gate11__moduleRefZ"] = (wasmExports["_D2ai12copilot_gate11__moduleRefZ"].value) >>> 0;
  __D2ai8analysis11__moduleRefZ = Module["__D2ai8analysis11__moduleRefZ"] = (wasmExports["_D2ai8analysis11__moduleRefZ"].value) >>> 0;
  __D2ai7advisor11__moduleRefZ = Module["__D2ai7advisor11__moduleRefZ"] = (wasmExports["_D2ai7advisor11__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind3arb7core_3011__moduleRefZ = Module["__D6bindbc6opengl4bind3arb7core_3011__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind3arb7core_3011__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind3arb7core_3111__moduleRefZ = Module["__D6bindbc6opengl4bind3arb7core_3111__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind3arb7core_3111__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind3arb7core_3311__moduleRefZ = Module["__D6bindbc6opengl4bind3arb7core_3311__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind3arb7core_3311__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl1111__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1111__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl1111__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl1311__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1311__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl1311__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl1411__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1411__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl1411__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl1511__moduleRefZ = Module["__D6bindbc6opengl4bind4gl1511__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl1511__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl2011__moduleRefZ = Module["__D6bindbc6opengl4bind4gl2011__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl2011__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl3011__moduleRefZ = Module["__D6bindbc6opengl4bind4gl3011__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl3011__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl3111__moduleRefZ = Module["__D6bindbc6opengl4bind4gl3111__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl3111__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl4bind4gl3311__moduleRefZ = Module["__D6bindbc6opengl4bind4gl3311__moduleRefZ"] = (wasmExports["_D6bindbc6opengl4bind4gl3311__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl7context11__moduleRefZ = Module["__D6bindbc6opengl7context11__moduleRefZ"] = (wasmExports["_D6bindbc6opengl7context11__moduleRefZ"].value) >>> 0;
  __D6bindbc6opengl11__moduleRefZ = Module["__D6bindbc6opengl11__moduleRefZ"] = (wasmExports["_D6bindbc6opengl11__moduleRefZ"].value) >>> 0;
  __D6bindbc6loader7codegen11__moduleRefZ = Module["__D6bindbc6loader7codegen11__moduleRefZ"] = (wasmExports["_D6bindbc6loader7codegen11__moduleRefZ"].value) >>> 0;
  __D6bindbc6loader9sharedlib11__moduleRefZ = Module["__D6bindbc6loader9sharedlib11__moduleRefZ"] = (wasmExports["_D6bindbc6loader9sharedlib11__moduleRefZ"].value) >>> 0;
  __D3bvh1c11__moduleRefZ = Module["__D3bvh1c11__moduleRefZ"] = (wasmExports["_D3bvh1c11__moduleRefZ"].value) >>> 0;
  __D3osd1c11__moduleRefZ = Module["__D3osd1c11__moduleRefZ"] = (wasmExports["_D3osd1c11__moduleRefZ"].value) >>> 0;
  __D9stb_image1c11__moduleRefZ = Module["__D9stb_image1c11__moduleRefZ"] = (wasmExports["_D9stb_image1c11__moduleRefZ"].value) >>> 0;
  __D7d_imgui12imgui_cimgui11__moduleRefZ = Module["__D7d_imgui12imgui_cimgui11__moduleRefZ"] = (wasmExports["_D7d_imgui12imgui_cimgui11__moduleRefZ"].value) >>> 0;
  __D7d_imgui7imgui_h11__moduleRefZ = Module["__D7d_imgui7imgui_h11__moduleRefZ"] = (wasmExports["_D7d_imgui7imgui_h11__moduleRefZ"].value) >>> 0;
  __D7d_imgui11__moduleRefZ = Module["__D7d_imgui11__moduleRefZ"] = (wasmExports["_D7d_imgui11__moduleRefZ"].value) >>> 0;
  __D18imgui_impl_opengl311__moduleRefZ = Module["__D18imgui_impl_opengl311__moduleRefZ"] = (wasmExports["_D18imgui_impl_opengl311__moduleRefZ"].value) >>> 0;
  __D15imgui_impl_sdl211__moduleRefZ = Module["__D15imgui_impl_sdl211__moduleRefZ"] = (wasmExports["_D15imgui_impl_sdl211__moduleRefZ"].value) >>> 0;
  __D6bindbc3sdl6config11__moduleRefZ = Module["__D6bindbc3sdl6config11__moduleRefZ"] = (wasmExports["_D6bindbc3sdl6config11__moduleRefZ"].value) >>> 0;
  __D6bindbc3sdl11__moduleRefZ = Module["__D6bindbc3sdl11__moduleRefZ"] = (wasmExports["_D6bindbc3sdl11__moduleRefZ"].value) >>> 0;
  __D3sdl6stdinc11__moduleRefZ = Module["__D3sdl6stdinc11__moduleRefZ"] = (wasmExports["_D3sdl6stdinc11__moduleRefZ"].value) >>> 0;
  __D6bindbc6common7codegen11__moduleRefZ = Module["__D6bindbc6common7codegen11__moduleRefZ"] = (wasmExports["_D6bindbc6common7codegen11__moduleRefZ"].value) >>> 0;
  __D5dyaml8composer11__moduleRefZ = Module["__D5dyaml8composer11__moduleRefZ"] = (wasmExports["_D5dyaml8composer11__moduleRefZ"].value) >>> 0;
  __D5dyaml11constructor11__moduleRefZ = Module["__D5dyaml11constructor11__moduleRefZ"] = (wasmExports["_D5dyaml11constructor11__moduleRefZ"].value) >>> 0;
  __D5dyaml6dumper11__moduleRefZ = Module["__D5dyaml6dumper11__moduleRefZ"] = (wasmExports["_D5dyaml6dumper11__moduleRefZ"].value) >>> 0;
  __D5dyaml7emitter11__moduleRefZ = Module["__D5dyaml7emitter11__moduleRefZ"] = (wasmExports["_D5dyaml7emitter11__moduleRefZ"].value) >>> 0;
  __D5dyaml7escapes11__moduleRefZ = Module["__D5dyaml7escapes11__moduleRefZ"] = (wasmExports["_D5dyaml7escapes11__moduleRefZ"].value) >>> 0;
  __D5dyaml5event11__moduleRefZ = Module["__D5dyaml5event11__moduleRefZ"] = (wasmExports["_D5dyaml5event11__moduleRefZ"].value) >>> 0;
  __D5dyaml9exception11__moduleRefZ = Module["__D5dyaml9exception11__moduleRefZ"] = (wasmExports["_D5dyaml9exception11__moduleRefZ"].value) >>> 0;
  __D5dyaml6loader11__moduleRefZ = Module["__D5dyaml6loader11__moduleRefZ"] = (wasmExports["_D5dyaml6loader11__moduleRefZ"].value) >>> 0;
  __D5dyaml4node11__moduleRefZ = Module["__D5dyaml4node11__moduleRefZ"] = (wasmExports["_D5dyaml4node11__moduleRefZ"].value) >>> 0;
  __D5dyaml11__moduleRefZ = Module["__D5dyaml11__moduleRefZ"] = (wasmExports["_D5dyaml11__moduleRefZ"].value) >>> 0;
  __D5dyaml6parser11__moduleRefZ = Module["__D5dyaml6parser11__moduleRefZ"] = (wasmExports["_D5dyaml6parser11__moduleRefZ"].value) >>> 0;
  __D5dyaml5queue11__moduleRefZ = Module["__D5dyaml5queue11__moduleRefZ"] = (wasmExports["_D5dyaml5queue11__moduleRefZ"].value) >>> 0;
  __D5dyaml6reader11__moduleRefZ = Module["__D5dyaml6reader11__moduleRefZ"] = (wasmExports["_D5dyaml6reader11__moduleRefZ"].value) >>> 0;
  __D5dyaml11representer11__moduleRefZ = Module["__D5dyaml11representer11__moduleRefZ"] = (wasmExports["_D5dyaml11representer11__moduleRefZ"].value) >>> 0;
  __D5dyaml8resolver11__moduleRefZ = Module["__D5dyaml8resolver11__moduleRefZ"] = (wasmExports["_D5dyaml8resolver11__moduleRefZ"].value) >>> 0;
  __D5dyaml7scanner11__moduleRefZ = Module["__D5dyaml7scanner11__moduleRefZ"] = (wasmExports["_D5dyaml7scanner11__moduleRefZ"].value) >>> 0;
  __D5dyaml10serializer11__moduleRefZ = Module["__D5dyaml10serializer11__moduleRefZ"] = (wasmExports["_D5dyaml10serializer11__moduleRefZ"].value) >>> 0;
  __D5dyaml12tagdirective11__moduleRefZ = Module["__D5dyaml12tagdirective11__moduleRefZ"] = (wasmExports["_D5dyaml12tagdirective11__moduleRefZ"].value) >>> 0;
  __D5dyaml5token11__moduleRefZ = Module["__D5dyaml5token11__moduleRefZ"] = (wasmExports["_D5dyaml5token11__moduleRefZ"].value) >>> 0;
  __D4lwo211__moduleRefZ = Module["__D4lwo211__moduleRefZ"] = (wasmExports["_D4lwo211__moduleRefZ"].value) >>> 0;
  __D4lwo26writer11__moduleRefZ = Module["__D4lwo26writer11__moduleRefZ"] = (wasmExports["_D4lwo26writer11__moduleRefZ"].value) >>> 0;
  __D3etc1c4curl11__moduleRefZ = Module["__D3etc1c4curl11__moduleRefZ"] = (wasmExports["_D3etc1c4curl11__moduleRefZ"].value) >>> 0;
  __D3etc1c4zlib11__moduleRefZ = Module["__D3etc1c4zlib11__moduleRefZ"] = (wasmExports["_D3etc1c4zlib11__moduleRefZ"].value) >>> 0;
  __D3std9algorithm10comparison11__moduleRefZ = Module["__D3std9algorithm10comparison11__moduleRefZ"] = (wasmExports["_D3std9algorithm10comparison11__moduleRefZ"].value) >>> 0;
  __D3std9algorithm9iteration11__moduleRefZ = Module["__D3std9algorithm9iteration11__moduleRefZ"] = (wasmExports["_D3std9algorithm9iteration11__moduleRefZ"].value) >>> 0;
  __D3std9algorithm8mutation11__moduleRefZ = Module["__D3std9algorithm8mutation11__moduleRefZ"] = (wasmExports["_D3std9algorithm8mutation11__moduleRefZ"].value) >>> 0;
  __D3std9algorithm9searching11__moduleRefZ = Module["__D3std9algorithm9searching11__moduleRefZ"] = (wasmExports["_D3std9algorithm9searching11__moduleRefZ"].value) >>> 0;
  __D3std9algorithm7sorting11__moduleRefZ = Module["__D3std9algorithm7sorting11__moduleRefZ"] = (wasmExports["_D3std9algorithm7sorting11__moduleRefZ"].value) >>> 0;
  __D3std5array11__moduleRefZ = Module["__D3std5array11__moduleRefZ"] = (wasmExports["_D3std5array11__moduleRefZ"].value) >>> 0;
  __D3std5ascii11__moduleRefZ = Module["__D3std5ascii11__moduleRefZ"] = (wasmExports["_D3std5ascii11__moduleRefZ"].value) >>> 0;
  __D3std6base6411__moduleRefZ = Module["__D3std6base6411__moduleRefZ"] = (wasmExports["_D3std6base6411__moduleRefZ"].value) >>> 0;
  __D3std8bitmanip11__moduleRefZ = Module["__D3std8bitmanip11__moduleRefZ"] = (wasmExports["_D3std8bitmanip11__moduleRefZ"].value) >>> 0;
  __D3std10checkedint11__moduleRefZ = Module["__D3std10checkedint11__moduleRefZ"] = (wasmExports["_D3std10checkedint11__moduleRefZ"].value) >>> 0;
  __D3std11concurrency11__moduleRefZ = Module["__D3std11concurrency11__moduleRefZ"] = (wasmExports["_D3std11concurrency11__moduleRefZ"].value) >>> 0;
  __D3std4conv11__moduleRefZ = Module["__D3std4conv11__moduleRefZ"] = (wasmExports["_D3std4conv11__moduleRefZ"].value) >>> 0;
  __D3std8datetime4date11__moduleRefZ = Module["__D3std8datetime4date11__moduleRefZ"] = (wasmExports["_D3std8datetime4date11__moduleRefZ"].value) >>> 0;
  __D3std8datetime7systime11__moduleRefZ = Module["__D3std8datetime7systime11__moduleRefZ"] = (wasmExports["_D3std8datetime7systime11__moduleRefZ"].value) >>> 0;
  __D3std8datetime8timezone11__moduleRefZ = Module["__D3std8datetime8timezone11__moduleRefZ"] = (wasmExports["_D3std8datetime8timezone11__moduleRefZ"].value) >>> 0;
  __D3std6digest2md11__moduleRefZ = Module["__D3std6digest2md11__moduleRefZ"] = (wasmExports["_D3std6digest2md11__moduleRefZ"].value) >>> 0;
  __D3std6digest3sha11__moduleRefZ = Module["__D3std6digest3sha11__moduleRefZ"] = (wasmExports["_D3std6digest3sha11__moduleRefZ"].value) >>> 0;
  __D3std8encoding11__moduleRefZ = Module["__D3std8encoding11__moduleRefZ"] = (wasmExports["_D3std8encoding11__moduleRefZ"].value) >>> 0;
  __D3std9exception11__moduleRefZ = Module["__D3std9exception11__moduleRefZ"] = (wasmExports["_D3std9exception11__moduleRefZ"].value) >>> 0;
  __D3std12experimental9allocator12gc_allocator11__moduleRefZ = Module["__D3std12experimental9allocator12gc_allocator11__moduleRefZ"] = (wasmExports["_D3std12experimental9allocator12gc_allocator11__moduleRefZ"].value) >>> 0;
  __D3std12experimental9allocator10mallocator11__moduleRefZ = Module["__D3std12experimental9allocator10mallocator11__moduleRefZ"] = (wasmExports["_D3std12experimental9allocator10mallocator11__moduleRefZ"].value) >>> 0;
  __D3std12experimental9allocator11__moduleRefZ = Module["__D3std12experimental9allocator11__moduleRefZ"] = (wasmExports["_D3std12experimental9allocator11__moduleRefZ"].value) >>> 0;
  __D3std4file11__moduleRefZ = Module["__D3std4file11__moduleRefZ"] = (wasmExports["_D3std4file11__moduleRefZ"].value) >>> 0;
  __D3std6format8internal6floats11__moduleRefZ = Module["__D3std6format8internal6floats11__moduleRefZ"] = (wasmExports["_D3std6format8internal6floats11__moduleRefZ"].value) >>> 0;
  __D3std6format8internal5write11__moduleRefZ = Module["__D3std6format8internal5write11__moduleRefZ"] = (wasmExports["_D3std6format8internal5write11__moduleRefZ"].value) >>> 0;
  __D3std6format11__moduleRefZ = Module["__D3std6format11__moduleRefZ"] = (wasmExports["_D3std6format11__moduleRefZ"].value) >>> 0;
  __D3std6format4spec11__moduleRefZ = Module["__D3std6format4spec11__moduleRefZ"] = (wasmExports["_D3std6format4spec11__moduleRefZ"].value) >>> 0;
  __D3std6format5write11__moduleRefZ = Module["__D3std6format5write11__moduleRefZ"] = (wasmExports["_D3std6format5write11__moduleRefZ"].value) >>> 0;
  __D3std10functional11__moduleRefZ = Module["__D3std10functional11__moduleRefZ"] = (wasmExports["_D3std10functional11__moduleRefZ"].value) >>> 0;
  __D3std8internal7cstring11__moduleRefZ = Module["__D3std8internal7cstring11__moduleRefZ"] = (wasmExports["_D3std8internal7cstring11__moduleRefZ"].value) >>> 0;
  __D3std8internal6memory11__moduleRefZ = Module["__D3std8internal6memory11__moduleRefZ"] = (wasmExports["_D3std8internal6memory11__moduleRefZ"].value) >>> 0;
  __D3std8internal12unicode_comp11__moduleRefZ = Module["__D3std8internal12unicode_comp11__moduleRefZ"] = (wasmExports["_D3std8internal12unicode_comp11__moduleRefZ"].value) >>> 0;
  __D3std8internal14unicode_tables11__moduleRefZ = Module["__D3std8internal14unicode_tables11__moduleRefZ"] = (wasmExports["_D3std8internal14unicode_tables11__moduleRefZ"].value) >>> 0;
  __D3std4json11__moduleRefZ = Module["__D3std4json11__moduleRefZ"] = (wasmExports["_D3std4json11__moduleRefZ"].value) >>> 0;
  __D3std6logger4core11__moduleRefZ = Module["__D3std6logger4core11__moduleRefZ"] = (wasmExports["_D3std6logger4core11__moduleRefZ"].value) >>> 0;
  __D3std6logger10filelogger11__moduleRefZ = Module["__D3std6logger10filelogger11__moduleRefZ"] = (wasmExports["_D3std6logger10filelogger11__moduleRefZ"].value) >>> 0;
  __D3std6logger11multilogger11__moduleRefZ = Module["__D3std6logger11multilogger11__moduleRefZ"] = (wasmExports["_D3std6logger11multilogger11__moduleRefZ"].value) >>> 0;
  __D3std4math9algebraic11__moduleRefZ = Module["__D3std4math9algebraic11__moduleRefZ"] = (wasmExports["_D3std4math9algebraic11__moduleRefZ"].value) >>> 0;
  __D3std4math11exponential11__moduleRefZ = Module["__D3std4math11exponential11__moduleRefZ"] = (wasmExports["_D3std4math11exponential11__moduleRefZ"].value) >>> 0;
  __D3std4math10operations11__moduleRefZ = Module["__D3std4math10operations11__moduleRefZ"] = (wasmExports["_D3std4math10operations11__moduleRefZ"].value) >>> 0;
  __D3std4math8rounding11__moduleRefZ = Module["__D3std4math8rounding11__moduleRefZ"] = (wasmExports["_D3std4math8rounding11__moduleRefZ"].value) >>> 0;
  __D3std4math6traits11__moduleRefZ = Module["__D3std4math6traits11__moduleRefZ"] = (wasmExports["_D3std4math6traits11__moduleRefZ"].value) >>> 0;
  __D3std4math12trigonometry11__moduleRefZ = Module["__D3std4math12trigonometry11__moduleRefZ"] = (wasmExports["_D3std4math12trigonometry11__moduleRefZ"].value) >>> 0;
  __D3std4meta11__moduleRefZ = Module["__D3std4meta11__moduleRefZ"] = (wasmExports["_D3std4meta11__moduleRefZ"].value) >>> 0;
  __D3std11parallelism11__moduleRefZ = Module["__D3std11parallelism11__moduleRefZ"] = (wasmExports["_D3std11parallelism11__moduleRefZ"].value) >>> 0;
  __D3std4path11__moduleRefZ = Module["__D3std4path11__moduleRefZ"] = (wasmExports["_D3std4path11__moduleRefZ"].value) >>> 0;
  __D3std7process11__moduleRefZ = Module["__D3std7process11__moduleRefZ"] = (wasmExports["_D3std7process11__moduleRefZ"].value) >>> 0;
  __D3std6random11__moduleRefZ = Module["__D3std6random11__moduleRefZ"] = (wasmExports["_D3std6random11__moduleRefZ"].value) >>> 0;
  __D3std5range11__moduleRefZ = Module["__D3std5range11__moduleRefZ"] = (wasmExports["_D3std5range11__moduleRefZ"].value) >>> 0;
  __D3std5range10primitives11__moduleRefZ = Module["__D3std5range10primitives11__moduleRefZ"] = (wasmExports["_D3std5range10primitives11__moduleRefZ"].value) >>> 0;
  __D3std5regex8internal12backtracking11__moduleRefZ = Module["__D3std5regex8internal12backtracking11__moduleRefZ"] = (wasmExports["_D3std5regex8internal12backtracking11__moduleRefZ"].value) >>> 0;
  __D3std5regex8internal2ir11__moduleRefZ = Module["__D3std5regex8internal2ir11__moduleRefZ"] = (wasmExports["_D3std5regex8internal2ir11__moduleRefZ"].value) >>> 0;
  __D3std5regex8internal6parser11__moduleRefZ = Module["__D3std5regex8internal6parser11__moduleRefZ"] = (wasmExports["_D3std5regex8internal6parser11__moduleRefZ"].value) >>> 0;
  __D3std5stdio11__moduleRefZ = Module["__D3std5stdio11__moduleRefZ"] = (wasmExports["_D3std5stdio11__moduleRefZ"].value) >>> 0;
  __D3std6string11__moduleRefZ = Module["__D3std6string11__moduleRefZ"] = (wasmExports["_D3std6string11__moduleRefZ"].value) >>> 0;
  __D3std7sumtype11__moduleRefZ = Module["__D3std7sumtype11__moduleRefZ"] = (wasmExports["_D3std7sumtype11__moduleRefZ"].value) >>> 0;
  __D3std6traits11__moduleRefZ = Module["__D3std6traits11__moduleRefZ"] = (wasmExports["_D3std6traits11__moduleRefZ"].value) >>> 0;
  __D3std8typecons11__moduleRefZ = Module["__D3std8typecons11__moduleRefZ"] = (wasmExports["_D3std8typecons11__moduleRefZ"].value) >>> 0;
  __D3std3uni11__moduleRefZ = Module["__D3std3uni11__moduleRefZ"] = (wasmExports["_D3std3uni11__moduleRefZ"].value) >>> 0;
  __D3std3utf11__moduleRefZ = Module["__D3std3utf11__moduleRefZ"] = (wasmExports["_D3std3utf11__moduleRefZ"].value) >>> 0;
  __D3std4uuid11__moduleRefZ = Module["__D3std4uuid11__moduleRefZ"] = (wasmExports["_D3std4uuid11__moduleRefZ"].value) >>> 0;
  __D3std7variant11__moduleRefZ = Module["__D3std7variant11__moduleRefZ"] = (wasmExports["_D3std7variant11__moduleRefZ"].value) >>> 0;
  __D3std3zip11__moduleRefZ = Module["__D3std3zip11__moduleRefZ"] = (wasmExports["_D3std3zip11__moduleRefZ"].value) >>> 0;
  __D3std4zlib11__moduleRefZ = Module["__D3std4zlib11__moduleRefZ"] = (wasmExports["_D3std4zlib11__moduleRefZ"].value) >>> 0;
  __D4core5bitop11__moduleRefZ = Module["__D4core5bitop11__moduleRefZ"] = (wasmExports["_D4core5bitop11__moduleRefZ"].value) >>> 0;
  __D4core10checkedint11__moduleRefZ = Module["__D4core10checkedint11__moduleRefZ"] = (wasmExports["_D4core10checkedint11__moduleRefZ"].value) >>> 0;
  __D4core5cpuid11__moduleRefZ = Module["__D4core5cpuid11__moduleRefZ"] = (wasmExports["_D4core5cpuid11__moduleRefZ"].value) >>> 0;
  __D4core8demangle11__moduleRefZ = Module["__D4core8demangle11__moduleRefZ"] = (wasmExports["_D4core8demangle11__moduleRefZ"].value) >>> 0;
  __D4core9exception11__moduleRefZ = Module["__D4core9exception11__moduleRefZ"] = (wasmExports["_D4core9exception11__moduleRefZ"].value) >>> 0;
  __D4core2gc6config11__moduleRefZ = Module["__D4core2gc6config11__moduleRefZ"] = (wasmExports["_D4core2gc6config11__moduleRefZ"].value) >>> 0;
  __D4core2gc11gcinterface11__moduleRefZ = Module["__D4core2gc11gcinterface11__moduleRefZ"] = (wasmExports["_D4core2gc11gcinterface11__moduleRefZ"].value) >>> 0;
  __D4core2gc8registry11__moduleRefZ = Module["__D4core2gc8registry11__moduleRefZ"] = (wasmExports["_D4core2gc8registry11__moduleRefZ"].value) >>> 0;
  __D4core8internal5abort11__moduleRefZ = Module["__D4core8internal5abort11__moduleRefZ"] = (wasmExports["_D4core8internal5abort11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array9appending11__moduleRefZ = Module["__D4core8internal5array9appending11__moduleRefZ"] = (wasmExports["_D4core8internal5array9appending11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array8capacity11__moduleRefZ = Module["__D4core8internal5array8capacity11__moduleRefZ"] = (wasmExports["_D4core8internal5array8capacity11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array7casting11__moduleRefZ = Module["__D4core8internal5array7casting11__moduleRefZ"] = (wasmExports["_D4core8internal5array7casting11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array13concatenation11__moduleRefZ = Module["__D4core8internal5array13concatenation11__moduleRefZ"] = (wasmExports["_D4core8internal5array13concatenation11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array12construction11__moduleRefZ = Module["__D4core8internal5array12construction11__moduleRefZ"] = (wasmExports["_D4core8internal5array12construction11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array11duplication11__moduleRefZ = Module["__D4core8internal5array11duplication11__moduleRefZ"] = (wasmExports["_D4core8internal5array11duplication11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array8equality11__moduleRefZ = Module["__D4core8internal5array8equality11__moduleRefZ"] = (wasmExports["_D4core8internal5array8equality11__moduleRefZ"].value) >>> 0;
  __D4core8internal5array5utils11__moduleRefZ = Module["__D4core8internal5array5utils11__moduleRefZ"] = (wasmExports["_D4core8internal5array5utils11__moduleRefZ"].value) >>> 0;
  __D4core8internal5cast_11__moduleRefZ = Module["__D4core8internal5cast_11__moduleRefZ"] = (wasmExports["_D4core8internal5cast_11__moduleRefZ"].value) >>> 0;
  __D4core8internal9container5array11__moduleRefZ = Module["__D4core8internal9container5array11__moduleRefZ"] = (wasmExports["_D4core8internal9container5array11__moduleRefZ"].value) >>> 0;
  __D4core8internal9container6common11__moduleRefZ = Module["__D4core8internal9container6common11__moduleRefZ"] = (wasmExports["_D4core8internal9container6common11__moduleRefZ"].value) >>> 0;
  __D4core8internal9container7hashtab11__moduleRefZ = Module["__D4core8internal9container7hashtab11__moduleRefZ"] = (wasmExports["_D4core8internal9container7hashtab11__moduleRefZ"].value) >>> 0;
  __D4core8internal9container5treap11__moduleRefZ = Module["__D4core8internal9container5treap11__moduleRefZ"] = (wasmExports["_D4core8internal9container5treap11__moduleRefZ"].value) >>> 0;
  __D4core8internal7convert11__moduleRefZ = Module["__D4core8internal7convert11__moduleRefZ"] = (wasmExports["_D4core8internal7convert11__moduleRefZ"].value) >>> 0;
  __D4core8internal11destruction11__moduleRefZ = Module["__D4core8internal11destruction11__moduleRefZ"] = (wasmExports["_D4core8internal11destruction11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc4bits11__moduleRefZ = Module["__D4core8internal2gc4bits11__moduleRefZ"] = (wasmExports["_D4core8internal2gc4bits11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc8blkcache11__moduleRefZ = Module["__D4core8internal2gc8blkcache11__moduleRefZ"] = (wasmExports["_D4core8internal2gc8blkcache11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc9blockmeta11__moduleRefZ = Module["__D4core8internal2gc9blockmeta11__moduleRefZ"] = (wasmExports["_D4core8internal2gc9blockmeta11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc4impl12conservativeQw11__moduleRefZ = Module["__D4core8internal2gc4impl12conservativeQw11__moduleRefZ"] = (wasmExports["_D4core8internal2gc4impl12conservativeQw11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc4impl6manualQp11__moduleRefZ = Module["__D4core8internal2gc4impl6manualQp11__moduleRefZ"] = (wasmExports["_D4core8internal2gc4impl6manualQp11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc4impl5protoQo11__moduleRefZ = Module["__D4core8internal2gc4impl5protoQo11__moduleRefZ"] = (wasmExports["_D4core8internal2gc4impl5protoQo11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc2os11__moduleRefZ = Module["__D4core8internal2gc2os11__moduleRefZ"] = (wasmExports["_D4core8internal2gc2os11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc9pooltable11__moduleRefZ = Module["__D4core8internal2gc9pooltable11__moduleRefZ"] = (wasmExports["_D4core8internal2gc9pooltable11__moduleRefZ"].value) >>> 0;
  __D4core8internal2gc5proxy11__moduleRefZ = Module["__D4core8internal2gc5proxy11__moduleRefZ"] = (wasmExports["_D4core8internal2gc5proxy11__moduleRefZ"].value) >>> 0;
  __D4core8internal4hash11__moduleRefZ = Module["__D4core8internal4hash11__moduleRefZ"] = (wasmExports["_D4core8internal4hash11__moduleRefZ"].value) >>> 0;
  __D4core8internal8lifetime11__moduleRefZ = Module["__D4core8internal8lifetime11__moduleRefZ"] = (wasmExports["_D4core8internal8lifetime11__moduleRefZ"].value) >>> 0;
  __D4core8internal5newaa11__moduleRefZ = Module["__D4core8internal5newaa11__moduleRefZ"] = (wasmExports["_D4core8internal5newaa11__moduleRefZ"].value) >>> 0;
  __D4core8internal12parseoptions11__moduleRefZ = Module["__D4core8internal12parseoptions11__moduleRefZ"] = (wasmExports["_D4core8internal12parseoptions11__moduleRefZ"].value) >>> 0;
  __D4core8internal8spinlock11__moduleRefZ = Module["__D4core8internal8spinlock11__moduleRefZ"] = (wasmExports["_D4core8internal8spinlock11__moduleRefZ"].value) >>> 0;
  __D4core8internal6string11__moduleRefZ = Module["__D4core8internal6string11__moduleRefZ"] = (wasmExports["_D4core8internal6string11__moduleRefZ"].value) >>> 0;
  __D4core8internal7switch_11__moduleRefZ = Module["__D4core8internal7switch_11__moduleRefZ"] = (wasmExports["_D4core8internal7switch_11__moduleRefZ"].value) >>> 0;
  __D4core8internal3utf11__moduleRefZ = Module["__D4core8internal3utf11__moduleRefZ"] = (wasmExports["_D4core8internal3utf11__moduleRefZ"].value) >>> 0;
  __D4core8internal4util5array11__moduleRefZ = Module["__D4core8internal4util5array11__moduleRefZ"] = (wasmExports["_D4core8internal4util5array11__moduleRefZ"].value) >>> 0;
  __D4core8internal4util4math11__moduleRefZ = Module["__D4core8internal4util4math11__moduleRefZ"] = (wasmExports["_D4core8internal4util4math11__moduleRefZ"].value) >>> 0;
  __D4core8lifetime11__moduleRefZ = Module["__D4core8lifetime11__moduleRefZ"] = (wasmExports["_D4core8lifetime11__moduleRefZ"].value) >>> 0;
  __D4core4math11__moduleRefZ = Module["__D4core4math11__moduleRefZ"] = (wasmExports["_D4core4math11__moduleRefZ"].value) >>> 0;
  __D4core6memory11__moduleRefZ = Module["__D4core6memory11__moduleRefZ"] = (wasmExports["_D4core6memory11__moduleRefZ"].value) >>> 0;
  __D4core7runtime11__moduleRefZ = Module["__D4core7runtime11__moduleRefZ"] = (wasmExports["_D4core7runtime11__moduleRefZ"].value) >>> 0;
  __D4core4sync9condition11__moduleRefZ = Module["__D4core4sync9condition11__moduleRefZ"] = (wasmExports["_D4core4sync9condition11__moduleRefZ"].value) >>> 0;
  __D4core4sync6config11__moduleRefZ = Module["__D4core4sync6config11__moduleRefZ"] = (wasmExports["_D4core4sync6config11__moduleRefZ"].value) >>> 0;
  __D4core4sync9exception11__moduleRefZ = Module["__D4core4sync9exception11__moduleRefZ"] = (wasmExports["_D4core4sync9exception11__moduleRefZ"].value) >>> 0;
  __D4core4sync5mutex11__moduleRefZ = Module["__D4core4sync5mutex11__moduleRefZ"] = (wasmExports["_D4core4sync5mutex11__moduleRefZ"].value) >>> 0;
  __D4core6thread7context11__moduleRefZ = Module["__D4core6thread7context11__moduleRefZ"] = (wasmExports["_D4core6thread7context11__moduleRefZ"].value) >>> 0;
  __D4core6thread8osthread11__moduleRefZ = Module["__D4core6thread8osthread11__moduleRefZ"] = (wasmExports["_D4core6thread8osthread11__moduleRefZ"].value) >>> 0;
  __D4core6thread11__moduleRefZ = Module["__D4core6thread11__moduleRefZ"] = (wasmExports["_D4core6thread11__moduleRefZ"].value) >>> 0;
  __D4core6thread10threadbase11__moduleRefZ = Module["__D4core6thread10threadbase11__moduleRefZ"] = (wasmExports["_D4core6thread10threadbase11__moduleRefZ"].value) >>> 0;
  __D4core6thread11threadgroup11__moduleRefZ = Module["__D4core6thread11threadgroup11__moduleRefZ"] = (wasmExports["_D4core6thread11threadgroup11__moduleRefZ"].value) >>> 0;
  __D4core6thread5types11__moduleRefZ = Module["__D4core6thread5types11__moduleRefZ"] = (wasmExports["_D4core6thread5types11__moduleRefZ"].value) >>> 0;
  __D4core4time11__moduleRefZ = Module["__D4core4time11__moduleRefZ"] = (wasmExports["_D4core4time11__moduleRefZ"].value) >>> 0;
  __D6object11__moduleRefZ = Module["__D6object11__moduleRefZ"] = (wasmExports["_D6object11__moduleRefZ"].value) >>> 0;
  __D2rt6aApply11__moduleRefZ = Module["__D2rt6aApply11__moduleRefZ"] = (wasmExports["_D2rt6aApply11__moduleRefZ"].value) >>> 0;
  __D2rt7aApplyR11__moduleRefZ = Module["__D2rt7aApplyR11__moduleRefZ"] = (wasmExports["_D2rt7aApplyR11__moduleRefZ"].value) >>> 0;
  __D2rt8arraycat11__moduleRefZ = Module["__D2rt8arraycat11__moduleRefZ"] = (wasmExports["_D2rt8arraycat11__moduleRefZ"].value) >>> 0;
  _rt_options = Module["_rt_options"] = (wasmExports["rt_options"].value) >>> 0;
  _rt_envvars_enabled = Module["_rt_envvars_enabled"] = (wasmExports["rt_envvars_enabled"].value) >>> 0;
  _rt_cmdline_enabled = Module["_rt_cmdline_enabled"] = (wasmExports["rt_cmdline_enabled"].value) >>> 0;
  __D2rt6config11__moduleRefZ = Module["__D2rt6config11__moduleRefZ"] = (wasmExports["_D2rt6config11__moduleRefZ"].value) >>> 0;
  __D2rt9critical_11__moduleRefZ = Module["__D2rt9critical_11__moduleRefZ"] = (wasmExports["_D2rt9critical_11__moduleRefZ"].value) >>> 0;
  __D2rt3deh11__moduleRefZ = Module["__D2rt3deh11__moduleRefZ"] = (wasmExports["_D2rt3deh11__moduleRefZ"].value) >>> 0;
  __D2rt15deh_win64_posix11__moduleRefZ = Module["__D2rt15deh_win64_posix11__moduleRefZ"] = (wasmExports["_D2rt15deh_win64_posix11__moduleRefZ"].value) >>> 0;
  __D2rt6dmain211__moduleRefZ = Module["__D2rt6dmain211__moduleRefZ"] = (wasmExports["_D2rt6dmain211__moduleRefZ"].value) >>> 0;
  __D2rt7dwarfeh11__moduleRefZ = Module["__D2rt7dwarfeh11__moduleRefZ"] = (wasmExports["_D2rt7dwarfeh11__moduleRefZ"].value) >>> 0;
  __D2rt7ehalloc11__moduleRefZ = Module["__D2rt7ehalloc11__moduleRefZ"] = (wasmExports["_D2rt7ehalloc11__moduleRefZ"].value) >>> 0;
  __D2rt8lifetime11__moduleRefZ = Module["__D2rt8lifetime11__moduleRefZ"] = (wasmExports["_D2rt8lifetime11__moduleRefZ"].value) >>> 0;
  __D2rt6memory11__moduleRefZ = Module["__D2rt6memory11__moduleRefZ"] = (wasmExports["_D2rt6memory11__moduleRefZ"].value) >>> 0;
  __D2rt5minfo11__moduleRefZ = Module["__D2rt5minfo11__moduleRefZ"] = (wasmExports["_D2rt5minfo11__moduleRefZ"].value) >>> 0;
  __D2rt8monitor_11__moduleRefZ = Module["__D2rt8monitor_11__moduleRefZ"] = (wasmExports["_D2rt8monitor_11__moduleRefZ"].value) >>> 0;
  __D2rt13sections_wasm11__moduleRefZ = Module["__D2rt13sections_wasm11__moduleRefZ"] = (wasmExports["_D2rt13sections_wasm11__moduleRefZ"].value) >>> 0;
  __D2rt5tlsgc11__moduleRefZ = Module["__D2rt5tlsgc11__moduleRefZ"] = (wasmExports["_D2rt5tlsgc11__moduleRefZ"].value) >>> 0;
  __D2rt4util8typeinfo11__moduleRefZ = Module["__D2rt4util8typeinfo11__moduleRefZ"] = (wasmExports["_D2rt4util8typeinfo11__moduleRefZ"].value) >>> 0;
  __D2rt4util7utility11__moduleRefZ = Module["__D2rt4util7utility11__moduleRefZ"] = (wasmExports["_D2rt4util7utility11__moduleRefZ"].value) >>> 0;
  __D4core3sys5posix7pthread11__moduleRefZ = Module["__D4core3sys5posix7pthread11__moduleRefZ"] = (wasmExports["_D4core3sys5posix7pthread11__moduleRefZ"].value) >>> 0;
  __D4core3sys5posixQk4stat11__moduleRefZ = Module["__D4core3sys5posixQk4stat11__moduleRefZ"] = (wasmExports["_D4core3sys5posixQk4stat11__moduleRefZ"].value) >>> 0;
}

var wasmImports = {
  /** @export */ ImGui_ImplSDL2_EmscriptenOpenURL,
  /** @export */ __cxa_throw: ___cxa_throw,
  /** @export */ __syscall_chmod: ___syscall_chmod,
  /** @export */ __syscall_fchmod: ___syscall_fchmod,
  /** @export */ __syscall_fcntl64: ___syscall_fcntl64,
  /** @export */ __syscall_fstat64: ___syscall_fstat64,
  /** @export */ __syscall_ftruncate64: ___syscall_ftruncate64,
  /** @export */ __syscall_getcwd: ___syscall_getcwd,
  /** @export */ __syscall_getdents64: ___syscall_getdents64,
  /** @export */ __syscall_ioctl: ___syscall_ioctl,
  /** @export */ __syscall_lstat64: ___syscall_lstat64,
  /** @export */ __syscall_mkdirat: ___syscall_mkdirat,
  /** @export */ __syscall_newfstatat: ___syscall_newfstatat,
  /** @export */ __syscall_openat: ___syscall_openat,
  /** @export */ __syscall_rmdir: ___syscall_rmdir,
  /** @export */ __syscall_stat64: ___syscall_stat64,
  /** @export */ __syscall_unlinkat: ___syscall_unlinkat,
  /** @export */ __syscall_utimensat: ___syscall_utimensat,
  /** @export */ _abort_js: __abort_js,
  /** @export */ _localtime_js: __localtime_js,
  /** @export */ _tzset_js: __tzset_js,
  /** @export */ clock_res_get: _clock_res_get,
  /** @export */ clock_time_get: _clock_time_get,
  /** @export */ eglBindAPI: _eglBindAPI,
  /** @export */ eglChooseConfig: _eglChooseConfig,
  /** @export */ eglCreateContext: _eglCreateContext,
  /** @export */ eglCreateWindowSurface: _eglCreateWindowSurface,
  /** @export */ eglDestroyContext: _eglDestroyContext,
  /** @export */ eglDestroySurface: _eglDestroySurface,
  /** @export */ eglGetConfigAttrib: _eglGetConfigAttrib,
  /** @export */ eglGetDisplay: _eglGetDisplay,
  /** @export */ eglGetError: _eglGetError,
  /** @export */ eglInitialize: _eglInitialize,
  /** @export */ eglMakeCurrent: _eglMakeCurrent,
  /** @export */ eglQueryString: _eglQueryString,
  /** @export */ eglSwapBuffers: _eglSwapBuffers,
  /** @export */ eglSwapInterval: _eglSwapInterval,
  /** @export */ eglTerminate: _eglTerminate,
  /** @export */ eglWaitGL: _eglWaitGL,
  /** @export */ eglWaitNative: _eglWaitNative,
  /** @export */ emscripten_asm_const_int: _emscripten_asm_const_int,
  /** @export */ emscripten_asm_const_int_sync_on_main_thread: _emscripten_asm_const_int_sync_on_main_thread,
  /** @export */ emscripten_asm_const_ptr_sync_on_main_thread: _emscripten_asm_const_ptr_sync_on_main_thread,
  /** @export */ emscripten_cancel_main_loop: _emscripten_cancel_main_loop,
  /** @export */ emscripten_date_now: _emscripten_date_now,
  /** @export */ emscripten_err: _emscripten_err,
  /** @export */ emscripten_exit_fullscreen: _emscripten_exit_fullscreen,
  /** @export */ emscripten_exit_pointerlock: _emscripten_exit_pointerlock,
  /** @export */ emscripten_get_device_pixel_ratio: _emscripten_get_device_pixel_ratio,
  /** @export */ emscripten_get_element_css_size: _emscripten_get_element_css_size,
  /** @export */ emscripten_get_gamepad_status: _emscripten_get_gamepad_status,
  /** @export */ emscripten_get_heap_max: _emscripten_get_heap_max,
  /** @export */ emscripten_get_now: _emscripten_get_now,
  /** @export */ emscripten_get_num_gamepads: _emscripten_get_num_gamepads,
  /** @export */ emscripten_get_screen_size: _emscripten_get_screen_size,
  /** @export */ emscripten_glActiveTexture: _emscripten_glActiveTexture,
  /** @export */ emscripten_glAttachShader: _emscripten_glAttachShader,
  /** @export */ emscripten_glBeginQuery: _emscripten_glBeginQuery,
  /** @export */ emscripten_glBeginQueryEXT: _emscripten_glBeginQueryEXT,
  /** @export */ emscripten_glBeginTransformFeedback: _emscripten_glBeginTransformFeedback,
  /** @export */ emscripten_glBindAttribLocation: _emscripten_glBindAttribLocation,
  /** @export */ emscripten_glBindBuffer: _emscripten_glBindBuffer,
  /** @export */ emscripten_glBindBufferBase: _emscripten_glBindBufferBase,
  /** @export */ emscripten_glBindBufferRange: _emscripten_glBindBufferRange,
  /** @export */ emscripten_glBindFramebuffer: _emscripten_glBindFramebuffer,
  /** @export */ emscripten_glBindRenderbuffer: _emscripten_glBindRenderbuffer,
  /** @export */ emscripten_glBindSampler: _emscripten_glBindSampler,
  /** @export */ emscripten_glBindTexture: _emscripten_glBindTexture,
  /** @export */ emscripten_glBindTransformFeedback: _emscripten_glBindTransformFeedback,
  /** @export */ emscripten_glBindVertexArray: _emscripten_glBindVertexArray,
  /** @export */ emscripten_glBindVertexArrayOES: _emscripten_glBindVertexArrayOES,
  /** @export */ emscripten_glBlendColor: _emscripten_glBlendColor,
  /** @export */ emscripten_glBlendEquation: _emscripten_glBlendEquation,
  /** @export */ emscripten_glBlendEquationSeparate: _emscripten_glBlendEquationSeparate,
  /** @export */ emscripten_glBlendFunc: _emscripten_glBlendFunc,
  /** @export */ emscripten_glBlendFuncSeparate: _emscripten_glBlendFuncSeparate,
  /** @export */ emscripten_glBlitFramebuffer: _emscripten_glBlitFramebuffer,
  /** @export */ emscripten_glBufferData: _emscripten_glBufferData,
  /** @export */ emscripten_glBufferSubData: _emscripten_glBufferSubData,
  /** @export */ emscripten_glCheckFramebufferStatus: _emscripten_glCheckFramebufferStatus,
  /** @export */ emscripten_glClear: _emscripten_glClear,
  /** @export */ emscripten_glClearBufferfi: _emscripten_glClearBufferfi,
  /** @export */ emscripten_glClearBufferfv: _emscripten_glClearBufferfv,
  /** @export */ emscripten_glClearBufferiv: _emscripten_glClearBufferiv,
  /** @export */ emscripten_glClearBufferuiv: _emscripten_glClearBufferuiv,
  /** @export */ emscripten_glClearColor: _emscripten_glClearColor,
  /** @export */ emscripten_glClearDepthf: _emscripten_glClearDepthf,
  /** @export */ emscripten_glClearStencil: _emscripten_glClearStencil,
  /** @export */ emscripten_glClientWaitSync: _emscripten_glClientWaitSync,
  /** @export */ emscripten_glClipControlEXT: _emscripten_glClipControlEXT,
  /** @export */ emscripten_glColorMask: _emscripten_glColorMask,
  /** @export */ emscripten_glCompileShader: _emscripten_glCompileShader,
  /** @export */ emscripten_glCompressedTexImage2D: _emscripten_glCompressedTexImage2D,
  /** @export */ emscripten_glCompressedTexImage3D: _emscripten_glCompressedTexImage3D,
  /** @export */ emscripten_glCompressedTexSubImage2D: _emscripten_glCompressedTexSubImage2D,
  /** @export */ emscripten_glCompressedTexSubImage3D: _emscripten_glCompressedTexSubImage3D,
  /** @export */ emscripten_glCopyBufferSubData: _emscripten_glCopyBufferSubData,
  /** @export */ emscripten_glCopyTexImage2D: _emscripten_glCopyTexImage2D,
  /** @export */ emscripten_glCopyTexSubImage2D: _emscripten_glCopyTexSubImage2D,
  /** @export */ emscripten_glCopyTexSubImage3D: _emscripten_glCopyTexSubImage3D,
  /** @export */ emscripten_glCreateProgram: _emscripten_glCreateProgram,
  /** @export */ emscripten_glCreateShader: _emscripten_glCreateShader,
  /** @export */ emscripten_glCullFace: _emscripten_glCullFace,
  /** @export */ emscripten_glDeleteBuffers: _emscripten_glDeleteBuffers,
  /** @export */ emscripten_glDeleteFramebuffers: _emscripten_glDeleteFramebuffers,
  /** @export */ emscripten_glDeleteProgram: _emscripten_glDeleteProgram,
  /** @export */ emscripten_glDeleteQueries: _emscripten_glDeleteQueries,
  /** @export */ emscripten_glDeleteQueriesEXT: _emscripten_glDeleteQueriesEXT,
  /** @export */ emscripten_glDeleteRenderbuffers: _emscripten_glDeleteRenderbuffers,
  /** @export */ emscripten_glDeleteSamplers: _emscripten_glDeleteSamplers,
  /** @export */ emscripten_glDeleteShader: _emscripten_glDeleteShader,
  /** @export */ emscripten_glDeleteSync: _emscripten_glDeleteSync,
  /** @export */ emscripten_glDeleteTextures: _emscripten_glDeleteTextures,
  /** @export */ emscripten_glDeleteTransformFeedbacks: _emscripten_glDeleteTransformFeedbacks,
  /** @export */ emscripten_glDeleteVertexArrays: _emscripten_glDeleteVertexArrays,
  /** @export */ emscripten_glDeleteVertexArraysOES: _emscripten_glDeleteVertexArraysOES,
  /** @export */ emscripten_glDepthFunc: _emscripten_glDepthFunc,
  /** @export */ emscripten_glDepthMask: _emscripten_glDepthMask,
  /** @export */ emscripten_glDepthRangef: _emscripten_glDepthRangef,
  /** @export */ emscripten_glDetachShader: _emscripten_glDetachShader,
  /** @export */ emscripten_glDisable: _emscripten_glDisable,
  /** @export */ emscripten_glDisableVertexAttribArray: _emscripten_glDisableVertexAttribArray,
  /** @export */ emscripten_glDrawArrays: _emscripten_glDrawArrays,
  /** @export */ emscripten_glDrawArraysInstanced: _emscripten_glDrawArraysInstanced,
  /** @export */ emscripten_glDrawArraysInstancedANGLE: _emscripten_glDrawArraysInstancedANGLE,
  /** @export */ emscripten_glDrawArraysInstancedARB: _emscripten_glDrawArraysInstancedARB,
  /** @export */ emscripten_glDrawArraysInstancedEXT: _emscripten_glDrawArraysInstancedEXT,
  /** @export */ emscripten_glDrawArraysInstancedNV: _emscripten_glDrawArraysInstancedNV,
  /** @export */ emscripten_glDrawBuffers: _emscripten_glDrawBuffers,
  /** @export */ emscripten_glDrawBuffersEXT: _emscripten_glDrawBuffersEXT,
  /** @export */ emscripten_glDrawBuffersWEBGL: _emscripten_glDrawBuffersWEBGL,
  /** @export */ emscripten_glDrawElements: _emscripten_glDrawElements,
  /** @export */ emscripten_glDrawElementsInstanced: _emscripten_glDrawElementsInstanced,
  /** @export */ emscripten_glDrawElementsInstancedANGLE: _emscripten_glDrawElementsInstancedANGLE,
  /** @export */ emscripten_glDrawElementsInstancedARB: _emscripten_glDrawElementsInstancedARB,
  /** @export */ emscripten_glDrawElementsInstancedEXT: _emscripten_glDrawElementsInstancedEXT,
  /** @export */ emscripten_glDrawElementsInstancedNV: _emscripten_glDrawElementsInstancedNV,
  /** @export */ emscripten_glDrawRangeElements: _emscripten_glDrawRangeElements,
  /** @export */ emscripten_glEnable: _emscripten_glEnable,
  /** @export */ emscripten_glEnableVertexAttribArray: _emscripten_glEnableVertexAttribArray,
  /** @export */ emscripten_glEndQuery: _emscripten_glEndQuery,
  /** @export */ emscripten_glEndQueryEXT: _emscripten_glEndQueryEXT,
  /** @export */ emscripten_glEndTransformFeedback: _emscripten_glEndTransformFeedback,
  /** @export */ emscripten_glFenceSync: _emscripten_glFenceSync,
  /** @export */ emscripten_glFinish: _emscripten_glFinish,
  /** @export */ emscripten_glFlush: _emscripten_glFlush,
  /** @export */ emscripten_glFlushMappedBufferRange: _emscripten_glFlushMappedBufferRange,
  /** @export */ emscripten_glFramebufferRenderbuffer: _emscripten_glFramebufferRenderbuffer,
  /** @export */ emscripten_glFramebufferTexture2D: _emscripten_glFramebufferTexture2D,
  /** @export */ emscripten_glFramebufferTextureLayer: _emscripten_glFramebufferTextureLayer,
  /** @export */ emscripten_glFrontFace: _emscripten_glFrontFace,
  /** @export */ emscripten_glGenBuffers: _emscripten_glGenBuffers,
  /** @export */ emscripten_glGenFramebuffers: _emscripten_glGenFramebuffers,
  /** @export */ emscripten_glGenQueries: _emscripten_glGenQueries,
  /** @export */ emscripten_glGenQueriesEXT: _emscripten_glGenQueriesEXT,
  /** @export */ emscripten_glGenRenderbuffers: _emscripten_glGenRenderbuffers,
  /** @export */ emscripten_glGenSamplers: _emscripten_glGenSamplers,
  /** @export */ emscripten_glGenTextures: _emscripten_glGenTextures,
  /** @export */ emscripten_glGenTransformFeedbacks: _emscripten_glGenTransformFeedbacks,
  /** @export */ emscripten_glGenVertexArrays: _emscripten_glGenVertexArrays,
  /** @export */ emscripten_glGenVertexArraysOES: _emscripten_glGenVertexArraysOES,
  /** @export */ emscripten_glGenerateMipmap: _emscripten_glGenerateMipmap,
  /** @export */ emscripten_glGetActiveAttrib: _emscripten_glGetActiveAttrib,
  /** @export */ emscripten_glGetActiveUniform: _emscripten_glGetActiveUniform,
  /** @export */ emscripten_glGetActiveUniformBlockName: _emscripten_glGetActiveUniformBlockName,
  /** @export */ emscripten_glGetActiveUniformBlockiv: _emscripten_glGetActiveUniformBlockiv,
  /** @export */ emscripten_glGetActiveUniformsiv: _emscripten_glGetActiveUniformsiv,
  /** @export */ emscripten_glGetAttachedShaders: _emscripten_glGetAttachedShaders,
  /** @export */ emscripten_glGetAttribLocation: _emscripten_glGetAttribLocation,
  /** @export */ emscripten_glGetBooleanv: _emscripten_glGetBooleanv,
  /** @export */ emscripten_glGetBufferParameteri64v: _emscripten_glGetBufferParameteri64v,
  /** @export */ emscripten_glGetBufferParameteriv: _emscripten_glGetBufferParameteriv,
  /** @export */ emscripten_glGetBufferPointerv: _emscripten_glGetBufferPointerv,
  /** @export */ emscripten_glGetError: _emscripten_glGetError,
  /** @export */ emscripten_glGetFloatv: _emscripten_glGetFloatv,
  /** @export */ emscripten_glGetFragDataLocation: _emscripten_glGetFragDataLocation,
  /** @export */ emscripten_glGetFramebufferAttachmentParameteriv: _emscripten_glGetFramebufferAttachmentParameteriv,
  /** @export */ emscripten_glGetInteger64i_v: _emscripten_glGetInteger64i_v,
  /** @export */ emscripten_glGetInteger64v: _emscripten_glGetInteger64v,
  /** @export */ emscripten_glGetIntegeri_v: _emscripten_glGetIntegeri_v,
  /** @export */ emscripten_glGetIntegerv: _emscripten_glGetIntegerv,
  /** @export */ emscripten_glGetInternalformativ: _emscripten_glGetInternalformativ,
  /** @export */ emscripten_glGetProgramBinary: _emscripten_glGetProgramBinary,
  /** @export */ emscripten_glGetProgramInfoLog: _emscripten_glGetProgramInfoLog,
  /** @export */ emscripten_glGetProgramiv: _emscripten_glGetProgramiv,
  /** @export */ emscripten_glGetQueryObjecti64vEXT: _emscripten_glGetQueryObjecti64vEXT,
  /** @export */ emscripten_glGetQueryObjectivEXT: _emscripten_glGetQueryObjectivEXT,
  /** @export */ emscripten_glGetQueryObjectui64vEXT: _emscripten_glGetQueryObjectui64vEXT,
  /** @export */ emscripten_glGetQueryObjectuiv: _emscripten_glGetQueryObjectuiv,
  /** @export */ emscripten_glGetQueryObjectuivEXT: _emscripten_glGetQueryObjectuivEXT,
  /** @export */ emscripten_glGetQueryiv: _emscripten_glGetQueryiv,
  /** @export */ emscripten_glGetQueryivEXT: _emscripten_glGetQueryivEXT,
  /** @export */ emscripten_glGetRenderbufferParameteriv: _emscripten_glGetRenderbufferParameteriv,
  /** @export */ emscripten_glGetSamplerParameterfv: _emscripten_glGetSamplerParameterfv,
  /** @export */ emscripten_glGetSamplerParameteriv: _emscripten_glGetSamplerParameteriv,
  /** @export */ emscripten_glGetShaderInfoLog: _emscripten_glGetShaderInfoLog,
  /** @export */ emscripten_glGetShaderPrecisionFormat: _emscripten_glGetShaderPrecisionFormat,
  /** @export */ emscripten_glGetShaderSource: _emscripten_glGetShaderSource,
  /** @export */ emscripten_glGetShaderiv: _emscripten_glGetShaderiv,
  /** @export */ emscripten_glGetString: _emscripten_glGetString,
  /** @export */ emscripten_glGetStringi: _emscripten_glGetStringi,
  /** @export */ emscripten_glGetSynciv: _emscripten_glGetSynciv,
  /** @export */ emscripten_glGetTexParameterfv: _emscripten_glGetTexParameterfv,
  /** @export */ emscripten_glGetTexParameteriv: _emscripten_glGetTexParameteriv,
  /** @export */ emscripten_glGetTransformFeedbackVarying: _emscripten_glGetTransformFeedbackVarying,
  /** @export */ emscripten_glGetUniformBlockIndex: _emscripten_glGetUniformBlockIndex,
  /** @export */ emscripten_glGetUniformIndices: _emscripten_glGetUniformIndices,
  /** @export */ emscripten_glGetUniformLocation: _emscripten_glGetUniformLocation,
  /** @export */ emscripten_glGetUniformfv: _emscripten_glGetUniformfv,
  /** @export */ emscripten_glGetUniformiv: _emscripten_glGetUniformiv,
  /** @export */ emscripten_glGetUniformuiv: _emscripten_glGetUniformuiv,
  /** @export */ emscripten_glGetVertexAttribIiv: _emscripten_glGetVertexAttribIiv,
  /** @export */ emscripten_glGetVertexAttribIuiv: _emscripten_glGetVertexAttribIuiv,
  /** @export */ emscripten_glGetVertexAttribPointerv: _emscripten_glGetVertexAttribPointerv,
  /** @export */ emscripten_glGetVertexAttribfv: _emscripten_glGetVertexAttribfv,
  /** @export */ emscripten_glGetVertexAttribiv: _emscripten_glGetVertexAttribiv,
  /** @export */ emscripten_glHint: _emscripten_glHint,
  /** @export */ emscripten_glInvalidateFramebuffer: _emscripten_glInvalidateFramebuffer,
  /** @export */ emscripten_glInvalidateSubFramebuffer: _emscripten_glInvalidateSubFramebuffer,
  /** @export */ emscripten_glIsBuffer: _emscripten_glIsBuffer,
  /** @export */ emscripten_glIsEnabled: _emscripten_glIsEnabled,
  /** @export */ emscripten_glIsFramebuffer: _emscripten_glIsFramebuffer,
  /** @export */ emscripten_glIsProgram: _emscripten_glIsProgram,
  /** @export */ emscripten_glIsQuery: _emscripten_glIsQuery,
  /** @export */ emscripten_glIsQueryEXT: _emscripten_glIsQueryEXT,
  /** @export */ emscripten_glIsRenderbuffer: _emscripten_glIsRenderbuffer,
  /** @export */ emscripten_glIsSampler: _emscripten_glIsSampler,
  /** @export */ emscripten_glIsShader: _emscripten_glIsShader,
  /** @export */ emscripten_glIsSync: _emscripten_glIsSync,
  /** @export */ emscripten_glIsTexture: _emscripten_glIsTexture,
  /** @export */ emscripten_glIsTransformFeedback: _emscripten_glIsTransformFeedback,
  /** @export */ emscripten_glIsVertexArray: _emscripten_glIsVertexArray,
  /** @export */ emscripten_glIsVertexArrayOES: _emscripten_glIsVertexArrayOES,
  /** @export */ emscripten_glLineWidth: _emscripten_glLineWidth,
  /** @export */ emscripten_glLinkProgram: _emscripten_glLinkProgram,
  /** @export */ emscripten_glMapBufferRange: _emscripten_glMapBufferRange,
  /** @export */ emscripten_glPauseTransformFeedback: _emscripten_glPauseTransformFeedback,
  /** @export */ emscripten_glPixelStorei: _emscripten_glPixelStorei,
  /** @export */ emscripten_glPolygonModeWEBGL: _emscripten_glPolygonModeWEBGL,
  /** @export */ emscripten_glPolygonOffset: _emscripten_glPolygonOffset,
  /** @export */ emscripten_glPolygonOffsetClampEXT: _emscripten_glPolygonOffsetClampEXT,
  /** @export */ emscripten_glProgramBinary: _emscripten_glProgramBinary,
  /** @export */ emscripten_glProgramParameteri: _emscripten_glProgramParameteri,
  /** @export */ emscripten_glQueryCounterEXT: _emscripten_glQueryCounterEXT,
  /** @export */ emscripten_glReadBuffer: _emscripten_glReadBuffer,
  /** @export */ emscripten_glReadPixels: _emscripten_glReadPixels,
  /** @export */ emscripten_glReleaseShaderCompiler: _emscripten_glReleaseShaderCompiler,
  /** @export */ emscripten_glRenderbufferStorage: _emscripten_glRenderbufferStorage,
  /** @export */ emscripten_glRenderbufferStorageMultisample: _emscripten_glRenderbufferStorageMultisample,
  /** @export */ emscripten_glResumeTransformFeedback: _emscripten_glResumeTransformFeedback,
  /** @export */ emscripten_glSampleCoverage: _emscripten_glSampleCoverage,
  /** @export */ emscripten_glSamplerParameterf: _emscripten_glSamplerParameterf,
  /** @export */ emscripten_glSamplerParameterfv: _emscripten_glSamplerParameterfv,
  /** @export */ emscripten_glSamplerParameteri: _emscripten_glSamplerParameteri,
  /** @export */ emscripten_glSamplerParameteriv: _emscripten_glSamplerParameteriv,
  /** @export */ emscripten_glScissor: _emscripten_glScissor,
  /** @export */ emscripten_glShaderBinary: _emscripten_glShaderBinary,
  /** @export */ emscripten_glShaderSource: _emscripten_glShaderSource,
  /** @export */ emscripten_glStencilFunc: _emscripten_glStencilFunc,
  /** @export */ emscripten_glStencilFuncSeparate: _emscripten_glStencilFuncSeparate,
  /** @export */ emscripten_glStencilMask: _emscripten_glStencilMask,
  /** @export */ emscripten_glStencilMaskSeparate: _emscripten_glStencilMaskSeparate,
  /** @export */ emscripten_glStencilOp: _emscripten_glStencilOp,
  /** @export */ emscripten_glStencilOpSeparate: _emscripten_glStencilOpSeparate,
  /** @export */ emscripten_glTexImage2D: _emscripten_glTexImage2D,
  /** @export */ emscripten_glTexImage3D: _emscripten_glTexImage3D,
  /** @export */ emscripten_glTexParameterf: _emscripten_glTexParameterf,
  /** @export */ emscripten_glTexParameterfv: _emscripten_glTexParameterfv,
  /** @export */ emscripten_glTexParameteri: _emscripten_glTexParameteri,
  /** @export */ emscripten_glTexParameteriv: _emscripten_glTexParameteriv,
  /** @export */ emscripten_glTexStorage2D: _emscripten_glTexStorage2D,
  /** @export */ emscripten_glTexStorage3D: _emscripten_glTexStorage3D,
  /** @export */ emscripten_glTexSubImage2D: _emscripten_glTexSubImage2D,
  /** @export */ emscripten_glTexSubImage3D: _emscripten_glTexSubImage3D,
  /** @export */ emscripten_glTransformFeedbackVaryings: _emscripten_glTransformFeedbackVaryings,
  /** @export */ emscripten_glUniform1f: _emscripten_glUniform1f,
  /** @export */ emscripten_glUniform1fv: _emscripten_glUniform1fv,
  /** @export */ emscripten_glUniform1i: _emscripten_glUniform1i,
  /** @export */ emscripten_glUniform1iv: _emscripten_glUniform1iv,
  /** @export */ emscripten_glUniform1ui: _emscripten_glUniform1ui,
  /** @export */ emscripten_glUniform1uiv: _emscripten_glUniform1uiv,
  /** @export */ emscripten_glUniform2f: _emscripten_glUniform2f,
  /** @export */ emscripten_glUniform2fv: _emscripten_glUniform2fv,
  /** @export */ emscripten_glUniform2i: _emscripten_glUniform2i,
  /** @export */ emscripten_glUniform2iv: _emscripten_glUniform2iv,
  /** @export */ emscripten_glUniform2ui: _emscripten_glUniform2ui,
  /** @export */ emscripten_glUniform2uiv: _emscripten_glUniform2uiv,
  /** @export */ emscripten_glUniform3f: _emscripten_glUniform3f,
  /** @export */ emscripten_glUniform3fv: _emscripten_glUniform3fv,
  /** @export */ emscripten_glUniform3i: _emscripten_glUniform3i,
  /** @export */ emscripten_glUniform3iv: _emscripten_glUniform3iv,
  /** @export */ emscripten_glUniform3ui: _emscripten_glUniform3ui,
  /** @export */ emscripten_glUniform3uiv: _emscripten_glUniform3uiv,
  /** @export */ emscripten_glUniform4f: _emscripten_glUniform4f,
  /** @export */ emscripten_glUniform4fv: _emscripten_glUniform4fv,
  /** @export */ emscripten_glUniform4i: _emscripten_glUniform4i,
  /** @export */ emscripten_glUniform4iv: _emscripten_glUniform4iv,
  /** @export */ emscripten_glUniform4ui: _emscripten_glUniform4ui,
  /** @export */ emscripten_glUniform4uiv: _emscripten_glUniform4uiv,
  /** @export */ emscripten_glUniformBlockBinding: _emscripten_glUniformBlockBinding,
  /** @export */ emscripten_glUniformMatrix2fv: _emscripten_glUniformMatrix2fv,
  /** @export */ emscripten_glUniformMatrix2x3fv: _emscripten_glUniformMatrix2x3fv,
  /** @export */ emscripten_glUniformMatrix2x4fv: _emscripten_glUniformMatrix2x4fv,
  /** @export */ emscripten_glUniformMatrix3fv: _emscripten_glUniformMatrix3fv,
  /** @export */ emscripten_glUniformMatrix3x2fv: _emscripten_glUniformMatrix3x2fv,
  /** @export */ emscripten_glUniformMatrix3x4fv: _emscripten_glUniformMatrix3x4fv,
  /** @export */ emscripten_glUniformMatrix4fv: _emscripten_glUniformMatrix4fv,
  /** @export */ emscripten_glUniformMatrix4x2fv: _emscripten_glUniformMatrix4x2fv,
  /** @export */ emscripten_glUniformMatrix4x3fv: _emscripten_glUniformMatrix4x3fv,
  /** @export */ emscripten_glUnmapBuffer: _emscripten_glUnmapBuffer,
  /** @export */ emscripten_glUseProgram: _emscripten_glUseProgram,
  /** @export */ emscripten_glValidateProgram: _emscripten_glValidateProgram,
  /** @export */ emscripten_glVertexAttrib1f: _emscripten_glVertexAttrib1f,
  /** @export */ emscripten_glVertexAttrib1fv: _emscripten_glVertexAttrib1fv,
  /** @export */ emscripten_glVertexAttrib2f: _emscripten_glVertexAttrib2f,
  /** @export */ emscripten_glVertexAttrib2fv: _emscripten_glVertexAttrib2fv,
  /** @export */ emscripten_glVertexAttrib3f: _emscripten_glVertexAttrib3f,
  /** @export */ emscripten_glVertexAttrib3fv: _emscripten_glVertexAttrib3fv,
  /** @export */ emscripten_glVertexAttrib4f: _emscripten_glVertexAttrib4f,
  /** @export */ emscripten_glVertexAttrib4fv: _emscripten_glVertexAttrib4fv,
  /** @export */ emscripten_glVertexAttribDivisor: _emscripten_glVertexAttribDivisor,
  /** @export */ emscripten_glVertexAttribDivisorANGLE: _emscripten_glVertexAttribDivisorANGLE,
  /** @export */ emscripten_glVertexAttribDivisorARB: _emscripten_glVertexAttribDivisorARB,
  /** @export */ emscripten_glVertexAttribDivisorEXT: _emscripten_glVertexAttribDivisorEXT,
  /** @export */ emscripten_glVertexAttribDivisorNV: _emscripten_glVertexAttribDivisorNV,
  /** @export */ emscripten_glVertexAttribI4i: _emscripten_glVertexAttribI4i,
  /** @export */ emscripten_glVertexAttribI4iv: _emscripten_glVertexAttribI4iv,
  /** @export */ emscripten_glVertexAttribI4ui: _emscripten_glVertexAttribI4ui,
  /** @export */ emscripten_glVertexAttribI4uiv: _emscripten_glVertexAttribI4uiv,
  /** @export */ emscripten_glVertexAttribIPointer: _emscripten_glVertexAttribIPointer,
  /** @export */ emscripten_glVertexAttribPointer: _emscripten_glVertexAttribPointer,
  /** @export */ emscripten_glViewport: _emscripten_glViewport,
  /** @export */ emscripten_glWaitSync: _emscripten_glWaitSync,
  /** @export */ emscripten_has_asyncify: _emscripten_has_asyncify,
  /** @export */ emscripten_request_fullscreen_strategy: _emscripten_request_fullscreen_strategy,
  /** @export */ emscripten_request_pointerlock: _emscripten_request_pointerlock,
  /** @export */ emscripten_resize_heap: _emscripten_resize_heap,
  /** @export */ emscripten_sample_gamepad_data: _emscripten_sample_gamepad_data,
  /** @export */ emscripten_set_beforeunload_callback_on_thread: _emscripten_set_beforeunload_callback_on_thread,
  /** @export */ emscripten_set_blur_callback_on_thread: _emscripten_set_blur_callback_on_thread,
  /** @export */ emscripten_set_canvas_element_size: _emscripten_set_canvas_element_size,
  /** @export */ emscripten_set_element_css_size: _emscripten_set_element_css_size,
  /** @export */ emscripten_set_focus_callback_on_thread: _emscripten_set_focus_callback_on_thread,
  /** @export */ emscripten_set_fullscreenchange_callback_on_thread: _emscripten_set_fullscreenchange_callback_on_thread,
  /** @export */ emscripten_set_gamepadconnected_callback_on_thread: _emscripten_set_gamepadconnected_callback_on_thread,
  /** @export */ emscripten_set_gamepaddisconnected_callback_on_thread: _emscripten_set_gamepaddisconnected_callback_on_thread,
  /** @export */ emscripten_set_keydown_callback_on_thread: _emscripten_set_keydown_callback_on_thread,
  /** @export */ emscripten_set_keypress_callback_on_thread: _emscripten_set_keypress_callback_on_thread,
  /** @export */ emscripten_set_keyup_callback_on_thread: _emscripten_set_keyup_callback_on_thread,
  /** @export */ emscripten_set_main_loop_arg: _emscripten_set_main_loop_arg,
  /** @export */ emscripten_set_mousedown_callback_on_thread: _emscripten_set_mousedown_callback_on_thread,
  /** @export */ emscripten_set_mouseenter_callback_on_thread: _emscripten_set_mouseenter_callback_on_thread,
  /** @export */ emscripten_set_mouseleave_callback_on_thread: _emscripten_set_mouseleave_callback_on_thread,
  /** @export */ emscripten_set_mousemove_callback_on_thread: _emscripten_set_mousemove_callback_on_thread,
  /** @export */ emscripten_set_mouseup_callback_on_thread: _emscripten_set_mouseup_callback_on_thread,
  /** @export */ emscripten_set_pointerlockchange_callback_on_thread: _emscripten_set_pointerlockchange_callback_on_thread,
  /** @export */ emscripten_set_resize_callback_on_thread: _emscripten_set_resize_callback_on_thread,
  /** @export */ emscripten_set_touchcancel_callback_on_thread: _emscripten_set_touchcancel_callback_on_thread,
  /** @export */ emscripten_set_touchend_callback_on_thread: _emscripten_set_touchend_callback_on_thread,
  /** @export */ emscripten_set_touchmove_callback_on_thread: _emscripten_set_touchmove_callback_on_thread,
  /** @export */ emscripten_set_touchstart_callback_on_thread: _emscripten_set_touchstart_callback_on_thread,
  /** @export */ emscripten_set_visibilitychange_callback_on_thread: _emscripten_set_visibilitychange_callback_on_thread,
  /** @export */ emscripten_set_wheel_callback_on_thread: _emscripten_set_wheel_callback_on_thread,
  /** @export */ emscripten_set_window_title: _emscripten_set_window_title,
  /** @export */ emscripten_sleep: _emscripten_sleep,
  /** @export */ environ_get: _environ_get,
  /** @export */ environ_sizes_get: _environ_sizes_get,
  /** @export */ exit: _exit,
  /** @export */ fd_close: _fd_close,
  /** @export */ fd_fdstat_get: _fd_fdstat_get,
  /** @export */ fd_read: _fd_read,
  /** @export */ fd_seek: _fd_seek,
  /** @export */ fd_write: _fd_write,
  /** @export */ glActiveTexture: _glActiveTexture,
  /** @export */ glAttachShader: _glAttachShader,
  /** @export */ glBindBuffer: _glBindBuffer,
  /** @export */ glBindSampler: _glBindSampler,
  /** @export */ glBindTexture: _glBindTexture,
  /** @export */ glBindVertexArray: _glBindVertexArray,
  /** @export */ glBlendEquation: _glBlendEquation,
  /** @export */ glBlendEquationSeparate: _glBlendEquationSeparate,
  /** @export */ glBlendFuncSeparate: _glBlendFuncSeparate,
  /** @export */ glBufferData: _glBufferData,
  /** @export */ glBufferSubData: _glBufferSubData,
  /** @export */ glClear: _glClear,
  /** @export */ glClearColor: _glClearColor,
  /** @export */ glCompileShader: _glCompileShader,
  /** @export */ glCreateProgram: _glCreateProgram,
  /** @export */ glCreateShader: _glCreateShader,
  /** @export */ glDeleteShader: _glDeleteShader,
  /** @export */ glDeleteTextures: _glDeleteTextures,
  /** @export */ glDeleteVertexArrays: _glDeleteVertexArrays,
  /** @export */ glDetachShader: _glDetachShader,
  /** @export */ glDisable: _glDisable,
  /** @export */ glDrawElements: _glDrawElements,
  /** @export */ glEnable: _glEnable,
  /** @export */ glEnableVertexAttribArray: _glEnableVertexAttribArray,
  /** @export */ glGenBuffers: _glGenBuffers,
  /** @export */ glGenSamplers: _glGenSamplers,
  /** @export */ glGenTextures: _glGenTextures,
  /** @export */ glGenVertexArrays: _glGenVertexArrays,
  /** @export */ glGetAttribLocation: _glGetAttribLocation,
  /** @export */ glGetIntegerv: _glGetIntegerv,
  /** @export */ glGetProgramInfoLog: _glGetProgramInfoLog,
  /** @export */ glGetProgramiv: _glGetProgramiv,
  /** @export */ glGetShaderInfoLog: _glGetShaderInfoLog,
  /** @export */ glGetShaderiv: _glGetShaderiv,
  /** @export */ glGetString: _glGetString,
  /** @export */ glGetUniformLocation: _glGetUniformLocation,
  /** @export */ glIsEnabled: _glIsEnabled,
  /** @export */ glIsProgram: _glIsProgram,
  /** @export */ glLinkProgram: _glLinkProgram,
  /** @export */ glPixelStorei: _glPixelStorei,
  /** @export */ glSamplerParameteri: _glSamplerParameteri,
  /** @export */ glScissor: _glScissor,
  /** @export */ glShaderSource: _glShaderSource,
  /** @export */ glTexImage2D: _glTexImage2D,
  /** @export */ glTexParameteri: _glTexParameteri,
  /** @export */ glTexSubImage2D: _glTexSubImage2D,
  /** @export */ glUniform1i: _glUniform1i,
  /** @export */ glUniformMatrix4fv: _glUniformMatrix4fv,
  /** @export */ glUseProgram: _glUseProgram,
  /** @export */ glVertexAttribPointer: _glVertexAttribPointer,
  /** @export */ glViewport: _glViewport
};

// Argument name here must shadow the `wasmExports` global so
// that it is recognised by metadce and minify-import-export-names
// passes.
function applySignatureConversions(wasmExports) {
  // First, make a copy of the incoming exports object
  wasmExports = Object.assign({}, wasmExports);
  var makeWrapper_pp = f => a0 => f(a0) >>> 0;
  var makeWrapper_p_ = f => a0 => f(a0) >>> 0;
  var makeWrapper_p = f => () => f() >>> 0;
  wasmExports["malloc"] = makeWrapper_pp(wasmExports["malloc"]);
  wasmExports["strerror"] = makeWrapper_p_(wasmExports["strerror"]);
  wasmExports["emscripten_stack_get_end"] = makeWrapper_p(wasmExports["emscripten_stack_get_end"]);
  wasmExports["emscripten_stack_get_base"] = makeWrapper_p(wasmExports["emscripten_stack_get_base"]);
  wasmExports["emscripten_stack_get_free"] = makeWrapper_p(wasmExports["emscripten_stack_get_free"]);
  wasmExports["_emscripten_stack_alloc"] = makeWrapper_pp(wasmExports["_emscripten_stack_alloc"]);
  wasmExports["emscripten_stack_get_current"] = makeWrapper_p(wasmExports["emscripten_stack_get_current"]);
  return wasmExports;
}

// include: postamble.js
// === Auto-generated postamble setup entry stuff ===
var calledRun;

function callMain(args = []) {
  assert(runDependencies == 0, 'cannot call main when async dependencies remain! (listen on Module["onRuntimeInitialized"])');
  assert(typeof onPreRuns === "undefined" || onPreRuns.length == 0, "cannot call main when preRun functions remain to be called");
  var entryFunction = _main;
  args.unshift(thisProgram);
  var argc = args.length;
  var argv = stackAlloc((argc + 1) * 4);
  var argv_ptr = argv;
  for (var arg of args) {
    HEAPU32[((argv_ptr) >>> 2) >>> 0] = stringToUTF8OnStack(arg);
    argv_ptr += 4;
  }
  HEAPU32[((argv_ptr) >>> 2) >>> 0] = 0;
  try {
    var ret = entryFunction(argc, argv);
    // if we're not running an evented main loop, it's time to exit
    exitJS(ret, /* implicit = */ true);
    return ret;
  } catch (e) {
    return handleException(e);
  }
}

function stackCheckInit() {
  // This is normally called automatically during __wasm_call_ctors but need to
  // get these values before even running any of the ctors so we call it redundantly
  // here.
  _emscripten_stack_init();
  // TODO(sbc): Move writeStackCookie to native to to avoid this.
  writeStackCookie();
}

async function run(args = programArgs) {
  assert(!calledRun);
  calledRun = true;
  stackCheckInit();
  preRun();
  if (runDependencies) {
    await resolveRunDependencies();
  }
  if (ABORT) return;
  initRuntime();
  // No ATMAINS hooks
  Module["onRuntimeInitialized"]?.();
  consumedModuleProp("onRuntimeInitialized");
  var noInitialRun = false;
  if (!noInitialRun) callMain(args);
  postRun();
}

function checkUnflushedContent() {
  // Compiler settings do not allow exiting the runtime, so flushing
  // the streams is not possible. but in ASSERTIONS mode we check
  // if there was something to flush, and if so tell the user they
  // should request that the runtime be exitable.
  // Normally we would not even include flush() at all, but in ASSERTIONS
  // builds we do so just for this check, and here we see if there is any
  // content to flush, that is, we check if there would have been
  // something a non-ASSERTIONS build would have not seen.
  // How we flush the streams depends on whether we are in SYSCALLS_REQUIRE_FILESYSTEM=0
  // mode (which has its own special function for this; otherwise, all
  // the code is inside libc)
  var oldOut = out;
  var oldErr = err;
  var has = false;
  out = err = x => {
    has = true;
  };
  try {
    // it doesn't matter if it fails
    _fflush(0);
    // also flush in the JS FS layer
    for (var name of [ "stdout", "stderr" ]) {
      var info = FS.analyzePath("/dev/" + name);
      if (!info) return;
      var stream = info.object;
      var rdev = stream.rdev;
      var tty = TTY.ttys[rdev];
      if (tty?.output?.length) {
        has = true;
      }
    }
  } catch (e) {}
  out = oldOut;
  err = oldErr;
  if (has) {
    warnOnce("stdio streams had content in them that was not flushed. you should set EXIT_RUNTIME to 1 (see the Emscripten FAQ), or make sure to emit a newline when you printf etc.");
  }
}

var wasmExports;

// With async instantation wasmExports is assigned asynchronously when the
// instance is received.
createWasm().then(() => run());
