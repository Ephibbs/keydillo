// Shared by the service worker and the popup.

// Commands that read or change things beyond the tab Claude is using. Chrome's debugger lets one tab read every
// cookie in the browser, including other sites' sign-in cookies, so those are refused outright.
const TARGET_OK = new Set(['setAutoAttach', 'getTargetInfo', 'setDiscoverTargets', 'detachFromTarget', 'runIfWaitingForDebugger']);
export function refused(method) {
  const [domain, name] = String(method).split('.');
  if (domain === 'Target') return !TARGET_OK.has(name);
  if (/cookie/i.test(name || '')) return true; // Network.getAllCookies, Storage.getCookies, Network.setCookie, ...
  if (['Browser', 'SystemInfo', 'Tracing', 'Memory', 'HeapProfiler', 'DOMStorage', 'IndexedDB', 'CacheStorage', 'Storage'].includes(domain)) return true;
  if (method === 'Page.setDownloadBehavior') return true; // downloads stay off (a key file would land in ~/Downloads)
  return false;
}

/** Extensions that could read what's on Claude's pages, so a password or key could reach them. */
export async function riskyExtensions() {
  const { trusted = {} } = await chrome.storage.local.get('trusted');
  const all = await chrome.management.getAll();
  const out = [];
  for (const e of all) {
    if (!e.enabled || e.id === chrome.runtime.id || e.type !== 'extension') continue;
    const perms = e.permissions || [], hosts = e.hostPermissions || [];
    if (perms.includes('debugger')) out.push({ id: e.id, name: e.name, reason: 'can control any tab with Chrome\'s debugger', canTrust: false });
    else if (hosts.some((h) => /^(<all_urls>|\*:\/\/\*\/\*|https?:\/\/\*\/\*|\*:\/\/\*\/|https?:\/\/\*\/)$/.test(h))) {
      out.push({ id: e.id, name: e.name, reason: 'can read every website', canTrust: true, trusted: !!trusted[e.id] });
    }
  }
  return out;
}

