// The browser file bridge (task 7420; plan doc/web_file_io_plan_2026-09-23.md
// §3.1, §3.2, §3.6). An Emscripten JS library: D and JS exchange only integers
// and C strings. Open: a one-shot hidden <input type=file> whose files are
// written into the MEMFS directory D names, then D is woken through its two
// exports. Save: the MEMFS file D just wrote is handed to the browser as a
// Blob download. The page never touches FS or the heap.
mergeInto(LibraryManager.library, {
  vibe3d_web_set_dirty: function(dirty) {
    if (typeof window !== 'undefined') window.__vibeDocumentDirty = dirty !== 0;
  },

  // The browser opens its own dialogs for these; the editor owns them.
  // A capture listener on window sees the key before the canvas does, and
  // preventDefault leaves the user activation the chooser needs intact
  // (measured, plan §2 P0-1b).
  $vibe3dFileBridgeKeys__postset: 'vibe3dFileBridgeKeys();',
  $vibe3dFileBridgeKeys: function() {
    if (typeof window === 'undefined') return;
    const kBrowserDialogKeys = ['Ctrl+O', 'Ctrl+S', 'Ctrl+Shift+S'];
    window.addEventListener('keydown', (e) => {
      if (!(e.ctrlKey || e.metaKey) || typeof e.key !== 'string') return;
      const combo = 'Ctrl+' + (e.shiftKey ? 'Shift+' : '') + e.key.toUpperCase();
      if (kBrowserDialogKeys.includes(combo)) e.preventDefault();
    }, {capture: true});
  },

  // Per-pick byte limit (owner Q3); mirrored for the notice text by
  // io.browser_pick_resume.kMaxWebPickBytes.
  $vibe3dMaxPickBytes: 256 * 1024 * 1024,

  vibe3d_web_pick_open__deps: ['$FS', '$UTF8ToString', '$vibe3dFileBridgeKeys',
                               '$vibe3dMaxPickBytes'],
  vibe3d_web_pick_open: function(acceptPtr, multiple, token, dirPtr) {
    // Codes: 0 cancelled, 1 too large, 2 browser read error, 3 MEMFS write
    // error, 4 no user activation.
    const fail = (code) => {
      try { _vibe3d_web_pick_failed(token, code); }
      catch (e) { console.error('file bridge: pick_failed threw: ' + e); }
    };
    if (!(navigator.userActivation && navigator.userActivation.isActive)) {
      fail(4);
      return;
    }
    const accept = UTF8ToString(acceptPtr);
    const dir = UTF8ToString(dirPtr);
    const input = document.createElement('input');
    input.type = 'file';
    // A scene may depend on .mtl, .bin or texture sidecars. Filtering to only
    // the primary extension prevents the user from choosing those siblings.
    input.accept = multiple ? '' : accept;
    input.multiple = multiple !== 0;
    input.style.display = 'none';
    let settled = false;
    const settle = () => {
      if (settled) return false;
      settled = true;
      input.remove();
      return true;
    };
    input.addEventListener('cancel', () => {
      if (!settle()) return;
      console.log('WEB-PICK cancel token=' + token + ' via=cancel');
      fail(0);
    });
    input.addEventListener('change', () => {
      const files = Array.from(input.files || []);
      if (!settle()) return;
      if (files.length === 0) {
        console.log('WEB-PICK cancel token=' + token + ' via=empty-change');
        fail(0);
        return;
      }
      const total = files.reduce((sum, f) => sum + f.size, 0);
      if (total > vibe3dMaxPickBytes) { fail(1); return; }
      Promise.all(files.map((f) => f.arrayBuffer())).then((buffers) => {
        try {
          FS.mkdirTree(dir);
          for (let i = 0; i < files.length; ++i)
            FS.writeFile(dir + '/' + files[i].name, new Uint8Array(buffers[i]));
        } catch (e) {
          console.error('file bridge: MEMFS write failed: ' + e);
          fail(3);
          return;
        }
        console.log('WEB-PICK done token=' + token + ' files=' + files.length);
        try { _vibe3d_web_pick_done(token, files.length); }
        catch (e) { console.error('file bridge: pick_done threw: ' + e); }
      }, (e) => {
        console.error('file bridge: read failed: ' + e);
        fail(2);
      });
    });
    document.body.appendChild(input);
    input.click();
  },

  // 1 = the bytes were handed to the browser's download mechanism (not
  // "received", owner Q6); 0 = the written file could not be read back.
  vibe3d_web_offer_download__deps: ['$FS', '$UTF8ToString'],
  vibe3d_web_offer_download: function(pathPtr) {
    try {
      const path = UTF8ToString(pathPtr);
      let bytes = FS.readFile(path);
      let filename = path.substring(path.lastIndexOf('/') + 1);
      const outputs = window.__vibeAssimpOutputs || [];
      if (outputs.includes(path) && outputs.length > 1) {
        // Store-only ZIP keeps .gltf/.bin and .obj/.mtl together in one
        // browser download; all CRCs and offsets are written explicitly.
        const enc = new TextEncoder();
        const chunks = [], entries = [];
        let offset = 0;
        const pack = (size, write) => {
          const b = new Uint8Array(size), v = new DataView(b.buffer);
          write(v, b); chunks.push(b); offset += size;
        };
        const crc = data => {
          let c = -1;
          for (const byte of data) {
            c ^= byte;
            for (let k=0;k<8;k++) c=(c>>>1)^((c&1)?0xedb88320:0);
          }
          return (c^-1)>>>0;
        };
        for (const file of outputs) {
          const name=enc.encode(file.substring(file.lastIndexOf('/')+1));
          const data=FS.readFile(file), sum=crc(data), start=offset;
          pack(30+name.length, (v,b) => {
            v.setUint32(0,0x04034b50,true); v.setUint16(4,20,true);
            v.setUint32(14,sum,true); v.setUint32(18,data.length,true);
            v.setUint32(22,data.length,true); v.setUint16(26,name.length,true);
            b.set(name,30);
          });
          chunks.push(data); offset += data.length;
          entries.push({name,data,sum,start});
        }
        const directory=offset;
        for (const e of entries) pack(46+e.name.length, (v,b) => {
          v.setUint32(0,0x02014b50,true); v.setUint16(4,20,true);
          v.setUint16(6,20,true); v.setUint32(16,e.sum,true);
          v.setUint32(20,e.data.length,true); v.setUint32(24,e.data.length,true);
          v.setUint16(28,e.name.length,true); v.setUint32(42,e.start,true);
          b.set(e.name,46);
        });
        const directorySize=offset-directory;
        pack(22, v => {
          v.setUint32(0,0x06054b50,true);
          v.setUint16(8,entries.length,true); v.setUint16(10,entries.length,true);
          v.setUint32(12,directorySize,true); v.setUint32(16,directory,true);
        });
        bytes = new Uint8Array(offset);
        let at=0; for (const c of chunks) { bytes.set(c,at); at+=c.length; }
        filename += '.zip';
      }
      window.__vibeAssimpOutputs = null;
      const url = URL.createObjectURL(
        new Blob([bytes], {type: 'application/octet-stream'}));
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
      return 1;
    } catch (e) {
      console.error('file bridge: download failed: ' + e);
      return 0;
    }
  },
});
