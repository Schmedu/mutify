// Shared helpers for the two Stripe-facing endpoints.
//
// No SDK on purpose: the whole server side is two calls to api.stripe.com, and
// a dependency-free function starts cold in a few milliseconds.

export const PRODUCT_ID = 'prod_VHxJtm1eDfmfWa';
export const CURRENCY = 'eur';

/** The floor, in cents. Mutify is pay-what-you-want above this. */
export const MIN_AMOUNT = 99;
/** A ceiling, so a slipped decimal point can't charge someone €99,000. */
export const MAX_AMOUNT = 50000;

/** Where the DMG comes from if GitHub's API is unreachable or rate-limited. */
const FALLBACK = {
  version: '1.0',
  url: 'https://github.com/Schmedu/mutify/releases/download/v1.0/Mutify-1.0.dmg',
};

const REPO = 'Schmedu/mutify';

export function stripe(path, { method = 'GET', body } = {}) {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw new Error('STRIPE_SECRET_KEY is not set');

  return fetch(`https://api.stripe.com/v1/${path}`, {
    method,
    headers: {
      Authorization: `Basic ${Buffer.from(`${key}:`).toString('base64')}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Stripe-Version': '2025-08-27.basil',
    },
    body: body ? form(body) : undefined,
  }).then(async (res) => {
    const json = await res.json();
    if (!res.ok) {
      const err = new Error(json?.error?.message ?? `Stripe returned ${res.status}`);
      err.status = res.status;
      err.stripeCode = json?.error?.code;
      throw err;
    }
    return json;
  });
}

/** Stripe speaks form encoding with bracketed nesting, not JSON. */
function form(obj, prefix = '', out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (typeof v === 'object') form(v, key, out);
    else out.append(key, String(v));
  }
  return out;
}

// One lookup per warm instance, so a burst of downloads is one call to GitHub.
let cached = null;
const TTL = 10 * 60 * 1000;

/** The newest release's .dmg, falling back to the last one we knew about. */
export async function latestDmg() {
  if (cached && Date.now() - cached.at < TTL) return cached.value;

  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'mutify-website' },
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) throw new Error(`GitHub returned ${res.status}`);

    const release = await res.json();
    const dmg = (release.assets ?? []).find((a) => a.name.endsWith('.dmg'));
    if (!dmg) throw new Error('no .dmg on the latest release');

    const value = {
      version: String(release.tag_name ?? '').replace(/^v/, '') || FALLBACK.version,
      url: dmg.browser_download_url,
      size: dmg.size,
    };
    cached = { at: Date.now(), value };
    return value;
  } catch {
    return FALLBACK;
  }
}

export function json(res, status, payload) {
  res.status(status)
    .setHeader('Content-Type', 'application/json; charset=utf-8')
    .setHeader('Cache-Control', 'no-store')
    .send(JSON.stringify(payload));
}
