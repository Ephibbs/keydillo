// Hand-off to the user: keydillo shows the page on the Mac and streams it to the paired iPhone; taps and typing from
// the phone are applied here. Claude only gets "the user is done" back.

const FRAME_EVERY_MS = 1000;
const LIMIT_MS = 10 * 60 * 1000;

export async function handOff({ context, store, reason }) {
  if (typeof store.handoffStart !== 'function') {
    return { ok: false, message: 'Hand-offs need the keydillo app. Ask the user to do this step in the browser window themselves, then continue.' };
  }
  const page = context.pages().at(-1);
  if (!page) return { ok: false, message: 'No page is open.' };
  await page.bringToFront().catch(() => {});
  const start = await store.handoffStart(reason, page.url());
  const session = start.session;
  const until = Date.now() + LIMIT_MS;
  let via = 'the Mac';
  try {
    while (Date.now() < until) {
      const shot = await page.screenshot({ type: 'jpeg', quality: 55, scale: 'css' }).catch(() => null);
      const size = await page.evaluate(() => ({ width: innerWidth, height: innerHeight })).catch(() => ({ width: 0, height: 0 }));
      const r = await store.handoffFrame(session, {
        jpeg: shot ? shot.toString('base64') : '', width: size.width, height: size.height, url: page.url(),
      });
      for (const i of r.inputs || []) {
        via = 'their iPhone';
        if (i.action === 'tap' && size.width) await page.mouse.click(i.x * size.width, i.y * size.height);
        else if (i.action === 'text' && i.text) await page.keyboard.type(i.text);
        else if (i.action === 'key' && i.text) await page.keyboard.press(i.text).catch(() => {});
      }
      if (r.done) {
        if (r.cancelled) return { ok: false, message: 'The user cancelled the hand-off.' };
        return { ok: true, message: `The user finished on ${r.via || via}. Take a snapshot to see where the page is now.` };
      }
      await new Promise((res) => setTimeout(res, FRAME_EVERY_MS));
    }
    return { ok: false, message: 'The user didn\'t finish within 10 minutes.' };
  } finally {
    await store.handoffEnd(session).catch(() => {});
  }
}
