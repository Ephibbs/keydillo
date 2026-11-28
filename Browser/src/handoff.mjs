// Hand-off to the user: keydillo shows the page on the Mac and streams it to the paired iPhone; taps and typing from
// the phone are applied here. Claude only gets "the user is done" back.
// In the user's own Chrome (`chrome`, the extension relay), the tab itself also says "Your turn: …" with a Done
// button, so they can just do it there. That works without the keydillo app too.

const FRAME_EVERY_MS = 1000;

/** Frames that hold a captcha (reCAPTCHA, hCaptcha, Turnstile, Arkose, DataDome). */
export const CAPTCHA_FRAME = /(google\.com|recaptcha\.net)\/recaptcha|hcaptcha\.com|challenges\.cloudflare\.com|arkoselabs\.com|funcaptcha\.com|captcha-delivery\.com|geo\.captcha/i;

/**
 * The part of the page worth showing on a phone: every visible captcha frame (the checkbox and, once it opens, the
 * picture puzzle), with some room around it. Null when there's no captcha, so the whole page is shown.
 */
async function captchaArea(page) {
  const view = await page.evaluate(() => ({ width: innerWidth, height: innerHeight })).catch(() => null);
  if (!view) return null;
  const boxes = [];
  for (const f of page.frames()) {
    if (!CAPTCHA_FRAME.test(f.url())) continue;
    const el = await f.frameElement().catch(() => null);
    const b = await el?.boundingBox().catch(() => null);
    if (b && b.width > 30 && b.height > 30 && b.x < view.width && b.y < view.height && b.x + b.width > 0 && b.y + b.height > 0) boxes.push(b);
  }
  if (!boxes.length) return null;
  const pad = 24;
  let x0 = Math.min(...boxes.map((b) => b.x)) - pad, y0 = Math.min(...boxes.map((b) => b.y)) - pad;
  let x1 = Math.max(...boxes.map((b) => b.x + b.width)) + pad, y1 = Math.max(...boxes.map((b) => b.y + b.height)) + pad;
  // Not narrower than a phone-sized column, so a lone checkbox isn't blown up past readable.
  const minW = Math.min(420, view.width);
  if (x1 - x0 < minW) { const c = (x0 + x1) / 2; x0 = c - minW / 2; x1 = c + minW / 2; }
  x0 = Math.max(0, x0); y0 = Math.max(0, y0); x1 = Math.min(view.width, x1); y1 = Math.min(view.height, y1);
  return { x: Math.round(x0), y: Math.round(y0), width: Math.round(x1 - x0), height: Math.round(y1 - y0) };
}
const LIMIT_MS = 10 * 60 * 1000;

export async function handOff({ context, store, reason, chrome }) {
  const app = typeof store.handoffStart === 'function';
  if (!app && !chrome) {
    return { ok: false, message: 'Hand-offs need the keydillo app. Ask the user to do this step in the browser window themselves, then continue.' };
  }
  const page = context.pages().at(-1);
  if (!page) return { ok: false, message: 'No page is open.' };
  await page.bringToFront().catch(() => {});
  let doneInChrome = false;
  const local = chrome?.yourTurn(reason).then(() => { doneInChrome = true; });
  const finished = (via) => ({ ok: true, message: `The user finished${via ? ` on ${via}` : ''}. Take a snapshot to see where the page is now.` });
  try {
    if (!app) {
      const t = await Promise.race([local.then(() => 'done'), new Promise((r) => setTimeout(() => r('late'), LIMIT_MS))]);
      return t === 'done' ? finished('Chrome') : { ok: false, message: 'The user didn\'t finish within 10 minutes.' };
    }
    return await streamed({ page, store, reason, done: () => doneInChrome, finished });
  } finally {
    chrome?.endTurn();
  }
}

async function streamed({ page, store, reason, done, finished }) {
  const start = await store.handoffStart(reason, page.url());
  const session = start.session;
  const until = Date.now() + LIMIT_MS;
  let via = 'the Mac';
  try {
    while (Date.now() < until) {
      if (done()) return finished('Chrome');
      // On a captcha, send just the captcha (zoomed in), not the whole desktop page shrunk to a phone's width.
      const area = await captchaArea(page);
      const shot = await page.screenshot({ type: 'jpeg', quality: area ? 70 : 55, scale: 'css', ...(area ? { clip: area } : {}) }).catch(() => null);
      const view = await page.evaluate(() => ({ width: innerWidth, height: innerHeight })).catch(() => ({ width: 0, height: 0 }));
      const size = area || { x: 0, y: 0, ...view };
      const r = await store.handoffFrame(session, {
        jpeg: shot ? shot.toString('base64') : '', width: size.width, height: size.height, url: page.url(),
      });
      // Taps are fractions of the image the user saw, which is this area of the page.
      for (const i of r.inputs || []) {
        via = 'their iPhone';
        if (i.action === 'tap' && size.width) await page.mouse.click(size.x + i.x * size.width, size.y + i.y * size.height);
        else if (i.action === 'text' && i.text) await page.keyboard.type(i.text);
        else if (i.action === 'key' && i.text) await page.keyboard.press(i.text).catch(() => {});
      }
      if (r.done) {
        if (r.cancelled) return { ok: false, message: 'The user cancelled the hand-off.' };
        return finished(r.via || via);
      }
      await new Promise((res) => setTimeout(res, FRAME_EVERY_MS));
    }
    return { ok: false, message: 'The user didn\'t finish within 10 minutes.' };
  } finally {
    await store.handoffEnd(session).catch(() => {});
  }
}
