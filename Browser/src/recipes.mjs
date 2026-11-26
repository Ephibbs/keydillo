// Key formats hidden everywhere, and per-provider API-key pages where every new value is hidden ("strict mode").

/** Known key formats. Matched in every tool result and file, even partially cut off (prefix + 12 chars). */
export const KEY_PATTERNS = [
  /sk-ant-[A-Za-z0-9_-]{12,}/g,                      // Anthropic
  /sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}/g, // OpenAI (also matches many sk- style keys)
  /github_pat_[A-Za-z0-9_]{12,}/g, /gh[pousr]_[A-Za-z0-9]{12,}/g, // GitHub
  /(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{12,}/g,        // Stripe secret and restricted keys
  /sk_[a-f0-9]{32,}/g,                                 // ElevenLabs
  /AKIA[0-9A-Z]{16}/g, /AIza[0-9A-Za-z_-]{30,}/g,      // AWS access key id, Google API key
  /xox[abposr]-[A-Za-z0-9-]{12,}/g, /glpat-[A-Za-z0-9_-]{12,}/g, /hf_[A-Za-z0-9]{20,}/g,
];

export function findKeyLike(text) {
  const out = new Set();
  for (const re of KEY_PATTERNS) for (const m of text.matchAll(re)) out.add(m[0]);
  return [...out];
}

/** Provider pages where API keys are created. Opening one turns on strict mode for that tab. */
export const RECIPES = [
  { provider: 'openai', page: /^https:\/\/platform\.openai\.com\/(api-keys|settings\/.*api-keys|organization\/api-keys)/, host: 'api.openai.com', keysUrl: 'https://platform.openai.com/api-keys' },
  { provider: 'anthropic', page: /^https:\/\/(console\.anthropic\.com|platform\.claude\.com)\/settings\/keys/, host: 'api.anthropic.com', keysUrl: 'https://console.anthropic.com/settings/keys' },
  { provider: 'github', page: /^https:\/\/github\.com\/settings\/(tokens|personal-access-tokens)/, host: 'api.github.com', keysUrl: 'https://github.com/settings/tokens' },
  { provider: 'stripe', page: /^https:\/\/dashboard\.stripe\.com\/(test\/)?apikeys/, host: 'api.stripe.com', keysUrl: 'https://dashboard.stripe.com/apikeys' },
  { provider: 'elevenlabs', page: /^https:\/\/elevenlabs\.io\/app\/(settings\/)?api-keys/, host: 'api.elevenlabs.io', keysUrl: 'https://elevenlabs.io/app/settings/api-keys' },
];

export const recipeFor = (url) => RECIPES.find((r) => r.page.test(url));

/** Button descriptions that mean "a new secret is about to be shown". */
export const CREATE_CLICK = /\b(create|generate|new|add|reveal|show|roll|regenerate)\b.*\b(key|token|secret)s?\b|\b(key|token|secret)\b.*\b(create|generate|reveal|show)\b/i;

/**
 * On a key page, anything new that isn't an ordinary word is hidden: 12+ characters with a digit, or 24+ of anything
 * without spaces. Over-hiding there is fine.
 */
export const looksLikeNewSecret = (t) => (t.length >= 12 && /[0-9]/.test(t) && /[A-Za-z]/.test(t)) || t.length >= 24;
