import {createRequire} from 'node:module';
import {resolve} from 'node:path';

const require = createRequire(import.meta.url);
const createRemesher = require(resolve(process.argv[2] || '.build/web-remesh/remesh_module.js'));
const remesher = await createRemesher();
const cube = `v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
f 1 3 2
f 1 4 3
f 5 6 7
f 5 7 8
f 1 2 6
f 1 6 5
f 2 3 7
f 2 7 6
f 3 4 8
f 3 8 7
f 4 1 5
f 4 5 8
`;
remesher.FS.writeFile('/in.obj', cube);
const status = remesher._vibe_remesh(0, 128, 1, 90);
if (status !== 0) throw new Error(`closed remesh status ${status}`);
const output = remesher.FS.readFile('/out.obj', {encoding: 'utf8'});
const faces = output.split('\n').filter(line => line.startsWith('f '));
const quads = faces.filter(line => line.trim().split(/\s+/).length === 5);
if (faces.length === 0 || quads.length === 0)
  throw new Error(`no quad result: ${faces.length} faces, ${quads.length} quads`);
console.log(`WEB-REMESH cube faces=${faces.length} quads=${quads.length}`);

// The selected-region path uses both C ABI modes. A planar grid has an open
// boundary, so it exercises the quad patch and the triangle fallback.
let patch = '';
for (let y = 0; y < 5; ++y)
  for (let x = 0; x < 5; ++x) patch += `v ${x} ${y} 0\n`;
for (let y = 0; y < 4; ++y)
  for (let x = 0; x < 4; ++x) {
    const a = y*5+x+1, b=a+1, c=a+5, d=c+1;
    patch += `f ${a} ${b} ${d}\nf ${a} ${d} ${c}\n`;
  }
for (const mode of [1,2]) {
  remesher.FS.writeFile('/in.obj', patch);
  const status = remesher._vibe_remesh(mode, 16, 0, 90);
  if (status !== 0) throw new Error(`patch mode ${mode} status ${status}`);
  const result = remesher.FS.readFile('/out.obj', {encoding: 'utf8'});
  const faces = result.split('\n').filter(line => line.startsWith('f '));
  const quads = faces.filter(line => line.trim().split(/\s+/).length === 5);
  if (faces.length === 0 || (mode === 1 && quads.length === 0))
    throw new Error(`patch mode ${mode} produced no useful faces`);
  console.log(`WEB-REMESH patch mode=${mode} faces=${faces.length} quads=${quads.length}`);
}
