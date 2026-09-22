#!/usr/bin/env node
import { spawn } from 'node:child_process';

const [chromium, url, profile, delayArg = '12000'] = process.argv.slice(2);
if (![chromium, url, profile].every(Boolean))
  throw new Error('usage: web_editor_liveness.mjs CHROMIUM URL PROFILE [DELAY_MS]');
const delayedInputMs = Number(delayArg);
const chrome = spawn(chromium, [
  '--headless', '--no-sandbox', '--disable-gpu', '--enable-unsafe-swiftshader',
  '--use-angle=swiftshader', '--window-size=1280,720',
  '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'
], { stdio: ['ignore', 'ignore', 'pipe'] });

let stderr = '';
let socket;
const pending = new Map();
let nextId = 1;
const stop = () => {
  try { socket?.close(); } catch {}
  if (!chrome.killed) chrome.kill('SIGTERM');
};

try {
  const wsUrl = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`DevTools endpoint deadline; stderr=${stderr}`)), 15000);
    chrome.stderr.on('data', chunk => {
      stderr += chunk.toString();
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    chrome.once('exit', code => reject(new Error(`Chromium exited before DevTools endpoint (${code})`)));
  });
  socket = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  let sessionId;
  const send = (method, params = {}, useSession = true) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    const message = { id, method, params };
    if (useSession && sessionId) message.sessionId = sessionId;
    socket.send(JSON.stringify(message));
  });
  const lines = [];
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.consoleAPICalled') {
      const line = message.params.args.map(arg => arg.value ?? arg.description ?? '').join(' ');
      if (/WEB-|Aborted|Unhandled exception|out of memory/i.test(line)) lines.push(line);
      return;
    }
    if (!message.id) return;
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
    else waiter.resolve(message.result);
  });
  const target = await send('Target.createTarget', { url: 'about:blank' }, false);
  const attached = await send('Target.attachToTarget', { targetId: target.targetId, flatten: true }, false);
  sessionId = attached.sessionId;
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.navigate', { url });

  const waitFor = async (pattern, deadlineMs) => {
    const started = Date.now();
    while (Date.now() - started < deadlineMs) {
      const found = lines.find(line => pattern.test(line));
      if (found) return found;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error(`receipt deadline for ${pattern}:\n${lines.join('\n')}`);
  };
  await waitFor(/WEB-RUNNER-INPUT-REQUEST mouse=321,234/, 90000);
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 321, y: 234, buttons: 0, pointerType: 'mouse' });
  await waitFor(/WEB-RUNNER-LIVE .* context=live /, 5000);

  // The second input is deliberately well after startup and first interaction.
  // A startup-only receipt or a queued event cannot satisfy this half.
  await new Promise(resolve => setTimeout(resolve, delayedInputMs));
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65, text: 'a' });
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 654, y: 345, buttons: 0, pointerType: 'mouse' });
  const mouse = await waitFor(/WEB-EDITOR-DELAYED-INPUT source=sdl generation=router .* mouse=654,345/, 5000);
  const live = await waitFor(/WEB-EDITOR-DELAYED-LIVE .* context=live /, 5000);
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65 });
  console.log(mouse);
  console.log(live);
  console.log(`WEB-EDITOR-LIVENESS delayMs=${delayedInputMs} mouse=live key=live`);
} finally {
  stop();
  await new Promise(resolve => {
    if (chrome.exitCode !== null) resolve();
    else { chrome.once('exit', resolve); setTimeout(() => { chrome.kill('SIGKILL'); resolve(); }, 3000); }
  });
}
