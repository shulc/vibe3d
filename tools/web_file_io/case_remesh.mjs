#!/usr/bin/env node
import assert from 'node:assert/strict';
import {mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {launch} from './driver.mjs';

const [chromium, base, scratch] = process.argv.slice(2);
const downloadDir = join(scratch, 'downloads');
mkdirSync(downloadDir, {recursive: true});
const url = `${base}/?probe=web-remesh&dispatch=mesh.remesh.start`
  + `&dispatchArgs=${encodeURIComponent(JSON.stringify({targetQuads:128}))}`;
const b = await launch({chromium, url, profile:join(scratch,'profile'), downloadDir});
try {
  await b.waitFor(/WEB-FIRST-FRAME-COMPLETE/, 90000);
  const before = (await b.waitFor(/^WEB-DOC-STATE layers=1 verts=8 faces=6 .* undo=0 /, 30000)).line;
  await b.chord('F9','F9',120);
  await b.waitFor(/^WEB-PROBE-DISPATCH id=mesh\.remesh\.start$/, 20000);
  await b.waitFor(/^WEB-REMESH-WORKER started mode=0$/, 20000);
  await b.waitFor(/^WEB-REMESH-WORKER result=success$/, 90000);
  const result = (await b.waitFor(/^WEB-REMESH-RESULT faces=\d+ quads=\d+$/,30000)).line;
  assert.ok(Number(/quads=(\d+)/.exec(result)[1]) > 0,
    'landed remesh produced no quad polygons');
  const landed = (await b.waitFor(/^WEB-DOC-STATE layers=1 verts=\d+ faces=\d+ .* undo=1 /, 90000)).line;
  assert.notEqual(landed.match(/verts=\d+ faces=\d+/)[0], before.match(/verts=\d+ faces=\d+/)[0]);
  await b.chord('z','KeyZ',90,2);
  await b.waitFor(/^WEB-DOC-STATE layers=1 verts=8 faces=6 .* undo=0 /, 30000,
                  b.lines.findIndex(line => line === landed) + 1);
  await b.chord('Z','KeyZ',90,2|8);
  await b.waitFor(/^WEB-DOC-STATE layers=1 verts=\d+ faces=\d+ .* undo=1 /, 30000,
                  b.lines.findIndex(line => line === landed) + 1);
  console.log(`WEB-REMESH-COMMAND success undo redo ${result} ${landed}`);
} catch (error) {
  console.log(b.lines.slice(-45).join('\n'));
  throw error;
} finally {
  await b.stop();
}

// The modal drives the same job. Its Cancel button must terminate the worker
// while the editor stays on the original document.
const cancel = await launch({
  chromium,
  url:`${base}/?probe=web-remesh-cancel&dispatch=mesh.remesh.open`,
  profile:join(scratch,'profile-cancel'), downloadDir
});
const click = async (x,y) => {
  await cancel.send('Input.dispatchMouseEvent',{type:'mouseMoved',x,y});
  await cancel.send('Input.dispatchMouseEvent',{type:'mousePressed',x,y,button:'left',clickCount:1});
  await cancel.send('Input.dispatchMouseEvent',{type:'mouseReleased',x,y,button:'left',clickCount:1});
};
const workerTargets = async () => {
  const {targetInfos} = await cancel.send('Target.getTargets',{},false);
  return targetInfos.filter(target => target.type === 'worker');
};
try {
  await cancel.waitFor(/WEB-FIRST-FRAME-COMPLETE/,90000);
  await cancel.send('Target.setDiscoverTargets',{discover:true},false);
  if (process.env.VIBE3D_TEST_REMESH_CANCEL_MUTATION === '1')
    await cancel.send('Runtime.evaluate',{
      expression:'Worker.prototype.terminate = function() {}'
    });
  await cancel.chord('F9','F9',120);
  await cancel.waitFor(/^WEB-PROBE-DISPATCH id=mesh\.remesh\.open$/,20000);
  await cancel.sleep(200);
  await click(475,365); // modal's Remesh button at 1280x720
  await cancel.waitFor(/^WEB-REMESH-WORKER started mode=0$/,20000);
  assert.ok((await workerTargets()).length > 0, 'remesh Worker target never appeared');
  await click(550,365); // busy row's Cancel button
  await cancel.waitFor(/^WEB-REMESH-WORKER cancelled$/,20000);
  await cancel.sleep(300);
  assert.equal((await workerTargets()).length,0, 'Cancel left the remesh Worker alive');
  assert.equal(cancel.since(0,/^WEB-REMESH-WORKER result=/).length,0);
  assert.equal(cancel.since(0,/^WEB-DOC-STATE .* undo=1 /).length,0);
  console.log('WEB-REMESH-COMMAND modal cancel retained original document');
} catch (error) {
  console.log(cancel.lines.slice(-45).join('\n'));
  throw error;
} finally {
  await cancel.stop();
}

// A picked polygon switches the production command to the open-patch path;
// the returned patch is stitched into the unchanged rest of the cube.
const region = await launch({
  chromium,
  url:`${base}/?probe=web-remesh-region&dispatch=mesh.remesh.start`
    + `&dispatchArgs=${encodeURIComponent(JSON.stringify({targetQuads:64}))}`,
  profile:join(scratch,'profile-region'), downloadDir
});
const regionClick = async (x,y) => {
  await region.send('Input.dispatchMouseEvent',{type:'mouseMoved',x,y});
  await region.send('Input.dispatchMouseEvent',{type:'mousePressed',x,y,button:'left',clickCount:1});
  await region.send('Input.dispatchMouseEvent',{type:'mouseReleased',x,y,button:'left',clickCount:1});
};
try {
  await region.waitFor(/WEB-FIRST-FRAME-COMPLETE/,90000);
  await region.chord('3','Digit3',51);
  await region.sleep(200);
  await regionClick(590,305);
  await region.chord('F9','F9',120);
  await region.waitFor(/^WEB-PROBE-DISPATCH id=mesh\.remesh\.start$/,20000);
  await region.waitFor(/^WEB-REMESH-WORKER started mode=1$/,20000);
  const result = (await region.waitFor(/^WEB-REMESH-RESULT faces=\d+ quads=\d+$/,90000)).line;
  assert.ok(Number(/quads=(\d+)/.exec(result)[1]) > 0);
  const landed = (await region.waitFor(/^WEB-DOC-STATE layers=1 verts=\d+ faces=\d+ .* undo=1 /,30000)).line;
  assert.ok(Number(/faces=(\d+)/.exec(landed)[1]) > 6);
  console.log(`WEB-REMESH-COMMAND selected region ${result} ${landed}`);
} catch (error) {
  console.log(region.lines.slice(-45).join('\n'));
  throw error;
} finally {
  await region.stop();
}
