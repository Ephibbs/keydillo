// End-to-end: runs the real MCP server over stdio against a local site, with a fake helper instead of Touch ID.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { startSite } from './site.mjs';

const SECRET = 'Hunter2-correct';
let site, c, base, dataDir, promptLog;
const prompts = () => fs.readFileSync(promptLog, 'utf8').trim().split('\n').map((l) => JSON.parse(l));

const call = async (name, args = {}) => {
  const r = await c.callTool({ name, arguments: args });
  return { ...r, text: (r.content || []).filter((x) => x.type === 'text').map((x) => x.text).join('\n') };
};
const noSecret = (s, where) => {
  for (const v of ['Wrong-password-1', SECRET, encodeURIComponent(SECRET), Buffer.from(SECRET).toString('base64').replace(/=+$/, '')]) {
    assert.ok(!s.includes(v), `secret leaked in ${where}: ${s.slice(0, 400)}`);
  }
};
const allOutputFiles = () => {
  const out = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); e.isDirectory() ? walk(p) : out.push(p); } };
  walk(path.join(dataDir, 'output'));
  return out.filter((p) => !p.endsWith('.png')).map((p) => fs.readFileSync(p, 'utf8')).join('\n');
};

before(async () => {
  site = await startSite();
  base = `http://127.0.0.1:${site.port}`;
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kdl-'));
  promptLog = path.join(dataDir, 'prompts.jsonl'); fs.writeFileSync(promptLog, '');
  c = new Client({ name: 't', version: '1' });
  await c.connect(new StdioClientTransport({
    command: process.execPath,
    args: ['src/server.mjs', '--headless', '--data-dir', dataDir, '--helper', 'test/fake-helper.mjs'],
    env: { ...process.env, KDLOGIN_FAKE_SITE: base, KDLOGIN_FAKE_LOG: promptLog, KDLOGIN_FAKE_STATE: path.join(dataDir, 'pages.json') },
    stderr: 'inherit',
  }));
});
after(async () => { await c.close(); site.srv.close(); });

test('tool list: fill_login present, run_code_unsafe removed', async () => {
  const names = (await c.listTools()).tools.map((t) => t.name);
  assert.ok(names.includes('fill_login') && names.includes('list_logins') && names.includes('browser_snapshot'));
  assert.ok(!names.includes('browser_run_code_unsafe'));
  assert.ok((await call('browser_run_code_unsafe', { code: 'x' })).isError);
});

test('list_logins has no password', async () => {
  const r = await call('list_logins');
  assert.match(r.text, /demo/); noSecret(r.text, 'list_logins');
});

test('refuses a page on another host', async () => {
  await call('browser_navigate', { url: `http://localhost:${site.port}/login` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(r.isError); assert.match(r.text, /No sign-in form on/);
  assert.equal(site.posts.length, 0);
});

test('refuses a form that posts to another host', async () => {
  await call('browser_navigate', { url: `${base}/evil-form` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(r.isError); assert.match(r.text, /different site/);
  assert.equal(site.posts.length, 0);
});

test('signs in and the agent never sees the password', async () => {
  await call('browser_navigate', { url: `${base}/login` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(!r.isError, r.text); assert.match(r.text, /Signed in/);
  const post = site.posts.at(-1);
  assert.equal(post.f.password, SECRET); assert.equal(post.f.login, 'evan');
  noSecret(r.text, 'fill_login result');
  const snap = await call('browser_snapshot'); noSecret(snap.text, 'snapshot');
  assert.match(snap.text, /Welcome evan/);
});

test('network and console tools are banned; extensions, chrome:// and the Web Store blocked', async () => {
  const names = (await c.listTools()).tools.map((t) => t.name);
  for (const t of ['browser_network_requests', 'browser_network_request', 'browser_console_messages']) {
    assert.ok(!names.includes(t), `${t} listed`);
    assert.ok((await call(t, { index: 1 })).isError, `${t} callable`);
  }
  for (const url of ['chrome://extensions', 'chrome-extension://abc/x.html', 'https://chromewebstore.google.com/']) {
    assert.ok((await call('browser_navigate', { url })).isError, `${url} allowed`);
  }
});

test('a password the agent typed itself is masked too', async () => {
  // Pretend the saved password is wrong by having the site reject it once.
  await call('browser_navigate', { url: `${base}/login` });
  await call('browser_type', { element: 'Password', target: 'e999', text: 'x' }).catch(() => {});
  const snap0 = await call('browser_snapshot');
  const pwRef = snap0.text.match(/textbox "Password" \[ref=(e\d+)\]/)?.[1];
  await call('browser_type', { element: 'Password', target: pwRef, text: SECRET + 'X' }); // agent-typed value is masked too
  const snap = await call('browser_snapshot'); noSecret(snap.text, 'snapshot with agent-typed password');
  assert.ok(!snap.text.includes(SECRET + 'X'));
});

test('wrong saved password: reported as failed and the field is emptied', async () => {
  await call('browser_navigate', { url: `${base}/login` });
  const r = await call('fill_login', { login: 'wrong' });
  assert.ok(r.isError); assert.match(r.text, /probably failed/);
  const snap = await call('browser_snapshot');
  assert.match(snap.text, /Incorrect password/); noSecret(r.text + snap.text, 'wrong-password flow');
  assert.match(snap.text, /textbox "Password" \[ref=[a-z0-9]+\]\n/, 'password field should be empty');
});

test('a page that keeps the password after a failed sign-in: field emptied, reveal shows nothing', async () => {
  await call('browser_navigate', { url: `${base}/login-spa` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(r.isError); assert.match(r.text, /probably failed/);
  const snap = await call('browser_snapshot');
  const reveal = snap.text.match(/button "Show password" \[ref=([a-z0-9]+)\]/)[1];
  await call('browser_click', { element: 'Show password', target: reveal });
  const after = await call('browser_snapshot');
  noSecret(r.text + snap.text + after.text, 'spa flow');
  assert.ok(!(await call('browser_take_screenshot', {})).isError, 'nothing to hide, screenshot should work');
});

test('JS evaluation is blocked on password pages and signed-in sites', async () => {
  await call('browser_navigate', { url: `${base}/login` });
  const r = await call('browser_evaluate', { function: '() => document.querySelector("input[type=password]").value' });
  assert.ok(r.isError); assert.match(r.text, /blocked/);
  await call('browser_navigate', { url: `${base}/` });
  const r2 = await call('browser_evaluate', { function: '() => document.title' });
  assert.ok(r2.isError); assert.match(r2.text, /signed in to/);
});

test('a page echoing the password: snapshot and files masked, screenshot refused', async () => {
  await call('browser_navigate', { url: `${base}/echo` });
  const snap = await call('browser_snapshot'); noSecret(snap.text, 'echo snapshot');
  assert.match(snap.text, /••••/);
  const shot = await call('browser_take_screenshot', {});
  assert.ok(shot.isError); assert.match(shot.text, /refused/);
  noSecret(allOutputFiles(), 'output files');
});

test('finds the username field when its name is unusual', async () => {
  await call('browser_navigate', { url: `${base}/odd-names` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(!r.isError, r.text);
  assert.equal(site.posts.at(-1).f.acct, 'evan');
});

test('first use asks about the new page; the next use on it does not', async () => {
  const p = prompts().filter((x) => x.name === 'demo' && x.page === `${base}/login`);
  assert.equal(p[0].known, false); assert.equal(p[0].action, `${base}/session`);
  assert.ok(p.slice(1).every((x) => x.known), 'later uses of /login should be known');
  const list = await call('list_logins');
  assert.ok(list.text.includes(`${base}/login`), 'approved page should be listed');
});

test('same-site fake form: user declines the new page, nothing sent', async () => {
  const n = site.posts.length;
  await call('browser_navigate', { url: `${base}/forms/evan/login` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(r.isError); assert.match(r.text, /hasn't been used on before: .*\/forms\/evan\/login/);
  const last = prompts().at(-1);
  assert.equal(last.known, false); assert.equal(last.page, `${base}/forms/evan/login`); assert.equal(last.action, `${base}/forms/evan/collect`);
  assert.equal(site.posts.length, n, 'nothing should be posted');
  const snap = await call('browser_snapshot'); noSecret(snap.text, 'fake form');
  assert.ok((await call('browser_evaluate', { function: '() => 1' })).isError, 'JS must stay blocked');
});

test('page script retargets the form after the check: request is stopped', async () => {
  const n = site.posts.length;
  await call('browser_navigate', { url: `${base}/login-swap` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(r.isError); assert.match(r.text, /tried to send the password to .*\/collect/);
  assert.ok(!site.posts.slice(n).some((p) => p.path === '/collect'), 'password reached /collect');
});

test('page script copies the password into a fetch: request is stopped', async () => {
  const n = site.posts.length;
  await call('browser_navigate', { url: `${base}/login-fetch` });
  await call('fill_login', { login: 'demo' });
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(!site.posts.slice(n).some((p) => p.path === '/collect'), 'password reached /collect');
  assert.ok(site.posts.slice(n).some((p) => p.path === '/session'), 'real sign-in should still go through');
});

test('page script sends the password over a WebSocket: stopped', async () => {
  await call('browser_navigate', { url: `${base}/login-ws` });
  await new Promise((r) => setTimeout(r, 300));
  assert.ok(site.wsMessages.includes('hello'), 'ordinary WebSocket traffic should pass');
  await call('fill_login', { login: 'demo' });
  await new Promise((r) => setTimeout(r, 300));
  assert.ok(!site.wsMessages.some((m) => m.includes('Hunter2')), 'password went out over the WebSocket');
});

test('javascript: navigation is blocked', async () => {
  const r = await call('browser_navigate', { url: 'javascript:alert(1)' });
  assert.ok(r.isError);
});

test('two-step sign-in with a TOTP code', async () => {
  const n = site.posts.length;
  await call('browser_navigate', { url: `${base}/two-step` });
  const r = await call('fill_login', { login: 'demo' });
  assert.ok(!r.isError, r.text);
  const posts = site.posts.slice(n).map((p) => p.path);
  assert.deepEqual(posts, ['/step1', '/step2', '/otp']);
  assert.match(site.posts.at(-1).f.otp, /^\d{6}$/);
  assert.match(r.text, /username, password, 2FA code/);
  noSecret(r.text, 'two-step result');
});
