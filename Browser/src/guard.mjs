import fs from 'node:fs';
import path from 'node:path';
import { KEY_PATTERNS, findKeyLike, recipeFor, CREATE_CLICK, looksLikeNewSecret } from './recipes.mjs';

const MASK = '••••••••';
const TEXT_EXT = new Set(['.yml', '.yaml', '.md', '.txt', '.json', '.log', '.html', '.har', '']);

/** Encodings a password can show up in: as typed, in a form post, in JSON, in HTML, in base64. */
export function variants(s) {
  const out = new Set([s]);
  const uri = encodeURIComponent(s);
  out.add(uri);
  out.add(uri.replace(/%20/g, '+'));
  out.add(JSON.stringify(s).slice(1, -1));
  out.add(s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'));
  out.add(Buffer.from(s).toString('base64').replace(/=+$/, ''));
  return [...out].filter((v) => v.length >= 4).sort((a, b) => b.length - a.length);
}

export const isWebStore = (u) => {
  try { const x = new URL(u); return x.hostname === 'chromewebstore.google.com' || (x.hostname === 'chrome.google.com' && x.pathname.startsWith('/webstore')); }
  catch { return false; }
};

const originOf = (u) => { try { return new URL(u).origin; } catch { return null; } };

/**
 * Runs in each frame: values of password fields, whether a known secret shows anywhere readable, and every
 * long token on the page (text, input values, alt/title/aria-label), for spotting newly shown API keys.
 */
function inspectFrame(secrets) {
  const pw = [...document.querySelectorAll('input[type=password]')].map((i) => i.value).filter((v) => v.length >= 4);
  const visible = [];
  const texts = [document.body?.innerText || ''];
  for (const el of document.querySelectorAll('input:not([type=password]), textarea')) texts.push(el.value || '');
  for (const el of document.querySelectorAll('[alt], [title], [aria-label], [value], [data-value]')) {
    for (const a of ['alt', 'title', 'aria-label', 'value', 'data-value']) { const v = el.getAttribute(a); if (v) texts.push(v); }
  }
  for (const s of secrets) if (texts.some((t) => t.includes(s))) visible.push(s);
  const TOKEN = /[A-Za-z0-9_\-.+\/=]{4,}/g;
  // Exact values: single text nodes, input values and attributes.
  const tokens = new Set();
  for (const t of texts.slice(1)) for (const m of t.match(TOKEN) || []) tokens.add(m);
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n && tokens.size < 20000; n = walker.nextNode()) {
    for (const m of n.data.match(TOKEN) || []) tokens.add(m);
  }
  // Joined values: rendered text, where a key split across several elements reads as one string.
  const joined = [...new Set(texts[0].match(/[A-Za-z0-9_\-.+\/=]{12,}/g) || [])].filter((t) => !tokens.has(t)).slice(0, 5000);
  // Signs this is a page for creating API keys: URL, title, headings, buttons and links.
  const KEYISH = /\b(api[ _-]?keys?|secret[ _-]?keys?|access[ _-]?tokens?|personal[ _-]?access|api[ _-]?tokens?|tokens|credentials|secrets)\b|\b(create|generate|new|add)\b[^\n]{0,20}\b(key|token|secret)s?\b/i;
  const labels = [location.pathname.replace(/[\/_-]+/g, ' '), document.title];
  for (const el of document.querySelectorAll('h1, h2, h3, button, a, [role=button], [role=tab]')) labels.push((el.innerText || '').slice(0, 80));
  const keyish = labels.some((l) => KEYISH.test(l));
  return { pw, visible, tokens: [...tokens], joined, keyish, hasPasswordField: document.querySelector('input[type=password]') !== null };
}

function groupByPage(frames) {
  const byPage = new Map();
  for (const f of frames) {
    if (!byPage.has(f.page)) byPage.set(f.page, { tokens: [], joined: [] });
    byPage.get(f.page).tokens.push(...f.tokens);
    byPage.get(f.page).joined.push(...f.joined);
  }
  return byPage;
}

const CLIPBOARD_BLOCK = `(() => {
  const deny = () => Promise.reject(new DOMException('Clipboard is blocked by keydillo', 'NotAllowedError'));
  try { if (navigator.clipboard) for (const m of ['write', 'writeText', 'read', 'readText']) Object.defineProperty(navigator.clipboard, m, { value: deny }); } catch {}
  const exec = Document.prototype.execCommand;
  Document.prototype.execCommand = function (cmd, ...rest) { return /^(copy|cut)$/i.test(cmd) ? false : exec.call(this, cmd, ...rest); };
  for (const t of ['copy', 'cut']) window.addEventListener(t, (e) => { e.stopImmediatePropagation(); e.preventDefault(); }, true);
})();`;

const keyLabel = (k) => `[key hidden …${k.slice(-4)}]`;

export class Guard {
  constructor({ getContext, outputDir }) {
    this.getContext = getContext;
    this.outputDir = outputDir;
    this.secrets = new Set();       // passwords and codes filled this session
    this.filledOrigins = new Set(); // origins fill_login has signed in to
    this.passwords = new Set();     // passwords only (2FA codes are too short to match on safely)
    this.endpoints = new Set();     // approved form endpoints (origin + path) a password may be sent to
    this.blocked = [];              // requests stopped because they carried a password elsewhere
    this.keys = new Set();          // API keys seen on pages this session (always hidden)
    this.keyPieces = new Set();     // parts of a key split across elements (hidden, not saveable)
    this.strict = new Map();        // page -> { baseline, path, saved }: API-key pages, where new values are hidden
    this.savedKeys = new Set();
    this.sent = [];                 // text of every result sent to Claude this session, for exposure checks
    this.sentBytes = 0;
  }

  /** Remembers what Claude was shown (already masked), so a saved key can be checked against it. */
  recordSent(result) {
    for (const c of result.content || []) {
      if (c.type !== 'text' || this.sentBytes > 50e6) continue;
      this.sent.push(c.text); this.sentBytes += c.text.length;
    }
  }

  /** Was any 12+ character piece of this key in something Claude was shown? */
  exposed(key) {
    const n = Math.min(12, key.length);
    for (let i = 0; i + n <= key.length; i++) {
      const piece = key.slice(i, i + n);
      if (this.sent.some((t) => t.includes(piece))) return true;
    }
    return false;
  }

  /** Turns on strict mode for a tab: everything already on it is the baseline, anything new that looks like a key is hidden. */
  enableStrict(page, tokens) {
    const st = this.strict.get(page);
    if (st) { st.saved = false; return; }
    let p = null; try { const u = new URL(page.url()); p = u.origin + u.pathname; } catch {}
    this.strict.set(page, { baseline: new Set(tokens.filter((t) => !findKeyLike(t).length)), path: p, saved: false });
  }

  /** Updates hidden keys and strict mode from a scan. */
  track(frames) {
    const byPage = groupByPage(frames);
    for (const f of frames) for (const t of f.tokens) for (const k of findKeyLike(t)) this.keys.add(k);
    const keyish = new Set(frames.filter((f) => f.keyish).map((f) => f.page));
    for (const [page, { tokens, joined }] of byPage) {
      let p = null; try { const u = new URL(page.url()); p = u.origin + u.pathname; } catch {}
      const st = this.strict.get(page);
      const keyPage = recipeFor(page.url()) || keyish.has(page);
      if (st && st.path !== p && !keyPage) this.strict.delete(page); // left the keys page
      // Err toward strict: a known provider page, or anything that looks like an API-keys page.
      if (!this.strict.has(page) && keyPage) this.enableStrict(page, [...tokens, ...joined]);
      const cur = this.strict.get(page);
      if (!cur) continue;
      const fresh = tokens.filter((t) => !cur.baseline.has(t));
      for (const t of fresh) if (looksLikeNewSecret(t)) this.keys.add(t);
      // A key split across several elements reads as one string in the rendered text. It counts as a split key
      // only if it is made entirely of new pieces that each contain a digit; "KEY" + "Done" is not one.
      const parts = fresh.filter((t) => /[0-9]/.test(t)).sort((a, b) => b.length - a.length);
      for (const j of joined) {
        if (cur.baseline.has(j) || !looksLikeNewSecret(j)) continue;
        let rest = j;
        for (const t of parts) rest = rest.split(t).join('');
        if (rest.length) continue;
        this.keys.add(j);
        for (const t of parts) if (j.includes(t)) { this.keys.delete(t); this.keyPieces.add(t); }
      }
    }
    for (const page of [...this.strict.keys()]) if (page.isClosed()) this.strict.delete(page);
  }

  /** Whole keys currently shown on any open page (not pieces of a longer one). */
  async visibleKeys() {
    const frames = await this.scan();
    const on = frames.flatMap((f) => [...f.tokens, ...f.joined]);
    const shown = [...this.keys].filter((k) => on.some((t) => t.includes(k)));
    return shown.filter((k) => !shown.some((o) => o !== k && o.includes(k)));
  }

  /** Turns on strict mode for every open tab (start_key_capture, or a click on a "Create key" button). */
  async strictAll() {
    const frames = await this.scan();
    for (const [page, { tokens, joined }] of groupByPage(frames)) this.enableStrict(page, [...tokens, ...joined]);
  }

  markSaved(key) {
    this.savedKeys.add(key);
    for (const st of this.strict.values()) st.saved = true;
  }

  remember(secret, origin, { password = false } = {}) {
    if (secret && secret.length >= 4) this.secrets.add(secret);
    if (password && secret) this.passwords.add(secret);
    if (origin) this.filledOrigins.add(origin);
  }

  allowEndpoint(action) { this.endpoints.add(action); }

  /**
   * Network-level lock. Page script can change a form's target after keydillo checked it, or copy the
   * password into a fetch. Any request carrying a filled password, in its URL or body, is aborted unless
   * it goes to an endpoint the user approved for that login.
   */
  carriesPassword(text) {
    return [...this.passwords].some((p) => variants(p).some((v) => text.includes(v)));
  }

  async install(context) {
    await context.addInitScript(CLIPBOARD_BLOCK);
    // WebSockets too: a page script could send the password over one instead of a request.
    await context.routeWebSocket(() => true, (ws) => {
      const server = ws.connectToServer();
      ws.onMessage((m) => {
        const t = typeof m === 'string' ? m : Buffer.from(m).toString('latin1');
        if (this.passwords.size && this.carriesPassword(t)) {
          this.blocked.push(ws.url());
          ws.close({ code: 1008, reason: 'blocked by keydillo' });
          return;
        }
        server.send(m);
      });
      server.onMessage((m) => ws.send(m));
    });
    await context.route('**/*', async (route) => {
      const req = route.request();
      if (isWebStore(req.url())) return route.abort('blockedbyclient');
      if (this.passwords.size) {
        const body = req.postDataBuffer()?.toString('latin1') ?? '';
        const hay = req.url() + '\n' + body;
        const carries = [...this.passwords].some((p) => variants(p).some((v) => hay.includes(v)));
        let key = null;
        try { const u = new URL(req.url()); key = u.origin + u.pathname; } catch {}
        if (carries && !this.endpoints.has(key)) {
          this.blocked.push(key);
          return route.abort('blockedbyclient');
        }
      }
      return route.fallback();
    });
  }

  async scan() {
    const ctx = this.getContext();
    const frames = [];
    for (const page of ctx?.pages() ?? []) {
      for (const frame of page.frames()) {
        try { frames.push({ page, frame, ...(await frame.evaluate(inspectFrame, [...this.secrets, ...this.keys])) }); } catch {}
      }
    }
    this.track(frames);
    return frames;
  }

  async allSecrets() {
    const all = new Set(this.secrets);
    for (const f of await this.scan()) f.pw.forEach((v) => all.add(v));
    return all;
  }

  hideKeys(s) {
    for (const k of [...this.keys].sort((a, b) => b.length - a.length)) for (const v of variants(k)) s = s.split(v).join(keyLabel(k));
    for (const k of [...this.keyPieces].sort((a, b) => b.length - a.length)) s = s.split(k).join('[part of a hidden key]');
    for (const re of KEY_PATTERNS) s = s.replace(re, (m) => keyLabel(m));
    return s;
  }

  scrubString(s, secrets) {
    // Session cookies and auth headers from network tools: a signed-in session is nearly as good as the password.
    s = s.replace(/^(\s*(?:cookie|set-cookie|authorization|proxy-authorization)\s*:).*$/gim, '$1 [hidden by keydillo]');
    s = this.hideKeys(s);
    for (const secret of secrets) for (const v of variants(secret)) s = s.split(v).join(MASK);
    return s;
  }

  async scrubResult(result) {
    // Console output is banned: drop Playwright MCP's pointers to its console log files.
    result = { ...result, content: (result.content || []).map((c) => (c.type === 'text'
      ? { ...c, text: c.text.replace(/^.*(console entries|console-[^\s]*\.log).*\n?/gim, '') } : c)) };
    const secrets = await this.allSecrets();
    return {
      ...result,
      content: (result.content || []).map((c) => (c.type === 'text' ? { ...c, text: this.scrubString(c.text, secrets) } : c)),
    };
  }

  /** Playwright MCP saves snapshots and other output as files the agent can open, so mask those too. */
  async scrubFiles(since) {
    const secrets = await this.allSecrets();
    const walk = (dir) => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) { walk(p); continue; }
        if (/^console-.*\.log$/.test(e.name)) { fs.rmSync(p, { force: true }); continue; }
        if (!TEXT_EXT.has(path.extname(p).toLowerCase())) continue;
        if (fs.statSync(p).mtimeMs < since - 1000) continue;
        const s = fs.readFileSync(p, 'utf8');
        const t = this.scrubString(s, secrets);
        if (t !== s) fs.writeFileSync(p, t);
      }
    };
    try { walk(this.outputDir); } catch {}
  }

  /** Returns a refusal message, or null to let the call through. May rewrite args in place. */
  async before(name, args) {
    // Keep every file Playwright MCP writes inside its output folder, where it gets masked.
    if (typeof args.filename === 'string') args.filename = path.join(this.outputDir, path.basename(args.filename));

    for (const u of [args.url].filter((x) => typeof x === 'string')) {
      if (/^\s*(javascript|chrome|chrome-extension|chrome-untrusted|devtools|edge|view-source):/i.test(u)) {
        return `${u.split(':')[0]}: URLs are blocked by keydillo-login.`;
      }
      if (isWebStore(u)) return 'The Chrome Web Store is blocked: extensions are turned off in this browser.';
    }

    if (name === 'browser_press_key' && /^(meta|control|ctrl|cmd|controlormeta)\+(c|x)$/i.test(String(args.key || '').trim())) {
      return 'Copy and cut are blocked by keydillo-login, so keys and passwords stay off the clipboard.';
    }

    if (name === 'browser_click') {
      // About to show a new secret? Judge by the agent's description and by the element's real text.
      let label = String(args.element || '');
      const target = String(args.target || '');
      if (target) {
        for (const page of this.getContext()?.pages() ?? []) {
          const loc = /^f?\d*e\d+$/.test(target) ? page.locator(`aria-ref=${target}`) : page.locator(target);
          try { label += ' ' + (await loc.first().innerText({ timeout: 500 })); break; } catch {}
        }
      }
      if (CREATE_CLICK.test(label)) await this.strictAll();
    }

    if (name === 'browser_evaluate') {
      const frames = await this.scan();
      if (this.strict.size || frames.some((f) => f.tokens.some((t) => [...this.keys].some((k) => t.includes(k))))) {
        return 'browser_evaluate is blocked while an API-key page is open or a key is showing.';
      }
      if (frames.some((f) => f.hasPasswordField)) {
        return 'browser_evaluate is blocked while a page has a password field, so passwords stay unreadable. Use browser_snapshot, browser_click and browser_type instead.';
      }
      const open = frames.map((f) => originOf(f.frame.url()));
      if (open.some((o) => this.filledOrigins.has(o))) {
        return 'browser_evaluate is blocked on sites keydillo signed in to this session. Use browser_snapshot instead.';
      }
    }

    if (name === 'browser_take_screenshot') {
      const frames = await this.scan();
      if (frames.some((f) => f.visible.length)) {
        return 'Screenshot refused: a password or API key is showing as plain text on the page. Use browser_snapshot (values are hidden there), or save the key with save_new_key / close the dialog first.';
      }
      if ([...this.strict.values()].some((st) => !st.saved)) {
        return 'Screenshot refused on an API-key page until the new key is saved with save_new_key or you leave the page (a key could be drawn in an image). Use browser_snapshot instead.';
      }
    }

    return null;
  }
}
