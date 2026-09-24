import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const artifactDir = process.argv[2];
const fixture = process.argv[3];
if (!artifactDir || !fixture)
  throw new Error('usage: node run.mjs <artifact-dir> <glb-fixture>');

const assimp = await require(`${artifactDir}/assimp_module.js`)();
const d = await require(`${artifactDir}/d_consumer.js`)();
assert.equal(assimp._vibe_eh_probe(), 7, 'C++ throw/catch runs inside Assimp wasm');
assert.equal(d._vibe_d_eh_probe(), 11, 'D throw/catch runs inside D wasm');
assert.notEqual(assimp.HEAPU8.buffer, d.HEAPU8.buffer, 'separate wasm memories');

const file = readFileSync(fixture);
const source = assimp._malloc(file.length);
assimp.HEAPU8.set(file, source);
assert.equal(assimp._vibe_import_glb(source, file.length), 1,
  `valid .glb import: ${assimp.UTF8ToString(assimp._vibe_error())}`);
assimp._free(source);
const wireSize = assimp._vibe_result_len();
const wire = Uint8Array.from(assimp.HEAPU8.subarray(
  assimp._vibe_result_ptr(), assimp._vibe_result_ptr() + wireSize));
assert.ok(wireSize > 12 && wireSize < file.length * 8, 'nonempty bounded wire');
const target = d._malloc(wireSize);
d.HEAPU8.set(wire, target);
assert.equal(d._vibe_consume_scene(target, wireSize), 1, 'D accepts geometry wire');
const counts = [d._vibe_d_parts(), d._vibe_d_vertices(), d._vibe_d_faces()];
assert.ok(counts.every(value => value > 0), 'scene contains geometry');
console.log(`VALID source=${file.length} wire=${wireSize} parts=${counts[0]} vertices=${counts[1]} faces=${counts[2]}`);

// Deliberate corruption must turn the otherwise-green D check red.
d.HEAPU8[target] ^= 0xff;
assert.equal(d._vibe_consume_scene(target, wireSize), 0, 'D rejects bad wire magic');
d._free(target);

const broken = new Uint8Array([0x67, 0x6c, 0x54, 0x46, 0, 0, 0, 0]);
const badSource = assimp._malloc(broken.length);
assimp.HEAPU8.set(broken, badSource);
assert.equal(assimp._vibe_import_glb(badSource, broken.length), 0, 'Assimp rejects broken glb');
assert.ok(assimp.UTF8ToString(assimp._vibe_error()).length > 0, 'error text survives');
console.log(`BAD-GLB ${assimp.UTF8ToString(assimp._vibe_error())}`);
assimp._free(badSource);
