import crypto from 'node:crypto';

const USERNAME = [
  'input[autocomplete~="username"]', 'input[autocomplete~="email"]', 'input[type="email"]',
  'input[name*="user" i]', 'input[name*="login" i]', 'input[name*="email" i]',
  'input[id*="user" i]', 'input[id*="login" i]', 'input[id*="email" i]',
].map((s) => `${s}:not([type="password"]):not([type="hidden"]):visible`).join(', ');
const PASSWORD = 'input[type="password"]:visible';
const OTP = [
  'input[autocomplete="one-time-code"]', 'input[name*="otp" i]', 'input[id*="otp" i]', 'input[name*="totp" i]',
  'input[id*="totp" i]', 'input[name*="2fa" i]', 'input[name*="mfa" i]', 'input[name*="code" i][inputmode="numeric"]',
].map((s) => `${s}:visible`).join(', ');

function base32(s) {
  const alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const c of s.replace(/=+$/, '')) { const v = alpha.indexOf(c); if (v < 0) throw new Error('Bad TOTP secret'); bits += v.toString(2).padStart(5, '0'); }
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}

export function totp(secret, now = Date.now()) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(now / 30000)));
  const h = crypto.createHmac('sha1', base32(secret)).update(counter).digest();
  const o = h[h.length - 1] & 0xf;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1_000_000).padStart(6, '0');
}

const originOf = (u) => { try { return new URL(u).origin; } catch { return null; } };

async function first(frame, selector) {
  const l = frame.locator(selector).first();
  return (await l.count()) ? l : null;
}

/** The frame on the login's own site that shows a sign-in field, in the most recent tab first. */
async function findFrame(context, site) {
  for (const page of [...context.pages()].reverse()) {
    for (const frame of page.frames()) {
      if (originOf(frame.url()) !== site) continue;
      if ((await first(frame, PASSWORD)) || (await first(frame, OTP)) || (await first(frame, USERNAME))) return { page, frame };
    }
  }
  return null;
}

/** Refuse when the form would post somewhere other than the saved site. */
async function formTargetOk(field, site) {
  const action = await field.evaluate((el) => (el.form ? el.form.action : location.href));
  return originOf(action) === site;
}

/** Fallback for forms with unusual names (Hacker News uses "acct"): the visible text field just before the password. */
async function fieldBefore(pw) {
  const h = await pw.evaluateHandle((el) => {
    const scope = el.form || document;
    const all = [...scope.querySelectorAll('input')];
    return all.slice(0, all.indexOf(el)).reverse()
      .find((i) => ['text', 'email', ''].includes(i.type) && i.offsetParent !== null) || null;
  });
  return h.asElement();
}

const pathKey = (u) => { try { const x = new URL(u); return x.origin + x.pathname; } catch { return null; } };

/** The sign-in page a field is on, and where its form sends what's typed into it. */
async function loginPageOf(frame, field) {
  const action = await field.evaluate((el) => (el.form ? el.form.action : location.href));
  return { page: pathKey(frame.url()), action: pathKey(action) };
}

async function submit(field) {
  const button = await field.evaluateHandle((el) => {
    const f = el.form;
    if (!f) return null;
    return [...f.querySelectorAll('button[type="submit"], input[type="submit"], button:not([type])')]
      .find((b) => b.offsetParent !== null && !b.disabled) || null;
  });
  const el = button.asElement();
  if (el) await el.click(); else await field.press('Enter');
}

async function settle(page) {
  await page.waitForLoadState('load', { timeout: 10_000 }).catch(() => {});
  await page.waitForTimeout(1500);
}

/** Empty any password field still holding a filled secret, e.g. after a failed sign-in. */
async function clearLeftovers(context, secrets) {
  for (const page of context.pages()) for (const frame of page.frames()) {
    await frame.evaluate((s) => {
      for (const i of document.querySelectorAll('input')) if (s.includes(i.value)) { i.value = ''; i.type = i.type === 'text' ? 'password' : i.type; }
    }, secrets).catch(() => {});
  }
}

class Stop extends Error {}

export async function fillLogin({ context, store, guard, login }) {
  const meta = await store.meta(login);
  if (!meta) return { ok: false, message: `No saved login named "${login}". Call list_logins to see the names, or request_login to have the user add one.` };
  const site = meta.site;

  const found = await findFrame(context, site);
  if (!found) {
    const open = context.pages().map((p) => p.url()).join(', ') || 'none';
    return { ok: false, message: `No sign-in form on ${site} is open. Navigate to the site's sign-in page first. Open tabs: ${open}. keydillo only fills "${login}" on ${site}.` };
  }
  const pw0 = await first(found.frame, PASSWORD);
  if (pw0 && !(await formTargetOk(pw0, site))) {
    return { ok: false, message: `Refused: the password form on this page posts to a different site than ${site}.` };
  }

  // Each login is locked to sign-in pages the user has approved. A new page gets its own Touch ID prompt naming it.
  const approved = [...(meta.pages || [])];
  const isApproved = (lp) => approved.some((p) => p.page === lp.page && p.action === lp.action);
  let secret;
  const unlock = async (lp) => {
    try {
      if (!secret) secret = await store.secret(login, lp);
      else if (!isApproved(lp)) await store.approve(login, lp);
    } catch (e) {
      if (/Denied/.test(e.message)) {
        throw new Stop(isApproved(lp)
          ? 'The user declined Touch ID. Ask them before trying again.'
          : `The user declined using "${login}" on a sign-in page it hasn't been used on before: ${lp.page} (sends to ${lp.action}). Ask the user before trying again.`);
      }
      throw new Stop(`Couldn't get the login: ${e.message}`);
    }
    if (!isApproved(lp)) approved.push(lp);
    guard.allowEndpoint(lp.action);
    guard.remember(secret.password, site, { password: true });
  };

  const page = found.page;
  const did = [];
  try {
    for (let step = 0; step < 4; step++) {
      const cur = await findFrame(context, site);
      if (!cur || cur.page !== page) break;
      const { frame } = cur;
      const pw = await first(frame, PASSWORD);
      const otp = !pw && (await first(frame, OTP));
      const user = (await first(frame, USERNAME)) || (pw && (await fieldBefore(pw)));

      if (pw) {
        if (did.includes('password')) break; // shown again: wrong password or a challenge
        if (!(await formTargetOk(pw, site))) { did.push('stopped: form posts to another site'); break; }
        await unlock(await loginPageOf(frame, pw));
        if (user && meta.username && (await user.inputValue()) !== meta.username) { await user.fill(meta.username); did.push('username'); }
        await pw.fill(secret.password);
        did.push('password');
        await submit(pw);
      } else if (otp) {
        if (!meta.hasTotp || did.includes('2FA code')) break;
        await unlock(await loginPageOf(frame, otp));
        const code = totp(secret.totp);
        guard.remember(code, site);
        await otp.fill(code);
        did.push('2FA code');
        await submit(otp);
      } else if (user && step === 0) {
        await user.fill(meta.username);
        did.push('username');
        await submit(user);
      } else break;
      await settle(page);
    }
  } catch (e) {
    if (!(e instanceof Stop)) throw e;
    return { ok: false, message: (did.length ? `Filled ${did.join(', ')} before stopping. ` : '') + e.message };
  } finally {
    await clearLeftovers(context, [...guard.secrets]);
  }

  const blocked = guard.blocked.splice(0);
  if (blocked.length) {
    return { ok: false, message: `Stopped: the page tried to send the password to ${blocked.join(', ')}, which isn't an approved sign-in endpoint for "${login}". Nothing was sent there. Tell the user.` };
  }
  const after = await findFrame(context, site);
  const stillPw = after && after.page === page && (await first(after.frame, PASSWORD));
  const stillOtp = after && after.page === page && (await first(after.frame, OTP));
  let status = 'Signed in, as far as keydillo can tell.';
  if (stillPw) status = 'A password field is still showing, so the sign-in probably failed (wrong password, captcha or extra check). Take a snapshot to see the message, and tell the user.';
  else if (stillOtp) status = 'The site is asking for a 2FA code and no TOTP secret is saved for this login. Ask the user to enter it in the browser.';
  return {
    ok: !stillPw,
    message: `Filled ${did.join(', ') || 'nothing'} for "${login}" on ${site} and submitted. ${status}\nNow at: ${page.url()} (${await page.title().catch(() => '')})`,
  };
}
