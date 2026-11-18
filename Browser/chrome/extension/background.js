// keydillo for Chrome: the only way Claude drives this browser.
//
// The extension is a thin driver. keydillo's browser tool (Playwright MCP plus keydillo's masking) sends it
// Chrome DevTools commands through a native messaging host; it runs them only on Claude's own tabs, the ones
// in the "Claude · keydillo" tab group, and refuses commands that reach outside a tab (other sites' cookies,
// other tabs, the browser). Passwords and keys are handled by the browser tool and the keydillo app, never here.

const HOST = 'com.studiokillswitch.keydillo';
const GROUP_TITLE = 'Claude · keydillo';

import { refused, riskyExtensions } from './shared.js';

let port = null;
let clientConnected = false;
const ours = new Set();
let groupId = null;

const save = () => chrome.storage.session.set({ ours: [...ours], groupId }).catch(() => {});
const restored = chrome.storage.session.get(['ours', 'groupId']).then(async (s) => {
  for (const id of s.ours || []) { try { await chrome.tabs.get(id); ours.add(id); } catch {} }
  groupId = s.groupId ?? null;
}).catch(() => {});

function send(msg) { try { port?.postMessage(msg); } catch {} }
const event = (method, params) => send({ method, params });

async function intoGroup(tabId) {
  try {
    if (groupId !== null) { await chrome.tabGroups.get(groupId); await chrome.tabs.group({ groupId, tabIds: [tabId] }); return; }
  } catch {}
  groupId = await chrome.tabs.group({ tabIds: [tabId] });
  await chrome.tabGroups.update(groupId, { title: GROUP_TITLE, color: 'grey' });
  save();
}

async function adopt(tab) {
  ours.add(tab.id);
  save();
  try { await intoGroup(tab.id); } catch {}
}

function drop(tabId) {
  if (!ours.delete(tabId)) return false;
  save();
  chrome.debugger.detach({ tabId }).catch(() => {});
  return true;
}

function mine(tabId) {
  if (!ours.has(tabId)) throw new Error('Refused by keydillo: that tab is not one of Claude\'s tabs.');
}

const handlers = {
  async 'chrome.tabs.create'([props]) {
    const tab = await chrome.tabs.create({ url: props?.url || 'about:blank', active: !!props?.active });
    await adopt(tab);
    return tab;
  },
  async 'chrome.tabs.remove'([tabId]) { mine(tabId); await chrome.tabs.remove(tabId); },
  async 'chrome.debugger.attach'([target, version]) {
    mine(target.tabId);
    await chrome.debugger.attach({ tabId: target.tabId }, version);
    await chrome.debugger.sendCommand({ tabId: target.tabId }, 'Page.setDownloadBehavior', { behavior: 'deny' }).catch(() => {});
  },
  async 'chrome.debugger.sendCommand'([target, method, params]) {
    mine(target.tabId);
    if (refused(method)) throw new Error(`Refused by keydillo: ${method} reaches outside Claude's tab.`);
    return await chrome.debugger.sendCommand(target, method, params);
  },
  async 'keydillo.status'() {
    return { extensions: await riskyExtensions(), tabs: ours.size, version: chrome.runtime.getManifest().version };
  },
};

async function onMessage(msg) {
  await restored;
  if (msg.method === 'client.hello') {
    clientConnected = true;
    for (const id of [...ours]) {
      try { event('chrome.tabs.onCreated', [await chrome.tabs.get(id)]); } catch { ours.delete(id); }
    }
    event('extension.initialized', []);
    return;
  }
  if (msg.method === 'client.bye') {
    clientConnected = false;
    for (const id of ours) chrome.debugger.detach({ tabId: id }).catch(() => {});
    return;
  }
  const h = handlers[msg.method];
  try {
    if (!h) throw new Error('Refused by keydillo: ' + msg.method);
    send({ id: msg.id, result: (await h(msg.params || [])) ?? null });
  } catch (e) {
    send({ id: msg.id, error: String(e?.message || e) });
  }
}

function connect() {
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => {
    port = null; clientConnected = false;
    for (const id of ours) chrome.debugger.detach({ tabId: id }).catch(() => {});
    setTimeout(connect, 5000);
  });
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (ours.has(source.tabId)) event('chrome.debugger.onEvent', [source, method, params]);
});
chrome.debugger.onDetach.addListener((source, reason) => {
  if (ours.has(source.tabId)) event('chrome.debugger.onDetach', [source, reason]);
});
// Pop-ups Claude's pages open are Claude's too.
chrome.tabs.onCreated.addListener(async (tab) => {
  await restored;
  if (tab.openerTabId !== undefined && ours.has(tab.openerTabId) && !ours.has(tab.id)) {
    await adopt(tab);
    event('chrome.tabs.onCreated', [tab]);
  }
});
chrome.tabs.onRemoved.addListener((tabId) => { if (drop(tabId)) event('chrome.tabs.onRemoved', [tabId]); });
// Drag a tab out of Claude's group to take it back; drag one in to hand it to Claude.
chrome.tabs.onUpdated.addListener(async (tabId, change, tab) => {
  if (change.groupId === undefined) return;
  await restored;
  if (ours.has(tabId) && change.groupId !== groupId) { if (drop(tabId)) event('chrome.tabs.onRemoved', [tabId]); }
  else if (!ours.has(tabId) && groupId !== null && change.groupId === groupId && clientConnected) {
    ours.add(tabId); save();
    event('chrome.tabs.onCreated', [tab]);
  }
});

connect();
