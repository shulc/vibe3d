// CDP driver for the browser file I/O lane (task 7420). It drives the REAL
// editor page with real input: keys through Input.dispatchKeyEvent (which also
// gives the page its user activation), the file chooser through
// Page.setInterceptFileChooserDialog + DOM.setFileInputFiles, and downloads
// through Browser.setDownloadBehavior, whose files are read back as bytes.
// Every assertion waits on a PRODUCTION console line (`WEB-*`).
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

export async function launch({ chromium, url, profile, downloadDir }) {
  const chrome = spawn(chromium, [
    '--headless', '--no-sandbox', '--disable-gpu', '--enable-unsafe-swiftshader',
    '--use-angle=swiftshader', '--window-size=1280,720',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  const wsUrl = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`DevTools endpoint deadline; stderr=${stderr}`)), 15000);
    chrome.stderr.on('data', chunk => {
      stderr += chunk.toString();
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    chrome.once('exit', code => reject(new Error(`Chromium exited before DevTools endpoint (${code})`)));
  });
  const socket = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });

  const pending = new Map();
  let nextId = 1;
  let sessionId;
  const lines = [];          // every WEB-* console line, in arrival order
  const choosers = [];       // Page.fileChooserOpened params
  const downloads = new Map(); // guid -> { name, state }
  const send = (method, params = {}, useSession = true) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    const message = { id, method, params };
    if (useSession && sessionId) message.sessionId = sessionId;
    socket.send(JSON.stringify(message));
  });
  socket.addEventListener('message', event => {
    const m = JSON.parse(event.data);
    if (m.method === 'Runtime.consoleAPICalled') {
      const text = m.params.args.map(a => a.value ?? a.description ?? '').join(' ');
      for (const line of text.split('\n'))
        // `[io] LWO: ` is the LWO reader's own log line (task 7440).
        if (/WEB-|^\[io\] LWO: |Aborted|Unhandled exception|out of memory/i.test(line)) lines.push(line);
      return;
    }
    if (m.method === 'Page.fileChooserOpened') { choosers.push(m.params); return; }
    if (m.method === 'Browser.downloadWillBegin') {
      downloads.set(m.params.guid, { name: m.params.suggestedFilename, state: 'begun' });
      return;
    }
    if (m.method === 'Browser.downloadProgress') {
      const d = downloads.get(m.params.guid) ?? { name: null };
      d.state = m.params.state;
      downloads.set(m.params.guid, d);
      return;
    }
    if (!m.id) return;
    const waiter = pending.get(m.id);
    if (!waiter) return;
    pending.delete(m.id);
    if (m.error) waiter.reject(new Error(JSON.stringify(m.error)));
    else waiter.resolve(m.result);
  });

  const target = await send('Target.createTarget', { url: 'about:blank' }, false);
  const attached = await send('Target.attachToTarget', { targetId: target.targetId, flatten: true }, false);
  sessionId = attached.sessionId;
  await send('Page.enable');
  await send('Runtime.enable');
  await send('DOM.enable');
  await send('Browser.setDownloadBehavior',
    { behavior: 'allowAndName', downloadPath: downloadDir, eventsEnabled: true }, false);
  await send('Page.setInterceptFileChooserDialog', { enabled: true });
  await send('Page.navigate', { url });

  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  // First line matching `pattern` at index >= `from`; returns { line, index }.
  const waitFor = async (pattern, deadlineMs, from = 0) => {
    const started = Date.now();
    while (Date.now() - started < deadlineMs) {
      for (let i = from; i < lines.length; ++i)
        if (pattern.test(lines[i])) return { line: lines[i], index: i };
      await sleep(25);
    }
    throw new Error(`deadline for ${pattern} after line ${from}:\n${lines.slice(from).join('\n')}`);
  };
  const since = (from, pattern) => lines.slice(from).filter(l => pattern.test(l));

  // A key chord with its modifier keys pressed and released around it, so
  // SDL's own modifier state sees them. `mods`: 2 Ctrl, 8 Shift.
  const MODKEYS = [
    { bit: 2, key: 'Control', code: 'ControlLeft', vk: 17 },
    { bit: 8, key: 'Shift', code: 'ShiftLeft', vk: 16 },
  ];
  const chord = async (key, code, vk, mods = 0) => {
    let held = 0;
    for (const m of MODKEYS) if (mods & m.bit) {
      held |= m.bit;
      await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: m.key, code: m.code,
        windowsVirtualKeyCode: m.vk, modifiers: held });
    }
    await send('Input.dispatchKeyEvent', { type: 'keyDown', key, code,
      windowsVirtualKeyCode: vk, modifiers: mods });
    await send('Input.dispatchKeyEvent', { type: 'keyUp', key, code,
      windowsVirtualKeyCode: vk, modifiers: mods });
    for (const m of [...MODKEYS].reverse()) if (mods & m.bit) {
      held &= ~m.bit;
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key: m.key, code: m.code,
        windowsVirtualKeyCode: m.vk, modifiers: held });
    }
  };

  const waitChooser = async (count, deadlineMs) => {
    const started = Date.now();
    while (Date.now() - started < deadlineMs) {
      if (choosers.length >= count) return choosers[count - 1];
      await sleep(25);
    }
    throw new Error(`file chooser #${count} never opened:\n${lines.slice(-20).join('\n')}`);
  };
  const choose = (chooser, files) =>
    send('DOM.setFileInputFiles', { files, backendNodeId: chooser.backendNodeId });

  // The next COMPLETED download after `known` guids; its bytes and sha256.
  const waitDownload = async (knownGuids, deadlineMs) => {
    const started = Date.now();
    while (Date.now() - started < deadlineMs) {
      for (const [guid, d] of downloads)
        if (!knownGuids.has(guid) && d.state === 'completed') {
          const bytes = readFileSync(join(downloadDir, guid));
          return { guid, name: d.name, bytes,
            sha256: createHash('sha256').update(bytes).digest('hex') };
        }
      await sleep(25);
    }
    throw new Error(`no completed download:\n${lines.slice(-20).join('\n')}`);
  };

  const stop = async () => {
    try { socket.close(); } catch {}
    if (chrome.exitCode === null) chrome.kill('SIGTERM');
    await new Promise(resolve => {
      if (chrome.exitCode !== null) resolve();
      else { chrome.once('exit', resolve); setTimeout(() => { chrome.kill('SIGKILL'); resolve(); }, 3000); }
    });
  };

  return { send, lines, choosers, downloads, waitFor, since, chord, waitChooser,
    choose, waitDownload, sleep, stop };
}

export function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}
