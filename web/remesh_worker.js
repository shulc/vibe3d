/* One worker per attempt. Terminating it is the browser equivalent of killing
 * the desktop helper: an abort in geogram cannot take down the editor wasm. */
importScripts('remesh_module.js');

self.onmessage = async event => {
  try {
    const {input, mode, target, adaptivity, sharp} = event.data;
    const remesher = await createRemesher();
    remesher.FS.writeFile('/in.obj', new Uint8Array(input));
    const status = remesher._vibe_remesh(mode, target, adaptivity, sharp);
    if (status !== 0) {
      self.postMessage({ok: false, error: `remesher exited with status ${status}`});
      return;
    }
    const output = remesher.FS.readFile('/out.obj');
    self.postMessage({ok: true, output: output.buffer}, [output.buffer]);
  } catch (error) {
    self.postMessage({ok: false, error: String(error)});
  }
};
