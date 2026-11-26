# keydillo for Chrome (prototype)

Lets Claude use your own Chrome, where you're already signed in, through keydillo. Claude signs in, signs up and creates API keys there, and never sees a password or key.

The extension replaces Claude in Chrome: it is Claude's only way into your browser, and everything Claude reads goes through keydillo's masking first (the same browser tool as the separate keydillo browser, in `Browser/`).

## The rules

1. **Claude only uses its own tabs.** They sit in a grey **Claude · keydillo** tab group. Claude can't see or touch your other tabs. Drag a tab out of the group to take it back; drag one in to hand it to Claude.
2. **Claude never gets a password or key.** Passwords are filled after Touch ID, keys are saved after Touch ID, and both show as `••••••••` / `[key hidden …abcd]` in everything Claude reads. Keys are drawn as dots on your screen too.
3. **Claude can't read cookies or run JavaScript in your Chrome.** Chrome's debugger would let one tab read every site's sign-in cookies, so the extension refuses those commands. Claude uses snapshots, clicks and typing instead.
4. **Signing in and saving keys stop while anything else could read the page.** The error names what to fix.
5. **You can see what Claude is doing.** Its tabs show a "Claude is using this tab" pill with **Stop**, and Claude's cursor with a short label ("Clicking "Create key""). Stop takes the tab back from Claude at once.
6. **Steps only a person can do come to you.** For a captcha, an "are you human" check, a 2FA code or a passkey, Claude calls `hand_off_to_user` (keydillo tells it to when it sees one). The tab's pill turns white and says "Your turn: …" with **Done**; with the keydillo app, the same page also streams to your paired iPhone, where you can tap and type, and to a window on your Mac. Whichever you finish on, Claude gets back only "the user finished". It never sees what you type. The overlay is drawn in its own JavaScript world inside a closed shadow root: page scripts can't reach it, it's left out of what Claude reads, and the pill lets clicks through, so it never blocks Claude's clicks and Claude can't press Stop.

| Side door | What keydillo does |
|---|---|
| Claude in Chrome, or any extension with the debugger permission | Signing in and saving keys refuse until it's off |
| An extension that can read every site (1Password, Grammarly, …) | Refuse until it's off, or you trust it in the keydillo extension's menu |
| Chrome started with a remote debugging port | Refuse (checked from Chrome's command line and `DevToolsActivePort`). Chrome 136 and later already ignore the flag on your normal profile |
| "Allow JavaScript from Apple Events" (View → Developer) | Refuse while it's on in any profile |
| Downloads from Claude's tabs | Always off, so a key file (AWS-style .csv) never lands in ~/Downloads |
| Chrome's profile on disk | Cookies and saved passwords are encrypted with Chrome's own Keychain item, which prompts any other app that asks. keydillo writes no secret to disk |

## Try it (about 5 minutes)

1. Register the native messaging host (writes one small file into Chrome's settings folder):
   ```sh
   cd ~/Desktop/keydillo-chrome/Browser && node chrome/install.mjs
   ```
2. In Chrome: `chrome://extensions` → turn on **Developer mode** → **Load unpacked** → choose `~/Desktop/keydillo-chrome/Browser/chrome/extension`. Its ID should be `cdhhnnnkegdlahpggglimplmchmahadb`. Turn off Claude in Chrome.
3. Give Claude Code the tool. With the standalone helper (logins in your login Keychain):
   ```sh
   cd ~/Desktop/keydillo-chrome/Browser && npm run build
   claude mcp add keydillo-chrome -- node ~/Desktop/keydillo-chrome/Browser/src/server.mjs --chrome
   ```
   Or through the keydillo app built from this branch: `defaults write com.studiokillswitch.keydillo browserUseChrome -bool true`, then restart keydillo; the `keydillo-browser` tool then drives your Chrome.
4. Ask Claude: "Open GitHub in my Chrome and tell me how many repositories I have." Its tab appears in the Claude · keydillo group.
5. Things to try: ask it to read a cookie or run JavaScript (refused); turn on "Allow JavaScript from Apple Events" and ask it to sign in somewhere (refused, with the fix); create an API key and watch it turn into dots on screen.

Chrome shows "keydillo started debugging this browser" while Claude is driving. Chrome adds that bar for any extension using its debugger, and it can't be hidden.

## Against a plaintext .env

An agent with a plaintext .env reads every key with `cat`. Here Claude never receives a password or a key. The ways around that are either closed (other tabs, cookies, JavaScript, downloads) or make the secret step refuse (other extensions, debugging port, Apple Events).

## Known limits

| Limit | Status |
|---|---|
| Claude's shell can connect to the native host's socket while the browser tool isn't connected, or edit this unpacked extension. The extension still limits it to Claude's tabs and refuses cookie reads | Open. Fixed by shipping the host inside the signed app (checking the caller's code signature) and the extension from the Chrome Web Store |
| Trusting an extension is a click in the keydillo extension's menu, not Touch ID yet | Open: moves to the app with the rest |
| A key with no known format shows on screen until Claude's next step, when keydillo spots it and dots it. Known formats (`sk-`, `ghp_`, …) are dotted the moment they appear | Accepted for the prototype |
| Apps with Accessibility or Screen Recording permission (screen readers, computer-use tools) can read what Chrome shows. Dots cover keys on screen; the Accessibility tree isn't covered | Open, documented |
| A pop-up can finish loading before keydillo attaches to it, so the first "page loaded" event is missed. Claude still sees it as one of its tabs | Accepted |
| Stop is tested only in the sense that Claude's own clicks can't trigger it; pressing it with your real mouse needs your run | Needs your run |
| Tested in Playwright's Chromium 130 with the extension loaded. Not yet in your Chrome | Needs your run (steps above) |

## Tests

```sh
cd ~/Desktop/keydillo-chrome/Browser
npm test                                    # everything, including test/chrome.test.mjs (tabs, cookies, side doors, dots)
KD_CHROME=1 node --test --test-concurrency=1 test/leaks.test.mjs test/keys.test.mjs test/signup.test.mjs
                                            # the sign-in, sign-up and key suites, driven through the extension
```

The relay in `src/chrome.mjs` is adapted from Playwright's extension relay (playwright-core, Apache-2.0, Microsoft).
