// Drives the user's own Chrome through the keydillo extension instead of launching a browser.
//
// Playwright talks Chrome DevTools Protocol to a browser-level endpoint. The extension can only speak for single
// tabs (chrome.debugger), so this file pretends to be the browser: it answers browser-level commands itself and
// forwards the rest to the right tab through the native messaging host. Adapted from Playwright's own extension
// relay (BrowserModel in playwright-core, Apache-2.0, Microsoft).
//
// Unlike Playwright's version, the extension never connects to a localhost WebSocket: it reaches us through Chrome's
// native messaging host and a Unix socket only this user can open. The DevTools endpoint Playwright connects to lives
// on 127.0.0.1 under a random path that exists only in this process.

import net from 'node:net';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { chromium } from 'playwright';
import os from 'node:os';
import path from 'node:path';

// Where the native messaging host (chrome/host.mjs) listens. Same default as there.
export const SOCKET = process.env.KEYDILLO_CHROME_SOCKET || path.join(os.homedir(), 'Library/Application Support/keydillo/chrome/bridge.sock');

const require = createRequire(import.meta.url);
const { wsServer: WebSocketServer } = require('playwright-core/lib/utilsBundle');

class Bridge {
  constructor(sockPath, onEvent) {
    this.callbacks = new Map(); this.lastId = 0; this.onEvent = onEvent;
    this.closed = false;
    this.ready = new Promise((resolve, reject) => {
      this.sock = net.createConnection(sockPath, resolve);
      this.sock.once('error', (e) => reject(new Error(
        e.code === 'ENOENT' || e.code === 'ECONNREFUSED'
          ? 'Chrome with the keydillo extension isn\'t running. Open Chrome; if it is open, check the keydillo extension is installed and on (chrome://extensions).'
          : e.message)));
    });
    let line = '';
    this.sock.on('data', (d) => {
      line += d;
      let i;
      while ((i = line.indexOf('\n')) >= 0) {
        const raw = line.slice(0, i); line = line.slice(i + 1);
        if (!raw) continue;
        const m = JSON.parse(raw);
        if (m.id === undefined && m.error) { this.refusedReason = m.error; continue; }
        if (m.id === undefined) { this.onEvent(m); continue; }
        const cb = this.callbacks.get(m.id); this.callbacks.delete(m.id);
        if (m.error) cb?.reject(new Error(m.error)); else cb?.resolve(m.result);
      }
    });
    this.sock.on('close', () => {
      this.closed = true;
      for (const cb of this.callbacks.values()) cb.reject(new Error('Lost the connection to Chrome.'));
      this.callbacks.clear();
      this.onClose?.();
    });
    this.sock.on('error', () => {});
  }
  send(method, params) {
    if (this.closed) return Promise.reject(new Error(this.refusedReason || 'Lost the connection to Chrome.'));
    const id = ++this.lastId;
    this.sock.write(JSON.stringify({ id, method, params }) + '\n');
    return new Promise((resolve, reject) => this.callbacks.set(id, { resolve, reject }));
  }
  close() { this.sock.end(); }
}

export class ChromeRelay {
  constructor(sockPath) {
    sockPath ||= SOCKET;
    this.known = new Set(); this.sessions = new Map(); this.autoAttach = false; this.next = 1; this.client = null;
    this.initialized = new Promise((r) => (this.markInitialized = r));
    this.bridge = new Bridge(sockPath, (e) => this.onExtensionEvent(e));
    this.bridge.onClose = () => { this.client?.close(); this.wss?.close(); };
  }

  async start() {
    await this.bridge.ready;
    const p = '/devtools/' + crypto.randomUUID();
    this.wss = new WebSocketServer({ host: '127.0.0.1', port: 0, path: p });
    await new Promise((r, j) => { this.wss.once('listening', r); this.wss.once('error', j); });
    this.wss.on('connection', (s) => {
      if (this.client) return s.close();
      this.client = s;
      s.on('message', async (raw) => {
        const { id, method, params, sessionId } = JSON.parse(raw.toString());
        try {
          const result = await this.handle(method, params, sessionId);
          s.send(JSON.stringify({ id, sessionId, result: result ?? {} }));
        } catch (e) {
          s.send(JSON.stringify({ id, sessionId, error: { code: -32000, message: e.message } }));
        }
      });
      s.on('close', () => { if (this.client === s) this.client = null; });
    });
    const timeout = new Promise((_, j) => setTimeout(() => j(new Error(this.bridge.refusedReason || 'The keydillo extension didn\'t answer. Reload it in chrome://extensions.')), 10_000));
    await Promise.race([this.initialized, timeout]);
    return `ws://127.0.0.1:${this.wss.address().port}${p}`;
  }

  /** Ways into this Chrome that bypass keydillo. Secret steps refuse to run while any is open. */
  async sideDoors() {
    const doors = [...await this.bridge.send('host.sideDoors')];
    const { extensions } = await this.bridge.send('keydillo.status');
    for (const e of extensions) {
      if (!e.canTrust) doors.push(`The "${e.name}" extension ${e.reason}. Turn it off in chrome://extensions while Claude signs in or saves keys.`);
      else if (!e.trusted) doors.push(`The "${e.name}" extension ${e.reason}. Turn it off, or trust it in the keydillo extension's menu (puzzle icon → keydillo).`);
    }
    return doors;
  }

  /** The user's turn in Chrome: the pill says what to do and shows Done. Resolves when they press it. */
  yourTurn(text) {
    this.bridge.send('keydillo.turn', [text]).catch(() => {});
    return new Promise((resolve) => { this.onUserDone = resolve; });
  }
  endTurn() { this.onUserDone = null; this.bridge.send('keydillo.turn', [null]).catch(() => {}); }

  /** Shows what Claude is doing next to its cursor in Chrome. */
  label(text) { if (text) this.bridge.send('keydillo.label', [text]).catch(() => {}); }

  toClient(m) { this.client?.send(JSON.stringify(m)); }

  async handle(method, params, sessionId) {
    switch (method) {
      case 'Browser.getVersion':
        return { protocolVersion: '1.3', product: 'Chrome/keydillo', userAgent: 'keydillo' };
      case 'Browser.setDownloadBehavior':
        return {}; // downloads are always off in Claude's tabs (the extension sets it per tab)
      case 'Target.setAutoAttach':
        if (sessionId) break;
        this.autoAttach = true;
        await Promise.all([...this.known].map((t) => this.attach(t).catch(() => {})));
        return {};
      case 'Target.createTarget': {
        const tab = await this.bridge.send('chrome.tabs.create', [{ url: params?.url, active: true }]);
        this.known.add(tab.id);
        const s = await this.attach(tab.id);
        return { targetId: s.targetInfo?.targetId };
      }
      case 'Target.closeTarget': {
        const s = this.find((x) => x.targetInfo?.targetId === params?.targetId);
        if (!s) return { success: false };
        await this.bridge.send('chrome.tabs.remove', [s.tabId]);
        return { success: true };
      }
      case 'Target.getTargetInfo':
        return sessionId ? this.find((s) => s.sessionId === sessionId)?.targetInfo : undefined;
    }
    return await this.bridge.send('chrome.debugger.sendCommand', [this.target(method, sessionId), method, params]);
  }

  target(method, sessionId) {
    if (!sessionId) {
      const s = this.sessions.values().next().value;
      if (!s) throw new Error(`No Claude tab to send ${method} to`);
      return { tabId: s.tabId };
    }
    const s = this.find((x) => x.sessionId === sessionId);
    if (s) return { tabId: s.tabId };
    const parent = this.find((x) => x.children.has(sessionId));
    if (parent) return { tabId: parent.tabId, sessionId };
    throw new Error(`No tab for session ${sessionId}`);
  }

  find(f) { for (const s of this.sessions.values()) if (f(s)) return s; }

  onExtensionEvent(e) {
    switch (e.method) {
      case 'chrome.tabs.onCreated': {
        const [t] = e.params;
        this.known.add(t.id);
        if (this.autoAttach) this.attach(t.id).catch(() => {});
        break;
      }
      case 'chrome.tabs.onRemoved': { const [id] = e.params; this.known.delete(id); this.detach(id); break; }
      case 'chrome.debugger.onEvent': {
        const [src, method, params] = e.params;
        const s = this.sessions.get(src.tabId);
        if (!s) break;
        if (method === 'Target.attachedToTarget' && params?.sessionId) s.children.add(params.sessionId);
        if (method === 'Target.detachedFromTarget' && params?.sessionId) s.children.delete(params.sessionId);
        this.toClient({ sessionId: src.sessionId || s.sessionId, method, params });
        break;
      }
      case 'chrome.debugger.onDetach': { const [src] = e.params; this.detach(src.tabId); break; }
      case 'extension.initialized': this.markInitialized(); break;
      case 'keydillo.userDone': { const f = this.onUserDone; this.onUserDone = null; f?.(); break; }
    }
  }

  async attach(tabId) {
    if (this.sessions.has(tabId)) return this.sessions.get(tabId);
    await this.bridge.send('chrome.debugger.attach', [{ tabId }, '1.3']);
    const { targetInfo } = await this.bridge.send('chrome.debugger.sendCommand', [{ tabId }, 'Target.getTargetInfo']);
    const s = { tabId, sessionId: `kd-tab-${this.next++}`, targetInfo, children: new Set() };
    this.sessions.set(tabId, s);
    this.toClient({ method: 'Target.attachedToTarget', params: { sessionId: s.sessionId, targetInfo: { ...targetInfo, attached: true }, waitingForDebugger: false } });
    return s;
  }

  detach(tabId) {
    const s = this.sessions.get(tabId);
    if (!s) return;
    this.sessions.delete(tabId);
    this.toClient({ method: 'Target.detachedFromTarget', params: { sessionId: s.sessionId, targetId: s.targetInfo?.targetId } });
  }

  close() { this.bridge.close(); this.wss?.close(); }
}

/** Connects Playwright to the user's Chrome through the extension. Returns { browser, context, relay }. */
export async function connectChrome(sockPath) {
  const relay = new ChromeRelay(sockPath);
  const url = await relay.start();
  const browser = await chromium.connectOverCDP(url);
  const context = browser.contexts()[0];
  return { browser, context, relay };
}
