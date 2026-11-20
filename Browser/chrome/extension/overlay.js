// Drawn on Claude's tabs: a "Claude is using this tab" pill with Stop, and Claude's cursor with a label of what it's
// doing. Runs in its own JavaScript world ("keydillo"), inside a closed shadow root, so page scripts can't reach it.
// It's hidden from accessibility, so it never shows up in what Claude reads, and Stop only answers a real click.
(() => {
  if (window.top !== window || globalThis.__kd) return;
  const kd = (globalThis.__kd = {});

  const host = document.createElement('keydillo-overlay');
  host.setAttribute('aria-hidden', 'true');
  host.style.cssText = 'all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none; display: block;';
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `
<style>
  * { box-sizing: border-box; }
  :host { all: initial; }
  .pill { position: fixed; top: 12px; left: 50%; transform: translateX(-50%); display: flex; align-items: center; gap: 10px;
    padding: 6px 6px 6px 12px; border-radius: 999px; background: #111; color: #fff; pointer-events: none; user-select: none;
    font: 500 12px/1.2 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; box-shadow: 0 4px 14px rgba(0,0,0,.18); white-space: nowrap; }
  .pill svg { width: 22px; height: 15px; display: block; }
  button { all: unset; cursor: pointer; background: #fff; color: #111; border-radius: 999px; padding: 4px 11px;
    font: 600 11.5px/1.2 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
  button:hover { background: #e9e9e9; }
  button:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }
  .cur { position: fixed; left: 0; top: 0; transition: transform .22s ease-out; will-change: transform; }
  .cur[hidden] { display: none; }
  .cur svg { width: 18px; height: 22px; display: block; filter: drop-shadow(0 1px 1.5px rgba(0,0,0,.25)); }
  .label { position: absolute; left: 18px; top: 20px; white-space: nowrap; max-width: 320px; overflow: hidden; text-overflow: ellipsis;
    background: #111; color: #fff; border-radius: 999px; padding: 4px 10px; transition: opacity .2s ease-out;
    font: 500 11.5px/1.2 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
  .label.off { opacity: 0; }
  .solo { position: fixed; top: 52px; left: 50%; transform: translateX(-50%); }
</style>
<div class="pill" part="pill">
  <svg viewBox="1.05 24.53 101.40 69.93" aria-hidden="true"><mask id="kdm" maskUnits="userSpaceOnUse" x="-20" y="-20" width="140" height="140"><g fill="#fff"><circle cx="12" cy="62" r="6.5"/><circle cx="29" cy="62" r="6.5"/><circle cx="46" cy="62" r="6.5"/><path d="M58 68.5 A16 18 0 0 1 90 68.5 Z"/><path d="M87 58 C92 59 96 63 98 68.5 L85 68.5 Z"/><path d="M87 59 L89.5 52 L92 60 Z"/></g><path d="M68 48 V69 M74 48 V69 M80 48 V69" stroke="#000" stroke-width="2.4"/></mask><rect x="-20" y="-20" width="140" height="140" fill="#fff" mask="url(#kdm)"/></svg>
  <span>Claude is using this tab</span>
  <button type="button">Stop</button>
</div>
<div class="cur" hidden>
  <svg viewBox="0 0 18 22"><path d="M1.5 1.5 L1.5 17.5 L5.6 13.6 L8.6 20.3 L11.4 19.1 L8.5 12.6 L14.2 12.6 Z" fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>
  <span class="label off"></span>
</div>
<span class="label solo off"></span>`;

  const pill = root.querySelector('.pill');
  const cur = root.querySelector('.cur');
  const curLabel = root.querySelector('.cur .label');
  const soloLabel = root.querySelector('.solo');
  root.querySelector('button').addEventListener('click', (e) => {
    if (!e.isTrusted) return; // only a real click by the user
    try { globalThis.kdStop?.('stop'); } catch {}
  });

  // The pill lets clicks through, so it never gets in the way of Claude's clicks, except while your own mouse is on
  // it. Claude's mouse events count as real too, so the pill stays click-through while Claude is moving the mouse.
  let busyUntil = 0;
  kd.busy = () => { busyUntil = performance.now() + 800; pill.style.pointerEvents = 'none'; };
  addEventListener('mousemove', (e) => {
    if (performance.now() < busyUntil) return;
    const r = pill.getBoundingClientRect();
    const over = e.clientX >= r.left - 4 && e.clientX <= r.right + 4 && e.clientY >= r.top - 4 && e.clientY <= r.bottom + 4;
    pill.style.pointerEvents = over ? 'auto' : 'none';
  }, true);

  const mount = () => { if (!host.isConnected && document.documentElement) document.documentElement.appendChild(host); };
  const keep = new MutationObserver(mount);
  const start = () => { mount(); keep.observe(document.documentElement, { childList: true }); };
  if (document.documentElement) start(); else document.addEventListener('readystatechange', start, { once: true });

  let fade;
  kd.move = (x, y) => {
    if (cur.hidden && !soloLabel.classList.contains('off')) { // the label moves to the cursor once it appears
      curLabel.textContent = soloLabel.textContent;
      curLabel.classList.remove('off');
      soloLabel.classList.add('off');
    }
    cur.hidden = false;
    cur.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
  };
  kd.label = (text) => {
    const el = cur.hidden ? soloLabel : curLabel;
    (cur.hidden ? curLabel : soloLabel).classList.add('off');
    el.textContent = text;
    el.classList.remove('off');
    clearTimeout(fade);
    fade = setTimeout(() => el.classList.add('off'), 4000);
  };
  kd.remove = () => { keep.disconnect(); host.remove(); delete globalThis.__kd; };
})();
