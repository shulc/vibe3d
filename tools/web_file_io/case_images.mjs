#!/usr/bin/env node
// Browser cells for image items through the web file bridge (task 7450, plan
// doc/web_file_io_plan_2026-09-23.md S4): Images > Load... through the real
// chooser, undo / redo of it, a save whose downloaded `.v3d` names the image by
// its FILE NAME, a reopen that picks that `.v3d` together with the image and
// resolves it in the NEW pick folder, and the reference-image plane drawing the
// picked PNG's pixels (with the control where the PNG was not picked). One page,
// the cells in order: each cell starts from the state the previous one left.
// Every cell waits on a PRODUCTION console line (`WEB-DOC-STATE`, `WEB-IMAGE`,
// `WEB-WORK-DIRS`) or on the page's own pixels.
import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { launch } from './driver.mjs';

const [chromium, baseUrl, scratch, fixtures, mode] = process.argv.slice(2);
if (![chromium, baseUrl, scratch, fixtures, mode].every(Boolean))
  throw new Error('usage: case_images.mjs CHROMIUM BASE_URL SCRATCH FIXTURES MODE');

const magenta = join(fixtures, 'magenta8.png');
const planeScene = join(fixtures, 'plane_scene.v3d');

// The I3 floor on (255,0,255)+-8 pixels. Derived from the DESKTOP grab of the
// same scene at the lane's window size (1280x720):
//   $ tools/web_file_io/measure_plane_pixels.sh --http-port 8550
//   PLANE-PIXELS no-plane magenta=0 of 1280x720
//   PLANE-PIXELS with-image magenta=192731 of 1280x720
//   PLANE-PIXELS missing magenta=0 of 1280x720
// A quarter of the desktop count: >4x headroom for the browser page's own
// camera and layout, while both controls (I0, I4) must read ZERO. The browser
// page itself measured 149161 of 1280x633 in both artifact modes (2026-09-24).
const MAGENTA_FLOOR = 48000;

const DEADLINE = 20000;
// The cells that actually passed, in order: the summary is built from them,
// and tools/test_web_file_io.sh requires each expected cell line exactly once.
const ran = [];
const ok = (cell, detail) => { ran.push(cell); console.log(`WEB-FILE-IO-CELL ${cell} ok ${detail}`); };
const fail = (cell, why) => { throw new Error(`WEB-FILE-IO-CELL ${cell} FAILED: ${why}`); };

const downloadDir = join(scratch, `downloads-img-${mode}`);
mkdirSync(downloadDir, { recursive: true });
const url = `${baseUrl}/?probe=w17-file-io-img-${mode}&dispatch=image.load`;
const b = await launch({ chromium, url, profile: join(scratch, `profile-img-${mode}`), downloadDir });

const ctrlO = () => b.chord('o', 'KeyO', 79, 2);
const ctrlS = () => b.chord('s', 'KeyS', 83, 2);
const ctrlZ = () => b.chord('z', 'KeyZ', 90, 2);
const ctrlShiftZ = () => b.chord('Z', 'KeyZ', 90, 2 | 8);
const f9 = () => b.chord('F9', 'F9', 120, 0);
const openChooser = async () => {
  const n = b.choosers.length;
  await ctrlO();
  return b.waitChooser(n + 1, DEADLINE);
};
const lastOf = prefix => [...b.lines].reverse().find(l => l.startsWith(prefix));
const undoOf = line => Number(/ undo=(\d+) /.exec(line)[1]);

// The page's own pixels: a PNG of the rendered surface, counted by python
// (PIL, as tools/check_web_frame_pixels.py) for (255,0,255) within +-8.
let shot = 0;
const magentaPixels = async () => {
  await b.sleep(1500);   // a few frames after the state line
  const png = await b.send('Page.captureScreenshot', { format: 'png', fromSurface: true });
  const path = join(scratch, `img-${mode}-${++shot}.png`);
  writeFileSync(path, Buffer.from(png.data, 'base64'));
  const r = spawnSync('python3', ['-c', [
    'import sys',
    'from PIL import Image',
    'im = Image.open(sys.argv[1]).convert("RGB")',
    'print(sum(1 for r, g, b in im.getdata() if r >= 247 and g <= 8 and b >= 247), im.width, im.height)',
  ].join('\n'), path], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`pixel count failed: ${r.stderr}`);
  const [n, w, h] = r.stdout.trim().split(' ').map(Number);
  return { n, size: `${w}x${h}` };
};

try {
  await b.waitFor(/WEB-FIRST-FRAME-COMPLETE/, 90000);

  // I0 start: the default cube, no image, and no magenta on the page — the
  // negative control of I3's pixel floor.
  const i0 = (await b.waitFor(/^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 docPath= dirty=0 /, DEADLINE)).line;
  const u0 = undoOf(i0);
  const px0 = await magentaPixels();
  if (px0.n !== 0) fail('I0', `the start page already has ${px0.n} magenta pixels`);
  ok('I0', `${i0} | magenta=${px0.n} of ${px0.size}`);

  // I1 Images > Load... (the probe door dispatches `image.load {}`, the id the
  // Images panel's Load button sends): ONE file (not a multiple chooser), the
  // picked PNG loads from its pick folder, one undo step.
  let mark = b.lines.length;
  const n1 = b.choosers.length;
  await f9();
  await b.waitFor(/^WEB-PROBE-DISPATCH id=image\.load$/, DEADLINE, mark);
  const ch1 = await b.waitChooser(n1 + 1, DEADLINE);
  if (ch1.mode !== 'selectSingle') fail('I1', `chooser mode ${ch1.mode}`);
  await b.waitFor(/^WEB-PICK-QUEUE parked=1$/, DEADLINE, mark);
  await b.choose(ch1, [magenta]);
  const i1 = (await b.waitFor(new RegExp(
    `^WEB-DOC-STATE layers=2 verts=8 faces=6 images=1 docPath= dirty=1 undo=${u0 + 1} `), DEADLINE, mark));
  const img1 = (await b.waitFor(/^WEB-IMAGE dims=8x8 missing=0 path=\/work\/(\d+)\/magenta8\.png$/,
    DEADLINE, i1.index)).line;
  const t1 = /\/work\/(\d+)\//.exec(img1)[1];
  ok('I1', `${i1.line} | ${img1}`);

  // I2 undo removes the image item, redo brings the SAME one back (I5 saves it).
  mark = b.lines.length;
  await ctrlZ();
  const i2u = (await b.waitFor(new RegExp(
    `^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 .* undo=${u0} `), DEADLINE, mark)).line;
  mark = b.lines.length;
  await ctrlShiftZ();
  const i2r = await b.waitFor(new RegExp(
    `^WEB-DOC-STATE layers=2 verts=8 faces=6 images=1 .* undo=${u0 + 1} `), DEADLINE, mark);
  await b.waitFor(new RegExp(`^WEB-IMAGE dims=8x8 missing=0 path=/work/${t1}/magenta8\\.png$`),
    DEADLINE, i2r.index);
  ok('I2', `${i2u} | ${i2r.line}`);

  // I5 Ctrl+S of the untitled document: Untitled.v3d downloads, and its JSON
  // names the image by its FILE NAME — not `../<t1>/magenta8.png`, the form the
  // desktop's parent anchor gives (plan §3.8; owner Q1).
  let known = new Set(b.downloads.keys());
  mark = b.lines.length;
  await ctrlS();
  const d5 = await b.waitDownload(known, DEADLINE);
  if (d5.name !== 'Untitled.v3d') fail('I5', `download named ${d5.name}`);
  const saved = JSON.parse(d5.bytes.toString('utf8'));
  const imageBlocks = (saved.layers ?? []).filter(l => l.image !== undefined);
  if (imageBlocks.length !== 1) fail('I5', `${imageBlocks.length} "image" blocks in the download`);
  const stored = imageBlocks[0].image.filename;
  if (stored !== 'magenta8.png') fail('I5', `the download stores "filename": ${JSON.stringify(stored)}`);
  await b.waitFor(/^WEB-DOC-STATE .* docPath=\/work\/untitled\/Untitled\.v3d dirty=0 /, DEADLINE, mark);
  ok('I5', `name=${d5.name} bytes=${d5.bytes.length} filename=${stored}`);

  // I6 reopen by picking the download TOGETHER with the image: the image
  // resolves in the new pick folder <t2>, not in the copy I1 left in <t1>,
  // which is still in MEMFS at this moment (the floor that makes t2 != t1 mean
  // anything).
  const dirs6 = lastOf('WEB-WORK-DIRS ');
  if (!dirs6.replace('WEB-WORK-DIRS dirs=', '').split(',').includes(t1))
    fail('I6', `the stale copy's folder ${t1} is already gone: ${dirs6}`);
  const reopenDir = join(scratch, `reopen-${mode}`);
  mkdirSync(reopenDir, { recursive: true });
  const reopenPath = join(reopenDir, 'Untitled.v3d');
  copyFileSync(join(downloadDir, d5.guid), reopenPath);   // the download's own bytes, under its name
  mark = b.lines.length;
  const ch6 = await openChooser();
  if (ch6.mode !== 'selectMultiple') fail('I6', `chooser mode ${ch6.mode}`);
  await b.choose(ch6, [reopenPath, magenta]);
  const i6 = await b.waitFor(
    /^WEB-DOC-STATE layers=2 verts=8 faces=6 images=1 docPath=\/work\/(\d+)\/Untitled\.v3d dirty=0 /, DEADLINE, mark);
  const t2 = /docPath=\/work\/(\d+)\//.exec(i6.line)[1];
  const img6 = (await b.waitFor(/^WEB-IMAGE /, DEADLINE, i6.index)).line;
  if (img6 !== `WEB-IMAGE dims=8x8 missing=0 path=/work/${t2}/magenta8.png`)
    fail('I6', `the reopened image resolves as ${img6} (document folder ${t2}, stale copy ${t1})`);
  if (t2 === t1) fail('I6', `the reopen reused /work/${t1}`);
  // The owner's MEMFS rule: this Open sweeps the earlier folders (the stale
  // copy's and the untitled save's) and keeps the new document's.
  const swept6 = (await b.waitFor(new RegExp(`^WEB-WORK-DIRS dirs=${t2}$`), DEADLINE, mark)).line;
  ok('I6', `${dirs6} -> ${swept6} | ${i6.line} | ${img6}`);

  // I3 open plane_scene.v3d picked with magenta8.png: the plane's image is
  // found, and the page draws its pixels.
  mark = b.lines.length;
  const ch3 = await openChooser();
  await b.choose(ch3, [planeScene, magenta]);
  const i3 = await b.waitFor(
    /^WEB-DOC-STATE layers=3 verts=8 faces=6 images=1 docPath=\/work\/(\d+)\/plane_scene\.v3d dirty=0 /, DEADLINE, mark);
  const t3 = /docPath=\/work\/(\d+)\//.exec(i3.line)[1];
  const img3 = (await b.waitFor(/^WEB-IMAGE /, DEADLINE, i3.index)).line;
  if (img3 !== `WEB-IMAGE dims=8x8 missing=0 path=/work/${t3}/magenta8.png`)
    fail('I3', `the plane's image resolves as ${img3}`);
  const px3 = await magentaPixels();
  if (px3.n < MAGENTA_FLOOR) fail('I3', `${px3.n} magenta pixels < floor ${MAGENTA_FLOOR}`);
  ok('I3', `${img3} | magenta=${px3.n} of ${px3.size} floor=${MAGENTA_FLOOR}`);

  // I4 the same document picked WITHOUT its image: missing, and no magenta —
  // the control that must flip against I3.
  mark = b.lines.length;
  const ch4 = await openChooser();
  await b.choose(ch4, [planeScene]);
  const i4 = await b.waitFor(
    /^WEB-DOC-STATE layers=3 verts=8 faces=6 images=1 docPath=\/work\/(\d+)\/plane_scene\.v3d dirty=0 /, DEADLINE, mark);
  const t4 = /docPath=\/work\/(\d+)\//.exec(i4.line)[1];
  const img4 = (await b.waitFor(/^WEB-IMAGE /, DEADLINE, i4.index)).line;
  if (!new RegExp(`^WEB-IMAGE dims=\\d+x\\d+ missing=1 path=/work/${t4}/magenta8\\.png$`).test(img4))
    fail('I4', `without the picked PNG the image reads ${img4}`);
  const px4 = await magentaPixels();
  if (px4.n !== 0) fail('I4', `${px4.n} magenta pixels with the image missing`);
  ok('I4', `${img4} | magenta=${px4.n} of ${px4.size}`);

  console.log(`WEB-FILE-IO-IMG mode=${mode} cells=${ran.join(',')} ok`);
} catch (e) {
  console.log(b.lines.slice(-40).join('\n'));
  console.log('CHOOSERS ' + JSON.stringify(b.choosers));
  throw e;
} finally {
  await b.stop();
}
