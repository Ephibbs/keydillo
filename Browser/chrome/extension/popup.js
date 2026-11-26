import { riskyExtensions } from './shared.js';

const $ = (id) => document.getElementById(id);

async function render() {
  const { ours = [] } = await chrome.storage.session.get('ours');
  $('status').innerHTML = ours.length
    ? `Claude has <b>${ours.length}</b> tab${ours.length === 1 ? '' : 's'} open, in the <b>Claude · keydillo</b> group. It can't see your other tabs.`
    : 'Claude has no tabs open. When it uses Chrome, its tabs go in the <b>Claude · keydillo</b> group, and it can\'t see your other tabs.';
  const list = await riskyExtensions();
  const { trusted = {} } = await chrome.storage.local.get('trusted');
  $('extHead').hidden = !list.length;
  $('ext').replaceChildren(...list.map((e) => {
    const li = document.createElement('li');
    const d = document.createElement('div');
    const b = document.createElement('b'); b.textContent = e.name;
    const s = document.createElement('span'); s.className = 'muted'; s.textContent = e.canTrust ? (e.trusted ? 'Trusted' : 'Blocks sign-in and saving keys') : 'Turn it off to let Claude sign in or save keys';
    d.append(b, s); li.append(d);
    if (e.canTrust) {
      const btn = document.createElement('button');
      btn.className = e.trusted ? 'quiet' : '';
      btn.textContent = e.trusted ? 'Untrust' : 'Trust';
      btn.onclick = async () => {
        if (e.trusted) delete trusted[e.id]; else trusted[e.id] = true;
        await chrome.storage.local.set({ trusted });
        render();
      };
      li.append(btn);
    }
    return li;
  }));
  $('note').textContent = list.length
    ? 'Trust an extension only if you trust it with every password and key Claude handles.'
    : 'No other extension can read Claude\'s pages.';
}
render();
