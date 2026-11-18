// API key capture against a fake provider: the key is shown after "Create", and Claude must never see it.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { Guard } from '../src/guard.mjs';

const KEY = 'Q7mZp2Lx9KvT4rW8nYb3HcJ6dF1sGa5E';      // no known prefix
const KEY2 = 'Hn4Wq8Rt2Yv6Kp9Ls3Df7Gj1Za5Xc0Bm';     // leaked through the page title before capture
const KEY3 = 'Tz5Nc8Vb1Qw4Ex7Ry2Ui6Op9As3Df0Gh';  // next to a Done button
const OPENAI_STYLE = 'sk-proj-' + 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6';

const dialog = (k) => `<div role=dialog><p>Your new key:</p>
  <p class=split><span>${k.slice(0, 8)}</span><span>${k.slice(8, 20)}</span><span>${k.slice(20)}</span></p>
  <input readonly value="${k}">
  <iframe srcdoc="<code>${k}</code>"></iframe>
  <button onclick="navigator.clipboard.writeText('${k}').then(() => s.textContent = 'copied', () => s.textContent = 'clipboard blocked')">Copy</button>
  <button onclick="s.textContent = document.execCommand('copy') ? 'copied' : 'copy blocked'">Copy (old way)</button>
  <p id=s></p></div>`;

const pages = {
  '/keys': `<title>Settings</title><h1>Project settings</h1><p>Existing: build 2026-11-18 ref Abc123def456Ghi</p>
    <template id=t>${dialog(KEY)}</template><button onclick="document.body.append(t.content.cloneNode(true))">Create secret key</button>`,
  '/dashboard': `<title>Dashboard</title><h1>Welcome</h1><template id=t>${dialog(KEY)}</template><button onclick="document.body.append(t.content.cloneNode(true))">Continue</button>`,
  '/canvas': `<title>API keys</title><h1>API keys</h1><canvas id=c width=400 height=40></canvas>
    <button onclick="c.getContext('2d').fillText('${KEY}', 10, 20)">Generate new key</button>`,
  '/done': `<title>Keys</title><h1>Keys</h1><template id=t><div role=dialog><code>${KEY3}</code><button>Done</button></div></template>
    <button onclick="document.body.append(t.content.cloneNode(true))">Create key</button>`,
  '/prefix':`<title>Docs</title><p>Example: ${OPENAI_STYLE}</p>`,
  '/leak': `<title>${KEY2}</title><h1>Account</h1>
    <template id=t>${dialog(KEY2)}</template><button onclick="document.body.append(t.content.cloneNode(true))">Create secret key</button>`,
};

let srv, base, c, dataDir, log;
const call = async (name, args = {}) => {
  const r = await c.callTool({ name, arguments: args });
  return { ...r, text: (r.content || []).filter((x) => x.type === 'text').map((x) => x.text).join('\n') };
};
const outputFiles = () => {
  const out = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); e.isDirectory() ? walk(p) : out.push(p); } };
  walk(path.join(dataDir, 'output'));
  return out.filter((p) => !p.endsWith('.png')).map((p) => fs.readFileSync(p, 'utf8')).join('\n');
};
const noKey = (s, where, k = KEY) => {
  for (const piece of [k, k.slice(0, 8), k.slice(8, 20), k.slice(20), Buffer.from(k).toString('base64').replace(/=+$/, '')]) {
    assert.ok(!s.includes(piece), `key piece "${piece}" leaked in ${where}:\n${s.slice(0, 600)}`);
  }
};
const saved = () => fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((x) => x.cmd === 'save-key');

before(async () => {
  srv = http.createServer((req, res) => { res.writeHead(200, { 'content-type': 'text/html' }); res.end(pages[req.url] || 'home'); });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${srv.address().port}`;
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kdk-'));
  log = path.join(dataDir, 'log.jsonl'); fs.writeFileSync(log, '');
  c = new Client({ name: 't', version: '1' });
  await c.connect(new StdioClientTransport({
    command: process.execPath,
    args: ['src/server.mjs', '--headless', '--data-dir', dataDir, '--helper', 'test/fake-helper.mjs'],
    env: { ...process.env, KDLOGIN_FAKE_SITE: base, KDLOGIN_FAKE_LOG: log, KDLOGIN_FAKE_STATE: path.join(dataDir, 'pages.json') },
    stderr: 'inherit',
  }));
});
after(async () => { await c.close(); srv.close(); });

test('click "Create secret key": no-prefix key hidden everywhere, split text and iframe included', async () => {
  await call('browser_navigate', { url: `${base}/keys` });
  const snap0 = await call('browser_snapshot');
  const ref = snap0.text.match(/button "Create secret key" \[ref=([a-z0-9]+)\]/)[1];
  const click = await call('browser_click', { element: 'Create secret key button', target: ref });
  noKey(click.text, 'click result');
  const snap = await call('browser_snapshot');
  noKey(snap.text, 'snapshot');
  assert.match(snap.text, /\[key hidden …Ga5E\]/);
  assert.match(snap.text, /Abc123def456Ghi/, 'values that were already on the page stay visible');
  noKey(outputFiles(), 'output files');
});

test('while a key is showing: JS, screenshots, clipboard and copy keys are blocked', async () => {
  assert.ok((await call('browser_evaluate', { function: '() => document.body.innerText' })).isError);
  const shot = await call('browser_take_screenshot', {});
  assert.ok(shot.isError); assert.match(shot.text, /refused/i);
  assert.ok((await call('browser_press_key', { key: 'Meta+c' })).isError);
  const snap = await call('browser_snapshot');
  for (const label of ['Copy', 'Copy (old way)']) {
    const ref = snap.text.match(new RegExp(`button "${label.replace(/[()]/g, '\\$&')}" \\[ref=([a-z0-9]+)\\]`))[1];
    await call('browser_click', { element: label, target: ref });
  }
  const after = await call('browser_snapshot');
  assert.match(after.text, /copy blocked/);
  assert.ok(!/(^|\W)copied/.test(after.text), 'a copy went through');
});

test('save_new_key stores the real key and returns only a placeholder', async () => {
  const r = await call('save_new_key', { name: 'acme', host: 'api.acme.example' });
  assert.ok(!r.isError, r.text);
  assert.match(r.text, /keydillo:acme/); assert.doesNotMatch(r.text, /visible to you/);
  noKey(r.text, 'save result');
  const s = saved().at(-1);
  assert.equal(s.value, KEY); assert.equal(s.host, 'api.acme.example');
});

test('start_key_capture works on a page with no key wording', async () => {
  await call('browser_navigate', { url: `${base}/dashboard` });
  assert.ok(!(await call('start_key_capture')).isError);
  const snap0 = await call('browser_snapshot');
  const ref = snap0.text.match(/button "Continue" \[ref=([a-z0-9]+)\]/)[1];
  const r = await call('browser_click', { element: 'Continue', target: ref });
  noKey(r.text, 'dashboard click'); noKey((await call('browser_snapshot')).text, 'dashboard snapshot');
});

test('a key drawn on a canvas: screenshots stay refused, save says it cannot see it', async () => {
  await call('browser_navigate', { url: `${base}/canvas` });
  const snap0 = await call('browser_snapshot');
  const ref = snap0.text.match(/button "Generate new key" \[ref=([a-z0-9]+)\]/)[1];
  await call('browser_click', { element: 'Generate new key', target: ref });
  assert.ok((await call('browser_take_screenshot', {})).isError, 'screenshot of canvas key allowed');
  const r = await call('save_new_key', { name: 'canvas', host: 'api.acme.example' });
  assert.ok(r.isError); assert.match(r.text, /No hidden key is showing/);
});

test('a key next to a "Done" button: the button stays readable and the exact key is saved', async () => {
  await call('browser_navigate', { url: `${base}/done` });
  const snap0 = await call('browser_snapshot');
  const ref = snap0.text.match(/button "Create key" \[ref=([a-z0-9]+)\]/)[1];
  await call('browser_click', { element: 'Create key', target: ref });
  const snap = await call('browser_snapshot');
  noKey(snap.text, 'done dialog', KEY3);
  assert.match(snap.text, /button "Done"/);
  const r = await call('save_new_key', { name: 'done', host: 'api.acme.example' });
  assert.equal(saved().at(-1).value, KEY3, r.text);
});

test('known key formats are hidden on any page', async () => {
  await call('browser_navigate', { url: `${base}/prefix` });
  const snap = await call('browser_snapshot');
  noKey(snap.text, 'prefix page', OPENAI_STYLE);
  assert.match(snap.text, /\[key hidden …/);
});

test('exposure check: a key Claude saw before capture gets a rotate warning', async () => {
  await call('browser_navigate', { url: `${base}/leak` }); // the page title carries the key, before anything is hidden
  const snap0 = await call('browser_snapshot');
  const ref = snap0.text.match(/button "Create secret key" \[ref=([a-z0-9]+)\]/)[1];
  await call('browser_click', { element: 'Create secret key', target: ref });
  const r = await call('save_new_key', { name: 'leaky', host: 'api.acme.example' });
  assert.ok(r.isError); assert.match(r.text, /visible to you earlier/);
  assert.equal(saved().at(-1).value, KEY2, 'still saved, so the user can rotate it');
});

test('exposure check catches a partial leak', () => {
  const g = new Guard({ getContext: () => null, outputDir: dataDir });
  g.recordSent({ content: [{ type: 'text', text: 'blah ' + KEY.slice(5, 19) + ' blah' }] });
  assert.ok(g.exposed(KEY));
  assert.ok(!g.exposed(KEY2));
});
