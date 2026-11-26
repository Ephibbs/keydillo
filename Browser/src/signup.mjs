import crypto from 'node:crypto';

const pathKey = (u) => { try { const x = new URL(u); return x.origin + x.pathname; } catch { return null; } };
const originOf = (u) => { try { return new URL(u).origin; } catch { return null; } };

/** A strong password: random letters and digits, plus symbols unless the site refuses them. */
export function generatePassword({ length = 20, symbols = true } = {}) {
  const lower = 'abcdefghijkmnopqrstuvwxyz', upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ', digits = '23456789', sym = '!#$%&*+-=?@_';
  const sets = [lower, upper, digits, ...(symbols ? [sym] : [])];
  const all = sets.join('');
  const pick = (s) => s[crypto.randomInt(s.length)];
  const chars = sets.map(pick); // at least one of each kind
  while (chars.length < length) chars.push(pick(all));
  for (let i = chars.length - 1; i > 0; i--) { const j = crypto.randomInt(i + 1); [chars[i], chars[j]] = [chars[j], chars[i]]; }
  return chars.join('');
}

/** The sign-up form: the frame and form with the most visible password fields (new password + confirm). */
async function findSignupForm(context) {
  let best = null;
  for (const page of [...context.pages()].reverse()) {
    for (const frame of page.frames()) {
      const info = await frame.evaluate(() => {
        const vis = (el) => el.offsetParent !== null;
        const pws = [...document.querySelectorAll('input[type=password]')].filter(vis);
        if (!pws.length) return null;
        const form = pws[0].form;
        const fields = form ? pws.filter((p) => p.form === form) : pws;
        const scope = form || document;
        const user = [...scope.querySelectorAll('input')].filter(vis)
          .find((i) => /email|user|login/i.test(i.type + i.name + i.id + i.autocomplete) && i.type !== 'password');
        return {
          count: fields.length,
          action: form ? form.action : location.href,
          newHint: fields.some((p) => /new-password/.test(p.autocomplete)) || fields.length > 1,
          username: user ? user.value : '',
        };
      }).catch(() => null);
      if (info && (!best || info.count > best.info.count)) best = { page, frame, info };
    }
    if (best) break;
  }
  return best;
}

export async function fillNewPassword({ context, store, guard, login, username, length, symbols }) {
  if (!/^[a-z0-9][a-z0-9._-]{0,40}$/i.test(login || '')) return { ok: false, message: 'Pass "login", a short name for the new login, e.g. "github".' };
  const found = await findSignupForm(context);
  if (!found) return { ok: false, message: 'No password field is showing. Open the sign-up page and fill the other fields first, then call this.' };
  const { frame, info } = found;
  const site = originOf(frame.url());
  const local = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(site);
  if (!site || (!site.startsWith('https://') && !local)) return { ok: false, message: 'Only https sites.' };
  if (originOf(info.action) !== site) return { ok: false, message: `Refused: this form sends to a different site (${originOf(info.action)}) than the page (${site}).` };
  if (!info.newHint) return { ok: false, message: 'This looks like a sign-in form, not a sign-up form. Use fill_login to sign in.' };
  const user = String(username || info.username || '').trim();
  if (!user) return { ok: false, message: 'Type the email or username into the form first (or pass "username"), so the login is saved under it.' };

  const password = generatePassword({ length: Math.min(Math.max(Number(length) || 20, 12), 64), symbols: symbols !== false });
  // Saved before it is typed, so a sign-up that goes through never leaves a password you don't have.
  try {
    await store.saveNew(login, { site, username: user, password });
  } catch (e) {
    return { ok: false, message: /Denied/.test(e.message) ? 'The user declined Touch ID. Ask them before trying again.' : `Couldn't save the new password: ${e.message}` };
  }
  guard.remember(password, site, { password: true });
  guard.allowEndpoint(pathKey(info.action));

  const fields = frame.locator('input[type=password]:visible');
  const n = await fields.count();
  for (let i = 0; i < n; i++) await fields.nth(i).fill(password);
  return {
    ok: true,
    message: `Generated a ${password.length}-character password, saved it as login "${login}" (${user} on ${site}) and typed it into ${n} password field${n === 1 ? '' : 's'}. It shows to you as hidden. Finish the rest of the form and submit it yourself. If the site rejects the password's format, call this again with "length" or "symbols": false; that replaces the saved one.`,
  };
}
