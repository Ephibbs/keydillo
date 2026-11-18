# keydillo on Product Hunt

Draft kit. Nothing has been posted.

## Date

**Tuesday, December 1, 2026. Live at 12:01 AM PT.**

A week after Show HN lands on Thanksgiving week (Thursday, Nov 26), when Product Hunt traffic drops. Tuesday Dec 1 is the first strong weekday after it, and leaves room to ship 0.1.2 and fix what HN finds. If you'd rather go sooner, Tuesday Nov 24 works: fewer launches to compete with, but fewer visitors too.

Before scheduling, 0.1.2 should be the latest GitHub release, so the download link, Homebrew cask and site all point at the DMG.

## Listing

**Name:** keydillo

**Tagline** (44 characters):
> Let AI use your API keys without seeing them

**Description** (under 260 characters):
> A free, open-source Mac app for coding with AI. Your .env holds placeholders, the real keys stay in the Keychain, and a local proxy adds them only for each key's own host after Touch ID. Works with Claude Code, Cursor and Codex.

**Links:**
- Website: https://ephibbs.github.io/keydillo-site/
- GitHub: https://github.com/Ephibbs/keydillo

**Pricing:** Free. **Open source:** yes (MIT).

**Topics**, in order (pick as many as the form allows):
1. Developer Tools
2. Mac
3. Open Source
4. Privacy
5. Artificial Intelligence

**Thumbnail:** `thumbnail.png` (240x240, the app icon).

## Gallery

In `gallery/`, 1270x760, with `@2x` versions at 2540x1520. Upload the plain ones; use the `@2x` files if Product Hunt accepts them, they're sharper on Retina screens.

1. `1-cover.png`: headline, a `.env` with placeholders, `kd npm run dev`
2. `2-how-it-works.png`: program → keydillo → api.openai.com, placeholder in, real key out
3. `3-claude-code.png`: the Touch ID prompt over a Claude Code session
4. `4-app.png`: the main window, keys by project
5. `5-limits.png`: what it protects and what it doesn't

Optional 6th slot: the Cursor GIF (`demo-cursor.gif` in the project files) or `keydillo-demo.gif` from the site. Product Hunt shows GIFs in the gallery; keep it under about 3 MB.

Sources are in `source/`. `gallery.html` holds all five; `node shoot.js` re-renders them (needs Playwright and the Inter and JetBrains Mono fonts).

## First comment

Post this as soon as the launch is live. Change the story to match what actually happened to you; the details below are a placeholder.

> Hi, I'm Evan. I made keydillo after watching Claude Code read my .env.
>
> I'd asked it to debug a failing Stripe call. The first thing it did was cat .env, and there were my live keys, in the transcript and sent off to the model. Nothing bad happened, but I'd been pasting keys into agent chats for months without thinking about it, and most people I asked do the same thing.
>
> keydillo is my fix. Your .env holds placeholders like keydillo:openai. The real keys live in the Mac Keychain. When you run a command with kd in front (Claude adds it for you), a local proxy swaps the placeholder for the real key on the way out, only to that key's own host, after Touch ID. The agent can run your app and call the API without ever having the key.
>
> What it doesn't do, so you can judge it fairly:
> - Secrets your app uses itself, like database URLs and JWT secrets, are handed to the program at start. They're out of your files, but not fully hidden.
> - Go and Rust clients ignore kd's certificate, so they need to call the local base URL instead.
> - Once you approve a session, that program can use the key. keydillo guards the key, not what's done with it.
>
> It's free, MIT licensed, local only, with no account and no telemetry. Mac only for now (macOS 15+).
>
> I'd love to hear where it breaks for you, especially clients and SDKs I haven't tested.

## Launch day

All times PT.

**The week before**
- [ ] Ship 0.1.2 and check the DMG, `brew install --cask ephibbs/keydillo/keydillo` and the site's download button on a clean Mac
- [ ] Fold anything HN raised into the README, FAQ and this kit
- [ ] Create the launch in Product Hunt's form and schedule it for Dec 1, 12:01 AM
- [ ] Add the gallery, thumbnail, topics and links; preview it
- [ ] Make sure your Product Hunt profile has a photo, a headline and your GitHub/X links

**Launch day**
- [ ] 12:01 AM: check the page is live and post the first comment
- [ ] Share the link where you already posted (Reddit threads, X, the HN thread if it fits). Ask people to try it and say what breaks, not to upvote; Product Hunt penalises vote requests.
- [ ] Morning: reply to every comment. Answer security questions plainly and point to the limits slide and SECURITY.md.
- [ ] Keep the repo issues open and fix small things the same day if you can
- [ ] Evening: thank people in a reply on the launch, note the questions that came up for the FAQ

**After**
- [ ] Add the Product Hunt link to the site footer and README only if you want it there
- [ ] Turn repeated questions into FAQ entries
