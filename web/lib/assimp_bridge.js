// The editor and Assimp have separate WebAssembly memories and exception ABIs.
// Only copied files and V3DI bytes cross this Emscripten JS library.
mergeInto(LibraryManager.library, {
  vibe3d_web_assimp_available: function() {
    return typeof window !== 'undefined' && !!window.__vibeAssimp ? 1 : 0;
  },
  vibe3d_web_assimp_import__deps: ['$FS', '$UTF8ToString', 'malloc'],
  vibe3d_web_assimp_import: function(pathPtr, dataPtr, lengthPtr) {
    const a = window.__vibeAssimp;
    if (!a) return 0;
    try {
      const path = UTF8ToString(pathPtr);
      const dir = path.substring(0, path.lastIndexOf('/'));
      a.FS.mkdirTree(dir);
      for (const name of FS.readdir(dir)) {
        if (name === '.' || name === '..') continue;
        const source = dir + '/' + name;
        if (FS.isFile(FS.stat(source).mode)) a.FS.writeFile(source, FS.readFile(source));
      }
      const p = a._malloc(a.lengthBytesUTF8(path) + 1);
      a.stringToUTF8(path, p, a.lengthBytesUTF8(path) + 1);
      const ok = a._vibe_import_file(p);
      a._free(p);
      if (!ok) { console.error('assimp import: ' + a.UTF8ToString(a._vibe_error())); return 0; }
      const len = a._vibe_result_len();
      const dst = _malloc(len);
      if (!dst) return 0;
      HEAPU8.set(a.HEAPU8.subarray(a._vibe_result_ptr(), a._vibe_result_ptr() + len), dst);
      HEAPU32[dataPtr >> 2] = dst;
      HEAPU32[lengthPtr >> 2] = len;
      return 1;
    } catch (e) { console.error('assimp import bridge:', e); return 0; }
  },
  vibe3d_web_assimp_free__deps: ['free'],
  vibe3d_web_assimp_free: function(ptr) { _free(ptr); },
  vibe3d_web_assimp_export__deps: ['$FS', '$UTF8ToString'],
  vibe3d_web_assimp_export: function(dataPtr, length, formatPtr, pathPtr) {
    const a = window.__vibeAssimp;
    if (!a) return 0;
    const allocString = s => { const n=a.lengthBytesUTF8(s)+1, p=a._malloc(n); a.stringToUTF8(s,p,n); return p; };
    try {
      const path=UTF8ToString(pathPtr), format=UTF8ToString(formatPtr);
      const dir=path.substring(0,path.lastIndexOf('/'));
      a.FS.mkdirTree(dir); FS.mkdirTree(dir);
      for (const name of a.FS.readdir(dir)) {
        if (name !== '.' && name !== '..' && a.FS.isFile(a.FS.stat(dir+'/'+name).mode))
          a.FS.unlink(dir+'/'+name);
      }
      const wire=a._malloc(length), fp=allocString(format), pp=allocString(path);
      a.HEAPU8.set(HEAPU8.subarray(dataPtr,dataPtr+length),wire);
      const ok=a._vibe_export_file(wire,length,fp,pp);
      a._free(wire); a._free(fp); a._free(pp);
      if (!ok) { console.error('assimp export: ' + a.UTF8ToString(a._vibe_error())); return 0; }
      const outputs=[];
      for (const name of a.FS.readdir(dir)) {
        if (name==='.'||name==='..') continue;
        const source=dir+'/'+name;
        if (a.FS.isFile(a.FS.stat(source).mode)) {
          FS.writeFile(source,a.FS.readFile(source));
          outputs.push(source);
        }
      }
      window.__vibeAssimpOutputs = outputs;
      return 1;
    } catch (e) { console.error('assimp export bridge:', e); return 0; }
  }
});
