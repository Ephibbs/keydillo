#!/usr/bin/env node
// keydillo-login: Playwright MCP (Microsoft, Apache-2.0) wrapped with a fill_login tool.
// The agent drives the browser as usual; logins are filled from the Keychain after Touch ID,
// and password values are masked in everything the agent gets back.

import { spawn } from 'node:child_process';

// Another program running as you could send this process SIGUSR1 to open Node's debugger and read
// passwords from memory. Re-run with that turned off; this parent never holds a password.
if (!process.execArgv.includes('--disable-sigusr1')) {
  const child = spawn(process.execPath, ['--disable-sigusr1', ...process.execArgv, ...process.argv.slice(1)], { stdio: 'inherit' });
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => child.kill(sig));
  child.on('exit', (code) => process.exit(code ?? 1));
  await new Promise(() => {});
}

import { createConnection } from '@playwright/mcp';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { chromium } from 'playwright';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Guard } from './guard.mjs';
import { fillLogin } from './fill.mjs';
import { fillNewPassword } from './signup.mjs';
import { Store } from './store.mjs';
import { AppStore } from './app-store.mjs';
import net from 'node:net';

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };

const appDir = opt('--data-dir', path.join(os.homedir(), 'Library/Application Support/keydillo-login'));
const profileDir = path.join(appDir, 'chrome-profile');
const outputDir = path.join(appDir, 'output');
fs.mkdirSync(profileDir, { recursive: true });
fs.mkdirSync(outputDir, { recursive: true });

// Keep Chrome's own password manager out of it, so no saved password can be autofilled where the agent can read it.
const prefsPath = path.join(profileDir, 'Default', 'Preferences');
if (!fs.existsSync(prefsPath)) {
  fs.mkdirSync(path.dirname(prefsPath), { recursive: true });
  fs.writeFileSync(prefsPath, JSON.stringify({ credentials_enable_service: false, profile: { password_manager_enabled: false } }));
}

// --app: started by the keydillo app, which answers over fd 3. Otherwise the standalone kdlogin helper.
const appMode = flag('--app');
const store = appMode ? new AppStore(3) : new Store(opt('--helper', process.env.KDLOGIN_HELPER || path.join(here, '..', 'bin', 'kdlogin')));

let context;
async function getContext() {
  if (context) return context;
  context = await chromium.launchPersistentContext(profileDir, {
    channel: opt('--channel', 'chrome'),
    headless: flag('--headless'),
    viewport: null,
    acceptDownloads: false, // no key files (AWS-style .csv) land on disk
    args: ['--disable-extensions', '--disable-features=PasswordManagerOnboarding,AutofillServerCommunication'],
  });
  context.on('close', () => { context = undefined; });
  await guard.install(context);
  return context;
}

const inner = await createConnection({
  outputDir,
  imageResponses: 'allow',
  capabilities: ['core'], // no devtools (tracing, video), pdf or vision extras
  saveSession: false,
  webmcp: false,          // pages can't add their own tools
}, getContext);
const [a, b] = InMemoryTransport.createLinkedPair();
await inner.connect(a);
const client = new Client({ name: 'keydillo-login', version: '0.1.0' });
await client.connect(b);

const guard = new Guard({ getContext: () => context, outputDir });

const ownTools = [
  {
    name: 'list_logins',
    description: 'List the website logins saved in keydillo (name, site, username). Never returns passwords.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'fill_login',
    description:
      "Sign in to a website with a login saved in keydillo, without you seeing the password. Navigate the browser to the site's sign-in page first, then call this. The user approves with Touch ID; keydillo checks that the page is on the login's saved site, fills the username and password (and a 2FA code if one is saved), and submits. Use this instead of asking the user for a password or typing one.",
    inputSchema: {
      type: 'object',
      properties: { login: { type: 'string', description: 'Login name from list_logins, e.g. "github"' } },
      required: ['login'],
    },
  },
  {
    name: 'request_login',
    description:
      "When the user wants you to sign in somewhere and list_logins has no login for that site: opens keydillo on the user's Mac so they can type the username and password themselves. You never see the password. Then call fill_login.",
    inputSchema: {
      type: 'object',
      properties: {
        login: { type: 'string', description: 'Suggested name, e.g. "github"' },
        site: { type: 'string', description: 'Suggested site, e.g. https://github.com' },
        username: { type: 'string', description: 'Suggested username, if known' },
      },
    },
  },
  {
    name: 'fill_new_password',
    description:
      "When signing the user up for a new account: generates a strong password, saves it in keydillo after Touch ID, and types it into the sign-up form's password fields (including \"confirm password\"). You never see it. Fill in the email or username first; submit the form yourself afterwards. Later, sign in with fill_login and the same login name.",
    inputSchema: {
      type: 'object',
      properties: {
        login: { type: 'string', description: 'Name to save the login under, e.g. "github"' },
        username: { type: 'string', description: 'Optional. Defaults to the email/username already typed in the form' },
        length: { type: 'integer', description: 'Optional, 12 to 64 (default 20)' },
        symbols: { type: 'boolean', description: 'Optional. false if the site rejects symbols' },
      },
      required: ['login'],
    },
  },
  {
    name: 'start_key_capture',
    description:
      "Call this before clicking a button that creates or reveals an API key or token on any website. From then on, every new value that appears on the page is hidden from you, so you can safely click Create and then call save_new_key.",
    inputSchema: { type: 'object', properties: { provider: { type: 'string', description: 'Optional, e.g. "openai"' } } },
  },
  {
    name: 'save_new_key',
    description:
      "Save an API key that a provider's website is showing (for example right after you clicked \"Create secret key\"), without you seeing it. Keys on the page appear to you as [key hidden …abcd]. The user approves with Touch ID; keydillo stores the key bound to the provider's API host and returns a placeholder to put in .env. Use this instead of copying, reading or screenshotting a key.",
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Name for the key, e.g. "openai"' },
        project: { type: 'string', description: 'keydillo project to put it in (usually the app folder name). Optional' },
        host: { type: 'string', description: "API host the key may be sent to, e.g. the provider's api. host. Optional on known provider pages." },
        ending: { type: 'string', description: 'Last 4 characters shown as [key hidden …abcd], when more than one key is showing' },
      },
      required: ['name'],
    },
  },
];

// Removed outright: running Node code in this server, and every tool that shows network traffic or console
// output (a sign-in request carries the password).
import { recipeFor } from './recipes.mjs';

const BLOCKED = new Set(['browser_run_code_unsafe', 'browser_network_requests', 'browser_network_request', 'browser_console_messages']);

let chain = Promise.resolve();
const serial = (fn) => { const p = chain.then(fn, fn); chain = p.catch(() => {}); return p; };
const text = (t, isError = false) => ({ content: [{ type: 'text', text: t }], isError });

const handleCall = (req) => serial(async () => {
  const { name, arguments: args = {} } = req.params;
  try {
    if (name === 'list_logins') return text(JSON.stringify(await store.list(), null, 2));
    if (name === 'fill_login') {
      await getContext();
      const r = await fillLogin({ context, store, guard, login: args.login });
      return guard.scrubResult(text(r.message, !r.ok));
    }
    if (name === 'request_login') {
      try { await store.requestLogin(args); } catch (e) { return text(e.message, true); }
      return text(`Saved. Call fill_login with "${args.login || 'the new login'}" (list_logins shows the name).`);
    }
    if (name === 'fill_new_password') {
      await getContext();
      const r = await fillNewPassword({ context, store, guard, ...args });
      const out = await guard.scrubResult(text(r.message, !r.ok));
      guard.recordSent(out);
      return out;
    }
    if (name === 'start_key_capture') {
      await getContext();
      await guard.strictAll();
      return text('Key capture is on for the open tabs. Click the button that creates the key, then call save_new_key. Screenshots and JavaScript are off until the key is saved or you leave the page.');
    }
    if (name === 'save_new_key') {
      await getContext();
      let keys = await guard.visibleKeys();
      if (args.ending) keys = keys.filter((k) => k.endsWith(args.ending));
      if (!keys.length) return text('No hidden key is showing in the browser. If the site drew the key in an image or it is already gone, ask the user to save it in keydillo themselves.', true);
      if (keys.length > 1) return guard.scrubResult(text(`More than one key is showing: ${keys.map((k) => '…' + k.slice(-4)).join(', ')}. Call again with "ending".`, true));
      const recipe = context.pages().map((p) => recipeFor(p.url())).find(Boolean);
      const host = String(args.host || recipe?.host || '').replace(/^https?:\/\//, '').replace(/\/.*$/, '').toLowerCase();
      if (!/^[a-z0-9.-]+\.[a-z]{2,}$/.test(host)) return text('Pass "host", the API host this key is for.', true);
      let placeholder = `keydillo:${args.name}`;
      try {
        placeholder = (await store.saveKey(args.name, host, keys[0], { keysUrl: recipe?.keysUrl, project: args.project })) || placeholder;
      } catch (e) {
        return text(/Denied/.test(e.message) ? 'The user declined Touch ID. Ask them before trying again.' : `Couldn't save: ${e.message}`, true);
      }
      guard.markSaved(keys[0]);
      if (guard.exposed(keys[0])) {
        const where = recipe ? ` (${recipe.keysUrl})` : '';
        return text(`Saved as ${placeholder} for ${host}, BUT this key was visible to you earlier in this session, before keydillo recognised it as a key. Tell the user to rotate it on the provider's API keys page${where} and save the new one.`, true);
      }
      return text(appMode
        ? `Saved in keydillo as "${args.name}", usable only with ${host}. Add these lines to the app's .env, then run it with kd in front:\n${placeholder}\nYou can close the key dialog now.`
        : `Saved as ${placeholder}, usable only with ${host}. Put KEY_NAME=${placeholder} in .env (standalone prototype: stored in the keydillo-login Keychain, not the keydillo app). You can close the key dialog now.`);
    }
    if (BLOCKED.has(name)) return text(`${name} is turned off in keydillo-login.`, true);
    const refusal = await guard.before(name, args);
    if (refusal) return text(refusal, true);
    const started = Date.now();
    const result = await client.callTool({ name, arguments: args });
    await guard.scrubFiles(started);
    const out = await guard.scrubResult(result);
    guard.recordSent(out);
    return out;
  } catch (e) {
    return guard.scrubResult(text(String(e?.message || e), true));
  }
});

function makeServer() {
  const server = new Server({ name: 'keydillo-browser', version: '0.2.0' }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const { tools } = await client.listTools();
    return { tools: [...ownTools, ...tools.filter((t) => !BLOCKED.has(t.name))] };
  });
  server.setRequestHandler(CallToolRequestSchema, handleCall);
  return server;
}

const listen = opt('--listen');
if (listen) {
  // One browser, shared by every Claude session that connects (each via `keydillo browser-mcp`).
  try { fs.unlinkSync(listen); } catch {}
  const srv = net.createServer((sock) => {
    makeServer().connect(new StdioServerTransport(sock, sock)).catch(() => sock.destroy());
  });
  srv.listen(listen, () => fs.chmodSync(listen, 0o600));
} else {
  await makeServer().connect(new StdioServerTransport());
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, async () => { await context?.close().catch(() => {}); process.exit(0); });
