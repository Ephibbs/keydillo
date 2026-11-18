// App mode: the keydillo app's BrowserHost starts this server and answers password requests over a private pipe.
// Uses kd-testbrowser (VaultCore test target): in-memory logins and an approver that logs the Touch ID reason.
// Set KD_TESTBROWSER to its path; skipped otherwise.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { startSite } from './site.mjs';

const bin = process.env.KD_TESTBROWSER;
const skip = !bin || !fs.existsSync(bin);
let site, base, host, c, events = [], sock;

const call = async (name, args = {}) => {
  const r = await c.callTool({ name, arguments: args });
  return { ...r, text: (r.content || []).filter((x) => x.type === 'text').map((x) => x.text).join('\n') };
};
const waitFor = async (pred, ms = 20000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { const e = events.find(pred); if (e) return e; await new Promise((r) => setTimeout(r, 50)); }
  throw new Error('timed out; events: ' + JSON.stringify(events));
};
const refOf = (snap, re) => snap.match(re)[1];

before(async () => {
  if (skip) return;
  site = await startSite();
  base = `http://127.0.0.1:${site.port}`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kda-'));
  sock = path.join(dir, 'b.sock');
  host = spawn(bin, ['--node', process.env.KD_NODE || process.execPath, '--server', process.env.KD_SERVER || path.resolve('src/server.mjs'), '--socket', sock, '--data-dir', dir, '--site', base, '--deny-new-pages'],
    { stdio: ['pipe', 'pipe', 'inherit'] });
  let buf = '';
  host.stdout.on('data', (d) => {
    buf += d; let i;
    while ((i = buf.indexOf('\n')) >= 0) { try { events.push(JSON.parse(buf.slice(0, i))); } catch {} buf = buf.slice(i + 1); }
  });
  await waitFor((e) => e.event === 'ready' || e.event === 'error');
  assert.ok(events.some((e) => e.event === 'ready'), JSON.stringify(events));
  c = new Client({ name: 't', version: '1' });
  await c.connect(new StdioClientTransport({ command: '/usr/bin/nc', args: ['-U', sock] }));
});
after(async () => { if (skip) return; await c?.close(); host.stdin.end(); host.kill(); site.srv.close(); });

test('app mode: list_logins comes from the app', { skip }, async () => {
  const r = await call('list_logins');
  assert.match(r.text, /"demo"/); assert.doesNotMatch(r.text, /Hunter2/);
});

test('app mode: fill_login gets the password from the app after Touch ID, naming a new page', { skip }, async () => {
  await call('browser_navigate', { url: `${base}/login` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(!r.isError, r.text);
  assert.equal(site.posts.at(-1).f.password, 'Hunter2-correct');
  assert.doesNotMatch(r.text, /Hunter2/);
  const t = events.filter((e) => e.event === 'touchid').at(-1);
  assert.match(t.reason, /NEW sign-in page: http:\/\/127\.0\.0\.1:\d+\/login \(sends to \/session\)/);
  await call('browser_navigate', { url: `${base}/login` });
  await call('fill_login', { login: 'demo' });
  assert.match(events.filter((e) => e.event === 'touchid').at(-1).reason, /^sign in to 127\.0\.0\.1 as evan/);
});

test('app mode: a declined new page sends nothing', { skip }, async () => {
  const n = site.posts.length;
  await call('browser_navigate', { url: `${base}/forms/evan/login` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(r.isError); assert.match(r.text, /declined/);
  assert.equal(site.posts.length, n);
});

test('app mode: sign-up password saved in the app', { skip }, async () => {
  await call('browser_navigate', { url: `${base}/signup` });
  const r = await call('fill_new_password', { login: 'newsite', username: 'evan@example.com' });
  assert.ok(!r.isError, r.text);
  host.stdin.write('dump\n');
  const d = await waitFor((e) => e.event === 'logins');
  assert.ok(d.names.includes('newsite'));
  const snap = (await call('browser_snapshot')).text;
  await call('browser_click', { element: 'Submit', target: refOf(snap, /button "Sign in" \[ref=([a-z0-9]+)\]/) });
  assert.equal(site.posts.at(-1).f.password, d.secrets.newsite);
});

test('app mode: captured key goes to the app as a keydillo key', { skip }, async () => {
  await call('browser_navigate', { url: `${base}/settings/keys` });
  await call('start_key_capture');
  const snap = (await call('browser_snapshot')).text;
  await call('browser_click', { element: 'Create key', target: refOf(snap, /button "Create key" \[ref=([a-z0-9]+)\]/) });
  const r = await call('save_new_key', { name: 'acme', host: 'api.acme.example', project: 'demo-app' });
  assert.ok(!r.isError, r.text);
  const e = await waitFor((x) => x.event === 'saveKey');
  assert.equal(e.value, 'Q7mZp2Lx9KvT4rW8nYb3HcJ6dF1sGa5E'); assert.equal(e.project, 'demo-app');
  assert.match(r.text, /keydillo:acme/); assert.doesNotMatch(r.text, /Q7mZp2Lx9KvT4rW8/);
});

test('app mode: request_login opens the app window and the new login can be used', { skip }, async () => {
  const r = await call('request_login', { login: 'acme', site: base, username: 'evan' });
  assert.ok(!r.isError, r.text);
  assert.ok(events.some((e) => e.event === 'requestLogin' && e.name === 'acme'));
  assert.match((await call('list_logins')).text, /"acme"/);
});
