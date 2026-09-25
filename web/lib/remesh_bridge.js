// The D editor and AutoRemesher use separate wasm memories. OBJ bytes are
// copied through Worker messages; no C++ exception or pointer crosses over.
mergeInto(LibraryManager.library, {
  $vibeRemesh: { worker: null, status: 0, output: '', log: '' },
  vibe3d_web_remesh_start__deps: ['$FS', '$UTF8ToString', '$vibeRemesh'],
  vibe3d_web_remesh_start: function(inputPtr, outputPtr, logPtr,
                                     mode, target, adaptivity, sharp) {
    if (typeof Worker === 'undefined') return 0;
    try {
      const input = FS.readFile(UTF8ToString(inputPtr));
      const output = UTF8ToString(outputPtr);
      const log = UTF8ToString(logPtr);
      const worker = new Worker('remesh_worker.js');
      vibeRemesh.worker = worker;
      vibeRemesh.output = output;
      vibeRemesh.log = log;
      vibeRemesh.status = 0;
      worker.onmessage = event => {
        if (vibeRemesh.worker !== worker) return;
        try {
          if (event.data.ok) {
            FS.writeFile(output, new Uint8Array(event.data.output));
            vibeRemesh.status = 1;
            console.log('WEB-REMESH-WORKER result=success');
          } else {
            FS.writeFile(log, event.data.error || 'remesh failed');
            vibeRemesh.status = -1;
            console.log('WEB-REMESH-WORKER result=failed');
          }
        } catch (error) {
          FS.writeFile(log, String(error));
          vibeRemesh.status = -1;
        }
        worker.terminate();
        vibeRemesh.worker = null;
      };
      worker.onerror = event => {
        if (vibeRemesh.worker !== worker) return;
        FS.writeFile(log, event.message || 'remesh worker crashed');
        vibeRemesh.status = -1;
        console.log('WEB-REMESH-WORKER result=error');
        worker.terminate();
        vibeRemesh.worker = null;
      };
      worker.postMessage({input: input.buffer, mode, target, adaptivity, sharp},
                         [input.buffer]);
      console.log('WEB-REMESH-WORKER started mode=' + mode);
      return 1;
    } catch (error) {
      if (vibeRemesh.worker) vibeRemesh.worker.terminate();
      vibeRemesh.worker = null;
      vibeRemesh.status = 0;
      console.error('remesh worker start:', error);
      return 0;
    }
  },
  vibe3d_web_remesh_poll__deps: ['$vibeRemesh'],
  vibe3d_web_remesh_poll: function() {
    const status = vibeRemesh.status;
    if (status) vibeRemesh.status = 0;
    return status;
  },
  vibe3d_web_remesh_cancel__deps: ['$vibeRemesh'],
  vibe3d_web_remesh_cancel: function() {
    if (vibeRemesh.worker) {
      vibeRemesh.worker.terminate();
      console.log('WEB-REMESH-WORKER cancelled');
    }
    vibeRemesh.worker = null;
    vibeRemesh.status = 0;
  }
});
